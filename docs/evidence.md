# Acceptance evidence

Evidence is a gate, not a product claim. This file records commands and
measurements while avoiding captured user text.

## Deterministic acceptance

Command:

```bash
./scripts/acceptance.sh
```

Result on 2026-08-15:

- normal run: PASS;
- network-denied sandbox run: PASS;
- 39/39 assertions per run.

Covered:

- real HEIF encoding and Vision OCR of synthetic pixels;
- exact-phrase FTS and reverse-chronological/app-filter metadata;
- exclusion before encoder, OCR, bytes, SQLite, and FTS;
- excluded phrase absent across every store file;
- known stored phrase absent as plaintext across DB/WAL/SHM/media;
- unchanged-frame deduplication;
- retention removes media, SQLite, and FTS together;
- quote-only query returns empty instead of leaking an FTS error;
- nonexistent mutation is an explicit error;
- SQLCipher header, no-key rejection, wrong-key rejection, correct-key reopen;
- SQLCipher 4.x runtime identity and owner-only DB sidecar modes;
- isolated local-build key generation, stable reopen, and owner-only key mode;
- stale command rejection after daemon restart;
- pause and stop write barriers;
- resume after pause;
- injected OCR failure reports `.failed` and exits rather than deadlocking.

## Real daemon control

At a two-second capture interval:

```text
pause receipt: stored 16
five seconds later: stored 16
resume receipt: stored 16
six seconds later: stored 19, dropped 0
stop receipt: stored 20, state stopped
three seconds later: stored 20, state stopped
```

A concurrent second daemon against the same root exited 69 with:

```text
Another process holds the Recall daemon lock.
```

## Real pixels through the packaged artifact

The extracted, signed artifact captured a visible TextEdit fixture through
ScreenCaptureKit. Vision found the fixture token in 63 moments. An app-filtered
query returned only:

```text
application: TextEdit
bundle: com.apple.TextEdit
window: rapp-recall-final-smoke.rtf
resolution: 1920x1080
dropped frames: 0
```

The first attribution attempt had incorrectly selected
`UserNotificationCenter`; that run was rejected. The resolver now excludes
system overlays and selects the topmost substantial user window on the
captured display.

## Encryption and artifact

```text
SQLCipher: 4.17.0 community
plaintext header: 53514c69746520666f726d6174203300
observed header: random 16-byte salt (not plaintext signature)
external sqlcipher/homebrew/openssl/libsqlite dependencies: none
local key file: mode 0600, 32 bytes, outside data root
archive: RappRecall-macos-arm64.tar.gz
extracted codesign verification: valid
packaged acceptance: PASS, 39/39
```

Ad-hoc local builds report `databaseKeyAccess: local-key-file`. Properly
Developer ID-signed releases report `application-bound-keychain`.

## Honest boundary

The SQLCipher database protects OCR, titles, app metadata, runtime state, and
FTS. Screen media is ordinary HEIF, matching the observed specimen boundary.
The current build therefore does not claim protection against another process
already running as the same user.
