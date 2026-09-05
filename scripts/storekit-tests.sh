#!/usr/bin/env bash
#
# storekit-tests.sh —— StoreKitTest 全场景集成测试（M4 硬化第二批）
#
#   sdk/ios/scripts/storekit-tests.sh                 # 默认 iOS 18.5 / iPhone Xs
#   SK_OS=18.5 SK_DEVICE='iPad Pro 13-inch (M4)' …    # 覆盖 destination
#   SK_FILTER='④' …                                    # 只跑某个 suite（-only-testing 的名字过滤）
#
# 为什么必须走这条路（结论见 docs/research/verify/storekittest-spm.md）：
#   1. **必须有宿主 app**。纯 SwiftPM testTarget 没有 app host，`Bundle.main` 是
#      `com.apple.dt.xctest.tool`，缺 `application-identifier` entitlement →
#      `Transaction.currentEntitlements / .all / .unfinished` 全部返回空，
#      RevenueDog 的上报管道（靠 `Transaction` 取 JWS）整条不可测。
#   2. **destination 必须钉 iOS 18.x**。iOS 26.x 模拟器上 `SKTestSession` 整体失灵
#      （storefront 读回空串、`Product.products(for:)` 返回 0），有没有宿主都一样，
#      加 scheme 的 StoreKit 配置也救不回来（FB22500243 / FB22836426）。
#      Apple 工程师称 26.6 起修复，但本机没有 26.6 运行时，**未验证**。
#
# 工程文件是**生成物**（`*.xcodeproj` 已 gitignore），每次跑先 `xcodegen generate`。
#
set -euo pipefail

cd "$(dirname "$0")/.."          # → sdk/ios

EXAMPLE_DIR="Example"
PROJECT="$EXAMPLE_DIR/RevenueDogExample.xcodeproj"
SCHEME="${SK_SCHEME:-RevenueDogExample}"
TEST_PLAN="${SK_TEST_PLAN:-RevenueDog-StoreKit}"
TEST_TARGET_NAME="RevenueDogStoreKitTests"
PLAN_FILE="$EXAMPLE_DIR/RevenueDog-StoreKit.xctestplan"

# —— destination（全部可覆盖）——
# 本机可用运行时：iOS 18.5（iPhone Xs / iPad Pro 13-inch (M4)）、iOS 26.5。
# **不要**改成 26.x：见上面第 2 条。
SK_OS="${SK_OS:-18.5}"
SK_DEVICE="${SK_DEVICE:-iPhone Xs}"
DESTINATION="${SK_DESTINATION:-platform=iOS Simulator,OS=$SK_OS,name=$SK_DEVICE}"

DERIVED_DATA="${SK_DERIVED_DATA:-.build-storekit-tests}"

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
if [[ ! -x "$XCODEGEN" ]]; then
    echo "❌ 找不到 xcodegen（brew install xcodegen）" >&2
    exit 2
fi

echo "==> xcodegen generate（${EXAMPLE_DIR}）"
(cd "$EXAMPLE_DIR" && "$XCODEGEN" generate)

# 测试计划里记的是 target 的 pbxproj UUID。XcodeGen 生成的 UUID 是确定性的
# （同一份 project.yml → 同一个 UUID），所以正常情况下这一步是空操作；
# 一旦 target 改名 / project.yml 结构变化导致 UUID 变了，这里就地纠正，
# 免得报出「测试计划找不到 target」这种查半天的错。
python3 - "$PROJECT/project.pbxproj" "$PLAN_FILE" "$TEST_TARGET_NAME" <<'PY'
import json, re, sys

pbxproj, plan_path, target_name = sys.argv[1], sys.argv[2], sys.argv[3]
source = open(pbxproj, encoding="utf-8").read()
match = re.search(
    r"([0-9A-F]{24}) /\* %s \*/ = \{\s*\n\s*isa = PBXNativeTarget;" % re.escape(target_name),
    source,
)
if not match:
    sys.exit("❌ pbxproj 里找不到 target %s" % target_name)
uuid = match.group(1)

plan = json.load(open(plan_path, encoding="utf-8"))
changed = False
for entry in plan.get("testTargets", []):
    target = entry.get("target", {})
    if target.get("name") == target_name and target.get("identifier") != uuid:
        target["identifier"] = uuid
        changed = True
if changed:
    with open(plan_path, "w", encoding="utf-8") as handle:
        json.dump(plan, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print("==> 已把测试计划里的 target identifier 更新为 %s" % uuid)
PY

echo "==> xcodebuild test"
echo "    scheme      = $SCHEME"
echo "    testPlan    = $TEST_PLAN"
echo "    destination = $DESTINATION"

# bash 3.2（macOS 自带）下 `set -u` 会把空数组展开当成未定义变量，
# 所以按需追加，不用空数组占位。
XCODEBUILD_ARGS=(
    test
    -project "$PROJECT"
    -scheme "$SCHEME"
    -testPlan "$TEST_PLAN"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA"
    -resultBundlePath "$DERIVED_DATA/result.xcresult"
    CODE_SIGNING_ALLOWED=NO
)
if [[ -n "${SK_FILTER:-}" ]]; then
    XCODEBUILD_ARGS+=(-only-testing:"$TEST_TARGET_NAME/$SK_FILTER")
fi

# 结果包必须是全新的，否则 xcodebuild 直接拒绝写入
rm -rf "$DERIVED_DATA/result.xcresult"

set +e
xcodebuild "${XCODEBUILD_ARGS[@]}" | tee "$DERIVED_DATA.log"
STATUS=${PIPESTATUS[0]}
set -e

echo
if [[ $STATUS -eq 0 ]]; then
    grep -E "Test run with .* tests? .* passed" "$DERIVED_DATA.log" | tail -1 || true
    echo "✅ StoreKitTest 场景全过（destination=${DESTINATION}）"
else
    echo "❌ StoreKitTest 失败（退出码 ${STATUS}）。排查顺序："
    echo "   1. destination 是不是 iOS 18.x？（26.x 上 SKTestSession 已知失灵）"
    echo "   2. 同一台模拟器上是不是并行跑了两个 xcodebuild test？（会假失败，重跑即好）"
    echo "   3. 详细日志：$DERIVED_DATA.log ／ $DERIVED_DATA/result.xcresult"
fi
exit $STATUS
