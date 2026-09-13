//
//  IdentityGateTests.swift
//  ADR 0046 ① / ADR 0047：冷启动上报等宿主身份就位（`Configuration.with(waitsForLogInBeforeSync:)`）。
//
//  事故形态（docs/audit/2026-09-13-bible-scroll-c5-script1-stale-identity.md）：
//  容器里残留旧具名身份 C、设备上有现役订阅 → 冷启动 currentEntitlements 扫描按 C 上报 →
//  0.7 秒后宿主才 logIn(D)。开关开启 + 持久化**具名**身份启动时，收据必须等 logIn(D) 之后按 D 上报。
//
//  门控只在三条同时成立时进入（ADR 0047）：开关开、configure 未传 appUserID、
//  bootstrap 读出的是持久化的**具名**身份。其余启动与 0.2.1 逐字一致。
//
//  两个计时（10 秒确认超时、60 秒 identity_pending 告警）一律走 `ManualDelayScheduler`
//  手动放行 —— 单测不真睡；不该门控的用例注入 `NoDelayScheduler`，一旦误门控会立刻超时报错而不是挂住。
//

import Foundation
import Testing
@testable import RevenueDog

// MARK: - 计时替身

/// 可手动放行的调度器：`sleep` 一直挂起，直到测试 `fire(seconds:)`；所在 Task 被取消时抛 `CancellationError`。
private actor ManualDelayScheduler: DelayScheduler {

    private struct Sleeper {
        let id: UUID
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var sleepers: [Sleeper] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // 取消先于登记到达时 onCancel 找不到人 —— 这里补一刀。
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, seconds: seconds, continuation: continuation))
                let waiters = arrivalWaiters
                arrivalWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// 放行所有时长为 `seconds` 的挂起中的 sleep，返回放行个数。
    @discardableResult
    func fire(seconds: TimeInterval) -> Int {
        let matched = sleepers.filter { $0.seconds == seconds }
        sleepers.removeAll { $0.seconds == seconds }
        for sleeper in matched { sleeper.continuation.resume() }
        return matched.count
    }

    func sleepingCount(seconds: TimeInterval) -> Int {
        sleepers.filter { $0.seconds == seconds }.count
    }

    /// 挂起到至少有一个时长为 `seconds` 的 sleep 在等 —— 用来确认「调用方确实卡在门上 / 计时确实起了」。
    func waitUntilSleeping(seconds: TimeInterval) async {
        while !sleepers.contains(where: { $0.seconds == seconds }) {
            await withCheckedContinuation { continuation in arrivalWaiters.append(continuation) }
        }
    }
}

/// 捕获日志文本（看「updates 交易被门控跳过」这类没有别的可观测面的时刻）。
private final class GateLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func write(level: LogLevel, category: String, message: String, file: String, line: UInt) {
        lock.lock(); messages.append(message); lock.unlock()
    }

    func contains(_ fragment: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return messages.contains { $0.contains(fragment) }
    }
}

// MARK: - Fixtures

private let staleNamedC = "stale-named-C"
private let currentD = "current-D"
private let receiptsPath = "/v1/receipts"
private let identifyPath = "/v1/subscribers/identify"

private let gateSubscriberJSON = """
{"request_date":"2026-09-13T00:00:00Z","request_date_ms":1789257600000,
 "subscriber":{"original_app_user_id":"tester","original_application_version":null,
   "original_purchase_date":null,"first_seen":"2026-09-01T00:00:00Z","last_seen":"2026-09-13T00:00:00Z",
   "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
"""

/// 现役订阅（已 finish 的也好、未 finish 的也好，扫描路径都认）。
private func activeSubscription(_ id: String, flag: FinishFlag = FinishFlag()) -> FakeTransaction {
    FakeTransaction(transactionIdentifier: id, originalTransactionIdentifier: id,
                    productIdentifier: "com.demo.monthly",
                    purchaseDate: Date(timeIntervalSinceNow: -3600),
                    expirationDate: Date(timeIntervalSinceNow: 30 * 86_400),
                    jwsRepresentation: "h.\(id).s", finishFlag: flag)
}

private func monthlyShell() -> StoreProduct {
    StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                 price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99")
}

private func gateTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogIdentityGate/\(UUID().uuidString)", isDirectory: true)
}

private func gateBody(_ request: URLRequest) -> [String: Any] {
    guard let body = request.httpBody,
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
    return json
}

private func requestPaths(_ transport: MockTransport) async -> [String] {
    await transport.capturedRequests.map { $0.url?.path ?? "" }
}

private func receiptAppUserIDs(_ transport: MockTransport) async -> [String?] {
    await transport.requests(forPath: receiptsPath).map { gateBody($0)["app_user_id"] as? String }
}

private func warnings(_ recorder: DiagnosticsRecorder, code: String) async -> [DiagnosticsEvent] {
    await recorder.queuedEvents().filter {
        $0.type == DiagnosticsEventType.sdkWarning && $0.fields["code"] == .string(code)
    }
}

/// 等 fire-and-forget 的 Task 跑到（调度收敛）：先纯 yield，再 1ms 小步兜底，总上限约 2 秒。
/// **门控计时不走这里** —— 那两个计时一律由 `ManualDelayScheduler` 手动放行。
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        await Task.yield()
    }
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

@MainActor
private func makeGateRig(persistedAppUserID: String?,
                         waitsForLogInBeforeSync: Bool,
                         configuredAppUserID: String? = nil,
                         completedBy: PurchasesCompletedBy = .revenueDog,
                         entitlements: [FakeTransaction] = [],
                         directory: URL = gateTempDirectory(),
                         gateScheduler: any DelayScheduler) async -> (Purchases, MockTransport, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    // 泛队列只放一个 → 粘住：receipts / identify / GET subscribers 都拿到同一份合法 subscriber。
    let transport = MockTransport(stubs: [.json(gateSubscriberJSON)])
    let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
    // StoreKit 侧状态必须在 configure 之前就位：不门控时 startTask 会立刻扫描。
    await provider.setCurrentEntitlements(entitlements)
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(appUserID: configuredAppUserID)
            .with(purchasesCompletedBy: completedBy)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!)
            .with(waitsForLogInBeforeSync: waitsForLogInBeforeSync),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(appUserID: persistedAppUserID),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: directory,
            storeKit: provider,
            networkDelayScheduler: NoDelayScheduler(),
            identityGateScheduler: gateScheduler,
            attributionState: InMemoryAttributionStateStorage(),
            diagnostics: .isolated(),
        ),
    )
    return (purchases, transport, provider)
}

/// 不门控的启动：宿主一 configure 就 logIn(D)（不等启动完成）。
/// 0.2.1 的时序是「logIn 等 startTask（含启动补投）」→ 收据一定先于 identify，且按**启动身份**上报。
/// 返回那张收据上的 app_user_id。
@MainActor
private func expectLegacyLaunchOrder(persistedAppUserID: String?,
                                     waitsForLogInBeforeSync: Bool,
                                     sourceLocation: SourceLocation = #_sourceLocation) async throws -> String? {
    let (purchases, transport, _) = await makeGateRig(persistedAppUserID: persistedAppUserID,
                                                      waitsForLogInBeforeSync: waitsForLogInBeforeSync,
                                                      entitlements: [activeSubscription("tx-legacy-1")],
                                                      gateScheduler: NoDelayScheduler())
    _ = try await purchases.logIn(currentD)

    let paths = await requestPaths(transport)
    let receiptIndex = paths.firstIndex(of: receiptsPath)
    let identifyIndex = paths.firstIndex(of: identifyPath)
    #expect(receiptIndex != nil, "启动补投应已上报：\(paths)", sourceLocation: sourceLocation)
    #expect(identifyIndex != nil, "logIn 应打 identify：\(paths)", sourceLocation: sourceLocation)
    if let receiptIndex, let identifyIndex {
        #expect(receiptIndex < identifyIndex, "0.2.1 时序：收据先于 identify：\(paths)", sourceLocation: sourceLocation)
    }
    #expect(await transport.callCount(forPath: receiptsPath) == 1, sourceLocation: sourceLocation)

    let recorder = purchases.diagnosticsRecorder
    let configured = await recorder.queuedEvents().first { $0.type == DiagnosticsEventType.sdkConfigured }
    #expect(configured?.fields["waits_for_login_before_sync"] == .bool(waitsForLogInBeforeSync),
            sourceLocation: sourceLocation)
    #expect(configured?.fields["identity_gated"] == .bool(false), sourceLocation: sourceLocation)
    // 注入的是 NoDelayScheduler：一旦误门控，60 秒告警会立刻落下 —— 这里必须为空。
    #expect(await warnings(recorder, code: DiagnosticsWarningCode.identityPending).isEmpty,
            sourceLocation: sourceLocation)
    return await receiptAppUserIDs(transport).first ?? nil
}

// MARK: - 门控

extension PurchasesSingletonDomain {
@MainActor
@Suite("ADR 0046/0047 · 身份门控（waitsForLogInBeforeSync）", .serialized, .timeLimit(.minutes(1)))
struct IdentityGateTests {

    @Test("持久化具名 C + 现役交易：logIn(D) 之前零收据；之后收据按 D 上报、identify 在先；再 logIn 不重跑补投")
    func staleNamedIdentityWaitsForLogIn() async throws {
        let (purchases, transport, provider) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true,
            entitlements: [activeSubscription("tx-gate-1")], gateScheduler: ManualDelayScheduler())
        defer { Purchases.resetForTesting() }

        await Purchases.awaitConfigured()
        for _ in 0..<50 { await Task.yield() }
        #expect(await transport.callCount(forPath: receiptsPath) == 0, "身份待确认期间不许有任何收据上报")
        #expect(await provider.unfinishedCallCount == 0, "待确认期间连扫描都不该开始")
        #expect(purchases.appUserID == staleNamedC)

        let recorder = purchases.diagnosticsRecorder
        let events = await recorder.queuedEvents()
        let configured = try #require(events.first { $0.type == DiagnosticsEventType.sdkConfigured })
        #expect(configured.fields["waits_for_login_before_sync"] == .bool(true))
        #expect(configured.fields["identity_gated"] == .bool(true))
        #expect(!events.contains { $0.type == DiagnosticsEventType.transactionObserved })

        _ = try await purchases.logIn(currentD)
        await purchases.awaitIdentityConfirmationReplay()

        #expect(await receiptAppUserIDs(transport) == [currentD], "收据必须按确认后的身份 D 上报")
        let receipt = try #require(await transport.requests(forPath: receiptsPath).first)
        #expect(gateBody(receipt)["initiation_source"] as? String == "queue")

        let paths = await requestPaths(transport)
        let identifyIndex = try #require(paths.firstIndex(of: identifyPath))
        let receiptIndex = try #require(paths.firstIndex(of: receiptsPath))
        #expect(identifyIndex < receiptIndex, "identify（C → D）必须先于收据：\(paths)")
        let identify = try #require(await transport.requests(forPath: identifyPath).first)
        #expect(gateBody(identify)["app_user_id"] as? String == staleNamedC)
        #expect(gateBody(identify)["new_app_user_id"] as? String == currentD)

        // 之后再 logIn：确认只发生一次，补投不重跑（扫描计数不再增长）。
        let scansAfterConfirmation = await provider.unfinishedCallCount
        _ = try await purchases.logIn("current-F")
        await purchases.awaitIdentityConfirmationReplay()
        for _ in 0..<50 { await Task.yield() }
        #expect(await provider.unfinishedCallCount == scansAfterConfirmation)
        #expect(await transport.callCount(forPath: receiptsPath) == 1)
    }

    @Test("logIn 与持久化身份同 id（早返回、不发 identify）也算确认：补投按 C 上报")
    func sameIDLogInEarlyReturnConfirms() async throws {
        let (purchases, transport, _) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true,
            entitlements: [activeSubscription("tx-gate-same")], gateScheduler: ManualDelayScheduler())
        defer { Purchases.resetForTesting() }

        await Purchases.awaitConfigured()
        #expect(await transport.callCount(forPath: receiptsPath) == 0)

        let result = try await purchases.logIn(staleNamedC)
        #expect(result.created == false)
        await purchases.awaitIdentityConfirmationReplay()

        #expect(await transport.callCount(forPath: identifyPath) == 0, "同 id 走早返回，不打 identify")
        #expect(await receiptAppUserIDs(transport) == [staleNamedC])
    }

    @Test("同 id logIn 随后拉 CustomerInfo 失败：logIn 照抛，但身份已确认 —— 补投按 C 上报（ADR 0048）")
    func sameIDLogInConfirmsEvenIfCustomerInfoFetchFails() async throws {
        let (purchases, transport, _) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true,
            entitlements: [activeSubscription("tx-gate-same-fail")], gateScheduler: ManualDelayScheduler())
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(#"{"code":7000,"message":"bad subscriber fetch"}"#, statusCode: 400),
                                forPath: "/v1/subscribers/\(staleNamedC)")

        await Purchases.awaitConfigured()
        #expect(await transport.callCount(forPath: receiptsPath) == 0)

        var thrown: (any Error)?
        do {
            _ = try await purchases.logIn(staleNamedC)
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "拉 CustomerInfo 400 → logIn 仍然抛给宿主")
        await purchases.awaitIdentityConfirmationReplay()

        #expect(await transport.callCount(forPath: identifyPath) == 0)
        #expect(await receiptAppUserIDs(transport) == [staleNamedC], "身份已由宿主声明：补投照常按 C 上报")
    }

    @Test("logIn 失败保持门控：零收据、身份不动；之后 logIn 成功才补投")
    func failedLogInKeepsGate() async throws {
        let (purchases, transport, _) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true,
            entitlements: [activeSubscription("tx-gate-fail")], gateScheduler: ManualDelayScheduler())
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(#"{"code":7000,"message":"bad identify"}"#, statusCode: 400),
                                forPath: identifyPath)

        await Purchases.awaitConfigured()
        var thrown: (any Error)?
        do {
            _ = try await purchases.logIn(currentD)
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "identify 400 → logIn 必须抛")
        await purchases.awaitIdentityConfirmationReplay()
        for _ in 0..<50 { await Task.yield() }
        #expect(await transport.callCount(forPath: receiptsPath) == 0, "logIn 失败不算确认")
        #expect(purchases.appUserID == staleNamedC)

        await transport.clearStubs(forPath: identifyPath)
        _ = try await purchases.logIn(currentD)
        await purchases.awaitIdentityConfirmationReplay()
        #expect(await receiptAppUserIDs(transport) == [currentD])
    }

    @Test("logOut 成功同样确认：补投按服务端刚认过的新匿名 ID 上报")
    func logOutConfirms() async throws {
        let (purchases, transport, _) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true,
            entitlements: [activeSubscription("tx-gate-logout")], gateScheduler: ManualDelayScheduler())
        defer { Purchases.resetForTesting() }

        await Purchases.awaitConfigured()
        #expect(await transport.callCount(forPath: receiptsPath) == 0)

        _ = try await purchases.logOut()
        await purchases.awaitIdentityConfirmationReplay()

        let anonymous = purchases.appUserID
        #expect(IdentityManager.isAnonymous(anonymous))
        #expect(await receiptAppUserIDs(transport) == [anonymous])
    }

    /// 这条路径**不经过** `handle()`（上下文重放直接调 poster）—— 只有补投入口的门控挡得住它。
    @Test("待确认期带 JWS 的待重放上下文不重放；确认后补报一次，沿用发起购买时的身份（与 0.2.1 一致）")
    func pendingContextReplayWaitsForConfirmation() async throws {
        let directory = gateTempDirectory()
        try await PendingPurchaseStore(directory: directory).save(
            PendingPurchaseContext(key: "tx-gate-ctx",
                                   productIdentifier: "com.demo.monthly",
                                   appUserID: "purchaser-P",
                                   initiationSource: .purchase,
                                   jws: "h.ctx.s",
                                   completedBy: .revenueDog))
        let (purchases, transport, _) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true,
            directory: directory, gateScheduler: ManualDelayScheduler())
        defer { Purchases.resetForTesting() }

        await Purchases.awaitConfigured()
        for _ in 0..<50 { await Task.yield() }
        #expect(await transport.callCount(forPath: receiptsPath) == 0, "身份待确认期间上下文重放也不许发")

        _ = try await purchases.logIn(currentD)
        await purchases.awaitIdentityConfirmationReplay()

        let bodies = await transport.requests(forPath: receiptsPath).map(gateBody)
        #expect(bodies.count == 1)
        #expect(bodies.first?["fetch_token"] as? String == "h.ctx.s")
        #expect(bodies.first?["initiation_source"] as? String == "purchase")
        #expect(bodies.first?["app_user_id"] as? String == "purchaser-P")
    }

    @Test("待确认期 purchase 挂在门上：logIn(D) 后先等确认触发的补投、再按 D 执行购买")
    func pendingPurchaseWaitsForLogIn() async throws {
        let scheduler = ManualDelayScheduler()
        let (purchases, transport, provider) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true,
            entitlements: [activeSubscription("tx-gate-launch")], gateScheduler: scheduler)
        defer { Purchases.resetForTesting() }
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-gate-buy", originalTransactionIdentifier: "tx-gate-buy",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date(timeIntervalSinceNow: 30 * 86_400),
                                     jwsRepresentation: "h.buy.s", finishFlag: flag))
        }

        await Purchases.awaitConfigured()
        let purchaseTask = Task { try await purchases.purchase(product: monthlyShell()) }
        await scheduler.waitUntilSleeping(seconds: PurchasesOrchestrator.identityConfirmationTimeout)
        #expect(await transport.callCount(forPath: receiptsPath) == 0)
        #expect(await provider.capturedAppAccountTokens.isEmpty, "确认之前不许碰 StoreKit 购买")

        _ = try await purchases.logIn(currentD)
        let result = try await purchaseTask.value
        #expect(result.transactionIdentifier == "tx-gate-buy")
        #expect(flag.value)

        let bodies = await transport.requests(forPath: receiptsPath).map(gateBody)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["app_user_id"] as? String == currentD })
        // 确认触发的补投先于购买上报（购买不与补投交叠）
        #expect(bodies.first?["initiation_source"] as? String == "queue")
        #expect(bodies.last?["initiation_source"] as? String == "purchase")
        // 10 秒计时随确认取消
        #expect(await eventually { await scheduler.sleepingCount(seconds: PurchasesOrchestrator.identityConfirmationTimeout) == 0 })
        #expect(await warnings(purchases.diagnosticsRecorder, code: DiagnosticsWarningCode.identityPendingTimeout).isEmpty)
    }

    @Test("待确认期 10 秒内未确认 → configurationError + identity_pending_timeout；零上报、不碰 StoreKit、不猜身份",
          arguments: ["purchase", "restore_purchases", "sync_purchases"])
    func pendingUserActionTimesOut(operation: String) async throws {
        let scheduler = ManualDelayScheduler()
        let (purchases, transport, provider) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true,
            entitlements: [activeSubscription("tx-gate-timeout")], gateScheduler: scheduler)
        defer { Purchases.resetForTesting() }
        await provider.scriptPurchase { _ in .userCancelled }

        await Purchases.awaitConfigured()
        let task = Task { () -> PurchasesError? in
            do {
                switch operation {
                case "purchase": _ = try await purchases.purchase(product: monthlyShell())
                case "restore_purchases": _ = try await purchases.restorePurchases()
                default: _ = try await purchases.syncPurchases()
                }
                return nil
            } catch let error as PurchasesError {
                return error
            } catch {
                return nil
            }
        }
        await scheduler.waitUntilSleeping(seconds: PurchasesOrchestrator.identityConfirmationTimeout)
        #expect(await scheduler.fire(seconds: PurchasesOrchestrator.identityConfirmationTimeout) == 1)

        let error = try #require(await task.value, "\(operation) 超时必须抛 PurchasesError")
        #expect(error.code == .configurationError)
        #expect(error.message.contains("waitsForLogInBeforeSync"))
        #expect(error.message.contains("logIn"))
        #expect(error.userInfo["operation"] == operation)

        #expect(await transport.callCount(forPath: receiptsPath) == 0)
        #expect(await provider.capturedAppAccountTokens.isEmpty)
        #expect(await provider.syncCallCount == 0)
        #expect(purchases.appUserID == staleNamedC)

        let timeouts = await warnings(purchases.diagnosticsRecorder, code: DiagnosticsWarningCode.identityPendingTimeout)
        #expect(timeouts.count == 1)
        #expect(timeouts.first?.fields["detail"] == .string("op=\(operation)"))

        // 超时不改变门控状态：之后 logIn 照样确认并补投。
        _ = try await purchases.logIn(currentD)
        await purchases.awaitIdentityConfirmationReplay()
        #expect(await receiptAppUserIDs(transport) == [currentD])
    }

    @Test("待确认期 Transaction.updates 交易：不上报、不 finish；确认后由补投按 D 上报一次")
    func updatesWhilePendingAreDeferred() async throws {
        let sink = GateLogSink()
        Purchases.setLogSink(sink)
        defer { Purchases.setLogSink(DefaultLogSink()) }

        let flag = FinishFlag()
        let transaction = activeSubscription("tx-gate-updates", flag: flag)
        let (purchases, transport, provider) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true, gateScheduler: ManualDelayScheduler())
        defer { Purchases.resetForTesting() }

        // StoreKit 视角：没 finish 的交易留在 unfinished 里。
        await provider.setUnfinished([transaction])
        // configure 之后立刻投递（可能早于 bootstrap —— 那条路径先等门控判定，同样必须跳过）。
        await provider.emit(transaction)
        await Purchases.awaitConfigured()

        #expect(await eventually { sink.contains("tx=tx-gate-updates") }, "updates 交易应被门控跳过并留痕")
        #expect(await transport.callCount(forPath: receiptsPath) == 0)
        #expect(!flag.value, "待确认期间不许 finish")
        let observed = await purchases.diagnosticsRecorder.queuedEvents()
            .filter { $0.type == DiagnosticsEventType.transactionObserved }
        #expect(observed.isEmpty)

        _ = try await purchases.logIn(currentD)
        await purchases.awaitIdentityConfirmationReplay()
        #expect(await receiptAppUserIDs(transport) == [currentD])
        #expect(flag.value, "确认后的补投 200 → finish")
    }

    @Test("待确认期前台重扫（.myApp）不上报；确认后补投按 D 上报")
    func foregroundRescanWhilePendingIsSkipped() async throws {
        let (purchases, transport, provider) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true, completedBy: .myApp,
            entitlements: [activeSubscription("tx-gate-foreground")], gateScheduler: ManualDelayScheduler())
        defer { Purchases.resetForTesting() }

        await Purchases.awaitConfigured()
        purchases.applicationDidBecomeActive()
        purchases.applicationDidBecomeActive()
        for _ in 0..<200 { await Task.yield() }
        #expect(await transport.callCount(forPath: receiptsPath) == 0)
        #expect(await provider.unfinishedCallCount == 0, "待确认期间前台重扫不许开始扫描")

        _ = try await purchases.logIn(currentD)
        await purchases.awaitIdentityConfirmationReplay()
        #expect(await receiptAppUserIDs(transport) == [currentD])
    }

    @Test("configure 后 60 秒仍未确认 → identity_pending 只记一次")
    func identityPendingWarnedOnce() async throws {
        let scheduler = ManualDelayScheduler()
        let (purchases, _, _) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true, gateScheduler: scheduler)
        defer { Purchases.resetForTesting() }
        let recorder = purchases.diagnosticsRecorder

        await Purchases.awaitConfigured()
        await scheduler.waitUntilSleeping(seconds: PurchasesOrchestrator.identityPendingWarningDelay)
        #expect(await warnings(recorder, code: DiagnosticsWarningCode.identityPending).isEmpty, "计时没到不许告警")

        #expect(await scheduler.fire(seconds: PurchasesOrchestrator.identityPendingWarningDelay) == 1)
        #expect(await eventually { await warnings(recorder, code: DiagnosticsWarningCode.identityPending).count == 1 })
        let warning = try #require(await warnings(recorder, code: DiagnosticsWarningCode.identityPending).first)
        #expect(warning.fields["detail"] == .string("after_s=60"))
        #expect(warning.level == DiagnosticsLevel.warn)

        // 每进程最多一次：不会再起第二个计时，也不会再记。
        #expect(await scheduler.sleepingCount(seconds: PurchasesOrchestrator.identityPendingWarningDelay) == 0)
        for _ in 0..<50 { await Task.yield() }
        #expect(await warnings(recorder, code: DiagnosticsWarningCode.identityPending).count == 1)
    }

    @Test("60 秒内确认 → 计时取消，不记 identity_pending")
    func confirmationCancelsIdentityPendingWarning() async throws {
        let scheduler = ManualDelayScheduler()
        let (purchases, _, _) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true, gateScheduler: scheduler)
        defer { Purchases.resetForTesting() }

        await Purchases.awaitConfigured()
        await scheduler.waitUntilSleeping(seconds: PurchasesOrchestrator.identityPendingWarningDelay)
        _ = try await purchases.logIn(currentD)
        await purchases.awaitIdentityConfirmationReplay()

        #expect(await eventually {
            await scheduler.sleepingCount(seconds: PurchasesOrchestrator.identityPendingWarningDelay) == 0
        }, "确认后 60 秒计时应被取消")
        #expect(await scheduler.fire(seconds: PurchasesOrchestrator.identityPendingWarningDelay) == 0)
        for _ in 0..<50 { await Task.yield() }
        #expect(await warnings(purchases.diagnosticsRecorder, code: DiagnosticsWarningCode.identityPending).isEmpty)
    }

    // MARK: 不门控的启动（ADR 0047）—— 与 0.2.1 逐字一致

    @Test("开关关（默认）+ 持久化具名 C：顺序与 0.2.1 一致 —— 收据先于 identify、按 C 上报")
    func switchOffKeepsLegacyOrder() async throws {
        defer { Purchases.resetForTesting() }
        let receiptUser = try await expectLegacyLaunchOrder(persistedAppUserID: staleNamedC,
                                                            waitsForLogInBeforeSync: false)
        #expect(receiptUser == staleNamedC)
    }

    @Test("开关开 + 无持久化身份（全新安装）→ 不门控：顺序同 0.2.1，按新生成的匿名 ID 上报")
    func freshInstallIsNotGated() async throws {
        defer { Purchases.resetForTesting() }
        let receiptUser = try await expectLegacyLaunchOrder(persistedAppUserID: nil,
                                                            waitsForLogInBeforeSync: true)
        let anonymous = try #require(receiptUser)
        #expect(anonymous.hasPrefix(IdentityManager.anonymousPrefix))
    }

    @Test("开关开 + 持久化匿名 ID → 不门控：顺序同 0.2.1，按该匿名 ID 上报",
          arguments: ["$RDAnonymousID:0123456789abcdef0123456789abcdef",
                      "$RCAnonymousID:fedcba9876543210fedcba9876543210"])
    func persistedAnonymousIsNotGated(persistedAnonymousID: String) async throws {
        defer { Purchases.resetForTesting() }
        let receiptUser = try await expectLegacyLaunchOrder(persistedAppUserID: persistedAnonymousID,
                                                            waitsForLogInBeforeSync: true)
        #expect(receiptUser == persistedAnonymousID)
    }

    @Test("开关开 + configure 传 appUserID → 不门控：启动即按该身份上报，purchase 不等确认")
    func configuredAppUserIDIsNotGated() async throws {
        // NoDelayScheduler：一旦误门控，purchase 会立刻超时抛 configurationError，而不是挂住。
        let (purchases, transport, provider) = await makeGateRig(
            persistedAppUserID: staleNamedC, waitsForLogInBeforeSync: true, configuredAppUserID: "configured-E",
            entitlements: [activeSubscription("tx-gate-e-launch")], gateScheduler: NoDelayScheduler())
        defer { Purchases.resetForTesting() }
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-gate-e-buy", originalTransactionIdentifier: "tx-gate-e-buy",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date(timeIntervalSinceNow: 30 * 86_400),
                                     jwsRepresentation: "h.ebuy.s", finishFlag: flag))
        }

        await Purchases.awaitConfigured()
        #expect(await receiptAppUserIDs(transport) == ["configured-E"], "startTask 内的启动补投照常执行")

        let result = try await purchases.purchase(product: monthlyShell())
        #expect(result.transactionIdentifier == "tx-gate-e-buy")
        #expect(await receiptAppUserIDs(transport) == ["configured-E", "configured-E"])

        let recorder = purchases.diagnosticsRecorder
        let configured = try #require(await recorder.queuedEvents().first { $0.type == DiagnosticsEventType.sdkConfigured })
        #expect(configured.fields["has_app_user_id"] == .bool(true))
        #expect(configured.fields["waits_for_login_before_sync"] == .bool(true))
        #expect(configured.fields["identity_gated"] == .bool(false))
        #expect(await warnings(recorder, code: DiagnosticsWarningCode.identityPending).isEmpty)
        #expect(await warnings(recorder, code: DiagnosticsWarningCode.identityPendingTimeout).isEmpty)
    }
}
}
