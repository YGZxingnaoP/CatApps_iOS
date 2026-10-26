# CatPaws / WDA 工作区

> 目标：让 PC 上的 agent 用「看截图 → 点屏幕 → 再看」的循环操作一台**不越狱**的真实 iPhone。
> 设备端只做「动作 + 观察」，决策留在 PC。
> 整条链路里最花时间的不是写代码，是**签名**——从 Sideloadly 一路折腾到 iloader，见
> [开发历程 §3.3](#33-签名整条链路里最花时间的一环)。

一个仓库，两个项目：

| 目录 | 是什么 | 状态 |
| --- | --- | --- |
| `CatCam/` | 手机端 SwiftUI App（连 runner 的 `/cw/v1`，看状态、截图、点按、停止） | 完整源码，可独立构建 |
| `CustomCode/` | 对 WebDriverAgent 的**魔改部分**（28 个新增 + 15 个改后文件），按 WDA 内的相对路径存放 | 只放改动，WDA 源码不入库 |
| `Scripts/` | 两个打包脚本：runner 未签名 IPA、剥离签名 | 见下 |
| `Patches/` | 同一批魔改的 git patch（review 用 / 上游升级后重放） | — |
| `WebDriverAgent/` | 上游 WebDriverAgent 的检出（自带 `.git`） | **不入库**，`apply.sh` 按 commit 拉 |
| `Docs/` | 内部设计/交接笔记 | **不入库** |
| `dist/` | 构建产物 | **不入库** |

关系：

```
CatCam.app（手机上前台 App） ──HTTP 127.0.0.1:8100/cw/v1/*──► WDA 魔改版 runner
        ▲                                                        ▲
   CatCam/ 源码                                        CustomCode/ + 上游 WebDriverAgent
```

## 1. WDA 魔改模块（`CustomCode/`）

上游钉死：

```
repo    https://github.com/appium/WebDriverAgent.git
version v16.15.0
commit  e7e2665a00633dc174d7fc579f7e606bc9ba782a
```

**为什么魔改文件不就地放在 `WebDriverAgent/` 里跟踪？**
因为 `WebDriverAgent/` 是它自己的 git 仓库，git 不允许把嵌套仓库里的单个文件当普通文件提交
（只会记成一个 submodule 指针）。所以魔改文件另存一份到 `CustomCode/`，路径与 WDA 内一致，
`apply.sh` 一条命令盖过去 —— 仓库里因此只有你一人的改动，没有上游那 658 个文件。

```bash
./apply.sh                       # 拉 pinned commit → ./WebDriverAgent，再覆盖 CustomCode
./Scripts/build-unsigned-ipa.sh  # 构建 + 剥签名 + 打 IPA
```

产物 `dist/catpaws-<版本号>.ipa`（版本号取自 `WebDriverAgentRunner/Info.plist`），
装机步骤见 [INSTALL.md](INSTALL.md)，接口见 [API.md](API.md)。

`CustomCode/` 里多出来的两个东西不参与覆盖：`Config/cw_config.example.plist`（示例配置）
和 `README.md`（本目录说明）。

## 2. CatCam App（`CatCam/`）

```bash
bash Scripts/build-catcam-ipa.sh                    # → dist/catcam-<版本号>.ipa
DERIVED=/tmp/dd bash Scripts/build-catcam-ipa.sh    # 自定义派生数据目录
```

- target / 产物：`CatCam` / `CatCam.app`，bundle id `com.meowlisis.catcam`
- 部署目标 iOS 15.0，Swift 5 + SwiftUI，无第三方依赖、无 entitlement
- 与 runner 的区别：没有扩展（不需要 REID）、没有 Asset Catalog（不触发 actool）

## 3. 开发历程

### 3.1 起因

目标很具体：**PC 上跑着的 agent，用「看一眼 → 点一下 → 再看一眼」操作一台真实的 iPhone**，
第一个要跑通的场景是「打开 QQ，给某人发一条消息」。约束四条，每条后来都变成了坑：

1. 不越狱 → 只能走 XCTest 这条路；
2. 免费 Apple ID → 证书 **7 天**过期，重签重装是常态；
3. 只有 Windows 主机 + 一台 iPhone → Xcode 只能在 macOS 上跑；
4. PC 侧要能"看见"屏幕 → 设备端必须给图（截图/OCR），不能只给元素树。

所以形态定死：**设备端只做「动作 + 观察」，决策留在 PC。**

### 3.2 环境：Windows + VMware 里的 macOS

VMware 装 macOS 15.7.5 + Xcode 26.3，与 Windows 之间**只用系统自带 `ssh.exe` / `scp.exe`**
（不装共享目录插件），因为要验证的是真实构建链路。

| 坑 | 现象 | 处理 |
| --- | --- | --- |
| 内存 | 8 GB 被 Xcode 吃满、swap 百万次 | 加到 12–16 GB |
| 下行带宽 | 虚拟机 → 主机只有 20–30 KB/s（上行 5 MB/s） | IPA 改 3 MiB × 4 路并行分块 + SHA-256 校验，94 KB/s |
| mtime | 推工程会带本地修改时间 | 比上次构建新就整仓重编（10–15 分钟，实测一次 14 分 41 秒） |

一条 SSH 命令固定 150–170 ms 开销（Windows OpenSSH 不支持连接复用），所以小命令都合并成一条。

### 3.3 签名：整条链路里最花时间的一环

这一段是整个项目的分水岭：**代码早就能跑了，卡在"怎么把包装进手机"卡了很久。**

#### 3.3.1 为什么必须自己签，而且必须"整包剥干净"

免费 Apple ID 没有企业分发，只能装「自己团队签名」的包。而 Xcode 的 `build-for-testing` 会把
XCTRunner 桩 App 和 14 个系统 framework 带着**苹果证书的签名**原样拷过来，
`PlugIns/` 里的 `.xctest` 却是未签名的 —— 这就是**混签名包**，iOS 直接拒装：

```
ApplicationVerificationFailed   0xE8008001
```

关键认知（走了很多弯路才确认）：**签名数据在 Mach-O 内部**（`LC_CODE_SIGNATURE`），
只删 `Payload/xxx.app/_CodeSignature` 目录是没用的。必须逐个二进制
`codesign --remove-signature`，再用 `otool -l` 复验没有 `LC_CODE_SIGNATURE` 残留。
`Scripts/strip-codesign.sh` 就是干这个的；打包脚本第 4 步还要**从最终 IPA 解包再验一遍**，
剩一个带签名的 Mach-O 就 `exit 1`——不给自己留"看起来成功"的包。

#### 3.3.2 Sideloadly：两个设置陷阱 + 一个会吃掉原文件的坑

第一站是 Windows 上的 **Sideloadly 0.71.1**。日志反复出现 `No-resign mode`，装机到 5% 就失败。

| 坑 | 真相 |
| --- | --- |
| `No-resign mode` | 设置里的 `Normal Install` **不是"正常安装"**，而是"不重签、原样装"。必须选 `Apple ID Sideload` |
| 设置被重置 | 面板上写着 `Signing Mode (will be reset on restart)`——每次启动都重置，顺序必须是先开程序、再改模式、再点 Start，中间不能关 |
| 原文件被截断 | **签名失败时 Sideloadly 会把打开的 IPA 截断成 0 字节**（实测发生两次）。所以 `temp\sideload.cmd` 永远先复制到 `%TEMP%` 再打开，绝不指向 `dist/` |

#### 3.3.3 卡死点：`Login failed (-80046)`

切到 `Apple ID Sideload` 后挡住的是登录：

```
Login failed (-80046): This action cannot be completed at this time.
```

同一个账号在浏览器里能正常登录，所以不是密码问题。排查结论：

- Sideloadly 的 **Local Anisette** 依赖 iTunes 的 `Apple Application Support` 组件，
  本机没有（`C:\Program Files (x86)\Common Files\Apple\...` 不存在，`D:\iTunes` 里也没有 `AOS*` DLL）；
- `Fake Anisette` 选项是**灰的**，`Remote Anisette` 要付费；
- iTunes 官网安装包装不上（装到一半失败）；
- 大背景：当时正赶上 **2026 年 10 月 Apple 收紧 Windows 侧签名**（同期的第三方反馈都是这个结论），
  换句话说不是配置没调对，是这条路整片不可用——这也是为什么后面干脆换了工具。

#### 3.3.4 试过的其它路，全部败在"要登录态"

| 尝试 | 结果 |
| --- | --- |
| macOS 虚拟机里装 Sideloadly（dmg） | 登录同样过不去（anisette 要 Mail 插件 / Apple ID 服务） |
| Xcode 直接 `Product → Test` 装机 | 需要虚拟机登录 Apple ID，系统设置报"发生未知错误"；`developer.apple.com` 的 Enroll 是付费计划，**免费安装不需要**，别去点 |
| AltServer（macOS） | 同样依赖 Apple ID 登录态 |
| 改虚拟机 `board-id` / 序列号去骗身份 | 可行但风险高、不确定；最终没用上 |
| 爱思助手等 Windows 签名工具 | 同样吃 anisette，且当时正赶上 Apple 收紧 |

顺带排掉的两个假线索：虚拟机时钟曾快 15 小时、Windows 的 DNS 有个坏掉的 IPv6 服务器——
修完之后 `-80046` **依旧**，说明它们不是主因。

#### 3.3.5 换 iloader：为什么是它

最终选 **[`nab138/iloader`](https://github.com/nab138/iloader)**（内嵌 `isideload`，开源）：

- Windows 单文件 exe（`iloader-windows-x64.exe`），不需要装 iTunes / Apple 应用支持；
- 它的登录走自己的 anisette 实现，绕开了 Sideloadly 那条断掉的路；
- 版本从 **2.3.10** 试到 **2.4.0**。

下载它本身就是个小工程：先在虚拟机里下（那边网络到 GitHub 正常），再用 `pull-ipa.cmd`
分块拉回 Windows，**拉完必须和虚拟机 `shasum -a 256` 对上**——下行 20 KB/s 的环境里，
一个字节的偏差就白等十分钟。

#### 3.3.6 iloader 装上之后的第二个拦路虎：扩展 id（REID）

iloader 第一次装就报：

```
Extension X is not part of the main app bundle identifier: Y
```

原因藏在 `isideload` 的 `update_bundle_id()` 里：它要求**扩展 id 以主 App id 开头且更长**。
而 Xcode 的 XCTRunner 是"反向嵌套"：

```
主 App   com.facebook.WebDriverAgentRunner.xctrunner
扩展     com.facebook.WebDriverAgentRunner          ← 反而比主 App 短
```

解法（打包脚本第 2.5 步，`REID=1` 默认开）：**只改扩展 id**，改成主 App id 的子域

```
com.facebook.WebDriverAgentRunner.xctrunner.tests
```

主 App id 一个字不动；`.xctest` 的文件名和路径也不动——go-ios 是按**路径**加载 xctest 的，
模块名取自**文件名**，都不依赖 id。`REID=0` 可关闭（回到 Xcode 原始结构）。

#### 3.3.7 免费证书会给 bundle id 加后缀

装完之后查到的 id 是：

```
com.facebook.WebDriverAgentRunner.xctrunner.D79NHBM8JL
```

那个后缀是签名工具加的，**每次重签都可能变**。所以拉起逻辑里绝不写死 id，
一律 `ios apps --list` 动态查；缓存里的旧 id 查不到就自动重查（`catpaws-launcher` 里的
`Get-RunnerId -Verify`）。这条不写死，直接决定了"7 天后还能不能自己恢复"。

#### 3.3.8 代价与现状

| 项 | 现在的做法 |
| --- | --- |
| 装机 | 手动：iloader 是 GUI + 要登录态 + 写 `%APPDATA%`，脚本代劳不了（沙箱里跑直接 panic） |
| 有效期 | 免费证书 **7 天**，到期重签重装，id 可能变 |
| 装完 | 手机上「设置 → 通用 → VPN 与设备管理」信任证书 + 打开「开发者模式」 |
| 失败信号 | `0xE8008001` = 包没剥干净；`Extension X is not part of…` = 没做 REID |

#### 3.3.9 可以照抄的五条

1. **包必须整包无签名**，并且要从最终 IPA 复验（不是只看中间产物）；
2. **工具必须真重签**——`Normal Install` / no-resign 这类模式装未签名包必然失败；
3. **扩展 id 必须重写**（REID），否则 isideload 系工具直接拒绝；
4. **bundle id 会变**，拉起时动态查，别写死；
5. **别让签名工具直接动 `dist/`**，它失败时会把原文件截断成 0 字节。

### 3.4 把 WDA 改成 `/cw/v1`（runner 1.0.1）

WebDriverAgent 是完整 WebDriver 实现：要建 session、返回元素树而不是像素、PC 还得自己算坐标。
保留它全部能力，另加一层只服务这个场景的接口：`/ping`、`/device`、`/screenshot`、`/actions`、
`/stop`、`/ocr`、`/paste`。

28 个新文件 + 16 处改动，刻意**不**替换原有路由（Appium 照常可用，要收敛用 `CW_ONLY=1`）。
第一次真机实测动作链路全通，但当场暴露两个问题——回头看都不是"写错了"，是不了解 iOS 的行为。

### 3.5 两个「看起来是 bug，其实是 iOS 行为」的问题

**一、`/device` 说屏幕 960×1440，截图却是 1284×2778。** PC 按它做越界校验会把 40% 屏幕判成越界。
两层根因：XCTRunner 缺 `UILaunchScreen` → iOS 14+ 进兼容模式，`UIScreen.main` 报 320×480@3x；
`CWGeometry` 三字段不同源。第一轮把 `UILaunchScreen` 加在 xctest bundle 上**没生效**——
必须注入**外壳 App**（`WebDriverAgentRunner-Runner.app/Info.plist`），只能在打包时用 PlistBuddy 做。
几何改成同源推导：`pixel` = 截图实测尺寸、`scale` = `nativeScale`、`point` = `pixel / scale`。

**二、`duration_ms=500` 的 swipe 要 4723 ms。** 关掉 `waitForIdleTimeout` 无效；翻 `wda.log`
才发现还有 `animationCoolOffTimeout`（默认 2 秒，**每个手势前后各等一次**）和
`fb_shouldWaitForQuiescence`。三者一起关：

| 动作 | 修之前 | 1.0.7 实测 |
| --- | --- | --- |
| swipe 500ms | 4723 ms | **851 ms** |
| 10 × swipe 300ms | 35 696 ms | **7186 ms** |
| tap / long_press / drag | — | 338 / 945 / 1244 ms |
| press_key home | 487 ms | 481 ms |

### 3.6 CatCam：为什么要一个手机上的 App

人不在 PC 前面时需要能在手机上直接看状态、点一下、急停；`.cam` 页面也要把 PC 网页投影回手机。
所以做了同机 App，走 `127.0.0.1:8100` 回环直连 runner，不需要端口转发。

开发顺序上省了时间：**先在模拟器里用假 `/cw/v1` 服务把三路指示灯跑通**（模拟器的 `127.0.0.1`
就是 Mac 的回环），链路逻辑验证完再上真机。真机才知道两个产品事实，后来都写进了 UI：

- 拔线不是"变慢"是"会死"：实测约 **28 秒**后 runner 被设备端 `testmanagerd` 回收（不是 go-ios 杀的）；
- 插回约 **6 秒**自动恢复，所以状态页做「已断开 / 正在重连」而不是一句红字。

### 3.7 拉起：把"能跑一次"变成"能一直跑"

go-ios 的四个坑固定成了 `catpaws-launcher`：`--opt=值` 的写法（含空格要引号）、
`runwda` **不做**端口转发（必须另起 `ios forward`）、`--bundleid` 与 `--testrunnerbundleid` 填同一个、
iOS 17+ 必须先 `ios tunnel start --userspace`。守护进程负责拔线打 `[WAIT]`、插回自动恢复、
证书过期时明说「没找到已安装的 CatPaws」而不是反复重试。

### 3.8 现在的状态

| 版本 | 这一步解决了什么 |
| --- | --- |
| 1.0.1 | `/cw/v1` 全链路打通，首次真机实测 |
| 1.0.2 | `/device` 几何同源、越界只在真越界时拒绝 |
| 1.0.3 | 手势关掉三处"等界面静止" → swipe 500ms 从 4.7 s 到 0.85 s |
| 1.0.4 | 新增 `drag`、`/screenshot?region=` |
| 1.0.7 | 真机联调收敛（CatCam 同步到 1.0.5），时延定稿 |

当前快照：

| 项 | 值 |
| --- | --- |
| runner | **1.0.7**（`…xctrunner.<后缀>`，桌面名 `CatPaws 1.0.7`） |
| CatCam | **1.0.5** |
| 测试机 | iPhone 12 Pro Max / iOS 18.3.2（`iPhone13,4`） |
| 屏幕 | pixel 1284×2778 / point 428×926 / scale 3 |
| 能力 | tap, long_press, swipe, drag, pinch, type_text, paste_text, press_key, launch_app, activate_app, terminate_app, screenshot, ocr |
| 已跑通的闭环 | 打开 QQ → 搜索联系人 → 发一条消息 → 截图确认 |

还没做：`/source`、屏幕推流（ReplayKit / H.264）、横屏、`.cam` 页自签证书指纹校验、停止的 WS 链路。

## 4. 许可

- `CustomCode/` 是对 WebDriverAgent 的改造，沿用上游 **BSD** 许可，版权声明见 `CustomCode/LICENSE`、
  归属说明见 `CustomCode/NOTICE`；
- `CatCam/` 为 MIT，见 `CatCam/LICENSE`。
