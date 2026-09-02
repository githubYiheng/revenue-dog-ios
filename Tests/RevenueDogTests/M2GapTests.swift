//
//  M2GapTests.swift
//  M2 门禁核验报告（docs/audit/2026-08-28-sdk-m2-gate.md）§1 中判定为 ⚠️「已实现无测试」
//  的各行补测。逐条对应：#4 / #12 / #14 / #16 / #17 / #15 / #55+#7 / #3。
//
//  惯例沿用 PurchaseFlowTests.swift 与 M2HardeningTests.swift：
//  FakeStoreKitProvider / MockTransport / FakeTransaction / FinishFlag 直接复用。
//

import Foundation
import Testing
@testable import RevenueDog

// MARK: - 测试替身（本文件专用）

/// finish 调用**计数**（FinishFlag 只有布尔，#55/#7 要断言「调用数 = 0」）。
final class FinishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

struct CountingTransaction: StoreTransactionType {
    let transactionIdentifier: String
    let originalTransactionIdentifier: String
    let productIdentifier: String
    let purchaseDate: Date
    let expirationDate: Date?
    var quantity: Int = 1
    var revocationDate: Date? = nil
    var isUpgraded: Bool = false
    var appAccountToken: UUID? = nil
    let jwsRepresentation: String?
    let counter: FinishCounter

    var isFinished: Bool { get async { counter.value > 0 } }
    func finish() async { counter.increment() }
}

/// 可闸门化的 transport：命中 `gatedPath` 的请求在闸门打开前一直挂起，
/// 借此在「多笔请求同时挂在传输层」这一事实上直接断言并发（#4）与 in-flight 去重（#14）。
private actor GatedTransport: HTTPTransport {

    private let gatedPath: String
    private let responseBody: Data
    private var isOpen = false
    private var inFlight = 0
    private(set) var peakInFlight = 0
    private(set) var capturedRequests: [URLRequest] = []

    init(gatedPath: String = "/v1/receipts", responseJSON: String) {
        self.gatedPath = gatedPath
        self.responseBody = Data(responseJSON.utf8)
    }

    func openGate() { isOpen = true }

    var gatedRequests: [URLRequest] { capturedRequests.filter { $0.url?.path == gatedPath } }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        capturedRequests.append(request)
        guard request.url?.path == gatedPath else {
            return HTTPTransportResponse(statusCode: 200, headers: [:], body: responseBody)
        }
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        // actor 重入：挂起期间其他 send 可以进来 —— 并发被真实观测，而非推断。
        while !isOpen {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        inFlight -= 1
        return HTTPTransportResponse(statusCode: 200, headers: [:], body: responseBody)
    }
}

// MARK: - Fixtures

private func gapSubscriberJSON(originalAppUserID: String = "tester") -> String {
    """
    {"request_date":"2026-08-27T00:00:00Z","request_date_ms":1782518400000,
     "subscriber":{"original_app_user_id":"\(originalAppUserID)","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
    """
}

private func gapWaitFor(timeoutMs: Int = 3000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

private func gapTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogM2Gap/\(UUID().uuidString)", isDirectory: true)
}

private func gapProduct(_ identifier: String = "com.demo.monthly") -> StoreProduct {
    StoreProduct(productIdentifier: identifier, localizedTitle: "", localizedDescription: "",
                 price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99")
}

private func gapPackage(offering: String, product: String = "com.demo.monthly") -> Package {
    Package(identifier: "$rc_monthly",
            packageType: .monthly,
            offeringIdentifier: offering,
            platformProductIdentifier: product,
            storeProduct: nil)
}

@MainActor
private func makeGapPurchases(
    transport: any HTTPTransport,
    directory: URL,
    appUserID: String? = nil,
    cacheStorage: any CacheStorage = InMemoryCacheStorage(),
) -> (Purchases, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly"),
                                                   FakeProduct(productIdentifier: "com.demo.coins")])
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(appUserID: appUserID)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: cacheStorage,
            transport: transport,
            pendingPurchasesDirectory: directory,
            storeKit: provider,
            delayScheduler: NoDelayScheduler(),
        ),
    )
    return (purchases, provider)
}

private func receiptBodies(_ requests: [URLRequest]) -> [[String: Any]] {
    requests
        .filter { $0.url?.path == "/v1/receipts" }
        .compactMap { $0.httpBody }
        .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

// MARK: - 用例

// 单例串行域（见 Support/SingletonSerialDomain.swift）：本 suite 碰 Purchases 静态单例，
// 必须与其它同类 suite 串行，不能靠 suite 内 `.serialized`。
extension PurchasesSingletonDomain {
@MainActor
@Suite("M2 门禁补测", .serialized)
struct M2GapTests {

    // MARK: #4 —— P5：updates 循环体不得串行化

    @Test("#4/P5：updates 注入 3 笔交易 → 3 个 POST 同时挂在传输层（未被串行化）")
    func updatesProcessingIsConcurrent() async throws {
        let transport = GatedTransport(responseJSON: gapSubscriberJSON())
        let (purchases, provider) = makeGapPurchases(transport: transport, directory: gapTempDirectory())
        defer { Task { await transport.openGate() } } // 断言失败也要放行，避免挂起的 Task 泄漏

        _ = try await purchases.customerInfo() // 走一次 awaitStart：updates 消费者已挂

        let flags = (0..<3).map { _ in FinishFlag() }
        for index in 0..<3 {
            await provider.emit(FakeTransaction(transactionIdentifier: "tx-conc-\(index)",
                                                originalTransactionIdentifier: "tx-conc-\(index)",
                                                productIdentifier: "com.demo.monthly",
                                                purchaseDate: Date(),
                                                expirationDate: Date().addingTimeInterval(3600),
                                                jwsRepresentation: "h.conc\(index).s",
                                                finishFlag: flags[index]))
        }

        // 三笔同时挂在闸门上 = 循环体没有等前一笔处理完再取下一笔
        let concurrent = await gapWaitFor { await transport.peakInFlight >= 3 }
        #expect(concurrent)
        #expect(await transport.peakInFlight == 3)

        await transport.openGate()
        let allFinished = await gapWaitFor { flags.allSatisfy(\.value) }
        #expect(allFinished)
        #expect(await transport.gatedRequests.count == 3)
    }

    // MARK: #12 —— revoked / isUpgraded 走同一管道，无特例

    @Test("#12：revocationDate != nil 与 isUpgraded == true 走统一管道 —— 200 即 finish，无特例分支")
    func revokedAndUpgradedUseSamePipeline() async throws {
        let transport = MockTransport()
        await transport.enqueue(.json(gapSubscriberJSON()))
        let (purchases, provider) = makeGapPurchases(transport: transport, directory: gapTempDirectory())
        _ = try await purchases.customerInfo()

        // 撤销交易：无 expirationDate（一次性形态），仅靠 revocationDate 归入「订阅型」判定
        let revokedFlag = FinishFlag()
        var revoked = FakeTransaction(transactionIdentifier: "tx-revoked",
                                      originalTransactionIdentifier: "tx-revoked",
                                      productIdentifier: "com.demo.coins",
                                      purchaseDate: Date().addingTimeInterval(-7200),
                                      expirationDate: nil,
                                      jwsRepresentation: "h.rev.s",
                                      finishFlag: revokedFlag)
        revoked.revocationDate = Date().addingTimeInterval(-60)

        // 升级交易：isUpgraded = true（订阅被换挡，Apple 侧已失效）
        let upgradedFlag = FinishFlag()
        var upgraded = FakeTransaction(transactionIdentifier: "tx-upgraded",
                                       originalTransactionIdentifier: "tx-upgraded",
                                       productIdentifier: "com.demo.monthly",
                                       purchaseDate: Date().addingTimeInterval(-3600),
                                       expirationDate: Date().addingTimeInterval(-1800),
                                       jwsRepresentation: "h.upg.s",
                                       finishFlag: upgradedFlag)
        upgraded.isUpgraded = true

        await provider.emit(revoked)
        await provider.emit(upgraded)

        let bothFinished = await gapWaitFor { revokedFlag.value && upgradedFlag.value }
        #expect(bothFinished) // 200 即 finish：撤销/升级都不走特例
        let receipts = await transport.capturedRequests.filter { $0.url?.path == "/v1/receipts" }
        #expect(receipts.count == 2) // 两笔都进了同一条上报管道，无一被静默丢弃
    }

    // MARK: #14 —— purchase 与 updates 双路投递同一笔交易

    @Test("#14：purchase 进行中注入同 transactionId 的 updates → 只产生一次带归因 POST")
    func inFlightDeduplicationAcrossPurchaseAndUpdates() async throws {
        let transport = GatedTransport(responseJSON: gapSubscriberJSON())
        let (purchases, provider) = makeGapPurchases(transport: transport, directory: gapTempDirectory())
        defer { Task { await transport.openGate() } }

        _ = try await purchases.customerInfo()

        let flag = FinishFlag()
        let tx = FakeTransaction(transactionIdentifier: "tx-dual",
                                 originalTransactionIdentifier: "tx-dual",
                                 productIdentifier: "com.demo.monthly",
                                 purchaseDate: Date(),
                                 expirationDate: Date().addingTimeInterval(3600),
                                 jwsRepresentation: "h.dual.s",
                                 finishFlag: flag)
        await provider.scriptPurchase { _ in .success(tx) }

        let purchaseTask = Task { @MainActor in
            try await purchases.purchase(package: gapPackage(offering: "offer-dual"))
        }

        // purchase 的上报已挂在闸门上 → in-flight 去重窗口正开着
        let inFlight = await gapWaitFor { await transport.gatedRequests.count == 1 }
        #expect(inFlight)

        await provider.emit(tx) // 同一笔从 updates 二次投递
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await transport.gatedRequests.count == 1) // 窗口内被去重，未二次 POST

        await transport.openGate()
        let result = try await purchaseTask.value
        #expect(result.transactionIdentifier == "tx-dual")

        try? await Task.sleep(nanoseconds: 200_000_000)
        let bodies = receiptBodies(await transport.capturedRequests)
        #expect(bodies.count == 1)
        // 唯一那次 POST 带完整归因（去重保住的是「带归因」的那一笔）
        #expect(bodies.first?["presented_offering_identifier"] as? String == "offer-dual")
        #expect(bodies.first?["initiation_source"] as? String == "purchase")
    }

    // MARK: #16 —— 配对守卫：cacheDate <= purchaseDate（+1 分钟时钟余量）

    @Test("#16：purchaseDate 早于上下文 createdAt 超 1 分钟 → matchInitiation 取回 nil")
    func matchInitiationRejectsEarlierPurchaseDate() async throws {
        let directory = gapTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PendingPurchaseStore(directory: directory)

        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let key = PendingPurchaseStore.initiationKey(productIdentifier: "com.demo.monthly")
        try await store.save(PendingPurchaseContext(key: key,
                                                    productIdentifier: "com.demo.monthly",
                                                    appUserID: "tester",
                                                    presentedOfferingIdentifier: "offer-guard",
                                                    initiationSource: .purchase,
                                                    createdAt: createdAt))

        // 交易发生在上下文落盘之前 120 秒 —— 超出 1 分钟时钟余量 → 不是这一笔
        let stale = await store.matchInitiation(productIdentifier: "com.demo.monthly",
                                                purchaseDate: createdAt.addingTimeInterval(-120))
        #expect(stale == nil)

        // 余量之内（-30 秒）仍然配上，证明拒绝的是「超余量」而不是「一律拒早」
        let withinTolerance = await store.matchInitiation(productIdentifier: "com.demo.monthly",
                                                          purchaseDate: createdAt.addingTimeInterval(-30))
        #expect(withinTolerance?.key == key)

        // 正常时序（交易晚于落盘）当然配得上
        let normal = await store.matchInitiation(productIdentifier: "com.demo.monthly",
                                                 purchaseDate: createdAt.addingTimeInterval(5))
        #expect(normal?.key == key)
    }

    // MARK: #17 —— 取消后必须清上下文

    @Test("#17：userCancelled 后 PendingPurchaseStore 上下文已清空（不只是没发 receipts）")
    func userCancelledClearsPendingContext() async throws {
        let directory = gapTempDirectory()
        let transport = MockTransport()
        await transport.enqueue(.json(gapSubscriberJSON()))
        let (purchases, provider) = makeGapPurchases(transport: transport, directory: directory)
        _ = try await purchases.customerInfo()

        await provider.scriptPurchase { _ in .userCancelled }
        let result = try await purchases.purchase(product: gapProduct())
        #expect(result.userCancelled)

        let leftovers = await PendingPurchaseStore(directory: directory).all()
        #expect(leftovers.isEmpty) // P3：取消是终态，发起键必须落地即清
        let receipts = await transport.capturedRequests.filter { $0.url?.path == "/v1/receipts" }
        #expect(receipts.isEmpty)
    }

    // MARK: #15 —— 同 productID 连续两次购买，归因不串

    @Test("#15：同 productID 连发两次购买（串行）→ 两笔归因各归各的，不串台")
    func sequentialPurchasesOfSameProductKeepDistinctAttribution() async throws {
        let directory = gapTempDirectory()
        let transport = MockTransport()
        await transport.enqueue(.json(gapSubscriberJSON()))
        let (purchases, provider) = makeGapPurchases(transport: transport, directory: directory)
        _ = try await purchases.customerInfo()

        let firstFlag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-seq-1",
                                     originalTransactionIdentifier: "tx-seq-1",
                                     productIdentifier: productID,
                                     purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.seq1.s",
                                     finishFlag: firstFlag))
        }
        let first = try await purchases.purchase(package: gapPackage(offering: "offer-first"))
        #expect(first.transactionIdentifier == "tx-seq-1")

        let secondFlag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-seq-2",
                                     originalTransactionIdentifier: "tx-seq-2",
                                     productIdentifier: productID,
                                     purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.seq2.s",
                                     finishFlag: secondFlag))
        }
        let second = try await purchases.purchase(package: gapPackage(offering: "offer-second"))
        #expect(second.transactionIdentifier == "tx-seq-2")

        let bodies = receiptBodies(await transport.capturedRequests)
        #expect(bodies.count == 2)
        // 复合发起键（pending:<productId>#<uuid8>）保证第二次没有捡到第一次的上下文
        #expect(bodies.map { $0["fetch_token"] as? String } == ["h.seq1.s", "h.seq2.s"])
        #expect(bodies.map { $0["presented_offering_identifier"] as? String } == ["offer-first", "offer-second"])
        #expect(bodies.allSatisfy { $0["product_id"] as? String == "com.demo.monthly" })

        #expect(firstFlag.value && secondFlag.value)
        let leftovers = await PendingPurchaseStore(directory: directory).all()
        #expect(leftovers.isEmpty) // 两笔上下文都按各自的键收尾，没有互相覆盖后残留
    }

    // MARK: #15（并发） —— 同 productID 并发两次购买，交易乱序到达也不串归因

    @Test("#15：同 productID **并发**两次购买，第二笔先返回 → 两笔归因仍各归各的")
    func concurrentPurchasesOfSameProductKeepDistinctAttribution() async throws {
        let directory = gapTempDirectory()
        let transport = MockTransport()
        await transport.enqueue(.json(gapSubscriberJSON()))   // 单条 stub 会被反复复用
        let (purchases, provider) = makeGapPurchases(transport: transport, directory: directory)
        _ = try await purchases.customerInfo()

        let firstFlag = FinishFlag()
        let secondFlag = FinishFlag()
        let gate = ConcurrentPurchaseGate()

        // 时序编排：第一笔的 storeKit.purchase 挂住，直到第二笔整条链路（含上报）走完 ——
        // 于是「后发起的 B 先被 handle」，正是 #15 描述的乱序场景。
        await provider.scriptPurchaseAsync { productID in
            let index = await gate.enter()
            if index == 1 {
                await gate.waitForSecond()
                return .success(FakeTransaction(transactionIdentifier: "tx-conc-1",
                                                originalTransactionIdentifier: "tx-conc-1",
                                                productIdentifier: productID,
                                                purchaseDate: Date(),
                                                expirationDate: Date().addingTimeInterval(3600),
                                                jwsRepresentation: "h.conc1.s",
                                                finishFlag: firstFlag))
            }
            return .success(FakeTransaction(transactionIdentifier: "tx-conc-2",
                                            originalTransactionIdentifier: "tx-conc-2",
                                            productIdentifier: productID,
                                            purchaseDate: Date(),
                                            expirationDate: Date().addingTimeInterval(3600),
                                            jwsRepresentation: "h.conc2.s",
                                            finishFlag: secondFlag))
        }

        let taskA = Task { @MainActor in
            try await purchases.purchase(package: gapPackage(offering: "offer-A"))
        }
        // 等 A 的上下文确实先落盘（A 进了脚本 = save 已完成），再发起 B
        let aStarted = await gapWaitFor { await gate.entered >= 1 }
        #expect(aStarted)
        let taskB = Task { @MainActor in
            try await purchases.purchase(package: gapPackage(offering: "offer-B"))
        }

        let resultB = try await taskB.value
        #expect(resultB.transactionIdentifier == "tx-conc-2")
        await gate.markSecondFinished()
        let resultA = try await taskA.value
        #expect(resultA.transactionIdentifier == "tx-conc-1")

        let bodies = receiptBodies(await transport.capturedRequests)
        #expect(bodies.count == 2)
        // 关键断言：B 先上报，带的必须是 B 自己的 offering（旧实现会捡到 A 的上下文 → offer-A）
        let byToken = Dictionary(bodies.compactMap { body -> (String, [String: Any])? in
            guard let token = body["fetch_token"] as? String else { return nil }
            return (token, body)
        }, uniquingKeysWith: { first, _ in first })
        #expect(byToken["h.conc2.s"]?["presented_offering_identifier"] as? String == "offer-B")
        #expect(byToken["h.conc1.s"]?["presented_offering_identifier"] as? String == "offer-A")

        #expect(firstFlag.value && secondFlag.value)
        let leftovers = await PendingPurchaseStore(directory: directory).all()
        #expect(leftovers.isEmpty) // 两笔上下文各自收尾，没有互相覆盖后残留
    }

    // MARK: #55 / #7 —— stale 缓存路径永不触发 finish

    @Test("#55/#7：后端 5xx 回落 stale 缓存 —— finish 调用数恒为 0")
    func staleCacheFallbackNeverFinishes() async throws {
        let appUserID = "tester-stale"
        let storage = InMemoryCacheStorage()
        let staleInfo = CustomerInfo(
            wireModel: try JSONDecoder().decode(CustomerInfoWireModel.self,
                                                from: Data(gapSubscriberJSON(originalAppUserID: "stale-marker").utf8)))
        // 1 小时前落的缓存 —— 前台 TTL 5 分钟，必然 stale
        await storage.write(DeviceCache.Entry(value: staleInfo, cachedAt: Date().addingTimeInterval(-3600)),
                            forKey: CacheKey.customerInfo(appUserID: appUserID))

        let transport = MockTransport()
        // Is-Retryable: false 让 HTTPClient 不做退避重试（本用例只关心 finish 侧语义）
        await transport.enqueue(.failure(statusCode: 500, headers: ["Is-Retryable": "false"]))
        let (purchases, provider) = makeGapPurchases(transport: transport,
                                                     directory: gapTempDirectory(),
                                                     appUserID: appUserID,
                                                     cacheStorage: storage)

        let counter = FinishCounter()
        await provider.scriptPurchase { productID in
            .success(CountingTransaction(transactionIdentifier: "tx-stale",
                                         originalTransactionIdentifier: "tx-stale",
                                         productIdentifier: productID,
                                         purchaseDate: Date(),
                                         expirationDate: Date().addingTimeInterval(3600),
                                         jwsRepresentation: "h.stale.s",
                                         counter: counter))
        }
        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(product: gapProduct())
        }
        #expect(counter.value == 0) // 5xx：finish 一次都没调（铁律 P2）

        // stale 回落路径：TTL 已过 → 拉网 → 5xx → 供给 stale 缓存
        let served = try await purchases.customerInfo(fetchPolicy: .cachedOrFetched)
        #expect(served.originalAppUserID == "stale-marker") // 确认走的确实是 stale 缓存分支
        #expect(counter.value == 0) // stale CustomerInfo 永远不是 finish 的依据（#7）
    }

    // MARK: #3 —— listener Task 跨多次 emit 持续存活

    @Test("#3：updates 监听 Task 在多次 emit 之间持续存活（处理完一笔后仍接住下一笔）")
    func updatesListenerSurvivesBetweenEmissions() async throws {
        let transport = MockTransport()
        await transport.enqueue(.json(gapSubscriberJSON()))
        let (purchases, provider) = makeGapPurchases(transport: transport, directory: gapTempDirectory())
        _ = try await purchases.customerInfo()

        let firstFlag = FinishFlag()
        await provider.emit(FakeTransaction(transactionIdentifier: "tx-live-1",
                                            originalTransactionIdentifier: "tx-live-1",
                                            productIdentifier: "com.demo.monthly",
                                            purchaseDate: Date(),
                                            expirationDate: Date().addingTimeInterval(3600),
                                            jwsRepresentation: "h.live1.s",
                                            finishFlag: firstFlag))
        let firstHandled = await gapWaitFor { firstFlag.value }
        #expect(firstHandled)

        // 第一笔已经彻底处理完（子 Task 结束）——此刻监听 Task 若被 cancel/结束，第二笔就会丢
        let secondFlag = FinishFlag()
        await provider.emit(FakeTransaction(transactionIdentifier: "tx-live-2",
                                            originalTransactionIdentifier: "tx-live-2",
                                            productIdentifier: "com.demo.monthly",
                                            purchaseDate: Date(),
                                            expirationDate: Date().addingTimeInterval(3600),
                                            jwsRepresentation: "h.live2.s",
                                            finishFlag: secondFlag))
        let secondHandled = await gapWaitFor { secondFlag.value }
        #expect(secondHandled)

        let bodies = receiptBodies(await transport.capturedRequests)
        #expect(bodies.map { $0["fetch_token"] as? String } == ["h.live1.s", "h.live2.s"])
    }
}
}

/// #15 并发用例的时序闸门：保证「A 先落上下文、B 先被处理」。
private actor ConcurrentPurchaseGate {

    private(set) var entered = 0
    private var secondFinished = false

    func enter() -> Int {
        entered += 1
        return entered
    }

    func markSecondFinished() { secondFinished = true }

    func waitForSecond() async {
        while !secondFinished {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
