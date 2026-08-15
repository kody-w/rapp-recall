import CoreGraphics
import CryptoKit
import Foundation

public struct RawCapturedFrame: @unchecked Sendable {
  public let capturedAt: Date
  public let image: CGImage
  public let context: AppContext

  public init(capturedAt: Date, image: CGImage, context: AppContext) {
    self.capturedAt = capturedAt
    self.image = image
    self.context = context
  }
}

public struct EncodedFrame: Sendable {
  public let data: Data
  public let format: String

  public init(data: Data, format: String) {
    self.data = data
    self.format = format
  }
}

public protocol FrameEncoding: Sendable {
  func encode(_ image: CGImage) throws -> EncodedFrame
}

public protocol TextExtracting: Sendable {
  func extractText(from image: CGImage) async throws -> String
}

public protocol MomentWriting: Sendable {
  func add(_ draft: MomentDraft) async throws -> Moment
}

extension RecallStore: MomentWriting {}

public enum FrameProcessingOutcome: Sendable, Equatable {
  case stored(Moment)
  case excluded(ExclusionReason)
  case duplicate
}

public actor CapturePipeline {
  private var policy: ExclusionPolicy
  private let encoder: any FrameEncoding
  private let textExtractor: any TextExtracting
  private let repository: any MomentWriting
  private var previousFrameHash: String?

  public init(
    policy: ExclusionPolicy,
    encoder: any FrameEncoding,
    textExtractor: any TextExtracting,
    repository: any MomentWriting
  ) {
    self.policy = policy
    self.encoder = encoder
    self.textExtractor = textExtractor
    self.repository = repository
  }

  public func updatePolicy(_ policy: ExclusionPolicy) {
    self.policy = policy
  }

  public func process(_ rawFrame: RawCapturedFrame) async throws -> FrameProcessingOutcome {
    switch policy.decision(for: rawFrame.context) {
    case .exclude(let reason):
      // This branch intentionally precedes encoding, OCR, hashing,
      // repository access, temporary files, and diagnostics.
      return .excluded(reason)
    case .allow:
      break
    }

    let encoded = try encoder.encode(rawFrame.image)
    let frameHash = SHA256.hash(data: encoded.data)
      .map { String(format: "%02x", $0) }
      .joined()

    guard frameHash != previousFrameHash else {
      return .duplicate
    }

    let text = try await textExtractor.extractText(from: rawFrame.image)
    let frame = CapturedFrame(
      capturedAt: rawFrame.capturedAt,
      imageData: encoded.data,
      imageFormat: encoded.format,
      width: rawFrame.image.width,
      height: rawFrame.image.height,
      context: rawFrame.context
    )
    let moment = try await repository.add(
      MomentDraft(frame: frame, recognizedText: text, frameHash: frameHash)
    )
    previousFrameHash = frameHash
    return .stored(moment)
  }
}
