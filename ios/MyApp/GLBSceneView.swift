import UIKit
import SceneKit
import QuartzCore
import Metal
import React

/// SceneKit 展示 Collada DAE；离屏截图用 SCNRenderer。
@objc(GLBSceneContainerView)
public class GLBSceneContainerView: UIView {
  private let scnView = SCNView()
  private let statusLabel = UILabel()
  private var didLoadModel = false
  private var cameraNode: SCNNode?

  @objc public override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = .white
    scnView.translatesAutoresizingMaskIntoConstraints = false
    scnView.backgroundColor = .white
    scnView.allowsCameraControl = true
    scnView.autoenablesDefaultLighting = true
    scnView.antialiasingMode = .multisampling4X
    addSubview(scnView)
    NSLayoutConstraint.activate([
      scnView.topAnchor.constraint(equalTo: topAnchor),
      scnView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scnView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scnView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.textColor = .darkGray
    statusLabel.numberOfLines = 0
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textAlignment = .center
    addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
    ])
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    if !didLoadModel, bounds.width > 0, bounds.height > 0 {
      didLoadModel = true
      loadDAE()
    }
  }

  private func loadDAE() {
    guard let url = Bundle.main.url(forResource: "glove", withExtension: "dae") else {
      statusLabel.text = "未找到 glove.dae\n请加入 Xcode Copy Bundle Resources"
      return
    }
    do {
      let scene = try SCNScene(url: url, options: nil)

      // 把 Blender 导出的 Z-up 模型旋转到 iOS 的 Y-up，并做一个统一缩放
      let root = scene.rootNode
      root.eulerAngles.x = -.pi / 2
      // 再放大一轮，让模型明显占据视图中心区域
      root.scale = SCNVector3(5, 5, 5)

      applyTextureFixups(to: scene)
      applyCameraAndLights(to: scene)
      scnView.scene = scene
      statusLabel.isHidden = true
    } catch {
      statusLabel.text = "DAE 加载失败：\(error.localizedDescription)"
    }
  }

  /// DAE 里可能缺少 UV 或材质未绑定；这里做一个运行时兜底：
  /// - 给所有材质设置 glove-image.jpg 作为 diffuse
  /// - 如果几何体没有 TEXCOORD，则用顶点坐标生成一套平面 UV
  private func applyTextureFixups(to scene: SCNScene) {
    let texture = UIImage(named: "glove-image.jpg")
    scene.rootNode.enumerateChildNodes { node, _ in
      guard let geo = node.geometry else { return }

      let fixedGeo = Self.geometryByEnsuringTexcoords(geo)
      if fixedGeo !== geo {
        node.geometry = fixedGeo
      }

      for material in (node.geometry?.materials ?? []) {
        if let texture {
          material.diffuse.contents = texture
        }
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
      }
    }
  }

  private static func geometryByEnsuringTexcoords(_ geometry: SCNGeometry) -> SCNGeometry {
    if !geometry.sources(for: .texcoord).isEmpty {
      return geometry
    }
    guard let positionSource = geometry.sources(for: .vertex).first else {
      return geometry
    }
    guard let texSource = Self.makePlanarTexcoordSource(from: positionSource) else {
      return geometry
    }

    let newSources = geometry.sources + [texSource]
    let newGeo = SCNGeometry(sources: newSources, elements: geometry.elements)
    newGeo.materials = geometry.materials
    return newGeo
  }

  private static func makePlanarTexcoordSource(from positionSource: SCNGeometrySource) -> SCNGeometrySource? {
    let count = positionSource.vectorCount
    guard count > 0 else { return nil }

    let data = positionSource.data as NSData
    let stride = positionSource.dataStride
    let offset = positionSource.dataOffset
    let bytesPerComponent = positionSource.bytesPerComponent
    let comps = positionSource.componentsPerVector
    guard bytesPerComponent == 4, comps >= 3 else {
      return nil
    }

    var xs = [Float](repeating: 0, count: count)
    var zs = [Float](repeating: 0, count: count)
    var minX = Float.greatestFiniteMagnitude
    var maxX = -Float.greatestFiniteMagnitude
    var minZ = Float.greatestFiniteMagnitude
    var maxZ = -Float.greatestFiniteMagnitude

    for i in 0..<count {
      let base = offset + i * stride
      let xPtr = data.bytes.advanced(by: base).assumingMemoryBound(to: Float.self)
      let x = xPtr[0]
      let z = xPtr[2]
      xs[i] = x
      zs[i] = z
      minX = min(minX, x); maxX = max(maxX, x)
      minZ = min(minZ, z); maxZ = max(maxZ, z)
    }

    let dx = max(0.00001, maxX - minX)
    let dz = max(0.00001, maxZ - minZ)

    var uv = [Float](repeating: 0, count: count * 2)
    for i in 0..<count {
      let u = (xs[i] - minX) / dx
      let v = (zs[i] - minZ) / dz
      uv[i * 2 + 0] = u
      uv[i * 2 + 1] = v
    }

    let uvData = Data(bytes: uv, count: uv.count * MemoryLayout<Float>.size)
    return SCNGeometrySource(
      data: uvData,
      semantic: .texcoord,
      vectorCount: count,
      usesFloatComponents: true,
      componentsPerVector: 2,
      bytesPerComponent: 4,
      dataOffset: 0,
      dataStride: 8
    )
  }

  /// 使用固定相机 + 简单灯光，保证总能看到 (0,0,0) 附近的模型
  private func applyCameraAndLights(to scene: SCNScene) {
    let camNode = SCNNode()
    camNode.camera = SCNCamera()
    camNode.camera?.zNear = 0.01
    camNode.camera?.zFar = 200
    // 视角更大 + 相机更远：避免“贴脸”
    camNode.camera?.fieldOfView = 42
    camNode.position = SCNVector3(0, 0.35, 2.8)
    camNode.look(at: SCNVector3(0, 0, 0))
    scene.rootNode.addChildNode(camNode)
    scnView.pointOfView = camNode
    cameraNode = camNode

    // 方向光
    let dirLightNode = SCNNode()
    let dir = SCNLight()
    dir.type = .directional
    dir.intensity = 2200
    dir.castsShadow = false
    dirLightNode.light = dir
    dirLightNode.position = SCNVector3(2, 4, 4)
    dirLightNode.look(at: SCNVector3(0, 0, 0))
    scene.rootNode.addChildNode(dirLightNode)

    // 环境光
    let ambientNode = SCNNode()
    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 400
    ambient.color = UIColor(white: 1.0, alpha: 1.0)
    ambientNode.light = ambient
    scene.rootNode.addChildNode(ambientNode)
  }

  private func snapshotOnce() -> String? {
    // 必须在主线程执行，否则 SceneKit / UIKit 可能崩溃
    if !Thread.isMainThread {
      var result: String?
      DispatchQueue.main.sync {
        result = self.captureSnapshotToBase64()
      }
      return result
    }

    guard scnView.scene != nil else {
      return nil
    }
    // 直接截取当前 SCNView 画面，效果与屏幕上看到的一致
    let image = scnView.snapshot()
    guard let data = image.jpegData(compressionQuality: 0.88) else { return nil }
    return data.base64EncodedString()
  }

  @objc public func captureSnapshotToBase64() -> String? {
    return snapshotOnce()
  }

  /// 多机位截图：在“正前方下侧弧线”上均匀布置 N 个视点，并全部对准中心点。
  /// - 约定：主相机在 (0, ~0.25, +Z) 朝向原点，因此这里用 +Z 半球的一段弧线（左右展开）。
  private static func multiCameraPositions(count: Int) -> [SCNVector3] {
    let n = max(2, count)
    let center = SCNVector3(0, 0, 0)
    // 视角“太近”主要由相机距离 + FOV 决定：这里先把相机整体拉远一些
    let radius: Float = 8.5
    let height: Float = 0.34
    let arcDegrees: Float = 70.0 // 总弧长角度：左右各 35°，越大左右视差越强

    let half = (arcDegrees * .pi / 180.0) / 2.0
    let start = -half
    let end = half
    let step = (end - start) / Float(n - 1)

    // angle=0 对应正前方（+Z）；angle<0 在左侧（x<0）；angle>0 在右侧（x>0）
    return (0..<n).map { i in
      let a = start + Float(i) * step
      let x = center.x + radius * sinf(a)
      let z = center.z + radius * cosf(a)
      return SCNVector3(x, height, z)
    }
  }

  private static func add(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z)
  }

  private static func sub(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z)
  }

  private static func length(_ v: SCNVector3) -> Float {
    sqrtf(v.x * v.x + v.y * v.y + v.z * v.z)
  }

  private static func normalize(_ v: SCNVector3) -> SCNVector3 {
    let len = max(0.00001, Self.length(v))
    return SCNVector3(v.x / len, v.y / len, v.z / len)
  }

  private static func rotateAroundY(_ v: SCNVector3, radians: Float) -> SCNVector3 {
    let c = cosf(radians)
    let s = sinf(radians)
    // 绕世界 Y 轴旋转
    return SCNVector3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
  }

  /// 基于当前视角生成多机位：以当前相机“到中心点的向量”为半径，左右小角度环绕。
  private static func multiCameraPositions(basedOn currentCamera: SCNNode?, count: Int, center: SCNVector3) -> [SCNVector3] {
    let n = max(2, count)
    guard let cam = currentCamera else {
      return Self.multiCameraPositions(count: n)
    }

    let camPos = cam.presentation.worldPosition
    var offset = Self.sub(camPos, center)
    let r = Self.length(offset)
    if r < 0.0001 {
      return Self.multiCameraPositions(count: n)
    }

    // 仅在水平面环绕，避免高低角度飘动；高度取当前相机高度
    offset = SCNVector3(offset.x, 0, offset.z)
    // 截图相机整体拉远：让模型在截图里更“小”、更不贴脸
    let distanceScale: Float = 1.35
    let flatR = max(0.0001, Self.length(offset)) * distanceScale
    let baseDir = Self.normalize(offset) // 从 center 指向 camera 的方向（水平）

    // 环绕角度范围：默认左右各 18°（总 36°），和用户当前视角保持“局部多视角”
    let arcDegrees: Float = 36.0
    let half = (arcDegrees * .pi / 180.0) / 2.0
    let start = -half
    let end = half
    let step = (end - start) / Float(n - 1)

    return (0..<n).map { i in
      let a = start + Float(i) * step
      let dir = Self.rotateAroundY(baseDir, radians: a)
      let pos = Self.add(center, SCNVector3(dir.x * flatR, camPos.y - center.y, dir.z * flatR))
      return pos
    }
  }

  /// 多机位截图：用离屏 SCNRenderer 按预设机位各渲染一帧
  @objc public func captureSnapshotsAround(_ countNumber: NSNumber) -> [String]? {
    if !Thread.isMainThread {
      var result: [String]?
      DispatchQueue.main.sync {
        result = self.captureSnapshotsAround(countNumber)
      }
      return result
    }

    guard let scene = scnView.scene else {
      return nil
    }
    // 构图中心点：稍微上移，让主体更落在“安全框/活动框”的中心区域（四周更留白）
    // 如需更靠上/靠下，可微调这个 Y 值（单位：SceneKit 世界坐标）
    let sceneCenter = SCNVector3(0, 0.12, 0)
    // 虚拟相机固定输出分辨率：1210x1920（其余区域填黑，不拉伸）
    let targetSize = CGSize(width: 1210, height: 1920)
    let viewSize = bounds.size.width > 1 && bounds.size.height > 1 ? bounds.size : CGSize(width: 800, height: 800)
    let viewAspect = max(0.0001, viewSize.width / max(0.0001, viewSize.height))
    let renderSize = Self.renderSizeFitting(aspect: viewAspect, into: targetSize)

    let device = scnView.device ?? MTLCreateSystemDefaultDevice()
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.autoenablesDefaultLighting = true

    let offscreenCam = SCNNode()
    offscreenCam.camera = SCNCamera()
    // 截图相机参数：尽量跟随当前交互相机，保证“所见即所得”
    let currentCam = scnView.pointOfView?.presentation.camera ?? cameraNode?.camera
    offscreenCam.camera?.zNear = currentCam?.zNear ?? 0.01
    offscreenCam.camera?.zFar = currentCam?.zFar ?? 200
    offscreenCam.camera?.fieldOfView = currentCam?.fieldOfView ?? 60

    let n = max(2, countNumber.intValue)
    let positions = Self.multiCameraPositions(basedOn: scnView.pointOfView, count: n, center: sceneCenter)

    var results: [String] = []
    for i in 0..<positions.count {
      offscreenCam.position = positions[i]
      offscreenCam.look(at: sceneCenter)
      renderer.pointOfView = offscreenCam
      var image = renderer.snapshot(atTime: 0, with: renderSize, antialiasingMode: scnView.antialiasingMode)
      // 离屏 snapshot 可能上下颠倒；先统一翻转
      image = Self.flipVertically(image)
      // 再居中贴到固定分辨率黑底画布（不拉伸、不缩放内容）
      image = Self.letterboxNoScale(image, canvasSize: targetSize)
      // 用 PNG 无损，避免 JPEG 压缩导致的“糊”和块状伪影
      if let data = image.pngData() {
        results.append(data.base64EncodedString())
      }
    }
    return results
  }

  private static func renderSizeFitting(aspect: CGFloat, into canvas: CGSize) -> CGSize {
    // 输出尺寸必须 <= canvas，保持宽高比；后续再贴到 canvas（黑底）
    let canvasAspect = canvas.width / max(0.0001, canvas.height)
    if aspect >= canvasAspect {
      let w = canvas.width
      let h = floor(w / max(0.0001, aspect))
      return CGSize(width: w, height: max(1, h))
    } else {
      let h = canvas.height
      let w = floor(h * aspect)
      return CGSize(width: max(1, w), height: h)
    }
  }

  private static func flipVertically(_ image: UIImage) -> UIImage {
    guard let cgImage = image.cgImage else { return image }
    let width = cgImage.width
    let height = cgImage.height

    UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 1.0)
    defer { UIGraphicsEndImageContext() }
    guard let ctx = UIGraphicsGetCurrentContext() else { return image }

    ctx.setFillColor(UIColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return UIGraphicsGetImageFromCurrentImageContext() ?? image
  }

  private static func letterboxNoScale(_ image: UIImage, canvasSize: CGSize) -> UIImage {
    guard let cgImage = image.cgImage else { return image }
    let iw = CGFloat(cgImage.width)
    let ih = CGFloat(cgImage.height)
    let cw = canvasSize.width
    let ch = canvasSize.height

    UIGraphicsBeginImageContextWithOptions(canvasSize, true, 1.0)
    defer { UIGraphicsEndImageContext() }
    guard let ctx = UIGraphicsGetCurrentContext() else { return image }

    ctx.setFillColor(UIColor.black.cgColor)
    ctx.fill(CGRect(origin: .zero, size: canvasSize))

    // 不缩放：按像素 1:1 居中绘制；若比画布大则居中裁切
    let dx = floor((cw - iw) / 2.0)
    let dy = floor((ch - ih) / 2.0)
    let drawRect = CGRect(x: dx, y: dy, width: iw, height: ih)
    UIImage(cgImage: cgImage, scale: 1.0, orientation: .up).draw(in: drawRect)

    return UIGraphicsGetImageFromCurrentImageContext() ?? image
  }
}

@objc(GLBSceneViewManager)
class GLBSceneViewManager: RCTViewManager {
  override func view() -> UIView! {
    GLBSceneContainerView()
  }

  override static func requiresMainQueueSetup() -> Bool {
    true
  }
}
