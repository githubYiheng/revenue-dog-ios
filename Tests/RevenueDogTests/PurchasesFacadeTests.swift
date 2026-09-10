//
//  PurchasesFacadeTests.swift
//  M1 端到端接线：configure → 身份 → GET subscribers → offerings。
//

import Foundation
import Testing
@testable import RevenueDog

// 单例串行域（见 Support/SingletonSerialDomain.swift）：本 suite 碰 Purchases 静态单例，
// 必须与其它同类 suite 串行，不能靠 suite 内 `.serialized`。
extension PurchasesSingletonDomain {
@MainActor
@Suite("Purchases 门面（M1 接线）", .serialized)
final class PurchasesFacadeTests {

    private let transport: MockTransport
    private let purchases: Purchases

    init() {
        Purchases.resetForTesting()
        let transport = MockTransport()
        self.transport = transport

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogTests/\(UUID().uuidString)", isDirectory: true)
        let dependencies = Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: directory,
            storeKit: nil,
            diagnostics: .isolated(),
        )
        self.purchases = Purchases.configure(
            with: Configuration(apiKey: "pk_test_0123456789")
                .with(appUserID: nil)
                .with(purchasesCompletedBy: .revenueDog)
                .with(baseURL: URL(string: "https://api.revenuedog.com")!),
            dependencies: dependencies
        )
    }

    @Test("configure 后立刻可读匿名 appUserID")
    func configuredWithAnonymousIdentity() {
        #expect(Purchases.isConfigured)
        #expect(purchases.isAnonymous)
        #expect(purchases.appUserID.hasPrefix("$RDAnonymousID:"))
        #expect(purchases.configuration.purchasesCompletedBy == .revenueDog)
    }

    @Test("customerInfo() 走 GET /v1/subscribers 并写缓存；第二次命中缓存不再发请求")
    func customerInfoFetchesThenCaches() async throws {
        await transport.enqueue(.json(Fixtures.customerInfoOfficialExample))

        let info = try await purchases.customerInfo()
        #expect(info.originalAppUserID == "XXX-XXXXX-XXXXX-XX")
        #expect(await transport.callCount == 1)
        #expect(purchases.cachedCustomerInfo == info)

        _ = try await purchases.customerInfo()
        #expect(await transport.callCount == 1)

        // 强制拉网则再发一次。
        await transport.enqueue(.json(Fixtures.customerInfoOfficialExample))
        _ = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)
        #expect(await transport.callCount == 2)
    }

    @Test("offerings() 解析后端最小响应")
    func offerings() async throws {
        await transport.enqueue(.json(Fixtures.offeringsMinimalExample))

        let offerings = try await purchases.offerings()
        #expect(offerings.current?.identifier == "default")
        #expect(offerings.current?.availablePackages.count == 3)
        #expect(offerings.current?.monthly?.platformProductIdentifier == "monthly_free_trial")
    }

    @Test("logIn 切换身份；201 → created")
    func logIn() async throws {
        await transport.enqueue(.json(Fixtures.customerInfoOfficialExample, statusCode: 201))

        let result = try await purchases.logIn("user_42")
        #expect(result.created)
        #expect(purchases.appUserID == "user_42")
        #expect(purchases.isAnonymous == false)

        // logOut 换回匿名身份。
        await transport.enqueue(.json(Fixtures.customerInfoOfficialExample))
        _ = try await purchases.logOut()
        #expect(purchases.isAnonymous)
    }

    @Test("M2/M3 未实现路径抛 notImplementedError，而不是崩溃")
    func notImplementedPaths() async throws {
        let package = Package(identifier: "$rc_monthly",
                              packageType: .monthly,
                              offeringIdentifier: "default",
                              platformProductIdentifier: "monthly_free_trial",
                              storeProduct: nil)

        await #expect(throws: PurchasesError.self) { _ = try await self.purchases.purchase(package: package) }
        await #expect(throws: PurchasesError.self) { _ = try await self.purchases.restorePurchases() }
        await #expect(throws: PurchasesError.self) { _ = try await self.purchases.syncPurchases() }
    }
}
}
