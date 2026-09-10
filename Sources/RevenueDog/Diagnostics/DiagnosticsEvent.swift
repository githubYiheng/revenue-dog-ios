//
//  DiagnosticsEvent.swift
//  客户端诊断事件模型（设计 docs/plan/sdk-diagnostics.md §1 wire 契约）。
//
//  这些类型**全部 internal** —— 诊断是 SDK 内部行为，宿主唯一能碰的开关是
//  `Configuration.with(diagnosticsEnabled:)`。仓库「禁 public enum」只约束公开面，
//  内部 enum 照常使用（同 `Endpoint` / `AuthScope`）。
//
//  禁止进 fields（契约 §1.3 末段）：邮箱、姓名、设备名、任何 token/密钥、
//  请求/响应 body、JWS 原文；错误只取 SDK 自己的 `error_code` / `error_class`，绝不带 message。
//

import Foundation

// MARK: - fields 值域

/// `fields` 只允许标量与字符串数组（契约 §1.3）；字符串 200 字符封顶（与服务端截断口径一致）。
enum DiagnosticsFieldValue: Sendable, Equatable {

    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case strings([String])

    static let maxStringLength = 200

    /// 便捷构造：`Int` / 可选值在调用点写起来更短。
    static func int(_ value: Int) -> DiagnosticsFieldValue { .int(Int64(value)) }

    /// 按服务端同一口径截断字符串（服务端也截，不拒——两边同规则避免「本地过了服务端截了」的错觉）。
    var truncated: DiagnosticsFieldValue {
        switch self {
        case .string(let value):
            return .string(Self.truncate(value))
        case .strings(let values):
            return .strings(values.map(Self.truncate))
        case .int, .double, .bool:
            return self
        }
    }

    private static func truncate(_ value: String) -> String {
        value.count <= maxStringLength ? value : String(value.prefix(maxStringLength))
    }
}

extension DiagnosticsFieldValue: Codable {

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String].self) { self = .strings(value); return }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "诊断 fields 只允许标量与字符串数组")
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }
}

// MARK: - 事件

struct DiagnosticsEvent: Sendable, Equatable, Codable {

    /// 单条序列化上限（契约 §1.3：超限服务端计入 `dropped`）。SDK 侧超限直接不入队。
    static let maxSerializedBytes = 2048

    /// SDK 生成的 uuid —— 服务端 `INSERT OR IGNORE` 的幂等键（重发不会翻倍）。
    let id: String
    /// 设备时钟（ms epoch）。
    let tsMs: Int64
    let type: String
    let level: String
    let fields: [String: DiagnosticsFieldValue]

    enum CodingKeys: String, CodingKey {
        case id
        case tsMs = "ts_ms"
        case type
        case level
        case fields
    }

    /// 构造：nil 值直接丢弃（契约「fields 全部可选，缺失容忍」），字符串按 200 截断。
    static func make(type: String,
                     level: String,
                     fields: [String: DiagnosticsFieldValue?] = [:],
                     id: String = UUID().uuidString.lowercased(),
                     tsMs: Int64) -> DiagnosticsEvent {
        var clean: [String: DiagnosticsFieldValue] = [:]
        for (key, value) in fields {
            guard let value else { continue }
            clean[key] = value.truncated
        }
        return DiagnosticsEvent(id: id, tsMs: tsMs, type: type, level: level, fields: clean)
    }
}

// MARK: - 闭集常量（SDK 侧闭集，服务端开集）

/// 事件类型（契约 §1.3 表）。禁 public enum 与此无关 —— 这里用常量是为了
/// 「服务端不做枚举校验、未知 type 照收」，端上仍要有唯一拼写来源。
enum DiagnosticsEventType {
    static let sdkConfigured = "sdk_configured"
    static let identityLogin = "identity_login"
    static let identityLogout = "identity_logout"
    static let purchaseStarted = "purchase_started"
    static let purchaseResult = "purchase_result"
    static let transactionObserved = "transaction_observed"
    static let receiptPost = "receipt_post"
    static let finishDecision = "finish_decision"
    static let restore = "restore"
    static let sync = "sync"
    static let customerInfoFetch = "customer_info_fetch"
    static let offeringsFetch = "offerings_fetch"
    static let httpError = "http_error"
    static let sdkWarning = "sdk_warning"
}

enum DiagnosticsLevel {
    static let info = "info"
    static let warn = "warn"
    static let error = "error"
}

/// `sdk_warning.code` 的闭集 —— 每一条都对应代码里一处既有的运行时告警。
enum DiagnosticsWarningCode {
    /// 本地队列超限丢最旧。
    static let queueOverflow = "queue_overflow"
    /// `Purchases.configure` 被重复调用（第二次起被忽略）。
    static let duplicateConfigure = "duplicate_configure"
    /// 观察到的交易没有 JWS，无法上报。
    static let missingJWS = "missing_jws"
    /// 坑 #21：「成功购买」的交易 expirationDate 已在过去。
    static let expiredOnArrival = "expired_on_arrival"
    /// unfinished 轮询到上限仍有 finish 义务未清。
    static let finishBacklog = "finish_backlog"
    /// 属性同步被服务端确定性拒绝（坑 #127）。
    static let attributesRejected = "attributes_rejected"
    /// 后端不可用，CustomerInfo 回落 stale 缓存。
    static let staleCustomerInfoFallback = "stale_customer_info_fallback"
    /// offerings 拉取失败，回落缓存。
    static let offeringsCacheFallback = "offerings_cache_fallback"
}

/// `receipt_post` / `http_error` 的 `error_class`（契约 §1.3）。
enum DiagnosticsErrorClass {
    static let network = "network"
    static let server = "server"
    static let client = "client"
    static let auth = "auth"

    /// HTTP 状态码 → error_class。`nil` 状态码 = 传输层错误（超时/断网）。
    static func from(statusCode: Int?) -> String {
        guard let statusCode else { return network }
        switch statusCode {
        case 401, 403: return auth
        case 400...499: return client
        case 500...599: return server
        default: return client
        }
    }
}

/// `transaction_observed.source`：`handle()` 是单一处理通道，四条来路必须能分辨。
enum DiagnosticsTransactionSource: String, Sendable {
    case purchase
    case updates
    case unfinishedScan = "unfinished_scan"
    case currentEntitlements = "current_entitlements"
}

/// `purchase_result.outcome`。
enum DiagnosticsPurchaseOutcome {
    static let success = "success"
    static let cancelled = "cancelled"
    static let pending = "pending"
    static let error = "error"
}

/// `finish_decision` 的 decision / reason。
enum DiagnosticsFinishDecision {
    static let finished = "finished"
    static let kept = "kept"
}

enum DiagnosticsFinishReason {
    /// 后端 2xx 且允许 finish（铁律 P2）。
    static let serverAck = "server_ack"
    /// 确定性 4xx：重试无意义，交易已在服务端 raw 留档 → finish。
    static let deterministic4xx = "deterministic_4xx"
    /// 401/403：服务端鉴权中间件在留档之前，finish 即丢单 → 保留（ADR 0023）。
    static let authFailureKeep = "auth_failure_keep"
    /// 一次性交易未在响应 `non_subscriptions` 里被确认 → 绝不 finish（坑 #6）。
    static let consumableUnconfirmed = "consumable_unconfirmed"
    /// `.myApp`：finish 归宿主，SDK 一律不 finish。
    static let observerMode = "observer_mode"
    /// 重放路径只有 JWS、没有交易对象，finish 义务留给 unfinished 扫描配对。
    static let replayNoTransaction = "replay_no_transaction"
    /// 暂时性失败（5xx / 网络 / 404 / 408 / 429）：保留上下文等重放。
    static let retryableFailure = "retryable_failure"
}

// MARK: - 编解码

enum DiagnosticsCoding {

    /// `.sortedKeys` 让同一事件的序列化结果稳定（快照/断言友好）；
    /// `.withoutEscapingSlashes` 让 `/v1/subscribers/*` 这种 path 不被写成 `\/v1\/...`（省字节、可读）。
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()
}
