//
//  PublicAPIHarness.swift
//  给「只用公开 API」的测试文件用的最小内部钩子。
//
//  `PublicTransportInjectionTests.swift` 故意**不** `@testable import` —— 它要证明宿主
//  单靠公开面就能把假后端接进来。但拆单例（`Purchases.resetForTesting()`）与
//  等启动完成（`Purchases.awaitConfigured()`）是测试基建，不属于公开面，
//  于是留在这个带 `@testable` 的薄壳里。
//

import Foundation
@testable import RevenueDog

enum PublicAPIHarness {

    @MainActor
    static func reset() {
        Purchases.resetForTesting()
    }

    @MainActor
    static func awaitConfigured() async {
        await Purchases.awaitConfigured()
    }
}
