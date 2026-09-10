//
//  DiagnosticsQueue.swift
//  诊断事件的本地 JSONL 队列（设计 docs/plan/sdk-diagnostics.md §2）。
//
//  - 位置：`<Application Support>/RevenueDog/diagnostics/queue.jsonl`。**绝不进 Documents**
//    （会被 iCloud 备份 / 用户可见）；目录由 `SDKFileLocations` 统一创建并标记不备份。
//  - 上限 **500 条 / 256 KB**：超限丢**最旧**，并由调用方补一条 `sdk_warning{queue_overflow}`
//    （那条本身不再触发溢出告警，否则会自激）。
//  - 损坏行（半截写入 / 手工改坏）**跳过不崩**：读取时逐行解码，坏行丢弃并重写文件。
//  - 落盘策略：追加走 `FileHandle` 增量写（O(1)）；只有裁剪 / 出队 / 清空才整文件重写
//    （文件上限 256 KB，重写一次是一次小原子写）。
//

import Foundation

actor DiagnosticsQueue {

    /// 队列上限（设计 §2）。
    static let maxEvents = 500
    static let maxBytes = 256 * 1024

    static let fileName = "queue.jsonl"

    private let fileURL: URL
    /// 内存镜像（每行一条序列化后的事件，不含换行符）。nil = 尚未从磁盘加载。
    private var lines: [Data]?
    /// 当前占用字节数（含每行的换行符）。
    private var byteCount = 0
    /// 本进程内跳过过的损坏行数（诊断用）。
    private(set) var corruptedLinesSkipped = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 默认位置：`<Application Support>/RevenueDog/diagnostics/queue.jsonl`。
    static func defaultFileURL() throws -> URL {
        try SDKFileLocations.subdirectory(named: "diagnostics")
            .appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - 读

    var count: Int {
        get async { await loaded().count }
    }

    var bytes: Int {
        get async {
            _ = await loaded()
            return byteCount
        }
    }

    /// 取队首一批（最旧优先），受条数与字节数双重上限约束。
    /// **不出队** —— 上传成功后由 `remove(count:)` 精确摘掉同样多的队首元素。
    func peek(maxCount: Int, maxBytes: Int) async -> [DiagnosticsEvent] {
        let all = await loaded()
        var result: [DiagnosticsEvent] = []
        var used = 0
        for line in all {
            if result.count >= maxCount { break }
            if !result.isEmpty && used + line.count > maxBytes { break }
            guard let event = try? DiagnosticsCoding.decoder.decode(DiagnosticsEvent.self, from: line) else {
                continue    // 理论上不可达：loaded() 已经把坏行滤掉了
            }
            used += line.count
            result.append(event)
        }
        return result
    }

    /// 全量读（测试与诊断用）。
    func allEvents() async -> [DiagnosticsEvent] {
        await loaded().compactMap { try? DiagnosticsCoding.decoder.decode(DiagnosticsEvent.self, from: $0) }
    }

    // MARK: - 写

    /// 入队一条事件。
    /// - Returns: 因超限被丢弃的**最旧**事件条数（0 = 未溢出）。调用方据此补 `queue_overflow` 告警。
    @discardableResult
    func append(_ event: DiagnosticsEvent) async -> Int {
        var all = await loaded()
        guard let line = try? DiagnosticsCoding.encoder.encode(event) else {
            Log.debug("诊断事件序列化失败，已丢弃（type=\(event.type)）", category: "diagnostics")
            return 0
        }
        guard line.count <= DiagnosticsEvent.maxSerializedBytes else {
            // 服务端会把超 2KB 的条目计入 dropped —— 端上就别发了。
            Log.debug("诊断事件超过 \(DiagnosticsEvent.maxSerializedBytes) 字节，已丢弃（type=\(event.type)）",
                      category: "diagnostics")
            return 0
        }

        all.append(line)
        byteCount += line.count + 1

        var dropped = 0
        while all.count > Self.maxEvents || byteCount > Self.maxBytes {
            let oldest = all.removeFirst()
            byteCount -= oldest.count + 1
            dropped += 1
        }
        lines = all

        if dropped > 0 {
            rewrite(all)
        } else {
            appendToDisk(line)
        }
        return dropped
    }

    /// 摘掉队首 `count` 条（上传成功后调用）。期间新入队的事件在队尾，前缀语义不受影响。
    func remove(count: Int) async {
        guard count > 0 else { return }
        var all = await loaded()
        let n = min(count, all.count)
        for _ in 0..<n {
            let line = all.removeFirst()
            byteCount -= line.count + 1
        }
        lines = all
        rewrite(all)
    }

    /// 清空队列并删除文件（`diagnosticsEnabled = false` 时的语义：不记不发、清空）。
    func clear() {
        lines = []
        byteCount = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 磁盘

    private func loaded() async -> [Data] {
        if let lines { return lines }
        var result: [Data] = []
        var skipped = 0
        if let data = try? Data(contentsOf: fileURL) {
            for raw in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                let line = Data(raw)
                // 损坏行（半截写入 / 被改坏）跳过，不崩、不影响后面的好行。
                if (try? DiagnosticsCoding.decoder.decode(DiagnosticsEvent.self, from: line)) != nil {
                    result.append(line)
                } else {
                    skipped += 1
                }
            }
        }
        // 超限的历史文件（换过上限 / 手工塞进来的）在加载时就裁到位。
        var bytes = result.reduce(0) { $0 + $1.count + 1 }
        var trimmed = false
        while result.count > Self.maxEvents || bytes > Self.maxBytes {
            let oldest = result.removeFirst()
            bytes -= oldest.count + 1
            trimmed = true
        }
        lines = result
        byteCount = bytes
        corruptedLinesSkipped += skipped
        if skipped > 0 || trimmed {
            Log.debug("诊断队列加载时跳过 \(skipped) 条损坏行，裁剪=\(trimmed)", category: "diagnostics")
            rewrite(result)
        }
        return result
    }

    private func appendToDisk(_ line: Data) {
        var payload = line
        payload.append(UInt8(ascii: "\n"))
        do {
            try SDKFileLocations.ensureDirectory(fileURL.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: fileURL, options: .atomic)
            }
        } catch {
            Log.debug("诊断队列写入失败：\(error)", category: "diagnostics")
        }
    }

    private func rewrite(_ all: [Data]) {
        do {
            try SDKFileLocations.ensureDirectory(fileURL.deletingLastPathComponent())
            var payload = Data()
            for line in all {
                payload.append(line)
                payload.append(UInt8(ascii: "\n"))
            }
            try payload.write(to: fileURL, options: .atomic)
        } catch {
            Log.debug("诊断队列重写失败：\(error)", category: "diagnostics")
        }
    }
}
