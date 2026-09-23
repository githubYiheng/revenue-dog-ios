//
//  ForegroundRefreshTests.swift
//  回前台按 TTL 刷新 CustomerInfo（RC `updateAllCachesIfNeeded` 的 CustomerInfo 半边；Android 同款）。
//
//  背景：权益到期判定 3 天内以服务端 request_date 为参照，缓存不刷新就不会自己变成过期——
//  试用未转化、服务端已收权的用户，端上要靠回前台这一次拉取才能看到权益下掉。
//

import Foundation
import Testing
@testable import RevenueDog

private let persistedUser = "user-foreground"
private let subscribersPath = "/v1/subscribers/\(persistedUser)"
private let receiptsPath = "/v1/receipts"

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogForegroundRefresh/\(UUID().uuidString)", isDirectory: true)
}

/// 等 fire-and-forget 的 Task 跑到（调度收敛）：先纯 yield，再 1ms 小步兜底，总上限约 2 秒。
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        await Task.yield()
    }
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

/// 不门控的常规宿主：持久化具名身份、开关关（configure 不打任何请求）。
@MainActor
private func makeRig(cacheStorage: InMemoryCacheStorage = InMemoryCacheStorage(),
                     waitsForLogInBeforeSync: Bool = false) -> (Purchases, MockTransport) {
    Purchases.resetForTesting()
    let transport = MockTransport(stubs: [.json(Fixtures.customerInfoOfficialExample)])
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(appUserID: nil)
            .with(purchasesCompletedBy: .revenueDog)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!)
            .with(waitsForLogInBeforeSync: waitsForLogInBeforeSync),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(appUserID: persistedUser),
            cacheStorage: cacheStorage,
            transport: transport,
            pendingPurchasesDirectory: tempDirectory(),
            storeKit: nil,
            networkDelayScheduler: NoDelayScheduler(),
            identityGateScheduler: NoDelayScheduler(),
            diagnostics: .isolated(),
        ),
    )
    return (purchases, transport)
}

extension PurchasesSingletonDomain {
@MainActor
@Suite("回前台刷新 CustomerInfo（按 5 分钟 TTL）", .serialized, .timeLimit(.minutes(1)))
struct ForegroundRefreshTests {

    @Test("无缓存回前台 → 拉一次并推给门面；缓存新鲜时再回前台不发请求")
    func fetchesWhenMissingThenUsesFreshCache() async throws {
        let (purchases, transport) = makeRig()
        defer { Purchases.resetForTesting() }
        await Purchases.awaitConfigured()
        #expect(await transport.callCount(forPath: subscribersPath) == 0, "启动本身不拉")

        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.callCount(forPath: subscribersPath) == 1 })
        #expect(await eventually { await MainActor.run { purchases.cachedCustomerInfo != nil } })

        purchases.applicationDidBecomeActive()
        purchases.applicationDidBecomeActive()
        for _ in 0..<200 { await Task.yield() }
        #expect(await transport.callCount(forPath: subscribersPath) == 1, "5 分钟内缓存新鲜，不重复拉")
        #expect(await transport.callCount(forPath: receiptsPath) == 0)
    }

    @Test("进程内第一次回前台无条件拉（ADR 0075 第 1 条）；之后 invalidateCustomerInfoCache 再回前台 → 重新拉")
    func firstForegroundFetchesUnconditionallyThenInvalidationRefetches() async throws {
        let (purchases, transport) = makeRig()
        defer { Purchases.resetForTesting() }
        await Purchases.awaitConfigured()
        _ = try await purchases.customerInfo()
        #expect(await transport.callCount(forPath: subscribersPath) == 1)

        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.callCount(forPath: subscribersPath) == 2 }, "缓存新鲜也拉：进程内第一次")

        purchases.applicationDidBecomeActive()
        for _ in 0..<200 { await Task.yield() }
        #expect(await transport.callCount(forPath: subscribersPath) == 2, "第二次起按 TTL")

        purchases.invalidateCustomerInfoCache()
        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.callCount(forPath: subscribersPath) == 3 })
    }

    @Test("磁盘缓存已过 TTL（10 分钟前）→ 回前台重新拉")
    func refetchesWhenDiskCacheStale() async throws {
        // 先用一套 rig 拿到一份合法 CustomerInfo，再以「10 分钟前写入」的姿态种进新 rig 的存储。
        let (seed, _) = makeRig()
        await Purchases.awaitConfigured()
        let info = try await seed.customerInfo()
        Purchases.resetForTesting()

        let storage = InMemoryCacheStorage()
        await storage.write(DeviceCache.Entry(value: info, cachedAt: Date(timeIntervalSinceNow: -10 * 60)),
                            forKey: CacheKey.customerInfo(appUserID: persistedUser))
        let (purchases, transport) = makeRig(cacheStorage: storage)
        defer { Purchases.resetForTesting() }
        await Purchases.awaitConfigured()
        #expect(purchases.cachedCustomerInfo == info, "启动先把磁盘缓存端上来")

        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.callCount(forPath: subscribersPath) == 1 })
    }

    @Test("身份待确认（ADR 0046）→ 回前台不拉；logIn 确认后由 logIn 自己拉")
    func skipsWhileIdentityPending() async throws {
        let (purchases, transport) = makeRig(waitsForLogInBeforeSync: true)
        defer { Purchases.resetForTesting() }
        await Purchases.awaitConfigured()

        purchases.applicationDidBecomeActive()
        purchases.applicationDidBecomeActive()
        for _ in 0..<200 { await Task.yield() }
        #expect(await transport.callCount(forPath: subscribersPath) == 0, "待确认期间不许按旧身份拉")

        _ = try await purchases.logIn(persistedUser)
        #expect(await transport.callCount(forPath: subscribersPath) == 1)

        // 待确认期间没有消耗「进程内第一次」：确认后首次回前台仍无条件拉。
        purchases.applicationDidBecomeActive()
        #expect(await eventually { await transport.callCount(forPath: subscribersPath) == 2 })
    }
}
}
