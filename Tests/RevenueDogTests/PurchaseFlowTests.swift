//
//  PurchaseFlowTests.swift
//  M2 购买闭环：铁律 P1–P8 + 坑矩阵 A 组裁决（#2/#7/#8/#10/#12/#15/#16）。
//

import Foundation
import Testing
@testable import RevenueDog

// MARK: - 测试替身

final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func markFinished() { lock.lock(); finished = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

struct FakeTransaction: StoreTransactionType {
    let transactionIdentifier: String
    let originalTransactionIdentifier: String
    let productIdentifier: String
    let purchaseDate: Date
    let expirationDate: Date?
    var quantity: Int = 1
    var revocationDate: Date? = nil
    var isUpgraded: Bool = false
    var appAccountToken: UUID? = nil
    let jwsRepresentation: String?
    let finishFlag: FinishFlag

    var isFinished: Bool { get async { finishFlag.value } }
    func finish() async { finishFlag.markFinished() }
}

struct FakeProduct: StoreProductType {
    let productIdentifier: String
    var localizedTitle: String { productIdentifier }
    var localizedDescription: String { productIdentifier }
    var price: Decimal { 9.99 }
    var currencyCode: String? { "USD" }
    var localizedPriceString: String { "$9.99" }
    var isSubscription: Bool { true }
}

// MARK: - Fixtures

private func subscriberJSON(nonSubscriptionTxIDs: [String] = []) -> String {
    let nonSubs = nonSubscriptionTxIDs.isEmpty
        ? "{}"
        : "{\"com.demo.coins\": [\(nonSubscriptionTxIDs.map { "{\"id\": \"\($0)\", \"purchase_date\": \"2026-08-20T10:00:00Z\", \"store\": \"app_store\", \"is_sandbox\": false}" }.joined(separator: ","))]}"
    return """
    {"request_date":"2026-08-27T00:00:00Z","request_date_ms":1782518400000,
     "subscriber":{"original_app_user_id":"tester","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":\(nonSubs)}}
    """
}

// MARK: - 组装

@MainActor
private func makePurchases(
    completedBy: PurchasesCompletedBy = .revenueDog,
    directory: URL? = nil,
) -> (Purchases, MockTransport, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    let transport = MockTransport()
    let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly"),
                                                  FakeProduct(productIdentifier: "com.demo.coins")])
    let dir = directory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogPurchaseTests/\(UUID().uuidString)", isDirectory: true)
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(purchasesCompletedBy: completedBy)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: dir,
            storeKit: provider,
        ),
    )
    return (purchases, transport, provider)
}

private func waitUntil(timeoutMs: Int = 2000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

// MARK: - 用例

@MainActor
@Suite("购买闭环（M2）", .serialized)
struct PurchaseFlowTests {

    @Test("P2/P3：订阅购买成功 → 上报 200 → finish，上下文清空，body 契约正确")
    func happyPathSubscription() async throws {
        let (purchases, transport, provider) = makePurchases()
        let flag = FinishFlag()
        await provider.scriptPurchase { productID in
            .success(FakeTransaction(transactionIdentifier: "tx-100",
                                     originalTransactionIdentifier: "tx-100",
                                     productIdentifier: productID,
                                     purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.p.s",
                                     finishFlag: flag))
        }
        await transport.enqueue(.json(subscriberJSON()))

        let result = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                  price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99"))
        #expect(result.transactionIdentifier == "tx-100")
        #expect(!result.userCancelled)
        #expect(flag.value) // 后端 200 后 finish

        let receiptRequest = await transport.capturedRequests.last
        #expect(receiptRequest?.url?.path == "/v1/receipts")
        let body = try JSONSerialization.jsonObject(with: receiptRequest!.httpBody!) as! [String: Any]
        #expect(body["fetch_token"] as? String == "h.p.s") // JWS 原文不 base64（契约 F8）
        #expect(body["product_id"] as? String == "com.demo.monthly")
        #expect(body["initiation_source"] as? String == "purchase")
        #expect(body["observer_mode"] as? Bool == false)
    }

    @Test("P2/#8：5xx → 绝不 finish，上下文保留（含 JWS）供重放；重放后端恢复 → 补报成功")
    func retryableFailureThenReplay() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogPurchaseTests/\(UUID().uuidString)", isDirectory: true)
        let (purchases, transport, provider) = makePurchases(directory: dir)
        let flag = FinishFlag()
        let tx = FakeTransaction(transactionIdentifier: "tx-200", originalTransactionIdentifier: "tx-200",
                                 productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                 expirationDate: Date().addingTimeInterval(3600),
                                 jwsRepresentation: "h.p2.s", finishFlag: flag)
        await provider.scriptPurchase { _ in .success(tx) }
        await transport.enqueue(.failure(statusCode: 500))
        await transport.enqueue(.failure(statusCode: 500)) // HTTPClient 自身可能重试一次

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(
                product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                      price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99"))
        }
        #expect(!flag.value) // 5xx 绝不 finish

        // 冷启动重放（P3）：同目录新实例，unfinished 里还有这笔
        let (_, transport2, provider2) = makePurchases(directory: dir)
        await provider2.setUnfinished([tx])
        await transport2.enqueue(.json(subscriberJSON())) // 重放 JWS 补报
        await transport2.enqueue(.json(subscriberJSON())) // unfinished 扫描配对后再报（幂等）
        let replayed = await waitUntil { await transport2.capturedRequests.contains { $0.url?.path == "/v1/receipts" } }
        #expect(replayed)
        let finished = await waitUntil { flag.value } // 扫描路径拿到交易对象后 finish
        #expect(finished)
    }

    @Test("#8：确定性 4xx → finish（重试无意义）+ 上下文清除")
    func finishableRejection() async throws {
        let (purchases, transport, provider) = makePurchases()
        let flag = FinishFlag()
        await provider.scriptPurchase { _ in
            .success(FakeTransaction(transactionIdentifier: "tx-300", originalTransactionIdentifier: "tx-300",
                                     productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                     expirationDate: Date().addingTimeInterval(3600),
                                     jwsRepresentation: "h.p3.s", finishFlag: flag))
        }
        await transport.enqueue(.failure(statusCode: 400))

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(
                product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                      price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99"))
        }
        #expect(flag.value) // 确定性拒绝 → finish，不再无限重投
    }

    @Test("消耗型：响应 non_subscriptions 未确认 → 不 finish、保留 finish 义务")
    func consumableUnconfirmedKeepsObligation() async throws {
        let (purchases, transport, provider) = makePurchases()
        let flag1 = FinishFlag()
        await provider.scriptPurchase { _ in
            .success(FakeTransaction(transactionIdentifier: "tx-400", originalTransactionIdentifier: "tx-400",
                                     productIdentifier: "com.demo.coins", purchaseDate: Date(),
                                     expirationDate: nil, jwsRepresentation: "h.p4.s", finishFlag: flag1))
        }
        await transport.enqueue(.json(subscriberJSON())) // 没有该 txID
        _ = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.coins", localizedTitle: "", localizedDescription: "",
                                  price: 1.99, currencyCode: "USD", localizedPriceString: "$1.99"))
        #expect(!flag1.value)
    }

    @Test("消耗型：响应 non_subscriptions 确认 → finish")
    func consumableConfirmedFinishes() async throws {
        let (purchases, transport, provider) = makePurchases()
        let flag2 = FinishFlag()
        await provider.scriptPurchase { _ in
            .success(FakeTransaction(transactionIdentifier: "tx-401", originalTransactionIdentifier: "tx-401",
                                     productIdentifier: "com.demo.coins", purchaseDate: Date(),
                                     expirationDate: nil, jwsRepresentation: "h.p5.s", finishFlag: flag2))
        }
        await transport.enqueue(.json(subscriberJSON(nonSubscriptionTxIDs: ["tx-401"])))
        _ = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.coins", localizedTitle: "", localizedDescription: "",
                                  price: 1.99, currencyCode: "USD", localizedPriceString: "$1.99"))
        #expect(flag2.value)
    }

    @Test("取消：userCancelled=true，不上报 receipts，发起键清理")
    func userCancelled() async throws {
        let (purchases, transport, provider) = makePurchases()
        await transport.enqueue(.json(subscriberJSON())) // customerInfo 预热
        _ = try await purchases.customerInfo()
        await provider.scriptPurchase { _ in .userCancelled }

        let result = try await purchases.purchase(
            product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                  price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99"))
        #expect(result.userCancelled)
        let receiptCalls = await transport.capturedRequests.filter { $0.url?.path == "/v1/receipts" }
        #expect(receiptCalls.isEmpty)
    }

    @Test("#10：.myApp 模式 —— SDK 拒绝发起购买；updates 观察上报但不 finish；台账去重")
    func observerMode() async throws {
        let (purchases, transport, provider) = makePurchases(completedBy: .myApp)

        await #expect(throws: PurchasesError.self) {
            _ = try await purchases.purchase(
                product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "", localizedDescription: "",
                                      price: 9.99, currencyCode: "USD", localizedPriceString: "$9.99"))
        }

        let flag = FinishFlag()
        let tx = FakeTransaction(transactionIdentifier: "tx-500", originalTransactionIdentifier: "tx-500",
                                 productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                 expirationDate: Date().addingTimeInterval(3600),
                                 jwsRepresentation: "h.p6.s", finishFlag: flag)
        await transport.enqueue(.json(subscriberJSON())) // customerInfo 预热 + 触发 start()（挂 updates 消费者）
        _ = try await purchases.customerInfo()
        await transport.enqueue(.json(subscriberJSON())) // 上报响应
        await provider.emit(tx)

        let posted = await waitUntil {
            await transport.capturedRequests.contains { $0.url?.path == "/v1/receipts" }
        }
        #expect(posted)
        #expect(!flag.value) // 宿主自管 finish（P2 / .myApp）

        let firstCount = await transport.capturedRequests.filter { $0.url?.path == "/v1/receipts" }.count
        let bodyData = await transport.capturedRequests.first { $0.url?.path == "/v1/receipts" }?.httpBody
        let body = try JSONSerialization.jsonObject(with: bodyData!) as! [String: Any]
        #expect(body["observer_mode"] as? Bool == true)

        // 台账去重：同交易再投不再上报
        await provider.emit(tx)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let secondCount = await transport.capturedRequests.filter { $0.url?.path == "/v1/receipts" }.count
        #expect(secondCount == firstCount)
    }
}
