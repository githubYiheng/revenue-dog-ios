//
//  IdentityManagerTests.swift
//  身份格式 / 校验 —— 与后端 packages/core/src/ids.ts 对齐。
//

import Foundation
import Testing
@testable import RevenueDog

@Suite("Identity — 匿名 ID 格式")
struct AnonymousIDFormatTests {

    /// ADR 0019：自生成的匿名 ID 用**我方**前缀 `$RDAnonymousID:`。
    /// 冒用 RC 的前缀会让排查第一反应是「RC 给的」（2026-09-08 身份分裂诊断实证）。
    @Test("匿名 ID = $RDAnonymousID: + 32 位无连字符小写 hex")
    func anonymousIDShape() throws {
        let id = IdentityManager.generateAnonymousAppUserID()

        #expect(id.hasPrefix("$RDAnonymousID:"))
        #expect(!id.hasPrefix("$RCAnonymousID:"))
        let suffix = String(id.dropFirst("$RDAnonymousID:".count))
        #expect(suffix.count == 32)
        #expect(!suffix.contains("-"))
        #expect(suffix.allSatisfy { $0.isHexDigit })
        #expect(suffix == suffix.lowercased())
        #expect(id.count == "$RDAnonymousID:".count + 32)
    }

    @Test("匿名 ID 每次生成都不同")
    func anonymousIDIsUnique() {
        let ids = (0..<64).map { _ in IdentityManager.generateAnonymousAppUserID() }
        #expect(Set(ids).count == ids.count)
    }

    /// **双前缀识别**（ADR 0019 决定 1）：自生成的 `$RDAnonymousID:` 与宿主注入的
    /// RC `$RCAnonymousID:` 都必须认。档 1/2 期间 Dog 的 appUserID 取自
    /// `RCPurchases.shared.appUserID`（含 RC 匿名 ID，dual-sdk-integration §6）——
    /// 少认一个就会把一个 RC 匿名用户当成具名用户，identify 走错分支。
    @Test("isAnonymous 双前缀判定（自生成 RD + 宿主注入的 RC）")
    func isAnonymous() {
        #expect(IdentityManager.isAnonymous(IdentityManager.generateAnonymousAppUserID()))
        #expect(IdentityManager.isAnonymous("$RDAnonymousID:deadbeef"))
        #expect(IdentityManager.isAnonymous("$RCAnonymousID:deadbeef"))
        #expect(!IdentityManager.isAnonymous("user_42"))
        #expect(!IdentityManager.isAnonymous("RCAnonymousID:deadbeef"))
        #expect(!IdentityManager.isAnonymous("RDAnonymousID:deadbeef"))
        #expect(!IdentityManager.isAnonymous("prefix$RCAnonymousID:deadbeef"))
        #expect(!IdentityManager.isAnonymous("prefix$RDAnonymousID:deadbeef"))
        // 占位符前缀只存在于服务端：SDK 不生成，也不需要认（认了反而会掩盖「它跑到客户端了」）
        #expect(!IdentityManager.isAnonymous("$RDUnattributedID:deadbeef"))
        #expect(!IdentityManager.isAnonymous(""))
    }

    @Test("account_token = 32 hex，转 UUID 形状按 8-4-4-4-12 分组")
    func accountToken() throws {
        let token = IdentityManager.generateAccountToken()
        #expect(token.count == 32)
        #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        let uuidString = try #require(IdentityManager.accountTokenToUUIDString(token))
        #expect(uuidString.count == 36)
        #expect(uuidString.split(separator: "-").map(\.count) == [8, 4, 4, 4, 12])
        #expect(IdentityManager.accountTokenToUUID(token) != nil)

        // 非法输入拒绝（与后端 accountTokenToUuid 的正则一致）。
        #expect(IdentityManager.accountTokenToUUIDString("ABCDEF") == nil)
        #expect(IdentityManager.accountTokenToUUIDString(String(repeating: "A", count: 32)) == nil)
        #expect(IdentityManager.accountTokenToUUIDString(String(repeating: "z", count: 32)) == nil)
    }
}

@Suite("Identity — app_user_id 校验")
struct AppUserIDValidationTests {

    @Test("禁用值全集（大小写不敏感）",
          arguments: ["null", "none", "nil", "unidentified", "undefined", "unknown", "anonymous", "guest", ""])
    func forbiddenValues(value: String) {
        #expect(throws: AppUserIDValidationError.forbiddenValue) {
            try IdentityManager.validate(value)
        }
        #expect(throws: AppUserIDValidationError.forbiddenValue) {
            try IdentityManager.validate(value.uppercased())
        }
    }

    @Test("超过 100 字符被拒绝，恰好 100 被接受")
    func lengthLimit() throws {
        #expect(throws: AppUserIDValidationError.tooLong) {
            try IdentityManager.validate(String(repeating: "a", count: 101))
        }
        try IdentityManager.validate(String(repeating: "a", count: 100))
        #expect(IdentityManager.isValid(String(repeating: "a", count: 100)))
    }

    @Test("含 '/' 被拒绝")
    func slash() {
        #expect(throws: AppUserIDValidationError.containsSlash) {
            try IdentityManager.validate("user/42")
        }
        #expect(throws: AppUserIDValidationError.containsSlash) {
            try IdentityManager.validate("/")
        }
    }

    @Test("合法值通过（含匿名 ID、email、含 $ 与 : 的 ID）")
    func validValues() throws {
        for value in ["user_42",
                      "firstlast@gmail.com",
                      IdentityManager.generateAnonymousAppUserID(),
                      "XXX-XXXXX-XXXXX-XX",
                      "用户42"] {
            try IdentityManager.validate(value)
        }
    }
}

@Suite("Identity — 生命周期")
struct IdentityLifecycleTests {

    @Test("无持久化 ID 时启动生成匿名身份并落存储")
    func bootstrapAnonymous() async throws {
        let storage = InMemoryIdentityStorage()
        let manager = IdentityManager(storage: storage)

        let id = try await manager.bootstrap(configuredAppUserID: nil)
        #expect(IdentityManager.isAnonymous(id))
        #expect(await storage.storedAppUserID() == id)
        #expect(await manager.isAnonymous)
    }

    @Test("已持久化的 ID 优先于新生成")
    func bootstrapUsesStored() async throws {
        let storage = InMemoryIdentityStorage(appUserID: "user_42")
        let manager = IdentityManager(storage: storage)

        #expect(try await manager.bootstrap(configuredAppUserID: nil) == "user_42")
        #expect(await manager.isAnonymous == false)
    }

    @Test("configure 显式传入的 ID 优先级最高，非法值直接报 invalidAppUserIdError")
    func bootstrapWithConfigured() async throws {
        let storage = InMemoryIdentityStorage(appUserID: "old_user")
        let manager = IdentityManager(storage: storage)
        #expect(try await manager.bootstrap(configuredAppUserID: "new_user") == "new_user")
        #expect(await storage.storedAppUserID() == "new_user")

        let other = IdentityManager(storage: InMemoryIdentityStorage())
        await #expect(throws: PurchasesError.self) {
            try await other.bootstrap(configuredAppUserID: "anonymous")
        }
    }

    @Test("logOut 换回新的匿名身份；匿名态再 logOut 报错")
    func logOut() async throws {
        let manager = IdentityManager(storage: InMemoryIdentityStorage())
        try await manager.bootstrap(configuredAppUserID: "user_42")

        let anonymous = try await manager.logOut()
        #expect(IdentityManager.isAnonymous(anonymous))

        await #expect(throws: PurchasesError.self) { try await manager.logOut() }
    }
}
