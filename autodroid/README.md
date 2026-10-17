# AutoDroid-WDA

[AutoDroid](https://github.com/liqiu-debug/AutoDroid) 自动化测试平台的 **iOS 设备端执行器**：`appium/WebDriverAgent` 的 fork，目标是让 iOS 手机在**不接电脑**的情况下自己起 WDA 会话、执行平台下发的脚本并回传结果（对应 Android 侧的 [AutoDroid-Android](https://github.com/liqiu-debug/AutoDroid-Android)）。

- 上游：`appium/WebDriverAgent`（BSD 许可，详见 [LICENSE](../LICENSE)）
- 本 fork 保持可直接同步上游（`git remote add upstream https://github.com/appium/WebDriverAgent.git`，改动集中在 `autodroid/`，补丁保持薄）
- 当前基于 WDA `16.15.3`，已在 Xcode 27.1 下验证可编译

## 为什么是 WDA + 「点图标启动」

非越狱 iOS 上做 UI 自动化只有 XCTest / WDA 一条路（越狱在 2026 年只覆盖 A12/A13 的 iOS 18.7.1 与 26.0–26.0.1，新机型没有）。而**普通 App 进入后台几秒就会被系统挂起**，只有 XCTest runner 进程能在目标 App 处于前台时持续工作——所以执行器必须活在 WDA 进程内，WDA 同时承担「驱动层」和「执行宿主」两个角色。

「手机端本地激活」指：把 runner 包装到手机上后，**直接点图标**即以 xctest 会话方式启动 WDA，监听 8100 端口，不再需要 USB 连接或 `xcodebuild test-without-building`。

## 构建与安装

```bash
# 1) 无签名构建（只验证编译、产出未签名包）
autodroid/build_ipa.sh

# 2) 自动签名构建（需要 Apple 开发者团队 ID，产出可直接装机的 IPA）
TEAM_ID=XXXXXXXXXX autodroid/build_ipa.sh

# 3) 自定义包名（避免与已装应用冲突；runner 会变为 <BUNDLE_ID>.xctrunner）
TEAM_ID=XXXXXXXXXX BUNDLE_ID=com.example.autodroid.wda autodroid/build_ipa.sh

# 4) 用指定证书重签（免费 Apple ID / 证书到期后重签同一个包）
IDENTITY="Apple Development: me@example.com (XXXXXXXXXX)" \
  autodroid/resign.sh autodroid/out/WebDriverAgentRunner-Runner.app autodroid/out/AutoDroidWDA-signed.ipa
```

产物在 `autodroid/out/`。安装方式三选一：

```bash
xcrun devicectl device install app --device <UDID> autodroid/out/WebDriverAgentRunner-Runner.app
```

或者把 IPA 交给 Apple Configurator / AltStore / Sideloadly 安装。装好后**在手机上点 `WebDriverAgentRunner` 图标**启动，然后验证：

```bash
curl http://<手机局域网IP>:8100/status
```

主机侧拉起（调试用，非日常路径）：

```bash
xcodebuild test-without-building \
  -xctestrun autodroid/.derivedData/Build/Products/WebDriverAgentRunner_iphoneos*.xctestrun \
  -destination 'id=<UDID>'
```

## 版本适配

| 目标系统 | 要求 | 备注 |
|---|---|---|
| iOS 18.x | WDA 13+ / XCUITest driver 11.5+（本 fork 16.x 满足） | 18.3.1 有社区反馈起不来，18.4 修复；建议 18.4+ |
| iOS 26.x | Appium 3 + XCUITest driver ≥10；26.4 起需 driver ≥10.23.2（WDA ≥11.1.5） | Xcode 26 起 CLI 自动签名需 `-allowProvisioningUpdates`（`build_ipa.sh` 已带） |
| iOS 27.x | XCUITest driver 11.17.5+ / WDA v13+；构建需 deployment target ≥ iOS 15（上游已改） | Appium 已禁用 `devicectl` 拉起 preinstalled WDA 的兜底路径，主机侧只能走 RemoteXPC tunnel；设备端「点图标」路径需真机验证 |

一套用 Xcode 27 + 本 fork 构建的包可同时覆盖 18/26/27（Xcode 27 只是不再支持在 iOS 15/16 上跑测试）。

## 已知坑与运维注意

- **证书有效期**：免费 Apple ID 7 天到期需重签重装；付费账号 1 年。自动注册设备会消耗 100 台/年配额。
- **设备重启后**可能无法再点图标启动（需重新挂载 Developer Disk Image，连一次 Xcode 即可），这是「无人值守」的最大变量。
- **内嵌 XCTest 框架**：iOS 17 起因 `testmanagerd` 更名（`com.apple.private…` → `com.apple.dt.testmanagerd.runner`），runner 内若内嵌 XCTest 副本，脱离 xcodebuild 启动会崩溃。WDA 16.x 构建默认不再内嵌（已实测确认），`build_ipa.sh` 仍保留清理逻辑以兼容旧产物。
- **WDA 没有任何鉴权**：只放在可信局域网，或由平台做一层带鉴权的代理。
- **内存压力下 runner 可能被系统杀掉**，定时任务执行前应先检查 `/status`，不存活则重新激活。
- 设备需要在设置里打开**开发者模式**，且首次安装需要信任证书。

## 后续计划（执行器补丁，尚未实现）

1. 新增 `/autodroid/status|run|stop` 路由（`WebDriverAgentLib/Commands/` + `FBWebServer` 注册）；
2. 内嵌 **JavaScriptCore** 运行平台下发的 `runtime.js`（与 Android 侧同一份执行器，语义不分叉）；
3. 适配层：把 `runtime.js` 依赖的 AutoJs6 API 映射到 WDA 自身的 HTTP 接口（`127.0.0.1:8100`）；
4. 报告直传平台（复用 `/device-runs/report` 的 `run_id` 幂等契约）；
5. 图像类动作（模板匹配 / SSIM）先由平台预检拦截，OCR 走 iOS **Vision** 框架实现。
