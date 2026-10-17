#!/usr/bin/env bash
#
# AutoDroid-WDA: 构建可安装到真机的 WebDriverAgentRunner IPA。
#
# 用法:
#   autodroid/build_ipa.sh
#   TEAM_ID=XXXXXXXXXX autodroid/build_ipa.sh
#
# 可选环境变量:
#   TEAM_ID       Apple 开发者团队 ID。设置后启用 Xcode 自动签名，产物可直接装机；
#                 不设置则做无签名构建（仅用于验证编译与产出未签名包）。
#   BUNDLE_ID     自定义测试包 Bundle ID（默认沿用上游 com.facebook.WebDriverAgentRunner，
#                 此时 Runner 应用 ID 为 <BUNDLE_ID>.xctrunner）。
#   CONFIG        构建配置，默认 Debug。
#   OUT_DIR       输出目录，默认 <repo>/autodroid/out。
#   DERIVED       派生数据目录，默认 <repo>/autodroid/.derivedData。
#   DESTINATION   构建目标，默认 generic/platform=iOS。
#
# 产物:
#   $OUT_DIR/AutoDroidWDA.ipa                 可安装的 IPA（未经重签则需签名后才可装机）
#   $OUT_DIR/WebDriverAgentRunner-Runner.app  未打包的 .app，配合 xcrun devicectl 直接安装
#
# 装机与启动（详见 autodroid/README.md）:
#   1. xcrun devicectl device install app --device <UDID> $OUT_DIR/WebDriverAgentRunner-Runner.app
#      或把 IPA 交给 Apple Configurator / AltStore / Sideloadly 安装；
#   2. 在手机上直接点 WebDriverAgentRunner 图标，WDA 会以 xctest 会话方式启动并在 8100 端口监听；
#   3. 验证: curl http://<手机IP>:8100/status
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/autodroid/out}"
DERIVED="${DERIVED:-$REPO_ROOT/autodroid/.derivedData}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"
APP_NAME="WebDriverAgentRunner-Runner.app"
XCTEST_NAME="WebDriverAgentRunner.xctest"

cd "$REPO_ROOT"
mkdir -p "$OUT_DIR"

XCB_ARGS=(
    -project WebDriverAgent.xcodeproj
    -scheme WebDriverAgentRunner
    -configuration "$CONFIG"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED"
)

if [ -n "${TEAM_ID:-}" ]; then
    echo "==> 自动签名构建 (TEAM_ID=$TEAM_ID)"
    XCB_ARGS+=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic)
    if [ -n "${BUNDLE_ID:-}" ]; then
        XCB_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
    fi
    if [ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]; then
        XCB_ARGS+=("PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE_SPECIFIER")
    fi
    xcodebuild build-for-testing "${XCB_ARGS[@]}" -allowProvisioningUpdates
else
    echo "==> 无签名构建（未设置 TEAM_ID，产物不能直接装机）"
    xcodebuild build-for-testing "${XCB_ARGS[@]}" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
fi

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/$APP_NAME"
if [ ! -d "$APP" ]; then
    echo "未找到构建产物: $APP" >&2
    exit 1
fi

# iOS 17 起 testmanagerd 更名为 com.apple.dt.testmanagerd.runner，
# 若 runner 包内嵌了 XCTest 框架副本，脱离 xcodebuild 启动会崩溃；
# 需要改用设备本地 XCTest。WDA 16.x 的构建默认已不内嵌，这里做兼容清理。
removed=0
for path in \
    "$APP"/Frameworks/XC*.framework \
    "$APP"/Frameworks/Testing.framework \
    "$APP"/Frameworks/libXCTestSwiftSupport.dylib \
    "$APP"/PlugIns/*.xctest/Frameworks/XC*.framework; do
    [ -e "$path" ] || continue
    echo "    移除内嵌测试框架: ${path#"$APP"/}"
    rm -rf "$path"
    removed=$((removed + 1))
done
if [ "$removed" -eq 0 ]; then
    echo "    未发现内嵌 XCTest 框架（当前版本默认使用设备本地 XCTest）"
fi

# 无签名路径下如需自定义包名，在这里改写（改写会破坏签名，必须再走 autodroid/resign.sh）
if [ -n "${BUNDLE_ID:-}" ] && [ -z "${TEAM_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/PlugIns/$XCTEST_NAME/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID.xctrunner" "$APP/Info.plist"
    echo "==> Bundle ID 已改写为 $BUNDLE_ID(.xctrunner)，装机前需重新签名: autodroid/resign.sh"
fi

if [ -z "${TEAM_ID:-}" ]; then
    echo "==> 跳过打包可安装 IPA 的签名校验（无签名构建）"
fi

find "$APP" -name "*.dSYM" -prune -exec rm -rf {} + 2>/dev/null || true

rm -rf "$OUT_DIR/Payload" "$OUT_DIR/$APP_NAME"
mkdir -p "$OUT_DIR/Payload"
cp -R "$APP" "$OUT_DIR/Payload/"
rm -f "$OUT_DIR/AutoDroidWDA.ipa"
(cd "$OUT_DIR" && zip -qry AutoDroidWDA.ipa Payload)
rm -rf "$OUT_DIR/Payload"
cp -R "$APP" "$OUT_DIR/$APP_NAME"

echo
echo "==> 完成"
echo "    IPA:  $OUT_DIR/AutoDroidWDA.ipa"
echo "    APP:  $OUT_DIR/$APP_NAME"
echo "    xctestrun（主机侧拉起用）: $DERIVED/Build/Products/WebDriverAgentRunner_iphoneos*.xctestrun"
echo
if [ -n "${TEAM_ID:-}" ]; then
    echo "    安装: xcrun devicectl device install app --device <UDID> \"$OUT_DIR/$APP_NAME\""
else
    echo "    这是未签名包，装机前请设置 TEAM_ID 重新构建，或用 autodroid/resign.sh 重签。"
fi
echo "    启动: 手机点图标运行 WebDriverAgentRunner，随后 curl http://<手机IP>:8100/status 验证。"
