# Changelog

语义化版本。公开 API 基线（`api-baseline/RevenueDog.public-api.txt`）有「减」或「改」= 主版本；只「增」= 次版本；无差异 = 修订号。
破坏性变更必须在对应条目里写迁移说明。tag 一经发布不可移动。

## [Unreleased]

**次版本：新增公开 API**（公开面只「增」一处 → 次版本号）。

- **新增**：客户端诊断事件管线（ADR 0028，契约 `docs/plan/sdk-diagnostics.md`）。SDK 在 configure / 身份 / 购买 / 交易观察 / 收据上报 / finish 判定 / 恢复同步 / CustomerInfo 与 offerings 拉取 / HTTP 错误 / 运行时告警处记结构化事件，落本地 JSONL 队列（`<Application Support>/RevenueDog/diagnostics/`，上限 500 条 / 256 KB），攒批上报 `POST /v1/diagnostics/events`。**默认开启，宿主零接入**。不上传 token / JWS / 请求响应 body / 错误消息 / 日志文本；`http_error` 的 `path` 里 app_user_id 段替换为 `*`。
- **新增公开 API（唯一一处）**：`Configuration.with(diagnosticsEnabled: Bool)` —— 关掉后不记不发并清空本地队列。
- **行为变更**：`install_id`（与本次安装同生命周期的随机标识）改为**首次 `configure` 就生成并持久化**，不再依赖宿主开启 AdServices 归因采集。影响：即使从不调 `enableAdServicesAttributionTokenCollection()`，`POST /v1/subscribers/identify` 也会带上 `install_id`。
- **行为变更**：`offerings()` 成功后会额外向 StoreKit 查一次商品可用性，用于在诊断事件里记录「后端配了但商店查不到」的商品 id（best-effort，失败不影响 offerings 本身）。
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
