//
//  M3CoreTests.swift
//  M3 核心语义：restore/sync（契约 C / 裁决 C2-C）、logIn → identify 端点、
//  customerInfoStream 完整语义（订阅回放 + 去重）。
//

import Foundation
import Testing
@testable import RevenueDog

#if canImport(StoreKit)
import StoreKit
#endif

private func subscriberJSON(userID: String = "tester") -> String {
    """
    {"request_date":"2026-08-27T00:00:00Z","request_date_ms":1782518400000,
     "subscriber":{"original_app_user_id":"\(userID)","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
    """
}

@MainActor
private func makeM3(
    prepare: (@Sendable (FakeStoreKitProvider, MockTransport) async -> Void)? = nil,
) async -> (Purchases, MockTransport, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    let transport = MockTransport()
    let provider = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
    await prepare?(provider, transport)
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: InMemoryIdentityStorage(),
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("RevenueDogM3/\(UUID().uuidString)", isDirectory: true),
            storeKit: provider,
            delayScheduler: NoDelayScheduler(),
        ),
    )
    return (purchases, transport, provider)
}

@MainActor
@Suite("M3 核心语义", .serialized)
struct M3CoreTests {

    @Test("restore（契约 C）：弹框同步 + 最新一笔 JWS + app_transaction 上报，initiation_source=restore")
    func restorePostsLatestWithAppTransaction() async throws {
        let flag = FinishFlag()
        let older = FakeTransaction(transactionIdentifier: "tx-old", originalTransactionIdentifier: "tx-old",
                                    productIdentifier: "com.demo.monthly", purchaseDate: Date(timeIntervalSinceNow: -86400),
                                    expirationDate: Date().addingTimeInterval(3600),
                                    jwsRepresentation: "h.old.s", finishFlag: FinishFlag())
        let newer = FakeTransaction(transactionIdentifier: "tx-new", originalTransactionIdentifier: "tx-new",
                                    productIdentifier: "com.demo.monthly", purchaseDate: Date(),
                                    expirationDate: Date().addingTimeInterval(3600),
                                    jwsRepresentation: "h.new.s", finishFlag: flag)
        let (purchases, transport, provider) = await makeM3 { provider, transport in
            await provider.setCurrentEntitlements([older, newer])
            await provider.setAppTransaction(AppTransactionInfo(jwsRepresentation: "h.apptx.s", environment: "Production"))
            // 启动 currentEntitlements 扫描会先补报两笔（台账为空）
            await transport.enqueue(.json(subscriberJSON()))
            await transport.enqueue(.json(subscriberJSON()))
            // restore 本身的上报
            await transport.enqueue(.json(subscriberJSON()))
        }

        _ = try await purchases.restorePurchases()

        let syncs = await provider.syncCallCount
        #expect(syncs == 1) // 用户显式动作弹了框

        let restoreRequest = await transport.capturedRequests.last
        #expect(restoreRequest?.url?.path == "/v1/receipts")
        let body = try JSONSerialization.jsonObject(with: restoreRequest!.httpBody!) as! [String: Any]
        #expect(body["fetch_token"] as? String == "h.new.s") // 最新一笔（#26 排序）
        #expect(body["initiation_source"] as? String == "restore")
        #expect(body["app_transaction"] as? String == "h.apptx.s") // 契约 C 的另一半
    }

    @Test("restore：用户取消 AppStore.sync → purchaseCancelledError，不上报")
    func restoreUserCancelled() async throws {
        #if canImport(StoreKit)
        let (purchases, transport, _) = await makeM3 { provider, _ in
            await provider.scriptSyncError(StoreKitError.userCancelled)
        }
        do {
            _ = try await purchases.restorePurchases()
            Issue.record("应当抛出取消错误")
        } catch let error as PurchasesError {
            #expect(error.code == .purchaseCancelledError)
        }
        let receipts = await transport.capturedRequests.filter { $0.url?.path == "/v1/receipts" }
        #expect(receipts.isEmpty)
        #endif
    }

    @Test("syncPurchases：静默（不弹框）；无本地交易 → 仅刷新服务端视图")
    func silentSyncWithoutLocalTransactions() async throws {
        let (purchases, transport, provider) = await makeM3 { _, transport in
            await transport.enqueue(.json(subscriberJSON()))
        }
        let info = try await purchases.syncPurchases()
        #expect(info.originalAppUserID == "tester")
        let syncs = await provider.syncCallCount
        #expect(syncs == 0) // 静默：绝不弹框
        let receipts = await transport.capturedRequests.filter { $0.url?.path == "/v1/receipts" }
        #expect(receipts.isEmpty) // 无可恢复交易 → 不发 receipts
        let gets = await transport.capturedRequests.filter { $0.url?.path.hasPrefix("/v1/subscribers/") == true }
        #expect(!gets.isEmpty)
    }

    @Test("logIn → POST /v1/subscribers/identify：body 形状正确、201 → created、身份切换")
    func logInGoesThroughIdentify() async throws {
        let (purchases, transport, _) = await makeM3()
        _ = try? await purchases.customerInfo(fetchPolicy: .cachedOnly) // 等启动收敛（bootstrap 后的持久身份）
        let anonymous = purchases.appUserID
        await transport.enqueue(.json(subscriberJSON(userID: "alice"), statusCode: 201))

        let result = try await purchases.logIn("alice")
        #expect(result.created)
        #expect(result.customerInfo.originalAppUserID == "alice")
        #expect(purchases.appUserID == "alice")

        let request = await transport.capturedRequests.last
        #expect(request?.url?.path == "/v1/subscribers/identify")
        let body = try JSONSerialization.jsonObject(with: request!.httpBody!) as! [String: Any]
        #expect(body["app_user_id"] as? String == anonymous)
        #expect(body["new_app_user_id"] as? String == "alice")
    }

    @Test("logIn：服务端失败 → 本地身份不切换")
    func logInFailureKeepsLocalIdentity() async throws {
        let (purchases, transport, _) = await makeM3()
        _ = try? await purchases.customerInfo(fetchPolicy: .cachedOnly) // 等启动收敛
        let before = purchases.appUserID
        await transport.enqueue(.failure(statusCode: 500))
        await transport.enqueue(.failure(statusCode: 500))
        await #expect(throws: PurchasesError.self) { _ = try await purchases.logIn("bob") }
        #expect(purchases.appUserID == before)
    }

    @Test("customerInfoStream 完整语义：订阅即回放最近值；相同值去重不重复推送")
    func streamReplayAndDedup() async throws {
        let (purchases, transport, _) = await makeM3 { _, transport in
            await transport.enqueue(.json(subscriberJSON())) // 首次 fetch
        }
        _ = try await purchases.customerInfo(fetchPolicy: .fetchCurrent) // 触发一次 publish

        // 订阅晚于 publish：仍应立即回放最近值
        let frames = FrameRecorder()
        let stream = purchases.customerInfoStream
        let collector = Task.detached {
            for await info in stream { await frames.record(info) }
        }
        let gotFirst = await waitUntilFrames(frames) { $0 >= 1 }
        #expect(gotFirst)
        #expect(await frames.last?.originalAppUserID == "tester")

        // 相同内容再 fetch：publish 去重 → 不应有第二帧
        await transport.enqueue(.json(subscriberJSON()))
        _ = try await purchases.customerInfo(fetchPolicy: .fetchCurrent)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await frames.count == 1) // 无重复帧
        collector.cancel()
    }
}

private actor FrameRecorder {
    private(set) var all: [CustomerInfo] = []
    var count: Int { all.count }
    var last: CustomerInfo? { all.last }
    func record(_ info: CustomerInfo) { all.append(info) }
}

private func waitUntilFrames(_ frames: FrameRecorder, timeoutMs: Int = 2000, _ condition: @Sendable (Int) -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if condition(await frames.count) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition(await frames.count)
}
