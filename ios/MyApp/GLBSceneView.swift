import UIKit
import SceneKit
import QuartzCore
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
    guard let url = Bundle.main.url(forResource: "FeiLinV2", withExtension: "dae") else {
      statusLabel.text = "未找到 FeiLinV2.dae\n请加入 Xcode Copy Bundle Resources"
      return
    }
    do {
      let scene = try SCNScene(url: url, options: nil)

      // 把 Blender 导出的 Z-up 模型旋转到 iOS 的 Y-up，并做一个统一缩放
      let root = scene.rootNode
      root.eulerAngles.x = -.pi / 2
      // 再放大一轮，让模型明显占据视图中心区域
      root.scale = SCNVector3(5, 5, 5)

      applyCameraAndLights(to: scene)
      scnView.scene = scene
      statusLabel.isHidden = true
    } catch {
      statusLabel.text = "DAE 加载失败：\(error.localizedDescription)"
    }
  }

  /// 使用固定相机 + 简单灯光，保证总能看到 (0,0,0) 附近的模型
  private func applyCameraAndLights(to scene: SCNScene) {
    let camNode = SCNNode()
    camNode.camera = SCNCamera()
    camNode.camera?.zNear = 0.01
    camNode.camera?.zFar = 200
    // 减小视角 + 再靠近，让模型在画面中更大
    camNode.camera?.fieldOfView = 28
    camNode.position = SCNVector3(0, 0.25, 1.2)
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

  /// 多机位环绕截图，固定绕 Y 轴均匀取样，返回 Base64 数组
  @objc public func captureSnapshotsAround(_ countNumber: NSNumber) -> [String]? {
    // 必须主线程
    if !Thread.isMainThread {
      var result: [String]?
      DispatchQueue.main.sync {
        result = self.captureSnapshotsAround(countNumber)
      }
      return result
    }

    guard let cam = cameraNode else {
      return nil
    }
    let sceneCenter = SCNVector3(0, 0, 0)
    let originalPos = cam.position

    // 以当前相机的水平距离为半径，在水平面上绕圈
    let dx = originalPos.x - sceneCenter.x
    let dz = originalPos.z - sceneCenter.z
    let radius = max(sqrt(dx * dx + dz * dz), 0.5)
    let baseAngle = atan2f(dz, dx)

    let n = max(1, min(countNumber.intValue, 12))
    var results: [String] = []

    for i in 0..<n {
      let t = Float(i) / Float(max(n, 1))
      let angle = baseAngle + 2.0 * Float.pi * t
      let x = sceneCenter.x + radius * cosf(angle)
      let z = sceneCenter.z + radius * sinf(angle)
      cam.position = SCNVector3(x, originalPos.y, z)
      cam.look(at: sceneCenter)
      if let b64 = snapshotOnce() {
        results.append(b64)
      }
    }

    // 恢复原位
    cam.position = originalPos
    cam.look(at: sceneCenter)

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
