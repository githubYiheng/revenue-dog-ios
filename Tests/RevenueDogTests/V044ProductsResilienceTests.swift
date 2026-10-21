//
//  V044ProductsResilienceTests.swift
//  0.4.4（ADR 0155）：StoreKit 拉商品的抛错重试 + 进程内商品缓存 + 并发合并 + 诊断补盲。
//
//  a. 抛错、抛错、成功 → 3 次尝试，退避 1 s、2 s，商品全有；
//  b. 连抛 3 次 → storeProduct 全 nil，offerings 照常返回，诊断记错误 + sdk_warning；
//  c. 成功但缺 1 个 → 不重试，not_found 照记，缺的不进缓存（下次只为它查商店）；
//  d. 磁盘缓存命中 → 不碰 StoreKit，仍记一条 offerings_fetch（cache_hit / products_*）；
//  e. storefront 变化 → 缓存整体失效，重新查；
//  f. 两个并发 offerings() → 同一缺失集合只查一次商店，两边各自拿到商品。
//  审查补测 T1–T7：回落磁盘缓存路径 / 部分命中 + 抛错 / 合并 + 抛错 / 在途切 storefront /
//  资格不进缓存 / 购买路径同一入口 / 在途超龄。
//

import Foundation
import Testing
#if canImport(StoreKit)
import StoreKit
#endif
@testable import RevenueDog

// MARK: - Fixtures

/// 三个包，商店里三个都有（a / b / d / e / f 用）。
private let v044FullOfferingsJSON = """
{
  "current_offering_id": "default",
  "offerings": [
    {
      "description": "The default offering",
      "identifier": "default",
      "packages": [
        { "identifier": "$rc_weekly",  "platform_product_identifier": "com.demo.weekly" },
        { "identifier": "$rc_monthly", "platform_product_identifier": "com.demo.monthly" },
        { "identifier": "$rc_annual",  "platform_product_identifier": "com.demo.yearly" }
      ]
    }
  ]
}
"""

/// 三个包，第三个商店里没有（c 用）。
private let v044GhostOfferingsJSON = """
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

private let v044AllIDs: Set<String> = ["com.demo.weekly", "com.demo.monthly", "com.demo.yearly"]

private func v044Products() -> [FakeProduct] {
    v044AllIDs.sorted().map { FakeProduct(productIdentifier: $0) }
}

/// 记录每次退避时长，不真睡。
private actor BackoffRecorder {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}

/// 手动放行的闸：StoreKit 请求停在这里，直到测试 `open()`。
private actor ProductsGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private func v044TempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogV044/\(UUID().uuidString)", isDirectory: true)
}

/// 只让**第一次** StoreKit 调用停在闸上（之后的调用照常返回）。
private actor CallCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

/// 资格的「当下事实」：真 StoreKit 每次现查 `isEligibleForIntroOffer`，替身用可翻转的开关模拟。
private final class EligibilitySwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var eligible = true
    var value: Bool { lock.lock(); defer { lock.unlock() }; return eligible }
    func set(_ newValue: Bool) { lock.lock(); eligible = newValue; lock.unlock() }
}

/// `introductoryOffer()` 每次现读开关的商品替身（T5）。
private struct LiveEligibilityProduct: StoreProductType {
    let productIdentifier: String
    let eligibility: EligibilitySwitch
    var localizedTitle: String { productIdentifier }
    var localizedDescription: String { productIdentifier }
    var price: Decimal { 9.99 }
    var currencyCode: String? { "USD" }
    var localizedPriceString: String { "$9.99" }
    var isSubscription: Bool { true }
    var subscriptionPeriod: RevenueDog.SubscriptionPeriod? { RevenueDog.SubscriptionPeriod(unit: .month, value: 1) }
    func introductoryOffer() async -> RevenueDog.IntroductoryOffer? {
        RevenueDog.IntroductoryOffer(type: .freeTrial, period: RevenueDog.SubscriptionPeriod(unit: .week, value: 1), periodCount: 1,
                          price: 0, displayPrice: "$0.00", isEligible: eligibility.value)
    }
}

private let v044SubscriberJSON = """
{"request_date":"2026-10-21T00:00:00Z","request_date_ms":1792540800000,
 "subscriber":{"original_app_user_id":"tester","original_application_version":null,
   "original_purchase_date":null,"first_seen":"2026-10-01T00:00:00Z","last_seen":"2026-10-21T00:00:00Z",
   "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
"""

@MainActor
private func makeV044Rig(
    products: [any StoreProductType],
    backoff: BackoffRecorder,
    cacheStorage: InMemoryCacheStorage = InMemoryCacheStorage(),
    appUserID: String? = nil,
    inFlightMaxAge: Duration? = nil,
) -> (Purchases, MockTransport, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    let transport = MockTransport()
    let provider = FakeStoreKitProvider(products: products)
    var dependencies = Purchases.Dependencies(
        identityStorage: InMemoryIdentityStorage(),
        cacheStorage: cacheStorage,
        transport: transport,
        pendingPurchasesDirectory: v044TempDirectory(),
        storeKit: provider,
        networkDelayScheduler: NoDelayScheduler(),
        attributionState: InMemoryAttributionStateStorage(),
        diagnostics: .isolated(),
    )
    dependencies.storeProductsBackoff = { duration in await backoff.record(duration) }
    if let inFlightMaxAge { dependencies.storeProductsInFlightMaxAge = inFlightMaxAge }
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(baseURL: URL(string: "https://api.revenuedog.com")!)
            .with(appUserID: appUserID),
        dependencies: dependencies,
    )
    return (purchases, transport, provider)
}

private func v044Offerings(_ json: String) throws -> Offerings {
    Offerings(wireModel: try HTTPClient.makeResponseDecoder().decode(OfferingsWireModel.self, from: Data(json.utf8)))
}

private func intField(_ event: DiagnosticsEvent, _ key: String) -> Int64? {
    if case .int(let value) = event.fields[key] { return value }
    return nil
}

private func storeProblem(underlying: (any Error)? = nil) -> PurchasesError {
    PurchasesError(code: .storeProblemError, message: "StoreKit 拉取商品失败", underlyingError: underlying)
}

@MainActor
private func offeringsFetchEvents(_ purchases: Purchases) async -> [DiagnosticsEvent] {
    await purchases.diagnosticsRecorder.queuedEvents().filter { $0.type == DiagnosticsEventType.offeringsFetch }
}

@MainActor
private func productsFetchFailedWarnings(_ purchases: Purchases) async -> [DiagnosticsEvent] {
    await purchases.diagnosticsRecorder.queuedEvents().filter {
        $0.type == DiagnosticsEventType.sdkWarning
            && $0.fields["code"] == .string(DiagnosticsWarningCode.productsFetchFailed)
    }
}

private func v044WaitFor(timeoutMs: Int = 3000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

// MARK: - Tests

extension PurchasesSingletonDomain {
@MainActor
@Suite("v0.4.4 · 商品拉取重试 / 进程内缓存 / 并发合并（ADR 0155）", .serialized)
struct V044ProductsResilienceTests {

    @Test("a：抛错、抛错、成功 → 调 3 次、退避 1 s / 2 s、商品全有；诊断 attempts=3、无错误码、无 not_found")
    func retriesThrownErrorsThenSucceeds() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON))
        await provider.scriptProductsFailures(2)

        let offerings = try await purchases.offerings()

        #expect(await provider.productsCallCount == 3)
        let packages = try #require(offerings.current).availablePackages
        #expect(packages.count == 3)
        #expect(packages.allSatisfy { $0.storeProduct != nil })
        #expect(await backoff.durations == [.seconds(1), .seconds(2)])

        let fetch = try #require(await offeringsFetchEvents(purchases).last)
        #expect(fetch.fields["cache_hit"] == .bool(false))
        #expect(fetch.fields["products_attempts"] == .int(3))
        #expect(fetch.fields["products_from_cache"] == .int(0))
        #expect(fetch.fields["products_fetched"] == .int(3))
        #expect(fetch.fields["products_error_code"] == nil)
        #expect(fetch.fields["not_found_product_ids"] == nil)
        #expect(await productsFetchFailedWarnings(purchases).isEmpty)
    }

    @Test("b：连抛 3 次 → storeProduct 全 nil、offerings 照常返回；products_error_code、无 not_found、有 sdk_warning")
    func exhaustedRetriesLeaveProductsNilAndWarn() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON))
        #if canImport(StoreKit)
        await provider.scriptProductsFailures(
            3, error: storeProblem(underlying: StoreKitError.networkError(URLError(.notConnectedToInternet))))
        let expectedUnderlying = "networkError(-1009)"
        #else
        await provider.scriptProductsFailures(3)
        let expectedUnderlying = "PurchasesError"
        #endif

        let offerings = try await purchases.offerings()

        #expect(await provider.productsCallCount == 3)
        let packages = try #require(offerings.current).availablePackages
        #expect(packages.count == 3)
        #expect(packages.allSatisfy { $0.storeProduct == nil })
        #expect(await backoff.durations == [.seconds(1), .seconds(2)])

        let fetch = try #require(await offeringsFetchEvents(purchases).last)
        #expect(fetch.fields["products_attempts"] == .int(3))
        #expect(fetch.fields["products_fetched"] == .int(0))
        #expect(fetch.fields["products_error_code"] == .string("storeProblemError"))
        // 抛错时不写 not_found：throw 与「商店查不到」必须分得开
        #expect(fetch.fields["not_found_product_ids"] == nil)
        #expect(fetch.fields["error_code"] == nil)   // offerings 本身是成功的

        let warnings = await productsFetchFailedWarnings(purchases)
        #expect(warnings.count == 1)
        #expect(warnings.first?.fields["detail"]
                == .string("attempts=3 error=storeProblemError missing=3 underlying=\(expectedUnderlying)"))

        // 失败什么都不缓存：下一次（磁盘缓存命中）重新查商店，这次成功就补齐
        let again = try await purchases.offerings()
        #expect(await provider.productsCallCount == 4)
        #expect(try #require(again.current).availablePackages.allSatisfy { $0.storeProduct != nil })
    }

    @Test("c：成功但缺 1 个 → 不重试、not_found 照记；缺的不进缓存，下次只为它查商店")
    func partialSuccessIsNotRetriedAndMissingIsNotCached() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: [
            FakeProduct(productIdentifier: "com.demo.monthly"),
            FakeProduct(productIdentifier: "com.demo.yearly"),
        ], backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044GhostOfferingsJSON))

        _ = try await purchases.offerings()

        #expect(await provider.productsCallCount == 1)
        #expect(await backoff.durations.isEmpty)
        let first = try #require(await offeringsFetchEvents(purchases).last)
        #expect(first.fields["products_attempts"] == .int(1))
        #expect(first.fields["products_fetched"] == .int(2))
        #expect(first.fields["not_found_product_ids"] == .strings(["com.demo.not-in-store"]))
        #expect(first.fields["products_error_code"] == nil)

        // 第二次（磁盘缓存命中）：查到的两个来自进程内缓存，只为缺的那个再查一次商店
        let again = try await purchases.offerings()
        #expect(await provider.productsCallCount == 2)
        #expect(await provider.productsRequests.last == ["com.demo.not-in-store"])
        #expect(again.current?.monthly?.storeProduct != nil)
        #expect(again.current?["ghost"]?.storeProduct == nil)

        let second = try #require(await offeringsFetchEvents(purchases).last)
        #expect(second.fields["cache_hit"] == .bool(true))
        #expect(second.fields["products_attempts"] == .int(1))
        #expect(second.fields["products_from_cache"] == .int(2))
        #expect(second.fields["products_fetched"] == .int(0))
        #expect(second.fields["not_found_product_ids"] == .strings(["com.demo.not-in-store"]))
    }

    @Test("d：磁盘缓存命中 → 不碰 StoreKit，仍记 offerings_fetch（cache_hit=true、attempts=0、from_cache=N）")
    func diskCacheHitUsesProcessCacheAndStillRecords() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON))

        _ = try await purchases.offerings()
        let networkCalls = await transport.callCount
        #expect(await provider.productsCallCount == 1)

        let cached = try await purchases.offerings()
        #expect(await transport.callCount == networkCalls)          // offerings 来自磁盘缓存
        #expect(await provider.productsCallCount == 1)             // 商品来自进程内缓存
        #expect(try #require(cached.current).availablePackages.allSatisfy { $0.storeProduct != nil })

        let events = await offeringsFetchEvents(purchases)
        #expect(events.count == 2)
        let hit = try #require(events.last)
        #expect(hit.fields["cache_hit"] == .bool(true))
        #expect(hit.fields["products_attempts"] == .int(0))
        #expect(hit.fields["products_from_cache"] == .int(3))
        #expect(hit.fields["products_fetched"] == .int(0))
        #expect(hit.fields["count"] == .int(1))
        #expect(hit.fields["status"] == nil)
        #expect(hit.fields["duration_ms"] != nil)
        #expect(hit.fields["not_found_product_ids"] == nil)
    }

    @Test("e：storefront 变化 → 进程内缓存整体失效，重新查商店；读不到（nil）不失效；之后同一 storefront 继续命中")
    func storefrontChangeInvalidatesCache() async throws {
        defer { StoreEnvironmentCache.setStorefront(nil) }
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await provider.setStorefront("USA")
        await transport.enqueue(.json(v044FullOfferingsJSON))

        _ = try await purchases.offerings()
        #expect(await provider.productsCallCount == 1)

        // 读不到 storefront（nil）= 未知：不失效
        await provider.setStorefront(nil)
        _ = try await purchases.offerings()
        #expect(await provider.productsCallCount == 1)

        await provider.setStorefront("CHN")
        let switched = try await purchases.offerings()
        #expect(await provider.productsCallCount == 2)
        #expect(await provider.productsRequests.last == v044AllIDs)
        #expect(try #require(switched.current).availablePackages.allSatisfy { $0.storeProduct != nil })
        let afterSwitch = try #require(await offeringsFetchEvents(purchases).last)
        #expect(afterSwitch.fields["products_from_cache"] == .int(0))
        #expect(afterSwitch.fields["products_attempts"] == .int(1))
        #expect(afterSwitch.fields["products_fetched"] == .int(3))

        _ = try await purchases.offerings()
        #expect(await provider.productsCallCount == 2)
    }

    @Test("f：两个并发 offerings() → 同一缺失集合只查一次商店，两边都有商品，各记一条 offerings_fetch")
    func concurrentOfferingsShareOneStoreKitRequest() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON))
        let gate = ProductsGate()
        await provider.setProductsHook { _ in await gate.wait() }

        async let first = purchases.offerings()
        async let second = purchases.offerings()

        // 第一个请求停在闸上，等第二个调用方确实合并进来再放行（否则它可能只是后到、命中缓存）
        let joined = await v044WaitFor { await purchases.storeProductFetchJoinCount() == 1 }
        #expect(joined)
        await gate.open()
        let (a, b) = try await (first, second)

        #expect(await provider.productsCallCount == 1)
        #expect(try #require(a.current).availablePackages.allSatisfy { $0.storeProduct != nil })
        #expect(try #require(b.current).availablePackages.allSatisfy { $0.storeProduct != nil })

        let events = await offeringsFetchEvents(purchases)
        #expect(events.count == 2)
        let attempts = events.compactMap { event -> Int64? in
            if case .int(let value) = event.fields["products_attempts"] { return value }
            return nil
        }.sorted()
        #expect(attempts == [0, 1])
        let joiner = try #require(events.first { $0.fields["products_attempts"] == .int(0) })
        #expect(joiner.fields["products_from_cache"] == .int(0))
        #expect(joiner.fields["products_fetched"] == .int(3))
    }

    // MARK: 审查补测 T1–T7

    @Test("T1：远端失败回落磁盘缓存 → cache_hit=true、error_code 有值、products_* 齐；顺序 cache_fallback → products_fetch_failed → offerings_fetch")
    func fallbackPathRecordsProductsAfterFallbackWarning() async throws {
        let storage = InMemoryCacheStorage()
        // 预置一份**已过期**的磁盘缓存：这次 offerings() 会先走远端，远端失败再回落它
        await DeviceCache(storage: storage).cache(offerings: try v044Offerings(v044FullOfferingsJSON),
                                                  appUserID: "v044-user",
                                                  now: Date().addingTimeInterval(-3600))
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff,
                                                           cacheStorage: storage, appUserID: "v044-user")
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.failure(statusCode: 500), forPath: "/offerings")
        await provider.scriptProductsFailures(3)

        let offerings = try await purchases.offerings()
        #expect(try #require(offerings.current).availablePackages.allSatisfy { $0.storeProduct == nil })

        let events = await purchases.diagnosticsRecorder.queuedEvents()
        let fallbackIndex = try #require(events.firstIndex {
            $0.type == DiagnosticsEventType.sdkWarning
                && $0.fields["code"] == .string(DiagnosticsWarningCode.offeringsCacheFallback)
        })
        let productsFailedIndex = try #require(events.firstIndex {
            $0.type == DiagnosticsEventType.sdkWarning
                && $0.fields["code"] == .string(DiagnosticsWarningCode.productsFetchFailed)
        })
        let fetchIndex = try #require(events.lastIndex { $0.type == DiagnosticsEventType.offeringsFetch })
        #expect(fallbackIndex < productsFailedIndex)
        #expect(productsFailedIndex < fetchIndex)

        let fetch = events[fetchIndex]
        #expect(fetch.level == DiagnosticsLevel.error)
        #expect(fetch.fields["cache_hit"] == .bool(true))
        #expect(fetch.fields["error_code"] != nil)
        #expect(fetch.fields["status"] == .int(500))
        #expect(fetch.fields["count"] == .int(1))
        #expect(fetch.fields["products_attempts"] == .int(3))
        #expect(fetch.fields["products_from_cache"] == .int(0))
        #expect(fetch.fields["products_fetched"] == .int(0))
        #expect(fetch.fields["products_error_code"] == .string("storeProblemError"))
        #expect(fetch.fields["not_found_product_ids"] == nil)
    }

    @Test("T1'：远端失败且无磁盘缓存 → offerings_fetch 不带 cache_hit、不带 products_*")
    func remoteFailureWithoutCacheOmitsCacheHit() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.failure(statusCode: 500), forPath: "/offerings")

        await #expect(throws: (any Error).self) { try await purchases.offerings() }

        #expect(await provider.productsCallCount == 0)
        let fetch = try #require(await offeringsFetchEvents(purchases).last)
        #expect(fetch.fields["cache_hit"] == nil)
        #expect(fetch.fields["products_attempts"] == nil)
        #expect(fetch.fields["error_code"] != nil)
    }

    @Test("T2：部分已在缓存 + 重试后仍抛错 → 缓存有的照填、其余 nil；不写 not_found，products_error_code 有值")
    func partialCacheThenExhaustedRetries() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: [
            FakeProduct(productIdentifier: "com.demo.monthly"),
            FakeProduct(productIdentifier: "com.demo.yearly"),
        ], backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044GhostOfferingsJSON))

        _ = try await purchases.offerings()   // monthly / yearly 进缓存，ghost 查不到不进
        await provider.scriptProductsFailures(3)

        let again = try await purchases.offerings()
        let current = try #require(again.current)
        #expect(current.monthly?.storeProduct != nil)
        #expect(current.annual?.storeProduct != nil)
        #expect(current["ghost"]?.storeProduct == nil)
        #expect(await provider.productsCallCount == 1 + 3)
        #expect(await provider.productsRequests.suffix(3).allSatisfy { $0 == ["com.demo.not-in-store"] })

        let fetch = try #require(await offeringsFetchEvents(purchases).last)
        #expect(fetch.fields["cache_hit"] == .bool(true))
        #expect(fetch.fields["products_from_cache"] == .int(2))
        #expect(fetch.fields["products_attempts"] == .int(3))
        #expect(fetch.fields["products_fetched"] == .int(0))
        #expect(fetch.fields["products_error_code"] == .string("storeProblemError"))
        #expect(fetch.fields["not_found_product_ids"] == nil)
        #expect(await productsFetchFailedWarnings(purchases).first?.fields["detail"]
                == .string("attempts=3 error=storeProblemError missing=1 underlying=PurchasesError"))
    }

    @Test("T3：并发合并 + 三次都抛错 → 只 1 条 sdk_warning，两条 offerings_fetch 都带 products_error_code，合并者 attempts=0")
    func coalescedFailureWarnsOnce() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON))
        await provider.scriptProductsFailures(3)
        let gate = ProductsGate()
        await provider.setProductsHook { _ in await gate.wait() }

        async let first = purchases.offerings()
        async let second = purchases.offerings()
        let joined = await v044WaitFor { await purchases.storeProductFetchJoinCount() == 1 }
        #expect(joined)
        await gate.open()
        let (a, b) = try await (first, second)

        #expect(await provider.productsCallCount == 3)
        #expect(try #require(a.current).availablePackages.allSatisfy { $0.storeProduct == nil })
        #expect(try #require(b.current).availablePackages.allSatisfy { $0.storeProduct == nil })
        #expect(await productsFetchFailedWarnings(purchases).count == 1)

        let events = await offeringsFetchEvents(purchases)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.fields["products_error_code"] == .string("storeProblemError") })
        #expect(events.allSatisfy { $0.fields["not_found_product_ids"] == nil })
        #expect(events.compactMap { intField($0, "products_attempts") }.sorted() == [0, 3])
    }

    @Test("T4：请求在途时切 storefront → 新调用方不并进旧请求，旧请求的结果不写回缓存")
    func storefrontSwitchWhileInFlight() async throws {
        defer { StoreEnvironmentCache.setStorefront(nil) }
        let backoff = BackoffRecorder()
        // 两批商品用订阅周期区分：旧 storefront 在途请求回来时商店已是「年」那批
        let monthPeriod = RevenueDog.SubscriptionPeriod(unit: .month, value: 1)
        let yearPeriod = RevenueDog.SubscriptionPeriod(unit: .year, value: 1)
        let (purchases, transport, provider) = makeV044Rig(
            products: v044AllIDs.sorted().map { FakeProduct(productIdentifier: $0, subscriptionPeriod: monthPeriod) },
            backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON))
        await provider.setStorefront("USA")
        let gate = ProductsGate()
        let counter = CallCounter()
        await provider.setProductsHook { _ in
            if await counter.next() == 1 { await gate.wait() }
        }

        async let first = purchases.offerings()
        let inFlight = await v044WaitFor { await provider.productsCallCount == 1 }
        #expect(inFlight)

        await provider.setStorefront("CHN")
        let second = try await purchases.offerings()
        #expect(await purchases.storeProductFetchJoinCount() == 0)   // 没并进旧请求
        #expect(await provider.productsCallCount == 2)
        #expect(second.current?.monthly?.storeProduct?.subscriptionPeriod == monthPeriod)

        await provider.setProducts(
            v044AllIDs.sorted().map { FakeProduct(productIdentifier: $0, subscriptionPeriod: yearPeriod) })
        await gate.open()
        let old = try await first
        #expect(old.current?.monthly?.storeProduct?.subscriptionPeriod == yearPeriod)   // 旧调用方用自己的结果

        // 缓存里仍是新 storefront 那次写入的（旧结果没写回）
        let third = try await purchases.offerings()
        #expect(await provider.productsCallCount == 2)
        #expect(third.current?.monthly?.storeProduct?.subscriptionPeriod == monthPeriod)
    }

    @Test("T5：资格不进缓存 → 两次 offerings() 之间资格变了，isEligible 跟着变（商品不重查）")
    func eligibilityIsNotCached() async throws {
        let backoff = BackoffRecorder()
        let eligibility = EligibilitySwitch()
        let (purchases, transport, provider) = makeV044Rig(
            products: v044AllIDs.sorted().map { LiveEligibilityProduct(productIdentifier: $0, eligibility: eligibility) },
            backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON))

        let before = try await purchases.offerings()
        #expect(before.current?.monthly?.storeProduct?.introductoryOffer?.isEligible == true)

        eligibility.set(false)   // 例如同一进程里刚买过
        let after = try await purchases.offerings()
        #expect(await provider.productsCallCount == 1)
        #expect(after.current?.monthly?.storeProduct?.introductoryOffer?.isEligible == false)
    }

    @Test("T6a：购买路径走同一入口 → offerings() 灌进缓存后 purchase(package:) 不再查商店")
    func purchaseUsesProcessCache() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON), forPath: "/offerings")
        await transport.enqueue(.json(v044SubscriberJSON), forPath: "/receipts")
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-v044-1", originalTransactionIdentifier: "tx-v044-1",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.v044.s", finishFlag: flag))
        }

        let package = try #require(try await purchases.offerings().current?.monthly)
        #expect(await provider.productsCallCount == 1)

        let result = try await purchases.purchase(package: package)
        #expect(result.transactionIdentifier == "tx-v044-1")
        #expect(await provider.productsCallCount == 1)
    }

    @Test("T6b：购买路径缓存为空、StoreKit 抛 2 次后成功 → 购买成功，调 3 次；之后再买不查商店")
    func purchaseRetriesThrownProductLookup() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044SubscriberJSON), forPath: "/receipts")
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-v044-\(UUID().uuidString)",
                                     originalTransactionIdentifier: "tx-v044-orig",
                                     productIdentifier: productID, purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.v044b.s", finishFlag: flag))
        }
        await provider.scriptProductsFailures(2)
        let product = StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                   price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99")

        let result = try await purchases.purchase(product: product)
        #expect(result.transactionIdentifier != nil)
        #expect(await provider.productsCallCount == 3)
        #expect(await backoff.durations == [.seconds(1), .seconds(2)])

        // 查到的商品已写进缓存
        _ = try await purchases.purchase(product: product)
        #expect(await provider.productsCallCount == 3)
    }

    @Test("T6c：购买路径错误映射不变 → 重试后仍抛错原样抛 storeProblemError；成功但没有 → productNotAvailableForPurchaseError")
    func purchaseLookupErrorMappingUnchanged() async throws {
        let backoff = BackoffRecorder()
        let (purchases, _, provider) = makeV044Rig(products: v044Products(), backoff: backoff)
        defer { Purchases.resetForTesting() }
        await provider.scriptProductsFailures(3)
        let monthly = StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                   price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99")

        do {
            _ = try await purchases.purchase(product: monthly)
            Issue.record("应当抛错")
        } catch let error as PurchasesError {
            #expect(error.code == .storeProblemError)
        }
        #expect(await provider.productsCallCount == 3)

        let ghost = StoreProduct(productIdentifier: "com.demo.not-in-store", localizedTitle: "", localizedDescription: "",
                                 price: 1, currencyCode: "USD", localizedPriceString: "$1")
        do {
            _ = try await purchases.purchase(product: ghost)
            Issue.record("应当抛错")
        } catch let error as PurchasesError {
            #expect(error.code == .productNotAvailableForPurchaseError)
        }
        #expect(await provider.productsCallCount == 4)   // 成功但空不重试
    }

    @Test("T7：在途请求超龄 → 第二个调用方不合并，自己发请求；两边都拿到商品")
    func staleInFlightRequestIsNotJoined() async throws {
        let backoff = BackoffRecorder()
        let (purchases, transport, provider) = makeV044Rig(products: v044Products(), backoff: backoff,
                                                           inFlightMaxAge: .milliseconds(100))
        defer { Purchases.resetForTesting() }
        await transport.enqueue(.json(v044FullOfferingsJSON))
        let gate = ProductsGate()
        let counter = CallCounter()
        await provider.setProductsHook { _ in
            if await counter.next() == 1 { await gate.wait() }
        }

        async let first = purchases.offerings()
        let inFlight = await v044WaitFor { await provider.productsCallCount == 1 }
        #expect(inFlight)
        try await Task.sleep(for: .milliseconds(250))   // 超过注入的 100 ms 时限

        let second = try await purchases.offerings()
        #expect(await purchases.storeProductFetchJoinCount() == 0)
        #expect(await provider.productsCallCount == 2)
        #expect(try #require(second.current).availablePackages.allSatisfy { $0.storeProduct != nil })

        await gate.open()
        let old = try await first
        #expect(try #require(old.current).availablePackages.allSatisfy { $0.storeProduct != nil })

        _ = try await purchases.offerings()
        #expect(await provider.productsCallCount == 2)
    }
}
}

// MARK: - 纯逻辑（StoreProductCache 代号 / storefront；underlying 名）

@Suite("v0.4.4 · StoreProductCache 与诊断取名（ADR 0155）")
struct V044StoreProductCacheTests {

    @Test("storefront：nil = 未知不失效不覆盖；首个确定值只记录；非 nil → 另一个非 nil 才失效；旧代号结果不写回")
    func generationGuardsStaleWrites() {
        var cache = StoreProductCache()
        let unknownFirst = cache.validate(storefrontID: nil)
        let firstObservation = cache.validate(storefrontID: "USA")
        #expect(unknownFirst == false)
        #expect(firstObservation == false)
        let oldGeneration = cache.generation
        let stored = cache.store([FakeProduct(productIdentifier: "a")], generation: oldGeneration)
        #expect(stored)
        #expect(cache.products(for: ["a", "b"]).keys.sorted() == ["a"])

        // 读不到：不失效、不覆盖已记录的 USA
        let unknown = cache.validate(storefrontID: nil)
        let stillUSA = cache.validate(storefrontID: "USA")
        #expect(unknown == false)
        #expect(stillUSA == false)
        #expect(cache.products(for: ["a"]).count == 1)

        // storefront 变了：整体失效
        let switched = cache.validate(storefrontID: "CHN")
        #expect(switched)
        #expect(cache.generation == oldGeneration + 1)
        #expect(cache.products(for: ["a"]).isEmpty)

        // 失效前发出的请求回来了：代号不等，不写
        let staleWrite = cache.store([FakeProduct(productIdentifier: "a")], generation: oldGeneration)
        #expect(staleWrite == false)
        #expect(cache.products(for: ["a"]).isEmpty)

        let sameStorefront = cache.validate(storefrontID: "CHN")
        #expect(sameStorefront == false)
    }

    @Test("products_fetch_failed 的 underlying：StoreKitError 取 case 名（networkError 带码、systemError 不带内层），其余取类型名，不带 message")
    func underlyingNames() {
        #if canImport(StoreKit)
        let network = storeProblem(underlying: StoreKitError.networkError(URLError(.notConnectedToInternet)))
        #expect(PurchasesOrchestrator.storeKitUnderlyingName(network) == "networkError(-1009)")
        let system = storeProblem(underlying: StoreKitError.systemError(
            NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret message"])))
        #expect(PurchasesOrchestrator.storeKitUnderlyingName(system) == "systemError")
        #expect(PurchasesOrchestrator.storeKitUnderlyingName(StoreKitError.notEntitled) == "notEntitled")
        #endif
        #expect(PurchasesOrchestrator.storeKitUnderlyingName(storeProblem()) == "PurchasesError")
        // 存进 `PurchasesError.underlyingError` 的 Foundation 错误已桥接成 NSError：类型名就是 NSError（口径字面）
        #expect(PurchasesOrchestrator.storeKitUnderlyingName(storeProblem(underlying: URLError(.timedOut)))
                == "NSError")
    }
}
