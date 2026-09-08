//
//  IdentityManager.swift
//  匿名 ID 生成 / logIn / logOut（设计 §2 Identity）。
//
//  ID 格式与后端 `packages/core/src/ids.ts` 逐字对齐（裁决 C5、契约决策 11，ADR 0019 修订）：
//    - 匿名 App User ID = "$RDAnonymousID:" + 32 位无连字符**小写** hex（**自生成用这个**）
//    - 识别端同时认 "$RCAnonymousID:"：档 1/2 期间宿主把 RC 的 appUserID（**含 RC 匿名 ID**）
//      注入进来（dual-sdk-integration.md §6），认不出来就会把一个 RC 匿名用户当成具名用户
//    - 服务端的 "$RDUnattributedID:" 占位符前缀 SDK 侧**不生成也不认**：它只存在于服务端
//    - account_token   = 32 位无连字符小写 hex（转 Apple appAccountToken 时补连字符）
//    - app_user_id 合法性 = 非保留值、≤100 字符、不含 '/'
//

import Foundation

// MARK: - 校验错误（内部枚举，不进公开 API 面）

enum AppUserIDValidationError: Error, Equatable {
    /// 保留/禁用值（含空串）。
    case forbiddenValue
    /// 超过 100 字符。
    case tooLong
    /// 含 '/'（会破坏 URL 路径语义）。
    case containsSlash

    var message: String {
        switch self {
        case .forbiddenValue: return "forbidden app_user_id value"
        case .tooLong: return "app_user_id exceeds 100 chars"
        case .containsSlash: return "app_user_id must not contain '/'"
        }
    }
}

// MARK: - IdentityStorage

/// 身份持久化。设计 §6 铁律 3：受保护状态里不放会做 I/O 的依赖 —— UserDefaults 写单独 actor 隔离。
protocol IdentityStorage: Sendable {
    func storedAppUserID() async -> String?
    func setAppUserID(_ appUserID: String?) async
}

actor UserDefaultsIdentityStorage: IdentityStorage {

    static let appUserIDKey = "com.revenuedog.sdk.appUserID"

    // UserDefaults 本身线程安全，但不是 Sendable；此处由 actor 独占持有。
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func storedAppUserID() -> String? {
        defaults.string(forKey: Self.appUserIDKey)
    }

    func setAppUserID(_ appUserID: String?) {
        if let appUserID {
            defaults.set(appUserID, forKey: Self.appUserIDKey)
        } else {
            defaults.removeObject(forKey: Self.appUserIDKey)
        }
    }
}

actor InMemoryIdentityStorage: IdentityStorage {

    private var appUserID: String?

    init(appUserID: String? = nil) { self.appUserID = appUserID }

    func storedAppUserID() -> String? { appUserID }

    func setAppUserID(_ appUserID: String?) { self.appUserID = appUserID }
}

// MARK: - IdentityManager

actor IdentityManager {

    // MARK: 纯逻辑（可单测，无状态）

    /// 我方自生成的匿名前缀（ADR 0019）。冒用 RC 的前缀会让排查第一反应是「RC 给的」。
    static let anonymousPrefix = "$RDAnonymousID:"

    /// 历史与 RC 兼容前缀：**只识别、不生成**。档 1/2 宿主注入的 RC 匿名 ID 长这样。
    static let legacyAnonymousPrefix = "$RCAnonymousID:"

    static let maxAppUserIDLength = 100

    /// 与后端 `FORBIDDEN_APP_USER_IDS` 逐项对齐（比较前统一转小写）。
    static let forbiddenAppUserIDs: Set<String> = [
        "null", "none", "nil", "unidentified", "undefined", "unknown", "anonymous", "guest", "",
    ]

    /// 32 位无连字符小写 hex。
    static func uuid32() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// `$RDAnonymousID:` + 32 位小写 hex。
    static func generateAnonymousAppUserID() -> String {
        anonymousPrefix + uuid32()
    }

    /// 两个前缀都认：自生成的 `$RDAnonymousID:` 与宿主注入的 RC `$RCAnonymousID:`。
    static func isAnonymous(_ appUserID: String) -> Bool {
        appUserID.hasPrefix(anonymousPrefix) || appUserID.hasPrefix(legacyAnonymousPrefix)
    }

    /// 派生账户令牌：32 hex，同时满足 Apple appAccountToken(UUID) 与 Google obfuscatedAccountId(≤64)。
    static func generateAccountToken() -> String { uuid32() }

    /// `account_token`(32hex) → Apple `appAccountToken` 要求的标准 UUID 形状。
    static func accountTokenToUUIDString(_ token32: String) -> String? {
        guard token32.count == 32,
              token32.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let s = Array(token32)
        let grouped = [
            String(s[0..<8]), String(s[8..<12]), String(s[12..<16]), String(s[16..<20]), String(s[20..<32]),
        ]
        return grouped.joined(separator: "-")
    }

    static func accountTokenToUUID(_ token32: String) -> UUID? {
        accountTokenToUUIDString(token32).flatMap(UUID.init(uuidString:))
    }

    /// 契约：app_user_id 合法性（≤100 字符、非保留值、不含 '/'）。
    static func validate(_ appUserID: String) throws(AppUserIDValidationError) {
        if appUserID.isEmpty || forbiddenAppUserIDs.contains(appUserID.lowercased()) {
            throw .forbiddenValue
        }
        if appUserID.count > maxAppUserIDLength { throw .tooLong }
        if appUserID.contains("/") { throw .containsSlash }
    }

    static func isValid(_ appUserID: String) -> Bool {
        do { try validate(appUserID); return true } catch { return false }
    }

    // MARK: 有状态部分

    private let storage: any IdentityStorage
    private var currentAppUserID: String?

    init(storage: any IdentityStorage) {
        self.storage = storage
    }

    /// 启动期解析当前身份（设计 §1：强制启动期配置）。
    ///
    /// 优先级：`configure` 显式传入 > 已持久化的 ID > 新生成匿名 ID。
    @discardableResult
    func bootstrap(configuredAppUserID: String?) async throws -> String {
        if let configuredAppUserID {
            do {
                try Self.validate(configuredAppUserID)
            } catch {
                throw PurchasesError(code: .invalidAppUserIdError,
                                     message: error.message,
                                     userInfo: ["app_user_id": configuredAppUserID])
            }
            try await set(configuredAppUserID)
            return configuredAppUserID
        }
        if let stored = await storage.storedAppUserID(), Self.isValid(stored) {
            currentAppUserID = stored
            return stored
        }
        let anonymous = Self.generateAnonymousAppUserID()
        try await set(anonymous)
        Log.debug("生成匿名 App User ID: \(anonymous)", category: "identity")
        return anonymous
    }

    var appUserID: String {
        get throws {
            guard let currentAppUserID else {
                throw PurchasesError.configuration("IdentityManager 尚未 bootstrap")
            }
            return currentAppUserID
        }
    }

    var currentAppUserIDIfAny: String? { currentAppUserID }

    var isAnonymous: Bool {
        guard let currentAppUserID else { return true }
        return Self.isAnonymous(currentAppUserID)
    }

    /// logIn：校验 → 切换本地身份。后端一致性由 `GET /v1/subscribers/{id}` 的 200/201 给出 `created`。
    @discardableResult
    func logIn(_ appUserID: String) async throws -> String {
        do {
            try Self.validate(appUserID)
        } catch {
            throw PurchasesError(code: .invalidAppUserIdError,
                                 message: error.message,
                                 userInfo: ["app_user_id": appUserID])
        }
        try await set(appUserID)
        return appUserID
    }

    /// logOut：换回新的匿名身份（缓存按 appUserID 哈希隔离，设计 §4）。
    @discardableResult
    func logOut() async throws -> String {
        if isAnonymous {
            throw PurchasesError(code: .invalidAppUserIdError,
                                 message: "当前已是匿名身份，logOut 无意义")
        }
        let anonymous = Self.generateAnonymousAppUserID()
        try await set(anonymous)
        return anonymous
    }

    private func set(_ appUserID: String) async throws {
        currentAppUserID = appUserID
        await storage.setAppUserID(appUserID)
    }
}
