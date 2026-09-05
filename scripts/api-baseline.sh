#!/usr/bin/env bash
#
# api-baseline.sh —— 公开 API 基线冻结（设计 §9 M4「API 基线冻结」）
#
#   ./scripts/api-baseline.sh check    # 比对当前公开 API 与基线，有差异 → 退出码 1
#   ./scripts/api-baseline.sh update   # 有意变更时刷新基线（改动必须进 code review）
#
# 机制：Xcode 自带的 `swift-api-digester`
#   1. `xcodebuild` 交叉编译出 **iOS**（产品基线平台）的 .swiftmodule；
#   2. `-dump-sdk` 把该模块的公开 API 导成 JSON（api-baseline/RevenueDog.json）；
#   3. 从 JSON 里抽一份**排序后的全限定符号清单**（api-baseline/RevenueDog.public-api.txt），
#      它才是 check 的判据 —— 逐行可读、可 review，新增/删除/改签名都会显出来；
#   4. 额外跑一次 `-diagnose-sdk`，把「哪些变更属于 ABI/API breakage」打给人看
#      （注意：`diagnose-sdk` 只报**破坏性**变更，新增 public 符号它不报 ——
#       所以门禁判据必须是清单 diff，不能只看它）。
#
# 为什么基线取 iOS 而不是 macOS：macOS 13 只是为了本机 `swift test` 跑纯逻辑单测，
# 产品面是 iOS 16。公开面上有 `#if canImport(StoreKit)` 门控的符号，平台不同结果不同。
#
set -euo pipefail

MODE="${1:-check}"
cd "$(dirname "$0")/.."

BASELINE_DIR="api-baseline"
BASELINE_JSON="$BASELINE_DIR/RevenueDog.json"
BASELINE_TXT="$BASELINE_DIR/RevenueDog.public-api.txt"
DERIVED_DATA=".build-api-baseline"
TARGET_TRIPLE="arm64-apple-ios16.0"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CURRENT_JSON="$WORK/current.json"
CURRENT_TXT="$WORK/current.txt"

echo "==> 交叉编译 iOS 模块（generic/platform=iOS）"
xcodebuild build \
    -scheme RevenueDog \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet

MODULE_DIR="$DERIVED_DATA/Build/Products/Debug-iphoneos"
if [[ ! -d "$MODULE_DIR/RevenueDog.swiftmodule" ]]; then
    echo "错误：没找到 $MODULE_DIR/RevenueDog.swiftmodule" >&2
    exit 2
fi

echo "==> swift-api-digester -dump-sdk"
xcrun swift-api-digester -dump-sdk \
    -module RevenueDog \
    -o "$CURRENT_JSON" \
    -I "$MODULE_DIR" \
    -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -target "$TARGET_TRIPLE" \
    -swift-version 6 \
    -abort-on-module-fail \
    -avoid-location \
    -avoid-tool-args

# 从 dump 里抽全限定公开符号清单（排序、去重）。
summarize() {
    python3 - "$1" "$2" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
root = json.load(open(src))["ABIRoot"]

lines = set()

def walk(node, prefix):
    kind = node.get("declKind")
    name = node.get("name", "")
    printed = node.get("printedName", name)
    # Import 节点只是模块依赖，不是我们的公开面
    if kind == "Import":
        return
    if kind:
        path = f"{prefix}.{printed}" if prefix else printed
        attrs = [a for a in node.get("declAttributes", []) if a != "RawDocComment"]
        suffix = f"  [{','.join(sorted(attrs))}]" if attrs else ""
        lines.add(f"{kind} {path}{suffix}")
        child_prefix = f"{prefix}.{name}" if prefix else name
    else:
        child_prefix = prefix
    for child in node.get("children", []):
        walk(child, child_prefix)

for child in root.get("children", []):
    walk(child, "")

with open(dst, "w") as handle:
    handle.write("\n".join(sorted(lines)) + "\n")
PY
}

summarize "$CURRENT_JSON" "$CURRENT_TXT"
echo "==> 当前公开符号数：$(wc -l < "$CURRENT_TXT" | tr -d ' ')"

case "$MODE" in
update)
    mkdir -p "$BASELINE_DIR"
    cp "$CURRENT_JSON" "$BASELINE_JSON"
    cp "$CURRENT_TXT" "$BASELINE_TXT"
    echo "✅ 基线已更新：$BASELINE_JSON / $BASELINE_TXT"
    echo "   请把 diff 一起提交并在 PR 里说明每一处公开面变更的理由。"
    ;;
check)
    if [[ ! -f "$BASELINE_TXT" ]]; then
        echo "❌ 基线缺失（$BASELINE_TXT）。先跑：./scripts/api-baseline.sh update" >&2
        exit 1
    fi
    if diff -u "$BASELINE_TXT" "$CURRENT_TXT" > "$WORK/diff.txt"; then
        echo "✅ 公开 API 与基线一致。"
        exit 0
    fi
    echo "❌ 公开 API 与基线不一致（新增 / 删除 / 签名变更都会命中）："
    cat "$WORK/diff.txt"
    if [[ -f "$BASELINE_JSON" ]]; then
        echo
        echo "---- swift-api-digester -diagnose-sdk（只列**破坏性**变更）----"
        xcrun swift-api-digester -diagnose-sdk \
            -input-paths "$BASELINE_JSON" \
            -input-paths "$CURRENT_JSON" \
            -o "$WORK/breakage.txt" 2>/dev/null || true
        [[ -s "$WORK/breakage.txt" ]] && cat "$WORK/breakage.txt" || echo "（无破坏性变更 —— 纯新增也需要 review）"
    fi
    echo
    echo "如为有意变更：./scripts/api-baseline.sh update，并在 PR 说明理由。"
    exit 1
    ;;
*)
    echo "用法：$0 {update|check}" >&2
    exit 2
    ;;
esac
