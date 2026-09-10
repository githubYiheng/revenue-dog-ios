//
//  DiagnosticsUploader.swift
//  诊断事件攒批上传（设计 docs/plan/sdk-diagnostics.md §1.2 / §2）。
//
//  - 走既有 `HTTPClient`：系统头（`X-Platform` / `X-Version` / `X-Client-Version` …）与
//    `Authorization: Bearer pk_…` 自动带上，body 不重复这些信息（契约 §1.1）。
//  - 端点级重试策略 = **不重试**（`EndpointPolicy.isRetryable = false`）：重试节奏由本上传器
//    自己的退避掌管，不能让 HTTPClient 在一次调用里连打四发。
//  - 响应处置（契约 §1.2，逐字）：
//      2xx        → 出队该批，落 `sample_rate_info`，退避归零
//      401 / 403  → **丢弃该批**并**停 1 小时**（key 错了不该反复打）
//      429 / 5xx / 网络错误 → 指数退避（30s 起，×2，上限 1h），**保留队列**
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
    /// 本次调用被跳过的原因（nil = 真的发了）。
    var skipped: Skip?

    enum Skip: String, Sendable {
        /// 已有一个上传在飞。
        case inFlight
        /// 处在退避 / 鉴权停摆窗口内。
        case backoff
        /// 队列为空。
        case empty
        /// 身份尚未就绪（configure 的启动 Task 还没解析出 appUserID）。
        case noIdentity
    }
}

actor DiagnosticsUploader {

    /// 退避：30s 起，×2，上限 1h（契约 §1.2）。
    static let initialBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 3600
    /// 401/403 的停摆时长。
    static let authSuspension: TimeInterval = 3600
    /// 单批上限：条数 100（契约 §1.3 硬限），字节数留出信封余量（整 body ≤ 64 KB）。
    static let maxEventsPerBatch = 100
    static let maxEventBytesPerBatch = 56 * 1024
    /// 一次 `upload()` 最多连发几批（有积压时一次性排空，但不无限占着单飞闸）。
    static let maxBatchesPerRun = 5

    private let httpClient: HTTPClient
    private let queue: DiagnosticsQueue
    private let installIDProvider: @Sendable () async -> String?
    private let appUserIDProvider: @Sendable () async -> String?
    private let sandboxProvider: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    private var isUploading = false
    /// 退避 / 停摆的解除时刻。
    private(set) var resumeAt: Date?
    /// 当前退避时长（0 = 未处在指数退避里）。测试断言退避序列用。
    private(set) var backoffSeconds: TimeInterval = 0

    init(httpClient: HTTPClient,
         queue: DiagnosticsQueue,
         installIDProvider: @escaping @Sendable () async -> String?,
         appUserIDProvider: @escaping @Sendable () async -> String?,
         sandboxProvider: @escaping @Sendable () -> Bool = { SystemInfo.currentIsSandbox },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.httpClient = httpClient
        self.queue = queue
        self.installIDProvider = installIDProvider
        self.appUserIDProvider = appUserIDProvider
        self.sandboxProvider = sandboxProvider
        self.now = now
    }

    // MARK: - 上传

    @discardableResult
    func upload() async -> DiagnosticsUploadResult {
        guard !isUploading else { return DiagnosticsUploadResult(skipped: .inFlight) }
        if let resumeAt, now() < resumeAt { return DiagnosticsUploadResult(skipped: .backoff) }

        isUploading = true
        defer { isUploading = false }

        var result = DiagnosticsUploadResult()
        for _ in 0..<Self.maxBatchesPerRun {
            let batch = await queue.peek(maxCount: Self.maxEventsPerBatch,
                                         maxBytes: Self.maxEventBytesPerBatch)
            guard !batch.isEmpty else {
                if result.uploaded == 0 && result.dropped == 0 && result.skipped == nil {
                    result.skipped = .empty
                }
                break
            }
            guard let appUserID = await appUserIDProvider() else {
                if result.uploaded == 0 && result.dropped == 0 { result.skipped = .noIdentity }
                break
            }

            let outcome = await send(batch, appUserID: appUserID)
            switch outcome {
            case .accepted(let sampleRate):
                await queue.remove(count: batch.count)
                result.uploaded += batch.count
                if let sampleRate { result.sampleRateInfo = sampleRate }
                clearBackoff()
            case .dropBatch(let suspendFor):
                await queue.remove(count: batch.count)
                result.dropped += batch.count
                if let suspendFor {
                    resumeAt = now().addingTimeInterval(suspendFor)
                    backoffSeconds = 0
                    return result            // 停摆：不再连发下一批
                }
                clearBackoff()
            case .retryLater:
                applyBackoff()
                return result                // 保留队列，等退避窗口过去
            }
        }
        return result
    }

    // MARK: - 单批

    private enum SendOutcome {
        /// 2xx。附带服务端下发的 info 采样率。
        case accepted(Double?)
        /// 确定性错误：丢弃该批。`suspendFor` 非空 = 同时停摆（401/403 停 1h）。
        case dropBatch(suspendFor: TimeInterval?)
        /// 暂时性错误：保留队列，指数退避。
        case retryLater
    }

    private func send(_ batch: [DiagnosticsEvent], appUserID: String) async -> SendOutcome {
        let body = DiagnosticsUploadBody(installID: await installIDProvider(),
                                         appUserID: appUserID,
                                         sandbox: sandboxProvider(),
                                         sentAtMs: Int64((now().timeIntervalSince1970 * 1000).rounded()),
                                         events: batch)
        guard let data = try? DiagnosticsCoding.encoder.encode(body) else {
            // 编码不出来是端上确定性故障，重发也一样 → 丢弃该批，别让它永久堵住队首。
            Log.debug("诊断上传体编码失败，丢弃该批（\(batch.count) 条）", category: "diagnostics")
            return .dropBatch(suspendFor: nil)
        }

        do {
            let response = try await httpClient.performRaw(.postDiagnosticsEvents, body: data)
            let wire = try? DiagnosticsCoding.decoder.decode(DiagnosticsUploadResponse.self, from: response.body)
            return .accepted(wire?.sampleRateInfo)
        } catch let error as PurchasesError {
            guard let status = error.httpStatusCode else { return .retryLater }   // 传输层错误
            switch status {
            case 401, 403:
                Log.warn("诊断上传鉴权失败（HTTP \(status)），丢弃该批并停 1 小时", category: "diagnostics")
                return .dropBatch(suspendFor: Self.authSuspension)
            case 429:
                return .retryLater
            case 400...499:
                Log.debug("诊断上传被确定性拒绝（HTTP \(status)），丢弃该批（\(batch.count) 条）",
                          category: "diagnostics")
                return .dropBatch(suspendFor: nil)
            default:
                return .retryLater                                                // 5xx
            }
        } catch {
            return .retryLater
        }
    }

    // MARK: - 退避

    private func applyBackoff() {
        backoffSeconds = backoffSeconds <= 0
            ? Self.initialBackoff
            : min(backoffSeconds * 2, Self.maxBackoff)
        resumeAt = now().addingTimeInterval(backoffSeconds)
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

// MARK: - wire 形状（契约 §1.1 / §1.2）

/// 请求体。系统信息只走请求头，body 不重复（契约 §1.1）。
private struct DiagnosticsUploadBody: Encodable {
    let installID: String?
    let appUserID: String
    let sandbox: Bool
    let sentAtMs: Int64
    let events: [DiagnosticsEvent]

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case appUserID = "app_user_id"
        case sandbox
        case sentAtMs = "sent_at_ms"
        case events
    }
}

/// `202 {"accepted": n, "dropped": m, "sample_rate_info": 1.0}`。
private struct DiagnosticsUploadResponse: Decodable {
    let accepted: Int?
    let dropped: Int?
    let sampleRateInfo: Double?

    enum CodingKeys: String, CodingKey {
        case accepted
        case dropped
        case sampleRateInfo = "sample_rate_info"
    }
}
