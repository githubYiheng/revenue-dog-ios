//
//  M3AttributionTests.swift
//  ASA（AdServices）归因 token 采集与上报（设计 §8；核实 `docs/research/verify/asa-adservices.md`）。
//  坑矩阵：#83（模拟器不可用 / 绝不阻塞初始化与购买）、#84（平台门控）。
//
//  契约口径以**服务端** `workers/api/src/attribution.ts` 为准：
//  路径 `/v1/attribution/adservices`（契约 §5.3 写的 `-token` 后缀是旧草案）、
//  `install_id` 必填且需匹配 `^[A-Za-z0-9_-]{8,64}$`、`token` 与 `error_code` 至少有其一。
//

import Foundation
import Testing
@testable import RevenueDog

// MARK: - Fixtures

private func asaSubscriberJSON() -> String {
    """
    {"request_date":"2026-08-27T00:00:00Z","request_date_ms":1782518400000,
     "subscriber":{"original_app_user_id":"tester","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
    """
}

/// 按路径决定状态码的 transport：断言不依赖请求先后顺序。
private actor PathRoutedTransport: HTTPTransport {

    private let body: Data
    private var statusByPath: [String: Int] = [:]
    private(set) var capturedRequests: [URLRequest] = []

    init(responseJSON: String = asaSubscriberJSON()) {
        self.body = Data(responseJSON.utf8)
    }

    func setStatus(_ status: Int, forPath path: String) { statusByPath[path] = status }

    func requests(path: String) -> [URLRequest] { capturedRequests.filter { $0.url?.path == path } }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        capturedRequests.append(request)
        let status = request.url.flatMap { statusByPath[$0.path] } ?? 200
        // Is-Retryable: false —— 失败用例不必真的走三轮退避
        return HTTPTransportResponse(statusCode: status,
                                     headers: status == 200 ? [:] : ["Is-Retryable": "false"],
                                     body: body)
    }
}

private let adServicesPath = "/v1/attribution/adservices"

@MainActor
private func makeASA(
    provider: FakeAdServicesTokenProvider,
    transport: PathRoutedTransport,
    state: InMemoryAttributionStateStorage,
    identity: InMemoryIdentityStorage = InMemoryIdentityStorage(),
) -> (Purchases, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    let storeKit = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: identity,
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("RevenueDogM3ASA/\(UUID().uuidString)", isDirectory: true),
            storeKit: storeKit,
            delayScheduler: NoDelayScheduler(),   // 5s × 3 的等待在测试里不真睡
            attributionState: state,
            adServicesTokenProvider: provider,
        ),
    )
    return (purchases, storeKit)
}

private func asaWaitFor(timeoutMs: Int = 3000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

private func jsonBody(_ request: URLRequest?) -> [String: Any] {
    guard let data = request?.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

// 单例串行域（见 Support/SingletonSerialDomain.swift）：本 suite 碰 Purchases 静态单例。
extension PurchasesSingletonDomain {

    @MainActor
    @Suite("M3 ASA 归因采集", .serialized)
    struct M3AttributionTests {

        @Test("成功路径：token 上报 /v1/attribution/adservices，install_id 合法、带 app_user_id 与 collected_at_ms")
        func happyPathUploadsToken() async throws {
            let provider = FakeAdServicesTokenProvider(outcomes: [.success("token-abc")])
            let transport = PathRoutedTransport()
            let (purchases, _) = makeASA(provider: provider, transport: transport,
                                         state: InMemoryAttributionStateStorage())
            _ = try? await purchases.customerInfo(fetchPolicy: .cachedOnly) // 等启动收敛，拿到稳定身份
            let appUserID = purchases.appUserID

            purchases.attribution.enableAdServicesAttributionTokenCollection()

            let arrived = await asaWaitFor { await transport.requests(path: adServicesPath).count == 1 }
            #expect(arrived)

            let body = jsonBody(await transport.requests(path: adServicesPath).first)
            #expect(body["token"] as? String == "token-abc")
            #expect(body["error_code"] == nil)          // 成功时不带 error_code
            #expect(body["app_user_id"] as? String == appUserID)
            let installID = try #require(body["install_id"] as? String)
            // 服务端 attribution.ts 的硬校验：^[A-Za-z0-9_-]{8,64}$
            #expect(installID.count >= 8 && installID.count <= 64)
            #expect(installID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
            let collectedAt = try #require(body["collected_at_ms"] as? Int64 ?? (body["collected_at_ms"] as? Int).map(Int64.init))
            #expect(collectedAt > 1_700_000_000_000)    // 毫秒 epoch，不是秒

            #expect(await provider.callCount == 1)      // 一次就成功，不该有多余重试
        }

        @Test("5s×3 重试（核实 §1.4）：前两次 networkError → 第三次成功，仍然上报 token")
        func retriesTransientFailuresPerAppleGuidance() async throws {
            let provider = FakeAdServicesTokenProvider(outcomes: [.failure(.networkError),
                                                                  .failure(.networkError),
                                                                  .success("token-after-retry")])
            let transport = PathRoutedTransport()
            let (purchases, _) = makeASA(provider: provider, transport: transport,
                                         state: InMemoryAttributionStateStorage())
            purchases.attribution.enableAdServicesAttributionTokenCollection()

            let arrived = await asaWaitFor { await transport.requests(path: adServicesPath).count == 1 }
            #expect(arrived)
            #expect(await provider.callCount == 3)
            #expect(jsonBody(await transport.requests(path: adServicesPath).first)["token"] as? String
                    == "token-after-retry")
        }

        @Test("重试上限：一直 networkError → 共 4 次调用（1 + 3），上报 error_code=network_error 且不带 token")
        func exhaustsRetriesThenReportsErrorCode() async throws {
            let provider = FakeAdServicesTokenProvider(outcomes: [.failure(.networkError)])
            let transport = PathRoutedTransport()
            let (purchases, _) = makeASA(provider: provider, transport: transport,
                                         state: InMemoryAttributionStateStorage())
            purchases.attribution.enableAdServicesAttributionTokenCollection()

            let arrived = await asaWaitFor { await transport.requests(path: adServicesPath).count == 1 }
            #expect(arrived)
            #expect(await provider.callCount == 4) // 官方明文：5s 间隔、最多 3 次重试 = 总 4 次调用

            let body = jsonBody(await transport.requests(path: adServicesPath).first)
            #expect(body["token"] == nil)
            #expect(body["error_code"] as? String == "network_error") // 服务端 CLIENT_ERRORS 白名单内
        }

        @Test("platformNotSupported（模拟器/旧机型/无框架）：不重试，只调 1 次，上报 platform_not_supported")
        func platformNotSupportedIsTerminal() async throws {
            let provider = FakeAdServicesTokenProvider(outcomes: [.failure(.platformNotSupported)])
            let transport = PathRoutedTransport()
            let (purchases, _) = makeASA(provider: provider, transport: transport,
                                         state: InMemoryAttributionStateStorage())
            purchases.attribution.enableAdServicesAttributionTokenCollection()

            let arrived = await asaWaitFor { await transport.requests(path: adServicesPath).count == 1 }
            #expect(arrived)
            #expect(await provider.callCount == 1) // 终态错误，重试无意义
            #expect(jsonBody(await transport.requests(path: adServicesPath).first)["error_code"] as? String
                    == "platform_not_supported")
        }

        @Test("只采一次：同实例重复 enable 不重发；持久化标记让新实例也不再采")
        func collectsOnlyOnce() async throws {
            let state = InMemoryAttributionStateStorage()
            let provider = FakeAdServicesTokenProvider(outcomes: [.success("token-once")])
            let transport = PathRoutedTransport()
            let (purchases, _) = makeASA(provider: provider, transport: transport, state: state)

            purchases.attribution.enableAdServicesAttributionTokenCollection()
            let arrived = await asaWaitFor { await transport.requests(path: adServicesPath).count == 1 }
            #expect(arrived)
            purchases.attribution.enableAdServicesAttributionTokenCollection()
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(await transport.requests(path: adServicesPath).count == 1)
            #expect(await state.adServicesCollected())
            let firstInstallID = jsonBody(await transport.requests(path: adServicesPath).first)["install_id"] as? String

            // 换一个进程/实例（同一份持久化状态）：一次性标记生效，不再采
            let provider2 = FakeAdServicesTokenProvider(outcomes: [.success("token-second-launch")])
            let transport2 = PathRoutedTransport()
            let (purchases2, _) = makeASA(provider: provider2, transport: transport2, state: state)
            purchases2.attribution.enableAdServicesAttributionTokenCollection()
            try? await Task.sleep(nanoseconds: 300_000_000)
            #expect(await transport2.requests(path: adServicesPath).isEmpty)
            #expect(await provider2.callCount == 0)
            // install_id 一旦生成就必须稳定（它是服务端的幂等键，裁决 D2）
            #expect(await state.installID() == firstInstallID)
        }

        @Test("上报失败（5xx）不落一次性标记 —— 下次启动可以重来")
        func failedUploadKeepsRetryableNextLaunch() async throws {
            let state = InMemoryAttributionStateStorage()
            let provider = FakeAdServicesTokenProvider(outcomes: [.success("token-5xx")])
            let transport = PathRoutedTransport()
            await transport.setStatus(500, forPath: adServicesPath)
            let (purchases, _) = makeASA(provider: provider, transport: transport, state: state)

            purchases.attribution.enableAdServicesAttributionTokenCollection()
            let attempted = await asaWaitFor { await transport.requests(path: adServicesPath).count >= 1 }
            #expect(attempted)
            try? await Task.sleep(nanoseconds: 200_000_000)
            #expect(await state.adServicesCollected() == false)
            // install_id 已经生成并持久化，重来时复用同一个（幂等键不能换）
            #expect(await state.installID() != nil)

            let provider2 = FakeAdServicesTokenProvider(outcomes: [.success("token-retry-launch")])
            let transport2 = PathRoutedTransport()
            let (purchases2, _) = makeASA(provider: provider2, transport: transport2, state: state)
            purchases2.attribution.enableAdServicesAttributionTokenCollection()
            let retried = await asaWaitFor { await transport2.requests(path: adServicesPath).count == 1 }
            #expect(retried)
            #expect(await state.adServicesCollected())
            #expect(jsonBody(await transport2.requests(path: adServicesPath).first)["install_id"] as? String
                    == (await state.installID()))
        }

        @Test("#83：token 采集挂住时，购买链路照常完成（采集绝不阻塞初始化/购买）")
        func collectionNeverBlocksPurchase() async throws {
            let provider = FakeAdServicesTokenProvider(outcomes: [.success("token-slow")])
            await provider.setSuspendSeconds(3)
            let transport = PathRoutedTransport()
            let (purchases, storeKit) = makeASA(provider: provider, transport: transport,
                                                state: InMemoryAttributionStateStorage())

            purchases.attribution.enableAdServicesAttributionTokenCollection()

            let flag = FinishFlag()
            await storeKit.scriptPurchase { productID in
                .success(FakeTransaction(transactionIdentifier: "tx-asa",
                                         originalTransactionIdentifier: "tx-asa",
                                         productIdentifier: productID,
                                         purchaseDate: Date(),
                                         expirationDate: Date().addingTimeInterval(3600),
                                         jwsRepresentation: "h.asa.s",
                                         finishFlag: flag))
            }
            let result = try await purchases.purchase(
                product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                      localizedDescription: "", price: 9.99, currencyCode: "USD",
                                      localizedPriceString: "$9.99"))
            #expect(result.transactionIdentifier == "tx-asa")
            #expect(flag.value)
            // 采集还挂在 provider 里，归因请求一条都没发 —— 证明购买没被它拖住
            #expect(await transport.requests(path: adServicesPath).isEmpty)
        }

        @Test("决策 20：logIn 的 identify 请求携带持久化的 install_id；无 install_id 时不带键")
        func identifyCarriesInstallID() async throws {
            let state = InMemoryAttributionStateStorage()
            await state.setInstallID("0123456789abcdef0123456789abcdef")
            let transport = PathRoutedTransport()
            let (purchases, _) = makeASA(provider: FakeAdServicesTokenProvider(outcomes: []),
                                         transport: transport, state: state)
            _ = try? await purchases.customerInfo(fetchPolicy: .cachedOnly) // 等启动收敛
            _ = try await purchases.logIn("carol")
            let identify = await transport.requests(path: "/v1/subscribers/identify").last
            #expect(jsonBody(identify)["install_id"] as? String == "0123456789abcdef0123456789abcdef")

            let transport2 = PathRoutedTransport()
            let (purchases2, _) = makeASA(provider: FakeAdServicesTokenProvider(outcomes: []),
                                          transport: transport2, state: InMemoryAttributionStateStorage())
            _ = try? await purchases2.customerInfo(fetchPolicy: .cachedOnly)
            _ = try await purchases2.logIn("dave")
            let identify2 = await transport2.requests(path: "/v1/subscribers/identify").last
            #expect(identify2 != nil)
            #expect(jsonBody(identify2)["install_id"] == nil)
        }
    }
}
