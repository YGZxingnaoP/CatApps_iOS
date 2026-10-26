# CustomCode/ —— WDA 的魔改部分

这里的文件**按 WebDriverAgent 内的相对路径**存放，`apply.sh` 会把它们覆盖到上游工作树上：

```
CustomCode/WebDriverAgentLib/CW/CWServer.m   →  WebDriverAgent/WebDriverAgentLib/CW/CWServer.m
CustomCode/WebDriverAgentRunner/Info.plist   →  WebDriverAgent/WebDriverAgentRunner/Info.plist
```

| 内容 | 说明 |
| --- | --- |
| `WebDriverAgentLib/CW/`（28 个） | 新增：`/cw/v1/*` 路由、鉴权、会话、动作执行、截图、OCR、粘贴 |
| `WebDriverAgentLib/Routing/`（10 个） | 改：请求头透传、`dedicated` 路由模式、`CW_ONLY` 分支 |
| `WebDriverAgentRunner/`（3 个） | 改：`Info.plist`（`CWToken` / `UILaunchScreen` / 版本）、启动时 bootstrap 会话、图标 |
| `WebDriverAgent.xcodeproj/project.pbxproj` | 改：加 `CW` group、源文件、链接 `Vision.framework` |
| `Scripts/embed-runner-icon.sh` | 改：图标抬到外壳 app + 桌面名 `CatPaws <版本号>` |
| `Config/cw_config.example.plist` | **不覆盖**：沙盒配置示例，手动放到 runner 的 `Documents/cw_config.plist` |
| `README.md` | **不覆盖**：本说明 |

规则：

- 只覆盖、不删除，上游文件一个都不会被删；
- 二进制文件（图标）也放这里，`cp -R` 直接搬；
- 内容必须等于 `Patches/0001-catpaws-cw-api.patch` 打完补丁的结果，两边一起改。

上游 README.md 里加的那 5 行 CatPaws 说明**没有**收进来（本仓库自己的 README 已覆盖这个信息）。

## 再生成一遍

```bash
# 0) 干净上游（先关 autocrlf）
git init /tmp/wda && git -C /tmp/wda config core.autocrlf false
git -C /tmp/wda remote add origin https://github.com/appium/WebDriverAgent.git
git -C /tmp/wda fetch --depth 1 origin e7e2665a00633dc174d7fc579f7e606bc9ba782a
git -C /tmp/wda checkout -B catpaws FETCH_HEAD

# 1) 覆盖 + 修可执行位
for d in WebDriverAgentLib WebDriverAgent.xcodeproj WebDriverAgentRunner Scripts; do
  cp -R CustomCode/$d/. /tmp/wda/$d/
done
chmod +x /tmp/wda/Scripts/*.sh
git -C /tmp/wda update-index --add --chmod=+x Scripts/build.sh Scripts/ci/build-real.sh \
  Scripts/ci/build-sim.sh Scripts/embed-runner-icon.sh

# 2) 导出 patch
git -C /tmp/wda add -A
git -C /tmp/wda write-tree          # 记下这个 hash，便于回归比对
git -C /tmp/wda diff --cached --binary --no-renames --output=Patches/0001-catpaws-cw-api.patch

# 3) 反向验证
git -C /tmp/wda reset --hard FETCH_HEAD && git -C /tmp/wda clean -fdq
git -C /tmp/wda apply --binary Patches/0001-catpaws-cw-api.patch
git -C /tmp/wda add -A && git -C /tmp/wda write-tree    # 应与第 2 步相同
```
