//
//  RuntimeSettings.swift
//  运行时可写的 SDK 设置盒（迁移方案 v2.1 §5 M-2a / M-4）。
//
//  两个字段，都必须能在**任意隔离域同步读写**：
//  - `purchasesCompletedBy`：档 1↔档 2 的权威开关（migration-strategy §1 档 2 第 3 条：
//    「Dog 侧 `purchasesCompletedBy` 目前是 configure 常量，需改为运行时可写」）。
//  - `purchaseResultHandler`：M-4 购买结果钩子，宿主拿去转交 RC `recordPurchase(_:)`。
//
//  为什么是锁而不是 actor（设计 §6「全 actor 化、零自定义锁」的显式例外，理由留档备审）：
//  1. `purchasesCompletedBy` 的消费点横跨 `@MainActor` 门面、`PurchasesOrchestrator` actor、
//     `TransactionPoster` actor 与 StoreKit 回调 —— 做成 actor 会让每个消费点变成 await，
//     并且把宿主侧 `Purchases.shared.purchasesCompletedBy = x` 这种「开关翻转必须是一个原子动作」
//     的同步写法变成 async（verify/rc-sdk-observer-mode.md §8.2 建议 4）。
//  2. 这正是 RC 的做法：`purchasesAreCompletedBy` 是公开可写属性，底层 `Atomic<Bool>`，
//     所有消费点动态读取（verify/rc-sdk-observer-mode.md §8.1 判断 6，`[源码]` 强）。
//  3. 死锁风险为零：临界区里**零 I/O、零回调**（坑 #65 的反面教材守则），
//     回调一律「锁内取出、锁外调用」（设计 §6 铁律 1）。
//

import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

final class RuntimeSettings: @unchecked Sendable {

    private let lock = NSLock()
    private var _purchasesCompletedBy: PurchasesCompletedBy

    #if canImport(StoreKit)
    private var _purchaseResultHandler: (@Sendable (Product.PurchaseResult) -> Void)?
    #endif

    init(purchasesCompletedBy: PurchasesCompletedBy) {
        self._purchasesCompletedBy = purchasesCompletedBy
    }

    // MARK: - M-2a：运行时可写的完成者模式

    /// 语义（迁移方案 v2.1 §5 M-2）：
    /// - 切换**立即**对新购买 / 新观察到的交易生效；
    /// - **进行中的购买沿用发起时的模式**做 finish 决策（发起时快照进 `PendingPurchaseContext`）；
    /// - 观察者台账（#10 / #2）两种模式共用，不受切换影响。
    var purchasesCompletedBy: PurchasesCompletedBy {
        get { lock.withLock { _purchasesCompletedBy } }
        set { lock.withLock { _purchasesCompletedBy = newValue } }
    }

    // MARK: - M-4：购买结果钩子

    #if canImport(StoreKit)
    /// 见 `Purchases.purchaseResultHandler` 的公开文档。
    var purchaseResultHandler: (@Sendable (Product.PurchaseResult) -> Void)? {
        get { lock.withLock { _purchaseResultHandler } }
        set { lock.withLock { _purchaseResultHandler = newValue } }
    }
    #endif

    /// 派发一次购买结果（M-4）。
    ///
    /// 调用点：`StoreKitProvider.purchase(...)` 里 `Product.purchase()` **一返回就同步调用** ——
    /// 此刻 Dog 还没上报后端、更没 `finish()`，满足 RC 的硬性要求
    /// 「`recordPurchase` 之后由调用方自己 finish」（verify/rc-sdk-observer-mode.md §8.1 判断 5）。
    ///
    /// 载荷用 `any Sendable` 承运：StoreKit 类型不许渗进业务层（设计 §2 协议隔离），
    /// 还原成 `Product.PurchaseResult` 只发生在这里。非 `Product.PurchaseResult` 的载荷
    /// （无 StoreKit 的平台、测试替身的标记值）静默忽略。
    func dispatchPurchaseResult(_ rawResult: any Sendable) {
        #if canImport(StoreKit)
        // 设计 §6 铁律 1：锁内取出、锁外调用（宿主的 handler 里再调 SDK 也不会死锁）。
        let handler = lock.withLock { _purchaseResultHandler }
        guard let handler else { return }
        guard let result = rawResult as? Product.PurchaseResult else {
            Log.debug("purchaseResultHandler 收到非 Product.PurchaseResult 载荷，已忽略", category: "purchase")
            return
        }
        handler(result)
        #endif
    }
}
