//
//  SubscriberAttributes.swift
//  Subscriber attributes 本地缓冲 + LWW + 未同步标记（设计 §1「属性与归因」/ §5「属性同步时机」）。
//
//  契约对齐（`docs/plan/api-contract-v1.md` §2.4，以服务端 `workers/api/src/attributes.ts` 为准）：
//  - 请求体 `{"attributes": {<key>: {"value": string, "updated_at_ms": int64}}}`
//  - **空串 = 删除**（服务端存 NULL 墓碑）。注意 `POST /v1/receipts` 的搭车通道
//    （`workers/api/src/receipts.ts`）只接受 string value（`typeof value !== "string"` 直接跳过），
//    所以墓碑一律编码成空串而**不是 JSON null** —— 两条上行通道语义才一致。
//  - LWW 按 `updated_at_ms`；服务端 UPSERT 条件是 `excluded.updated_at_ms >= 库中值`。
//  - 自定义键：`^[A-Za-z][A-Za-z0-9_-]{0,39}$`；保留键：`$` 前缀；value ≤ 500 字符；
//    每 subscriber 最多 50 个**非空**自定义属性（服务端超限直接 400，会连累整批 —— 端上先挡）。
//
//  坑矩阵：
//  - **#51**：`UserDefaults` 字典整体读-改-写非原子（RC 自认技术债）。这里的落盘布局是
//    **一属性一文件**（`<桶>/<sha256(key)>.json`），从存储结构上消灭 RMW；并发安全再由 actor 兜底。
//  - **#52**：`logIn` 前先 sync 旧身份属性；且**只有旧身份是匿名时**才把属性迁到新身份
//    （两个真实用户之间不迁移）—— 迁移动作见 `migrateIfOldIsAnonymous`。
//  - **#68**：会做磁盘 I/O 的依赖不进被保护状态 —— 本 actor 自己就是 I/O 边界，
//    orchestrator 只持有它的引用，不在自身状态里缓存属性字典。
//

import Foundation
import CryptoKit

// MARK: - 保留键（契约 §2.4 原文 35 个 + 决策 12 的 `$appleAds*` 系列）

/// 保留属性键（`$` 前缀）。命名空间，无 case —— 不构成「可扩展 public enum」。
enum SubscriberAttributeKeys {

    // 契约 §2.4 保留键全集（RC 原文）
    static let displayName = "$displayName"
    static let apnsTokens = "$apnsTokens"
    static let fcmTokens = "$fcmTokens"
    static let attConsentStatus = "$attConsentStatus"
    static let clevertapID = "$clevertapId"
    static let idfa = "$idfa"
    static let idfv = "$idfv"
    static let gpsAdID = "$gpsAdId"
    static let amazonAdID = "$amazonAdId"
    static let adjustID = "$adjustId"
    static let amplitudeDeviceID = "$amplitudeDeviceId"
    static let amplitudeUserID = "$amplitudeUserId"
    static let appsflyerID = "$appsflyerId"
    static let brazeAliasName = "$brazeAliasName"
    static let brazeAliasLabel = "$brazeAliasLabel"
    static let fbAnonID = "$fbAnonId"
    static let mparticleID = "$mparticleId"
    static let onesignalID = "$onesignalId"
    static let airshipChannelID = "$airshipChannelId"
    static let iterableUserID = "$iterableUserId"
    static let iterableCampaignID = "$iterableCampaignId"
    static let iterableTemplateID = "$iterableTemplateId"
    static let firebaseAppInstanceID = "$firebaseAppInstanceId"
    static let mixpanelDistinctID = "$mixpanelDistinctId"
    static let kochavaDeviceID = "$kochavaDeviceId"
    static let tenjinID = "$tenjinId"
    static let ip = "$ip"
    static let email = "$email"
    static let phoneNumber = "$phoneNumber"
    static let posthogUserID = "$posthogUserId"
    static let deviceVersion = "$deviceVersion"
    static let appleRefundHandlingPreference = "$appleRefundHandlingPreference"
    static let customerioID = "$customerioId"
    static let appstackID = "$appstackId"

    // 归因通用键（契约附录 A 决策 12：03 号调研自 RC 官方文档抓取的清单）
    static let mediaSource = "$mediaSource"
    static let campaign = "$campaign"
    static let adGroup = "$adGroup"
    static let ad = "$ad"
    static let keyword = "$keyword"
    static let creative = "$creative"

    /// 前缀判定：`$` 开头即保留键（与服务端 `attributes.ts` 的判定逐字一致）。
    static func isReserved(_ key: String) -> Bool { key.hasPrefix("$") }
}

// MARK: - 约束

/// 键/值约束（契约 §2.4 + 服务端 `attributes.ts` 常量）。
enum SubscriberAttributeLimits {

    /// 每 subscriber 最多 50 个**非空**自定义属性（不含保留键）。
    static let maxCustomAttributes = 50
    /// value ≤ 500 字符。
    static let maxValueLength = 500
    /// 自定义键：字母开头、≤40 字符、`[A-Za-z0-9_-]`。
    static func isValidCustomKey(_ key: String) -> Bool {
        guard (1...40).contains(key.count) else { return false }
        guard let first = key.first, first.isASCII, first.isLetter else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// 键是否可上行（保留键放行，自定义键按正则）。
    static func isValidKey(_ key: String) -> Bool {
        SubscriberAttributeKeys.isReserved(key) ? key.count > 1 : isValidCustomKey(key)
    }
}

// MARK: - 模型

/// 一条本地缓冲的属性。
struct SubscriberAttribute: Codable, Sendable, Equatable {

    let key: String
    /// `nil` = 墓碑（删除）。上行编码为空串（见文件头注：两条上行通道都以空串为删除）。
    let value: String?
    /// LWW 时间戳（毫秒 epoch）。
    let updatedAtMs: Int64
    /// 是否已同步到服务端。
    var isSynced: Bool

    var isTombstone: Bool { value == nil }
}

/// 上行编码（`{"value": "...", "updated_at_ms": 123}`）。
struct SubscriberAttributeWire: Encodable, Sendable, Equatable {

    let value: String
    let updatedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case value
        case updatedAtMs = "updated_at_ms"
    }

    init(_ attribute: SubscriberAttribute) {
        self.value = attribute.value ?? ""   // 墓碑 → 空串
        self.updatedAtMs = attribute.updatedAtMs
    }
}

extension [SubscriberAttribute] {

    /// 转成上行 map。同键取最后一条（本地存储天然一键一条，这里只是防御）。
    var wireMap: [String: SubscriberAttributeWire] {
        Dictionary(map { ($0.key, SubscriberAttributeWire($0)) }, uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Store

/// 属性本地缓冲：**按 appUserID 分桶**、持久化、未同步标记（任务书 M3 属性项）。
///
/// 目录布局（#51：一属性一文件，无字典 RMW）：
/// ```
/// <directory>/<sha256(appUserID)>/<sha256(key)>.json
/// ```
actor SubscriberAttributesStore {

    private let directory: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() throws -> URL {
        try SDKFileLocations.subdirectory(named: "Attributes")
    }

    // MARK: 路径

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func bucket(_ appUserID: String) -> URL {
        directory.appendingPathComponent(Self.hash(appUserID), isDirectory: true)
    }

    private func url(appUserID: String, key: String) -> URL {
        bucket(appUserID).appendingPathComponent("\(Self.hash(key)).json", isDirectory: false)
    }

    // MARK: 读

    func all(appUserID: String) -> [SubscriberAttribute] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: bucket(appUserID),
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SubscriberAttribute.self, from: data)
            }
            .sorted { $0.key < $1.key }   // 稳定顺序 → 出站快照可 diff
    }

    /// 待同步集合（未同步标记）。
    func unsynced(appUserID: String) -> [SubscriberAttribute] {
        all(appUserID: appUserID).filter { !$0.isSynced }
    }

    func attribute(forKey key: String, appUserID: String) -> SubscriberAttribute? {
        guard let data = try? Data(contentsOf: url(appUserID: appUserID, key: key)) else { return nil }
        return try? decoder.decode(SubscriberAttribute.self, from: data)
    }

    // MARK: 写

    /// 写入一批属性。
    ///
    /// - `value == nil` 或空串 = 墓碑（删除，契约 §2.4）。
    /// - LWW：新时间戳取 `max(now, 库中值 + 1)` —— 本地 setter 表达的是「用户此刻的最新意图」，
    ///   必须赢；`+1` 保证在本地时钟被拨回过去时服务端的
    ///   `excluded.updated_at_ms >= 库中值` 条件仍然成立（不然写入会被服务端静默丢弃）。
    /// - 返回被拒绝的键（键名非法 / value 超 500 / 触及 50 上限）—— setter 是 fire-and-forget，
    ///   不抛错，只回报 + 打日志；服务端对非法键整批 400，端上先挡住才不会连累同批的合法键。
    @discardableResult
    func set(_ attributes: [String: String?], appUserID: String, now: Date = Date()) -> [String] {
        guard !attributes.isEmpty else { return [] }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var rejected: [String] = []
        var accepted: [(key: String, value: String?)] = []

        for (key, raw) in attributes.sorted(by: { $0.key < $1.key }) {
            guard SubscriberAttributeLimits.isValidKey(key) else {
                rejected.append(key)
                continue
            }
            // 空串与 nil 同义：都是墓碑
            let normalized: String? = (raw?.isEmpty == false) ? raw : nil
            if let normalized, normalized.count > SubscriberAttributeLimits.maxValueLength {
                rejected.append(key)
                continue
            }
            accepted.append((key, normalized))
        }

        // 50 个自定义属性上限（与服务端 `attributes.ts` 的计数口径一致：只数**非空**的自定义键）
        let existing = all(appUserID: appUserID)
        let incomingCustomKeys = Set(accepted.filter { !SubscriberAttributeKeys.isReserved($0.key) }.map(\.key))
        let existingCustomCount = existing
            .filter { !SubscriberAttributeKeys.isReserved($0.key) && !$0.isTombstone
                      && !incomingCustomKeys.contains($0.key) }
            .count
        var budget = SubscriberAttributeLimits.maxCustomAttributes - existingCustomCount

        var toWrite: [(key: String, value: String?)] = []
        for item in accepted {
            let isNewCustomValue = !SubscriberAttributeKeys.isReserved(item.key) && item.value != nil
            if isNewCustomValue {
                guard budget > 0 else {
                    rejected.append(item.key)
                    continue
                }
                budget -= 1
            }
            toWrite.append(item)
        }

        for item in toWrite {
            let previous = attribute(forKey: item.key, appUserID: appUserID)
            // 值与同步状态都没变 → 不重写文件，也不重置 isSynced（避免每次前后台都白发一次请求）
            if let previous, previous.value == item.value, previous.isSynced { continue }
            let updatedAtMs = max(nowMs, (previous?.updatedAtMs ?? 0) + 1)
            write(SubscriberAttribute(key: item.key,
                                      value: item.value,
                                      updatedAtMs: updatedAtMs,
                                      isSynced: false),
                  appUserID: appUserID)
        }

        if !rejected.isEmpty {
            Log.warn("属性被拒绝（键名非法 / value>500 / 超 50 自定义上限）：\(rejected.sorted())",
                     category: "attributes")
        }
        return rejected
    }

    /// 标记已同步。
    ///
    /// 只对「时间戳与上行时一致」的条目生效 —— 上行途中被新的 setter 覆盖过的属性
    /// 必须保持未同步，否则那次更新会永远发不出去。
    /// 已同步的**墓碑**直接删文件：服务端已存 NULL，本地不必再留（也让 50 上限计数干净）。
    func markSynced(_ attributes: [SubscriberAttribute], appUserID: String) {
        for sent in attributes {
            guard let current = attribute(forKey: sent.key, appUserID: appUserID),
                  current.updatedAtMs == sent.updatedAtMs else { continue }
            if current.isTombstone {
                try? FileManager.default.removeItem(at: url(appUserID: appUserID, key: sent.key))
                continue
            }
            var synced = current
            synced.isSynced = true
            write(synced, appUserID: appUserID)
        }
    }

    /// 坑 #52：`logIn` 时**只有旧身份是匿名**才把属性迁到新身份（两个真实用户之间不迁移）。
    /// 迁移过去的条目一律标记为未同步 —— 它们在新 customer 下还没落过库。
    func migrateIfOldIsAnonymous(from oldAppUserID: String, to newAppUserID: String) {
        guard oldAppUserID != newAppUserID,
              IdentityManager.isAnonymous(oldAppUserID) else { return }
        let source = all(appUserID: oldAppUserID)
        guard !source.isEmpty else { return }
        for item in source {
            // 新身份下已有同键且更新 → 不覆盖（LWW）
            if let existing = attribute(forKey: item.key, appUserID: newAppUserID),
               existing.updatedAtMs >= item.updatedAtMs { continue }
            write(SubscriberAttribute(key: item.key,
                                      value: item.value,
                                      updatedAtMs: item.updatedAtMs,
                                      isSynced: false),
                  appUserID: newAppUserID)
        }
        clear(appUserID: oldAppUserID)
        Log.debug("匿名身份属性已迁移到 \(newAppUserID)（\(source.count) 条，#52）", category: "attributes")
    }

    func clear(appUserID: String) {
        try? FileManager.default.removeItem(at: bucket(appUserID))
    }

    // MARK: 私有

    private func write(_ attribute: SubscriberAttribute, appUserID: String) {
        do {
            try SDKFileLocations.ensureDirectory(bucket(appUserID))
            let data = try encoder.encode(attribute)
            try data.write(to: url(appUserID: appUserID, key: attribute.key), options: .atomic)
        } catch {
            Log.warn("属性落盘失败（key=\(attribute.key)）: \(error)", category: "attributes")
        }
    }
}

// MARK: - 上行请求体

/// `POST /v1/subscribers/{app_user_id}/attributes` 请求体（契约 §2.4）。
struct SubscriberAttributesBody: Encodable, Sendable {
    let attributes: [String: SubscriberAttributeWire]
}
