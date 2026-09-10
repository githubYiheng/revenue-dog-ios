//
//  Purchases.swift
//  公开门面（设计 §1）。内部全 actor（PurchasesOrchestrator）。
//
//  M1 configure / 身份 / customerInfo / offerings、M2 购买链路、
//  M3 restore/sync / 属性 setter 与同步时机 / ASA 归因采集均已落地。
//

import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

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
    ///
    /// ⚠️ M-2a 起这只是**初始值**：运行期的权威开关是 `Purchases.shared.purchasesCompletedBy`
    /// （运行时可写、热切立即生效）。判断「当前是谁在 finish」一律读门面属性，不要读这里。
    public private(set) var purchasesCompletedBy: PurchasesCompletedBy
    /// 后端 Base URL（契约 §1.1 `https://{API_HOST}/v1` 的 host 部分）。
    public private(set) var baseURL: URL
    /// 日志级别。
    public private(set) var logLevel: LogLevel
    /// 客户端诊断事件开关（ADR 0028 / sdk-diagnostics）。默认 **true**。
    ///
    /// 刻意保持 **internal**：宿主唯一需要的动作是 `with(diagnosticsEnabled:)`，
    /// 读回这个值没有集成价值，而公开面只进不出 —— 一条诊断需求只值一个公开符号。
    internal private(set) var diagnosticsEnabled: Bool

    public static let defaultBaseURL = URL(string: "https://api.revdog.org")!

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.appUserID = nil
        self.purchasesCompletedBy = .revenueDog
        self.baseURL = Configuration.defaultBaseURL
        self.logLevel = .info
        self.diagnosticsEnabled = true
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

    /// **客户端诊断事件开关**（默认开启）。
    ///
    /// 开启时 SDK 会在关键节点（configure / 身份 / 购买 / 收据上报 / finish 判定 /
    /// 恢复同步 / HTTP 错误）记结构化事件，攒批上报到 Revenue Dog 后端，
    /// 供「某个用户在他机器上到底发生了什么」的排查。宿主**零工作量**。
    ///
    /// 上传的内容：事件类型与等级、时间戳、商品 id / 交易 id、HTTP 状态码与 `request_id`、
    /// 耗时、错误分类，以及当前 `app_user_id` 与安装标识 `install_id`。
    /// **不上传**：任何 token / 密钥、JWS 原文、请求或响应 body、错误消息文本、
    /// 邮箱 / 姓名 / 设备名，以及日志文本。
    ///
    /// 关掉之后 SDK 不记录、不上传，并**清空本地队列文件**。
    public func with(diagnosticsEnabled: Bool) -> Configuration {
        var copy = self
        copy.diagnosticsEnabled = diagnosticsEnabled
        return copy
    }
}

/// 谁负责 `finish()`（裁决 C4）。禁 public enum → struct + static。
///
/// `Codable`：M-2a 把「发起购买那一刻的模式」快照进 `PendingPurchaseContext` 落盘，
/// 保证跨崩溃重放时在途购买仍按发起时的模式做 finish 决策。
public struct PurchasesCompletedBy: Sendable, Hashable, Codable, CustomStringConvertible {

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
            instance.recordWarning(DiagnosticsWarningCode.duplicateConfigure)
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
        /// 网络层重试策略（设计 §5）。M4 故障注入测试靠它把「重试几次」变成可断言的常量。
        var networkRetryPolicy: RetryPolicy = .default
        /// 网络层退避等待的调度器。与 `delayScheduler`（P4 可见性轮询）分开：
        /// 故障注入测试要既不真睡、又能**记录**每次退避时长（验证 Retry-After 优先）。
        var networkDelayScheduler: any DelayScheduler = TaskDelayScheduler()
        /// ASA 归因端状态（install_id + 已采集标记）。测试注入 InMemory 版避免污染 UserDefaults。
        var attributionState: any AttributionStateStorage = UserDefaultsAttributionStateStorage()
        /// AdServices token 取值面（坑 #83/#84：协议隔离，模拟器/无框架平台优雅降级）。
        var adServicesTokenProvider: any AdServicesTokenProvider = SystemAdServicesTokenProvider()
        /// 客户端诊断管线的可注入面（测试用；生产全走默认值）。
        var diagnostics = DiagnosticsDependencies()

        /// 诊断管线的注入点。默认即生产配置。
        struct DiagnosticsDependencies: Sendable {
            /// JSONL 队列文件位置。nil = `<Application Support>/RevenueDog/diagnostics/queue.jsonl`。
            var fileURL: URL?
            /// `sample_rate_info` 的落盘面。
            var settings: any DiagnosticsSettingsStorage = UserDefaultsDiagnosticsSettingsStorage()
            /// 防抖 / 定时用的调度器（测试注入 NoDelayScheduler）。
            var scheduler: any DelayScheduler = TaskDelayScheduler()
            /// 是否起「前台每 30s」的定时循环。测试注入 NoDelayScheduler 时必须关掉，否则空转。
            var startsPeriodicFlush = true
            var now: @Sendable () -> Date = { Date() }
            var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
        }

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

    /// 运行时可写设置盒（M-2a / M-4）。`nonisolated` 可达 —— 见下面两个公开属性。
    private let settings: RuntimeSettings
    /// CustomerInfo 缓存失效代 —— `invalidateCustomerInfoCache()` 靠它**同步**生效。
    private let cacheInvalidation: CustomerInfoCacheInvalidation
    private let orchestrator: PurchasesOrchestrator
    /// 客户端诊断（ADR 0028）。关掉时仍然存在，只是不记不发（并在 start 时清空队列文件）。
    private let diagnostics: DiagnosticsRecorder
    private let httpClient: HTTPClient
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
        let settings = RuntimeSettings(purchasesCompletedBy: configuration.purchasesCompletedBy)
        self.settings = settings

        let identity = IdentityManager(storage: dependencies.identityStorage)
        let httpClient = HTTPClient(apiKey: configuration.apiKey,
                                    baseURL: configuration.baseURL,
                                    transport: dependencies.transport,
                                    retryPolicy: dependencies.networkRetryPolicy,
                                    scheduler: dependencies.networkDelayScheduler)
        self.httpClient = httpClient
        let cacheInvalidation = CustomerInfoCacheInvalidation()
        self.cacheInvalidation = cacheInvalidation

        // 诊断管线（ADR 0028）。构造顺序：queue → uploader（要 httpClient）→ recorder；
        // httpClient 反过来要 recorder（receipt_post / http_error 的记录点），
        // 这一环由 `httpClient.setDiagnostics(_:)` 在 start() 里闭合。
        let diagnosticsQueue = DiagnosticsQueue(
            fileURL: dependencies.diagnostics.fileURL
                ?? (try? DiagnosticsQueue.defaultFileURL())
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("RevenueDog/diagnostics/\(DiagnosticsQueue.fileName)",
                                            isDirectory: false),
        )
        let attributionState = dependencies.attributionState
        let diagnosticsUploader = DiagnosticsUploader(
            httpClient: httpClient,
            queue: diagnosticsQueue,
            installIDProvider: { await Purchases.resolveInstallID(attributionState) },
            appUserIDProvider: { [identity] in await identity.currentAppUserIDIfAny },
            now: dependencies.diagnostics.now,
        )
        self.diagnostics = DiagnosticsRecorder(queue: diagnosticsQueue,
                                               uploader: diagnosticsUploader,
                                               settings: dependencies.diagnostics.settings,
                                               enabled: configuration.diagnosticsEnabled,
                                               scheduler: dependencies.diagnostics.scheduler,
                                               startsPeriodicFlush: dependencies.diagnostics.startsPeriodicFlush,
                                               now: dependencies.diagnostics.now,
                                               random: dependencies.diagnostics.random)
        let deviceCache = DeviceCache(storage: dependencies.cacheStorage, invalidation: cacheInvalidation)
        let pending = PendingPurchaseStore(directory: dependencies.pendingPurchasesDirectory)

        // 台账放注入目录的子目录（pending 枚举只认根级 *.json，不会误读）→ 与实例同生命周期，测试天然隔离
        let ledgerFileURL = dependencies.pendingPurchasesDirectory
            .appendingPathComponent("_ledger", isDirectory: true)
            .appendingPathComponent("synced-transactions.json", isDirectory: false)
        // 属性缓冲同理放注入目录的子目录（pending 枚举只认根级 *.json）→ 测试天然隔离
        let attributesDirectory = dependencies.pendingPurchasesDirectory
            .appendingPathComponent("_attributes", isDirectory: true)
        let orchestrator = PurchasesOrchestrator(configuration: configuration,
                                                  settings: settings,
                                                  identity: identity,
                                                  httpClient: httpClient,
                                                  deviceCache: deviceCache,
                                                  pendingPurchases: pending,
                                                  storeKit: dependencies.storeKit,
                                                  ledgerFileURL: ledgerFileURL,
                                                  delayScheduler: dependencies.delayScheduler,
                                                  attributesDirectory: attributesDirectory,
                                                  attributionState: dependencies.attributionState,
                                                  adServicesTokenProvider: dependencies.adServicesTokenProvider,
                                                  diagnostics: self.diagnostics)
        self.orchestrator = orchestrator
        self.attribution = Attribution(orchestrator: orchestrator)

        // 同步可读的 appUserID：显式传入就用它，否则先给一个匿名 ID，
        // 启动 Task 里再与持久化结果对齐（避免 configure 之后立刻读到空值）。
        self.appUserID = configuration.appUserID ?? IdentityManager.generateAnonymousAppUserID()
    }

    // MARK: - 迁移开关与钩子（迁移方案 v2.1 §5 M-2a / M-4）

    /// **谁负责 `finish()` —— 运行时可写、热切立即生效。**
    ///
    /// 双 SDK 共存期的权威开关（migration-strategy §1 档 1 ⇄ 档 2）。语义：
    /// - 切换**立即**对之后发起的购买、以及之后观察到的交易生效；
    /// - **进行中的购买沿用其发起时的模式**做 finish 决策（发起时已落盘快照）——
    ///   否则宿主在购买弹窗还开着的时候翻开关，那笔交易就会挂着永不 finish；
    /// - 观察者台账（坑 #10 / 裁决 #2）两种模式共用，切换不影响去重。
    ///
    /// `nonisolated`：与 RC 的 `Purchases.shared.purchasesAreCompletedBy` 同款同步可写
    /// （verify/rc-sdk-observer-mode.md §8.1 判断 6）。开关翻转必须是**一个原子动作**：
    /// 同一处同时切 RC 的 `purchasesAreCompletedBy`、Dog 的本属性、以及 UI 层购买入口
    /// （同上 §8.2 建议 4）。接线模板见 docs/plan/dual-sdk-integration.md §3。
    public nonisolated var purchasesCompletedBy: PurchasesCompletedBy {
        get { settings.purchasesCompletedBy }
        set {
            let old = settings.purchasesCompletedBy
            guard old != newValue else { return }
            settings.purchasesCompletedBy = newValue
            Log.info("purchasesCompletedBy 热切：\(old) → \(newValue)（在途购买沿用发起时的模式）",
                     category: "purchase")
        }
    }

    #if canImport(StoreKit)
    /// **M-4 购买结果钩子**：Dog 自己发起的每次 `Product.purchase()` 返回后、
    /// **Dog 调 `finish()` 之前**同步回调；`success` / `userCancelled` / `pending` 全都回调。
    ///
    /// 用途（档 2）：宿主原样转交 RC —— `try await RevenueCat.Purchases.shared.recordPurchase(result)`。
    /// RC 在观察者模式下**必须**拿到这个回调，否则只剩「前台激活时读 `Transaction.all`、
    /// 一次只报最新 1 条、其余永久静默丢弃」的脆弱兜底
    /// （verify/rc-sdk-observer-mode.md §8.1 判断 3，`[源码]` 强）。
    /// RC 收下之后 **finish 仍由 Dog 负责**（同上 判断 5）。
    ///
    /// 时序保证：回调在 SDK 上报后端之前、`finish()` 之前发生 —— 有单测上锁。
    /// **不回调的唯一情形**：`StoreKitError.userCancelled` 这种 throw 形态的取消（坑 #18），
    /// 它根本没有 `Product.PurchaseResult` 可交。
    ///
    /// 回调在发起购买的那条 Task 上**同步**执行，请只做转交、别做重活（RC 的
    /// `recordPurchase` 是 async，宿主自行起 Task；见 dual-sdk-integration.md §4）。
    ///
    /// 为什么做成运行时可写属性、而不是 `Configuration.with(purchaseResultHandler:)`：
    /// 1. 钩子必须能**随开关一起热切/热卸** —— 档 2 回滚到档 1 时 Dog 不再发起购买，
    ///    钩子要能立刻摘掉，避免 RC 侧重复记账；`Configuration` 是 configure 时冻结的值。
    /// 2. 与本次同样改成运行时可写的 `purchasesCompletedBy` 放在同一处，
    ///    「一个原子动作切完权威」才写得出来（见上）。
    /// 3. `Configuration` 是公开可读的 `Sendable` 值类型（`purchases.configuration`），
    ///    往里塞闭包会让配置不再可比较、不可快照。
    public nonisolated var purchaseResultHandler: (@Sendable (Product.PurchaseResult) -> Void)? {
        get { settings.purchaseResultHandler }
        set { settings.purchaseResultHandler = newValue }
    }
    #endif

    /// `install_id`：与「这次安装」同生命周期的设备标识（裁决 D2 的 ASA 幂等键，诊断事件复用同一个）。
    /// 没有就地生成并落盘 —— ASA 采集路径读的是同一把键，两边不会各生成一个。
    private static func resolveInstallID(_ storage: any AttributionStateStorage) async -> String {
        if let stored = await storage.installID() { return stored }
        let generated = IdentityManager.uuid32()
        await storage.setInstallID(generated)
        return generated
    }

    /// 门面层的 `sdk_warning` 出口（fire-and-forget，绝不阻塞调用方）。
    private nonisolated func recordWarning(_ code: String, detail: String? = nil) {
        Task { [diagnostics] in await diagnostics.warn(code, detail: detail) }
    }

    private func start() {
        AppStateProvider.refresh()
        observeAppLifecycle()
        // 铁律 P1：configure 内**同步**创建监听 Task。
        startTask = Task { [orchestrator, diagnostics, httpClient, configuration] in
            // 诊断先接线：receipt_post / http_error 的记录点在 HTTPClient 里，
            // 必须早于任何一次请求（所有公开入口都先 await 本 Task）。
            await httpClient.setDiagnostics(diagnostics)
            await diagnostics.start()
            await diagnostics.record(DiagnosticsEventType.sdkConfigured, fields: [
                "log_level": .string(configuration.logLevel.label),
                "purchases_completed_by": .string(configuration.purchasesCompletedBy.rawValue),
                "has_app_user_id": .bool(configuration.appUserID != nil),
                "diagnostics_enabled": .bool(configuration.diagnosticsEnabled),
            ])
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

    /// 进入后台：刷新 `X-Is-Backgrounded` 快照 + 冲一次属性缓冲（设计 §5）
    /// + 把攒着的诊断事件发出去（sdk-diagnostics §2 的第三个触发条件）。
    ///
    /// 平台抽象走 `observeAppLifecycle()` 里既有的那套：
    /// iOS/tvOS/visionOS = `UIApplication.didEnterBackgroundNotification`，
    /// macOS = `NSApplication.didResignActiveNotification`，watchOS 无对应通知（不触发，编译照过）。
    func applicationDidEnterBackground() {
        AppStateProvider.setBackgrounded(true)
        Task { [orchestrator] in await orchestrator.syncAttributesIfNeeded() }
        Task { [diagnostics] in await diagnostics.flushForBackground() }
    }

    func applicationDidBecomeActive() {
        AppStateProvider.setBackgrounded(false)
        // M-2b（迁移方案 v2.1 §1 档 1）：观察者模式下前台激活重扫
        // `Transaction.unfinished ∪ currentEntitlements`，台账去重后上报。
        // 依据 verify/storekit2-multi-listener.md §1 结论 3：**观察方不能指望从 `updates`
        // 看到购买方 `purchase()` 返回的那笔**（Apple 只保证走 `PurchaseResult`）。
        // 先 await 启动流程，避免与启动扫描叠加、也避免身份未就绪就上报。
        Task { [weak self] in
            await self?.awaitStart()
            await self?.orchestrator.rescanOnForegroundIfObserving()
        }
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

    /// 作废本地 CustomerInfo 缓存，强制**下一次** fetch 走网络。
    ///
    /// **同步生效**：失效代在本方法返回前就已经 +1，紧接着的
    /// `customerInfo(fetchPolicy:)`（除 `.cachedOnly` 外）必然发请求 ——
    /// 不再像之前那样把失效动作丢进 fire-and-forget `Task` 与调用方赛跑。
    ///
    /// `.cachedOnly` 不受影响（RC 语义：invalidate 只强制下一次 fetch，不是删缓存）。
    public func invalidateCustomerInfoCache() {
        cacheInvalidation.invalidate()
    }

    // MARK: - 权益 diff 上报（M-3 客户端半边，迁移方案 v2.1 §5）

    /// 把 RC 与 Dog 的 `entitlements.active` 两份快照上报
    /// `POST /v1/diagnostics/entitlement-diff`，服务端按日聚合成「按用户逐个的权益一致率」——
    /// 档 1（观察者期）的**核心指标**与出口条件（migration-strategy §1 档 1）。
    ///
    /// - **匹配由服务端算，客户端不判**：端上只如实提供两份快照。端上判等会把
    ///   「时钟偏移 / 3 天 grace / 缓存延迟」这些本该在服务端归因的差异提前吃掉。
    /// - Dog 侧快照取**本地缓存**的 CustomerInfo（不发网）；完全没有缓存时才拉一次。
    ///   上报 diff 不该改变被观测对象。
    /// - 建议调用点：RC `customerInfoStream` 每次更新时调一次
    ///   （接线模板 docs/plan/dual-sdk-integration.md §5）。**节流由服务端 cap**
    ///   （每用户每天 ≤N 次），被 cap 掉的返回 `capped == true`。
    /// - 该端点**不重试**（每次上报是一条独立观测样本，重发会污染日聚合分母）；
    ///   失败即抛，宿主按 best-effort 吞掉即可。
    ///
    /// - Parameters:
    ///   - rcActive: RC 侧 `customerInfo.entitlements.active` 的 `[权益ID: 到期时间]`；
    ///     终身权益传 `nil`（会编码成 JSON `null`）。
    ///   - rcRequestDate: RC 侧 `customerInfo.requestDate`（服务端时间），用于服务端归因时钟差。
    ///   - rcSDKVersion: RC SDK 版本（可选，服务端用于按版本归因）。
    @discardableResult
    public func reportEntitlementDiff(rcActive: [String: Date?],
                                      rcRequestDate: Date?,
                                      rcSDKVersion: String? = nil) async throws -> EntitlementDiffResult {
        await awaitStart()
        return try await orchestrator.reportEntitlementDiff(rcActive: rcActive,
                                                            rcRequestDate: rcRequestDate,
                                                            rcSDKVersion: rcSDKVersion)
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

    /// 诊断记录器（内部读视图：测试断言事件序列用）。
    var diagnosticsRecorder: DiagnosticsRecorder { diagnostics }

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
