//
//  StoreKitScenarioSupport.swift
//  StoreKitTest 场景测试的公共基建。
//
//  分工（第一批实测结论，verify/storekittest-spm.md）：
//  - **StoreKit 是真的**：`SKTestSession` 驱动，`Product.purchase()` 走真实 SK2 管道，
//    JWS / `appAccountToken` / `finish()` 都是真的。
//  - **后端是假的**：transport 用 SDK 测试基建里的 `MockTransport`
//    （文件由 `Tests/RevenueDogTests/Support/MockTransport.swift` **引用**进本 target ——
//    两个 target 编同一份源码，内部 API 改名两边一起红，堵住第一批留下的静默腐坏口子）。
//
//  运行前提（硬性）：
//  1. 必须有宿主 app（TEST_HOST = RevenueDogExample），否则 `Transaction.*` 全空；
//  2. destination 必须钉 **iOS 18.x**，iOS 26.x 模拟器上 `SKTestSession` 整体失灵。
//

import Foundation
import Testing

#if canImport(StoreKitTest) && canImport(StoreKit)
import StoreKit
import StoreKitTest
@testable import RevenueDog

// MARK: - 串行域

/// 测试环境**整机一份**（Apple 官方原文：*"There's a single instance of the test
/// environment. All `SKTestSession` instances control the same test environment."*），
/// 而且 `Purchases` 是静态单例 —— 所以本 target 的**全部** suite 都必须挂在这个
/// 带 `.serialized` 的父 suite 下（trait 会递归作用到所有后代 suite 与测试）。
///
/// 加新 suite 时请一律写成 `extension StoreKitScenarioDomain { @Suite … }`。
@Suite("StoreKitTest 串行域", .serialized)
enum StoreKitScenarioDomain {}

// MARK: - 商品 ID（与 Tests/StoreKitTestSupport/RevenueDog.storekit 一致）

enum DemoProduct {
    static let monthly = "com.demo.monthly"
    static let yearly = "com.demo.yearly"
    static let coins = "com.demo.coins"
    static let subscriptionGroupID = "2000000001"
}

// MARK: - SKTestSession 装配

enum SKTestHarness {

    /// 建一个干净的测试会话。
    ///
    /// 两个坑一起处理：
    /// - **顺序陷阱（第一批实测）**：`resetToDefaultState()` 会把 `disableDialogs` 冲回 NO，
    ///   所以必须**先 reset / clear、再设属性**，否则购买会卡在无人应答的弹窗上直到 480s 超时。
    /// - **坑 #103**：`clearTransactions()` 清不干净，测试会带着上一轮的残留交易开始。
    ///   → clear 之后再遍历 `allTransactions()` 逐个 `deleteTransaction`，
    ///     最后把 SK2 侧仍然 unfinished 的交易 finish 掉，保证起点真的是空的。
    @MainActor
    static func makeSession(storefront: String = "USA") async throws -> SKTestSession {
        let session: SKTestSession
        // `.storekit` 打进了**宿主 app bundle**，named-init 直接可用（第一批实测 `named-init OK`）。
        if let url = Bundle.main.url(forResource: "RevenueDog", withExtension: "storekit") {
            session = try SKTestSession(contentsOf: url)
        } else {
            session = try SKTestSession(configurationFileNamed: "RevenueDog")
        }
        session.resetToDefaultState()
        try await clearEverything(session)
        session.disableDialogs = true
        session.storefront = storefront
        session.timeRate = .realTime
        // 坑 #105：StoreKitTest 初始化要几秒，过早跑测试会失败 —— bundle 级一次性等待。
        await StoreKitWarmup.shared.waitIfNeeded()
        return session
    }

    /// 坑 #103 的完整绕法（**本次实测踩到的假失败根因**）。
    ///
    /// `clearTransactions()` 不但清不干净，而且**清干净这件事对 StoreKit 2 侧是异步可见的**：
    /// clear 刚返回时 `Transaction.currentEntitlements` 里可能还留着上一条测试的订阅。
    /// 后果非常隐蔽 —— 下一条测试的 SDK 冷启动扫描会把这条残留权益当成「从未上报过的交易」
    /// 补报一次，于是「买完应该只有 1 次上报」变成 2 次，测试随机变红。
    ///
    /// 所以这里不只是 clear + delete，还要**等到 unfinished 与 currentEntitlements 都空**
    /// 才算清完。
    @MainActor
    static func clearEverything(_ session: SKTestSession) async throws {
        session.clearTransactions()
        for transaction in session.allTransactions() {
            try? session.deleteTransaction(identifier: transaction.identifier)
        }
        for await result in StoreKit.Transaction.unfinished {
            await result.unsafePayloadValue.finish()
        }
        let clean = await SKObserve.wait(timeout: 20) {
            let unfinished = await SKObserve.unfinishedTransactionIDs()
            let entitlements = await SKObserve.currentEntitlementProductIDs()
            return unfinished.isEmpty && entitlements.isEmpty
        }
        try #require(clean, """
                     SKTestSession 清理没生效（坑 #103）：unfinished / currentEntitlements 仍非空。
                     继续跑下去只会给出误导性的失败（残留权益会被下一条测试的冷启动扫描误报一次）。
                     """)
    }

    /// 前置自检：iOS 26.x 模拟器上 `SKTestSession` 整体失灵（storefront 空串、0 商品）。
    /// 命中时直接把失败信息说清楚，别让后面的断言给出误导性的报错。
    static func requireSessionIsLive(file: StaticString = #file, line: UInt = #line) async throws {
        let probe = try await Product.products(for: [DemoProduct.monthly, DemoProduct.coins])
        try #require(probe.count == 2,
                     """
                     SKTestSession 未接管本进程（读到 \(probe.count) 个商品，应为 2）。
                     检查两件事：destination 是否为 iOS 18.x（26.x 已知失灵）；
                     test target 是否配了 TEST_HOST = RevenueDogExample。
                     """)
    }
}

/// 坑 #105：整个 bundle 只等一次。
actor StoreKitWarmup {

    static let shared = StoreKitWarmup()
    private var warmed = false

    func waitIfNeeded() async {
        guard !warmed else { return }
        for _ in 0..<40 {
            if let count = try? await Product.products(for: [DemoProduct.monthly]).count, count == 1 {
                warmed = true
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        warmed = true // 等够了还不行就往下走，让 requireSessionIsLive 给出准确报错
    }
}

// MARK: - 假后端响应

/// `POST /v1/receipts` / `GET /v1/subscribers/{id}` 的响应构造器。
///
/// 只拼契约 §2.2 里 SDK 真正会读的字段；其余走宽容解码的默认值。
enum FakeBackend {

    static let farFuture = "2099-01-01T00:00:00Z"
    static let farPast = "2020-01-01T00:00:00Z"

    /// 空客户（无任何权益）。
    static func empty(appUserID: String = "storekit-test") -> String {
        customerInfo(appUserID: appUserID)
    }

    /// - Parameters:
    ///   - subscriptions: productID → expires_date（ISO8601）
    ///   - entitlements: entitlementID → (productID, expires_date)
    ///   - nonSubscriptions: productID → [transactionID]（消耗型 finish 的判据，坑 #6）
    static func customerInfo(appUserID: String = "storekit-test",
                             subscriptions: [String: String] = [:],
                             entitlements: [String: (product: String, expires: String)] = [:],
                             nonSubscriptions: [String: [String]] = [:]) -> String {
        let subscriptionsJSON = subscriptions
            .sorted { $0.key < $1.key }
            .map { productID, expires in
                """
                "\(productID)":{"expires_date":"\(expires)","purchase_date":"2026-01-01T00:00:00Z",\
                "original_purchase_date":"2026-01-01T00:00:00Z","store":"app_store","is_sandbox":true,\
                "period_type":"normal","ownership_type":"PURCHASED"}
                """
            }
            .joined(separator: ",")

        let entitlementsJSON = entitlements
            .sorted { $0.key < $1.key }
            .map { identifier, value in
                """
                "\(identifier)":{"expires_date":"\(value.expires)","grace_period_expires_date":null,\
                "product_identifier":"\(value.product)","purchase_date":"2026-01-01T00:00:00Z"}
                """
            }
            .joined(separator: ",")

        let nonSubscriptionsJSON = nonSubscriptions
            .sorted { $0.key < $1.key }
            .map { productID, transactionIDs in
                let entries = transactionIDs.map { id in
                    """
                    {"id":"\(id)","purchase_date":"2026-01-01T00:00:00Z",\
                    "original_purchase_date":"2026-01-01T00:00:00Z","store":"app_store","is_sandbox":true}
                    """
                }.joined(separator: ",")
                return "\"\(productID)\":[\(entries)]"
            }
            .joined(separator: ",")

        return """
        {"request_date":"2026-01-01T00:00:00Z","request_date_ms":1767225600000,"subscriber":{\
        "original_app_user_id":"\(appUserID)","first_seen":"2026-01-01T00:00:00Z",\
        "last_seen":"2026-01-01T00:00:00Z","original_purchase_date":"2026-01-01T00:00:00Z",\
        "management_url":null,"subscriptions":{\(subscriptionsJSON)},"entitlements":{\(entitlementsJSON)},\
        "non_subscriptions":{\(nonSubscriptionsJSON)},"subscriber_attributes":{}}}
        """
    }
}

// MARK: - SDK 装配

/// 一次「App 生命周期」：一个 `Purchases` 实例 + 它的假后端。
///
/// 冷启动重放场景靠**换实例、复用同一个 pending 目录**来模拟 —— 这正是生产上
/// 「杀进程再拉起」发生的事（台账、待重放上下文都在磁盘上）。
@MainActor
struct SDKSession {

    let purchases: Purchases
    let transport: MockTransport
    let directory: URL

    /// - Parameters:
    ///   - directory: pending purchase / 台账 / 属性缓冲的根目录。传同一个 = 冷启动重放。
    ///   - receipts: `POST /v1/receipts` 的响应队列（只剩最后一个时**粘住**）。
    ///   - other: 其余端点（`/subscribers` 等）的兜底响应。
    ///   - retryPolicy: 默认 `.none` —— 让「上报失败几次」在断言里是个确定数，
    ///     HTTP 层的重试逻辑另有单测覆盖（`M4FaultInjectionTests`）。
    ///   - diagnosticsEnabled: 默认 **false**（sdk-diagnostics §6-14）。诊断上传会往
    ///     transport 里多打请求，把「这条链路一共发了几次」这类断言变成随机值；
    ///     只有专门断言事件序列的诊断场景才打开。打开时队列落 `directory` 下的独立文件，
    ///     不会碰到 Application Support 里那份全局队列。
    static func start(directory: URL,
                      appUserID: String = "storekit-test",
                      receipts: [MockTransport.Stub],
                      other: MockTransport.Stub = .json(FakeBackend.empty()),
                      retryPolicy: RetryPolicy = .none,
                      diagnosticsEnabled: Bool = false) async -> SDKSession {
        let transport = MockTransport(stubs: [other])
        for stub in receipts {
            await transport.enqueue(stub, forPath: "/receipts")
        }
        let configuration = Configuration(apiKey: "pk_storekit_test")
            .with(appUserID: appUserID)
            .with(baseURL: URL(string: "https://storekit.test.invalid")!)
            .with(logLevel: .debug)
            .with(diagnosticsEnabled: diagnosticsEnabled)
            // 假后端走**公开**注入点（v0.2.0 D 项）：这条路径宿主也能用，
            // 顺带让它一直有人跑 —— `Configuration.with(transport:)` 一旦回退成 internal，本 target 立刻红。
            .with(transport: transport)

        var dependencies = Purchases.Dependencies.live(configuration: configuration)
        dependencies.identityStorage = InMemoryIdentityStorage()
        dependencies.cacheStorage = InMemoryCacheStorage()
        dependencies.attributionState = InMemoryAttributionStateStorage()
        dependencies.pendingPurchasesDirectory = directory
        dependencies.storeKit = SK2Provider()          // 真身 SK2，由 SKTestSession 驱动
        dependencies.delayScheduler = NoDelayScheduler()
        dependencies.networkDelayScheduler = NoDelayScheduler()
        dependencies.networkRetryPolicy = retryPolicy
        dependencies.diagnostics.fileURL = directory
            .appendingPathComponent("_diagnostics", isDirectory: true)
            .appendingPathComponent(DiagnosticsQueue.fileName, isDirectory: false)
        dependencies.diagnostics.settings = InMemoryDiagnosticsSettingsStorage()
        dependencies.diagnostics.startsPeriodicFlush = false

        Purchases.resetForTesting()
        let purchases = Purchases.configure(with: configuration, dependencies: dependencies)
        // 启动期做完（含 replayPendingPurchases）再往下走
        await Purchases.awaitConfigured()
        return SDKSession(purchases: purchases, transport: transport, directory: directory)
    }

    /// 拆掉单例（每个测试结束必须调，否则污染下一个测试）。
    static func tearDown() {
        Purchases.resetForTesting()
    }

    /// 造一个只带 identifier 的商品壳 —— orchestrator 内部会按 identifier 重新向 StoreKit 取货。
    static func productShell(_ identifier: String) -> StoreProduct {
        StoreProduct(productIdentifier: identifier,
                     localizedTitle: identifier,
                     localizedDescription: identifier,
                     price: 0,
                     currencyCode: "USD",
                     localizedPriceString: "—")
    }

    // MARK: 断言辅助

    /// `POST /v1/receipts` 的请求体（按发生顺序）。
    func receiptBodies() async -> [[String: Any]] {
        await transport.requests(forPath: "/receipts").compactMap { request in
            guard let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            return json
        }
    }

    func receiptCallCount() async -> Int {
        await transport.callCount(forPath: "/receipts")
    }

    /// 本次会话记下的诊断事件（按发生顺序）。只有 `diagnosticsEnabled: true` 的用例才有内容。
    @MainActor
    func diagnosticEvents() async -> [DiagnosticsEvent] {
        await purchases.diagnosticsRecorder.queuedEvents()
    }

    /// 待重放上下文的残留数（pending 目录里的根级 *.json）。
    func pendingContextCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.count
    }
}

// MARK: - StoreKit 侧观测

enum SKObserve {

    /// 当前仍未 finish 的交易的 productID 集合。
    static func unfinishedProductIDs() async -> Set<String> {
        var result: Set<String> = []
        for await item in StoreKit.Transaction.unfinished {
            result.insert(item.unsafePayloadValue.productID)
        }
        return result
    }

    static func unfinishedTransactionIDs() async -> Set<UInt64> {
        var result: Set<UInt64> = []
        for await item in StoreKit.Transaction.unfinished {
            result.insert(item.unsafePayloadValue.id)
        }
        return result
    }

    static func currentEntitlementProductIDs() async -> Set<String> {
        var result: Set<String> = []
        for await item in StoreKit.Transaction.currentEntitlements {
            result.insert(item.unsafePayloadValue.productID)
        }
        return result
    }

    /// 轮询等待条件成立（真 StoreKit 的事件是异步到达的，没法靠一次读断言）。
    @discardableResult
    static func wait(timeout: TimeInterval = 15,
                     interval: TimeInterval = 0.2,
                     until condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return await condition()
    }
}

// MARK: - 临时目录

enum TempDirectory {

    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogStoreKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

#endif
