//
//  AppModel.swift
//  示例 app 的唯一状态容器 —— 只消费 RevenueDog 的**公开 API**。
//
//  纪律：示例 app 不 `@testable import`、不碰任何 internal 符号。
//  它同时是「真机核验载体」：门禁报告 docs/audit/2026-08-28-sdk-m2-gate.md §2
//  的真机清单靠这个 app 跑（清单正文见 VerificationChecklist.swift）。
//

import Foundation
import RevenueDog
import SwiftUI

// MARK: - 日志面板

/// 面板里的一行日志。
struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let level: String
    let category: String
    let message: String

    var line: String {
        let stamp = LogEntry.formatter.string(from: date)
        return "\(stamp) [\(level)][\(category)] \(message)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// `Purchases.setLogSink` 的宿主出口：把 SDK 日志转给 UI。
///
/// SDK 从任意线程/任务调用 sink，所以这里只做一次 hop 到主线程。
final class ForwardingLogSink: LogSink {

    private let handler: @Sendable (LogLevel, String, String) -> Void

    init(handler: @escaping @Sendable (LogLevel, String, String) -> Void) {
        self.handler = handler
    }

    func write(level: LogLevel, category: String, message: String, file: String, line: UInt) {
        handler(level, category, message)
    }
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {

    // 配置面（configure 之前可改）
    @Published var apiKeyInput: String = "pk_example"
    @Published var baseURLInput: String = "http://127.0.0.1:8787"
    @Published var appUserIDInput: String = ""
    @Published var verboseLogging: Bool = true

    // 运行态
    @Published private(set) var isConfigured: Bool = Purchases.isConfigured
    @Published private(set) var appUserID: String = "（未配置）"
    @Published private(set) var customerInfo: CustomerInfo?
    @Published private(set) var offerings: Offerings?
    @Published private(set) var busy: Bool = false
    @Published private(set) var lastMessage: String = ""
    @Published private(set) var lastMessageIsError: Bool = false
    @Published private(set) var logs: [LogEntry] = []

    /// 后端不可达时的兜底商品列表 —— 与 `Tests/StoreKitTestSupport/RevenueDog.storekit` 一致。
    /// 模拟器上挂了 StoreKit 配置就能直接走完购买 UI，不需要后端。
    static let fallbackProductIdentifiers = ["com.demo.monthly", "com.demo.yearly", "com.demo.coins"]

    /// 兜底列表拉到的 StoreKit 商品（`offerings()` 失败时用）。
    @Published private(set) var fallbackProducts: [StoreProduct] = []

    private var streamTask: Task<Void, Never>?

    // MARK: 配置

    func configure() {
        guard !Purchases.isConfigured else {
            note("Purchases 已配置过，进程内不可重配（SDK 设计：启动期一次性配置）", isError: true)
            return
        }
        guard let baseURL = URL(string: baseURLInput.trimmingCharacters(in: .whitespaces)) else {
            note("baseURL 不是合法 URL", isError: true)
            return
        }
        // 日志出口先接上，才能看到 configure 期间的日志
        Purchases.setLogSink(ForwardingLogSink { [weak self] level, category, message in
            Task { @MainActor in self?.appendLog(level: level, category: category, message: message) }
        })

        var configuration = Configuration(apiKey: apiKeyInput.trimmingCharacters(in: .whitespaces))
            .with(baseURL: baseURL)
            .with(logLevel: verboseLogging ? .verbose : .info)
        let trimmedUser = appUserIDInput.trimmingCharacters(in: .whitespaces)
        if !trimmedUser.isEmpty {
            configuration = configuration.with(appUserID: trimmedUser)
        }

        let purchases = Purchases.configure(with: configuration)
        isConfigured = true
        appUserID = purchases.appUserID
        customerInfo = purchases.cachedCustomerInfo
        observeCustomerInfo()
        note("已配置：baseURL=\(baseURL.absoluteString)")
        // 启动期身份可能在 Task 里对齐，稍后再读一次
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.refreshIdentitySnapshot()
        }
    }

    private func observeCustomerInfo() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard Purchases.isConfigured else { return }
            for await info in Purchases.shared.customerInfoStream {
                guard let self else { return }
                self.customerInfo = info
                self.appUserID = Purchases.shared.appUserID
            }
        }
    }

    func refreshIdentitySnapshot() {
        guard Purchases.isConfigured else { return }
        appUserID = Purchases.shared.appUserID
        customerInfo = Purchases.shared.cachedCustomerInfo ?? customerInfo
    }

    // MARK: 动作

    func loadOfferings() {
        run("拉取 offerings") {
            let result = try await Purchases.shared.offerings()
            self.offerings = result
            let count = result.all.values.reduce(0) { $0 + $1.availablePackages.count }
            return "offerings=\(result.all.count) 个，packages=\(count) 个"
        } onFailure: {
            // 后端不可达时退回 StoreKit 直读，保证模拟器上购买 UI 仍可走通
            await self.loadFallbackProducts()
        }
    }

    /// 后端无关的兜底：直接从 StoreKit 配置里认商品 ID，构造 `StoreProduct` 壳。
    /// SDK 的 `purchase(product:)` 内部按 `productIdentifier` 重新向 StoreKit 取货，
    /// 所以壳里的价格/文案只用于展示。
    func loadFallbackProducts() async {
        fallbackProducts = Self.fallbackProductIdentifiers.map { identifier in
            StoreProduct(productIdentifier: identifier,
                         localizedTitle: identifier,
                         localizedDescription: "StoreKit 配置内建商品（后端不可达时的兜底入口）",
                         price: 0,
                         currencyCode: nil,
                         localizedPriceString: "—")
        }
    }

    func purchase(package: Package) {
        run("购买 package \(package.identifier)") {
            let result = try await Purchases.shared.purchase(package: package)
            self.customerInfo = result.customerInfo
            return result.userCancelled
                ? "用户取消"
                : "成功，tx=\(result.transactionIdentifier ?? "nil")，激活权益=\(result.customerInfo.entitlements.active.keys.sorted())"
        }
    }

    func purchase(product: StoreProduct) {
        run("购买商品 \(product.productIdentifier)") {
            let result = try await Purchases.shared.purchase(product: product)
            self.customerInfo = result.customerInfo
            return result.userCancelled
                ? "用户取消"
                : "成功，tx=\(result.transactionIdentifier ?? "nil")，激活权益=\(result.customerInfo.entitlements.active.keys.sorted())"
        }
    }

    func restore() {
        run("restorePurchases（会弹 Apple ID 框）") {
            let info = try await Purchases.shared.restorePurchases()
            self.customerInfo = info
            return "激活权益=\(info.entitlements.active.keys.sorted())"
        }
    }

    func sync() {
        run("syncPurchases（静默）") {
            let info = try await Purchases.shared.syncPurchases()
            self.customerInfo = info
            return "激活权益=\(info.entitlements.active.keys.sorted())"
        }
    }

    func refreshCustomerInfo(policy: FetchPolicy) {
        run("customerInfo(fetchPolicy: \(policy))") {
            let info = try await Purchases.shared.customerInfo(fetchPolicy: policy)
            self.customerInfo = info
            return "originalAppUserID=\(info.originalAppUserID)"
        }
    }

    func invalidateCache() {
        guard Purchases.isConfigured else { return }
        Purchases.shared.invalidateCustomerInfoCache()
        note("已作废 CustomerInfo 缓存")
    }

    func logIn(_ newAppUserID: String) {
        let target = newAppUserID.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            note("appUserID 不能为空", isError: true)
            return
        }
        run("logIn(\(target))") {
            let result = try await Purchases.shared.logIn(target)
            self.customerInfo = result.customerInfo
            self.appUserID = Purchases.shared.appUserID
            return "created=\(result.created)，appUserID=\(Purchases.shared.appUserID)"
        }
    }

    func logOut() {
        run("logOut") {
            let info = try await Purchases.shared.logOut()
            self.customerInfo = info
            self.appUserID = Purchases.shared.appUserID
            return "匿名 appUserID=\(Purchases.shared.appUserID)"
        }
    }

    // MARK: 日志面板

    func appendLog(level: LogLevel, category: String, message: String) {
        logs.append(LogEntry(date: Date(), level: level.label, category: category, message: message))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    func clearLogs() { logs.removeAll() }

    var logsText: String { logs.map(\.line).joined(separator: "\n") }

    // MARK: 内部

    private func note(_ message: String, isError: Bool = false) {
        lastMessage = message
        lastMessageIsError = isError
        appendLog(level: isError ? .error : .info, category: "example", message: message)
    }

    private func run(_ label: String,
                     _ body: @escaping @MainActor () async throws -> String,
                     onFailure: (@MainActor () async -> Void)? = nil) {
        guard Purchases.isConfigured else {
            note("请先在「配置」页 configure", isError: true)
            return
        }
        guard !busy else { return }
        busy = true
        note("▶︎ \(label)")
        Task { @MainActor in
            defer { busy = false }
            do {
                let detail = try await body()
                note("✅ \(label)：\(detail)")
            } catch let error as PurchasesError {
                note("❌ \(label)：\(error.description)", isError: true)
                await onFailure?()
            } catch {
                note("❌ \(label)：\(error)", isError: true)
                await onFailure?()
            }
        }
    }
}
