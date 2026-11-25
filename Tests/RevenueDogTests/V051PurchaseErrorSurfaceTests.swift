//
//  V051PurchaseErrorSurfaceTests.swift
//  0.5.1（ADR 0243）：`Product.purchase` 抛出的错误一律映射成 `PurchasesError`，失败诊断统一带原因字段。
//
//  本文件是纯函数层：
//  1. 映射表逐行（真 `StoreKitError` / `Product.PurchaseError` 值）；
//  2. 模块判定 + `Mirror` 读商店错误码（本地同形结构体）；
//  3. 真 `InvalidRequestError` 实例的特征测试（没有公开构造器，按内存布局造，布局不符就跳过）；
//  4. `DiagnosticsErrorFields` 的分类表与合并口径。
//  端到端（购买流 / 五个失败事件 / 字节上限）见 V051FailureDiagnosticsTests.swift。
//

import Foundation
import Testing
#if canImport(StoreKit)
import StoreKit
#endif
@testable import RevenueDog

// MARK: - Fixtures

/// 与 `InvalidRequestError` 同形的本地类型（不在 StoreKit 模块里）。
private struct LookAlikeStoreError: Error {
    let code: Int64
    let message: String
}

/// 没有 `code` 成员的本地错误。
private struct CodelessError: Error {
    let reason: String
}

/// `code` 是 `Int` 的同形结构体（Mirror 读取也接受 `Int`）。
private struct IntCodeValue {
    let code: Int
}

/// `code` 不是整数的结构体。
private struct StringCodeValue {
    let code: String
}

private func mapped(_ error: any Error) -> PurchasesError {
    StoreKitErrorMapping.purchasesError(fromPurchaseFailure: error)
}

/// 映射出的文案：ASCII 英文（会被宿主直接显示，与 901 / 902 同一条规则）。
private func isASCIIEnglish(_ message: String) -> Bool {
    !message.isEmpty && message.unicodeScalars.allSatisfy(\.isASCII)
}

// MARK: - 1. 映射表

@Suite("0.5.1 · StoreKit 购买错误映射表（ADR 0243）")
struct V051PurchaseErrorMappingTests {

    #if canImport(StoreKit)
    @Test("StoreKitError.networkError → networkError（10），原错误进 underlyingError，文案带类别名")
    func networkErrorMapsToNetwork() throws {
        let original = StoreKitError.networkError(URLError(.notConnectedToInternet))
        let error = mapped(original)
        #expect(error.code == .networkError)
        #expect(error.code.rawValue == 10)
        let underlying = try #require(error.underlyingError as? StoreKitError)
        guard case .networkError(let urlError) = underlying else {
            Issue.record("underlyingError 应是原 StoreKitError.networkError，实得 \(underlying)")
            return
        }
        #expect(urlError.code == .notConnectedToInternet)
        #expect(error.message.contains("networkError(-1009)"))
        #expect(isASCIIEnglish(error.message))
        #expect(error.storeErrorCode == nil)
    }

    @Test("StoreKitError.notAvailableInStorefront → productNotAvailableForPurchaseError（5）")
    func notAvailableInStorefrontMapsToFive() {
        let error = mapped(StoreKitError.notAvailableInStorefront)
        #expect(error.code == .productNotAvailableForPurchaseError)
        #expect(error.code.rawValue == 5)
        #expect(error.underlyingError is StoreKitError)
        #expect(error.message.contains("notAvailableInStorefront"))
        #expect(isASCIIEnglish(error.message))
    }

    @Test("StoreKitError.unsupported → purchaseInvalidError（4）（Swift 6.1 起的 SDK + iOS 18.4 / macOS 15.4 运行时）")
    func unsupportedMapsToFour() throws {
        #if compiler(>=6.1)
        if #available(iOS 18.4, macOS 15.4, tvOS 18.4, watchOS 11.4, visionOS 2.4, *) {
            let error = mapped(StoreKitError.unsupported)
            #expect(error.code == .purchaseInvalidError)
            #expect(error.code.rawValue == 4)
            #expect(error.underlyingError is StoreKitError)
            #expect(isASCIIEnglish(error.message))
        }
        #endif
    }

    @Test("StoreKitError 其余 case → storeProblemError（2）", arguments: [
        StoreKitError.unknown,
        StoreKitError.systemError(NSError(domain: "x", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "apple secret text"])),
        StoreKitError.notEntitled,
        // 取消本该由调用方先接走；直接交进来也只是「其余 case」，不会被当成别的。
        StoreKitError.userCancelled,
    ])
    func otherStoreKitErrorsMapToTwo(original: StoreKitError) {
        let error = mapped(original)
        #expect(error.code == .storeProblemError)
        #expect(error.underlyingError is StoreKitError)
        #expect(isASCIIEnglish(error.message))
        #expect(!error.message.contains("apple secret text"))
    }

    @Test("Product.PurchaseError.purchaseNotAllowed → purchaseNotAllowedError（3），文案改英文")
    func purchaseNotAllowedMapsToThree() {
        let error = mapped(Product.PurchaseError.purchaseNotAllowed)
        #expect(error.code == .purchaseNotAllowedError)
        #expect(error.code.rawValue == 3)
        #expect(error.underlyingError is Product.PurchaseError)
        #expect(error.message.contains("purchaseNotAllowed"))
        #expect(isASCIIEnglish(error.message))
    }

    @Test("Product.PurchaseError.productUnavailable → productNotAvailableForPurchaseError（5）")
    func productUnavailableMapsToFive() {
        let error = mapped(Product.PurchaseError.productUnavailable)
        #expect(error.code == .productNotAvailableForPurchaseError)
        #expect(error.underlyingError is Product.PurchaseError)
        #expect(isASCIIEnglish(error.message))
    }

    @Test("Product.PurchaseError 其余 case → storeProblemError（2）", arguments: [
        Product.PurchaseError.invalidQuantity,
        Product.PurchaseError.ineligibleForOffer,
        Product.PurchaseError.invalidOfferIdentifier,
        Product.PurchaseError.invalidOfferPrice,
        Product.PurchaseError.invalidOfferSignature,
        Product.PurchaseError.missingOfferParameters,
    ])
    func otherPurchaseErrorsMapToTwo(original: Product.PurchaseError) {
        let error = mapped(original)
        #expect(error.code == .storeProblemError)
        #expect(error.underlyingError is Product.PurchaseError)
        #expect(isASCIIEnglish(error.message))
    }
    #endif

    @Test("不是 StoreKit 的类型 → unknownError（0），原错误保留，文案带类型名")
    func nonStoreKitErrorMapsToZero() {
        let error = mapped(CodelessError(reason: "should not leak"))
        #expect(error.code == .unknownError)
        #expect(error.code.rawValue == 0)
        #expect(error.underlyingError is CodelessError)
        #expect(error.message.contains("CodelessError"))
        #expect(!error.message.contains("should not leak"))
        #expect(isASCIIEnglish(error.message))
        // 同形但不在 StoreKit 模块里：不是商店错误，不读 code
        let lookAlike = mapped(LookAlikeStoreError(code: 1002, message: "null"))
        #expect(lookAlike.code == .unknownError)
        #expect(lookAlike.storeErrorCode == nil)
    }

    @Test("已经是 PurchasesError → 原样返回（码位 / 文案 / 后端码 / 原错误都不动）")
    func purchasesErrorPassesThrough() {
        let inner = URLError(.timedOut)
        let original = PurchasesError(code: .configurationError, message: "配置错误",
                                      backendCode: 7243, httpStatusCode: 401, underlyingError: inner)
        let error = mapped(original)
        #expect(error.code == .configurationError)
        #expect(error.message == "配置错误")
        #expect(error.backendCode == 7243)
        #expect(error.httpStatusCode == 401)
        #expect((error.underlyingError as? URLError)?.code == .timedOut)
    }

    @Test("SK2Provider 实际抛出的错误：任务取消的 CancellationError 原样透出，其余都是映射后的 PurchasesError")
    func thrownErrorLetsTaskCancellationThrough() {
        let cancelled = StoreKitErrorMapping.thrownError(fromPurchaseFailure: CancellationError())
        #expect(cancelled is CancellationError)
        #expect(!(cancelled is PurchasesError))
        let other = StoreKitErrorMapping.thrownError(fromPurchaseFailure: CodelessError(reason: "r"))
        #expect((other as? PurchasesError)?.code == .unknownError)
        #if canImport(StoreKit)
        let store = StoreKitErrorMapping.thrownError(fromPurchaseFailure: StoreKitError.notAvailableInStorefront)
        #expect((store as? PurchasesError)?.code == .productNotAvailableForPurchaseError)
        #endif
    }

    #if canImport(StoreKit)
    @Test("取消判定：StoreKitError.userCancelled 与 purchaseCancelledError 为真，其余为假")
    func cancelDetection() {
        #expect(StoreKitErrorMapping.isUserCancelled(StoreKitError.userCancelled))
        #expect(StoreKitErrorMapping.isUserCancelled(
            PurchasesError(code: .purchaseCancelledError, message: "x", underlyingError: StoreKitError.userCancelled)))
        #expect(!StoreKitErrorMapping.isUserCancelled(StoreKitError.unknown))
        #expect(!StoreKitErrorMapping.isUserCancelled(Product.PurchaseError.purchaseNotAllowed))
        #expect(!StoreKitErrorMapping.isUserCancelled(CancellationError()))
        #expect(!StoreKitErrorMapping.isUserCancelled(PurchasesError(code: .storeProblemError, message: "x")))
    }
    #endif
}

// MARK: - 2. 模块判定 + Mirror 读取

@Suite("0.5.1 · StoreKit 模块判定与商店错误码读取（ADR 0243 决定 3）")
struct V051StoreErrorCodeReadingTests {

    @Test("模块判定：真 StoreKit 错误为真，本地类型 / Foundation 错误为假")
    func moduleRule() {
        #if canImport(StoreKit)
        #expect(StoreKitErrorMapping.isStoreKitModuleError(StoreKitError.unknown))
        #expect(StoreKitErrorMapping.isStoreKitModuleError(Product.PurchaseError.productUnavailable))
        #endif
        #expect(!StoreKitErrorMapping.isStoreKitModuleError(LookAlikeStoreError(code: 1, message: "m")))
        #expect(!StoreKitErrorMapping.isStoreKitModuleError(URLError(.timedOut)))
        #expect(!StoreKitErrorMapping.isStoreKitModuleError(CancellationError()))
        #expect(!StoreKitErrorMapping.isStoreKitModuleError(PurchasesError(code: .storeProblemError, message: "x")))
    }

    @Test("Mirror 读取：Int64 / Int 的 code 读得到；没有 code 或 code 不是整数则为 nil")
    func mirrorRead() {
        #expect(StoreKitErrorMapping.integerCodeMember(of: LookAlikeStoreError(code: 1002, message: "null")) == 1002)
        #expect(StoreKitErrorMapping.integerCodeMember(of: IntCodeValue(code: 7)) == 7)
        #expect(StoreKitErrorMapping.integerCodeMember(of: CodelessError(reason: "r")) == nil)
        #expect(StoreKitErrorMapping.integerCodeMember(of: StringCodeValue(code: "1002")) == nil)
        // 作为 `any Error` 交进去（生产调用的形态）也读得到
        let existential: any Error = LookAlikeStoreError(code: -5, message: "m")
        #expect(StoreKitErrorMapping.integerCodeMember(of: existential) == -5)
    }

    @Test("商店错误码只认 StoreKit 模块：同形本地类型读不到；StoreKitError 的 case 没有 code")
    func storeErrorCodeRequiresStoreKitModule() {
        #expect(StoreKitErrorMapping.storeErrorCode(of: LookAlikeStoreError(code: 1002, message: "null")) == nil)
        #if canImport(StoreKit)
        #expect(StoreKitErrorMapping.storeErrorCode(of: StoreKitError.unknown) == nil)
        #expect(StoreKitErrorMapping.storeErrorCode(of: StoreKitError.networkError(URLError(.timedOut))) == nil)
        #endif
    }

    @Test("类别名：沿包装链走到最里层；URLError 带码；其它取类型名；链上没有原错误为 nil")
    func underlyingNames() {
        #if canImport(StoreKit)
        #expect(StoreKitErrorMapping.underlyingName(of: StoreKitError.networkError(URLError(.notConnectedToInternet)))
                == "networkError(-1009)")
        #expect(StoreKitErrorMapping.underlyingName(of: StoreKitError.systemError(CodelessError(reason: "secret")))
                == "systemError")
        #expect(StoreKitErrorMapping.underlyingName(of: Product.PurchaseError.invalidQuantity) == "invalidQuantity")
        // 两层包装（901 的形状）
        let twoLevels = PurchasesError(code: .purchasePendingServerConfirmation, message: "a",
                                       underlyingError: PurchasesError(code: .storeProblemError, message: "b",
                                                                       underlyingError: StoreKitError.notEntitled))
        #expect(StoreKitErrorMapping.underlyingName(of: twoLevels) == "notEntitled")
        #endif
        #expect(StoreKitErrorMapping.underlyingName(of: URLError(.timedOut)) == "URLError(-1001)")
        #expect(StoreKitErrorMapping.underlyingName(
            of: PurchasesError.network("x", underlying: URLError(.cannotFindHost))) == "URLError(-1003)")
        #expect(StoreKitErrorMapping.underlyingName(of: CancellationError()) == "CancellationError")
        #expect(StoreKitErrorMapping.underlyingName(of: LookAlikeStoreError(code: 1, message: "m"))
                == "LookAlikeStoreError")
        #expect(StoreKitErrorMapping.underlyingName(of: PurchasesError(code: .storeProblemError, message: "x")) == nil)
    }

    @Test("包装链深度封顶：4 层以内找得到原错误，超过就当没有（不猜、不死循环）")
    func chainDepthIsBounded() {
        func wrap(_ error: any Error, times: Int) -> any Error {
            var current = error
            for index in 0..<times {
                current = PurchasesError(code: .unknownError, message: "layer \(index)", underlyingError: current)
            }
            return current
        }
        #expect(StoreKitErrorMapping.underlyingName(of: wrap(CancellationError(), times: 4)) == "CancellationError")
        #expect(StoreKitErrorMapping.chain(of: wrap(CancellationError(), times: 4)).layers.count == 4)
        #expect(StoreKitErrorMapping.underlyingName(of: wrap(CancellationError(), times: 5)) == nil)
    }
}

// MARK: - 3. 真 InvalidRequestError 实例（特征测试）

#if canImport(StoreKit) && compiler(>=6.1)
/// `InvalidRequestError` 没有公开构造器（ADR 0243「核到的事实」），也不能用 StoreKitTest 注入。
/// 按 `{ code: Int64, message: String }` 的布局造一个真实例；布局与 `(Int64, String)` 不符就整条跳过，绝不硬造。
private enum InvalidRequestErrorProbe {

    static var layoutMatches: Bool {
        guard #available(iOS 18.4, macOS 15.4, tvOS 18.4, watchOS 11.4, visionOS 2.4, *) else { return false }
        return MemoryLayout<InvalidRequestError>.size == MemoryLayout<(Int64, String)>.size
            && MemoryLayout<InvalidRequestError>.stride == MemoryLayout<(Int64, String)>.stride
            && MemoryLayout<InvalidRequestError>.alignment == MemoryLayout<(Int64, String)>.alignment
    }
}

@Suite("0.5.1 · 真 InvalidRequestError 的映射（特征测试，布局不符即跳过）")
struct V051InvalidRequestErrorCharacterizationTests {

    @Test("InvalidRequestError(code: 1002) → storeProblemError（2）+ storeErrorCode 1002 + 类别名；文案带码、不带 Apple 文案",
          .enabled(if: InvalidRequestErrorProbe.layoutMatches,
                   "需要 iOS 18.4 / macOS 15.4 运行时，且 InvalidRequestError 的布局与 (Int64, String) 一致"))
    func realInvalidRequestError() throws {
        guard #available(iOS 18.4, macOS 15.4, tvOS 18.4, watchOS 11.4, visionOS 2.4, *) else {
            Issue.record("trait 已保证运行时可用，不应走到这里")
            return
        }
        let original = unsafeBitCast((Int64(1002), "null"), to: InvalidRequestError.self)
        // 自检：造出来的值反射得到的正是这两个成员（宿主日志里 `InvalidRequestError(code: 1002, message: "null")` 的形状）
        #expect(StoreKitErrorMapping.integerCodeMember(of: original) == 1002)
        #expect(StoreKitErrorMapping.isStoreKitModuleError(original))

        let error = mapped(original)
        #expect(error.code == .storeProblemError)
        #expect(error.code.rawValue == 2)
        #expect(error.storeErrorCode == 1002)
        #expect(error.underlyingError is InvalidRequestError)
        #expect(StoreKitErrorMapping.underlyingName(of: error) == "InvalidRequestError")
        #expect(error.message == "The App Store could not complete the purchase (InvalidRequestError, code 1002).")
        #expect(!error.message.contains("null"))
        #expect(isASCIIEnglish(error.message))

        let fields = DiagnosticsErrorFields.of(error)
        #expect(fields["error_code"] == .string("storeProblemError"))
        #expect(fields["error_class"] == .string("billing"))
        #expect(fields["underlying"] == .string("InvalidRequestError"))
        #expect(fields["store_error_code"] == .int(1002))
    }
}
#endif

// MARK: - 4. DiagnosticsErrorFields 分类表

@Suite("0.5.1 · 失败诊断的原因字段（DiagnosticsErrorFields，ADR 0243 决定 5）")
struct V051DiagnosticsErrorFieldsTests {

    private func field(_ error: (any Error)?, _ key: String) -> DiagnosticsFieldValue? {
        DiagnosticsErrorFields.of(error)[key] ?? nil
    }

    private func errorClass(_ error: any Error) -> String {
        DiagnosticsErrorFields.classify(error)
    }

    private func httpError(_ status: Int, payload: String = #"{"message":"boom"}"#) -> PurchasesError {
        HTTPClient.error(statusCode: status, payload: Data(payload.utf8), decoder: HTTPClient.makeResponseDecoder())
    }

    @Test("HTTP 状态码三档：401 / 403 → auth，422 → client，503 → server；status / backend_code 带上")
    func httpStatusClasses() {
        #expect(errorClass(httpError(401)) == "auth")
        #expect(errorClass(httpError(403)) == "auth")
        #expect(errorClass(httpError(422)) == "client")
        #expect(errorClass(httpError(503)) == "server")
        let withBackendCode = httpError(401, payload: #"{"code":7243,"message":"secret key in app"}"#)
        #expect(field(withBackendCode, "status") == .int(401))
        #expect(field(withBackendCode, "backend_code") == .int(7243))
        #expect(field(withBackendCode, "error_code") == .string("invalidCredentialsError"))
        #expect(field(withBackendCode, "underlying") == nil)
        // 400 的码位是解析类，但有状态码：④ 排在 ⑤ 前面 → client（与 Android 同序）
        #expect(errorClass(httpError(400)) == "client")
    }

    @Test("网络：URLError(.timedOut) → timeout；URLError(.notConnectedToInternet) → network")
    func networkAndTimeout() {
        let timedOut = PurchasesError.network("x", underlying: URLError(.timedOut))
        #expect(errorClass(timedOut) == "timeout")
        #expect(field(timedOut, "underlying") == .string("URLError(-1001)"))
        let offline = PurchasesError.network("x", underlying: URLError(.notConnectedToInternet))
        #expect(errorClass(offline) == "network")
        #expect(field(offline, "underlying") == .string("URLError(-1009)"))
        #expect(errorClass(PurchasesError(code: .offlineConnectionError, message: "x")) == "network")
        // 裸 URLError（不是 PurchasesError）：码位是 unknownError，只有超时那一档能命中
        #expect(errorClass(URLError(.timedOut)) == "timeout")
        #expect(errorClass(URLError(.notConnectedToInternet)) == "unknown")
    }

    @Test("解析 / 配置：unexpectedBackendResponseError（解码失败）→ parse，configurationError → config")
    func parseAndConfig() {
        let decoding = PurchasesError.decoding("x", underlying: DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "secret body text")))
        #expect(errorClass(decoding) == "parse")
        #expect(field(decoding, "error_code") == .string("unexpectedBackendResponseError"))
        #expect(field(decoding, "underlying") == .string("DecodingError"))
        #expect(errorClass(PurchasesError(code: .customerInfoError, message: "x")) == "parse")
        #expect(errorClass(PurchasesError.configuration("x")) == "config")
        #expect(errorClass(PurchasesError(code: .invalidAppUserIdError, message: "x")) == "config")
        #expect(errorClass(PurchasesError(code: .notImplementedError, message: "x")) == "config")
    }

    #if canImport(StoreKit)
    @Test("商店：映射出的 storeProblemError（StoreKitError.unknown）→ billing，underlying = unknown")
    func storeProblemIsBilling() {
        let error = mapped(StoreKitError.unknown)
        #expect(field(error, "error_code") == .string("storeProblemError"))
        #expect(field(error, "error_class") == .string("billing"))
        #expect(field(error, "underlying") == .string("unknown"))
        #expect(field(error, "store_error_code") == nil)
    }

    @Test("商店：映射出的 StoreKitError.networkError(-1009) → networkError / network / networkError(-1009)")
    func storeKitNetworkErrorIsNetwork() {
        let error = mapped(StoreKitError.networkError(URLError(.notConnectedToInternet)))
        #expect(field(error, "error_code") == .string("networkError"))
        #expect(field(error, "error_class") == .string("network"))
        #expect(field(error, "underlying") == .string("networkError(-1009)"))
    }

    @Test("恢复时的取消（purchaseCancelledError over StoreKitError.userCancelled）→ billing，underlying = userCancelled")
    func restoreCancelIsBilling() {
        let error = PurchasesError(code: .purchaseCancelledError, message: "x", underlyingError: StoreKitError.userCancelled)
        #expect(field(error, "error_class") == .string("billing"))
        #expect(field(error, "underlying") == .string("userCancelled"))
    }
    #endif

    @Test("带商店错误码 → billing（① 最先判），store_error_code 是整数；包进 901 也找得到")
    func storeErrorCodeWinsAndIsFoundAlongChain() {
        let withCode = PurchasesError(code: .storeProblemError, message: "x", storeErrorCode: 1002)
        #expect(field(withCode, "error_class") == .string("billing"))
        #expect(field(withCode, "store_error_code") == .int(1002))
        // ① 排在 ② 前面：即使原错误是超时，带商店码就是 billing
        let codeOverTimeout = PurchasesError(code: .networkError, message: "x",
                                             underlyingError: URLError(.timedOut), storeErrorCode: 7)
        #expect(field(codeOverTimeout, "error_class") == .string("billing"))
        let wrapped = PurchasesError(code: .purchasePendingServerConfirmation, message: "x", underlyingError: withCode)
        #expect(field(wrapped, "store_error_code") == .int(1002))
        #expect(field(wrapped, "error_class") == .string("billing"))
    }

    @Test("901 由超时构成（两层包装）→ timeout；902 由 422 构成 → client")
    func postFailureErrorsClassifyByCause() throws {
        let timeout = PurchasesError.network("网络请求失败：/v1/receipts", underlying: URLError(.timedOut))
        let pending = PurchasesOrchestrator.postFailureError(.pendingServerConfirmation(timeout), transactionID: "tx-1")
        #expect(pending.code == .purchasePendingServerConfirmation)
        #expect(field(pending, "error_code") == .string("purchasePendingServerConfirmation"))
        #expect(field(pending, "error_class") == .string("timeout"))
        #expect(field(pending, "underlying") == .string("URLError(-1001)"))

        let rejected = PurchasesOrchestrator.postFailureError(.rejectedByServer(httpError(422)), transactionID: "tx-2")
        #expect(rejected.code == .purchaseRejectedByServer)
        #expect(field(rejected, "error_class") == .string("client"))
        #expect(field(rejected, "status") == .int(422))
        #expect(field(rejected, "underlying") == nil)
    }

    @Test("裸 CancellationError → error_code = unknownError、underlying = CancellationError、class = unknown")
    func bareCancellation() {
        let fields = DiagnosticsErrorFields.of(CancellationError())
        #expect(fields["error_code"] == .string("unknownError"))
        #expect(fields["underlying"] == .string("CancellationError"))
        #expect(fields["error_class"] == .string("unknown"))
        #expect((fields["status"] ?? nil) == nil)
        #expect((fields["store_error_code"] ?? nil) == nil)
    }

    @Test("没有错误 → 空字典，一个键都不出")
    func nilErrorYieldsNoKeys() {
        #expect(DiagnosticsErrorFields.of(nil).isEmpty)
        #expect(DiagnosticsErrorFields.merging(["duration_ms": .int(5)], error: nil) == ["duration_ms": .int(5)])
    }

    @Test("合并口径：调用点的非 nil 值一个字不动，nil 或缺的键才由原因字段补")
    func mergingKeepsCallSiteValues() {
        let error = httpError(401)
        let merged = DiagnosticsErrorFields.merging([
            "status": .int(999),                 // 调用点有值 → 保留
            "request_id": .string("req-1"),
            "backend_code": nil,                 // 调用点显式 nil → 补
            "products_error_code": .string("storeProblemError"),
        ], error: error)
        #expect((merged["status"] ?? nil) == .int(999))
        #expect((merged["request_id"] ?? nil) == .string("req-1"))
        #expect((merged["products_error_code"] ?? nil) == .string("storeProblemError"))
        #expect((merged["error_code"] ?? nil) == .string("invalidCredentialsError"))
        #expect((merged["error_class"] ?? nil) == .string("auth"))
        // 401 的 body 没有数值码：backend_code 仍为 nil（由 DiagnosticsEvent.make 丢掉）
        #expect((merged["backend_code"] ?? nil) == nil)
    }

    @Test("classify 只会返回契约 §1.3 的九个值")
    func classifyStaysInVocabulary() {
        var samples: [any Error] = [
            CancellationError(), URLError(.timedOut), URLError(.badURL),
            PurchasesError(code: .unknownError, message: "x"),
            PurchasesError(code: .receiptAlreadyInUseError, message: "x"),
            PurchasesError(code: .unknownBackendError, message: "x"),
            PurchasesError(code: .systemInfoError, message: "x"),
            PurchasesError(code: .purchaseRejectedByServer, message: "x"),
            PurchasesError(code: .purchasePendingServerConfirmation, message: "x"),
            PurchasesError(code: .unknown(rawValue: 9999), message: "x"),
        ]
        samples.append(contentsOf: [401, 404, 429, 500, 302].map { httpError($0) })
        for sample in samples {
            #expect(DiagnosticsErrorFields.allClasses.contains(errorClass(sample)), "\(sample)")
        }
        #expect(DiagnosticsErrorFields.allClasses
                == ["network", "timeout", "auth", "client", "server", "billing", "parse", "config", "unknown"])
    }
}
