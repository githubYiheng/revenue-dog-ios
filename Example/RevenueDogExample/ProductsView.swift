//
//  ProductsView.swift
//  商品页：offerings 列表 + 购买 / restore / sync。
//

import RevenueDog
import SwiftUI

struct ProductsView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button("拉取 offerings") { model.loadOfferings() }
                    Button("restorePurchases（弹 Apple ID 框）") { model.restore() }
                    Button("syncPurchases（静默）") { model.sync() }
                }
                .disabled(model.busy || !model.isConfigured)

                if let offerings = model.offerings {
                    ForEach(offerings.all.keys.sorted(), id: \.self) { key in
                        if let offering = offerings.all[key] {
                            Section(header: Text(sectionTitle(offering, current: offerings.currentOfferingIdentifier))) {
                                ForEach(offering.availablePackages, id: \.identifier) { package in
                                    packageRow(package)
                                }
                            }
                        }
                    }
                }

                if !model.fallbackProducts.isEmpty {
                    Section(header: Text("兜底商品（后端不可达，直读 StoreKit 配置）")) {
                        ForEach(model.fallbackProducts, id: \.productIdentifier) { product in
                            Button {
                                model.purchase(product: product)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.productIdentifier).font(.body.monospaced())
                                    Text(product.localizedDescription)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(model.busy)
                        }
                    }
                }

                if model.offerings == nil && model.fallbackProducts.isEmpty {
                    Section {
                        Text("还没有商品。点上面「拉取 offerings」；"
                             + "后端不可达时会自动退回 StoreKit 配置里的内建商品。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("商品")
            .overlay { if model.busy { ProgressView().controlSize(.large) } }
        }
        .navigationViewStyle(.stack)
    }

    private func sectionTitle(_ offering: Offering, current: String?) -> String {
        offering.identifier == current
            ? "\(offering.identifier)（current）"
            : offering.identifier
    }

    private func packageRow(_ package: Package) -> some View {
        Button {
            model.purchase(package: package)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(package.identifier).font(.body)
                Text("\(package.packageType.rawValue) · \(package.platformProductIdentifier)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                // v0.2.0：storeProduct 由 SDK 用 StoreKit 批量填充（在这之前恒为 nil）
                if let product = package.storeProduct {
                    Text("\(product.localizedTitle) · \(product.displayPrice)")
                        .font(.caption)
                    if let period = product.subscriptionPeriod {
                        Text("周期 \(period.value) \(period.unit.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let offer = product.introductoryOffer {
                        Text("优惠 \(offer.type.rawValue) · \(offer.displayPrice) / \(offer.period.value) \(offer.period.unit.rawValue) × \(offer.periodCount)"
                             + (offer.isEligible ? " · 当前账号有资格" : " · 当前账号无资格"))
                            .font(.caption2)
                            .foregroundStyle(offer.isEligible ? .green : .secondary)
                    }
                } else {
                    Text("商店查不到该商品（ASC 未建 / 未过审 / 地区不售）")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(model.busy)
    }
}
