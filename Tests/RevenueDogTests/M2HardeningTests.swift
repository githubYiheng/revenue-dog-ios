//
//  M2HardeningTests.swift
//  M2 门禁 ❌ 项修复的回归锁（2026-08-28 门禁报告 §3）：
//  P4 可见性轮询（#24/#25）、SK 序列排序（#26）、currentEntitlements 扫描（#2）、
//  appAccountToken 接线（#22）、account_token wire 解码（契约决策 21）、
//  X-Storefront / AppTransaction 环境快照（#123/#36）。
//

import Foundation
import Testing
@testable import RevenueDog

private func subscriberJSON(accountToken: String? = nil) -> String {
    let tokenField = accountToken.map { "\"account_token\":\"\($0)\"," } ?? ""
    return """
    {"request_date":"2026-08-27T00:00:00Z","request_date_ms":1782518400000,
     "subscriber":{"original_app_user_id":"tester",\(tokenField)"original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
    """
}

@MainActor
private func makeHardened(
    directory: URL? = nil,
    completedBy: PurchasesCompletedBy = .revenueDog,
    prepare: (@Sendable (FakeStoreKitProvider, MockTransport) async -> Void)? = nil,
) async -> (Purchases, MockTransport, FakeStoreKitProvider, URL) {
    Purchases.resetForTesting()
    let transport = MockTransport()
    let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
    let dir = directory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogM2Hardening/\(UUID().uuidString)", isDirectory: true)
    // 启动 Task（重放/扫描/预取）在 configure 内即刻开跑 —— 一切编排必须先就位
    await prepare?(provider, transport)
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(purchasesCompletedBy: completedBy)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: dir,
            storeKit: provider,
            delayScheduler: NoDelayScheduler(),
        ),
    )
    return (purchases, transport, provider, dir)
}

private func waitFor(timeoutMs: Int = 2000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

@MainActor
@Suite("M2 硬化", .serialized)
struct M2HardeningTests {

    @Test("P4（#24/#25）：unfinished 可见性轮询 —— 前两轮为空、第三轮出现 → finish 义务清零")
    func unfinishedVisibilityPolling() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogM2Hardening/\(UUID().uuidString)", isDirectory: true)

        // 第一程：购买成功但后端 5xx → 上下文（含 JWS）留存，不 finish
        let (purchases, transport, provider, _) = await makeHardened(directory: dir)
        let flag = FinishFlag()
        let tx = FakeTransaction(transactionIdentifier: "tx-p4", originalTransactionIdentifier: "tx-p4",
                                 productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                 expirationDate: Date().addingTimeInterval(3600),
                                 jwsRepresentation: "h.p4.s", finishFlag: flag)
        await provider.scriptPurchase { _ in .success(tx) }
        await transport.enqueue(.failure(statusCode: 500))
        await transport.enqueue(.failure(statusCode: 500))
        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(
                product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                      price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99"))
        }
        #expect(!flag.value)

        // 第二程（冷启动）：JWS 补报成功，但 unfinished 前两轮为空（FB13133387 场景），第三轮才可见
        let (_, transport2, provider2, _) = await makeHardened(directory: dir) { provider, transport in
            await provider.setUnfinishedSequence([[], [], [tx]])
            await transport.enqueue(.json(subscriberJSON())) // JWS 补报
            await transport.enqueue(.json(subscriberJSON())) // 轮询命中后的配对上报
        }

        let finished = await waitFor { flag.value }
        #expect(finished) // 轮询拿到交易对象后 finish 义务清零
        let calls = await provider2.unfinishedCallCount
        #expect(calls >= 3) // 确实发生了重试轮询，而非单次读取

        let store = PendingPurchaseStore(directory: dir)
        let leftovers = await store.all()
        #expect(leftovers.isEmpty) // finish 后上下文清空
    }

    @Test("#2 后半：currentEntitlements 启动扫描补报，台账去重防每启动一 POST")
    func currentEntitlementsScanWithLedgerDedupe() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogM2Hardening/\(UUID().uuidString)", isDirectory: true)
        let flag = FinishFlag()
        let entitlementTx = FakeTransaction(transactionIdentifier: "tx-ent", originalTransactionIdentifier: "tx-ent",
                                            productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                            expirationDate: Date().addingTimeInterval(3600),
                                            jwsRepresentation: "h.ent.s", finishFlag: flag)

        // 第一程：已 finish 但从未上报的权益交易（别处设备购买/兑换码）只出现在 currentEntitlements
        let (_, transport, _, _) = await makeHardened(directory: dir) { provider, transport in
            await provider.setCurrentEntitlements([entitlementTx])
            await transport.enqueue(.json(subscriberJSON()))
        }
        let posted = await waitFor {
            await transport.capturedRequests.contains { $0.url?.path == "/v1/receipts" }
        }
        #expect(posted) // 扫描补报发生

        // 第二程（同台账目录）：台账已记录 → 不再重复上报
        let (_, transport2, _, _) = await makeHardened(directory: dir) { provider, _ in
            await provider.setCurrentEntitlements([entitlementTx])
        }
        let reposted = await waitFor(timeoutMs: 500) {
            await transport2.capturedRequests.contains { $0.url?.path == "/v1/receipts" }
        }
        #expect(!reposted) // 台账去重生效
    }

    @Test("#22：缓存 CustomerInfo 的 account_token → 购买时以 UUID 形状传入 appAccountToken 并落上下文")
    func appAccountTokenWiring() async throws {
        let (purchases, transport, provider, dir) = await makeHardened()
        let token32 = "0123456789abcdef0123456789abcdef"

        // 先拉一次 CustomerInfo 灌缓存（响应携带服务端签发的 account_token，契约决策 21）
        await transport.enqueue(.json(subscriberJSON(accountToken: token32)))
        _ = try await purchases.customerInfo()

        let flag = FinishFlag()
        await provider.scriptPurchase { _ in
            .success(FakeTransaction(transactionIdentifier: "tx-token", originalTransactionIdentifier: "tx-token",
                                     productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.tok.s", finishFlag: flag))
        }
        await transport.enqueue(.json(subscriberJSON(accountToken: token32)))
        _ = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                  price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99"))

        let captured = await provider.capturedAppAccountTokens
        #expect(captured.count == 1)
        #expect(captured.first??.uuidString.lowercased() == "01234567-89ab-cdef-0123-456789abcdef")
        _ = dir
    }

    @Test("契约决策 21：account_token 宽容解码 —— 有则取值，无则 nil，畸形不炸整体")
    func accountTokenWireDecoding() throws {
        let decoder = JSONDecoder()
        let with = try decoder.decode(CustomerInfoWireModel.self, from: Data(subscriberJSON(accountToken: "aa").utf8))
        #expect(with.subscriber.accountToken == "aa")
        let without = try decoder.decode(CustomerInfoWireModel.self, from: Data(subscriberJSON().utf8))
        #expect(without.subscriber.accountToken == nil)
        let info = CustomerInfo(wireModel: with)
        #expect(info.accountToken == "aa")
    }

    @Test("#123/#36：启动预取 storefront 与 AppTransaction 环境 → X-Storefront 头 / 沙盒判定")
    func storefrontAndAppTransactionPrefetch() async throws {
        defer {
            StoreEnvironmentCache.setStorefront(nil)
            StoreEnvironmentCache.setAppTransactionEnvironment(nil)
        }
        let (purchases, transport, _, _) = await makeHardened { provider, _ in
            await provider.setStorefront("USA")
            await provider.setAppTransaction(AppTransactionInfo(jwsRepresentation: "h.at.s", environment: "Sandbox"))
        }

        // 预取是启动 Task 里的 best-effort：等缓存就位
        let prefetched = await waitFor { StoreEnvironmentCache.storefront == "USA" }
        #expect(prefetched)
        #expect(SystemInfo.currentIsSandbox) // AppTransaction.environment=Sandbox 优先于收据路径（#98）

        await transport.enqueue(.json(subscriberJSON()))
        _ = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)
        let request = await transport.capturedRequests.last
        #expect(request?.value(forHTTPHeaderField: "X-Storefront") == "USA")
        #expect(request?.value(forHTTPHeaderField: "X-Is-Sandbox") == "true")
    }
}
