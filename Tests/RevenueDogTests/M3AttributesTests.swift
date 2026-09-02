//
//  M3AttributesTests.swift
//  Subscriber attributes：本地缓冲（按 appUserID 分桶 / 持久化 / 未同步标记）、LWW、
//  50 上限与墓碑删除、同步时机（进入后台 / 购买搭车 / logIn 合并前后 / 显式）。
//
//  契约 §2.4 + 服务端 `workers/api/src/attributes.ts`（以服务端为准）。
//  坑矩阵：#51（一属性一 key，消灭 RMW）、#52（logIn 前 sync + 只有旧身份匿名才迁移）、
//  #127（4xx 除 404 视为已同步，不再重试）。
//

import Foundation
import Testing
@testable import RevenueDog

#if canImport(AppKit) && !canImport(UIKit)
import AppKit
#endif

// MARK: - Fixtures

private func attrSubscriberJSON(userID: String = "tester") -> String {
    """
    {"request_date":"2026-08-27T00:00:00Z","request_date_ms":1782518400000,
     "subscriber":{"original_app_user_id":"\(userID)","original_application_version":null,
       "original_purchase_date":null,"first_seen":"2026-08-01T00:00:00Z","last_seen":"2026-08-27T00:00:00Z",
       "management_url":null,"entitlements":{},"subscriptions":{},"non_subscriptions":{}}}
    """
}

/// 按路径决定状态码（断言不依赖请求先后顺序）。
private actor AttrTransport: HTTPTransport {

    private var statusByPath: [String: Int] = [:]
    private var bodyForNext: String
    private(set) var capturedRequests: [URLRequest] = []

    init(responseJSON: String = attrSubscriberJSON()) { self.bodyForNext = responseJSON }

    func setStatus(_ status: Int, forPath path: String) { statusByPath[path] = status }
    func setResponseJSON(_ json: String) { bodyForNext = json }

    func requests(path: String) -> [URLRequest] { capturedRequests.filter { $0.url?.path == path } }
    func requests(pathSuffix: String) -> [URLRequest] {
        capturedRequests.filter { $0.url?.path.hasSuffix(pathSuffix) == true }
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        capturedRequests.append(request)
        let path = request.url?.path ?? ""
        let status = statusByPath.first { path.hasSuffix($0.key) }?.value ?? 200
        return HTTPTransportResponse(statusCode: status,
                                     headers: status == 200 ? [:] : ["Is-Retryable": "false"],
                                     body: Data(bodyForNext.utf8))
    }
}

private func attrTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RevenueDogM3Attr/\(UUID().uuidString)", isDirectory: true)
}

@MainActor
private func makeAttrPurchases(
    transport: AttrTransport,
    appUserID: String? = nil,
    identity: InMemoryIdentityStorage = InMemoryIdentityStorage(),
    directory: URL = attrTempDirectory(),
) -> (Purchases, FakeStoreKitProvider) {
    Purchases.resetForTesting()
    let storeKit = FakeStoreKitProvider(products: [FakeProduct(productIdentifier: "com.demo.monthly")])
    let purchases = Purchases.configure(
        with: Configuration(apiKey: "pk_test_0123456789")
            .with(appUserID: appUserID)
            .with(baseURL: URL(string: "https://api.revenuedog.com")!),
        dependencies: Purchases.Dependencies(
            identityStorage: identity,
            cacheStorage: InMemoryCacheStorage(),
            transport: transport,
            pendingPurchasesDirectory: directory,
            storeKit: storeKit,
            delayScheduler: NoDelayScheduler(),
            attributionState: InMemoryAttributionStateStorage(),
        ),
    )
    return (purchases, storeKit)
}

private func attrWaitFor(timeoutMs: Int = 3000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

/// 等 fire-and-forget 的 setter 把属性落进缓冲（比 sleep 确定）。
@MainActor
private func waitForBuffered(_ purchases: Purchases, count: Int, timeoutMs: Int = 3000) async -> Bool {
    for _ in 0..<(timeoutMs / 20) {
        if await purchases.unsyncedAttributes().count == count { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await purchases.unsyncedAttributes().count == count
}

private func attrBody(_ request: URLRequest?) -> [String: Any] {
    guard let data = request?.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

// MARK: - 纯 Store 层（不碰单例，可并行）

@Suite("M3 属性缓冲（Store 纯逻辑）")
struct SubscriberAttributesStoreTests {

    private func makeStore() -> SubscriberAttributesStore {
        SubscriberAttributesStore(directory: attrTempDirectory())
    }

    @Test("按 appUserID 分桶 + 未同步标记：两个身份的同名键互不干扰")
    func bucketsByAppUserID() async throws {
        let store = makeStore()
        _ = await store.set(["favorite": "pizza"], appUserID: "alice")
        _ = await store.set(["favorite": "ramen"], appUserID: "bob")

        #expect(await store.attribute(forKey: "favorite", appUserID: "alice")?.value == "pizza")
        #expect(await store.attribute(forKey: "favorite", appUserID: "bob")?.value == "ramen")
        #expect(await store.unsynced(appUserID: "alice").count == 1)

        await store.markSynced(await store.unsynced(appUserID: "alice"), appUserID: "alice")
        #expect(await store.unsynced(appUserID: "alice").isEmpty)
        #expect(await store.unsynced(appUserID: "bob").count == 1) // bob 的桶没被连累
    }

    @Test("持久化：换一个 Store 实例指向同一目录，缓冲与未同步标记都还在")
    func persistsAcrossInstances() async throws {
        let directory = attrTempDirectory()
        let first = SubscriberAttributesStore(directory: directory)
        _ = await first.set(["favorite": "pizza", SubscriberAttributeKeys.email: "a@b.c"], appUserID: "alice")

        let second = SubscriberAttributesStore(directory: directory)
        let unsynced = await second.unsynced(appUserID: "alice")
        #expect(unsynced.map(\.key) == ["$email", "favorite"]) // 稳定顺序
        #expect(unsynced.allSatisfy { !$0.isSynced })
    }

    @Test("LWW：updated_at_ms 严格单调递增，本地时钟被拨回过去也不会让服务端丢弃写入")
    func lastWriteWinsTimestampIsMonotonic() async throws {
        let store = makeStore()
        let future = Date().addingTimeInterval(3600)
        _ = await store.set(["favorite": "pizza"], appUserID: "alice", now: future)
        let first = try #require(await store.attribute(forKey: "favorite", appUserID: "alice"))

        // 时钟被拨回一小时后再写：时间戳仍必须 > 上一条，否则服务端
        // `excluded.updated_at_ms >= 库中值` 不成立，这次更新会被静默丢弃
        _ = await store.set(["favorite": "ramen"], appUserID: "alice", now: Date())
        let second = try #require(await store.attribute(forKey: "favorite", appUserID: "alice"))
        #expect(second.value == "ramen")
        #expect(second.updatedAtMs > first.updatedAtMs)
    }

    @Test("墓碑：空串与 nil 同义 = 删除；上行编码为空串（receipts 通道只认 string）")
    func tombstoneEncodesAsEmptyString() async throws {
        let store = makeStore()
        _ = await store.set(["favorite": "pizza"], appUserID: "alice")
        await store.markSynced(await store.unsynced(appUserID: "alice"), appUserID: "alice")

        _ = await store.set(["favorite": ""], appUserID: "alice")
        let tombstone = try #require(await store.attribute(forKey: "favorite", appUserID: "alice"))
        #expect(tombstone.value == nil)
        #expect(tombstone.isTombstone)
        #expect(!tombstone.isSynced)
        #expect(SubscriberAttributeWire(tombstone).value == "")     // 上行 = 空串，不是 JSON null

        // nil 与空串等价
        _ = await store.set(["other": "x"], appUserID: "alice")
        _ = await store.set(["other": nil], appUserID: "alice")
        #expect(await store.attribute(forKey: "other", appUserID: "alice")?.isTombstone == true)

        // 同步完成后墓碑本地清除（服务端已存 NULL）
        await store.markSynced(await store.unsynced(appUserID: "alice"), appUserID: "alice")
        #expect(await store.attribute(forKey: "favorite", appUserID: "alice") == nil)
    }

    @Test("50 个自定义属性上限：超出的键被拒绝；保留键与墓碑不计入配额")
    func enforcesFiftyCustomAttributeLimit() async throws {
        let store = makeStore()
        var batch: [String: String?] = [:]
        for index in 0..<50 { batch["custom\(index)"] = "v\(index)" }
        #expect(await store.set(batch, appUserID: "alice").isEmpty)
        #expect(await store.all(appUserID: "alice").count == 50)

        // 第 51 个自定义键被拒
        #expect(await store.set(["overflow": "x"], appUserID: "alice") == ["overflow"])
        #expect(await store.attribute(forKey: "overflow", appUserID: "alice") == nil)

        // 已存在的键更新不占新配额
        #expect(await store.set(["custom0": "updated"], appUserID: "alice").isEmpty)
        // 保留键不计入 50 上限（服务端计数口径：`key NOT LIKE '$%'`）
        #expect(await store.set([SubscriberAttributeKeys.email: "a@b.c"], appUserID: "alice").isEmpty)

        // 删掉一个之后腾出配额
        _ = await store.set(["custom1": ""], appUserID: "alice")
        #expect(await store.set(["overflow": "x"], appUserID: "alice").isEmpty)
    }

    @Test("键/值校验：非法自定义键与超 500 字符的 value 被端上挡下（服务端整批 400）")
    func rejectsInvalidKeysAndOversizedValues() async throws {
        let store = makeStore()
        let rejected = await store.set([
            "invalid key with spaces": "x",   // 含空格
            "9startsWithDigit": "x",          // 非字母开头
            String(repeating: "k", count: 41): "x", // 超 40 字符
            "tooLong": String(repeating: "v", count: 501), // value 超 500
            "good_key-1": "ok",
        ], appUserID: "alice")
        #expect(Set(rejected) == ["invalid key with spaces", "9startsWithDigit",
                                  String(repeating: "k", count: 41), "tooLong"])
        #expect(await store.all(appUserID: "alice").map(\.key) == ["good_key-1"])

        // 边界：正好 40 字符的键、正好 500 字符的 value 必须通过
        #expect(await store.set([String(repeating: "k", count: 40): String(repeating: "v", count: 500)],
                                appUserID: "alice").isEmpty)
    }

    @Test("markSynced 只认时间戳一致的条目：在途期间被新 setter 覆盖的属性保持未同步")
    func markSyncedSkipsAttributesChangedInFlight() async throws {
        let store = makeStore()
        _ = await store.set(["favorite": "pizza"], appUserID: "alice")
        let inFlight = await store.unsynced(appUserID: "alice")

        // 请求在途时用户又改了一次
        _ = await store.set(["favorite": "ramen"], appUserID: "alice")
        await store.markSynced(inFlight, appUserID: "alice")

        let remaining = await store.unsynced(appUserID: "alice")
        #expect(remaining.count == 1)
        #expect(remaining.first?.value == "ramen") // 后一次更新没被误标为已同步
    }

    @Test("#52：logIn 属性迁移 —— 旧身份匿名才迁；两个实名用户之间不迁")
    func migratesOnlyFromAnonymousIdentity() async throws {
        let store = makeStore()
        let anonymous = IdentityManager.generateAnonymousAppUserID()
        _ = await store.set(["favorite": "pizza"], appUserID: anonymous)
        await store.markSynced(await store.unsynced(appUserID: anonymous), appUserID: anonymous)

        await store.migrateIfOldIsAnonymous(from: anonymous, to: "alice")
        let migrated = try #require(await store.attribute(forKey: "favorite", appUserID: "alice"))
        #expect(migrated.value == "pizza")
        #expect(!migrated.isSynced)  // 在新 customer 下还没落过库
        #expect(await store.all(appUserID: anonymous).isEmpty) // 旧桶清空

        // 实名 → 实名：不迁移（两个真实的人）
        await store.migrateIfOldIsAnonymous(from: "alice", to: "bob")
        #expect(await store.attribute(forKey: "favorite", appUserID: "bob") == nil)
        #expect(await store.attribute(forKey: "favorite", appUserID: "alice")?.value == "pizza")
    }
}

// MARK: - 门面 / 同步时机（碰单例，进串行域）

extension PurchasesSingletonDomain {

    @MainActor
    @Suite("M3 属性同步时机", .serialized)
    struct M3AttributesSyncTests {

        @Test("setAttributes 只落缓冲不发请求；syncAttributesIfNeeded 打出契约 §2.4 的 body")
        func explicitSyncPostsContractBody() async throws {
            let transport = AttrTransport()
            let (purchases, _) = makeAttrPurchases(transport: transport, appUserID: "alice")
            purchases.setAttributes(["favorite_food": "pizza"])
            purchases.setEmail("firstlast@gmail.com")
            purchases.setDisplayName("First Last")
            purchases.setPushToken(Data([0xab, 0x0c]))
            #expect(await waitForBuffered(purchases, count: 4))

            // 只写缓冲，不发请求
            #expect(await transport.requests(pathSuffix: "/attributes").isEmpty)

            await purchases.syncAttributesIfNeeded()

            let requests = await transport.requests(pathSuffix: "/attributes")
            #expect(requests.count == 1)
            #expect(requests.first?.url?.path == "/v1/subscribers/alice/attributes")
            #expect(requests.first?.httpMethod == "POST")

            let attributes = try #require(attrBody(requests.first)["attributes"] as? [String: Any])
            #expect(Set(attributes.keys) == ["favorite_food", "$email", "$displayName", "$apnsTokens"])
            let email = try #require(attributes["$email"] as? [String: Any])
            #expect(email["value"] as? String == "firstlast@gmail.com")
            #expect((email["updated_at_ms"] as? Int64 ?? Int64(email["updated_at_ms"] as? Int ?? 0)) > 1_700_000_000_000)
            #expect((attributes["$apnsTokens"] as? [String: Any])?["value"] as? String == "ab0c")

            // 已同步 → 再 sync 不重发
            await purchases.syncAttributesIfNeeded()
            #expect(await transport.requests(pathSuffix: "/attributes").count == 1)
        }

        @Test("同一键连续两次 setter：调用顺序 = 落盘顺序（LWW 不会被 Task 乱序翻转）")
        func sequentialSettersOnSameKeyPreserveCallOrder() async throws {
            let transport = AttrTransport()
            let (purchases, _) = makeAttrPurchases(transport: transport, appUserID: "alice")
            for index in 0..<20 { purchases.setEmail("v\(index)@example.com") }
            #expect(await waitForBuffered(purchases, count: 1))
            #expect(await purchases.unsyncedAttributes().first?.value == "v19@example.com")

            await purchases.syncAttributesIfNeeded()
            let attributes = try #require(
                attrBody(await transport.requests(pathSuffix: "/attributes").first)["attributes"] as? [String: Any])
            #expect((attributes["$email"] as? [String: Any])?["value"] as? String == "v19@example.com")
        }

        @Test("setAttributes 拒绝 `$` 保留键（避免整批 400），保留键只能走专用 setter")
        func customSetterRejectsReservedKeys() async throws {
            let transport = AttrTransport()
            let (purchases, _) = makeAttrPurchases(transport: transport, appUserID: "alice")
            purchases.setAttributes(["$email": "sneaky@example.com", "favorite_food": "pizza"])
            #expect(await waitForBuffered(purchases, count: 1))
            await purchases.syncAttributesIfNeeded()

            let attributes = try #require(
                attrBody(await transport.requests(pathSuffix: "/attributes").first)["attributes"] as? [String: Any])
            #expect(Set(attributes.keys) == ["favorite_food"]) // `$email` 被挡在门面外
        }

        @Test("同步时机 —— 进入后台通知触发一次属性同步")
        func appDidEnterBackgroundTriggersSync() async throws {
            let transport = AttrTransport()
            let (purchases, _) = makeAttrPurchases(transport: transport, appUserID: "alice")
            purchases.setAttributes(["favorite_food": "pizza"])
            #expect(await waitForBuffered(purchases, count: 1))
            #expect(await transport.requests(pathSuffix: "/attributes").isEmpty)

            #if canImport(AppKit) && !canImport(UIKit)
            // 真实通知链路（macOS 侧对应 UIApplication.didEnterBackgroundNotification）
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            #else
            purchases.applicationDidEnterBackground()
            #endif

            let synced = await attrWaitFor { await transport.requests(pathSuffix: "/attributes").count == 1 }
            #expect(synced)
            #expect(AppStateProvider.isBackgrounded)

            #if canImport(AppKit) && !canImport(UIKit)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            #else
            purchases.applicationDidBecomeActive()
            #endif
            let foreground = await attrWaitFor { AppStateProvider.isBackgrounded == false }
            #expect(foreground) // 恢复前台快照，别把 25h 后台 TTL 留给后面的测试
        }

        @Test("同步时机 —— 属性随购买收据搭车上报，之后不再单发 /attributes")
        func attributesRideAlongWithReceipt() async throws {
            let transport = AttrTransport()
            let (purchases, storeKit) = makeAttrPurchases(transport: transport, appUserID: "alice")
            purchases.setAttributes(["favorite_food": "pizza"])
            purchases.setEmail("buyer@example.com")
            #expect(await waitForBuffered(purchases, count: 2))

            let flag = FinishFlag()
            await storeKit.scriptPurchase { productID in
                .success(FakeTransaction(transactionIdentifier: "tx-attr",
                                         originalTransactionIdentifier: "tx-attr",
                                         productIdentifier: productID,
                                         purchaseDate: Date(),
                                         expirationDate: Date().addingTimeInterval(3600),
                                         jwsRepresentation: "h.attr.s",
                                         finishFlag: flag))
            }
            _ = try await purchases.purchase(
                product: StoreProduct(productIdentifier: "com.demo.monthly", localizedTitle: "",
                                      localizedDescription: "", price: 9.99, currencyCode: "USD",
                                      localizedPriceString: "$9.99"))

            let receipt = try #require(await transport.requests(path: "/v1/receipts").first)
            let attributes = try #require(attrBody(receipt)["attributes"] as? [String: Any])
            #expect(Set(attributes.keys) == ["favorite_food", "$email"])
            #expect((attributes["$email"] as? [String: Any])?["value"] as? String == "buyer@example.com")

            // 搭车成功 = 已同步：显式再 sync 也不该再发一次 /attributes
            await purchases.syncAttributesIfNeeded()
            #expect(await transport.requests(pathSuffix: "/attributes").isEmpty)
        }

        @Test("#127：属性同步 400 → 标记已同步不再重试；500 → 保留待发下次再冲")
        func fourXXIsTreatedAsSyncedFiveXXKeepsPending() async throws {
            let transport = AttrTransport()
            await transport.setStatus(400, forPath: "/attributes")
            let (purchases, _) = makeAttrPurchases(transport: transport, appUserID: "alice")
            purchases.setAttributes(["favorite_food": "pizza"])
            #expect(await waitForBuffered(purchases, count: 1))
            await purchases.syncAttributesIfNeeded()
            #expect(await transport.requests(pathSuffix: "/attributes").count == 1)
            await purchases.syncAttributesIfNeeded()
            #expect(await transport.requests(pathSuffix: "/attributes").count == 1) // 400：不再重试

            // 500：保留待发，下一次时机再冲
            let transport2 = AttrTransport()
            await transport2.setStatus(500, forPath: "/attributes")
            let (purchases2, _) = makeAttrPurchases(transport: transport2, appUserID: "bob")
            purchases2.setAttributes(["favorite_food": "ramen"])
            #expect(await waitForBuffered(purchases2, count: 1))
            await purchases2.syncAttributesIfNeeded()
            #expect(await transport2.requests(pathSuffix: "/attributes").count == 1)
            await transport2.setStatus(200, forPath: "/attributes")
            await purchases2.syncAttributesIfNeeded()
            #expect(await transport2.requests(pathSuffix: "/attributes").count == 2) // 还在待发队列里
            await purchases2.syncAttributesIfNeeded()
            #expect(await transport2.requests(pathSuffix: "/attributes").count == 2) // 这次真同步了
        }

        @Test("#52：logIn 前先冲旧身份属性，合并成功后匿名属性迁到新身份并再同步一次")
        func logInSyncsThenMigratesAnonymousAttributes() async throws {
            let transport = AttrTransport()
            let (purchases, _) = makeAttrPurchases(transport: transport)
            _ = try? await purchases.customerInfo(fetchPolicy: .cachedOnly) // 等启动收敛
            let anonymous = purchases.appUserID
            #expect(purchases.isAnonymous)

            purchases.setAttributes(["favorite_food": "pizza"])
            #expect(await waitForBuffered(purchases, count: 1))

            _ = try await purchases.logIn("alice")

            let requests = await transport.capturedRequests
            let paths = requests.compactMap { $0.url?.path } // URL.path 是解码后的形态
            // 顺序铁律：先冲旧（匿名）身份 → 再 identify → 迁移后再冲新身份
            let identifyIndex = try #require(paths.firstIndex(of: "/v1/subscribers/identify"))
            let oldIndex = try #require(paths.firstIndex(of: "/v1/subscribers/\(anonymous)/attributes"))
            let newIndex = try #require(paths.lastIndex(of: "/v1/subscribers/alice/attributes"))
            #expect(oldIndex < identifyIndex)
            #expect(newIndex > identifyIndex)

            // 契约 §1.1：路径参数必须 URL 编码后再拼接（`$` / `:` 都不能裸奔）
            let rawURL = try #require(requests[oldIndex].url?.absoluteString)
            #expect(rawURL.contains("%24RCAnonymousID%3A"))

            // 迁移过去的属性确实在新身份下发出（而不是空批）
            let migrated = try #require(attrBody(requests[newIndex])["attributes"] as? [String: Any])
            #expect((migrated["favorite_food"] as? [String: Any])?["value"] as? String == "pizza")
        }
    }
}
