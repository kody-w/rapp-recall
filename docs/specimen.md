# Clean-room specimen report

This report records externally observable product behavior used to define Rapp
Recall. It is deliberately about **shape**, not implementation.

## Boundary

The preserved Rewind application and backup were inspected read-only. The work
did not:

- decrypt or query the archived database;
- view archived screen frames;
- extract proprietary source;
- copy artwork, UI, text, model weights, or binary resources;
- recover credentials or depend on the discontinued service.

No Rewind binary or private record belongs in this repository.

## Observed facts

| Surface | Observation |
|---|---|
| Product | Native macOS menu-bar app, bundle version 1.5607 |
| Permissions | Screen Recording and Accessibility; microphone optional |
| Screen cadence | One frame every two seconds |
| Display behavior | Captured the display containing the pointer |
| Storage | Local media chunks plus a separate encrypted SQLite index |
| Media | Archived chunk metadata identifies HEVC in MP4 containers |
| Processing | Compression, OCR, and speech recognition described as local |
| Retrieval | Reverse-chronological OCR/transcript search, phrases, app filters |
| Navigation | Scrollable timeline, moment preview, starred moments, deep links |
| Privacy | Pause/resume, excluded apps, private-browser exclusions |
| Lifecycle | Configurable retention and deletion of timeline ranges |
| Meetings | Optional audio capture, transcript, playback, summaries |

The preserved preferences also expose product-level settings such as capture on
launch, audio capture policy, retention period, OCR quality, menu-bar behavior,
meeting end behavior, keyboard shortcuts, and window layout.

## What the backup taught us

The useful architectural pattern is separation:

1. compressed media is append-only and organized by time;
2. searchable metadata lives in a database;
3. audio snippets are separate from screen chunks;
4. retention can remove old media and matching index rows;
5. the product can remain useful without a server because capture, OCR,
   compression, and playback are local.

The encrypted database is not required to recreate that architecture. Rapp
Recall defines its own schema and starts a new timeline.

## Clean-room design choices

- Use ScreenCaptureKit rather than reproducing an unknown capture algorithm.
- Use HEIF still frames first; introduce HEVC segments only after measured
  storage evidence justifies the added recovery complexity.
- Use Vision OCR and SQLite FTS5, both public platform technologies.
- Create an original SwiftUI interface rather than reproducing Rewind's UI.
- Treat audio and AI summaries as independent later milestones.

## Evidence sources

Facts came from:

- the application's `Info.plist`;
- bundled user-facing Help articles;
- preference key names and non-personal configuration values;
- directory and filename layout;
- `ffprobe` container/codec metadata without decoding or viewing frames.

This is a provenance record, not a claim that Rapp Recall is affiliated with or
endorsed by Rewind or Limitless.
