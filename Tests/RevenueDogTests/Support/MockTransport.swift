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

    var callCount: Int { capturedRequests.count }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        let index = capturedRequests.count
        capturedRequests.append(request)
        if let error = thrownErrors[index] { throw error }
        guard !stubs.isEmpty else {
            return HTTPTransportResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let stub = stubs.count == 1 ? stubs[0] : stubs.removeFirst()
        return HTTPTransportResponse(statusCode: stub.statusCode, headers: stub.headers, body: stub.body)
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
