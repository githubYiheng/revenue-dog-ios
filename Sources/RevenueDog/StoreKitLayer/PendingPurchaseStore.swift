//
//  PendingPurchaseStore.swift
//  购买上下文抗崩溃持久化（设计 §3 铁律 P3）。
//
//  P3：购买上下文**先落盘再发起购买**，成功或终态错误才删；前台恢复时串行重放未完成项。
//
//  落盘位置：Application Support（绝不 Documents）。
//  文件名：sha256(key) —— key 是 transactionId（拿到之后）或 productId（发起购买时还没有 tx id）。
//  哈希文件名的作用：产品/交易 ID 不进文件系统明文，且长度/字符集恒定合法。
//

import Foundation
import CryptoKit

// MARK: - 购买发起来源

/// 契约 §2.1：`initiation_source ∈ purchase / restore / queue`。禁 public enum → struct + static。
public struct InitiationSource: Sendable, Hashable, Codable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let purchase = InitiationSource(rawValue: "purchase")
    public static let restore = InitiationSource(rawValue: "restore")
    public static let queue = InitiationSource(rawValue: "queue")

    public var description: String { rawValue }
}

// MARK: - 上下文

/// 一笔待完成购买的全部上下文。崩溃/杀进程后靠它把交易补回后端。
struct PendingPurchaseContext: Codable, Sendable, Equatable {

    /// 存储键：拿到 transactionId 就用它；发起购买那一刻只有 productId。
    let key: String
    let productIdentifier: String
    let appUserID: String
    /// 展示该商品的 offering（契约 §2.1 `presented_offering_identifier`）。
    let presentedOfferingIdentifier: String?
    let presentedPackageIdentifier: String?
    /// 我们写进 `appAccountToken` 的 32 hex 令牌。
    let accountToken: String?
    let initiationSource: InitiationSource
    let createdAt: Date
    /// 重放次数 —— 用于退避与「反复失败」告警。
    var replayCount: Int
    /// 交易 JWS 原文（rekey 到 transactionId 时写入）：崩溃在「拿到交易后、上报成功前」也能凭它重放。
    var jws: String?
    /// **发起这笔购买时**的完成者模式快照（迁移方案 v2.1 §5 M-2a）。
    ///
    /// `purchasesCompletedBy` 运行时可写之后，「谁 finish」不能再在交易回流时才现读 ——
    /// 否则宿主在购买弹窗还开着的时候翻开关，这笔在途购买就会换一套 finish 语义
    /// （最坏情况：Dog 发起、Dog 上报，却因为切到 `.myApp` 而永不 finish → 交易挂着）。
    /// 落盘保证跨崩溃重放也用同一份快照。nil = 老版本写下的上下文 / 非 Dog 发起 → 回落当前运行时值。
    let completedBy: PurchasesCompletedBy?

    init(key: String,
         productIdentifier: String,
         appUserID: String,
         presentedOfferingIdentifier: String? = nil,
         presentedPackageIdentifier: String? = nil,
         accountToken: String? = nil,
         initiationSource: InitiationSource = .purchase,
         createdAt: Date = Date(),
         replayCount: Int = 0,
         jws: String? = nil,
         completedBy: PurchasesCompletedBy? = nil) {
        self.completedBy = completedBy
        self.key = key
        self.productIdentifier = productIdentifier
        self.appUserID = appUserID
        self.presentedOfferingIdentifier = presentedOfferingIdentifier
        self.presentedPackageIdentifier = presentedPackageIdentifier
        self.accountToken = accountToken
        self.initiationSource = initiationSource
        self.createdAt = createdAt
        self.replayCount = replayCount
        self.jws = jws
    }
}

// MARK: - Store

actor PendingPurchaseStore {

    private let directory: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
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
        try SDKFileLocations.subdirectory(named: "PendingPurchases")
    }

    // MARK: 纯函数

    /// 文件名 = sha256(key) 的小写 hex。
    static func fileName(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined() + ".json"
    }

    nonisolated func url(forKey key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(forKey: key), isDirectory: false)
    }

    // MARK: 读写

    /// 落盘（原子写）。**必须在 `product.purchase()` 之前完成**（铁律 P3）。
    func save(_ context: PendingPurchaseContext) throws {
        do {
            try SDKFileLocations.ensureDirectory(directory)
            let data = try encoder.encode(context)
            try data.write(to: url(forKey: context.key), options: .atomic)
            Log.debug("落盘购买上下文 key=\(context.key) product=\(context.productIdentifier)",
                      category: "pending")
        } catch {
            throw PurchasesError(code: .unknownError,
                                 message: "购买上下文落盘失败（key=\(context.key)）",
                                 underlyingError: error)
        }
    }

    func context(forKey key: String) -> PendingPurchaseContext? {
        guard let data = try? Data(contentsOf: url(forKey: key)) else { return nil }
        do {
            return try decoder.decode(PendingPurchaseContext.self, from: data)
        } catch {
            Log.warn("购买上下文解码失败，丢弃（key=\(key)）: \(error)", category: "pending")
            remove(forKey: key)
            return nil
        }
    }

    /// 删除。**只在后端 200 落库成功或终态错误后调用**（铁律 P2/P3）。
    func remove(forKey key: String) {
        try? FileManager.default.removeItem(at: url(forKey: key))
    }

    /// 枚举全部未完成项（按落盘时间升序，前台恢复时**串行**重放）。
    func all() -> [PendingPurchaseContext] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> PendingPurchaseContext? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(PendingPurchaseContext.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 交易 id 就位后把 key 从「发起键」迁到 transactionId，并写入 JWS（同一笔上下文换键）。
    @discardableResult
    func rekey(from oldKey: String, to newKey: String, jws: String? = nil) throws -> PendingPurchaseContext? {
        guard let existing = context(forKey: oldKey) else { return nil }
        let context = PendingPurchaseContext(key: newKey,
                                             productIdentifier: existing.productIdentifier,
                                             appUserID: existing.appUserID,
                                             presentedOfferingIdentifier: existing.presentedOfferingIdentifier,
                                             presentedPackageIdentifier: existing.presentedPackageIdentifier,
                                             accountToken: existing.accountToken,
                                             initiationSource: existing.initiationSource,
                                             createdAt: existing.createdAt,
                                             replayCount: existing.replayCount,
                                             jws: jws ?? existing.jws,
                                             completedBy: existing.completedBy) // M-2a：换键不换模式快照
        try save(context)
        remove(forKey: oldKey)
        return context
    }

    /// 匹配「发起键」上下文（坑矩阵裁决 #15/#16）：同商品取**最早**且 `createdAt <= purchaseDate` 的一笔。
    /// 复合发起键 = `pending:<productId>#<seq>`，同商品并发购买互不覆盖。
    static func initiationKey(productIdentifier: String) -> String {
        "pending:\(productIdentifier)#\(UUID().uuidString.prefix(8))"
    }

    func matchInitiation(productIdentifier: String, purchaseDate: Date) -> PendingPurchaseContext? {
        all()
            .filter {
                $0.key.hasPrefix("pending:\(productIdentifier)#")
                    && $0.createdAt <= purchaseDate.addingTimeInterval(60) // 时钟余量 1 分钟
            }
            .first
    }

    /// 重放计数 +1 并回写。
    @discardableResult
    func incrementReplayCount(forKey key: String) throws -> PendingPurchaseContext? {
        guard var context = context(forKey: key) else { return nil }
        context.replayCount += 1
        try save(context)
        return context
    }

    func removeAll() {
        for context in all() { remove(forKey: context.key) }
    }
}
