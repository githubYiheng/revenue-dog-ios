# RevenueDog iOS SDK

Revenue Dog 的 iOS 客户端 SDK：自建 RevenueCat 式内购后端的 StoreKit 2 SDK，接口命名与 RevenueCat 兼容以便迁移。MIT 许可。

## 安装（SwiftPM）

```swift
.package(url: "https://github.com/githubYiheng/revenue-dog-ios.git", from: "0.1.0")
```

Xcode：File → Add Package Dependencies… → 填上面的 URL，规则选 "Up to Next Major"。

> **这个仓库是发布产物，不接受 PR。** 开发在私有 monorepo 的 `sdk/ios` 目录进行，每次发布用
> `git subtree split` 推到这里并打 `vX.Y.Z` tag（历史保留）。下文提到的 `docs/…` 路径都指 monorepo 内的设计文档，本仓库不含。
> 版本纪律见 `CHANGELOG.md`。

## 概览

SwiftPM 包，Swift 6 严格并发，**产品基线 iOS 16**。
`Package.swift` 里的 `macOS 13` 只是为了让纯逻辑单测能在开发机上直接 `swift test`
（StoreKit 相关代码用 `#if canImport(StoreKit)` + `@available` 门控）。

设计与坑矩阵：
- `docs/plan/ios-sdk-design.md`
- `docs/plan/ios-sdk-pitfall-matrix.md`
- 门禁报告：`docs/audit/2026-08-28-sdk-m2-gate.md`

## 宿主接线要点

### 商品文案：`Package.storeProduct`（0.2.0 起不再恒 nil）

`offerings()` 会用 StoreKit 2 一次批量把商品详情填进每个 `Package`。做定价文案直接读它：

```swift
guard let package = try await Purchases.shared.offerings().current?.monthly,
      let product = package.storeProduct else { return }   // nil = 商店里查不到这个商品

product.displayPrice              // "¥68.00"（== localizedPriceString，StoreKit 2 命名别名）
product.price                     // Decimal(68)
product.currencyCode              // "CNY"
product.subscriptionPeriod        // SubscriptionPeriod(unit: .month, value: 1)
if let offer = product.introductoryOffer, offer.isEligible {
    // offer.type ∈ .freeTrial / .payAsYouGo / .payUpFront
    // offer.period（单个周期）/ offer.periodCount（重复几次）/ offer.displayPrice
    // payAsYouGo 的文案要两者一起用："\(offer.displayPrice) / \(offer.period)" × periodCount
}
```

> `storeProduct == nil` = 后端 offerings 里配了、但 App Store 查不到（ASC 没建 / 没过审 / 地区不售）。
> 这一条同时会进诊断事件 `offerings_fetch.not_found_product_ids`，后台可直接查到是哪几个 id。
> `introductoryOffer.isEligible` 是**订阅组级**且端上不可信的判定（坑 #91 / 裁决 #124）——
> 只用来决定 UI 上显不显示优惠文案，**计费与权益一律以服务端为准**。

### 购买结果：`isPending` 与扣款后的两个错误码

```swift
do {
    let result = try await Purchases.shared.purchase(package: package)
    if result.userCancelled {
        // 用户自己取消，什么都不用做
    } else if result.isPending {
        // Ask-to-Buy（家长同意）/ SCA（银行验证）：transactionIdentifier == nil
        // **不要**发权益、**不要**报错；提示「等待批准」，监听 customerInfoStream 等结果
    } else {
        // 已上报后端并落库，result.customerInfo 就是最新权益
    }
} catch let error as PurchasesError {
    switch error.code {
    case .purchasePendingServerConfirmation:
        // 钱扣了、后端暂时没确认（5xx / 断网 / 401 / 403 / 408 / 429）。
        // 交易**未 finish**、上下文已落盘，SDK 会自动重放。
        // 提示「支付已收到，权益稍后到账」，**绝不要**引导用户再买一次。
    case .purchaseRejectedByServer:
        // 钱扣了、后端确定性拒绝（确定性 4xx）。交易**已 finish**，不会再有权益。
        // 这是要人看的状态：走客服 / 退款路径，别静默吞掉。
        // (error.underlyingError as? PurchasesError)?.backendCode 带后端错误体码。
    case .purchaseCancelledError, .purchaseNotAllowedError, .storeProblemError:
        // 商店侧失败，钱没扣
    default:
        break
    }
}
```

### 集成测试：把假后端接进来（仅测试用）

```swift
struct FakeBackend: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        HTTPTransportResponse(statusCode: 200, headers: [:], body: subscriberJSON)
    }
}

Purchases.configure(with: Configuration(apiKey: "pk_test")
    .with(transport: FakeBackend()))       // 不注入 = 用内置 URLSession 实现
```

只做「发出去、把响应原样带回来」即可 —— 重试、退避、`Retry-After`、鉴权头、诊断头都由 SDK 上层负责。
**不要在生产构建里注入。**

## 本机开发

```bash
cd sdk/ios
swift test                                   # 全量单测（macOS 上跑纯逻辑层）
swift test --filter M4                       # 只跑 M4 故障注入
```

iOS 交叉编译（零告警门禁）：

```bash
xcodebuild build -scheme RevenueDog -destination 'generic/platform=iOS' \
    -derivedDataPath .build-api-baseline -quiet
```

### 出站请求快照

上行契约是可 diff 的产物（`Tests/__Snapshots__/*.json`）。本地重新录制：

```bash
REVENUEDOG_RECORD_SNAPSHOTS=1 swift test
```

CI 上**不设**该变量 —— 快照缺失或不一致直接失败。

## 公开 API 基线冻结

公开面是对宿主的承诺，任何增删改都必须是**显式提交的产物**。

```bash
./scripts/api-baseline.sh check     # 与基线一致 → 退出 0；有任何差异 → 退出 1 并打 diff
./scripts/api-baseline.sh update    # 有意变更时刷新基线，diff 一并提交并说明理由
```

产物（`api-baseline/`）：

| 文件 | 用途 |
|---|---|
| `RevenueDog.json` | `swift-api-digester -dump-sdk` 的完整 API dump（机器读，喂 `-diagnose-sdk`）。**已 gitignore**：612KB 的机器产物不进库，`update` 时在本地重建；缺它时 `check` 照常工作，只是不再附带破坏性变更分类 |
| `RevenueDog.public-api.txt` | 从 dump 抽出的**排序后全限定符号清单**，逐行可 review —— `check` 的判据就是它 |

要点：
- 基线取 **iOS**（`arm64-apple-ios16.0`）而不是 macOS —— 产品面是 iOS，公开符号里有 `#if canImport(StoreKit)` 门控项。
- 判据用符号清单 diff，不能只看 `-diagnose-sdk`：后者只报**破坏性**变更，**新增 public 符号它不报**，而新增同样需要 review（公开面只进不出）。
- 换 Xcode / Swift 工具链后 dump 可能出现与本仓库无关的差异 —— 这时应该 `update` 一次并在 PR 里注明「工具链升级导致」。

## 诊断事件（默认开启）

SDK 在关键节点记**结构化事件**，攒批上报到 Revenue Dog 后端，供「某个用户在他机器上到底发生了什么」的排查。
**宿主零工作量**，不需要接任何三方 SDK。契约与服务端设计见 `docs/plan/sdk-diagnostics.md`（ADR 0028）。

**怎么关**：

```swift
Purchases.configure(with: Configuration(apiKey: "pk_…")
    .with(diagnosticsEnabled: false))     // 默认 true
```

关掉之后：不记录、不上传，并**清空本地队列文件**。

**上传什么**：事件类型与等级（info / warn / error）、设备时间戳与会话内序号、
`app_user_id`（当前身份，可能是匿名 `$RDAnonymousID:…`）、`install_id`（与这次安装同生命周期的随机标识）、
商品 id / 交易 id、HTTP 状态码与 `X-Request-Id`、尝试次数、耗时、错误分类与我方错误码、
finish 判定结果与理由、当前生效的权益 id。系统信息走既有请求头（平台 / OS 版本 / 机型 / SDK 与宿主版本）。

**不上传**：任何 token 或密钥、StoreKit JWS 原文、请求或响应 body、错误消息文本、日志文本、
邮箱 / 姓名 / 设备名。`http_error` 的 `path` 会把 app_user_id 段替换成 `*`。

**行为**：事件先落 `<Application Support>/RevenueDog/diagnostics/queue.jsonl`（上限 500 条 / 256 KB，
超限丢最旧）；队列攒够 20 条、前台每 30s、进后台、或任一 warn/error 事件 2s 防抖后上传；
失败按 30s→1h 指数退避并**保留事件**，恢复后补发；鉴权失败停 1 小时。同一时刻只有一个上传在飞。

> **宿主需要自己做的两件事**：
> 1. **App Store 隐私营养标签**：SDK 的 `PrivacyInfo.xcprivacy` 只覆盖 SDK 自己这一层；提交时宿主要在
>    App Store Connect 的 App Privacy 问卷里勾上 **User ID / Device ID / Diagnostics**（均为 linked，非 tracking）。
>    Xcode 的 Product → Archive → Generate Privacy Report 会把 SDK 清单聚合出来，照着填即可。
> 2. **`app_user_id` 不得是个人信息**：传给 `configure(appUserID:)` / `logIn(_:)` 的值会随事件上行并留存，
>    请用稳定的内部 uid（Firebase uid 这类），**不要**用邮箱、手机号、姓名。

## 隐私清单（PrivacyInfo.xcprivacy）

`Sources/RevenueDog/PrivacyInfo.xcprivacy`，在 `Package.swift` 里以
`resources: [.copy("PrivacyInfo.xcprivacy")]` 挂到 target。
逐条核实见 `docs/research/verify/ios-privacy-manifest.md`。

SDK 侧声明：

- `NSPrivacyTracking = false`，`NSPrivacyTrackingDomains` 为空数组（SDK 不做跨 App 追踪）。
- Required Reason API 只有一条：`NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`
  （身份与归因状态存自家私有键）。文件时间戳 / 系统启动时间 / 磁盘空间 / 键盘 类 API 全仓零使用，因此不声明。
- 收集的数据类型：购买历史、用户 ID、设备 ID（`install_id` / AdServices token）、其它诊断数据；全部 `Linked = true`、`Tracking = false`。
- 用途：购买历史 / 设备 ID / 其它诊断数据均含 **App Functionality + Analytics**（诊断事件在后台既按用户反查、
  也按版本做分布聚合，后者只能落在 Analytics —— 逐条核实见 `docs/research/verify/privacy-manifest-diagnostics.md`）；
  用户 ID 只含 App Functionality。

> **维护触发条件**：诊断请求头里的平台 / OS 版本 / 机型 / SDK 与宿主版本**已随诊断事件写进 D1 留存 30 天**
> （ADR 0028），核实结论是它们被既有的 `OtherDiagnosticData` / `DeviceID` 覆盖，无需新增数据类型；
> 但 `X-Storefront` / `X-Preferred-Locales` **如果**日后也进 D1，需要重新核对
> （商店地区与 `CoarseLocation` 的边界官方未明确，见 verify 报告 §5.2）。改服务端留存策略时请一并回看本节。

> **宿主需要自己声明的部分**：隐私清单是 per-target 的。如果你的 App 调用了
> `setEmail` / `setPhoneNumber` / `setDisplayName` 这类保留属性 setter，
> 对应的邮箱、电话、姓名数据类型必须由**宿主 App 自己的** `PrivacyInfo.xcprivacy` 声明 ——
> SDK 自身拿不到这些值，无条件替宿主声明反而会让从不调 setter 的集成方标签失真。

## 测试基建

| 文件 | 作用 |
|---|---|
| `Tests/RevenueDogTests/Support/MockTransport.swift` | 出站请求捕获 + 可编排响应；支持**按路径**排队 stub、按路径注入超时/断网、整机断网 |
| `Tests/RevenueDogTests/PublicTransportInjectionTests.swift` | **故意不 `@testable`**：公开注入路径（`HTTPTransport` / `Configuration.with(transport:)`）的可用性门禁 |
| `Tests/RevenueDogTests/Support/RequestSnapshot.swift` | 出站请求 JSON 快照 |
| `Tests/RevenueDogTests/Support/SingletonSerialDomain.swift` | 碰 `Purchases` 静态单例的 suite 必须挂在这个串行域下 |
| `Sources/RevenueDog/StoreKitLayer/StoreKitAbstraction.swift` | `FakeStoreKitProvider`：纯内存 StoreKit 替身 |
| `Tests/RevenueDogTests/M4FaultInjectionTests.swift` | M4 故障注入：端点重试策略 / 崩溃重放三切点 / 冷启动离线 |

`Purchases.Dependencies` 是**内部**注入点（`@testable` 可达），其中与故障注入直接相关的：

- `networkRetryPolicy` —— 网络层重试策略，测试里让「重试几次」变成可断言的常量。
- `networkDelayScheduler` —— 网络退避调度器；测试注入 `NoDelayScheduler`（不真睡）或 `RecordingDelayScheduler`（记录每次退避时长，用来验 `Retry-After` 优先）。
- `delayScheduler` —— P4 交易可见性轮询用的调度器（与网络退避分开）。

## 宿主示例 app（`Example/`）

`sdk/ios/Example/` 是一个 **XcodeGen 生成**的宿主示例 app（`*.xcodeproj` 已 gitignore，**不入库**）。
它有两个职责：

1. **给 StoreKitTest 当宿主（TEST_HOST）**。没有 app host 时 `Bundle.main` 是
   `com.apple.dt.xctest.tool`，进程缺 `application-identifier` entitlement →
   `Transaction.currentEntitlements / .all / .unfinished` **全部返回空**，
   RevenueDog 的上报管道（靠 `Transaction` 取 JWS）整条不可测。
2. **当真机核验载体**。门禁报告 `docs/audit/2026-08-28-sdk-m2-gate.md` §2 的真机清单
   （📱 必做 2 条 + 建议补充 4 条）做成了 app 内的「核验」页，每条给操作步骤与通过判据。

### 生成与运行

```bash
cd sdk/ios/Example
xcodegen generate                 # → RevenueDogExample.xcodeproj（生成物，不入库）
open RevenueDogExample.xcodeproj  # Xcode 里选 RevenueDogExample scheme 跑
```

模拟器上 scheme 已挂 `Tests/StoreKitTestSupport/RevenueDog.storekit`，**不连后端也能走完购买 UI**：
商品从 StoreKitTest 出；「商品」页拉 offerings 失败时会自动退回配置里的三个内建商品。

界面：**配置**（apiKey / baseURL，默认 `http://127.0.0.1:8787`）、**商品**（offerings + 购买 /
restore / sync）、**客户**（logIn / logOut / CustomerInfo 全貌 / 四种 FetchPolicy）、
**核验**（真机清单）、**日志**（接 `Purchases.setLogSink` 的实时面板，可过滤 / 拷贝）。

### 真机核验

```bash
cd sdk/ios/Example
REVENUEDOG_DEVELOPMENT_TEAM=ABCDE12345 xcodegen generate   # 注入签名 team
```

Xcode 打开工程 → 选真机 → Run → 进「核验」页按清单逐条跑。清单勾选状态只存本机 UserDefaults。

> app 只消费**公开 API**（不 `@testable import`），所以它同时是公开面可用性的活样例。
> app **故意不在启动时 configure**（为了能在界面上改 baseURL）；生产集成必须在启动期 configure（铁律 P1），
> 核验清单里有一条专门测这个时序。

## StoreKitTest 全场景（`RevenueDogStoreKitTests`）

核实与实测见 `docs/research/verify/storekittest-spm.md`。结论：**走不了纯 SwiftPM testTarget，必须挂宿主 app。**

- 编译层面没问题：testTarget 里直接 `import StoreKitTest` 就能过，不需要 `linkedFramework` / `unsafeFlags`。
- 运行层面必须有 app host（见上）。
- **iOS 26.x 模拟器上 `SKTestSession` 整体失灵**（有无宿主都一样：`Product.products(for:)` 返回 0），
  iOS 18.5 正常。**CI destination 必须钉 iOS 18.x**（2026-09-06 在 26.5 上复测，仍然失灵）。

因此 `Package.swift` **不声明** StoreKitTest 相关 target；场景测试挂在
`Example/RevenueDogStoreKitTests`（host = 示例 app）。分工是：
**StoreKit 是真的**（`SKTestSession` 驱动，JWS / `appAccountToken` / `finish()` 都是真的），
**后端是假的**（transport 走**公开**注入点 `Configuration.with(transport:)`，与宿主用的是同一条路径）。

### 运行

```bash
sdk/ios/scripts/storekit-tests.sh                       # 默认 iOS 18.5 / iPhone Xs
SK_OS=18.5 SK_DEVICE='iPad Pro 13-inch (M4)' sdk/ios/scripts/storekit-tests.sh
SK_FILTER='StoreKitScenarioDomain/ConsumableTests' sdk/ios/scripts/storekit-tests.sh   # 只跑一个 suite
```

脚本内部：`xcodegen generate` → 校正测试计划里的 target UUID → `xcodebuild test`（退出码透传）。
可覆盖变量：`SK_OS` / `SK_DEVICE` / `SK_DESTINATION` / `SK_SCHEME` / `SK_TEST_PLAN` /
`SK_FILTER` / `SK_DERIVED_DATA` / `XCODEGEN`。

### 场景表（23 条，iOS 18.5 全绿）

| # | 场景 | 对照编号 | 关键断言 |
|:-:|---|---|---|
| ① | 购买成功 → 上报带真 JWS → 200 后才 finish | 铁律 P2 / 裁决 F8 | `fetch_token` 是三段式 JWS 原文；200 后 `unfinished` 里不再有它；上下文清空 |
| ① | 购买 package 携带 offering 归因 | 契约 §2.1 | `presented_offering_identifier` 上行 |
| ② | 5xx → 不 finish；冷启动重放 200 → finish；第三次冷启动零上报 | 坑 #8 / 铁律 P3 | 「恰好一次」= 不无限重报 |
| ② | 确定性 4xx（400）→ finishable：finish + 删上下文；401/403 例外（鉴权失败，保留上下文等重放，ADR 0023） | 坑 #8 | 重试无意义的错误不许卡住 finish 义务；配置错误不许抹掉付款 |
| ③ | `forceRenewalOfSubscription` → 续期交易到达并上报 | 坑 #11 / #102 | 续期走 `queue` 通道；每笔 JWS 互不相同；200 后 finish |
| ③ | `timeRate` 加速的真实续期（对照路径） | 坑 #102 | 同上 |
| ④ | `refundTransaction` → revoked 交易上报 | 裁决 #12 | revoked 走同一管道、200 即 finish，无特例 |
| ⑤ | `expireSubscription` → 权益退出 `currentEntitlements` | 坑 #31 / #102 | 过期后冷启动零重报 |
| ⑤ | 购买日期回拨一年 → 交易一落地即过期 | — | `.purchaseDate(_:renewalBehavior:)`（StoreKitTest 专属选项） |
| ⑥ | Ask-to-Buy：pending → approve → **配对**上报 | 坑 #19 / #104 | `initiation_source == "purchase"` 证明配对回了原发起上下文 |
| ⑥ | Ask-to-Buy decline → 零上报、无权益 | 坑 #19 | — |
| ⑦ | 注入 `purchaseNotAllowed` → 映射 `purchaseNotAllowedError` | 坑 #18 | 无上报、无残留上下文、无未 finish 交易 |
| ⑦ | 注入通用 `StoreKitError` → 映射 `storeProblemError` | 坑 #43 | 同上 |
| ⑦ | `failTransactionsEnabled` 在 iOS 17+ 已是 no-op | **矩阵修正** | 警戒线：拿它造失败 = 假绿 |
| ⑦ | `interruptedPurchasesEnabled` → 不误报、不误 finish | 坑 #18 | 没有交易时绝不凭空上报 |
| ⑧ | 新 `Purchases` 实例扫描 `Transaction.unfinished` 并补报 | 坑 #132 / 裁决 #2 | 补投路径 `initiation_source == "queue"` |
| ⑧ | `clearTransactions` 之后冷启动 → 零上报 | 坑 #103 | clear 的可见性是异步的，必须等 |
| ⑨ | 无 intro offer 时 `isEligibleForIntroOffer` 的实际返回 | 坑 #91 | 组级语义：同组两商品同答案 |
| ⑨ | 购买后同组 intro 资格翻转 | 裁决 #124 | 端上不可信，以服务端为准 |
| ⑩ | 消耗型未在响应 `non_subscriptions` 确认 → **绝不 finish** | 坑 #6（必抄 #1） | 「钱付了道具没到」的防线 |
| ⑩ | 响应确认该交易 id → finish、上下文清空 | 坑 #6 | — |
| ⑪ | 一次购买产出 `purchase_started → transaction_observed → receipt_post → finish_decision` | ADR 0028 | 事件字段合规、无 JWS/密钥外泄 |
| ⑫ | `Package.storeProduct` 来自真 StoreKit | v0.2.0 A | 价格 / `subscriptionPeriod` 映射正确；消耗型无周期；商店没有的仍为 nil |

### 做不到 / 没做的场景（写明理由，不硬凑）

| 场景 | 原因 |
|---|---|
| promo offer 资格（`promotionalOffer(_:compactJWS:)`） | 需要 ASC 签名密钥，`.storekit` 的 `adHocOffers` 为空；且 **SDK 当前根本没用这个 API**（属 R6 范围）。只做了「读得到、且为空」的特征化断言 |
| `unverified` 交易（篡改签名） | `VerificationResult.unverified` 无法用 `SKTestSession` 构造。留在**真机核验清单**（补充场景 · 坑 20） |
| `@backDeployed` 三件套在 iOS 16 上的返回 | 模拟器给不出结论，必须最低版**真机**。留在真机清单 #122 |
| 真机 CI | 真机 entitlement 情况与模拟器不同，本批全部结论基于模拟器 |
| iOS 26.6 是否修好 `SKTestSession` | 本机只有 26.5 / 18.5，**未验证**。在拿到 26.6 运行时之前 CI 一律钉 18.x |

### 已知限制与踩坑速查

- **destination 必须钉 iOS 18.x。** 26.x 上 `Product.products(for:)` 返回 0，所有场景在前置自检处直接失败
  （前置自检刻意做在最前面，避免给出误导性的报错）。
- **`.serialized` 是硬性要求。** 测试环境整机一份（Apple 官方原文），`Purchases` 又是静态单例。
  本 target 所有 suite 都挂在 `StoreKitScenarioDomain` 这个带 `.serialized` 的父 suite 下 ——
  加新 suite 请一律写成 `extension StoreKitScenarioDomain { @Suite … }`。
- **setup 顺序**：先 `resetToDefaultState()` / `clearTransactions()`，再设 `disableDialogs` /
  `storefront`（reset 会把 `disableDialogs` 冲回 NO，顺序错了购买会卡在无人应答的弹窗上直到 480s 超时）。
- **坑 #103 的完整绕法**：`clearTransactions()` 不但清不干净，**清干净这件事对 StoreKit 2 侧还是异步可见的**。
  必须 clear + 逐个 `deleteTransaction` + **等到 `unfinished` 与 `currentEntitlements` 都空**。
  少了最后一步会出现随机假失败：残留权益被下一条测试的冷启动扫描误报一次。
- **`timeRate` 必须在购买之前设**，购买后再改，那笔已存在的订阅不会被加速。
- **别在同一台模拟器上并行跑两个 `xcodebuild test`**，会撞出 `Application failed preflight checks` 这类假失败。
- **测试计划的 `testExecutionOrdering` 键在 Xcode 26.6 上会让整个 `.xctestplan` 读不出来**
  （报 "test plan could not be read"）。别加；串行由 `.serialized` trait 负责。

`Tests/StoreKitTestSupport/` 现在只剩 `RevenueDog.storekit`（一个订阅组两档 + 一个消耗型），
由示例 app target 以**引用**方式打进 bundle。第一批留下的样板测试与测试计划模板已**迁入**
`Example/`（样板即场景 ①），避免两份漂移。

> **静默腐坏的堵漏**：测试 target 以**引用**方式编译
> `Tests/RevenueDogTests/Support/MockTransport.swift` —— 同一份源码进两个 target，
> `Purchases.Dependencies` / `HTTPTransport` 这类内部注入点改名会让两边一起红。
> 这正是第一批留下的「StoreKitTestSupport 不在 CI 编译范围内」风险点的处置。

现有单测直接跑上 iOS Simulator（不涉及 StoreKitTest）：

```bash
xcodebuild test -scheme RevenueDog \
    -destination 'platform=iOS Simulator,name=iPhone Xs,OS=18.5'
```
