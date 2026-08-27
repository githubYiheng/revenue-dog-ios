//
//  DeviceCacheTests.swift
//  requestDate 3 天 grace（设计 §4「必抄」）+ TTL + 缓存键。
//

import Foundation
import Testing
@testable import RevenueDog

@Suite("DeviceCache — requestDate 3 天 grace")
struct EntitlementGracePolicyTests {

    private let requestDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var threeDays: TimeInterval { EntitlementGracePolicy.gracePeriod }

    @Test("grace 常量就是 3 天")
    func graceIsThreeDays() {
        #expect(threeDays == 3 * 24 * 60 * 60)
    }

    @Test("3 天内：一律用服务端时间，不信本地钟")
    func withinGraceUsesServerTime() {
        for offset in [0, 60, 3600, threeDays - 1] {
            let now = requestDate.addingTimeInterval(offset)
            #expect(EntitlementGracePolicy.referenceDate(requestDate: requestDate, now: now) == requestDate)
        }
    }

    @Test("本地钟被拨到过去（now < requestDate）：仍用服务端时间 —— 抗改时区薅羊毛")
    func clockMovedBackwardsUsesServerTime() {
        let now = requestDate.addingTimeInterval(-30 * 24 * 3600)
        #expect(EntitlementGracePolicy.referenceDate(requestDate: requestDate, now: now) == requestDate)
        #expect(EntitlementGracePolicy.isBeyondGrace(requestDate: requestDate, now: now) == false)
    }

    @Test("恰好 3 天：边界仍算「内」；超过 3 天：回退本地钟 —— 防永久离线白嫖")
    func beyondGraceFallsBackToLocalClock() {
        let boundary = requestDate.addingTimeInterval(threeDays)
        #expect(EntitlementGracePolicy.referenceDate(requestDate: requestDate, now: boundary) == requestDate)
        #expect(EntitlementGracePolicy.isBeyondGrace(requestDate: requestDate, now: boundary) == false)

        let beyond = requestDate.addingTimeInterval(threeDays + 1)
        #expect(EntitlementGracePolicy.referenceDate(requestDate: requestDate, now: beyond) == beyond)
        #expect(EntitlementGracePolicy.isBeyondGrace(requestDate: requestDate, now: beyond))
    }

    @Test("没有 requestDate（从未联网）：只能用本地钟")
    func missingRequestDate() {
        let now = Date()
        #expect(EntitlementGracePolicy.referenceDate(requestDate: nil, now: now) == now)
        #expect(EntitlementGracePolicy.isBeyondGrace(requestDate: nil, now: now))
    }

    @Test("grace 语义落到权益判定上：改表往前拨也拿不回已过期的权益")
    func entitlementActivationUsesGrace() throws {
        // 服务端时间 = requestDate，权益 1 小时后到期。
        let expiration = requestDate.addingTimeInterval(3600)
        let entitlement = EntitlementInfo(identifier: "pro",
                                          productIdentifier: "annual",
                                          latestPurchaseDate: requestDate,
                                          originalPurchaseDate: requestDate,
                                          expirationDate: expiration,
                                          gracePeriodExpiresDate: nil,
                                          store: .appStore,
                                          periodType: .normal,
                                          ownershipType: .purchased,
                                          isSandbox: false,
                                          unsubscribeDetectedAt: nil,
                                          billingIssueDetectedAt: nil,
                                          requestDate: requestDate)
        let infos = EntitlementInfos(all: ["pro": entitlement], requestDate: requestDate)

        // 本地钟被往回拨一年 → 仍以服务端时间判定 → 有效（因为服务端时间 < 到期时间）。
        #expect(infos.active(now: requestDate.addingTimeInterval(-365 * 24 * 3600)).count == 1)
        // 本地钟往前拨 2 天（仍在 grace 内）→ 用服务端时间 → 依然有效。
        #expect(infos.active(now: requestDate.addingTimeInterval(2 * 24 * 3600)).count == 1)
        // 超出 grace（离线 4 天）→ 回落本地钟 → 已过期。
        #expect(infos.active(now: requestDate.addingTimeInterval(4 * 24 * 3600)).isEmpty)
    }
}

@Suite("DeviceCache — TTL 与键")
struct DeviceCacheTests {

    @Test("TTL 常量：前台 5min / 后台 25h")
    func ttlConstants() {
        #expect(CacheTTL.foreground == 5 * 60)
        #expect(CacheTTL.background == 25 * 60 * 60)
        #expect(CacheTTL.ttl(isAppBackgrounded: false) == CacheTTL.foreground)
        #expect(CacheTTL.ttl(isAppBackgrounded: true) == CacheTTL.background)
    }

    @Test("staleness 判定")
    func staleness() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(CacheTTL.isStale(cachedAt: nil, now: now, isAppBackgrounded: false))
        #expect(!CacheTTL.isStale(cachedAt: now.addingTimeInterval(-299), now: now, isAppBackgrounded: false))
        #expect(CacheTTL.isStale(cachedAt: now.addingTimeInterval(-300), now: now, isAppBackgrounded: false))
        // 后台放宽到 25h
        #expect(!CacheTTL.isStale(cachedAt: now.addingTimeInterval(-3600), now: now, isAppBackgrounded: true))
        #expect(CacheTTL.isStale(cachedAt: now.addingTimeInterval(-26 * 3600), now: now, isAppBackgrounded: true))
        // 本地钟被拨到过去 → 视为过期，宁可多刷一次
        #expect(CacheTTL.isStale(cachedAt: now.addingTimeInterval(60), now: now, isAppBackgrounded: false))
    }

    @Test("缓存键含 appUserID 的 sha256，不含明文")
    func cacheKeys() {
        let appUserID = "$RCAnonymousID:0123456789abcdef0123456789abcdef"
        let key = CacheKey.customerInfo(appUserID: appUserID)

        #expect(!key.contains(appUserID))
        #expect(key.hasPrefix("customer-info."))
        let hash = CacheKey.hash(appUserID: appUserID)
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // 同一 ID 稳定、不同 ID 隔离
        #expect(CacheKey.customerInfo(appUserID: appUserID) == key)
        #expect(CacheKey.customerInfo(appUserID: "user_42") != key)
        #expect(CacheKey.offerings(appUserID: appUserID) != key)
    }

    @Test("CustomerInfo 缓存写入 / 读取 / 失效 / logOut 隔离")
    func cacheRoundTrip() async throws {
        let cache = DeviceCache(storage: InMemoryCacheStorage())
        let info = try CustomerInfo(
            wireModel: JSONDecoder().decode(CustomerInfoWireModel.self,
                                            from: Data(Fixtures.customerInfoOfficialExample.utf8))
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(await cache.cachedCustomerInfo(appUserID: "user_42") == nil)
        #expect(await cache.isCustomerInfoStale(appUserID: "user_42", now: now, isAppBackgrounded: false))

        await cache.cache(customerInfo: info, appUserID: "user_42", now: now)
        #expect(await cache.cachedCustomerInfo(appUserID: "user_42") == info)
        #expect(await cache.isCustomerInfoStale(appUserID: "user_42", now: now, isAppBackgrounded: false) == false)

        // 另一个身份读不到（键含 appUserID 哈希）。
        #expect(await cache.cachedCustomerInfo(appUserID: "user_43") == nil)

        // 显式失效。
        await cache.invalidateCustomerInfoCache(appUserID: "user_42")
        #expect(await cache.isCustomerInfoStale(appUserID: "user_42", now: now, isAppBackgrounded: false))
    }
}
