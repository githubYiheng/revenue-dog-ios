//
//  ChecklistView.swift
//  真机核验清单页 —— 门禁报告 §2 逐条可跑。
//

import SwiftUI

struct ChecklistView: View {

    @EnvironmentObject private var checklist: ChecklistState

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("这一页把门禁报告 `docs/audit/2026-08-28-sdk-m2-gate.md` §2 的真机清单搬到了手机上："
                         + "2 条必做（📱）+ 4 条建议一并在真机跑的补充场景。"
                         + "每条给了操作步骤与通过判据，勾选状态只存本机。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(ChecklistItem.all) { item in
                    NavigationLink {
                        ChecklistDetailView(item: item)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: checklist.isChecked(item.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(checklist.isChecked(item.id) ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.body)
                                Text(item.origin).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("真机核验清单")
        }
        .navigationViewStyle(.stack)
    }
}

struct ChecklistDetailView: View {

    let item: ChecklistItem
    @EnvironmentObject private var checklist: ChecklistState

    var body: some View {
        List {
            Section("来源") {
                Text(item.origin).font(.caption.monospaced())
            }
            Section("操作步骤") {
                ForEach(Array(item.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(step).font(.callout)
                    }
                }
            }
            Section("通过判据") {
                Text(item.expectation).font(.callout)
            }
            if let note = item.note {
                Section("备注") {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(checklist.isChecked(item.id) ? "取消标记" : "标记为已核验") {
                    checklist.toggle(item.id)
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
