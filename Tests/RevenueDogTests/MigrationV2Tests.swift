//
//  MigrationV2Tests.swift
//  迁移方案 v2.1 §5 前置工程的 SDK 侧：M-2a（`purchasesCompletedBy` 运行时可写）、
//  M-2b（观察者模式前台激活重扫）、M-4（购买结果钩子）、M-3（权益 diff 上报客户端半边）。
//

import Foundation
import Testing
@testable import RevenueDog

#if canImport(StoreKit)
import StoreKit
#endif

// MARK: - 测试替身

/// 有序事件记录（M-4 时序断言：钩子必须早于 finish）。
final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var value: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

/// `finish()` 会写进有序日志的交易替身。
private struct OrderLoggingTransaction: StoreTransactionType {
    let transactionIdentifier: String
    var originalTransactionIdentifier: String { transactionIdentifier }
    let productIdentifier: String
    let purchaseDate: Date
    let expirationDate: Date?
    var quantity: Int = 1
    var revocationDate: Date? = nil
    var isUpgraded: Bool = false
    var appAccountToken: UUID? = nil
    let jwsRepresentation: String?
    let log: OrderLog

    var isFinished: Bool { get async { log.value.contains("finish") } }
    func finish() async { log.append("finish") }
}

// MARK: - Fixtures

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func migrationSubscriberJSON(userID: String = "tester") -> String {
    """
    {"request_date":"2026-08-27T00:00:00Z","request_date_ms":1782518400000,
     "subscriber":{"original_app_user_id":"\(userID)","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
    """
}

/// 带一条有效权益（`pro`）+ 一条终身权益（`lifetime`，`expires_date = null`）的响应。
private func subscriberWithEntitlementsJSON(requestDate: Date, proExpires: Date) -> String {
    """
    {"request_date":"\(iso8601String(requestDate))",
     "request_date_ms":\(Int64((requestDate.timeIntervalSince1970 * 1000).rounded())),
     "subscriber":{"original_app_user_id":"tester","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,
       "entitlements":{
         "pro":{"expires_date":"\(iso8601String(proExpires))","grace_period_expires_date":null,
                "product_identifier":"com.demo.monthly","purchase_date":"2026-08-01T00:00:00Z"},
         "lifetime":{"expires_date":null,"grace_period_expires_date":null,
                "product_identifier":"com.demo.forever","purchase_date":"2026-08-01T00:00:00Z"}},
       "subscriptions":{},"non_subscriptions":{}}}
    """
}

// MARK: - 组装

@MainActor
private func makeMigrationPurchases(
    completedBy: PurchasesCompletedBy = .revenueDog,
    transport: MockTransport = MockTransport(stubs: [.json(migrationSubscriberJSON())]),
) -> (Purchases, MockTransport, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(purchasesCompletedBy: completedBy)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("RevenueDogMigrationV2/\(UUID().uuidString)", isDirectory: true),
            storeKit: provider,
            delayScheduler: NoDelayScheduler(),
            diagnostics: .isolated(),
        ),
    )
    return (purchases, transport, provider)
}

private func migrationWaitUntil(timeoutMs: Int = 2000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

private func receiptBodies(_ transport: MockTransport) async -> [[String: Any]] {
    await transport.capturedRequests
        .filter { $0.url?.path == "/v1/receipts" }
        .compactMap { $0.httpBody }
        .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

// 单例串行域（见 Support/SingletonSerialDomain.swift）：本 suite 碰 Purchases 静态单例，
// 必须与其它同类 suite 串行，不能靠 suite 内 `.serialized`。
extension PurchasesSingletonDomain {
@MainActor
@Suite("迁移 v2 前置（M-2 / M-3 / M-4）", .serialized)
struct MigrationV2Tests {

    // MARK: - M-2a：purchasesCompletedBy 运行时可写

    @Test("M-2a：热切立即对新观察到的交易生效 —— .myApp 不 finish，切到 .revenueDog 后 finish")
    func hotSwitchAppliesToNewTransactions() async throws {
        let (purchases, transport, provider) = makeMigrationPurchases(completedBy: .myApp)
        _ = try await purchases.customerInfo() // 触发 start()（挂 updates 消费者）

        #expect(purchases.purchasesCompletedBy == .myApp)
        // .myApp 下 SDK 拒绝发起购买（铁律 P2 / 设计 §3）
        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(
                product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                      localizedDescription: "", price: 9.99, currencyCode: "USD",
                                      localizedPriceString: "$9.99"))
        }

        let observedLog = OrderLog()
        let observed = OrderLoggingTransaction(transactionIdentifier: "tx-obs-1",
                                               productIdentifier: "com.demo.monthly",
                                               purchaseDate: Date(),
                                               expirationDate: Date().addingTimeInterval(3600),
                                               jwsRepresentation: "h.obs1.s",
                                               log: observedLog)
        await provider.emit(observed)
        #expect(await migrationWaitUntil { await receiptBodies(transport).count == 1 })
        #expect(observedLog.value.isEmpty)                       // .myApp：绝不 finish
        #expect(await receiptBodies(transport)[0]["observer_mode"] as? Bool == true)

        // —— 热切 ——
        purchases.purchasesCompletedBy = .revenueDog
        #expect(purchases.purchasesCompletedBy == .revenueDog)

        let switchedLog = OrderLog()
        let switched = OrderLoggingTransaction(transactionIdentifier: "tx-obs-2",
                                               productIdentifier: "com.demo.monthly",
                                               purchaseDate: Date(),
                                               expirationDate: Date().addingTimeInterval(3600),
                                               jwsRepresentation: "h.obs2.s",
                                               log: switchedLog)
        await provider.emit(switched)
        #expect(await migrationWaitUntil { await receiptBodies(transport).count == 2 })
        #expect(await migrationWaitUntil { switchedLog.value == ["finish"] }) // 新模式立即生效
        #expect(await receiptBodies(transport)[1]["observer_mode"] as? Bool == false)

        // 购买入口也随之解禁（同一开关，动态读）
        await provider.scriptPurchase { _ in .userCancelled }
        let result = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                  localizedDescription: "", price: 9.99, currencyCode: "USD",
                                  localizedPriceString: "$9.99"))
        #expect(result.userCancelled)
    }

    @Test("M-2a：在途购买沿用**发起时**的模式 —— 购买中途切到 .myApp 仍然 finish")
    func inFlightPurchaseKeepsInitiationTimeMode() async throws {
        let (purchases, transport, provider) = makeMigrationPurchases(completedBy: .revenueDog)
        _ = try await purchases.customerInfo()

        let log = OrderLog()
        // 购买脚本挂起期间（= 商店弹窗还开着）把开关翻到 .myApp，模拟宿主在最坏时刻翻开关。
        await provider.scriptPurchaseAsync { productID in
            purchases.purchasesCompletedBy = .myApp
            return .success(OrderLoggingTransaction(transactionIdentifier: "tx-inflight",
                                                    productIdentifier: productID,
                                                    purchaseDate: Date(),
                                                    expirationDate: Date().addingTimeInterval(3600),
                                                    jwsRepresentation: "h.inflight.s",
                                                    log: log))
        }

        let result = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                  localizedDescription: "", price: 9.99, currencyCode: "USD",
                                  localizedPriceString: "$9.99"))

        #expect(result.transactionIdentifier == "tx-inflight")
        #expect(purchases.purchasesCompletedBy == .myApp)          // 开关确实已经翻了
        #expect(log.value == ["finish"])                           // 但这笔沿用发起时的 .revenueDog
        let bodies = await receiptBodies(transport)
        #expect(bodies.count == 1)
        #expect(bodies[0]["observer_mode"] as? Bool == false)      // 上行标记也用发起时的模式

        // 切换之后**新**观察到的交易才走新模式
        let afterLog = OrderLog()
        await provider.emit(OrderLoggingTransaction(transactionIdentifier: "tx-after-switch",
                                                    productIdentifier: "com.demo.monthly",
                                                    purchaseDate: Date(),
                                                    expirationDate: Date().addingTimeInterval(3600),
                                                    jwsRepresentation: "h.after.s",
                                                    log: afterLog))
        #expect(await migrationWaitUntil { await receiptBodies(transport).count == 2 })
        #expect(afterLog.value.isEmpty)
        #expect(await receiptBodies(transport)[1]["observer_mode"] as? Bool == true)
    }

    // MARK: - M-2b：观察者模式前台激活重扫

    @Test("M-2b：.myApp 下前台激活重扫 currentEntitlements 并上报；已上报过的不重发")
    func foregroundRescanInObserverMode() async throws {
        let (purchases, transport, provider) = makeMigrationPurchases(completedBy: .myApp)
        _ = try await purchases.customerInfo() // 等启动扫描跑完（此时商店里还没有交易）
        #expect(await receiptBodies(transport).isEmpty)

        // 模拟「RC 在 App 运行期间自己买了一笔」：Apple 不保证这笔进 Dog 的 `updates`
        // （verify/storekit2-multi-listener.md §1 结论 3），所以只能靠快照序列扫出来。
        let log = OrderLog()
        await provider.setCurrentEntitlements([
            OrderLoggingTransaction(transactionIdentifier: "tx-rc-bought",
                                    productIdentifier: "com.demo.monthly",
                                    purchaseDate: Date(),
                                    expirationDate: Date().addingTimeInterval(3600),
                                    jwsRepresentation: "h.rcbought.s",
                                    log: log),
        ])

        purchases.applicationDidBecomeActive()
        #expect(await migrationWaitUntil { await receiptBodies(transport).count == 1 })
        #expect(log.value.isEmpty) // 观察者绝不 finish（铁律 P2 / 坑 #9）

        // 第二次前台激活：台账去重（坑 #10 / 裁决 #2），不重发
        purchases.applicationDidBecomeActive()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await receiptBodies(transport).count == 1)
    }

    @Test("M-2b：.revenueDog 下前台激活不触发重扫（Dog 自己 finish，updates + 启动扫描已覆盖）")
    func foregroundRescanSkippedWhenAuthoritative() async throws {
        let (purchases, transport, provider) = makeMigrationPurchases(completedBy: .revenueDog)
        _ = try await purchases.customerInfo()

        await provider.setCurrentEntitlements([
            OrderLoggingTransaction(transactionIdentifier: "tx-owned",
                                    productIdentifier: "com.demo.monthly",
                                    purchaseDate: Date(),
                                    expirationDate: Date().addingTimeInterval(3600),
                                    jwsRepresentation: "h.owned.s",
                                    log: OrderLog()),
        ])

        purchases.applicationDidBecomeActive()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await receiptBodies(transport).isEmpty)
    }

    // MARK: - M-4：购买结果钩子

    #if canImport(StoreKit)

    @Test("M-4：钩子在 Dog 调 finish **之前**回调（可挂起脚本锁定时序）")
    func purchaseResultHookFiresBeforeFinish() async throws {
        let (purchases, transport, provider) = makeMigrationPurchases()
        _ = try await purchases.customerInfo()

        let log = OrderLog()
        purchases.purchaseResultHandler = { _ in log.append("hook") }
        // 载荷用 `.pending` 顶替：`.success(_:)` 需要 `VerificationResult<Transaction>`，
        // 单测里造不出来。载荷取值与时序断言正交 —— 钩子在 SK2Provider 里是在 `switch` **之前**
        // 对三种 case 一视同仁地派发的（StoreKitAbstraction.swift）。
        await provider.scriptRawPurchaseResult(Product.PurchaseResult.pending)
        await provider.scriptPurchaseAsync { productID in
            .success(OrderLoggingTransaction(transactionIdentifier: "tx-hook",
                                             productIdentifier: productID,
                                             purchaseDate: Date(),
                                             expirationDate: Date().addingTimeInterval(3600),
                                             jwsRepresentation: "h.hook.s",
                                             log: log))
        }

        _ = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                  localizedDescription: "", price: 9.99, currencyCode: "USD",
                                  localizedPriceString: "$9.99"))

        // 顺序上锁：RC 的 `recordPurchase` 必须在 Dog finish 之前拿到结果
        // （verify/rc-sdk-observer-mode.md §8.1 判断 5）。
        #expect(log.value == ["hook", "finish"])
        // 而且钩子早于上报：上报是 finish 的前置条件，所以 hook 也早于 POST /v1/receipts
        #expect(await receiptBodies(transport).count == 1)
    }

    @Test("M-4：userCancelled 也回调（且不产生上报、不 finish）")
    func purchaseResultHookFiresOnUserCancelled() async throws {
        let (purchases, transport, provider) = makeMigrationPurchases()
        _ = try await purchases.customerInfo()

        let log = OrderLog()
        purchases.purchaseResultHandler = { result in
            switch result {
            case .userCancelled: log.append("cancelled")
            case .pending: log.append("pending")
            case .success: log.append("success")
            @unknown default: log.append("unknown")
            }
        }
        await provider.scriptRawPurchaseResult(Product.PurchaseResult.userCancelled)
        await provider.scriptPurchase { _ in .userCancelled }

        let result = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                  localizedDescription: "", price: 9.99, currencyCode: "USD",
                                  localizedPriceString: "$9.99"))

        #expect(result.userCancelled)
        #expect(log.value == ["cancelled"])
        #expect(await receiptBodies(transport).isEmpty)
    }

    @Test("M-4：pending（Ask-to-Buy / SCA）也回调；摘掉钩子后不再回调")
    func purchaseResultHookFiresOnPendingAndCanBeDetached() async throws {
        let (purchases, _, provider) = makeMigrationPurchases()
        _ = try await purchases.customerInfo()

        let log = OrderLog()
        purchases.purchaseResultHandler = { result in
            if case .pending = result { log.append("pending") }
        }
        await provider.scriptRawPurchaseResult(Product.PurchaseResult.pending)
        await provider.scriptPurchase { _ in .pending }

        _ = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                  localizedDescription: "", price: 9.99, currencyCode: "USD",
                                  localizedPriceString: "$9.99"))
        #expect(log.value == ["pending"])

        // 档 2 回滚到档 1 时钩子要能立刻摘掉（这正是它不放进 Configuration 的理由）。
        purchases.purchaseResultHandler = nil
        _ = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                  localizedDescription: "", price: 9.99, currencyCode: "USD",
                                  localizedPriceString: "$9.99"))
        #expect(log.value == ["pending"])
    }

    #endif

    // MARK: - M-3：权益 diff 上报（客户端半边）

    @Test("M-3：POST /v1/diagnostics/entitlement-diff 请求形状 + 201 响应解析")
    func entitlementDiffRequestShapeAndResponse() async throws {
        let transport = MockTransport()
        let (purchases, _, _) = makeMigrationPurchases(transport: transport)

        let requestDate = Date(timeIntervalSince1970: 1_787_961_600)      // 固定，方便断言毫秒
        let proExpires = Date(timeIntervalSince1970: 1_790_553_600)
        // MockTransport 只剩一条 stub 时是「粘性」复用，所以两条必须在第一次请求之前排好。
        await transport.enqueue(.json(subscriberWithEntitlementsJSON(requestDate: requestDate,
                                                                    proExpires: proExpires)))
        await transport.enqueue(.json("""
        {"match":false,"diff":{"only_rc":["legacy"],"only_dog":["lifetime"],"expires_mismatch":["pro"]},
         "capped":false}
        """, statusCode: 201))

        _ = try await purchases.customerInfo()                            // 写入 Dog 侧本地缓存

        let rcRequestDate = Date(timeIntervalSince1970: 1_787_961_540)
        let result = try await purchases.reportEntitlementDiff(
            rcActive: ["pro": proExpires.addingTimeInterval(60), "legacy": nil],
            rcRequestDate: rcRequestDate,
            rcSDKVersion: "5.87.1")

        // —— 响应：匹配由服务端算，SDK 原样透出 ——
        #expect(result.match == false)
        #expect(result.diff.onlyRC == ["legacy"])
        #expect(result.diff.onlyDog == ["lifetime"])
        #expect(result.diff.expiresMismatch == ["pro"])
        #expect(result.capped == false)

        // —— 请求：形状按迁移方案 v2.1 §5 M-3 定死 ——
        let request = try #require(await transport.capturedRequests.last)
        #expect(request.url?.path == "/v1/diagnostics/entitlement-diff")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pk_test_0123456789")

        let httpBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["app_user_id"] as? String == purchases.appUserID)
        let observedAtMs = try #require(body["observed_at_ms"] as? Int64)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        #expect(abs(nowMs - observedAtMs) < 60_000) // 观测时刻 = 调用时刻，不是响应里的 request_date

        let rc = try #require(body["rc"] as? [String: Any])
        let rcActive = try #require(rc["active"] as? [String: Any])
        #expect(rcActive["pro"] as? Int64 == Int64((proExpires.timeIntervalSince1970 + 60) * 1000))
        #expect(rcActive["legacy"] is NSNull)                              // 终身权益 → 显式 null
        #expect(rc["request_date_ms"] as? Int64 == Int64(rcRequestDate.timeIntervalSince1970 * 1000))
        #expect(rc["sdk_version"] as? String == "5.87.1")

        let dog = try #require(body["dog"] as? [String: Any])
        let dogActive = try #require(dog["active"] as? [String: Any])
        #expect(dogActive["pro"] as? Int64 == Int64(proExpires.timeIntervalSince1970 * 1000))
        #expect(dogActive["lifetime"] is NSNull)
        #expect(dog["request_date_ms"] as? Int64 == Int64(requestDate.timeIntervalSince1970 * 1000))
        #expect(dog.keys.contains("sdk_version") == false)                 // sdk_version 只属于 rc 侧

        let context = try #require(body["context"] as? [String: Any])
        #expect(context.keys.contains("app_version"))
        #expect(context.keys.contains("os_version"))
    }

    @Test("M-3：Dog 侧取本地缓存不发网；完全无缓存时才先拉一次 CustomerInfo")
    func entitlementDiffUsesCacheAndFetchesOnlyWhenEmpty() async throws {
        // ① 无缓存：先 GET /v1/subscribers，再 POST diff
        let transport = MockTransport()
        let (purchases, _, _) = makeMigrationPurchases(transport: transport)
        // MockTransport 只剩一条 stub 时是「粘性」复用，所以三条一次排好。
        await transport.enqueue(.json(migrationSubscriberJSON()))
        await transport.enqueue(.json(#"{"match":true,"diff":{"only_rc":[],"only_dog":[],"expires_mismatch":[]},"capped":false}"#,
                                      statusCode: 201))
        await transport.enqueue(.json(#"{"match":true,"diff":{"only_rc":[],"only_dog":[],"expires_mismatch":[]},"capped":true}"#,
                                      statusCode: 201))

        _ = try await purchases.reportEntitlementDiff(rcActive: [:], rcRequestDate: nil)
        // URL.path 会把百分号编码解回去，所以这里比未编码的 appUserID。
        let paths = await transport.capturedRequests.compactMap { $0.url?.path }
        #expect(paths == ["/v1/subscribers/\(purchases.appUserID)",
                          "/v1/diagnostics/entitlement-diff"])

        // ② 已有缓存：只发 diff 这一条，绝不为了对账去刷新自己（会让一致率虚高）
        let second = try await purchases.reportEntitlementDiff(rcActive: [:], rcRequestDate: nil)
        #expect(second.capped)
        let after = await transport.capturedRequests.compactMap { $0.url?.path }
        #expect(after.count == 3)
        #expect(after.last == "/v1/diagnostics/entitlement-diff")
    }

    @Test("M-3：匹配由服务端算 —— 两侧快照明显不同，客户端也原样透出服务端的 match")
    func entitlementDiffDoesNotJudgeLocally() async throws {
        let transport = MockTransport()
        let (purchases, _, _) = makeMigrationPurchases(transport: transport)
        await transport.enqueue(.json(subscriberWithEntitlementsJSON(requestDate: Date(),
                                                                    proExpires: Date().addingTimeInterval(86_400))))
        // 服务端说 match=true（比如时钟差在容差内），端上有 2 条权益、RC 侧 0 条 —— 照样透传。
        await transport.enqueue(.json(#"{"match":true,"diff":{"only_rc":[],"only_dog":[],"expires_mismatch":[]}}"#,
                                      statusCode: 201))
        _ = try await purchases.customerInfo()

        let result = try await purchases.reportEntitlementDiff(rcActive: [:], rcRequestDate: nil)
        #expect(result.match)
        #expect(result.capped == false) // 缺字段走容错缺省（设计 §8）
    }
}
}
