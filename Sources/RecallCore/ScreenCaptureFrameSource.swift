import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum FrameSourceEvent: Sendable {
  case frame(RawCapturedFrame)
  case failure(String)
}

public protocol FrameSource: AnyObject, Sendable {
  func start(handler: @escaping @Sendable (FrameSourceEvent) -> Void) async throws
  func stop() async throws
}

public enum ScreenCaptureSourceError: Error, LocalizedError {
  case noDisplay
  case alreadyRunning

  public var errorDescription: String? {
    switch self {
    case .noDisplay:
      "ScreenCaptureKit did not return an available display."
    case .alreadyRunning:
      "Screen capture is already running."
    }
  }
}

public final class ScreenCaptureFrameSource: NSObject, FrameSource, @unchecked Sendable {
  private let interval: TimeInterval
  private let excludedBundleIdentifiers: Set<String>
  private let callbackQueue = DispatchQueue(
    label: "ai.rapp.recall.capture",
    qos: .utility,
    autoreleaseFrequency: .workItem
  )
  private let lock = NSLock()
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  private var stream: SCStream?
  private var handler: (@Sendable (FrameSourceEvent) -> Void)?
  private var filterRefreshTask: Task<Void, Never>?
  private var currentDisplayID: CGDirectDisplayID?
  private var captureBounds: CGRect?
  private var excludedProcessIDs: Set<pid_t> = []

  public init(
    interval: TimeInterval = 2.0,
    excludedBundleIdentifiers: Set<String> = []
  ) {
    self.interval = max(interval, 0.25)
    self.excludedBundleIdentifiers = excludedBundleIdentifiers
    super.init()
  }

  public func start(handler: @escaping @Sendable (FrameSourceEvent) -> Void) async throws {
    let running = lock.withLock { stream != nil }
    guard !running else { throw ScreenCaptureSourceError.alreadyRunning }

    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    guard let display = selectedDisplay(from: content.displays) else {
      throw ScreenCaptureSourceError.noDisplay
    }

    let configuration = streamConfiguration(for: display)

    let excludedApplications = content.applications.filter {
      excludedBundleIdentifiers.contains($0.bundleIdentifier)
    }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: excludedApplications,
      exceptingWindows: []
    )
    let newStream = SCStream(
      filter: filter,
      configuration: configuration,
      delegate: self
    )
    try newStream.addStreamOutput(
      self,
      type: .screen,
      sampleHandlerQueue: callbackQueue
    )

    lock.withLock {
      self.handler = handler
      stream = newStream
      currentDisplayID = display.displayID
      captureBounds = display.frame
      excludedProcessIDs = Set(excludedApplications.map(\.processID))
    }

    do {
      try await newStream.startCapture()
      let refreshTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled else { return }
          await self?.refreshContentFilter()
        }
      }
      lock.withLock { filterRefreshTask = refreshTask }
    } catch {
      lock.withLock {
        self.handler = nil
        stream = nil
        currentDisplayID = nil
        captureBounds = nil
        excludedProcessIDs = []
      }
      throw error
    }
  }

  public func stop() async throws {
    let active = lock.withLock {
      let current = stream
      let refresh = filterRefreshTask
      stream = nil
      handler = nil
      filterRefreshTask = nil
      currentDisplayID = nil
      captureBounds = nil
      excludedProcessIDs = []
      return (current, refresh)
    }
    active.1?.cancel()
    await active.1?.value
    if let activeStream = active.0 {
      try await activeStream.stopCapture()
      try? activeStream.removeStreamOutput(self, type: .screen)
    }
  }

  private func selectedDisplay(from displays: [SCDisplay]) -> SCDisplay? {
    let pointer = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }),
      let displayNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber
    {
      let identifier = CGDirectDisplayID(displayNumber.uint32Value)
      if let match = displays.first(where: { $0.displayID == identifier }) {
        return match
      }
    }
    return displays.first
  }

  private func currentContext() -> AppContext {
    let displayBounds = lock.withLock { captureBounds }
    if let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] {
      for info in windows {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
          pid != ProcessInfo.processInfo.processIdentifier,
          (info[kCGWindowLayer as String] as? Int) == 0,
          (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
          let owner = info[kCGWindowOwnerName as String] as? String,
          !Self.ignoredWindowOwners.contains(owner.lowercased()),
          let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(
            dictionaryRepresentation: boundsDictionary as CFDictionary
          ),
          displayBounds.map({ bounds.intersects($0) }) ?? true,
          bounds.width >= 160,
          bounds.height >= 100,
          bounds.width * bounds.height >= 40_000
        else {
          continue
        }

        let app = NSRunningApplication(processIdentifier: pid)
        if let bundleIdentifier = app?.bundleIdentifier,
          Self.ignoredWindowBundles.contains(bundleIdentifier)
        {
          continue
        }
        return AppContext(
          applicationName: app?.localizedName ?? owner,
          bundleIdentifier: app?.bundleIdentifier,
          windowTitle: info[kCGWindowName as String] as? String
        )
      }
    }

    if let app = NSWorkspace.shared.frontmostApplication {
      return AppContext(
        applicationName: app.localizedName ?? "",
        bundleIdentifier: app.bundleIdentifier,
        windowTitle: nil
      )
    }
    return AppContext(applicationName: "", bundleIdentifier: nil, windowTitle: nil)
  }

  private func emit(_ event: FrameSourceEvent) {
    let currentHandler = lock.withLock { handler }
    currentHandler?(event)
  }

  private func streamConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.minimumFrameInterval = CMTime(
      seconds: interval,
      preferredTimescale: 600
    )
    configuration.queueDepth = 2
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = true
    configuration.capturesAudio = false
    return configuration
  }

  private func refreshContentFilter() async {
    let activeStream = lock.withLock { stream }
    guard let activeStream else { return }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
      guard let display = selectedDisplay(from: content.displays) else {
        throw ScreenCaptureSourceError.noDisplay
      }
      let excludedApplications = content.applications.filter {
        excludedBundleIdentifiers.contains($0.bundleIdentifier)
      }
      let processIDs = Set(excludedApplications.map(\.processID))
      let previous = lock.withLock {
        (currentDisplayID, excludedProcessIDs)
      }
      guard previous.0 != display.displayID || previous.1 != processIDs else {
        return
      }

      let filter = SCContentFilter(
        display: display,
        excludingApplications: excludedApplications,
        exceptingWindows: []
      )
      try await activeStream.updateContentFilter(filter)
      if previous.0 != display.displayID {
        try await activeStream.updateConfiguration(
          streamConfiguration(for: display)
        )
      }
      lock.withLock {
        currentDisplayID = display.displayID
        captureBounds = display.frame
        excludedProcessIDs = processIDs
      }
    } catch {
      guard !Task.isCancelled else { return }
      // Continuing with a stale exclusion filter can persist a newly
      // launched private app. Stop the daemon rather than guess.
      emit(.failure("Could not refresh capture privacy filter: \(error.localizedDescription)"))
    }
  }

  private static let ignoredWindowOwners: Set<String> = [
    "control center",
    "dock",
    "notification center",
    "rapp recall",
    "systemuiserver",
    "usernotificationcenter",
    "window server",
  ]

  private static let ignoredWindowBundles: Set<String> = [
    "ai.rapp.recall",
    "com.apple.controlcenter",
    "com.apple.dock",
    "com.apple.notificationcenterui",
    "com.apple.systemuiserver",
    "com.apple.usernotificationcenter",
  ]
}

extension ScreenCaptureFrameSource: SCStreamOutput {
  public func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen,
      sampleBuffer.isValid,
      let pixelBuffer = sampleBuffer.imageBuffer
    else {
      return
    }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: false
    ) as? [[SCStreamFrameInfo: Any]],
      let statusRaw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: statusRaw),
      status != .complete
    {
      return
    }

    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
      emit(.failure("Core Image could not materialize a captured frame."))
      return
    }
    emit(
      .frame(
        RawCapturedFrame(
          capturedAt: Date(),
          image: cgImage,
          context: currentContext()
        )))
  }
}

extension ScreenCaptureFrameSource: SCStreamDelegate {
  public func stream(_ stream: SCStream, didStopWithError error: any Error) {
    emit(.failure(error.localizedDescription))
  }
}
