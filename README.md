# RevenueDog iOS SDK

SwiftPM 包，Swift 6 严格并发，**产品基线 iOS 16**。
`Package.swift` 里的 `macOS 13` 只是为了让纯逻辑单测能在开发机上直接 `swift test`
（StoreKit 相关代码用 `#if canImport(StoreKit)` + `@available` 门控）。

设计与坑矩阵：
- `docs/plan/ios-sdk-design.md`
- `docs/plan/ios-sdk-pitfall-matrix.md`
- 门禁报告：`docs/audit/2026-08-28-sdk-m2-gate.md`

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
| `RevenueDog.json` | `swift-api-digester -dump-sdk` 的完整 API dump（机器读，喂 `-diagnose-sdk`） |
| `RevenueDog.public-api.txt` | 从 dump 抽出的**排序后全限定符号清单**，逐行可 review —— `check` 的判据就是它 |

要点：
- 基线取 **iOS**（`arm64-apple-ios16.0`）而不是 macOS —— 产品面是 iOS，公开符号里有 `#if canImport(StoreKit)` 门控项。
- 判据用符号清单 diff，不能只看 `-diagnose-sdk`：后者只报**破坏性**变更，**新增 public 符号它不报**，而新增同样需要 review（公开面只进不出）。
- 换 Xcode / Swift 工具链后 dump 可能出现与本仓库无关的差异 —— 这时应该 `update` 一次并在 PR 里注明「工具链升级导致」。

## 隐私清单（PrivacyInfo.xcprivacy）

`Sources/RevenueDog/PrivacyInfo.xcprivacy`，在 `Package.swift` 里以
`resources: [.copy("PrivacyInfo.xcprivacy")]` 挂到 target。
逐条核实见 `docs/research/verify/ios-privacy-manifest.md`。

SDK 侧声明：

- `NSPrivacyTracking = false`，`NSPrivacyTrackingDomains` 为空数组（SDK 不做跨 App 追踪）。
- Required Reason API 只有一条：`NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`
  （身份与归因状态存自家私有键）。文件时间戳 / 系统启动时间 / 磁盘空间 / 键盘 类 API 全仓零使用，因此不声明。
- 收集的数据类型：购买历史、用户 ID、设备 ID（`install_id` / AdServices token）、其它诊断数据；全部 `Linked = true`、`Tracking = false`。

> **宿主需要自己声明的部分**：隐私清单是 per-target 的。如果你的 App 调用了
> `setEmail` / `setPhoneNumber` / `setDisplayName` 这类保留属性 setter，
> 对应的邮箱、电话、姓名数据类型必须由**宿主 App 自己的** `PrivacyInfo.xcprivacy` 声明 ——
> SDK 自身拿不到这些值，无条件替宿主声明反而会让从不调 setter 的集成方标签失真。

## 测试基建

| 文件 | 作用 |
|---|---|
| `Tests/RevenueDogTests/Support/MockTransport.swift` | 出站请求捕获 + 可编排响应；支持**按路径**排队 stub、按路径注入超时/断网、整机断网 |
| `Tests/RevenueDogTests/Support/RequestSnapshot.swift` | 出站请求 JSON 快照 |
| `Tests/RevenueDogTests/Support/SingletonSerialDomain.swift` | 碰 `Purchases` 静态单例的 suite 必须挂在这个串行域下 |
| `Sources/RevenueDog/StoreKitLayer/StoreKitAbstraction.swift` | `FakeStoreKitProvider`：纯内存 StoreKit 替身 |
| `Tests/RevenueDogTests/M4FaultInjectionTests.swift` | M4 故障注入：端点重试策略 / 崩溃重放三切点 / 冷启动离线 |

`Purchases.Dependencies` 是**内部**注入点（`@testable` 可达），其中与故障注入直接相关的：

- `networkRetryPolicy` —— 网络层重试策略，测试里让「重试几次」变成可断言的常量。
- `networkDelayScheduler` —— 网络退避调度器；测试注入 `NoDelayScheduler`（不真睡）或 `RecordingDelayScheduler`（记录每次退避时长，用来验 `Retry-After` 优先）。
- `delayScheduler` —— P4 交易可见性轮询用的调度器（与网络退避分开）。

## StoreKitTest（`SKTestSession`）

核实与实测见 `docs/research/verify/storekittest-spm.md`。结论：**有条件可行，但走不了纯 SwiftPM testTarget。**

- 编译层面没问题：testTarget 里直接 `import StoreKitTest` 就能过，不需要 `linkedFramework` / `unsafeFlags`。
- 运行层面卡在**没有 app host**：`Bundle.main` 是 `com.apple.dt.xctest.tool`，没有 `application-identifier` entitlement，
  结果是「商品目录能读、购买不能做」，而且 `Transaction.currentEntitlements / .all / .unfinished` 全部返回 0 ——
  RevenueDog 的上报管道正是靠 `Transaction` 取 JWS，所以无宿主 = 整条链路不可测。
- **iOS 26.x 模拟器上 `SKTestSession` 整体失灵**（有无宿主都一样），iOS 18.5 正常。CI destination 必须钉在 iOS 18.x。

因此 `Package.swift` **不声明** StoreKitTest 相关 target。素材放在 `Tests/StoreKitTestSupport/`，
由外部宿主示例 app 工程消费（接法见上述文档 §8）：

| 文件 | 说明 |
|---|---|
| `RevenueDog.storekit` | 最小配置：一个订阅组两档 + 一个消耗型 |
| `StoreKitPurchaseFlowTests.swift` | 样板测试：购买成功 → 上报带 JWS → 200 后才 finish（`#if canImport(StoreKitTest)` 门控） |
| `RevenueDog-StoreKit.xctestplan` | 测试计划模板，`storeKitConfigurationFileReference` 已指向 `.storekit` |

> 这些文件**不在** `swift test` 的编译范围内 —— 内部注入点（`Purchases.Dependencies`）改名不会被 CI 挡住，
> 属于已知的静默腐坏风险点。

现有单测直接跑上 iOS Simulator（不涉及 StoreKitTest）：

```bash
xcodebuild test -scheme RevenueDog \
    -destination 'platform=iOS Simulator,name=iPhone Xs,OS=18.5'
```
