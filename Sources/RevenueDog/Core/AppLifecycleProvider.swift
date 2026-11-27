//
//  AppLifecycleProvider.swift
//  后台执行时间的申请面 + 「应用当前是否活跃」（0.5.2，ADR 0248 决定 2、3）。
//
//  为什么做成可注入的依赖：
//  - 离开前台（失活 / 进后台）那两件工作（属性同步、诊断上传）各包一个后台活动，申请必须在通知回调所在的线程上、
//    任何 `Task` / actor 跳转**之前**同步完成 —— Apple：断言是异步授予的，「as early as possible … preferably before
//    your app actually enters the background」（核实 `research/verify/2026-11-27-attribute-sync-timing-rc-apple.md` C1 / C2）。
//    这条顺序只有把申请面换成记录型实现才能在 macOS 单测里断言（UIKit 真实路径单测跑不到）。
//  - configure 时应用已经活跃（晚 configure 的宿主：冷启动那次 `didBecomeActive` 早于观察者挂上）要补跑一次回前台处理；
//    「是否活跃」同样要能在单测里注入。
//
//  对照 RC（purchases-ios `EventsManager.swift:314-372`）：通知回调里同步 `beginBackgroundTask`，再起 `Task` 做工作 —— 采纳这个顺序；
//  RC 过期回调在 `begin` 返回前被同步调用时会留下一个等工作做完才结束的任务（审查 Q1）—— 我方在 `begin` 返回后立刻结束它。
//

import Foundation

import os

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// 后台活动的申请面与「应用当前是否活跃」。
protocol AppLifecycleProvider: Sendable {

    /// **同步**申请一个后台活动，任意线程可调。
    ///
    /// 拿不到后台时间（`.invalid`）时返回的令牌 `end()` 是空操作，调用方照常做工作、不报错。
    func beginBackgroundActivity(named name: String) -> any BackgroundActivityToken

    /// 应用当前是否处于活跃（前台、接收事件）状态。只在主线程上读。
    @MainActor var isApplicationActive: Bool { get }
}

/// 一个已申请的后台活动。
protocol BackgroundActivityToken: Sendable {

    /// 结束这个后台活动：**幂等**、线程安全、任意线程可调（工作做完与过期回调谁先到都只结束一次）。
    func end()
}

/// 拿不到后台时间、或平台没有后台任务时的令牌：结束是空操作。
struct NoBackgroundActivity: BackgroundActivityToken {
    func end() {}
}

// MARK: - 生产实现

/// 生产实现。UIKit 平台走 `UIApplication.beginBackgroundTask`；没有 UIKit 的平台（macOS 只为本机单测）是空实现。
struct SystemAppLifecycleProvider: AppLifecycleProvider {

    #if canImport(UIKit) && !os(watchOS)

    /// configure 时在主线程取一次（`UIApplication` 是主 actor 类，实例本身可跨线程持有）。
    /// 之后的 `beginBackgroundTask` / `endBackgroundTask` 都是 `nonisolated`（`UIApplication.h` 的 `NS_SWIFT_NONISOLATED`），
    /// 在通知到达的线程上直接调 —— 不用 `MainActor.assumeIsolated`（审查 S2：有人在非主线程 post 同名通知时那是崩溃）。
    private let application: UIApplication

    @MainActor
    init() {
        self.application = UIApplication.shared
    }

    func beginBackgroundActivity(named name: String) -> any BackgroundActivityToken {
        let task = BackgroundActivityHandle<UIBackgroundTaskIdentifier> { [application] identifier in
            // `.invalid` = 没拿到后台时间，没有东西可结束。
            guard identifier != .invalid else { return }
            application.endBackgroundTask(identifier)
        }
        // 过期回调：系统在主线程同步调用（Apple 原文）。拿不到断言时系统同样调它 —— 可能发生在 `begin` 返回之前。
        let identifier = application.beginBackgroundTask(withName: name) {
            Log.warn("后台活动 \(name) 到期，提前结束", category: "lifecycle")
            task.end()
        }
        if identifier == .invalid {
            Log.debug("后台活动 \(name) 拿不到后台时间（.invalid），工作照常进行", category: "lifecycle")
        }
        task.attach(identifier)
        return task
    }

    /// 看 scene，不看 `applicationState`。
    ///
    /// `applicationState` 在启动最早期不可信：还没有任何 scene 连上时（SwiftUI 的 `App.init`，宿主最常见的 configure 位置）
    /// 它读出来是 `.active`，约 80 ms 后才随 scene 连接变成 inactive、再变 active 并发 `didBecomeActive`
    /// （0.5.2 发版前验收实测，iOS 27.0 模拟器，pitfalls P106）。那时当真就会在每次冷启动把回前台处理跑两遍，
    /// 后台拉起的进程在那一刻读到什么没有测过。Apple 对 `applicationState` 的定义本来就是「取最活跃的 scene 的状态」，直接看 scene：
    /// 没有 scene = 不活跃。晚 configure 的宿主（Flutter）此时已有前台活跃的 scene，照常追平。
    @MainActor
    var isApplicationActive: Bool {
        application.connectedScenes.contains { $0.activationState == .foregroundActive }
    }

    #else

    @MainActor
    init() {}

    func beginBackgroundActivity(named name: String) -> any BackgroundActivityToken {
        NoBackgroundActivity()
    }

    @MainActor
    var isApplicationActive: Bool { false }

    #endif
}

/// 一次后台任务申请的配对状态机：`end()` 幂等、线程安全、任意线程可调。与 UIKit 无关（结束动作注入为闭包），所以本机单测测得到。
///
/// 状态只有两项：申请返回的标识（返回前为 nil）与「是否已经结束」。两处会结束它 —— 工作做完、过期回调 ——
/// 谁先到谁结束，后到的是空操作。过期回调若在申请返回之前就被同步调用（审查 Q1），那时还没有标识可结束，
/// 只记下「已结束」；`attach` 拿到标识后立刻结束，不留一个要等工作做完才结束的任务。
final class BackgroundActivityHandle<Identifier: Sendable>: BackgroundActivityToken {

    private struct State {
        var identifier: Identifier?
        var isEnded = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let endTask: @Sendable (Identifier) -> Void

    /// - Parameter endTask: 真正结束后台任务的动作；每个 handle 至多调用一次。
    init(endTask: @escaping @Sendable (Identifier) -> Void) {
        self.endTask = endTask
    }

    /// 申请返回后登记标识。已经结束过（过期回调先到）就立刻结束这个标识。
    func attach(_ identifier: Identifier) {
        let endsNow = state.withLock { state -> Bool in
            if state.isEnded { return true }
            state.identifier = identifier
            return false
        }
        if endsNow { endTask(identifier) }
    }

    func end() {
        let identifier = state.withLock { state -> Identifier? in
            guard !state.isEnded else { return nil }
            state.isEnded = true
            defer { state.identifier = nil }
            return state.identifier
        }
        if let identifier { endTask(identifier) }
    }
}
