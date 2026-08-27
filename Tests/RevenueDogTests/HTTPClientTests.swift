//
//  HTTPClientTests.swift
//  出站请求快照 + 端点策略 + 重试协议（设计 §5 / §7）。
//

import Foundation
import Testing
@testable import RevenueDog

// 快照必须逐字节稳定，所以固定 appUserID / apiKey / baseURL / SystemInfo。
private let snapshotAppUserID = "$RCAnonymousID:0123456789abcdef0123456789abcdef"
private let snapshotAPIKey = "pk_test_0123456789"
private let snapshotBaseURL = URL(string: "https://api.revenuedog.com")!

private func makeClient(transport: any HTTPTransport,
                        retryPolicy: RetryPolicy = .default,
                        isBackgrounded: Bool = false) -> HTTPClient {
    HTTPClient(apiKey: snapshotAPIKey,
               baseURL: snapshotBaseURL,
               transport: transport,
               retryPolicy: retryPolicy,
               scheduler: NoDelayScheduler(),
               systemInfoProvider: { SystemInfo.fixture(isBackgrounded: isBackgrounded) },
               randomProvider: { 0.5 })
}

@Suite("HTTPClient — 出站请求快照")
struct RequestSnapshotTests {

    @Test("GET /v1/subscribers/{app_user_id}")
    func getSubscribersSnapshot() async throws {
        let transport = MockTransport(stubs: [
            .json(Fixtures.customerInfoOfficialExample,
                  headers: ["X-RevenueDog-Request-Time": "1564162810884"]),
        ])
        let client = makeClient(transport: transport)

        _ = try await client.perform(.getCustomerInfo(appUserID: snapshotAppUserID),
                                     as: CustomerInfoWireModel.self)

        let request = try #require(await transport.capturedRequests.first)
        try RequestSnapshot.assertMatches(request, named: "get-subscribers")
    }

    @Test("路径参数百分号编码：$ 与 : 都必须转义（契约 §1.1）")
    func pathEncoding() {
        #expect(Endpoint.getCustomerInfo(appUserID: snapshotAppUserID).path
                == "/v1/subscribers/%24RCAnonymousID%3A0123456789abcdef0123456789abcdef")
        #expect(Endpoint.getCustomerInfo(appUserID: "a/b").path == "/v1/subscribers/a%2Fb")
        #expect(Endpoint.getOfferings(appUserID: "user 42").path == "/v1/subscribers/user%2042/offerings")
    }

    @Test("诊断头全集齐备（设计 §5）")
    func diagnosticHeaders() async throws {
        let transport = MockTransport(stubs: [.json(Fixtures.customerInfoOfficialExample)])
        let client = makeClient(transport: transport)
        _ = try await client.perform(.getCustomerInfo(appUserID: snapshotAppUserID),
                                     as: CustomerInfoWireModel.self)

        let headers = try #require(await transport.capturedRequests.first?.allHTTPHeaderFields)
        for name in ["X-Platform", "X-Version", "X-Client-Version", "X-Is-Sandbox",
                     "X-Is-Backgrounded", "X-Is-Debug-Build", "X-Installation-Method",
                     "X-Platform-Device"] {
            #expect(headers[name] != nil, "缺少诊断头 \(name)")
        }
        #expect(headers["Authorization"] == "Bearer \(snapshotAPIKey)")
        #expect(headers["X-Is-Backgrounded"] == "false")
    }

    @Test("X-Is-Backgrounded 在发请求那一刻求值")
    func backgroundedHeaderIsEvaluatedPerRequest() async throws {
        let transport = MockTransport(stubs: [.json(Fixtures.customerInfoOfficialExample)])
        let client = makeClient(transport: transport, isBackgrounded: true)
        _ = try await client.perform(.getCustomerInfo(appUserID: snapshotAppUserID),
                                     as: CustomerInfoWireModel.self)

        let headers = try #require(await transport.capturedRequests.first?.allHTTPHeaderFields)
        #expect(headers["X-Is-Backgrounded"] == "true")
    }
}

@Suite("HTTPClient — 端点策略与响应")
struct EndpointPolicyTests {

    @Test("端点自带策略声明")
    func policies() {
        #expect(Endpoint.getCustomerInfo(appUserID: "u").method == .get)
        #expect(Endpoint.postReceipt.method == .post)
        #expect(Endpoint.getCustomerInfo(appUserID: "u").policy.usesETag)
        #expect(Endpoint.getCustomerInfo(appUserID: "u").policy.sendsPlatformHeader)
        // 契约 §1.5：POST /attributes 不必带 X-Platform。
        #expect(Endpoint.postAttributes(appUserID: "u").policy.sendsPlatformHeader == false)
        // SDK 只持 public key。
        for endpoint in [Endpoint.getCustomerInfo(appUserID: "u"), .getOfferings(appUserID: "u"),
                         .postAttributes(appUserID: "u"), .postReceipt] {
            #expect(endpoint.policy.authScope == .publicKey)
        }
    }

    @Test("201 → created；服务端时间头解析")
    func createdAndServerDate() async throws {
        let transport = MockTransport(stubs: [
            .json(Fixtures.customerInfoOfficialExample,
                  statusCode: 201,
                  headers: ["X-RevenueDog-Request-Time": "1564162810884"]),
        ])
        let client = makeClient(transport: transport)
        let response = try await client.perform(.getCustomerInfo(appUserID: "u"),
                                                as: CustomerInfoWireModel.self)

        #expect(response.statusCode == 201)
        #expect(response.serverRequestDate == Date(timeIntervalSince1970: 1_564_162_810.884))
    }

    @Test("兼容 RC 品牌的服务端时间头名（契约 ⟦决策3⟧ 未定名前两个都读）")
    func legacyRequestTimeHeader() {
        #expect(HTTPClient.serverRequestDate(from: ["X-RevenueCat-Request-Time": "1564162810884"]) != nil)
        #expect(HTTPClient.serverRequestDate(from: ["x-revenuedog-request-time": "1564162810884"]) != nil)
        #expect(HTTPClient.serverRequestDate(from: [:]) == nil)
    }

    @Test("错误体解析成 PurchasesError（契约 §1.4）")
    func errorBody() async throws {
        let transport = MockTransport(stubs: [
            .json(#"{"code": 7243, "message": "Secret API keys should not be used in your app."}"#,
                  statusCode: 403),
        ])
        let client = makeClient(transport: transport, retryPolicy: .none)

        await #expect(throws: PurchasesError.self) {
            _ = try await client.perform(.getOfferings(appUserID: "u"), as: OfferingsWireModel.self)
        }
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {

    private let policy = RetryPolicy.default

    @Test("5xx / 429 / 传输层错误重试；4xx 不重试")
    func retryDecisions() {
        #expect(policy.shouldRetry(attempt: 1, statusCode: 500, serverIsRetryable: nil, endpointIsRetryable: true))
        #expect(policy.shouldRetry(attempt: 1, statusCode: 429, serverIsRetryable: nil, endpointIsRetryable: true))
        #expect(policy.shouldRetry(attempt: 1, statusCode: nil, serverIsRetryable: nil, endpointIsRetryable: true))
        #expect(!policy.shouldRetry(attempt: 1, statusCode: 400, serverIsRetryable: nil, endpointIsRetryable: true))
        #expect(!policy.shouldRetry(attempt: 1, statusCode: 500, serverIsRetryable: nil, endpointIsRetryable: false))
        #expect(!policy.shouldRetry(attempt: 4, statusCode: 500, serverIsRetryable: nil, endpointIsRetryable: true))
    }

    @Test("Is-Retryable 头：false 一票否决，true 可让 4xx 也重试")
    func serverVeto() {
        #expect(!policy.shouldRetry(attempt: 1, statusCode: 500, serverIsRetryable: false, endpointIsRetryable: true))
        #expect(policy.shouldRetry(attempt: 1, statusCode: 400, serverIsRetryable: true, endpointIsRetryable: true))

        #expect(RetryPolicy.isRetryableHeaderValue(["Is-Retryable": "false"]) == false)
        #expect(RetryPolicy.isRetryableHeaderValue(["is-retryable": "TRUE"]) == true)
        #expect(RetryPolicy.isRetryableHeaderValue(["Is-Retryable": "maybe"]) == nil)
        #expect(RetryPolicy.isRetryableHeaderValue([:]) == nil)
    }

    @Test("Retry-After 优先于本地退避；只认 delta-seconds")
    func retryAfterWins() {
        #expect(RetryPolicy.retryAfterSeconds(["Retry-After": "12"]) == 12)
        #expect(RetryPolicy.retryAfterSeconds(["retry-after": " 3 "]) == 3)
        #expect(RetryPolicy.retryAfterSeconds(["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]) == nil)

        #expect(policy.delay(forAttempt: 1, retryAfter: 2, random: 0) == 2)
        // 超过 maxDelay 的 Retry-After 被夹到上限。
        #expect(policy.delay(forAttempt: 1, retryAfter: 600, random: 0) == policy.maxDelay)
    }

    @Test("指数退避 + jitter，且封顶")
    func backoffWithJitter() {
        // attempt=1 → base=0.75；jitterRatio=0.4 → 区间 [0.45, 0.75]
        #expect(policy.delay(forAttempt: 1, retryAfter: nil, random: 0) == 0.75 * 0.6)
        #expect(policy.delay(forAttempt: 1, retryAfter: nil, random: 1) == 0.75)
        // attempt=2 → 1.5
        #expect(policy.delay(forAttempt: 2, retryAfter: nil, random: 1) == 1.5)
        // 大 attempt 被 maxDelay 封顶
        #expect(policy.delay(forAttempt: 20, retryAfter: nil, random: 1) == policy.maxDelay)
    }

    @Test("HTTPClient 真的按策略重试：5xx 后成功")
    func clientRetriesAndSucceeds() async throws {
        let transport = MockTransport(stubs: [
            .failure(statusCode: 503),
            .failure(statusCode: 503),
            .json(Fixtures.customerInfoOfficialExample),
        ])
        let client = makeClient(transport: transport)

        let response = try await client.perform(.getCustomerInfo(appUserID: "u"),
                                                as: CustomerInfoWireModel.self)
        #expect(response.statusCode == 200)
        #expect(await transport.callCount == 3)
    }

    @Test("HTTPClient 尊重 Is-Retryable: false —— 一次就放弃")
    func clientRespectsServerVeto() async throws {
        let transport = MockTransport(stubs: [
            .failure(statusCode: 503, headers: ["Is-Retryable": "false"]),
            .json(Fixtures.customerInfoOfficialExample),
        ])
        let client = makeClient(transport: transport)

        await #expect(throws: PurchasesError.self) {
            _ = try await client.perform(.getCustomerInfo(appUserID: "u"), as: CustomerInfoWireModel.self)
        }
        #expect(await transport.callCount == 1)
    }
}
