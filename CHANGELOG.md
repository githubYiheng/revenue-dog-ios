# Changelog

语义化版本。公开 API 基线（`api-baseline/RevenueDog.public-api.txt`）有「减」或「改」= 主版本；只「增」= 次版本；无差异 = 修订号。
破坏性变更必须在对应条目里写迁移说明。tag 一经发布不可移动。

## [Unreleased]

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
