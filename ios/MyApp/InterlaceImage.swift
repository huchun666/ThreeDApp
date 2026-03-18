import Foundation
import UIKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import React
import Photos

@objc(InterlaceImage)
final class InterlaceImage: NSObject {

  static func moduleName() -> String! {
    return "InterlaceImage"
  }

  static func requiresMainQueueSetup() -> Bool {
    return false
  }

  @objc(generateInterlacedImage:resolver:rejecter:)
  func generateInterlacedImage(
    _ imagePaths: [String],
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      autoreleasepool {
        do {
          let outputPath = try Self.generateInterlacedImageInternal(
            imagePaths: imagePaths,
            axis: .columns,
            stride: 1,
            resizeToFirst: true
          )

          DispatchQueue.main.async {
            resolve(outputPath)
          }
        } catch {
          let nsError = error as NSError
          DispatchQueue.main.async {
            reject("E_INTERLACE_IMAGE", nsError.localizedDescription, nsError)
          }
        }
      }
    }
  }

  @objc(saveImageToPhotos:resolver:rejecter:)
  func saveImageToPhotos(
    _ options: NSDictionary,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let filePath = options["filePath"] as? String
    let base64 = options["base64"] as? String

    func fail(_ message: String) {
      reject("E_SAVE_PHOTOS", message, nil)
    }

    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          fail("未获得保存到相册权限（Photos Add Only）")
        }
        return
      }

      if let filePath, !filePath.isEmpty {
        let resolved = filePath.hasPrefix("file://") ? (URL(string: filePath)?.path ?? filePath) : filePath
        let url = URL(fileURLWithPath: resolved)
        PHPhotoLibrary.shared().performChanges({
          _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }, completionHandler: { ok, err in
          DispatchQueue.main.async {
            if ok {
              resolve(true)
            } else {
              fail(err?.localizedDescription ?? "保存失败（filePath）")
            }
          }
        })
        return
      }

      if let base64, !base64.isEmpty {
        let s = base64
        let idx = s.range(of: "base64,")?.upperBound
        let b64 = idx != nil ? String(s[idx!...]) : s
        guard let data = Data(base64Encoded: b64), let image = UIImage(data: data) else {
          DispatchQueue.main.async { fail("base64 图片解码失败") }
          return
        }

        PHPhotoLibrary.shared().performChanges({
          PHAssetChangeRequest.creationRequestForAsset(from: image)
        }, completionHandler: { ok, err in
          DispatchQueue.main.async {
            if ok {
              resolve(true)
            } else {
              fail(err?.localizedDescription ?? "保存失败（base64）")
            }
          }
        })
        return
      }

      DispatchQueue.main.async {
        fail("请传入 filePath 或 base64")
      }
    }
  }

  private enum InterlaceAxis {
    case columns
    case rows
  }

  private enum InterlaceError: LocalizedError {
    case emptyInput
    case failedToLoadImage(String)
    case invalidFirstImage
    case bufferAllocationFailed(Int)
    case cgImageCreationFailed
    case pngWriteFailed

    var errorDescription: String? {
      switch self {
      case .emptyInput:
        return "imagePaths 不能为空"
      case .failedToLoadImage(let path):
        return "无法加载图片: \(path)"
      case .invalidFirstImage:
        return "第一张图片无效（无法获取 CGImage/尺寸）"
      case .bufferAllocationFailed(let bytes):
        return "分配像素缓冲区失败: \(bytes) bytes"
      case .cgImageCreationFailed:
        return "生成 CGImage 失败"
      case .pngWriteFailed:
        return "写入 PNG 失败"
      }
    }
  }

  private static func generateInterlacedImageInternal(
    imagePaths: [String],
    axis: InterlaceAxis,
    stride: Int,
    resizeToFirst: Bool
  ) throws -> String {
    guard !imagePaths.isEmpty else {
      throw InterlaceError.emptyInput
    }

    let firstUIImage = try loadUIImage(path: imagePaths[0])
    guard let firstCGImage = firstUIImage.cgImage else {
      throw InterlaceError.invalidFirstImage
    }

    let targetWidth = firstCGImage.width
    let targetHeight = firstCGImage.height
    guard targetWidth > 0, targetHeight > 0 else {
      throw InterlaceError.invalidFirstImage
    }

    let bytesPerPixel = 4
    let bytesPerRow = targetWidth * bytesPerPixel
    let totalBytes = targetHeight * bytesPerRow

    let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)
    outputBuffer.initialize(repeating: 0, count: totalBytes)

    defer {
      outputBuffer.deinitialize(count: totalBytes)
      outputBuffer.deallocate()
    }

    let imageCount = imagePaths.count
    var sourceBuffers: [UnsafeMutablePointer<UInt8>] = []
    sourceBuffers.reserveCapacity(imageCount)

    defer {
      for sourceBuffer in sourceBuffers {
        sourceBuffer.deinitialize(count: totalBytes)
        sourceBuffer.deallocate()
      }
    }

    for imagePath in imagePaths {
      let uiImage = try loadUIImage(path: imagePath)
      let cgImage = try normalizedCGImage(uiImage: uiImage)

      let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)
      sourceBuffer.initialize(repeating: 0, count: totalBytes)
      sourceBuffers.append(sourceBuffer)

      guard let context = CGContext(
        data: sourceBuffer,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
        throw InterlaceError.cgImageCreationFailed
      }

      context.interpolationQuality = .high
      context.setBlendMode(.copy)

      if resizeToFirst {
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
      } else {
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
      }
    }

    let safeStride = max(1, stride)

    switch axis {
    case .columns:
      for x in 0..<targetWidth {
        let imgIndex = ((x / safeStride) % imageCount)
        let sourcePixels = sourceBuffers[imgIndex]

        for y in 0..<targetHeight {
          let offset = y * bytesPerRow + x * bytesPerPixel
          memcpy(outputBuffer + offset, sourcePixels + offset, bytesPerPixel)
        }
      }

    case .rows:
      for y in 0..<targetHeight {
        let imgIndex = ((y / safeStride) % imageCount)
        let sourcePixels = sourceBuffers[imgIndex]

        let rowOffset = y * bytesPerRow
        memcpy(outputBuffer + rowOffset, sourcePixels + rowOffset, bytesPerRow)
      }
    }

    guard let outputContext = CGContext(
      data: outputBuffer,
      width: targetWidth,
      height: targetHeight,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw InterlaceError.cgImageCreationFailed
    }

    guard let outputCGImage = outputContext.makeImage() else {
      throw InterlaceError.cgImageCreationFailed
    }

    let filename = "interlaced_\(Int(Date().timeIntervalSince1970 * 1000)).png"
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
    try writePNG(cgImage: outputCGImage, to: outputURL)

    return outputURL.path
  }

  private static func loadUIImage(path: String) throws -> UIImage {
    let resolvedPath: String
    if path.hasPrefix("file://") {
      resolvedPath = URL(string: path)?.path ?? path
    } else {
      resolvedPath = path
    }

    guard let image = UIImage(contentsOfFile: resolvedPath) else {
      throw InterlaceError.failedToLoadImage(resolvedPath)
    }
    return image
  }

  private static func normalizedCGImage(uiImage: UIImage) throws -> CGImage {
    if let cgImage = uiImage.cgImage, uiImage.imageOrientation == .up {
      return cgImage
    }

    let inputCGImage: CGImage
    if let cgImage = uiImage.cgImage {
      inputCGImage = cgImage
    } else if let ciImage = uiImage.ciImage {
      let ciContext = CIContext(options: nil)
      guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
        throw InterlaceError.cgImageCreationFailed
      }
      inputCGImage = cgImage
    } else {
      throw InterlaceError.cgImageCreationFailed
    }

    let width = inputCGImage.width
    let height = inputCGImage.height

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    let totalBytes = height * bytesPerRow

    let tempBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)
    tempBuffer.initialize(repeating: 0, count: totalBytes)

    defer {
      tempBuffer.deinitialize(count: totalBytes)
      tempBuffer.deallocate()
    }

    guard let context = CGContext(
      data: tempBuffer,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw InterlaceError.cgImageCreationFailed
    }

    context.interpolationQuality = .high
    context.setBlendMode(.copy)

    var transform = CGAffineTransform.identity

    switch uiImage.imageOrientation {
    case .down, .downMirrored:
      transform = transform.translatedBy(x: CGFloat(width), y: CGFloat(height))
      transform = transform.rotated(by: .pi)

    case .left, .leftMirrored:
      transform = transform.translatedBy(x: CGFloat(width), y: 0)
      transform = transform.rotated(by: .pi / 2)

    case .right, .rightMirrored:
      transform = transform.translatedBy(x: 0, y: CGFloat(height))
      transform = transform.rotated(by: -.pi / 2)

    case .up, .upMirrored:
      break

    @unknown default:
      break
    }

    switch uiImage.imageOrientation {
    case .upMirrored, .downMirrored:
      transform = transform.translatedBy(x: CGFloat(width), y: 0)
      transform = transform.scaledBy(x: -1, y: 1)

    case .leftMirrored, .rightMirrored:
      transform = transform.translatedBy(x: CGFloat(height), y: 0)
      transform = transform.scaledBy(x: -1, y: 1)

    default:
      break
    }

    context.concatenate(transform)

    let drawRect: CGRect
    switch uiImage.imageOrientation {
    case .left, .leftMirrored, .right, .rightMirrored:
      drawRect = CGRect(x: 0, y: 0, width: height, height: width)
    default:
      drawRect = CGRect(x: 0, y: 0, width: width, height: height)
    }

    context.draw(inputCGImage, in: drawRect)

    guard let normalized = context.makeImage() else {
      throw InterlaceError.cgImageCreationFailed
    }

    return normalized
  }

  private static func writePNG(cgImage: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw InterlaceError.pngWriteFailed
    }

    CGImageDestinationAddImage(destination, cgImage, nil)

    guard CGImageDestinationFinalize(destination) else {
      throw InterlaceError.pngWriteFailed
    }
  }
}

