//
//  DiagnosticsUploader.swift
//  诊断事件攒批上传（设计 docs/plan/sdk-diagnostics.md §1.2 / §2，修正见 §6）。
//
//  - 走既有 `HTTPClient`：系统头（`X-Platform` / `X-Version` / `X-Client-Version` …）与
//    `Authorization: Bearer pk_…` 自动带上，body 不重复这些信息（契约 §1.1）。
//  - 端点级重试策略 = **不重试**；重试节奏由本上传器的退避掌管。
//  - **按原始 HTTP 状态码分类**（§6-10）：走 `performUnchecked`，不经 `PurchasesError` 映射 ——
//    413 / 429 / 503 在映射之后会揉成同几个 code，而处置矩阵恰恰是按状态码分叉的。
//  - **文件轮转**（§6-8）：先把 `queue.jsonl` 改名成 `inflight-<uuid>.jsonl` 再发，
//    在飞期间新入队的事件写进全新的 `queue.jsonl`，绝不会被这一批的成功给截掉；
//    整批成功才删在飞文件，中途失败就把剩余行写回去等下次。启动时先补发遗留的在飞文件。
//  - 响应处置（契约 §1.2 + §6-10）：
//      2xx        → 出队该批，落 `sample_rate_info`；带 `backoff_ms` 就按它退避，
//                   带 `disable_until_ms` 就在该时刻前不记不发
//      401 / 403  → **丢弃该批**并**停 1 小时**（key 错了不该反复打）
//      429        → 退避（优先读 `Retry-After`），**保留队列**
//      5xx / 网络错误 → 指数退避（30s 起，×2，上限 1h），**保留队列**
//      其余 4xx（含 413） → 丢弃该批（确定性错误，重发只会再被拒）
//  - 同一时刻只有一个上传在飞（单飞闸）。
//

import Foundation

/// 一次 `upload()` 的结果（测试与 Recorder 用；不上行、不落盘）。
struct DiagnosticsUploadResult: Sendable, Equatable {
    /// 成功上传（且已出队）的事件条数。
    var uploaded = 0
    /// 因确定性错误被丢弃的事件条数。
    var dropped = 0
    /// 服务端下发的 info 采样率（有才回传，由 Recorder 落盘）。
    var sampleRateInfo: Double?
    /// 服务端下发的「到这个时刻前不记不发」（§6-9 的硬开关）。
    var disableUntilMs: Int64?
    /// 本次成功之前**连续失败过几次**（§6-13：>0 时 Recorder 补一条 `diag_upload_failed`）。
    var recoveredFailureCount = 0
    /// 本次调用被跳过的原因（nil = 真的发了）。
    var skipped: Skip?

    enum Skip: String, Sendable {
        /// 已有一个上传在飞。
        case inFlight
        /// 处在退避 / 鉴权停摆 / 服务端禁用窗口内。
        case backoff
        /// 队列与在飞文件都是空的。
        case empty
    }
}

actor DiagnosticsUploader {

    /// 退避：30s 起，×2，上限 1h（契约 §1.2）。
    static let initialBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 3600
    /// 401/403 的停摆时长。
    static let authSuspension: TimeInterval = 3600
    /// 单批上限：条数 100（契约 §1.3 硬限）+ 序列化 60 KB（§6-3；服务端 body 上限 64 KB，留信封余量）。
    static let maxEventsPerBatch = 100
    static let maxEventBytesPerBatch = 60 * 1024
    /// 一次 `upload()` 最多连发几批（有积压时尽量排空，但不无限占着单飞闸）。
    static let maxBatchesPerRun = 20

    /// wire 契约版本（§6-5）。
    static let schemaVersion = 1

    private let httpClient: HTTPClient
    private let queue: DiagnosticsQueue
    private let sessionID: String
    /// **非可选**：服务端对缺失 / 空 / 超长 `install_id` 回 400，而 400 是确定性 4xx →
    /// 会被丢批 → 整台设备的诊断静默消失。按 §6-1，install_id 在首次 `configure` 就生成并持久化，
    /// 这里拿到的永远是个非空值 —— 类型上就把「可能没有」这条路堵死。
    private let installIDProvider: @Sendable () async -> String
    private let systemInfoProvider: @Sendable () -> SystemInfo
    private let localeProvider: @Sendable () -> String?
    private let now: @Sendable () -> Date

    private var isUploading = false
    /// 退避 / 停摆的解除时刻。
    private(set) var resumeAt: Date?
    /// 当前退避时长（0 = 未处在指数退避里）。测试断言退避序列用。
    private(set) var backoffSeconds: TimeInterval = 0
    /// 连续失败次数（§6-13：上传失败**只在本地计数**，绝不为诊断失败再发一次诊断请求）。
    private(set) var consecutiveFailures = 0

    init(httpClient: HTTPClient,
         queue: DiagnosticsQueue,
         sessionID: String,
         installIDProvider: @escaping @Sendable () async -> String,
         systemInfoProvider: @escaping @Sendable () -> SystemInfo
             = { SystemInfo.current(isBackgrounded: AppStateProvider.isBackgrounded) },
         localeProvider: @escaping @Sendable () -> String? = { Locale.current.identifier },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.httpClient = httpClient
        self.queue = queue
        self.sessionID = sessionID
        self.installIDProvider = installIDProvider
        self.systemInfoProvider = systemInfoProvider
        self.localeProvider = localeProvider
        self.now = now
    }

    // MARK: - 上传

    @discardableResult
    func upload() async -> DiagnosticsUploadResult {
        guard !isUploading else { return DiagnosticsUploadResult(skipped: .inFlight) }
        if let resumeAt, now() < resumeAt { return DiagnosticsUploadResult(skipped: .backoff) }

        isUploading = true
        defer { isUploading = false }

        // 遗留的在飞文件优先（进程被杀 / 上次失败留下的），再轮转当前队列。
        var files = queue.inflightFiles()
        if let rotated = await queue.rotate() { files.append(rotated) }
        guard !files.isEmpty else { return DiagnosticsUploadResult(skipped: .empty) }

        var result = DiagnosticsUploadResult()
        var batches = 0

        for file in files {
            var lines = DiagnosticsQueue.lines(at: file)
            while !lines.isEmpty {
                guard batches < Self.maxBatchesPerRun else {
                    persist(lines, to: file)
                    return result
                }
                batches += 1
                let batch = DiagnosticsQueue.batch(from: lines,
                                                   maxCount: Self.maxEventsPerBatch,
                                                   maxBytes: Self.maxEventBytesPerBatch)
                guard !batch.isEmpty else { break }

                switch await send(batch) {
                case .accepted(let response):
                    lines.removeFirst(min(batch.count, lines.count))
                    result.uploaded += batch.count
                    if let rate = response.sampleRateInfo { result.sampleRateInfo = rate }
                    if let disableUntil = response.disableUntilMs {
                        result.disableUntilMs = disableUntil
                        persist(lines, to: file)
                        // 先收干净失败计数，再套上服务端给的窗口（顺序反了会把窗口清掉）。
                        result = finish(result, clearingBackoff: true)
                        applyDisableUntil(disableUntil)
                        return result
                    }
                    if let backoffMs = response.backoffMs {
                        // 服务端明确要求歇一会儿（§6-9 的每 install 日限额就是这么回传的）。
                        persist(lines, to: file)
                        result = finish(result, clearingBackoff: true)
                        applyServerBackoff(seconds: Double(backoffMs) / 1000)
                        return result
                    }
                case .dropBatch(let suspendFor):
                    lines.removeFirst(min(batch.count, lines.count))
                    result.dropped += batch.count
                    if let suspendFor {
                        consecutiveFailures += 1
                        applySuspension(seconds: suspendFor)
                        persist(lines, to: file)
                        return result
                    }
                case .retryLater(let retryAfter):
                    consecutiveFailures += 1
                    persist(lines, to: file)                 // 一条不丢，等退避窗口过去
                    applyBackoff(retryAfter: retryAfter)
                    return result
                }
            }
            DiagnosticsQueue.removeFile(at: file)
        }
        return finish(result, clearingBackoff: true)
    }

    /// 成功收尾：清退避，并把「本次成功之前连续失败了几次」交给 Recorder 记一条 `diag_upload_failed`。
    private func finish(_ result: DiagnosticsUploadResult, clearingBackoff: Bool) -> DiagnosticsUploadResult {
        var result = result
        if clearingBackoff { clearBackoff() }
        result.recoveredFailureCount = consecutiveFailures
        consecutiveFailures = 0
        return result
    }

    private func persist(_ lines: [Data], to file: URL) {
        if lines.isEmpty {
            DiagnosticsQueue.removeFile(at: file)
        } else {
            DiagnosticsQueue.write(lines, to: file)
        }
    }

    // MARK: - 单批

    private enum SendOutcome {
        case accepted(DiagnosticsUploadResponse)
        /// 确定性错误：丢弃该批。`suspendFor` 非空 = 同时停摆（401/403 停 1h）。
        case dropBatch(suspendFor: TimeInterval?)
        /// 暂时性错误：保留队列，退避（`retryAfter` 来自 429 的 `Retry-After` 头）。
        case retryLater(retryAfter: TimeInterval?)
    }

    private func send(_ batch: [DiagnosticsEvent]) async -> SendOutcome {
        let system = systemInfoProvider()
        let body = DiagnosticsUploadBody(schemaVersion: Self.schemaVersion,
                                         installID: await installIDProvider(),
                                         sessionID: sessionID,
                                         sandbox: system.isSandbox,
                                         isDebug: system.isDebugBuild,
                                         storefront: system.storefront,
                                         locale: localeProvider(),
                                         sentAtMs: Int64((now().timeIntervalSince1970 * 1000).rounded()),
                                         events: batch)
        guard let data = try? DiagnosticsCoding.encoder.encode(body) else {
            // 编码不出来是端上确定性故障，重发也一样 → 丢弃该批，别让它永久堵住队首。
            Log.debug("诊断上传体编码失败，丢弃该批（\(batch.count) 条）", category: "diagnostics")
            return .dropBatch(suspendFor: nil)
        }

        let response = await httpClient.performUnchecked(.postDiagnosticsEvents, body: data)
        guard let status = response.statusCode else {
            return .retryLater(retryAfter: nil)                     // 传输层错误（超时 / 断网）
        }
        switch status {
        case 200...299:
            let wire = try? DiagnosticsCoding.decoder.decode(DiagnosticsUploadResponse.self,
                                                             from: response.body)
            return .accepted(wire ?? DiagnosticsUploadResponse())
        case 401, 403:
            Log.warn("诊断上传鉴权失败（HTTP \(status)），丢弃该批并停 1 小时", category: "diagnostics")
            return .dropBatch(suspendFor: Self.authSuspension)
        case 429:
            return .retryLater(retryAfter: RetryPolicy.retryAfterSeconds(response.headers))
        case 400...499:
            Log.debug("诊断上传被确定性拒绝（HTTP \(status)），丢弃该批（\(batch.count) 条）",
                      category: "diagnostics")
            return .dropBatch(suspendFor: nil)
        default:
            return .retryLater(retryAfter: nil)                     // 5xx
        }
    }

    // MARK: - 退避

    private func applyBackoff(retryAfter: TimeInterval?) {
        backoffSeconds = backoffSeconds <= 0
            ? Self.initialBackoff
            : min(backoffSeconds * 2, Self.maxBackoff)
        // `Retry-After` 优先（与 HTTPClient 的 §5 口径一致），但不短于本地退避的当前档位 ——
        // 服务端说「再等久点」听它的，说「马上再来」不听（诊断不值得为此打穿后端）。
        let delay = max(retryAfter.map { min($0, Self.maxBackoff) } ?? 0, backoffSeconds)
        resumeAt = now().addingTimeInterval(delay)
    }

    private func applyServerBackoff(seconds: TimeInterval) {
        backoffSeconds = min(max(seconds, 0), Self.maxBackoff)
        resumeAt = now().addingTimeInterval(min(max(seconds, 0), Self.maxBackoff))
    }

    private func applySuspension(seconds: TimeInterval) {
        backoffSeconds = 0
        resumeAt = now().addingTimeInterval(seconds)
    }

    private func applyDisableUntil(_ disableUntilMs: Int64) {
        backoffSeconds = 0
        let until = Date(timeIntervalSince1970: Double(disableUntilMs) / 1000)
        resumeAt = max(until, resumeAt ?? until)
    }

    private func clearBackoff() {
        backoffSeconds = 0
        resumeAt = nil
    }

    /// 测试用：直接问「现在能不能发」。
    var isSuspended: Bool {
        guard let resumeAt else { return false }
        return now() < resumeAt
    }
}

// MARK: - wire 形状（契约 §1.1 / §1.2 + §6-5 / §6-10）

/// 请求体。系统信息只走请求头，body 不重复（契约 §1.1）；
/// `app_user_id` **不在信封里** —— 它下沉到每条事件（§6-2）。
private struct DiagnosticsUploadBody: Encodable {
    let schemaVersion: Int
    /// 非可选：见 `installIDProvider` 的注释（服务端 400 → 丢批 → 诊断静默消失）。
    let installID: String
    let sessionID: String
    let sandbox: Bool
    let isDebug: Bool
    let storefront: String?
    let locale: String?
    let sentAtMs: Int64
    let events: [DiagnosticsEvent]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case installID = "install_id"
        case sessionID = "session_id"
        case sandbox
        case isDebug = "is_debug"
        case storefront
        case locale
        case sentAtMs = "sent_at_ms"
        case events
    }
}

/// `202 {"accepted": n, "dropped": m, "sample_rate_info": 1.0, "backoff_ms"?, "disable_until_ms"?}`。
struct DiagnosticsUploadResponse: Decodable, Sendable {
    var accepted: Int?
    var dropped: Int?
    var sampleRateInfo: Double?
    var backoffMs: Int64?
    var disableUntilMs: Int64?

    enum CodingKeys: String, CodingKey {
        case accepted
        case dropped
        case sampleRateInfo = "sample_rate_info"
        case backoffMs = "backoff_ms"
        case disableUntilMs = "disable_until_ms"
    }
}
