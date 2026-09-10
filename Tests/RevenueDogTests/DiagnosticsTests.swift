//
//  DiagnosticsTests.swift
//  客户端诊断管线（ADR 0028 / docs/plan/sdk-diagnostics.md §1–§2）。
//
//  五组：
//  1. 队列（JSONL）：上限 500 条 / 256 KB、丢最旧 + `queue_overflow` 告警（那条自己不再触发）、
//     损坏行跳过不崩。
//  2. 采样与触发：`sample_rate_info` 只作用于 info；队列 ≥ 20 条触发；error 2s 防抖。
//  3. 上传器响应处置（契约 §1.2 逐字）：202 出队 / 401 丢批停 1h / 其余 4xx（含 413）丢批 /
//     429·5xx·网络错误保留 + 指数退避 30s×2 上限 1h / 同一时刻单飞。
//  4. 开关：`diagnosticsEnabled = false` → 不记不发 + 清空队列文件。
//  5. 端到端：一次购买产出的事件序列与字段合规；上报失败 → 事件保留 → 恢复后补发。
//

import Foundation
import Testing
@testable import RevenueDog

private let diagnosticsPath = "/v1/diagnostics/events"
private let receiptsPath = "/v1/receipts"

// MARK: - 夹具

private func tempQueueURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogDiagnosticsTests/\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(DiagnosticsQueue.fileName, isDirectory: false)
}

/// 可推进的时钟：退避窗口是「时间」而不是「睡眠」，测试必须能把表拨快。
private final class MutableClock: @unchecked Sendable {

    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_789_000_000)) { self.value = value }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }
}

/// 固定随机数（采样断言用）。
private final class FixedRandom: @unchecked Sendable {

    private let lock = NSLock()
    private var value: Double

    init(_ value: Double) { self.value = value }

    var next: Double {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ value: Double) {
        lock.lock(); self.value = value; lock.unlock()
    }
}

/// 卡住的传输层：`send` 挂起直到 `release()`，用来构造「上传在飞」的窗口。
private actor GatedTransport: HTTPTransport {

    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        callCount += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return HTTPTransportResponse(statusCode: 202, headers: [:],
                                     body: Data(#"{"accepted":1,"dropped":0}"#.utf8))
    }

    func release() {
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}

private struct DiagnosticsRig {
    let recorder: DiagnosticsRecorder
    let uploader: DiagnosticsUploader
    let queue: DiagnosticsQueue
    let transport: MockTransport
    let clock: MutableClock
    let random: FixedRandom
    let scheduler: RecordingDelayScheduler
    let fileURL: URL
}

private func makeRig(fileURL: URL = tempQueueURL(),
                     enabled: Bool = true,
                     sampleRateInfo: Double? = nil,
                     appUserID: String? = "tester") -> DiagnosticsRig {
    let transport = MockTransport()
    let clock = MutableClock()
    let random = FixedRandom(0.5)
    let scheduler = RecordingDelayScheduler()
    let httpClient = HTTPClient(apiKey: "pk_test_0123456789",
                                baseURL: URL(string: "https://api.revenuedog.com")!,
                                transport: transport,
                                retryPolicy: .none,
                                scheduler: NoDelayScheduler(),
                                systemInfoProvider: { .fixture() })
    let queue = DiagnosticsQueue(fileURL: fileURL)
    let uploader = DiagnosticsUploader(httpClient: httpClient,
                                       queue: queue,
                                       sessionID: "session-1234",
                                       installIDProvider: { "install-1234" },
                                       systemInfoProvider: { .fixture() },
                                       localeProvider: { "zh-Hans_CN" },
                                       now: { clock.now })
    let recorder = DiagnosticsRecorder(queue: queue,
                                       uploader: uploader,
                                       settings: InMemoryDiagnosticsSettingsStorage(sampleRateInfo: sampleRateInfo),
                                       enabled: enabled,
                                       appUserIDProvider: { appUserID },
                                       scheduler: scheduler,
                                       startsPeriodicFlush: false,
                                       now: { clock.now },
                                       random: { random.next })
    return DiagnosticsRig(recorder: recorder, uploader: uploader, queue: queue, transport: transport,
                          clock: clock, random: random, scheduler: scheduler, fileURL: fileURL)
}


/// 待发总数 = 当前队列 + 所有在飞文件（轮转之后事件在在飞文件里，只看 queue.count 会误判成「丢了」）。
private func pendingCount(_ rig: DiagnosticsRig) async -> Int {
    let inflight = rig.queue.inflightFiles().reduce(0) { $0 + DiagnosticsQueue.lines(at: $1).count }
    return await rig.queue.count + inflight
}

private func event(_ index: Int,
                   type: String = DiagnosticsEventType.purchaseStarted,
                   level: String = DiagnosticsLevel.info) -> DiagnosticsEvent {
    DiagnosticsEvent.make(type: type, level: level,
                          fields: ["product_id": .string("com.demo.monthly"), "attempt": .int(index)],
                          id: "id-\(index)",
                          appUserID: "tester",
                          seq: Int64(index),
                          tsMs: 1_789_000_000_000 + Int64(index))
}

private func waitUntil(timeoutMs: Int = 3000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 10) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

// MARK: - 1. 队列

@Suite("诊断 · JSONL 队列")
struct DiagnosticsQueueTests {

    @Test("上限 500 条：超限丢最旧，队首推进、队尾保留")
    func dropsOldestBeyondEventCap() async throws {
        let queue = DiagnosticsQueue(fileURL: tempQueueURL())
        for index in 0..<(DiagnosticsQueue.maxEvents + 5) {
            let dropped = await queue.append(event(index))
            #expect(dropped == (index >= DiagnosticsQueue.maxEvents ? 1 : 0))
        }
        let events = await queue.allEvents()
        #expect(events.count == DiagnosticsQueue.maxEvents)
        #expect(events.first?.id == "id-5")                                   // 最旧的 5 条被丢了
        #expect(events.last?.id == "id-\(DiagnosticsQueue.maxEvents + 4)")
    }

    @Test("上限 256 KB：字节数超限同样丢最旧，且落盘文件不超上限")
    func dropsOldestBeyondByteCap() async throws {
        let url = tempQueueURL()
        let queue = DiagnosticsQueue(fileURL: url)
        // 每条 ~1.2 KB（单条上限 2 KB 之内）→ 200 条足以撞上 256 KB。
        let filler = String(repeating: "x", count: 200)
        for index in 0..<400 {
            let big = DiagnosticsEvent.make(
                type: DiagnosticsEventType.sdkWarning,
                level: DiagnosticsLevel.warn,
                fields: Dictionary(uniqueKeysWithValues: (0..<6).map { ("f\($0)", DiagnosticsFieldValue.string(filler)) }),
                id: "big-\(index)",
                tsMs: 1_789_000_000_000,
            )
            _ = await queue.append(big)
        }
        #expect(await queue.bytes <= DiagnosticsQueue.maxBytes)
        #expect(await queue.count < 400)
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk.count <= DiagnosticsQueue.maxBytes)
    }

    @Test("单条超过 2 KB 直接不入队（服务端会计入 dropped，端上就别发）")
    func rejectsOversizedEvent() async throws {
        let queue = DiagnosticsQueue(fileURL: tempQueueURL())
        let huge = DiagnosticsEvent(id: "huge", tsMs: 1, appUserID: "tester", seq: 1,
                                    type: "x", level: "info",
                                    fields: Dictionary(uniqueKeysWithValues: (0..<40).map {
                                        ("f\($0)", DiagnosticsFieldValue.string(String(repeating: "y", count: 200)))
                                    }))
        _ = await queue.append(huge)
        #expect(await queue.count == 0)
    }

    @Test("JSONL：一行一条、可回读；损坏行跳过不崩，且重写后文件里不再有坏行")
    func skipsCorruptedLines() async throws {
        let url = tempQueueURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let good1 = try DiagnosticsCoding.encoder.encode(event(1))
        let good2 = try DiagnosticsCoding.encoder.encode(event(2))
        var payload = Data()
        payload.append(good1); payload.append(UInt8(ascii: "\n"))
        payload.append(Data("{\"id\": \"broken\", ".utf8)); payload.append(UInt8(ascii: "\n"))  // 半截写入
        payload.append(Data("这不是 JSON".utf8)); payload.append(UInt8(ascii: "\n"))
        payload.append(good2); payload.append(UInt8(ascii: "\n"))
        try payload.write(to: url)

        let queue = DiagnosticsQueue(fileURL: url)
        let events = await queue.allEvents()
        #expect(events.map(\.id) == ["id-1", "id-2"])
        #expect(await queue.corruptedLinesSkipped == 2)

        // 坏行已被重写掉：新实例读到的仍然只有两条，且文件里只剩两行。
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
    }

    @Test("出队只摘队首 N 条；期间新入队的在队尾不受影响")
    func removesPrefixOnly() async throws {
        let queue = DiagnosticsQueue(fileURL: tempQueueURL())
        for index in 0..<5 { _ = await queue.append(event(index)) }
        let batch = await queue.peek(maxCount: 3, maxBytes: 64 * 1024)
        #expect(batch.map(\.id) == ["id-0", "id-1", "id-2"])
        _ = await queue.append(event(99))
        await queue.remove(count: batch.count)
        #expect(await queue.allEvents().map(\.id) == ["id-3", "id-4", "id-99"])
    }

    @Test("字段值域：标量与字符串数组可往返；字符串按 200 截断")
    func encodesFieldValues() async throws {
        let long = String(repeating: "z", count: 500)
        let source = DiagnosticsEvent.make(type: "t", level: "info", fields: [
            "s": .string(long), "i": .int(7), "d": .double(1.5), "b": .bool(true),
            "a": .strings([long, "ok"]), "nil_dropped": nil,
        ], id: "e", tsMs: 1)
        let data = try DiagnosticsCoding.encoder.encode(source)
        let back = try DiagnosticsCoding.decoder.decode(DiagnosticsEvent.self, from: data)
        #expect(back == source)
        #expect(back.fields["nil_dropped"] == nil)
        #expect(back.fields["s"] == .string(String(repeating: "z", count: 200)))
        #expect(back.fields["a"] == .strings([String(repeating: "z", count: 200), "ok"]))
        #expect(back.fields["i"] == .int(7))
        #expect(back.fields["b"] == .bool(true))
    }
}

// MARK: - 2. 采样与触发

@Suite("诊断 · 采样与上传触发")
struct DiagnosticsRecorderTests {

    @Test("溢出告警：丢最旧时补一条 sdk_warning{queue_overflow}，且那一条自己不再触发溢出")
    func recordsQueueOverflowWarningExactlyOnce() async throws {
        let url = tempQueueURL()
        // 先把队列灌到刚好满。
        let seed = DiagnosticsQueue(fileURL: url)
        for index in 0..<DiagnosticsQueue.maxEvents { _ = await seed.append(event(index)) }

        let rig = makeRig(fileURL: url)
        await rig.transport.failTransportAlways()   // 不让上传把队列清空，断言的是队列本身
        await rig.recorder.record(DiagnosticsEventType.purchaseStarted,
                                  fields: ["product_id": .string("com.demo.monthly")])

        let events = await rig.recorder.queuedEvents()
        #expect(events.count == DiagnosticsQueue.maxEvents)
        let overflows = events.filter {
            $0.type == DiagnosticsEventType.sdkWarning
                && $0.fields["code"] == .string(DiagnosticsWarningCode.queueOverflow)
        }
        #expect(overflows.count == 1)                       // 不自激：告警本身没再生一条告警
        #expect(events.last?.type == DiagnosticsEventType.sdkWarning)
        #expect(overflows.first?.level == DiagnosticsLevel.warn)
    }

    @Test("采样只作用于 info：rate=0 时 info 全丢，warn / error 一条不少")
    func samplingAppliesToInfoOnly() async throws {
        let rig = makeRig(sampleRateInfo: 0)
        await rig.transport.failTransportAlways()
        await rig.recorder.start()
        #expect(await rig.recorder.currentSampleRateInfo == 0)

        for _ in 0..<5 {
            await rig.recorder.record(DiagnosticsEventType.purchaseStarted)
            await rig.recorder.record(DiagnosticsEventType.sdkWarning, level: DiagnosticsLevel.warn,
                                      fields: ["code": .string("x")])
            await rig.recorder.record(DiagnosticsEventType.httpError, level: DiagnosticsLevel.error)
        }
        let events = await rig.recorder.queuedEvents()
        #expect(events.filter { $0.level == DiagnosticsLevel.info }.isEmpty)
        #expect(events.filter { $0.level == DiagnosticsLevel.warn }.count == 5)
        #expect(events.filter { $0.level == DiagnosticsLevel.error }.count == 5)
    }

    @Test("采样是概率闸：rate=0.5 时 random 落在阈值内保留、之外丢弃")
    func samplingUsesRandomThreshold() async throws {
        let rig = makeRig(sampleRateInfo: 0.5)
        await rig.transport.failTransportAlways()
        await rig.recorder.start()

        rig.random.set(0.9)                                  // 0.9 >= 0.5 → 丢
        await rig.recorder.record(DiagnosticsEventType.purchaseStarted)
        #expect(await rig.recorder.queuedCount() == 0)

        rig.random.set(0.1)                                  // 0.1 < 0.5 → 留
        await rig.recorder.record(DiagnosticsEventType.purchaseStarted)
        #expect(await rig.recorder.queuedCount() == 1)
    }

    @Test("队列 ≥ 20 条触发上传：第 19 条不发，第 20 条发")
    func flushesAtTwentyEvents() async throws {
        let rig = makeRig()
        await rig.transport.enqueue(.json(#"{"accepted":20,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)
        for index in 0..<(DiagnosticsRecorder.uploadThreshold - 1) {
            await rig.recorder.record(DiagnosticsEventType.purchaseStarted,
                                      fields: ["attempt": .int(index)])
        }
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 0)

        await rig.recorder.record(DiagnosticsEventType.purchaseStarted)
        #expect(await waitUntil { await rig.transport.callCount(forPath: diagnosticsPath) == 1 })
        #expect(await waitUntil { await pendingCount(rig) == 0 })
    }

    @Test("error 级事件 2s 防抖：退避窗口就是 2s，窗口结束后发一次")
    func errorSchedulesTwoSecondDebounce() async throws {
        let rig = makeRig()
        await rig.transport.enqueue(.json(#"{"accepted":1,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)
        await rig.recorder.record(DiagnosticsEventType.httpError, level: DiagnosticsLevel.error,
                                  fields: ["path": .string("/v1/subscribers/*"), "status": .int(500)])

        #expect(await waitUntil { await rig.scheduler.recorded == [DiagnosticsRecorder.errorDebounce] })
        #expect(await waitUntil { await rig.transport.callCount(forPath: diagnosticsPath) == 1 })
    }

    @Test("info 级单条事件不触发上传（不到 20 条、也没有 error 防抖）")
    func singleInfoEventDoesNotUpload() async throws {
        let rig = makeRig()
        await rig.recorder.record(DiagnosticsEventType.purchaseStarted)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 0)
        #expect(await rig.scheduler.recorded.isEmpty)
    }

    @Test("diagnosticsEnabled = false：不记不发，并清空已有队列文件")
    func disabledClearsQueueAndRecordsNothing() async throws {
        let url = tempQueueURL()
        let seed = DiagnosticsQueue(fileURL: url)
        for index in 0..<10 { _ = await seed.append(event(index)) }
        #expect(FileManager.default.fileExists(atPath: url.path))

        let rig = makeRig(fileURL: url, enabled: false)
        await rig.recorder.start()
        #expect(!FileManager.default.fileExists(atPath: url.path))

        await rig.recorder.record(DiagnosticsEventType.purchaseStarted)
        await rig.recorder.record(DiagnosticsEventType.httpError, level: DiagnosticsLevel.error)
        #expect(await rig.recorder.queuedCount() == 0)
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 0)
    }
}

// MARK: - 3. 上传器（契约 §1.2 响应处置）

@Suite("诊断 · 上传响应处置")
struct DiagnosticsUploaderTests {

    private func filled(_ rig: DiagnosticsRig, count: Int = 3) async {
        for index in 0..<count { _ = await rig.queue.append(event(index)) }
    }

    @Test("202：出队该批，落 sample_rate_info，退避归零")
    func acceptedRemovesBatchAndAppliesSampleRate() async throws {
        let rig = makeRig()
        await filled(rig)
        await rig.transport.enqueue(.json(#"{"accepted":3,"dropped":0,"sample_rate_info":0.25}"#,
                                          statusCode: 202), forPath: diagnosticsPath)

        let result = await rig.recorder.flush()
        #expect(result.uploaded == 3)
        #expect(await pendingCount(rig) == 0)
        #expect(await rig.uploader.backoffSeconds == 0)
        #expect(await rig.recorder.currentSampleRateInfo == 0.25)
    }

    @Test("上行信封：install_id / app_user_id / sandbox / sent_at_ms / events 齐全，系统信息只走请求头")
    func uploadBodyMatchesContract() async throws {
        let rig = makeRig()
        await filled(rig, count: 2)
        await rig.transport.enqueue(.json(#"{"accepted":2,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)
        _ = await rig.recorder.flush()

        let request = try #require(await rig.transport.requests(forPath: diagnosticsPath).first)
        let httpBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["schema_version"] as? Int == 1)
        // install_id 必须非空：服务端对缺失/空回 400，而 400 会被当成确定性 4xx 丢批 ——
        // 一旦这里发空，这台设备的诊断就会静默消失。
        let installID = try #require(body["install_id"] as? String)
        #expect(!installID.isEmpty)
        #expect(installID == "install-1234")
        #expect(body["session_id"] as? String == "session-1234")
        #expect(body["sandbox"] as? Bool == false)
        #expect(body["is_debug"] as? Bool == true)
        #expect(body["locale"] as? String == "zh-Hans_CN")
        #expect(body["sent_at_ms"] as? Int64 != nil || body["sent_at_ms"] as? Int != nil)
        // §6-2：`app_user_id` **不在信封里**，下沉到每条事件。
        #expect(body["app_user_id"] == nil)
        let wireEvents = try #require(body["events"] as? [[String: Any]])
        #expect(wireEvents.count == 2)
        #expect(wireEvents.allSatisfy { $0["app_user_id"] as? String == "tester" })
        #expect(wireEvents.allSatisfy { $0["seq"] != nil })
        // 系统信息只从既有请求头取，body 不重复（契约 §1.1）。
        #expect(body["platform"] == nil && body["sdk_version"] == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pk_test_0123456789")
        #expect(request.value(forHTTPHeaderField: "X-Platform") == "iOS")
        #expect(request.value(forHTTPHeaderField: "X-Version") == SystemInfo.sdkVersionString)
    }

    @Test("401 / 403：丢弃该批并停 1 小时；窗口内不再发，窗口过后恢复", arguments: [401, 403])
    func authFailureDropsBatchAndSuspendsOneHour(status: Int) async throws {
        let rig = makeRig()
        await filled(rig)
        await rig.transport.enqueue(.failure(statusCode: status), forPath: diagnosticsPath)

        let first = await rig.recorder.flush()
        #expect(first.dropped == 3)
        #expect(await pendingCount(rig) == 0)                       // 丢批
        #expect(await rig.uploader.isSuspended)

        await filled(rig)
        rig.clock.advance(DiagnosticsUploader.authSuspension - 1)
        #expect(await rig.recorder.flush().skipped == .backoff)   // 还在停摆窗口内
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 1)

        rig.clock.advance(2)
        await rig.transport.clearStubs(forPath: diagnosticsPath)
        await rig.transport.enqueue(.json(#"{"accepted":3,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)
        #expect(await rig.recorder.flush().uploaded == 3)
    }

    @Test("其余 4xx（含 413 body 超限）：丢弃该批，不退避", arguments: [400, 413, 422])
    func deterministicFourXXDropsBatch(status: Int) async throws {
        let rig = makeRig()
        await filled(rig)
        await rig.transport.enqueue(.failure(statusCode: status), forPath: diagnosticsPath)

        let result = await rig.recorder.flush()
        #expect(result.dropped == 3)
        #expect(await pendingCount(rig) == 0)
        #expect(await rig.uploader.backoffSeconds == 0)
        #expect(!(await rig.uploader.isSuspended))
    }

    @Test("429 / 5xx / 网络错误：保留队列并退避", arguments: [429, 500, 503])
    func transientFailuresKeepQueue(status: Int) async throws {
        let rig = makeRig()
        await filled(rig)
        await rig.transport.enqueue(.failure(statusCode: status), forPath: diagnosticsPath)

        _ = await rig.recorder.flush()
        #expect(await pendingCount(rig) == 3)                        // 一条都没丢
        #expect(await rig.uploader.backoffSeconds == DiagnosticsUploader.initialBackoff)
    }

    @Test("传输层错误（断网）同样保留队列并退避")
    func networkErrorKeepsQueue() async throws {
        let rig = makeRig()
        await filled(rig)
        await rig.transport.failTransportAlways()

        _ = await rig.recorder.flush()
        #expect(await pendingCount(rig) == 3)
        #expect(await rig.uploader.backoffSeconds == 30)
    }

    @Test("退避序列：30s 起、每次 ×2、上限 1h")
    func backoffSequenceDoublesAndCaps() async throws {
        let rig = makeRig()
        await filled(rig)
        await rig.transport.enqueue(.failure(statusCode: 503), forPath: diagnosticsPath)   // 粘住

        var observed: [TimeInterval] = []
        for _ in 0..<9 {
            _ = await rig.recorder.flush()
            let delay = await rig.uploader.backoffSeconds
            observed.append(delay)
            rig.clock.advance(delay)                                // 把表拨到窗口之后再试
        }
        #expect(observed == [30, 60, 120, 240, 480, 960, 1920, 3600, 3600])
        #expect(await pendingCount(rig) == 3)
    }

    @Test("退避窗口内的调用直接被跳过，不打请求")
    func backoffWindowSkipsUpload() async throws {
        let rig = makeRig()
        await filled(rig)
        await rig.transport.enqueue(.failure(statusCode: 500), forPath: diagnosticsPath)

        _ = await rig.recorder.flush()
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 1)
        #expect(await rig.recorder.flush().skipped == .backoff)
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 1)
    }

    @Test("同一时刻只有一个上传在飞")
    func onlyOneUploadInFlight() async throws {
        let gate = GatedTransport()
        let httpClient = HTTPClient(apiKey: "pk_test_0123456789",
                                    baseURL: URL(string: "https://api.revenuedog.com")!,
                                    transport: gate,
                                    retryPolicy: .none,
                                    scheduler: NoDelayScheduler(),
                                    systemInfoProvider: { .fixture() })
        let queue = DiagnosticsQueue(fileURL: tempQueueURL())
        for index in 0..<3 { _ = await queue.append(event(index)) }
        let uploader = DiagnosticsUploader(httpClient: httpClient,
                                           queue: queue,
                                           sessionID: "session-1234",
                                           installIDProvider: { "install-1234" },
                                           systemInfoProvider: { .fixture() })

        let inFlight = Task { await uploader.upload() }
        #expect(await waitUntil { await gate.callCount == 1 })      // 第一发已经挂在传输层上

        let second = await uploader.upload()
        #expect(second.skipped == .inFlight)                        // 单飞闸生效
        #expect(await gate.callCount == 1)

        await gate.release()
        _ = await inFlight.value
    }

    @Test("上报失败 → 事件保留 → 后端恢复后补发（M4 风格）")
    func retainsEventsAndResendsAfterRecovery() async throws {
        let rig = makeRig()
        for index in 0..<5 { _ = await rig.queue.append(event(index)) }
        await rig.transport.enqueue(.failure(statusCode: 503), forPath: diagnosticsPath)

        _ = await rig.recorder.flush()
        #expect(await pendingCount(rig) == 5)                         // 一条不丢

        rig.clock.advance(DiagnosticsUploader.initialBackoff + 1)   // 退避窗口过去
        await rig.transport.clearStubs(forPath: diagnosticsPath)
        await rig.transport.enqueue(.json(#"{"accepted":5,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)
        let result = await rig.recorder.flush()
        #expect(result.uploaded == 5)
        #expect(result.recoveredFailureCount == 1)
        // 队列里只可能剩那条「上传曾经失败过」的告警（§6-13），原来的五条一条不剩。
        let remaining = await rig.recorder.queuedEvents()
        #expect(remaining.allSatisfy {
            $0.fields["code"] == .string(DiagnosticsWarningCode.diagUploadFailed)
        })

        // 补发的确实是原来那五条（id 是服务端 INSERT OR IGNORE 的幂等键）。
        let requests = await rig.transport.requests(forPath: diagnosticsPath)
        let bodies = requests.compactMap { request -> [[String: Any]]? in
            guard let data = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["events"] as? [[String: Any]]
        }
        let resent = try #require(bodies.first { $0.count == 5 })
        #expect(resent.compactMap { $0["id"] as? String } == ["id-0", "id-1", "id-2", "id-3", "id-4"])
    }
}

// MARK: - 4. 轮转与服务端指令（§6-8 / §6-9 / §6-10）

@Suite("诊断 · 轮转与服务端指令")
struct DiagnosticsRotationTests {

    @Test("轮转：上传在飞期间新入队的事件不会被这一批的成功给截掉")
    func rotationKeepsEventsEnqueuedDuringFlight() async throws {
        let url = tempQueueURL()
        let queue = DiagnosticsQueue(fileURL: url)
        for index in 0..<3 { _ = await queue.append(event(index)) }

        // 轮转 = 把当前队列改名成在飞文件，新事件写进一份全新的 queue.jsonl。
        let inflight = try #require(await queue.rotate())
        #expect(await queue.count == 0)
        _ = await queue.append(event(100))
        _ = await queue.append(event(101))

        #expect(DiagnosticsQueue.lines(at: inflight).count == 3)     // 在飞的还是原来那三条
        #expect(await queue.allEvents().map(\.id) == ["id-100", "id-101"])

        // 在飞那批成功 → 只删在飞文件，新队列一条不动。
        DiagnosticsQueue.removeFile(at: inflight)
        #expect(await queue.allEvents().map(\.id) == ["id-100", "id-101"])
        #expect(queue.inflightFiles().isEmpty)
    }

    @Test("在飞文件失败后留在盘上，下次 upload 先补发它")
    func leftoverInflightIsResentFirst() async throws {
        let rig = makeRig()
        for index in 0..<3 { _ = await rig.queue.append(event(index)) }
        await rig.transport.enqueue(.failure(statusCode: 503), forPath: diagnosticsPath)

        _ = await rig.recorder.flush()
        #expect(rig.queue.inflightFiles().count == 1)                // 没删，等下次
        #expect(await rig.queue.count == 0)                          // 当前队列已轮转走
        #expect(await pendingCount(rig) == 3)                        // 一条不丢，只是搬了个家

        // 期间又来了新事件 —— 它们进新队列，不影响在飞那批。
        _ = await rig.queue.append(event(50))

        rig.clock.advance(DiagnosticsUploader.initialBackoff + 1)
        await rig.transport.clearStubs(forPath: diagnosticsPath)
        await rig.transport.enqueue(.json(#"{"accepted":4,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)
        let result = await rig.recorder.flush()
        #expect(result.uploaded == 4)                                // 3 条补发 + 1 条新的
        #expect(rig.queue.inflightFiles().isEmpty)
        // 只可能剩那条「上传曾经失败过」的告警（§6-13）。
        #expect(await rig.recorder.queuedEvents().allSatisfy {
            $0.fields["code"] == .string(DiagnosticsWarningCode.diagUploadFailed)
        })
    }

    @Test("按字节切批：60 KB 上限把一大堆事件切成多批，一条不丢")
    func splitsBatchesByBytes() async throws {
        let rig = makeRig()
        // 每条 ~1.3 KB → 100 条 ≈ 130 KB，必然被 60 KB 上限切成 ≥ 3 批。
        let filler = String(repeating: "x", count: 190)
        for index in 0..<100 {
            let big = DiagnosticsEvent.make(
                type: DiagnosticsEventType.sdkWarning, level: DiagnosticsLevel.warn,
                fields: Dictionary(uniqueKeysWithValues: (0..<6).map { ("f\($0)", DiagnosticsFieldValue.string(filler)) }),
                id: "big-\(index)", appUserID: "tester", seq: Int64(index), tsMs: 1_789_000_000_000)
            _ = await rig.queue.append(big)
        }
        await rig.transport.enqueue(.json(#"{"accepted":40,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)

        let result = await rig.recorder.flush()
        #expect(result.uploaded == 100)
        #expect(await pendingCount(rig) == 0)

        let requests = await rig.transport.requests(forPath: diagnosticsPath)
        #expect(requests.count >= 3, "60 KB 上限应把 100 条切成多批")
        for request in requests {
            let size = request.httpBody?.count ?? 0
            #expect(size <= 64 * 1024, "单批 body 不得超过服务端 64 KB 上限（实际 \(size)）")
        }
    }

    @Test("单批条数上限 100：120 条至少切成两批")
    func splitsBatchesByCount() async throws {
        let rig = makeRig()
        for index in 0..<120 { _ = await rig.queue.append(event(index)) }
        await rig.transport.enqueue(.json(#"{"accepted":100,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)

        _ = await rig.recorder.flush()
        let requests = await rig.transport.requests(forPath: diagnosticsPath)
        #expect(requests.count == 2)
        let first = try JSONSerialization.jsonObject(with: try #require(requests.first?.httpBody)) as? [String: Any]
        #expect((first?["events"] as? [[String: Any]])?.count == DiagnosticsUploader.maxEventsPerBatch)
    }

    @Test("响应 backoff_ms：按服务端给的时长退避（§6-9 的每 install 日限额就走这条）")
    func serverBackoffIsHonoured() async throws {
        let rig = makeRig()
        for index in 0..<3 { _ = await rig.queue.append(event(index)) }
        await rig.transport.enqueue(.json(#"{"accepted":3,"dropped":0,"backoff_ms":600000}"#, statusCode: 202),
                                    forPath: diagnosticsPath)

        _ = await rig.recorder.flush()
        #expect(await rig.uploader.backoffSeconds == 600)
        #expect(await rig.uploader.isSuspended)
        rig.clock.advance(599)
        #expect(await rig.recorder.flush().skipped == .backoff)
        rig.clock.advance(2)
        #expect(!(await rig.uploader.isSuspended))
    }

    @Test("响应 disable_until_ms：窗口内不记不发，并清空本地队列")
    func serverDisableStopsRecordingAndSending() async throws {
        let rig = makeRig()
        for index in 0..<3 { _ = await rig.queue.append(event(index)) }
        let disableUntilMs = Int64((rig.clock.now.timeIntervalSince1970 + 86_400) * 1000)
        await rig.transport.enqueue(
            .json(#"{"accepted":3,"dropped":0,"disable_until_ms":\#(disableUntilMs)}"#, statusCode: 202),
            forPath: diagnosticsPath)

        let result = await rig.recorder.flush()
        #expect(result.disableUntilMs == disableUntilMs)
        #expect(await rig.recorder.isTemporarilyDisabled)

        await rig.recorder.record(DiagnosticsEventType.httpError, level: DiagnosticsLevel.error)
        #expect(await rig.recorder.queuedCount() == 0)                 // 不记
        #expect(await rig.recorder.flush().skipped == .backoff)        // 不发

        rig.clock.advance(86_401)
        await rig.recorder.record(DiagnosticsEventType.purchaseStarted)
        #expect(await rig.recorder.queuedCount() == 1)                 // 窗口过去恢复
    }

    @Test("429 读 Retry-After（不短于当前退避档位）")
    func honoursRetryAfterOn429() async throws {
        let rig = makeRig()
        for index in 0..<3 { _ = await rig.queue.append(event(index)) }
        await rig.transport.enqueue(.failure(statusCode: 429, headers: ["Retry-After": "900"]),
                                    forPath: diagnosticsPath)

        _ = await rig.recorder.flush()
        #expect(await pendingCount(rig) == 3)
        rig.clock.advance(899)
        #expect(await rig.recorder.flush().skipped == .backoff)
        rig.clock.advance(2)
        #expect(!(await rig.uploader.isSuspended))
    }

    @Test("§6-13：上传失败只在本地计数，恢复后补一条 sdk_warning{diag_upload_failed}")
    func recordsUploadFailureWarningAfterRecovery() async throws {
        let rig = makeRig()
        for index in 0..<3 { _ = await rig.queue.append(event(index)) }
        await rig.transport.enqueue(.failure(statusCode: 500), forPath: diagnosticsPath)

        _ = await rig.recorder.flush()
        rig.clock.advance(31)
        _ = await rig.recorder.flush()                                 // 第二次仍失败
        #expect(await rig.uploader.consecutiveFailures == 2)
        // 失败期间**没有**为「诊断失败」再发一次诊断请求（只有那两次真上传）。
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 2)

        rig.clock.advance(61)
        await rig.transport.clearStubs(forPath: diagnosticsPath)
        await rig.transport.enqueue(.json(#"{"accepted":3,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)
        _ = await rig.recorder.flush()

        let events = await rig.recorder.queuedEvents()
        let warning = try #require(events.first {
            $0.fields["code"] == .string(DiagnosticsWarningCode.diagUploadFailed)
        })
        #expect(warning.level == DiagnosticsLevel.warn)
        #expect(warning.fields["detail"] == .string("consecutive=2"))
    }

    @Test("进后台触发上传；队列为空时不发")
    func backgroundFlush() async throws {
        let rig = makeRig()
        await rig.recorder.flushForBackground()
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 0)

        _ = await rig.queue.append(event(1))
        await rig.transport.enqueue(.json(#"{"accepted":1,"dropped":0}"#, statusCode: 202),
                                    forPath: diagnosticsPath)
        await rig.recorder.flushForBackground()
        #expect(await rig.transport.callCount(forPath: diagnosticsPath) == 1)
    }

    @Test("§6-2：每条事件带**记录那一刻**的身份，跨 logIn 不串")
    func eventsCarryIdentityAtRecordTime() async throws {
        let identity = MutableIdentity("$RDAnonymousID:abc")
        let url = tempQueueURL()
        let transport = MockTransport()
        let httpClient = HTTPClient(apiKey: "pk_test_0123456789",
                                    baseURL: URL(string: "https://api.revenuedog.com")!,
                                    transport: transport, retryPolicy: .none,
                                    scheduler: NoDelayScheduler(), systemInfoProvider: { .fixture() })
        let queue = DiagnosticsQueue(fileURL: url)
        let uploader = DiagnosticsUploader(httpClient: httpClient, queue: queue,
                                           sessionID: "s", installIDProvider: { "i" },
                                           systemInfoProvider: { .fixture() })
        let recorder = DiagnosticsRecorder(queue: queue, uploader: uploader,
                                           settings: InMemoryDiagnosticsSettingsStorage(),
                                           enabled: true,
                                           appUserIDProvider: { identity.value },
                                           scheduler: RecordingDelayScheduler(),
                                           startsPeriodicFlush: false)

        await recorder.record(DiagnosticsEventType.purchaseStarted)
        identity.value = "firebase-uid-9"                              // logIn
        await recorder.record(DiagnosticsEventType.identityLogin)

        let events = await recorder.queuedEvents()
        #expect(events.map(\.appUserID) == ["$RDAnonymousID:abc", "firebase-uid-9"])
        #expect(events.compactMap(\.seq) == [1, 2])
    }
}

/// 可变身份（模拟 logIn 切换）。
private final class MutableIdentity: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: String

    init(_ value: String) { storage = value }

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

// MARK: - 5. 端到端（走公开门面，与购买流同一套基建）

private func integrationDeps(directory: URL,
                             transport: MockTransport,
                             storeKit: (any StoreKitProvider)?,
                             attributionState: any AttributionStateStorage
                                 = InMemoryAttributionStateStorage()) -> Purchases.Dependencies {
    var diagnostics = Purchases.Dependencies.DiagnosticsDependencies.isolated()
    diagnostics.fileURL = directory
        .appendingPathComponent("_diag", isDirectory: true)
        .appendingPathComponent(DiagnosticsQueue.fileName, isDirectory: false)
    return Purchases.Dependencies(identityStorage: InMemoryIdentityStorage(),
                                  cacheStorage: InMemoryCacheStorage(),
                                  transport: transport,
                                  pendingPurchasesDirectory: directory,
                                  storeKit: storeKit,
                                  attributionState: attributionState,
                                  diagnostics: diagnostics)
}

private func integrationSubscriberJSON() -> String {
    """
    {"request_date":"2026-09-10T00:00:00Z","request_date_ms":1789000000000,
     "subscriber":{"original_app_user_id":"tester","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-09-01T00:00:00Z","last_seen":"2026-09-10T00:00:00Z",
       "management_url":null,
       "entitlements":{"pro":{"expires_date":"2099-01-01T00:00:00Z","grace_period_expires_date":null,
                              "product_identifier":"com.demo.monthly","purchase_date":"2026-09-01T00:00:00Z"}},
       "subscriptions":{},"non_subscriptions":{}}}
    """
}

extension PurchasesSingletonDomain {
@MainActor
@Suite("诊断 · 端到端（购买流）", .serialized)
struct DiagnosticsIntegrationTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogDiagnosticsE2E/\(UUID().uuidString)", isDirectory: true)
    }

    @Test("一次购买的事件序列：purchase_started → transaction_observed → receipt_post → finish_decision，且字段合规")
    func purchaseProducesCompliantEventSequence() async throws {
        Purchases.resetForTesting()
        let directory = tempDir()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let purchases = Purchases.configure(
            with: Configuration(apiKey: "pk_test_0123456789")
                .with(baseURL: URL(string: "https://api.revenuedog.com")!),
            dependencies: integrationDeps(directory: directory, transport: transport, storeKit: provider))
        defer { Purchases.resetForTesting() }

        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-diag-1",
                                     originalTransactionIdentifier: "otx-diag-1",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "header.payload.signature", finishFlag: flag))
        }
        await transport.enqueue(.json(integrationSubscriberJSON(),
                                      headers: ["X-Request-Id": "req-abc-123"]),
                                forPath: receiptsPath)

        _ = try await purchases.purchase(product: StoreProduct(productIdentifier: "com.demo.monthly",
                                                               localizedTitle: "", localizedDescription: "",
                                                               price: 9.99, currencyCode: "USD",
                                                               localizedPriceString: "$9.99"))

        let events = await purchases.diagnosticsRecorder.queuedEvents()
        let types = events.map(\.type)
        #expect(types.first == DiagnosticsEventType.sdkConfigured)

        // 四个关键节点按序出现（中间允许有别的事件）。
        var cursor = types.startIndex
        for expected in [DiagnosticsEventType.purchaseStarted,
                         DiagnosticsEventType.transactionObserved,
                         DiagnosticsEventType.receiptPost,
                         DiagnosticsEventType.finishDecision] {
            let found = types[cursor...].firstIndex(of: expected)
            #expect(found != nil, "事件序列缺 \(expected)：\(types)")
            guard let found else { return }
            cursor = types.index(after: found)
        }
        #expect(types.contains(DiagnosticsEventType.purchaseResult))
        #expect(types.contains(DiagnosticsEventType.customerInfoUpdated))

        // 字段口径
        let started = try #require(events.first { $0.type == DiagnosticsEventType.purchaseStarted })
        #expect(started.fields["product_id"] == .string("com.demo.monthly"))
        let observed = try #require(events.first { $0.type == DiagnosticsEventType.transactionObserved })
        #expect(observed.fields["source"] == .string(DiagnosticsTransactionSource.purchase.rawValue))
        #expect(observed.fields["transaction_id"] == .string("tx-diag-1"))
        #expect(observed.fields["original_transaction_id"] == .string("otx-diag-1"))
        let receipt = try #require(events.first { $0.type == DiagnosticsEventType.receiptPost })
        #expect(receipt.fields["status"] == .int(200))
        #expect(receipt.fields["attempt"] == .int(1))
        #expect(receipt.fields["transaction_id"] == .string("tx-diag-1"))
        // `request_id` 一律取响应头 X-Request-Id（契约 §1.3）
        #expect(receipt.fields["request_id"] == .string("req-abc-123"))
        let finish = try #require(events.first { $0.type == DiagnosticsEventType.finishDecision })
        #expect(finish.fields["decision"] == .string(DiagnosticsFinishDecision.finished))
        #expect(finish.fields["reason"] == .string(DiagnosticsFinishReason.serverAck))
        #expect(finish.level == DiagnosticsLevel.info)
        let updated = try #require(events.first { $0.type == DiagnosticsEventType.customerInfoUpdated })
        #expect(updated.fields["active_entitlement_ids"] == .strings(["pro"]))

        // 禁止内容（契约 §1.3 末段）：JWS / key / message / body 一律不得出现。
        let dump = try #require(String(data: try DiagnosticsCoding.encoder.encode(events), encoding: .utf8))
        #expect(!dump.contains("header.payload.signature"))
        #expect(!dump.contains("pk_test_0123456789"))
        #expect(!dump.contains("fetch_token"))
        #expect(!dump.contains("original_app_user_id"))
        // 每条事件都带记录时刻的身份与单调 seq（§6-2 / §6-5）
        #expect(events.allSatisfy { $0.appUserID?.isEmpty == false })
        #expect(events.compactMap(\.seq) == Array(1...Int64(events.count)))
    }

    @Test("http_error：非 receipts 端点的非 2xx 记事件，path 里的 app_user_id 段换成 *")
    func httpErrorMasksAppUserID() async throws {
        Purchases.resetForTesting()
        let directory = tempDir()
        let transport = MockTransport()
        let purchases = Purchases.configure(
            with: Configuration(apiKey: "pk_test_0123456789")
                .with(appUserID: "firebase-uid-42")
                .with(baseURL: URL(string: "https://api.revenuedog.com")!),
            dependencies: integrationDeps(directory: directory, transport: transport, storeKit: nil))
        defer { Purchases.resetForTesting() }

        await transport.enqueue(.failure(statusCode: 500, headers: ["X-Request-Id": "req-err-1"]),
                                forPath: "/v1/subscribers/firebase-uid-42")
        _ = try? await purchases.customerInfo(fetchPolicy: .fetchCurrent)

        let events = await purchases.diagnosticsRecorder.queuedEvents()
        let httpErrors = events.filter { $0.type == DiagnosticsEventType.httpError }
        #expect(!httpErrors.isEmpty)
        let first = try #require(httpErrors.first)
        #expect(first.fields["path"] == .string("/v1/subscribers/*"))     // 身份被打码
        #expect(first.fields["status"] == .int(500))
        #expect(first.fields["error_class"] == .string(DiagnosticsErrorClass.server))
        #expect(first.fields["request_id"] == .string("req-err-1"))
        #expect(first.level == DiagnosticsLevel.error)

        // 注意：事件**顶层**的 app_user_id 是契约要求的（§6-2），要打码的是 fields.path。
        for event in httpErrors {
            if case .string(let path)? = event.fields["path"] {
                #expect(!path.contains("firebase-uid-42"), "http_error 的 path 里不得出现 app_user_id")
            }
        }

        // customer_info_fetch 也应记一条 error（同一次失败的另一个视角）
        let fetch = try #require(events.first { $0.type == DiagnosticsEventType.customerInfoFetch })
        #expect(fetch.level == DiagnosticsLevel.error)
        #expect(fetch.fields["policy"] == .string(FetchPolicy.fetchCurrent.rawValue))
    }

    @Test("§6-1：install_id 由首次 configure 生成并持久化，跨 configure 稳定，且与 ASA 采集无关")
    func installIDIsStableAcrossConfigure() async throws {
        Purchases.resetForTesting()
        let state = InMemoryAttributionStateStorage()
        #expect(await state.installID() == nil)

        let directory = tempDir()
        let purchases = Purchases.configure(
            with: Configuration(apiKey: "pk_test_0123456789")
                .with(baseURL: URL(string: "https://api.revenuedog.com")!),
            dependencies: integrationDeps(directory: directory, transport: MockTransport(),
                                          storeKit: nil, attributionState: state))
        _ = try? await purchases.customerInfo(fetchPolicy: .cachedOnly)   // 等启动 Task 收敛
        let first = try #require(await state.installID())
        #expect(first.count == 32)
        Purchases.resetForTesting()

        // 第二次 configure 复用同一份持久化状态 → 同一个 install_id。
        let purchases2 = Purchases.configure(
            with: Configuration(apiKey: "pk_test_0123456789")
                .with(baseURL: URL(string: "https://api.revenuedog.com")!),
            dependencies: integrationDeps(directory: tempDir(), transport: MockTransport(),
                                          storeKit: nil, attributionState: state))
        _ = try? await purchases2.customerInfo(fetchPolicy: .cachedOnly)
        #expect(await state.installID() == first)
        Purchases.resetForTesting()
    }

    @Test("diagnosticsEnabled = false：整条链路零事件、零上传")
    func disabledEndToEnd() async throws {
        Purchases.resetForTesting()
        let directory = tempDir()
        let transport = MockTransport()
        let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        let purchases = Purchases.configure(
            with: Configuration(apiKey: "pk_test_0123456789")
                .with(baseURL: URL(string: "https://api.revenuedog.com")!)
                .with(diagnosticsEnabled: false),
            dependencies: integrationDeps(directory: directory, transport: transport, storeKit: provider))
        defer { Purchases.resetForTesting() }

        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-off-1",
                                     originalTransactionIdentifier: "tx-off-1",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.o.s", finishFlag: flag))
        }
        await transport.enqueue(.json(integrationSubscriberJSON()), forPath: receiptsPath)
        _ = try await purchases.purchase(product: StoreProduct(productIdentifier: "com.demo.monthly",
                                                               localizedTitle: "", localizedDescription: "",
                                                               price: 9.99, currencyCode: "USD",
                                                               localizedPriceString: "$9.99"))

        #expect(await purchases.diagnosticsRecorder.queuedCount() == 0)
        #expect(await transport.callCount(forPath: diagnosticsPath) == 0)
    }
}
}
