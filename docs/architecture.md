# Architecture

## The local memory loop

```text
ScreenCaptureKit
       |
       v
CapturedFrame + AppContext
       |
       v
ExclusionPolicy  ---- excluded ----> discard in memory
       |
     allowed
       |
       +----> Vision OCR
       |
       +----> HEIF encoder
                 |
                 v
          RecallStore transaction
           media + SQLite FTS5
                 |
                 v
       SwiftUI timeline/search
```

## Privacy boundary

`ExclusionPolicy` executes before:

- image encoding;
- OCR;
- hashing/deduplication;
- filesystem writes;
- database writes;
- diagnostic logging.

The pipeline reports only an aggregate excluded-frame count. It never records
the excluded app title, OCR text, pixels, or window title. An exclusion feature
that writes first and deletes later is not an exclusion feature.

Configured bundle exclusions are also passed into ScreenCaptureKit's content
filter. This blanks every window owned by that application even when it is a
small overlay and some other app remains prominent. The policy check then
rejects the entire frame when an excluded app is the selected user window.

Private-window detection from window titles is inherently imperfect. The app
will label that limitation instead of implying browser-level guarantees. A
future browser extension can supply a trusted private-mode signal.

## Store

`RecallStore` owns one SQLite connection behind a Swift actor. The schema uses a
content-backed FTS5 table and triggers so text index rows cannot drift from
moment rows.

The complete SQLite/FTS database is encrypted by the vendored SQLCipher
Community Edition using its CommonCrypto provider. A random 256-bit key lives
in the user's macOS Keychain and is applied before any schema or PRAGMA access.
Acceptance injects an isolated deterministic key and never touches Keychain.

Release builds should set `RAPP_RECALL_SIGNING_IDENTITY` to a Developer ID
identity; their Keychain item is application-bound and remains stable across
updates. Ad-hoc signatures have no stable Keychain identity and modern
partition lists cannot be widened without an interactive login-password
operation. Local builds therefore use a separate `0600` key file under
`~/Library/Application Support/ai.rapp.recall.keys`, outside the recording data
root. This explicit tradeoff is reported by `doctor`: it preserves unattended
updates and keeps data-only backups separated from their database key, but it
does not resist another process already running as the same user. Ordinary HEIF
media is already readable to same-user processes.

Screen media matches the observed product boundary and remains ordinary HEIF.
That fact is explicit: SQLCipher protects OCR, titles, app metadata, runtime
state, and the search index; it does not claim to encrypt screenshots. FileVault
is still strongly recommended.

Media writes are atomic. If the database insertion fails, the just-written
media file is removed. Retention uses a same-volume trash rename, then commits
database deletion, then empties trash. If the transaction fails, files move
back before the error is surfaced.

## Failure semantics

- Capture permission denied: visible stopped/error state; no success fallback.
- OCR failure: frame persists with an explicit OCR error state and remains
  navigable; it is not silently indexed as empty.
- Store failure: capture pauses and surfaces the error.
- Exclusion uncertainty: conservative exclusion for configured apps.
- Missing media during search: result is marked damaged, never substituted.
- Retention partial failure: rollback and explicit error.

## Network

The core target links no networking framework and contains no HTTP client.
Offline behavior is therefore an architectural property, not a feature flag.

## Deferred boundaries

Audio capture/transcription and local question-answering are separate
pipelines. They must not gain implicit access to screen history merely because
they run in the same application.
