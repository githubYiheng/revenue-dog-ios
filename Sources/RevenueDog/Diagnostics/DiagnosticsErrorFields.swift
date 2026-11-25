//
//  DiagnosticsErrorFields.swift
//  失败类诊断事件的**统一原因字段**（ADR 0243 决定 5；契约 `docs/plan/sdk-diagnostics.md` §8，
//  `error_class` 的词汇与判定顺序见 §1.3）。与 Android `DiagnosticsErrorFields` 同名、同键、同判定顺序。
//
//  起因：0.5.0 及以前五个失败事件各自只写 `error_code`，不是 `PurchasesError` 的错误一律落 `unknownError`；
//  生产上一类购买失败在诊断里只剩一个 `unknownError`，原错误（`InvalidRequestError` 1002）只能去宿主日志里找。
//
//  走这里的五个事件：`identity_login` / `identity_logout`、`customer_info_fetch`、`offerings_fetch`、
//  `purchase_result`、`restore` / `sync`。**`receipt_post` / `http_error` 不经这里**
//  （`DiagnosticsRecorder.recordHTTPAttempt`，巡检 18 / 19 与 `launch-sync` 逐字依赖它们的 `error_class`）。
//
//  不进这些字段（契约 §1.3 的红线）：任何错误文案（SDK 的、Apple 的都不带）、邮箱、姓名、设备名、token / 密钥、
//  请求或响应 body。`underlying` 是类别名，`store_error_code` 是整数 —— README「不上传错误消息文本」的承诺不变。
//

import Foundation

enum DiagnosticsErrorFields {

    // MARK: 字段名

    static let keyErrorCode = "error_code"
    /// 契约 §1.3 的提列名就是 `status`。
    static let keyStatus = "status"
    /// 契约 §1.4 错误体里的数值码（例如 7243）。
    static let keyBackendCode = "backend_code"
    static let keyErrorClass = "error_class"
    /// 最里层原错误的类别名（`StoreKitErrorMapping.underlyingName`），不带文案。
    static let keyUnderlying = "underlying"
    /// **iOS 专属**：StoreKit 错误值自带的整数码（今天只有 `InvalidRequestError.code`），对应 Android 的 `billing_response_code`。
    static let keyStoreErrorCode = "store_error_code"

    // MARK: error_class 取值（全端唯一一套词汇，契约 §1.3）

    /// 传输层失败：连不上、断网。
    static let network = DiagnosticsErrorClass.network
    /// 传输层失败且原错误是超时。码位同样是 `networkError`，排查方向不同，所以单列。
    static let timeout = "timeout"
    /// 401 / 403。与 `client` / `server` 一起**就是** `DiagnosticsErrorClass.from` 的原口径。
    static let auth = DiagnosticsErrorClass.auth
    static let client = DiagnosticsErrorClass.client
    static let server = DiagnosticsErrorClass.server
    /// 商店计费链路（StoreKit）的失败。带商店错误码时具体值看 `store_error_code`。
    static let billing = "billing"
    /// 响应不是我们要的形状（解码失败 / 缓存里没有）。
    static let parse = "parse"
    /// 接线或用法问题：宿主改代码才能修。
    static let config = "config"
    /// 以上都不是。出现得多就说明码位集合该补了。
    static let unknown = "unknown"

    /// 全集。单测拿它断言 `classify` 不会返回表外的值。
    static let allClasses: [String] = [network, timeout, auth, client, server, billing, parse, config, unknown]

    // MARK: 入口

    /// 一个失败诊断该附的全部原因字段。没有错误时一个键都不出；值为 nil 的键由 `DiagnosticsEvent.make` 丢掉。
    static func of(_ error: (any Error)?) -> [String: DiagnosticsFieldValue?] {
        guard let error else { return [:] }
        let purchasesError = error as? PurchasesError
        return [
            keyErrorCode: .string(errorCodeName(error)),
            keyStatus: purchasesError?.httpStatusCode.map { .int($0) },
            keyBackendCode: purchasesError?.backendCode.map { .int($0) },
            keyErrorClass: .string(classify(error)),
            keyUnderlying: StoreKitErrorMapping.underlyingName(of: error).map { .string($0) },
            keyStoreErrorCode: storeErrorCode(of: error).map { .int($0) },
        ]
    }

    /// 把原因字段并进调用点已有的字段：**调用点的非 nil 值优先、一个字不动**（`status`、`request_id` 等），
    /// 这里只补缺。`error == nil` 时原样返回。
    static func merging(_ fields: [String: DiagnosticsFieldValue?],
                        error: (any Error)?) -> [String: DiagnosticsFieldValue?] {
        var merged = fields
        for (key, value) in of(error) {
            guard let value else { continue }
            if case .some(.some) = merged[key] { continue }
            merged[key] = value
        }
        return merged
    }

    /// SDK 自己的错误码名（`error_code` 的口径，0.5.0 起不变）：`PurchasesError` 取 `code.name`，其余一律 `unknownError`。
    /// `offerings_fetch.products_error_code` 与 `products_fetch_failed` 的 detail 也用它。
    static func errorCodeName(_ error: any Error) -> String {
        (error as? PurchasesError)?.code.name ?? PurchasesErrorCode.unknownError.name
    }

    /// 顺着包装链找商店错误码：外层先，再逐层往里（只有 `StoreKitErrorMapping` 会填它）。
    static func storeErrorCode(of error: any Error) -> Int64? {
        StoreKitErrorMapping.chain(of: error).layers.lazy.compactMap(\.storeErrorCode).first
    }

    // MARK: 分类

    /// **唯一**的分类函数（这五个事件只有这一处推 `error_class`）。判定顺序与 Android `classify` 相同，
    /// 从「证据最硬」排到「只能靠码位猜」：
    /// 1. 带商店错误码 → `billing`；
    /// 2. 最里层原错误是超时（`URLError.timedOut`）→ `timeout`（它的码位也是 `networkError`，必须排在 ③ 前面）；
    /// 3. 码位是网络类 → `network`；
    /// 4. 有 HTTP 状态码 → 交给 `DiagnosticsErrorClass.from`（401/403 = `auth`、其余 4xx = `client`、5xx = `server`）；
    /// 5.–7. 按码位归 `parse` / `config` / `billing`；8. 都落不上 → `unknown`。
    ///
    /// 不是 `PurchasesError` 的错误按 `unknownError` 码位走同一顺序（只有 ② 可能命中，如裸 `URLError(.timedOut)`）。
    static func classify(_ error: any Error) -> String {
        let purchasesError = error as? PurchasesError
        let code = purchasesError?.code ?? .unknownError
        if storeErrorCode(of: error) != nil { return billing }
        if isTimeout(error) { return timeout }
        if networkCodes.contains(code) { return network }
        if let statusCode = purchasesError?.httpStatusCode { return DiagnosticsErrorClass.from(statusCode: statusCode) }
        if parseCodes.contains(code) { return parse }
        if configCodes.contains(code) { return config }
        if billingCodes.contains(code) { return billing }
        return unknown
    }

    /// 按原错误的类型判，不按文案判：文案随系统语言变，`URLError.Code` 不会。
    private static func isTimeout(_ error: any Error) -> Bool {
        guard let root = StoreKitErrorMapping.chain(of: error).root else { return false }
        return (root as? URLError)?.code == .timedOut
    }

    // 四个码位集合与 Android `NETWORK_CODES` / `PARSE_CODES` / `CONFIG_CODES` / `BILLING_CODES` 逐项对应；
    // Android 的 `PaymentPendingError`（20）iOS 没有这个码位，其余一一同名。

    private static let networkCodes: Set<PurchasesErrorCode> = [
        .networkError,
        .offlineConnectionError,
    ]

    private static let parseCodes: Set<PurchasesErrorCode> = [
        .unexpectedBackendResponseError,
        // 「缓存里没有 CustomerInfo」也走它 —— 拿到了东西但用不了。
        .customerInfoError,
    ]

    private static let configCodes: Set<PurchasesErrorCode> = [
        .configurationError,
        .unsupportedError,
        .notImplementedError,
        // 没带 HTTP 状态码时来自端上守卫（logIn 传了空 id / 已是匿名还 logOut）= 用法问题。
        .invalidAppUserIdError,
        .invalidCredentialsError,
        .operationAlreadyInProgressError,
        .invalidAppleSubscriptionKeyError,
        .emptySubscriberAttributesError,
    ]

    /// 端上自己判定的商店语义错误（StoreKit 层映射出的码位、恢复时的取消等）。
    private static let billingCodes: Set<PurchasesErrorCode> = [
        .storeProblemError,
        .purchaseNotAllowedError,
        .purchaseCancelledError,
        .purchaseInvalidError,
        .productNotAvailableForPurchaseError,
        .productAlreadyPurchasedError,
        .productDiscountMissingIdentifierError,
    ]
}
