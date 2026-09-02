//
//  EntitlementDiff.swift
//  权益 diff 上报的 wire 层（迁移方案 v2.1 §5 M-3；档 1 核心指标）。
//
//  档 1（观察者期）RC 是权威、Dog 只看不动。要证明 Dog 的权益装配与 RC 一致，
//  唯一可信的口径是**按用户逐个比对两份 `entitlements.active` 快照**
//  （migration-strategy §1 档 1 第 3 条）。
//
//  铁律：**匹配由服务端算，客户端不判**。端上只负责如实提交两份快照 ——
//  端上判等会把「时钟偏移 / 3 天 grace / 缓存延迟」这些本该在服务端归因的差异
//  提前吃掉，日聚合的一致率就不可信了。
//

import Foundation

// MARK: - 请求体

/// `POST /v1/diagnostics/entitlement-diff` 请求体。
///
/// 形状按迁移方案 v2.1 §5 M-3 定死。`request_date_ms` / `sdk_version` / `app_version` /
/// `os_version` 一律**显式发 null**（不省略）：服务端按固定形状解析，省略与 null 在
/// JSON schema 校验上不是一回事。
struct EntitlementDiffBody: Encodable, Sendable {

    let appUserID: String
    let observedAtMs: Int64
    let rc: Side
    let dog: Side
    let context: Context

    enum CodingKeys: String, CodingKey {
        case appUserID = "app_user_id"
        case observedAtMs = "observed_at_ms"
        case rc
        case dog
        case context
    }

    /// 一侧的权益快照。`active` = entitlement_id → 到期毫秒（终身/无到期 = null）。
    struct Side: Encodable, Sendable {

        let active: [String: Int64?]
        let requestDateMs: Int64?
        /// 只有 RC 侧带（Dog 侧的 SDK 版本走 `X-Version` 头，不重复发）。
        let sdkVersion: String?
        /// Dog 侧不发 `sdk_version` 键（形状里它只属于 rc）。
        let includesSDKVersion: Bool

        enum CodingKeys: String, CodingKey {
            case active
            case requestDateMs = "request_date_ms"
            case sdkVersion = "sdk_version"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(active, forKey: .active)
            try container.encode(requestDateMs, forKey: .requestDateMs) // nil → 显式 null
            if includesSDKVersion {
                try container.encode(sdkVersion, forKey: .sdkVersion)   // nil → 显式 null
            }
        }
    }

    struct Context: Encodable, Sendable {

        let appVersion: String?
        let osVersion: String?

        enum CodingKeys: String, CodingKey {
            case appVersion = "app_version"
            case osVersion = "os_version"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(appVersion, forKey: .appVersion)
            try container.encode(osVersion, forKey: .osVersion)
        }
    }

    /// `[String: Date?]` → `[String: Int64?]`（毫秒 epoch；nil 保持 nil = 终身权益）。
    static func activeMap(_ source: [String: Date?]) -> [String: Int64?] {
        source.mapValues { date in date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } }
    }
}

// MARK: - 响应

/// `POST /v1/diagnostics/entitlement-diff` 的 201 响应（迁移方案 v2.1 §5 M-3）。
///
/// `match` / `diff` 都是**服务端算出来的**；SDK 只做解析与透出，不参与判定。
public struct EntitlementDiffResult: Sendable, Hashable, Codable {

    /// 服务端判定的两侧快照是否一致。
    public let match: Bool
    /// 差异明细（服务端归因用）。
    public let diff: Diff
    /// 本次上报是否被服务端按「每用户每天 N 次」节流丢弃（true = 未计入聚合）。
    public let capped: Bool

    public struct Diff: Sendable, Hashable, Codable {

        /// 只有 RC 认为有效的 entitlement_id。
        public let onlyRC: [String]
        /// 只有 Dog 认为有效的 entitlement_id。
        public let onlyDog: [String]
        /// 两侧都有、但 `expires_at` 不一致的 entitlement_id。
        public let expiresMismatch: [String]

        enum CodingKeys: String, CodingKey {
            case onlyRC = "only_rc"
            case onlyDog = "only_dog"
            case expiresMismatch = "expires_mismatch"
        }

        public init(onlyRC: [String] = [], onlyDog: [String] = [], expiresMismatch: [String] = []) {
            self.onlyRC = onlyRC
            self.onlyDog = onlyDog
            self.expiresMismatch = expiresMismatch
        }

        // 容错解码（设计 §8）：服务端将来给 diff 加字段/漏发数组，老 SDK 不摔。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.onlyRC = (try? container.decode([String].self, forKey: .onlyRC)) ?? []
            self.onlyDog = (try? container.decode([String].self, forKey: .onlyDog)) ?? []
            self.expiresMismatch = (try? container.decode([String].self, forKey: .expiresMismatch)) ?? []
        }
    }

    public init(match: Bool, diff: Diff, capped: Bool) {
        self.match = match
        self.diff = diff
        self.capped = capped
    }

    /// `match` 是本端点的核心字段，缺失即破契约 → 整体解码失败（让宿主看得见）。
    /// `diff` / `capped` 走容错缺省。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.match = try container.decode(Bool.self, forKey: .match)
        self.diff = (try? container.decode(Diff.self, forKey: .diff)) ?? Diff()
        self.capped = (try? container.decode(Bool.self, forKey: .capped)) ?? false
    }
}
