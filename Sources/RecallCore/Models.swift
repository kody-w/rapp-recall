import Foundation

public struct AppContext: Sendable, Equatable {
  public let applicationName: String
  public let bundleIdentifier: String?
  public let windowTitle: String?

  public init(
    applicationName: String,
    bundleIdentifier: String?,
    windowTitle: String?
  ) {
    self.applicationName = applicationName
    self.bundleIdentifier = bundleIdentifier
    self.windowTitle = windowTitle
  }
}

public struct CapturedFrame: Sendable {
  public let capturedAt: Date
  public let imageData: Data
  public let imageFormat: String
  public let width: Int
  public let height: Int
  public let context: AppContext

  public init(
    capturedAt: Date,
    imageData: Data,
    imageFormat: String,
    width: Int,
    height: Int,
    context: AppContext
  ) {
    self.capturedAt = capturedAt
    self.imageData = imageData
    self.imageFormat = imageFormat
    self.width = width
    self.height = height
    self.context = context
  }
}

public struct MomentDraft: Sendable {
  public let frame: CapturedFrame
  public let recognizedText: String
  public let frameHash: String

  public init(frame: CapturedFrame, recognizedText: String, frameHash: String) {
    self.frame = frame
    self.recognizedText = recognizedText
    self.frameHash = frameHash
  }
}

public struct Moment: Identifiable, Sendable, Equatable, Codable {
  public let id: Int64
  public let capturedAt: Date
  public let applicationName: String
  public let bundleIdentifier: String?
  public let windowTitle: String?
  public let mediaURL: URL
  public let recognizedText: String
  public let width: Int
  public let height: Int
  public let starred: Bool

  public init(
    id: Int64,
    capturedAt: Date,
    applicationName: String,
    bundleIdentifier: String?,
    windowTitle: String?,
    mediaURL: URL,
    recognizedText: String,
    width: Int,
    height: Int,
    starred: Bool
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.applicationName = applicationName
    self.bundleIdentifier = bundleIdentifier
    self.windowTitle = windowTitle
    self.mediaURL = mediaURL
    self.recognizedText = recognizedText
    self.width = width
    self.height = height
    self.starred = starred
  }
}

public struct SearchRequest: Sendable, Equatable {
  public var text: String
  public var application: String?
  public var starredOnly: Bool
  public var limit: Int

  public init(
    text: String = "",
    application: String? = nil,
    starredOnly: Bool = false,
    limit: Int = 200
  ) {
    self.text = text
    self.application = application
    self.starredOnly = starredOnly
    self.limit = limit
  }
}
