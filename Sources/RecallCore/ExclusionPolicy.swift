import Foundation

public enum ExclusionReason: String, Sendable, Equatable {
  case application
  case privateWindow
  case noFrontmostApplication
}

public enum CaptureDecision: Sendable, Equatable {
  case allow
  case exclude(ExclusionReason)
}

public struct ExclusionPolicy: Sendable {
  public var excludedBundleIdentifiers: Set<String>
  public var excludedApplicationNames: Set<String>
  public var privateWindowMarkers: [String]
  public var excludeUnknownApplications: Bool

  public init(
    excludedBundleIdentifiers: Set<String> = [],
    excludedApplicationNames: Set<String> = [],
    privateWindowMarkers: [String] = [
      "private browsing",
      "private window",
      "incognito",
    ],
    excludeUnknownApplications: Bool = true
  ) {
    self.excludedBundleIdentifiers = excludedBundleIdentifiers
    self.excludedApplicationNames = excludedApplicationNames
    self.privateWindowMarkers = privateWindowMarkers
    self.excludeUnknownApplications = excludeUnknownApplications
  }

  public func decision(for context: AppContext) -> CaptureDecision {
    let appName = context.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
    if appName.isEmpty, excludeUnknownApplications {
      return .exclude(.noFrontmostApplication)
    }

    if let bundleIdentifier = context.bundleIdentifier,
      excludedBundleIdentifiers.contains(bundleIdentifier)
    {
      return .exclude(.application)
    }

    if excludedApplicationNames.contains(where: {
      $0.caseInsensitiveCompare(appName) == .orderedSame
    }) {
      return .exclude(.application)
    }

    if let title = context.windowTitle?.lowercased(),
      privateWindowMarkers.contains(where: title.contains)
    {
      return .exclude(.privateWindow)
    }

    return .allow
  }
}
