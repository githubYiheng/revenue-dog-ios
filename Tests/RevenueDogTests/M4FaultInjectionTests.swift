//
//  M4FaultInjectionTests.swift
//  M4 硬化第一批 —— **故障注入**（设计 §9 M4：5xx / 超时 / 崩溃重放）。
//
//  四组：
//  1. 端点重试策略（设计 §5、坑 #73/#74/#127）：5xx / 429+Retry-After / 超时 / 断网 下
//     每个端点是否按自己的 `EndpointPolicy.isRetryable` 行事；不可重试错误不重试；
//     重试次数有上限；**重试期间不重复 finish**（铁律 P2、坑 #7/#8）。
//  2. 崩溃重放三切点（铁律 P3、坑 #2/#24/#25/#132）：进程死在 ①上报前 ②上报后 finish 前
//     ③finish 后台账写入前，重启新实例后 `PendingPurchaseStore` + unfinished 扫描 +
//     `SyncedTransactionLedger` 的恢复行为。
//  3. 冷启动后端不可达（设计 §4、坑 #55/#56/#58）：各 FetchPolicy 的离线返回与 stale 语义，
//     以及「stale 结果不回写缓存」。
//  4. Ask-to-Buy / SCA 的 `.pending` 残余边界（门禁报告 §2、坑 #15/#16）：
//     pending → 发起键保留 → updates 到达后按商品配对，归因不丢、只上报一次。
//
//  测试替身复用 PurchaseFlowTests 里的 `FakeTransaction` / `FinishFlag` / `FakeProduct`
//  与 Support/MockTransport 的路径维度编排。
//

import Foundation
import Testing
@testable import RevenueDog

// MARK: - 路径常量

private let receiptsPath = "/v1/receipts"
private let identifyPath = "/v1/subscribers/identify"
private let entitlementDiffPath = "/v1/diagnostics/entitlement-diff"
private let attributesPath = "/attributes"          // 带 appUserID，用后缀匹配

// MARK: - Fixtures

private func subscriberJSON(nonSubscriptionTxIDs: [String] = []) -> String {
    let nonSubs = nonSubscriptionTxIDs.isEmpty
        ? "{}"
        : "{\"com.demo.coins\": [\(nonSubscriptionTxIDs.map { "{\"id\": \"\($0)\", \"purchase_date\": \"2026-08-20T10:00:00Z\", \"store\": \"app_store\", \"is_sandbox\": false}" }.joined(separator: ","))]}"
    return """
    {"request_date":"2026-08-27T00:00:00Z","request_date_ms":1782518400000,
     "subscriber":{"original_app_user_id":"tester","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":\(nonSubs)}}
    """
}

/// 服务端时间 = 现在、且带一条未到期权益的响应 —— 用来端到端验 3 天 grace（坑 #56）。
private func freshSubscriberJSONWithEntitlement() -> String {
    let formatter = ISO8601DateFormatter()
    let now = Date()
    let requestDate = formatter.string(from: now)
    let expires = formatter.string(from: now.addingTimeInterval(3600))
    let purchase = formatter.string(from: now.addingTimeInterval(-3600))
    return """
    {"request_date":"\(requestDate)","request_date_ms":\(Int64(now.timeIntervalSince1970 * 1000)),
     "subscriber":{"original_app_user_id":"tester","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"\(requestDate)",
       "management_url":null,
       "entitlements":{"pro":{"expires_date":"\(expires)","grace_period_expires_date":null,
                              "product_identifier":"com.demo.monthly","purchase_date":"\(purchase)"}},
       "subscriptions":{},"non_subscriptions":{}}}
    """
}

private func monthly() -> StoreProduct {
    StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                 price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99")
}

// MARK: - 写次数可观测的缓存后端（坑 #58：stale 结果不得回写缓存）

actor CountingCacheStorage: CacheStorage {

    private let inner = InMemoryCacheStorage()
    private(set) var writeCount = 0

    func read<Value: Codable & Sendable>(forKey key: String) async -> DeviceCache.Entry<Value>? {
        await inner.read(forKey: key)
    }

    func write<Value: Codable & Sendable>(_ entry: DeviceCache.Entry<Value>, forKey key: String) async {
        writeCount += 1
        await inner.write(entry, forKey: key)
    }

    func remove(forKey key: String) async {
        await inner.remove(forKey: key)
    }
}

// MARK: - 组装

@MainActor
private func makeRig(
    directory: URL,
    transport: MockTransport,
    storeKit: (any StoreKitProvider)?,
    identityStorage: any IdentityStorage,
    cacheStorage: any CacheStorage,
    completedBy: PurchasesCompletedBy = .revenueDog,
    networkScheduler: any DelayScheduler = NoDelayScheduler(),
) -> Purchases {
    Purchases.resetForTesting()
    return Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(purchasesCompletedBy: completedBy)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: identityStorage,
            cacheStorage: cacheStorage,
            transport: transport,
            pendingPurchasesDirectory: directory,
            storeKit: storeKit,
            delayScheduler: NoDelayScheduler(),
            networkDelayScheduler: networkScheduler,
        ),
    )
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogM4/\(UUID().uuidString)", isDirectory: true)
}

// MARK: - 1. 端点重试策略

// 单例串行域（见 Support/SingletonSerialDomain.swift）。
extension PurchasesSingletonDomain {
@MainActor
@Suite("M4 故障注入 · 重试策略", .serialized)
struct M4RetryFaultTests {

    /// `RetryPolicy.default.maxRetries = 3` → 首发 + 3 次重试 = 4 次调用。
    private static let attemptsWithRetries = 4

    @Test("#73/#74 + P2：receipts 一直 5xx → 首发+3 次重试后放弃；全程零 finish、上下文（含 JWS）留存")
    func receiptsRetriesFiveHundredThenGivesUp() async throws {
        let dir = tempDirectory()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let purchases = makeRig(directory: dir, transport: transport, storeKit: provider,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-m4-500",
                                     originalTransactionIdentifier: "tx-m4-500",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.m4a.s", finishFlag: flag))
        }
        await transport.enqueue(.failure(statusCode: 500), forPath: receiptsPath) // 粘住：一直 500

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(product: monthly())
        }

        #expect(await transport.callCount(forPath: receiptsPath) == Self.attemptsWithRetries)
        #expect(flag.callCount == 0) // 5xx 绝不 finish（铁律 P2 / 坑 #8）

        // 上下文留存且带 JWS —— 重放的必要条件（铁律 P3）
        let leftovers = await PendingPurchaseStore(directory: dir).all()
        #expect(leftovers.count == 1)
        #expect(leftovers.first?.jws == "h.m4a.s")
        #expect(leftovers.first?.key == "tx-m4-500")
    }

    @Test("#73：429 带 Retry-After → 退避时长取头部值（不走本地指数退避），恢复后只 finish 一次")
    func receiptsHonoursRetryAfterAndFinishesOnce() async throws {
        let dir = tempDirectory()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let scheduler = RecordingDelayScheduler()
        let purchases = makeRig(directory: dir, transport: transport, storeKit: provider,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage(),
                                networkScheduler: scheduler)
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-m4-429",
                                     originalTransactionIdentifier: "tx-m4-429",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.m4b.s", finishFlag: flag))
        }
        await transport.enqueue(.failure(statusCode: 429, headers: ["Retry-After": "2"]), forPath: receiptsPath)
        await transport.enqueue(.json(subscriberJSON()), forPath: receiptsPath)

        let result = try await purchases.purchase(product: monthly())

        #expect(result.transactionIdentifier == "tx-m4-429")
        #expect(await transport.callCount(forPath: receiptsPath) == 2)
        // Retry-After 优先：唯一一次退避的时长 = 头部声明的 2s，而不是 baseDelay(0.75)*jitter。
        #expect(await scheduler.recorded == [2.0])
        #expect(flag.callCount == 1) // 重试期间不重复 finish（只有那一次 2xx 触发）
    }

    @Test("超时（传输层错误）：前两次超时、第三次 200 → 共 3 次调用，finish 恰好一次")
    func receiptsRetriesTransportTimeout() async throws {
        let dir = tempDirectory()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let purchases = makeRig(directory: dir, transport: transport, storeKit: provider,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-m4-timeout",
                                     originalTransactionIdentifier: "tx-m4-timeout",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.m4c.s", finishFlag: flag))
        }
        await transport.failTransport(forPath: receiptsPath, times: 2, error: URLError(.timedOut))
        await transport.enqueue(.json(subscriberJSON()), forPath: receiptsPath)

        _ = try await purchases.purchase(product: monthly())

        #expect(await transport.callCount(forPath: receiptsPath) == 3)
        #expect(flag.callCount == 1)
        // 成功后上下文清空（铁律 P3 终态）
        #expect(await PendingPurchaseStore(directory: dir).all().isEmpty)
    }

    @Test("断网（一直不通）：重试到上限后放弃，零 finish、上下文留存等重放")
    func receiptsGivesUpWhenOffline() async throws {
        let dir = tempDirectory()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let purchases = makeRig(directory: dir, transport: transport, storeKit: provider,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-m4-offline",
                                     originalTransactionIdentifier: "tx-m4-offline",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.m4d.s", finishFlag: flag))
        }
        await transport.failTransport(forPath: receiptsPath, times: .max,
                                      error: URLError(.notConnectedToInternet))

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(product: monthly())
        }

        #expect(await transport.callCount(forPath: receiptsPath) == Self.attemptsWithRetries)
        #expect(flag.callCount == 0)
        #expect(await PendingPurchaseStore(directory: dir).all().count == 1)
    }

    @Test("#8：确定性 4xx 不可重试 —— receipts 400 只调用一次，finish 恰好一次，上下文清空")
    func receiptsDoesNotRetryDeterministicRejection() async throws {
        let dir = tempDirectory()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let purchases = makeRig(directory: dir, transport: transport, storeKit: provider,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-m4-400",
                                     originalTransactionIdentifier: "tx-m4-400",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.m4e.s", finishFlag: flag))
        }
        await transport.enqueue(.failure(statusCode: 400), forPath: receiptsPath)

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(product: monthly())
        }

        #expect(await transport.callCount(forPath: receiptsPath) == 1) // 不可重试错误绝不重试
        #expect(flag.callCount == 1)                                    // 确定性拒绝 → finish 一次
        #expect(await PendingPurchaseStore(directory: dir).all().isEmpty)
    }

    @Test("#8 映射表：404 / 408 / 429 属于**暂时性**失败 —— 用尽重试后仍绝不 finish，上下文留待重放",
          arguments: [404, 408, 429])
    func retryableFourXXNeverFinishes(status: Int) async throws {
        let dir = tempDirectory()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let purchases = makeRig(directory: dir, transport: transport, storeKit: provider,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-m4-\(status)",
                                     originalTransactionIdentifier: "tx-m4-\(status)",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.m4-\(status).s", finishFlag: flag))
        }
        await transport.enqueue(.failure(statusCode: status), forPath: receiptsPath) // 粘住

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(product: monthly())
        }

        // 429 走退避重试到上限；404 / 408 状态码类默认规则不重试，一次就放弃 ——
        // 但**处置**都一样：retryable，不 finish、不删上下文。
        #expect(await transport.callCount(forPath: receiptsPath) == (status == 429 ? Self.attemptsWithRetries : 1))
        #expect(flag.callCount == 0)
        #expect(await PendingPurchaseStore(directory: dir).all().count == 1)
    }

    @Test("端点级不可重试：/v1/diagnostics/entitlement-diff 500 只发一次（每条上报是独立观测样本）")
    func entitlementDiffIsNotRetryable() async throws {
        let transport = MockTransport()
        let purchases = makeRig(directory: tempDirectory(), transport: transport, storeKit: nil,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        await transport.enqueue(.failure(statusCode: 500), forPath: entitlementDiffPath)

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.reportEntitlementDiff(rcActive: [:], rcRequestDate: nil)
        }
        #expect(await transport.callCount(forPath: entitlementDiffPath) == 1)
        // 端点策略本身也断言一次，避免有人把 isRetryable 改成 true 而测试仍靠巧合过。
        #expect(Endpoint.postEntitlementDiff.policy.isRetryable == false)
    }

    @Test("identify（logIn）可重试：两次 5xx 后成功 —— 共 3 次调用，身份确实切过去了")
    func identifyRetriesThenSucceeds() async throws {
        let transport = MockTransport()
        let purchases = makeRig(directory: tempDirectory(), transport: transport, storeKit: nil,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        await transport.enqueue(.failure(statusCode: 503), forPath: identifyPath)
        await transport.enqueue(.failure(statusCode: 503), forPath: identifyPath)
        await transport.enqueue(.json(subscriberJSON()), forPath: identifyPath)

        let result = try await purchases.logIn("user-m4")

        #expect(await transport.callCount(forPath: identifyPath) == 3)
        #expect(result.customerInfo.originalAppUserID == "tester")
        #expect(purchases.appUserID == "user-m4")
        #expect(Endpoint.postIdentify.policy.isRetryable) // LWW/四分支收敛 → 幂等可重试
    }

    @Test("#127 边界：属性同步一直 5xx → 每次触发都重试到上限，且属性保持未同步（下次时机再冲）")
    func attributesRetryAndStayUnsynced() async throws {
        let transport = MockTransport()
        let purchases = makeRig(directory: tempDirectory(), transport: transport, storeKit: nil,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        await transport.enqueue(.failure(statusCode: 500), forPath: attributesPath)

        purchases.setAttributes(["plan": "gold"])
        await purchases.syncAttributesIfNeeded()
        #expect(await transport.callCount(forPath: attributesPath) == 4) // 1 + 3 次重试

        // 仍未同步 —— 第二次触发又打满一轮，且待发队列还在
        await purchases.syncAttributesIfNeeded()
        #expect(await transport.callCount(forPath: attributesPath) == 8)
        let unsynced = await purchases.unsyncedAttributes()
        #expect(unsynced.contains { $0.key == "plan" })
    }

    @Test("restore 全程断网：重试到上限后抛错，绝不 finish")
    func restoreGivesUpOffline() async throws {
        let dir = tempDirectory()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let purchases = makeRig(directory: dir, transport: transport, storeKit: provider,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        // 先把启动扫描（此时 provider 里什么都没有）跑完，避免与 restore 的请求计数混在一起
        _ = try? await purchases.customerInfo(fetchPolicy: .cachedOnly)

        let flag = FinishFlag()
        let tx = FakeTransaction(transactionIdentifier: "tx-m4-restore",
                                 originalTransactionIdentifier: "tx-m4-restore",
                                 productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                 expirationDate: Date().addingTimeInterval(3600),
                                 jwsRepresentation: "h.m4f.s", finishFlag: flag)
        await provider.setCurrentEntitlements([tx])
        await transport.failTransport(forPath: receiptsPath, times: .max,
                                      error: URLError(.notConnectedToInternet))

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.restorePurchases()
        }
        #expect(await transport.callCount(forPath: receiptsPath) == Self.attemptsWithRetries)
        #expect(flag.callCount == 0)
    }
}
}

// MARK: - 2. 崩溃重放三切点

extension PurchasesSingletonDomain {
@MainActor
@Suite("M4 故障注入 · 崩溃重放三切点", .serialized)
struct M4CrashReplayTests {

    /// 把「进程死在某个切点」还原成**磁盘上的状态**：待重放上下文 + StoreKit 侧可见性 + 台账。
    /// 这比「让请求半路失败」更精确 —— 崩溃点不同，落盘状态就不同。
    private static func seedContext(directory: URL,
                                    key: String,
                                    productIdentifier: String,
                                    jws: String) async throws {
        let store = PendingPurchaseStore(directory: directory)
        try await store.save(PendingPurchaseContext(key: key,
                                                    productIdentifier: productIdentifier,
                                                    appUserID: "tester",
                                                    initiationSource: .purchase,
                                                    jws: jws,
                                                    completedBy: .revenueDog))
    }

    @Test("切点①（上报前崩溃）：重启后 JWS 补报 + unfinished 配对 → finish 恰好一次、上下文清空、台账落账")
    func crashBeforePost() async throws {
        let dir = tempDirectory()
        try await Self.seedContext(directory: dir, key: "tx-crash-1",
                                   productIdentifier: "com.demo.monthly", jws: "h.crash1.s")

        let flag = FinishFlag()
        let tx = FakeTransaction(transactionIdentifier: "tx-crash-1",
                                 originalTransactionIdentifier: "tx-crash-1",
                                 productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                 expirationDate: Date().addingTimeInterval(3600),
                                 jwsRepresentation: "h.crash1.s", finishFlag: flag)
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        await provider.setUnfinished([tx])                                 // 崩溃前没 finish → 重启后仍未完成
        await transport.enqueue(.json(subscriberJSON()), forPath: receiptsPath)

        _ = makeRig(directory: dir, transport: transport, storeKit: provider,
                    identityStorage: InMemoryIdentityStorage(), cacheStorage: InMemoryCacheStorage())
        await Purchases.awaitConfigured()

        #expect(flag.callCount == 1) // 无漏 finish，也没有重复 finish
        // 两次 POST：JWS 补报（无交易对象 → 不能 finish）+ unfinished 配对后的那次（带交易对象 → finish）。
        // 服务端按 fetch_token 幂等收敛（契约 §1.6），端上不做第三次。
        #expect(await transport.callCount(forPath: receiptsPath) == 2)
        #expect(await PendingPurchaseStore(directory: dir).all().isEmpty)
    }

    @Test("切点②（上报成功、finish 前崩溃，消耗型）：重启后按响应确认 finish 一次，不重复上报")
    func crashAfterPostBeforeFinish() async throws {
        let dir = tempDirectory()
        try await Self.seedContext(directory: dir, key: "tx-crash-2",
                                   productIdentifier: "com.demo.coins", jws: "h.crash2.s")

        let flag = FinishFlag()
        let tx = FakeTransaction(transactionIdentifier: "tx-crash-2",
                                 originalTransactionIdentifier: "tx-crash-2",
                                 productIdentifier: "com.demo.coins", purchaseDate: Date(),
                                 expirationDate: nil,                       // 消耗型
                                 jwsRepresentation: "h.crash2.s", finishFlag: flag)
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.coins")])
        await provider.setUnfinished([tx])
        // 后端**已经**收下这笔（切点②的定义）：响应的 non_subscriptions 里能看到它
        await transport.enqueue(.json(subscriberJSON(nonSubscriptionTxIDs: ["tx-crash-2"])),
                                forPath: receiptsPath)

        _ = makeRig(directory: dir, transport: transport, storeKit: provider,
                    identityStorage: InMemoryIdentityStorage(), cacheStorage: InMemoryCacheStorage())
        await Purchases.awaitConfigured()

        #expect(flag.callCount == 1)  // 消耗型：响应确认后才 finish，且只 finish 一次
        #expect(await transport.callCount(forPath: receiptsPath) == 2)
        #expect(await PendingPurchaseStore(directory: dir).all().isEmpty)
    }

    @Test("切点③（finish 后、台账/上下文清理前崩溃）：重启后不再漏 finish，上下文清空、台账补上")
    func crashAfterFinishBeforeLedger() async throws {
        let dir = tempDirectory()
        try await Self.seedContext(directory: dir, key: "tx-crash-3",
                                   productIdentifier: "com.demo.monthly", jws: "h.crash3.s")

        let flag = FinishFlag()
        flag.markFinished()   // 崩溃前已经 finish 过了
        let tx = FakeTransaction(transactionIdentifier: "tx-crash-3",
                                 originalTransactionIdentifier: "tx-crash-3",
                                 productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                 expirationDate: Date().addingTimeInterval(3600),
                                 jwsRepresentation: "h.crash3.s", finishFlag: flag)
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        // 已 finish → 不在 unfinished 里，但仍在 currentEntitlements 里（裁决 #2 后半）
        await provider.setUnfinished([])
        await provider.setCurrentEntitlements([tx])
        await transport.enqueue(.json(subscriberJSON()), forPath: receiptsPath)

        let ledgerURL = dir.appendingPathComponent("_ledger", isDirectory: true)
            .appendingPathComponent("synced-transactions.json", isDirectory: false)
        _ = makeRig(directory: dir, transport: transport, storeKit: provider,
                    identityStorage: InMemoryIdentityStorage(), cacheStorage: InMemoryCacheStorage())
        await Purchases.awaitConfigured()

        #expect(flag.value)  // finish 状态没丢
        // 上下文最终由 currentEntitlements 扫描收尾清掉，台账补上去重标记
        #expect(await PendingPurchaseStore(directory: dir).all().isEmpty)
        #expect(await SyncedTransactionLedger(fileURL: ledgerURL).contains("tx-crash-3"))
        // 上报次数有限（JWS 补报 + currentEntitlements 配对），不会因为「finish 义务清不掉」而无限打
        #expect(await transport.callCount(forPath: receiptsPath) == 2)
    }

    @Test("崩溃重放不双重上报：同一笔交易第二次冷启动时台账已去重，零新增 POST")
    func replayIsIdempotentAcrossRestarts() async throws {
        let dir = tempDirectory()
        try await Self.seedContext(directory: dir, key: "tx-crash-4",
                                   productIdentifier: "com.demo.monthly", jws: "h.crash4.s")

        let flag = FinishFlag()
        let tx = FakeTransaction(transactionIdentifier: "tx-crash-4",
                                 originalTransactionIdentifier: "tx-crash-4",
                                 productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                 expirationDate: Date().addingTimeInterval(3600),
                                 jwsRepresentation: "h.crash4.s", finishFlag: flag)

        // 第一次冷启动：补报 + finish + 台账落账 + 上下文清空
        let transport1 = MockTransport()
        let provider1 = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        await provider1.setUnfinished([tx])
        await transport1.enqueue(.json(subscriberJSON()), forPath: receiptsPath)
        _ = makeRig(directory: dir, transport: transport1, storeKit: provider1,
                    identityStorage: InMemoryIdentityStorage(), cacheStorage: InMemoryCacheStorage())
        await Purchases.awaitConfigured()
        #expect(flag.callCount == 1)

        // 第二次冷启动：交易已 finish（不在 unfinished），但仍在 currentEntitlements 里 ——
        // 台账（裁决 #2 / #10）必须挡住，否则每次启动都白报一次。
        let transport2 = MockTransport()
        let provider2 = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        await provider2.setUnfinished([])
        await provider2.setCurrentEntitlements([tx])
        await transport2.enqueue(.json(subscriberJSON()), forPath: receiptsPath)
        _ = makeRig(directory: dir, transport: transport2, storeKit: provider2,
                    identityStorage: InMemoryIdentityStorage(), cacheStorage: InMemoryCacheStorage())
        await Purchases.awaitConfigured()

        #expect(await transport2.callCount(forPath: receiptsPath) == 0)
    }
}
}

// MARK: - 3. 冷启动后端不可达

extension PurchasesSingletonDomain {
@MainActor
@Suite("M4 故障注入 · 冷启动离线", .serialized)
struct M4OfflineColdStartTests {

    /// 把已落盘的 CustomerInfo 缓存条目「做旧」到 TTL 之外（前台 5min）。
    ///
    /// 这里刻意**不用** `invalidateCustomerInfoCache()`：本组要验的是 TTL 这一根轴
    /// （「缓存到点了、拉网又失败」），失效代是另一根轴（见「缓存失效代」suite）。
    /// 必须在**创建离线实例之前**做旧：DeviceCache 有内存层，实例起来后再改磁盘不生效。
    static func ageCachedCustomerInfo(_ storage: any CacheStorage,
                                      appUserID: String,
                                      by seconds: TimeInterval = 3600) async {
        let key = CacheKey.customerInfo(appUserID: appUserID)
        guard let entry: DeviceCache.Entry<CustomerInfo> = await storage.read(forKey: key) else { return }
        await storage.write(DeviceCache.Entry(value: entry.value,
                                              cachedAt: Date(timeIntervalSinceNow: -seconds)),
                            forKey: key)
    }

    /// 第一程联网写好缓存（并把缓存做旧成 stale），第二程整机断网 —— 返回 (离线实例, 离线 transport)。
    /// 身份与缓存后端跨实例复用 = 真实的「同一台设备重启」。
    private static func coldStartOffline(seedJSON: String) async -> (Purchases, MockTransport) {
        let identity = InMemoryIdentityStorage()
        let cache = InMemoryCacheStorage()

        let onlineTransport = MockTransport(stubs: [.json(seedJSON)])
        let online = makeRig(directory: tempDirectory(), transport: onlineTransport, storeKit: nil,
                             identityStorage: identity, cacheStorage: cache)
        _ = try? await online.customerInfo()   // 写缓存
        await ageCachedCustomerInfo(cache, appUserID: online.appUserID)

        let offlineTransport = MockTransport()
        await offlineTransport.failTransportAlways()
        let offline = makeRig(directory: tempDirectory(), transport: offlineTransport, storeKit: nil,
                              identityStorage: identity, cacheStorage: cache)
        await Purchases.awaitConfigured()
        return (offline, offlineTransport)
    }

    @Test("离线 + .cachedOnly：即便缓存已 stale 也直接给，一个网络请求都不发")
    func cachedOnlyServesCacheOffline() async throws {
        let (purchases, transport) = await Self.coldStartOffline(seedJSON: subscriberJSON())
        let info = try await purchases.customerInfo(fetchPolicy: .cachedOnly)
        #expect(info.originalAppUserID == "tester")
        #expect(await transport.callCount == 0)
    }

    @Test("离线 + 无缓存 + .cachedOnly：报 customerInfoError，而不是挂住或返回空对象")
    func cachedOnlyWithoutCacheThrows() async throws {
        let transport = MockTransport()
        await transport.failTransportAlways()
        let purchases = makeRig(directory: tempDirectory(), transport: transport, storeKit: nil,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        do {
            _ = try await purchases.customerInfo(fetchPolicy: .cachedOnly)
            Issue.record("离线且无缓存时应当抛错")
        } catch let error as PurchasesError {
            #expect(error.code == .customerInfoError)
        }
        #expect(await transport.callCount == 0)
    }

    @Test("离线 + 缓存已 stale + .cachedOrFetched / .notStaleCachedOrFetched：回落 stale 缓存（设计 §4）")
    func staleFallbackWhenOffline() async throws {
        let (purchases, transport) = await Self.coldStartOffline(seedJSON: subscriberJSON())

        let a = try await purchases.customerInfo(fetchPolicy: .cachedOrFetched)
        #expect(a.originalAppUserID == "tester")
        let b = try await purchases.customerInfo(fetchPolicy: .notStaleCachedOrFetched)
        #expect(b.originalAppUserID == "tester")
        // 两次都真的去拉过网（各自打满 1+3 次重试）才回落 —— 不是「缓存没过期直接返回」的假通过
        #expect(await transport.callCount == 8)
    }

    @Test("离线 + .fetchCurrent：明确要求现值 → 抛 networkError，绝不拿 stale 顶包")
    func fetchCurrentRefusesStale() async throws {
        let (purchases, _) = await Self.coldStartOffline(seedJSON: subscriberJSON())
        do {
            _ = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)
            Issue.record(".fetchCurrent 在离线时应当抛错")
        } catch let error as PurchasesError {
            #expect(error.code == .networkError)
        }
    }

    @Test("#58：stale 回落路径不回写缓存（离线结果绝不覆盖磁盘上的权威快照）")
    func staleFallbackDoesNotRewriteCache() async throws {
        let identity = InMemoryIdentityStorage()
        let cache = CountingCacheStorage()

        // 第一程联网：写入权威快照
        let online = makeRig(directory: tempDirectory(),
                             transport: MockTransport(stubs: [.json(subscriberJSON())]),
                             storeKit: nil, identityStorage: identity, cacheStorage: cache)
        _ = try await online.customerInfo()
        await Self.ageCachedCustomerInfo(cache, appUserID: online.appUserID)
        let baseline = await cache.writeCount
        #expect(baseline >= 1)

        // 第二程断网：走 stale 回落
        let offlineTransport = MockTransport()
        await offlineTransport.failTransportAlways()
        let offline = makeRig(directory: tempDirectory(), transport: offlineTransport, storeKit: nil,
                              identityStorage: identity, cacheStorage: cache)
        await Purchases.awaitConfigured()
        _ = try await offline.customerInfo(fetchPolicy: .cachedOrFetched)

        #expect(await cache.writeCount == baseline) // 一次都没再写
    }

    @Test("#56：离线拿到的 stale 缓存仍按 3 天 grace 判权益 —— 服务端时间在 grace 内则权益有效")
    func graceAppliesToOfflineCachedInfo() async throws {
        let (purchases, _) = await Self.coldStartOffline(seedJSON: freshSubscriberJSONWithEntitlement())
        let info = try await purchases.customerInfo(fetchPolicy: .cachedOnly)
        #expect(info.entitlements.active.keys.contains("pro"))
        // 同步读视图（设计 §1「离线可用」）在冷启动后也已就位
        #expect(purchases.cachedCustomerInfo?.entitlements.active.keys.contains("pro") == true)
    }
}
}

// MARK: - 4. Ask-to-Buy / SCA 的 `.pending` 残余边界

extension PurchasesSingletonDomain {
@MainActor
@Suite("M4 故障注入 · Ask-to-Buy pending 闭环", .serialized)
struct M4PendingPurchaseTests {

    private static func waitFor(timeoutMs: Int = 2000, _ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<(timeoutMs / 20) {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// 门禁报告 §2 / `PurchasesOrchestrator` 注释里标注的残余边界：
    /// `.pending` 时没有交易对象可以 rekey，上下文只能留在**发起键**上，
    /// 等 Ask-to-Buy 审批通过后交易从 `Transaction.updates` 流出，再靠
    /// `matchInitiation`（同商品 + `createdAt <= purchaseDate`）配对（坑 #15/#16）。
    ///
    /// 本例把这条路径闭环：pending → 发起键保留 → updates 到达 → 归因不丢、只上报一次。
    /// **仍然残余**（fake 层无法消除、需要真机/StoreKitTest）：同一商品**同时**挂着两笔
    /// pending 时，`matchInitiation` 取最早一笔仍可能张冠李戴 —— 端上没有任何信息能区分。
    @Test("`.pending` → 后续 updates 到达 → 按发起键配对，归因与 initiation_source 不丢，只上报一次")
    func pendingThenUpdatesPairsWithInitiationContext() async throws {
        let dir = tempDirectory()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        await transport.enqueue(.json(subscriberJSON()))                       // GET 兜底（粘住）
        await transport.enqueue(.json(subscriberJSON()), forPath: receiptsPath)
        let purchases = makeRig(directory: dir, transport: transport, storeKit: provider,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        _ = try await purchases.customerInfo()

        await provider.scriptPurchase { _ in .pending }
        let package = Package(identifier: "$rc_monthly",
                              packageType: .monthly,
                              offeringIdentifier: "offer-atb",
                              platformProductIdentifier: "com.demo.monthly",
                              storeProduct: nil)
        let result = try await purchases.purchase(package: package)

        #expect(result.transactionIdentifier == nil)
        #expect(!result.userCancelled)
        // 发起键上下文必须**保留**（唯一的归因载体），且此刻还没有 JWS
        let staged = await PendingPurchaseStore(directory: dir).all()
        #expect(staged.count == 1)
        #expect(staged.first?.key.hasPrefix("pending:com.demo.monthly#") == true)
        #expect(staged.first?.jws == nil)
        #expect(staged.first?.presentedOfferingIdentifier == "offer-atb")
        #expect(await transport.callCount(forPath: receiptsPath) == 0) // pending 阶段不上报

        // 家长批准 → 交易从 updates 流出
        let flag = FinishFlag()
        await provider.emit(FakeTransaction(transactionIdentifier: "tx-atb",
                                            originalTransactionIdentifier: "tx-atb",
                                            productIdentifier: "com.demo.monthly",
                                            purchaseDate: Date(),
                                            expirationDate: Date().addingTimeInterval(3600),
                                            jwsRepresentation: "h.atb.s",
                                            finishFlag: flag))

        let posted = await Self.waitFor { await transport.callCount(forPath: receiptsPath) == 1 }
        #expect(posted)

        let body = try JSONSerialization.jsonObject(
            with: #require(await transport.requests(forPath: receiptsPath).first?.httpBody)) as! [String: Any]
        #expect(body["fetch_token"] as? String == "h.atb.s")
        // 归因没丢：配对上了发起键上下文，而不是退化成「无上下文的补投」
        #expect(body["presented_offering_identifier"] as? String == "offer-atb")
        #expect(body["initiation_source"] as? String == "purchase")

        #expect(flag.callCount == 1)
        #expect(await PendingPurchaseStore(directory: dir).all().isEmpty) // 配对后按 txID 键收尾
        #expect(await transport.callCount(forPath: receiptsPath) == 1)    // 不重复配对、不重复上报
    }
}
}

// MARK: - 5. `invalidateCustomerInfoCache()` 同步生效（失效代）

extension PurchasesSingletonDomain {
@MainActor
@Suite("M4 收尾 · 缓存失效代", .serialized)
struct M4CacheInvalidationTests {

    /// 旧实现把失效动作丢进 fire-and-forget `Task`，「invalidate 完立刻读」会与它赛跑。
    /// 现在失效代在 `invalidateCustomerInfoCache()` 返回前就 +1 —— 本例**不含任何 sleep/轮询**，
    /// 紧接着的一行就断言必然发了网络请求。
    @Test("invalidate 后**立即**调 customerInfo() 必然走网络（无 sleep、无轮询）")
    func invalidateTakesEffectSynchronously() async throws {
        let transport = MockTransport(stubs: [.json(subscriberJSON())])
        let purchases = makeRig(directory: tempDirectory(), transport: transport, storeKit: nil,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())

        _ = try await purchases.customerInfo()
        let afterFirstFetch = await transport.callCount
        #expect(afterFirstFetch == 1)

        // 缓存新鲜 → 第二次不发请求
        _ = try await purchases.customerInfo()
        #expect(await transport.callCount == afterFirstFetch)

        purchases.invalidateCustomerInfoCache()   // 同步生效
        _ = try await purchases.customerInfo()
        #expect(await transport.callCount == afterFirstFetch + 1)

        // 拉回来的新值又追平了失效代 → 再读一次回到命中缓存
        _ = try await purchases.customerInfo()
        #expect(await transport.callCount == afterFirstFetch + 1)
    }

    @Test("invalidate 对 .notStaleCachedOrFetched 同样生效；对 .cachedOnly 不生效（只强制下一次 fetch，不是删缓存）")
    func invalidateSemanticsPerFetchPolicy() async throws {
        let transport = MockTransport(stubs: [.json(subscriberJSON())])
        let purchases = makeRig(directory: tempDirectory(), transport: transport, storeKit: nil,
                                identityStorage: InMemoryIdentityStorage(),
                                cacheStorage: InMemoryCacheStorage())
        _ = try await purchases.customerInfo()
        let baseline = await transport.callCount

        purchases.invalidateCustomerInfoCache()
        // .cachedOnly：仍然返回旧值，且一个请求都不发
        let cached = try await purchases.customerInfo(fetchPolicy: .cachedOnly)
        #expect(cached.originalAppUserID == "tester")
        #expect(await transport.callCount == baseline)

        // .notStaleCachedOrFetched：走网络
        _ = try await purchases.customerInfo(fetchPolicy: .notStaleCachedOrFetched)
        #expect(await transport.callCount == baseline + 1)
    }
}
}
