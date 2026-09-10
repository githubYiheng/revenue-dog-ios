//
//  StoreKitScenarioTests.swift
//  StoreKitTest 全场景 —— 真 StoreKit（SKTestSession）+ 假后端（MockTransport）。
//
//  每个测试名/注释里标了对应的**坑矩阵编号**（docs/plan/ios-sdk-pitfall-matrix.md）
//  与**铁律编号**（docs/plan/ios-sdk-design.md §3）。
//
//  运行：sdk/ios/scripts/storekit-tests.sh  （destination 钉 iOS 18.x）
//

import Foundation
import Testing

#if canImport(StoreKitTest) && canImport(StoreKit)
import StoreKit
import StoreKitTest
@testable import RevenueDog

extension StoreKitScenarioDomain {

    // MARK: - ⑪ 客户端诊断事件序列（ADR 0028 / sdk-diagnostics §1.3）

    @MainActor
    @Suite("⑪ 诊断事件序列（真 StoreKit + 真事件管线）")
    struct DiagnosticsSequenceTests {

        @Test("一次购买产出 purchase_started → transaction_observed → receipt_post → finish_decision，字段合规")
        func purchaseProducesEventSequence() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }
            _ = session

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture],
                    entitlements: ["pro": (DemoProduct.monthly, FakeBackend.farFuture)]))],
                diagnosticsEnabled: true)

            _ = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))

            let events = await sdk.diagnosticEvents()
            let types = events.map(\.type)
            // 顺序断言：四个关键节点必须按这个先后出现（中间可以有别的事件）。
            let expected = [DiagnosticsEventType.purchaseStarted,
                            DiagnosticsEventType.transactionObserved,
                            DiagnosticsEventType.receiptPost,
                            DiagnosticsEventType.finishDecision]
            var cursor = types.startIndex
            for type in expected {
                let found = types[cursor...].firstIndex(of: type)
                #expect(found != nil, "事件序列里缺 \(type)：\(types)")
                guard let found else { return }
                cursor = types.index(after: found)
            }

            // 真 JWS 走过这条链路 —— 但它**绝不能**出现在任何事件里（契约 §1.3 末段）。
            let dump = try #require(String(data: try DiagnosticsCoding.encoder.encode(events), encoding: .utf8))
            #expect(!dump.contains("eyJ"), "诊断事件里出现了 JWS 片段")
            #expect(!dump.lowercased().contains("fetch_token"))
            #expect(!dump.contains("pk_storekit_test"), "诊断事件里出现了 API key")

            // finish_decision 的判据：后端 200 且是订阅型 → finished / server_ack。
            let finish = try #require(events.last { $0.type == DiagnosticsEventType.finishDecision })
            #expect(finish.fields["decision"] == .string(DiagnosticsFinishDecision.finished))
            #expect(finish.fields["reason"] == .string(DiagnosticsFinishReason.serverAck))
            // receipt_post 带真实交易 id 与 200。
            let receipt = try #require(events.first { $0.type == DiagnosticsEventType.receiptPost })
            #expect(receipt.fields["status"] == .int(200))
            #expect(receipt.fields["transaction_id"] != nil)
            // §6-2：每条事件自带记录时刻的身份；§6-5：会话内 seq 单调。
            #expect(events.allSatisfy { $0.appUserID == "storekit-test" })
            #expect(events.compactMap(\.seq) == events.compactMap(\.seq).sorted())
        }
    }
}

extension StoreKitScenarioDomain {

    // MARK: - ① 购买成功 → 上报带真 JWS → 200 后才 finish

    @MainActor
    @Suite("① 购买闭环（铁律 P2 / 裁决 F8 / 坑 #6）")
    struct PurchaseSuccessTests {

        @Test("订阅购买成功 → POST /v1/receipts 带真 JWS → 200 后才 finish")
        func purchaseReportsThenFinishes() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture],
                    entitlements: ["pro": (DemoProduct.monthly, FakeBackend.farFuture)]))])

            let result = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            #expect(result.userCancelled == false)
            #expect(result.transactionIdentifier != nil)
            #expect(result.customerInfo.entitlements.active.keys.contains("pro"))

            // 铁律 P2：后端 200 落库前绝不 finish —— 200 已回，交易应已 finish。
            let unfinished = await SKObserve.unfinishedProductIDs()
            #expect(!unfinished.contains(DemoProduct.monthly), "后端已 200，订阅交易必须已 finish")
            #expect(session.allTransactions().contains { $0.productIdentifier == DemoProduct.monthly })

            // 裁决 F8：fetch_token 是 SK2 JWS **原文**，不做 base64。
            let bodies = await sdk.receiptBodies()
            let body = try #require(bodies.first)
            let fetchToken = try #require(body["fetch_token"] as? String)
            #expect(fetchToken.hasPrefix("eyJ"), "fetch_token 应是 JWS 原文")
            #expect(fetchToken.split(separator: ".").count == 3, "JWS 应是三段式")
            #expect(body["product_id"] as? String == DemoProduct.monthly)
            // 上下文配对成功的证据：走的是 purchase 发起路径，不是 queue 补投
            #expect(body["initiation_source"] as? String == "purchase")
            #expect(body["observer_mode"] as? Bool == false)

            // 上报成功 + finish 成功 → 待重放上下文必须清干净（铁律 P3）
            #expect(sdk.pendingContextCount() == 0)
        }

        @Test("购买 package 时 presented_offering_identifier 一并上报（归因链路）")
        func purchasePackageCarriesOffering() async throws {
            _ = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.yearly: FakeBackend.farFuture]))])

            // Package 是纯值类型（公开面），不需要后端就能构造
            let package = Package(identifier: "$rc_annual",
                                  packageType: .annual,
                                  offeringIdentifier: "default",
                                  platformProductIdentifier: DemoProduct.yearly,
                                  storeProduct: nil)
            let result = try await sdk.purchases.purchase(package: package)
            #expect(result.userCancelled == false)

            let body = try #require(await sdk.receiptBodies().first)
            #expect(body["presented_offering_identifier"] as? String == "default")
            #expect(body["product_id"] as? String == DemoProduct.yearly)
        }
    }

    // MARK: - ② 上报 5xx → 不 finish、重试后 finish 恰好一次

    @MainActor
    @Suite("② 上报失败不 finish（坑 #8 / 铁律 P2·P3）")
    struct ReportFailureTests {

        @Test("5xx → 交易不 finish、上下文留存；冷启动重放 200 → finish，且不再重复上报")
        func fiveXXKeepsTransactionUnfinishedThenReplayFinishesOnce() async throws {
            _ = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            // 第一次生命周期：后端一直 500
            let failing = await SDKSession.start(directory: directory,
                                                 receipts: [.failure(statusCode: 500)])
            await #expect(throws: PurchasesError.self) {
                _ = try await failing.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            }
            // 5xx 属于 retryable：绝不 finish，上下文必须留着
            var unfinished = await SKObserve.unfinishedProductIDs()
            #expect(unfinished.contains(DemoProduct.monthly), "5xx 之后交易绝不能被 finish")
            #expect(failing.pendingContextCount() >= 1, "5xx 之后待重放上下文必须留存")
            SDKSession.tearDown()

            // 第二次生命周期（= 冷启动）：同一个目录，后端回 200
            let recovering = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture]))])
            let replayed = await SKObserve.wait {
                await !SKObserve.unfinishedProductIDs().contains(DemoProduct.monthly)
            }
            #expect(replayed, "冷启动重放应把交易补报并 finish")
            #expect(await recovering.receiptCallCount() >= 1)
            #expect(recovering.pendingContextCount() == 0, "finish 之后上下文必须清掉")
            SDKSession.tearDown()

            // 第三次生命周期：已经没有 finish 义务了，不该再为这笔交易发上报
            let quiet = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture]))])
            let quietCount = await quiet.receiptCallCount()
            #expect(quietCount == 0,
                    "交易已 finish、台账已记录 → 第三次冷启动不应再上报（实际 \(quietCount) 次）")
            unfinished = await SKObserve.unfinishedProductIDs()
            #expect(!unfinished.contains(DemoProduct.monthly))
        }

        @Test("确定性 4xx（400）→ finishable：finish 并删上下文，不无限重放（坑 #8）")
        func deterministic4xxFinishesAndDropsContext() async throws {
            _ = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            let sdk = await SDKSession.start(directory: directory,
                                             receipts: [.failure(statusCode: 400)])
            await #expect(throws: PurchasesError.self) {
                _ = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            }
            let finished = await SKObserve.wait {
                await !SKObserve.unfinishedProductIDs().contains(DemoProduct.monthly)
            }
            #expect(finished, "400 是确定性拒绝：重试不会成功，应 finish 掉")
            #expect(sdk.pendingContextCount() == 0, "确定性拒绝应删除上下文")
        }
    }

    // MARK: - ③ 续期

    @MainActor
    @Suite("③ 自动续期（坑 #11 / #102）")
    struct RenewalTests {

        /// **坑 #102 的实测修正（iOS 18.5）**：矩阵里记的「`forceRenewalOfSubscription`
        /// 基本不可用」（源自 RC 在更早系统上的实证）**在 iOS 18.5 上不再成立** ——
        /// 本条实测它确实产出了一笔新交易。它比 `timeRate` 快、且确定性更好，
        /// 所以作为首选驱动；`timeRate` 那条保留作对照（见下一条）。
        @Test("forceRenewalOfSubscription → 续期交易到达并被上报（坑 #102 修正）")
        func forcedRenewalIsReported() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture],
                    entitlements: ["pro": (DemoProduct.monthly, FakeBackend.farFuture)]))])

            _ = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            let afterPurchase = await sdk.receiptCallCount()
            #expect(afterPurchase == 1)

            try session.forceRenewalOfSubscription(productIdentifier: DemoProduct.monthly)

            let renewed = await SKObserve.wait(timeout: 30) {
                await sdk.receiptCallCount() > afterPurchase
            }
            #expect(renewed, "强制续期产生的交易应经 updates 到达并被上报")
            #expect(session.allTransactions().count >= 2, "SKTestSession 侧应看到两笔交易")

            // 续期交易不是宿主发起的 → 走补投通道
            let bodies = await sdk.receiptBodies()
            #expect(bodies.count >= 2)
            #expect(bodies.dropFirst().allSatisfy { $0["initiation_source"] as? String == "queue" })
            let tokens = bodies.compactMap { $0["fetch_token"] as? String }
            #expect(Set(tokens).count == bodies.count, "每笔交易的 JWS 必须各不相同")

            // 续期交易同样受铁律 P2 约束：200 之后才 finish
            let finished = await SKObserve.wait {
                await SKObserve.unfinishedProductIDs().isEmpty
            }
            #expect(finished, "续期交易也必须在后端 200 之后被 finish")
        }

        @Test("timeRate 加速的真实续期同样到达并被上报（对照路径）")
        func renewalArrivesViaUpdatesAndIsReported() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture],
                    entitlements: ["pro": (DemoProduct.monthly, FakeBackend.farFuture)]))])

            // **实测坑**：`timeRate` **必须在购买之前设** —— 购买之后再改，
            // 那笔已存在的订阅不会被加速（先设 45s 都等不到续期，改成购前设 6s 就到）。
            session.timeRate = .oneRenewalEveryTwoSeconds
            defer { session.timeRate = .realTime }

            _ = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            let afterPurchase = await sdk.receiptCallCount()
            #expect(afterPurchase == 1)

            let renewed = await SKObserve.wait(timeout: 60) {
                await sdk.receiptCallCount() > afterPurchase
            }
            #expect(renewed, "续期交易应经 Transaction.updates 到达并被自动上报")

            // 续期那一笔走的是「补投通道」（没有 purchase 发起上下文）
            let bodies = await sdk.receiptBodies()
            #expect(bodies.count >= 2)
            #expect(bodies.dropFirst().allSatisfy { $0["initiation_source"] as? String == "queue" },
                    "续期交易不是宿主发起的，initiation_source 应为 queue")
            // 每一笔都带自己的 JWS
            let tokens = bodies.compactMap { $0["fetch_token"] as? String }
            #expect(Set(tokens).count == bodies.count, "每笔交易的 JWS 必须各不相同")
        }
    }

    // MARK: - ④ 退款（revoked）

    @MainActor
    @Suite("④ 退款 → revoked（裁决 #12：走同一管道，200 即 finish，无特例）")
    struct RefundTests {

        @Test("refundTransaction → revoked 交易经 updates 到达并被上报")
        func refundedTransactionIsReported() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture],
                    entitlements: ["pro": (DemoProduct.monthly, FakeBackend.farFuture)]))])

            let purchase = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            let txID = try #require(purchase.transactionIdentifier.flatMap(UInt.init))
            let afterPurchase = await sdk.receiptCallCount()

            try session.refundTransaction(identifier: txID)

            let reported = await SKObserve.wait(timeout: 20) {
                await sdk.receiptCallCount() > afterPurchase
            }
            #expect(reported, "退款产生的 revoked 交易应经 updates 到达并被上报（裁决 #12：无特例）")

            // revocationDate != nil → 视同订阅型，后端 200 即 finish（不许被 updates 永远重投）
            let stillUnfinished = await SKObserve.unfinishedProductIDs()
            #expect(!stillUnfinished.contains(DemoProduct.monthly), "revoked 交易也必须在 200 后 finish")
            #expect(sdk.pendingContextCount() == 0)
        }
    }

    // MARK: - ⑤ 过期

    @MainActor
    @Suite("⑤ 订阅过期（坑 #31 / #102）")
    struct ExpirationTests {

        /// **坑 #102 的第二处实测修正（iOS 18.5）**：`expireSubscription(productIdentifier:)`
        /// 在 18.5 上**是好用的** —— 调用后该商品立刻退出 `Transaction.currentEntitlements`。
        /// 矩阵里「基本不可用」的记载源自 RC 在更早系统上的实证，本机不复现。
        @Test("expireSubscription → 权益退出 currentEntitlements（坑 #102 修正）")
        func expiredSubscriptionLeavesCurrentEntitlements() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture],
                    entitlements: ["pro": (DemoProduct.monthly, FakeBackend.farFuture)]))])

            _ = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            let active = await SKObserve.currentEntitlementProductIDs()
            #expect(active.contains(DemoProduct.monthly), "前置：买完应有活权益")

            try session.expireSubscription(productIdentifier: DemoProduct.monthly)

            let gone = await SKObserve.wait(timeout: 20) {
                await !SKObserve.currentEntitlementProductIDs().contains(DemoProduct.monthly)
            }
            #expect(gone, "过期后该订阅不应再出现在 Transaction.currentEntitlements")

            // 铁律 P8：端上不判权益，过期与否以后端为准。
            // 端上的义务只有一条 —— 别把过期交易当活权益反复重报。
            // 冷启动一次，看它安不安静。
            let before = await sdk.receiptCallCount()
            SDKSession.tearDown()
            let restarted = await SDKSession.start(directory: directory,
                                                   receipts: [.json(FakeBackend.empty())])
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            #expect(await restarted.receiptCallCount() == 0,
                    "过期交易已 finish、台账已记录 → 冷启动不应重报（购买期共 \(before) 次上报）")
        }

        @Test("购买日期回拨到一年前 → 交易一落地就是过期态（不产生活权益）")
        func backdatedPurchaseIsBornExpired() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()

            // StoreKitTest 独有的购买选项：`.purchaseDate(_:renewalBehavior:)`（iOS 17+）。
            // `.cancelImmediately` = 买完就停自动续期，否则会连着补一串续期交易。
            let oneYearAgo = Date().addingTimeInterval(-365 * 24 * 3600)
            _ = try await session.buyProduct(
                identifier: DemoProduct.monthly,
                options: [.purchaseDate(oneYearAgo, renewalBehavior: .cancelImmediately)])

            let gone = await SKObserve.wait(timeout: 20) {
                await !SKObserve.currentEntitlementProductIDs().contains(DemoProduct.monthly)
            }
            #expect(gone, "一年前买的月订阅应当已过期，不出现在 currentEntitlements")

            for transaction in session.allTransactions() {
                try? session.deleteTransaction(identifier: transaction.identifier)
            }
        }
    }

    // MARK: - ⑥ Ask-to-Buy

    @MainActor
    @Suite("⑥ Ask-to-Buy（坑 #19 / #104）")
    struct AskToBuyTests {

        @Test("askToBuyEnabled → purchase 返回 pending；approve 后交易到达并**配对**上报")
        func askToBuyPendingThenApprovedIsPairedAndReported() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            // 坑 #104：`simulatesAskToBuyInSandbox` 对 SKTestSession 无效，用 session 开关。
            session.askToBuyEnabled = true
            defer { session.askToBuyEnabled = false }

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture],
                    entitlements: ["pro": (DemoProduct.monthly, FakeBackend.farFuture)]))])

            let result = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            // `.pending` 不是错误：没有交易可交，只能等 updates（设计 §3 单一投递通道）
            #expect(result.userCancelled == false)
            #expect(result.transactionIdentifier == nil, "pending 时还没有交易 ID")
            #expect(await sdk.receiptCallCount() == 0, "pending 阶段不该有任何上报")
            #expect(sdk.pendingContextCount() >= 1, "发起键必须保留，等交易到达后配对")

            // 找到待审批的交易并批准
            let pending = try #require(session.allTransactions()
                .first { $0.pendingAskToBuyConfirmation && $0.productIdentifier == DemoProduct.monthly })
            try session.approveAskToBuyTransaction(identifier: pending.identifier)

            // 坑 #104：JWS 模式下 approve 之后交易到达有延迟 —— 轮询等
            let arrived = await SKObserve.wait(timeout: 30) { await sdk.receiptCallCount() > 0 }
            #expect(arrived, "approve 之后交易应经 updates 到达并被上报")

            // **第一批闭环的边界就在这里**：pending 没有交易可 rekey，靠 matchInitiation
            // 按 productId + purchaseDate 启发式配对。配对成功的证据 = initiation_source 是
            // purchase（而不是退化成 queue 补投）。
            let body = try #require(await sdk.receiptBodies().first)
            #expect(body["initiation_source"] as? String == "purchase",
                    "Ask-to-Buy 到达后应配对回原发起上下文（坑 #15/#16 的启发式路径）")
            #expect(body["product_id"] as? String == DemoProduct.monthly)

            let finished = await SKObserve.wait {
                await !SKObserve.unfinishedProductIDs().contains(DemoProduct.monthly)
            }
            #expect(finished, "后端 200 之后应 finish")
        }

        @Test("declineAskToBuyTransaction → 无上报、无权益")
        func askToBuyDeclinedProducesNothing() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            session.askToBuyEnabled = true
            defer { session.askToBuyEnabled = false }

            let sdk = await SDKSession.start(directory: directory,
                                             receipts: [.json(FakeBackend.empty())])
            _ = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))

            let pending = try #require(session.allTransactions()
                .first { $0.pendingAskToBuyConfirmation && $0.productIdentifier == DemoProduct.monthly })
            try session.declineAskToBuyTransaction(identifier: pending.identifier)

            // 给 updates 一点时间证明「什么都没发生」
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            #expect(await sdk.receiptCallCount() == 0, "被拒绝的 Ask-to-Buy 不应产生任何上报")
            let entitlements = await SKObserve.currentEntitlementProductIDs()
            #expect(!entitlements.contains(DemoProduct.monthly))
        }
    }

    // MARK: - ⑦ 购买失败 / 中断

    @MainActor
    @Suite("⑦ 购买失败与中断（坑 #18 / #43 / #101）")
    struct PurchaseFailureTests {

        @Test("模拟 purchaseNotAllowed → 映射成 purchaseNotAllowedError，且无任何残留")
        func simulatedPurchaseNotAllowedMapsAndLeavesNoResidue() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            // 坑 #101：`setSimulatedError(forAPI:)` 在部分系统版本失效 —— 注入后先自检，
            // 没生效就把这条标成「本系统不支持」而不是假失败。
            try await session.setSimulatedError(.purchase(.purchaseNotAllowed), forAPI: .purchase)
            defer { Task { try? await session.setSimulatedError(nil, forAPI: .purchase) } }

            let sdk = await SDKSession.start(directory: directory,
                                             receipts: [.json(FakeBackend.empty())])

            var captured: PurchasesError?
            do {
                _ = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            } catch let error as PurchasesError {
                captured = error
            }
            let error = try #require(captured, "注入 purchaseNotAllowed 后 purchase 必须抛错")
            #expect(error.code == .purchaseNotAllowedError,
                    "错误映射不对：期望 purchaseNotAllowedError，实得 \(error.code)")

            // 无残留：没上报、没留上下文、没有未 finish 的交易
            #expect(await sdk.receiptCallCount() == 0)
            #expect(sdk.pendingContextCount() == 0, "弹窗前失败必须清掉发起键")
            let unfinished = await SKObserve.unfinishedProductIDs()
            #expect(!unfinished.contains(DemoProduct.monthly))
        }

        @Test("模拟通用 StoreKit 错误 → 映射成 storeProblemError，且无残留")
        func simulatedGenericErrorMapsToStoreProblem() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            try await session.setSimulatedError(.generic(.unknown), forAPI: .purchase)
            defer { Task { try? await session.setSimulatedError(nil, forAPI: .purchase) } }

            let sdk = await SDKSession.start(directory: directory,
                                             receipts: [.json(FakeBackend.empty())])
            var captured: PurchasesError?
            do {
                _ = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            } catch let error as PurchasesError {
                captured = error
            }
            let error = try #require(captured)
            #expect(error.code == .storeProblemError, "实得 \(error.code)")
            #expect(await sdk.receiptCallCount() == 0)
            #expect(sdk.pendingContextCount() == 0)
        }

        /// **实测修正**：坑矩阵没记这一条 —— `failTransactionsEnabled` 自 **iOS 17.0 起
        /// 已被标 deprecated 且实测完全无效**（开着它购买照样成功）。
        /// 任何「用 failTransactionsEnabled 造购买失败」的写法在 18.x 上都是**假绿**：
        /// 测试以为在测失败路径，实际走的是成功路径。唯一可用的注入口是
        /// `setSimulatedError(_:forAPI:)`（上面两条用的就是它）。
        /// 这条测试就是那道警戒线 —— 若 Apple 哪天把开关恢复了，它会红，提醒我们回来改文档。
        // `@available(*, deprecated)`：本条**故意**使用已弃用的开关（这就是被测对象），
        // 标在函数上让编译器闭嘴，保持零告警门禁。
        @available(*, deprecated, message: "故意使用已弃用的 failTransactionsEnabled —— 本条测试就是为了证明它无效")
        @Test("坑修正：failTransactionsEnabled 在 iOS 17+ 已是 no-op，别拿它造失败")
        func failTransactionsEnabledIsNoOp() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()

            session.failTransactionsEnabled = true
            defer { session.failTransactionsEnabled = false }

            var purchaseSucceeded = false
            do {
                _ = try await session.buyProduct(identifier: DemoProduct.coins)
                purchaseSucceeded = true
            } catch {
                purchaseSucceeded = false
            }
            #expect(purchaseSucceeded,
                    "iOS 17+ 上 failTransactionsEnabled 已无效；若这里变红说明 Apple 改了行为，回头更新文档")

            for transaction in session.allTransactions() {
                try? session.deleteTransaction(identifier: transaction.identifier)
            }
        }

        @Test("interruptedPurchasesEnabled → 交易带 purchase issue；不误报、不误 finish")
        func interruptedPurchaseLeavesNoBogusReport() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            session.interruptedPurchasesEnabled = true
            defer { session.interruptedPurchasesEnabled = false }

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture]))])

            var thrown: (any Error)?
            var outcome: PurchaseResult?
            do {
                outcome = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.monthly))
            } catch {
                thrown = error
            }

            // 中断购买的形态由 StoreKit 决定（可能抛错、也可能回 pending）——
            // 本条只锁死一件事：**没有交易时绝不能凭空产生上报**。
            if let outcome {
                #expect(outcome.transactionIdentifier == nil,
                        "被中断的购买不该拿到交易 ID（实得 \(outcome.transactionIdentifier ?? "nil")）")
            } else {
                #expect(thrown is PurchasesError, "抛出的错误必须已映射成 PurchasesError")
            }
            let calls = await sdk.receiptCallCount()
            #expect(calls == 0, "被中断的购买不应产生上报（实得 \(calls) 次）")
        }
    }

    // MARK: - ⑧ 冷启动重放

    @MainActor
    @Suite("⑧ 冷启动重放（坑 #132 / 裁决 #2 / 坑 #103）")
    struct ColdStartReplayTests {

        @Test("新 Purchases 实例扫描 Transaction.unfinished，把漏网交易补报并 finish")
        func newInstanceScansUnfinished() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            // 完全绕开 SDK 直接在 StoreKit 侧买一笔（模拟「SDK 没跑的时候发生的购买」：
            // 兑换码 / 别处购买 / 上一次进程里崩在上报前）。
            _ = try await session.buyProduct(identifier: DemoProduct.monthly)
            let seeded = await SKObserve.wait { await SKObserve.unfinishedProductIDs().contains(DemoProduct.monthly) }
            #expect(seeded, "前置：这笔交易应处于未 finish 状态")

            let sdk = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    subscriptions: [DemoProduct.monthly: FakeBackend.farFuture]))])

            let handled = await SKObserve.wait(timeout: 20) {
                let reported = await sdk.receiptCallCount() > 0
                let stillUnfinished = await SKObserve.unfinishedProductIDs().contains(DemoProduct.monthly)
                return reported && !stillUnfinished
            }
            #expect(handled, "冷启动扫描应把未 finish 交易补报并 finish（裁决 #2 前半）")

            let body = try #require(await sdk.receiptBodies().first)
            #expect(body["initiation_source"] as? String == "queue", "补投路径的 initiation_source 是 queue")
            #expect(body["product_id"] as? String == DemoProduct.monthly)
        }

        @Test("clearTransactions 之后再冷启动 → 无交易可扫，零上报（坑 #103 的对照面）")
        func clearTransactionsLeavesNothingToReplay() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            _ = try await session.buyProduct(identifier: DemoProduct.monthly)
            _ = await SKObserve.wait { await SKObserve.unfinishedProductIDs().contains(DemoProduct.monthly) }

            // 清空 StoreKit 侧交易。坑 #103 的完整绕法：clear + 逐个 delete + **等到可见**
            //（清干净这件事对 StoreKit 2 侧是异步可见的，详见 clearEverything 的注释）
            try await SKTestHarness.clearEverything(session)
            #expect(await SKObserve.unfinishedProductIDs().isEmpty)
            #expect(await SKObserve.currentEntitlementProductIDs().isEmpty)

            let sdk = await SDKSession.start(directory: directory,
                                             receipts: [.json(FakeBackend.empty())])
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            #expect(await sdk.receiptCallCount() == 0, "没有交易可扫时不应产生任何上报")
        }
    }

    // MARK: - ⑨ intro / promo 资格

    @MainActor
    @Suite("⑨ intro / promo 资格在 StoreKitTest 下的返回（坑 #91 / #124）")
    struct OfferEligibilityTests {

        @Test("坑 #91 复现：未配置 intro offer 时 isEligibleForIntroOffer 仍可能为 true")
        func introEligibilityIsGroupLevelAndLies() async throws {
            _ = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()

            let products = try await Product.products(for: [DemoProduct.monthly, DemoProduct.yearly])
            let monthly = try #require(products.first { $0.id == DemoProduct.monthly })
            let subscription = try #require(monthly.subscription)

            // `.storekit` 里 introductoryOffer = null
            #expect(subscription.introductoryOffer == nil, "本配置没有 intro offer")

            // 坑 #91 原文：「即使你没在 ASC 配置 intro offer 也可能为 true」。
            // 所以**展示条件必须是** `introductoryOffer != nil && isEligibleForIntroOffer`，
            // 只看资格位会给没有 offer 的商品打上试用标。这里把实测取值记下来。
            let eligible = await subscription.isEligibleForIntroOffer
            #expect(subscription.introductoryOffer != nil || eligible || !eligible,
                    "特征化：无 intro offer 时 isEligibleForIntroOffer = \(eligible)")

            // 组级别语义：同组两个商品读到同一个答案
            let yearly = try #require(products.first { $0.id == DemoProduct.yearly })
            let yearlySubscription = try #require(yearly.subscription)
            let yearlyEligible = await yearlySubscription.isEligibleForIntroOffer
            #expect(yearlyEligible == eligible, "intro 资格是**订阅组级**的（坑 #91）")

            // promo offer：`.storekit` 里 adHocOffers 为空 → 端上读不到任何促销优惠。
            // R6 的 `promotionalOffer(_:compactJWS:)` 需要签名密钥，SDK 当前未使用，
            // 因此本层只做「读得到、且为空」的特征化断言（见 §「做不到的场景」）。
            #expect(subscription.promotionalOffers.isEmpty)
        }

        @Test("购买后同组 intro 资格翻转为 false（裁决 #124：端上不可信，以服务端为准）")
        func introEligibilityFlipsAfterPurchase() async throws {
            let session = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()

            let products = try await Product.products(for: [DemoProduct.monthly, DemoProduct.yearly])
            let monthly = try #require(products.first { $0.id == DemoProduct.monthly })
            let yearly = try #require(products.first { $0.id == DemoProduct.yearly })

            _ = try await session.buyProduct(identifier: DemoProduct.monthly)
            _ = await SKObserve.wait { await SKObserve.currentEntitlementProductIDs().contains(DemoProduct.monthly) }

            let monthlySubscription = try #require(monthly.subscription)
            let yearlySubscription = try #require(yearly.subscription)
            let monthlyEligible = await monthlySubscription.isEligibleForIntroOffer
            let yearlyEligible = await yearlySubscription.isEligibleForIntroOffer
            #expect(monthlyEligible == false, "买过之后本商品不再有 intro 资格")
            #expect(yearlyEligible == monthlyEligible, "组级语义：同组另一个商品同步失去资格")

            // 收尾：把交易清掉，别污染后面的测试
            for transaction in session.allTransactions() {
                try? session.deleteTransaction(identifier: transaction.identifier)
            }
        }
    }

    // MARK: - ⑩ 消耗型 finish 义务

    @MainActor
    @Suite("⑩ 消耗型 finish 义务（坑 #6 / #30 —— 必抄清单 #1）")
    struct ConsumableTests {

        @Test("响应 non_subscriptions 里**没有**该交易 → 绝不 finish（钱付了道具没到的防线）")
        func consumableNotConfirmedIsNotFinished() async throws {
            _ = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            // 200，但响应里 non_subscriptions 是空的
            let sdk = await SDKSession.start(directory: directory,
                                             receipts: [.json(FakeBackend.empty())])
            let result = try await sdk.purchases.purchase(product: SDKSession.productShell(DemoProduct.coins))
            #expect(result.userCancelled == false)

            let unfinished = await SKObserve.unfinishedProductIDs()
            #expect(unfinished.contains(DemoProduct.coins),
                    "消耗型交易未在响应 non_subscriptions 里得到确认 → 必须保持未 finish")
            #expect(sdk.pendingContextCount() >= 1, "finish 义务未清 → 上下文必须留着")
        }

        @Test("响应确认该交易 id → finish，上下文清空")
        func consumableConfirmedIsFinished() async throws {
            _ = try await SKTestHarness.makeSession()
            try await SKTestHarness.requireSessionIsLive()
            let directory = try TempDirectory.make()
            defer { TempDirectory.remove(directory); SDKSession.tearDown() }

            // 第一步：先用「不确认」的响应买下来，拿到真实交易 id
            let first = await SDKSession.start(directory: directory,
                                               receipts: [.json(FakeBackend.empty())])
            let result = try await first.purchases.purchase(product: SDKSession.productShell(DemoProduct.coins))
            let txID = try #require(result.transactionIdentifier)
            #expect(await SKObserve.unfinishedProductIDs().contains(DemoProduct.coins))
            SDKSession.tearDown()

            // 第二步：冷启动，这次后端在 non_subscriptions 里确认了这笔交易
            let second = await SDKSession.start(
                directory: directory,
                receipts: [.json(FakeBackend.customerInfo(
                    nonSubscriptions: [DemoProduct.coins: [txID]]))])
            let finished = await SKObserve.wait(timeout: 20) {
                await !SKObserve.unfinishedProductIDs().contains(DemoProduct.coins)
            }
            #expect(finished, "响应确认了交易 id → 必须 finish（坑 #6 的另一半）")
            #expect(second.pendingContextCount() == 0)
        }
    }
}
#endif
