//
//  PublicTransportInjectionTests.swift
//  待办 39 D：宿主可用的假后端注入点。
//
//  **本文件故意不 `@testable import RevenueDog`** —— 它是「宿主只用公开面就能把假后端接进来」
//  的活样例，也是这条公开路径的可用性门禁：`HTTPTransport` / `HTTPTransportResponse` /
//  `Configuration.with(transport:)` 任何一个不是 public，本文件立刻编译不过。
//

import Foundation
import Testing
import RevenueDog

// MARK: - 宿主视角的假后端（只依赖公开面）

/// 回放固定响应并记下走过的路径。宿主在自己的集成测试里写的就是这种东西。
private actor HostFakeBackend: HTTPTransport {

    private(set) var capturedPaths: [String] = []
    private let body: Data

    init(body: String) {
        self.body = Data(body.utf8)
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        capturedPaths.append(request.url?.path ?? "")
        return HTTPTransportResponse(statusCode: 200,
                                     headers: ["Content-Type": "application/json"],
                                     body: body)
    }
}

private let hostSubscriberJSON = """
{"request_date":"2026-09-10T00:00:00Z","request_date_ms":1789000000000,
 "subscriber":{"original_app_user_id":"host-fake-backend","original_application_version":null,
   "original_purchase_date":null,"first_seen":"2026-09-01T00:00:00Z","last_seen":"2026-09-10T00:00:00Z",
   "management_url":null,
   "entitlements":{"pro":{"expires_date":"2099-01-01T00:00:00Z","grace_period_expires_date":null,
                          "product_identifier":"com.demo.monthly","purchase_date":"2026-09-01T00:00:00Z"}},
   "subscriptions":{},"non_subscriptions":{}}}
"""

// MARK: - 用例

extension PurchasesSingletonDomain {
@MainActor
@Suite("v0.2.0 · 公开传输层注入（D）", .serialized)
struct PublicTransportInjectionTests {

    @Test("Configuration.with(transport:) 把 customerInfo() 接到宿主自己的假后端上")
    func hostInjectedTransportServesCustomerInfo() async throws {
        PublicAPIHarness.reset()
        defer { PublicAPIHarness.reset() }

        let backend = HostFakeBackend(body: hostSubscriberJSON)
        let purchases = Purchases.configure(
            with: Configuration(apiKey: "pk_public_transport_test")
                .with(appUserID: "host-fake-backend")
                .with(baseURL: URL(string: "https://api.revenuedog.invalid")!)
                .with(diagnosticsEnabled: false)   // 诊断上传会往假后端多打请求，断言里不需要
                .with(transport: backend))
        await PublicAPIHarness.awaitConfigured()

        // `.fetchCurrent`：必须真的走一次传输层（不吃上一轮跑留在磁盘上的缓存）
        let info = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)

        #expect(info.originalAppUserID == "host-fake-backend")
        #expect(info.entitlements.active.keys.contains("pro"))
        #expect(await backend.capturedPaths.contains { $0.hasSuffix("/v1/subscribers/host-fake-backend") })
        #expect(purchases.cachedCustomerInfo?.originalAppUserID == "host-fake-backend")
    }
}
}
