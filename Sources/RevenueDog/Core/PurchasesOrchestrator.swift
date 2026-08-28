//
//  PurchasesOrchestrator.swift
//  全部业务编排的唯一入口（设计 §2）。actor，零自定义锁（设计 §6）。
//
//  M1 实现范围（设计 §9）：configure / 身份 / GET subscribers / offerings 展示。
//  M2 起：购买链路 P1–P8、receipts 上报、finish 语义。
//

import Foundation

actor PurchasesOrchestrator {

    let configuration: Configuration

    private let identity: IdentityManager
    private let httpClient: HTTPClient
    private let deviceCache: DeviceCache
    private let pendingPurchases: PendingPurchaseStore
    private let storeKit: (any StoreKitProvider)?
    private let poster: TransactionPoster
    private let delayScheduler: any DelayScheduler
    /// 已同步台账（#10 / #2）：`.myApp` 用它防止宿主未 finish 的重投重复上报；
    /// 两种模式都用它给 currentEntitlements 启动扫描去重（已 finish 交易每次启动都可见）。
    private let ledger: SyncedTransactionLedger?
    /// AppTransaction JWS（#36 / P7）：启动期异步获取缓存，restore（M3）上行 `app_transaction` 用。
    private(set) var appTransactionJWS: String?
    /// 内存级同交易去重（purchase() 直接结果与 updates 流可能双到）。
    private var inFlightTransactionIDs: Set<String> = []

    /// customerInfoStream 的多播出口（设计 §6 铁律 2：观察者通知一律异步派发）。
    private var customerInfoContinuations: [UUID: AsyncStream<CustomerInfo>.Continuation] = [:]
    /// 主线程侧镜像的更新回调（Purchases 门面用它同步 `cachedCustomerInfo` / delegate）。
    private var customerInfoObserver: (@Sendable (CustomerInfo) -> Void)?

    private var didStart = false

    init(configuration: Configuration,
         identity: IdentityManager,
         httpClient: HTTPClient,
         deviceCache: DeviceCache,
         pendingPurchases: PendingPurchaseStore,
         storeKit: (any StoreKitProvider)?,
         ledgerFileURL: URL? = nil,
         delayScheduler: any DelayScheduler = TaskDelayScheduler()) {
        self.configuration = configuration
        self.identity = identity
        self.httpClient = httpClient
        self.deviceCache = deviceCache
        self.pendingPurchases = pendingPurchases
        self.storeKit = storeKit
        self.delayScheduler = delayScheduler
        self.poster = TransactionPoster(httpClient: httpClient,
                                        completedBy: configuration.purchasesCompletedBy)
        self.ledger = (ledgerFileURL ?? (try? SyncedTransactionLedger.defaultFileURL()))
            .map { SyncedTransactionLedger(fileURL: $0) }
    }

    // MARK: - 生命周期

    /// 启动期初始化。
    ///
    /// **铁律 P1**：`configure()` 内同步启动 updates 监听 Task，Task 创建先于任何 await。
    /// M1 只把监听 Task 建起来（消费逻辑属于 M2），保证结构上不会退化成「登录后再挂监听」。
    func start() async throws -> String {
        guard !didStart else { return try await identity.appUserID }
        didStart = true

        // P1：先建 Task，再做任何 await。
        if let storeKit {
            Task { [weak self] in
                for await transaction in storeKit.transactionUpdates() {
                    // P5：循环体内立即派生子 Task，不阻塞流消费。
                    Task { await self?.handle(transaction: transaction) }
                }
            }
        }

        let appUserID = try await identity.bootstrap(configuredAppUserID: configuration.appUserID)
        Log.info("RevenueDog 已配置，appUserID=\(appUserID)（匿名=\(IdentityManager.isAnonymous(appUserID))）")

        // 启动重放由门面 `Purchases.start()` 在 start() 之后 await 一次（单一调用点，
        // 修复门禁核验发现的「冷启动双重重放」）；这里只做环境快照预取。
        Task { [weak self] in await self?.prefetchStoreEnvironment() }
        return appUserID
    }

    /// 启动期异步预取（全部 best-effort，失败静默）：
    /// - AppTransaction（#36 / P7）：JWS 缓存给 restore；environment 喂沙盒判定（#98）
    /// - Storefront（#123）：X-Storefront 诊断头
    private func prefetchStoreEnvironment() async {
        guard let storeKit else { return }
        if let info = await storeKit.appTransactionInfo() {
            appTransactionJWS = info.jwsRepresentation
            StoreEnvironmentCache.setAppTransactionEnvironment(info.environment)
        }
        StoreEnvironmentCache.setStorefront(await storeKit.storefrontCountryCode())
    }

    /// 单一处理通道（裁决 C2-A）：purchase() 直接结果与 updates 流都汇入这里。
    /// 幂等由三层保证：内存 in-flight 去重、.myApp 台账、服务端 content_hash。
    @discardableResult
    func handle(transaction: any StoreTransactionType) async -> CustomerInfo? {
        let txID = transaction.transactionIdentifier

        // 内存级去重：同一交易同时从 purchase() 与 updates 到达时只处理一次
        if inFlightTransactionIDs.contains(txID) { return nil }
        inFlightTransactionIDs.insert(txID)
        defer { inFlightTransactionIDs.remove(txID) }

        // .myApp 台账（#10）：已同步过且宿主没 finish 的重投直接跳过
        if configuration.purchasesCompletedBy == .myApp, let ledger,
           await ledger.contains(txID) {
            return nil
        }

        guard let jws = transaction.jwsRepresentation else {
            Log.warn("交易缺少 JWS，无法上报（tx=\(txID)）", category: "purchase")
            return nil
        }

        // 坑 #21：「成功购买」却带过去的 expirationDate = StoreKit 自身异常。埋点 warn，不阻断（P8：权益以后端为准）。
        if let expiration = transaction.expirationDate,
           transaction.revocationDate == nil, expiration < Date() {
            Log.warn("购买/投递的交易 expirationDate 已在过去（tx=\(txID)，expires=\(expiration)）——疑似 StoreKit 异常，继续上报以后端裁决为准",
                     category: "storekit")
        }

        // 上下文配对：优先 txID 键（重放），否则按商品匹配发起键（#15/#16）并 rekey + 写入 JWS
        var context = await pendingPurchases.context(forKey: txID)
        if context == nil,
           let matched = await pendingPurchases.matchInitiation(productIdentifier: transaction.productIdentifier,
                                                                purchaseDate: transaction.purchaseDate) {
            context = try? await pendingPurchases.rekey(from: matched.key, to: txID, jws: jws)
        }
        // 无上下文（续订/别处购买/补投）：也要落一份可重放的最小上下文（P3 完整性）
        if context == nil {
            let minimal = PendingPurchaseContext(key: txID,
                                                 productIdentifier: transaction.productIdentifier,
                                                 appUserID: (try? await identity.appUserID) ?? "",
                                                 initiationSource: .queue,
                                                 jws: jws)
            try? await pendingPurchases.save(minimal)
            context = minimal
        }

        let appUserID = context?.appUserID.isEmpty == false
            ? context!.appUserID
            : ((try? await identity.appUserID) ?? "")

        let result = await poster.post(jws: jws,
                                       transaction: transaction,
                                       productIdentifier: transaction.productIdentifier,
                                       appUserID: appUserID,
                                       context: context)
        switch result {
        case .success(let posted):
            if posted.finished || configuration.purchasesCompletedBy == .myApp {
                await pendingPurchases.remove(forKey: txID)
            } else {
                // 上报成功但 finish 未获准（如一次性交易未在响应确认）：保留上下文，finish 义务不丢
                _ = try? await pendingPurchases.incrementReplayCount(forKey: txID)
            }
            // 台账记录不分模式（#2）：currentEntitlements 启动扫描靠它识别「已上报过」的已 finish 交易
            await ledger?.record(txID)
            await deviceCache.cache(customerInfo: posted.customerInfo, appUserID: appUserID)
            await publish(posted.customerInfo)
            return posted.customerInfo
        case .failure(.finishable(let error)):
            // 确定性拒绝：重试无意义 —— finish（.revenueDog 模式）并删除上下文
            Log.warn("交易被后端确定性拒绝（tx=\(txID)）：\(error.description)", category: "purchase")
            if configuration.purchasesCompletedBy == .revenueDog {
                await transaction.finish()
            }
            await pendingPurchases.remove(forKey: txID)
            return nil
        case .failure(.retryable(let error)):
            // 保留上下文，前台重放兜底（P3）
            Log.warn("交易上报暂时失败，保留待重放（tx=\(txID)）：\(error.description)", category: "purchase")
            _ = try? await pendingPurchases.incrementReplayCount(forKey: txID)
            return nil
        }
    }

    // MARK: - 身份

    var appUserID: String {
        get async throws { try await identity.appUserID }
    }

    var isAnonymous: Bool {
        get async { await identity.isAnonymous }
    }

    /// logIn。`created` 来自 `GET /v1/subscribers/{id}` 的 201（契约 §2.2）。
    func logIn(_ newAppUserID: String) async throws -> (customerInfo: CustomerInfo, created: Bool) {
        let previous = try? await identity.appUserID
        guard previous != newAppUserID else {
            let info = try await customerInfo(fetchPolicy: .cachedOrFetched)
            return (info, false)
        }
        try await identity.logIn(newAppUserID)
        if let previous { await deviceCache.clearMemoryCache(appUserID: previous) }
        let response = try await fetchCustomerInfo(appUserID: newAppUserID)
        await publish(response.info)
        return (response.info, response.created)
    }

    func logOut() async throws -> CustomerInfo {
        let previous = try await identity.appUserID
        let anonymous = try await identity.logOut()
        await deviceCache.clearMemoryCache(appUserID: previous)
        let response = try await fetchCustomerInfo(appUserID: anonymous)
        await publish(response.info)
        return response.info
    }

    // MARK: - CustomerInfo

    func customerInfo(fetchPolicy: FetchPolicy) async throws -> CustomerInfo {
        let appUserID = try await identity.appUserID
        let isBackgrounded = AppStateProvider.isBackgrounded

        if fetchPolicy == .cachedOnly {
            guard let cached = await deviceCache.cachedCustomerInfo(appUserID: appUserID) else {
                throw PurchasesError(code: .customerInfoError, message: "本地无 CustomerInfo 缓存")
            }
            return cached
        }

        if fetchPolicy == .cachedOrFetched || fetchPolicy == .notStaleCachedOrFetched {
            let stale = await deviceCache.isCustomerInfoStale(appUserID: appUserID,
                                                              isAppBackgrounded: isBackgrounded)
            if !stale, let cached = await deviceCache.cachedCustomerInfo(appUserID: appUserID) {
                return cached
            }
        }

        do {
            let response = try await fetchCustomerInfo(appUserID: appUserID)
            await publish(response.info)
            return response.info
        } catch let error as PurchasesError {
            // 设计 §4：后端 5xx 时忽略 TTL 直接供给 stale 缓存。
            let isServerError = (error.httpStatusCode.map { (500...599).contains($0) } ?? false)
                || error.code == .networkError
            if isServerError, fetchPolicy != .fetchCurrent,
               let cached = await deviceCache.cachedCustomerInfo(appUserID: appUserID) {
                Log.warn("后端不可用（\(error.description)），回落 stale 缓存", category: "customer-info")
                return cached
            }
            throw error
        }
    }

    func cachedCustomerInfo() async -> CustomerInfo? {
        guard let appUserID = await identity.currentAppUserIDIfAny else { return nil }
        return await deviceCache.cachedCustomerInfo(appUserID: appUserID)
    }

    func invalidateCustomerInfoCache() async {
        guard let appUserID = await identity.currentAppUserIDIfAny else { return }
        await deviceCache.invalidateCustomerInfoCache(appUserID: appUserID)
    }

    private func fetchCustomerInfo(appUserID: String) async throws -> (info: CustomerInfo, created: Bool) {
        let response = try await httpClient.perform(.getCustomerInfo(appUserID: appUserID),
                                                    as: CustomerInfoWireModel.self)
        let info = CustomerInfo(wireModel: response.body)
        await deviceCache.cache(customerInfo: info, appUserID: appUserID)
        return (info, response.statusCode == 201)
    }

    // MARK: - Offerings

    func offerings() async throws -> Offerings {
        let appUserID = try await identity.appUserID
        let isBackgrounded = AppStateProvider.isBackgrounded

        let stale = await deviceCache.isOfferingsStale(appUserID: appUserID, isAppBackgrounded: isBackgrounded)
        if !stale, let cached = await deviceCache.cachedOfferings(appUserID: appUserID) {
            return cached
        }

        do {
            let response = try await httpClient.perform(.getOfferings(appUserID: appUserID),
                                                        as: OfferingsWireModel.self)
            // M2：这里再用 StoreKit 批量拉 platform_product_identifier 对应的商品填 storeProduct。
            let offerings = Offerings(wireModel: response.body)
            await deviceCache.cache(offerings: offerings, appUserID: appUserID)
            return offerings
        } catch {
            if let cached = await deviceCache.cachedOfferings(appUserID: appUserID) {
                Log.warn("offerings 拉取失败，回落缓存: \(error)", category: "offerings")
                return cached
            }
            throw error
        }
    }

    // MARK: - 事件多播

    func customerInfoStream() -> AsyncStream<CustomerInfo> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CustomerInfo>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        customerInfoContinuations[id] = continuation
        return stream
    }

    func setCustomerInfoObserver(_ observer: (@Sendable (CustomerInfo) -> Void)?) {
        customerInfoObserver = observer
    }

    private func removeContinuation(_ id: UUID) {
        customerInfoContinuations.removeValue(forKey: id)
    }

    /// 设计 §6 铁律 1/2：锁（actor 状态）内取出、锁外调用；观察者通知异步派发。
    private func publish(_ customerInfo: CustomerInfo) async {
        let continuations = Array(customerInfoContinuations.values)
        let observer = customerInfoObserver
        Task.detached {
            for continuation in continuations { continuation.yield(customerInfo) }
            observer?(customerInfo)
        }
    }

    // MARK: - 购买（M2，铁律 P1–P8）

    func purchase(package: Package) async throws -> PurchaseResult {
        try await purchase(productIdentifier: package.platformProductIdentifier,
                           presentedOfferingIdentifier: package.offeringIdentifier,
                           presentedPackageIdentifier: package.identifier)
    }

    func purchase(product: StoreProduct) async throws -> PurchaseResult {
        try await purchase(productIdentifier: product.productIdentifier,
                           presentedOfferingIdentifier: nil,
                           presentedPackageIdentifier: nil)
    }

    private func purchase(productIdentifier: String,
                          presentedOfferingIdentifier: String?,
                          presentedPackageIdentifier: String?) async throws -> PurchaseResult {
        guard configuration.purchasesCompletedBy == .revenueDog else {
            throw PurchasesError(code: .configurationError,
                                 message: "purchasesCompletedBy == .myApp 时购买由宿主发起，SDK 只观察")
        }
        guard let storeKit else {
            throw PurchasesError(code: .configurationError, message: "当前平台无 StoreKit 能力")
        }
        let products = try await storeKit.products(forIdentifiers: [productIdentifier])
        guard let product = products.first else {
            throw PurchasesError(code: .productNotAvailableForPurchaseError,
                                 message: "商店无此商品：\(productIdentifier)")
        }
        let appUserID = try await identity.appUserID

        // #22：服务端签发的 account_token（缓存 CustomerInfo 携带，契约决策 21）→ Apple appAccountToken。
        // 辅助归户链，best-effort：无缓存/形状不合法就不带（后端权威仍是 originalTransactionId ↔ appUserID）。
        let accountToken = await deviceCache.cachedCustomerInfo(appUserID: appUserID)?.accountToken
        let appAccountToken = accountToken.flatMap(IdentityManager.accountTokenToUUID)

        // P3：上下文先落盘再发起购买（复合发起键 #15）
        let initiationKey = PendingPurchaseStore.initiationKey(productIdentifier: productIdentifier)
        let context = PendingPurchaseContext(key: initiationKey,
                                             productIdentifier: productIdentifier,
                                             appUserID: appUserID,
                                             presentedOfferingIdentifier: presentedOfferingIdentifier,
                                             presentedPackageIdentifier: presentedPackageIdentifier,
                                             accountToken: accountToken,
                                             initiationSource: .purchase)
        try await pendingPurchases.save(context)

        let outcome: StorePurchaseOutcome
        do {
            outcome = try await storeKit.purchase(product: product, appAccountToken: appAccountToken)
        } catch {
            // 购买未发生（弹窗前失败）：清理发起键，原样抛出
            await pendingPurchases.remove(forKey: initiationKey)
            throw error
        }

        switch outcome {
        case .userCancelled:
            await pendingPurchases.remove(forKey: initiationKey)
            let info = try await customerInfo(fetchPolicy: .cachedOrFetched)
            return PurchaseResult(customerInfo: info, transactionIdentifier: nil, userCancelled: true)

        case .pending:
            // Ask-to-Buy / SCA：结果只会从 updates 流出（R3）；发起键保留供配对
            let info = try await customerInfo(fetchPolicy: .cachedOrFetched)
            return PurchaseResult(customerInfo: info, transactionIdentifier: nil, userCancelled: false)

        case .success(let transaction):
            // 单一处理通道（C2-A）：直接结果与 updates 汇入同一 handle()
            if let info = await handle(transaction: transaction) {
                return PurchaseResult(customerInfo: info,
                                      transactionIdentifier: transaction.transactionIdentifier,
                                      userCancelled: false)
            }
            // 上报暂时失败：交易未 finish、上下文已留存，重放兜底；对宿主如实报错
            throw PurchasesError(code: .networkError,
                                 message: "购买已在商店完成，上报后端暂时失败，将自动重试（tx=\(transaction.transactionIdentifier)）")
        }
    }

    func restorePurchases() async throws -> CustomerInfo {
        throw PurchasesError.notImplemented("Purchases.restorePurchases()", milestone: "M3")
    }

    func syncPurchases() async throws -> CustomerInfo {
        throw PurchasesError.notImplemented("Purchases.syncPurchases()", milestone: "M3")
    }

    func setAttributes(_ attributes: [String: String?]) async {
        Log.notImplemented("Purchases.setAttributes(_:)", milestone: "M3")
    }

    /// 启动/前台恢复时串行重放未完成购买（铁律 P3），并做启动补投扫描（裁决 #2 两半）。
    /// 两类上下文：有 JWS 的直接补报（无交易对象 → 不 finish，finish 义务由本轮 unfinished
    /// 扫描配对完成）；只有发起键的（崩溃在弹窗前后）→ 交给 unfinished 扫描配对。
    func replayPendingPurchases() async {
        // 有 finish 义务待清的交易键（.revenueDog：JWS 补报成功但无交易对象可 finish）
        var awaitingFinish: Set<String> = []

        let pending = await pendingPurchases.all()
        for context in pending where context.jws != nil {
            let result = await poster.post(jws: context.jws!,
                                           transaction: nil,
                                           productIdentifier: context.productIdentifier,
                                           appUserID: context.appUserID,
                                           context: context)
            switch result {
            case .success(let posted):
                await deviceCache.cache(customerInfo: posted.customerInfo, appUserID: context.appUserID)
                await publish(posted.customerInfo)
                if configuration.purchasesCompletedBy == .myApp {
                    await pendingPurchases.remove(forKey: context.key)
                    await ledger?.record(context.key)
                } else {
                    awaitingFinish.insert(context.key) // key 已 rekey 为 transactionId
                }
            case .failure(.finishable):
                await pendingPurchases.remove(forKey: context.key)
            case .failure(.retryable):
                _ = try? await pendingPurchases.incrementReplayCount(forKey: context.key)
            }
        }

        // 启动补投只有一次（#2 前半）：扫 unfinished 把漏网交易汇入统一通道。
        // 铁律 P4（FB13133387）：unfinished 可见性最终一致 —— 还有 finish 义务未清时
        // 轮询重读，最多 5 次 × 300ms（RC 实证参数）。#26：SK 序列一律按 purchaseDate 排序。
        if let storeKit {
            var attempt = 0
            var seen: Set<String> = []
            while true {
                attempt += 1
                let unfinished = await storeKit.unfinishedTransactions()
                    .sorted { $0.purchaseDate < $1.purchaseDate }
                for transaction in unfinished {
                    let txID = transaction.transactionIdentifier
                    if seen.contains(txID) && !awaitingFinish.contains(txID) { continue }
                    seen.insert(txID)
                    if await handle(transaction: transaction) != nil {
                        awaitingFinish.remove(txID)
                    }
                }
                if awaitingFinish.isEmpty || attempt >= 5 { break }
                try? await delayScheduler.sleep(seconds: 0.3)
            }
            if !awaitingFinish.isEmpty {
                Log.warn("unfinished 轮询 5 次后仍有 \(awaitingFinish.count) 笔 finish 义务未清，留待下次启动",
                         category: "purchase")
            }
        }

        // #2 后半：currentEntitlements 扫描 —— 已 finish 但可能从未上报成功的权益型交易
        // （别处设备购买 / 兑换码 / 历史上报失败后被宿主 finish）在 unfinished 里看不到。
        await scanCurrentEntitlements()
    }

    /// currentEntitlements 启动扫描（裁决 #2 后半）。台账去重：已上报过的不重发
    /// （已 finish 交易每次启动都在 currentEntitlements 里，无台账会变成每启动一 POST）。
    private func scanCurrentEntitlements() async {
        guard let storeKit else { return }
        let entitlements = await storeKit.currentEntitlementTransactions()
            .sorted { $0.purchaseDate < $1.purchaseDate } // #26
        for transaction in entitlements {
            let txID = transaction.transactionIdentifier
            if let ledger, await ledger.contains(txID) { continue }
            if await handle(transaction: transaction) != nil {
                await ledger?.record(txID)
            }
        }
    }
}
