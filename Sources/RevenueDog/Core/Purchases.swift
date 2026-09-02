//
//  Purchases.swift
//  公开门面（设计 §1）。内部全 actor（PurchasesOrchestrator）。
//
//  M1 configure / 身份 / customerInfo / offerings、M2 购买链路、
//  M3 restore/sync / 属性 setter 与同步时机 / ASA 归因采集均已落地。
//

import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
        /// ASA 归因端状态（install_id + 已采集标记）。测试注入 InMemory 版避免污染 UserDefaults。
        var attributionState: any AttributionStateStorage = UserDefaultsAttributionStateStorage()
        /// AdServices token 取值面（坑 #83/#84：协议隔离，模拟器/无框架平台优雅降级）。
        var adServicesTokenProvider: any AdServicesTokenProvider = SystemAdServicesTokenProvider()

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
    /// 前后台通知观察者。装在独立盒子里：Purchases 释放时盒子随之析构并摘掉观察者
    /// （Swift 6 下 @MainActor 类的 deinit 不能安全触碰隔离状态，所以不写在 deinit 里）。
    private let lifecycleObservers = NotificationObserverBox()
    /// 属性写入的串行链。setter 是 fire-and-forget，若各自起一个 Task，
    /// **同一个键连写两次时执行顺序不保证** —— 后调用的可能先落盘，用户看到的就是「改回去了」。
    /// 串成一条链后「调用顺序 = 落盘顺序」（LWW 的语义前提）。
    private var attributeWriteChain: Task<Void, Never> = Task {}

    private init(configuration: Configuration, dependencies: Dependencies) {
        Log.setLevel(configuration.logLevel)

        self.configuration = configuration

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
        // 属性缓冲同理放注入目录的子目录（pending 枚举只认根级 *.json）→ 测试天然隔离
        let attributesDirectory = dependencies.pendingPurchasesDirectory
            .appendingPathComponent("_attributes", isDirectory: true)
        let orchestrator = PurchasesOrchestrator(configuration: configuration,
                                                  identity: identity,
                                                  httpClient: httpClient,
                                                  deviceCache: deviceCache,
                                                  pendingPurchases: pending,
                                                  storeKit: dependencies.storeKit,
                                                  ledgerFileURL: ledgerFileURL,
                                                  delayScheduler: dependencies.delayScheduler,
                                                  attributesDirectory: attributesDirectory,
                                                  attributionState: dependencies.attributionState,
                                                  adServicesTokenProvider: dependencies.adServicesTokenProvider)
        self.orchestrator = orchestrator
        self.attribution = Attribution(orchestrator: orchestrator)

        // 同步可读的 appUserID：显式传入就用它，否则先给一个匿名 ID，
        // 启动 Task 里再与持久化结果对齐（避免 configure 之后立刻读到空值）。
        self.appUserID = configuration.appUserID ?? IdentityManager.generateAnonymousAppUserID()
    }

    private func start() {
        AppStateProvider.refresh()
        observeAppLifecycle()
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

    /// 前后台切换观察（设计 §5「属性同步时机：前后台切换 + 购买时」）。
    ///
    /// 用 `queue: nil` 同步派发再自行跳 MainActor —— `OperationQueue.main` 的 block
    /// 要主 run loop 转起来才执行，SPM 单测进程里不保证有。
    private func observeAppLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        let background: Notification.Name? = UIApplication.didEnterBackgroundNotification
        let foreground: Notification.Name? = UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        let background: Notification.Name? = NSApplication.didResignActiveNotification
        let foreground: Notification.Name? = NSApplication.didBecomeActiveNotification
        #else
        let background: Notification.Name? = nil
        let foreground: Notification.Name? = nil
        #endif
        guard let background, let foreground else { return }
        lifecycleObservers.observe(background) { [weak self] in
            Task { @MainActor in self?.applicationDidEnterBackground() }
        }
        lifecycleObservers.observe(foreground) { [weak self] in
            Task { @MainActor in self?.applicationDidBecomeActive() }
        }
    }

    /// 进入后台：刷新 `X-Is-Backgrounded` 快照 + 冲一次属性缓冲（设计 §5）。
    func applicationDidEnterBackground() {
        AppStateProvider.setBackgrounded(true)
        Task { [orchestrator] in await orchestrator.syncAttributesIfNeeded() }
    }

    func applicationDidBecomeActive() {
        AppStateProvider.setBackgrounded(false)
    }

    /// 等待 SDK 启动期初始化（供 `Attribution` 这类不持有 startTask 的协作方使用）。
    static func awaitConfigured() async {
        await instance?.startTask?.value
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

    // MARK: - 属性与归因（M3，契约 §2.4）

    /// 写入**自定义**属性（键必须字母开头、≤40 字符、`[A-Za-z0-9_-]`）。
    ///
    /// - 空串 = 删除该属性（墓碑，服务端存 NULL）。
    /// - `$` 前缀是保留键，这里一律拒绝并打日志 —— 保留键请走下面的专用 setter，
    ///   免得宿主拼错键名后整批 400（服务端 `attributes.ts` 对非法键整批拒绝）。
    /// - 写入只落本地缓冲，**不立刻发请求**；同步时机 = 进入后台 / 购买上报（搭车）/
    ///   logIn 合并前后 / `syncAttributesIfNeeded()`（设计 §5）。
    public func setAttributes(_ attributes: [String: String]) {
        let reserved = attributes.keys.filter { SubscriberAttributeKeys.isReserved($0) }
        if !reserved.isEmpty {
            Log.warn("setAttributes 收到保留键（`$` 前缀），已忽略：\(reserved.sorted()) —— 请用专用 setter",
                     category: "attributes")
        }
        let custom = attributes.filter { !SubscriberAttributeKeys.isReserved($0.key) }
        guard !custom.isEmpty else { return }
        enqueueAttributeWrite(custom.mapValues { Optional($0) })
    }

    /// 立刻把待同步属性冲到服务端（宿主显式触发点；设计 §5 同步时机之一）。
    public func syncAttributesIfNeeded() async {
        await awaitStart()
        await attributeWriteChain.value   // 先把排队中的 setter 落盘，别把最后一条漏在队列里
        await orchestrator.syncAttributesIfNeeded()
    }

    /// 当前身份下**待同步**的属性缓冲（诊断/测试读视图，不对外公开）。
    /// 先等属性写入链排空，读到的才是「所有已调用的 setter 都落盘之后」的状态。
    func unsyncedAttributes() async -> [SubscriberAttribute] {
        await awaitStart()
        await attributeWriteChain.value
        return await orchestrator.unsyncedAttributes()
    }

    // 保留键 setter（契约 §2.4 保留键全集 + 决策 12 的归因键）。`nil` / 空串 = 删除。

    public func setEmail(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.email, value) }
    public func setPhoneNumber(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.phoneNumber, value) }
    public func setDisplayName(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.displayName, value) }
    /// APNs device token（`$apnsTokens`）。传 `Data` 的重载见下。
    public func setPushToken(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.apnsTokens, value) }
    /// `didRegisterForRemoteNotificationsWithDeviceToken` 的 `Data` 直接喂进来（转小写 hex）。
    public func setPushToken(_ token: Data?) {
        setPushToken(token.map { $0.map { String(format: "%02x", $0) }.joined() })
    }
    public func setFCMToken(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.fcmTokens, value) }
    public func setATTConsentStatus(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.attConsentStatus, value) }
    public func setIDFA(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.idfa, value) }
    public func setIDFV(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.idfv, value) }
    public func setDeviceVersion(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.deviceVersion, value) }
    public func setAppleRefundHandlingPreference(_ value: String?) {
        setReservedAttribute(SubscriberAttributeKeys.appleRefundHandlingPreference, value)
    }

    // 归因 / 三方 SDK 保留键
    public func setAdjustID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.adjustID, value) }
    public func setAppsflyerID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.appsflyerID, value) }
    public func setAmplitudeDeviceID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.amplitudeDeviceID, value) }
    public func setAmplitudeUserID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.amplitudeUserID, value) }
    public func setBrazeAliasName(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.brazeAliasName, value) }
    public func setBrazeAliasLabel(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.brazeAliasLabel, value) }
    public func setCleverTapID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.clevertapID, value) }
    public func setFBAnonymousID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.fbAnonID, value) }
    public func setMparticleID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.mparticleID, value) }
    public func setOnesignalID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.onesignalID, value) }
    public func setAirshipChannelID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.airshipChannelID, value) }
    public func setIterableUserID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.iterableUserID, value) }
    public func setIterableCampaignID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.iterableCampaignID, value) }
    public func setIterableTemplateID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.iterableTemplateID, value) }
    public func setFirebaseAppInstanceID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.firebaseAppInstanceID, value) }
    public func setMixpanelDistinctID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.mixpanelDistinctID, value) }
    public func setKochavaDeviceID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.kochavaDeviceID, value) }
    public func setTenjinID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.tenjinID, value) }
    public func setPostHogUserID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.posthogUserID, value) }
    public func setCustomerioID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.customerioID, value) }
    public func setAppstackID(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.appstackID, value) }

    // 通用归因维度（决策 12 清单）
    public func setMediaSource(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.mediaSource, value) }
    public func setCampaign(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.campaign, value) }
    public func setAdGroup(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.adGroup, value) }
    public func setAd(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.ad, value) }
    public func setKeyword(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.keyword, value) }
    public func setCreative(_ value: String?) { setReservedAttribute(SubscriberAttributeKeys.creative, value) }

    private func setReservedAttribute(_ key: String, _ value: String?) {
        enqueueAttributeWrite([key: value])
    }

    /// 把一次属性写入挂到串行链尾（保证「调用顺序 = 落盘顺序」）。
    private func enqueueAttributeWrite(_ attributes: [String: String?]) {
        let previous = attributeWriteChain
        attributeWriteChain = Task { [orchestrator] in
            await previous.value
            await self.awaitStart()
            await orchestrator.setAttributes(attributes)
        }
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

    private let orchestrator: PurchasesOrchestrator

    init(orchestrator: PurchasesOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// 开启 AdServices 归因 token 采集（设计 §8）。
    ///
    /// 语义：**只采一次**（持久化标记跨启动生效）；采集失败按 Apple 官方节奏
    /// 5s × 3 次重试；模拟器 / 无 `AdServices.framework` 的平台优雅跳过并打日志；
    /// 无论成功与否都会带 `install_id` 打一次 `POST /v1/attribution/adservices`
    /// （失败时带 `error_code`，让后端能区分「没广告归因」与「没拿到 token」）。
    ///
    /// 坑 #83：**fire-and-forget**，绝不阻塞 `configure()` / `purchase()`。
    public func enableAdServicesAttributionTokenCollection() {
        Task { [orchestrator] in
            await Purchases.awaitConfigured()
            await orchestrator.collectAdServicesAttributionTokenIfNeeded()
        }
    }
}

// MARK: - 通知观察者盒子

/// `NotificationCenter` 观察者的生命周期容器。持有者释放时自动摘除，
/// 避免测试里反复 configure 留下越积越多的僵尸观察者。
final class NotificationObserverBox: @unchecked Sendable {

    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []

    func observe(_ name: Notification.Name, handler: @escaping @Sendable () -> Void) {
        // queue: nil = 在发帖线程同步派发；handler 自己跳到 MainActor。
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            handler()
        }
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
