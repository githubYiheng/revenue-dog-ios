//
//  V041TestFactoriesTests.swift
//  0.4.1 SPI 工厂 `CustomerInfo.fromBackendResponse` / `Offerings.fromBackendResponse`：
//  与经 `Purchases` + 注入 transport 的真实路径得到的模型 `==`；`now` 注入生效；坏 JSON 抛错不崩。
//

import Foundation
import Testing
@_spi(RevenueDogInternal) @testable import RevenueDog

private func iso(_ string: String) -> Date {
    ISO8601DateFormatter().date(from: string)!
}

@MainActor
private func makeFactoryRig(products: [FakeProduct]) -> (Purchases, MockTransport) {
    Purchases.resetForTesting()
    let transport = MockTransport()
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(appUserID: "tester")
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("RevenueDogV041/\(UUID().uuidString)", isDirectory: true),
            storeKit: FakeStoreKitProvider(products: products),
            networkDelayScheduler: NoDelayScheduler(),
            attributionState: InMemoryAttributionStateStorage(),
            diagnostics: .isolated(),
        ),
    )
    return (purchases, transport)
}

// MARK: - 纯工厂（不碰单例）

@Suite("v0.4.1 · SPI 测试工厂")
struct V041TestFactoriesTests {

    private let officialData = Data(Fixtures.customerInfoOfficialExample.utf8)

    @Test("CustomerInfo 工厂 == wire 解码 + init(wireModel:now:)，不变式成立")
    func customerInfoMatchesWirePath() throws {
        let now = iso("2019-07-27T00:00:00Z")
        let info = try CustomerInfo.fromBackendResponse(officialData, now: now)
        let wire = try JSONDecoder().decode(CustomerInfoWireModel.self, from: officialData)
        #expect(info == CustomerInfo(wireModel: wire, now: now))

        #expect(info.originalAppUserID == "XXX-XXXXX-XXXXX-XX")
        #expect(info.activeSubscriptionProductIdentifiers
                == Set(info.subscriptionsByProductIdentifier.filter { $0.value.isActive }.keys))
        #expect(Set(info.allPurchaseDates.keys) == info.allPurchasedProductIdentifiers)
        #expect(Set(info.nonSubscriptionTransactions.map(\.transactionIdentifier))
                == info.nonSubscriptionTransactionIdentifiers)
    }

    @Test("now 注入生效：同一份 JSON、不同 now → 不同 isActive")
    func nowInjection() throws {
        // request_date = 2019-07-26T17:40:10Z；annual 到期 08-14、promo 到期 08-26。
        // 3 天 grace 内以 request_date 为参照 → 两个都活跃。
        let early = try CustomerInfo.fromBackendResponse(officialData, now: iso("2019-07-27T00:00:00Z"))
        #expect(early.activeSubscriptionProductIdentifiers == ["annual", "rc_promo_pro_cat_monthly"])
        #expect(early.subscriptionsByProductIdentifier["annual"]?.isActive == true)

        // 超出 grace → 以 now 为参照：annual 已过期、promo 仍活跃。
        let mid = try CustomerInfo.fromBackendResponse(officialData, now: iso("2019-08-20T00:00:00Z"))
        #expect(mid.activeSubscriptionProductIdentifiers == ["rc_promo_pro_cat_monthly"])
        #expect(mid.subscriptionsByProductIdentifier["annual"]?.isActive == false)

        let late = try CustomerInfo.fromBackendResponse(officialData, now: iso("2030-01-01T00:00:00Z"))
        #expect(late.activeSubscriptionProductIdentifiers.isEmpty)
        #expect(early != late)
        // 终身权益不受参照时间影响。
        #expect(late.entitlements["pro_cat"]?.isLifetime == true)
    }

    @Test("Offerings 工厂：按 platformProductIdentifier 挂上 product，挂不上的为 nil")
    func offeringsAttachProducts() throws {
        let monthly = StoreProduct(productIdentifier: "monthly_free_trial",
                                   localizedTitle: "Monthly", localizedDescription: "m",
                                   price: Decimal(string: "9.99")!, currencyCode: "USD",
                                   localizedPriceString: "$9.99",
                                   subscriptionPeriod: SubscriptionPeriod(unit: .month, value: 1),
                                   introductoryOffer: nil)
        let unrelated = StoreProduct(productIdentifier: "not_in_offerings",
                                     localizedTitle: "x", localizedDescription: "x",
                                     price: 1, currencyCode: "USD", localizedPriceString: "$1.00",
                                     subscriptionPeriod: nil, introductoryOffer: nil)
        let offerings = try Offerings.fromBackendResponse(Data(Fixtures.offeringsMinimalExample.utf8),
                                                          products: [monthly, unrelated])
        let current = try #require(offerings.current)
        #expect(current.monthly?.storeProduct == monthly)
        #expect(current.annual?.storeProduct == nil)
        #expect(current["consumable"]?.storeProduct == nil)
        #expect(current.availablePackages.count == 3)

        let bare = try Offerings.fromBackendResponse(Data(Fixtures.offeringsMinimalExample.utf8), products: [])
        #expect(bare.current?.availablePackages.allSatisfy { $0.storeProduct == nil } == true)
    }

    @Test("坏 JSON 抛错不崩（两个工厂）")
    func badJSONThrows() {
        #expect(throws: (any Error).self) { try CustomerInfo.fromBackendResponse(Data("not json".utf8)) }
        #expect(throws: (any Error).self) {
            // 契约必填 original_app_user_id 缺失
            try CustomerInfo.fromBackendResponse(Data("""
            { "request_date": "2019-07-26T17:40:10Z", "subscriber": { "first_seen": "2019-02-21T00:08:41Z" } }
            """.utf8))
        }
        #expect(throws: (any Error).self) { try Offerings.fromBackendResponse(Data("[1,2]".utf8), products: []) }
        #expect(throws: (any Error).self) { try Offerings.fromBackendResponse(Data(), products: []) }
    }
}

// MARK: - 与真实路径（Purchases + 注入 transport）对拍

extension PurchasesSingletonDomain {
@MainActor
@Suite("v0.4.1 · SPI 工厂与真实路径对拍", .serialized)
struct V041FactoryParityTests {

    @Test("CustomerInfo：工厂结果 == customerInfo(.fetchCurrent) 拿到的模型")
    func customerInfoParity() async throws {
        let (purchases, transport) = makeFactoryRig(products: [])
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(Fixtures.customerInfoOfficialExample), forPath: "/v1/subscribers/tester")

        let real = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)
        // request_date 在 2019：真实路径与工厂都以本地 now 为参照（超出 grace），now 差几毫秒不影响结果。
        let factory = try CustomerInfo.fromBackendResponse(Data(Fixtures.customerInfoOfficialExample.utf8))
        #expect(real == factory)
    }

    @Test("Offerings：工厂结果 == offerings() 拿到的模型（商店缺的商品两边都为 nil）")
    func offeringsParity() async throws {
        let fakes = [
            FakeProduct(productIdentifier: "monthly_free_trial",
                        subscriptionPeriod: SubscriptionPeriod(unit: .month, value: 1)),
            FakeProduct(productIdentifier: "consumable1"),
        ]
        let (purchases, transport) = makeFactoryRig(products: fakes)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(Fixtures.customerInfoOfficialExample), forPath: "/v1/subscribers/tester")
        await transport.enqueue(.json(Fixtures.offeringsMinimalExample), forPath: "/v1/subscribers/tester/offerings")

        let real = try await purchases.offerings()
        var products: [StoreProduct] = []
        for fake in fakes { products.append(await fake.makeStoreProduct()) }
        let factory = try Offerings.fromBackendResponse(Data(Fixtures.offeringsMinimalExample.utf8),
                                                        products: products)
        #expect(real == factory)
        #expect(real.current?.monthly?.storeProduct != nil)
        #expect(real.current?.annual?.storeProduct == nil)
    }
}
}
