# CW API（`/cw/v1/*`）

在 Appium WebDriverAgent v16.15.0 上外加的一套设备端接口，`CustomCode/` 就是它的实现。
默认端口沿用 WDA 的 8100，原 WDA 路由一并保留（Appium 不受影响）。

基地址：`http://<device>:8100/cw/v1`

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/ping` | 存活探测，不建会话 |
| GET | `/device` | 屏幕元数据、系统信息、capabilities |
| POST | `/session` | 建立/重建 XCTest 会话 |
| DELETE | `/session` | 释放会话 |
| POST | `/actions` | 顺序执行 1..64 个原子动作 |
| POST | `/stop` | 打断当前动作序列 |
| GET | `/screenshot` | 原始 PNG，支持 `max_edge`、`region` |
| POST | `/ocr` | Vision 行级 OCR，返回像素框 |
| POST | `/paste` | 写剪贴板并粘贴 |
| GET | `/source` | 预留，返回 `E_UNSUPPORTED` |

信封：

```json
{ "ok": true,  "data": { ... } }
{ "ok": false, "error": { "code": "E_DEVICE_LOCKED", "message": "..." } }
```

## 坐标

- 对外一律是**截图像素**，左上原点；
- 像素 → 逻辑点只在 `CWGeometry` 里做一次 `round(pixel / scale)`；
- 越界在整批执行前校验：任一步越界，整批不执行。

## 配置

优先级：环境变量 → runner `Info.plist` → 沙盒 `Documents/cw_config.plist`
（示例：`CustomCode/Config/cw_config.example.plist`）。

| 键 | 环境变量 | 说明 |
| --- | --- | --- |
| `CWToken` | `CW_TOKEN` | Bearer token；**空 = 不校验** |
| `CWOnly` | `CW_ONLY=1` | 只注册 `/cw/v1/*`，不暴露 `/session`、`/wda/*` 等原 WDA 路由 |
| `CWOCRDisabled` | `CW_OCR_DISABLED=1` | capabilities 不含 `ocr`，`/ocr` 返回 `E_UNSUPPORTED` |

## 线程与会话

- CW 路由用独立队列；XCTest 手势/截图/应用操作同步切主线程，避免长动作堵住 WDA 路由队列；
- `/stop` 走独立路由，能在 `wait` 里 50ms 级打断；
- runner 启动后异步自动建会话；`/ping` 只读状态；会话丢了动作前自动重建一次。

## 与常见客户端预期的差异

1. `/source` 未实现（`E_UNSUPPORTED`），capabilities 不含 `source`；
2. 屏幕推流（ReplayKit / BroadcastExtension / H.264）不在 runner 侧；
3. 旧 WDA 路由默认保留，收敛用 `CW_ONLY=1`；
4. `type_text` 仅 ASCII，中文走 `paste_text`；
5. `paste_text` 依赖当前焦点：找 `fb_activeElement` → 长按 → 点「粘贴/Paste」并处理「允许粘贴」弹窗；
   找不到焦点返回 `E_INTERNAL`，不会盲点屏幕中心；
6. 横屏不支持（`/device` 检测到非竖屏直接 `E_UNSUPPORTED`）；
7. 单动作硬超时不实现（XCTest 调用无法安全取消），由客户端按 `E_TIMEOUT` 重试兜底。

## 版本变化

当前 `Info.plist` 版本 **1.0.7**，有对外含义的改动：

| 版本 | 变化 |
| --- | --- |
| 1.0.2 | `/device` 的 `pixel/point/scale` 改为同源推导（`pixel`=截图尺寸、`point`=`pixel/nativeScale`、`scale`=`nativeScale`）；`safe_area` 取 `keyWindow.safeAreaInsets`，取不到给 `null`；异常时带 `warnings[]`；越界校验含边界 |
| 1.0.3 | `/actions` 新增可选 `wait_idle`；执行期间 idle / animationCoolOff 置 0、`fb_shouldWaitForQuiescence=NO`；`tap` 多点间隔 `CW_TAP_GAP_MS`（默认 90，30–1000） |
| 1.0.4 | 新增动作 `drag`；`GET /screenshot` 新增 `region=x,y,w,h`（响应头多 `X-CW-Crop`）；capabilities 增加 `drag` |

全部是新增可选字段/动作，旧客户端不改也不会坏。
