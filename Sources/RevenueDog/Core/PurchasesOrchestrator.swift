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
    /// `.myApp` 模式的已同步台账（#10）；`.revenueDog` 模式为 nil（finish 即标记）。
    private let ledger: SyncedTransactionLedger?
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
         ledgerFileURL: URL? = nil) {
        self.configuration = configuration
        self.identity = identity
        self.httpClient = httpClient
        self.deviceCache = deviceCache
        self.pendingPurchases = pendingPurchases
        self.storeKit = storeKit
        self.poster = TransactionPoster(httpClient: httpClient,
                                        completedBy: configuration.purchasesCompletedBy)
        self.ledger = configuration.purchasesCompletedBy == .myApp
            ? (ledgerFileURL ?? (try? SyncedTransactionLedger.defaultFileURL())).map { SyncedTransactionLedger(fileURL: $0) }
            : nil
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

        // 坑矩阵裁决 #2：Apple 的启动补投只有一次 —— 挂完监听后并行跑一次
        // 未完成上下文重放 + unfinished 扫描，把两半都接住。
        Task { [weak self] in await self?.replayPendingPurchases() }
        return appUserID
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
            if configuration.purchasesCompletedBy == .myApp, let ledger {
                await ledger.record(txID)
            }
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

        // P3：上下文先落盘再发起购买（复合发起键 #15）
        let initiationKey = PendingPurchaseStore.initiationKey(productIdentifier: productIdentifier)
        let context = PendingPurchaseContext(key: initiationKey,
                                             productIdentifier: productIdentifier,
                                             appUserID: appUserID,
                                             presentedOfferingIdentifier: presentedOfferingIdentifier,
                                             presentedPackageIdentifier: presentedPackageIdentifier,
                                             initiationSource: .purchase)
        try await pendingPurchases.save(context)

        let outcome: StorePurchaseOutcome
        do {
            outcome = try await storeKit.purchase(product: product, appAccountToken: nil)
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

    /// 前台恢复时串行重放未完成购买（铁律 P3）。
    /// 两类：有 JWS 的直接补报（无交易对象 → 不 finish，等下次启动 unfinished 扫描配对后 finish）；
    /// 只有发起键的（崩溃在弹窗前后）→ 交给 unfinished 扫描配对。
    func replayPendingPurchases() async {
        let pending = await pendingPurchases.all()
        for context in pending where context.jws != nil {
            let result = await poster.post(jws: context.jws!,
                                           transaction: nil,
                                           productIdentifier: context.productIdentifier,
                                           appUserID: context.appUserID,
                                           context: context)
            switch result {
            case .success(let posted):
                // 无交易对象可 finish：上下文保留 finish 义务，交给启动 unfinished 扫描（P4）
                await deviceCache.cache(customerInfo: posted.customerInfo, appUserID: context.appUserID)
                await publish(posted.customerInfo)
                if configuration.purchasesCompletedBy == .myApp {
                    await pendingPurchases.remove(forKey: context.key)
                    await ledger?.record(context.key)
                }
            case .failure(.finishable):
                await pendingPurchases.remove(forKey: context.key)
            case .failure(.retryable):
                _ = try? await pendingPurchases.incrementReplayCount(forKey: context.key)
            }
        }
        // 启动补投只有一次（#2）：主动扫 unfinished 把漏网交易汇入统一通道
        if let storeKit {
            for transaction in await storeKit.unfinishedTransactions() {
                await handle(transaction: transaction)
            }
        }
    }
}
