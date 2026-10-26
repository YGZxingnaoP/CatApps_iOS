# Patches

`0001-catpaws-cw-api.patch` —— `CustomCode/` 里那批魔改的 git patch 形态（43 个文件：28 新增 + 15 修改，含二进制图标）。

| 项 | 值 |
| --- | --- |
| 上游 | `appium/WebDriverAgent` @ `e7e2665a00633dc174d7fc579f7e606bc9ba782a`（v16.15.0） |
| 打完后 `git write-tree` | `745b0145da75af7e9382041581d4d76061980750` |
| 与 `CustomCode/` 的关系 | 43 个文件逐字节相同（已在干净检出上验证） |

用法：

```bash
# 干净检出（注意 LF）
git -C WebDriverAgent apply --binary ../Patches/0001-catpaws-cw-api.patch
# 上游更新过、要三方合并
git -C WebDriverAgent apply --3way ../Patches/0001-catpaws-cw-api.patch
# 只看
git apply --stat Patches/0001-catpaws-cw-api.patch
```

注意：

- 检出必须是 LF（`git config core.autocrlf false` 后再 checkout），否则上下文对不上；
- Windows 上可能打印 `warning: Scripts/embed-runner-icon.sh has type 100644, expected 100755`，
  只是可执行位差异，`apply` 仍然成功，之后 `chmod +x Scripts/*.sh`；
- 日常构建推荐 `apply.sh` + `CustomCode/`（对二进制更稳），patch 主要用于 review 和上游升级重放。
