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
    /// 服务端签发的 32hex 账户令牌（契约决策 21）：购买时转 UUID 形状写 `appAccountToken`（#22）。
    @IgnoreDecodeErrors var accountToken: String?
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
        case accountToken = "account_token"
        case subscriberAttributes = "subscriber_attributes"
    }
}

/// 契约 §2.2：entitlement **只有 4 个字段**，其余语义从 subscriptions 关联算。
struct EntitlementWireModel: Codable, Sendable, Equatable {

    let expiresDate: WireDateValue
    let gracePeriodExpiresDate: WireDateValue
    @DefaultDecodable<DecodableDefaults.EmptyString> var productIdentifier: String
    let purchaseDate: WireDateValue
    /// 0.4.0（R7）：契约允许键缺失（老后端 / RC 形状都可能不带）；缺失回退到对应订阅上的同名字段。
    @IgnoreDecodeErrors var productPlanIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case expiresDate = "expires_date"
        case gracePeriodExpiresDate = "grace_period_expires_date"
        case productIdentifier = "product_identifier"
        case purchaseDate = "purchase_date"
        case productPlanIdentifier = "product_plan_identifier"
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

// MARK: - 共用判定规则（权益 / 订阅明细 / 活跃订阅集合只此一份，不许各写各的）

enum SubscriptionStatusRules {

    /// 有效判定：宽限期未过 → 有效；无到期（终身）→ 有效；否则到期晚于参照时间才有效。
    /// `referenceDate` 由 `EntitlementGracePolicy.referenceDate(requestDate:now:)` 给出（设计 §4）。
    static func isActive(expirationDate: Date?, gracePeriodExpiresDate: Date?, referenceDate: Date) -> Bool {
        if let gracePeriodExpiresDate, gracePeriodExpiresDate > referenceDate { return true }
        guard let expirationDate else { return true }
        return expirationDate > referenceDate
    }

    /// 会续订：有到期时间、没检测到关闭自动续订、也没检测到扣款问题。
    static func willRenew(expirationDate: Date?, unsubscribeDetectedAt: Date?, billingIssuesDetectedAt: Date?) -> Bool {
        guard expirationDate != nil else { return false }
        return unsubscribeDetectedAt == nil && billingIssuesDetectedAt == nil
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
    /// 商店侧的计划标识（0.4.0，R7）。取权益上的 `product_plan_identifier`，缺失回退到
    /// `subscriptions[productIdentifier].product_plan_identifier`；App Store 商品通常为 nil
    /// （Play 的 base plan id 才有值）。对照 RC：`EntitlementInfo.productPlanIdentifier` 同名同义。
    ///
    /// 可选类型 → 合成的 `Codable` 用 `decodeIfPresent`，0.3.x 写下的缓存照常解码（该字段为 nil）。
    public let productPlanIdentifier: String?

    /// 非订阅（一次性购买）授予的权益。
    public var isLifetime: Bool { expirationDate == nil }

    /// 检测到关闭自动续订，但订阅可能仍有效（以 expirationDate 为准）。
    public var willRenew: Bool {
        SubscriptionStatusRules.willRenew(expirationDate: expirationDate,
                                          unsubscribeDetectedAt: unsubscribeDetectedAt,
                                          billingIssuesDetectedAt: billingIssueDetectedAt)
    }

    /// 权益是否有效。
    ///
    /// `referenceDate` 由 `EntitlementGracePolicy.referenceDate(requestDate:now:)` 给出
    /// ——3 天内用服务端时间，超 3 天回落本地时钟（设计 §4）。
    public func isActive(referenceDate: Date) -> Bool {
        SubscriptionStatusRules.isActive(expirationDate: expirationDate,
                                         gracePeriodExpiresDate: gracePeriodExpiresDate,
                                         referenceDate: referenceDate)
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

// MARK: - 公开模型：SubscriptionInfo（0.4.0，R6）

/// 单个订阅商品的明细（`CustomerInfo.subscriptionsByProductIdentifier` 的值）。
///
/// 全部字段来自 `subscriber.subscriptions[productId]`（契约 §2.2），解析时一次算好；
/// `isActive` 与 `CustomerInfo.activeSubscriptionProductIdentifiers` **同一规则、同一参照时间**，
/// `willRenew` 与 `EntitlementInfo.willRenew` 同一规则（`SubscriptionStatusRules`）。
/// 对照 RC：`SubscriptionInfo`（purchases-ios 4.x+ / Dart 19 字段）逐字段同名；RC 的 `price` 本版不带
/// （后端 `price` 是服务端记账口径，不是商店价，宿主不读）。
public struct SubscriptionInfo: Sendable, Hashable, Codable {

    public let productIdentifier: String
    /// 本周期（最近一次购买 / 续订）的购买时间。
    public let purchaseDate: Date?
    public let originalPurchaseDate: Date?
    /// 到期时间；nil 只可能来自后端缺字段（订阅本应有到期）。
    public let expiresDate: Date?
    public let store: Store
    public let isSandbox: Bool
    public let periodType: PeriodType
    public let ownershipType: OwnershipType
    public let unsubscribeDetectedAt: Date?
    public let billingIssuesDetectedAt: Date?
    public let gracePeriodExpiresDate: Date?
    public let refundedAt: Date?
    public let autoResumeDate: Date?
    public let storeTransactionID: String?
    /// 商店侧的计划标识（Play base plan）；App Store 通常为 nil。
    public let productPlanIdentifier: String?
    /// 后端下发的展示名（`display_name`）。
    public let displayName: String?
    /// 订阅管理页（= 客户级 `CustomerInfo.managementURL`，后端只下发一份）。
    public let managementURL: URL?
    /// 解析时按 3 天 grace 参照时间算出的有效性（设计 §4）。
    public let isActive: Bool
    /// 有到期时间、且未检测到关闭自动续订 / 扣款问题。
    public let willRenew: Bool
    /// 响应的服务端时间（`request_date`）。
    public let requestDate: Date?

    init(productIdentifier: String,
         wire: SubscriptionWireModel,
         managementURL: URL?,
         requestDate: Date?,
         referenceDate: Date) {
        self.productIdentifier = productIdentifier
        self.purchaseDate = wire.purchaseDate.date
        self.originalPurchaseDate = wire.originalPurchaseDate.date
        self.expiresDate = wire.expiresDate.date
        self.store = wire.store
        self.isSandbox = wire.isSandbox
        self.periodType = wire.periodType
        self.ownershipType = wire.ownershipType
        self.unsubscribeDetectedAt = wire.unsubscribeDetectedAt.date
        self.billingIssuesDetectedAt = wire.billingIssuesDetectedAt.date
        self.gracePeriodExpiresDate = wire.gracePeriodExpiresDate.date
        self.refundedAt = wire.refundedAt.date
        self.autoResumeDate = wire.autoResumeDate.date
        self.storeTransactionID = wire.storeTransactionID
        self.productPlanIdentifier = wire.productPlanIdentifier
        self.displayName = wire.displayName
        self.managementURL = managementURL
        self.isActive = SubscriptionStatusRules.isActive(expirationDate: wire.expiresDate.date,
                                                         gracePeriodExpiresDate: wire.gracePeriodExpiresDate.date,
                                                         referenceDate: referenceDate)
        self.willRenew = SubscriptionStatusRules.willRenew(expirationDate: wire.expiresDate.date,
                                                           unsubscribeDetectedAt: wire.unsubscribeDetectedAt.date,
                                                           billingIssuesDetectedAt: wire.billingIssuesDetectedAt.date)
        self.requestDate = requestDate
    }
}

// MARK: - 公开模型：NonSubscriptionTransaction（0.4.0，R6）

/// 一笔非订阅（消耗型 / 非消耗型）交易，来自 `subscriber.non_subscriptions[productId][]`。
/// 对照 RC：`NonSubscriptionTransaction`（`transactionIdentifier` = 后端 `id`，与 RC 同）。
public struct NonSubscriptionTransaction: Sendable, Hashable, Codable {

    /// 后端交易 id（wire `id`）；与 `CustomerInfo.nonSubscriptionTransactionIdentifiers` 同一口径。
    public let transactionIdentifier: String
    public let productIdentifier: String
    public let purchaseDate: Date?
    public let originalPurchaseDate: Date?
    public let store: Store
    /// 商店侧交易 id（App Store `transactionId` / Play `orderId`）。
    public let storeTransactionID: String?
    public let isSandbox: Bool
    public let displayName: String?

    init(productIdentifier: String, wire: NonSubscriptionWireModel) {
        self.transactionIdentifier = wire.id
        self.productIdentifier = productIdentifier
        self.purchaseDate = wire.purchaseDate.date
        self.originalPurchaseDate = wire.originalPurchaseDate.date
        self.store = wire.store
        self.storeTransactionID = wire.storeTransactionID
        self.isSandbox = wire.isSandbox
        self.displayName = wire.displayName
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
    /// 服务端签发的账户令牌（32hex）；购买时转 UUID 写 `appAccountToken`（#22 辅助归户链）。
    let accountToken: String?

    // ---- 0.4.0（R6）：补齐 RC `CustomerInfo` 的明细字段，全部由同一份 wire 派生 ----
    //
    // 缓存兼容：`DeviceCache` 落盘的是本结构的 `Codable` 编码（不是 wire JSON）。0.3.x 写下的缓存没有
    // 下面这些键 → 自定义 `init(from:)` 用 `decodeIfPresent` 兜底为空 / nil，直到下一次拉取覆盖
    // （前台 5 分钟 TTL / 回前台刷新）。兜底期间下面的不变式对**旧缓存**不成立，这是有意的：
    // 旧缓存里没有派生所需的原始数据，编造比留空更糟。

    /// 订阅明细，键 = 订阅商品 id。不变式：`isActive == true` 的键集合 == `activeSubscriptionProductIdentifiers`。
    public let subscriptionsByProductIdentifier: [String: SubscriptionInfo]
    /// 全部非订阅交易（展平）：按 `purchaseDate` 升序（nil 排最前），同时间按 `transactionIdentifier` 升序；
    /// 跳过 `id` 为空的条目。不变式：id 集合 == `nonSubscriptionTransactionIdentifiers`。
    public let nonSubscriptionTransactions: [NonSubscriptionTransaction]
    /// 订阅商品 id → 到期时间（值可 nil）。对照 RC `expirationDate(forProductIdentifier:)` 的底表。
    public let allExpirationDates: [String: Date?]
    /// 商品 id → 购买时间（值可 nil）。键 == `allPurchasedProductIdentifiers`；
    /// 订阅取本周期 `purchase_date`，一次性商品取该商品最新一笔的 `purchase_date`。
    public let allPurchaseDates: [String: Date?]
    /// 订阅里非 nil 到期时间的最大值；没有则 nil。
    public let latestExpirationDate: Date?

    enum CodingKeys: String, CodingKey {
        case originalAppUserID
        case firstSeen
        case lastSeen
        case managementURL
        case requestDate
        case entitlements
        case originalApplicationVersion
        case originalPurchaseDate
        case allPurchasedProductIdentifiers
        case activeSubscriptionProductIdentifiers
        case nonSubscriptionTransactionIdentifiers
        case accountToken
        case subscriptionsByProductIdentifier
        case nonSubscriptionTransactions
        case allExpirationDates
        case allPurchaseDates
        case latestExpirationDate
    }

    /// 键名与 0.3.x 合成实现逐字一致（属性名）；0.4.0 新增的五个键缺失时兜底（见上）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.originalAppUserID = try container.decode(String.self, forKey: .originalAppUserID)
        self.firstSeen = try container.decodeIfPresent(Date.self, forKey: .firstSeen)
        self.lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
        self.managementURL = try container.decodeIfPresent(URL.self, forKey: .managementURL)
        self.requestDate = try container.decodeIfPresent(Date.self, forKey: .requestDate)
        self.entitlements = try container.decode(EntitlementInfos.self, forKey: .entitlements)
        self.originalApplicationVersion = try container.decodeIfPresent(String.self,
                                                                        forKey: .originalApplicationVersion)
        self.originalPurchaseDate = try container.decodeIfPresent(Date.self, forKey: .originalPurchaseDate)
        self.allPurchasedProductIdentifiers = try container.decode(Set<String>.self,
                                                                   forKey: .allPurchasedProductIdentifiers)
        self.activeSubscriptionProductIdentifiers = try container.decode(
            Set<String>.self, forKey: .activeSubscriptionProductIdentifiers)
        self.nonSubscriptionTransactionIdentifiers = try container.decode(
            Set<String>.self, forKey: .nonSubscriptionTransactionIdentifiers)
        self.accountToken = try container.decodeIfPresent(String.self, forKey: .accountToken)
        // 0.4.0 新增：旧缓存没有这些键 → 空 / nil。键在但形状坏了照常抛（缓存层会当作未命中）。
        self.subscriptionsByProductIdentifier = try container.decodeIfPresent(
            [String: SubscriptionInfo].self, forKey: .subscriptionsByProductIdentifier) ?? [:]
        self.nonSubscriptionTransactions = try container.decodeIfPresent(
            [NonSubscriptionTransaction].self, forKey: .nonSubscriptionTransactions) ?? []
        self.allExpirationDates = try container.decodeIfPresent([String: Date?].self,
                                                                forKey: .allExpirationDates) ?? [:]
        self.allPurchaseDates = try container.decodeIfPresent([String: Date?].self,
                                                              forKey: .allPurchaseDates) ?? [:]
        self.latestExpirationDate = try container.decodeIfPresent(Date.self, forKey: .latestExpirationDate)
    }

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
        self.accountToken = subscriber.accountToken

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
                requestDate: requestDate,
                productPlanIdentifier: wire.productPlanIdentifier ?? subscription?.productPlanIdentifier
            )
        }
        self.entitlements = EntitlementInfos(all: entitlements, requestDate: requestDate)

        var allProducts = Set(subscriber.subscriptions.keys)
        allProducts.formUnion(subscriber.nonSubscriptions.keys)
        self.allPurchasedProductIdentifiers = allProducts

        // 订阅明细与活跃集合**同源**：活跃集合就是明细里 isActive 的键（同一规则、同一 reference）。
        let managementURL = self.managementURL
        let subscriptions = Dictionary(uniqueKeysWithValues: subscriber.subscriptions.map { productID, wire in
            (productID, SubscriptionInfo(productIdentifier: productID,
                                         wire: wire,
                                         managementURL: managementURL,
                                         requestDate: requestDate,
                                         referenceDate: reference))
        })
        self.subscriptionsByProductIdentifier = subscriptions
        self.activeSubscriptionProductIdentifiers = Set(subscriptions.filter { $0.value.isActive }.keys)

        self.nonSubscriptionTransactionIdentifiers = Set(
            subscriber.nonSubscriptions.values.flatMap { $0 }.map(\.id).filter { !$0.isEmpty }
        )
        self.nonSubscriptionTransactions = subscriber.nonSubscriptions
            .flatMap { productID, transactions in
                transactions
                    .filter { !$0.id.isEmpty }       // 与 nonSubscriptionTransactionIdentifiers 同一过滤
                    .map { NonSubscriptionTransaction(productIdentifier: productID, wire: $0) }
            }
            .sorted(by: CustomerInfo.nonSubscriptionOrder)

        self.allExpirationDates = subscriptions.mapValues(\.expiresDate)
        self.latestExpirationDate = subscriptions.values.compactMap(\.expiresDate).max()

        // 键 == allPurchasedProductIdentifiers（订阅 ∪ 一次性）；同 id 两边都有时订阅优先。
        var purchaseDates: [String: Date?] = [:]
        for (productID, transactions) in subscriber.nonSubscriptions {
            // 「最新一笔」= 购买时间最大的那笔（不依赖后端数组顺序）；全无日期 → nil。
            purchaseDates[productID] = .some(transactions.compactMap(\.purchaseDate.date).max())
        }
        for (productID, subscription) in subscriptions {
            purchaseDates[productID] = .some(subscription.purchaseDate)
        }
        self.allPurchaseDates = purchaseDates
    }

    /// 非订阅交易的稳定顺序：`purchaseDate` 升序、nil 最前，同时间按 `transactionIdentifier` 升序。
    static func nonSubscriptionOrder(_ lhs: NonSubscriptionTransaction, _ rhs: NonSubscriptionTransaction) -> Bool {
        switch (lhs.purchaseDate, rhs.purchaseDate) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(left), .some(right)) where left != right: return left < right
        default: return lhs.transactionIdentifier < rhs.transactionIdentifier
        }
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

    init(all: [String: Offering], currentOfferingIdentifier: String?) {
        self.all = all
        self.currentOfferingIdentifier = currentOfferingIdentifier
    }

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

    /// 用 StoreKit 查回来的商品详情补 `Package.storeProduct`（M2 A 项）。
    /// 查不到的商品保持 `nil` —— 「后端配了但商店没有」在诊断事件
    /// `offerings_fetch.not_found_product_ids` 里已经有记录点，这里不再重复判定。
    func fillingStoreProducts(from products: [String: StoreProduct]) -> Offerings {
        let filled = all.mapValues { offering in
            Offering(identifier: offering.identifier,
                     serverDescription: offering.serverDescription,
                     availablePackages: offering.availablePackages.map { package in
                         Package(identifier: package.identifier,
                                 packageType: package.packageType,
                                 offeringIdentifier: package.offeringIdentifier,
                                 platformProductIdentifier: package.platformProductIdentifier,
                                 storeProduct: products[package.platformProductIdentifier])
                     })
        }
        return Offerings(all: filled, currentOfferingIdentifier: currentOfferingIdentifier)
    }

    /// 同上，入参为商品数组（按 `productIdentifier` 建索引；同 id 重复时后者覆盖前者，
    /// 与编排层逐个写字典的旧行为一致）。编排层与 SPI 工厂 `fromBackendResponse(_:products:)` 共用这一处。
    func fillingStoreProducts(_ products: [StoreProduct]) -> Offerings {
        let byIdentifier = Dictionary(products.map { ($0.productIdentifier, $0) },
                                      uniquingKeysWith: { _, last in last })
        return fillingStoreProducts(from: byIdentifier)
    }
}

// MARK: - 公开模型：订阅周期与介绍性优惠（由 StoreKit 填充，供宿主做定价文案）

/// 订阅周期。禁 public enum → 单位用 struct + static 常量（Apple 日后加单位不摔老 SDK）。
public struct SubscriptionPeriod: Sendable, Hashable, Codable, CustomStringConvertible {

    /// 周期单位。
    public struct Unit: Sendable, Hashable, Codable, CustomStringConvertible {

        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue.lowercased() }

        public static let day = Unit(rawValue: "day")
        public static let week = Unit(rawValue: "week")
        public static let month = Unit(rawValue: "month")
        public static let year = Unit(rawValue: "year")
        /// StoreKit 给出了我们还不认识的单位。
        public static let unknown = Unit(rawValue: "unknown")

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(rawValue: (try? container.decode(String.self)) ?? Unit.unknown.rawValue)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public var description: String { rawValue }
    }

    public let unit: Unit
    /// 单位数量（`value = 3` + `unit = .month` = 三个月）。
    public let value: Int

    public init(unit: Unit, value: Int) {
        self.unit = unit
        self.value = value
    }

    public var description: String { "\(value) \(unit.rawValue)" }
}

/// 介绍性优惠（首购优惠）。禁 public enum → 类型用 struct + static 常量。
public struct IntroductoryOffer: Sendable, Hashable, Codable {

    /// 优惠形态。Apple 三选一：免费试用 / 分期低价 / 一次性预付。
    public struct OfferType: Sendable, Hashable, Codable, CustomStringConvertible {

        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue.lowercased() }

        /// 免费试用。
        public static let freeTrial = OfferType(rawValue: "free_trial")
        /// 优惠期内按周期付低价。
        public static let payAsYouGo = OfferType(rawValue: "pay_as_you_go")
        /// 优惠期一次性预付。
        public static let payUpFront = OfferType(rawValue: "pay_up_front")
        /// StoreKit 给出了我们还不认识的形态。
        public static let unknown = OfferType(rawValue: "unknown")

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(rawValue: (try? container.decode(String.self)) ?? OfferType.unknown.rawValue)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public var description: String { rawValue }
    }

    public let type: OfferType
    /// 优惠期长度（**单个**周期，不含重复次数 —— 重复次数见 `periodCount`）。
    public let period: SubscriptionPeriod
    /// 优惠期重复几次（`Product.SubscriptionOffer.periodCount` 原样带出）。
    ///
    /// `payAsYouGo` 靠它才做得出「$1.99/月 × 3 个月」这种文案（`period` 只是「1 个月」）；
    /// `freeTrial` / `payUpFront` 通常是 1，但一律**如实带**，不在端上做归一化。
    public let periodCount: Int
    /// 优惠价的数值（0.4.0，R9）：`freeTrial` 恒为 0；`payAsYouGo` 是**每个周期**的价格、
    /// `payUpFront` 是整段优惠的一次性价格（均为 `Product.SubscriptionOffer.price` 原值，商店币种）。
    /// 对照 RC：`StoreProductDiscount.price`（Decimal）同义；宿主用 `price == 0` 判免费试用。
    public let price: Decimal
    /// 本地化价格串（免费试用为商店给出的零价串）。
    public let displayPrice: String
    /// 当前 Apple ID 是否**还有资格**享受该优惠（`Product.SubscriptionInfo.isEligibleForIntroOffer`）。
    ///
    /// 资格是**订阅组级**的（坑 #91），且端上判定不可信（裁决 #124）——
    /// 只用于展示文案，计费与权益一律以服务端为准。
    public let isEligible: Bool

    /// 0.4.0 起的完整构造器（带数值价）。
    public init(type: OfferType,
                period: SubscriptionPeriod,
                periodCount: Int,
                price: Decimal,
                displayPrice: String,
                isEligible: Bool) {
        self.type = type
        self.period = period
        self.periodCount = periodCount
        self.price = price
        self.displayPrice = displayPrice
        self.isEligible = isEligible
    }

    /// 0.3.x 构造器：保留只为不破宿主源码（测试 fixture / 预览），`price` 一律填 0。
    /// 非免费试用的优惠请改用带 `price:` 的构造器，否则数值价是错的。
    /// 不标 deprecated（主代理裁定）：次版本不给宿主添告警，基线保持纯「增」。
    public init(type: OfferType,
                period: SubscriptionPeriod,
                periodCount: Int,
                displayPrice: String,
                isEligible: Bool) {
        self.init(type: type,
                  period: period,
                  periodCount: periodCount,
                  price: 0,
                  displayPrice: displayPrice,
                  isEligible: isEligible)
    }

    /// SK2 映射的数值价规则（R9）：免费试用恒 0（不信任商店给出的值），其余取 `Product.SubscriptionOffer.price`。
    /// 抽成纯函数，单测不依赖 StoreKit 真身。
    static func price(for type: OfferType, offerPrice: Decimal) -> Decimal {
        type == .freeTrial ? 0 : offerPrice
    }
}

// MARK: - 公开模型：StoreProduct（M2 由 StoreKit 填充）

public struct StoreProduct: Sendable, Hashable, Codable {

    public let productIdentifier: String
    public let localizedTitle: String
    public let localizedDescription: String
    public let price: Decimal
    /// ISO 4217 币种码（`Product.priceFormatStyle.currencyCode`）。
    ///
    /// 0.4.0 起 StoreKit 路径**恒有值**（SK2 该属性是非可选 `String`）；类型保持 `String?` 只为不破源码。
    /// nil 只可能来自宿主自行构造的 fixture。
    public let currencyCode: String?
    public let localizedPriceString: String
    /// 订阅周期。非订阅商品（消耗型 / 非消耗型 / 永久）为 nil。
    public let subscriptionPeriod: SubscriptionPeriod?
    /// 介绍性优惠（含当前 Apple ID 的资格）。没有配置优惠时为 nil。
    public let introductoryOffer: IntroductoryOffer?

    /// 本地化价格串的 StoreKit 2 命名别名（与 `localizedPriceString` **同值**）。
    /// 从 RC 迁移的代码读 `localizedPriceString`，照 StoreKit 2 写的代码读 `displayPrice`。
    public var displayPrice: String { localizedPriceString }

    public init(productIdentifier: String,
                localizedTitle: String,
                localizedDescription: String,
                price: Decimal,
                currencyCode: String?,
                localizedPriceString: String) {
        self.init(productIdentifier: productIdentifier,
                  localizedTitle: localizedTitle,
                  localizedDescription: localizedDescription,
                  price: price,
                  currencyCode: currencyCode,
                  localizedPriceString: localizedPriceString,
                  subscriptionPeriod: nil,
                  introductoryOffer: nil)
    }

    public init(productIdentifier: String,
                localizedTitle: String,
                localizedDescription: String,
                price: Decimal,
                currencyCode: String?,
                localizedPriceString: String,
                subscriptionPeriod: SubscriptionPeriod?,
                introductoryOffer: IntroductoryOffer?) {
        self.productIdentifier = productIdentifier
        self.localizedTitle = localizedTitle
        self.localizedDescription = localizedDescription
        self.price = price
        self.currencyCode = currencyCode
        self.localizedPriceString = localizedPriceString
        self.subscriptionPeriod = subscriptionPeriod
        self.introductoryOffer = introductoryOffer
    }
}

// MARK: - 公开模型：PurchaseResult（M2 填实）

public struct PurchaseResult: Sendable {

    public let customerInfo: CustomerInfo
    public let transactionIdentifier: String?
    public let userCancelled: Bool
    /// 购买已提交、但**还在等第三方批准**（Ask-to-Buy 家长同意 / SCA 银行验证）。
    ///
    /// 为 true 时 `transactionIdentifier == nil` 且 `userCancelled == false`：
    /// 交易稍后会从 `Transaction.updates` 流出并由 SDK 自动上报，宿主此刻**不要**发放权益，
    /// 请提示「等待批准」并监听 `customerInfoStream`。
    public let isPending: Bool
    /// 成交交易的商品 id（0.4.0，R12）。SDK 发起的购买成功时（`transactionIdentifier != nil`）**恒非 nil**，
    /// 取交易的 `productID`（升降级时可能与发起购买的商品不同，以交易为准）；取消 / 待定为 nil。
    /// 对照 RC：`StoreTransaction.productIdentifier`。
    public let productIdentifier: String?
    /// 成交交易的购买时间（0.4.0，R12）。成功时**恒非 nil**（交易的 `purchaseDate`）；取消 / 待定为 nil。
    /// 对照 RC：`StoreTransaction.purchaseDate`。
    public let purchaseDate: Date?

    public init(customerInfo: CustomerInfo, transactionIdentifier: String?, userCancelled: Bool) {
        self.init(customerInfo: customerInfo,
                  transactionIdentifier: transactionIdentifier,
                  productIdentifier: nil,
                  purchaseDate: nil,
                  userCancelled: userCancelled,
                  isPending: false)
    }

    public init(customerInfo: CustomerInfo,
                transactionIdentifier: String?,
                userCancelled: Bool,
                isPending: Bool) {
        self.init(customerInfo: customerInfo,
                  transactionIdentifier: transactionIdentifier,
                  productIdentifier: nil,
                  purchaseDate: nil,
                  userCancelled: userCancelled,
                  isPending: isPending)
    }

    /// 0.4.0 起的完整构造器（带成交交易的商品 id 与购买时间）。
    public init(customerInfo: CustomerInfo,
                transactionIdentifier: String?,
                productIdentifier: String?,
                purchaseDate: Date?,
                userCancelled: Bool,
                isPending: Bool) {
        self.customerInfo = customerInfo
        self.transactionIdentifier = transactionIdentifier
        self.productIdentifier = productIdentifier
        self.purchaseDate = purchaseDate
        self.userCancelled = userCancelled
        self.isPending = isPending
    }
}
