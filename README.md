# CatPaws / WDA 工作区

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
装机与踩坑见 [INSTALL.md](INSTALL.md)，接口见 [API.md](API.md)。

`CustomCode/` 里多出来的两个东西不参与覆盖：`Config/cw_config.example.plist`（示例配置）
和 `README.md`（本目录说明）。

## 2. CatCam App（`CatCam/`）

```bash
bash Scripts/build-catcam-ipa.sh          # → dist/catcam-<版本号>.ipa
DERIVED=/tmp/dd bash Scripts/build-catcam-ipa.sh   # 自定义派生数据目录
```

也可以在 Xcode 里直接打开 `CatCam/CatCam.xcodeproj` 跑模拟器/真机（走正常签名）。

- target / 产物：`CatCam` / `CatCam.app`，bundle id `com.meowlisis.catcam`
- 部署目标 iOS 15.0，Swift 5 + SwiftUI，无第三方依赖、无 entitlement
- 构建脚本逻辑：`xcodebuild -target CatCam -sdk iphoneos` → 组 `Payload` →
  `Scripts/strip-codesign.sh` 剥签名 → zip → 从最终 IPA 解包再验一遍（有残留签名就 `exit 1`）

## 3. 推到 GitHub 之前

```bat
git config --global user.name
git config --global user.email
```

现在是占位值 `Your Name <you@example.com>`，不改会写进公开提交历史。

```bat
cd /d "D:\Virtual Machines\connector\WDA"
git init -b main
git add -A
git commit -m "CatCam app + CatPaws /cw/v1 device API on top of WebDriverAgent v16.15.0"
git remote add origin git@github.com:<你的用户名>/<仓库名>.git
git push -u origin main
```

核对清单（应为空 = 上游和内部资料没进库）：

```bat
git ls-files | find /i "WebDriverAgent\"   :: 只有 CustomCode 下的，不是上游树
git ls-files | find /i "\Docs\"
git ls-files | find /i ".ipa"
```

## 4. 许可

- `CustomCode/` 是对 WebDriverAgent 的改造，沿用上游 **BSD** 许可，版权声明见 `CustomCode/LICENSE`、
  归属说明见 `CustomCode/NOTICE`；
- `CatCam/` 为 MIT，见 `CatCam/LICENSE`。
