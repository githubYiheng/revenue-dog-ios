//
//  StoreKitPurchaseFlowTests.swift
//  StoreKitTest 集成测试样板 —— 「购买成功 → 上报 → finish」端到端一条。
//
//  ⚠️ 运行前提（实测结论，详见 docs/research/verify/storekittest-spm.md）：
//  1. **必须有宿主 app（TEST_HOST）**。纯 SwiftPM testTarget（无 app host）下
//     `Bundle.main` 是 `com.apple.dt.xctest.tool`，进程没有 application-identifier
//     entitlement：`Product.purchase()` / `SKTestSession.buyProduct` 一律失败
//     （iOS 26 报 `.notEntitled`，iOS 18 报 `.unknown`），且
//     `Transaction.currentEntitlements` / `.all` / `.unfinished` **全部返回空**。
//     → 本文件不能挂在 `RevenueDogTests` 上，必须挂在宿主 app 的 unit-test target。
//  2. **iOS 26.x 模拟器上 SKTestSession 整体失灵**（storefront 读回空串、
//     `Product.products(for:)` 返回 0 个），iOS 18.5 正常 —— 对应
//     Sources/RevenueDog/StoreKitLayer/StoreKitAbstraction.swift 里记的 FB22500243。
//     → CI 必须把 destination 钉在 iOS 18.x 模拟器。
//
//  该文件用 `#if canImport(StoreKitTest)` 门控，未接入宿主 app target 时不参与编译。
//

import Foundation
import Testing

#if canImport(StoreKitTest) && canImport(StoreKit)
import StoreKit
import StoreKitTest
@testable import RevenueDog

// MARK: - 自带的最小传输层替身
//
// 不复用 RevenueDogTests/Support/MockTransport.swift：那个文件属于纯逻辑单测 target，
// 本文件在宿主 app 的 test target 里编译，两边不共享 target。

private actor StubTransport: HTTPTransport {

    private let receiptsResponse: Data
    private let subscribersResponse: Data
    private(set) var capturedPaths: [String] = []
    private(set) var receiptsBodies: [Data] = []

    init(receiptsResponse: String, subscribersResponse: String) {
        self.receiptsResponse = Data(receiptsResponse.utf8)
        self.subscribersResponse = Data(subscribersResponse.utf8)
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        let path = request.url?.path ?? ""
        capturedPaths.append(path)
        if path.hasSuffix("/receipts") {
            receiptsBodies.append(request.httpBody ?? Data())
            return HTTPTransportResponse(statusCode: 200, headers: [:], body: receiptsResponse)
        }
        return HTTPTransportResponse(statusCode: 200, headers: [:], body: subscribersResponse)
    }

    func paths() -> [String] { capturedPaths }
    func bodies() -> [Data] { receiptsBodies }
}

// MARK: - 测试

@MainActor
@Suite("StoreKitTest 集成：购买 → 上报 → finish", .serialized)
struct StoreKitPurchaseFlowTests {

    /// 后端 `POST /v1/receipts` 的最小 200 响应：把刚买的月订阅算作已确认权益。
    private static let receiptsJSON = """
    {"request_date_ms":0,"subscriber":{"original_app_user_id":"test",\
    "first_seen":"2026-01-01T00:00:00Z","subscriptions":{"com.demo.monthly":\
    {"expires_date":"2099-01-01T00:00:00Z","purchase_date":"2026-01-01T00:00:00Z",\
    "store":"app_store"}},"entitlements":{"pro":{"expires_date":"2099-01-01T00:00:00Z",\
    "purchase_date":"2026-01-01T00:00:00Z","product_identifier":"com.demo.monthly"}},\
    "non_subscriptions":{},"subscriber_attributes":{}}}
    """

    private static let subscribersJSON = """
    {"request_date_ms":0,"subscriber":{"original_app_user_id":"test",\
    "first_seen":"2026-01-01T00:00:00Z","subscriptions":{},"entitlements":{},\
    "non_subscriptions":{},"subscriber_attributes":{}}}
    """

    /// `.storekit` 从**宿主 app bundle** 里取（app target 把它作为 resource 打进去）。
    /// 若改为挂 test bundle，把 `Bundle.main` 换成 `Bundle(for:)`/`Bundle.module`。
    private func makeSession() throws -> SKTestSession {
        let session: SKTestSession
        if let url = Bundle.main.url(forResource: "RevenueDog", withExtension: "storekit") {
            session = try SKTestSession(contentsOf: url)
        } else {
            session = try SKTestSession(configurationFileNamed: "RevenueDog")
        }
        // 顺序要紧：resetToDefaultState() 会把 disableDialogs 冲回 NO（实测）。
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = "USA"
        return session
    }

    @Test("订阅购买成功 → POST /v1/receipts 带 JWS → 200 后才 finish")
    func purchaseReportsThenFinishes() async throws {
        let session = try makeSession()
        // 前置自检：iOS 26.x 模拟器上 SKTestSession 失灵，这里会直接空手而归。
        let probe = try await Product.products(for: ["com.demo.monthly"])
        try #require(!probe.isEmpty,
                     "SKTestSession 未接管本进程：检查 destination 是否为 iOS 18.x，以及 test target 是否配了 TEST_HOST")

        let transport = StubTransport(receiptsResponse: Self.receiptsJSON,
                                      subscribersResponse: Self.subscribersJSON)
        var deps = Purchases.Dependencies.live(configuration: .init(apiKey: "test"))
        deps.transport = transport
        deps.storeKit = SK2Provider()   // 真身 SK2，由 SKTestSession 驱动

        Purchases.resetForTesting()
        let purchases = Purchases.configure(with: .init(apiKey: "test"), dependencies: deps)
        defer { Purchases.resetForTesting() }

        // orchestrator 内部会按 productIdentifier 重新向 StoreKit 取货，
        // 所以这里只需要一个 identifier 正确的 StoreProduct 壳。
        let product = StoreProduct(productIdentifier: "com.demo.monthly",
                                   localizedTitle: "Demo Pro Monthly",
                                   localizedDescription: "Demo Pro 月订阅",
                                   price: 9.99,
                                   currencyCode: "USD",
                                   localizedPriceString: "$9.99")

        let result = try await purchases.purchase(product: product)
        #expect(result.userCancelled == false)

        // 铁律 P2：后端 200 落库前绝不 finish —— 这里 200 已回，交易应已 finish。
        // SKTestTransaction 不暴露 finish 状态，改问 StoreKit 侧的未完成队列。
        #expect(session.allTransactions().contains { $0.productIdentifier == "com.demo.monthly" },
                "SKTestSession 应记录到这笔购买")
        var stillUnfinished: [String] = []
        for await tx in StoreKit.Transaction.unfinished {
            stillUnfinished.append(tx.unsafePayloadValue.productID)
        }
        #expect(!stillUnfinished.contains("com.demo.monthly"), "后端已 200，交易必须已 finish")

        // 上报确实发生，且 body 带 SK2 JWS 原文（裁决 F8：不做 base64）。
        let paths = await transport.paths()
        #expect(paths.contains { $0.hasSuffix("/receipts") })
        let bodies = await transport.bodies()
        let body = try #require(bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let fetchToken = try #require(json["fetch_token"] as? String)
        #expect(fetchToken.hasPrefix("eyJ"), "fetch_token 应是 JWS 原文")
    }
}
#endif
