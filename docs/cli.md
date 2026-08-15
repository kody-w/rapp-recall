# Headless CLI contract

The executable is JSON-first and non-interactive. Successful commands write one
JSON object to stdout. Failures write one JSON object to stderr and use a
nonzero exit.

## Envelope

Success:

```json
{"ok":true,"command":"status","data":{}}
```

Failure:

```json
{"ok":false,"command":"search","error":{"code":64,"message":"search requires a query."}}
```

Exit codes follow `sysexits.h` where applicable:

| Code | Meaning |
|---:|---|
| 0 | command completed |
| 64 | invalid command or argument |
| 69 | daemon/resource unavailable |
| 70 | operation failed |

## Store selection

Every command accepts `--root PATH`. If omitted:

```text
~/Library/Application Support/ai.rapp.recall
```

This makes tests disposable and lets a user place a new timeline on an
external drive without symlinking internal implementation paths.

## Daemon

```bash
rapp-recall daemon \
  [--root PATH] \
  [--interval SECONDS] \
  [--exclude-bundle BUNDLE_ID]...
```

The daemon stays in the foreground. It refuses to start if the selected store
already records a live daemon PID.

Default bundle exclusions:

- `com.1password.1password`
- `com.bitwarden.desktop`
- `com.apple.keychainaccess`

## Control

```bash
rapp-recall pause  [--wait] [--timeout SECONDS]
rapp-recall resume [--wait] [--timeout SECONDS]
rapp-recall stop   [--wait] [--timeout SECONDS]
```

Commands are durable SQLite rows, not ephemeral signals or TCP messages.
`--wait` returns only after the daemon records a receipt. Pause and stop are
**write barriers**: the receipt is not written until ScreenCaptureKit is
stopped and an in-flight Vision/store operation has drained.

## Query

```bash
rapp-recall search <query> [--app NAME_OR_BUNDLE] [--starred] [--limit N]
rapp-recall recent [--app NAME_OR_BUNDLE] [--starred] [--limit N]
```

Quotes create phrase terms. Unquoted terms are combined with OR, matching the
observed product behavior. Results are newest-first.

## Mutation and diagnostics

```bash
rapp-recall star <moment-id> [--off]
rapp-recall purge --before <ISO-8601>
rapp-recall doctor
rapp-recall acceptance
```

Retention first renames media into a same-volume trash directory, commits the
SQLite/FTS deletion, and then removes trash. On a transaction error, media is
moved back before failure is reported.

`acceptance` invokes the bundled standalone acceptance executable. It uses
synthetic pixels but the real HEIF encoder, Vision OCR, SQLite FTS, exclusion
policy, daemon command loop, pause/resume barriers, and retention path.
