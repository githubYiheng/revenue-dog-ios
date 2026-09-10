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
    /// `POST /v1/subscribers/identify` —— logIn 合并（服务端四分支矩阵）—— M3。
    case postIdentify
    /// `POST /v1/attribution/adservices` —— ASA token 上报 —— M3。
    ///
    /// ⚠️ 契约 §5.3 写的是 `/v1/attribution/adservices-token` 且自标「形状未定稿」；
    /// 以服务端 `workers/api/src/attribution.ts` + 契约附录 A 决策 20 为准 → `/v1/attribution/adservices`。
    case postAdServicesAttribution
    /// `POST /v1/diagnostics/entitlement-diff` —— 档 1 权益一致率上报（迁移方案 v2.1 §5 M-3）。
    case postEntitlementDiff
    /// `POST /v1/diagnostics/events` —— SDK 客户端诊断事件攒批上报（sdk-diagnostics §1）。
    case postDiagnosticsEvents

    var method: HTTPMethod {
        switch self {
        case .getCustomerInfo, .getOfferings: return .get
        case .postAttributes, .postReceipt, .postIdentify, .postAdServicesAttribution,
             .postEntitlementDiff, .postDiagnosticsEvents: return .post
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
        case .postIdentify:
            return "/v1/subscribers/identify"
        case .postAdServicesAttribution:
            return "/v1/attribution/adservices"
        case .postEntitlementDiff:
            return "/v1/diagnostics/entitlement-diff"
        case .postDiagnosticsEvents:
            return "/v1/diagnostics/events"
        }
    }

    /// 进诊断事件 `http_error.path` 的**脱敏路径**：app_user_id 段一律换成 `*`
    /// （契约 §1.3：`/v1/subscribers/*`）。app_user_id 可能是宿主 uid，不进 fields。
    var diagnosticsPath: String {
        switch self {
        case .getCustomerInfo: return "/v1/subscribers/*"
        case .getOfferings: return "/v1/subscribers/*/offerings"
        case .postAttributes: return "/v1/subscribers/*/attributes"
        case .postReceipt, .postIdentify, .postAdServicesAttribution,
             .postEntitlementDiff, .postDiagnosticsEvents:
            return path
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
        case .postIdentify:
            // 四分支矩阵确定性收敛（重复 identify 落「同一 customer」早退分支）→ 幂等，可重试。
            return EndpointPolicy(isRetryable: true, usesETag: false,
                                  authScope: .publicKey, sendsPlatformHeader: true)
        case .postAdServicesAttribution:
            // 服务端按 install_id 做 UPSERT（裁决 D2：install_id 是幂等键）→ 幂等，可重试。
            return EndpointPolicy(isRetryable: true, usesETag: false,
                                  authScope: .publicKey, sendsPlatformHeader: true)
        case .postEntitlementDiff:
            // **不可重试**：每次上报是一条独立观测样本，没有幂等键；网络抖动重发会把
            // 同一次观测计成多条，直接污染日聚合的「权益一致率」（档 1 出口条件的分母）。
            // 丢一次样本无所谓 —— 宿主在 RC `customerInfoStream` 每次更新时都会再报
            // （接线模板 dual-sdk-integration.md §5），服务端还有每用户每天 cap 兜底。
            return EndpointPolicy(isRetryable: false, usesETag: false,
                                  authScope: .publicKey, sendsPlatformHeader: true)
        case .postDiagnosticsEvents:
            // **不重试**（sdk-diagnostics §2）：重发节奏归 `DiagnosticsUploader` 的退避掌管。
            // 让 HTTPClient 在一次调用里连打四发，会把「30s 起、×2、上限 1h」的口径架空。
            // 服务端按事件 `id` 做 `INSERT OR IGNORE`，重发本身是幂等的 —— 这里不重试是节奏问题，不是幂等问题。
            return EndpointPolicy(isRetryable: false, usesETag: false,
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

/// 一次 HTTP 往返的响应。
///
/// **公开面的存在理由只有一个：让宿主能在自己的测试里塞一个假后端**
/// （`Configuration.with(transport:)`）。生产接线不需要碰它。
public struct HTTPTransportResponse: Sendable {

    public let statusCode: Int
    /// 响应头。SDK 读 `X-Request-Id` / `Retry-After` / `Is-Retryable`（设计 §5）。
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// 传输层协议 —— SDK 全部出站请求的唯一出口。
///
/// **仅测试用**：宿主在集成测试里实现它 + `Configuration.with(transport:)`，
/// 就能在不连后端的情况下跑完整条 SDK 链路（SDK 自己的 StoreKitTest 套件就是这么做的）。
/// 生产环境不要注入 —— 不注入时 SDK 用内置的 `URLSession` 实现（含超时/缓存策略）。
///
/// 实现要求：`send` 只做「发出去、把响应原样带回来」。重试、退避、`Retry-After`、
/// 鉴权头、诊断头一律由 SDK 自己在上层做，实现方**不要**重复一遍。
public protocol HTTPTransport: Sendable {
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

/// `performUnchecked` 的返回：原始状态码 + 头 + body，`statusCode == nil` = 传输层错误。
struct HTTPUncheckedResponse: Sendable {
    let statusCode: Int?
    let headers: [String: String]
    let body: Data
}

// MARK: - 调用观测句柄（诊断事件用）

/// 一次 `perform` / `performRaw` 调用的观测句柄。
///
/// 存在的理由：`PurchasesError` 是**公开**类型，不能为了诊断往里塞 `request_id`
/// （公开面只进不出，一条诊断需求不该扩公开 API）。所以调用方按需传一个 trace 进去，
/// HTTPClient 每次尝试结束时往里填一笔，调用方读回最后一次的 status / `X-Request-Id` / 耗时。
///
/// `extraFields` 是调用方要**补进该端点事件**的字段（如 receipts 的 `transaction_id`）——
/// HTTPClient 自己不认识交易，但它是唯一握有 attempt / 耗时 / request_id 的地方。
final class HTTPCallTrace: @unchecked Sendable {

    struct Attempt: Sendable, Equatable {
        let attempt: Int
        /// nil = 传输层错误（超时 / 断网）。
        let statusCode: Int?
        let requestID: String?
        let durationMs: Int
    }

    private let lock = NSLock()
    private var storage: [Attempt] = []
    private var extra: [String: DiagnosticsFieldValue]

    init(extraFields: [String: DiagnosticsFieldValue] = [:]) {
        self.extra = extraFields
    }

    /// 追加一个要补进该端点事件的字段（如 receipts 的 `transaction_id`）。
    func addExtraField(_ key: String, _ value: DiagnosticsFieldValue) {
        lock.lock(); defer { lock.unlock() }
        extra[key] = value
    }

    var extraFields: [String: DiagnosticsFieldValue] {
        lock.lock(); defer { lock.unlock() }
        return extra
    }

    func record(_ attempt: Attempt) {
        lock.lock(); defer { lock.unlock() }
        storage.append(attempt)
    }

    var attempts: [Attempt] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var last: Attempt? {
        lock.lock(); defer { lock.unlock() }
        return storage.last
    }
}

// MARK: - HTTPClient

actor HTTPClient {

    /// 服务端请求 id 头（契约 §1.3：`request_id` 一律取它）。
    static let requestIDHeaderName = "X-Request-Id"

    /// 服务端时间头。契约 ⟦决策3⟧ 尚未定名 —— 保守做法：两个名字都读，优先自家品牌名。
    static let requestTimeHeaderNames = ["X-RevenueDog-Request-Time", "X-RevenueCat-Request-Time"]

    private let apiKey: String
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let scheduler: any DelayScheduler
    private let systemInfoProvider: @Sendable () -> SystemInfo
    private let randomProvider: @Sendable () -> Double
    /// 客户端诊断（sdk-diagnostics §1.3：`receipt_post` / `http_error` 的唯一记录点）。
    /// 后置注入：Recorder 的 uploader 反过来依赖本 client，构造期无法闭环。
    private var diagnostics: DiagnosticsRecorder?

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

    /// 由 `Purchases.start()` 在任何请求发生前注入一次。
    func setDiagnostics(_ recorder: DiagnosticsRecorder?) {
        diagnostics = recorder
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
                                             as type: Body.Type,
                                             trace: HTTPCallTrace? = nil) async throws -> HTTPResponse<Body> {
        let raw = try await performRaw(endpoint, body: body, trace: trace)
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

    func performRaw(_ endpoint: Endpoint,
                    body: Data? = nil,
                    trace: HTTPCallTrace? = nil) async throws -> HTTPResponse<Data> {
        let request = try makeRequest(for: endpoint, body: body)
        let policy = endpoint.policy
        var attempt = 0
        var lastError: (any Error)?

        while true {
            attempt += 1
            var statusCode: Int?
            var headers: [String: String] = [:]
            var payload = Data()
            let startedAt = Date()

            do {
                let response = try await transport.send(request)
                statusCode = response.statusCode
                headers = response.headers
                payload = response.body
            } catch {
                lastError = error
                Log.debug("请求失败（第 \(attempt) 次）\(endpoint.path): \(error)", category: "network")
            }

            // 每次尝试结束就记一笔（契约 §1.3：receipt_post 的记录点就是「每次尝试结束」）。
            // 这里 **await** 而不是 fire-and-forget：事件顺序是排查的全部价值所在，
            // 队列写入是一次极小的文件追加，网络上传由 Recorder 另起 Task，不会卡住请求。
            let durationMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
            let requestID = headers.firstValue(forCaseInsensitiveKey: Self.requestIDHeaderName)
            trace?.record(HTTPCallTrace.Attempt(attempt: attempt,
                                                statusCode: statusCode,
                                                requestID: requestID,
                                                durationMs: durationMs))
            if let diagnostics {
                await diagnostics.recordHTTPAttempt(endpoint: endpoint,
                                                    attempt: attempt,
                                                    statusCode: statusCode,
                                                    requestID: requestID,
                                                    durationMs: durationMs,
                                                    errorCode: Self.diagnosticErrorCode(statusCode: statusCode,
                                                                                        payload: payload,
                                                                                        decoder: decoder),
                                                    extraFields: trace?.extraFields ?? [:])
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

    /// 发一次、**不重试、不把非 2xx 转成错误**：诊断上传要按原始 HTTP 状态码分类
    /// （sdk-diagnostics §6-10）。经 `PurchasesError` 映射会把 413 / 429 / 503 揉成同几个 code，
    /// 而上传器的处置矩阵恰恰是**按状态码**分叉的（丢批 / 停摆 / 退避各不相同）。
    ///
    /// 本路径同样不记诊断事件（`recordHTTPAttempt` 对该端点直接返回），不会自激。
    func performUnchecked(_ endpoint: Endpoint, body: Data? = nil) async -> HTTPUncheckedResponse {
        do {
            let request = try makeRequest(for: endpoint, body: body)
            let response = try await transport.send(request)
            return HTTPUncheckedResponse(statusCode: response.statusCode,
                                         headers: response.headers,
                                         body: response.body)
        } catch {
            return HTTPUncheckedResponse(statusCode: nil, headers: [:], body: Data())
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

    /// 诊断事件的 `error_code`：优先取后端错误体里的数值码（契约 §1.4，如 7243 = 用错了 secret key），
    /// 没有就退回 SDK 自己的 code 名。**永远是字符串、永远不带 message**（契约 §1.3 末段）。
    static func diagnosticErrorCode(statusCode: Int?, payload: Data, decoder: JSONDecoder) -> String? {
        guard let statusCode else { return PurchasesErrorCode.networkError.name }
        guard !(200...299).contains(statusCode) else { return nil }
        if let code = (try? decoder.decode(BackendErrorWireModel.self, from: payload))?.code {
            return String(code)
        }
        return Self.error(statusCode: statusCode, payload: payload, decoder: decoder).code.name
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
