//
//  V052AttributeSyncTests.swift
//  0.5.2（ADR 0248）：属性上传在离开前台时带后台活动保护地发、回前台补传、在途期间的触发不丢。
//
//  覆盖 ADR 决定 1–7：离开前台的后台活动申请顺序（经可注入的记录型申请面断言）、回前台补传与 configure 追平、
//  同步入口按「遍」合并、成功不再推 CustomerInfo、`attributes_sync` 诊断事件。墓碑保留见本文件末段与
//  `M3AttributesTests` 的 Store 用例。
//
//  macOS 上「离开前台」只有 `NSApplication.didResignActiveNotification` 一个通知（ADR 0248 决定 1）；
//  UIKit 的真实路径（`beginBackgroundTask`、两个通知）单测跑不到，靠 `scripts/api-baseline.sh` 交叉编译与真机验收。
//

import Foundation
import Testing
@testable import RevenueDog

#if canImport(AppKit) && !canImport(UIKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private let attributesActivity = Purchases.attributesBackgroundActivityName
private let diagnosticsActivity = Purchases.diagnosticsBackgroundActivityName
private let aliceSubscribers = "/v1/subscribers/alice"
private let aliceAttributes = "/v1/subscribers/alice/attributes"
private let identifyPath = "/v1/subscribers/identify"

private func subscriberJSON(userID: String = "alice") -> String {
    """
    {"request_date":"2026-11-27T00:00:00Z","request_date_ms":1795737600000,
     "subscriber":{"original_app_user_id":"\(userID)","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-11-01T00:00:00Z","last_seen":"2026-11-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
    """
}

/// 可编排的假后端：按路径后缀排队状态码（用完回落 200）、可「扣住」接下来 N 次 `/attributes` 请求直到放行，
/// 请求与响应都写进共享时间线（`request:<path>` / `response:<path>`）。
private actor ScriptedTransport: HTTPTransport {

    let timeline: TestTimeline
    private var statusesBySuffix: [String: [Int]] = [:]
    private var attributesHoldsRemaining = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var capturedRequests: [URLRequest] = []

    init(timeline: TestTimeline) {
        self.timeline = timeline
    }

    /// 命中 `suffix` 的请求依次用这些状态码；非 200 带 `Is-Retryable: false`（一遍只发一次请求，计数好断言）。
    func setStatuses(_ statuses: [Int], forPathSuffix suffix: String) {
        statusesBySuffix[suffix] = statuses
    }

    func holdNextAttributesRequests(_ count: Int) {
        attributesHoldsRemaining = count
    }

    var heldCount: Int { held.count }

    func releaseOne() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func requests(pathSuffix suffix: String) -> [URLRequest] {
        capturedRequests.filter { $0.url?.path.hasSuffix(suffix) == true }
    }

    func requests(path: String) -> [URLRequest] {
        capturedRequests.filter { $0.url?.path == path }
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        let path = request.url?.path ?? ""
        capturedRequests.append(request)
        timeline.append("request:\(path)")
        if path.hasSuffix("/attributes"), attributesHoldsRemaining > 0 {
            attributesHoldsRemaining -= 1
            await withCheckedContinuation { held.append($0) }
            // URLSession 在所属 task 被取消时抛错 —— 照它做：这一遍若跑在被取消的调用方 task 里，请求就会失败。
            if Task.isCancelled {
                timeline.append("cancelled:\(path)")
                throw URLError(.cancelled)
            }
        }
        if path == "/v1/diagnostics/events" {
            return HTTPTransportResponse(statusCode: 202, headers: [:],
                                         body: Data(#"{"accepted":0,"dropped":0}"#.utf8))
        }
        var status = 200
        if let key = statusesBySuffix.keys.first(where: { path.hasSuffix($0) }),
           var queue = statusesBySuffix[key], !queue.isEmpty {
            status = queue.removeFirst()
            statusesBySuffix[key] = queue
        }
        timeline.append("response:\(path)")
        return HTTPTransportResponse(statusCode: status,
                                     headers: status == 200 ? [:] : ["Is-Retryable": "false"],
                                     body: Data(subscriberJSON().utf8))
    }
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogV052AttributeSync/\(UUID().uuidString)", isDirectory: true)
}

@MainActor
private func makeRig(appUserID: String? = "alice",
                     persistedAppUserID: String? = nil,
                     waitsForLogInBeforeSync: Bool = false,
                     isApplicationActive: Bool = false,
                     directory: URL = tempDirectory()) -> (Purchases, ScriptedTransport, RecordingAppLifecycle) {
    Purchases.resetForTesting()
    let timeline = TestTimeline()
    let transport = ScriptedTransport(timeline: timeline)
    let lifecycle = RecordingAppLifecycle(isApplicationActive: isApplicationActive, timeline: timeline)
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(appUserID: appUserID)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!)
            .with(waitsForLogInBeforeSync: waitsForLogInBeforeSync),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(appUserID: persistedAppUserID),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: directory,
            storeKit: nil,
            delayScheduler: NoDelayScheduler(),
            networkDelayScheduler: NoDelayScheduler(),
            identityGateScheduler: NoDelayScheduler(),
            attributionState: InMemoryAttributionStateStorage(),
            diagnostics: .isolated(),
            makeAppLifecycle: { lifecycle },
        ),
    )
    return (purchases, transport, lifecycle)
}

/// 等 fire-and-forget 的 Task 跑到：先纯 yield，再 1ms 小步兜底，总上限约 3 秒。
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        await Task.yield()
    }
    for _ in 0..<3_000 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

@MainActor
private func waitForBuffered(_ purchases: Purchases, count: Int) async -> Bool {
    await eventually { await purchases.unsyncedAttributes().count == count }
}

private func attributeKeys(_ request: URLRequest?) -> Set<String> {
    guard let data = request?.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let attributes = object["attributes"] as? [String: Any] else { return [] }
    return Set(attributes.keys)
}

private func attributeValue(_ request: URLRequest?, key: String) -> String? {
    guard let data = request?.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let attributes = object["attributes"] as? [String: Any] else { return nil }
    return (attributes[key] as? [String: Any])?["value"] as? String
}

private func attributesSyncEvents(_ purchases: Purchases) async -> [DiagnosticsEvent] {
    await purchases.diagnosticsRecorder.queuedEvents().filter { $0.type == DiagnosticsEventType.attributesSync }
}

/// 全部 `attributes_sync` 的 `trigger`：还在队列里的 + 已经随诊断上传发走的。
/// 离开前台时诊断上传与属性同步并行，这一遍的事件落在哪一边不确定，两边都要看。
private func attributesSyncTriggers(_ purchases: Purchases, _ transport: ScriptedTransport) async -> [String] {
    var triggers: [String] = []
    for request in await transport.requests(path: "/v1/diagnostics/events") {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { continue }
        for event in events where event["type"] as? String == DiagnosticsEventType.attributesSync {
            if let trigger = (event["fields"] as? [String: Any])?["trigger"] as? String { triggers.append(trigger) }
        }
    }
    for event in await attributesSyncEvents(purchases) {
        if case .string(let trigger)? = event.fields["trigger"] { triggers.append(trigger) }
    }
    return triggers
}

/// 发「失活」通知（macOS 单测：`NSApplication.didResignActiveNotification`，同一个通知也翻后台标志）。
private func postResignActive() {
    #if canImport(AppKit) && !canImport(UIKit)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    #elseif canImport(UIKit)
    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
    #endif
}

@MainActor
private final class CountingDelegate: PurchasesDelegate {
    var received = 0
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        received += 1
    }
}

extension PurchasesSingletonDomain {

@MainActor
@Suite("0.5.2 · 属性同步时机与按遍合并（ADR 0248）", .serialized, .timeLimit(.minutes(1)))
struct V052AttributeSyncTests {

    // MARK: 离开前台（决定 1、2）

    @Test("失活：通知发出的调用返回前两个后台活动都已申请；请求在申请之后；请求结束后属性那个活动结束一次")
    func resignActiveBeginsActivitiesBeforeRequest() async throws {
        defer { AppStateProvider.setBackgrounded(false) }
        let (purchases, transport, lifecycle) = makeRig()
        purchases.setAttributes(["favorite": "pizza"])
        #expect(await waitForBuffered(purchases, count: 1))

        postResignActive()
        // 同步断言：post 返回时两个活动都已申请（观察者在发帖线程同步派发）。
        #expect(lifecycle.beginCount(attributesActivity) == 1)
        #expect(lifecycle.beginCount(diagnosticsActivity) == 1)

        #expect(await eventually { lifecycle.endCount(attributesActivity) == 1 })
        #expect(await eventually { lifecycle.endCount(diagnosticsActivity) == 1 })
        let timeline = lifecycle.timeline
        let begin = try #require(timeline.firstIndex("begin:\(attributesActivity)"))
        let request = try #require(timeline.firstIndex("request:\(aliceAttributes)"))
        let response = try #require(timeline.firstIndex("response:\(aliceAttributes)"))
        let end = try #require(timeline.firstIndex("end:\(attributesActivity)"))
        #expect(begin < request)
        #expect(response < end)
        #expect(await transport.requests(path: aliceAttributes).count == 1)
        #expect(await purchases.unsyncedAttributes().isEmpty)
        for _ in 0..<200 { await Task.yield() }
        #expect(lifecycle.endCount(attributesActivity) == 1, "只结束一次")
    }

    @Test("失活：请求失败（500）时属性那个活动同样结束一次，待发保留")
    func resignActiveEndsActivityOnFailure() async throws {
        defer { AppStateProvider.setBackgrounded(false) }
        let (purchases, transport, lifecycle) = makeRig()
        await transport.setStatuses([500], forPathSuffix: "/attributes")
        purchases.setAttributes(["favorite": "pizza"])
        #expect(await waitForBuffered(purchases, count: 1))

        postResignActive()
        #expect(lifecycle.beginCount(attributesActivity) == 1)
        #expect(await eventually { lifecycle.endCount(attributesActivity) == 1 })
        let response = try #require(lifecycle.timeline.firstIndex("response:\(aliceAttributes)"))
        let end = try #require(lifecycle.timeline.firstIndex("end:\(attributesActivity)"))
        #expect(response < end)
        #expect(await transport.requests(path: aliceAttributes).count == 1)
        #expect(await purchases.unsyncedAttributes().map(\.key) == ["favorite"])
        for _ in 0..<200 { await Task.yield() }
        #expect(lifecycle.endCount(attributesActivity) == 1)
    }

    @Test("失活时没有待发属性 → 不发 /attributes，申请的两个活动仍被结束")
    func resignActiveWithoutPendingEndsActivities() async throws {
        defer { AppStateProvider.setBackgrounded(false) }
        let (purchases, transport, lifecycle) = makeRig()
        await Purchases.awaitConfigured()

        postResignActive()
        #expect(lifecycle.beginCount(attributesActivity) == 1)
        #expect(lifecycle.beginCount(diagnosticsActivity) == 1)
        #expect(await eventually { lifecycle.endCount(attributesActivity) == 1 })
        #expect(await eventually { lifecycle.endCount(diagnosticsActivity) == 1 })
        #expect(await transport.requests(pathSuffix: "/attributes").isEmpty)
        #expect(await attributesSyncEvents(purchases).isEmpty, "没发请求不记 attributes_sync")
    }

    @Test("setter 之后立刻失活（不等缓冲落盘）→ 这一遍带上刚写的属性（审查 M3）")
    func resignRightAfterSetterIncludesLatestWrite() async throws {
        defer { AppStateProvider.setBackgrounded(false) }
        let (purchases, transport, _) = makeRig()
        purchases.setAttributes(["late": "x"])
        purchases.setATTConsentStatus("denied")
        postResignActive()

        #expect(await eventually { await transport.requests(path: aliceAttributes).count == 1 })
        let request = await transport.requests(path: aliceAttributes).first
        #expect(attributeKeys(request) == ["late", "$attConsentStatus"])
    }

    @Test("失活触发的那一遍记 attributes_sync.trigger = resign_active")
    func resignActivePassRecordsItsTrigger() async throws {
        defer { AppStateProvider.setBackgrounded(false) }
        let (purchases, transport, _) = makeRig()
        purchases.setAttributes(["favorite": "pizza"])
        #expect(await waitForBuffered(purchases, count: 1))

        postResignActive()
        #expect(await eventually { await purchases.unsyncedAttributes().isEmpty })
        #expect(await eventually { await attributesSyncTriggers(purchases, transport) == ["resign_active"] })
    }

    // MARK: 回前台（决定 3）

    @Test("回前台：有待发 → 在 GET /subscribers 返回之后发一次 /attributes（trigger = foreground）")
    func foregroundSyncsAfterRefresh() async throws {
        let (purchases, transport, lifecycle) = makeRig()
        purchases.setAttributes(["favorite": "pizza"])
        #expect(await waitForBuffered(purchases, count: 1))

        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.requests(path: aliceAttributes).count == 1 })
        let refreshed = try #require(lifecycle.timeline.firstIndex("response:\(aliceSubscribers)"))
        let posted = try #require(lifecycle.timeline.firstIndex("request:\(aliceAttributes)"))
        #expect(refreshed < posted)
        #expect(await transport.requests(path: aliceSubscribers).count == 1)

        #expect(await eventually { await attributesSyncEvents(purchases).count == 1 })
        let event = try #require(await attributesSyncEvents(purchases).first)
        #expect(event.fields["trigger"] == .string("foreground"))
        #expect(event.fields["outcome"] == .string("success"))
    }

    @Test("回前台：刷新失败（500）也照发 /attributes")
    func foregroundSyncsEvenWhenRefreshFails() async throws {
        let (purchases, transport, _) = makeRig()
        await transport.setStatuses([500], forPathSuffix: aliceSubscribers)
        purchases.setAttributes(["favorite": "pizza"])
        #expect(await waitForBuffered(purchases, count: 1))

        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.requests(path: aliceAttributes).count == 1 })
        #expect(await transport.requests(path: aliceSubscribers).count == 1)
        #expect(await eventually { await purchases.unsyncedAttributes().isEmpty })
    }

    @Test("回前台：没有待发 → 只刷新，不发 /attributes")
    func foregroundWithoutPendingSendsNothing() async throws {
        let (purchases, transport, _) = makeRig()
        await Purchases.awaitConfigured()

        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.requests(path: aliceSubscribers).count == 1 })
        for _ in 0..<300 { await Task.yield() }
        #expect(await transport.requests(pathSuffix: "/attributes").isEmpty)
    }

    @Test("身份门控待确认期间回前台 → 不拉 CustomerInfo，但照常补传属性（决定 8：门控不拦属性同步）")
    func foregroundSyncsAttributesWhileIdentityPending() async throws {
        let (purchases, transport, _) = makeRig(appUserID: nil, persistedAppUserID: "user-c",
                                                waitsForLogInBeforeSync: true)
        purchases.setAttributes(["favorite": "pizza"])
        #expect(await waitForBuffered(purchases, count: 1))

        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.requests(path: "/v1/subscribers/user-c/attributes").count == 1 })
        #expect(await transport.requests(path: "/v1/subscribers/user-c").isEmpty, "待确认期间不许按旧身份拉")
    }

    @Test("configure 时应用已经活跃 → 不发任何通知也跑一次回前台处理（拉一次 CustomerInfo、补传待发）")
    func configureWhileActiveRunsForegroundOnce() async throws {
        let directory = tempDirectory()
        // 上一次进程留下的待发（离开时没送达）。
        let store = SubscriberAttributesStore(directory: directory.appendingPathComponent("_attributes", isDirectory: true))
        _ = await store.set(["favorite": "pizza"], appUserID: "alice")

        let (purchases, transport, lifecycle) = makeRig(isApplicationActive: true, directory: directory)
        #expect(await eventually { await transport.requests(path: aliceAttributes).count == 1 })
        #expect(await transport.requests(path: aliceSubscribers).count == 1)
        let refreshed = try #require(lifecycle.timeline.firstIndex("response:\(aliceSubscribers)"))
        let posted = try #require(lifecycle.timeline.firstIndex("request:\(aliceAttributes)"))
        #expect(refreshed < posted)
        #expect(await eventually { await purchases.unsyncedAttributes().isEmpty })
    }

    @Test("configure 时应用不活跃 → 不跑回前台处理（不拉、不补传）")
    func configureWhileInactiveDoesNothing() async throws {
        let directory = tempDirectory()
        let store = SubscriberAttributesStore(directory: directory.appendingPathComponent("_attributes", isDirectory: true))
        _ = await store.set(["favorite": "pizza"], appUserID: "alice")

        let (purchases, transport, _) = makeRig(isApplicationActive: false, directory: directory)
        await Purchases.awaitConfigured()
        for _ in 0..<300 { await Task.yield() }
        #expect(await transport.requests(path: aliceSubscribers).isEmpty)
        #expect(await transport.requests(pathSuffix: "/attributes").isEmpty)
        #expect(await purchases.unsyncedAttributes().map(\.key) == ["favorite"])
    }

    // MARK: 按遍合并（决定 4）

    @Test("一遍在途时写入新属性并再次调用 → 第一遍结束后自动有第二遍带上新属性；第二次调用返回时待发为空；请求恰好 2 次")
    func queuedPassCarriesWritesMadeWhileInFlight() async throws {
        let (purchases, transport, _) = makeRig()
        purchases.setAttributes(["first": "1"])
        #expect(await waitForBuffered(purchases, count: 1))
        await transport.holdNextAttributesRequests(1)

        let firstCall = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await transport.heldCount == 1 })
        purchases.setAttributes(["second": "2"])
        let secondCall = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await purchases.attributeSyncQueueState().queuedJoined == 0 })

        await transport.releaseOne()
        #expect(await firstCall.value)
        #expect(await secondCall.value)
        #expect(await purchases.unsyncedAttributes().isEmpty)

        let requests = await transport.requests(pathSuffix: "/attributes")
        #expect(requests.count == 2)
        #expect(attributeKeys(requests.first) == ["first"])
        #expect(attributeKeys(requests.last) == ["second"])
        #expect(await purchases.attributeSyncQueueState() == (inFlight: false, queuedJoined: nil))
    }

    @Test("一遍在途时来三次调用（没有新属性）→ 只多跑一遍且不发请求（请求总数 1），三次调用都返回")
    func callsDuringInFlightShareOneQueuedPass() async throws {
        let (purchases, transport, _) = makeRig()
        purchases.setAttributes(["first": "1"])
        #expect(await waitForBuffered(purchases, count: 1))
        await transport.holdNextAttributesRequests(1)

        let firstCall = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await transport.heldCount == 1 })
        let joiners = (0..<3).map { _ in Task { await purchases.syncAttributes(trigger: .explicit) } }
        #expect(await eventually { await purchases.attributeSyncQueueState().queuedJoined == 2 })

        await transport.releaseOne()
        #expect(await firstCall.value)
        for joiner in joiners {
            #expect(await joiner.value == false, "排队的那一遍没有待发：不发请求，返回 false")
        }
        #expect(await transport.requests(pathSuffix: "/attributes").count == 1)
        #expect(await attributesSyncEvents(purchases).count == 1, "没发请求的那一遍不记事件")
        #expect(await purchases.attributeSyncQueueState() == (inFlight: false, queuedJoined: nil))
    }

    @Test("在途那遍可重试失败、期间有新写入与调用 → 排队的那一遍照常发出（新旧属性一起），调用返回")
    func queuedPassRunsAfterRetryableFailure() async throws {
        let (purchases, transport, _) = makeRig()
        await transport.setStatuses([500], forPathSuffix: "/attributes")
        purchases.setAttributes(["first": "1"])
        #expect(await waitForBuffered(purchases, count: 1))
        await transport.holdNextAttributesRequests(1)

        let firstCall = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await transport.heldCount == 1 })
        purchases.setAttributes(["second": "2"])
        let secondCall = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await purchases.attributeSyncQueueState().queuedJoined == 0 })

        await transport.releaseOne()
        #expect(await firstCall.value == false)
        #expect(await secondCall.value)
        let requests = await transport.requests(pathSuffix: "/attributes")
        #expect(requests.count == 2)
        #expect(attributeKeys(requests.last) == ["first", "second"])
        #expect(await purchases.unsyncedAttributes().isEmpty)
    }

    @Test("调用方任务被取消 → 在途那一遍照常完成并标记已同步；并入的其它调用正常返回")
    func cancelledCallerDoesNotCancelThePass() async throws {
        let (purchases, transport, lifecycle) = makeRig()
        purchases.setAttributes(["first": "1"])
        #expect(await waitForBuffered(purchases, count: 1))
        await transport.holdNextAttributesRequests(1)

        let cancelledCall = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await transport.heldCount == 1 })
        let joiner = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await purchases.attributeSyncQueueState().queuedJoined == 0 })

        cancelledCall.cancel()
        await transport.releaseOne()
        #expect(await cancelledCall.value, "这一遍跑在编排层自己的 Task 里：调用方被取消不影响它")
        #expect(await joiner.value == false)
        #expect(lifecycle.timeline.firstIndex(where: { $0.hasPrefix("cancelled:") }) == nil)
        #expect(await purchases.unsyncedAttributes().isEmpty)
        #expect(await transport.requests(pathSuffix: "/attributes").count == 1)
    }

    @Test("logIn：一遍在途时 logIn → 切换前旧身份的待发已发；每一遍用的是那一遍开始时的身份")
    func logInWaitsForInFlightPassAndUsesIdentityAtPassStart() async throws {
        let (purchases, transport, _) = makeRig(appUserID: nil)
        await Purchases.awaitConfigured()
        let anonymous = purchases.appUserID
        #expect(purchases.isAnonymous)
        let anonymousAttributes = "/v1/subscribers/\(anonymous)/attributes"

        purchases.setAttributes(["first": "1"])
        #expect(await waitForBuffered(purchases, count: 1))
        await transport.holdNextAttributesRequests(1)
        let explicitCall = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await transport.heldCount == 1 })

        purchases.setAttributes(["second": "2"])
        #expect(await waitForBuffered(purchases, count: 2)) // first 在途、尚未标记；second 新写
        let logIn = Task { try await purchases.logIn("alice") }
        #expect(await eventually { await purchases.attributeSyncQueueState().queuedJoined == 0 })

        await transport.releaseOne()
        #expect(await explicitCall.value)
        _ = try await logIn.value

        let paths = await transport.capturedRequests.compactMap { $0.url?.path }
            .filter { $0.hasSuffix("/attributes") || $0 == identifyPath }
        #expect(paths == [anonymousAttributes, anonymousAttributes, identifyPath, aliceAttributes])
        let attributeRequests = await transport.requests(pathSuffix: "/attributes")
        #expect(attributeKeys(attributeRequests[0]) == ["first"])
        #expect(attributeKeys(attributeRequests[1]) == ["second"], "logIn 切换前那一遍：开始时仍是旧身份，带上在途期间的新写入")
        #expect(attributeKeys(attributeRequests[2]) == ["first", "second"], "迁移到新身份后那一遍")

        let triggers = await attributesSyncEvents(purchases).map { $0.fields["trigger"] }
        #expect(triggers == [.string("explicit"), .string("login"), .string("login")])
    }

    /// 发布前审查 R1。写入链是串行的：先排 400 次写入（40 个键各改写 10 次），紧接着切身份。
    /// 切换前那一遍若不先等写入链落盘，读到的只是其中一段，剩下的会落进旧身份的桶里再也发不出去 ——
    /// 断言旧身份收到的每个键都是最后一次写的值。（只写一两条时竞态几乎总是写入先到，抓不住回归。）
    private static let burstKeys = 40
    private static let burstRounds = 10

    @MainActor
    private func writeBurst(_ purchases: Purchases) {
        for round in 0..<Self.burstRounds {
            for index in 0..<Self.burstKeys {
                purchases.setAttributes(["k\(index)": "v\(round)"])
            }
        }
    }

    /// 旧身份（alice）先后收到的属性按键合并，后到的覆盖先到的。
    private func latestValuesSentToAlice(_ transport: ScriptedTransport) async -> [String: String] {
        var latest: [String: String] = [:]
        for request in await transport.requests(path: aliceAttributes) {
            for key in attributeKeys(request) {
                latest[key] = attributeValue(request, key: key)
            }
        }
        return latest
    }

    @Test("logOut：一串写入之后不等落盘立刻 logOut → 登出前那一遍把它们全部发给旧身份（发布前审查 R1）")
    func logOutFlushesWritesMadeJustBefore() async throws {
        let (purchases, transport, _) = makeRig()
        writeBurst(purchases)
        _ = try await purchases.logOut()

        let latest = await latestValuesSentToAlice(transport)
        #expect(latest.count == Self.burstKeys)
        #expect(latest.values.allSatisfy { $0 == "v\(Self.burstRounds - 1)" }, "晚到的写入会留在旧身份的桶里再也发不出去")
        #expect(purchases.isAnonymous)
    }

    @Test("logIn（具名 → 具名）：一串写入之后不等落盘立刻 logIn → 切换前那一遍把它们全部发给旧身份，不带到新身份")
    func logInFlushesWritesMadeJustBefore() async throws {
        let (purchases, transport, _) = makeRig()
        writeBurst(purchases)
        _ = try await purchases.logIn("bob")

        let latest = await latestValuesSentToAlice(transport)
        #expect(latest.count == Self.burstKeys)
        #expect(latest.values.allSatisfy { $0 == "v\(Self.burstRounds - 1)" })
        #expect(await transport.requests(path: "/v1/subscribers/bob/attributes").isEmpty, "两个具名用户之间不迁移")
    }

    // MARK: 不再用属性响应更新 CustomerInfo（决定 5）

    @Test("属性同步成功 → 宿主收不到 CustomerInfo 回调、缓存不被属性响应改写、没有 customer_info_updated")
    func successfulSyncDoesNotPublishCustomerInfo() async throws {
        let (purchases, transport, _) = makeRig()
        let delegate = CountingDelegate()
        purchases.delegate = delegate
        purchases.setAttributes(["favorite": "pizza"])
        #expect(await waitForBuffered(purchases, count: 1))

        #expect(await purchases.syncAttributes(trigger: .explicit))
        #expect(await transport.requests(path: aliceAttributes).count == 1)
        for _ in 0..<300 { await Task.yield() }

        #expect(delegate.received == 0)
        #expect(purchases.cachedCustomerInfo == nil)
        #expect((try? await purchases.customerInfo(fetchPolicy: .cachedOnly)) == nil, "属性响应没有写进缓存")
        let updates = await purchases.diagnosticsRecorder.queuedEvents()
            .filter { $0.type == DiagnosticsEventType.customerInfoUpdated }
        #expect(updates.isEmpty)
    }

    // MARK: 墓碑保留（决定 6）

    @Test("墓碑：setIDFA(nil) 同步后再 setIDFA(nil) → 没有新待发、不发请求；写入一个值再写空 → 各发一次")
    func syncedTombstoneIsNotResent() async throws {
        let (purchases, transport, _) = makeRig()
        purchases.setIDFA(nil)
        #expect(await waitForBuffered(purchases, count: 1))
        #expect(await purchases.syncAttributes(trigger: .explicit))
        #expect(await transport.requests(path: aliceAttributes).count == 1)

        purchases.setIDFA(nil)
        #expect(await purchases.unsyncedAttributes().isEmpty)
        #expect(await purchases.syncAttributes(trigger: .explicit) == false)
        #expect(await transport.requests(path: aliceAttributes).count == 1)

        purchases.setIDFA("AAAA-BBBB")
        #expect(await purchases.unsyncedAttributes().map(\.value) == ["AAAA-BBBB"])
        #expect(await purchases.syncAttributes(trigger: .explicit))
        purchases.setIDFA(nil)
        #expect(await purchases.unsyncedAttributes().map(\.isTombstone) == [true])
        #expect(await purchases.syncAttributes(trigger: .explicit))

        let requests = await transport.requests(path: aliceAttributes)
        #expect(requests.count == 3)
        #expect(attributeValue(requests[1], key: "$idfa") == "AAAA-BBBB")
        #expect(attributeValue(requests[2], key: "$idfa") == "")
    }

    // MARK: attributes_sync（决定 7）

    @Test("attributes_sync：成功 / 400 / 500 各一条，count、outcome、trigger、级别与失败原因字段正确")
    func attributesSyncEventPerPassWithRequest() async throws {
        let (purchases, transport, _) = makeRig()
        await transport.setStatuses([200, 400, 500], forPathSuffix: "/attributes")

        purchases.setAttributes(["a": "1", "b": "2"])
        #expect(await waitForBuffered(purchases, count: 2))
        #expect(await purchases.syncAttributes(trigger: .explicit))
        purchases.setAttributes(["c": "3"])
        #expect(await waitForBuffered(purchases, count: 1))
        #expect(await purchases.syncAttributes(trigger: .explicit) == false) // 400：确定性拒绝，标记已同步
        purchases.setAttributes(["d": "4"])
        #expect(await waitForBuffered(purchases, count: 1))
        #expect(await purchases.syncAttributes(trigger: .explicit) == false) // 500：保留待发

        let events = await attributesSyncEvents(purchases)
        #expect(events.count == 3)
        let success = try #require(events.first)
        #expect(success.level == DiagnosticsLevel.info)
        #expect(success.fields["count"] == .int(2))
        #expect(success.fields["outcome"] == .string("success"))
        #expect(success.fields["trigger"] == .string("explicit"))
        #expect(success.fields["joined"] == .int(0))
        #expect(success.fields["backgrounded"] == .bool(false))
        #expect(success.fields["duration_ms"] != nil)
        #expect(success.fields["error_class"] == nil)

        let rejected = events[1]
        #expect(rejected.level == DiagnosticsLevel.error)
        #expect(rejected.fields["count"] == .int(1))
        #expect(rejected.fields["outcome"] == .string("rejected"))
        #expect(rejected.fields["status"] == .int(400))
        #expect(rejected.fields["error_class"] == .string("client"))
        #expect(rejected.fields["error_code"] != nil)

        let retryable = events[2]
        #expect(retryable.level == DiagnosticsLevel.error)
        #expect(retryable.fields["outcome"] == .string("retryable"))
        #expect(retryable.fields["status"] == .int(500))
        #expect(retryable.fields["error_class"] == .string("server"))
        #expect(await purchases.unsyncedAttributes().map(\.key) == ["d"])
    }

    @Test("attributes_sync.joined：一遍在途时来三次调用且有新写入 → 排队那一遍记 trigger = 第一次调用、joined = 2")
    func attributesSyncJoinedCountsMergedCalls() async throws {
        let (purchases, transport, _) = makeRig()
        purchases.setAttributes(["first": "1"])
        #expect(await waitForBuffered(purchases, count: 1))
        await transport.holdNextAttributesRequests(1)

        let firstCall = Task { await purchases.syncAttributes(trigger: .explicit) }
        #expect(await eventually { await transport.heldCount == 1 })
        purchases.setAttributes(["second": "2"])
        let queuedFirst = Task { await purchases.syncAttributes(trigger: .foreground) }
        #expect(await eventually { await purchases.attributeSyncQueueState().queuedJoined == 0 })
        let joiners = [Task { await purchases.syncAttributes(trigger: .explicit) },
                       Task { await purchases.syncAttributes(trigger: .login) }]
        #expect(await eventually { await purchases.attributeSyncQueueState().queuedJoined == 2 })

        await transport.releaseOne()
        _ = await firstCall.value
        #expect(await queuedFirst.value)
        for joiner in joiners { #expect(await joiner.value) }

        let events = await attributesSyncEvents(purchases)
        #expect(events.count == 2)
        #expect(events[0].fields["joined"] == .int(0))
        #expect(events[1].fields["trigger"] == .string("foreground"))
        #expect(events[1].fields["joined"] == .int(2))
        #expect(events[1].fields["count"] == .int(1))
    }
}
}

// MARK: - 后台任务配对状态机（决定 2；发布前审查 S1）

/// 线程安全的结束记录：每次真正结束后台任务记一条标识。
private final class EndRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func record(_ identifier: Int) {
        lock.lock()
        storage.append(identifier)
        lock.unlock()
    }

    var ended: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 生产实现（UIKit）里只有「申请」与「真正结束」两步碰 UIKit，配对逻辑全在 `BackgroundActivityHandle`，这里直接测它。
@Suite("0.5.2 · 后台任务配对状态机（ADR 0248 决定 2）")
struct BackgroundActivityHandleTests {

    @Test("正常：登记标识 → 工作做完结束一次；过期回调随后再来是空操作")
    func endsOnceAfterAttach() {
        let recorder = EndRecorder()
        let handle = BackgroundActivityHandle<Int> { recorder.record($0) }
        handle.attach(7)
        #expect(recorder.ended.isEmpty)
        handle.end()
        handle.end()
        #expect(recorder.ended == [7])
    }

    @Test("过期回调先于申请返回：登记标识时立刻结束，不留一个要等工作做完才结束的任务")
    func expirationBeforeAttachEndsOnAttach() {
        let recorder = EndRecorder()
        let handle = BackgroundActivityHandle<Int> { recorder.record($0) }
        handle.end()                    // 过期回调在 begin 返回之前被同步调用：还没有标识可结束
        #expect(recorder.ended.isEmpty)
        handle.attach(7)                // begin 返回
        #expect(recorder.ended == [7])
        handle.end()                    // 工作做完
        #expect(recorder.ended == [7])
    }

    @Test("工作做完与过期回调从多个线程同时到达：只结束一次")
    func concurrentEndsEndOnce() async {
        for _ in 0..<200 {
            let recorder = EndRecorder()
            let handle = BackgroundActivityHandle<Int> { recorder.record($0) }
            handle.attach(1)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 { group.addTask { handle.end() } }
            }
            #expect(recorder.ended == [1])
        }
    }
}
