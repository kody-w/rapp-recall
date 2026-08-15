import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameEncodingError: Error, LocalizedError {
  case destinationUnavailable
  case finalizeFailed

  public var errorDescription: String? {
    switch self {
    case .destinationUnavailable:
      "The system HEIF encoder is unavailable."
    case .finalizeFailed:
      "The system HEIF encoder failed to finalize the frame."
    }
  }
}

public struct HEIFFrameEncoder: FrameEncoding {
  public let quality: Double

  public init(quality: Double = 0.58) {
    self.quality = min(max(quality, 0), 1)
  }

  public func encode(_ image: CGImage) throws -> EncodedFrame {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.heic.identifier as CFString,
        1,
        nil
      )
    else {
      throw FrameEncodingError.destinationUnavailable
    }

    let properties: CFDictionary =
      [
        kCGImageDestinationLossyCompressionQuality: quality
      ] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
      throw FrameEncodingError.finalizeFailed
    }
    return EncodedFrame(data: data as Data, format: "heic")
  }
}
