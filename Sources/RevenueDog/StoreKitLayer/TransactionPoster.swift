//
//  TransactionPoster.swift
//  交易上报 + finish 裁决（设计 §3 铁律 P2/P7/P8；坑矩阵裁决 #7/#8/#12）。
//
//  finish 三铁律（RC `shouldFinish` + 我们的收紧）：
//  1. 只有「本次后端 2xx 响应」（source=backend200）允许触发 finish —— stale 缓存 / 本地推算永不 finish（#7）。
//  2. 消耗型 / 非订阅：必须在响应 `non_subscriptions` 里看到该 transactionId 才 finish。
//  3. 失败侧映射（#8）：确定性 4xx（除 404/429）→ finishable（重试也不会成功，交易已在服务端 raw 留档）；
//     5xx / 网络 / 超时 → 绝不 finish，保留上下文等待重放。
//  revoked / 已过期 / isUpgraded 交易走同一管道，无特例（#12）。
//

import Foundation

/// 上报结果。
struct PostReceiptResult: Sendable {
    let customerInfo: CustomerInfo
    /// 本次是否执行了 finish（.myApp 模式恒 false）。
    let finished: Bool
}

/// 上报失败时的处置指令。
enum PostReceiptFailure: Error, Sendable {
    /// 确定性拒绝：finish（如允许）并删除上下文 —— 重试不会成功。
    case finishable(PurchasesError)
    /// 暂时性失败：保留上下文，交给前台重放。
    case retryable(PurchasesError)
}

actor TransactionPoster {

    private let httpClient: HTTPClient
    private let completedBy: PurchasesCompletedBy

    init(httpClient: HTTPClient, completedBy: PurchasesCompletedBy) {
        self.httpClient = httpClient
        self.completedBy = completedBy
    }

    /// 上报一笔交易。成功返回 CustomerInfo 并按铁律裁决 finish；失败返回处置指令。
    func post(
        jws: String,
        transaction: (any StoreTransactionType)?,
        productIdentifier: String,
        appUserID: String,
        context: PendingPurchaseContext?,
        appTransactionJWS: String? = nil,
        attributes: [SubscriberAttribute] = [],
    ) async -> Result<PostReceiptResult, PostReceiptFailure> {
        let body = ReceiptBody(
            fetchToken: jws,
            appUserID: appUserID,
            productID: productIdentifier,
            presentedOfferingIdentifier: context?.presentedOfferingIdentifier,
            initiationSource: (context?.initiationSource ?? .queue).rawValue,
            observerMode: completedBy == .myApp,
            appTransaction: appTransactionJWS,
            // 属性随收据「搭车」上报（RC 同款省请求手法，见 06-rc-ios-sdk-internals §2.3；
            // 契约 §2.1 的 `attributes` 字段，服务端 receipts.ts 用同一套 LWW UPSERT 落库）。
            attributes: attributes.isEmpty ? nil : attributes.wireMap,
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            return .failure(.retryable(PurchasesError(code: .unknownError,
                                                      message: "receipt body 编码失败",
                                                      underlyingError: error)))
        }

        do {
            let response = try await httpClient.perform(.postReceipt, body: data, as: CustomerInfoWireModel.self)
            let info = CustomerInfo(wireModel: response.body)
            let finished = await finishIfAllowed(transaction: transaction,
                                                 productIdentifier: productIdentifier,
                                                 customerInfo: info)
            return .success(PostReceiptResult(customerInfo: info, finished: finished))
        } catch let error as PurchasesError {
            return .failure(classify(error))
        } catch {
            return .failure(.retryable(PurchasesError(code: .networkError,
                                                      message: "receipt 上报未知失败",
                                                      underlyingError: error)))
        }
    }

    /// 铁律 P2 + #7/#8：本函数只会被「后端 2xx」路径调用（编译期由调用点保证，运行期再断言）。
    private func finishIfAllowed(
        transaction: (any StoreTransactionType)?,
        productIdentifier: String,
        customerInfo: CustomerInfo,
    ) async -> Bool {
        guard completedBy == .revenueDog else { return false } // .myApp：宿主自管 finish
        guard let transaction else { return false }            // 重放路径无交易对象（仅 JWS）时不 finish

        // 判定规则（RC shouldFinish + 裁决 #12）：
        // - 订阅型（有 expirationDate）/ 已撤销：后端 2xx 即 finish
        // - 一次性（无 expirationDate）：必须在响应 non_subscriptions 里看到该 transactionId 才 finish
        let isSubscriptionLike = transaction.expirationDate != nil || transaction.revocationDate != nil
        let confirmedNonSubscription = customerInfo.nonSubscriptionTransactionIdentifiers
            .contains(transaction.transactionIdentifier)

        if isSubscriptionLike || confirmedNonSubscription {
            await transaction.finish()
            return true
        }
        // 一次性但响应里没看到：不 finish（下次启动补投重试；服务端幂等）
        Log.warn("一次性交易未出现在响应 non_subscriptions，暂不 finish（tx=\(transaction.transactionIdentifier)）",
                 category: "poster")
        return false
    }

    /// 失败侧 finishable 映射（#8）。
    private func classify(_ error: PurchasesError) -> PostReceiptFailure {
        guard let status = error.httpStatusCode else { return .retryable(error) } // 网络/超时
        switch status {
        case 404, 408, 429: return .retryable(error)
        case 400...499: return .finishable(error)
        default: return .retryable(error)
        }
    }
}

/// `POST /v1/receipts` 请求体（契约 §2.1 P0 子集；fetch_token = SK2 JWS 原文，裁决 F8）。
private struct ReceiptBody: Encodable {
    let fetchToken: String
    let appUserID: String
    let productID: String
    let presentedOfferingIdentifier: String?
    let initiationSource: String
    let observerMode: Bool
    /// restore 契约 C（裁决 C2-C）：AppTransaction JWS，后端凭它拉全量历史。
    let appTransaction: String?
    /// 搭车上报的 subscriber attributes（契约 §2.1 `attributes`）。空时整字段省略。
    let attributes: [String: SubscriberAttributeWire]?

    enum CodingKeys: String, CodingKey {
        case fetchToken = "fetch_token"
        case appUserID = "app_user_id"
        case productID = "product_id"
        case presentedOfferingIdentifier = "presented_offering_identifier"
        case initiationSource = "initiation_source"
        case observerMode = "observer_mode"
        case appTransaction = "app_transaction"
        case attributes
    }
}
