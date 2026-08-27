//
//  HTTPClient.swift
//  网络层（设计 §5）。
//
//  - 端点自带策略声明（鉴权面 / 可重试性 / 是否走 ETag），HTTPClient 按声明执行。
//  - 重试：服务端 `Is-Retryable` 头**可否决** + `Retry-After` **优先** + jitter 退避。
//  - 诊断头全集见 SystemInfo.headers。
//  - 传输层协议化（HTTPTransport）以便测试注入 / 出站请求快照。
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 基本类型

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}

/// 鉴权面（契约 §1.2）。SDK 只持 public key；secret key 面永不在端上出现。
enum AuthScope: Sendable, Equatable {
    case publicKey
    case none
}

/// 端点策略声明（设计 §5）。
struct EndpointPolicy: Sendable, Equatable {
    /// 该端点在网络/5xx 失败时是否允许重试（幂等性判断）。
    var isRetryable: Bool
    /// 是否参与 ETag 协商缓存（契约 §1.3 ⟦决策4⟧ —— M1 只声明，ETagManager 留到 M2）。
    var usesETag: Bool
    /// 需要的鉴权面。
    var authScope: AuthScope
    /// 是否发送 `X-Platform`（契约 §1.5：GET /subscribers 给了才更新 last_seen）。
    var sendsPlatformHeader: Bool
}

// MARK: - Endpoint

enum Endpoint: Sendable, Equatable {

    /// `GET /v1/subscribers/{app_user_id}` —— 查询或创建 Customer（契约 §2.2）。
    case getCustomerInfo(appUserID: String)
    /// `GET /v1/subscribers/{app_user_id}/offerings`（契约 §2.3）。
    case getOfferings(appUserID: String)
    /// `POST /v1/subscribers/{app_user_id}/attributes`（契约 §2.4）—— M3。
    case postAttributes(appUserID: String)
    /// `POST /v1/receipts` —— 上报购买（契约 §2.1）—— M2。
    case postReceipt

    var method: HTTPMethod {
        switch self {
        case .getCustomerInfo, .getOfferings: return .get
        case .postAttributes, .postReceipt: return .post
        }
    }

    /// 路径参数（尤其 app_user_id）**必须 URL 编码**后再拼接（契约 §1.1）。
    var path: String {
        switch self {
        case .getCustomerInfo(let appUserID):
            return "/v1/subscribers/\(Endpoint.encodePathComponent(appUserID))"
        case .getOfferings(let appUserID):
            return "/v1/subscribers/\(Endpoint.encodePathComponent(appUserID))/offerings"
        case .postAttributes(let appUserID):
            return "/v1/subscribers/\(Endpoint.encodePathComponent(appUserID))/attributes"
        case .postReceipt:
            return "/v1/receipts"
        }
    }

    var policy: EndpointPolicy {
        switch self {
        case .getCustomerInfo:
            return EndpointPolicy(isRetryable: true, usesETag: true,
                                  authScope: .publicKey, sendsPlatformHeader: true)
        case .getOfferings:
            return EndpointPolicy(isRetryable: true, usesETag: true,
                                  authScope: .publicKey, sendsPlatformHeader: true)
        case .postAttributes:
            // LWW（updated_at_ms）保证幂等，可重试。
            return EndpointPolicy(isRetryable: true, usesETag: false,
                                  authScope: .publicKey, sendsPlatformHeader: false)
        case .postReceipt:
            // 契约 §1.6：同一 fetch_token 重复上报收敛为同一笔交易 → 幂等，可重试。
            return EndpointPolicy(isRetryable: true, usesETag: false,
                                  authScope: .publicKey, sendsPlatformHeader: true)
        }
    }

    /// 保守做法：路径段只保留 unreserved 字符，`$` / `:` 一律百分号编码。
    static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - 传输层

struct HTTPTransportResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

/// 传输层协议 —— 测试注入点（出站请求快照基建靠它）。
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse
}

struct URLSessionTransport: HTTPTransport {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func makeDefault(timeout: TimeInterval = 30) -> URLSessionTransport {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PurchasesError.network("非 HTTP 响应")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPTransportResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

// MARK: - 重试策略

/// 延迟调度器 —— 测试里换成 no-op，让重试路径不真的睡。
protocol DelayScheduler: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct TaskDelayScheduler: DelayScheduler {
    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

struct NoDelayScheduler: DelayScheduler {
    func sleep(seconds: TimeInterval) async throws {}
}

/// 设计 §5：`Is-Retryable` 头可否决 + `Retry-After` 优先 + JitterableDelay。
struct RetryPolicy: Sendable, Equatable {

    var maxRetries: Int = 3
    var baseDelay: TimeInterval = 0.75
    var maxDelay: TimeInterval = 8
    /// jitter 幅度：实际延迟 ∈ [d*(1-ratio), d]。
    var jitterRatio: Double = 0.4

    static let `default` = RetryPolicy()
    static let none = RetryPolicy(maxRetries: 0)

    /// 服务端 `Is-Retryable` 头：显式 `false` **一票否决**，显式 `true` 可让 4xx 也重试。
    static func isRetryableHeaderValue(_ headers: [String: String]) -> Bool? {
        guard let raw = headers.firstValue(forCaseInsensitiveKey: "Is-Retryable") else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    /// `Retry-After`：只支持 delta-seconds（保守；HTTP-date 形式忽略，回落退避算法）。
    static func retryAfterSeconds(_ headers: [String: String]) -> TimeInterval? {
        guard let raw = headers.firstValue(forCaseInsensitiveKey: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else { return nil }
        return seconds
    }

    /// 是否应该重试。
    /// - Parameters:
    ///   - attempt: 已经完成的尝试次数（首次请求后为 1）。
    ///   - statusCode: nil 表示传输层错误（超时/断网）。
    func shouldRetry(attempt: Int,
                     statusCode: Int?,
                     serverIsRetryable: Bool?,
                     endpointIsRetryable: Bool) -> Bool {
        guard endpointIsRetryable, attempt <= maxRetries else { return false }
        // 服务端一票否决优先于一切本地判断。
        if serverIsRetryable == false { return false }
        if serverIsRetryable == true { return true }
        guard let statusCode else { return true }        // 传输层错误 → 重试
        if statusCode == 429 { return true }
        return (500...599).contains(statusCode)
    }

    /// 退避延迟。`Retry-After` 优先于本地退避算法；jitter 用注入的随机数以便单测确定化。
    func delay(forAttempt attempt: Int,
               retryAfter: TimeInterval?,
               random: Double) -> TimeInterval {
        if let retryAfter { return min(retryAfter, maxDelay) }
        let exponential = baseDelay * pow(2, Double(max(0, attempt - 1)))
        let capped = min(exponential, maxDelay)
        let clampedRandom = min(max(random, 0), 1)
        let jitterFloor = capped * (1 - jitterRatio)
        return jitterFloor + (capped - jitterFloor) * clampedRandom
    }
}

extension [String: String] {

    func firstValue(forCaseInsensitiveKey key: String) -> String? {
        if let value = self[key] { return value }
        let lowered = key.lowercased()
        return first { $0.key.lowercased() == lowered }?.value
    }
}

// MARK: - 响应

struct HTTPResponse<Body: Sendable>: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Body
    /// 服务端时间（`X-RevenueDog-Request-Time` / `X-RevenueCat-Request-Time`，毫秒 epoch）。
    let serverRequestDate: Date?
}

// MARK: - HTTPClient

actor HTTPClient {

    /// 服务端时间头。契约 ⟦决策3⟧ 尚未定名 —— 保守做法：两个名字都读，优先自家品牌名。
    static let requestTimeHeaderNames = ["X-RevenueDog-Request-Time", "X-RevenueCat-Request-Time"]

    private let apiKey: String
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let scheduler: any DelayScheduler
    private let systemInfoProvider: @Sendable () -> SystemInfo
    private let randomProvider: @Sendable () -> Double

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(apiKey: String,
         baseURL: URL,
         transport: any HTTPTransport,
         retryPolicy: RetryPolicy = .default,
         scheduler: any DelayScheduler = TaskDelayScheduler(),
         systemInfoProvider: @escaping @Sendable () -> SystemInfo = { SystemInfo.current(isBackgrounded: AppStateProvider.isBackgrounded) },
         randomProvider: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.scheduler = scheduler
        self.systemInfoProvider = systemInfoProvider
        self.randomProvider = randomProvider
    }

    // MARK: 请求构造

    func makeRequest(for endpoint: Endpoint, body: Data? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PurchasesError.configuration("非法的 baseURL: \(baseURL)")
        }
        components.percentEncodedPath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) + endpoint.path
            : components.percentEncodedPath + endpoint.path
        guard let url = components.url else {
            throw PurchasesError.configuration("无法拼接 URL: \(baseURL)\(endpoint.path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = body

        let policy = endpoint.policy
        let systemInfo = systemInfoProvider()

        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if policy.authScope == .publicKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in systemInfo.headers {
            // X-Platform 按端点策略决定发不发（契约 §1.5）。
            if name == "X-Platform" && !policy.sendsPlatformHeader { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    // MARK: 执行

    func perform<Body: Decodable & Sendable>(_ endpoint: Endpoint,
                                             body: Data? = nil,
                                             as type: Body.Type) async throws -> HTTPResponse<Body> {
        let raw = try await performRaw(endpoint, body: body)
        do {
            let decoded = try decoder.decode(Body.self, from: raw.body)
            return HTTPResponse(statusCode: raw.statusCode,
                                headers: raw.headers,
                                body: decoded,
                                serverRequestDate: raw.serverRequestDate)
        } catch {
            throw PurchasesError.decoding("响应解码失败（\(endpoint.path)）", underlying: error)
        }
    }

    func performRaw(_ endpoint: Endpoint, body: Data? = nil) async throws -> HTTPResponse<Data> {
        let request = try makeRequest(for: endpoint, body: body)
        let policy = endpoint.policy
        var attempt = 0
        var lastError: (any Error)?

        while true {
            attempt += 1
            var statusCode: Int?
            var headers: [String: String] = [:]
            var payload = Data()

            do {
                let response = try await transport.send(request)
                statusCode = response.statusCode
                headers = response.headers
                payload = response.body
            } catch {
                lastError = error
                Log.debug("请求失败（第 \(attempt) 次）\(endpoint.path): \(error)", category: "network")
            }

            let serverIsRetryable = RetryPolicy.isRetryableHeaderValue(headers)

            if let statusCode, (200...299).contains(statusCode) {
                return HTTPResponse(statusCode: statusCode,
                                    headers: headers,
                                    body: payload,
                                    serverRequestDate: Self.serverRequestDate(from: headers))
            }

            let shouldRetry = retryPolicy.shouldRetry(attempt: attempt,
                                                      statusCode: statusCode,
                                                      serverIsRetryable: serverIsRetryable,
                                                      endpointIsRetryable: policy.isRetryable)
            guard shouldRetry else {
                if let statusCode {
                    throw Self.error(statusCode: statusCode, payload: payload, decoder: decoder)
                }
                throw PurchasesError.network("网络请求失败：\(endpoint.path)", underlying: lastError)
            }

            let delay = retryPolicy.delay(forAttempt: attempt,
                                          retryAfter: RetryPolicy.retryAfterSeconds(headers),
                                          random: randomProvider())
            Log.debug("\(endpoint.path) 第 \(attempt) 次失败，\(String(format: "%.2f", delay))s 后重试",
                      category: "network")
            try await scheduler.sleep(seconds: delay)
        }
    }

    // MARK: 辅助

    static func serverRequestDate(from headers: [String: String]) -> Date? {
        for name in requestTimeHeaderNames {
            if let raw = headers.firstValue(forCaseInsensitiveKey: name), let ms = Double(raw) {
                return Date(timeIntervalSince1970: ms / 1000)
            }
        }
        return nil
    }

    static func error(statusCode: Int, payload: Data, decoder: JSONDecoder) -> PurchasesError {
        let wire = try? decoder.decode(BackendErrorWireModel.self, from: payload)
        let message = wire?.message.isEmpty == false ? wire!.message : "HTTP \(statusCode)"
        let code: PurchasesErrorCode
        switch statusCode {
        case 401, 403: code = .invalidCredentialsError
        case 404: code = .invalidAppUserIdError
        case 400: code = .unexpectedBackendResponseError
        case 500...599: code = .unknownBackendError
        default: code = .unknownBackendError
        }
        return PurchasesError(code: code,
                              message: message,
                              backendCode: wire?.code,
                              httpStatusCode: statusCode)
    }

    func encode(_ value: some Encodable) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw PurchasesError(code: .unknownError, message: "请求体编码失败", underlyingError: error)
        }
    }
}
