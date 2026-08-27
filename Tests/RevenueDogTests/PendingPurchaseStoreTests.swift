//
//  PendingPurchaseStoreTests.swift
//  购买上下文抗崩溃持久化 round-trip（设计 §3 铁律 P3）。
//

import Foundation
import Testing
@testable import RevenueDog

@Suite("PendingPurchaseStore")
struct PendingPurchaseStoreTests {

    private func makeStore() throws -> (PendingPurchaseStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (PendingPurchaseStore(directory: directory), directory)
    }

    private func context(key: String,
                         product: String = "monthly_free_trial",
                         createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> PendingPurchaseContext {
        PendingPurchaseContext(key: key,
                               productIdentifier: product,
                               appUserID: "$RCAnonymousID:0123456789abcdef0123456789abcdef",
                               presentedOfferingIdentifier: "default",
                               presentedPackageIdentifier: "$rc_monthly",
                               accountToken: "0123456789abcdef0123456789abcdef",
                               initiationSource: .purchase,
                               createdAt: createdAt)
    }

    @Test("文件名 = sha256(key) 的小写 hex，不含明文 key")
    func fileNameIsSHA256() throws {
        let name = PendingPurchaseStore.fileName(forKey: "2000000123456789")
        #expect(name.hasSuffix(".json"))
        let hex = String(name.dropLast(".json".count))
        #expect(hex.count == 64)
        #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(!name.contains("2000000123456789"))
        // 稳定 + 区分
        #expect(PendingPurchaseStore.fileName(forKey: "2000000123456789") == name)
        #expect(PendingPurchaseStore.fileName(forKey: "2000000123456780") != name)
    }

    @Test("落盘 → 读取 round-trip 完整保留上下文")
    func roundTrip() async throws {
        let (store, _) = try makeStore()
        let original = context(key: "2000000123456789")

        try await store.save(original)
        let restored = try #require(await store.context(forKey: "2000000123456789"))
        #expect(restored == original)
        #expect(restored.presentedOfferingIdentifier == "default")
        #expect(restored.accountToken == "0123456789abcdef0123456789abcdef")
        #expect(restored.initiationSource == .purchase)
    }

    @Test("新建 store 实例仍读得到（模拟崩溃后冷启动重放）")
    func survivesProcessRestart() async throws {
        let (store, directory) = try makeStore()
        try await store.save(context(key: "tx-1"))

        let reopened = PendingPurchaseStore(directory: directory)
        let restored = try #require(await reopened.context(forKey: "tx-1"))
        #expect(restored.productIdentifier == "monthly_free_trial")
    }

    @Test("枚举未完成项按落盘时间升序（串行重放要求）")
    func enumerationIsOrdered() async throws {
        let (store, _) = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.save(context(key: "c", createdAt: base.addingTimeInterval(300)))
        try await store.save(context(key: "a", createdAt: base))
        try await store.save(context(key: "b", createdAt: base.addingTimeInterval(60)))

        let all = await store.all()
        #expect(all.map(\.key) == ["a", "b", "c"])
    }

    @Test("删除：只在终态才调用；删完读不到，其余项不受影响")
    func removal() async throws {
        let (store, _) = try makeStore()
        try await store.save(context(key: "tx-1"))
        try await store.save(context(key: "tx-2"))

        await store.remove(forKey: "tx-1")
        #expect(await store.context(forKey: "tx-1") == nil)
        #expect(await store.context(forKey: "tx-2") != nil)
        #expect(await store.all().count == 1)

        await store.removeAll()
        #expect(await store.all().isEmpty)
    }

    @Test("交易 id 就位后可以从 productId 键迁移到 transactionId 键")
    func rekey() async throws {
        let (store, _) = try makeStore()
        try await store.save(context(key: "monthly_free_trial"))

        let moved = try #require(await store.rekey(from: "monthly_free_trial", to: "2000000123456789"))
        #expect(moved.key == "2000000123456789")
        #expect(moved.productIdentifier == "monthly_free_trial")
        #expect(await store.context(forKey: "monthly_free_trial") == nil)
        #expect(await store.context(forKey: "2000000123456789") != nil)
        #expect(await store.all().count == 1)
    }

    @Test("重放计数递增并回写")
    func replayCount() async throws {
        let (store, _) = try makeStore()
        try await store.save(context(key: "tx-1"))

        #expect(try await store.incrementReplayCount(forKey: "tx-1")?.replayCount == 1)
        #expect(try await store.incrementReplayCount(forKey: "tx-1")?.replayCount == 2)
        #expect(await store.context(forKey: "tx-1")?.replayCount == 2)
        #expect(try await store.incrementReplayCount(forKey: "missing") == nil)
    }

    @Test("坏文件不会毒死枚举，读取时自动丢弃")
    func corruptedFileIsDiscarded() async throws {
        let (store, directory) = try makeStore()
        try await store.save(context(key: "good"))
        let badURL = directory.appendingPathComponent(PendingPurchaseStore.fileName(forKey: "bad"))
        try Data("{ not json".utf8).write(to: badURL)

        #expect(await store.context(forKey: "bad") == nil)
        #expect(await store.all().map(\.key) == ["good"])
    }
}
