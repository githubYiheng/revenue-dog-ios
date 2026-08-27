//
//  Log.swift
//  结构化日志薄封装（设计 §2 Diagnostics）。
//
//  规则：不建自研锁保护业务状态（设计 §6），这里唯一的可变全局是日志级别/sink，
//  用 os 提供的 OSAllocatedUnfairLock（iOS 16 / macOS 13 起可用，与我们的平台基线一致）。
//

import Foundation

#if canImport(os)
import os
#endif

// MARK: - LogLevel

/// 日志级别。遵守「禁 public enum」（设计 §1）：struct + static 常量。
public struct LogLevel: Sendable, Hashable, Comparable, CustomStringConvertible {

    public let rawValue: Int
    public let label: String

    internal init(rawValue: Int, label: String) {
        self.rawValue = rawValue
        self.label = label
    }

    public static let verbose = LogLevel(rawValue: 0, label: "VERBOSE")
    public static let debug = LogLevel(rawValue: 1, label: "DEBUG")
    public static let info = LogLevel(rawValue: 2, label: "INFO")
    public static let warn = LogLevel(rawValue: 3, label: "WARN")
    public static let error = LogLevel(rawValue: 4, label: "ERROR")
    /// 关闭全部输出。
    public static let off = LogLevel(rawValue: 5, label: "OFF")

    public var description: String { label }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - LogSink

/// 宿主可注入的日志出口。
public protocol LogSink: Sendable {
    func write(level: LogLevel, category: String, message: String, file: String, line: UInt)
}

/// 默认出口：Apple 平台走 os.Logger，其它平台走 print。
struct DefaultLogSink: LogSink {

    func write(level: LogLevel, category: String, message: String, file: String, line: UInt) {
        let file = (file as NSString).lastPathComponent
        let line = "[RevenueDog][\(level.label)][\(category)] \(message) (\(file):\(line))"
        #if canImport(os)
        let logger = os.Logger(subsystem: "com.revenuedog.sdk", category: category)
        switch level {
        case .verbose, .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .warn: logger.warning("\(line, privacy: .public)")
        default: logger.error("\(line, privacy: .public)")
        }
        #else
        print(line)
        #endif
    }
}

// MARK: - Log

/// SDK 内部日志门面。
enum Log {

    private struct State: Sendable {
        var level: LogLevel
        var sink: any LogSink
    }

    #if canImport(os)
    private static let state = OSAllocatedUnfairLock(
        initialState: State(level: .info, sink: DefaultLogSink())
    )

    static var level: LogLevel { state.withLock { $0.level } }

    static func setLevel(_ level: LogLevel) { state.withLock { $0.level = level } }

    static func setSink(_ sink: any LogSink) { state.withLock { $0.sink = sink } }

    private static func emit(_ level: LogLevel, _ category: String, _ message: String,
                             _ file: String, _ line: UInt) {
        let sink: (any LogSink)? = state.withLock { $0.level <= level ? $0.sink : nil }
        sink?.write(level: level, category: category, message: message, file: file, line: line)
    }
    #else
    nonisolated(unsafe) private static var _state = State(level: .info, sink: DefaultLogSink())

    static var level: LogLevel { _state.level }
    static func setLevel(_ level: LogLevel) { _state.level = level }
    static func setSink(_ sink: any LogSink) { _state.sink = sink }

    private static func emit(_ level: LogLevel, _ category: String, _ message: String,
                             _ file: String, _ line: UInt) {
        guard _state.level <= level else { return }
        _state.sink.write(level: level, category: category, message: message, file: file, line: line)
    }
    #endif

    static func verbose(_ message: @autoclosure () -> String, category: String = "core",
                        file: String = #fileID, line: UInt = #line) {
        guard level <= .verbose else { return }
        emit(.verbose, category, message(), file, line)
    }

    static func debug(_ message: @autoclosure () -> String, category: String = "core",
                      file: String = #fileID, line: UInt = #line) {
        guard level <= .debug else { return }
        emit(.debug, category, message(), file, line)
    }

    static func info(_ message: @autoclosure () -> String, category: String = "core",
                     file: String = #fileID, line: UInt = #line) {
        guard level <= .info else { return }
        emit(.info, category, message(), file, line)
    }

    static func warn(_ message: @autoclosure () -> String, category: String = "core",
                     file: String = #fileID, line: UInt = #line) {
        guard level <= .warn else { return }
        emit(.warn, category, message(), file, line)
    }

    static func error(_ message: @autoclosure () -> String, category: String = "core",
                      file: String = #fileID, line: UInt = #line) {
        guard level <= .error else { return }
        emit(.error, category, message(), file, line)
    }

    /// M2/M3 未实现路径的统一提示。
    static func notImplemented(_ symbol: String, milestone: String,
                               file: String = #fileID, line: UInt = #line) {
        emit(.warn, "core", "\(symbol) 尚未实现（计划：\(milestone)）", file, line)
    }
}
