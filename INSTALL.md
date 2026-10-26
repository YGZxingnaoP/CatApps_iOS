# 装机：runner 与 CatCam

两个都是**未签名 IPA**，要用重签工具（Sideloadly / iloader 等）配自己的 Apple ID 装。
runner 与 CatCam 装在同一台手机上：App 走 `127.0.0.1:8100` 回环直连 runner，不需要端口转发。

## 1. runner（WebDriverAgent 魔改版）

```bash
./apply.sh
./Scripts/build-unsigned-ipa.sh     # → dist/catpaws-<版本号>.ipa
```

### 为什么必须「整包无签名」

Xcode 的 `build-for-testing` 会把 XCTRunner 桩 app 和系统 framework 带签名拷过来，
而 `PlugIns/` 里的 `.xctest` 是未签名的 —— 混签名包 iOS 直接拒装，报 `0xE8008001`。
`Scripts/strip-codesign.sh` 递归剥离并用 `otool -l` 复验；打包脚本第 4 步再从**最终 IPA**
解包验一次，有残留就 `exit 1`。

### REID：扩展 id 必须是主 App id 的前缀

Xcode 的 XCTRunner 是反向嵌套：主 App `…WebDriverAgentRunner.xctrunner`，
扩展 `…WebDriverAgentRunner`。多数重签工具要求扩展 id 以主 id 开头且更长，否则报
`Extension X is not part of the main app bundle identifier: Y`。
脚本只把扩展 id 改成 `…xctrunner.tests`；主 App id 与 `.xctest` 文件名/路径都不动。
`REID=0` 可关。

### 外壳 App 必须有 `UILaunchScreen`

iOS 14+ 缺启动屏会把 App 放进兼容模式：`UIScreen.main` 报 320×480@3x（960×1440），
而截图仍是原生 1284×2778，`/device` 的 `pixel/point/scale` 就和截图打架。
必须注入到 `Payload/WebDriverAgentRunner-Runner.app/Info.plist`（xctest bundle 上的不生效），
打包脚本第 2 步做这件事，失败即中止。

### 图标与桌面名

`CustomCode/Scripts/embed-runner-icon.sh` 是 Xcode scheme 的 post-action：把 xctest 里 actool
产出的图标抬到外壳 app 根目录、改 `CFBundleIcons`，并把桌面名设成 `CatPaws <版本号>`
（版本号读自 xctest 的 `Info.plist`，与 `/device` 的 `version` 同源）。改完按原签名者 leaf
证书 SHA-1 重签；失败则回滚，只丢图标。

### 用 go-ios 拉起

```bat
ios list
ios tunnel start --userspace            :: iOS 17+ 必须，需保持运行
ios forward 8100 8100
ios runwda --bundleid=<runner-id> ^
           --testrunnerbundleid=<同上> ^
           --xctestconfig=WebDriverAgentRunner.xctest
```

`<runner-id>` 用 `ios apps --list` 查，别手写：重签会加随机后缀（如 `…xctrunner.D79NHBM8JL`）。

## 2. CatCam

```bash
bash Scripts/build-catcam-ipa.sh     # → dist/catcam-<版本号>.ipa
```

流程同上（组 Payload → 剥签名 → 打包 → 复验）。差别：没有扩展，所以不需要 REID；
没有 Asset Catalog，图标是松散的 `CatCam/Icons/AppIcon60x60@*.png`。
bundle id `com.meowlisis.catcam` 保持不动，重签工具自己 mangling。

免费账号额度：runner 占 2 个 App ID（主 app + REID 后的扩展），CatCam 占 1 个。

## 3. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 安装报 `0xE8008001` | IPA 里有带签名的 Mach-O | 重打，看 `dist/ipa-summary.txt` 的 `macho_signed` 必须为 0 |
| `Extension X is not part of the main app bundle identifier` | 扩展 id 不是主 id 前缀 | 保持 `REID=1` 重打 |
| 点图标闪退 | 证书没信任 / 描述文件过期 / 没开开发者模式 | 信任证书 + 开发者模式；免费证书 7 天到期 |
| 拔线后 runner 失效 | 设备端 `testmanagerd` 约 28 秒后回收 | 插回 USB，重新 `runwda` |
| `ping` 连不上 | 隧道没起 / 没 forward / runner 没拉起 | 依次确认 `ios list`、`tunnel start`、`runwda` |
| 动作返回 `E_DEVICE_LOCKED` | 锁屏 | 解锁 |
| `/device` 的 pixel 与截图不一致 | 外壳 app 缺 `UILaunchScreen` | 确认打包日志有 `UILaunchScreen 已注入` |
