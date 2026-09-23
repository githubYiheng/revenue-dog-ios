//
//  BackendResponseFactories.swift
//  0.4.1 SPI：「后端响应 JSON → 公开模型」工厂，供混合框架插件（Flutter Bridge）的单测
//  构造与网络路径**逐字段一致**的模型。与 Android 0.2.0 `RevenueDogTestModels` 对称（主代理裁定 7）。
//
//  **非宿主承诺**（`@_spi(RevenueDogInternal)`）：签名可能随插件需要调整。
//

import Foundation

extension CustomerInfo {

    /// 把 `GET /v1/subscribers/{id}` 的响应体（契约 §2.2）解成公开 `CustomerInfo`。
    ///
    /// 与网络路径**同一解码**：`HTTPClient.makeResponseDecoder()` 解 `CustomerInfoWireModel`
    /// → `CustomerInfo(wireModel:now:)`。`now` 是权益 / 订阅 `isActive` 的本地参照时间
    /// （仍受 `request_date` 3 天 grace 规则约束，与真实路径同一函数），测试里注入以得到确定结果。
    /// JSON 不合契约（如缺 `original_app_user_id`）时抛解码错误，不崩。
    @_spi(RevenueDogInternal)
    public static func fromBackendResponse(_ data: Data, now: Date = Date()) throws -> CustomerInfo {
        let wire = try HTTPClient.makeResponseDecoder().decode(CustomerInfoWireModel.self, from: data)
        return CustomerInfo(wireModel: wire, now: now)
    }
}

extension Offerings {

    /// 把 `GET /v1/subscribers/{id}/offerings` 的响应体解成公开 `Offerings`，并按
    /// `platformProductIdentifier` 挂上 `products`（与编排层 `resolveStoreProducts` 共用
    /// `fillingStoreProducts(_:)`）。挂不上的 package 保持 `storeProduct == nil`，与真实路径一致。
    /// JSON 不合契约时抛解码错误，不崩。
    @_spi(RevenueDogInternal)
    public static func fromBackendResponse(_ data: Data, products: [StoreProduct]) throws -> Offerings {
        let wire = try HTTPClient.makeResponseDecoder().decode(OfferingsWireModel.self, from: data)
        return Offerings(wireModel: wire).fillingStoreProducts(products)
    }
}
