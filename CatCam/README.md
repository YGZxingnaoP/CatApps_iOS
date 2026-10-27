# CatCam

手机端控制面板（SwiftUI，iOS 15+，无第三方依赖，无 entitlement）。

两条链路：

1. **runner 控制**：`http://127.0.0.1:8100/cw/v1/*` 直连同机 runner——看状态、截图、点按、回桌面、打断动作；
2. **`.cam` 原生客户端（1.2.0 起）**：`wss://<pc>:8443/ws` 推相机 H.264、推麦克风 PCM、轮询 TTS 并播放、聊天、通话/聊天模式、证书指纹固定。**不再用 WKWebView 载入 `.cam` 页面**。

> 与 runner 的关系：runner = 上游 WebDriverAgent + 本仓库 `CustomCode/`。
> 两者装在同一台手机上，App 走回环，**不需要** `go-ios forward`。
> 交付说明与主项目（`.cam`）对接清单见 `Docs/CATCAM_NATIVE.md`。

## 结构

```
CatCam.xcodeproj/                 手写最小工程（1 个 target，无 workspace、无 Podfile）
  xcshareddata/xcschemes/CatCam.xcscheme
CatCam/
  CatCamApp.swift          @main + 4 个 Tab + 非相机页的常驻「停止」按钮
  CWConfig.swift           UserDefaults 键的读写与 URL 拼装
  CWClient.swift           /cw/v1 客户端（ping / device / screenshot / actions / stop）
  CWStore.swift            App 状态、自检、日志（最多 200 条，落 UserDefaults）
  CWStatusView.swift       状态页：三路指示灯 + /device 信息 + 分辨率告警
  CWOperationsView.swift   操作面板：截图预览、停止、点按、回桌面
  CWSettingsView.swift     设置页：PC 连接 / 相机 / 开关 / 指纹
  CWLogView.swift          日志页
  CWPinning.swift          证书指纹固定（TOFU）+ 共享 URLSession
  CWLive.swift             .cam 原生链路：WS、相机/H.264、音频、TTS、聊天、模式
  CWCamNativeView.swift    相机页（整屏预览 + 三球 + 气泡 + 模式/音量）
  CWWebView.swift          旧 .cam 页面（已不再使用，保留作回退参考）
  CWTheme.swift            配色
  Icons/                   松散图标（不进 Asset Catalog，不触发 actool）
  Info.plist               ATS、本地网络、相机/麦克风、UIBackgroundModes=audio
```

- target / 产物：`CatCam` / `CatCam.app`；bundle id `com.meowlisis.catcam`；桌面名 `CatCam`
- 版本号唯一来源：`CatCam/Info.plist` 的 `CFBundleShortVersionString`

## 构建

```bash
bash Scripts/build-catcam-ipa.sh
DERIVED=/tmp/dd bash Scripts/build-catcam-ipa.sh   # 自定义派生数据目录
```

产物 `dist/catcam-<版本号>.ipa`、`catcam-latest.ipa`、`catcam-build.log`、`catcam-summary.txt`
（后者含 SHA-256 与「Mach-O 签名残留数」，必须为 0，否则 iOS 报 `0xE8008001`）。

Xcode 里直接打开工程也能跑（走正常签名）。

## 配置（UserDefaults，设置页即时写盘）

| key | 说明 | 默认 |
| --- | --- | --- |
| `cw_pc_host` | PC 局域网 IP（可带 `http://`/端口，App 会归一化） | 空 |
| `cw_control_port` | PC 侧控制服务端口 | 18110 |
| `cw_video_port` | PC 侧中继端口 | 18111 |
| `cw_runner_port` | runner 回环端口 | 8100 |
| `cw_token` | Bearer token，空 = 不校验（与 runner 的 `CWToken` 一致） | 空 |
| `cw_screen_fps` | 推流 fps（暂只保存） | 10 |
| `cw_screen_max_edge` | 截图长边（也作 `/screenshot?max_edge=`） | 1280 |
| `cw_screen_bitrate` | 推流码率（暂只保存） | 1500000 |
| `cw_allow_ocr` | 允许 PC 调 OCR（暂只保存） | true |
| `cw_start_in_cam` | 启动落在「相机」Tab | true |
| `cw_meowid` | 用户模式身份：六位编号（000001）或 temp-000012；空 = 手机用户 | 空 |
| `cw_cam_https` | 用 HTTPS/WSS（8443）；关掉走 8445 明文 | true |
| `cw_cam_pin` | `.cam` 证书 SHA-256 指纹；空 = 首次连接自动学习 | 空 |
| `cw_cam_volume` / `cw_cam_muted` | 手机播放 AI 语音的音量/静音（相机页写入） | 1 / false |

`cw_pc_host` 留空时两路 PC 指示灯显示「未配置」，不是「不可达」。

## 已实现 / 未实现

已实现：三路指示灯（只在状态页可见且前台时 3s 轮询）、`/device` 全字段、截图
（`max_edge` 可调、可要原图）、停止（`POST /stop` 显示 `cancelled`/`remaining_steps`）、
点按（`tap` 像素坐标、`press_key home`）、日志页、`/device` 与 `X-CW-Size` 的交叉校验告警；
`.cam` 原生链路：相机 H.264 推流、麦克风上行、TTS 播放（后台）、聊天、模式切换、证书指纹固定；
用户模式（MeowID + `/api/who` 昵称）。

未实现：ReplayKit 屏幕推流、桌宠渲染、`.cam` 侧 token 鉴权（App 已预留字段位，见交接文档）、
空闲后台的 APNs 唤醒。

## 排错

| 现象 | 处理 |
| --- | --- |
| Runner 一直红 | `curl http://127.0.0.1:8100/cw/v1/ping`；PC 侧要 `ios forward 8100 8100` |
| 截图 500 | runner 截图失败（多因锁屏/后台挂起），解锁后重试 |
| 装机后闪退 | 证书未信任 / 描述文件过期 / 未开开发者模式；免费证书 7 天 |
| `cw_token` 不一致 | 两边都设或都不设 |
