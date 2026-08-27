//
//  RequestSnapshot.swift
//  出站请求 JSON 快照基建（设计 §7：上行契约变成可 diff 产物）。
//
//  用法：
//    try RequestSnapshot.assertMatches(request, named: "get-subscribers")
//
//  录制模式（**仅本地**）：
//    REVENUEDOG_RECORD_SNAPSHOTS=1 swift test
//  CI 上不设该变量 → 只比对；快照缺失直接失败（等价 RC 的录制模式锁 `.never`）。
//

import Foundation
import Testing

enum RequestSnapshot {

    // MARK: 配置

    static let recordEnvironmentKey = "REVENUEDOG_RECORD_SNAPSHOTS"

    static var isRecording: Bool {
        let value = ProcessInfo.processInfo.environment[recordEnvironmentKey]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// 每次运行都会变、或跟宿主环境绑定的头 —— 一律剔除，否则快照没法 diff。
    static let volatileHeaders: Set<String> = [
        "x-client-version",
        "x-client-build-version",
        "x-client-bundle-id",
        "x-platform-version",
        "x-platform-device",
        "x-preferred-locales",
        "x-storefront",
        "x-apple-device-identifier",
        "x-retry-count",
        "user-agent",
        "accept-encoding",
        "accept-language",
    ]

    /// 需要脱敏（保留「有没有发」这个事实，但不把值写进仓库）的头。
    static let redactedHeaders: Set<String> = ["authorization"]

    static var snapshotsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // RevenueDogTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("__Snapshots__", isDirectory: true)
    }

    // MARK: 规范化

    static func normalized(_ request: URLRequest) throws -> String {
        var payload: [String: Any] = [:]
        payload["method"] = request.httpMethod ?? "GET"

        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        payload["path"] = components?.percentEncodedPath ?? ""
        if let items = components?.queryItems, !items.isEmpty {
            payload["query"] = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }

        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lowered = name.lowercased()
            if volatileHeaders.contains(lowered) { continue }
            headers[name] = redactedHeaders.contains(lowered) ? "<redacted>" : value
        }
        payload["headers"] = headers

        if let body = request.httpBody, !body.isEmpty {
            payload["body"] = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } else {
            payload["body"] = NSNull()
        }

        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: 断言

    static func assertMatches(_ request: URLRequest,
                              named name: String,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actual = try normalized(request)
        let url = snapshotsDirectory.appendingPathComponent("\(name).json", isDirectory: false)

        guard let data = try? Data(contentsOf: url) else {
            guard isRecording else {
                Issue.record("""
                    缺少请求快照 \(name).json。
                    本地录制：\(recordEnvironmentKey)=1 swift test
                    CI 不允许自动录制 —— 上行契约必须是显式提交的产物。
                    实际内容：
                    \(actual)
                    """, sourceLocation: sourceLocation)
                return
            }
            try write(actual, to: url)
            Issue.record("已录制新快照 \(name).json —— 请检查内容并提交，然后重跑测试。",
                         sourceLocation: sourceLocation)
            return
        }

        let expected = String(decoding: data, as: UTF8.self)
        if expected == actual { return }

        if isRecording {
            try write(actual, to: url)
            Issue.record("快照 \(name).json 已更新 —— 请 review diff 后提交。", sourceLocation: sourceLocation)
            return
        }

        Issue.record("""
            出站请求与快照 \(name).json 不一致（上行契约变了？）。
            —— 期望 ——
            \(expected)
            —— 实际 ——
            \(actual)
            如为有意变更：\(recordEnvironmentKey)=1 swift test 重新录制。
            """, sourceLocation: sourceLocation)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}
