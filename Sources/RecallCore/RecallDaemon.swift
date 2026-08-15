import Foundation

public enum RecallPaths {
  public static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support", directoryHint: .isDirectory)
      .appending(path: "ai.rapp.recall", directoryHint: .isDirectory)
  }
}

public actor RecallDaemon {
  private let source: any FrameSource
  private let pipeline: CapturePipeline
  private let store: RecallStore
  private var status: RuntimeStatus
  private var sourceRunning = false
  private var processingFrame = false
  private var shuttingDown = false
  private var finished = false
  private var stopContinuation: CheckedContinuation<Void, Never>?
  private var commandTask: Task<Void, Never>?

  public init(
    source: any FrameSource,
    pipeline: CapturePipeline,
    store: RecallStore,
    processID: Int32 = ProcessInfo.processInfo.processIdentifier
  ) {
    self.source = source
    self.pipeline = pipeline
    self.store = store
    self.status = RuntimeStatus(
      processID: processID,
      state: .starting,
      startedAt: Date()
    )
  }

  public func run() async throws {
    try await store.abandonPendingRuntimeCommands(
      reason: "daemon restarted before command processing"
    )
    try await persistStatus()
    do {
      try await startSource()
      status.state = .recording
      try await persistStatus()
    } catch {
      status.state = .failed
      status.lastError = error.localizedDescription
      try? await persistStatus()
      throw error
    }

    commandTask = Task { [weak self] in
      await self?.commandLoop()
    }

    await withCheckedContinuation { continuation in
      if finished {
        continuation.resume()
      } else {
        stopContinuation = continuation
      }
    }
  }

  public func requestStop() async {
    await shutdown()
  }

  private func startSource() async throws {
    try await source.start { [weak self] event in
      Task { await self?.receive(event) }
    }
    sourceRunning = true
  }

  private func receive(_ event: FrameSourceEvent) async {
    switch event {
    case .failure(let message):
      await fail(message)
    case .frame(let frame):
      guard status.state == .recording, !shuttingDown else { return }
      guard !processingFrame else {
        status.droppedFrames += 1
        try? await persistStatus()
        return
      }

      processingFrame = true
      defer { processingFrame = false }
      do {
        let outcome = try await pipeline.process(frame)
        status.lastCaptureAt = frame.capturedAt
        switch outcome {
        case .stored:
          status.storedFrames += 1
        case .excluded:
          status.excludedFrames += 1
        case .duplicate:
          status.duplicateFrames += 1
        }
        try await persistStatus()
      } catch {
        // This receive invocation owns the in-flight marker. Calling
        // shutdown while it is still true would make shutdown wait for
        // this same invocation forever.
        processingFrame = false
        await fail(error.localizedDescription)
      }
    }
  }

  private func commandLoop() async {
    while !shuttingDown {
      do {
        if let command = try await store.nextRuntimeCommand() {
          await process(command)
        } else {
          try await Task.sleep(for: .milliseconds(100))
        }
      } catch is CancellationError {
        return
      } catch {
        await fail(error.localizedDescription)
        return
      }
    }
  }

  private func process(_ command: RuntimeCommand) async {
    do {
      switch command.kind {
      case .pause:
        if status.state == .recording {
          status.state = .paused
          try await persistStatus()
          if sourceRunning {
            try await source.stop()
            sourceRunning = false
          }
          // A frame may already be inside Vision/store when pause is
          // requested. The command is not complete until it drains;
          // otherwise a successful pause can be followed by a write.
          await drainInFlightFrame()
          try await persistStatus()
        }
      case .resume:
        if status.state == .paused {
          try await startSource()
          status.state = .recording
          try await persistStatus()
        }
      case .stop:
        status.state = .stopping
        try await persistStatus()
        if sourceRunning {
          try await source.stop()
          sourceRunning = false
        }
        await drainInFlightFrame()
        await shutdown()
        try await store.completeRuntimeCommand(command.id, error: nil)
        return
      }
      try await store.completeRuntimeCommand(command.id, error: nil)
    } catch {
      try? await store.completeRuntimeCommand(
        command.id,
        error: error.localizedDescription
      )
      await fail(error.localizedDescription)
    }
  }

  private func fail(_ message: String) async {
    guard !shuttingDown else { return }
    status.state = .failed
    status.lastError = message
    try? await persistStatus()
    await shutdown(finalState: .failed)
  }

  private func shutdown(finalState: RecallDaemonState = .stopped) async {
    guard !shuttingDown else { return }
    shuttingDown = true
    status.state = finalState == .failed ? .failed : .stopping
    try? await persistStatus()

    if sourceRunning {
      try? await source.stop()
      sourceRunning = false
    }
    await drainInFlightFrame()

    status.state = finalState
    try? await persistStatus()
    commandTask?.cancel()
    commandTask = nil
    finished = true
    stopContinuation?.resume()
    stopContinuation = nil
  }

  private func drainInFlightFrame() async {
    while processingFrame {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func persistStatus() async throws {
    status.updatedAt = Date()
    try await store.setRuntimeStatus(status)
  }
}
