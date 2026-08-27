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
         storeKit: (any StoreKitProvider)?) {
        self.configuration = configuration
        self.identity = identity
        self.httpClient = httpClient
        self.deviceCache = deviceCache
        self.pendingPurchases = pendingPurchases
        self.storeKit = storeKit
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
        return appUserID
    }

    /// M2：读 PendingPurchaseStore 补上下文 → TransactionPoster.post → shouldFinish 判定。
    private func handle(transaction: any StoreTransactionType) async {
        Log.notImplemented("PurchasesOrchestrator.handle(transaction:) tx=\(transaction.transactionIdentifier)",
                           milestone: "M2")
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

    // MARK: - M2 / M3 占位

    func purchase(package: Package) async throws -> PurchaseResult {
        throw PurchasesError.notImplemented("Purchases.purchase(package:)", milestone: "M2")
    }

    func purchase(product: StoreProduct) async throws -> PurchaseResult {
        throw PurchasesError.notImplemented("Purchases.purchase(product:)", milestone: "M2")
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

    /// 前台恢复时串行重放未完成购买（铁律 P3）。M2 填实。
    func replayPendingPurchases() async {
        let pending = await pendingPurchases.all()
        guard !pending.isEmpty else { return }
        Log.notImplemented("PurchasesOrchestrator.replayPendingPurchases()（\(pending.count) 项待重放）",
                           milestone: "M2")
    }
}
