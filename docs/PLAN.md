# Hex Mobile Sync — build plan and spec

> Last update: 2026-11-01

**Hex Mobile Sync**: unofficial iPhone companion for [Hex](https://github.com/anomalyco/hex), the macOS
dictation app. Not affiliated with Hex or its author. Distributed as source only:
you build and sideload it with Xcode (no App Store, no notarization). The repo is
meant to become public under MIT and be donated to the Hex / opencode (Anomaly) community: code, docs and naming must be ready for a maintainer handover (no personal references, clear CONTRIBUTING, neutral identifiers).

## Goal

Wispr Flow–style dictation on iPhone, on-device, sharing vocabulary and text rules
with Hex on the Mac.

## Hard constraints

1. **Works with a free Apple ID (Personal Team).** No capability that a Personal
   Team cannot sign: no App Groups, no iCloud/CloudKit entitlement, no push, no
   Associated Domains. Paid account must work too (only longer provisioning).
2. **On-device only.** Transcription via Apple `SpeechAnalyzer` (iOS 26+ Speech
   framework). No network calls from app or extensions, no analytics, no LLM.
3. **Deployment target iOS 26.0**, built with Xcode 27.2 / iOS 27.2 SDK. Swift 6
   language mode, strict concurrency complete, zero errors.
4. **Generic open-source code.** No personal paths, names, tailnet IPs, tokens or
   vocabulary in code, fixtures or docs. Bundle ID prefix and team come from a
   gitignored `Config/Local.xcconfig`; default prefix `io.github.hexmobile`.
5. **Hex is read through its CLI**, never by editing its files while it runs.
   Reading `settings.json` read-only is allowed only as a fallback when the Hex app
   is not running (CLI exit code 3).
6. English for code, comments, README. App UI: English base + Italian localization
   (String Catalog).

## Architecture

```
Mac                                         iPhone
Hex.app ── hex CLI (--json) ──► mac/hex-mobile-sync.sh ──► iCloud Drive/Hex Mobile/
                                   ▲  (launchd: WatchPaths + interval)      hex-mobile-sync.json
                                   └── applies pending-vocabulary.json ◄──  pending-vocabulary.json
                                                                            (optional) iphone-history.jsonl
iPhone app picks the "Hex Mobile" folder once in Files (security-scoped bookmark,
no iCloud entitlement needed) and reads/writes it with NSFileCoordinator.
```

### Targets (XcodeGen `project.yml`, generated `.xcodeproj` is committed? **No**: gitignored, `make project` regenerates)

| Target | Kind | Role |
|---|---|---|
| `HexMobileCore` | local Swift package `Packages/HexMobileCore` (iOS 26, macOS 26) | models, text processing, sync codec, history, IPC constants. Pure, testable with `swift test` on macOS |
| `HexMobile` | iOS app | recording + transcription, UI, sync, App Intents, Live Activity host, flow session |
| `HexMobileWidgets` | WidgetKit extension | Live Activity (lock screen + Dynamic Island) and Control Center `ControlWidget` toggle |
| `HexKeyboard` | custom keyboard extension, `RequestsOpenAccess = YES` | mic key + insert last dictation, Wispr Flow–style |

### Sync file format (`hex-mobile-sync.json`, written by the Mac script)

```json
{
  "schema_version": 1,
  "exported_at": "2026-11-01T10:00:00Z",
  "source": { "app": "Hex", "app_version": "3.1.1", "via": "cli" },
  "language": "it",
  "vocabulary": [ { "term": "Kubernetes", "sounds_like": ["cooper netties"] } ],
  "default_mode": { "name": "Global", "replacements": [ { "matched_phrase": "x", "output": "y" } ], "transformations": ["lowercase"] },
  "modes": [ { "name": "Terminal", "applications": ["Terminal"], "browser_hosts": [], "replacements": [], "transformations": ["no-trailing-punctuation"] } ]
}
```

- `post_processing` (LLM prompt and model) is **never exported**.
- Decoders are tolerant: unknown keys ignored, missing arrays = empty, `schema_version` > 1 = refuse with a clear error.
- The Mac script rewrites the file only when content (excluding `exported_at`) changes (idempotent).

`pending-vocabulary.json` (written by iPhone, consumed by Mac):

```json
{ "schema_version": 1, "entries": [ { "id": "UUID", "term": "Terraform", "sounds_like": ["terra form"], "created_at": "…" } ] }
```

The Mac script runs `hex vocabulary add --sounds-like="a,b" <term>` for entries not
already present (only when Hex is running), then removes applied entries from the
file. Entries already present are dropped as applied.

### Text pipeline (independent reimplementation of Hex's documented semantics, `TextProcessor`)

1. Vocabulary rewrite: every `sounds_like` phrase → `term`.
2. Mode replacements: `matched_phrase` → `output`.
3. Mode transformations in order. Built-ins: `lowercase`, `no-trailing-punctuation`,
   `spongebob-case`. Unknown ids (Hex personal TS commands) are skipped and reported.

Matching rules for 1–2: case-insensitive, diacritic-sensitive, whole-word (Unicode
letter/digit boundaries), longest phrase first, single left-to-right pass without
re-matching output. On iPhone the active mode is `default_mode`; the user may pick
one of `modes` as a manual override in Settings.

### Transcription engine

- `SpeechAnalyzer` with `SpeechTranscriber` when the locale is in
  `SpeechTranscriber.supportedLocales`, else `DictationTranscriber`. Volatile
  results shown live, finalized results kept.
- Assets via `AssetInventory` (install request with progress in Settings).
- Vocabulary bias: `AnalysisContext.contextualStrings` filled with vocabulary terms
  (cap 100). *To verify on device:* effect on recognition quality.
- Audio: `AVAudioEngine` input tap → `AnalyzerInputConverter`/`bestAvailableAudioFormat` → analyzer input stream.
- Language default: synced `language` if present, else device locale; overridable.

### Engine abstraction and Mac relay (future)

All transcription goes through a `TranscriptionEngine` protocol in the app
(`start(locale:context:)`, live volatile text stream, `finish() async throws -> String`,
`cancel()`). v1 ships `OnDeviceSpeechEngine`. A community Android client already
uses the Mac Hex as a relay (vkpdeveloper on X, 2026, PR proposed to the Hex
maintainers): a `MacRelayEngine` (audio streamed to Hex on the Mac over LAN/tailnet,
same model and rules as the desktop) can plug in once Hex exposes a relay endpoint.
Not in v1: Hex's local API is owner-only on localhost today.

### Triggers

1. **In app**: big record button (tap to toggle, long-press = push-to-talk).
2. **Action Button / Shortcuts / Control Center**: `ToggleDictationIntent` conforming
   to `AudioRecordingIntent`; starts a Live Activity while recording (required by
   the system for background recording). Second press stops, transcribes, copies
   to clipboard, returns the text as intent output. `AppShortcutsProvider` exposes it.
3. **Keyboard (Wispr Flow–style flow session)**: the app can keep a *flow session*
   alive (audio session active in background, input discarded until dictation
   starts, auto-ends after N idle minutes, default 5). The keyboard talks to the app
   with Darwin notifications (no App Group): `ping`/`pong`, `toggle`,
   `state.recording|processing|idle`, `done`, and `session.ended` (no flow
   session: it ended, or a `ping`/`toggle` arrived without one). Result goes
   through `UIPasteboard` with plain text plus custom type
   `io.github.hexmobile.dictation` (JSON with id), which the keyboard inserts once
   via `textDocumentProxy`, and automatically only after a stop it requested
   itself (otherwise it offers Insert). Pasteboard copies are local-only (no
   Universal Clipboard) unless the user allows it; with Copy to Clipboard off, a
   keyboard-triggered result is still written, local-only, expiring after
   two minutes. With no session the mic
   key tries to open `hexmobile://session/start` (best effort) and otherwise shows
   instructions. *To verify on device:* Darwin notifications between app and
   keyboard without App Group; opening the host app from the keyboard on iOS 27.

### Output

Final text → clipboard (setting, default on) + history. Share sheet and copy in UI.

### History

On-device JSON file in Application Support, retention day/week/month/forever
(default week, like Hex). Optional export of entries to `iphone-history.jsonl` in
the sync folder (default off).

## Acceptance criteria

- A1 `swift test` in `Packages/HexMobileCore` green; tests cover codec (real-shaped
  fixtures, unknown keys, future schema), pipeline (Italian accents, word
  boundaries, longest-first, built-ins, unknown transformations), pending vocab
  merge, history retention.
- A2 `xcodebuild -scheme HexMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` succeeds, 0 errors, no warnings in our code.
- A3 Same for `generic/platform=iOS Simulator`; when a simulator runtime is
  available the app launches and screenshots of the main screens are captured.
- A4 `tests/mac/test-sync.sh` (stub `hex` CLI) green: export, idempotence, fallback
  without running Hex, pending vocab apply, failure paths. Real run on the
  maintainer's Mac produces the bundle with all vocabulary terms and no `post_processing`.
- A5 Entitlements contain nothing a Personal Team cannot sign. Info.plist has
  microphone and speech usage strings; `PrivacyInfo.xcprivacy` present for app and
  extensions.
- A6 Adversarial review: no open high-severity finding.
- A7 README (install with free Apple ID, sync setup, keyboard, Action Button,
  privacy, limitations), LICENSE (MIT), CI workflow (`swift test` + unsigned build).

## Error handling (Mac script)

Error → Detection → Response → Fallback → Alert:
Hex CLI missing → path check → exit 1 with message → none → log + macOS notification
(deduped per day). Hex not running → exit 3 → fallback read-only `settings.json`,
pending vocab kept for next run → log. iCloud folder missing → create it once →
log. Invalid pending JSON → move aside to `pending-vocabulary.invalid-<ts>.json` →
log + notification. Logs: `~/Library/Logs/hex-mobile-sync.log` (rotated at 1 MB).

## Out of scope (v1)

Self-hosted remote transcription, LLM polish, per-app modes on iPhone,
meetings, App Store distribution.
