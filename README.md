# Rapp Recall

A clean-room, local-first screen memory for macOS.

Rapp Recall continuously captures the display at a low frame rate, recognizes
visible text with Apple's Vision framework, and stores a searchable timeline on
your Mac. It has no account requirement and no core-path network dependency.

> **Status:** first vertical slice under construction. The repository is public
> early so the privacy boundary and acceptance evidence can be reviewed before
> users entrust it with real screens.

## Non-negotiable properties

- **Local-first:** screen media and OCR stay on the Mac.
- **Encrypted search history:** SQLCipher encrypts SQLite/FTS with a random
  256-bit key held in macOS Keychain.
- **Exclude before persistence:** blocked apps/windows never reach media,
  SQLite, logs, or temporary files.
- **Pause means pause:** the capture pipeline has one visible state authority.
- **Auditable:** no analytics SDK, updater, account client, or networking
  framework in the core application.
- **Clean-room:** behavior was inferred from user-facing documentation and
  file/format metadata. No proprietary source, assets, or decrypted user data.

## Headless control

The recorder is a foreground daemon. A supervisor (Terminal, launchd, or a
service manager) decides whether it is detached. Every command emits JSON.

```bash
# Terminal 1
rapp-recall daemon --interval 2

# Terminal 2
rapp-recall status --pretty
rapp-recall pause --wait
rapp-recall resume --wait
rapp-recall search '"project nebula"' --app com.apple.Notes --pretty
rapp-recall recent --limit 20
rapp-recall star 42
rapp-recall purge --before 2026-01-01T00:00:00Z
rapp-recall stop --wait
```

Run `rapp-recall acceptance` for the deterministic end-to-end suite. An
unobserved assertion is a failure, never a pass.

See [`docs/cli.md`](docs/cli.md) for schemas and exit behavior.
See [`docs/evidence.md`](docs/evidence.md) for measured acceptance results and
the explicit security boundary.

## Build

Requires macOS 14 or newer and the Apple command-line developer tools.

```bash
swift build
swift run RecallAcceptance
./scripts/build-app.sh
build/RappRecall.app/Contents/MacOS/RappRecall doctor --pretty
```

Launching `RappRecall.app` starts the daemon with the default store at
`~/Library/Application Support/ai.rapp.recall`. The first launch asks for
Screen Recording permission. Accessibility is optional in the first milestone
and only enriches window metadata.

## Repository map

- `Sources/RecallCore/` — capture-independent models, privacy policy, store
- `Sources/RappRecall/` — JSON CLI and daemon process
- `Tests/RecallAcceptance/` — standalone deterministic acceptance executable
- `docs/specimen.md` — observed behavior and clean-room provenance
- `docs/architecture.md` — boundaries and failure semantics

Tracked by [issue #1](https://github.com/kody-w/rapp-recall/issues/1) and
[issue #2](https://github.com/kody-w/rapp-recall/issues/2), with database
encryption tracked by
[issue #3](https://github.com/kody-w/rapp-recall/issues/3).
