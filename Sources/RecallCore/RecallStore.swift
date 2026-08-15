import CSQLite
import Foundation

public enum RecallStoreError: Error, LocalizedError {
  case sqlite(String)
  case invalidMediaPath(String)
  case unsupportedImageFormat(String)
  case momentNotFound(Int64)
  case sqlCipherUnavailable
  case databaseUnreadable

  public var errorDescription: String? {
    switch self {
    case .sqlite(let message):
      "SQLite error: \(message)"
    case .invalidMediaPath(let path):
      "Media path escapes the Recall store: \(path)"
    case .unsupportedImageFormat(let format):
      "Unsupported image format: \(format)"
    case .momentNotFound(let id):
      "Moment \(id) does not exist."
    case .sqlCipherUnavailable:
      "The linked SQLite library does not provide SQLCipher."
    case .databaseUnreadable:
      "The database key does not match, or the encrypted database is corrupted."
    }
  }
}

public actor RecallStore {
  public let rootURL: URL
  private let databaseURL: URL
  // SQLite access remains actor-isolated. `nonisolated(unsafe)` is needed
  // only so deinit can close the C handle under Swift 6's Sendable checks.
  nonisolated(unsafe) private var database: OpaquePointer?
  private let fileManager: FileManager
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  public init(
    rootURL: URL,
    fileManager: FileManager = .default,
    databaseKey: Data? = nil
  ) throws {
    self.rootURL = rootURL.standardizedFileURL
    self.databaseURL = rootURL.appending(path: "recall.sqlite", directoryHint: .notDirectory)
    self.fileManager = fileManager
    let key = try databaseKey ?? DatabaseKeyProvider.loadOrCreate()
    guard key.count == 32 else {
      throw DatabaseKeyError.invalidKeyLength(key.count)
    }

    try Self.prepareDirectory(rootURL, fileManager: fileManager)

    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
      let handle
    else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
      if let handle { sqlite3_close(handle) }
      throw RecallStoreError.sqlite(message)
    }
    database = handle

    do {
      let keyResult = key.withUnsafeBytes {
        recall_sqlite_key(handle, $0.baseAddress, Int32($0.count))
      }
      guard keyResult == SQLITE_OK else {
        throw RecallStoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
      }
      guard
        let version = try Self.scalarText(
          "PRAGMA cipher_version;",
          on: handle
        ), !version.isEmpty
      else {
        throw RecallStoreError.sqlCipherUnavailable
      }
      sqlite3_busy_timeout(handle, 5_000)
      try Self.execute("PRAGMA journal_mode = WAL;", on: handle)
      try Self.execute("PRAGMA foreign_keys = ON;", on: handle)
      try Self.execute("PRAGMA synchronous = FULL;", on: handle)
      try Self.execute(Self.schema, on: handle)
      try Self.hardenDatabaseFiles(databaseURL, fileManager: fileManager)
    } catch {
      let mappedError: Error =
        sqlite3_errcode(handle) == SQLITE_NOTADB
        ? RecallStoreError.databaseUnreadable
        : error
      sqlite3_close(handle)
      database = nil
      throw mappedError
    }

    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: databaseURL.path
    )
  }

  deinit {
    if let database {
      sqlite3_close(database)
    }
  }

  @discardableResult
  public func add(_ draft: MomentDraft) throws -> Moment {
    let format = draft.frame.imageFormat.lowercased()
    guard ["heic", "heif", "png", "jpg", "jpeg"].contains(format) else {
      throw RecallStoreError.unsupportedImageFormat(format)
    }

    let mediaURL = try makeMediaURL(
      capturedAt: draft.frame.capturedAt,
      extension: format
    )
    do {
      try draft.frame.imageData.write(to: mediaURL, options: [.atomic])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: mediaURL.path
      )
    } catch {
      throw error
    }

    do {
      let id = try insert(draft, mediaURL: mediaURL)
      return Moment(
        id: id,
        capturedAt: draft.frame.capturedAt,
        applicationName: draft.frame.context.applicationName,
        bundleIdentifier: draft.frame.context.bundleIdentifier,
        windowTitle: draft.frame.context.windowTitle,
        mediaURL: mediaURL,
        recognizedText: draft.recognizedText,
        width: draft.frame.width,
        height: draft.frame.height,
        starred: false
      )
    } catch {
      try? fileManager.removeItem(at: mediaURL)
      throw error
    }
  }

  public func search(_ request: SearchRequest) throws -> [Moment] {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }

    let boundedLimit = min(max(request.limit, 1), 1_000)
    let trimmedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasText = !trimmedText.isEmpty
    let matchExpression = hasText ? Self.ftsExpression(trimmedText) : ""
    // A query made only of quote delimiters has no searchable term.
    // Returning no matches is a user-level result; MATCH '' is an internal
    // FTS syntax error and must never escape as an operation failure.
    if hasText && matchExpression.isEmpty {
      return []
    }
    var clauses: [String] = []
    var bindings: [String] = []

    if hasText {
      clauses.append("moments_fts MATCH ?")
      bindings.append(matchExpression)
    }
    if let application = request.application, !application.isEmpty {
      clauses.append("(m.application_name = ? COLLATE NOCASE OR m.bundle_id = ?)")
      bindings.append(application)
      bindings.append(application)
    }
    if request.starredOnly {
      clauses.append("m.starred = 1")
    }

    let from =
      hasText
      ? "moments_fts JOIN moments m ON m.id = moments_fts.rowid"
      : "moments m"
    let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
    let sql = """
      SELECT m.id, m.captured_at, m.application_name, m.bundle_id,
             m.window_title, m.media_path, m.ocr_text, m.width, m.height, m.starred
        FROM \(from)\(whereSQL)
       ORDER BY m.captured_at DESC
       LIMIT \(boundedLimit);
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }

    for (offset, value) in bindings.enumerated() {
      guard
        sqlite3_bind_text(
          statement,
          Int32(offset + 1),
          value,
          -1,
          Self.transient
        ) == SQLITE_OK
      else {
        throw sqliteError()
      }
    }

    var moments: [Moment] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      moments.append(try moment(from: statement))
    }
    let result = sqlite3_errcode(database)
    guard result == SQLITE_OK || result == SQLITE_DONE else {
      throw sqliteError()
    }
    return moments
  }

  public func setStarred(_ starred: Bool, momentID: Int64) throws {
    try executeMutation(
      "UPDATE moments SET starred = ? WHERE id = ?;",
      integers: [starred ? 1 : 0, momentID]
    )
    guard let database, sqlite3_changes(database) == 1 else {
      throw RecallStoreError.momentNotFound(momentID)
    }
  }

  @discardableResult
  public func purge(before cutoff: Date) throws -> Int {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    let rows = try mediaRows(before: cutoff)
    guard !rows.isEmpty else { return 0 }

    let trashRoot = rootURL.appending(path: ".trash", directoryHint: .isDirectory)
    try Self.prepareDirectory(trashRoot, fileManager: fileManager)
    var moved: [(original: URL, trash: URL)] = []

    do {
      for row in rows {
        let original = try validatedMediaURL(row.path)
        guard fileManager.fileExists(atPath: original.path) else { continue }
        let trash = trashRoot.appending(
          path: "\(row.id)-\(UUID().uuidString).trash",
          directoryHint: .notDirectory
        )
        try fileManager.moveItem(at: original, to: trash)
        moved.append((original, trash))
      }

      try Self.execute("BEGIN IMMEDIATE;", on: database)
      do {
        var statement: OpaquePointer?
        let sql = "DELETE FROM moments WHERE captured_at < ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
        else {
          throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
          throw sqliteError()
        }
        let deleted = Int(sqlite3_changes(database))
        try Self.execute("COMMIT;", on: database)
        for item in moved {
          try? fileManager.removeItem(at: item.trash)
        }
        return deleted
      } catch {
        try? Self.execute("ROLLBACK;", on: database)
        throw error
      }
    } catch {
      for item in moved.reversed() where fileManager.fileExists(atPath: item.trash.path) {
        try? Self.prepareDirectory(
          item.original.deletingLastPathComponent(),
          fileManager: fileManager
        )
        try? fileManager.moveItem(at: item.trash, to: item.original)
      }
      throw error
    }
  }

  public func momentCount() throws -> Int {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM moments;", -1, &statement, nil)
        == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  public func cipherVersion() throws -> String {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    guard let version = try Self.scalarText("PRAGMA cipher_version;", on: database),
      !version.isEmpty
    else {
      throw RecallStoreError.sqlCipherUnavailable
    }
    return version
  }

  public func setRuntimeStatus(_ status: RuntimeStatus) throws {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    let sql = """
      INSERT INTO runtime_state(
          singleton, process_id, state, started_at, last_capture_at,
          stored_frames, excluded_frames, duplicate_frames, dropped_frames,
          last_error, updated_at
      ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(singleton) DO UPDATE SET
          process_id = excluded.process_id,
          state = excluded.state,
          started_at = excluded.started_at,
          last_capture_at = excluded.last_capture_at,
          stored_frames = excluded.stored_frames,
          excluded_frames = excluded.excluded_frames,
          duplicate_frames = excluded.duplicate_frames,
          dropped_frames = excluded.dropped_frames,
          last_error = excluded.last_error,
          updated_at = excluded.updated_at;
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_int(statement, 1, status.processID)
    try bind(status.state.rawValue, at: 2, to: statement)
    sqlite3_bind_double(statement, 3, status.startedAt.timeIntervalSince1970)
    if let lastCaptureAt = status.lastCaptureAt {
      sqlite3_bind_double(statement, 4, lastCaptureAt.timeIntervalSince1970)
    } else {
      sqlite3_bind_null(statement, 4)
    }
    sqlite3_bind_int64(statement, 5, Int64(status.storedFrames))
    sqlite3_bind_int64(statement, 6, Int64(status.excludedFrames))
    sqlite3_bind_int64(statement, 7, Int64(status.duplicateFrames))
    sqlite3_bind_int64(statement, 8, Int64(status.droppedFrames))
    try bindOptional(status.lastError, at: 9, to: statement)
    sqlite3_bind_double(statement, 10, status.updatedAt.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
  }

  public func runtimeStatus() throws -> RuntimeStatus? {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    let sql = """
      SELECT process_id, state, started_at, last_capture_at,
             stored_frames, excluded_frames, duplicate_frames, dropped_frames,
             last_error, updated_at
        FROM runtime_state WHERE singleton = 1;
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let state = RecallDaemonState(rawValue: stringColumn(statement, 1)) else {
      throw RecallStoreError.sqlite("runtime_state contains an unknown state")
    }
    return RuntimeStatus(
      processID: sqlite3_column_int(statement, 0),
      state: state,
      startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      lastCaptureAt: sqlite3_column_type(statement, 3) == SQLITE_NULL
        ? nil
        : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
      storedFrames: Int(sqlite3_column_int64(statement, 4)),
      excludedFrames: Int(sqlite3_column_int64(statement, 5)),
      duplicateFrames: Int(sqlite3_column_int64(statement, 6)),
      droppedFrames: Int(sqlite3_column_int64(statement, 7)),
      lastError: optionalStringColumn(statement, 8),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
    )
  }

  @discardableResult
  public func enqueueRuntimeCommand(_ kind: RuntimeCommandKind) throws -> Int64 {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    var statement: OpaquePointer?
    let sql = "INSERT INTO runtime_commands(kind, requested_at) VALUES (?, ?);"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    try bind(kind.rawValue, at: 1, to: statement)
    sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    return sqlite3_last_insert_rowid(database)
  }

  public func nextRuntimeCommand() throws -> RuntimeCommand? {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    var statement: OpaquePointer?
    let sql = """
      SELECT id, kind, requested_at
        FROM runtime_commands
       WHERE processed_at IS NULL
       ORDER BY id
       LIMIT 1;
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let kindText = stringColumn(statement, 1)
    guard let kind = RuntimeCommandKind(rawValue: kindText) else {
      throw RecallStoreError.sqlite("unknown runtime command: \(kindText)")
    }
    return RuntimeCommand(
      id: sqlite3_column_int64(statement, 0),
      kind: kind,
      requestedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
    )
  }

  public func completeRuntimeCommand(_ id: Int64, error: String?) throws {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    var statement: OpaquePointer?
    let sql = "UPDATE runtime_commands SET processed_at = ?, error = ? WHERE id = ?;"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
    try bindOptional(error, at: 2, to: statement)
    sqlite3_bind_int64(statement, 3, id)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
  }

  public func runtimeCommandReceipt(_ id: Int64) throws -> RuntimeCommandReceipt? {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    var statement: OpaquePointer?
    let sql = """
      SELECT kind, requested_at, processed_at, error
        FROM runtime_commands WHERE id = ?;
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, id)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let kindText = stringColumn(statement, 0)
    guard let kind = RuntimeCommandKind(rawValue: kindText) else {
      throw RecallStoreError.sqlite("unknown runtime command: \(kindText)")
    }
    return RuntimeCommandReceipt(
      id: id,
      kind: kind,
      requestedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
      processedAt: sqlite3_column_type(statement, 2) == SQLITE_NULL
        ? nil
        : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      error: optionalStringColumn(statement, 3)
    )
  }

  @discardableResult
  public func abandonPendingRuntimeCommands(reason: String) throws -> Int {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    var statement: OpaquePointer?
    let sql = """
      UPDATE runtime_commands
         SET processed_at = ?, error = ?
       WHERE processed_at IS NULL;
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
    try bind(reason, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    return Int(sqlite3_changes(database))
  }

  private func insert(_ draft: MomentDraft, mediaURL: URL) throws -> Int64 {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    let sql = """
      INSERT INTO moments(
          captured_at, application_name, bundle_id, window_title,
          media_path, ocr_text, frame_hash, width, height
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_double(statement, 1, draft.frame.capturedAt.timeIntervalSince1970)
    try bind(draft.frame.context.applicationName, at: 2, to: statement)
    try bindOptional(draft.frame.context.bundleIdentifier, at: 3, to: statement)
    try bindOptional(draft.frame.context.windowTitle, at: 4, to: statement)
    try bind(mediaURL.path, at: 5, to: statement)
    try bind(draft.recognizedText, at: 6, to: statement)
    try bind(draft.frameHash, at: 7, to: statement)
    sqlite3_bind_int64(statement, 8, Int64(draft.frame.width))
    sqlite3_bind_int64(statement, 9, Int64(draft.frame.height))

    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    return sqlite3_last_insert_rowid(database)
  }

  private func moment(from statement: OpaquePointer) throws -> Moment {
    let path = stringColumn(statement, 5)
    let mediaURL = try validatedMediaURL(path)
    return Moment(
      id: sqlite3_column_int64(statement, 0),
      capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
      applicationName: stringColumn(statement, 2),
      bundleIdentifier: optionalStringColumn(statement, 3),
      windowTitle: optionalStringColumn(statement, 4),
      mediaURL: mediaURL,
      recognizedText: stringColumn(statement, 6),
      width: Int(sqlite3_column_int64(statement, 7)),
      height: Int(sqlite3_column_int64(statement, 8)),
      starred: sqlite3_column_int(statement, 9) == 1
    )
  }

  private func mediaRows(before cutoff: Date) throws -> [(id: Int64, path: String)] {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    var statement: OpaquePointer?
    let sql = "SELECT id, media_path FROM moments WHERE captured_at < ?;"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)

    var rows: [(Int64, String)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      rows.append((sqlite3_column_int64(statement, 0), stringColumn(statement, 1)))
    }
    return rows
  }

  private func makeMediaURL(capturedAt: Date, extension format: String) throws -> URL {
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents(in: .current, from: capturedAt)
    let mediaDirectory =
      rootURL
      .appending(path: "media", directoryHint: .isDirectory)
      .appending(path: String(format: "%04d", components.year ?? 0), directoryHint: .isDirectory)
      .appending(path: String(format: "%02d", components.month ?? 0), directoryHint: .isDirectory)
      .appending(path: String(format: "%02d", components.day ?? 0), directoryHint: .isDirectory)
    try Self.prepareDirectory(mediaDirectory, fileManager: fileManager)

    let milliseconds = Int64(capturedAt.timeIntervalSince1970 * 1_000)
    return mediaDirectory.appending(
      path: "\(milliseconds)-\(UUID().uuidString).\(format)",
      directoryHint: .notDirectory
    )
  }

  private func validatedMediaURL(_ path: String) throws -> URL {
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    guard candidate.path.hasPrefix(rootPath) else {
      throw RecallStoreError.invalidMediaPath(path)
    }
    return candidate
  }

  private func executeMutation(_ sql: String, integers: [Int64]) throws {
    guard let database else { throw RecallStoreError.sqlite("database is closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw sqliteError()
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in integers.enumerated() {
      sqlite3_bind_int64(statement, Int32(offset + 1), value)
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
  }

  private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
    guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else {
      throw sqliteError()
    }
  }

  private func bindOptional(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
    if let value {
      try bind(value, at: index, to: statement)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func stringColumn(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
  }

  private func optionalStringColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return stringColumn(statement, index)
  }

  private func sqliteError() -> RecallStoreError {
    guard let database else { return .sqlite("database is closed") }
    return .sqlite(String(cString: sqlite3_errmsg(database)))
  }

  private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private static func hardenDatabaseFiles(
    _ databaseURL: URL,
    fileManager: FileManager
  ) throws {
    for suffix in ["", "-wal", "-shm"] {
      let path = databaseURL.path + suffix
      guard fileManager.fileExists(atPath: path) else { continue }
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
  }

  private static func execute(_ sql: String, on database: OpaquePointer) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
      sqlite3_free(errorMessage)
      throw RecallStoreError.sqlite(message)
    }
  }

  private static func scalarText(
    _ sql: String,
    on database: OpaquePointer
  ) throws -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw RecallStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let value = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: value)
  }

  private static func ftsExpression(_ input: String) -> String {
    var terms: [String] = []
    var current = ""
    var insideQuote = false

    for character in input {
      if character == "\"" {
        if insideQuote, !current.isEmpty {
          terms.append(current)
          current = ""
        } else if !insideQuote, !current.trimmingCharacters(in: .whitespaces).isEmpty {
          terms.append(contentsOf: current.split(whereSeparator: \.isWhitespace).map(String.init))
          current = ""
        }
        insideQuote.toggle()
      } else if character.isWhitespace, !insideQuote {
        if !current.isEmpty {
          terms.append(current)
          current = ""
        }
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { terms.append(current) }

    return
      terms
      .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
      .joined(separator: " OR ")
  }

  private static let schema = """
    CREATE TABLE IF NOT EXISTS moments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        captured_at REAL NOT NULL,
        application_name TEXT NOT NULL,
        bundle_id TEXT,
        window_title TEXT,
        media_path TEXT NOT NULL UNIQUE,
        ocr_text TEXT NOT NULL,
        frame_hash TEXT NOT NULL,
        width INTEGER NOT NULL CHECK(width > 0),
        height INTEGER NOT NULL CHECK(height > 0),
        starred INTEGER NOT NULL DEFAULT 0 CHECK(starred IN (0, 1))
    );

    CREATE INDEX IF NOT EXISTS moments_captured_at
        ON moments(captured_at DESC);
    CREATE INDEX IF NOT EXISTS moments_application
        ON moments(application_name, captured_at DESC);
    CREATE INDEX IF NOT EXISTS moments_frame_hash
        ON moments(frame_hash);

    CREATE VIRTUAL TABLE IF NOT EXISTS moments_fts USING fts5(
        ocr_text,
        application_name,
        window_title,
        content='moments',
        content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER IF NOT EXISTS moments_after_insert AFTER INSERT ON moments BEGIN
        INSERT INTO moments_fts(rowid, ocr_text, application_name, window_title)
        VALUES (new.id, new.ocr_text, new.application_name, coalesce(new.window_title, ''));
    END;

    CREATE TRIGGER IF NOT EXISTS moments_after_delete AFTER DELETE ON moments BEGIN
        INSERT INTO moments_fts(moments_fts, rowid, ocr_text, application_name, window_title)
        VALUES ('delete', old.id, old.ocr_text, old.application_name, coalesce(old.window_title, ''));
    END;

    CREATE TRIGGER IF NOT EXISTS moments_after_update AFTER UPDATE ON moments BEGIN
        INSERT INTO moments_fts(moments_fts, rowid, ocr_text, application_name, window_title)
        VALUES ('delete', old.id, old.ocr_text, old.application_name, coalesce(old.window_title, ''));
        INSERT INTO moments_fts(rowid, ocr_text, application_name, window_title)
        VALUES (new.id, new.ocr_text, new.application_name, coalesce(new.window_title, ''));
    END;

    CREATE TABLE IF NOT EXISTS runtime_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
        process_id INTEGER NOT NULL,
        state TEXT NOT NULL,
        started_at REAL NOT NULL,
        last_capture_at REAL,
        stored_frames INTEGER NOT NULL,
        excluded_frames INTEGER NOT NULL,
        duplicate_frames INTEGER NOT NULL,
        dropped_frames INTEGER NOT NULL,
        last_error TEXT,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS runtime_commands (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL CHECK(kind IN ('pause', 'resume', 'stop')),
        requested_at REAL NOT NULL,
        processed_at REAL,
        error TEXT
    );
    """
}
