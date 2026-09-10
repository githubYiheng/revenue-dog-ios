//
//  PurchasesOrchestrator.swift
//  全部业务编排的唯一入口（设计 §2）。actor，零自定义锁（设计 §6）。
//
//  M1 实现范围（设计 §9）：configure / 身份 / GET subscribers / offerings 展示。
//  M2 起：购买链路 P1–P8、receipts 上报、finish 语义。
//

import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

/// `POST /v1/subscribers/identify` 请求体（M3；服务端形状我方定义）。
private struct IdentifyBody: Encodable {
    let appUserID: String?
    let newAppUserID: String
    /// 决策 20：携带设备 install_id，服务端在四分支收敛后把 ASA 归因行重链到登入后的 customer（纯切换分支也覆盖）。
    let installID: String?

    enum CodingKeys: String, CodingKey {
        case appUserID = "app_user_id"
        case newAppUserID = "new_app_user_id"
        case installID = "install_id"
    }
}

/// 单一处理通道（`handle(transaction:source:)`）的处置结果。
///
/// 之前这里只返回 `CustomerInfo?`，于是 `purchase()` 分不清「后端暂时没确认（交易保留、会重放）」
/// 与「后端确定性拒绝（已 finish、不会再有权益）」—— 两者都退化成一个裸 `.networkError`，
/// 宿主既没法给出正确文案，也没法决定要不要给用户兜底。禁 public enum 只约束**公开面**，
/// 这是内部类型。
enum TransactionHandleOutcome: Sendable {
    /// 后端 2xx 落库成功（finish 裁决已按铁律执行）。
    case posted(CustomerInfo)
    /// 暂时性失败（5xx / 网络 / 401 / 403 / 408 / 429）：交易**未 finish**、上下文保留，
    /// 由前台重放与冷启动扫描补报。
    case pendingServerConfirmation(PurchasesError)
    /// 确定性拒绝（除 401/403/404/408/429 外的 4xx）：`.revenueDog` 下已 finish，重试无意义。
    case rejectedByServer(PurchasesError)
    /// 本次没有走上报：内存去重命中 / 交易缺 JWS / 观察者台账已记。
    case skipped

    var customerInfo: CustomerInfo? {
        guard case .posted(let info) = self else { return nil }
        return info
    }
}

actor PurchasesOrchestrator {

    let configuration: Configuration
    /// 运行时可写设置（M-2a `purchasesCompletedBy` / M-4 购买结果钩子）。
    /// `configuration.purchasesCompletedBy` 只是**初始值**，运行期一律读这里。
    let settings: RuntimeSettings

    private let identity: IdentityManager
    private let httpClient: HTTPClient
    private let deviceCache: DeviceCache
    private let pendingPurchases: PendingPurchaseStore
    private let storeKit: (any StoreKitProvider)?
    private let poster: TransactionPoster
    private let delayScheduler: any DelayScheduler
    /// 属性本地缓冲（设计 §1「属性与归因」；坑 #51 一属性一文件）。
    private let attributesStore: SubscriberAttributesStore
    /// ASA 归因端状态（install_id 幂等键 + 已采集标记，裁决 D2）。
    private let attributionState: any AttributionStateStorage
    /// AdServices token 取值面（协议隔离，坑 #83/#84）。
    private let adServicesTokenProvider: any AdServicesTokenProvider
    /// 客户端诊断（ADR 0028 / sdk-diagnostics §1.3 的记录点大半在本文件）。
    private let diagnostics: DiagnosticsRecorder
    /// 属性同步的单飞闸：同时只允许一次 POST /attributes 在途，避免前后台抖动打出重复请求。
    private var isSyncingAttributes = false
    /// ASA 采集在本进程内只启动一次（跨进程的一次性由 `attributionState` 持久化保证）。
    private var didStartAdServicesCollection = false
    /// 已同步台账（#10 / #2）：`.myApp` 用它防止宿主未 finish 的重投重复上报；
    /// 两种模式都用它给 currentEntitlements 启动扫描去重（已 finish 交易每次启动都可见）。
    private let ledger: SyncedTransactionLedger?
    /// AppTransaction JWS（#36 / P7）：启动期异步获取缓存，restore（M3）上行 `app_transaction` 用。
    private(set) var appTransactionJWS: String?
    /// 内存级同交易去重（purchase() 直接结果与 updates 流可能双到）。
    private var inFlightTransactionIDs: Set<String> = []
    /// M-2b 前台重扫的单飞闸（前后台抖动不叠加扫描）。
    private var isForegroundRescanning = false

    /// customerInfoStream 的多播出口（设计 §6 铁律 2：观察者通知一律异步派发）。
    private var customerInfoContinuations: [UUID: AsyncStream<CustomerInfo>.Continuation] = [:]
    /// 主线程侧镜像的更新回调（Purchases 门面用它同步 `cachedCustomerInfo` / delegate）。
    private var customerInfoObserver: (@Sendable (CustomerInfo) -> Void)?

    private var didStart = false

    init(configuration: Configuration,
         settings: RuntimeSettings,
         identity: IdentityManager,
         httpClient: HTTPClient,
         deviceCache: DeviceCache,
         pendingPurchases: PendingPurchaseStore,
         storeKit: (any StoreKitProvider)?,
         ledgerFileURL: URL? = nil,
         delayScheduler: any DelayScheduler = TaskDelayScheduler(),
         attributesDirectory: URL,
         attributionState: any AttributionStateStorage = UserDefaultsAttributionStateStorage(),
         adServicesTokenProvider: any AdServicesTokenProvider = SystemAdServicesTokenProvider(),
         diagnostics: DiagnosticsRecorder) {
        self.configuration = configuration
        self.settings = settings
        self.identity = identity
        self.httpClient = httpClient
        self.deviceCache = deviceCache
        self.pendingPurchases = pendingPurchases
        self.storeKit = storeKit
        self.delayScheduler = delayScheduler
        self.attributesStore = SubscriberAttributesStore(directory: attributesDirectory)
        self.attributionState = attributionState
        self.adServicesTokenProvider = adServicesTokenProvider
        self.diagnostics = diagnostics
        self.poster = TransactionPoster(httpClient: httpClient, diagnostics: diagnostics)
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
                    Task { await self?.handle(transaction: transaction, source: .updates) }
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
    func handle(transaction: any StoreTransactionType,
                source: DiagnosticsTransactionSource = .updates) async -> TransactionHandleOutcome {
        let txID = transaction.transactionIdentifier

        // 诊断（契约 §1.3）：单一处理通道的入口是「端上看见了这笔交易」的唯一时刻。
        await diagnostics.record(DiagnosticsEventType.transactionObserved, fields: [
            "source": .string(source.rawValue),
            "transaction_id": .string(txID),
            "original_transaction_id": .string(transaction.originalTransactionIdentifier),
            "product_id": .string(transaction.productIdentifier),
            "environment": StoreEnvironmentCache.appTransactionEnvironment.map { .string($0) },
        ])

        // 内存级去重：同一交易同时从 purchase() 与 updates 到达时只处理一次
        if inFlightTransactionIDs.contains(txID) { return .skipped }
        inFlightTransactionIDs.insert(txID)
        defer { inFlightTransactionIDs.remove(txID) }

        // M-2a（迁移方案 v2.1 §5）：**进行中的购买沿用发起时的模式**做 finish 决策 ——
        // 发起时已把模式快照进 `PendingPurchaseContext`；没有快照的（updates 补投 / 续订 /
        // 别处购买 / 老版本上下文）用当前运行时值，即「切换立即对新交易生效」。
        var context = await pendingPurchases.context(forKey: txID)
        let completedBy = context?.completedBy ?? settings.purchasesCompletedBy

        // .myApp 台账（#10）：已同步过且宿主没 finish 的重投直接跳过
        if completedBy == .myApp, let ledger,
           await ledger.contains(txID) {
            return .skipped
        }

        guard let jws = transaction.jwsRepresentation else {
            Log.warn("交易缺少 JWS，无法上报（tx=\(txID)）", category: "purchase")
            await diagnostics.warn(DiagnosticsWarningCode.missingJWS, detail: "tx=\(txID)")
            return .skipped
        }

        // 坑 #21：「成功购买」却带过去的 expirationDate = StoreKit 自身异常。埋点 warn，不阻断（P8：权益以后端为准）。
        if let expiration = transaction.expirationDate,
           transaction.revocationDate == nil, expiration < Date() {
            Log.warn("购买/投递的交易 expirationDate 已在过去（tx=\(txID)，expires=\(expiration)）——疑似 StoreKit 异常，继续上报以后端裁决为准",
                     category: "storekit")
            await diagnostics.warn(DiagnosticsWarningCode.expiredOnArrival, detail: "tx=\(txID)")
        }

        // 上下文配对：txID 键（重放）已在上面读过；没读到就按商品匹配发起键（#15/#16）并 rekey + 写入 JWS
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
                                                 jws: jws,
                                                 completedBy: completedBy) // M-2a：重放沿用同一模式
            try? await pendingPurchases.save(minimal)
            context = minimal
        }

        let appUserID = context?.appUserID.isEmpty == false
            ? context!.appUserID
            : ((try? await identity.appUserID) ?? "")

        // 设计 §5「属性同步时机：前后台切换 + 购买时」：待同步属性随收据搭车（省一次请求）
        let pendingAttributes = await attributesStore.unsynced(appUserID: appUserID)
        let result = await poster.post(jws: jws,
                                       transaction: transaction,
                                       productIdentifier: transaction.productIdentifier,
                                       appUserID: appUserID,
                                       context: context,
                                       completedBy: completedBy,
                                       attributes: pendingAttributes)
        switch result {
        case .success(let posted):
            await attributesStore.markSynced(pendingAttributes, appUserID: appUserID)
            if posted.finished || completedBy == .myApp {
                await pendingPurchases.remove(forKey: txID)
            } else {
                // 上报成功但 finish 未获准（如一次性交易未在响应确认）：保留上下文，finish 义务不丢
                _ = try? await pendingPurchases.incrementReplayCount(forKey: txID)
            }
            // 台账记录不分模式（#2）：currentEntitlements 启动扫描靠它识别「已上报过」的已 finish 交易
            await ledger?.record(txID)
            await deviceCache.cache(customerInfo: posted.customerInfo, appUserID: appUserID)
            await publish(posted.customerInfo, source: .purchase)
            return .posted(posted.customerInfo)
        case .failure(.finishable(let error)):
            // 确定性拒绝：重试无意义 —— finish（.revenueDog 模式）并删除上下文
            Log.warn("交易被后端确定性拒绝（tx=\(txID)）：\(error.description)", category: "purchase")
            if completedBy == .revenueDog {
                await transaction.finish()
            }
            await pendingPurchases.remove(forKey: txID)
            return .rejectedByServer(error)
        case .failure(.retryable(let error)):
            // 保留上下文，前台重放兜底（P3）
            Log.warn("交易上报暂时失败，保留待重放（tx=\(txID)）：\(error.description)", category: "purchase")
            _ = try? await pendingPurchases.incrementReplayCount(forKey: txID)
            return .pendingServerConfirmation(error)
        }
    }

    // MARK: - 身份

    var appUserID: String {
        get async throws { try await identity.appUserID }
    }

    var isAnonymous: Bool {
        get async { await identity.isAnonymous }
    }

    /// logIn（M3：对接服务端 identify 合并端点，四分支矩阵在服务端裁决）。
    /// 顺序：先服务端合并成功、再切本地身份 —— 服务端失败时本地身份不动。
    func logIn(_ newAppUserID: String) async throws -> (customerInfo: CustomerInfo, created: Bool) {
        let previous = try? await identity.appUserID
        guard previous != newAppUserID else {
            let info = try await customerInfo(fetchPolicy: .cachedOrFetched)
            return (info, false)
        }
        // 坑 #52 前半：logIn 前先把旧身份的属性刷出去，保证旧用户的属性不丢。
        await syncAttributesIfNeeded()
        let installID = await attributionState.installID()
        let body = try JSONEncoder().encode(IdentifyBody(appUserID: previous, newAppUserID: newAppUserID, installID: installID))
        let fromAnonymous = previous.map { IdentityManager.isAnonymous($0) } ?? true
        let startedAt = Date()
        let trace = HTTPCallTrace()
        let response: HTTPResponse<CustomerInfoWireModel>
        do {
            response = try await httpClient.perform(.postIdentify, body: body,
                                                    as: CustomerInfoWireModel.self, trace: trace)
        } catch {
            await recordIdentityEvent(DiagnosticsEventType.identityLogin,
                                      trace: trace, startedAt: startedAt,
                                      extra: ["from_anonymous": .bool(fromAnonymous)],
                                      error: error)
            throw error
        }
        try await identity.logIn(newAppUserID)
        if let previous { await deviceCache.clearMemoryCache(appUserID: previous) }
        let info = CustomerInfo(wireModel: response.body)
        await deviceCache.cache(customerInfo: info, appUserID: newAppUserID)
        // 坑 #52 后半：**只有旧身份是匿名**时才把属性迁到新身份（两个真实用户之间不迁移），
        // 迁移后立刻同步一次（合并后同步时机，任务书 M3 属性项）。
        if let previous {
            await attributesStore.migrateIfOldIsAnonymous(from: previous, to: newAppUserID)
        }
        await syncAttributesIfNeeded()
        await publish(info, source: .login, requestID: trace.last?.requestID)
        await recordIdentityEvent(DiagnosticsEventType.identityLogin,
                                  trace: trace, startedAt: startedAt,
                                  extra: ["from_anonymous": .bool(fromAnonymous),
                                          "created": .bool(response.statusCode == 201)],
                                  error: nil)
        return (info, response.statusCode == 201)
    }

    func logOut() async throws -> CustomerInfo {
        let startedAt = Date()
        let trace = HTTPCallTrace()
        do {
            let previous = try await identity.appUserID
            let anonymous = try await identity.logOut()
            await deviceCache.clearMemoryCache(appUserID: previous)
            let response = try await fetchCustomerInfo(appUserID: anonymous, trace: trace)
            await publish(response.info, source: .fetch, requestID: trace.last?.requestID)
            await recordIdentityEvent(DiagnosticsEventType.identityLogout,
                                      trace: trace, startedAt: startedAt, extra: [:], error: nil)
            return response.info
        } catch {
            await recordIdentityEvent(DiagnosticsEventType.identityLogout,
                                      trace: trace, startedAt: startedAt, extra: [:], error: error)
            throw error
        }
    }

    /// `identity_login` / `identity_logout` 的统一出口（契约 §1.3）。
    private func recordIdentityEvent(_ type: String,
                                     trace: HTTPCallTrace,
                                     startedAt: Date,
                                     extra: [String: DiagnosticsFieldValue],
                                     error: (any Error)?) async {
        var fields: [String: DiagnosticsFieldValue?] = [
            "status": trace.last?.statusCode.map { .int($0) },
            "request_id": trace.last?.requestID.map { .string($0) },
            "duration_ms": .int(Self.elapsedMs(since: startedAt)),
            "error_code": Self.diagnosticsErrorCode(error),
        ]
        for (key, value) in extra { fields[key] = value }
        await diagnostics.record(type,
                                 level: error == nil ? DiagnosticsLevel.info : DiagnosticsLevel.error,
                                 fields: fields)
    }

    /// SDK 自己的错误码名（**绝不带 message**，契约 §1.3 末段）。
    static func diagnosticsErrorCode(_ error: (any Error)?) -> DiagnosticsFieldValue? {
        guard let error else { return nil }
        if let purchases = error as? PurchasesError { return .string(purchases.code.name) }
        return .string(PurchasesErrorCode.unknownError.name)
    }

    static func elapsedMs(since startedAt: Date) -> Int {
        Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
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

        // 走到这里 = 缓存没命中（或策略要求拉网），契约 §1.3 的 `customer_info_fetch` 记录点。
        let startedAt = Date()
        let trace = HTTPCallTrace()
        do {
            let response = try await fetchCustomerInfo(appUserID: appUserID, trace: trace)
            await publish(response.info, source: .fetch, requestID: trace.last?.requestID)
            await recordCustomerInfoFetch(policy: fetchPolicy, cacheHit: false,
                                          trace: trace, startedAt: startedAt, error: nil)
            return response.info
        } catch let error as PurchasesError {
            // 设计 §4：后端 5xx 时忽略 TTL 直接供给 stale 缓存。
            let isServerError = (error.httpStatusCode.map { (500...599).contains($0) } ?? false)
                || error.code == .networkError
            if isServerError, fetchPolicy != .fetchCurrent,
               let cached = await deviceCache.cachedCustomerInfo(appUserID: appUserID) {
                Log.warn("后端不可用（\(error.description)），回落 stale 缓存", category: "customer-info")
                await diagnostics.warn(DiagnosticsWarningCode.staleCustomerInfoFallback,
                                       detail: "policy=\(fetchPolicy.rawValue)")
                await recordCustomerInfoFetch(policy: fetchPolicy, cacheHit: true,
                                              trace: trace, startedAt: startedAt, error: error)
                return cached
            }
            await recordCustomerInfoFetch(policy: fetchPolicy, cacheHit: false,
                                          trace: trace, startedAt: startedAt, error: error)
            throw error
        }
    }

    private func recordCustomerInfoFetch(policy: FetchPolicy,
                                         cacheHit: Bool,
                                         trace: HTTPCallTrace,
                                         startedAt: Date,
                                         error: (any Error)?) async {
        await diagnostics.record(DiagnosticsEventType.customerInfoFetch,
                                 level: error == nil ? DiagnosticsLevel.info : DiagnosticsLevel.error,
                                 fields: [
                                     "policy": .string(policy.rawValue),
                                     "cache_hit": .bool(cacheHit),
                                     "status": trace.last?.statusCode.map { .int($0) },
                                     "request_id": trace.last?.requestID.map { .string($0) },
                                     "duration_ms": .int(Self.elapsedMs(since: startedAt)),
                                     "error_code": Self.diagnosticsErrorCode(error),
                                 ])
    }

    func cachedCustomerInfo() async -> CustomerInfo? {
        guard let appUserID = await identity.currentAppUserIDIfAny else { return nil }
        return await deviceCache.cachedCustomerInfo(appUserID: appUserID)
    }

    private func fetchCustomerInfo(appUserID: String,
                                   trace: HTTPCallTrace? = nil) async throws -> (info: CustomerInfo, created: Bool) {
        let response = try await httpClient.perform(.getCustomerInfo(appUserID: appUserID),
                                                    as: CustomerInfoWireModel.self, trace: trace)
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
            // 缓存里**不存** storeProduct（价格/文案是商店的当下事实，不该被我们冻在磁盘上），
            // 读取时现补一次。
            return await resolveStoreProducts(in: cached).offerings
        }

        let startedAt = Date()
        let trace = HTTPCallTrace()
        do {
            let response = try await httpClient.perform(.getOfferings(appUserID: appUserID),
                                                        as: OfferingsWireModel.self, trace: trace)
            let offerings = Offerings(wireModel: response.body)
            // 缓存的是**后端下发的那份**（不含 storeProduct），读取时再补。
            await deviceCache.cache(offerings: offerings, appUserID: appUserID)
            let resolved = await resolveStoreProducts(in: offerings)
            await recordOfferingsFetch(count: offerings.all.count,
                                       notFoundProductIDs: resolved.notFoundProductIDs,
                                       trace: trace, startedAt: startedAt, error: nil)
            return resolved.offerings
        } catch {
            if let cached = await deviceCache.cachedOfferings(appUserID: appUserID) {
                Log.warn("offerings 拉取失败，回落缓存: \(error)", category: "offerings")
                await diagnostics.warn(DiagnosticsWarningCode.offeringsCacheFallback)
                await recordOfferingsFetch(count: cached.all.count, notFoundProductIDs: nil,
                                           trace: trace, startedAt: startedAt, error: error)
                return await resolveStoreProducts(in: cached).offerings
            }
            await recordOfferingsFetch(count: nil, notFoundProductIDs: nil,
                                       trace: trace, startedAt: startedAt, error: error)
            throw error
        }
    }

    private func recordOfferingsFetch(count: Int?,
                                      notFoundProductIDs: [String]?,
                                      trace: HTTPCallTrace,
                                      startedAt: Date,
                                      error: (any Error)?) async {
        await diagnostics.record(DiagnosticsEventType.offeringsFetch,
                                 level: error == nil ? DiagnosticsLevel.info : DiagnosticsLevel.error,
                                 fields: [
                                     "status": trace.last?.statusCode.map { .int($0) },
                                     "request_id": trace.last?.requestID.map { .string($0) },
                                     "count": count.map { .int($0) },
                                     "not_found_product_ids": notFoundProductIDs.flatMap {
                                         $0.isEmpty ? nil : .strings(Array($0.prefix(50)))
                                     },
                                     "duration_ms": .int(Self.elapsedMs(since: startedAt)),
                                     "error_code": Self.diagnosticsErrorCode(error),
                                 ])
    }

    /// 用 StoreKit **一次批量**拉齐 offerings 里全部 `platform_product_identifier`，
    /// 填 `Package.storeProduct`，顺带算出「后端配了但商店查不到」的商品 id。
    ///
    /// 两件事共用同一次 `Product.products(for:)`：
    /// - `Package.storeProduct`（宿主做定价文案的唯一来源）；
    /// - §6-4 诊断字段 `offerings_fetch.not_found_product_ids` —— 接线期最常见的一类事故
    ///   （ASC 里没建、没过审、地区不售），端上不查就只能靠用户报「买不了」。
    ///
    /// best-effort：查不动（无 StoreKit / 抛错）就原样返回，`notFoundProductIDs` 为 nil ——
    /// 商品详情缺失绝不能让 offerings 本身失败。
    private func resolveStoreProducts(
        in offerings: Offerings,
    ) async -> (offerings: Offerings, notFoundProductIDs: [String]?) {
        guard let storeKit else { return (offerings, nil) }
        let wanted = Set(offerings.all.values.flatMap { $0.availablePackages.map(\.platformProductIdentifier) })
        guard !wanted.isEmpty else { return (offerings, []) }
        guard let found = try? await storeKit.products(forIdentifiers: wanted) else { return (offerings, nil) }

        var products: [String: StoreProduct] = [:]
        for product in found {
            products[product.productIdentifier] = await product.makeStoreProduct()
        }
        let notFound = wanted.subtracting(products.keys).sorted()
        return (offerings.fillingStoreProducts(from: products), notFound)
    }

    // MARK: - 事件多播

    /// M3 完整语义：订阅即回放最近一次已知值（RC customerInfoStream 同款），后续去重推送。
    func customerInfoStream() -> AsyncStream<CustomerInfo> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CustomerInfo>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        customerInfoContinuations[id] = continuation
        // 立即回放：优先最近一次 publish 的值，冷启动回落磁盘缓存
        Task { [weak self] in
            if let current = await self?.currentKnownCustomerInfo() {
                continuation.yield(current)
            }
        }
        return stream
    }

    private func currentKnownCustomerInfo() async -> CustomerInfo? {
        if let lastPublished { return lastPublished }
        return await cachedCustomerInfo()
    }

    func setCustomerInfoObserver(_ observer: (@Sendable (CustomerInfo) -> Void)?) {
        customerInfoObserver = observer
    }

    private func removeContinuation(_ id: UUID) {
        customerInfoContinuations.removeValue(forKey: id)
    }

    /// 最近一次 publish 的值（stream 订阅回放 + 去重基准）。
    private var lastPublished: CustomerInfo?

    /// 设计 §6 铁律 1/2：锁（actor 状态）内取出、锁外调用；观察者通知异步派发。
    /// M3：连续相同值去重（stream 消费者不吃重复帧）。
    ///
    /// §6-4：这里是 CustomerInfo **真正发生变化**的唯一收口，`customer_info_updated` 记在这
    /// —— 「权益是什么时候变的、由哪条路带来的」是排查权益争议的主线。
    private func publish(_ customerInfo: CustomerInfo,
                         source: DiagnosticsCustomerInfoSource,
                         requestID: String? = nil) async {
        guard customerInfo != lastPublished else { return }
        lastPublished = customerInfo
        await diagnostics.record(DiagnosticsEventType.customerInfoUpdated, fields: [
            "source": .string(source.rawValue),
            // 只上权益 id（我方配置里的标识），不带到期时间之外的任何用户信息。
            "active_entitlement_ids": .strings(Array(customerInfo.entitlements.active.keys.sorted().prefix(50))),
            "request_id": requestID.map { .string($0) },
        ])
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
        // M-2a：**动态读**运行时值（热切立即生效，对齐 RC `purchasesAreCompletedBy` 的做法，
        // verify/rc-sdk-observer-mode.md §8.1 判断 6）。读一次并贯穿本次购买 ——
        // 这一读就是「发起时快照」的取值点。
        let completedBy = settings.purchasesCompletedBy
        // 诊断（契约 §1.3）：`purchase()` 进入。initiation_key 在下面才算得出来，
        // 但「进入」这个事实必须在任何一次 throw 之前落下 —— 否则「用户点了买、然后什么都没发生」
        // 这种最常见的报障在事件流里根本看不见。
        let purchaseStartedAt = Date()
        let initiationKey = PendingPurchaseStore.initiationKey(productIdentifier: productIdentifier)
        await diagnostics.record(DiagnosticsEventType.purchaseStarted, fields: [
            "product_id": .string(productIdentifier),
            "package_id": presentedPackageIdentifier.map { .string($0) },
            "initiation_key": .string(initiationKey),
        ])

        do {
            guard completedBy == .revenueDog else {
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
        let context = PendingPurchaseContext(key: initiationKey,
                                             productIdentifier: productIdentifier,
                                             appUserID: appUserID,
                                             presentedOfferingIdentifier: presentedOfferingIdentifier,
                                             presentedPackageIdentifier: presentedPackageIdentifier,
                                             accountToken: accountToken,
                                             initiationSource: .purchase,
                                             completedBy: completedBy) // M-2a：发起时模式快照
        try await pendingPurchases.save(context)

        let outcome: StorePurchaseOutcome
        do {
            // M-4：把购买结果钩子交给 StoreKit 层 —— `Product.purchase()` 一返回就同步回调，
            // 早于上报、早于 finish（迁移方案 v2.1 §5 M-4；档 2 宿主转交 RC `recordPurchase`）。
            outcome = try await storeKit.purchase(product: product,
                                                  appAccountToken: appAccountToken,
                                                  onPurchaseResult: { [settings] raw in
                                                      settings.dispatchPurchaseResult(raw)
                                                  })
        } catch {
            // 购买未发生（弹窗前失败）：清理发起键，原样抛出
            await pendingPurchases.remove(forKey: initiationKey)
            throw error
        }

        switch outcome {
        case .userCancelled:
            await pendingPurchases.remove(forKey: initiationKey)
            let info = try await customerInfo(fetchPolicy: .cachedOrFetched)
            await recordPurchaseResult(productIdentifier: productIdentifier,
                                       outcome: DiagnosticsPurchaseOutcome.cancelled,
                                       transactionID: nil, startedAt: purchaseStartedAt, error: nil)
            return PurchaseResult(customerInfo: info, transactionIdentifier: nil, userCancelled: true)

        case .pending:
            // Ask-to-Buy / SCA：结果只会从 updates 流出（R3）；发起键保留供配对
            let info = try await customerInfo(fetchPolicy: .cachedOrFetched)
            await recordPurchaseResult(productIdentifier: productIdentifier,
                                       outcome: DiagnosticsPurchaseOutcome.pending,
                                       transactionID: nil, startedAt: purchaseStartedAt, error: nil)
            // B：显式 pending 标志 —— 宿主此刻既不该发权益、也不该报错。
            return PurchaseResult(customerInfo: info, transactionIdentifier: nil,
                                  userCancelled: false, isPending: true)

        case .success(let transaction):
            // 坑 **#15**（同 productID **并发**购买配对张冠李戴）：交易 id 一到手就立刻把
            // **本次**的发起键 rekey 成 transactionId —— 这是端上唯一确知「哪笔上下文属于哪笔交易」
            // 的时刻。之后无论走 purchase 直接结果还是 updates 双路投递，handle() 的
            // `context(forKey: txID)` 都会精确命中，不再退化到「按 productId 取最早一条」的启发式
            // （那条启发式在同商品并发时会把 A 的归因发给 B）。
            // 残余边界：`.pending`（Ask-to-Buy/SCA）没有交易可 rekey，仍靠 matchInitiation 启发式。
            _ = try? await pendingPurchases.rekey(from: initiationKey,
                                                  to: transaction.transactionIdentifier,
                                                  jws: transaction.jwsRepresentation)
            // 单一处理通道（C2-A）：直接结果与 updates 汇入同一 handle()
            let outcome = await handle(transaction: transaction, source: .purchase)
            if let info = outcome.customerInfo {
                await recordPurchaseResult(productIdentifier: productIdentifier,
                                           outcome: DiagnosticsPurchaseOutcome.success,
                                           transactionID: transaction.transactionIdentifier,
                                           startedAt: purchaseStartedAt, error: nil)
                return PurchaseResult(customerInfo: info,
                                      transactionIdentifier: transaction.transactionIdentifier,
                                      userCancelled: false,
                                      isPending: false)
            }
            // C：**钱已经扣了**，上报没成 —— 两种后果完全不同，必须给宿主两个码位，
            // 不再共用一个裸 `.networkError`（宿主拿它没法决定给不给用户兜底）。
            let postFailure = Self.postFailureError(outcome, transactionID: transaction.transactionIdentifier)
            await recordPurchaseResult(productIdentifier: productIdentifier,
                                       outcome: DiagnosticsPurchaseOutcome.error,
                                       transactionID: transaction.transactionIdentifier,
                                       startedAt: purchaseStartedAt, error: postFailure)
            throw postFailure
        }
        } catch {
            // `purchase()` 抛出（含商品不存在 / 弹窗前失败 / StoreKit 取消）：一律留一条 error 级事件。
            await recordPurchaseResult(productIdentifier: productIdentifier,
                                       outcome: Self.isUserCancelledOutcome(error)
                                           ? DiagnosticsPurchaseOutcome.cancelled
                                           : DiagnosticsPurchaseOutcome.error,
                                       transactionID: nil, startedAt: purchaseStartedAt, error: error)
            throw error
        }
    }

    /// 扣款之后上报失败的两个码位（C）。文案用中性英文 —— 这两条会被宿主直接
    /// 拿去做用户可见提示，SDK 内部日志才是中文。
    ///
    /// - `.purchasePendingServerConfirmation`：交易**未 finish**、上下文已留存，
    ///   SDK 会在前台/下次冷启动自动重放。宿主应提示「稍后到账」，**不要**重复扣款。
    /// - `.purchaseRejectedByServer`：服务端确定性拒绝，交易已 finish，不会再有权益。
    ///   `underlyingError` 带后端错误体码（`PurchasesError.backendCode`）。
    static func postFailureError(_ outcome: TransactionHandleOutcome,
                                 transactionID: String) -> PurchasesError {
        switch outcome {
        case .posted:
            // 调用方已在上面处理；留一条兜底，语义与 `.skipped` 相同。
            return PurchasesError(code: .purchasePendingServerConfirmation,
                                  message: "The purchase completed in the App Store but the server "
                                      + "confirmation is not available yet (transaction \(transactionID)).")
        case .rejectedByServer(let error):
            return PurchasesError(code: .purchaseRejectedByServer,
                                  message: "The purchase completed in the App Store but the server "
                                      + "rejected the receipt; no entitlement will be granted "
                                      + "(transaction \(transactionID)).",
                                  backendCode: error.backendCode,
                                  httpStatusCode: error.httpStatusCode,
                                  underlyingError: error)
        case .pendingServerConfirmation(let error):
            return PurchasesError(code: .purchasePendingServerConfirmation,
                                  message: "The purchase completed in the App Store but could not be "
                                      + "confirmed by the server yet; the transaction is retained and "
                                      + "will be retried automatically (transaction \(transactionID)).",
                                  backendCode: error.backendCode,
                                  httpStatusCode: error.httpStatusCode,
                                  underlyingError: error)
        case .skipped:
            return PurchasesError(code: .purchasePendingServerConfirmation,
                                  message: "The purchase completed in the App Store but has not been "
                                      + "confirmed by the server yet; the transaction is retained and "
                                      + "will be retried automatically (transaction \(transactionID)).")
        }
    }

    /// `purchase_result`（契约 §1.3）。取消不算错误 → info 级。
    private func recordPurchaseResult(productIdentifier: String,
                                      outcome: String,
                                      transactionID: String?,
                                      startedAt: Date,
                                      error: (any Error)?) async {
        let isError = outcome == DiagnosticsPurchaseOutcome.error
        await diagnostics.record(DiagnosticsEventType.purchaseResult,
                                 level: isError ? DiagnosticsLevel.error : DiagnosticsLevel.info,
                                 fields: [
                                     "product_id": .string(productIdentifier),
                                     "outcome": .string(outcome),
                                     "transaction_id": transactionID.map { .string($0) },
                                     "error_code": Self.diagnosticsErrorCode(error),
                                     "duration_ms": .int(Self.elapsedMs(since: startedAt)),
                                 ])
    }

    /// 坑 #18：`StoreKitError.userCancelled` 这种 throw 形态的取消没有 `PurchaseResult` 可交。
    static func isUserCancelledOutcome(_ error: any Error) -> Bool {
        #if canImport(StoreKit)
        if let skError = error as? StoreKitError, case .userCancelled = skError { return true }
        #endif
        return (error as? PurchasesError)?.code == .purchaseCancelledError
    }

    /// restore（用户显式动作，会弹 Apple ID 框）。契约 C（裁决 C2-C）：
    /// 端上只传「最新一笔交易 JWS + AppTransaction」，全量历史由后端凭锚点回填。
    func restorePurchases() async throws -> CustomerInfo {
        try await syncInternal(userInitiated: true)
    }

    /// 静默同步（不弹框），语义同 restore。
    func syncPurchases() async throws -> CustomerInfo {
        try await syncInternal(userInitiated: false)
    }

    private func syncInternal(userInitiated: Bool) async throws -> CustomerInfo {
        let type = userInitiated ? DiagnosticsEventType.restore : DiagnosticsEventType.sync
        let startedAt = Date()
        let trace = HTTPCallTrace()
        do {
            return try await syncInternalBody(userInitiated: userInitiated, trace: trace) { count in
                await self.recordSyncEvent(type, count: count, trace: trace,
                                           startedAt: startedAt, error: nil)
            }
        } catch {
            await recordSyncEvent(type, count: nil, trace: trace, startedAt: startedAt, error: error)
            throw error
        }
    }

    /// `restore` / `sync`（契约 §1.3）。`count` = 端上找到的可上报交易数。
    private func recordSyncEvent(_ type: String,
                                 count: Int?,
                                 trace: HTTPCallTrace,
                                 startedAt: Date,
                                 error: (any Error)?) async {
        await diagnostics.record(type,
                                 level: error == nil ? DiagnosticsLevel.info : DiagnosticsLevel.error,
                                 fields: [
                                     "status": trace.last?.statusCode.map { .int($0) },
                                     "request_id": trace.last?.requestID.map { .string($0) },
                                     "count": count.map { .int($0) },
                                     "duration_ms": .int(Self.elapsedMs(since: startedAt)),
                                     "error_code": Self.diagnosticsErrorCode(error),
                                 ])
    }

    private func syncInternalBody(userInitiated: Bool,
                                  trace: HTTPCallTrace,
                                  onSuccess: (Int?) async -> Void) async throws -> CustomerInfo {
        guard let storeKit else {
            let info = try await customerInfo(fetchPolicy: .fetchCurrent)
            await onSuccess(0)
            return info
        }
        if userInitiated {
            do {
                try await storeKit.syncStoreAccount() // AppStore.sync()：弹框
            } catch {
                if isUserCancelled(error) {
                    throw PurchasesError(code: .purchaseCancelledError, message: "用户取消了恢复购买", underlyingError: error)
                }
                // 其余 sync 失败 best-effort 继续：本地已有的交易仍可上报
                Log.warn("AppStore.sync 失败，继续用本地交易恢复：\(error)", category: "restore")
            }
        }

        // 候选：currentEntitlements ∪ unfinished，取 purchaseDate 最新且带 JWS 的一笔（#26 排序纪律）
        let entitlements = await storeKit.currentEntitlementTransactions()
        let unfinished = await storeKit.unfinishedTransactions()
        let latest = (entitlements + unfinished)
            .filter { $0.jwsRepresentation != nil }
            .sorted { $0.purchaseDate > $1.purchaseDate }
            .first

        let candidateCount = (entitlements + unfinished).filter { $0.jwsRepresentation != nil }.count

        guard let latest, let jws = latest.jwsRepresentation else {
            // 无任何本地交易 = 没有可恢复的 —— 只刷新服务端视图
            let info = try await customerInfo(fetchPolicy: .fetchCurrent)
            await onSuccess(0)
            return info
        }

        // AppTransaction：优先启动预取缓存，缺则现取（P7：失败不阻断）
        if appTransactionJWS == nil, let info = await storeKit.appTransactionInfo() {
            appTransactionJWS = info.jwsRepresentation
            StoreEnvironmentCache.setAppTransactionEnvironment(info.environment)
        }

        let appUserID = try await identity.appUserID
        // 瞬态上下文（不落盘）：restore 不是购买，失败由用户重试/下次 sync 兜底
        let context = PendingPurchaseContext(key: latest.transactionIdentifier,
                                             productIdentifier: latest.productIdentifier,
                                             appUserID: appUserID,
                                             initiationSource: .restore,
                                             jws: jws)
        let pendingAttributes = await attributesStore.unsynced(appUserID: appUserID)
        let result = await poster.post(jws: jws,
                                       transaction: latest,
                                       productIdentifier: latest.productIdentifier,
                                       appUserID: appUserID,
                                       context: context,
                                       // restore/sync 不是「进行中的购买」，用当前运行时模式（M-2a）
                                       completedBy: settings.purchasesCompletedBy,
                                       appTransactionJWS: appTransactionJWS,
                                       attributes: pendingAttributes,
                                       trace: trace)
        switch result {
        case .success(let posted):
            await attributesStore.markSynced(pendingAttributes, appUserID: appUserID)
            await ledger?.record(latest.transactionIdentifier)
            await deviceCache.cache(customerInfo: posted.customerInfo, appUserID: appUserID)
            await publish(posted.customerInfo,
                          source: userInitiated ? .restore : .sync,
                          requestID: trace.last?.requestID)
            await onSuccess(candidateCount)
            return posted.customerInfo
        case .failure(.finishable(let error)), .failure(.retryable(let error)):
            throw error
        }
    }

    private func isUserCancelled(_ error: any Error) -> Bool {
        #if canImport(StoreKit)
        if let skError = error as? StoreKitError, case .userCancelled = skError { return true }
        #endif
        return (error as? PurchasesError)?.code == .purchaseCancelledError
    }

    // MARK: - 属性（M3，设计 §1 / §5；契约 §2.4）

    /// 写入属性缓冲（按当前 appUserID 分桶）。**不立刻发请求** —— 同步时机见
    /// `syncAttributesIfNeeded()` 的调用点：进入后台 / 购买上报（搭车）/ logIn 合并前后 / 宿主显式调用。
    /// 返回被拒绝的键（键名非法 / value 超 500 / 触及 50 自定义上限）。
    @discardableResult
    func setAttributes(_ attributes: [String: String?]) async -> [String] {
        guard let appUserID = try? await identity.appUserID else {
            Log.warn("setAttributes 在身份就绪前被调用，已丢弃 \(attributes.count) 条", category: "attributes")
            return Array(attributes.keys)
        }
        return await attributesStore.set(attributes, appUserID: appUserID)
    }

    /// 待同步属性的读视图（测试与诊断用）。
    func unsyncedAttributes() async -> [SubscriberAttribute] {
        guard let appUserID = try? await identity.appUserID else { return [] }
        return await attributesStore.unsynced(appUserID: appUserID)
    }

    /// 同步待发属性到 `POST /v1/subscribers/{id}/attributes`（契约 §2.4）。
    ///
    /// - 单飞：同时只允许一次在途，重复触发直接返回（前后台抖动不会打出重复请求）。
    /// - **坑 #127**：4xx（404/408/429 除外）一律视为「已同步」——RC 原文
    ///   「all 4xx (except 404) are considered as successfully synced … continuing to retry
    ///   won't yield any different results」。属性 400 多半是键名/值非法，重试永远不会变好，
    ///   继续挂在待发队列只会每次前后台都白发一遍。5xx / 网络错误保持未同步等下次时机。
    ///   （可重试性判定本身仍由 §5 的 `Is-Retryable` 协议在 HTTPClient 层说了算，
    ///   这里只处理「HTTPClient 已经放弃之后」的标记语义。）
    /// - 返回是否真的成功落库。
    @discardableResult
    func syncAttributesIfNeeded() async -> Bool {
        guard !isSyncingAttributes else { return false }
        guard let appUserID = try? await identity.appUserID else { return false }
        let pending = await attributesStore.unsynced(appUserID: appUserID)
        guard !pending.isEmpty else { return false }

        isSyncingAttributes = true
        defer { isSyncingAttributes = false }

        let data: Data
        do {
            data = try JSONEncoder().encode(SubscriberAttributesBody(attributes: pending.wireMap))
        } catch {
            Log.warn("属性请求体编码失败：\(error)", category: "attributes")
            return false
        }

        do {
            // 用 performRaw：2xx 即代表服务端已落库；响应体（完整 Subscriber）解码失败
            // 不该把「已经写成功的属性」退回待发队列。
            let raw = try await httpClient.performRaw(.postAttributes(appUserID: appUserID), body: data)
            await attributesStore.markSynced(pending, appUserID: appUserID)
            if let wire = try? JSONDecoder().decode(CustomerInfoWireModel.self, from: raw.body) {
                let info = CustomerInfo(wireModel: wire)
                await deviceCache.cache(customerInfo: info, appUserID: appUserID)
                await publish(info, source: .fetch)
            }
            return true
        } catch let error as PurchasesError {
            if let status = error.httpStatusCode,
               (400...499).contains(status), status != 404, status != 408, status != 429 {
                Log.warn("属性同步被服务端确定性拒绝（HTTP \(status)）：\(error.description) —— 标记已同步不再重试（#127）",
                         category: "attributes")
                await diagnostics.warn(DiagnosticsWarningCode.attributesRejected, detail: "status=\(status)")
                await attributesStore.markSynced(pending, appUserID: appUserID)
                return false
            }
            Log.warn("属性同步暂时失败，保留待发：\(error.description)", category: "attributes")
            return false
        } catch {
            Log.warn("属性同步失败：\(error)", category: "attributes")
            return false
        }
    }

    // MARK: - ASA 归因采集（M3，设计 §8；核实 asa-adservices.md）

    /// AdServices token 采集 + 上报。**只采一次**（持久化标记），失败按官方 5s×3 重试，
    /// 采集不到（模拟器 / 旧机型 / 无网）时上报 `error_code` 而不是静默丢弃（核实 §4.4）。
    ///
    /// 坑 #83：整条链路 fire-and-forget，绝不阻塞 `configure()` / `purchase()`。
    func collectAdServicesAttributionTokenIfNeeded() async {
        guard !didStartAdServicesCollection else { return }
        didStartAdServicesCollection = true
        guard await attributionState.adServicesCollected() == false else {
            Log.debug("AdServices 归因已采集过，跳过（一次性标记）", category: "attribution")
            return
        }

        // install_id：ASA 上报的幂等键（裁决 D2 —— 不能用 token，ATT 变化会生成新 token）。
        // 32 位小写 hex，满足服务端 `^[A-Za-z0-9_-]{8,64}$`。
        let installID: String
        if let stored = await attributionState.installID() {
            installID = stored
        } else {
            installID = IdentityManager.uuid32()
            await attributionState.setInstallID(installID)
        }

        let collector = AdServicesTokenCollector(provider: adServicesTokenProvider,
                                                 scheduler: delayScheduler)
        let outcome = await collector.collect()

        let body: AdServicesAttributionBody
        switch outcome {
        case .success(let token):
            body = AdServicesAttributionBody(installID: installID,
                                             token: token,
                                             errorCode: nil,
                                             collectedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                             appUserID: try? await identity.appUserID)
        case .failure(let error):
            body = AdServicesAttributionBody(installID: installID,
                                             token: nil,
                                             errorCode: error.wireCode,
                                             collectedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                             appUserID: try? await identity.appUserID)
        }

        do {
            let data = try JSONEncoder().encode(body)
            _ = try await httpClient.performRaw(.postAdServicesAttribution, body: data)
            // 上报成功才落一次性标记：上报失败下次启动重来（token TTL 24h，重取一次更合理）。
            await attributionState.setAdServicesCollected(true)
            Log.info("AdServices 归因已上报（install_id=\(installID)，token=\(body.token != nil)）",
                     category: "attribution")
        } catch {
            // 允许下次启动重试 —— 但本进程内不再重来（didStartAdServicesCollection 已置位）。
            didStartAdServicesCollection = false
            Log.warn("AdServices 归因上报失败，留待下次启动：\(error)", category: "attribution")
        }
    }

    /// 启动/前台恢复时串行重放未完成购买（铁律 P3），并做启动补投扫描（裁决 #2 两半）。
    /// 两类上下文：有 JWS 的直接补报（无交易对象 → 不 finish，finish 义务由本轮 unfinished
    /// 扫描配对完成）；只有发起键的（崩溃在弹窗前后）→ 交给 unfinished 扫描配对。
    func replayPendingPurchases() async {
        // 有 finish 义务待清的交易键（.revenueDog：JWS 补报成功但无交易对象可 finish）
        var awaitingFinish: Set<String> = []

        // **坑 #142**：带待重放上下文的冷启动过去要上报 2 次 —— 上下文重放先发一次（只有 JWS、
        // 没有交易对象 → 不能 finish），接着 unfinished 扫描把同一笔又发一次（这次才 finish）。
        // 服务端靠 content_hash 幂等，不是 bug，但白花一次请求，且两次 fetch_token 还不同
        // （StoreKit 会重签），后端要多存一份 raw。
        //
        // 省法：**先看一眼两份 StoreKit 快照**（`Transaction.unfinished` + `currentEntitlements`），
        // 凡是当下就看得见交易对象的上下文，这一轮跳过重放、交给下面的扫描 ——
        // 扫描那条路径握着交易对象，一次上报就能把 finish 义务一起清掉。
        // 去重键就是 `pendingPurchases` 现有的键（rekey 之后 = transactionId），不引入任何新状态。
        // 看不见（P4 可见性滞后 / 交易已被清掉）时行为与从前完全一致。
        var unfinishedSnapshot: [any StoreTransactionType] = []
        var entitlementSnapshot: [any StoreTransactionType] = []
        if let storeKit {
            unfinishedSnapshot = await storeKit.unfinishedTransactions()
                .sorted { $0.purchaseDate < $1.purchaseDate } // #26
            entitlementSnapshot = await storeKit.currentEntitlementTransactions()
                .sorted { $0.purchaseDate < $1.purchaseDate } // #26
        }
        // 只认「拿得到 JWS」的：没有 JWS 的交易扫描路径也报不出去，跳过重放会白丢一次补报机会。
        var coveredByScan = Set(unfinishedSnapshot.filter { $0.jwsRepresentation != nil }
            .map { $0.transactionIdentifier })
        for transaction in entitlementSnapshot where transaction.jwsRepresentation != nil {
            let txID = transaction.transactionIdentifier
            // currentEntitlements 扫描对**台账已记**的交易是直接跳过的（#2 / #10 去重）——
            // 那种交易让位过去就没人收尾了，上下文会永远挂着。只让位给「扫描真的会上报」的那些。
            if let ledger, await ledger.contains(txID) { continue }
            coveredByScan.insert(txID)
        }

        let pending = await pendingPurchases.all()
        for context in pending where context.jws != nil {
            if coveredByScan.contains(context.key) {
                Log.debug("上下文 \(context.key) 对应的交易已在 unfinished 里可见，重放交给扫描路径（#142）",
                          category: "purchase")
                continue
            }
            // M-2a：重放沿用**这笔购买发起时**的模式快照；没有快照的用当前运行时值。
            let completedBy = context.completedBy ?? settings.purchasesCompletedBy
            let result = await poster.post(jws: context.jws!,
                                           transaction: nil,
                                           productIdentifier: context.productIdentifier,
                                           appUserID: context.appUserID,
                                           context: context,
                                           completedBy: completedBy)
            switch result {
            case .success(let posted):
                await deviceCache.cache(customerInfo: posted.customerInfo, appUserID: context.appUserID)
                await publish(posted.customerInfo, source: .purchase)
                if completedBy == .myApp {
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
            // 第一轮直接复用上面那次读（#142 的快照）—— 不为省一次上报再多读一次 StoreKit。
            var unfinished = unfinishedSnapshot
            while true {
                attempt += 1
                if attempt > 1 {
                    unfinished = await storeKit.unfinishedTransactions()
                        .sorted { $0.purchaseDate < $1.purchaseDate }
                }
                for transaction in unfinished {
                    let txID = transaction.transactionIdentifier
                    if seen.contains(txID) && !awaitingFinish.contains(txID) { continue }
                    seen.insert(txID)
                    if await handle(transaction: transaction, source: .unfinishedScan).customerInfo != nil {
                        awaitingFinish.remove(txID)
                    }
                }
                if awaitingFinish.isEmpty || attempt >= 5 { break }
                try? await delayScheduler.sleep(seconds: 0.3)
            }
            if !awaitingFinish.isEmpty {
                Log.warn("unfinished 轮询 5 次后仍有 \(awaitingFinish.count) 笔 finish 义务未清，留待下次启动",
                         category: "purchase")
                await diagnostics.warn(DiagnosticsWarningCode.finishBacklog,
                                       detail: "pending=\(awaitingFinish.count)")
            }
        }

        // #2 后半：currentEntitlements 扫描 —— 已 finish 但可能从未上报成功的权益型交易
        // （别处设备购买 / 兑换码 / 历史上报失败后被宿主 finish）在 unfinished 里看不到。
        // 复用上面那次读（#142）：这一轮里上面的循环已经上报过的，台账去重会挡住。
        await scanCurrentEntitlements(snapshot: entitlementSnapshot)
    }

    /// **M-2b：观察者模式的前台激活重扫**（迁移方案 v2.1 §1 档 1）。
    ///
    /// 依据 `verify/storekit2-multi-listener.md` §1 结论 3 / §4：Apple **只保证**
    /// `purchase()` 发起方经 `Product.PurchaseResult.success(_:)` 拿到那笔交易，
    /// **不保证它也进 `Transaction.updates`** —— 档 1 里购买是 RC 发起的，
    /// Dog 作为观察方只挂 `updates` 就会系统性漏掉「本机刚买的那笔」。
    /// 所以观察者模式必须保留「前台激活时轮询快照序列 + 台账去重」（RC 自己也是这么兜的）。
    ///
    /// 复用**同一条**启动扫描路径 `replayPendingPurchases()`
    /// （= 待重放上下文 + `Transaction.unfinished` + `Transaction.currentEntitlements`），
    /// 不写第二套；去重全靠台账（#10 / #2），已上报过的不会重发。
    func rescanOnForegroundIfObserving() async {
        // 只在观察者模式做：`.revenueDog` 下 Dog 自己发起购买、自己 finish，
        // updates + 启动扫描已经覆盖，前台再扫是纯浪费。
        guard settings.purchasesCompletedBy == .myApp else { return }
        // 单飞：前后台反复抖动不叠加扫描（每次扫描要遍历快照序列 + 读台账）。
        guard !isForegroundRescanning else { return }
        isForegroundRescanning = true
        defer { isForegroundRescanning = false }
        await replayPendingPurchases()
    }

    // MARK: - 权益 diff 上报（M-3 客户端半边，迁移方案 v2.1 §5）

    /// 见 `Purchases.reportEntitlementDiff(rcActive:rcRequestDate:rcSDKVersion:)` 的公开文档。
    func reportEntitlementDiff(rcActive: [String: Date?],
                               rcRequestDate: Date?,
                               rcSDKVersion: String?) async throws -> EntitlementDiffResult {
        let appUserID = try await identity.appUserID

        // Dog 侧快照取**本地缓存**（不发网）—— 上报 diff 本身不该改变被观测对象：
        // 每次比对都强刷会让 Dog 侧永远比 RC 侧新，一致率虚高。完全没缓存时才拉一次。
        let dogInfo: CustomerInfo?
        if let cached = await deviceCache.cachedCustomerInfo(appUserID: appUserID) {
            dogInfo = cached
        } else {
            dogInfo = try? await customerInfo(fetchPolicy: .cachedOrFetched)
        }

        let dogActive = (dogInfo?.entitlements.active ?? [:]).mapValues { $0.expirationDate }
        let system = SystemInfo.current(isBackgrounded: AppStateProvider.isBackgrounded)
        let body = EntitlementDiffBody(
            appUserID: appUserID,
            observedAtMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
            rc: EntitlementDiffBody.Side(active: EntitlementDiffBody.activeMap(rcActive),
                                         requestDateMs: rcRequestDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                                         sdkVersion: rcSDKVersion,
                                         includesSDKVersion: true),
            dog: EntitlementDiffBody.Side(active: EntitlementDiffBody.activeMap(dogActive),
                                          requestDateMs: dogInfo?.requestDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                                          sdkVersion: nil,
                                          includesSDKVersion: false),
            context: EntitlementDiffBody.Context(appVersion: system.clientVersion,
                                                 osVersion: system.platformVersion),
        )

        let data = try await httpClient.encode(body)
        // 匹配由**服务端**算，客户端不判 —— SDK 只解析并透出结果。
        let response = try await httpClient.perform(.postEntitlementDiff, body: data,
                                                    as: EntitlementDiffResult.self)
        return response.body
    }

    /// currentEntitlements 启动扫描（裁决 #2 后半）。台账去重：已上报过的不重发
    /// （已 finish 交易每次启动都在 currentEntitlements 里，无台账会变成每启动一 POST）。
    ///
    /// - Parameter snapshot: `replayPendingPurchases()` 开头读的那份快照（#142：读一次用两处）。
    private func scanCurrentEntitlements(snapshot: [any StoreTransactionType]) async {
        guard storeKit != nil else { return }
        for transaction in snapshot {
            let txID = transaction.transactionIdentifier
            if let ledger, await ledger.contains(txID) { continue }
            if await handle(transaction: transaction, source: .currentEntitlements).customerInfo != nil {
                await ledger?.record(txID)
            }
        }
    }
}
