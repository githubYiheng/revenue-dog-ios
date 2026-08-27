//
//  FaultTolerantDecodingTests.swift
//  容错解码（设计 §8「必抄」）：后端加枚举值 / 少字段 / 换类型都不能摔老 SDK。
//

import Foundation
import Testing
@testable import RevenueDog

@Suite("容错解码")
struct FaultTolerantDecodingTests {

    private func decodeCustomerInfo(_ json: String) throws -> CustomerInfoWireModel {
        try JSONDecoder().decode(CustomerInfoWireModel.self, from: Data(json.utf8))
    }

    // MARK: 未知枚举值

    @Test("后端新增的 store / period_type / ownership_type 值降级为默认值，不整体失败")
    func unknownEnumValues() throws {
        let model = try decodeCustomerInfo("""
        {
          "request_date": "2019-07-26T17:40:10Z",
          "request_date_ms": 1564162810884,
          "subscriber": {
            "original_app_user_id": "user_42",
            "first_seen": "2019-02-21T00:08:41Z",
            "subscriptions": {
              "annual": {
                "expires_date": "2030-08-14T21:07:40Z",
                "purchase_date": "2019-07-14T20:07:40Z",
                "store": "future_store_9000",
                "period_type": "brand_new_period",
                "ownership_type": "SOMETHING_NEW"
              }
            }
          }
        }
        """)

        let subscription = try #require(model.subscriber.subscriptions["annual"])
        // 未知 store 保留原值语义但不等于任何已知常量 —— 关键是没抛异常。
        #expect(subscription.store != .appStore)
        #expect(subscription.store.rawValue == "future_store_9000")
        #expect(subscription.periodType.rawValue == "brand_new_period")
        #expect(subscription.ownershipType.rawValue == "SOMETHING_NEW")
    }

    @Test("枚举字段类型换成数字 → 回落默认值")
    func enumWrongType() throws {
        let model = try decodeCustomerInfo("""
        {
          "request_date": "2019-07-26T17:40:10Z",
          "subscriber": {
            "original_app_user_id": "user_42",
            "first_seen": "2019-02-21T00:08:41Z",
            "subscriptions": { "annual": { "store": 7, "period_type": null, "is_sandbox": "yes" } }
          }
        }
        """)

        let subscription = try #require(model.subscriber.subscriptions["annual"])
        #expect(subscription.store == .unknown)
        #expect(subscription.periodType == .normal)
        #expect(subscription.ownershipType == .purchased)
        #expect(subscription.isSandbox == false)
    }

    // MARK: 缺字段

    @Test("三个 map 缺失 → 空字典；可空日期缺失 → nil")
    func missingMapsDefaultToEmpty() throws {
        let model = try decodeCustomerInfo("""
        {
          "request_date": "2019-07-26T17:40:10Z",
          "subscriber": {
            "original_app_user_id": "user_42",
            "first_seen": "2019-02-21T00:08:41Z"
          }
        }
        """)

        #expect(model.subscriber.entitlements.isEmpty)
        #expect(model.subscriber.subscriptions.isEmpty)
        #expect(model.subscriber.nonSubscriptions.isEmpty)
        #expect(model.subscriber.subscriberAttributes.isEmpty)
        #expect(model.subscriber.lastSeen.date == nil)
        #expect(model.subscriber.managementURL == nil)
        #expect(model.subscriber.originalPurchaseDate.date == nil)
    }

    @Test("original_app_user_id / first_seen 缺失 → 整体解码失败（契约要求）")
    func requiredFieldsFailLoudly() {
        #expect(throws: (any Error).self) {
            try decodeCustomerInfo("""
            { "request_date": "2019-07-26T17:40:10Z", "subscriber": { "first_seen": "2019-02-21T00:08:41Z" } }
            """)
        }
        #expect(throws: (any Error).self) {
            try decodeCustomerInfo("""
            { "request_date": "2019-07-26T17:40:10Z", "subscriber": { "original_app_user_id": "u" } }
            """)
        }
    }

    @Test("后端新增未知字段一律忽略")
    func unknownFieldsIgnored() throws {
        let model = try decodeCustomerInfo("""
        {
          "request_date": "2019-07-26T17:40:10Z",
          "brand_new_top_level": { "a": 1 },
          "subscriber": {
            "original_app_user_id": "user_42",
            "first_seen": "2019-02-21T00:08:41Z",
            "future_field": [1, 2, 3]
          }
        }
        """)
        #expect(model.subscriber.originalAppUserID == "user_42")
    }

    @Test("日期格式坏掉 → 该字段 nil，其余照常")
    func badDateDegradesToNil() throws {
        let model = try decodeCustomerInfo("""
        {
          "request_date": "not-a-date",
          "subscriber": {
            "original_app_user_id": "user_42",
            "first_seen": "2019-02-21T00:08:41Z",
            "last_seen": 12345
          }
        }
        """)
        #expect(model.requestDate.date == nil)
        #expect(model.subscriber.lastSeen.date == nil)
        #expect(model.subscriber.firstSeen.date != nil)
    }

    @Test("带小数秒的 ISO 日期也能解析")
    func fractionalSecondsDate() throws {
        let model = try decodeCustomerInfo("""
        {
          "request_date": "2019-07-26T17:40:10.884Z",
          "subscriber": { "original_app_user_id": "u", "first_seen": "2019-02-21T00:08:41Z" }
        }
        """)
        #expect(model.requestDate.date != nil)
    }

    // MARK: 金额

    @Test("price 字符串 → Decimal，且不经过 Double 丢精度")
    func priceFromString() throws {
        let model = try decodeCustomerInfo("""
        {
          "request_date": "2019-07-26T17:40:10Z",
          "subscriber": {
            "original_app_user_id": "u",
            "first_seen": "2019-02-21T00:08:41Z",
            "subscriptions": {
              "annual": { "price": { "amount": "10.98", "currency": "USD" } }
            }
          }
        }
        """)

        let price = try #require(model.subscriber.subscriptions["annual"]?.price)
        #expect(price.amount == Decimal(string: "10.98"))
        #expect(price.currency == "USD")
        #expect(Money.decimalString(price.amount) == "10.98")
    }

    @Test("price 数字形态也必须接受（裁决 F2：两种都要吃）")
    func priceFromNumber() throws {
        let model = try decodeCustomerInfo("""
        {
          "request_date": "2019-07-26T17:40:10Z",
          "subscriber": {
            "original_app_user_id": "u",
            "first_seen": "2019-02-21T00:08:41Z",
            "subscriptions": {
              "annual": { "price": { "amount": 10.98, "currency": "EUR" } },
              "monthly": { "price": null }
            }
          }
        }
        """)

        let price = try #require(model.subscriber.subscriptions["annual"]?.price)
        #expect(price.amount == Decimal(string: "10.98"))
        #expect(price.currency == "EUR")
        #expect(model.subscriber.subscriptions["monthly"]?.price == nil)
    }

    @Test("Money 上行一律编码成字符串（NSDecimalNumber.description）")
    func moneyEncodesAsString() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Money(amount: Decimal(string: "10.98")!, currency: "USD"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"amount":"10.98","currency":"USD"}"#)
    }

    // MARK: 完整响应 → 公开模型

    @Test("契约 §2.2 官方示例：EntitlementInfo 从 subscriptions 关联算出来")
    func officialExample() throws {
        let model = try decodeCustomerInfo(Fixtures.customerInfoOfficialExample)
        let info = CustomerInfo(wireModel: model)

        #expect(info.originalAppUserID == "XXX-XXXXX-XXXXX-XX")
        #expect(info.managementURL?.absoluteString == "https://apps.apple.com/account/subscriptions")
        #expect(info.allPurchasedProductIdentifiers == ["annual", "rc_promo_pro_cat_monthly", "onetime"])
        #expect(info.nonSubscriptionTransactionIdentifiers == ["cadba0c81b"])

        let entitlement = try #require(info.entitlements["pro_cat"])
        #expect(entitlement.productIdentifier == "onetime")
        // 终身权益（expires_date == null）
        #expect(entitlement.isLifetime)
        #expect(entitlement.willRenew == false)
        // store 从 non_subscriptions["onetime"] 关联得到
        #expect(entitlement.store == .appStore)
        #expect(entitlement.isSandbox)
        // 终身权益在任何参照时间都有效
        #expect(entitlement.isActive(referenceDate: Date(timeIntervalSince1970: 4_000_000_000)))
    }

    @Test("Offerings 最小响应解析 + $rc_ 包类型映射")
    func offeringsDecoding() throws {
        let wire = try JSONDecoder().decode(OfferingsWireModel.self,
                                            from: Data(Fixtures.offeringsMinimalExample.utf8))
        let offerings = Offerings(wireModel: wire)

        #expect(offerings.currentOfferingIdentifier == "default")
        let current = try #require(offerings.current)
        #expect(current.serverDescription == "The default offering")
        #expect(current.availablePackages.count == 3)
        #expect(current.monthly?.platformProductIdentifier == "monthly_free_trial")
        #expect(current.annual?.packageType == .annual)
        #expect(current["consumable"]?.packageType == .custom)
        // M1 不拉 StoreKit 商品。
        #expect(current.monthly?.storeProduct == nil)
    }

    @Test("offerings 里未知字段与缺失 packages 不摔")
    func offeringsTolerance() throws {
        let wire = try JSONDecoder().decode(OfferingsWireModel.self, from: Data("""
        {
          "current_offering_id": "default",
          "offerings": [
            { "identifier": "default", "description": "d", "paywall": { "x": 1 } },
            { "identifier": "other", "packages": [] }
          ],
          "placements": null
        }
        """.utf8))

        let offerings = Offerings(wireModel: wire)
        #expect(offerings.all.count == 2)
        #expect(offerings["default"]?.availablePackages.isEmpty == true)
    }
}

enum Fixtures {

    /// api-contract-v1 §2.2 的官方原文示例。
    static let customerInfoOfficialExample = """
    {
      "request_date": "2019-07-26T17:40:10Z",
      "request_date_ms": 1564162810884,
      "subscriber": {
        "entitlements": {
          "pro_cat": {
            "expires_date": null,
            "grace_period_expires_date": null,
            "product_identifier": "onetime",
            "purchase_date": "2019-04-05T21:52:45Z"
          }
        },
        "first_seen": "2019-02-21T00:08:41Z",
        "management_url": "https://apps.apple.com/account/subscriptions",
        "non_subscriptions": {
          "onetime": [
            {
              "id": "cadba0c81b",
              "is_sandbox": true,
              "purchase_date": "2019-04-05T21:52:45Z",
              "store": "app_store"
            }
          ]
        },
        "original_app_user_id": "XXX-XXXXX-XXXXX-XX",
        "original_application_version": "1.0",
        "original_purchase_date": "2019-01-30T23:54:10Z",
        "other_purchases": {},
        "subscriptions": {
          "annual": {
            "auto_resume_date": null,
            "billing_issues_detected_at": null,
            "expires_date": "2019-08-14T21:07:40Z",
            "grace_period_expires_date": null,
            "is_sandbox": true,
            "original_purchase_date": "2019-02-21T00:42:05Z",
            "ownership_type": "PURCHASED",
            "period_type": "normal",
            "purchase_date": "2019-07-14T20:07:40Z",
            "refunded_at": null,
            "store": "play_store",
            "store_transaction_id": "GPA.6801-7988-0152-76034..5",
            "unsubscribe_detected_at": "2019-07-17T22:48:38Z"
          },
          "rc_promo_pro_cat_monthly": {
            "auto_resume_date": null,
            "billing_issues_detected_at": null,
            "expires_date": "2019-08-26T01:02:16Z",
            "grace_period_expires_date": null,
            "is_sandbox": false,
            "original_purchase_date": "2019-07-26T01:02:16Z",
            "ownership_type": "FAMILY_SHARED",
            "period_type": "normal",
            "purchase_date": "2019-07-26T01:02:16Z",
            "refunded_at": null,
            "store": "promotional",
            "store_transaction_id": "a42db3af39530cb82b17eaf9c6576393",
            "unsubscribe_detected_at": null
          }
        }
      }
    }
    """

    /// api-contract-v1 §2.3 的最小响应示例。
    static let offeringsMinimalExample = """
    {
      "current_offering_id": "default",
      "offerings": [
        {
          "description": "The default offering",
          "identifier": "default",
          "packages": [
            { "identifier": "$rc_monthly", "platform_product_identifier": "monthly_free_trial" },
            { "identifier": "$rc_annual",  "platform_product_identifier": "yearly_free_trial" },
            { "identifier": "consumable",  "platform_product_identifier": "consumable1" }
          ]
        }
      ]
    }
    """
}
