import Testing
@testable import RevenueDog

/// ADR 0135：StoreKit 偶尔把 1 周报成 7 天、12 个月报成 1 年；与 RC `normalized()` 同规则。
@Suite("SubscriptionPeriod.normalized()")
struct SubscriptionPeriodNormalizationTests {

    @Test("7 的倍数天折成周，12 的倍数月折成年")
    func foldsDaysAndMonths() {
        #expect(SubscriptionPeriod(unit: .day, value: 7).normalized() == SubscriptionPeriod(unit: .week, value: 1))
        #expect(SubscriptionPeriod(unit: .day, value: 14).normalized() == SubscriptionPeriod(unit: .week, value: 2))
        #expect(SubscriptionPeriod(unit: .month, value: 12).normalized() == SubscriptionPeriod(unit: .year, value: 1))
        #expect(SubscriptionPeriod(unit: .month, value: 24).normalized() == SubscriptionPeriod(unit: .year, value: 2))
    }

    @Test("与 RC 逐字同规则：0 与负数也按倍数折（RC isMultiple(of:) 语义）")
    func matchesRevenueCatEdgeSemantics() {
        #expect(SubscriptionPeriod(unit: .day, value: 0).normalized() == SubscriptionPeriod(unit: .week, value: 0))
        #expect(SubscriptionPeriod(unit: .month, value: 0).normalized() == SubscriptionPeriod(unit: .year, value: 0))
        #expect(SubscriptionPeriod(unit: .day, value: -7).normalized() == SubscriptionPeriod(unit: .week, value: -1))
    }

    @Test("不整除、week / year / unknown 一律原样；幂等")
    func leavesOthersUntouched() {
        for period in [
            SubscriptionPeriod(unit: .day, value: 3),
            SubscriptionPeriod(unit: .day, value: 10),
            SubscriptionPeriod(unit: .month, value: 1),
            SubscriptionPeriod(unit: .month, value: 6),
            SubscriptionPeriod(unit: .week, value: 1),
            SubscriptionPeriod(unit: .year, value: 1),
            SubscriptionPeriod(unit: .unknown, value: 7),
        ] {
            #expect(period.normalized() == period)
        }
        let folded = SubscriptionPeriod(unit: .day, value: 7).normalized()
        #expect(folded.normalized() == folded)
    }
}
