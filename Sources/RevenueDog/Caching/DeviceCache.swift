//
//  DeviceCache.swift
//  CustomerInfo / Offerings 缓存骨架（设计 §4）。
//
//  M1 范围：键规则、TTL 常量、staleness 判定、requestDate 3 天 grace —— 全是纯逻辑，可单测。
//  磁盘落盘用 Application Support（**绝不 Documents**），键含 appUserID 哈希，logOut 即隔离。
//

import Foundation
import CryptoKit

// MARK: - 3 天 grace（设计 §4「必抄」）

/// 权益到期判定的参照时间。
///
/// - 服务端 `request_date` 之后 **3 天内**：一律用服务端时间，不信本地时钟
///   （抗「改时区/往回拨表」薅羊毛；本地钟被拨到过去时 `elapsed < 0`，同样走服务端时间）。
/// - 超过 3 天：回退本地时钟（防「永久离线白嫖」）。
enum EntitlementGracePolicy {

    /// 3 天。
    static let gracePeriod: TimeInterval = 3 * 24 * 60 * 60

    static func referenceDate(requestDate: Date?,
                              now: Date,
                              gracePeriod: TimeInterval = EntitlementGracePolicy.gracePeriod) -> Date {
        guard let requestDate else { return now }
        let elapsed = now.timeIntervalSince(requestDate)
        // 缓存太旧 → 回退本地钟；否则（含本地钟被拨回过去）一律信服务端时间。
        return elapsed > gracePeriod ? now : requestDate
    }

    /// 缓存是否已超出 grace（超出后权益判定回落本地时钟）。
    static func isBeyondGrace(requestDate: Date?,
                              now: Date,
                              gracePeriod: TimeInterval = EntitlementGracePolicy.gracePeriod) -> Bool {
        guard let requestDate else { return true }
        return now.timeIntervalSince(requestDate) > gracePeriod
    }
}

// MARK: - TTL

enum CacheTTL {

    /// 前台 5 分钟（RC 同款）。
    static let foreground: TimeInterval = 5 * 60
    /// 后台 25 小时（RC 同款）。
    static let background: TimeInterval = 25 * 60 * 60

    static func ttl(isAppBackgrounded: Bool) -> TimeInterval {
        isAppBackgrounded ? background : foreground
    }

    /// 缓存是否过期。
    static func isStale(cachedAt: Date?, now: Date, isAppBackgrounded: Bool) -> Bool {
        guard let cachedAt else { return true }
        let age = now.timeIntervalSince(cachedAt)
        // 本地钟被拨到过去 → age < 0 → 视为过期，宁可多刷一次。
        if age < 0 { return true }
        return age >= ttl(isAppBackgrounded: isAppBackgrounded)
    }
}

// MARK: - 缓存键

enum CacheKey {

    /// 键含 appUserID 哈希（设计 §4）：不把明文用户 ID 写进文件名 / UserDefaults 键。
    static func hash(appUserID: String) -> String {
        SHA256.hash(data: Data(appUserID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func customerInfo(appUserID: String) -> String {
        "customer-info.\(hash(appUserID: appUserID))"
    }

    static func offerings(appUserID: String) -> String {
        "offerings.\(hash(appUserID: appUserID))"
    }
}

// MARK: - DeviceCache

/// 设计 §6：全 actor 化，零自定义锁。
actor DeviceCache {

    struct Entry<Value: Codable & Sendable>: Codable, Sendable {
        let value: Value
        let cachedAt: Date
    }

    private let storage: any CacheStorage
    private var customerInfoEntries: [String: Entry<CustomerInfo>] = [:]
    private var offeringsEntries: [String: Entry<Offerings>] = [:]
    /// `invalidateCustomerInfoCache()` 打的强制失效标记（按 appUserID 哈希键）。
    private var invalidatedCustomerInfoKeys: Set<String> = []

    init(storage: any CacheStorage) {
        self.storage = storage
    }

    // MARK: CustomerInfo

    func cachedCustomerInfo(appUserID: String) async -> CustomerInfo? {
        await entryForCustomerInfo(appUserID: appUserID)?.value
    }

    /// 是否需要刷新。5xx 时上层可以忽略这个判定直接供给 stale 缓存（设计 §4）。
    func isCustomerInfoStale(appUserID: String, now: Date = Date(), isAppBackgrounded: Bool) async -> Bool {
        let key = CacheKey.customerInfo(appUserID: appUserID)
        if invalidatedCustomerInfoKeys.contains(key) { return true }
        let entry = await entryForCustomerInfo(appUserID: appUserID)
        return CacheTTL.isStale(cachedAt: entry?.cachedAt, now: now, isAppBackgrounded: isAppBackgrounded)
    }

    func cache(customerInfo: CustomerInfo, appUserID: String, now: Date = Date()) async {
        let key = CacheKey.customerInfo(appUserID: appUserID)
        let entry = Entry(value: customerInfo, cachedAt: now)
        customerInfoEntries[key] = entry
        invalidatedCustomerInfoKeys.remove(key)
        await storage.write(entry, forKey: key)
    }

    func invalidateCustomerInfoCache(appUserID: String) {
        invalidatedCustomerInfoKeys.insert(CacheKey.customerInfo(appUserID: appUserID))
    }

    private func entryForCustomerInfo(appUserID: String) async -> Entry<CustomerInfo>? {
        let key = CacheKey.customerInfo(appUserID: appUserID)
        if let entry = customerInfoEntries[key] { return entry }
        guard let entry: Entry<CustomerInfo> = await storage.read(forKey: key) else { return nil }
        customerInfoEntries[key] = entry
        return entry
    }

    // MARK: Offerings

    func cachedOfferings(appUserID: String) async -> Offerings? {
        await entryForOfferings(appUserID: appUserID)?.value
    }

    func isOfferingsStale(appUserID: String, now: Date = Date(), isAppBackgrounded: Bool) async -> Bool {
        let entry = await entryForOfferings(appUserID: appUserID)
        return CacheTTL.isStale(cachedAt: entry?.cachedAt, now: now, isAppBackgrounded: isAppBackgrounded)
    }

    func cache(offerings: Offerings, appUserID: String, now: Date = Date()) async {
        let key = CacheKey.offerings(appUserID: appUserID)
        let entry = Entry(value: offerings, cachedAt: now)
        offeringsEntries[key] = entry
        await storage.write(entry, forKey: key)
    }

    private func entryForOfferings(appUserID: String) async -> Entry<Offerings>? {
        let key = CacheKey.offerings(appUserID: appUserID)
        if let entry = offeringsEntries[key] { return entry }
        guard let entry: Entry<Offerings> = await storage.read(forKey: key) else { return nil }
        offeringsEntries[key] = entry
        return entry
    }

    // MARK: 清理

    /// logOut 时把当前身份的缓存从内存里摘掉（磁盘上的按哈希键天然隔离）。
    func clearMemoryCache(appUserID: String) {
        customerInfoEntries.removeValue(forKey: CacheKey.customerInfo(appUserID: appUserID))
        offeringsEntries.removeValue(forKey: CacheKey.offerings(appUserID: appUserID))
    }
}

// MARK: - CacheStorage

/// 缓存持久化后端。设计 §6 铁律 3：I/O 依赖单独 actor 隔离，不放进被保护状态里同步调用。
protocol CacheStorage: Sendable {
    func read<Value: Codable & Sendable>(forKey key: String) async -> DeviceCache.Entry<Value>?
    func write<Value: Codable & Sendable>(_ entry: DeviceCache.Entry<Value>, forKey key: String) async
    func remove(forKey key: String) async
}

/// Application Support 落盘（**绝不 Documents**，设计 §4）。
actor FileCacheStorage: CacheStorage {

    private let directory: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() throws -> URL {
        try SDKFileLocations.subdirectory(named: "Cache")
    }

    private func url(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    func read<Value: Codable & Sendable>(forKey key: String) -> DeviceCache.Entry<Value>? {
        guard let data = try? Data(contentsOf: url(forKey: key)) else { return nil }
        do {
            return try decoder.decode(DeviceCache.Entry<Value>.self, from: data)
        } catch {
            Log.warn("缓存解码失败，丢弃（key=\(key)）: \(error)", category: "cache")
            try? FileManager.default.removeItem(at: url(forKey: key))
            return nil
        }
    }

    func write<Value: Codable & Sendable>(_ entry: DeviceCache.Entry<Value>, forKey key: String) {
        do {
            try SDKFileLocations.ensureDirectory(directory)
            let data = try encoder.encode(entry)
            try data.write(to: url(forKey: key), options: .atomic)
        } catch {
            Log.warn("缓存写入失败（key=\(key)）: \(error)", category: "cache")
        }
    }

    func remove(forKey key: String) {
        try? FileManager.default.removeItem(at: url(forKey: key))
    }
}

/// 纯内存缓存后端（单测 / 无磁盘可用时的兜底）。
actor InMemoryCacheStorage: CacheStorage {

    private var storage: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {}

    func read<Value: Codable & Sendable>(forKey key: String) -> DeviceCache.Entry<Value>? {
        guard let data = storage[key] else { return nil }
        return try? decoder.decode(DeviceCache.Entry<Value>.self, from: data)
    }

    func write<Value: Codable & Sendable>(_ entry: DeviceCache.Entry<Value>, forKey key: String) {
        storage[key] = try? encoder.encode(entry)
    }

    func remove(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}

// MARK: - 目录

enum SDKFileLocations {

    /// `<Application Support>/RevenueDog/<name>`。绝不落 Documents（会被 iCloud 备份/用户可见）。
    static func subdirectory(named name: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let url = base
            .appendingPathComponent("RevenueDog", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try ensureDirectory(url)
        return url
    }

    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // 缓存/待处理交易不该进 iCloud 备份。
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
