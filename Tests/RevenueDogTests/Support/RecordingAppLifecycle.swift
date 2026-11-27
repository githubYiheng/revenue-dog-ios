//
//  RecordingAppLifecycle.swift
//  记录型后台活动申请面（0.5.2，ADR 0248 决定 2）+ 跨组件共享的时间线。
//
//  UIKit 的真实 `beginBackgroundTask` 在 macOS 单测里跑不到；把申请面换成它，就能断言
//  「通知发出的调用返回之前已申请」「请求发生在申请之后」「请求结束后活动被结束一次」。
//

import Foundation
@testable import RevenueDog

/// 线程安全的有序时间线。申请面、传输层往同一条里写，断言先后顺序。
final class TestTimeline: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ entry: String) {
        lock.lock()
        storage.append(entry)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func count(_ entry: String) -> Int {
        entries.filter { $0 == entry }.count
    }

    func firstIndex(_ entry: String) -> Int? {
        entries.firstIndex(of: entry)
    }

    func firstIndex(where predicate: (String) -> Bool) -> Int? {
        entries.firstIndex(where: predicate)
    }
}

/// 每次申请记一条 `begin:<name>`，每次 `end()` 调用记一条 `end:<name>`（**逐次**记，不去重 ——
/// 断言「结束一次」要能抓到重复结束）。「应用是否活跃」由构造参数决定。
final class RecordingAppLifecycle: AppLifecycleProvider {

    let timeline: TestTimeline
    private let isActive: Bool

    init(isApplicationActive: Bool = false, timeline: TestTimeline = TestTimeline()) {
        self.isActive = isApplicationActive
        self.timeline = timeline
    }

    func beginBackgroundActivity(named name: String) -> any BackgroundActivityToken {
        timeline.append("begin:\(name)")
        return Token(name: name, timeline: timeline)
    }

    @MainActor
    var isApplicationActive: Bool { isActive }

    func beginCount(_ name: String) -> Int { timeline.count("begin:\(name)") }
    func endCount(_ name: String) -> Int { timeline.count("end:\(name)") }

    private struct Token: BackgroundActivityToken {
        let name: String
        let timeline: TestTimeline

        func end() {
            timeline.append("end:\(name)")
        }
    }
}
