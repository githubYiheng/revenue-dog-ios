//
//  AdServicesTokenCollector.swift
//  Apple Ads（原 Apple Search Ads）归因 token 采集（设计 §2「Attribution / AdServicesTokenCollector」+ §8）。
//
//  官方核实：`docs/research/verify/asa-adservices.md`
//  - 框架平台：**iOS 14.3+ / macOS 11.1+ / Mac Catalyst 14.3+ / visionOS 1.0+**（§4.1）；
//    tvOS / watchOS 上 `AdServices.framework` 根本不存在（坑 **#84**：
//    weak-link + `#if canImport(AdServices)` + `@available` 三件套缺一不可）。
//  - **模拟器拿不到 token**（坑 **#83**，RC `AttributionFetcherTests` 只能断言「不挂起」）——
//    这里直接短路成 `platformNotSupported`，不去空转 4 次 × 5 秒。
//  - 客户端错误码三种：`internalError` / `networkError` / `platformNotSupported`（§4.4），
//    核实结论要求**上报**而不是静默丢弃（否则后端无法区分「设备没广告归因」与「设备根本没拿到 token」）。
//  - 重试节奏：**5 秒间隔、最多 3 次**（§1.4 官方明文数字，设计 §8「端上只重试 5s×3，
//    长程重试归后端 Workflow」）；不要自己发明退避曲线。
//  - **绝不能阻塞初始化 / 购买**（坑 #83）：入口是 fire-and-forget 的 Task。
//
//  关于 #84 的「weak-link」：本 SDK 基线是 iOS 16 / macOS 13，AdServices.framework
//  （iOS 14.3+ / macOS 11.1+）在所有支持的运行环境上必然存在，因此不需要 `-weak_framework`；
//  真正起作用的门控是 `#if canImport(AdServices)`（tvOS/watchOS/Linux 直接编不进来）
//  加 `@available`。CI 侧另有 #129 的符号扫描：产物里不得出现
//  `ASIdentifierManager` / `ATTrackingManager`（本文件天然干净）。
//
//  另：坑 **#129**（App Review 疑似字符串扫描 IDFA 符号）——本文件只用 AdServices，
//  二进制里不会出现 `ASIdentifierManager` / `ATTrackingManager`。
//

import Foundation

#if canImport(AdServices)
import AdServices
#endif

// MARK: - 错误

/// 采集失败原因。上行 `error_code` 取值必须落在服务端
/// `workers/api/src/attribution.ts` 的 `CLIENT_ERRORS` 白名单内，否则会被静默丢弃。
enum AdServicesTokenError: Error, Sendable, Equatable {

    case networkError
    case internalError
    case platformNotSupported
    /// 官方 3 个码位之外的未知失败（含 `@unknown default`）。
    case unknown(String)

    /// 上行 `error_code`（服务端白名单：network_error / internal_error / platform_not_supported）。
    var wireCode: String {
        switch self {
        case .networkError: return "network_error"
        case .platformNotSupported: return "platform_not_supported"
        case .internalError, .unknown: return "internal_error"
        }
    }

    /// 是否值得按官方节奏重试。`platformNotSupported` 是设备/OS 事实，重试没有意义。
    var isTransient: Bool {
        switch self {
        case .networkError, .internalError, .unknown: return true
        case .platformNotSupported: return false
        }
    }
}

// MARK: - Provider

/// AdServices token 取值面 —— 协议隔离，单测彻底绕开系统框架（设计 §7）。
protocol AdServicesTokenProvider: Sendable {
    func attributionToken() async throws -> String
}

/// 真身：`AAAttribution.attributionToken()`。
struct SystemAdServicesTokenProvider: AdServicesTokenProvider {

    func attributionToken() async throws -> String {
        #if targetEnvironment(simulator)
        // 坑 #83：模拟器上永远拿不到 token —— 优雅跳过，不空转重试。
        Log.info("模拟器不提供 AdServices 归因 token，跳过采集", category: "attribution")
        throw AdServicesTokenError.platformNotSupported
        #elseif canImport(AdServices)
        // 坑 #84：`#if canImport` + `@available` 双门控（本 SDK 基线 iOS 16 / macOS 13，
        // 恒满足 14.3 / 11.1，但守卫保留 —— 它同时是给 tvOS/watchOS/未来平台的兜底）。
        // 版本取自框架头文件 `AAAttribution.h`：`API_AVAILABLE(ios(14.3), macosx(11.1), tvos(14.3))`。
        if #available(iOS 14.3, macOS 11.1, macCatalyst 14.3, tvOS 14.3, *) {
            do {
                return try AAAttribution.attributionToken()
            } catch {
                throw Self.map(error)
            }
        }
        throw AdServicesTokenError.platformNotSupported
        #else
        // tvOS / watchOS / Linux：AdServices.framework 不存在。
        Log.info("当前平台无 AdServices.framework，跳过归因 token 采集", category: "attribution")
        throw AdServicesTokenError.platformNotSupported
        #endif
    }

    /// `AAAttributionError` → 我们的三态（核实 §4.4）。未知码位走 `.unknown`
    /// （坑 #43 纪律：系统枚举一律留未知分支 + 诊断埋点，不硬断言只有三个值）。
    static func map(_ error: any Error) -> AdServicesTokenError {
        if let mapped = error as? AdServicesTokenError { return mapped }
        #if canImport(AdServices) && !targetEnvironment(simulator)
        if #available(iOS 14.3, macOS 11.1, macCatalyst 14.3, tvOS 14.3, *) {
            let nsError = error as NSError
            if nsError.domain == AAAttributionErrorDomain {
                switch nsError.code {
                case AAAttributionError.networkError.rawValue: return .networkError
                case AAAttributionError.internalError.rawValue: return .internalError
                case AAAttributionError.platformNotSupported.rawValue: return .platformNotSupported
                default: return .unknown("AAAttribution(\(nsError.code))")
                }
            }
        }
        #endif
        return .unknown("\(error)")
    }
}

/// 测试替身：按脚本逐次返回结果。
actor FakeAdServicesTokenProvider: AdServicesTokenProvider {

    private var outcomes: [Result<String, AdServicesTokenError>]
    private(set) var callCount = 0
    /// >0 时每次调用先挂起这么久（用来验「采集慢/挂起不阻塞其它链路」，坑 #83）。
    private var suspendSeconds: TimeInterval = 0

    init(outcomes: [Result<String, AdServicesTokenError>]) {
        self.outcomes = outcomes
    }

    func setSuspendSeconds(_ seconds: TimeInterval) { suspendSeconds = seconds }

    func attributionToken() async throws -> String {
        callCount += 1
        if suspendSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(suspendSeconds * 1_000_000_000))
        }
        // 脚本耗尽后停在最后一项（不会因为多调一次就换语义）
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : (outcomes.first ?? .failure(.internalError))
        switch outcome {
        case .success(let token): return token
        case .failure(let error): throw error
        }
    }
}

// MARK: - Collector

/// token 采集器：按官方节奏（5s × 3 次重试）取一次 token。
///
/// 只负责「拿到 token 或拿到终态错误」；install_id / 上报 / 一次性标记归 orchestrator。
struct AdServicesTokenCollector: Sendable {

    /// 核实 §1.4：官方明文「initiate retries at intervals of 5 seconds, with a maximum of three attempts」。
    static let retryInterval: TimeInterval = 5
    static let maxRetries = 3

    private let provider: any AdServicesTokenProvider
    private let scheduler: any DelayScheduler

    init(provider: any AdServicesTokenProvider, scheduler: any DelayScheduler) {
        self.provider = provider
        self.scheduler = scheduler
    }

    func collect() async -> Result<String, AdServicesTokenError> {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return .success(try await provider.attributionToken())
            } catch {
                let mapped = (error as? AdServicesTokenError) ?? SystemAdServicesTokenProvider.map(error)
                guard mapped.isTransient, attempt <= Self.maxRetries else {
                    Log.info("AdServices token 采集终止（第 \(attempt) 次，原因=\(mapped.wireCode)）",
                             category: "attribution")
                    return .failure(mapped)
                }
                Log.debug("AdServices token 第 \(attempt) 次失败（\(mapped.wireCode)），\(Self.retryInterval)s 后重试",
                          category: "attribution")
                try? await scheduler.sleep(seconds: Self.retryInterval)
            }
        }
    }
}

// MARK: - 归因端状态持久化

/// install_id（ASA 上报的**幂等键**，裁决 D2）与「已采集过」标记的持久化。
///
/// 用 `UserDefaults` 而不是 Application Support：它要与「这次安装」同生命周期
/// （卸载即失效，正是 install 语义），且是两个极小的标量 —— 不触碰坑 #23（大对象进 UserDefaults 会崩）。
protocol AttributionStateStorage: Sendable {
    func installID() async -> String?
    func setInstallID(_ installID: String) async
    func adServicesCollected() async -> Bool
    func setAdServicesCollected(_ collected: Bool) async
}

actor UserDefaultsAttributionStateStorage: AttributionStateStorage {

    static let installIDKey = "com.revenuedog.sdk.installID"
    static let adServicesCollectedKey = "com.revenuedog.sdk.adServicesCollected"

    // UserDefaults 本身线程安全，但不是 Sendable；此处由 actor 独占持有（同 IdentityStorage）。
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func installID() -> String? { defaults.string(forKey: Self.installIDKey) }

    func setInstallID(_ installID: String) { defaults.set(installID, forKey: Self.installIDKey) }

    func adServicesCollected() -> Bool { defaults.bool(forKey: Self.adServicesCollectedKey) }

    func setAdServicesCollected(_ collected: Bool) {
        defaults.set(collected, forKey: Self.adServicesCollectedKey)
    }
}

actor InMemoryAttributionStateStorage: AttributionStateStorage {

    private var storedInstallID: String?
    private var collected = false

    init(installID: String? = nil, collected: Bool = false) {
        self.storedInstallID = installID
        self.collected = collected
    }

    func installID() -> String? { storedInstallID }
    func setInstallID(_ installID: String) { storedInstallID = installID }
    func adServicesCollected() -> Bool { collected }
    func setAdServicesCollected(_ collected: Bool) { self.collected = collected }
}

// MARK: - 上行请求体

/// `POST /v1/attribution/adservices` 请求体。
///
/// ⚠️ 契约 §5.3 的路径写的是 `/v1/attribution/adservices-token`，字段表也标「形状未定稿」；
/// **以服务端实现 `workers/api/src/attribution.ts` + 契约附录 A 决策 20 为准**：
/// 路径 `/v1/attribution/adservices`，public key 鉴权，
/// `install_id`(必，`^[A-Za-z0-9_-]{8,64}$`) / `token`(可) / `error_code`(字符串枚举) /
/// `collected_at_ms`(可) / `app_user_id`(可)，且 `token` 与 `error_code` 至少要有一个。
struct AdServicesAttributionBody: Encodable, Sendable {

    let installID: String
    let token: String?
    let errorCode: String?
    let collectedAtMs: Int64
    let appUserID: String?

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case token
        case errorCode = "error_code"
        case collectedAtMs = "collected_at_ms"
        case appUserID = "app_user_id"
    }
}
