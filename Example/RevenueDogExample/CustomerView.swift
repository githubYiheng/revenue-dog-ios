//
//  CustomerView.swift
//  客户页：appUserID / logIn / logOut / CustomerInfo 全貌。
//

import RevenueDog
import SwiftUI

struct CustomerView: View {

    @EnvironmentObject private var model: AppModel
    @State private var loginInput: String = ""

    var body: some View {
        NavigationView {
            List {
                Section("身份") {
                    kv("appUserID", model.appUserID)
                    kv("匿名", model.isConfigured && Purchases.isConfigured
                        ? (Purchases.shared.isAnonymous ? "是" : "否") : "—")
                    LabeledField(title: "目标 appUserID", text: $loginInput)
                    Button("logIn") { model.logIn(loginInput) }
                    Button("logOut（回匿名）") { model.logOut() }
                }
                .disabled(model.busy || !model.isConfigured)

                Section("CustomerInfo 读取") {
                    Button("cachedOrFetched") { model.refreshCustomerInfo(policy: .cachedOrFetched) }
                    Button("cachedOnly") { model.refreshCustomerInfo(policy: .cachedOnly) }
                    Button("fetchCurrent") { model.refreshCustomerInfo(policy: .fetchCurrent) }
                    Button("notStaleCachedOrFetched") { model.refreshCustomerInfo(policy: .notStaleCachedOrFetched) }
                    Button("invalidateCustomerInfoCache") { model.invalidateCache() }
                }
                .disabled(model.busy || !model.isConfigured)

                if let info = model.customerInfo {
                    Section("当前 CustomerInfo") {
                        kv("originalAppUserID", info.originalAppUserID)
                        kv("requestDate", info.requestDate.map(String.init(describing:)) ?? "—")
                        kv("managementURL", info.managementURL?.absoluteString ?? "—")
                        kv("已购商品", info.allPurchasedProductIdentifiers.sorted().joined(separator: ", "))
                        kv("在订阅商品", info.activeSubscriptionProductIdentifiers.sorted().joined(separator: ", "))
                        kv("非订阅交易", info.nonSubscriptionTransactionIdentifiers.sorted().joined(separator: ", "))
                    }
                    Section("权益（active / all）") {
                        if info.entitlements.all.isEmpty {
                            Text("（无）").font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(info.entitlements.all.keys.sorted(), id: \.self) { key in
                            if let entitlement = info.entitlements.all[key] {
                                entitlementRow(entitlement, isActive: info.entitlements.active[key] != nil)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("还没有 CustomerInfo。configure 后 SDK 会自行拉取，"
                             + "也可以点上面的读取按钮。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("客户")
        }
        .navigationViewStyle(.stack)
    }

    private func entitlementRow(_ entitlement: EntitlementInfo, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entitlement.identifier).font(.body)
                Spacer()
                Text(isActive ? "active" : "inactive")
                    .font(.caption)
                    .foregroundStyle(isActive ? .green : .secondary)
            }
            // `Text(verbatim:)`：这些是诊断信息，不走本地化插值
            //（`Store` / `PeriodType` 这类自定义类型走 LocalizedStringKey 插值会报 deprecated）
            Text(verbatim: "product=\(entitlement.productIdentifier)"
                 + " · store=\(entitlement.store.rawValue)"
                 + " · period=\(entitlement.periodType.rawValue)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(verbatim: "expires=\(entitlement.expirationDate.map(String.init(describing:)) ?? "永久")"
                 + " · willRenew=\(entitlement.willRenew)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func kv(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.caption.monospaced())
        }
    }
}
