//
//  ConfigurationView.swift
//  配置页：apiKey / baseURL / 初始 appUserID。
//

import RevenueDog
import SwiftUI

struct ConfigurationView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            Form {
                Section("SDK 配置（configure 前可改）") {
                    LabeledField(title: "apiKey", text: $model.apiKeyInput)
                    LabeledField(title: "baseURL", text: $model.baseURLInput, keyboard: .URL)
                    LabeledField(title: "appUserID（留空 = 匿名）", text: $model.appUserIDInput)
                    Toggle("verbose 日志", isOn: $model.verboseLogging)
                    Button(model.isConfigured ? "已配置（进程内不可重配）" : "configure") {
                        model.configure()
                    }
                    .disabled(model.isConfigured)
                }

                Section("常用 baseURL") {
                    ForEach(Self.presets, id: \.1) { preset in
                        Button(preset.0) { model.baseURLInput = preset.1 }
                            .disabled(model.isConfigured)
                    }
                }

                Section("运行态") {
                    row("已配置", model.isConfigured ? "是" : "否")
                    row("appUserID", model.appUserID)
                    row("匿名", model.isConfigured && Purchases.isConfigured
                        ? (Purchases.shared.isAnonymous ? "是" : "否") : "—")
                    row("SDK 日志级别", "\(Purchases.logLevel)")
                }

                Section("说明") {
                    Text("模拟器上挂了 StoreKit 配置（scheme 已配 `RevenueDog.storekit`）时，"
                         + "**不连后端也能走完购买 UI**：商品从 StoreKitTest 出，"
                         + "只是上报会失败并留待重放。")
                        .font(.footnote)
                    Text("生产集成必须在 App 启动期 configure（铁律 P1）；"
                         + "本 app 为了能改 baseURL 才做成按钮触发。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("配置")
        }
        .navigationViewStyle(.stack)
    }

    private static let presets: [(String, String)] = [
        ("本机 wrangler dev", "http://127.0.0.1:8787"),
        ("模拟器访问宿主机", "http://localhost:8787"),
        ("生产默认", Configuration.defaultBaseURL.absoluteString),
    ]

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LabeledField: View {

    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: $text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
        }
    }
}
