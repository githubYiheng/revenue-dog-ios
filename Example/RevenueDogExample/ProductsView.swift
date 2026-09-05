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
                if let product = package.storeProduct {
                    Text("\(product.localizedTitle) · \(product.localizedPriceString)")
                        .font(.caption)
                }
            }
        }
        .disabled(model.busy)
    }
}
