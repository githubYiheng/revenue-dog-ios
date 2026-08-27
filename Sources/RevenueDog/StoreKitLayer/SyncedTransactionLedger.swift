//
//  SyncedTransactionLedger.swift
//  `.myApp`（observer）模式的已同步 transactionId 台账（坑矩阵裁决 #10）。
//
//  没有 finish 就没有「已处理」标记：宿主自管 finish 时，updates 每次启动都会重投未 finish 交易，
//  没有台账会无限重复上报。RC 用 UserDefaults 无上限数组（本身是坑），我们用
//  Application Support 文件 + FIFO 上限 200 条。服务端本就幂等，台账只是省流量/省日志。
//

import Foundation

actor SyncedTransactionLedger {

    private let fileURL: URL
    private let capacity: Int
    private var ids: [String]? // 惰性加载

    init(fileURL: URL, capacity: Int = 200) {
        self.fileURL = fileURL
        self.capacity = capacity
    }

    static func defaultFileURL() throws -> URL {
        try SDKFileLocations.subdirectory(named: "Ledger")
            .appendingPathComponent("synced-transactions.json", isDirectory: false)
    }

    func contains(_ transactionID: String) -> Bool {
        load().contains(transactionID)
    }

    func record(_ transactionID: String) {
        var current = load()
        guard !current.contains(transactionID) else { return }
        current.append(transactionID)
        if current.count > capacity {
            current.removeFirst(current.count - capacity) // FIFO
        }
        ids = current
        persist(current)
    }

    private func load() -> [String] {
        if let ids { return ids }
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        ids = loaded
        return loaded
    }

    private func persist(_ value: [String]) {
        do {
            try SDKFileLocations.ensureDirectory(fileURL.deletingLastPathComponent())
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.warn("synced ledger 落盘失败: \(error)", category: "ledger")
        }
    }
}
