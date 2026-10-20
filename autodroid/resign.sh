#!/usr/bin/env bash
#
# AutoDroid-WDA: 用指定证书重新签名 runner 包，产出可安装的 IPA。
#
# 典型场景:
#   - 免费 Apple ID / 指定个人证书签名（Xcode 自动签名不方便时）
#   - build_ipa.sh 用 BUNDLE_ID 改写过包名（改包名会破坏原签名）
#   - 证书到期后重签同一个包
#
# 用法:
#   IDENTITY="Apple Development: foo@bar.com (XXXXXXXXXX)" \
#   PROFILE=~/Library/MobileDevice/Provisioning\ Profiles/xxx.mobileprovision \
#   autodroid/resign.sh autodroid/out/WebDriverAgentRunner-Runner.app autodroid/out/AutoDroidWDA-signed.ipa
#
# 环境变量:
#   IDENTITY  必填，codesign 身份（security find-identity -v -p codesigning 可列出）
#   PROFILE   可选，.mobileprovision 路径。提供后会写入 embedded.mobileprovision，
#             并用其 entitlements 签名（自签/指定证书场景通常需要）。
#
# 说明: 签名顺序为 内部框架/插件 -> 外层 .app，避免嵌套签名校验失败。
set -euo pipefail

INPUT="${1:-}"
OUTPUT="${2:-}"
IDENTITY="${IDENTITY:-}"
PROFILE="${PROFILE:-}"

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
    echo "用法: IDENTITY=\"<签名身份>\" [PROFILE=<.mobileprovision>] $0 <输入 .app 或 .ipa> <输出 .ipa>" >&2
    exit 1
fi
if [ -z "$IDENTITY" ]; then
    echo "缺少 IDENTITY。可用签名身份:" >&2
    security find-identity -v -p codesigning >&2 || true
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1) 准备一个可写的 .app
case "$INPUT" in
    *.ipa)
        ditto -x -k "$INPUT" "$WORK/ipa"
        APP="$(find "$WORK/ipa/Payload" -maxdepth 1 -name "*.app" | head -1)"
        ;;
    *.app)
        APP="$WORK/$(basename "$INPUT")"
        cp -R "$INPUT" "$APP"
        ;;
    *)
        echo "输入必须是 .app 或 .ipa: $INPUT" >&2
        exit 1
        ;;
esac
if [ -z "${APP:-}" ] || [ ! -d "$APP" ]; then
    echo "在输入里找不到 .app" >&2
    exit 1
fi
echo "==> 待签名: $APP"

# 2) 兼容清理内嵌 XCTest 框架（iOS 17+ 需使用设备本地 XCTest）
for path in "$APP"/Frameworks/XC*.framework "$APP"/Frameworks/Testing.framework \
            "$APP"/Frameworks/libXCTestSwiftSupport.dylib "$APP"/PlugIns/*.xctest/Frameworks/XC*.framework; do
    [ -e "$path" ] || continue
    echo "    移除内嵌测试框架: $(basename "$path")"
    rm -rf "$path"
done

# 3) 可选：写入描述文件并提取 entitlements
ENTITLEMENTS=""
if [ -n "$PROFILE" ]; then
    [ -f "$PROFILE" ] || { echo "找不到描述文件: $PROFILE" >&2; exit 1; }
    cp "$PROFILE" "$APP/embedded.mobileprovision"
    ENTITLEMENTS="$WORK/entitlements.plist"
    security cms -D -i "$PROFILE" > "$WORK/profile.plist"
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK/profile.plist" > "$ENTITLEMENTS"
    echo "==> 已写入 embedded.mobileprovision 并提取 entitlements"
fi

sign() {
    local target="$1"
    if [ -n "$ENTITLEMENTS" ]; then
        codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$target"
    else
        codesign --force --timestamp=none --sign "$IDENTITY" "$target"
    fi
}

# 4) 由内到外签名
while IFS= read -r -d '' item; do
    sign "$item"
done < <(find "$APP" \( -name "*.framework" -o -name "*.dylib" \) -not -path "$APP" -print0)

while IFS= read -r -d '' item; do
    sign "$item"
done < <(find "$APP" \( -name "*.appex" -o -name "*.xctest" \) -print0 2>/dev/null)

sign "$APP"

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -3

# 5) 打包 IPA（顺带清掉调试符号）
find "$APP" -name "*.dSYM" -prune -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$WORK/out/Payload"
cp -R "$APP" "$WORK/out/Payload/"
mkdir -p "$(dirname "$OUTPUT")"
# 先转成绝对路径：zip 会在 $WORK/out 子 shell 里执行，相对路径会解析错
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
rm -f "$OUTPUT"
(cd "$WORK/out" && zip -qry "$OUTPUT" Payload)

echo "==> 完成: $OUTPUT"
echo "    安装: xcrun devicectl device install app --device <UDID> \"$APP\"，或将 IPA 交给 Apple Configurator / AltStore / Sideloadly"
