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
    let sceneCenter = SCNVector3(0, 0, 0)
    var size = bounds.size
    if size.width < 1 || size.height < 1 {
      size = CGSize(width: 800, height: 800)
    }
    // 用更高分辨率离屏渲染，避免交织后细节不足。
    // `bounds.size` 是 points，这里按屏幕 scale 转为像素尺寸。
    let scale = max(1.0, UIScreen.main.scale)
    size = CGSize(width: size.width * scale, height: size.height * scale)

    let device = scnView.device ?? MTLCreateSystemDefaultDevice()
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.autoenablesDefaultLighting = true

    let offscreenCam = SCNNode()
    offscreenCam.camera = SCNCamera()
    offscreenCam.camera?.zNear = 0.01
    offscreenCam.camera?.zFar = 200
    // 截图视角：适当增大 FOV，让画面“更远”（物体更小）
    offscreenCam.camera?.fieldOfView = 75

    let n = max(2, countNumber.intValue)
    let positions = Self.multiCameraPositions(count: n)

    var results: [String] = []
    for i in 0..<positions.count {
      offscreenCam.position = positions[i]
      offscreenCam.look(at: sceneCenter)
      renderer.pointOfView = offscreenCam
      let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: scnView.antialiasingMode)
      // 用 PNG 无损，避免 JPEG 压缩导致的“糊”和块状伪影
      if let data = image.pngData() {
        results.append(data.base64EncodedString())
      }
    }
    return results
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
