//
//  MockTransport.swift
//  出站请求捕获 + 可编排响应（设计 §7 测试基建）。
//

import Foundation
@testable import RevenueDog

actor MockTransport: HTTPTransport {

    struct Stub: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data

        static func json(_ string: String,
                         statusCode: Int = 200,
                         headers: [String: String] = [:]) -> Stub {
            Stub(statusCode: statusCode, headers: headers, body: Data(string.utf8))
        }

        static func failure(statusCode: Int,
                            headers: [String: String] = [:],
                            message: String = "boom") -> Stub {
            Stub(statusCode: statusCode,
                 headers: headers,
                 body: Data("{\"message\":\"\(message)\"}".utf8))
        }
    }

    private var stubs: [Stub]
    private var thrownErrors: [Int: any Error] = [:]
    private(set) var capturedRequests: [URLRequest] = []

    /// 按**路径**编排的 stub 队列（M4 故障注入：一条链路上多个端点各自编排，
    /// 不再依赖「全局队列顺序」这种脆弱前提）。键可以是完整路径，也可以是路径后缀
    /// （`/attributes` 这种带 appUserID 的路径用后缀匹配）。
    private var stubsByPath: [String: [Stub]] = [:]
    /// 按路径编排的传输层错误（超时 / 断网）：前 `remaining` 次调用抛错，用尽后回落 stub 队列。
    private var transportFailuresByPath: [String: (remaining: Int, error: any Error)] = [:]
    /// 整机断网（任何路径都抛传输层错误）。
    private var alwaysFailError: (any Error)?

    /// §6-14：诊断上传端点的**兜底**响应（不是排队 stub —— 排进队列会把测试自己编排的
    /// 第一个 stub 挤到第二位）。只有该路径上没有任何编排时才生效，
    /// 保证任何用例意外打开诊断时，上传拿到的是形状正确的 202，而不是别的端点的 body。
    private var fallbackStubsByPath: [String: Stub] = [
        "/v1/diagnostics/events": .json(#"{"accepted":0,"dropped":0}"#, statusCode: 202),
    ]

    init(stubs: [Stub] = []) {
        self.stubs = stubs
    }

    func enqueue(_ stub: Stub) {
        stubs.append(stub)
    }

    /// 第 `index` 次（从 0 起）调用抛传输层错误（模拟超时/断网）。
    func failTransport(atCallIndex index: Int, error: any Error = URLError(.timedOut)) {
        thrownErrors[index] = error
    }

    // MARK: 路径维度编排（M4）

    /// 给某个路径（或路径后缀）排队一个响应。队列只剩最后一个时**粘住**不出队 ——
    /// 「后端一直 5xx」这种场景不用把 stub 数得刚刚好。
    func enqueue(_ stub: Stub, forPath path: String) {
        stubsByPath[path, default: []].append(stub)
    }

    /// 清掉某路径已排队的 stub（「先一直失败、再恢复」的场景要先清，
    /// 否则粘住的失败 stub 会把恢复后的第一次调用又吃掉一次）。
    func clearStubs(forPath path: String) {
        stubsByPath[path] = nil
        transportFailuresByPath[path] = nil
        alwaysFailError = nil
    }

    /// 让某路径的前 `times` 次调用抛传输层错误（超时/断网）。`times: .max` = 一直不通。
    func failTransport(forPath path: String, times: Int, error: any Error = URLError(.timedOut)) {
        transportFailuresByPath[path] = (times, error)
    }

    /// 整机断网：任何路径都抛传输层错误（冷启动离线场景）。
    func failTransportAlways(error: any Error = URLError(.notConnectedToInternet)) {
        alwaysFailError = error
    }

    /// 命中某路径（完整或后缀）的请求数。
    func callCount(forPath path: String) -> Int {
        capturedRequests.filter { Self.matches($0.url?.path ?? "", key: path) }.count
    }

    func requests(forPath path: String) -> [URLRequest] {
        capturedRequests.filter { Self.matches($0.url?.path ?? "", key: path) }
    }

    private static func matches(_ path: String, key: String) -> Bool {
        path == key || path.hasSuffix(key)
    }

    var callCount: Int { capturedRequests.count }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        let index = capturedRequests.count
        capturedRequests.append(request)
        if let error = thrownErrors[index] { throw error }

        if let alwaysFailError { throw alwaysFailError }

        let path = request.url?.path ?? ""
        if let key = transportFailuresByPath.keys.first(where: { Self.matches(path, key: $0) }),
           var failure = transportFailuresByPath[key], failure.remaining > 0 {
            failure.remaining -= 1
            transportFailuresByPath[key] = failure
            throw failure.error
        }
        if let key = stubsByPath.keys.first(where: { Self.matches(path, key: $0) }),
           var queue = stubsByPath[key], !queue.isEmpty {
            let stub = queue.count == 1 ? queue[0] : queue.removeFirst()
            stubsByPath[key] = queue
            return HTTPTransportResponse(statusCode: stub.statusCode, headers: stub.headers, body: stub.body)
        }
        if let key = fallbackStubsByPath.keys.first(where: { Self.matches(path, key: $0) }),
           let stub = fallbackStubsByPath[key] {
            return HTTPTransportResponse(statusCode: stub.statusCode, headers: stub.headers, body: stub.body)
        }

        guard !stubs.isEmpty else {
            return HTTPTransportResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let stub = stubs.count == 1 ? stubs[0] : stubs.removeFirst()
        return HTTPTransportResponse(statusCode: stub.statusCode, headers: stub.headers, body: stub.body)
    }
}

/// **永不返回**的调度器：把「定时 / 防抖上传」彻底冻住。
///
/// 为什么需要它：诊断的防抖是 2s、网络重试的真实退避是 5s 量级 —— 用真调度器跑集成测试时，
/// 防抖会在断言之前把队列冲走（队列轮转到在飞文件、上传成功后清空），断言就变成了掷骰子。
/// 冻住之后队列在整条链路跑完前保持原样，事件序列才是可断言的。
/// Task 被取消时照常抛 `CancellationError`，不会泄漏。
struct NeverDelayScheduler: DelayScheduler {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
    }
}

/// 记录每次退避时长的调度器（不真睡）—— 用来验证 `Retry-After` 优先于本地指数退避（设计 §5）。
actor RecordingDelayScheduler: DelayScheduler {

    private(set) var recorded: [TimeInterval] = []

    func sleep(seconds: TimeInterval) async throws {
        recorded.append(seconds)
    }
}

// MARK: - 固定 SystemInfo（让快照稳定）

extension SystemInfo {

    /// 快照/单测专用：全部字段固定，机型/OS 版本等易变项在快照里也被剔除。
    static func fixture(isBackgrounded: Bool = false, isSandbox: Bool = false) -> SystemInfo {
        SystemInfo(platform: "iOS",
                   platformVersion: "Version 17.0 (Build 21A000)",
                   platformDevice: "iPhone15,2",
                   platformFlavor: "native",
                   sdkVersion: SystemInfo.sdkVersionString,
                   clientVersion: "1.2.3",
                   clientBuildVersion: "42",
                   clientBundleID: "com.example.host",
                   storeKitVersion: "2",
                   isSandbox: isSandbox,
                   isBackgrounded: isBackgrounded,
                   isDebugBuild: true,
                   installationMethod: SystemInfo.installationMethodString,
                   preferredLocales: ["en-US", "zh-Hans-CN"])
    }
}

// MARK: - 诊断管线的测试隔离（sdk-diagnostics §2）

extension Purchases.Dependencies.DiagnosticsDependencies {

    /// 单测隔离版：
    /// - 队列落**每次调用独立**的临时文件 —— 默认位置是 `<Application Support>` 下的全局单文件，
    ///   同一个测试进程里所有 suite 会往同一份 JSONL 里堆事件，攒够 20 条就触发一次真上传，
    ///   把「这条链路一共发了几个请求」这类断言污染成随机值。
    /// - 采样率存内存，不写 `UserDefaults.standard`。
    /// - 不起「前台每 30s」的定时循环（测试进程里那是纯空转）。
    /// - Parameter scheduler: 默认 `NeverDelayScheduler` —— 冻住防抖与定时上传，
    ///   让「这条链路一共发了几个请求 / 队列里有哪些事件」在断言时是确定的。
    static func isolated(startsPeriodicFlush: Bool = false,
                         scheduler: any DelayScheduler = NeverDelayScheduler()) -> Self {
        var dependencies = Purchases.Dependencies.DiagnosticsDependencies()
        dependencies.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevenueDogDiagnostics/\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(DiagnosticsQueue.fileName, isDirectory: false)
        dependencies.settings = InMemoryDiagnosticsSettingsStorage()
        dependencies.scheduler = scheduler
        dependencies.startsPeriodicFlush = startsPeriodicFlush
        return dependencies
    }
}
