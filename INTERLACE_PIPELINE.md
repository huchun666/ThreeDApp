# 3D 展示 → 多机位截图 → 生成交织图（iOS / Python）

本文档描述当前项目里从 **SceneKit 3D 展示** 到 **多机位离屏截图**，再到 **生成交织图（Interlaced PNG）** 的完整链路、关键代码位置与常见问题排查。

本项目当前支持两条“交织”路径：

- **iOS 原生交织（按列交织）**：输入为本地 PNG 路径，iOS 端合成输出 PNG（离线、无需网络）。
- **Python 公式交织（推荐用于调参数）**：输入为 base64 PNG 列表，通过本机 Node 服务转发给 Python 脚本，返回 base64 PNG（方便快速迭代公式参数）。

---

## 总览：数据流

1. **3D 展示（iOS 原生）**
   - RN 通过 `requireNativeComponent('GLBSceneView')` 挂载原生 `GLBSceneContainerView`（SceneKit `SCNView`）。
2. **多机位离屏截图**
   - RN 调用 `NativeModules.GLBSnapshot.captureMulti(tag, count)`（返回 base64 PNG 列表）。
   - 原生使用 `SCNRenderer` 离屏逐帧 `snapshot`，得到 **PNG** base64（用于 RN 预览，也可直接作为 Python 交织输入）。
 3. **生成交织图（两条路径二选一）**
   - **路径 A：Python 公式交织**
     - RN `fetch(POST /interlace)` 把 base64 PNG 列表发到本机服务
     - Node 服务写入临时目录 → 调 Python 脚本 → 读 `out.png` → 返回 base64 PNG
   - **路径 B：iOS 原生按列交织**
     - RN 调用 `GLBSnapshot.captureMultiToFiles(tag, count)` 获取本地 PNG 路径数组
     - 再调用 `InterlaceImage.generateInterlacedImage(imagePaths)` 输出交织 PNG 路径
 4. **预览**
   - base64 预览：`data:image/png;base64,...`
   - 本地文件预览：`file://${path}`

---

## 运行入口（React Native）

入口文件：`MyApp/App.tsx`

关键按钮与流程：

- **多机位截图 × 9**
  - 调用：`GLBSnapshot.captureMulti(tag, 9)`
  - 返回：`base64` 列表（当前为 **PNG**）
  - 预览：`data:image/png;base64,...`

- **多机位截图 → 生成交织图**
  - 当前 `App.tsx` 走 **Python 公式交织**：
    - 先调用：`GLBSnapshot.captureMulti(tag, 9)` 拿到 base64 PNG 列表
    - 再调用：`POST ${pyInterlaceBaseUrl}/interlace`，返回 `image_base64`
    - 预览：`data:image/png;base64,${image_base64}`
  - 如需切到 **iOS 原生交织**：
    - 调用：`GLBSnapshot.captureMultiToFiles(tag, 9)` 拿到本地路径数组
    - 再调用：`InterlaceImage.generateInterlacedImage(paths)` 生成交织图输出路径

原生交织模块 JS 包装：`MyApp/src/native/interlaceImage.ts`

---

## iOS 原生：3D 展示（SceneKit）

文件：`MyApp/ios/MyApp/GLBSceneView.swift`

- `GLBSceneContainerView`
  - 内部持有 `SCNView`（屏幕展示）
  - `loadDAE()` 加载 `glove.dae` 并设置相机、灯光等

### 资源文件要求

- 模型：`ios/MyApp/glove.dae` 必须加入 Xcode **Copy Bundle Resources**
- 若 DAE 引用贴图（例如某个 `.jpg/.png`），贴图也需要放到 `ios/MyApp/` 并加入 **Copy Bundle Resources**

---

## iOS 原生：多机位截图（离屏 SCNRenderer）

核心文件：`MyApp/ios/MyApp/GLBSceneView.swift`

### 机位选择

本项目目前实现为 **“基于当前视角”** 的机位生成：

- 用户在 `SCNView` 里用手势旋转/缩放（`allowsCameraControl = true`），`scnView.pointOfView` 会变化
- `captureSnapshotsAround(count)` 会读取当前 `pointOfView`，在保持距离基本不变的前提下，绕世界 **Y 轴** 左右小角度取样出 `count` 个机位（局部多视角）

### 截图实现

`captureSnapshotsAround(_ countNumber: NSNumber) -> [String]?`

- 在主线程触发（SceneKit / UIKit 线程要求）
- 创建 `SCNRenderer` 并设置 `pointOfView`
- 对每个机位调用：
  - `renderer.snapshot(atTime: 0, with: size, antialiasingMode: ...)`
  - 再 `pngData()` → base64

### 截图“上下颠倒”（重要）

部分设备/渲染路径下，`SCNRenderer.snapshot` 的离屏结果可能会出现 **上下翻转**。为了保证与屏幕 `scnView.snapshot()` 看到的一致，本项目在离屏截图后做了 `flipVertically` 统一翻转。

### 分辨率与清晰度（重要）

为了避免交织后细节不足，这里做了两点：

- **离屏渲染尺寸按屏幕 scale 提升**
  - `bounds.size` 是 *points*，会乘以 `UIScreen.main.scale` 得到更高的像素尺寸
- **用 PNG 无损**
  - 避免 JPEG 压缩导致的涂抹感/块状伪影

---

## iOS 原生：截图写盘（返回本地路径）

文件：`MyApp/ios/MyApp/GLBSnapshotModule.m`

导出 RN 模块：`GLBSnapshot`

- `captureMultiToFiles(reactTag, count)`
  - 先从 `GLBSceneContainerView` 拿 `captureSnapshotsAround(count)` 的 base64 列表
  - 再后台线程逐个 base64 解码并写入 `NSTemporaryDirectory()`
  - 文件名：`glb_snap_<timestamp>_<index>.png`
  - 返回：`[fullPath1, fullPath2, ...]`

---

## iOS 原生：生成交织图（InterlaceImage）

文件：`MyApp/ios/MyApp/InterlaceImage.swift`

RN 调用入口：

- `InterlaceImage.generateInterlacedImage(imagePaths: string[]) -> Promise<string>`

实现要点：

- 读取第一张图作为目标尺寸（`targetWidth/targetHeight`）
- 将所有输入图统一绘制进 RGBA 缓冲（避免朝向/色彩空间差异）
- **按列交织**（当前固定 `axis: .columns`，`stride: 1`）：
  - 第 \(x\) 列来自第 `((x / stride) % imageCount)` 张输入图
- 输出：写入临时目录 `interlaced_<timestamp>.png`，返回 `outputPath`

---

## 本机 Python 交织：Node 服务 → Python 脚本（公式模式）

### 为什么要这条链路？

当你需要频繁调整“公式交织”的参数（例如 `val_x / val_tan / offset`）时，走 Python 更方便：不用重新编译 iOS，直接改参数、点按钮就能看到输出。

### 启动方式

在项目根目录运行：

- `npm run py:interlace`

对应脚本：`dev_py_interlace_server.mjs`

### RN 调用方式

`App.tsx` 里通过：

- `fetch(POST ${pyInterlaceBaseUrl}/interlace, { images: base64PngList, val_x, val_tan, offset })`

注意：

- **模拟器**可以访问 `http://localhost:8787`（如果你把 baseUrl 配成 localhost）
- **真机**不能用 localhost，必须用你 Mac 的 **局域网 IP**（示例：`http://10.28.111.123:8787`）

### Node 服务做了什么

`dev_py_interlace_server.mjs` 的核心流程：

1. 接收 `images: string[]`（每项可以是纯 base64 或 data-uri）
2. 写入临时目录：`MyApp/_py_interlace_tmp/<ts>/in/1.png ...`
3. `spawn` 调用：`.venv/bin/python MyApp/interleaveV2.py --input_dir ... --output out.png --mode formula --val_x ... --val_tan ... --offset ...`
4. 读取 `out.png` → base64 返回：`{ ok: true, image_base64 }`
5. best-effort 清理临时目录

---

## 输出产物在哪里？

在 iOS 上都写在系统临时目录（`NSTemporaryDirectory()`）：

- 多机位输入：`glb_snap_<ts>_<i>.png`
- 交织输出：`interlaced_<ts>.png`

RN 预览时记得加 `file://`：

- 多机位预览：`file://${path}`
- 交织预览：`file://${interlacedOutputPath}`

---

## 常见问题（FAQ / 排查）

### 1) “交织图有点糊”

优先排查：

- **离屏渲染尺寸是否足够大**：`GLBSceneView.swift` 里 `size` 由 `bounds.size * UIScreen.main.scale` 决定；如果你的 `GLBSceneView` 在 RN 里很小，离屏像素尺寸也会跟着小。
- **是否有 JPEG 压缩**：本项目已改成 PNG；如果你回退到 JPEG，会更容易“糊/脏”。
- **预览缩放插值**：RN `Image` 在缩放显示时会插值；建议对比把图片保存到相册或导出到电脑看原图像素级细节。

### 2) “DAE 能显示但没有贴图/灰模”

- 检查 DAE 引用贴图的文件名是否与 `ios/MyApp/` 内图片一致
- 确认贴图也加入了 Xcode **Copy Bundle Resources**

### 3) “captureMultiToFiles 提示未开启/找不到原生视图”

- `App.tsx` 里 `findNodeHandle(glbRef.current)` 必须拿到有效 tag
- `GLBSceneView` 组件需要 `collapsable={false}`（当前已设置）
- iOS 侧 `GLBSnapshotModule.m` 会校验视图类型是否为 `GLBSceneContainerView`

### 4) “生成交织图失败：无法加载图片”

- `generateInterlacedImage` 需要传入 **真实文件路径**（可以是 `/var/.../xxx.png` 或 `file://...`）
- 临时目录内容可能被系统清理：建议在使用链路中尽快生成交织图

### 5) “真机请求 Python 服务失败 / 超时 / 404”

- 确认 Mac 和 iPhone 在同一个局域网
- `pyInterlaceBaseUrl` 必须是 Mac 的局域网 IP（不能是 localhost）
- 确认 Node 服务正在运行：`GET /health` 返回 `{ ok: true }`
- 如端口冲突：`PY_INTERLACE_PORT=8788 npm run py:interlace`，并同步修改 `App.tsx`

---

## 代码导航（快速索引）

- **RN UI / 入口**：`MyApp/App.tsx`
- **RN 调原生交织模块**：`MyApp/src/native/interlaceImage.ts`
- **iOS 原生 3D + 截图**：`MyApp/ios/MyApp/GLBSceneView.swift`
- **iOS 原生 RN Bridge（截图/写盘）**：`MyApp/ios/MyApp/GLBSnapshotModule.m`
- **iOS 原生交织实现**：`MyApp/ios/MyApp/InterlaceImage.swift`
- **Node → Python 交织服务**：`MyApp/dev_py_interlace_server.mjs` → `MyApp/interleaveV2.py`

