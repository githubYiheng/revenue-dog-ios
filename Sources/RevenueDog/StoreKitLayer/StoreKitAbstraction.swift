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

// MARK: - Provider

/// StoreKit 能力面。业务层只认这个协议，永远不直接碰 StoreKit 类型。
protocol StoreKitProvider: Sendable {

    func products(forIdentifiers identifiers: Set<String>) async throws -> [any StoreProductType]

    /// `Transaction.updates` —— **唯一消费者**（设计 §3 / 铁律 P1、P5）。
    func transactionUpdates() -> AsyncStream<any StoreTransactionType>

    /// `Transaction.unfinished`。铁律 P4：关键读取要带 5×300ms 重试（FB13133387），M2 实现。
    func unfinishedTransactions() async -> [any StoreTransactionType]

    /// 发起购买。M2 实现（铁律 P6：必须带 UI context）。
    func purchase(product: any StoreProductType, appAccountToken: UUID?) async throws -> StorePurchaseOutcome
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

    func purchase(product: any StoreProductType, appAccountToken: UUID?) async throws -> StorePurchaseOutcome {
        guard let sk2Product = (product as? SK2Product)?.underlying else {
            throw PurchasesError(code: .productNotAvailableForPurchaseError,
                                 message: "非 StoreKit 商品无法购买：\(product.productIdentifier)")
        }
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }

        // TODO(M2 硬化 / 坑矩阵 R7)：接入 confirmIn: UI context 注入（iOS 18.2+ / SwiftUI 17+），
        // 基线用 purchase(options:)。
        let result: Product.PurchaseResult
        do {
            result = try await sk2Product.purchase(options: options)
        } catch StoreKit.Product.PurchaseError.purchaseNotAllowed {
            throw PurchasesError(code: .purchaseNotAllowedError, message: "设备不允许购买")
        } catch let error as StoreKitError {
            if case .userCancelled = error { return .userCancelled } // 坑 #18：throw 形态的取消
            throw PurchasesError(code: .storeProblemError, message: "StoreKit 购买失败", underlyingError: error)
        }

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
        productsByIdentifier = Dictionary(uniqueKeysWithValues: products.map { ($0.productIdentifier, $0) })
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
    /// 测试脚本：下一次 purchase() 的行为。
    private var nextPurchaseOutcome: (@Sendable (String) -> StorePurchaseOutcome)?

    func setUnfinished(_ transactions: [any StoreTransactionType]) {
        unfinished = transactions
    }

    func scriptPurchase(_ outcome: @escaping @Sendable (String) -> StorePurchaseOutcome) {
        nextPurchaseOutcome = outcome
    }

    func unfinishedTransactions() async -> [any StoreTransactionType] { unfinished }

    func purchase(product: any StoreProductType, appAccountToken: UUID?) async throws -> StorePurchaseOutcome {
        guard let script = nextPurchaseOutcome else {
            throw PurchasesError(code: .storeProblemError, message: "FakeStoreKitProvider：未编排购买脚本")
        }
        return script(product.productIdentifier)
    }
}
