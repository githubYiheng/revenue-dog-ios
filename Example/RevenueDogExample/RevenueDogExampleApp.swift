//
//  RevenueDogExampleApp.swift
//  宿主示例 app 入口。
//
//  这个 app 有两个职责：
//  1. **给 StoreKitTest 当宿主**（TEST_HOST）—— 没有它 `Transaction.*` 全空，
//     RevenueDog 的上报链路整条不可测（verify/storekittest-spm.md §4.3）。
//  2. **当真机核验载体** —— 门禁报告 §2 的真机清单在「核验」页逐条可跑。
//
//  注意：本 app **故意不在启动时 configure** —— 为了能在界面上改 apiKey / baseURL。
//  生产集成必须在 App 启动期 configure（铁律 P1）；核验清单里有一条专测这个时序。
//

import SwiftUI

@main
struct RevenueDogExampleApp: App {

    @StateObject private var model = AppModel()
    @StateObject private var checklist = ChecklistState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(checklist)
        }
    }
}

struct RootView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ConfigurationView()
                .tabItem { Label("配置", systemImage: "gearshape") }
            ProductsView()
                .tabItem { Label("商品", systemImage: "cart") }
            CustomerView()
                .tabItem { Label("客户", systemImage: "person.crop.circle") }
            ChecklistView()
                .tabItem { Label("核验", systemImage: "checklist") }
            LogView()
                .tabItem { Label("日志", systemImage: "text.alignleft") }
        }
        .overlay(alignment: .top) { StatusBanner() }
    }
}

/// 顶部一行状态条：最近一次动作的结果。
struct StatusBanner: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.lastMessage.isEmpty {
            Text(model.lastMessage)
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.lastMessageIsError ? Color.red.opacity(0.18) : Color.green.opacity(0.15))
                .transition(.opacity)
        }
    }
}
