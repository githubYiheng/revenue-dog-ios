//
//  Models.swift
//  后端响应模型 + 容错解码（设计 §8「必抄」：后端加枚举值不摔老 SDK）。
//
//  分层：
//    - `*WireModel`：与 api-contract-v1 §2 逐字段对齐的内部 DTO，只负责解码容错。
//    - `CustomerInfo` / `EntitlementInfo` / `Offerings`：公开模型，由 DTO 计算出来。
//      （契约 §2.2 明确：EntitlementInfo 的 store/period_type/... 是从
//       `subscriptions[product_identifier]` 关联算出来的，后端不下发。）
//

import Foundation

// MARK: - 时间格式（契约 §1.7）

/// ISO 8601 UTC。REST 平面是**秒精度**，但解析要容忍带小数秒。
enum WireDate {

    private static let secondsStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func parse(_ string: String) -> Date? {
        if let date = try? secondsStyle.parse(string) { return date }
        return try? fractionalStyle.parse(string)
    }

    static func format(_ date: Date) -> String {
        secondsStyle.format(date)
    }
}

/// 只负责「ISO 字符串 ↔ Date」的容错载体：解析失败 → nil，绝不整体失败。
struct WireDateValue: Codable, Sendable, Equatable {

    let date: Date?
    let rawValue: String?

    init(date: Date?) {
        self.date = date
        self.rawValue = date.map(WireDate.format)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.date = nil
            self.rawValue = nil
            return
        }
        guard let raw = try? container.decode(String.self) else {
            // 后端换了形状（例如给了数字）——降级为 nil，不摔整个响应。
            self.date = nil
            self.rawValue = nil
            return
        }
        self.rawValue = raw
        self.date = WireDate.parse(raw)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let rawValue { try container.encode(rawValue) } else { try container.encodeNil() }
    }
}

/// 契约里标注「**不可缺失**」的日期字段（`first_seen` 等）。
///
/// 与 `WireDateValue` 的差别：**没有** `KeyedDecodingContainer` 的缺省重载 ——
/// 键缺失 = 后端破契约 = 整体解码失败；值本身格式坏掉仍降级为 nil。
struct RequiredWireDateValue: Codable, Sendable, Equatable {

    private let wrapped: WireDateValue

    var date: Date? { wrapped.date }
    var rawValue: String? { wrapped.rawValue }

    init(date: Date?) { self.wrapped = WireDateValue(date: date) }

    init(from decoder: any Decoder) throws {
        self.wrapped = try WireDateValue(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}

// MARK: - 容错解码属性包装器（设计 §8）

/// 为 `@DefaultDecodable` 提供缺省值的来源。
protocol DecodableDefaultSource {
    associatedtype Value: Codable & Sendable & Equatable
    static var defaultValue: Value { get }
}

/// 字段缺失 / 为 null / 类型不匹配 → 回落到 `Source.defaultValue`。
@propertyWrapper
struct DefaultDecodable<Source: DecodableDefaultSource>: Codable, Sendable, Equatable {

    var wrappedValue: Source.Value

    init(wrappedValue: Source.Value) { self.wrappedValue = wrappedValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = (try? container.decode(Source.Value.self)) ?? Source.defaultValue
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// 单字段解码失败 → nil，整个响应照常解出来。
@propertyWrapper
struct IgnoreDecodeErrors<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {

    var wrappedValue: Value?

    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
            return
        }
        wrappedValue = try? container.decode(Value.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

extension KeyedDecodingContainer {

    /// 关键：键**缺失**时也要走缺省值（Codable 默认会抛 keyNotFound）。
    func decode<Source>(_ type: DefaultDecodable<Source>.Type,
                        forKey key: Key) throws -> DefaultDecodable<Source> {
        (try? decodeIfPresent(type, forKey: key)) ?? DefaultDecodable(wrappedValue: Source.defaultValue)
    }

    func decode<Value>(_ type: IgnoreDecodeErrors<Value>.Type,
                       forKey key: Key) throws -> IgnoreDecodeErrors<Value> {
        (try? decodeIfPresent(type, forKey: key)) ?? IgnoreDecodeErrors(wrappedValue: nil)
    }

    func decode(_ type: WireDateValue.Type, forKey key: Key) throws -> WireDateValue {
        (try? decodeIfPresent(type, forKey: key)) ?? WireDateValue(date: nil)
    }
}

/// 常用缺省值来源。
enum DecodableDefaults {

    struct False: DecodableDefaultSource {
        static var defaultValue: Bool { false }
    }

    struct True: DecodableDefaultSource {
        static var defaultValue: Bool { true }
    }

    struct EmptyString: DecodableDefaultSource {
        static var defaultValue: String { "" }
    }

    struct EmptyArray<Element: Codable & Sendable & Equatable>: DecodableDefaultSource {
        static var defaultValue: [Element] { [] }
    }

    struct EmptyDictionary<Value: Codable & Sendable & Equatable>: DecodableDefaultSource {
        static var defaultValue: [String: Value] { [:] }
    }
}

// MARK: - 枚举替身（设计 §1「禁 public enum」）

/// 商店。REST 平面小写（契约 §1.8）；解析大小写不敏感；未知值 → `.unknown`。
public struct Store: Sendable, Hashable, Codable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }

    public static let appStore = Store(rawValue: "app_store")
    public static let macAppStore = Store(rawValue: "mac_app_store")
    public static let playStore = Store(rawValue: "play_store")
    public static let amazon = Store(rawValue: "amazon")
    public static let stripe = Store(rawValue: "stripe")
    public static let promotional = Store(rawValue: "promotional")
    public static let roku = Store(rawValue: "roku")
    public static let paddle = Store(rawValue: "paddle")
    public static let unknown = Store(rawValue: "unknown")

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: (try? container.decode(String.self)) ?? Store.unknown.rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

extension Store: DecodableDefaultSource {
    static var defaultValue: Store { .unknown }
}

/// 周期类型。REST 平面小写 `normal` / `trial` / `intro`（契约 §1.8）。
public struct PeriodType: Sendable, Hashable, Codable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }

    public static let normal = PeriodType(rawValue: "normal")
    public static let trial = PeriodType(rawValue: "trial")
    public static let intro = PeriodType(rawValue: "intro")
    public static let prepaid = PeriodType(rawValue: "prepaid")
    public static let unknown = PeriodType(rawValue: "unknown")

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: (try? container.decode(String.self)) ?? PeriodType.unknown.rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

extension PeriodType: DecodableDefaultSource {
    static var defaultValue: PeriodType { .normal }
}

/// 所有权。契约 §1.8：大写 `PURCHASED` / `FAMILY_SHARED`。
public struct OwnershipType: Sendable, Hashable, Codable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }

    public static let purchased = OwnershipType(rawValue: "PURCHASED")
    public static let familyShared = OwnershipType(rawValue: "FAMILY_SHARED")
    public static let unknown = OwnershipType(rawValue: "UNKNOWN")

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: (try? container.decode(String.self)) ?? OwnershipType.unknown.rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

extension OwnershipType: DecodableDefaultSource {
    static var defaultValue: OwnershipType { .purchased }
}

// MARK: - 金额（裁决 F2）

/// 金额一律 `Decimal`；**wire 上一律字符串**（`NSDecimalNumber.description` 保精度），
/// 但解码必须同时接受字符串与数字。
public struct Money: Sendable, Hashable, Codable, CustomStringConvertible {

    public let amount: Decimal
    public let currency: String

    public init(amount: Decimal, currency: String) {
        self.amount = amount
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey {
        case amount
        case currency
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.amount = try Money.decodeDecimal(from: container, forKey: .amount) ?? 0
        self.currency = (try? container.decode(String.self, forKey: .currency)) ?? "USD"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // 上行一律字符串。
        try container.encode(Money.decimalString(amount), forKey: .amount)
        try container.encode(currency, forKey: .currency)
    }

    public var description: String { "\(Money.decimalString(amount)) \(currency)" }

    /// `NSDecimalNumber.description` —— 与后端 `decimalStringFromMicros` 的输出形状一致。
    public static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: nil as Locale?)
    }

    /// 字符串 **或** 数字 → Decimal（裁决 F2：两种都必须接受）。
    static func decodeDecimal<K: CodingKey>(from container: KeyedDecodingContainer<K>,
                                           forKey key: K) throws -> Decimal? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return Decimal(string: string, locale: nil as Locale?)
        }
        if let decimal = try? container.decodeIfPresent(Decimal.self, forKey: key) {
            return decimal
        }
        return nil
    }
}

/// 「字符串或数字 → Decimal」的属性包装器。
@propertyWrapper
struct DecimalStringOrNumber: Codable, Sendable, Equatable {

    var wrappedValue: Decimal?

    init(wrappedValue: Decimal?) { self.wrappedValue = wrappedValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
            return
        }
        if let string = try? container.decode(String.self) {
            wrappedValue = Decimal(string: string, locale: nil as Locale?)
            return
        }
        wrappedValue = try? container.decode(Decimal.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(Money.decimalString(wrappedValue))
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {

    func decode(_ type: DecimalStringOrNumber.Type, forKey key: Key) throws -> DecimalStringOrNumber {
        (try? decodeIfPresent(type, forKey: key)) ?? DecimalStringOrNumber(wrappedValue: nil)
    }
}

// MARK: - Wire DTO：GET /v1/subscribers/{id}（契约 §2.2）

struct CustomerInfoWireModel: Codable, Sendable, Equatable {

    /// 契约：必填。
    let requestDate: WireDateValue
    let requestDateMs: Int64?
    let subscriber: SubscriberWireModel

    enum CodingKeys: String, CodingKey {
        case requestDate = "request_date"
        case requestDateMs = "request_date_ms"
        case subscriber
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestDate = try container.decode(WireDateValue.self, forKey: .requestDate)
        self.requestDateMs = try? container.decodeIfPresent(Int64.self, forKey: .requestDateMs)
        // subscriber 缺失 = 真·破契约，允许整体失败。
        self.subscriber = try container.decode(SubscriberWireModel.self, forKey: .subscriber)
    }
}

struct SubscriberWireModel: Codable, Sendable, Equatable {

    /// 契约明确：**不可缺失**，缺失整个响应解码失败。
    let originalAppUserID: String
    /// 同上，不可缺失。
    let firstSeen: RequiredWireDateValue
    let lastSeen: WireDateValue
    @IgnoreDecodeErrors var managementURL: String?
    @DefaultDecodable<DecodableDefaults.EmptyDictionary<EntitlementWireModel>>
    var entitlements: [String: EntitlementWireModel]
    @DefaultDecodable<DecodableDefaults.EmptyDictionary<SubscriptionWireModel>>
    var subscriptions: [String: SubscriptionWireModel]
    @DefaultDecodable<DecodableDefaults.EmptyDictionary<[NonSubscriptionWireModel]>>
    var nonSubscriptions: [String: [NonSubscriptionWireModel]]
    @IgnoreDecodeErrors var originalApplicationVersion: String?
    let originalPurchaseDate: WireDateValue
    /// 只在 secret key 请求时返回；SDK（public key）永远拿不到，保留字段以便宽容解码。
    @DefaultDecodable<DecodableDefaults.EmptyDictionary<SubscriberAttributeWireModel>>
    var subscriberAttributes: [String: SubscriberAttributeWireModel]

    enum CodingKeys: String, CodingKey {
        case originalAppUserID = "original_app_user_id"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case managementURL = "management_url"
        case entitlements
        case subscriptions
        case nonSubscriptions = "non_subscriptions"
        case originalApplicationVersion = "original_application_version"
        case originalPurchaseDate = "original_purchase_date"
        case subscriberAttributes = "subscriber_attributes"
    }
}

/// 契约 §2.2：entitlement **只有 4 个字段**，其余语义从 subscriptions 关联算。
struct EntitlementWireModel: Codable, Sendable, Equatable {

    let expiresDate: WireDateValue
    let gracePeriodExpiresDate: WireDateValue
    @DefaultDecodable<DecodableDefaults.EmptyString> var productIdentifier: String
    let purchaseDate: WireDateValue

    enum CodingKeys: String, CodingKey {
        case expiresDate = "expires_date"
        case gracePeriodExpiresDate = "grace_period_expires_date"
        case productIdentifier = "product_identifier"
        case purchaseDate = "purchase_date"
    }
}

struct SubscriptionWireModel: Codable, Sendable, Equatable {

    let expiresDate: WireDateValue
    let purchaseDate: WireDateValue
    let originalPurchaseDate: WireDateValue
    @DefaultDecodable<Store> var store: Store
    @DefaultDecodable<DecodableDefaults.False> var isSandbox: Bool
    @DefaultDecodable<PeriodType> var periodType: PeriodType
    @DefaultDecodable<OwnershipType> var ownershipType: OwnershipType
    let unsubscribeDetectedAt: WireDateValue
    let billingIssuesDetectedAt: WireDateValue
    let gracePeriodExpiresDate: WireDateValue
    let refundedAt: WireDateValue
    let autoResumeDate: WireDateValue
    @IgnoreDecodeErrors var storeTransactionID: String?
    @IgnoreDecodeErrors var displayName: String?
    @IgnoreDecodeErrors var price: Money?
    @IgnoreDecodeErrors var productPlanIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case expiresDate = "expires_date"
        case purchaseDate = "purchase_date"
        case originalPurchaseDate = "original_purchase_date"
        case store
        case isSandbox = "is_sandbox"
        case periodType = "period_type"
        case ownershipType = "ownership_type"
        case unsubscribeDetectedAt = "unsubscribe_detected_at"
        case billingIssuesDetectedAt = "billing_issues_detected_at"
        case gracePeriodExpiresDate = "grace_period_expires_date"
        case refundedAt = "refunded_at"
        case autoResumeDate = "auto_resume_date"
        case storeTransactionID = "store_transaction_id"
        case displayName = "display_name"
        case price
        case productPlanIdentifier = "product_plan_identifier"
    }
}

struct NonSubscriptionWireModel: Codable, Sendable, Equatable {

    @DefaultDecodable<DecodableDefaults.EmptyString> var id: String
    let purchaseDate: WireDateValue
    let originalPurchaseDate: WireDateValue
    @DefaultDecodable<Store> var store: Store
    @IgnoreDecodeErrors var storeTransactionID: String?
    @DefaultDecodable<DecodableDefaults.False> var isSandbox: Bool
    @IgnoreDecodeErrors var displayName: String?
    @IgnoreDecodeErrors var price: Money?

    enum CodingKeys: String, CodingKey {
        case id
        case purchaseDate = "purchase_date"
        case originalPurchaseDate = "original_purchase_date"
        case store
        case storeTransactionID = "store_transaction_id"
        case isSandbox = "is_sandbox"
        case displayName = "display_name"
        case price
    }
}

struct SubscriberAttributeWireModel: Codable, Sendable, Equatable {

    @IgnoreDecodeErrors var value: String?
    @IgnoreDecodeErrors var updatedAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case value
        case updatedAtMs = "updated_at_ms"
    }
}

// MARK: - Wire DTO：GET /v1/subscribers/{id}/offerings（契约 §2.3）

struct OfferingsWireModel: Codable, Sendable, Equatable {

    @IgnoreDecodeErrors var currentOfferingID: String?
    @DefaultDecodable<DecodableDefaults.EmptyArray<OfferingWireModel>> var offerings: [OfferingWireModel]

    enum CodingKeys: String, CodingKey {
        case currentOfferingID = "current_offering_id"
        case offerings
    }
}

struct OfferingWireModel: Codable, Sendable, Equatable {

    @DefaultDecodable<DecodableDefaults.EmptyString> var identifier: String
    @DefaultDecodable<DecodableDefaults.EmptyString> var description: String
    @DefaultDecodable<DecodableDefaults.EmptyArray<PackageWireModel>> var packages: [PackageWireModel]

    enum CodingKeys: String, CodingKey {
        case identifier
        case description
        case packages
    }
}

struct PackageWireModel: Codable, Sendable, Equatable {

    @DefaultDecodable<DecodableDefaults.EmptyString> var identifier: String
    @DefaultDecodable<DecodableDefaults.EmptyString> var platformProductIdentifier: String

    enum CodingKeys: String, CodingKey {
        case identifier
        case platformProductIdentifier = "platform_product_identifier"
    }
}

// MARK: - Wire DTO：错误体（契约 §1.4）

struct BackendErrorWireModel: Codable, Sendable, Equatable {

    @IgnoreDecodeErrors var code: Int?
    @DefaultDecodable<DecodableDefaults.EmptyString> var message: String

    enum CodingKeys: String, CodingKey {
        case code
        case message
    }
}

// MARK: - 公开模型：EntitlementInfo

public struct EntitlementInfo: Sendable, Hashable, Codable {

    public let identifier: String
    public let productIdentifier: String
    /// 该产品最近一次购买/续订时间。
    public let latestPurchaseDate: Date?
    public let originalPurchaseDate: Date?
    /// 终身权益为 nil。
    public let expirationDate: Date?
    public let gracePeriodExpiresDate: Date?
    /// 以下四项来自关联的 `subscriptions[product_identifier]`（契约 §2.2 明确）。
    public let store: Store
    public let periodType: PeriodType
    public let ownershipType: OwnershipType
    public let isSandbox: Bool
    public let unsubscribeDetectedAt: Date?
    public let billingIssueDetectedAt: Date?
    /// 响应的服务端时间，用于 3 天 grace 的到期判定（设计 §4）。
    public let requestDate: Date?

    /// 非订阅（一次性购买）授予的权益。
    public var isLifetime: Bool { expirationDate == nil }

    /// 检测到关闭自动续订，但订阅可能仍有效（以 expirationDate 为准）。
    public var willRenew: Bool {
        guard expirationDate != nil else { return false }
        return unsubscribeDetectedAt == nil && billingIssueDetectedAt == nil
    }

    /// 权益是否有效。
    ///
    /// `referenceDate` 由 `EntitlementGracePolicy.referenceDate(requestDate:now:)` 给出
    /// ——3 天内用服务端时间，超 3 天回落本地时钟（设计 §4）。
    public func isActive(referenceDate: Date) -> Bool {
        if let gracePeriodExpiresDate, gracePeriodExpiresDate > referenceDate { return true }
        guard let expirationDate else { return true }
        return expirationDate > referenceDate
    }
}

public struct EntitlementInfos: Sendable, Hashable, Codable {

    public let all: [String: EntitlementInfo]
    /// 服务端时间（`request_date`），供 3 天 grace 判定使用。
    public let requestDate: Date?

    public init(all: [String: EntitlementInfo], requestDate: Date?) {
        self.all = all
        self.requestDate = requestDate
    }

    public subscript(identifier: String) -> EntitlementInfo? { all[identifier] }

    /// 当前有效的权益（按设计 §4 的 3 天 grace 决定参照时间）。
    public var active: [String: EntitlementInfo] {
        active(now: Date())
    }

    public func active(now: Date) -> [String: EntitlementInfo] {
        let reference = EntitlementGracePolicy.referenceDate(requestDate: requestDate, now: now)
        return all.filter { $0.value.isActive(referenceDate: reference) }
    }
}

// MARK: - 公开模型：CustomerInfo

public struct CustomerInfo: Sendable, Hashable, Codable {

    public let originalAppUserID: String
    public let firstSeen: Date?
    public let lastSeen: Date?
    public let managementURL: URL?
    public let requestDate: Date?
    public let entitlements: EntitlementInfos
    public let originalApplicationVersion: String?
    public let originalPurchaseDate: Date?
    /// 所有出现过的产品标识（订阅 + 一次性）。
    public let allPurchasedProductIdentifiers: Set<String>
    /// 活跃订阅的产品标识（按 3 天 grace 参照时间判定）。
    public let activeSubscriptionProductIdentifiers: Set<String>
    /// 非订阅交易 id（M2 消耗型 finish 判定要用：响应里见到 transactionId 才 finish）。
    public let nonSubscriptionTransactionIdentifiers: Set<String>

    init(wireModel: CustomerInfoWireModel, now: Date = Date()) {
        let subscriber = wireModel.subscriber
        let requestDate = wireModel.requestDate.date
        let reference = EntitlementGracePolicy.referenceDate(requestDate: requestDate, now: now)

        self.originalAppUserID = subscriber.originalAppUserID
        self.firstSeen = subscriber.firstSeen.date
        self.lastSeen = subscriber.lastSeen.date
        self.managementURL = subscriber.managementURL.flatMap(URL.init(string:))
        self.requestDate = requestDate
        self.originalApplicationVersion = subscriber.originalApplicationVersion
        self.originalPurchaseDate = subscriber.originalPurchaseDate.date

        var entitlements: [String: EntitlementInfo] = [:]
        for (identifier, wire) in subscriber.entitlements {
            let subscription = subscriber.subscriptions[wire.productIdentifier]
            let nonSubscription = subscriber.nonSubscriptions[wire.productIdentifier]?.last
            entitlements[identifier] = EntitlementInfo(
                identifier: identifier,
                productIdentifier: wire.productIdentifier,
                latestPurchaseDate: wire.purchaseDate.date,
                originalPurchaseDate: subscription?.originalPurchaseDate.date
                    ?? nonSubscription?.originalPurchaseDate.date,
                expirationDate: wire.expiresDate.date,
                gracePeriodExpiresDate: wire.gracePeriodExpiresDate.date,
                store: subscription?.store ?? nonSubscription?.store ?? .unknown,
                periodType: subscription?.periodType ?? .normal,
                ownershipType: subscription?.ownershipType ?? .purchased,
                isSandbox: subscription?.isSandbox ?? nonSubscription?.isSandbox ?? false,
                unsubscribeDetectedAt: subscription?.unsubscribeDetectedAt.date,
                billingIssueDetectedAt: subscription?.billingIssuesDetectedAt.date,
                requestDate: requestDate
            )
        }
        self.entitlements = EntitlementInfos(all: entitlements, requestDate: requestDate)

        var allProducts = Set(subscriber.subscriptions.keys)
        allProducts.formUnion(subscriber.nonSubscriptions.keys)
        self.allPurchasedProductIdentifiers = allProducts

        self.activeSubscriptionProductIdentifiers = Set(
            subscriber.subscriptions
                .filter { _, value in
                    guard let expires = value.expiresDate.date else { return true }
                    if let grace = value.gracePeriodExpiresDate.date, grace > reference { return true }
                    return expires > reference
                }
                .map(\.key)
        )

        self.nonSubscriptionTransactionIdentifiers = Set(
            subscriber.nonSubscriptions.values.flatMap { $0 }.map(\.id).filter { !$0.isEmpty }
        )
    }
}

// MARK: - 公开模型：Offerings

/// 包类型（禁 public enum → struct + static）。RC 默认标识带 `$rc_` 前缀（契约决策 11）。
public struct PackageType: Sendable, Hashable, Codable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let unknown = PackageType(rawValue: "unknown")
    public static let custom = PackageType(rawValue: "custom")
    public static let lifetime = PackageType(rawValue: "$rc_lifetime")
    public static let annual = PackageType(rawValue: "$rc_annual")
    public static let sixMonth = PackageType(rawValue: "$rc_six_month")
    public static let threeMonth = PackageType(rawValue: "$rc_three_month")
    public static let twoMonth = PackageType(rawValue: "$rc_two_month")
    public static let monthly = PackageType(rawValue: "$rc_monthly")
    public static let weekly = PackageType(rawValue: "$rc_weekly")

    static let known: [PackageType] = [
        .lifetime, .annual, .sixMonth, .threeMonth, .twoMonth, .monthly, .weekly,
    ]

    /// 后端下发的 package identifier → PackageType；未知的一律 `.custom`。
    static func from(identifier: String) -> PackageType {
        known.first { $0.rawValue == identifier } ?? .custom
    }

    public var description: String { rawValue }
}

public struct Package: Sendable, Hashable, Codable {

    public let identifier: String
    public let packageType: PackageType
    public let offeringIdentifier: String
    /// 商店产品标识（后端下发）。
    public let platformProductIdentifier: String
    /// StoreKit 商品详情。**M1 恒为 nil**（M2 才去 StoreKit 拉商品）。
    public let storeProduct: StoreProduct?
}

public struct Offering: Sendable, Hashable, Codable {

    public let identifier: String
    public let serverDescription: String
    public let availablePackages: [Package]

    public subscript(packageIdentifier: String) -> Package? {
        availablePackages.first { $0.identifier == packageIdentifier }
    }

    public func package(ofType type: PackageType) -> Package? {
        availablePackages.first { $0.packageType == type }
    }

    public var lifetime: Package? { package(ofType: .lifetime) }
    public var annual: Package? { package(ofType: .annual) }
    public var monthly: Package? { package(ofType: .monthly) }
    public var weekly: Package? { package(ofType: .weekly) }
}

public struct Offerings: Sendable, Hashable, Codable {

    public let all: [String: Offering]
    public let currentOfferingIdentifier: String?

    public var current: Offering? {
        currentOfferingIdentifier.flatMap { all[$0] }
    }

    public subscript(identifier: String) -> Offering? { all[identifier] }

    init(wireModel: OfferingsWireModel) {
        var offerings: [String: Offering] = [:]
        for wire in wireModel.offerings where !wire.identifier.isEmpty {
            let packages = wire.packages.map { package in
                Package(identifier: package.identifier,
                        packageType: PackageType.from(identifier: package.identifier),
                        offeringIdentifier: wire.identifier,
                        platformProductIdentifier: package.platformProductIdentifier,
                        storeProduct: nil)
            }
            offerings[wire.identifier] = Offering(identifier: wire.identifier,
                                                  serverDescription: wire.description,
                                                  availablePackages: packages)
        }
        self.all = offerings
        self.currentOfferingIdentifier = wireModel.currentOfferingID
    }
}

// MARK: - 公开模型：StoreProduct（M2 由 StoreKit 填充）

public struct StoreProduct: Sendable, Hashable, Codable {

    public let productIdentifier: String
    public let localizedTitle: String
    public let localizedDescription: String
    public let price: Decimal
    public let currencyCode: String?
    public let localizedPriceString: String

    public init(productIdentifier: String,
                localizedTitle: String,
                localizedDescription: String,
                price: Decimal,
                currencyCode: String?,
                localizedPriceString: String) {
        self.productIdentifier = productIdentifier
        self.localizedTitle = localizedTitle
        self.localizedDescription = localizedDescription
        self.price = price
        self.currencyCode = currencyCode
        self.localizedPriceString = localizedPriceString
    }
}

// MARK: - 公开模型：PurchaseResult（M2 填实）

public struct PurchaseResult: Sendable {

    public let customerInfo: CustomerInfo
    public let transactionIdentifier: String?
    public let userCancelled: Bool

    public init(customerInfo: CustomerInfo, transactionIdentifier: String?, userCancelled: Bool) {
        self.customerInfo = customerInfo
        self.transactionIdentifier = transactionIdentifier
        self.userCancelled = userCancelled
    }
}
