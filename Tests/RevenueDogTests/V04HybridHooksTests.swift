//
//  V04HybridHooksTests.swift
//  0.4.0：Flutter 插件需要的 M0 挂点（docs/plan/flutter-sdk-design.md §9 M0 iOS 清单）。
//  ① PlatformInfo 注入 + `X-Platform-Flavor-Version`（R1）
//  ② 内部记诊断入口（裁定 10）
//  ③ `IntroductoryOffer.price`（R9）
//  ⑤ `CustomerInfo` 明细字段（R6）+ 旧缓存格式解码
//  ⑥ `EntitlementInfo.productPlanIdentifier`（R7）
//  （④ `PurchaseResult.productIdentifier / purchaseDate` 的断言在 PurchaseFlowTests / V02GapTests 的既有用例里。）
//

import Foundation
import Testing
@_spi(RevenueDogInternal) @testable import RevenueDog

// MARK: - Fixtures

private let v04SubscriberJSON = """
{"request_date":"2026-09-10T00:00:00Z","request_date_ms":1789000000000,
 "subscriber":{"original_app_user_id":"tester","original_application_version":null,
   "original_purchase_date":null,"first_seen":"2026-09-01T00:00:00Z","last_seen":"2026-09-10T00:00:00Z",
   "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
"""

/// 覆盖面刻意铺开：活跃 / 宽限期内 / 已过期 / 无到期四种订阅；非订阅含空 id、无日期、同日期、空数组；
/// 权益的 product_plan_identifier 覆盖「权益自带 / 回退订阅 / 两边都没有 / 一次性商品」。
private let richCustomerInfoJSON = """
{
  "request_date": "2026-09-20T00:00:00Z",
  "request_date_ms": 1789862400000,
  "subscriber": {
    "original_app_user_id": "rich_user",
    "first_seen": "2026-01-01T00:00:00Z",
    "management_url": "https://apps.apple.com/account/subscriptions",
    "entitlements": {
      "pro":     { "expires_date": "2026-10-01T00:00:00Z", "product_identifier": "monthly",
                   "purchase_date": "2026-09-01T00:00:00Z", "product_plan_identifier": "ent-plan" },
      "legacy":  { "expires_date": "2026-08-01T00:00:00Z", "product_identifier": "weekly_old",
                   "purchase_date": "2026-07-25T00:00:00Z" },
      "gold":    { "expires_date": "2026-09-10T00:00:00Z", "grace_period_expires_date": "2026-09-25T00:00:00Z",
                   "product_identifier": "annual_lapsed", "purchase_date": "2025-09-10T00:00:00Z",
                   "product_plan_identifier": null },
      "forever": { "expires_date": null, "product_identifier": "lifetime", "purchase_date": null }
    },
    "subscriptions": {
      "monthly": {
        "expires_date": "2026-10-01T00:00:00Z", "purchase_date": "2026-09-01T00:00:00Z",
        "original_purchase_date": "2026-06-01T00:00:00Z", "store": "app_store", "is_sandbox": true,
        "period_type": "trial", "ownership_type": "PURCHASED", "unsubscribe_detected_at": null,
        "billing_issues_detected_at": null, "grace_period_expires_date": null, "refunded_at": null,
        "auto_resume_date": null, "store_transaction_id": "2000000111", "display_name": "Monthly"
      },
      "annual_lapsed": {
        "expires_date": "2026-09-10T00:00:00Z", "purchase_date": "2025-09-10T00:00:00Z",
        "grace_period_expires_date": "2026-09-25T00:00:00Z",
        "billing_issues_detected_at": "2026-09-10T00:00:00Z", "store": "play_store",
        "period_type": "normal", "ownership_type": "FAMILY_SHARED"
      },
      "weekly_old": {
        "expires_date": "2026-08-01T00:00:00Z", "purchase_date": "2026-07-25T00:00:00Z",
        "unsubscribe_detected_at": "2026-07-20T00:00:00Z", "refunded_at": "2026-07-26T00:00:00Z",
        "auto_resume_date": "2026-10-01T00:00:00Z", "product_plan_identifier": "weekly-base",
        "store": "play_store"
      },
      "no_expiry": { "store": "promotional" }
    },
    "non_subscriptions": {
      "coins": [
        { "id": "b2", "purchase_date": "2026-09-02T00:00:00Z", "store": "app_store" },
        { "id": "a1", "purchase_date": "2026-09-02T00:00:00Z", "store": "app_store",
          "original_purchase_date": "2026-09-02T00:00:00Z" },
        { "id": "",   "purchase_date": "2026-08-01T00:00:00Z", "store": "app_store" },
        { "id": "c0", "purchase_date": "2026-09-01T00:00:00Z", "store": "app_store" }
      ],
      "lifetime": [
        { "id": "z9", "store": "play_store", "store_transaction_id": "GPA.1", "is_sandbox": true,
          "display_name": "Lifetime" }
      ],
      "empty_product": []
    }
  }
}
"""

private func customerInfo(_ json: String, now: Date) throws -> CustomerInfo {
    let wire = try JSONDecoder().decode(CustomerInfoWireModel.self, from: Data(json.utf8))
    return CustomerInfo(wireModel: wire, now: now)
}

private func date(_ iso: String) -> Date {
    WireDate.parse(iso)!
}

/// 三条不变式（规格 ⑤）：任何 CustomerInfo 都必须满足。
private func assertInvariants(_ info: CustomerInfo, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(Set(info.subscriptionsByProductIdentifier.filter { $0.value.isActive }.keys)
            == info.activeSubscriptionProductIdentifiers, sourceLocation: sourceLocation)
    #expect(Set(info.allPurchaseDates.keys) == info.allPurchasedProductIdentifiers, sourceLocation: sourceLocation)
    #expect(Set(info.nonSubscriptionTransactions.map(\.transactionIdentifier))
            == info.nonSubscriptionTransactionIdentifiers, sourceLocation: sourceLocation)
    #expect(info.nonSubscriptionTransactions.count == info.nonSubscriptionTransactionIdentifiers.count,
            sourceLocation: sourceLocation)
    #expect(Set(info.allExpirationDates.keys) == Set(info.subscriptionsByProductIdentifier.keys),
            sourceLocation: sourceLocation)
}

// MARK: - ⑤ CustomerInfo 明细（纯模型，不碰单例）

@Suite("0.4.0 · CustomerInfo 明细字段（R6）")
struct V04CustomerInfoDetailTests {

    @Test("契约 §2.2 官方示例：不变式成立 + 各字段值")
    func officialExample() throws {
        let requestDate = date("2019-07-26T17:40:10Z")
        let info = try customerInfo(Fixtures.customerInfoOfficialExample, now: requestDate)
        assertInvariants(info)

        #expect(info.activeSubscriptionProductIdentifiers == ["annual", "rc_promo_pro_cat_monthly"])
        let annual = try #require(info.subscriptionsByProductIdentifier["annual"])
        #expect(annual.productIdentifier == "annual")
        #expect(annual.purchaseDate == date("2019-07-14T20:07:40Z"))
        #expect(annual.originalPurchaseDate == date("2019-02-21T00:42:05Z"))
        #expect(annual.expiresDate == date("2019-08-14T21:07:40Z"))
        #expect(annual.store == .playStore)
        #expect(annual.isSandbox)
        #expect(annual.periodType == .normal)
        #expect(annual.ownershipType == .purchased)
        #expect(annual.unsubscribeDetectedAt == date("2019-07-17T22:48:38Z"))
        #expect(annual.billingIssuesDetectedAt == nil)
        #expect(annual.gracePeriodExpiresDate == nil)
        #expect(annual.refundedAt == nil)
        #expect(annual.autoResumeDate == nil)
        #expect(annual.storeTransactionID == "GPA.6801-7988-0152-76034..5")
        #expect(annual.productPlanIdentifier == nil)
        #expect(annual.displayName == nil)
        #expect(annual.managementURL?.absoluteString == "https://apps.apple.com/account/subscriptions")
        #expect(annual.isActive)
        #expect(annual.willRenew == false)                    // 检测到关闭自动续订
        #expect(annual.requestDate == requestDate)

        let promo = try #require(info.subscriptionsByProductIdentifier["rc_promo_pro_cat_monthly"])
        #expect(promo.store == .promotional)
        #expect(promo.ownershipType == .familyShared)
        #expect(promo.willRenew)

        let tx = try #require(info.nonSubscriptionTransactions.first)
        #expect(info.nonSubscriptionTransactions.count == 1)
        #expect(tx.transactionIdentifier == "cadba0c81b")
        #expect(tx.productIdentifier == "onetime")
        #expect(tx.purchaseDate == date("2019-04-05T21:52:45Z"))
        #expect(tx.originalPurchaseDate == nil)
        #expect(tx.store == .appStore)
        #expect(tx.storeTransactionID == nil)
        #expect(tx.isSandbox)
        #expect(tx.displayName == nil)

        #expect(info.allExpirationDates == ["annual": date("2019-08-14T21:07:40Z"),
                                            "rc_promo_pro_cat_monthly": date("2019-08-26T01:02:16Z")])
        #expect(info.allPurchaseDates == ["annual": date("2019-07-14T20:07:40Z"),
                                          "rc_promo_pro_cat_monthly": date("2019-07-26T01:02:16Z"),
                                          "onetime": date("2019-04-05T21:52:45Z")])
        #expect(info.latestExpirationDate == date("2019-08-26T01:02:16Z"))
    }

    @Test("官方示例按本地钟（超 3 天 grace）解析：订阅全过期，不变式照样成立")
    func officialExampleBeyondGrace() throws {
        let info = try customerInfo(Fixtures.customerInfoOfficialExample, now: date("2026-09-23T00:00:00Z"))
        assertInvariants(info)
        #expect(info.activeSubscriptionProductIdentifiers.isEmpty)
        #expect(info.subscriptionsByProductIdentifier.values.allSatisfy { !$0.isActive })
    }

    @Test("丰富 fixture：活跃 / 宽限 / 过期 / 无到期，非订阅排序与过滤，购买与到期表")
    func richFixture() throws {
        let requestDate = date("2026-09-20T00:00:00Z")
        let info = try customerInfo(richCustomerInfoJSON, now: requestDate)
        assertInvariants(info)

        // 活跃集合：到期在后的 monthly、宽限期内的 annual_lapsed、无到期的 no_expiry
        #expect(info.activeSubscriptionProductIdentifiers == ["monthly", "annual_lapsed", "no_expiry"])

        let monthly = try #require(info.subscriptionsByProductIdentifier["monthly"])
        #expect(monthly.isActive && monthly.willRenew)
        #expect(monthly.periodType == .trial)
        #expect(monthly.displayName == "Monthly")
        #expect(monthly.storeTransactionID == "2000000111")
        #expect(monthly.managementURL?.absoluteString == "https://apps.apple.com/account/subscriptions")

        let lapsed = try #require(info.subscriptionsByProductIdentifier["annual_lapsed"])
        #expect(lapsed.isActive)                             // 已过到期，但宽限期未过
        #expect(lapsed.willRenew == false)                   // 扣款问题
        #expect(lapsed.gracePeriodExpiresDate == date("2026-09-25T00:00:00Z"))
        #expect(lapsed.billingIssuesDetectedAt == date("2026-09-10T00:00:00Z"))
        #expect(lapsed.ownershipType == .familyShared)

        let old = try #require(info.subscriptionsByProductIdentifier["weekly_old"])
        #expect(old.isActive == false)
        #expect(old.willRenew == false)
        #expect(old.refundedAt == date("2026-07-26T00:00:00Z"))
        #expect(old.autoResumeDate == date("2026-10-01T00:00:00Z"))
        #expect(old.productPlanIdentifier == "weekly-base")

        let noExpiry = try #require(info.subscriptionsByProductIdentifier["no_expiry"])
        #expect(noExpiry.isActive)
        #expect(noExpiry.willRenew == false)                 // 没有到期时间 → 不算会续订（同 EntitlementInfo）
        #expect(noExpiry.purchaseDate == nil)

        // 非订阅：跳过空 id；nil 日期最前；同日期按 id 升序
        #expect(info.nonSubscriptionTransactions.map(\.transactionIdentifier) == ["z9", "c0", "a1", "b2"])
        let lifetime = info.nonSubscriptionTransactions[0]
        #expect(lifetime.productIdentifier == "lifetime")
        #expect(lifetime.purchaseDate == nil)
        #expect(lifetime.store == .playStore)
        #expect(lifetime.storeTransactionID == "GPA.1")
        #expect(lifetime.isSandbox)
        #expect(lifetime.displayName == "Lifetime")
        #expect(info.nonSubscriptionTransactions[2].originalPurchaseDate == date("2026-09-02T00:00:00Z"))

        // 到期表：订阅全量，值可 nil
        #expect(info.allExpirationDates == [
            "monthly": date("2026-10-01T00:00:00Z"),
            "annual_lapsed": date("2026-09-10T00:00:00Z"),
            "weekly_old": date("2026-08-01T00:00:00Z"),
            "no_expiry": nil,
        ])
        #expect(info.latestExpirationDate == date("2026-10-01T00:00:00Z"))

        // 购买表：订阅 ∪ 一次性（含空数组的商品），一次性取最新一笔
        #expect(info.allPurchaseDates == [
            "monthly": date("2026-09-01T00:00:00Z"),
            "annual_lapsed": date("2025-09-10T00:00:00Z"),
            "weekly_old": date("2026-07-25T00:00:00Z"),
            "no_expiry": nil,
            "coins": date("2026-09-02T00:00:00Z"),
            "lifetime": nil,
            "empty_product": nil,
        ])
    }

    @Test("没有订阅：latestExpirationDate == nil，各表为空")
    func noSubscriptions() throws {
        let info = try customerInfo(v04SubscriberJSON, now: date("2026-09-10T00:00:00Z"))
        assertInvariants(info)
        #expect(info.latestExpirationDate == nil)
        #expect(info.subscriptionsByProductIdentifier.isEmpty)
        #expect(info.nonSubscriptionTransactions.isEmpty)
        #expect(info.allExpirationDates.isEmpty)
        #expect(info.allPurchaseDates.isEmpty)
    }

    // MARK: ⑥ EntitlementInfo.productPlanIdentifier

    @Test("R7：权益自带 / 回退订阅 / 两边都没有 / 一次性商品")
    func entitlementProductPlanIdentifier() throws {
        let info = try customerInfo(richCustomerInfoJSON, now: date("2026-09-20T00:00:00Z"))
        #expect(info.entitlements["pro"]?.productPlanIdentifier == "ent-plan")        // 权益上的值优先
        #expect(info.entitlements["legacy"]?.productPlanIdentifier == "weekly-base")  // 键缺失 → 回退订阅
        #expect(info.entitlements["gold"]?.productPlanIdentifier == nil)              // null + 订阅也没有
        #expect(info.entitlements["forever"]?.productPlanIdentifier == nil)           // 一次性商品
    }

    @Test("SubscriptionInfo.willRenew 与 EntitlementInfo.willRenew 同一规则")
    func willRenewSharedRule() throws {
        let info = try customerInfo(richCustomerInfoJSON, now: date("2026-09-20T00:00:00Z"))
        for (_, entitlement) in info.entitlements.all {
            guard let subscription = info.subscriptionsByProductIdentifier[entitlement.productIdentifier],
                  subscription.expiresDate == entitlement.expirationDate else { continue }
            #expect(subscription.willRenew == entitlement.willRenew, "\(entitlement.identifier)")
        }
    }

    // MARK: 缓存格式

    @Test("新格式经 DeviceCache 落盘往返：新增字段（含值为 nil 的字典项）逐字保真")
    func cacheRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogV04Cache/\(UUID().uuidString)", isDirectory: true)
        let info = try customerInfo(richCustomerInfoJSON, now: date("2026-09-20T00:00:00Z"))
        await DeviceCache(storage: FileCacheStorage(directory: directory)).cache(customerInfo: info, appUserID: "rich_user")

        let reread = try #require(await DeviceCache(storage: FileCacheStorage(directory: directory))
            .cachedCustomerInfo(appUserID: "rich_user"))
        #expect(reread == info)
        #expect(reread.allExpirationDates["no_expiry"] == .some(nil))
        #expect(reread.allPurchaseDates.keys.contains("empty_product"))
    }

    @Test("旧格式解码：0.3.x 写下的 CustomerInfo 缓存（无新增键）在 0.4.0 照常读出，新字段兜底为空")
    func legacyCacheFormatDecodes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogV04Legacy/\(UUID().uuidString)", isDirectory: true)
        let info = try customerInfo(richCustomerInfoJSON, now: date("2026-09-20T00:00:00Z"))

        // 以落盘编码器（ISO 8601 日期）写出，再剥掉 0.4.0 新增的全部键 = 0.3.x 的缓存形状。
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(DeviceCache.Entry(value: info, cachedAt: Date()))
        var entry = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var value = try #require(entry["value"] as? [String: Any])
        for key in ["subscriptionsByProductIdentifier", "nonSubscriptionTransactions",
                    "allExpirationDates", "allPurchaseDates", "latestExpirationDate"] {
            #expect(value.removeValue(forKey: key) != nil || key == "latestExpirationDate")
        }
        var entitlements = try #require(value["entitlements"] as? [String: Any])
        var all = try #require(entitlements["all"] as? [String: [String: Any]])
        for id in all.keys { all[id]?.removeValue(forKey: "productPlanIdentifier") }
        entitlements["all"] = all
        value["entitlements"] = entitlements
        entry["value"] = value
        let legacy = try JSONSerialization.data(withJSONObject: entry)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("productPlanIdentifier"))
        #expect(!String(decoding: legacy, as: UTF8.self).contains("allPurchaseDates"))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try legacy.write(to: directory.appendingPathComponent("\(CacheKey.customerInfo(appUserID: "rich_user")).json"))

        let cached = try #require(await DeviceCache(storage: FileCacheStorage(directory: directory))
            .cachedCustomerInfo(appUserID: "rich_user"))
        // 旧字段原样
        #expect(cached.originalAppUserID == "rich_user")
        #expect(cached.activeSubscriptionProductIdentifiers == info.activeSubscriptionProductIdentifiers)
        #expect(cached.allPurchasedProductIdentifiers == info.allPurchasedProductIdentifiers)
        #expect(cached.nonSubscriptionTransactionIdentifiers == info.nonSubscriptionTransactionIdentifiers)
        #expect(Set(cached.entitlements.all.keys) == Set(info.entitlements.all.keys))
        #expect(cached.managementURL == info.managementURL)
        // 新字段兜底
        #expect(cached.subscriptionsByProductIdentifier.isEmpty)
        #expect(cached.nonSubscriptionTransactions.isEmpty)
        #expect(cached.allExpirationDates.isEmpty)
        #expect(cached.allPurchaseDates.isEmpty)
        #expect(cached.latestExpirationDate == nil)
        #expect(cached.entitlements.all.values.allSatisfy { $0.productPlanIdentifier == nil })
    }
}

// MARK: - ③ IntroductoryOffer.price

@Suite("0.4.0 · 介绍性优惠数值价（R9）")
struct V04IntroductoryOfferPriceTests {

    @Test("SK2 映射规则：freeTrial 恒 0；payAsYouGo / payUpFront 取商店原值；unknown 取原值")
    func priceRule() {
        #expect(IntroductoryOffer.price(for: .freeTrial, offerPrice: Decimal(string: "0.99")!) == 0)
        #expect(IntroductoryOffer.price(for: .freeTrial, offerPrice: 0) == 0)
        #expect(IntroductoryOffer.price(for: .payAsYouGo, offerPrice: Decimal(string: "1.99")!)
                == Decimal(string: "1.99"))
        #expect(IntroductoryOffer.price(for: .payUpFront, offerPrice: Decimal(string: "29.99")!)
                == Decimal(string: "29.99"))
        #expect(IntroductoryOffer.price(for: .unknown, offerPrice: Decimal(string: "3.50")!)
                == Decimal(string: "3.50"))
    }

    @Test("三种 paymentMode 经 StoreKit 抽象进入公开模型，price 原样带出", arguments: [
        (IntroductoryOffer.OfferType.freeTrial, Decimal(0), "$0.00"),
        (IntroductoryOffer.OfferType.payAsYouGo, Decimal(string: "1.99")!, "$1.99"),
        (IntroductoryOffer.OfferType.payUpFront, Decimal(string: "29.99")!, "$29.99"),
    ])
    func mappedThroughStoreKitAbstraction(type: IntroductoryOffer.OfferType, price: Decimal, display: String) async {
        let offer = IntroductoryOffer(type: type,
                                      period: SubscriptionPeriod(unit: .month, value: 1),
                                      periodCount: 3,
                                      price: price,
                                      displayPrice: display,
                                      isEligible: true)
        let product = await FakeProduct(productIdentifier: "com.demo.monthly",
                                        subscriptionPeriod: SubscriptionPeriod(unit: .month, value: 1),
                                        introOffer: offer).makeStoreProduct()
        #expect(product.introductoryOffer?.type == type)
        #expect(product.introductoryOffer?.price == price)
        #expect(product.introductoryOffer?.displayPrice == display)
        #expect(product.introductoryOffer?.periodCount == 3)
        #expect(product.currencyCode == "USD")
    }

    @available(*, deprecated, message: "有意调用旧构造器")
    @Test("旧 5 参构造器保留：price 填 0")
    func deprecatedInitDefaultsToZero() {
        let offer = IntroductoryOffer(type: .payAsYouGo,
                                      period: SubscriptionPeriod(unit: .month, value: 1),
                                      periodCount: 3,
                                      displayPrice: "$1.99",
                                      isEligible: true)
        #expect(offer.price == 0)
        #expect(offer.displayPrice == "$1.99")
    }
}

// MARK: - ① ② 走门面（碰单例）

@MainActor
private func makeV04Rig(configuration: Configuration) -> (Purchases, MockTransport) {
    Purchases.resetForTesting()
    let transport = MockTransport()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogV04Hooks/\(UUID().uuidString)", isDirectory: true)
    let purchases = Purchases.configure(
        with: configuration.with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: directory,
            storeKit: nil,
            networkDelayScheduler: NoDelayScheduler(),
            attributionState: InMemoryAttributionStateStorage(),
            diagnostics: .isolated(),
        ),
    )
    return (purchases, transport)
}

extension PurchasesSingletonDomain {
@MainActor
@Suite("0.4.0 · 混合框架挂点（R1 / 裁定 10）", .serialized)
struct V04HybridFacadeTests {

    @Test("R1：with(platformFlavor: flutter, flavorVersion: 0.1.0) → 两个头都按配置发")
    func flutterFlavorHeaders() async throws {
        let (purchases, transport) = makeV04Rig(configuration: Configuration(apiKey: "pk_test_0123456789")
            .with(platformFlavor: "flutter", flavorVersion: "0.1.0"))
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v04SubscriberJSON))

        _ = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)

        let requests = await transport.capturedRequests
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "X-Platform-Flavor") == "flutter")
            #expect(request.value(forHTTPHeaderField: "X-Platform-Flavor-Version") == "0.1.0")
        }
    }

    @Test("R1：默认配置 → X-Platform-Flavor: native，且没有 X-Platform-Flavor-Version 头")
    func nativeDefaultHeaders() async throws {
        let (purchases, transport) = makeV04Rig(configuration: Configuration(apiKey: "pk_test_0123456789"))
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v04SubscriberJSON))

        _ = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)

        let requests = await transport.capturedRequests
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "X-Platform-Flavor") == "native")
            #expect(request.value(forHTTPHeaderField: "X-Platform-Flavor-Version") == nil)
            #expect(request.allHTTPHeaderFields?.keys.contains("X-Platform-Flavor-Version") == false)
        }
    }

    @Test("R1：Configuration 的默认值与 SPI 改写")
    func configurationValues() {
        let native = Configuration(apiKey: "pk_test")
        #expect(native.platformFlavor == "native")
        #expect(native.platformFlavorVersion == nil)
        let flutter = native.with(platformFlavor: "flutter", flavorVersion: nil)
        #expect(flutter.platformFlavor == "flutter")
        #expect(flutter.platformFlavorVersion == nil)
        #expect(SystemInfo.current(platformFlavor: "flutter", platformFlavorVersion: "0.1.0")
            .headers["X-Platform-Flavor-Version"] == "0.1.0")
        #expect(SystemInfo.current().headers["X-Platform-Flavor-Version"] == nil)
    }

    @Test("裁定 10：recordDiagnosticsEvent 透传为 info 事件，字段全为字符串")
    func recordEventPassesThrough() async throws {
        let (purchases, _) = makeV04Rig(configuration: Configuration(apiKey: "pk_test_0123456789"))
        defer { Purchases.resetForTesting() }

        await purchases.recordDiagnosticsEvent("hybrid_package_dropped",
                                               fields: ["offering_id": "default", "package_id": "ghost"])

        let events = await purchases.diagnosticsRecorder.queuedEvents()
        let event = try #require(events.first { $0.type == "hybrid_package_dropped" })
        #expect(event.level == DiagnosticsLevel.info)
        #expect(event.fields["offering_id"] == .string("default"))
        #expect(event.fields["package_id"] == .string("ghost"))
        #expect(event.fields.count == 2)
        #expect(event.appUserID?.isEmpty == false)          // 等过启动：带记录时刻的身份
    }

    @Test("裁定 10：非法事件名（大写 / 数字 / 空 / 超 64）丢弃，不抛", arguments: [
        "Hybrid_Event", "hybrid-event", "event1", "", String(repeating: "a", count: 65),
    ])
    func invalidNameDropped(name: String) async throws {
        let (purchases, _) = makeV04Rig(configuration: Configuration(apiKey: "pk_test_0123456789"))
        defer { Purchases.resetForTesting() }
        await purchases.recordDiagnosticsEvent("warm_up", fields: [:])      // 保证启动事件已落
        let before = await purchases.diagnosticsRecorder.queuedEvents().count

        await purchases.recordDiagnosticsEvent(name, fields: ["k": "v"])

        let events = await purchases.diagnosticsRecorder.queuedEvents()
        #expect(events.count == before)
        #expect(!events.contains { $0.type == name })
    }

    @Test("事件名规则：边界值")
    func nameRule() {
        #expect(Purchases.isValidDiagnosticsEventName("a"))
        #expect(Purchases.isValidDiagnosticsEventName("_"))
        #expect(Purchases.isValidDiagnosticsEventName(String(repeating: "z", count: 64)))
        #expect(!Purchases.isValidDiagnosticsEventName(String(repeating: "z", count: 65)))
        #expect(!Purchases.isValidDiagnosticsEventName("é"))
        #expect(!Purchases.isValidDiagnosticsEventName(" a"))
    }

    @Test("裁定 10：recordDiagnosticsWarning → sdk_warning{code, detail}，warn 级")
    func recordWarning() async throws {
        let (purchases, _) = makeV04Rig(configuration: Configuration(apiKey: "pk_test_0123456789"))
        defer { Purchases.resetForTesting() }

        await purchases.recordDiagnosticsWarning("hybrid_field_fallback", detail: "entitlement=pro")
        await purchases.recordDiagnosticsWarning("hybrid_option_ignored", detail: nil)

        let warnings = await purchases.diagnosticsRecorder.queuedEvents()
            .filter { $0.type == DiagnosticsEventType.sdkWarning }
        let fallback = try #require(warnings.first { $0.fields["code"] == .string("hybrid_field_fallback") })
        #expect(fallback.level == DiagnosticsLevel.warn)
        #expect(fallback.fields["detail"] == .string("entitlement=pro"))
        let ignored = try #require(warnings.first { $0.fields["code"] == .string("hybrid_option_ignored") })
        #expect(ignored.fields["detail"] == nil)
    }

    @Test("诊断关闭：两个入口都是空操作")
    func disabledIsNoOp() async throws {
        let (purchases, _) = makeV04Rig(configuration: Configuration(apiKey: "pk_test_0123456789")
            .with(diagnosticsEnabled: false))
        defer { Purchases.resetForTesting() }

        await purchases.recordDiagnosticsEvent("hybrid_duplicate_configure", fields: [:])
        await purchases.recordDiagnosticsWarning("hybrid_option_ignored", detail: "x")

        #expect(await purchases.diagnosticsRecorder.queuedCount() == 0)
    }
}
}
