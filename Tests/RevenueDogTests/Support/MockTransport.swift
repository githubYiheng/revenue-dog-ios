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

        guard !stubs.isEmpty else {
            return HTTPTransportResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let stub = stubs.count == 1 ? stubs[0] : stubs.removeFirst()
        return HTTPTransportResponse(statusCode: stub.statusCode, headers: stub.headers, body: stub.body)
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
