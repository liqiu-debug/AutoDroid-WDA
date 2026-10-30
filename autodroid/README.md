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
  查看当前安装包的到期时间：
  `security cms -D -i autodroid/out/WebDriverAgentRunner-Runner.app/embedded.mobileprovision | plutil -extract ExpirationDate raw -`；
  到期前用 `autodroid/resign.sh` 重签同一个包再重装即可，不必重新构建。建议把这条检查加进发布前清单。
- **设备重启后**可能无法再点图标启动（需重新挂载 Developer Disk Image，连一次 Xcode 即可），这是「无人值守」的最大变量。
- **内嵌 XCTest 框架**：iOS 17 起因 `testmanagerd` 更名（`com.apple.private…` → `com.apple.dt.testmanagerd.runner`），runner 内若内嵌 XCTest 副本，脱离 xcodebuild 启动会崩溃。WDA 16.x 构建默认不再内嵌（已实测确认），`build_ipa.sh` 仍保留清理逻辑以兼容旧产物。
- **WDA 没有任何鉴权**：只放在可信局域网，或由平台做一层带鉴权的代理。
- **内存压力下 runner 可能被系统杀掉**，定时任务执行前应先检查 `/status`，不存活则重新激活。
- 设备需要在设置里打开**开发者模式**，且首次安装需要信任证书。

## 设备端执行器（已实现）

fork 在 WDA 之上增加了 AutoDroid 执行器，让设备自己执行平台下发的脚本包：

| 组件 | 说明 |
|---|---|
| `WebDriverAgentLib/AutoDroid/ADTRunner` | 接收脚本包 → 落盘到 `Documents/autodroid_runs/<run_id>/` → 用 JavaScriptCore 执行 → 回传结果（回传由包内 runtime.js 完成） |
| `WebDriverAgentLib/AutoDroid/ADTPrimitives` | 原生原语（元素查询复用 WDA 的 `XCUIElement+FBFind`、点击/输入/滑动走 XCTest、截图与坐标按 scale 换算） |
| `WebDriverAgentLib/AutoDroid/ADTImageTools` | 模板匹配（积分图 + 粗筛/精修 NCC，对齐 PC 侧 TM_CCOEFF_NORMED）、SSIM、OCR（Vision） |
| `WebDriverAgentLib/Commands/ADTAutoDroidCommands` | 注册全部 `/autodroid/*` 路由（见下表），均不要求 WebDriver 会话 |

**适配层不在这里**：AutoJs6 API 兼容层（`adapter.js`）由平台随脚本包下发
（平台仓库 `backend/autojs_export/adapters/ios_adapter.js`，包内字段 `adapter_js`），
执行器优先使用包内适配层 —— 这样**改适配层不需要重新签名/安装 WDA**。

### 执行器接口

所有路由都挂在 WDA 的 HTTP 服务上（默认 8100 端口），不需要先建 WebDriver 会话，也没有鉴权：

| 路由 | 作用 |
|---|---|
| `GET /autodroid/status` | `{running, run_id, last_result, log_count, version, stop_requested}` |
| `POST /autodroid/run` | 提交脚本包并立即开始执行，返回 `{accepted, run_id}`；执行中再次提交会被拒绝 |
| `POST /autodroid/stop` | 置停止标志；脚本在下一个原语边界检查到后中止（`jsSleep` 期间不会被打断） |
| `GET /autodroid/logs?since=N` | 执行日志 `{lines, next}`；缓冲区上限 6000 行，超出丢最旧 2000 行。iOS App 不用 `since`，每次取完整快照 |
| `POST /autodroid/report` | `{run_id}` → `{found, report}`：取回落盘的报告，供 App 在 WDA 上报失败后补传 |
| `GET /autodroid/schedules` | 当前调度状态：任务列表、各任务 `next_run`、最近事件 |
| `POST /autodroid/schedules` | **整体替换**定时任务（`{items: [...], server, token, username}`），App 每次同步都整包下发 |
| `GET /autodroid/notifications` | 执行器侧通知权限状态 |
| `POST /autodroid/notifications` | 申请通知权限（新版 App 统一关闭 WDA 自身通知，由 App 发） |

`POST /autodroid/run` 载荷（`ADTRunner` 实际读取的字段）：

| 字段 | 说明 |
|---|---|
| `bundle` | 平台 `GET /app-runs/.../script?platform=ios` 返回的整个 JSON |
| `run_id` | App 生成的 UUID，贯穿落盘目录名、上报幂等与完成回跳 |
| `server`、`token` | 供包内 `runtime.js` 回传 `/device-runs/report`；token 只驻留内存 |
| `notify` | 是否发飞书卡片（透传到报告）；**缺省时执行器兜底报告按 `true` 处理**，App 总是显式传 |
| `target_bundle_id` | 被自动化 App 的 bundle id；缺省则跟随 `start_app` 动态设置。当前 iOS App 未发送此字段 |
| `device_serial`、`name` | 写入报告与日志的标识 |
| `notify_app`、`completion_bundle_id`、`system_notify` | 完成后是否把客户端 App 拉回前台、拉哪个、是否由 WDA 自己发系统通知 |

定时任务项（`items[]`）字段：`id, enabled, rule(once|daily|weekly|interval), hour, minute, weekday, interval, fetch_url, next_run`；
`fetch_url` 是触发时向平台取脚本的完整地址，配合整包里的 `server/token/username` 使用。

落盘与持久化：

- 每次运行落到 `Documents/autodroid_runs/<run_id>/`（`manifest.json`、`runtime.js`、`adapter.js`、`main.js`、`cases/`、`assets/`，执行完写 `report.json`），
  **只保留最近 10 次**（`pruneRunsRoot:keep:10`）。
- 调度状态持久化在 `Documents/autodroid_scheduler.json`（任务、`next_run`、最近 100 条事件），WDA 重启后由 App 重新同步。
- 完成后若 `notify_app` 为真，执行器会 `activate` `completion_bundle_id` 指定的 App——**目前硬编码只接受 `com.liuzhenyu.autodroid.ios`**（`ADTRunner.m` 的 `returnToClient:`），客户端换 Bundle ID 必须同步改这里。
- 脚本在 `evaluateScript:` 里同步执行，**没有执行超时**；死循环脚本会让执行器保持 `running` 直到 WDA 重启。

### 单元测试

AutoDroid 新增的原生测试在 `WebDriverAgentTests/UnitTests/`（`ADTRunnerTests.m`、`ADTImageToolsTests.m`），
是 XCTest 目标，**不在 `npm test`（只跑 TypeScript 单测）也不在任何 GitHub Actions 里**，需要本机跑：

```bash
xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentLib \
  -destination 'platform=iOS Simulator,id=<模拟器标识>' \
  -only-testing:UnitTests/ADTRunnerTests -only-testing:UnitTests/ADTImageToolsTests test
```

## 真机验证（Phase 0）

真机到手后按顺序做：

```bash
# 1) 手机点 WDA 图标启动，然后在同一网络的本机执行自动检查
autodroid/verify_device.sh http://<手机IP>:8100 --platform-repo ../AutoDroid

# 2) 只跑平台侧自检（下发自检包 → 执行 → 等结果）
cd ../AutoDroid && .venv/bin/python -m backend.autojs_export.selftest --url http://<手机IP>:8100

# 3) 无真机时先做 JS 链路验证（Node 扮演原生原语，覆盖 runtime.js + 适配层 + 报告载荷）
cd ../AutoDroid && .venv/bin/python -m unittest backend.tests.test_ios_runtime_harness
```

自检包会启动「设置」、截图 + OCR、滑动、返回、回桌面，不依赖任何业务应用与界面语言。

脚本无法替代、需要人工确认的项：
点图标启动是否成功、重启后是否还能启动、锁屏/后台 2 分钟后会话是否还在、证书 7 天续期流程。

## 在模拟器上先跑一遍（可选，但推荐）

模拟器能覆盖原生层（XCTest 元素查询、坐标换算、Vision OCR、模板匹配），比真机迭代快。
前提是 Xcode 里已安装 iOS 模拟器运行时：

1. Xcode → Settings → Components → 下载 **iOS Simulator** 运行时（需在 Xcode 中登录 Apple ID，
   命令行 `xcodebuild -downloadPlatform iOS` 在没有交互式认证时不会推进）；
2. 之后即可：

```bash
# 构建并装到模拟器（无需签名）
xcodebuild build-for-testing -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/wda-sim
xcodebuild test-without-building -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/wda-sim &
# 然后跑平台侧自检（模拟器上 WDA 监听本机 8100）
cd ../AutoDroid && .venv/bin/python -m backend.autojs_export.selftest --url http://127.0.0.1:8100
```

## 原生层尚未验证的部分

`ADTPrimitives` / `ADTImageTools` 里的 XCTest 与 Vision 调用只能在真机或 iOS 模拟器上验证
（元素查询语义、坐标换算、模板匹配精度、OCR 语言与阈值）。模拟器上可以先用同一套自检包
跑通流程，再上真机复核。
