//
//  LogView.swift
//  日志面板 —— 接 `Purchases.setLogSink`，SDK 的每一行日志都会到这里。
//

import SwiftUI

struct LogView: View {

    @EnvironmentObject private var model: AppModel
    @State private var filter: String = ""

    private var visible: [LogEntry] {
        guard !filter.isEmpty else { return model.logs }
        let needle = filter.lowercased()
        return model.logs.filter {
            $0.message.lowercased().contains(needle)
                || $0.category.lowercased().contains(needle)
                || $0.level.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextField("过滤（级别 / category / 正文）", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(8)
                ScrollViewReader { proxy in
                    List(visible) { entry in
                        Text(entry.line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(color(for: entry.level))
                            .id(entry.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                    .listStyle(.plain)
                    .onChange(of: visible.count) { _ in
                        if let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("日志（\(model.logs.count)）")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { model.clearLogs() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("拷贝") { UIPasteboard.general.string = model.logsText }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func color(for level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        case "INFO": return .primary
        default: return .secondary
        }
    }
}
