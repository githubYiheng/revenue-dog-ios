//
//  VerificationChecklist.swift
//  「真机核验清单」的数据源。
//
//  正文逐条来自门禁报告 `docs/audit/2026-08-28-sdk-m2-gate.md` §2：
//  正式 📱 项 2 条（#13 / #122）+ 建议一并在真机跑的补充场景 4 条（坑 132 / 20 / 23 / 1）。
//  勾选状态只存 UserDefaults（本机、per-device），纯粹是给跑清单的人留个记号。
//

import Foundation

struct ChecklistItem: Identifiable, Sendable {

    /// 稳定 ID —— 勾选状态的持久化键，别改。
    let id: String
    /// 来源编号（门禁报告里的 # 或坑矩阵编号）。
    let origin: String
    let title: String
    /// 逐步操作。
    let steps: [String]
    /// 通过判据。
    let expectation: String
    /// 前置条件 / 备注。
    let note: String?

    static let all: [ChecklistItem] = [

        ChecklistItem(
            id: "gate-13",
            origin: "门禁 §2 #13（📱 必做）",
            title: "购买一次，Console 不得出现「未监听 updates」告警",
            steps: [
                "真机装本 app（或模拟器挂 StoreKit 配置），冷启动。",
                "在「配置」页 configure（真机连真后端；模拟器可留默认 127.0.0.1）。",
                "去「商品」页完成一次购买（真机需沙盒账号；模拟器走 StoreKitTest）。",
                "Mac 上打开 Console.app，按进程 RevenueDogExample 过滤，搜关键字 "
                    + "\"Making a purchase without listening for transaction updates\"。",
            ],
            expectation: "整个购买过程 Console **不出现** "
                + "\"Making a purchase without listening for transaction updates risks missing successful purchases.\"",
            note: "这是铁律 P1（configure 内同步挂 updates 监听）的运行期回归信号。"
                + "当前实现即可测，无前置。"
        ),

        ChecklistItem(
            id: "gate-122",
            origin: "门禁 §2 #122（📱 必做）",
            title: "三个 @backDeployed API 在 iOS 16 最低版真机上逐个实测",
            steps: [
                "准备一台**系统版本为 iOS 16.x** 的真机（模拟器不算数）。",
                "在「核验」页点开本条，用下方三行代码在真机上逐个打印返回值："
                    + "AppTransaction.shared 的 appTransactionID；"
                    + "Product.SubscriptionOffer.promotionalOffer(_:compactJWS:)；"
                    + "Product.SubscriptionInfo.introductoryOfferEligibility(compactJWS:)。",
                "记录每个 API 的实际返回值（是否非空、行为是否正确）。",
            ],
            expectation: "每个 API 返回非空 / 行为正确；任一不达标 → 该能力按保守版本门控（当作 iOS 18.4+/26+）。",
            note: "当前 SDK **未使用**这三个 API。实测必须在启用 R6 相关能力**之前**完成 —— "
                + "坑 #122 的教训是 `@backDeployed` 标注会说谎。"
        ),

        ChecklistItem(
            id: "supp-132",
            origin: "补充场景（坑 132）",
            title: "冷启动重建 SDK，观察 Transaction.updates 是否重投未 finish 交易",
            steps: [
                "先制造一笔「已在商店成功、但上报失败」的交易：把「配置」页 baseURL 指到一个不可达地址，然后购买。",
                "购买会报错（上报失败），但交易在 StoreKit 侧已成功且**未 finish**。",
                "杀掉 app（上滑关闭），把 baseURL 改回可用后端，冷启动。",
                "看「日志」页：应出现该交易被重放并上报的日志。",
            ],
            expectation: "冷启动后那笔未 finish 的交易被重新上报，且后端 200 后才 finish。",
            note: "单测用 FakeStoreKitProvider 验的是**我们自己的重放**；SK2 侧的重投是外部前提，只有真机/真 StoreKit 能给结论。"
                + "2026-09-02 已核实纠偏：重投触发条件是 **App 启动**，不是新建 iterator。"
        ),

        ChecklistItem(
            id: "supp-20",
            origin: "补充场景（坑 20）",
            title: "构造 unverified 交易，验证丢弃策略",
            steps: [
                "只能用 StoreKitTest 篡改场景构造（真机沙盒无法人为伪造签名）。",
                "在模拟器上跑 RevenueDogStoreKitTests，或手工改 .storekit 里的 _developerTeamID 后重跑购买。",
                "看「日志」页是否出现「交易未通过 StoreKit 验签」warn。",
            ],
            expectation: "unverified 交易被丢弃 + 埋点，**不进上报管道**（裁决 #20）。",
            note: "单测层无法构造 VerificationResult.unverified，只有集成层可验。"
        ),

        ChecklistItem(
            id: "supp-23",
            origin: "补充场景（坑 23）",
            title: "iPad 多任务 / 多场景下发起购买",
            steps: [
                "用 iPad 真机，把本 app 与另一个 app 并排（Split View）。",
                "在「商品」页发起购买，观察确认弹窗出现在哪一侧。",
                "再试一次：把本 app 放到 Slide Over，重复购买。",
            ],
            expectation: "确认弹窗出现在**本 app 的场景内**，不错位、不消失。",
            note: "验证 purchase(confirmIn:) 自动场景探测的实际后果。"
                + "若错位：宿主应显式注入 PurchaseUIContext.sceneProvider。"
        ),

        ChecklistItem(
            id: "supp-1",
            origin: "补充场景（坑 1）",
            title: "首屏前 configure，观察监听挂载时序",
            steps: [
                "本 app 默认是「点按钮才 configure」（方便切 baseURL）——本条要临时改成启动即配：",
                "在 RevenueDogExampleApp.swift 的 init 里直接调 Purchases.configure(with:)，重编译。",
                "冷启动，立刻看 Console/日志页里 SDK 日志的先后顺序。",
            ],
            expectation: "updates 监听 Task 在任何 await 之前建立；不出现「先 await 再挂监听」的窗口。",
            note: "佐证铁律 P1 字面偏差在真机上的实际风险面（门禁 §1 #1 备注）。"
        ),
    ]
}

/// 勾选状态（只存本机 UserDefaults）。
@MainActor
final class ChecklistState: ObservableObject {

    @Published private(set) var checked: Set<String>

    private static let key = "example.checklist.checked"

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        checked = Set(stored)
    }

    func isChecked(_ id: String) -> Bool { checked.contains(id) }

    func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
        UserDefaults.standard.set(Array(checked), forKey: Self.key)
    }
}
