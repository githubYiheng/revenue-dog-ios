//
//  Purchases.swift
//  公开门面（设计 §1）。内部全 actor（PurchasesOrchestrator）。
//
//  M1 骨架：configure / 身份 / customerInfo / offerings 可用；
//  购买链路（M2）、restore/sync/属性/归因（M3）为显式占位，调用会抛 notImplementedError。
//

import Foundation

// MARK: - Configuration（builder 风格）

public struct Configuration: Sendable {

    /// Public / SDK key，前缀 `pk_`（契约 §1.2）。
    public let apiKey: String
    /// nil = 匿名启动。
    public private(set) var appUserID: String?
    /// `.revenueDog` = SDK 负责 finish；`.myApp` = 宿主自管 finish（裁决 C4）。
    public private(set) var purchasesCompletedBy: PurchasesCompletedBy
    /// 后端 Base URL（契约 §1.1 `https://{API_HOST}/v1` 的 host 部分）。
    public private(set) var baseURL: URL
    /// 日志级别。
    public private(set) var logLevel: LogLevel

    public static let defaultBaseURL = URL(string: "https://api.revenuedog.com")!

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.appUserID = nil
        self.purchasesCompletedBy = .revenueDog
        self.baseURL = Configuration.defaultBaseURL
        self.logLevel = .info
    }

    public func with(appUserID: String?) -> Configuration {
        var copy = self
        copy.appUserID = appUserID
        return copy
    }

    public func with(purchasesCompletedBy: PurchasesCompletedBy) -> Configuration {
        var copy = self
        copy.purchasesCompletedBy = purchasesCompletedBy
        return copy
    }

    public func with(baseURL: URL) -> Configuration {
        var copy = self
        copy.baseURL = baseURL
        return copy
    }

    public func with(logLevel: LogLevel) -> Configuration {
        var copy = self
        copy.logLevel = logLevel
        return copy
    }
}

/// 谁负责 `finish()`（裁决 C4）。禁 public enum → struct + static。
public struct PurchasesCompletedBy: Sendable, Hashable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// SDK 负责：后端 200 落库后才 finish（铁律 P2）。
    public static let revenueDog = PurchasesCompletedBy(rawValue: "revenue_dog")
    /// 宿主自管：SDK **一律不 finish**（铁律 P2）。
    public static let myApp = PurchasesCompletedBy(rawValue: "my_app")

    public var description: String { rawValue }
}

/// CustomerInfo 读取策略。禁 public enum → struct + static。
public struct FetchPolicy: Sendable, Hashable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// 默认：有缓存且未过期用缓存，否则拉网。
    public static let cachedOrFetched = FetchPolicy(rawValue: "cached_or_fetched")
    /// 只用缓存，没有就报错（完全离线场景）。
    public static let cachedOnly = FetchPolicy(rawValue: "cached_only")
    /// 强制拉网（不接受 stale 回落）。
    public static let fetchCurrent = FetchPolicy(rawValue: "fetch_current")
    /// 未过期才用缓存，否则拉网；拉网失败时可回落 stale。
    public static let notStaleCachedOrFetched = FetchPolicy(rawValue: "not_stale_cached_or_fetched")

    public var description: String { rawValue }
}

// MARK: - Delegate

@MainActor
public protocol PurchasesDelegate: AnyObject {
    /// 与 `customerInfoStream` **同源**（设计 §1）。
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo)
}

public extension PurchasesDelegate {
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {}
}

// MARK: - Purchases

/// SDK 门面。
///
/// 并发模型：门面本身 `@MainActor`（可变的 delegate / 缓存镜像都在主线程），
/// 真正的编排在 `PurchasesOrchestrator` actor 里（设计 §6：全 actor 化，零自定义锁）。
@MainActor
public final class Purchases {

    // MARK: 单例

    private static var instance: Purchases?

    public static var isConfigured: Bool { instance != nil }

    public static var shared: Purchases {
        guard let instance else {
            fatalError("Purchases.shared 在 configure(with:) 之前被访问 —— "
                       + "SDK 必须在 App 启动期配置（设计 §1 / 铁律 P1）")
        }
        return instance
    }

    /// 强制启动期配置（堵死「登录后再 init」的丢单源，R1/C4）。
    @discardableResult
    public static func configure(with configuration: Configuration) -> Purchases {
        if let instance {
            Log.warn("Purchases 已配置过，忽略重复的 configure(with:)")
            return instance
        }
        let purchases = Purchases(configuration: configuration, dependencies: .live(configuration: configuration))
        instance = purchases
        purchases.start()
        return purchases
    }

    /// 测试/预览用配置入口。
    @discardableResult
    static func configure(with configuration: Configuration, dependencies: Dependencies) -> Purchases {
        let purchases = Purchases(configuration: configuration, dependencies: dependencies)
        instance = purchases
        purchases.start()
        return purchases
    }

    /// 仅用于测试：拆掉单例。
    static func resetForTesting() {
        instance = nil
    }

    // MARK: 依赖

    struct Dependencies: Sendable {
        var identityStorage: any IdentityStorage
        var cacheStorage: any CacheStorage
        var transport: any HTTPTransport
        var pendingPurchasesDirectory: URL
        var storeKit: (any StoreKitProvider)?
        /// P4 轮询等待的调度器；测试注入 NoDelayScheduler。
        var delayScheduler: any DelayScheduler = TaskDelayScheduler()

        static func live(configuration: Configuration) -> Dependencies {
            let pendingDirectory = (try? PendingPurchaseStore.defaultDirectory())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("RevenueDog/PendingPurchases",
                                                                                 isDirectory: true)
            let cacheStorage: any CacheStorage
            if let directory = try? FileCacheStorage.defaultDirectory() {
                cacheStorage = FileCacheStorage(directory: directory)
            } else {
                Log.warn("Application Support 不可用，缓存降级为纯内存")
                cacheStorage = InMemoryCacheStorage()
            }
            var storeKit: (any StoreKitProvider)?
            #if canImport(StoreKit)
            storeKit = SK2Provider()
            #else
            storeKit = nil
            #endif
            return Dependencies(identityStorage: UserDefaultsIdentityStorage(),
                                cacheStorage: cacheStorage,
                                transport: URLSessionTransport.makeDefault(),
                                pendingPurchasesDirectory: pendingDirectory,
                                storeKit: storeKit)
        }
    }

    // MARK: 状态

    public let configuration: Configuration

    /// 兼容习惯的 delegate，事件与 `customerInfoStream` 同源（设计 §1）。
    public weak var delegate: (any PurchasesDelegate)?

    /// 离线可用：同步读缓存（设计 §1）。
    public private(set) var cachedCustomerInfo: CustomerInfo?

    /// 当前 App User ID。`configure` 后立即可读（匿名 ID 在启动期生成）。
    public private(set) var appUserID: String

    public var isAnonymous: Bool { IdentityManager.isAnonymous(appUserID) }

    public let attribution: Attribution

    private let orchestrator: PurchasesOrchestrator
    private var startTask: Task<Void, Never>?

    private init(configuration: Configuration, dependencies: Dependencies) {
        Log.setLevel(configuration.logLevel)

        self.configuration = configuration
        self.attribution = Attribution()

        let identity = IdentityManager(storage: dependencies.identityStorage)
        let httpClient = HTTPClient(apiKey: configuration.apiKey,
                                    baseURL: configuration.baseURL,
                                    transport: dependencies.transport)
        let deviceCache = DeviceCache(storage: dependencies.cacheStorage)
        let pending = PendingPurchaseStore(directory: dependencies.pendingPurchasesDirectory)

        // 台账放注入目录的子目录（pending 枚举只认根级 *.json，不会误读）→ 与实例同生命周期，测试天然隔离
        let ledgerFileURL = dependencies.pendingPurchasesDirectory
            .appendingPathComponent("_ledger", isDirectory: true)
            .appendingPathComponent("synced-transactions.json", isDirectory: false)
        self.orchestrator = PurchasesOrchestrator(configuration: configuration,
                                                  identity: identity,
                                                  httpClient: httpClient,
                                                  deviceCache: deviceCache,
                                                  pendingPurchases: pending,
                                                  storeKit: dependencies.storeKit,
                                                  ledgerFileURL: ledgerFileURL,
                                                  delayScheduler: dependencies.delayScheduler)

        // 同步可读的 appUserID：显式传入就用它，否则先给一个匿名 ID，
        // 启动 Task 里再与持久化结果对齐（避免 configure 之后立刻读到空值）。
        self.appUserID = configuration.appUserID ?? IdentityManager.generateAnonymousAppUserID()
    }

    private func start() {
        AppStateProvider.refresh()
        // 铁律 P1：configure 内**同步**创建监听 Task。
        startTask = Task { [orchestrator] in
            await orchestrator.setCustomerInfoObserver { [weak self] customerInfo in
                Task { @MainActor in self?.receive(customerInfo) }
            }
            do {
                let resolved = try await orchestrator.start()
                self.appUserID = resolved
                self.cachedCustomerInfo = await orchestrator.cachedCustomerInfo()
            } catch {
                Log.error("SDK 启动失败: \(error)")
            }
            await orchestrator.replayPendingPurchases()
        }
    }

    private func receive(_ customerInfo: CustomerInfo) {
        cachedCustomerInfo = customerInfo
        delegate?.purchases(self, receivedUpdated: customerInfo)
    }

    /// 等待启动期初始化完成（身份解析）。公开方法内部先 await 它，保证顺序正确。
    private func awaitStart() async {
        await startTask?.value
    }

    // MARK: - 身份

    public func logIn(_ appUserID: String) async throws -> (customerInfo: CustomerInfo, created: Bool) {
        await awaitStart()
        let result = try await orchestrator.logIn(appUserID)
        self.appUserID = try await orchestrator.appUserID
        self.cachedCustomerInfo = result.customerInfo
        return result
    }

    public func logOut() async throws -> CustomerInfo {
        await awaitStart()
        let info = try await orchestrator.logOut()
        self.appUserID = try await orchestrator.appUserID
        self.cachedCustomerInfo = info
        return info
    }

    // MARK: - 状态

    public func customerInfo(fetchPolicy: FetchPolicy = .cachedOrFetched) async throws -> CustomerInfo {
        await awaitStart()
        let info = try await orchestrator.customerInfo(fetchPolicy: fetchPolicy)
        cachedCustomerInfo = info
        return info
    }

    /// 替代 delegate 的主通道（设计 §1）。每次访问返回一条独立的流。
    public var customerInfoStream: AsyncStream<CustomerInfo> {
        let (stream, continuation) = AsyncStream<CustomerInfo>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { [orchestrator] in
            for await info in await orchestrator.customerInfoStream() {
                continuation.yield(info)
            }
            continuation.finish()
        }
        return stream
    }

    public func invalidateCustomerInfoCache() {
        Task { [orchestrator] in await orchestrator.invalidateCustomerInfoCache() }
    }

    // MARK: - 商品与购买

    public func offerings() async throws -> Offerings {
        await awaitStart()
        return try await orchestrator.offerings()
    }

    /// M2：购买链路（铁律 P1–P8）。awaitStart 保证 updates 监听已挂（宿主首个调用就是 purchase 也安全）。
    public func purchase(package: Package) async throws -> PurchaseResult {
        await awaitStart()
        return try await orchestrator.purchase(package: package)
    }

    /// M2：购买链路（铁律 P1–P8）。
    public func purchase(product: StoreProduct) async throws -> PurchaseResult {
        await awaitStart()
        return try await orchestrator.purchase(product: product)
    }

    /// M3：显式用户动作触发（会弹框）。
    public func restorePurchases() async throws -> CustomerInfo {
        await awaitStart()
        let info = try await orchestrator.restorePurchases()
        cachedCustomerInfo = info
        return info
    }

    /// M3：静默同步。
    public func syncPurchases() async throws -> CustomerInfo {
        await awaitStart()
        let info = try await orchestrator.syncPurchases()
        cachedCustomerInfo = info
        return info
    }

    // MARK: - 属性与归因（M3）

    public func setAttributes(_ attributes: [String: String]) {
        Task { [orchestrator] in
            await orchestrator.setAttributes(attributes.mapValues { Optional($0) })
        }
    }

    public func setEmail(_ email: String?) { setReservedAttribute("$email", email) }
    public func setPhoneNumber(_ phoneNumber: String?) { setReservedAttribute("$phoneNumber", phoneNumber) }
    public func setDisplayName(_ displayName: String?) { setReservedAttribute("$displayName", displayName) }
    public func setPushToken(_ token: String?) { setReservedAttribute("$apnsTokens", token) }
    public func setAdjustID(_ value: String?) { setReservedAttribute("$adjustId", value) }
    public func setAppsflyerID(_ value: String?) { setReservedAttribute("$appsflyerId", value) }
    public func setMixpanelDistinctID(_ value: String?) { setReservedAttribute("$mixpanelDistinctId", value) }
    public func setFirebaseAppInstanceID(_ value: String?) { setReservedAttribute("$firebaseAppInstanceId", value) }
    public func setOnesignalID(_ value: String?) { setReservedAttribute("$onesignalId", value) }
    public func setMediaSource(_ value: String?) { setReservedAttribute("$mediaSource", value) }
    public func setCampaign(_ value: String?) { setReservedAttribute("$campaign", value) }

    private func setReservedAttribute(_ key: String, _ value: String?) {
        Task { [orchestrator] in await orchestrator.setAttributes([key: value]) }
    }

    // MARK: - 日志

    public static var logLevel: LogLevel {
        get { Log.level }
        set { Log.setLevel(newValue) }
    }

    public static func setLogSink(_ sink: any LogSink) { Log.setSink(sink) }
}

// MARK: - Attribution（M3）

public final class Attribution: Sendable {

    init() {}

    /// AdServices token 采集（设计 §8：token 采集后交 `POST /v1/attribution/adservices`）。
    public func enableAdServicesAttributionTokenCollection() {
        Log.notImplemented("Attribution.enableAdServicesAttributionTokenCollection()", milestone: "M3")
    }
}
