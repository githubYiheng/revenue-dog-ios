//
//  PurchasesError.swift
//  单一错误面（设计 §1）：code + userInfo，code 命名对齐 RC ErrorCode。
//
//  「禁 public enum」：ErrorCode 用 struct + static 常量，后端加码位不摔老 SDK。
//

import Foundation

// MARK: - ErrorCode

public struct PurchasesErrorCode: Sendable, Hashable, CustomStringConvertible {

    public let rawValue: Int
    public let name: String

    internal init(rawValue: Int, name: String) {
        self.rawValue = rawValue
        self.name = name
    }

    /// 后端返回了我们不认识的码位时的兜底。
    public static func unknown(rawValue: Int) -> PurchasesErrorCode {
        PurchasesErrorCode(rawValue: rawValue, name: "unknownError")
    }

    public static let unknownError = PurchasesErrorCode(rawValue: 0, name: "unknownError")
    public static let purchaseCancelledError = PurchasesErrorCode(rawValue: 1, name: "purchaseCancelledError")
    public static let storeProblemError = PurchasesErrorCode(rawValue: 2, name: "storeProblemError")
    public static let purchaseNotAllowedError = PurchasesErrorCode(rawValue: 3, name: "purchaseNotAllowedError")
    public static let purchaseInvalidError = PurchasesErrorCode(rawValue: 4, name: "purchaseInvalidError")
    public static let productNotAvailableForPurchaseError = PurchasesErrorCode(rawValue: 5, name: "productNotAvailableForPurchaseError")
    public static let productAlreadyPurchasedError = PurchasesErrorCode(rawValue: 6, name: "productAlreadyPurchasedError")
    public static let receiptAlreadyInUseError = PurchasesErrorCode(rawValue: 7, name: "receiptAlreadyInUseError")
    public static let invalidReceiptError = PurchasesErrorCode(rawValue: 8, name: "invalidReceiptError")
    public static let missingReceiptFileError = PurchasesErrorCode(rawValue: 9, name: "missingReceiptFileError")
    public static let networkError = PurchasesErrorCode(rawValue: 10, name: "networkError")
    public static let invalidCredentialsError = PurchasesErrorCode(rawValue: 11, name: "invalidCredentialsError")
    public static let unexpectedBackendResponseError = PurchasesErrorCode(rawValue: 12, name: "unexpectedBackendResponseError")
    public static let invalidAppUserIdError = PurchasesErrorCode(rawValue: 14, name: "invalidAppUserIdError")
    public static let operationAlreadyInProgressError = PurchasesErrorCode(rawValue: 15, name: "operationAlreadyInProgressError")
    public static let unknownBackendError = PurchasesErrorCode(rawValue: 16, name: "unknownBackendError")
    public static let invalidAppleSubscriptionKeyError = PurchasesErrorCode(rawValue: 17, name: "invalidAppleSubscriptionKeyError")
    public static let configurationError = PurchasesErrorCode(rawValue: 23, name: "configurationError")
    public static let unsupportedError = PurchasesErrorCode(rawValue: 24, name: "unsupportedError")
    public static let emptySubscriberAttributesError = PurchasesErrorCode(rawValue: 25, name: "emptySubscriberAttributesError")
    public static let productDiscountMissingIdentifierError = PurchasesErrorCode(rawValue: 26, name: "productDiscountMissingIdentifierError")
    public static let customerInfoError = PurchasesErrorCode(rawValue: 28, name: "customerInfoError")
    public static let systemInfoError = PurchasesErrorCode(rawValue: 29, name: "systemInfoError")
    public static let offlineConnectionError = PurchasesErrorCode(rawValue: 35, name: "offlineConnectionError")
    /// 本 SDK 专有：M1 骨架里尚未实现的路径。
    public static let notImplementedError = PurchasesErrorCode(rawValue: 900, name: "notImplementedError")

    public var description: String { "\(name)(\(rawValue))" }
}

// MARK: - PurchasesError

public struct PurchasesError: Error, Sendable, CustomStringConvertible {

    public static let domain = "com.revenuedog.sdk"

    public let code: PurchasesErrorCode
    public let message: String
    /// 后端错误体里的数值码（契约 §1.4 的 `code`，如 7243）。
    public let backendCode: Int?
    /// HTTP 状态码（若来自网络层）。
    public let httpStatusCode: Int?
    public let userInfo: [String: String]
    public let underlyingError: (any Error)?

    public init(code: PurchasesErrorCode,
                message: String,
                backendCode: Int? = nil,
                httpStatusCode: Int? = nil,
                userInfo: [String: String] = [:],
                underlyingError: (any Error)? = nil) {
        self.code = code
        self.message = message
        self.backendCode = backendCode
        self.httpStatusCode = httpStatusCode
        self.userInfo = userInfo
        self.underlyingError = underlyingError
    }

    public var description: String {
        var parts = ["[\(code)] \(message)"]
        if let backendCode { parts.append("backend_code=\(backendCode)") }
        if let httpStatusCode { parts.append("http=\(httpStatusCode)") }
        return parts.joined(separator: " ")
    }

    public var localizedDescription: String { description }

    // MARK: 常用构造

    static func notImplemented(_ symbol: String, milestone: String) -> PurchasesError {
        PurchasesError(code: .notImplementedError,
                       message: "\(symbol) 尚未实现（计划：\(milestone)）",
                       userInfo: ["symbol": symbol, "milestone": milestone])
    }

    static func configuration(_ message: String) -> PurchasesError {
        PurchasesError(code: .configurationError, message: message)
    }

    static func network(_ message: String, underlying: (any Error)? = nil) -> PurchasesError {
        PurchasesError(code: .networkError, message: message, underlyingError: underlying)
    }

    static func decoding(_ message: String, underlying: (any Error)? = nil) -> PurchasesError {
        PurchasesError(code: .unexpectedBackendResponseError, message: message, underlyingError: underlying)
    }
}

extension PurchasesError: CustomNSError {

    public static var errorDomain: String { PurchasesError.domain }

    public var errorCode: Int { code.rawValue }

    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = userInfo
        info[NSLocalizedDescriptionKey] = description
        if let underlyingError { info[NSUnderlyingErrorKey] = underlyingError as NSError }
        return info
    }
}
