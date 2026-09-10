//
//  SystemInfo.swift
//  诊断请求头的数据源（设计 §5 / api-contract-v1 §1.3）。
//
//  纯值类型 —— 测试里可以整体注入固定值，让请求快照稳定。
//

import Foundation

#if canImport(os)
import os
#endif

#if canImport(UIKit)
import UIKit
#endif

struct SystemInfo: Sendable, Equatable {

    /// `X-Platform`：后端大小写不敏感解析（契约 §1.5），我们照 RC 发 `iOS` / `macOS`。
    var platform: String
    /// `X-Platform-Version`：OS 版本。
    var platformVersion: String
    /// `X-Platform-Device`：机型标识（`iPhone15,2` / `Mac14,7`）。
    var platformDevice: String
    /// `X-Platform-Flavor`：原生 = `native`。
    var platformFlavor: String
    /// `X-Version`：SDK 版本。
    var sdkVersion: String
    /// `X-Client-Version`：宿主 App 的 CFBundleShortVersionString。
    var clientVersion: String
    /// `X-Client-Build-Version`：宿主 App 的 CFBundleVersion。
    var clientBuildVersion: String
    /// `X-Client-Bundle-ID`。
    var clientBundleID: String
    /// `X-StoreKit-Version`：本 SDK 纯 SK2。
    var storeKitVersion: String
    /// `X-Is-Sandbox`。
    var isSandbox: Bool
    /// `X-Is-Backgrounded`：随时变，取值在发请求那一刻求。
    var isBackgrounded: Bool
    /// `X-Is-Debug-Build`。
    var isDebugBuild: Bool
    /// `X-Installation-Method`：SPM / 手动集成。
    var installationMethod: String
    /// `X-Preferred-Locales`：逗号分隔。
    var preferredLocales: [String]
    /// `X-Storefront`：商店国家码（裁决 #123：走 `Storefront.current`，不依赖交易字段）。
    /// 启动期异步取到前为 nil —— 头按需省略。
    var storefront: String? = nil

    /// SDK 版本。**必须与 CHANGELOG 最新版本号一致** —— `scripts/sdk-release.sh` 门禁 7 会比对。
    static let sdkVersionString = "0.2.0"

    /// 本 SDK 只有 SPM 分发形态（设计基线：SPM 分发、无 ObjC 层）。
    static let installationMethodString = "swift-package-manager"

    static var currentPlatform: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "unknown"
        #endif
    }

    /// 机型标识（`uname().machine`）。模拟器上返回宿主机型，保守地不做特判。
    static var currentDevice: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    /// 沙盒判定。优先 `AppTransaction.environment`（纯 SK2 正道，坑 #98；启动期异步缓存），
    /// 未就绪时回落收据文件名判定（`sandboxReceipt`）。
    /// 保守取值：两路都拿不到时按 **非沙盒** 处理，避免误把生产标成 sandbox。
    static var currentIsSandbox: Bool {
        if let environment = StoreEnvironmentCache.appTransactionEnvironment {
            return environment != "Production" // Sandbox / Xcode 都算沙盒侧
        }
        #if targetEnvironment(simulator)
        return true
        #else
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.lastPathComponent == "sandboxReceipt"
        #endif
    }

    static var currentIsDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func current(isBackgrounded: Bool = false) -> SystemInfo {
        let bundle = Bundle.main
        return SystemInfo(
            platform: currentPlatform,
            platformVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            platformDevice: currentDevice,
            platformFlavor: "native",
            sdkVersion: sdkVersionString,
            clientVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            clientBuildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            clientBundleID: bundle.bundleIdentifier ?? "unknown",
            storeKitVersion: "2",
            isSandbox: currentIsSandbox,
            isBackgrounded: isBackgrounded,
            isDebugBuild: currentIsDebugBuild,
            installationMethod: installationMethodString,
            preferredLocales: Array(Locale.preferredLanguages.prefix(5)),
            storefront: StoreEnvironmentCache.storefront
        )
    }

    /// 诊断头全集（设计 §5 的 8 个必发头 + 契约 §1.3 宽容接受的补充头）。
    var headers: [String: String] {
        var all = [
            "X-Platform": platform,
            "X-Platform-Version": platformVersion,
            "X-Platform-Device": platformDevice,
            "X-Platform-Flavor": platformFlavor,
            "X-Version": sdkVersion,
            "X-Client-Version": clientVersion,
            "X-Client-Build-Version": clientBuildVersion,
            "X-Client-Bundle-ID": clientBundleID,
            "X-StoreKit-Version": storeKitVersion,
            "X-Is-Sandbox": isSandbox ? "true" : "false",
            "X-Is-Backgrounded": isBackgrounded ? "true" : "false",
            "X-Is-Debug-Build": isDebugBuild ? "true" : "false",
            "X-Installation-Method": installationMethod,
            "X-Preferred-Locales": preferredLocales.joined(separator: ","),
        ]
        if let storefront { all["X-Storefront"] = storefront }
        return all
    }
}

/// StoreKit 环境快照缓存（storefront / AppTransaction 环境）。
/// 启动期由 orchestrator 异步填充；取不到就保持 nil，读取方各自降级。
enum StoreEnvironmentCache {
    #if canImport(os)
    private static let state = OSAllocatedUnfairLock<(storefront: String?, env: String?)>(initialState: (nil, nil))

    static var storefront: String? { state.withLock { $0.storefront } }
    static var appTransactionEnvironment: String? { state.withLock { $0.env } }
    static func setStorefront(_ value: String?) { state.withLock { $0.storefront = value } }
    static func setAppTransactionEnvironment(_ value: String?) { state.withLock { $0.env = value } }
    #else
    nonisolated(unsafe) private static var _storefront: String?
    nonisolated(unsafe) private static var _env: String?
    static var storefront: String? { _storefront }
    static var appTransactionEnvironment: String? { _env }
    static func setStorefront(_ value: String?) { _storefront = value }
    static func setAppTransactionEnvironment(_ value: String?) { _env = value }
    #endif
}

/// 应用前后台状态提供者。
///
/// 设计 §5 要求 `X-Is-Backgrounded` 在**发请求那一刻**求值；iOS 上读 `UIApplication.applicationState`
/// 必须在主线程，因此这里做成一个可注入的 @Sendable 闭包，测试里换成固定值。
enum AppStateProvider {

    /// 前后台状态的最近一次快照。由 `Purchases.configure` 起在主线程刷新（M2 接入通知）。
    #if canImport(os)
    private static let backgroundedFlag = OSAllocatedUnfairLock(initialState: false)

    static var isBackgrounded: Bool { backgroundedFlag.withLock { $0 } }
    static func setBackgrounded(_ value: Bool) { backgroundedFlag.withLock { $0 = value } }
    #else
    nonisolated(unsafe) private static var _isBackgrounded = false
    static var isBackgrounded: Bool { _isBackgrounded }
    static func setBackgrounded(_ value: Bool) { _isBackgrounded = value }
    #endif

    /// 在主线程读取一次真实状态并缓存。
    @MainActor
    static func refresh() {
        #if canImport(UIKit) && !os(watchOS)
        setBackgrounded(UIApplication.shared.applicationState == .background)
        #else
        setBackgrounded(false)
        #endif
    }
}
