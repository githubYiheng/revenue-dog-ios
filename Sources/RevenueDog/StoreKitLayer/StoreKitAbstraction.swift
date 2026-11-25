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
///
/// **internal**：这是 StoreKit 的注入缝，只服务 SDK 内部与单测（`@testable import`）。
/// 曾经是 `public` —— 但公开 protocol 意味着宿主可以 conform，之后往里加任何一条要求
/// 都是破坏性变更；而公开面上没有任何类型暴露它（`StoreProduct` 是独立的值类型），
/// 收窄零代价。M4 API 基线冻结时一并处理。
protocol StoreTransactionType: Sendable {
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
    /// **确知**是续订（SK2 `Transaction.reason == .renewal`，iOS 17+）。iOS 16 拿不到 reason，一律 false。
    /// 续订从来不是 `purchase()` 发起的，不需要排在进行中的购买后面（对齐 RC，ADR 0129）。
    var isKnownRenewal: Bool { get }
    /// 是否已 finish。
    var isFinished: Bool { get async }

    /// **铁律 P2**：后端 200 落库前绝不调用。
    func finish() async
}

extension StoreTransactionType {
    /// 默认「不确知」：测试替身与拿不到 reason 的系统版本都落在这里。
    var isKnownRenewal: Bool { false }
}

/// 商品抽象。**internal**，理由同 `StoreTransactionType`。
protocol StoreProductType: Sendable {
    var productIdentifier: String { get }
    var localizedTitle: String { get }
    var localizedDescription: String { get }
    var price: Decimal { get }
    var currencyCode: String? { get }
    var localizedPriceString: String { get }
    /// 是否为订阅型商品。
    var isSubscription: Bool { get }
    /// 订阅周期（非订阅商品为 nil）。
    var subscriptionPeriod: SubscriptionPeriod? { get }
    /// 介绍性优惠 + 当前 Apple ID 的资格。
    ///
    /// 做成 `async`：资格判定要向 StoreKit 查（`Product.SubscriptionInfo.isEligibleForIntroOffer`
    /// 是 async 属性，且语义是**订阅组级**的，坑 #91）。查不动一律返回 nil，绝不 throw。
    func introductoryOffer() async -> IntroductoryOffer?
}

extension StoreProductType {

    // 默认实现：不带订阅信息的商品替身（测试 / 非订阅平台）无需逐个实现。
    var subscriptionPeriod: SubscriptionPeriod? { nil }
    func introductoryOffer() async -> IntroductoryOffer? { nil }

    /// 转成公开模型（`Package.storeProduct` 的唯一构造点）。
    func makeStoreProduct() async -> StoreProduct {
        // 0.4.0：SK2 的 `priceFormatStyle.currencyCode` 是非可选 String，这里拿到 nil 只可能是替身 / 未来适配层的缺陷。
        // 不改口径（类型仍 String?），只留痕，让桥接层「nil → 码 12」有据可查。
        if currencyCode == nil {
            Log.warn("商品 \(productIdentifier) 的 currencyCode 为 nil（StoreKit 路径本应恒有值）", category: "storekit")
        }
        return StoreProduct(productIdentifier: productIdentifier,
                     localizedTitle: localizedTitle,
                     localizedDescription: localizedDescription,
                     price: price,
                     currencyCode: currencyCode,
                     localizedPriceString: localizedPriceString,
                     subscriptionPeriod: subscriptionPeriod,
                     introductoryOffer: await introductoryOffer())
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
    ///   **例外**：`Product.purchase()` 抛错时根本没有 `Product.PurchaseResult` 可交，不回调 ——
    ///   含 `StoreKitError.userCancelled` 这种 throw 形态的取消（坑 #18，返回 `.userCancelled`）
    ///   与其余经 `StoreKitErrorMapping` 映射成 `PurchasesError` 抛出的失败。RC 侧同样无从记录，语义一致。
    ///
    /// - Throws: `SK2Provider` 抛的一律是 `PurchasesError`（ADR 0243：StoreKit 的原错误在 `underlyingError`）；
    ///   测试替身可以编排任意错误（`FakeStoreKitProvider.scriptPurchaseError`）。
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

    var isKnownRenewal: Bool {
        if #available(iOS 17.0, macOS 14.0, *) { return underlying.reason == .renewal }
        return false
    }

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

    var subscriptionPeriod: SubscriptionPeriod? {
        guard let subscription = underlying.subscription else { return nil }
        return Self.period(subscription.subscriptionPeriod)
    }

    /// 「新 SK2 API 接入模板」纪律：`Unit` 是 enum（`@unknown default` 兜底），
    /// `PaymentMode` 是 struct + static 常量（`default` 兜底）—— 两者都不许硬吃未知值。
    func introductoryOffer() async -> IntroductoryOffer? {
        guard let subscription = underlying.subscription,
              let offer = subscription.introductoryOffer else { return nil }
        // 资格是组级语义（坑 #91）；端上结论仅用于文案（裁决 #124）。
        let isEligible = await subscription.isEligibleForIntroOffer
        let type = Self.offerType(offer.paymentMode)
        return IntroductoryOffer(type: type,
                                 period: Self.period(offer.period),
                                 periodCount: offer.periodCount,
                                 // R9：freeTrial 恒 0，其余取商店原值（payAsYouGo = 每周期价，payUpFront = 整段价）
                                 price: IntroductoryOffer.price(for: type, offerPrice: offer.price),
                                 displayPrice: offer.displayPrice,
                                 isEligible: isEligible)
    }

    /// StoreKit 偶尔把 1 周的商品 / 优惠报成 `7 day`（ADR 0135，实测 iOS 26.3 沙盒），
    /// 按 RC `SubscriptionPeriod.normalized()` 同款规则归一化：day 为 7 的倍数折 week、month 为 12 的倍数折 year。
    /// 商品周期与介绍性优惠周期都经此处。
    private static func period(_ period: Product.SubscriptionPeriod) -> SubscriptionPeriod {
        let unit: SubscriptionPeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default:
            Log.warn("未知订阅周期单位，按 unknown 处理", category: "storekit")
            unit = .unknown
        }
        return SubscriptionPeriod(unit: unit, value: period.value).normalized()
    }

    private static func offerType(_ mode: Product.SubscriptionOffer.PaymentMode) -> IntroductoryOffer.OfferType {
        switch mode {
        case .freeTrial: return .freeTrial
        case .payAsYouGo: return .payAsYouGo
        case .payUpFront: return .payUpFront
        default:
            Log.warn("未知介绍性优惠形态（\(mode.rawValue)），按 unknown 处理", category: "storekit")
            return .unknown
        }
    }
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
        } catch {
            // 坑 #18：throw 形态的取消仍按取消返回，不抛。
            if StoreKitErrorMapping.isUserCancelled(error) { return .userCancelled }
            // 其余经唯一映射转成 `PurchasesError`（ADR 0243），原错误留在 `underlyingError`；
            // 任务取消的 `CancellationError` 原样透出（决定 7）。
            throw StoreKitErrorMapping.thrownError(fromPurchaseFailure: error)
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
    // - 矩阵 #23 提到的 `StoreKitError.invalidPresentationContext` 在 26.5 SDK 里还没有；
    //   2026-11-25 复核 iPhoneOS 27.2 SDK：它从 iOS 27.0 起才有（`@available(iOS 27.0, …)`）。
    //   映射表不点名它（按「StoreKitError 其余 case → storeProblemError」处理，ADR 0243），
    //   这里的 UI 策略不变：无 scene 场景走自动探测尽力，探测不到回落无参形态。
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

// MARK: - StoreKit 错误的唯一映射（ADR 0243）

/// SDK 里**唯一**认识 StoreKit 错误类型的地方（ADR 0243 决定 1–3、5）：
/// 购买错误的码位映射、类别名（诊断 `underlying`）、商店错误码的读取、取消判定。
/// orchestrator 与诊断只调这里，不再出现任何 StoreKit 错误类型。
///
/// 放在 `#if canImport(StoreKit)` 之外：调用方不必为它加平台门控；
/// 没有 StoreKit 的平台上，StoreKit 相关分支编译期消失，其余规则照常。
enum StoreKitErrorMapping {

    /// 「类型所在模块是 StoreKit」的判定前缀（`String(reflecting:)` 带模块名）。
    /// 带点号：`StoreKitTest.` 之类的模块不算。
    static let storeKitModulePrefix = "StoreKit."

    /// 沿 `PurchasesError.underlyingError` 往里拆的层数上限。901 / 902 是两层包装
    /// （外层 901 → 上报失败的 `PurchasesError` → 原错误），4 层足够；封顶是防御，链再深就当没有原错误。
    static let maxUnwrapDepth = 4

    // MARK: 购买错误 → PurchasesError

    /// `Product.purchase` 抛出的错误 → `PurchasesError`。一条规则（ADR 0243 决定 1）：
    /// **StoreKit 抛的错误 → 表里的具体码位，表里没有的一律 `storeProblemError`；不是 StoreKit 的类型 → `unknownError`。**
    ///
    /// | 原错误 | 码位 |
    /// |---|---|
    /// | 已经是 `PurchasesError` | 原样返回 |
    /// | `StoreKitError.networkError` | `networkError`（10） |
    /// | `StoreKitError.notAvailableInStorefront` | `productNotAvailableForPurchaseError`（5） |
    /// | `StoreKitError.unsupported`（Swift 6.1 起的 SDK 才有） | `purchaseInvalidError`（4） |
    /// | `StoreKitError` 其余 case（含将来新增的） | `storeProblemError`（2） |
    /// | `Product.PurchaseError.purchaseNotAllowed` | `purchaseNotAllowedError`（3） |
    /// | `Product.PurchaseError.productUnavailable` | `productNotAvailableForPurchaseError`（5） |
    /// | `Product.PurchaseError` 其余 case（含将来新增的） | `storeProblemError`（2） |
    /// | StoreKit 模块里的其它错误类型（今天是 `InvalidRequestError`） | `storeProblemError`（2） |
    /// | 其它类型 | `unknownError`（0） |
    ///
    /// 取消（`StoreKitError.userCancelled`）由调用方先用 `isUserCancelled` 接走、返回 `.userCancelled`，不走这里。
    /// 产出的错误 `underlyingError` 一律是原错误；文案是中性英文（会被宿主直接显示），带类别名与商店错误码，
    /// **绝不带 Apple 给的文案**。
    ///
    /// 未知 case 归 2 而不是 RC 的 0：否则码位随宿主用哪个 Xcode 编译而变（新 case 在旧工具链里就是「未知」）。
    /// 用 `if case` 而不是穷举 `switch`：不需要 `@unknown default`，也不必为每个新 case 写编译器门控。
    ///
    /// 生产路径不直接调它，调 `thrownError(fromPurchaseFailure:)`（多一条任务取消的例外）。
    static func purchasesError(fromPurchaseFailure error: any Error) -> PurchasesError {
        if let purchasesError = error as? PurchasesError { return purchasesError }
        let code = purchaseFailureCode(error)
        let storeCode = storeErrorCode(of: error)
        return PurchasesError(code: code,
                              message: purchaseFailureMessage(code: code,
                                                              name: leafName(error),
                                                              storeErrorCode: storeCode),
                              underlyingError: error,
                              storeErrorCode: storeCode)
    }

    /// `SK2Provider.purchase` 实际抛出的错误：映射表之外只有一条例外 ——
    /// **任务取消的 `CancellationError` 原样透出**（ADR 0243 决定 7：SDK 任何路径都不把它包成 `PurchasesError`，
    /// 包了只会让写了 `catch is CancellationError` 的宿主开始弹错）。其余走 `purchasesError(fromPurchaseFailure:)`。
    static func thrownError(fromPurchaseFailure error: any Error) -> any Error {
        if error is CancellationError { return error }
        return purchasesError(fromPurchaseFailure: error)
    }

    private static func purchaseFailureCode(_ error: any Error) -> PurchasesErrorCode {
        #if canImport(StoreKit)
        if let storeKitError = error as? StoreKitError {
            if case .networkError = storeKitError { return .networkError }
            if case .notAvailableInStorefront = storeKitError { return .productNotAvailableForPurchaseError }
            #if compiler(>=6.1)
            // `.unsupported` 随 iOS 18.4 SDK（Xcode 16.3 / Swift 6.1）出现，门控照 RC。
            // 旧工具链里这一行不存在，它落到下一行的 2。
            if case .unsupported = storeKitError { return .purchaseInvalidError }
            #endif
            return .storeProblemError
        }
        if let purchaseError = error as? Product.PurchaseError {
            if case .purchaseNotAllowed = purchaseError { return .purchaseNotAllowedError }
            if case .productUnavailable = purchaseError { return .productNotAvailableForPurchaseError }
            return .storeProblemError
        }
        #endif
        // 不点名具体类型（`InvalidRequestError` 只在新 SDK 里有，引用错了就是宿主编译失败）：按模块判。
        return isStoreKitModuleError(error) ? .storeProblemError : .unknownError
    }

    /// 映射出的错误文案（中性英文，与 901 / 902 同一条规则）。例：
    /// `The App Store could not complete the purchase (InvalidRequestError, code 1002).`
    private static func purchaseFailureMessage(code: PurchasesErrorCode,
                                               name: String,
                                               storeErrorCode: Int64?) -> String {
        let lead: String
        switch code {
        case .networkError:
            lead = "The App Store purchase failed because of a network error"
        case .productNotAvailableForPurchaseError:
            lead = "The product is not available for purchase in the App Store"
        case .purchaseInvalidError:
            lead = "The App Store does not support this purchase"
        case .purchaseNotAllowedError:
            lead = "Purchases are not allowed on this device or account"
        case .storeProblemError:
            lead = "The App Store could not complete the purchase"
        default:
            lead = "The purchase failed with an unexpected error"
        }
        let detail = storeErrorCode.map { "\(name), code \($0)" } ?? name
        return "\(lead) (\(detail))."
    }

    // MARK: 取消

    /// 取消的唯一判定：`StoreKitError.userCancelled`（坑 #18：throw 形态的取消）或已映射的 `purchaseCancelledError`。
    /// 购买（`SK2Provider.purchase`）与恢复（`AppStore.sync()` 抛的是原始 StoreKit 错误）共用。
    static func isUserCancelled(_ error: any Error) -> Bool {
        #if canImport(StoreKit)
        if let storeKitError = error as? StoreKitError, case .userCancelled = storeKitError { return true }
        #endif
        return (error as? PurchasesError)?.code == .purchaseCancelledError
    }

    // MARK: 模块判定与商店错误码

    /// 错误类型是否定义在 StoreKit 模块里（今天的实例：`StoreKitError`、`Product.PurchaseError`、`InvalidRequestError`）。
    static func isStoreKitModuleError(_ error: any Error) -> Bool {
        String(reflecting: type(of: error)).hasPrefix(storeKitModulePrefix)
    }

    /// StoreKit 错误值自带的整数码（ADR 0243 决定 3）。只认 StoreKit 模块里的类型，
    /// 读名为 `code` 的整数成员（今天就是 `InvalidRequestError.code`）；读不到就是 nil，不影响映射。
    /// 不用类型化取值：那要引用 `InvalidRequestError`，而它从哪版 SDK 开始有无法逐版核实。
    /// **只读码，不读 `message`**（README 对宿主的承诺：不上传错误消息文本）。
    static func storeErrorCode(of error: any Error) -> Int64? {
        guard isStoreKitModuleError(error) else { return nil }
        return integerCodeMember(of: error)
    }

    /// 纯反射读取：名为 `code` 的子成员是 `Int64`（或 `Int`）就返回。单独拆出来，单测用本地同形结构体验证。
    /// 宿主日志里 `InvalidRequestError(code: 1002, message: "null")` 就是反射打印出来的，读得到这个成员有生产证据。
    static func integerCodeMember(of value: Any) -> Int64? {
        for child in Mirror(reflecting: value).children where child.label == "code" {
            if let code = child.value as? Int64 { return code }
            if let code = child.value as? Int { return Int64(code) }
            return nil
        }
        return nil
    }

    // MARK: 包装链与类别名（诊断 `underlying`）

    /// 顺着 `PurchasesError.underlyingError` 拆开的一条错误链：外层到内层的各层 `PurchasesError`，
    /// 以及最里层的**非** `PurchasesError` 原错误（没有就是 nil）。类别名、超时判定、商店错误码都顺着它找。
    struct ErrorChain {
        let layers: [PurchasesError]
        let root: (any Error)?
    }

    static func chain(of error: any Error) -> ErrorChain {
        var layers: [PurchasesError] = []
        var current: any Error = error
        while let purchasesError = current as? PurchasesError {
            layers.append(purchasesError)
            // 到顶或链断了：没有原错误（深度封顶时不猜）。
            guard layers.count <= maxUnwrapDepth, let next = purchasesError.underlyingError else {
                return ErrorChain(layers: layers, root: nil)
            }
            current = next
        }
        return ErrorChain(layers: layers, root: current)
    }

    /// 诊断 `underlying` 的取值（ADR 0243 决定 5，沿用并扩展 ADR 0155 的类别名）：最里层原错误的**类别名，不带文案**。
    /// 链上没有非 `PurchasesError` 的原错误就是 nil。
    static func underlyingName(of error: any Error) -> String? {
        chain(of: error).root.map(leafName)
    }

    /// 单个原错误的类别名：
    /// - `StoreKitError` 取 case 名；`networkError` 带 URLError 码（`networkError(-1009)`），`systemError` 不带内层；
    /// - `Product.PurchaseError` 取 case 名；
    /// - `URLError` 带码（`URLError(-1001)`）。存进 `any Error` 的 URLError 在 Darwin 上的动态类型是 `NSError`，
    ///   所以按转型判，不按类型名判；
    /// - 其它取类型名（`InvalidRequestError`、`CancellationError`、`NSError`…）。
    static func leafName(_ error: any Error) -> String {
        #if canImport(StoreKit)
        if let storeKitError = error as? StoreKitError {
            // 带关联值的两个显式处理（`systemError` 的关联值里可能有 message），其余取 case 名。
            if case .networkError(let urlError) = storeKitError {
                return "networkError(\(urlError.code.rawValue))"
            }
            if case .systemError = storeKitError { return "systemError" }
            return caseName(storeKitError)
        }
        if let purchaseError = error as? Product.PurchaseError {
            return caseName(purchaseError)
        }
        #endif
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue))"
        }
        return String(describing: type(of: error))
    }

    /// 枚举值的 case 名：取描述里第一个 `(` 之前的部分，关联值（可能含文案）一律不带。
    private static func caseName(_ value: Any) -> String {
        String(String(describing: value).prefix { $0 != "(" })
    }
}

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

    /// `products(forIdentifiers:)` 的调用次数（A 项断言「补 storeProduct 与算 not_found 只查一次商店」）。
    private(set) var productsCallCount = 0
    /// 每次调用请求的 id 集合（ADR 0155：断言「只把缺的 id 交给 StoreKit」）。
    private(set) var productsRequests: [Set<String>] = []
    /// 测试脚本：接下来还要抛错的次数与错误（ADR 0155 重试用例：前 N 次抛错、之后成功）。
    private var productsFailuresRemaining = 0
    private var productsFailureError: any Error = PurchasesError(code: .storeProblemError,
                                                                 message: "FakeStoreKitProvider：编排的商品请求失败")
    /// 测试脚本：每次调用返回前先等它（编排「请求在途」的时序，如并发合并用例）。
    private var productsHook: (@Sendable (Set<String>) async -> Void)?

    /// 让接下来 `count` 次 `products(forIdentifiers:)` 抛 `error`（默认 `storeProblemError`），之后照常返回。
    func scriptProductsFailures(_ count: Int, error: (any Error)? = nil) {
        productsFailuresRemaining = count
        if let error { productsFailureError = error }
    }

    func setProductsHook(_ hook: (@Sendable (Set<String>) async -> Void)?) {
        productsHook = hook
    }

    func products(forIdentifiers identifiers: Set<String>) async throws -> [any StoreProductType] {
        productsCallCount += 1
        productsRequests.append(identifiers)
        if let productsHook { await productsHook(identifiers) }
        if productsFailuresRemaining > 0 {
            productsFailuresRemaining -= 1
            throw productsFailureError
        }
        return identifiers.compactMap { productsByIdentifier[$0] }
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

    /// 测试脚本：purchase() 抛的错误（nil = 不抛）。优先级高于两种结果脚本，抛错时不回调钩子（与 SK2Provider 同）。
    /// **原样抛出、不经 `StoreKitErrorMapping`**：用来验证 orchestrator 对任意错误的处置
    /// （如 `CancellationError` 原样透出）。要模拟 SK2Provider 的产出，就把映射后的 `PurchasesError` 交进来。
    private var purchaseError: (any Error)?

    func scriptPurchaseError(_ error: (any Error)?) {
        purchaseError = error
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
        if let purchaseError { throw purchaseError }
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
