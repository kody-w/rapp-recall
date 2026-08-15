import CSQLite
import CoreGraphics
import CoreText
import Foundation
import RecallCore

private struct Check: Codable {
  let name: String
  let status: String
  let detail: String
}

private struct Report: Codable {
  let verdict: String
  let checks: [Check]
  let storeRoot: String
}

private final class CountingEncoder: FrameEncoding, @unchecked Sendable {
  private let lock = NSLock()
  private let delegate: any FrameEncoding
  private(set) var count = 0

  init(delegate: any FrameEncoding) {
    self.delegate = delegate
  }

  func encode(_ image: CGImage) throws -> EncodedFrame {
    lock.withLock { count += 1 }
    return try delegate.encode(image)
  }

  var calls: Int { lock.withLock { count } }
}

private final class CountingExtractor: TextExtracting, @unchecked Sendable {
  private let lock = NSLock()
  private let delegate: any TextExtracting
  private(set) var count = 0

  init(delegate: any TextExtracting) {
    self.delegate = delegate
  }

  func extractText(from image: CGImage) async throws -> String {
    lock.withLock { count += 1 }
    return try await delegate.extractText(from: image)
  }

  var calls: Int { lock.withLock { count } }
}

private final class SequenceEncoder: FrameEncoding, @unchecked Sendable {
  private let lock = NSLock()
  private var sequence = 0

  func encode(_ image: CGImage) throws -> EncodedFrame {
    let value = lock.withLock {
      sequence += 1
      return sequence
    }
    return EncodedFrame(
      data: Data("synthetic-frame-\(value)".utf8),
      format: "png"
    )
  }
}

private struct StaticExtractor: TextExtracting {
  func extractText(from image: CGImage) async throws -> String {
    "daemon acceptance frame"
  }
}

private struct InjectedPipelineError: Error, LocalizedError {
  var errorDescription: String? { "injected OCR failure" }
}

private struct ThrowingExtractor: TextExtracting {
  func extractText(from image: CGImage) async throws -> String {
    throw InjectedPipelineError()
  }
}

private final class CompletionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  func markCompleted() {
    lock.withLock { completed = true }
  }

  var isCompleted: Bool { lock.withLock { completed } }
}

private final class SequenceFrameSource: FrameSource, @unchecked Sendable {
  private let lock = NSLock()
  private let image: CGImage
  private var task: Task<Void, Never>?

  init(image: CGImage) {
    self.image = image
  }

  func start(handler: @escaping @Sendable (FrameSourceEvent) -> Void) async throws {
    let alreadyRunning = lock.withLock { task != nil }
    guard !alreadyRunning else {
      throw NSError(
        domain: "RecallAcceptance",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Synthetic source already running."]
      )
    }

    let newTask = Task.detached { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        handler(
          .frame(
            RawCapturedFrame(
              capturedAt: Date(),
              image: self.image,
              context: AppContext(
                applicationName: "Acceptance Fixture",
                bundleIdentifier: "test.acceptance",
                windowTitle: "Synthetic"
              )
            )))
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    lock.withLock { task = newTask }
  }

  func stop() async throws {
    let active = lock.withLock {
      let current = task
      task = nil
      return current
    }
    active?.cancel()
    await active?.value
  }
}

@main
private enum AcceptanceMain {
  static func main() async {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "rapp-recall-acceptance-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let testKey = Data(repeating: 0xA5, count: 32)
    var checks: [Check] = []

    func check(_ condition: Bool, _ name: String, _ detail: String) {
      checks.append(
        Check(
          name: name,
          status: condition ? "pass" : "fail",
          detail: detail
        ))
    }

    do {
      if DatabaseKeyProvider.accessMode == "local-key-file" {
        let localKeyURL = root.appending(path: "isolated-local-build-key")
        setenv("RAPP_RECALL_LOCAL_KEY_PATH", localKeyURL.path, 1)
        defer { unsetenv("RAPP_RECALL_LOCAL_KEY_PATH") }
        let firstLocalKey = try DatabaseKeyProvider.loadOrCreate()
        let secondLocalKey = try DatabaseKeyProvider.loadOrCreate()
        let keyAttributes = try FileManager.default.attributesOfItem(
          atPath: localKeyURL.path
        )
        let keyMode = (keyAttributes[.posixPermissions] as? NSNumber)?.intValue
        check(
          firstLocalKey.count == 32 && firstLocalKey == secondLocalKey,
          "local_key_file_stable",
          "Local builds reopen the same random 256-bit key without interaction."
        )
        check(
          keyMode == 0o600,
          "local_key_file_private",
          "The isolated local-build key file mode is \(keyMode ?? -1); expected 0600."
        )
      } else {
        check(
          DatabaseKeyProvider.accessMode == "application-bound-keychain",
          "signed_keychain_mode",
          "Signed release declares application-bound Keychain mode without touching Keychain in acceptance."
        )
      }

      let store = try RecallStore(rootURL: root, databaseKey: testKey)
      let encoder = CountingEncoder(delegate: HEIFFrameEncoder())
      let extractor = CountingExtractor(delegate: VisionTextExtractor())
      let policy = ExclusionPolicy(
        excludedBundleIdentifiers: ["test.secret"],
        excludeUnknownApplications: true
      )
      let pipeline = CapturePipeline(
        policy: policy,
        encoder: encoder,
        textExtractor: extractor,
        repository: store
      )

      let start = Date(timeIntervalSince1970: 1_800_000_000)
      let firstImage = try syntheticImage(text: "ORBITAL MANGO SEVEN")
      let first = try await pipeline.process(
        RawCapturedFrame(
          capturedAt: start,
          image: firstImage,
          context: AppContext(
            applicationName: "Notes",
            bundleIdentifier: "test.notes",
            windowTitle: "Mission Notes"
          )
        ))

      if case .stored = first {
        checks.append(
          Check(
            name: "allowed_frame_stored",
            status: "pass",
            detail: "An allowed synthetic frame crossed encoder, Vision, media, and SQLite."
          ))
      } else {
        checks.append(
          Check(
            name: "allowed_frame_stored",
            status: "fail",
            detail: "The allowed synthetic frame did not produce a moment."
          ))
      }

      let ocrResults = try await store.search(SearchRequest(text: "\"ORBITAL MANGO\""))
      check(
        ocrResults.count == 1,
        "vision_ocr_search",
        "Phrase search returned \(ocrResults.count) result(s); expected exactly one."
      )
      check(
        ocrResults.first?.applicationName == "Notes",
        "search_metadata",
        "The OCR match retained the source application."
      )

      let encoderBefore = encoder.calls
      let extractorBefore = extractor.calls
      let excludedPhrase = "NEVER PERSIST CIPHER"
      let excluded = try await pipeline.process(
        RawCapturedFrame(
          capturedAt: start.addingTimeInterval(2),
          image: try syntheticImage(text: excludedPhrase),
          context: AppContext(
            applicationName: "Secrets",
            bundleIdentifier: "test.secret",
            windowTitle: excludedPhrase
          )
        ))
      check(
        excluded == .excluded(.application),
        "excluded_decision",
        "The configured bundle identifier was excluded."
      )
      check(
        encoder.calls == encoderBefore,
        "exclude_before_encode",
        "Encoder call count stayed at \(encoderBefore)."
      )
      check(
        extractor.calls == extractorBefore,
        "exclude_before_ocr",
        "Vision call count stayed at \(extractorBefore)."
      )
      check(
        try await store.search(SearchRequest(text: "CIPHER")).isEmpty,
        "excluded_not_indexed",
        "FTS returned no excluded phrase."
      )
      let excludedBytesFound = try directoryContains(
        root: root,
        bytes: Data(excludedPhrase.utf8)
      )
      check(
        !excludedBytesFound,
        "excluded_bytes_absent",
        "No file in the store contains the excluded phrase bytes."
      )
      check(
        try !directoryContains(
          root: root,
          bytes: Data("ORBITAL MANGO SEVEN".utf8)
        ),
        "stored_text_is_ciphertext",
        "A phrase that was stored and searchable appears nowhere as plaintext bytes."
      )

      let duplicate = try await pipeline.process(
        RawCapturedFrame(
          capturedAt: start.addingTimeInterval(4),
          image: firstImage,
          context: AppContext(
            applicationName: "Notes",
            bundleIdentifier: "test.notes",
            windowTitle: "Mission Notes"
          )
        ))
      check(
        duplicate == .duplicate,
        "unchanged_frame_deduplicated",
        "An unchanged frame did not create another media or index row."
      )
      check(
        try await store.momentCount() == 1,
        "deduplicated_row_count",
        "Store contains one row after replaying an identical frame."
      )

      let second = try await pipeline.process(
        RawCapturedFrame(
          capturedAt: start.addingTimeInterval(10),
          image: try syntheticImage(text: "NEBULA RIVER NINE"),
          context: AppContext(
            applicationName: "Terminal",
            bundleIdentifier: "test.terminal",
            windowTitle: "Build"
          )
        ))
      check(
        {
          if case .stored = second { return true }
          return false
        }(),
        "second_allowed_frame",
        "A changed allowed frame was stored."
      )

      let recent = try await store.search(SearchRequest())
      check(
        recent.map(\.applicationName) == ["Terminal", "Notes"],
        "reverse_chronological",
        "Recent results are newest-first."
      )

      let firstMedia = ocrResults.first?.mediaURL
      let purged = try await store.purge(
        before: start.addingTimeInterval(5)
      )
      check(
        purged == 1,
        "retention_row_removed",
        "Retention removed one old row."
      )
      check(
        firstMedia.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
        "retention_media_removed",
        "Retention removed matching media."
      )
      check(
        try await store.search(SearchRequest(text: "ORBITAL")).isEmpty,
        "retention_fts_removed",
        "Retention removed the matching FTS row."
      )
      check(
        try await store.search(SearchRequest(text: "NEBULA")).count == 1,
        "retention_preserves_recent",
        "Retention kept the recent moment."
      )
      check(
        try await store.search(SearchRequest(text: "\"")).isEmpty,
        "degenerate_search_is_empty",
        "A quote-only query returns no results instead of an internal FTS error."
      )
      do {
        try await store.setStarred(true, momentID: 9_999_999)
        check(
          false,
          "missing_moment_is_error",
          "Starring a nonexistent moment incorrectly reported success."
        )
      } catch RecallStoreError.momentNotFound {
        check(
          true,
          "missing_moment_is_error",
          "Starring a nonexistent moment reports an explicit error."
        )
      }
      let databaseURL = root.appending(path: "recall.sqlite")
      let header = try Data(contentsOf: databaseURL).prefix(16)
      check(
        header != Data("SQLite format 3\u{0}".utf8),
        "database_header_encrypted",
        "The database header is not the plaintext SQLite signature."
      )
      check(
        !rawDatabaseIsReadable(at: databaseURL, key: nil),
        "database_rejects_no_key",
        "SQLCipher rejects a query when no database key is supplied."
      )
      check(
        !rawDatabaseIsReadable(
          at: databaseURL,
          key: Data(repeating: 0x5A, count: 32)
        ),
        "database_rejects_wrong_key",
        "SQLCipher rejects a query with a wrong 256-bit key."
      )
      do {
        _ = try RecallStore(
          rootURL: root,
          databaseKey: Data(repeating: 0x5A, count: 32)
        )
        check(
          false,
          "wrong_key_has_specific_error",
          "A wrong key unexpectedly opened the database."
        )
      } catch RecallStoreError.databaseUnreadable {
        check(
          true,
          "wrong_key_has_specific_error",
          "A wrong key surfaces the encrypted-database-unreadable error."
        )
      }
      check(
        rawDatabaseIsReadable(at: databaseURL, key: testKey),
        "database_accepts_correct_key",
        "The injected correct key opens the encrypted database."
      )
      let reopened = try RecallStore(rootURL: root, databaseKey: testKey)
      check(
        try await reopened.search(SearchRequest(text: "NEBULA")).count == 1,
        "encrypted_database_reopens",
        "Closing semantics are independent: another keyed connection preserves FTS results."
      )
      check(
        try await store.cipherVersion().hasPrefix("4."),
        "sqlcipher_version",
        "The store reports SQLCipher \(try await store.cipherVersion())."
      )
      let sidecarModes = try databaseFileModes(root: root)
      check(
        sidecarModes.values.allSatisfy { $0 == 0o600 },
        "database_sidecars_private",
        "Database file modes are \(sidecarModes); expected owner-only 0600."
      )

      let daemonRoot = FileManager.default.temporaryDirectory.appending(
        path: "rapp-recall-daemon-acceptance-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? FileManager.default.removeItem(at: daemonRoot) }
      let daemonStore = try RecallStore(rootURL: daemonRoot, databaseKey: testKey)
      let daemonSource = SequenceFrameSource(image: firstImage)
      let daemonPipeline = CapturePipeline(
        policy: ExclusionPolicy(),
        encoder: SequenceEncoder(),
        textExtractor: StaticExtractor(),
        repository: daemonStore
      )
      let daemon = RecallDaemon(
        source: daemonSource,
        pipeline: daemonPipeline,
        store: daemonStore
      )
      let staleCommandID = try await daemonStore.enqueueRuntimeCommand(.stop)
      let daemonTask = Task { try await daemon.run() }

      let began = try await waitUntil {
        try await daemonStore.runtimeStatus()?.state == .recording
      }
      check(
        began,
        "daemon_started",
        "The headless daemon reached recording state despite a stale stop command."
      )
      let staleReceipt = try await daemonStore.runtimeCommandReceipt(staleCommandID)
      check(
        staleReceipt?.error == "daemon restarted before command processing",
        "stale_command_abandoned",
        "A pending command from a prior daemon lifetime was rejected, not replayed."
      )
      let captured = try await waitUntil {
        try await daemonStore.momentCount() >= 3
      }
      check(
        captured,
        "daemon_captured",
        "The daemon stored at least three synthetic frames."
      )

      let pauseID = try await daemonStore.enqueueRuntimeCommand(.pause)
      let pauseCompleted = try await waitUntil {
        try await daemonStore.runtimeCommandReceipt(pauseID)?.succeeded == true
      }
      let pausedCount = try await daemonStore.momentCount()
      try await Task.sleep(for: .milliseconds(350))
      let pausedCountAfterDelay = try await daemonStore.momentCount()
      check(
        pauseCompleted,
        "pause_acknowledged",
        "The pause command received a successful receipt."
      )
      check(
        pausedCount == pausedCountAfterDelay,
        "pause_is_write_barrier",
        "Moment count stayed \(pausedCount) across the measured pause gap."
      )

      let resumeID = try await daemonStore.enqueueRuntimeCommand(.resume)
      let resumeCompleted = try await waitUntil {
        try await daemonStore.runtimeCommandReceipt(resumeID)?.succeeded == true
      }
      let resumedCapture = try await waitUntil {
        try await daemonStore.momentCount() > pausedCount
      }
      check(
        resumeCompleted && resumedCapture,
        "resume_restarts_capture",
        "Resume was acknowledged and the moment count increased."
      )

      let stopID = try await daemonStore.enqueueRuntimeCommand(.stop)
      let stopCompleted = try await waitUntil {
        try await daemonStore.runtimeCommandReceipt(stopID)?.succeeded == true
      }
      try await daemonTask.value
      let stoppedCount = try await daemonStore.momentCount()
      try await Task.sleep(for: .milliseconds(350))
      let stoppedCountAfterDelay = try await daemonStore.momentCount()
      let stoppedStatus = try await daemonStore.runtimeStatus()
      check(
        stopCompleted && stoppedStatus?.state == .stopped,
        "stop_acknowledged",
        "Stop was acknowledged and runtime state is stopped."
      )
      check(
        stoppedCount == stoppedCountAfterDelay,
        "stop_is_write_barrier",
        "Moment count stayed \(stoppedCount) after stop completed."
      )

      let failureRoot = FileManager.default.temporaryDirectory.appending(
        path: "rapp-recall-failure-acceptance-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? FileManager.default.removeItem(at: failureRoot) }
      let failureStore = try RecallStore(rootURL: failureRoot, databaseKey: testKey)
      let failureSource = SequenceFrameSource(image: firstImage)
      let failurePipeline = CapturePipeline(
        policy: ExclusionPolicy(),
        encoder: SequenceEncoder(),
        textExtractor: ThrowingExtractor(),
        repository: failureStore
      )
      let failureDaemon = RecallDaemon(
        source: failureSource,
        pipeline: failurePipeline,
        store: failureStore
      )
      let completion = CompletionProbe()
      let failureTask = Task {
        do {
          try await failureDaemon.run()
        } catch {
          // Frame-processing errors are reflected in persisted
          // runtime state; run itself may complete normally after
          // the daemon shuts down.
        }
        completion.markCompleted()
      }
      let failureExited = try await waitUntil {
        completion.isCompleted
      }
      let failureStatus = try await failureStore.runtimeStatus()
      check(
        failureExited,
        "pipeline_error_exits_daemon",
        "An injected OCR failure did not deadlock the daemon."
      )
      check(
        failureStatus?.state == .failed
          && failureStatus?.lastError?.contains("injected OCR failure") == true,
        "pipeline_error_is_reported",
        "The injected failure is persisted as failed runtime state."
      )
      if !failureExited {
        failureTask.cancel()
      }
    } catch {
      checks.append(
        Check(
          name: "acceptance_runtime",
          status: "fail",
          detail: String(describing: error)
        ))
    }

    let failed = checks.filter { $0.status != "pass" }
    let report = Report(
      verdict: failed.isEmpty ? "PASS" : "FAIL",
      checks: checks,
      storeRoot: root.path
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report) {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }

    if failed.isEmpty {
      try? FileManager.default.removeItem(at: root)
    }
    exit(failed.isEmpty ? 0 : 1)
  }

  private static func syntheticImage(text: String) throws -> CGImage {
    let width = 1_600
    let height = 900
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw NSError(
        domain: "RecallAcceptance",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not create synthetic CGContext."]
      )
    }

    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1))
    context.fill(CGRect(x: 80, y: 260, width: 1_440, height: 380))

    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 92, nil)
    let attributes: [CFString: Any] = [
      kCTFontAttributeName: font,
      kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
    ]
    let attributed = CFAttributedStringCreate(
      nil,
      text as CFString,
      attributes as CFDictionary
    )!
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 125, y: 430)
    CTLineDraw(line, context)

    guard let image = context.makeImage() else {
      throw NSError(
        domain: "RecallAcceptance",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Could not materialize synthetic image."]
      )
    }
    return image
  }

  private static func directoryContains(root: URL, bytes needle: Data) throws -> Bool {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
      )
    else {
      return false
    }

    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      if try Data(contentsOf: url).range(of: needle) != nil {
        return true
      }
    }
    return false
  }

  private static func rawDatabaseIsReadable(at url: URL, key: Data?) -> Bool {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
      ) == SQLITE_OK, let database
    else {
      if let database { sqlite3_close(database) }
      return false
    }
    defer { sqlite3_close(database) }

    if let key {
      let result = key.withUnsafeBytes {
        recall_sqlite_key(database, $0.baseAddress, Int32($0.count))
      }
      guard result == SQLITE_OK else { return false }
    }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT count(*) FROM sqlite_master;",
        -1,
        &statement,
        nil
      ) == SQLITE_OK, let statement
    else {
      return false
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private static func databaseFileModes(root: URL) throws -> [String: Int] {
    var modes: [String: Int] = [:]
    for name in ["recall.sqlite", "recall.sqlite-wal", "recall.sqlite-shm"] {
      let url = root.appending(path: name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      if let mode = attributes[.posixPermissions] as? NSNumber {
        modes[name] = mode.intValue
      }
    }
    return modes
  }

  private static func waitUntil(
    timeout: Duration = .seconds(5),
    condition: @escaping @Sendable () async throws -> Bool
  ) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if try await condition() { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }
}
