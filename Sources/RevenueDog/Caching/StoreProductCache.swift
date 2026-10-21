//
//  StoreProductCache.swift
//  进程内商品缓存（0.4.4，ADR 0155 第 2、3 条）。
//
//  对照 RC：`CachingProductsManager`（键 = 商品 id、成功才写、部分也写、不做负缓存、无 TTL、
//  storefront 变化清空）；「代号」照 RC PR #8084 的修法，堵「清缓存后在途旧请求写回旧数据」。
//

import Foundation

/// 进程内 StoreKit 商品缓存。值类型，由 `PurchasesOrchestrator`（actor）独占持有，不需要锁。
///
/// 规则（ADR 0155 第 2 条）：
/// - 键 = 商品 id；只写 StoreKit **成功**返回的商品（部分查到也写查到的那部分）；
///   查不到的不写（不做负缓存 —— ASC 刚过审的商品下次自然补上）；抛错什么都不写。
/// - 无过期，进程生命周期内有效。
/// - **storefront 变化即整体失效**：每次读取前 `validate(storefrontID:)`（读取时比对，不监听
///   `Storefront.updates`），与缓存所属的 storefront 不同 → 清空并 `generation += 1`。
///   读不到 storefront（nil）视为「未知」：不失效、不覆盖已记录的值；只有「非 nil → 另一个非 nil」才失效。
/// - `generation`（代号）：发 StoreKit 请求时记下当时的代号，返回后 `store(_:generation:)` 发现代号已变
///   （期间失效过）就丢弃不写。
///
/// 存的是商店层商品（`any StoreProductType`），**不是**公开模型 `StoreProduct`：
/// `StoreProduct.introductoryOffer.isEligible` 是**当下** Apple ID 的资格（买过就变），
/// 冻进缓存会让同一进程里买完之后付费墙仍显示「可免费试用」。组装时照旧 `makeStoreProduct()`
/// 现查资格（与 0.4.3 行为一致；RC 同样只缓存商店商品，资格另查）。
struct StoreProductCache: Sendable {

    /// 当前代号。storefront 失效一次 +1。
    private(set) var generation = 0
    /// 缓存内容所属的 storefront。nil = 还没观察到过一个确定的值。
    private var storefrontID: String?
    private var productsByIdentifier: [String: any StoreProductType] = [:]

    /// 读取前校验 storefront：与缓存所属的不同 → 整体失效（清空 + 代号 +1）。返回是否发生了失效。
    ///
    /// - 读不到（nil）= 未知：不失效、不覆盖已记录的值（`Storefront.current` 偶发读不到不该把缓存冲掉）；
    /// - 第一次读到确定值只记录、不算失效；
    /// - 只有「已记录的非 nil → 另一个非 nil」才失效。
    @discardableResult
    mutating func validate(storefrontID current: String?) -> Bool {
        guard let current else { return false }
        defer { storefrontID = current }
        guard let recorded = storefrontID, recorded != current else { return false }
        productsByIdentifier.removeAll()
        generation += 1
        return true
    }

    /// 取缓存里命中的那部分（调用方各自拿自己的快照组装，见 ADR 0155 第 3 条）。
    func products(for identifiers: Set<String>) -> [String: any StoreProductType] {
        var hits: [String: any StoreProductType] = [:]
        for identifier in identifiers {
            if let product = productsByIdentifier[identifier] { hits[identifier] = product }
        }
        return hits
    }

    /// 写入 StoreKit 成功返回的商品。`generation` 是发请求时的代号；不等 = 期间 storefront 变过，丢弃不写。
    /// 返回是否写入。同 id 重复时后者覆盖前者（#125 纪律：不 crash）。
    @discardableResult
    mutating func store(_ products: [any StoreProductType], generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        for product in products { productsByIdentifier[product.productIdentifier] = product }
        return true
    }
}
