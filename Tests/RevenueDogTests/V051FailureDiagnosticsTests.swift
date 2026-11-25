//
//  V051FailureDiagnosticsTests.swift
//  0.5.1（ADR 0243）端到端：经门面走真编排层 + `FakeStoreKitProvider` + 假后端。
//
//  5. 购买失败：宿主拿到的就是 `PurchasesError`（码位不被改写）、发起键清掉、`purchase_result` 带原因字段；
//     `CancellationError` 原样透出（ADR 决定 7：不在公开 API 外沿再包一层），诊断记 `unknownError`。
//  6. 五个失败事件都带新字段，且调用点已有的字段（`status` / `request_id` / `products_error_code` …）取值不变；
//     `customer_info_fetch` 对非 `PurchasesError` 的失败也记事件。
//  7. 最坏情形的 `purchase_result` 失败事件仍在单条序列化上限（`DiagnosticsEvent.maxSerializedBytes`）以内。
//

import Foundation
import Testing
#if canImport(StoreKit)
import StoreKit
#endif
@testable import RevenueDog

// MARK: - Fixtures

private let v051OfferingsJSON = """
{
  "current_offering_id": "default",
  "offerings": [
    {
      "description": "The default offering",
      "identifier": "default",
      "packages": [
        { "identifier": "$rc_monthly", "platform_product_identifier": "com.demo.monthly" }
      ]
    }
  ]
}
"""

private func v051TempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogV051/\(UUID().uuidString)", isDirectory: true)
}

/// 网络退避时直接抛 `CancellationError`：模拟「任务被取消时 HTTP 重试等待抛出」（ADR 0243 背景里唯一的非 `PurchasesError` 来源）。
private struct CancellingDelayScheduler: DelayScheduler {
    func sleep(seconds: TimeInterval) async throws { throw CancellationError() }
}

/// 不在 StoreKit 模块里的本地错误（端到端里当作「SK2Provider 包进 underlyingError 的原错误」用）。
private struct V051LocalError: Error {
    let code: Int64
    let message: String
}

/// 类型名很长的错误：用来把 `underlying` 撑到 200 字符截断线（字节上限用例）。
private struct V051WorstCaseUnderlyingErrorWithAnExtremelyLongTypeName<Wrapped>: Error {}

private struct V051Rig {
    let purchases: Purchases
    let transport: MockTransport
    let provider: FakeStoreKitProvider
    let directory: URL
}

@MainActor
private func makeV051Rig(
    appUserID: String? = nil,
    cacheStorage: InMemoryCacheStorage = InMemoryCacheStorage(),
    networkDelayScheduler: any DelayScheduler = NoDelayScheduler(),
) async -> V051Rig {
    Purchases.resetForTesting()
    let transport = MockTransport()
    let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
    let directory = v051TempDirectory()
    var dependencies = Purchases.Dependencies(
        identityStorage: InMemoryIdentityStorage(),
        cacheStorage: cacheStorage,
        transport: transport,
        pendingPurchasesDirectory: directory,
        storeKit: provider,
        networkDelayScheduler: networkDelayScheduler,
        attributionState: InMemoryAttributionStateStorage(),
        diagnostics: .isolated(),
    )
    dependencies.storeProductsBackoff = { _ in }
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(baseURL: URL(string: "https://api.revenuedog.com")!)
            .with(appUserID: appUserID),
        dependencies: dependencies,
    )
    // 启动期初始化跑完再编排后端，免得启动请求吃掉用例的 stub。
    await Purchases.awaitConfigured()
    return V051Rig(purchases: purchases, transport: transport, provider: provider, directory: directory)
}

private func monthlyProduct() -> StoreProduct {
    StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                 price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99")
}

@MainActor
private func lastEvent(_ purchases: Purchases, type: String) async -> DiagnosticsEvent? {
    await purchases.diagnosticsRecorder.queuedEvents().last { $0.type == type }
}

// MARK: - 5. 购买失败端到端

extension PurchasesSingletonDomain {
@MainActor
@Suite("0.5.1 · 购买失败端到端（ADR 0243）", .serialized)
struct V051PurchaseFailureFlowTests {

    #if canImport(StoreKit)
    @Test("SK2Provider 的产出（映射后的 PurchasesError）→ 宿主原样收到、发起键清掉、purchase_result 带原因字段",
          arguments: [
              (StoreKitError.networkError(URLError(.notConnectedToInternet)) as any Error & Sendable,
               PurchasesErrorCode.networkError, "network", "networkError(-1009)"),
              (StoreKitError.notAvailableInStorefront, .productNotAvailableForPurchaseError, "billing",
               "notAvailableInStorefront"),
              (Product.PurchaseError.productUnavailable, .productNotAvailableForPurchaseError, "billing",
               "productUnavailable"),
              (Product.PurchaseError.purchaseNotAllowed, .purchaseNotAllowedError, "billing", "purchaseNotAllowed"),
              (StoreKitError.unknown, .storeProblemError, "billing", "unknown"),
          ])
    func mappedStoreKitFailure(original: any Error & Sendable, expectedCode: PurchasesErrorCode,
                               expectedClass: String, expectedUnderlying: String) async throws {
        let rig = await makeV051Rig()
        defer { Purchases.resetForTesting() }
        await rig.provider.scriptPurchaseError(StoreKitErrorMapping.purchasesError(fromPurchaseFailure: original))

        var thrown: (any Error)?
        do {
            _ = try await rig.purchases.purchase(product: monthlyProduct())
        } catch {
            thrown = error
        }
        let error = try #require(thrown as? PurchasesError, "宿主必须拿到 PurchasesError，实得 \(String(describing: thrown))")
        #expect(error.code == expectedCode)
        #expect(error.underlyingError != nil)

        // 弹窗前失败：发起键清掉（铁律 P3 的另一半），没有上报
        #expect(await PendingPurchaseStore(directory: rig.directory).all().isEmpty)
        #expect(await rig.transport.callCount(forPath: "/v1/receipts") == 0)

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.purchaseResult))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["outcome"] == .string(DiagnosticsPurchaseOutcome.error))
        #expect(event.fields["product_id"] == .string("com.demo.monthly"))
        #expect(event.fields["error_code"] == .string(expectedCode.name))
        #expect(event.fields["error_class"] == .string(expectedClass))
        #expect(event.fields["underlying"] == .string(expectedUnderlying))
        #expect(event.fields["store_error_code"] == nil)
        #expect(event.fields["duration_ms"] != nil)
    }
    #endif

    @Test("带商店错误码的失败 → purchase_result 带 store_error_code（整数）与 billing；不带任何文案")
    func storeErrorCodeReachesPurchaseResult() async throws {
        let rig = await makeV051Rig()
        defer { Purchases.resetForTesting() }
        let scripted = PurchasesError(code: .storeProblemError,
                                      message: "The App Store could not complete the purchase (V051LocalError, code 1002).",
                                      underlyingError: V051LocalError(code: 1002, message: "apple secret text"),
                                      storeErrorCode: 1002)
        await rig.provider.scriptPurchaseError(scripted)

        await #expect(throws: PurchasesError.self) { _ = try await rig.purchases.purchase(product: monthlyProduct()) }

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.purchaseResult))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["error_code"] == .string("storeProblemError"))
        #expect(event.fields["error_class"] == .string("billing"))
        #expect(event.fields["store_error_code"] == .int(1002))
        #expect(event.fields["underlying"] == .string("V051LocalError"))
        let dump = try #require(String(data: try DiagnosticsCoding.encoder.encode(event), encoding: .utf8))
        #expect(!dump.contains("apple secret text"))
        #expect(!dump.contains("could not complete"))
    }

    @Test("CancellationError 原样透出给宿主（不包成 PurchasesError），诊断记 unknownError / CancellationError")
    func cancellationPropagatesUnwrapped() async throws {
        let rig = await makeV051Rig()
        defer { Purchases.resetForTesting() }
        await rig.provider.scriptPurchaseError(CancellationError())

        var thrown: (any Error)?
        do {
            _ = try await rig.purchases.purchase(product: monthlyProduct())
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError, "实得 \(String(describing: thrown))")
        #expect(!(thrown is PurchasesError))
        #expect(await PendingPurchaseStore(directory: rig.directory).all().isEmpty)

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.purchaseResult))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["outcome"] == .string(DiagnosticsPurchaseOutcome.error))
        #expect(event.fields["error_code"] == .string("unknownError"))
        #expect(event.fields["underlying"] == .string("CancellationError"))
        #expect(event.fields["error_class"] == .string("unknown"))
    }
}
}

// MARK: - 6. 五个失败事件

extension PurchasesSingletonDomain {
@MainActor
@Suite("0.5.1 · 五个失败事件的原因字段（ADR 0243 决定 5）", .serialized)
struct V051FailureEventFieldsTests {

    @Test("identity_login 401：status / request_id 取调用点（不变），新增 error_class = auth")
    func identityLoginUnauthorized() async throws {
        let rig = await makeV051Rig()
        defer { Purchases.resetForTesting() }
        await rig.transport.enqueue(.failure(statusCode: 401, headers: ["X-Request-Id": "req-login-401"]),
                                    forPath: "/v1/subscribers/identify")

        await #expect(throws: PurchasesError.self) { _ = try await rig.purchases.logIn("alice") }

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.identityLogin))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["status"] == .int(401))
        #expect(event.fields["request_id"] == .string("req-login-401"))
        #expect(event.fields["from_anonymous"] == .bool(true))
        #expect(event.fields["duration_ms"] != nil)
        #expect(event.fields["error_code"] == .string("invalidCredentialsError"))
        #expect(event.fields["error_class"] == .string("auth"))
        #expect(event.fields["underlying"] == nil)
    }

    @Test("identity_logout：匿名态 logOut（端上守卫，无 HTTP）→ invalidAppUserIdError / config，不带 status")
    func identityLogoutGuard() async throws {
        let rig = await makeV051Rig()
        defer { Purchases.resetForTesting() }

        await #expect(throws: PurchasesError.self) { _ = try await rig.purchases.logOut() }

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.identityLogout))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["error_code"] == .string("invalidAppUserIdError"))
        #expect(event.fields["error_class"] == .string("config"))
        #expect(event.fields["status"] == nil)
    }

    @Test("customer_info_fetch：5xx → 调用点字段不变 + error_class = server")
    func customerInfoServerError() async throws {
        let rig = await makeV051Rig(appUserID: "v051-user")
        defer { Purchases.resetForTesting() }
        await rig.transport.enqueue(.failure(statusCode: 503, headers: ["X-Request-Id": "req-cif-503"]),
                                    forPath: "/v1/subscribers/v051-user")

        await #expect(throws: PurchasesError.self) {
            _ = try await rig.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        }

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.customerInfoFetch))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["policy"] == .string(FetchPolicy.fetchCurrent.rawValue))
        #expect(event.fields["cache_hit"] == .bool(false))
        #expect(event.fields["status"] == .int(503))
        #expect(event.fields["request_id"] == .string("req-cif-503"))
        #expect(event.fields["error_code"] == .string("unknownBackendError"))
        #expect(event.fields["error_class"] == .string("server"))
    }

    @Test("customer_info_fetch：非 PurchasesError 的失败（重试等待被取消）现在也记事件，错误原样抛出")
    func customerInfoRecordsNonPurchasesErrorFailure() async throws {
        let rig = await makeV051Rig(appUserID: "v051-user", networkDelayScheduler: CancellingDelayScheduler())
        defer { Purchases.resetForTesting() }
        // 503 → HTTPClient 要重试 → 退避等待抛 CancellationError
        await rig.transport.enqueue(.failure(statusCode: 503), forPath: "/v1/subscribers/v051-user")

        var thrown: (any Error)?
        do {
            _ = try await rig.purchases.customerInfo(fetchPolicy: .fetchCurrent)
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError, "实得 \(String(describing: thrown))")

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.customerInfoFetch),
                                 "0.5.0 在这条路径上不记 customer_info_fetch")
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["cache_hit"] == .bool(false))
        #expect(event.fields["status"] == .int(503))          // 调用点 trace 里的最后一次尝试
        #expect(event.fields["error_code"] == .string("unknownError"))
        #expect(event.fields["underlying"] == .string("CancellationError"))
        #expect(event.fields["error_class"] == .string("unknown"))
    }

    @Test("offerings_fetch：远端 500 回落磁盘缓存 + 商品重试后仍抛错 → products_error_code 不变，新增 error_class")
    func offeringsFallbackKeepsProductsErrorCode() async throws {
        let storage = InMemoryCacheStorage()
        let cached = Offerings(wireModel: try HTTPClient.makeResponseDecoder()
            .decode(OfferingsWireModel.self, from: Data(v051OfferingsJSON.utf8)))
        await DeviceCache(storage: storage).cache(offerings: cached, appUserID: "v051-user",
                                                  now: Date().addingTimeInterval(-3600))
        let rig = await makeV051Rig(appUserID: "v051-user", cacheStorage: storage)
        defer { Purchases.resetForTesting() }
        await rig.transport.enqueue(.failure(statusCode: 500, headers: ["X-Request-Id": "req-off-500"]),
                                    forPath: "/offerings")
        await rig.provider.scriptProductsFailures(3)

        _ = try await rig.purchases.offerings()

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.offeringsFetch))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["cache_hit"] == .bool(true))
        #expect(event.fields["status"] == .int(500))
        #expect(event.fields["request_id"] == .string("req-off-500"))
        #expect(event.fields["count"] == .int(1))
        #expect(event.fields["products_attempts"] == .int(3))
        #expect(event.fields["products_error_code"] == .string("storeProblemError"))
        #expect(event.fields["error_code"] == .string("unknownBackendError"))
        #expect(event.fields["error_class"] == .string("server"))
    }

    #if canImport(StoreKit)
    @Test("restore：AppStore.sync 的原始取消仍映射为 purchaseCancelledError；事件新增 error_class = billing / underlying")
    func restoreCancelGainsReasonFields() async throws {
        let rig = await makeV051Rig()
        defer { Purchases.resetForTesting() }
        await rig.provider.scriptSyncError(StoreKitError.userCancelled)

        var thrown: PurchasesError?
        do {
            _ = try await rig.purchases.restorePurchases()
        } catch let error as PurchasesError {
            thrown = error
        }
        #expect(thrown?.code == .purchaseCancelledError)

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.restore))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["error_code"] == .string("purchaseCancelledError"))
        #expect(event.fields["error_class"] == .string("billing"))
        #expect(event.fields["underlying"] == .string("userCancelled"))
        #expect(event.fields["count"] == nil)
    }
    #endif

    @Test("sync：刷新服务端视图 500 → 新增 error_class = server，status 由错误补上（调用点 trace 没有）")
    func syncFailureGainsErrorClass() async throws {
        let rig = await makeV051Rig(appUserID: "v051-user")
        defer { Purchases.resetForTesting() }
        await rig.transport.enqueue(.failure(statusCode: 500), forPath: "/v1/subscribers/v051-user")

        await #expect(throws: PurchasesError.self) { _ = try await rig.purchases.syncPurchases() }

        let event = try #require(await lastEvent(rig.purchases, type: DiagnosticsEventType.sync))
        #expect(event.level == DiagnosticsLevel.error)
        #expect(event.fields["error_code"] == .string("unknownBackendError"))
        #expect(event.fields["error_class"] == .string("server"))
        #expect(event.fields["status"] == .int(500))
        #expect(event.fields["request_id"] == nil)
    }
}
}

// MARK: - 7. 单条字节上限

@Suite("0.5.1 · 最坏情形的 purchase_result 失败事件不超单条上限")
struct V051WorstCaseEventSizeTests {

    @Test("200 字符商品 id + 最长 app_user_id（多字节）+ 全部原因字段 → 序列化 ≤ maxSerializedBytes，且能入队")
    func worstCasePurchaseResultFitsLimit() async throws {
        typealias Long = V051WorstCaseUnderlyingErrorWithAnExtremelyLongTypeName
        let deepUnderlying = Long<Long<Long<Long<Long<V051LocalError>>>>>()
        let error = PurchasesError(code: .productNotAvailableForPurchaseError,
                                   message: String(repeating: "m", count: 2000),   // 文案不进诊断
                                   backendCode: Int.max,
                                   httpStatusCode: 599,
                                   underlyingError: deepUnderlying,
                                   storeErrorCode: Int64.min)
        // 与 recordPurchaseResult 同一组调用点字段
        let fields = DiagnosticsErrorFields.merging([
            "product_id": .string(String(repeating: "p", count: 200)),
            "outcome": .string(DiagnosticsPurchaseOutcome.error),
            "transaction_id": .string(String(repeating: "9", count: 20)),
            "duration_ms": .int(Int64.max),
        ], error: error)
        for key in ["error_code", "status", "backend_code", "error_class", "underlying", "store_error_code"] {
            #expect((fields[key] ?? nil) != nil, "缺字段 \(key)")
        }
        let event = DiagnosticsEvent.make(type: DiagnosticsEventType.purchaseResult,
                                          level: DiagnosticsLevel.error,
                                          fields: fields,
                                          appUserID: String(repeating: "🐶", count: IdentityManager.maxAppUserIDLength),
                                          seq: Int64.max,
                                          tsMs: Int64.max)
        // underlying 已被截到 200 字符
        guard case .string(let underlying)? = event.fields["underlying"] else {
            Issue.record("underlying 缺失")
            return
        }
        #expect(underlying.count == DiagnosticsFieldValue.maxStringLength)

        let bytes = try DiagnosticsCoding.encoder.encode(event).count
        #expect(bytes <= DiagnosticsEvent.maxSerializedBytes, "最坏情形 \(bytes) 字节")

        let queue = DiagnosticsQueue(fileURL: v051TempDirectory()
            .appendingPathComponent(DiagnosticsQueue.fileName, isDirectory: false))
        _ = await queue.append(event)
        #expect(await queue.count == 1)
    }
}
