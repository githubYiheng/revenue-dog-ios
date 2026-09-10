//
//  DiagnosticsRecorder.swift
//  诊断事件的记录入口 + 采样 + 上传触发（设计 docs/plan/sdk-diagnostics.md §2）。
//
//  触发上传（四条，任一命中即发）：
//    1. 队列 ≥ 20 条
//    2. 前台每 30s 定时（**有事件才发**）
//    3. 进后台时（走既有前后台抽象，见 Purchases.applicationDidEnterBackground）
//    4. 任一 `error` 级事件入队后 2s 防抖（连着来的错误只发一次）
//
//  采样：`sample_rate_info` 由服务端下发、端上持久化，**只作用于 info**；warn / error 恒 100%。
//  开关：`Configuration.with(diagnosticsEnabled:)`，默认 true；false 时不记不发并清空队列文件。
//

import Foundation

// MARK: - 采样率持久化

/// `sample_rate_info` 的落盘面。与身份 / install_id 同处一个 `UserDefaults`
/// （键前缀 `com.revenuedog.sdk.`）—— 一个标量，不触碰坑 #23。
protocol DiagnosticsSettingsStorage: Sendable {
    func sampleRateInfo() async -> Double?
    func setSampleRateInfo(_ value: Double) async
}

actor UserDefaultsDiagnosticsSettingsStorage: DiagnosticsSettingsStorage {

    static let sampleRateInfoKey = "com.revenuedog.sdk.diagnostics.sampleRateInfo"

    // UserDefaults 本身线程安全但不 Sendable；由本 actor 独占持有（同 IdentityStorage）。
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func sampleRateInfo() -> Double? {
        guard defaults.object(forKey: Self.sampleRateInfoKey) != nil else { return nil }
        return defaults.double(forKey: Self.sampleRateInfoKey)
    }

    func setSampleRateInfo(_ value: Double) {
        defaults.set(value, forKey: Self.sampleRateInfoKey)
    }
}

actor InMemoryDiagnosticsSettingsStorage: DiagnosticsSettingsStorage {

    private var value: Double?

    init(sampleRateInfo: Double? = nil) { self.value = sampleRateInfo }

    func sampleRateInfo() -> Double? { value }

    func setSampleRateInfo(_ value: Double) { self.value = value }
}

// MARK: - Recorder

actor DiagnosticsRecorder {

    /// 队列达到这个条数立刻发。
    static let uploadThreshold = 20
    /// error 级事件的防抖窗口。
    static let errorDebounce: TimeInterval = 2
    /// 前台定时上传间隔。
    static let periodicInterval: TimeInterval = 30

    private let queue: DiagnosticsQueue
    private let uploader: DiagnosticsUploader
    private let settings: any DiagnosticsSettingsStorage
    private let scheduler: any DelayScheduler
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let idProvider: @Sendable () -> String
    private let startsPeriodicFlush: Bool

    private var enabled: Bool
    /// info 采样率（服务端下发，端上持久化）。默认 1.0 = 不采样。
    private var sampleRateInfo: Double = 1
    private var didStart = false
    private var errorDebounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    init(queue: DiagnosticsQueue,
         uploader: DiagnosticsUploader,
         settings: any DiagnosticsSettingsStorage,
         enabled: Bool,
         scheduler: any DelayScheduler = TaskDelayScheduler(),
         startsPeriodicFlush: Bool = true,
         now: @escaping @Sendable () -> Date = { Date() },
         random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
         idProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.queue = queue
        self.uploader = uploader
        self.settings = settings
        self.enabled = enabled
        self.scheduler = scheduler
        self.startsPeriodicFlush = startsPeriodicFlush
        self.now = now
        self.random = random
        self.idProvider = idProvider
    }

    deinit {
        errorDebounceTask?.cancel()
        periodicTask?.cancel()
    }

    // MARK: - 生命周期

    /// 由 `Purchases.start()` 调一次。关掉诊断时**清空队列文件**（旧版本留下的也一并清）。
    func start() async {
        guard !didStart else { return }
        didStart = true
        guard enabled else {
            await queue.clear()
            Log.debug("诊断已关闭（diagnosticsEnabled = false），本地队列已清空", category: "diagnostics")
            return
        }
        if let stored = await settings.sampleRateInfo() {
            sampleRateInfo = min(max(stored, 0), 1)
        }
        if startsPeriodicFlush { startPeriodicFlush() }
    }

    var isEnabled: Bool { enabled }

    var currentSampleRateInfo: Double { sampleRateInfo }

    // MARK: - 记录

    /// 记录一条事件。`fields` 里的 nil 会被丢掉（契约「缺失容忍」）。
    func record(_ type: String,
                level: String = DiagnosticsLevel.info,
                fields: [String: DiagnosticsFieldValue?] = [:]) async {
        guard enabled else { return }
        // 采样只作用于 info；warn / error 恒 100%（契约 §1.2）。
        if level == DiagnosticsLevel.info, sampleRateInfo < 1 {
            guard sampleRateInfo > 0, random() < sampleRateInfo else { return }
        }

        let event = DiagnosticsEvent.make(type: type,
                                          level: level,
                                          fields: fields,
                                          id: idProvider(),
                                          tsMs: Int64((now().timeIntervalSince1970 * 1000).rounded()))
        let dropped = await queue.append(event)
        if dropped > 0 {
            await recordQueueOverflow(dropped: dropped)
        }

        if await queue.count >= Self.uploadThreshold {
            triggerFlush()
        } else if level == DiagnosticsLevel.error {
            scheduleErrorDebounce()
        }
    }

    /// 队列溢出告警。**这一条自己不再触发溢出告警**（否则会自激成无限告警）。
    private func recordQueueOverflow(dropped: Int) async {
        let event = DiagnosticsEvent.make(type: DiagnosticsEventType.sdkWarning,
                                          level: DiagnosticsLevel.warn,
                                          fields: [
                                              "code": .string(DiagnosticsWarningCode.queueOverflow),
                                              "detail": .string("dropped_oldest=\(dropped)"),
                                          ],
                                          id: idProvider(),
                                          tsMs: Int64((now().timeIntervalSince1970 * 1000).rounded()))
        _ = await queue.append(event)
    }

    // MARK: - 上传触发

    /// 立刻尝试上传（内部有单飞闸与退避）。返回结果供测试断言。
    @discardableResult
    func flush() async -> DiagnosticsUploadResult {
        guard enabled else { return DiagnosticsUploadResult(skipped: .empty) }
        let result = await uploader.upload()
        if let rate = result.sampleRateInfo {
            let clamped = min(max(rate, 0), 1)
            if clamped != sampleRateInfo {
                sampleRateInfo = clamped
                await settings.setSampleRateInfo(clamped)
                Log.debug("诊断 info 采样率更新为 \(clamped)", category: "diagnostics")
            }
        }
        return result
    }

    /// 进后台：把攒着的事件冲出去（`Purchases.applicationDidEnterBackground`）。
    func flushForBackground() async {
        guard enabled, await queue.count > 0 else { return }
        await flush()
    }

    private func triggerFlush() {
        errorDebounceTask?.cancel()
        errorDebounceTask = nil
        Task { [weak self] in await self?.flush() }
    }

    /// error 级事件 2s 防抖：连着炸出来的错误合成一次上传。
    private func scheduleErrorDebounce() {
        errorDebounceTask?.cancel()
        errorDebounceTask = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: Self.errorDebounce)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func startPeriodicFlush() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self, scheduler] in
            while !Task.isCancelled {
                try? await scheduler.sleep(seconds: Self.periodicInterval)
                guard !Task.isCancelled else { return }
                // 前台才发（后台由 didEnterBackground 那一次负责），且**有事件才发**。
                guard !AppStateProvider.isBackgrounded else { continue }
                await self?.flushIfNonEmpty()
            }
        }
    }

    private func flushIfNonEmpty() async {
        guard await queue.count > 0 else { return }
        await flush()
    }

    // MARK: - 测试读视图

    func queuedEvents() async -> [DiagnosticsEvent] {
        await queue.allEvents()
    }

    func queuedCount() async -> Int {
        await queue.count
    }
}

// MARK: - HTTP 层的记录辅助

extension DiagnosticsRecorder {

    /// `receipt_post`（`/v1/receipts` 每次尝试结束）与 `http_error`（非 receipts 端点的非 2xx）。
    /// 由 `HTTPClient` 在每次尝试结束时调用 —— 那里是唯一同时握有
    /// 状态码 / `X-Request-Id` / 尝试序号 / 耗时的地方。
    func recordHTTPAttempt(endpoint: Endpoint,
                           attempt: Int,
                           statusCode: Int?,
                           requestID: String?,
                           durationMs: Int,
                           errorCode: String?,
                           extraFields: [String: DiagnosticsFieldValue]) async {
        // 诊断上传自己的请求绝不记事件（否则失败会自激成事件雪崩）。
        if case .postDiagnosticsEvents = endpoint { return }

        let isSuccess = statusCode.map { (200...299).contains($0) } ?? false
        let errorClass = isSuccess ? nil : DiagnosticsErrorClass.from(statusCode: statusCode)

        if case .postReceipt = endpoint {
            var fields: [String: DiagnosticsFieldValue?] = [
                "status": statusCode.map { .int($0) },
                "request_id": requestID.map { .string($0) },
                "attempt": .int(attempt),
                "duration_ms": .int(durationMs),
                "error_class": errorClass.map { .string($0) },
                "error_code": isSuccess ? nil : errorCode.map { .string($0) },
            ]
            for (key, value) in extraFields { fields[key] = value }
            await record(DiagnosticsEventType.receiptPost,
                         level: isSuccess ? DiagnosticsLevel.info : DiagnosticsLevel.error,
                         fields: fields)
            return
        }

        guard !isSuccess else { return }
        var fields: [String: DiagnosticsFieldValue?] = [
            "path": .string(endpoint.diagnosticsPath),
            "status": statusCode.map { .int($0) },
            "request_id": requestID.map { .string($0) },
            "error_class": errorClass.map { .string($0) },
            "error_code": errorCode.map { .string($0) },
            "attempt": .int(attempt),
            "duration_ms": .int(durationMs),
        ]
        for (key, value) in extraFields { fields[key] = value }
        await record(DiagnosticsEventType.httpError, level: DiagnosticsLevel.error, fields: fields)
    }

    /// 既有运行时告警处的统一入口（`sdk_warning`）。
    func warn(_ code: String, detail: String? = nil) async {
        await record(DiagnosticsEventType.sdkWarning,
                     level: DiagnosticsLevel.warn,
                     fields: ["code": .string(code), "detail": detail.map { .string($0) }])
    }
}
