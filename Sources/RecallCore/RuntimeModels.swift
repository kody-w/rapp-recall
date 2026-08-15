import Foundation

public enum RecallDaemonState: String, Codable, Sendable {
  case starting
  case recording
  case paused
  case stopping
  case stopped
  case failed
}

public enum RuntimeCommandKind: String, Codable, Sendable {
  case pause
  case resume
  case stop
}

public struct RuntimeStatus: Codable, Sendable, Equatable {
  public var processID: Int32
  public var state: RecallDaemonState
  public var startedAt: Date
  public var lastCaptureAt: Date?
  public var storedFrames: Int
  public var excludedFrames: Int
  public var duplicateFrames: Int
  public var droppedFrames: Int
  public var lastError: String?
  public var updatedAt: Date

  public init(
    processID: Int32,
    state: RecallDaemonState,
    startedAt: Date,
    lastCaptureAt: Date? = nil,
    storedFrames: Int = 0,
    excludedFrames: Int = 0,
    duplicateFrames: Int = 0,
    droppedFrames: Int = 0,
    lastError: String? = nil,
    updatedAt: Date = Date()
  ) {
    self.processID = processID
    self.state = state
    self.startedAt = startedAt
    self.lastCaptureAt = lastCaptureAt
    self.storedFrames = storedFrames
    self.excludedFrames = excludedFrames
    self.duplicateFrames = duplicateFrames
    self.droppedFrames = droppedFrames
    self.lastError = lastError
    self.updatedAt = updatedAt
  }
}

public struct RuntimeCommand: Codable, Sendable, Equatable {
  public let id: Int64
  public let kind: RuntimeCommandKind
  public let requestedAt: Date

  public init(id: Int64, kind: RuntimeCommandKind, requestedAt: Date) {
    self.id = id
    self.kind = kind
    self.requestedAt = requestedAt
  }
}

public struct RuntimeCommandReceipt: Codable, Sendable, Equatable {
  public let id: Int64
  public let kind: RuntimeCommandKind
  public let requestedAt: Date
  public let processedAt: Date?
  public let error: String?

  public var processed: Bool { processedAt != nil }
  public var succeeded: Bool { processed && error == nil }
}
