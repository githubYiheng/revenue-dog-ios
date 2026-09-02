//
//  StoreKitAbstraction.swift
//  协议隔离全部 StoreKit 类型（设计 §2 / §7）。
//
//  为什么：`SKTestSession` 年年在坏（FB22500243），单测层必须能完全脱离 StoreKit；
//  StoreKit 真身只在集成测试层出现。M1 只建协议 + SK2 适配壳，购买逻辑属于 M2。
//

import Foundation

#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(AppKit) && !canImport(UIKit)
import AppKit
#endif

// MARK: - 交易

/// 交易抽象。`Transaction` 的 SDK 侧只读视图。
public protocol StoreTransactionType: Sendable {
    var transactionIdentifier: String { get }
    var originalTransactionIdentifier: String { get }
    var productIdentifier: String { get }
    var purchaseDate: Date { get }
    var expirationDate: Date? { get }
    var quantity: Int { get }
    var revocationDate: Date? { get }
    var isUpgraded: Bool { get }
    /// 派生账户令牌（我们写进去的 `account_token`）。
    var appAccountToken: UUID? { get }
    /// SK2 JWS 原文 —— 上报 `POST /v1/receipts` 的 `fetch_token`（裁决 F8：不做 base64）。
    var jwsRepresentation: String? { get }
    /// 是否已 finish。
    var isFinished: Bool { get async }

    /// **铁律 P2**：后端 200 落库前绝不调用。
    func finish() async
}

/// 商品抽象。
public protocol StoreProductType: Sendable {
    var productIdentifier: String { get }
    var localizedTitle: String { get }
    var localizedDescription: String { get }
    var price: Decimal { get }
    var currencyCode: String? { get }
    var localizedPriceString: String { get }
    /// 是否为订阅型商品。
    var isSubscription: Bool { get }
}

extension StoreProductType {

    /// 转成公开模型。
    public var storeProduct: StoreProduct {
        StoreProduct(productIdentifier: productIdentifier,
                     localizedTitle: localizedTitle,
                     localizedDescription: localizedDescription,
                     price: price,
                     currencyCode: currencyCode,
                     localizedPriceString: localizedPriceString)
    }
}

/// 购买结果（StoreKit 侧原始形态）。禁 public enum → 内部 enum。
enum StorePurchaseOutcome: Sendable {
    case success(any StoreTransactionType)
    case userCancelled
    /// Ask-to-Buy / SCA —— 交易稍后从 `Transaction.updates` 流出（设计 §3 单一投递通道）。
    case pending
}

/// `AppTransaction` 的 SDK 侧只读摘要（坑 #36 / 铁律 P7：获取失败绝不阻断购买流程）。
struct AppTransactionInfo: Sendable, Equatable {
    /// AppTransaction 的 JWS 原文 —— restore 契约 C 的 `app_transaction` 载荷。
    let jwsRepresentation: String?
    /// `AppStore.Environment` 原文（`Production` / `Sandbox` / `Xcode`）。
    let environment: String?
}

// MARK: - Provider

/// StoreKit 能力面。业务层只认这个协议，永远不直接碰 StoreKit 类型。
protocol StoreKitProvider: Sendable {

    func products(forIdentifiers identifiers: Set<String>) async throws -> [any StoreProductType]

    /// `Transaction.updates` —— **唯一消费者**（设计 §3 / 铁律 P1、P5）。
    func transactionUpdates() -> AsyncStream<any StoreTransactionType>

    /// `Transaction.unfinished` 单次读取。可见性重试（铁律 P4：5×300ms，FB13133387）
    /// 由调用方（orchestrator 重放路径）编排 —— 单次读取语义保持纯粹。
    func unfinishedTransactions() async -> [any StoreTransactionType]

    /// `Transaction.currentEntitlements` 单次读取（裁决 #2 的另一半：
    /// 已 finish 但可能从未上报成功的权益型交易，unfinished 里看不到）。
    func currentEntitlementTransactions() async -> [any StoreTransactionType]

    /// `AppTransaction.shared`（#36 / P7）：任何失败返回 nil，绝不 throw。
    func appTransactionInfo() async -> AppTransactionInfo?

    /// `Storefront.current?.countryCode`（裁决 #123：storefront 归因不依赖交易字段）。
    func storefrontCountryCode() async -> String?

    /// `AppStore.sync()` —— restore 的用户显式弹框同步（M3）。取消/失败原样抛。
    func syncStoreAccount() async throws

    /// 发起购买（铁律 P6：UI context 自动探测 + `PurchaseUIContext` 显式注入，见下）。
    ///
    /// - Parameter onPurchaseResult: **M-4 购买结果钩子**（迁移方案 v2.1 §5 M-4）。
    ///   `Product.purchase()` 一返回就**同步**调用一次，`success` / `userCancelled` / `pending`
    ///   三种结果全都回调 —— 此刻 Dog 还没上报后端、更没 `finish()`，
    ///   满足 RC「`recordPurchase(_:)` 之后由调用方自己 finish」的硬性要求
    ///   （verify/rc-sdk-observer-mode.md §8.1 判断 5）。
    ///   载荷用 `any Sendable` 承运：StoreKit 类型不许渗进业务层（设计 §2 协议隔离），
    ///   还原成 `Product.PurchaseResult` 在 `RuntimeSettings.dispatchPurchaseResult` 里做。
    ///   **例外**：`StoreKitError.userCancelled` 这种 throw 形态的取消（坑 #18）根本没有
    ///   `Product.PurchaseResult` 可交，不回调 —— RC 侧同样无从记录，语义一致。
    func purchase(product: any StoreProductType,
                  appAccountToken: UUID?,
                  onPurchaseResult: (@Sendable (any Sendable) -> Void)?) async throws -> StorePurchaseOutcome
}

// MARK: - 购买 UI context（铁律 P6 / 坑 #23）

/// 宿主可显式注入购买确认弹窗的 UI 载体；不注入则 SDK 自动探测。
/// iPad 多任务 / visionOS 多场景下建议显式注入，避免弹错位置。
@MainActor
public enum PurchaseUIContext {
    #if canImport(UIKit) && !os(watchOS)
    /// 返回承载购买确认弹窗的 scene；nil = 交回自动探测。
    public static var sceneProvider: (() -> UIScene?)?
    #endif
    #if canImport(AppKit) && !canImport(UIKit)
    /// macOS：返回承载购买确认弹窗的窗口；nil = 交回自动探测。
    public static var windowProvider: (() -> NSWindow?)?
    #endif
}

// MARK: - StoreKit 2 适配层

#if canImport(StoreKit)

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct SK2Transaction: StoreTransactionType {

    let underlying: StoreKit.Transaction
    let jwsRepresentation: String?

    init(underlying: StoreKit.Transaction, jwsRepresentation: String?) {
        self.underlying = underlying
        self.jwsRepresentation = jwsRepresentation
    }

    /// 从 `VerificationResult` 构造。M1 不做签名裁决（Trusted Entitlements 是 P1，裁决 C6）：
    /// 保守做法 —— **未通过验签的交易一律不构造**，由调用方决定丢弃或上报。
    init?(verificationResult: VerificationResult<StoreKit.Transaction>) {
        switch verificationResult {
        case .verified(let transaction):
            self.init(underlying: transaction, jwsRepresentation: verificationResult.jwsRepresentation)
        case .unverified(let transaction, let error):
            Log.warn("交易未通过 StoreKit 验签（id=\(transaction.id)）: \(error)", category: "storekit")
            return nil
        }
    }

    var transactionIdentifier: String { String(underlying.id) }
    var originalTransactionIdentifier: String { String(underlying.originalID) }
    var productIdentifier: String { underlying.productID }
    var purchaseDate: Date { underlying.purchaseDate }
    var expirationDate: Date? { underlying.expirationDate }
    var quantity: Int { underlying.purchasedQuantity }
    var revocationDate: Date? { underlying.revocationDate }
    var isUpgraded: Bool { underlying.isUpgraded }
    var appAccountToken: UUID? { underlying.appAccountToken }

    var isFinished: Bool {
        get async {
            for await result in StoreKit.Transaction.unfinished {
                if case .verified(let transaction) = result, transaction.id == underlying.id {
                    return false
                }
                if case .unverified(let transaction, _) = result, transaction.id == underlying.id {
                    return false
                }
            }
            return true
        }
    }

    func finish() async {
        await underlying.finish()
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct SK2Product: StoreProductType {

    let underlying: Product

    init(underlying: Product) { self.underlying = underlying }

    var productIdentifier: String { underlying.id }
    var localizedTitle: String { underlying.displayName }
    var localizedDescription: String { underlying.description }
    var price: Decimal { underlying.price }
    var currencyCode: String? { underlying.priceFormatStyle.currencyCode }
    var localizedPriceString: String { underlying.displayPrice }
    var isSubscription: Bool { underlying.subscription != nil }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct SK2Provider: StoreKitProvider {

    func products(forIdentifiers identifiers: Set<String>) async throws -> [any StoreProductType] {
        do {
            return try await Product.products(for: identifiers).map { SK2Product(underlying: $0) }
        } catch {
            throw PurchasesError(code: .storeProblemError,
                                 message: "StoreKit 拉取商品失败",
                                 underlyingError: error)
        }
    }

    func transactionUpdates() -> AsyncStream<any StoreTransactionType> {
        AsyncStream { continuation in
            let task = Task {
                for await result in StoreKit.Transaction.updates {
                    // 铁律 P5：循环体内不做重活，立即让出。
                    guard let transaction = SK2Transaction(verificationResult: result) else { continue }
                    continuation.yield(transaction)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unfinishedTransactions() async -> [any StoreTransactionType] {
        var result: [any StoreTransactionType] = []
        for await item in StoreKit.Transaction.unfinished {
            if let transaction = SK2Transaction(verificationResult: item) {
                result.append(transaction)
            }
        }
        return result
    }

    func currentEntitlementTransactions() async -> [any StoreTransactionType] {
        var result: [any StoreTransactionType] = []
        for await item in StoreKit.Transaction.currentEntitlements {
            if let transaction = SK2Transaction(verificationResult: item) {
                result.append(transaction)
            }
        }
        return result
    }

    func appTransactionInfo() async -> AppTransactionInfo? {
        // P7：AppTransaction.shared 会 throw（首次可能触发网络/弹 Apple ID 登录），
        // 任何失败一律吞掉返回 nil —— 绝不允许它阻断购买/启动流程。
        guard let result = try? await AppTransaction.shared else { return nil }
        switch result {
        case .verified(let appTransaction):
            return AppTransactionInfo(jwsRepresentation: result.jwsRepresentation,
                                      environment: appTransaction.environment.rawValue)
        case .unverified(_, let error):
            Log.warn("AppTransaction 未通过验签，忽略：\(error)", category: "storekit")
            return nil
        }
    }

    func storefrontCountryCode() async -> String? {
        await Storefront.current?.countryCode
    }

    func syncStoreAccount() async throws {
        try await AppStore.sync()
    }

    func purchase(product: any StoreProductType,
                  appAccountToken: UUID?,
                  onPurchaseResult: (@Sendable (any Sendable) -> Void)?) async throws -> StorePurchaseOutcome {
        guard let sk2Product = (product as? SK2Product)?.underlying else {
            throw PurchasesError(code: .productNotAvailableForPurchaseError,
                                 message: "非 StoreKit 商品无法购买：\(product.productIdentifier)")
        }
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }

        let result: Product.PurchaseResult
        do {
            result = try await Self.performPurchase(sk2Product, options: options)
        } catch StoreKit.Product.PurchaseError.purchaseNotAllowed {
            throw PurchasesError(code: .purchaseNotAllowedError, message: "设备不允许购买")
        } catch let error as StoreKitError {
            if case .userCancelled = error { return .userCancelled } // 坑 #18：throw 形态的取消
            throw PurchasesError(code: .storeProblemError, message: "StoreKit 购买失败", underlyingError: error)
        }

        // M-4：原始结果一到手就交给宿主（**早于**验签丢弃、早于上报、早于 finish）。
        // 放在 switch 之前 = 三种 case 全都回调，且 unverified 被我们丢弃的那笔
        // RC 侧仍能收到（谁认不认那笔交易是各自后端的事）。
        onPurchaseResult?(result)

        switch result {
        case .success(let verification):
            guard let transaction = SK2Transaction(verificationResult: verification) else {
                // 坑矩阵裁决 #20：unverified 一律丢弃 + 埋点，不进上报管道
                throw PurchasesError(code: .storeProblemError, message: "交易未通过 StoreKit 验签，已丢弃")
            }
            return .success(transaction)
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            // 坑矩阵裁决 #43：未知 case 容忍 + 埋点
            Log.warn("未知 PurchaseResult case，按 pending 处理", category: "storekit")
            return .pending
        }
    }

    // MARK: 铁律 P6：UI context（坑 #23 / #87 四件套模板的首个真实用例）
    //
    // 「新 SK2 API 接入模板」（裁决 86/87/88）四件套：
    //   1. `#if compiler(>=X)`   —— API 只存在于新工具链 SDK 时加（本例 confirmIn 系
    //      iOS 17 SDK 起有，而本包要求 swift-tools 6.0 = Xcode 16+，故无需 compiler 门）；
    //   2. `if #available(...)`  —— 运行期版本门控；
    //   3. 平台排除              —— `#if canImport(UIKit) && !os(watchOS)` / AppKit 分支；
    //   4. 无参兜底              —— 全部失败回落 `purchase(options:)`。
    // 多 Xcode 版本编译矩阵：CI 待部署 SOP 落地（M2 出门备注）。
    //
    // 事实核对（2026-08-28 对照 iOS 26.5 SDK swiftinterface）：
    // - `purchase(confirmIn: some UIScene)` = iOS 17.0+/tvOS 17.0+/visionOS 1.0+，@MainActor；
    // - `purchase(confirmIn: NSWindow)` = macOS 侧变体；
    // - 矩阵 #23 提到的 `StoreKitError.invalidPresentationContext` **不存在于任何现行 SDK**
    //   （已在矩阵附录记裁决修正）：无 scene 场景走自动探测尽力，探测不到回落无参形态。
    @MainActor
    private static func performPurchase(_ product: Product,
                                        options: Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult {
        #if canImport(UIKit) && !os(watchOS)
        if #available(iOS 17.0, tvOS 17.0, *) {
            if let scene = PurchaseUIContext.sceneProvider?() ?? Self.detectScene() {
                return try await product.purchase(confirmIn: scene, options: options)
            }
        }
        return try await product.purchase(options: options)
        #elseif canImport(AppKit)
        if #available(macOS 15.2, *) {
            if let window = PurchaseUIContext.windowProvider?()
                ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
                return try await product.purchase(confirmIn: window, options: options)
            }
        }
        return try await product.purchase(options: options)
        #else
        return try await product.purchase(options: options)
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// RC 实证：偶发只有 `foregroundInactive` / `background` scene —— 按优先级降级探测。
    @MainActor
    private static func detectScene() -> UIScene? {
        let scenes = UIApplication.shared.connectedScenes
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
    #endif
}

#endif

// MARK: - 测试替身（无 StoreKit 依赖）

/// 纯内存 provider：单测层用它彻底绕开 StoreKit。
actor FakeStoreKitProvider: StoreKitProvider {

    private var productsByIdentifier: [String: any StoreProductType] = [:]
    private let updatesStream: AsyncStream<any StoreTransactionType>
    private let updatesContinuation: AsyncStream<any StoreTransactionType>.Continuation

    init(products: [any StoreProductType] = []) {
        let (stream, continuation) = AsyncStream<any StoreTransactionType>.makeStream()
        self.updatesStream = stream
        self.updatesContinuation = continuation
        for product in products { productsByIdentifier[product.productIdentifier] = product }
    }

    func setProducts(_ products: [any StoreProductType]) {
        // #125 纪律：重复键不 crash（后写胜出）
        productsByIdentifier = Dictionary(products.map { ($0.productIdentifier, $0) },
                                          uniquingKeysWith: { _, new in new })
    }

    func emit(_ transaction: any StoreTransactionType) {
        updatesContinuation.yield(transaction)
    }

    func products(forIdentifiers identifiers: Set<String>) async throws -> [any StoreProductType] {
        identifiers.compactMap { productsByIdentifier[$0] }
    }

    nonisolated func transactionUpdates() -> AsyncStream<any StoreTransactionType> {
        updatesStream
    }

    private var unfinished: [any StoreTransactionType] = []
    /// P4 测试脚本：逐次调用返回的 unfinished 序列（耗尽后停在最后一组）。
    private var unfinishedSequence: [[any StoreTransactionType]]?
    private(set) var unfinishedCallCount = 0
    private var currentEntitlements: [any StoreTransactionType] = []
    private var appTransaction: AppTransactionInfo?
    private var storefront: String?
    /// 测试脚本：下一次 purchase() 的行为。
    private var nextPurchaseOutcome: (@Sendable (String) -> StorePurchaseOutcome)?
    /// 可挂起版脚本（优先级高于同步版）。
    private var nextPurchaseOutcomeAsync: (@Sendable (String) async -> StorePurchaseOutcome)?
    /// purchase() 收到的 appAccountToken 序列（#22 接线断言用）。
    private(set) var capturedAppAccountTokens: [UUID?] = []
    /// M-4 测试脚本：本次 purchase() 要交给钩子的「原始结果」载荷。
    /// 单测里塞真的 `Product.PurchaseResult`（`.userCancelled` / `.pending` 可直接构造），
    /// 走的是与生产完全同一条派发路径。nil = 不回调（模拟 throw 形态取消）。
    private var scriptedRawPurchaseResult: (any Sendable)?

    func setUnfinished(_ transactions: [any StoreTransactionType]) {
        unfinished = transactions
        unfinishedSequence = nil
    }

    func setUnfinishedSequence(_ sequence: [[any StoreTransactionType]]) {
        unfinishedSequence = sequence
    }

    func setCurrentEntitlements(_ transactions: [any StoreTransactionType]) {
        currentEntitlements = transactions
    }

    func setAppTransaction(_ info: AppTransactionInfo?) { appTransaction = info }
    func setStorefront(_ countryCode: String?) { storefront = countryCode }

    func scriptPurchase(_ outcome: @escaping @Sendable (String) -> StorePurchaseOutcome) {
        nextPurchaseOutcome = outcome
    }

    /// 可挂起的购买脚本（用来编排「同商品并发购买、结果乱序返回」这类时序，坑 #15）。
    func scriptPurchaseAsync(_ outcome: @escaping @Sendable (String) async -> StorePurchaseOutcome) {
        nextPurchaseOutcomeAsync = outcome
    }

    /// M-4：编排本次 purchase() 回调给钩子的原始结果载荷。
    func scriptRawPurchaseResult(_ value: (any Sendable)?) {
        scriptedRawPurchaseResult = value
    }

    func unfinishedTransactions() async -> [any StoreTransactionType] {
        unfinishedCallCount += 1
        if var sequence = unfinishedSequence {
            let batch = sequence.isEmpty ? [] : sequence.removeFirst()
            if !sequence.isEmpty { unfinishedSequence = sequence } // 耗尽后停在最后一组
            return batch
        }
        return unfinished
    }

    func currentEntitlementTransactions() async -> [any StoreTransactionType] { currentEntitlements }

    func appTransactionInfo() async -> AppTransactionInfo? { appTransaction }

    func storefrontCountryCode() async -> String? { storefront }

    /// 测试脚本：syncStoreAccount 行为（nil = 成功；否则抛出该错误）。
    private var syncError: (any Error)?
    private(set) var syncCallCount = 0

    func scriptSyncError(_ error: (any Error)?) { syncError = error }

    func syncStoreAccount() async throws {
        syncCallCount += 1
        if let syncError { throw syncError }
    }

    func purchase(product: any StoreProductType,
                  appAccountToken: UUID?,
                  onPurchaseResult: (@Sendable (any Sendable) -> Void)?) async throws -> StorePurchaseOutcome {
        capturedAppAccountTokens.append(appAccountToken)
        let outcome: StorePurchaseOutcome
        if let asyncScript = nextPurchaseOutcomeAsync {
            outcome = await asyncScript(product.productIdentifier)
        } else if let script = nextPurchaseOutcome {
            outcome = script(product.productIdentifier)
        } else {
            throw PurchasesError(code: .storeProblemError, message: "FakeStoreKitProvider：未编排购买脚本")
        }
        // M-4：与 SK2Provider 同一时序 —— 结果到手就回调，返回给 orchestrator 之前。
        if let scriptedRawPurchaseResult { onPurchaseResult?(scriptedRawPurchaseResult) }
        return outcome
    }
}
