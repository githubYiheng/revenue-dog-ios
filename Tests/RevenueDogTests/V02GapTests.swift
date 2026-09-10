//
//  V02GapTests.swift
//  v0.2.0 的三个缺口（STATUS 待办 39 A/B/C）：
//  A. `Package.storeProduct` 不再恒 nil —— offerings 拉到后用 StoreKit 批量补齐商品详情；
//  B. `PurchaseResult.isPending` —— Ask-to-Buy / SCA 的显式标志；
//  C. 扣款后上报失败的两个独立错误码 —— `purchasePendingServerConfirmation`（交易保留、会重放）
//     与 `purchaseRejectedByServer`（确定性 4xx，已 finish、不会再有权益）。
//
//  （D 在 `PublicTransportInjectionTests.swift`，E 的回归锁在 `M4FaultInjectionTests` 崩溃三切点。）
//

import Foundation
import Testing
@testable import RevenueDog

// MARK: - Fixtures

private func gapSubscriberJSON(nonSubscriptionTxIDs: [String] = []) -> String {
    let nonSubs = nonSubscriptionTxIDs.isEmpty
        ? "{}"
        : "{\"com.demo.coins\": [\(nonSubscriptionTxIDs.map { "{\"id\": \"\($0)\", \"purchase_date\": \"2026-08-20T10:00:00Z\", \"store\": \"app_store\", \"is_sandbox\": false}" }.joined(separator: ","))]}"
    return """
    {"request_date":"2026-09-10T00:00:00Z","request_date_ms":1789000000000,
     "subscriber":{"original_app_user_id":"tester","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-09-01T00:00:00Z","last_seen":"2026-09-10T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":\(nonSubs)}}
    """
}

/// 后端下发三个包，商店里只有前两个 —— 第三个用来验「查不到 → storeProduct 仍为 nil」。
private let gapOfferingsJSON = """
{
  "current_offering_id": "default",
  "offerings": [
    {
      "description": "The default offering",
      "identifier": "default",
      "packages": [
        { "identifier": "$rc_monthly", "platform_product_identifier": "com.demo.monthly" },
        { "identifier": "$rc_annual",  "platform_product_identifier": "com.demo.yearly" },
        { "identifier": "ghost",       "platform_product_identifier": "com.demo.not-in-store" }
      ]
    }
  ]
}
"""

private func gapTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogV02Gap/\(UUID().uuidString)", isDirectory: true)
}

@MainActor
private func makeGapRig(
    directory: URL = gapTempDirectory(),
    products: [FakeProduct],
) -> (Purchases, MockTransport, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    let transport = MockTransport()
    let provider = FakeStoreKitProvider(products: products)
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: directory,
            storeKit: provider,
            networkDelayScheduler: NoDelayScheduler(),
            attributionState: InMemoryAttributionStateStorage(),
            diagnostics: .isolated(),
        ),
    )
    return (purchases, transport, provider)
}

// MARK: - A：offerings 的商品详情

extension PurchasesSingletonDomain {
@MainActor
@Suite("v0.2.0 · offerings 商品详情（A）", .serialized)
struct V02OfferingsProductTests {

    private static func trialProduct(_ identifier: String) -> FakeProduct {
        FakeProduct(productIdentifier: identifier,
                    subscriptionPeriod: SubscriptionPeriod(unit: .month, value: 1),
                    introOffer: IntroductoryOffer(type: .freeTrial,
                                                  period: SubscriptionPeriod(unit: .week, value: 2),
                                                  periodCount: 1,
                                                  displayPrice: "$0.00",
                                                  isEligible: true))
    }

    @Test("offerings() 用 StoreKit 批量补 Package.storeProduct：字段正确，商店查不到的仍为 nil")
    func offeringsFillStoreProducts() async throws {
        let (purchases, transport, _) = makeGapRig(products: [
            Self.trialProduct("com.demo.monthly"),
            FakeProduct(productIdentifier: "com.demo.yearly",
                        subscriptionPeriod: SubscriptionPeriod(unit: .year, value: 1)),
        ])
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(gapOfferingsJSON))

        let offerings = try await purchases.offerings()
        let current = try #require(offerings.current)

        let monthly = try #require(current.monthly)
        let product = try #require(monthly.storeProduct)
        #expect(product.productIdentifier == "com.demo.monthly")
        #expect(product.localizedTitle == "com.demo.monthly")
        #expect(product.price == Decimal(string: "9.99"))
        #expect(product.currencyCode == "USD")
        #expect(product.localizedPriceString == "$9.99")
        #expect(product.displayPrice == "$9.99")            // StoreKit 2 命名别名，与上一行同值
        #expect(product.subscriptionPeriod == SubscriptionPeriod(unit: .month, value: 1))
        let offer = try #require(product.introductoryOffer)
        #expect(offer.type == .freeTrial)
        #expect(offer.period == SubscriptionPeriod(unit: .week, value: 2))
        #expect(offer.periodCount == 1)
        #expect(offer.displayPrice == "$0.00")
        #expect(offer.isEligible)

        // 没配优惠的商品：周期有、优惠为 nil
        let annual = try #require(current.annual?.storeProduct)
        #expect(annual.subscriptionPeriod == SubscriptionPeriod(unit: .year, value: 1))
        #expect(annual.introductoryOffer == nil)

        // 商店里没有的商品：storeProduct 仍为 nil（offerings 本身照常返回）
        let ghost = try #require(current["ghost"])
        #expect(ghost.storeProduct == nil)
        #expect(ghost.platformProductIdentifier == "com.demo.not-in-store")
    }

    @Test("命中缓存的 offerings 在读取时同样补齐 storeProduct（缓存里不冻价格）")
    func cachedOfferingsAreFilledOnRead() async throws {
        let directory = gapTempDirectory()
        let (purchases, transport, _) = makeGapRig(directory: directory, products: [
            Self.trialProduct("com.demo.monthly"),
            FakeProduct(productIdentifier: "com.demo.yearly"),
        ])
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(gapOfferingsJSON))

        _ = try await purchases.offerings()
        let networkCalls = await transport.callCount

        // 第二次：TTL 内 → 走缓存，不发请求，但 storeProduct 照样在
        let cached = try await purchases.offerings()
        #expect(await transport.callCount == networkCalls)
        #expect(cached.current?.monthly?.storeProduct?.localizedPriceString == "$9.99")
        #expect(cached.current?.monthly?.storeProduct?.introductoryOffer?.type == .freeTrial)
        #expect(cached.current?["ghost"]?.storeProduct == nil)
    }

    @Test("诊断 offerings_fetch.not_found_product_ids 仍只记「商店查不到」的 id，且只查一次商店")
    func notFoundProductIDsStillRecordedOnce() async throws {
        let (purchases, transport, provider) = makeGapRig(products: [
            FakeProduct(productIdentifier: "com.demo.monthly"),
            FakeProduct(productIdentifier: "com.demo.yearly"),
        ])
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(gapOfferingsJSON))

        _ = try await purchases.offerings()

        let events = await purchases.diagnosticsRecorder.queuedEvents()
        let fetch = try #require(events.last { $0.type == DiagnosticsEventType.offeringsFetch })
        #expect(fetch.fields["not_found_product_ids"] == .strings(["com.demo.not-in-store"]))
        #expect(fetch.fields["count"] == .int(1))
        // 补 storeProduct 与算 not_found 共用同一次 `Product.products(for:)`，不许查两遍
        #expect(await provider.productsCallCount == 1)
    }
}
}

// MARK: - B/C：购买结果标志与扣款后错误码

extension PurchasesSingletonDomain {
@MainActor
@Suite("v0.2.0 · 购买结果与扣款后错误码（B/C）", .serialized)
struct V02PurchaseResultTests {

    private static func monthly() -> StoreProduct {
        StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                     price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99")
    }

    @Test("B：Ask-to-Buy / SCA → isPending == true、无 transactionId、非取消")
    func pendingPurchaseSetsIsPending() async throws {
        let (purchases, transport, provider) = makeGapRig(
            products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(gapSubscriberJSON()))
        await provider.scriptPurchase { _ in .pending }

        let result = try await purchases.purchase(product: Self.monthly())
        #expect(result.isPending)
        #expect(result.transactionIdentifier == nil)
        #expect(!result.userCancelled)
    }

    @Test("B：成功购买 isPending == false")
    func successfulPurchaseIsNotPending() async throws {
        let (purchases, transport, provider) = makeGapRig(
            products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        defer { Purchases.resetForTesting() }
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-b-1", originalTransactionIdentifier: "tx-b-1",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.b1.s", finishFlag: flag))
        }
        await transport.enqueue(.json(gapSubscriberJSON()), forPath: "/receipts")

        let result = try await purchases.purchase(product: Self.monthly())
        #expect(!result.isPending)
        #expect(result.transactionIdentifier == "tx-b-1")
    }

    @Test("B：用户取消 isPending == false、userCancelled == true")
    func cancelledPurchaseIsNotPending() async throws {
        let (purchases, transport, provider) = makeGapRig(
            products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(gapSubscriberJSON()))
        await provider.scriptPurchase { _ in .userCancelled }

        let result = try await purchases.purchase(product: Self.monthly())
        #expect(result.userCancelled)
        #expect(!result.isPending)
    }

    /// C 的暂时性一半：5xx / 网络错误 / 401 / 403 全都是「交易保留、SDK 会重放」。
    @Test("C：5xx / 网络错误 / 401 / 403 → purchasePendingServerConfirmation 且未 finish",
          arguments: [500, 503, 401, 403, -1])
    func retryableFailuresThrowPendingConfirmation(status: Int) async throws {
        let (purchases, transport, provider) = makeGapRig(
            products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        defer { Purchases.resetForTesting() }
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-c-\(status)",
                                     originalTransactionIdentifier: "tx-c-\(status)",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.c\(status).s", finishFlag: flag))
        }
        if status < 0 {
            // 传输层直接抛（断网/超时）：HTTPClient 会重试，整机断网让每次都抛。
            await transport.failTransportAlways(error: URLError(.notConnectedToInternet))
        } else {
            // 路径队列只剩一个时**粘住** —— HTTPClient 自身重试几次都拿到同一个错误码
            await transport.enqueue(.failure(statusCode: status), forPath: "/receipts")
        }

        var thrown: PurchasesError?
        do {
            _ = try await purchases.purchase(product: Self.monthly())
        } catch let error as PurchasesError {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error.code == .purchasePendingServerConfirmation)
        #expect(error.code.rawValue == 901)
        #expect(error.code != .networkError)   // 不再是裸 networkError
        #expect(!flag.value, "status \(status)：扣款后上报失败绝不 finish")

        // 诊断事件用新码名（契约 §1.3 `purchase_result.error_code`）
        let events = await purchases.diagnosticsRecorder.queuedEvents()
        let result = try #require(events.last { $0.type == DiagnosticsEventType.purchaseResult })
        #expect(result.fields["error_code"] == .string("purchasePendingServerConfirmation"))
        #expect(result.fields["outcome"] == .string(DiagnosticsPurchaseOutcome.error))
    }

    @Test("C：确定性 4xx（400）→ purchaseRejectedByServer，交易已 finish，带后端错误体码")
    func deterministicRejectionThrowsRejectedByServer() async throws {
        let (purchases, transport, provider) = makeGapRig(
            products: [FakeProduct(productIdentifier: "com.demo.monthly")])
        defer { Purchases.resetForTesting() }
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-c-400", originalTransactionIdentifier: "tx-c-400",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.c400.s", finishFlag: flag))
        }
        await transport.enqueue(
            .json(#"{"code":7243,"message":"invalid receipt"}"#, statusCode: 400), forPath: "/receipts")

        var thrown: PurchasesError?
        do {
            _ = try await purchases.purchase(product: Self.monthly())
        } catch let error as PurchasesError {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error.code == .purchaseRejectedByServer)
        #expect(error.code.rawValue == 902)
        #expect(error.httpStatusCode == 400)
        // 后端错误体码经 underlyingError 透出（宿主排障要它）
        let underlying = try #require(error.underlyingError as? PurchasesError)
        #expect(underlying.backendCode == 7243)
        #expect(flag.value, "确定性 4xx：finish 义务照清，不许把交易挂死")

        let events = await purchases.diagnosticsRecorder.queuedEvents()
        let result = try #require(events.last { $0.type == DiagnosticsEventType.purchaseResult })
        #expect(result.fields["error_code"] == .string("purchaseRejectedByServer"))
    }

    @Test("C：消耗型未被响应确认 → 交易保留（不 finish），报 purchasePendingServerConfirmation")
    func unconfirmedConsumableThrowsPendingConfirmation() async throws {
        let (purchases, transport, provider) = makeGapRig(
            products: [FakeProduct(productIdentifier: "com.demo.coins")])
        defer { Purchases.resetForTesting() }
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-c-coins",
                                     originalTransactionIdentifier: "tx-c-coins",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: nil,           // 消耗型
                                     jwsRepresentation: "h.ccoins.s", finishFlag: flag))
        }
        // 200，但 non_subscriptions 里没有这笔 → 铁律 P2 第三条：绝不 finish
        await transport.enqueue(.json(gapSubscriberJSON()), forPath: "/receipts")

        let result = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.coins", localizedTitle: "",
                                  localizedDescription: "", price: 0.99, currencyCode: "USD",
                                  localizedPriceString: "$0.99"))
        // 上报成功（200）→ 正常返回；finish 义务留着下次启动补
        #expect(result.transactionIdentifier == "tx-c-coins")
        #expect(!flag.value)
    }
}
}
