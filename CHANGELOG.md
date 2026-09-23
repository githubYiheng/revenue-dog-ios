# Changelog

语义化版本。公开 API 基线（`api-baseline/RevenueDog.public-api.txt`）有「减」或「改」= 主版本；只「增」= 次版本；无差异 = 修订号。
破坏性变更必须在对应条目里写迁移说明。tag 一经发布不可移动。

## [Unreleased]

## [0.4.1] - 2026-09-23

**修订号**（基线 498 → 500 行；diff 只有 `+` 行，2 行全是 SPI）。**破坏性变更：无**。
为什么是修订号而不是次版本：新增的两个入口都在 `@_spi(RevenueDogInternal)` 后面，**不是对宿主的公开承诺**，
宿主可见的公开面零变化；基线行数变化只是 SPI 按 0.4.0 先例入清单（带 `[SPIAccessControl]`）。主代理裁定。
用途：Flutter 插件 Bridge 单测构造与网络路径逐字段一致的模型，与 Android 0.2.0 `RevenueDogTestModels` 对称（主代理裁定 7）。

### 新增（SPI，非宿主承诺）

- `CustomerInfo.fromBackendResponse(_ data: Data, now: Date = Date()) throws -> CustomerInfo`：`GET /v1/subscribers/{id}`
  响应体（契约 §2.2）→ 公开模型。与网络路径**同一解码**（同一个响应解码器 → `CustomerInfoWireModel` → `CustomerInfo(wireModel:now:)`）；
  `now` 为 `isActive` 的本地参照时间（仍受 `request_date` 3 天 grace 规则约束），可注入以得到确定结果。
- `Offerings.fromBackendResponse(_ data: Data, products: [StoreProduct]) throws -> Offerings`：offerings 响应体 → 公开模型，
  按 `platformProductIdentifier` 挂上 `products`；挂不上的 package `storeProduct == nil`，与真实路径一致。
- 两者遇坏 JSON / 缺契约必填字段时抛解码错误，不崩。

### 内部

- 挂 `StoreProduct` 的逻辑收成 `Offerings.fillingStoreProducts(_:)` 一处，编排层 `offerings()` 与上面的工厂共用（不复制）；
  后端响应解码器收成 `HTTPClient.makeResponseDecoder()` 一处。行为不变。
- `X-Version` 变为 `0.4.1`（出站请求快照同步）。

## [0.4.0] - 2026-09-23

**次版本：公开 API 只「增」**（基线 444 → 498 行；diff 只有 `+` 行，其中 SPI 3 行）。**破坏性变更：无**，现有 `init` 全部保留、不标 deprecated。
用途：Flutter 插件的 M0 原生挂点（`docs/plan/flutter-sdk-design.md` §9、ADR 0100）；公开模型的补齐原生宿主同样可用。

### 新增（公开）

- **`IntroductoryOffer.price: Decimal`**（R9）：优惠价数值。`freeTrial` 恒 0；`payAsYouGo` 为每周期价、`payUpFront` 为整段价，
  均取 `Product.SubscriptionOffer.price`。新构造器 `init(type:period:periodCount:price:displayPrice:isEligible:)`；
  旧 5 参构造器保留、`price` 填 0（不标 deprecated：次版本不给宿主添告警）。对照 RC：`StoreProductDiscount.price`。
- **`PurchaseResult.productIdentifier: String?` / `purchaseDate: Date?`**（R12）：SDK 发起的购买成功时
  （`transactionIdentifier != nil`）两者恒非 nil，取成交交易的 `productID` / `purchaseDate`；取消 / 待定为 nil。
  新构造器 `init(customerInfo:transactionIdentifier:productIdentifier:purchaseDate:userCancelled:isPending:)`；旧两个构造器保留、两字段填 nil。
  对照 RC：`StoreTransaction.productIdentifier` / `purchaseDate`。
- **`CustomerInfo` 明细**（R6）：`subscriptionsByProductIdentifier: [String: SubscriptionInfo]`、
  `nonSubscriptionTransactions: [NonSubscriptionTransaction]`（按购买时间升序、nil 在前、同时间按 id；跳过 id 为空的条目）、
  `allExpirationDates: [String: Date?]`、`allPurchaseDates: [String: Date?]`（订阅取本周期购买时间，一次性取该商品最新一笔）、
  `latestExpirationDate: Date?`。全部由同一份 wire 派生，不改 wire 解码的宽容规则。
  不变式：活跃订阅明细的键集合 == `activeSubscriptionProductIdentifiers`；`allPurchaseDates` 的键 == `allPurchasedProductIdentifiers`；
  非订阅交易 id 集合 == `nonSubscriptionTransactionIdentifiers`。
- **新类型 `SubscriptionInfo`**（20 个字段，与 RC 同名；`isActive` 与活跃订阅集合同一规则同一参照时间，
  `willRenew` 与 `EntitlementInfo.willRenew` 共用同一内部规则）与 **`NonSubscriptionTransaction`**（8 个字段，`transactionIdentifier` = 后端 `id`）。
- **`EntitlementInfo.productPlanIdentifier: String?`**（R7）：权益上的 `product_plan_identifier`，缺失回退到对应订阅上的同名字段。
- `StoreProduct.currencyCode`：文档写明 0.4.0 起 StoreKit 路径恒有值（类型保持 `String?`，nil 只可能来自宿主自造的 fixture）；
  SDK 构造商品时若拿到 nil 记一条 `Log.warn`。

### 新增（SPI，非宿主承诺）

以下入口在 `@_spi(RevenueDogInternal)` 后面，只供混合框架插件使用（`@_spi(RevenueDogInternal) import RevenueDog`）。
**不属于对宿主的公开承诺**，签名可能随插件需要调整；它们在基线清单里带 `[SPIAccessControl]` 标注。

- `Configuration.with(platformFlavor:flavorVersion:)`（R1）：改写 `X-Platform-Flavor`（默认 `native`），
  并在 `flavorVersion` 非 nil 时发新头 **`X-Platform-Flavor-Version`**。原生宿主不调它时请求头与 0.3.1 完全一致。
  对照 RC：`Configuration.Builder.with(platformInfo:)`。
- `Purchases.recordDiagnosticsEvent(_:fields:)`：记一条 info 级诊断事件（字段全为字符串）；事件名须匹配 `^[a-z_]{1,64}$`，
  不合法时 `Log.warn` 并丢弃，不抛。`Purchases.recordDiagnosticsWarning(_:detail:)`：记 `sdk_warning{code, detail}`。
  诊断关闭时两者均为空操作（裁定 10）。

### 兼容性

- **CustomerInfo 缓存**：设备缓存落盘的是 `CustomerInfo` 的 `Codable` 编码。0.3.x 写下的缓存在 0.4.0 照常解码
  （新增键缺失 → 明细为空 / nil，`EntitlementInfo.productPlanIdentifier` 为 nil），下一次拉取即补齐；有专门的旧格式解码单测。
- `X-Version` 变为 `0.4.0`（出站请求快照同步）。

## [0.3.1] - 2026-09-23

**修订号：公开 API 无差异**（基线 444 不变）。破坏性变更：无。

### 修复

- **回前台按 TTL 刷新 CustomerInfo**（RC `updateAllCachesIfNeeded` / Android SDK 同款）。此前 `didBecomeActive` 只做观察者模式的
  交易重扫，不刷新 CustomerInfo；而权益到期判定 3 天内以服务端 `request_date` 为参照，缓存不刷新就不会自己变成过期 ——
  试用未转化、服务端已收权的用户，端上要等宿主主动调 `customerInfo()` 才看到权益下掉。现在回前台（含冷启动那一次）刷新：
  进程内第一次无条件拉，之后缓存超 5 分钟才拉，结果推给 `customerInfoStream` / delegate；缓存新鲜不发请求、不重复推；身份待确认
  （`waitsForLogInBeforeSync`）期间跳过；拉取失败沿用缓存。公开 API 无变化。

## [0.3.0] - 2026-09-13

**次版本：公开 API 只「增」1 个符号**（基线 443 → 444：`Configuration.with(waitsForLogInBeforeSync:)`，diff 只有 `+` 行）。
**默认关闭；不开启时行为与 0.2.1 一致。** 破坏性变更：无。

### 新增

- **`Configuration.with(waitsForLogInBeforeSync: Bool)`：冷启动上报等宿主身份就位**（ADR 0046 / 0047，默认 `false`）。
  修的是「设备上持久化的是**旧的具名身份**，SDK 冷启动扫描抢在宿主 `logIn` 之前按旧身份上报，
  把现役订阅归到旧客户名下」（bible-scroll C5 剧本 1：残留身份 C 冷启动扫描上报，0.7 秒后宿主才 `logIn(D)`）。
  - **何时开启**：宿主自己管理身份、**每次启动都会调 `logIn(_:)`**（例如 Firebase uid 从 Keychain 异步恢复后再登录）。
  - **何时生效**：开关为 `true`、`configure` 没传 `appUserID`、且启动时读出的持久化身份是**具名**的 ——
    三条同时成立才进入「身份待确认」。全新安装（生成匿名 ID）、持久化的是匿名 ID、或 `configure` 传了
    `appUserID` 时**不门控**，行为与 0.2.1 完全一致（首启付费墙早于 `logIn` 也照常能买）。
  - **身份待确认期间**：不做启动补投（待重放购买 / `Transaction.unfinished` / `currentEntitlements` 扫描），
    不上报 `Transaction.updates` 观察到的交易，不做前台重扫；这些交易**不 finish**，留在 StoreKit 里。
    交易监听仍在 `configure` 时同步挂上。`logIn(_:)` / `logOut()` 只等身份初始化，**不再排在启动补投之后**。
  - **确认**：本进程内首次 `logIn(_:)` 成功或 `logOut()` 成功；与当前身份**相同 id** 的 `logIn` 一调用即确认
    （即使随后拉取 CustomerInfo 失败 —— 身份已由宿主声明，拉取失败只是数据没拿到）。
    确认后以确认后的身份跑**一次**完整启动补投，之后再 `logIn` 不重跑；`logIn` / `logOut` 失败保持待确认。
  - **待确认期间调 `purchase` / `restorePurchases` / `syncPurchases`**：最多等 10 秒确认，确认后先等那次补投完成再执行；
    10 秒内没确认抛 `PurchasesError`（`code == .configurationError`，`userInfo["operation"]` 为操作名），
    并记诊断告警 `identity_pending_timeout`。SDK **不猜身份**、不回退到持久化身份。
  - `configure` 后 60 秒仍未确认：记一次诊断告警 `identity_pending`（每进程最多一次），用来发现漏调 `logIn` 的宿主。
- 诊断事件 `sdk_configured` 新增字段 `waits_for_login_before_sync`（开关原值）与 `identity_gated`（本次启动是否实际进入门控）。

## [0.2.1] - 2026-09-13

**补丁版本：公开 API 与 0.2.0 完全一致（基线 443 符号，零变化）。**

### 修复

- **`logOut` 改为先服务端成功再切本地身份；离线 logOut 不再分裂身份**（审计 A4 / 待办 59）。
  旧实现先切本地匿名身份、再去拉 `CustomerInfo`：拉取失败（离线 / 5xx）时设备被留在一个
  **后端从没见过**的匿名 ID 上，而门面 `appUserID` 因为抛错没同步，门面与内部身份各说各话。
  现在与 `logIn` 同形 —— 匿名态守卫 → 旧身份属性同步 → 生成**不落盘**的匿名候选 →
  `GET /v1/subscribers/{候选}`（服务端 get-or-create）→ **仅成功后**才落盘身份、清旧身份内存缓存、
  写新缓存、推流。失败时身份（内存 + 磁盘）、设备缓存、门面与 `customerInfoStream`
  一个字节都不动，错误原样抛出；此后的购买/恢复归因仍算在**旧 uid** 上。
  公开 API 无变化（`logOut()` 签名与语义不变，匿名态照旧抛 `invalidAppUserIdError`）。

## [0.2.0] - 2026-09-10

**次版本：公开 API 只「增」不「减」不「改」**（基线 377 → 443 个符号：诊断切片 +1，缺口 A–E +65，diff 全是 `+` 行）。**bff 直切实际版本**（ADR 0028）。
**破坏性变更：无。** 门禁：194 单测 + 23 StoreKitTest 场景（iOS 18.5）全绿，iOS 交叉编译零告警。

### 新增

- **`Package.storeProduct` 不再恒 nil**：`offerings()` 拿到后端 offerings 后，用 StoreKit 2
  `Product.products(for:)` **一次批量**取回全部 `platform_product_identifier` 对应的商品，
  填进 `Package.storeProduct`；命中本地缓存的 offerings 也在**读取时**补齐
  （缓存里只存后端下发的那份，不冻价格）。商店查不到的商品 `storeProduct` 仍为 `nil`，
  并照旧记进诊断事件 `offerings_fetch.not_found_product_ids`（与补商品共用同一次商店查询）。
- **`StoreProduct` 补齐做定价文案要用的字段**：`subscriptionPeriod`（`SubscriptionPeriod`：
  `unit` + `value`，unit 是 struct + static 常量，不是 enum）、`introductoryOffer`
  （`IntroductoryOffer`：`type ∈ freeTrial / payAsYouGo / payUpFront / unknown`、`period`、
  `periodCount`、`displayPrice`、`isEligible`；资格走 `Product.SubscriptionInfo.isEligibleForIntroOffer`，
  `periodCount` 是 `Product.SubscriptionOffer.periodCount` 原样带出 —— `payAsYouGo` 靠它才写得出
  「$1.99/月 × 3 个月」，`freeTrial` / `payUpFront` 也如实带，不在端上归一化）、
  以及 StoreKit 2 命名的 `displayPrice`（与既有 `localizedPriceString` **同值**的计算属性别名）。
  新增一个带这两个新字段的 `init`，**旧 `init` 原样保留**。
  ⚠️ `isEligible` 是**订阅组级**且端上不可信的判定（坑 #91 / 裁决 #124）：只用于展示文案，
  计费与权益一律以服务端为准。
- **`PurchaseResult.isPending`**：Ask-to-Buy（家长同意）/ SCA（银行验证）时为 `true`，
  此刻 `transactionIdentifier == nil` 且 `userCancelled == false`。宿主**不要**在此发放权益，
  提示「等待批准」并监听 `customerInfoStream` 即可 —— 交易稍后从 `Transaction.updates` 流出，
  由 SDK 自动上报。新增带 `isPending` 的 `init`，旧 `init` 保留（默认 `false`）。
- **扣款之后上报失败的两个独立错误码**（此前两种后果共用一个裸 `.networkError`，宿主分不开）：
  - `PurchasesErrorCode.purchasePendingServerConfirmation`（901）：5xx / 网络错误 / 超时 /
    401 / 403 / 408 / 429。**交易未 finish、上下文已落盘**，SDK 会在前台恢复与下次冷启动自动重放。
    宿主提示「支付已收到，权益稍后到账」，**不要**引导用户再买一次。
  - `PurchasesErrorCode.purchaseRejectedByServer`（902）：确定性 4xx。**交易已 finish**，
    不会再有权益产生；`underlyingError` 是原始 `PurchasesError`，其 `backendCode` 带后端错误体码。
    宿主应走客服 / 退款路径，别静默吞掉。
  - `TransactionPoster` 的 finishable / retryable 划分**未变**，只是把结果映射到了新码位；
    诊断事件 `purchase_result.error_code` 随之记新码名。
- **`Configuration.with(transport:)` + 公开的 `HTTPTransport` / `HTTPTransportResponse`**：
  宿主可以在**自己的**集成测试里塞一个假后端，不连服务端跑完整条 SDK 链路。
  **仅测试用** —— 生产构建不要注入（不注入时 SDK 用内置的 `URLSession` 实现，带超时与缓存策略）。
  重试、退避、`Retry-After`、鉴权头、诊断头一律由 SDK 上层负责，实现方不要重复一遍。
- **客户端诊断事件管线**（ADR 0028，契约 `docs/plan/sdk-diagnostics.md`）。SDK 在 configure / 身份 / 购买 / 交易观察 / 收据上报 / finish 判定 / 恢复同步 / CustomerInfo 与 offerings 拉取 / HTTP 错误 / 运行时告警处记结构化事件，落本地 JSONL 队列（`<Application Support>/RevenueDog/diagnostics/`，上限 500 条 / 256 KB），攒批上报 `POST /v1/diagnostics/events`。**默认开启，宿主零接入**。不上传 token / JWS / 请求响应 body / 错误消息 / 日志文本；`http_error` 的 `path` 里 app_user_id 段替换为 `*`。
- **`Configuration.with(diagnosticsEnabled: Bool)`** —— 关掉后不记不发并清空本地队列。

### 修复

- **冷启动少发一次收据**（坑矩阵 #142）：带待重放上下文的冷启动过去要上报 **2 次** ——
  上下文重放先发一次（只有 JWS、没有交易对象 → 不能 finish），启动扫描把同一笔又发一次（这次才 finish）。
  现在重放前先看一眼 `Transaction.unfinished` **与** `Transaction.currentEntitlements` 两份快照，
  当下就看得见交易对象的上下文这一轮跳过重放、交给扫描路径（它一次上报就能把 finish 义务一起清掉），
  **同一 `transactionId` 只上报一次**（崩在 finish 之后的那种也覆盖）。
  去重用 `pendingPurchases` 现有的键，不引入新状态；两份快照里都看不见（P4 可见性滞后 / 交易已被清掉），
  或该交易在台账里已记（`currentEntitlements` 扫描本来就会跳过它）时，行为与从前完全一致。

### 破坏性

无。

### 其它行为变更

- **行为变更**：`install_id`（与本次安装同生命周期的随机标识）改为**首次 `configure` 就生成并持久化**，不再依赖宿主开启 AdServices 归因采集。影响：即使从不调 `enableAdServicesAttributionTokenCollection()`，`POST /v1/subscribers/identify` 也会带上 `install_id`。
- **行为变更**：`offerings()` 成功后会向 StoreKit 查一次商品（**每次 offerings 一次**，补 `storeProduct` 与算 `not_found_product_ids` 共用这一次）。best-effort：查不动就 `storeProduct` 留空、诊断字段省略，不影响 offerings 本身。
- **隐私清单**：`DeviceID` 与 `OtherDiagnosticData` 补 `NSPrivacyCollectedDataTypePurposeAnalytics`；未新增数据类型，未新增 Required Reason API 声明（逐条核实见 `docs/research/verify/privacy-manifest-diagnostics.md`）。
- **宿主须知**：App Store 隐私营养标签要宿主自己勾 User ID / Device ID / Diagnostics（linked，非 tracking）；`app_user_id` 不得使用邮箱等个人信息。见 README「诊断事件」。

## [0.1.1] - 2026-09-10

修订号：公开 API 基线无差异（377 符号）。**bff 直切接线必须用本版本或更高**（v0.1.0 会在鉴权失败时错误 finish 交易）。

- **修复**：`POST /v1/receipts` 返回 401/403 时不再 finish 交易。鉴权失败发生在服务端留档之前，此前的行为会把用户已付款的交易从 StoreKit 与后端两侧同时抹掉（消耗型不可恢复）。现在保留上下文，密钥修正后由前台重放补报。
- **修复**：`Purchases.defaultBaseURL` 从 `https://api.revenuedog.com`（非本项目域名）改为 `https://api.revdog.org`。公开符号不变。

## [0.1.0] - 2026-09-08

首个 tag。**尚未在生产 App 上线**，仅供双 SDK 影子期接线与真机核验。

- StoreKit 2 购买闭环：单一处理通道、finish 三铁律（200 后才 finish；确定性 4xx 也 finish；消耗型未被服务端确认绝不 finish）。
- 身份：匿名 ID / `logIn` / `logOut`，`CustomerInfo` 四种 `FetchPolicy` 与缓存代失效。
- `restorePurchases` / `syncPurchases` 全链；冷启动扫描 `Transaction.unfinished` 补报（恰好一次）。
- 订阅者属性、AdServices 归因 token、`presented_offering_identifier` 归因上行。
- 运行时权威开关、购买结果钩子、权益 diff 上报（双 SDK 共存期用）。
- 网络层：端点级重试策略、`Retry-After` 优先、故障注入测试 4 组。
- 隐私清单 `PrivacyInfo.xcprivacy`（`NSPrivacyTracking = false`，Required Reason API 仅 `CA92.1`）。
- 公开 API 基线冻结：377 个公开符号；146 单测 + 21 StoreKitTest 场景（iOS 18.5）。
