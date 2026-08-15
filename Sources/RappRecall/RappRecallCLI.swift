import CoreGraphics
import Darwin
import Foundation
import RecallCore

private struct ParsedArguments {
  let command: String
  let positionals: [String]
  let options: [String: [String]]

  init(_ raw: [String]) throws {
    var values = raw
    command = values.first.map { $0.hasPrefix("--") ? "daemon" : $0 } ?? "daemon"
    if values.first == command { values.removeFirst() }

    let booleanOptions = Set([
      "json", "pretty", "wait", "starred", "off", "help",
    ])
    var parsedOptions: [String: [String]] = [:]
    var parsedPositionals: [String] = []
    var index = 0
    while index < values.count {
      let value = values[index]
      guard value.hasPrefix("--") else {
        parsedPositionals.append(value)
        index += 1
        continue
      }

      let option = String(value.dropFirst(2))
      if let separator = option.firstIndex(of: "=") {
        let key = String(option[..<separator])
        let item = String(option[option.index(after: separator)...])
        parsedOptions[key, default: []].append(item)
        index += 1
      } else if booleanOptions.contains(option) {
        parsedOptions[option, default: []].append("true")
        index += 1
      } else {
        guard index + 1 < values.count else {
          throw CLIError.usage("Missing value for --\(option).")
        }
        parsedOptions[option, default: []].append(values[index + 1])
        index += 2
      }
    }
    positionals = parsedPositionals
    options = parsedOptions
  }

  func option(_ name: String) -> String? { options[name]?.last }
  func all(_ name: String) -> [String] { options[name] ?? [] }
  func flag(_ name: String) -> Bool { options[name] != nil }
}

private enum CLIError: Error, LocalizedError {
  case usage(String)
  case unavailable(String)
  case operation(String)

  var errorDescription: String? {
    switch self {
    case .usage(let message), .unavailable(let message), .operation(let message):
      message
    }
  }

  var exitCode: Int32 {
    switch self {
    case .usage: 64
    case .unavailable: 69
    case .operation: 70
    }
  }
}

private struct SuccessEnvelope<Value: Encodable>: Encodable {
  let ok = true
  let command: String
  let data: Value
}

private struct ErrorEnvelope: Encodable {
  struct Detail: Encodable {
    let code: Int32
    let message: String
  }

  let ok = false
  let command: String
  let error: Detail
}

private struct StatusResponse: Encodable {
  let root: String
  let running: Bool
  let momentCount: Int
  let runtime: RuntimeStatus?
}

private struct CommandResponse: Encodable {
  let receipt: RuntimeCommandReceipt
  let runtime: RuntimeStatus?
}

private struct PurgeResponse: Encodable {
  let removedMoments: Int
  let before: Date
}

private struct StarResponse: Encodable {
  let momentID: Int64
  let starred: Bool
}

private struct DoctorResponse: Encodable {
  let osVersion: String
  let architecture: String
  let root: String
  let rootWritable: Bool
  let screenCaptureAuthorized: Bool
  let sqliteFTS5: Bool
  let sqlCipherVersion: String
  let databaseKeyAccess: String
  let networkRequired: Bool
}

private struct DaemonStartedResponse: Encodable {
  let root: String
  let processID: Int32
  let state: RecallDaemonState
  let intervalSeconds: Double
  let excludedBundleIdentifiers: [String]
}

private struct HelpResponse: Encodable {
  let usage: String
  let commands: [String]
}

private final class DaemonFileLock {
  private var descriptor: Int32

  init(root: URL) throws {
    let path = root.appending(path: ".daemon.lock").path
    descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw CLIError.operation("Could not open daemon lock at \(path).")
    }
    Darwin.ftruncate(descriptor, 0)
    let value = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
    _ = value.withUnsafeBytes { bytes in
      Darwin.write(descriptor, bytes.baseAddress, bytes.count)
    }
    Darwin.lseek(descriptor, 0, SEEK_SET)
    guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
      Darwin.close(descriptor)
      descriptor = -1
      throw CLIError.unavailable("Another process holds the Recall daemon lock.")
    }
  }

  func release() {
    guard descriptor >= 0 else { return }
    Darwin.lseek(descriptor, 0, SEEK_SET)
    _ = Darwin.lockf(descriptor, F_ULOCK, 0)
    Darwin.close(descriptor)
    descriptor = -1
  }

  deinit {
    release()
  }
}

@main
private enum RappRecallCLI {
  static func main() async {
    let command = CommandLine.arguments.dropFirst().first ?? "daemon"
    do {
      let arguments = try ParsedArguments(Array(CommandLine.arguments.dropFirst()))
      if arguments.flag("help") || arguments.command == "help" {
        emitSuccess(command: "help", data: help(), pretty: true)
        return
      }

      switch arguments.command {
      case "daemon":
        try await runDaemon(arguments)
      case "status":
        try await status(arguments)
      case "pause":
        try await send(.pause, arguments: arguments)
      case "resume":
        try await send(.resume, arguments: arguments)
      case "stop":
        try await send(.stop, arguments: arguments)
      case "search":
        try await search(arguments, requireQuery: true)
      case "recent":
        try await search(arguments, requireQuery: false)
      case "star":
        try await star(arguments)
      case "purge":
        try await purge(arguments)
      case "doctor":
        try await doctor(arguments)
      case "acceptance":
        try runAcceptance()
      default:
        throw CLIError.usage("Unknown command: \(arguments.command).")
      }
    } catch let error as CLIError {
      emitError(
        command: command,
        code: error.exitCode,
        message: error.localizedDescription
      )
      exit(error.exitCode)
    } catch {
      emitError(command: command, code: 70, message: error.localizedDescription)
      exit(70)
    }
  }

  private static func runDaemon(_ arguments: ParsedArguments) async throws {
    let root = rootURL(arguments)
    let store = try RecallStore(rootURL: root)
    let daemonLock = try DaemonFileLock(root: root)
    defer { daemonLock.release() }
    if let existing = try await store.runtimeStatus(),
      [.starting, .recording, .paused, .stopping].contains(existing.state),
      processExists(existing.processID)
    {
      throw CLIError.unavailable(
        "A Recall daemon is already running with PID \(existing.processID)."
      )
    }

    let interval = try positiveDouble(arguments.option("interval") ?? "2", name: "interval")
    let defaultExcluded: Set<String> = [
      "com.1password.1password",
      "com.bitwarden.desktop",
      "com.apple.keychainaccess",
    ]
    let excluded = defaultExcluded.union(arguments.all("exclude-bundle"))
    let policy = ExclusionPolicy(excludedBundleIdentifiers: excluded)
    let source = ScreenCaptureFrameSource(
      interval: interval,
      excludedBundleIdentifiers: excluded
    )
    let pipeline = CapturePipeline(
      policy: policy,
      encoder: HEIFFrameEncoder(),
      textExtractor: VisionTextExtractor(),
      repository: store
    )
    let daemon = RecallDaemon(source: source, pipeline: pipeline, store: store)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interrupt.setEventHandler { Task { await daemon.requestStop() } }
    terminate.setEventHandler { Task { await daemon.requestStop() } }
    interrupt.resume()
    terminate.resume()

    let runTask = Task {
      try await daemon.run()
    }

    var started: RuntimeStatus?
    for _ in 0..<200 {
      if let current = try await store.runtimeStatus() {
        if current.state == .recording || current.state == .failed {
          started = current
          break
        }
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard let started else {
      await daemon.requestStop()
      throw CLIError.operation("Daemon did not reach a reportable state within five seconds.")
    }
    guard started.state == .recording else {
      _ = try? await runTask.value
      throw CLIError.operation(started.lastError ?? "Capture failed during startup.")
    }

    emitSuccess(
      command: "daemon",
      data: DaemonStartedResponse(
        root: root.path,
        processID: started.processID,
        state: started.state,
        intervalSeconds: interval,
        excludedBundleIdentifiers: excluded.sorted()
      ),
      pretty: arguments.flag("pretty")
    )
    try await runTask.value
  }

  private static func status(_ arguments: ParsedArguments) async throws {
    let root = rootURL(arguments)
    let store = try RecallStore(rootURL: root)
    let runtime = try await store.runtimeStatus()
    let running =
      runtime.map {
        [.starting, .recording, .paused, .stopping].contains($0.state)
          && processExists($0.processID)
      } ?? false
    emitSuccess(
      command: "status",
      data: StatusResponse(
        root: root.path,
        running: running,
        momentCount: try await store.momentCount(),
        runtime: runtime
      ),
      pretty: arguments.flag("pretty")
    )
  }

  private static func send(
    _ kind: RuntimeCommandKind,
    arguments: ParsedArguments
  ) async throws {
    let store = try RecallStore(rootURL: rootURL(arguments))
    guard let current = try await store.runtimeStatus(),
      [.starting, .recording, .paused, .stopping].contains(current.state),
      processExists(current.processID)
    else {
      throw CLIError.unavailable("No live Recall daemon is available.")
    }

    let id = try await store.enqueueRuntimeCommand(kind)
    if !arguments.flag("wait") {
      guard let receipt = try await store.runtimeCommandReceipt(id) else {
        throw CLIError.operation("Command \(id) disappeared after enqueue.")
      }
      emitSuccess(
        command: kind.rawValue,
        data: CommandResponse(receipt: receipt, runtime: current),
        pretty: arguments.flag("pretty")
      )
      return
    }

    let timeout = try positiveDouble(
      arguments.option("timeout") ?? "15",
      name: "timeout"
    )
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while clock.now < deadline {
      if let receipt = try await store.runtimeCommandReceipt(id), receipt.processed {
        if let error = receipt.error {
          throw CLIError.operation(error)
        }
        emitSuccess(
          command: kind.rawValue,
          data: CommandResponse(
            receipt: receipt,
            runtime: try await store.runtimeStatus()
          ),
          pretty: arguments.flag("pretty")
        )
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw CLIError.unavailable("Timed out waiting for command \(id) to complete.")
  }

  private static func search(
    _ arguments: ParsedArguments,
    requireQuery: Bool
  ) async throws {
    let query = arguments.positionals.joined(separator: " ")
    if requireQuery && query.isEmpty {
      throw CLIError.usage("search requires a query.")
    }
    let limit = try positiveInt(arguments.option("limit") ?? "200", name: "limit")
    let store = try RecallStore(rootURL: rootURL(arguments))
    let moments = try await store.search(
      SearchRequest(
        text: query,
        application: arguments.option("app"),
        starredOnly: arguments.flag("starred"),
        limit: limit
      ))
    emitSuccess(
      command: requireQuery ? "search" : "recent",
      data: moments,
      pretty: arguments.flag("pretty")
    )
  }

  private static func star(_ arguments: ParsedArguments) async throws {
    guard let rawID = arguments.positionals.first, let id = Int64(rawID) else {
      throw CLIError.usage("star requires a numeric moment ID.")
    }
    let starred = !arguments.flag("off")
    let store = try RecallStore(rootURL: rootURL(arguments))
    try await store.setStarred(starred, momentID: id)
    emitSuccess(
      command: "star",
      data: StarResponse(momentID: id, starred: starred),
      pretty: arguments.flag("pretty")
    )
  }

  private static func purge(_ arguments: ParsedArguments) async throws {
    guard let value = arguments.option("before") else {
      throw CLIError.usage("purge requires --before <ISO-8601>.")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date =
      formatter.date(from: value)
      ?? ISO8601DateFormatter().date(from: value)
    guard let date else {
      throw CLIError.usage("Invalid ISO-8601 date: \(value).")
    }
    let store = try RecallStore(rootURL: rootURL(arguments))
    let removed = try await store.purge(before: date)
    emitSuccess(
      command: "purge",
      data: PurgeResponse(removedMoments: removed, before: date),
      pretty: arguments.flag("pretty")
    )
  }

  private static func doctor(_ arguments: ParsedArguments) async throws {
    let root = rootURL(arguments)
    let store = try RecallStore(rootURL: root)
    let probe = root.appending(path: ".doctor-\(UUID().uuidString)")
    let rootWritable: Bool
    do {
      try Data("probe".utf8).write(to: probe, options: .atomic)
      try FileManager.default.removeItem(at: probe)
      rootWritable = true
    } catch {
      rootWritable = false
    }

    _ = try await store.search(SearchRequest(text: "fts-doctor-probe", limit: 1))
    let architecture = ProcessInfo.processInfo.machineArchitecture
    emitSuccess(
      command: "doctor",
      data: DoctorResponse(
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: architecture,
        root: root.path,
        rootWritable: rootWritable,
        screenCaptureAuthorized: CGPreflightScreenCaptureAccess(),
        sqliteFTS5: true,
        sqlCipherVersion: try await store.cipherVersion(),
        databaseKeyAccess: DatabaseKeyProvider.accessMode,
        networkRequired: false
      ),
      pretty: arguments.flag("pretty")
    )
  }

  private static func runAcceptance() throws {
    let ownURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidates = [
      ownURL.deletingLastPathComponent().appending(path: "RecallAcceptance"),
      ownURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "RecallAcceptance"),
    ]
    guard
      let executable = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    else {
      throw CLIError.unavailable(
        "RecallAcceptance is not beside the CLI. Run `swift build` or use the packaged app."
      )
    }
    let process = Process()
    process.executableURL = executable
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
  }

  private static func rootURL(_ arguments: ParsedArguments) -> URL {
    guard let path = arguments.option("root") else { return RecallPaths.defaultRoot }
    let expanded = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
  }

  private static func processExists(_ processID: Int32) -> Bool {
    guard processID > 0 else { return false }
    return kill(processID, 0) == 0 || errno == EPERM
  }

  private static func positiveDouble(_ value: String, name: String) throws -> Double {
    guard let parsed = Double(value), parsed > 0, parsed.isFinite else {
      throw CLIError.usage("--\(name) must be a positive number.")
    }
    return parsed
  }

  private static func positiveInt(_ value: String, name: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0 else {
      throw CLIError.usage("--\(name) must be a positive integer.")
    }
    return parsed
  }

  private static func emitSuccess<T: Encodable>(
    command: String,
    data: T,
    pretty: Bool
  ) {
    emit(SuccessEnvelope(command: command, data: data), to: .standardOutput, pretty: pretty)
  }

  private static func emitError(command: String, code: Int32, message: String) {
    emit(
      ErrorEnvelope(
        command: command,
        error: .init(code: code, message: message)
      ),
      to: .standardError,
      pretty: false
    )
  }

  private static func emit<T: Encodable>(
    _ value: T,
    to handle: FileHandle,
    pretty: Bool
  ) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting =
      pretty
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) {
      handle.write(data)
      handle.write(Data("\n".utf8))
    }
  }

  private static func help() -> HelpResponse {
    HelpResponse(
      usage: "rapp-recall <command> [options]",
      commands: [
        "daemon [--root PATH] [--interval 2] [--exclude-bundle ID]",
        "status [--root PATH]",
        "pause|resume|stop [--root PATH] [--wait] [--timeout 15]",
        "search <query> [--app NAME_OR_ID] [--starred] [--limit 200]",
        "recent [--app NAME_OR_ID] [--starred] [--limit 200]",
        "star <moment-id> [--off]",
        "purge --before <ISO-8601>",
        "doctor",
        "acceptance",
      ]
    )
  }
}

extension ProcessInfo {
  fileprivate var machineArchitecture: String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(cString: $0)
      }
    }
  }
}
