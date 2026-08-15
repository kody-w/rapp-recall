import CoreGraphics
import Foundation
import Vision

public enum VisionTextError: Error, LocalizedError {
  case noResults

  public var errorDescription: String? {
    "Vision returned no recognition result."
  }
}

public final class VisionTextExtractor: TextExtracting, @unchecked Sendable {
  private final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  private let queue = DispatchQueue(
    label: "ai.rapp.recall.vision",
    qos: .utility,
    autoreleaseFrequency: .workItem
  )
  private let recognitionLevel: VNRequestTextRecognitionLevel

  public init(accurate: Bool = true) {
    recognitionLevel = accurate ? .accurate : .fast
  }

  public func extractText(from image: CGImage) async throws -> String {
    let boxed = ImageBox(image)
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [recognitionLevel] in
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        do {
          let handler = VNImageRequestHandler(cgImage: boxed.image)
          try handler.perform([request])
          guard let observations = request.results else {
            throw VisionTextError.noResults
          }
          // Vision does not promise reading order. Sort lines by
          // visual row, then left-to-right, so phrase search reflects
          // what a person sees instead of request-result ordering.
          let ordered = observations.sorted { left, right in
            let rowTolerance =
              max(
                left.boundingBox.height,
                right.boundingBox.height
              ) * 0.5
            if abs(left.boundingBox.midY - right.boundingBox.midY) > rowTolerance {
              return left.boundingBox.midY > right.boundingBox.midY
            }
            return left.boundingBox.minX < right.boundingBox.minX
          }
          let text =
            ordered
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
          continuation.resume(returning: text)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
