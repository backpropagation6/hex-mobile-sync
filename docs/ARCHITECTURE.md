# Architecture

How Hex Mobile Sync is put together. The normative spec, including the exact
file formats and acceptance criteria, is [PLAN.md](PLAN.md); this document
explains the code as it is.

## Overview

```
Mac                                              iPhone
Hex.app ── hex CLI (--json) ──► mac/hex-mobile-sync.sh ──► iCloud Drive/Hex Mobile/
                                  ▲  (launchd: WatchPaths + 900 s interval)  hex-mobile-sync.json
                                  └── applies pending-vocabulary.json ◄────── pending-vocabulary.json
                                                                             iphone-history.jsonl (optional)

┌──────────────────────────── HexMobile.app ────────────────────────────┐
│ SyncManager ── SyncFolderIO (bookmark + NSFileCoordinator)            │
│      │ SyncBundle / PendingVocabulary                                 │
│      ▼                                                                │
│ DictationController ── AudioCapture ── TranscriptionEngine            │
│      │                                  └─ OnDeviceSpeechEngine       │
│      │                                     (SpeechAnalyzer)           │
│      ├─ FinalPass, TextCleaner (HexMobileSpeech), spelling            │
│      ├─ TextProcessor (HexMobileCore) ──► HistoryStore                │
│      ├─ DictationPasteboard (text + JSON payload)                     │
│      ├─ LiveActivityManager                                           │
│      └─ Darwin notifications ◄──► keyboard / widget extension         │
└───────────────────────────────────────────────────────────────────────┘
   ▲ App Intents (Action Button, Control Center, Shortcuts, Siri)
```

## Targets

The Xcode project is generated from `project.yml` by XcodeGen (`make project`)
and is not committed.

| Target | Kind | Sources | Role |
|---|---|---|---|
| `HexMobileCore` | local Swift package (`Packages/HexMobileCore`, iOS 26 / macOS 26, no dependencies), library `HexMobileCore` | `Sources/HexMobileCore` | Models, sync codec, text pipeline, pending vocabulary, history store, IPC constants, Darwin notification wrapper; the pure parts of the second pass and the cleanup (policy, guard, prompt, transcript assembly), the user's spelling, the kept-clip library, the word error rate. Pure and tested with `swift test` on macOS. |
| `HexMobileSpeech` | second library of the same package | `Sources/HexMobileSpeech` | What talks to Apple's Speech and Foundation Models frameworks: recognition of an audio file, the final pass, the clip writer, the cleanup. In the package, not in the app, so `tools/asr-bench` runs the very same code. Not unit tested (the models are not deterministic) except the clip writer; every decision that does not need a model is in `HexMobileCore`. |
| `asr-bench` | macOS command line tool (`tools/asr-bench`, its own Swift package) | `tools/asr-bench/Sources` | Compares recognizer variants and the app's pipeline on a folder of clips, with the word error rate. See its README. |
| `HexMobile` | iOS app | `App/`, `Shared/`, `Design/` | Recording, transcription, UI, sync, App Intents, Live Activity host, flow session. The only target that links the Swift package `ArgmaxOSS` (WhisperKit, pinned to 1.1.1) and `Packages/HexMobileWhisper` (the Whisper recipe) for the optional Whisper pass; the extensions link nothing from them. |
| `HexMobileWidgets` | WidgetKit extension | `Widgets/`, `Shared/`, `Design/` | Live Activity (Lock Screen, Dynamic Island) and the Control Center control. |
| `HexKeyboard` | custom keyboard extension, `RequestsOpenAccess = YES` | `Keyboard/`, `Design/` | Mic key that drives the app's flow session and inserts the result. |

Build settings shared by all targets live in `Config/Base.xcconfig`. The team
and bundle ID prefix come from the gitignored `Config/Local.xcconfig`. Swift 6
language mode with complete strict concurrency, deployment target iOS 26.0.

No target has entitlements that a free Personal Team cannot sign: no App
Groups, no iCloud, no push, no Associated Domains. That constraint shapes most
of the design below.

## Sync

### Mac side

`mac/hex-mobile-sync.sh` (bash 3.2, BSD tools, `jq`) runs as a launchd agent
installed by `mac/install.sh`. It reads Hex only through the CLI
(`hex vocabulary list`, `hex settings get dictation_processing`,
`hex settings get transcription`, all `--json`). When the CLI exits 3 (Hex not
running) it reads Hex's `settings.json` read-only instead. It builds the bundle
from a whitelist of fields, refuses to write if `post_processing` appears, and
writes atomically only when the content other than `exported_at` changed.

Pending vocabulary from the iPhone is applied with `hex vocabulary add` only
while Hex is running. Behavior, exit codes and error handling:
[mac/README.md](../mac/README.md).

### iPhone side

- `SyncManager` (main actor, observable) owns the current `SyncBundle`, the
  local copy of the pending vocabulary and the sync status.
- The user picks the folder once with the Files picker. The app stores a
  security-scoped bookmark and resolves it on each refresh. `SyncFolderIO`
  reads and writes with `NSFileCoordinator` so iCloud Drive sees consistent
  files. No iCloud entitlement is needed because the app only touches the
  folder the user granted.
- The last good bundle and the local pending queue are cached in Application
  Support, so the app works offline and before the first sync.
- When the user adds a term, it goes into the local queue and is merged into
  `pending-vocabulary.json` in the folder. On refresh, entries that Hex already
  has (according to the bundle) are removed from the queue.

### File formats

| File | Writer | Reader | Codec |
|---|---|---|---|
| `hex-mobile-sync.json` | Mac script | app | `SyncCodec.decodeBundle` / `SyncBundle` |
| `pending-vocabulary.json` | app | Mac script | `SyncCodec.decodePendingVocabulary` / `PendingVocabulary` |
| `iphone-history.jsonl` | app (opt-in) | user / future tools | `HistoryExport.jsonLines` |

All files carry `schema_version` 1. Decoders ignore unknown keys, treat missing
or invalid arrays as empty, skip bad items and refuse a missing or newer
`schema_version` with a clear error. JSON examples are in
[PLAN.md](PLAN.md#sync-file-format-hex-mobile-syncjson-written-by-the-mac-script).

## Text pipeline

`TextProcessor` (HexMobileCore) ports Hex's semantics:

1. **Vocabulary rewrite**: every `sounds_like` phrase becomes its `term`.
   Pending terms added on the iPhone are included before the Mac applies them.
2. **Mode replacements**: `matched_phrase` becomes `output`.
3. **Transformations** in order. Built-ins: `lowercase`,
   `no-trailing-punctuation`, `spongebob-case`. Unknown ids (Hex's personal
   script commands) are skipped and reported in
   `ProcessingResult.skippedTransformations`.

Matching rules for steps 1 and 2 (`PhraseRewriter`):

- case-insensitive, diacritic-sensitive (`è` differs from `e`; composed and
  decomposed forms of the same character are equal);
- whole words only, where a word character is a Unicode letter or digit;
- longest phrase first, ties in declaration order;
- one left-to-right pass per step that never re-scans its own output.

The active mode is `default_mode`, unless the user picked one of `modes` in
Settings. Per-app modes are not applied on iPhone.

## Transcription

`TranscriptionEngine` is the seam for every engine:

```swift
protocol TranscriptionEngine {
    func start(locale: Locale, context: TranscriptionContext, audio: AudioCapture) async throws -> TranscriptionSession
}
// session: live volatile text, finish() async throws -> String, cancel() async
```

v1 ships `OnDeviceSpeechEngine`:

- `SpeechAnalyzer` with `SpeechTranscriber` when the locale is supported,
  otherwise `DictationTranscriber` (`SpeechModels.resolve`).
- Model assets through `AssetInventory`; install progress is shown in the app.
  When `assetInstallationRequest` returns `nil`, `SpeechModels.install`
  rechecks the status: `installed` ends as a success, anything else throws
  `assetInstallUnavailable`, which `SpeechAssetsModel` shows as its
  `errorMessage` (before, both ended as a silent success).
  The Dictate screen shows the install card instead of the error banner when
  the model is missing, since both carry the same message. The card and that
  message go away as soon as `SpeechAssetsModel.refresh` finds the model
  installed (`onInstalled`, wired in `AppServices` to
  `DictationController.modelInstalled(for:)`): after an install, on a
  foreground refresh or on opening Settings. Before, they stayed until the
  next `start()`. Observed on the simulator (1 Nov 2026) with a real de-DE
  download: `autoinstall done assets=installed missingModel=- banner=-`.
- `AudioCapture` taps `AVAudioEngine` input; buffers are converted to the
  analyzer's best available format (`AnalyzerInputConversion`). Three steps
  can come back empty, and each throws its own error
  (`noCompatibleAudioFormat(.inputFormat | .analyzerFormat | .converter)`) and
  logs an `engine format:` line with the input and analyzer formats.
- **Model installed but not loadable**: when the module offers no audio format
  at all, with or without the input as a hint, the engine throws
  `modelUnavailable` ("installed but cannot be loaded on this device"), not a
  microphone-format error. On iOS Simulator 27.2 (1 Nov 2026) this is the
  state of `DictationTranscriber` for it-IT and en-US: `AssetInventory.status`
  says `installed`, `availableCompatibleAudioFormats` is empty,
  `bestAvailableAudioFormat` returns `nil` in about 10 ms and
  `prepareToAnalyze` fails with `SFSpeechErrorDomain` 4 "Model not available",
  while the simulator's microphone is a plain mono 48 kHz float32 input.
  `SpeechTranscriber.isAvailable` is false there. ipotesi: the dictation model
  does not run on the simulator; the dictation path to transcribed text is only
  verifiable on a device. `SFSpeechRecognizer` reports on-device support on the
  simulator and could back a simulator-only engine; not built.
- Vocabulary bias: up to 100 terms (`ContextualVocabulary`) go into
  `AnalysisContext.contextualStrings`. The effect on accuracy is not yet
  measured on device.
- Language: the synced `language` when set and not `auto`, else the device
  locale; overridable in Settings. The synced value is a bare code (`it`) and
  stays one in the requests; what runs is the locale the engine resolves
  (`SpeechTranscriber.supportedLocale(equivalentTo:)`). Checked 2 Nov 2026 on
  the phone log: the 58 `on-device` records of `history.json` all say `it-IT`,
  the locale the engine ran with, even though the log line
  `cleanup availability=available locale=it` shows `it`: that line prints the
  locale handed to `TextCleaner`, which uses only its language code. The
  `debug-fake` records say `it` or `it-IT` because the fake engine echoes the
  locale it was asked for. Nothing to fix; the line is cosmetic.
- Empty vocabulary: `VocabularyNotice` (HexMobileCore, pure, tested) turns
  «folder picked?» and «terms synced» into `noFolder` or `noTerms`; the Dictate
  screen and Settings > Sync show one footnote for it
  (`SyncManager.vocabularyNotice`). It does not block anything: the
  recognizer simply runs without `contextualStrings`, and Whisper without a prompt.

Every `DictationRecord` stores the engine identifier, so a future engine (see
the Mac relay below) is visible in history and in the keyboard payload.

## Accurate pass and text cleanup

Added 1 Nov 2026 after «non capisce bene, non formatta e non aggiusta il testo».
The live recognizer runs with `fastResults` (Apple: «faster but also less
accurate results», a smaller context window), which is what makes words appear in
about a second. Nothing fixed the text afterwards.

### After the stop

`DictationController.stop()`:

1. `engine.finish()` ends the live analysis (the transcript so far, `live`).
2. **Accurate pass** (`FinalPass`): the audio the live analyzer received, already
   at the analyzer's format (16 kHz mono 16-bit), was written to a CAF file in
   Caches by `AudioClipWriter` while recording (the converter's flushed tail
   included; written on its own queue, never on the audio thread; capped at 15
   minutes). The file goes to a second `SpeechTranscriber` without `fastResults`
   through `analyzeSequence(from:)`. Behind the `FinalPassEngine` protocol; Whisper is
   a second engine behind it, run after this one when chosen in Settings (see
   [Whisper second pass](#whisper-second-pass)).
   Deadline `clamp(2 + 0.05 × recording seconds, 3, 5)` s (`FinalPassPolicy`).
   The live text stays on a timeout, an error, an empty result, a recording under
   0.5 s, or when the pass has fewer than half the live words.
3. **Cleanup** (`TextCleaner`): Foundation Models, one new `LanguageModelSession`
   per dictation (prewarmed when recording starts), greedy sampling,
   `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, Italian
   instructions with three examples, the text inside `<dettatura>` tags. It starts
   only if its estimate (0.25 s + 3.9 ms per character) fits what is left until 7.55 s
   after the stop (at least 1 s), else `reason=budget` and the text arrives at once;
   when it starts it runs to that absolute deadline (see **Cleanup plan** below).
   `CleanupGuard` (pure, tested) rejects an empty answer, a refusal
   phrase, a preamble («Ecco…», labels, quotes the text did not have), a length
   outside 0.6–1.5 of the input, fewer than 85% of the answer's words being words
   of the input (a changed word counts as new), and fewer than half as many words
   as the input: an outer net. Inside it `CleanupEditGuard` aligns the answer with
   the input word by word (`TranscriptGapGuard.matchedPairs`, forward and reversed,
   the answer stands if either alignment is clean; words folded to no case, no
   accents, no punctuation, every number as digits by `ItalianNumber`). A dictated
   word may be missing from the answer only if it is a hesitation (ehm, eh, mmm,
   uhm, ah…), the repetition of an adjacent kept word or phrase, or part of the
   phrase before a correction marker of the input («no anzi», «anzi», «scusa»,
   «intendevo», «volevo dire», at most 8 words, the marker included). Any other
   word replaced, added, moved or taken out is `reason=edited` and the text stays
   as received. The bag of words let through a deleted «bene o male», three
   deleted «di», «ed è» turned into «e è» (phone, 2 Nov 2026). Unavailable
   model (reason logged), `guardrailViolation`, `rateLimited`, context exceeded,
   a language other than the text's, more than 3000 characters: the text as
   received stays.
4. **Spelling** (`PersonalVocabulary.respell`): the terms that bias recognition fix
   the case of whole-word matches, longest first, and never change letters.
5. The Hex steps (`TextProcessor`).

`rawText` of the history record is what the recognizer returned (the accurate pass,
or the live text when it fell back), `cleanedText` what the model returned when it
was accepted, `text` what was inserted. The history export carries `text` only.
The keyboard, Shortcuts and the loopback get `text`.

### Why not the names in the instructions

An early prompt listed the user's terms (Zentrix, Hugging Face, LoRA, Mauro,
Ferrandi, Castaldi) «as correct spellings». In a manual test of 1 Nov 2026 the
model then rewrote `Marco` as `Mauro` in a sentence that had no reason to be
touched. The terms stay out of the instructions; recognition gets them as
contextual strings, and the case is fixed in code.

### Why not one analyzer with two recognizers

`SpeechAnalyzer(modules: [fast, accurate])`, fed once, accepts both. Measured with
`asr-bench --variants live,dual --realtime` on four synthetic clips of about 5 s
(Mac, 1 Nov 2026): the fast recognizer alone gave its first result at 1.03 s and
18 results before the stop; in the pair both gave **0 results before the stop**
and their first result at the end of the audio (5.15 s and 5.20 s for a 5.1 s
clip), with the accurate text for both. The live transcript is lost, so the app
streams with the fast recognizer and runs the accurate one on the file at the
stop. A second analyzer in parallel would have kept both live but doubled the load
while recording; not tried.

### Numbers (Mac, synthetic voice)

`asr-bench` on 13 clips made with the `say -v Alice` voice (10 sentences of 4–6
s with names and technical words, three long clips of 42, 62 and 104 s; 777
reference words), 1 Nov 2026, Apple's it-IT models. **A synthetic voice is easier
than real speech: these numbers order the variants and prove the tool, they do not
predict the error rate on a person.** Normalized WER (case and punctuation
ignored, accents counted):

| Variant | WER | S / D / I | mean / max time |
|---|---|---|---|
| `fast` (file, `fastResults`) | 2.3% | 9 / 7 / 2 | 0.20 / 0.92 s |
| `accurate` (file, no `fastResults`) | 2.3% | 11 / 5 / 2 | 0.19 / 0.85 s |
| `dictation` (`DictationTranscriber`, punctuation) | 3.3% | 14 / 10 / 2 | 0.44 / 1.83 s |
| `live` (streamed, as the live transcript) | 2.3% | 9 / 7 / 2 | 0.19 / 0.91 s after the stop |
| `app` (live + final pass + cleanup + spelling) | 2.3% | 11 / 5 / 2 | 1.52 / 4.84 s stop to text |

- On the whole set the accurate pass did not beat the fast one (same WER, a
  different mix of errors); the three long clips are 624 of the 777 words. On the
  four short clips with names and technical words (s01, s04, s08, s09, 62 words)
  the fast variant gave 9.7%, the accurate one 6.5% and `dictation` 12.9%: four
  sentences, a difference of two words. The evening's `Sta rompando` was real speech, which this set
  cannot reproduce. Whether the second pass helps on real speech is **not
  measured**: that is what the kept clips and a script read aloud are for.
- Live streaming in real time: first result at 1.03–1.13 s, from the stop to the
  end of the analysis 0.03–0.23 s.
- The cleanup does not change the words (same WER as `accurate`); what it changes
  is punctuation, capitals and hesitations.
- Cleanup duration grows with the text: 121 words 2.5 s, 190 words 3.9 s, 312
  words 6.5 s (with the timeout raised to 12 s). With the 3 s limit the two longest
  clips came back as the recognizer heard them (`reason=timeout`). The phone is
  probably slower: **not measured**. A timeout that grows with the length would
  format long dictations too, at the price of a longer wait; left to the author.
- Text loss on long dictations (the 123 s record of 16:18Z with 110 characters
  ending in «training fio»): not reproduced. The 62 s clip streamed in real time
  and the 104 s clip returned the text up to the last word (1.6% WER, 2 and 3
  deletions in 191 and 312 words) both live and as a file. In the device log the
  transcript had no update for the last 54 s before that stop, which fits silence
  as well as a stall; ipotesi: the last volatile words were cut mid-word, which the
  accurate pass over the whole audio now replaces.
- **Mid-sentence capitals** (`Okay, quindi Funziona tutto.`): the recognizer starts
  every segment with a capital and `TranscriptAssembler` keeps it (a capital at
  the start of a later segment may be a name). The cleanup repairs it; with the
  cleanup off it stays. No code rule lowercases them, except for the pieces of a
  long Whisper recording (see Whisper second pass, "Pieces").

### Kept clips and `asr-bench`

With «Keep Audio to Improve Recognition» (off by default) the recording of step 2
is moved, not copied, into `Library/Application Support/clips/` (`ClipLibrary`):
`clip-<UTC time>-<suffix>.caf` plus a `.json` (`ClipMetadata`: live, final-pass,
cleaned and inserted text, the outcome and seconds of each step, locale, input
port, the history record id; with Whisper chosen also `final_engine`,
`whisper_text`, `whisper_outcome` and `whisper_seconds`, all optional, so
`schema_version` stays 1 and older clips decode). The newest 20 are kept; the folder is excluded from
backups, outside the sync folder and the history export, and the setting has a
delete button. Clips of dictations where the recognizer heard nothing are kept
too. `tools/asr-bench` reads such a folder, runs the variants and the phone's own
texts against a reference file (clip id → right text) and prints the WER per
variant. A recognizer outside Apple's is added with `--external
NAME=/abs/path` or in `External.swift`. The phone's Whisper text shows as
`phone-whisper`, and `phone-inserted` carries `final_engine` as its note.

### Whisper second pass

An optional second `FinalPassEngine` (`WhisperFinalPassEngine`, App target only)
over WhisperKit, with the `large-v3` turbo model (632 MB). Settings > Final Text
Engine (`settings.finalTextEngine`, default `apple`) offers it only when the model
is installed. It runs after Apple's pass over the same recording file
(`DictationController.whisperPass`); Apple's result is the baseline and the
fallback.

**No network.** WhisperKit can download models and tokenizers from Hugging Face,
and `ModelUtilities.loadTokenizer` does so when no local tokenizer loads. Three
guards, the first one in `HexMobileCore` and unit tested:
`WhisperLocator` reports the model as missing unless the three Core ML models and
`tokenizer.json` + `tokenizer_config.json` of a `whisper-large-v3` folder are
under `Library/Application Support/whisper/` (model up to two folders deep,
tokenizer up to five: where `devicectl device copy to` puts a copied folder is not
documented); `WhisperModelHolder` loads the tokenizer itself from that folder
before handing it to the library; and the configuration is `download: false` with
the tokenizer folder set. Only the `large-v3` family is accepted, because its
tokenizer is the one provided. The model is copied from the Mac
(`make push-whisper-model`, README).

**Ownership.** `WhisperKit` is a non-`Sendable` class, so the actor
`WhisperModelHolder` owns it and every call goes through the actor. Its state
(`unloaded`, `loading`, `ready`, `failed`) is also readable without the actor
(a `Mutex`), because a load keeps the actor busy and the stop must be able to ask
«ready?» and move on. A deadline returns control before Core ML stops (a
prediction cannot be interrupted): a `busy` guard keeps a second run from starting
on top of it, and a release asked during a load or run takes effect when it ends.

**When it loads.** `WhisperModel` (main actor) starts the load when a flow session
opens and when a dictation starts (a no-op if it is loaded or loading), and
releases it when the flow session ends with no dictation running, when a dictation
outside a flow session ends, and on `didReceiveMemoryWarning`. A model that is not
in memory at the stop means Apple's text (`reason=not-ready`). Consequence: outside
a flow session the model loads per dictation, so it helps only when the load is
shorter than the recording. One narrow case is not handled: a flow session
*start* still in progress when a dictation outside a session ends skips the
release, and a start then cancelled leaves the model loaded until the next
release path or a memory warning.

**First load and memory after the unload.** The first load of a model, or the first
after an iOS update, makes Core ML compile it for the Neural Engine: 746.58 s
(`whisper load dt=`, iPhone 16 Pro, 2 Nov 2026, one measurement); the loads after it
took 2.9 to 3.6 s, the simulator 22 to 34 s after each install. A compile that long
only finishes if the app stays open, so Settings says it twice: a footnote under
Prepare Whisper while `WhisperModel.preparedFor` does not match the current model and
iOS version (`isPrepared`, written when a load ends `.loaded` and asked for the Neural
Engine, `WhisperLoadReport.neuralEngine`; the CPU-only load after a Core ML error does
not write it, the simulator does as before; a marker of one
success, not a check that the compiled model is still in the system's cache), and one
under the progress indicator while the load runs. Not done: keeping the screen awake
(`isIdleTimerDisabled`) or asking for confirmation, so the button stays as it was.
`unloadNow()` logs `whisper unloaded footprint=` right after `unloadModels()` and
`whisper unloaded +10s footprint= peak= state=` ten seconds later: Core ML frees late
or never, and only the second figure says whether the process went back down. `state`
is the holder's state then (`unloaded`, or `loading`/`ready` if another load began, in
which case the footprint includes it). Not measured on the phone yet.

**Time.** `FinalPassPolicy.whisperPlan`: Whisper starts only if its estimated time
and the cleanup's both fit in the 8 s after the stop. The plan is `.run(endBy:)`, an
absolute time after the stop, `8 - cleanupReserve(Apple's characters)`; the time Whisper
has is `whisperDeadline(endBy:elapsedSinceStop:) = endBy - elapsed`, and an estimate above
it is not started (`reason=budget`). The reserve is `max(1, 1.3 × (0.25 + 0.0039 ×
characters)) + whisperContentionMargin + endToEndMargin` (0.4 s and 0.45 s; zero when no
cleanup follows): the first margin is for a Core ML prediction that cannot be interrupted,
so after a deadline the model still runs on the Neural Engine while the cleanup starts (not
measured on a phone; the margin sits on top of the `max`, so the cleanup always finds at
least `minimumCleanupTime` + 0.4); the second is the one the cleanup itself keeps before
the 8 s (see **Cleanup plan** below), so Whisper's deadline moves 0.45 s earlier than in
batch 10. **The deadline is absolute because `whisperPass` awaits the
Live Activity update between the decision and `FinalPass.run`**: the first version handed
Whisper `available` as measured before that wait, so when it ran to its deadline the
cleanup was left with `reserve - wait`, and for a short text the reserve was the 1 s that
the cleanup's own guard needs to start (`reason=budget`, the cleanup skipped). Now the
plan is asked again with the clock after the wait, Whisper gets `endBy` minus that
clock, or a skip (`whisper plan skip … after-wait`) if the wait took its room;
`WhisperTests` `waitBeforeRun` shows both. No ceiling such as 1.5 × the estimate was added
(the estimate is fitted on four runs without pieces): if it is wanted, it is one constant
to place on `whisperDeadline` after the phone's measures. The estimate is
`1.15 × (0.1 + 0.4 × pieces + 0.015 × steps)` with `steps = pieces × (prompt + 5) +
6 × audio seconds` and `pieces = WhisperClips.plannedPieces` (the cut of the
recording, planned without the audio: 0.85 of the maximum on average). Fitted on four
phone runs (within 3 %); the pieces are measured on the Mac only. **The prompt tokens of
the plan are the real ones when the model is ready** (`DictationController.whisperPromptTokens`
asks the holder's tokenizer, bounded to 0.3 s with `withDeadline`; `WhisperRecipe.promptTokenCount`
builds the prompt exactly as the run will), and the cap of 100 only when it is not (state not
`ready`, no tokenizer, or the 0.3 s elapsed; the log says `prompt=100(cap)`): the first version
planned every dictation with the cap, and a 15.0 s recording with a 98-token prompt is one
piece for the run and two for the plan, so Whisper was skipped without need (`WhisperTests`
`realPromptTokens`). With the 100-token prompt it runs up to about 14.7 s (one piece; 12.5 s when
Apple's pass ended 2 s after the stop), from 15 s the estimate jumps to about 6.2 s and it is
skipped; without a prompt up to 21 to 27 s (elapsed 2 to 0.5 s, 18 characters per second; a
replica of the formulas, with the 0.4 s and 0.45 s margins; it was 24 to 29 s before the
end-to-end margin). **The policy "Whisper only if the
cleanup still fits" was chosen by the coordinator in place of the author** (2 Nov 2026):
he asked for the formatted text and then to go on without questions, so on a long
dictation Apple's text goes to the cleanup. The guard of
the Apple pass applies to Whisper's text too: at least half of Apple's words, else
Apple's text stays.

**Cleanup plan** (`FinalPassPolicy.cleanupPlan`, batch 11). The cleanup has no limit of
its own any more (before: `max(3, 1.3 × estimate)`, never more than what was left of the
8 s). Its deadline is absolute, `cleanupDeadline = 8 - endToEndMargin = 7.55 s` after the
stop (0.45 s is left for the guard, the spelling, the history and the insertion; a choice
made in place of the author, between the 0.4 and 0.5 asked for). It **starts** only if its
point estimate (`cleanupEstimate = 0.25 + 0.0039 × characters`, the same function Whisper's
reserve is worked out from) is at most what is left until the deadline, and that is at
least `minimumCleanupTime` (1 s); then its timeout is all that is left, asked again after
the Live Activity update like Whisper's. Otherwise it does not start, the log says
`cleanup dt=0.00 outcome=fallback reason=budget in=N out=0 estimate=… available=…`, and the
text arrives at once. On the phone (2 Nov 2026) 1890 characters started 1.3 s after the
stop, were cut at 6.6 s and returned nothing; now they are skipped (7.6 s estimated, 6.25 s
left), while 1127 characters (4.19 s measured) after 0.8 s start. The longest text that
still gets the cleanup is `(7.55 - Apple's pass - 0.25) / 0.0039` characters: about 1,740
after a 0.5 s pass, about 1,540 after the 1.3 s one of the long03 clip; above that the 8 s
cannot hold it. The incremental
cleanup during the recording is a batch of its own. The estimate is a line through phone
runs that overshoots the long ones (435 characters 1.65 s measured against 1.95 s,
1127: 4.19 against 4.65), so a start decision can still end in `reason=timeout` at the
deadline for a slow run (94 characters once took 0.98 s against 0.62 estimated); it then
costs no more than 7.55 s.

**Pieces.** A recording longer than the decoder room is cut at pauses
(`WhisperClips`) and read piece by piece in one call. The model starts every window as
a sentence, so a piece after a comma began with a capital («registrazioni, Perché»).
`WhisperRecipe.assemble` takes the segments of the result when there is one per
window (`withoutTimestamps`: the library writes one segment per window; the count is
checked against `totalDecodingWindows` and, if it differs, the library's text is kept)
and `WhisperClips.join` puts them together: the first letter of a piece after a comma,
a semicolon, a colon or a word with no punctuation is lowercased; after `.`, `!`, `?`,
`…` it stays, and so do words with two or more capitals and pieces that open with a
quote or bracket. Nothing else is added between pieces (a window usually starts with a
space; a cut inside a word that the model continues with no space stays one word).
The user's terms are given their spelling back by `PersonalVocabulary.respell`, which
runs on the final text. **Residual cost:** a proper name that is not a term and opens a
piece after a comma is lowercased (`bergamo`); this reverses, for Whisper pieces, the
choice the Apple join (`appendingSegment`) makes for the same reason, and it was asked
for by the coordinator (batch 10). The cleanup may give the capital back (not
verified). **The text starts with a capital** (batch 11): `WhisperClips.capitalizingFirstLetter`
is applied to the joined text and, in `WhisperRecipe.assemble`, to the library's text
when there is one window or the segments are not one per window. With the vocabulary
prompt, which ends with a comma, the model started s10 in lowercase («sta andando
proprio…», 2 Nov 2026). A first word with a capital inside (`iPhone`), a digit, a
quote, a bracket or a symbol is left alone. Log: `whisper join pieces=N lowercased=K`
(not logged for the capital). Tests: `WhisperPieceJoinTests` (the rule) and
`WhisperRecipeTests` (when it applies).

**Gap guard.** The length rule does not see a lost sentence (728 of 760 characters on
2 Nov 2026 with six words missing). `TranscriptGapGuard` (HexMobileCore, pure, tested
with the synthetic `long01` texts of that day and with the cases of the batch-9 review)
aligns the text in hand and Whisper's word by word (longest common subsequence over
`WordErrorRate.words`, a table capped at one million cells). Between two matched words
it counts the words of the text in hand left over (`unmatched`) and the words of
Whisper's left over (`written`): a word replaced by another is a substitution, one for
one. `Gap.missing` is `unmatched - written`. **Two things were added in batch 10** after
the review: (1) gaps with exactly one matched word of two letters or fewer between them
are one gap (`shortAnchorCharacters`; the aligner takes any `il`, `di`, `e` inside a lost
stretch as an anchor and split a loss of five in two and three; the anchor itself is not
counted); (2) a gap is also refused when `unmatched` reaches the run and Whisper wrote at
least `coverNet` (half the run rounded up, 3) fewer words, because a loss covered by a
hallucination (a subtitle credit, a thanks, in the silence that pads a piece to 30 s) has
a net below the run: nine lost, five invented, net 4. The cover net is a choice made in
place of the author, not fitted to a phone text; a rewording with as many words as it
replaces has a net of 0 and passes (5 by 5, 9 by 9). The rule that was proposed, to
refuse `unmatched` at twice the run (10), would have let the nine-word case through.
`FinalPass.run(gapGuard:)` uses `TranscriptGapGuard.judge`, a verdict (`accepted`,
`refused(Gap)`, `notJudged(cells:)`): texts too long to align used to pass without a
trace, and now the log says `guard skipped reason=too-long cells=…`. The refusal logs
`guard gap=N at=i … unmatched=R written=C`, so the log says which rule fired. The
guard runs only for the Whisper pass. **Its reference is the text in hand, which is
Apple's pass when it was used and the live transcript when the Apple pass fell back**
(`StepResult.text` of the Apple step is `live` then): in that case the log calls the
baseline `live` (`live_words=`, `live=`), not `apple`. The first pass (Apple against the
live transcript) does not use the guard: the live text is the one with errors.
Not done: removing known Whisper hallucination phrases ("Sottotitoli creati dalla comunità
Amara.org", "Grazie per la visione") at the end of a piece. No such text was looked for in
the clips measured so far, a phrase list edits speech, and what it would fix is what the
cover rule already refuses; `guard gap` lines with `written` above 0 on the phone will say
if it is needed.

**Kept clips and logs.** `StepResult.engine` and `.whisper` carry the result to
`ClipMetadata`; the log lines are listed in the README (Whisper on the iPhone).
Simulator debugging: `-HexMobileFakeEngine YES -HexMobileFakeClip <wav>
-settings.finalTextEngine whisper -HexMobileWhisperDeadline N -HexMobileFakeFinalPass fail`
and `make push-whisper-model-sim`.

## Triggers and the flow session

`DictationController` (main actor) is the single state machine:
`idle → preparing → recording → processing → idle`. After `stop()` it applies
the text pipeline, writes the record to history, puts the result on the
pasteboard (when Copy to Clipboard is on, and always for keyboard dictations),
posts `done`, and optionally exports history to the sync folder.

- **In app**: `RecordButton`, tap to toggle, hold for push-to-talk.
- **App Intents** (`Shared/SharedIntents.swift`, `App/Sources/Intents`):
  `ToggleDictationIntent` is an `AudioRecordingIntent`; the system runs it in
  the app process and a Live Activity is shown while recording, which iOS
  requires for background recording. It returns the text as intent output.
  `StopDictationIntent` (Live Activity stop button) and
  `StartFlowSessionIntent` complete the set; `HexMobileShortcuts` exposes them
  as App Shortcuts. The shared intents compile into the widget extension too;
  there they fall back to posting a Darwin notification to the app.
- **Control Center / Action Button**: `DictationControl` is a
  `ControlWidgetButton` running `ToggleDictationIntent`. It is not a toggle
  because the extension cannot read the app's state without an App Group. Its
  kind is the constant `io.github.hexmobile.control.dictation`, independent of
  `BUNDLE_ID_PREFIX`.
- **Flow session**: the app keeps its audio session active in the background
  (`UIBackgroundModes: audio`), discards input until a dictation starts, and
  ends the session after the idle time from Settings (`FlowSessionDuration`:
  5 minutes by default, 15, 60, or Never; see below). A Live Activity shows
  the session as ready. When the session ends
  the activity stays up in a standby phase (microphone off) until its stop
  button ends it. The exception is a session opened by `ToggleDictationIntent`
  (below): it ends with its dictation, once the keyboard has taken the text.
- **Idle time of a flow session** (Settings > Flow Session > End After Idle, a
  menu: 5 minutes, 15 minutes, 1 hour, Never). `FlowSessionDuration` (in
  `HexMobileCore`, tested) is stored as minutes, 0 for Never, under the key the
  old 1–30 minute stepper used, so an installed app keeps its setting: a stored
  value rounds up to the next choice (1–5 → 5, 6–15 → 15, 16 and more → 60),
  never down, because a session must not end sooner than it was asked to.
  `DictationController.scheduleFlowTimeout` arms the timer from it, and arms none
  for Never (`flowSessionEndsAt` is `nil`, and the Dictate card says «Stays on
  until you end it»). A session opened by `ToggleDictationIntent` keeps the 5
  minute default even with Never, since it lasts one dictation. Changing the
  setting while a session waits (`flowSessionDurationChanged`) re-arms or drops
  the timer at once and refreshes the Live Activity; a session that records,
  starts or hands a text to the keyboard takes the new value at its next idle
  period. The Live Activity's `ContentState.neverEnds` (`true` or `nil`, so an
  older activity decodes) is set by `LiveActivityManager.show` while a flow
  session with Never holds the microphone (not in `standby`, not in `handoff`):
  the Lock Screen subtitle and the expanded island read «Stays on until you end
  it», and in the `ready` phase the island's trailing region shows an infinity
  sign where the timer would be. The compact and minimal islands carry no text
  and are unchanged. Log lines: `flow timeout in …s opener=…`, `flow timeout
  none (never) opener=…`, `flow session duration changed to … phase=…`, `live
  activity neverEnds=… phase=…`. Never does not make the session permanent: an
  audio route change, an interruption, the user's stop button or iOS ending the
  app still end it. da verificare: ActivityKit ends a Live Activity after a
  maximum of 8 hours, and nothing here ends the session or requests a new
  activity when that happens (a Never session would then hold the microphone
  with no island; the system's microphone indicator stays).
- **The keyboard's microphone with no flow session** (`hexmobile://dictate`,
  modelled on Wispr Flow's keyboard): one tap opens the app, which dictates at
  once. `AppServices.dictateFromRoute` waits until the scene is active (at most
  3 s: `onOpenURL` can run first and the audio session starts from the
  foreground), opens the flow session if there is none, starts a dictation with
  trigger `keyboard` and shows `KeyboardDictationView`: a screen that says
  «Listening», the live words and how to go back, with Cancel and Done. Log
  lines: `route dictate source=… phase=… app=…` on entry (`app=0` is
  `UIApplication.State.active`), `route dictate started=… waited=…s` at the end,
  `route dictate flow session failed` when the session did not open. A repeated
  link while dictating only shows the screen again. The dictation does not wait
  for the user: it goes on when they do not go back, and stops from the keyboard,
  the Live Activity or the screen's Done. There is no timer of 10 s as in Wispr
  Flow's docs; the start's own 30 s preparing watchdog bounds the start.
  The screen closes by itself when the dictation ends (an empty transcript
  counts as ended); an error stays until Close, with Retry.
  Going back to the previous app is up to the user: iOS gives a keyboard no
  public way to know the host app (`_hostBundleID` is nil since iOS 18 and
  26.4 in the Apple developer forum reports, threads 811992, 836168, 826851) and
  the app no way to return to another one (`UIApplication.suspend` goes Home;
  `sourceApplication` returns the extension's container). Private APIs are out
  of scope. What remains is the system's: the button at the top left that iOS
  shows when an app opens another through a URL (not confirmed for a link that
  a keyboard extension opens), and the swipe right along the Home bar. A
  dictation of trigger `keyboard` is also offered over loopback when it ends
  with the app in the foreground (the user pressed Done on that screen), so the
  keyboard inserts it when it shows again.
- **Starting from an App Intent** (Action Button, Shortcuts): a start that
  needs the microphone in the background always ends any existing Live
  Activity and requests a new one before it starts audio
  (`LiveActivityManager.show(fresh:)`, passed by `startFlowSession` when
  `requiresLiveActivity` is set). If the engine refuses (`engine.start` fails
  with `'what'`), the start keeps that activity and retries `audio.start()`
  five more times with pauses of 0.2, 0.3, 0.5, 0.8 and 1.2 s (about 3 s in
  all, `DictationController.flowAudioRetryDelays`). After each `engine.start`
  failure the next attempt gets a new `AVAudioEngine`
  (`AudioCapture.replaceEngineAfterFailedStart`). A new Live Activity is
  requested only if the current one has ended
  (`LiveActivityManager.hasActiveActivity`), and logged.
  Fallback ladder (added the same evening, after the log of 19:10Z: six
  attempts over 3.5 s, one engine replaced each time, all `'what'`, while the
  press after worked at attempt 0; the OSLog dump showed `output client: 2 ch,
  0 Hz` right before `AUIOClient_StartIO failed`). Replacing the engine alone
  never touched the audio session, so every attempt ran on the same session
  and the same route. So, once an `engine.start` has failed and only then,
  `AudioCapture.prepareRetry(_:)` runs before the next attempt, in one
  synchronous turn with no `await` between its steps and the next
  `audio.start()`: after the first failure the `session-reset` variant
  (`setActive(false, .notifyOthersOnDeactivation)`, `setCategory` again with no
  shortcut, `setActive(true)`); from the second failure on the `record-only`
  variant (`setActive(false)`, then `.record` with `[.allowBluetoothHFP]`:
  input only, no output unit; `mixWithOthers` and `defaultToSpeaker` are valid
  only with `.playAndRecord` and would make `setCategory` fail). `.record` is
  never the default: it removes `mixWithOthers`, so other audio is interrupted
  while it runs. It is left when the dictation or the session ends
  (`AudioCapture.stop()`), when a start gives up, or when the app is in the
  foreground with nothing capturing (`configureCategoryForForeground()`,
  called on scene `.active`); a `setCategory` refused from the background
  (`!int`) leaves the flag set and the next start keeps using `.record`. A
  start that works at the first attempt never reaches any of this. The calls
  are made on the main thread on purpose (a thread-hang check flags
  `setActive` there): putting them in a detached task would put a suspension
  point between deactivating and reactivating the session.
  Each attempt logs the session's category and options, the outputs of the
  route (count and port types), sample rate, output channels and output
  latency; `flow audio retry variant=… steps=[…]` logs what each step did, and
  `flow audio unblocked by variant=…` names the variant in effect when an
  attempt worked (order, not proof). Verified on the iOS Simulator 27.2
  (`-HexMobileSimulateWhat 1|2|7`, simulated failures): the reset steps are
  accepted, `setCategory(.record, options: [.allowBluetoothHFP])` is accepted
  (`options=4`, `outputs=0[]`), the category is restored at the end, and a
  start that fails six times ends at about 4.3 s instead of 3.5 s because of
  the session resets. Not verified: that either variant clears the real
  `'what'`, and whether iOS accepts `setCategory` from the background with
  the app suspended soon after, both only visible on the device.
  Why the old rounds were removed (evening device log of 1 Nov 2026, iPhone
  16 Pro, build 2785a68): the first press, 4 s after the app went to the
  background, had its activity (`requestedNew=true age=0.1s`) and failed on
  `engine.start` four times; the old code then ended that activity, the new
  request from the background returned `shown=false`, and rounds 1 and 2 ran
  with `activities=n=0[]` and failed the same way. The press 17 s later, a new
  `perform()` in the same process and on the same `AVAudioEngine` that had
  failed 12 times, started on its first attempt, and so did a cold launch from
  the Action Button 55 s after that (`t=0.4s`). So a Live Activity requested
  again does not explain the difference, and neither does a new engine
  instance (the working press reused the failed one); the cause of `'what'` is
  not known. Starts from the app, the URL and the keyboard keep updating the
  existing activity.
  If every attempt fails, the activity is ended, no session stays open and a
  start that `ToggleDictationIntent` opened sets the message «Dictation could
  not start. Press the Action Button again.» (Italian: «La dettatura non è
  partita. Premi di nuovo il Tasto Azione.»), because a second press has
  worked every time in the device logs of 1 Nov 2026. The system error stays
  in `diagnostics.log`. Other starts keep the system's own text.
  A second press inside those attempts cancels the start. `isFlowSessionActive`
  only turns on after the audio started, so the second `perform()` used to see
  no session and began a second loop on the same `AudioCapture`.
  `DictationController.isFlowSessionStarting` now marks the window:
  `IntentBridge.toggleDictation` sees it, calls `cancelFlowSessionStart()` and
  returns `""` without dictating (log: `intent press cancelled flow start`);
  the running start notices within 50 ms, ends the activity it requested and
  returns with no error (`flow start cancelled by a second press`), and its own
  `perform()` returns `""` too (`intent start abandoned during flow session
  start`). Any other opener that asks while a start runs is ignored (`flow
  start already in progress`).
  A start that fails after that always reaches the user: `IntentBridge`
  throws an `IntentFailure` with the reason, and Shortcuts shows it. Only a
  stop that heard nothing ends quietly with an empty result. If the intent had
  opened the flow session itself, a failed dictation closes it again and ends
  its Live Activity (`endFlowSession(dismissActivity: true)`); before, the
  microphone and a `ready` activity stayed up until the idle timeout
  (simulator, 1 Nov 2026).
  **One dictation per session** (decision of 1 Nov 2026, amended the same
  day): the flow session that `ToggleDictationIntent` opens ends with its
  dictation, as soon as the keyboard has taken the text. `DictationController`
  records who opened the session (`flowSessionOpener`, `.toggleIntent` or
  `.other`, set only when this call opens it and reset in `endFlowSession`,
  the one place every session end goes through). `finishCycle`, which every
  dictation ends in (text, empty transcript, failure, cancel, stop button of
  the Live Activity), decides for an intent-opened session:
  - Nothing offered to the keyboard (empty transcript, failure, cancel, or a
    text finished inside the app, where the pasteboard write works): close at
    once, `endFlowSession(dismissActivity: true, cause: .dictationEnded)`:
    microphone off, Live Activity ended.
  - A text offered over loopback (finished in the background: the pasteboard
    write is dropped there, `pbChange=0` in the device log of 1 Nov 2026): the
    session stays up, its Live Activity in the `handoff` phase, until
    `LoopbackHandoff` reports the payload settled (`onSettled`): the
    keyboard pulled it (`loopback served`, then `cause=handoff-served`) or
    `LoopbackHandoff.ttl`, 60 s, ran out (`loopback expired`, then
    `cause=handoff-expired`). Both end with `dismissActivity: true`. The
    `handoff` phase (`DictationActivityAttributes.ContentState.Phase`, shared
    by the app and the widget extension, which are installed together) shows
    the title «Text ready», the first `DictationController.handoffPreviewLength`
    (120) characters of the text on one line in `liveText`, cut at the end
    (the recording phase cuts at the start), and the hint «Open the Hex Mobile
    keyboard to insert it»; `LoopbackHandoff.pendingText` carries the text and
    is cleared with the payload. The reason for keeping the session is
    that only the running audio session keeps the app alive in the
    background and the pull is served by this process: closing the session at
    the end of the dictation (commit 51ea74c) would let iOS suspend the app
    before the pull, which came 4 to 39 s after `done` in the device log
    (ipotesi: not measured; reported before any device run). A timer of
    `ttl` + 2 s runs during the wait: a backstop for a settlement that never
    comes, and the end time the Dictate card shows (`flowSessionEndsAt`). Like
    every end of an intent-opened session by timeout, it dismisses the Live
    Activity.
  - A new Action Button press inside the wait cancels it
    (`handoff wait cancelled by a new dictation`): the dictation runs in the
    same session, which stays intent-opened and applies these rules again at
    its end. A payload still pending keeps the session up through a press that
    fails.
  - An explicit request takes the session over: `startFlowSession` called with
    `.other` while an intent-opened session is live makes it `.other` (log
    `flow session adopted opener=intent->other`), cancels the wait and leaves
    the normal idle timeout; the text is still served to the keyboard. Callers
    found in the code: `StartFlowSessionIntent`, the
    `hexmobile://session/start` link and the `hexmobile://dictate` one, which
    the keyboard opens only from a tap
    on its microphone key with no `pong` (its automatic traffic, `ping` and the
    loopback pull at `appear()`, never starts a session). The Dictate and
    Settings buttons start a session only when none is live (they read End Flow
    Session otherwise), so they cannot take one over. A keyboard dictation
    (`toggle` signal) inside an intent-opened session does not take it over:
    the session ends after it by these rules (open question for the author).
  A session that existed when the press arrived, or that
  `StartFlowSessionIntent`, the keyboard, the Settings button or the
  `hexmobile://` link opened, keeps its idle timeout. Every end is logged:
  `flow session ended cause=… opener=…`, with the cause `user`,
  `idle-timeout`, `live-activity`, `interruption`, `audio-config`,
  `dictation-ended`, `handoff-served`, `handoff-expired` or `intent-failed`;
  `handoff settled outcome=… waiting=…` records every settlement,
  `loopback served` / `loopback expired` the payload itself, and
  `handoff activity phase=handoff preview=N chars shown=…` the Live Activity
  update that shows its start (the count, never the text). A pull that lands
  before `finishCycle` ran (during the history write) finds nothing pending
  there and closes with `dictation-ended`. Observed on the simulator (1 Nov
  2026), where a transcription cannot run, with a synthetic payload
  (`-HexMobileAutoHandoff`, Debug) and the keyboard's request played from the
  Mac (`printf 'HEXMOBILE-PULL 1\n' | nc 127.0.0.1 47391`): `hold` then pull,
  `loopback served 204 bytes`, `handoff settled outcome=served waiting=true`,
  `flow session ended cause=handoff-served opener=intent
  dismissActivity=true`, and the system log shows the activity gone; `hold` and
  60 s without a pull, `loopback expired`, `cause=handoff-expired`, and a late
  pull reads 0 bytes; `press`, where the start fails with `modelUnavailable`:
  `handoff wait cancelled`, the session stays up with the payload pending, the
  pull then ends it; `adopt`: `flow session adopted opener=intent->other`, the
  pull settles with `waiting=false` and the session stays. The success path
  (second press with a real text) cannot run there. Earlier, with
  `-HexMobileAutoStartIntent YES` and a start that fails with
  `modelUnavailable` and no text: `cause=dictation-ended` at once.
  A second press while the start is still `.preparing` cancels it (unchanged:
  only the author changes that) and a press during `.processing` does nothing;
  both are logged (`intent press cancelled|ignored phase=…`). The first
  intent, whose start was cancelled, closes the session it opened
  (`intent start abandoned …`); before, it returned `""` and left the
  microphone and the Live Activity up.

`Diagnostics` (`App/Sources/Support/Diagnostics.swift`) keeps a local log of
start-up events in Application Support (`diagnostics.log`, excluded from
backups, last 1000 lines, never dictated text). Every failed audio attempt,
in the flow-session retry and in `start()`, writes one line with: path,
attempt and seconds since the first attempt; the stage that failed (`setCategory`, `setActive`,
`inputFormat`, `engine.start`); the error domain, code and four-character
code (2003329396 reads `what`); the input node's format and the audio
session's sample rate and channel count; the input route; whether other audio
is playing; seconds since the process started (the kernel start time, not the
first log line); and the Live Activities (count, `activityState`, whether the
current one was requested by the last `show` or only updated, and its age).
A successful flow-session start logs the same time and activities. The
keyboard keeps its own log (`KeyboardDiagnostics`, 200 lines).

The keyboard log also tells a crash from a process that iOS ended (the phone
had three `HexKeyboard` SIGABRT crashes on 1 Nov 2026 and then none, while the
keyboard still fell back to the previous one; other developers report that iOS
ends a keyboard that goes over its memory limit, about 60 MB of
`phys_footprint`, without a crash log: reported, not measured here).
`keyboard process started pid=… kernelStart=…` is written once per extension
process, from the first controller's `viewDidLoad`; `appear` (`viewWillAppear`),
`appeared` (`viewDidAppear`, after the first layout) and `disappear` carry the
pid and `footprint=…MB available=…MB controllers=N models=N`: `phys_footprint` from
`task_vm_info` (the figure the limit is compared with), `os_proc_available_memory`
(`n/a` on the simulator, which reports 0), the keyboard controllers alive and the
keyboard models alive;
`didReceiveMemoryWarning` writes `keyboard memory warning`, and while recording
`keyboard recording t=…s` repeats the footprint every 10 s. Measured on the iOS
Simulator 27.2 (1 Nov 2026, `-HexMobileKeyboardProbe`, the fake engine, one fresh
keyboard process): 9.1 MB at process start, 19.4 MB at `appear`, 20.0 MB at
`appeared`; while recording 20.2 MB at 0 s, 22.4 MB at 10, 20 and 30 s (growth in
the first ten seconds, flat after). With the level-driven blob (same setup, fresh
process, a 4 s wave as the fake level): 9.3 MB at start, 19.5 at `appear`, 19.9 at
`appeared`, 20.1 at 0 s of recording, 22.3 at 10 s and 22.4 at 20, 30 and 40 s: the
same as with the fixed level.

Keyboard memory leak (found 1 Nov 2026, fixed in batch 8). The device log of
that day (`build/device-logs/b6t-kb.log`, one keyboard process, pid 3556, 20:30:57Z
to 20:46:53Z) showed the footprint at `appear` rising from 19.6 to 42.2 MB over
eleven sessions (about 2 MB each), a jump to 82.5 MB at 20:43:56 (the previous
controller's `deinit` came 105 s after its `disappear`), then 83 to 87 MB; no
`keyboard model deinit` anywhere; and at 20:45:48 every Darwin signal three
times (`sessionEnded`, `stateRecording`, `done`), `keyboard recording t=0s`
three times, and `insert blocked: no full access` twice before the live model
inserted the text. Three models were subscribed with one controller alive: the
two others belonged to controllers that had gone (their `hasFullAccess`
closure, weak on the controller, read `false`). Footprint plus `available` was
about 176 MB on every line and the process id never changed, so in that window iOS did
not end the process for memory (the peak, 87 MB, is half the limit it
reported); the fall back to the previous keyboard is not explained by this log.

Cause. The same happens on the simulator when the host app is killed (`simctl
terminate` between `-HexMobileKeyboardProbe` launches): `viewDidDisappear` does
not arrive, the controller and its `UIHostingController` deallocate, and the
SwiftUI graph stays alive with the model it holds. `heap` after five such
sessions listed 5 `KeyboardModel`, 5 `_UIHostingView<KeyboardView<GlobeKey>>`
and 130 `LetterKey` (26 letter keys per graph). `leaks --traceTree` on a
hosting view listed, among its paths to a root, the graph's own
`ViewGraphDisplayLink` registered in `CA::Display::DisplayLink::_list` (the blob
is a `TimelineView(.animation)`, which asks for frames at display rate) and a
`DynamicContainer` item held by the run loop's delayed performers. An earlier
test with `animated: false` on the blob freed nothing, so the display link is
one path to a root, not shown to be the only one. The listener was the second
half: each model opened its own Darwin stream in `appear()` and
closed it only in `disappear()`, so a model that never got `disappear` kept
handling signals, once per model (the simulator printed 1, 2, 3, 4 and 5
`signal sessionEnded` lines for one ping over five killed-host sessions).

Fix, which does not depend on `disappear` arriving:

- `KeyboardSignals` owns the only Darwin streams of the process (one for the
  seven signals, one for the debug keys) and hands each element to the model that
  called `appear()` last, held weakly (`SignalRelay` in HexMobileCore, with unit
  tests). A model that is gone, or that was replaced, receives nothing.
- `KeyboardViewController` has an `isolated deinit` that empties the hosting
  controller's root (`KeyboardRoot(model: nil)`), takes the hosting view out of
  its superview and calls `KeyboardModel.shutdown()` (cancels its tasks and drops
  the controller's closures). Which of those steps releases the graph was not
  isolated; together they do.
- The live-level polling loop ends when its model is gone (it used to keep asking
  the app every 150 ms for nobody), and `pullThenInsert` no longer holds the model
  while the loopback request runs.
- A model that something still holds after `shutdown()` (the leaked SwiftUI graph
  above) has `actions` that insert nothing. A pull that woke up after the teardown used
  to mark the dictation as inserted before calling them, and the keyboard shown next
  skipped a text nobody typed. Now `isShutDown` makes `insert` and
  `insertLatestDictation` return (`insert dropped: keyboard shut down` in the
  keyboard log) and the id is marked inserted after `actions.insertText`, in the
  same main-actor step. Not covered by a test (the keyboard target has none); a text
  proxy that drops the text silently cannot be told from one that took it. **Limit:**
  a payload pulled over loopback and dropped this way is lost to that route (the app
  serves it once); leaving its id unmarked only keeps the pasteboard route, when it
  holds the same text, from skipping it.
- The log counts models: `models=N` on every line that has `controllers=`, `keyboard
  load` before any SwiftUI, and `keyboard model deinit models=N`.

Measured on the iOS Simulator 27.2 (1 Nov 2026), same probe, same device: before,
five killed-host sessions raised the footprint at `appear` from 19.5 to 29.3 MB and
left 5 models and 5 hosting views; after, in one process, five killed-host
sessions, five orderly ones and six more killed-host ones kept it between 19.6 and
21.8 MB, every controller `deinit`
was followed by `keyboard model deinit models=0` in the same second, `heap`
showed one `KeyboardModel` and one hosting view (the live ones), and after
posting `pong`, `state.idle`, `state.recording` and `state.idle` once each from
`notifyutil` the log had one `signal` line per post. Not measured: a device (the
build is on the author's phone only once it is installed; the `appear` and
`keyboard model deinit` lines of a day of use will say). The +40 MB step on the
device is not explained: it fell between a `disappear` and the next `appear`
with no controller alive for 105 s, and the `appear` to `appeared` step is 0.2 to
0.5 MB on every line, so it did not come from building this view; the old
graphs kept rendering, each with a blur-filtered `Canvas` at display rate, which
is a hypothesis, not a measurement. `keyboard load` (before SwiftUI) and
`appear` now bracket it. The idle keyboard is not quiet on the simulator
either: about 7 to 10 percent of one core of the Mac with the keyboard visible and
nothing happening, from the blob's `TimelineView(.animation)`; left as it is.

Keyboards loaded and never shown (found 2 Nov 2026, fixed in batch 9). The phone
log of that day after the batch 8 fix (`build/device-logs/b8-kb.log`, pid 5415,
from 08:35:54Z): one `signal` per event, but `controllers=` rose from 1 to 7 and
the idle footprint from 13 to 28 MB in 30 minutes. Every `keyboard load` that was
not followed by an `appear` never got a `keyboard controller deinit` (cases at
08:37:14, 08:47:39, 08:47:47 and 08:48:47); the controllers that appeared were freed
about a second after `disappear`. Every reference to the controller in our own
code is weak.

Reproduced on the iOS Simulator 27.2 with `-HexMobileKeyboardProbeFlick 10`
(`-HexMobileKeyboardProbeFlickMs 40`: the field asks for the keyboard and gives it up
40 ms later): `keyboard load` seven times with no `appear`, `controllers=7
models=7`, footprint 20 to 32 MB, `heap` with 7 `KeyboardViewController` and 182
`LetterKey` (7 × 26). `leaks --traceTree` on one controller (41 paths to roots, 36
of them the same): controller, an array, the hosting view's `ViewCache`,
`_UIHostingView<KeyboardRoot>`, its `ViewGraph`, the graph's own `ViewGraphDisplayLink`,
`CADisplayLink`, the main run loop. The SwiftUI graph of a hosting view that is in no
window keeps running on its display link (the blob is a `TimelineView(.animation)`)
and holds the controller. Taking the target off the globe key
did not change it (tried, not kept), so it is not that. Which object of the graph holds the
controller was not isolated; not building the graph was enough.

Fix, which does not depend on iOS letting the controller go: `viewDidLoad` builds
nothing but the black view and its 300 pt height (the constraint is on the view
itself, so the keyboard has its size before the hosting view exists). The model
and the `UIHostingController` are built in the first `viewWillAppear` (nothing there
reads the text document) and torn down in `viewDidDisappear` (the hosting view
leaves the hierarchy, `KeyboardModel.shutdown()`), and again in `deinit` as before.
A controller that is loaded and never shown is a bare view with no model.
`keyboard controller deinit … unshown` marks one freed without having appeared;
`controllers=` counts only controllers whose `viewDidLoad` ran.

Measured on the same simulator and device, same probe, after the change, in one
keyboard process (pid 74588): three runs of 20 cycles with a 40, a 1200 and a 300 ms
gap, one probe launch with the screenshot and three launches whose host was ended
while the keyboard was up (no `disappear`): 39 `keyboard load`, 21 of them with an
`appear` and 18 without; `controllers=` never above 2, `models=` never above 1; 17
`deinit … unshown` lines a second or two after their load (the 18th is not in the
log window kept; ipotesi: freed when the host was ended); footprint at `appeared`
18.9 to 23.2 MB with no trend (the same probe before: the footprint at `keyboard
load` went from 20.3 to 32.2 MB over seven loads); after the host was ended `heap` listed 0 `KeyboardViewController` and 0
`LetterKey`, and the killed-host sessions ended with `controller deinit` and `model
deinit models=0`. A simulator screenshot with the keyboard up shows the 300 pt keyboard
drawn whole (`build/b9-shots/kb-after-lazy.png`, not committed).
Not measured: a device (the lines `keyboard load … controllers=N models=N`,
`appear`, `keyboard controller deinit … unshown` of a day of use will say), and the
flash on a real keyboard transition (the simulator shows the keyboard from the first frame
it could capture, not the animation).

`AudioFailureLog` (`App/Sources/Support/AudioFailureLog.swift`) adds a second
file, `audio-failure-oslog.log`, for the cause that the error code does not
give. At the first `engine.start` failure of a start (flow session or
`start()`), it reads `OSLogStore(scope: .currentProcessIdentifier)` from 5 s
before the failure to 0.25 s after it, keeps the entries whose sender,
subsystem or category contains `audio` (the newest 40, 240 characters each)
and appends them to the file under a header with the UTC time, the app state,
`backgroundTimeRemaining`, the record permission, `isInputAvailable`,
`secondaryAudioShouldBeSilencedHint` and the session's category, mode and
options. The file keeps 500 lines; the read runs in a detached task, so the
retries do not wait for it, and `diagnostics.log` gets
`oslog dumped n=… scanned=…`. Observed on the iOS Simulator 27.2 (1 Nov 2026,
`-HexMobileAutoOSLog YES`, a flow session and the dump forced, not a failure):
the store returns this process's CoreAudio, AVFAudio and AudioToolbox entries
(`scanned=505`, `n=40`, about 1 to 2 s to read), with senders `AudioToolbox`,
`AudioToolboxCore` and `libEmbeddedSystemAUs.dylib` and subsystems
`com.apple.coreaudio` and `com.apple.avfaudio`. Not observed: the same on a
device, and whether the lines name the cause of `'what'` (it does not happen
on the simulator). Copying the file: README, Diagnostics.

A dictation that dies silently (device log of 1 Nov 2026: four Action Button
dictations inside an open flow session wrote `live activity push #1 chars=0`
and nothing after) is told apart by two additions, made without a fix because
the cause is not known (ipotesi: the process is suspended or killed while no
audio arrives). The `live activity push` line, written at pushes 1, 21, 41 and
so on (every 9 to 19 seconds in the device log of 1 Nov 2026), now ends with `buffers=` (input buffers the
tap delivered since the transcription sink was attached, that is since the
recording started; with no sink ever attached, as in a bare flow session,
since the engine started), `lastBuffer=` (seconds since the last buffer; `-` before
the first), `level=` (the smoothed input level), `footprint=` (`phys_footprint`
in MB from `TASK_VM_INFO`, the figure memory pressure is judged on),
`available=` (`os_proc_available_memory`, MB left before the per-process
limit; `n/a` on the simulator, which reports 0) and `bgTime=` (`-` in the
foreground, `unlimited` or the seconds left in the background). Read together:
buffers growing with `level=0.00` is a muted microphone; `lastBuffer` growing
or `buffers` stuck is no audio; a footprint close to the limit, with
`available` near 0, is memory. A separate `lifecycle` line (same footprint
fields) records `didBecomeActive`, `willResignActive`, `didEnterBackground`,
`willEnterForeground`, `didReceiveMemoryWarning`, `willTerminate`, scene
`willConnect` and `didDisconnect`, and `process started pid=… t=…` once per
process; the `scene phase` line records every SwiftUI scene-phase change. A
kill by the system (jetsam, or a suspended process that is then killed) sends
no notification, so it shows as the log stopping and the next `process
started` line, not as `willTerminate`; the lines before it say the last state
the app was in. The app registers no background task (nothing calls
`beginBackgroundTask`), so there is no expiry to log.
`-HexMobileAutoFlow YES` (Debug) opens a flow session for the listening
seconds and logs the audio fields, to check them on the simulator.

## App ↔ keyboard IPC

There is no App Group, so the app and the keyboard share nothing on disk. They
use two system channels, with constants in `HexMobileIPC`:

| Channel | Direction | Content |
|---|---|---|
| Darwin notifications (`DarwinNotificationCenter`) | keyboard → app | `io.github.hexmobile.ping`, `.toggle` (stop and transcribe, or start), `.cancel` (the ✕ key: drop the dictation, no text) |
| | app → keyboard | `.pong`, `.state.recording`, `.state.processing`, `.state.idle`, `.done`, `.start.failed` (a start or a dictation failed; the reason is on loopback) |
| | widget → app | `io.github.hexmobile.stop` (`SharedSignal.stop`) |
| `UIPasteboard.general` | app → keyboard | plain text + `io.github.hexmobile.dictation` (JSON `DictationPayload`: id, text, created_at, locale, engine) |
| TCP `127.0.0.1:47391` | app → keyboard | request `HEXMOBILE-PULL 1\n`, reply = JSON `DictationPayload` (served once); `HEXMOBILE-LIVE 1\n`, reply = live transcript text while recording; `HEXMOBILE-LIVE 2\n`, reply = the microphone level as `0.00`..`1.00`, a newline, then the same transcript (the keyboard polls this one about every 150 ms while recording; 0 when no session records; `HexMobileIPC.parseLiveLevelReply`); `HEXMOBILE-ERROR 1\n`, reply = the reason of the last failed start or dictation (empty when none; not consumed, kept up to 60 s or until a new start or the keyboard's Close). iOS drops pasteboard writes from a background app (measured 1 Nov 2026, iOS 27.2), and a free signing team has no App Group. The app listens only while a result is pending (max 60 s), serves it once, loopback only. |
| URL `hexmobile://dictate?source=keyboard` | keyboard → app | best-effort launch: the app, in the foreground, starts a flow session if there is none and dictation at once (trigger keyboard). `hexmobile://session/start` (flow session only) stays valid |

Darwin notifications carry no payload, only names. The keyboard:

1. on appear, listens for app signals and posts `ping`; with no `pong` within
   700 ms it assumes no session is running;
2. on mic tap, posts `toggle` when a session answered, otherwise opens
   `hexmobile://dictate?source=keyboard` (log `keyboard dictate opened=…`). The
   keyboard is usually suspended while the app is in front; when it shows again
   `appear()` pings and finds the recording. If it was not suspended and the app
   still does not answer 2 s later, it shows how to start by hand;
3. on `done`, reads the payload from the pasteboard and inserts it with
   `textDocumentProxy`, only if the payload is fresh (120 s) and its id was not
   inserted before. A manual Insert key skips the freshness check but keeps
   the once-per-id rule;
4. while recording, shows ✕ and ✓ (the mic key becomes ✓), and the voice blob in the
   mic key follows the microphone level: the app sets
   `LoopbackHandoff.setLevel` from its 33 ms level meter, the keyboard reads
   it with `HEXMOBILE-LIVE 2` about every 150 ms (`KeyboardModel.level`, 0 when
   not recording) and gives it to `ParticleBlob`, which eases it every frame.
   With Reduce Motion on, the blob is not animated: it is redrawn at each
   reading, its size and brightness the level indicator. The blob's cost in
   memory was measured (see the keyboard memory paragraph above). ✓ and a tap on the
   mic key send `toggle` and remember the stop request (`stopRequestedAt`), so
   the `done` that follows inserts the text. ✕ sends `cancel`, forgets the stop
   request and the pasteboard mark, and the app answers with the idle state and
   no `done`. `DictationController.cancel()` writes nothing to the pasteboard,
   offers nothing over loopback and adds nothing to the history (log:
   `keyboard cancel phase=… pending=…`, `keyboard cancel done … pending=…
   changeCount=…`; the keyboard's own log has `keyboard cancel` and `keyboard
   finish`). Like `toggle`, `cancel` is not authenticated: another app could
   post it during a dictation;
5. on `start.failed`, reads the reason with `HEXMOBILE-ERROR 1` (up to four
   tries 250 ms apart: the app opens the listener as it sets the reason, and the
   signal can win the race) and replaces the top bar with an orange triangle,
   the reason, a Close key and a Retry key. Without Full Access, or when the
   app does not answer, the text is «Dictation could not start.» A new
   recording or transcription, `done` or hiding the keyboard removes the bar.
   Close drops it and posts `cancel` (the app, with nothing to cancel, clears the
   reason and answers with the state); Retry drops it and, 300 ms later, does what
   a mic tap does (`toggle` with a session, the `dictate` route without). The app
   publishes the failure (`DictationController.publishFailure`) from `fail()`, a
   start while the last one is still stopping, the flow-session start (permissions,
   Live Activity, audio), a cancelled preparation and a flow session ended by an
   audio route change; a `ping` answer repeats the signal while a reason is pending,
   so a keyboard that was hidden when it happened still shows it. The app's own
   error screen of the `dictate` route clears the reason when closed. Log lines:
   `keyboard error signal`, `keyboard error shown chars=… fromApp=…`, `keyboard
   error closed`, `keyboard error retry`; the app's `keyboard failure published`.
   Verified on the iOS Simulator 27.2 with the real engine (no speech model: the
   start fails with `modelUnavailable`): the bar with the Italian reason, Retry
   starting again and failing again, Close and the loopback reply going empty, and
   the `ping` repeat. Debug builds take `notifyutil -p
   io.github.hexmobile.debug.keyboard.close|retry` for the two keys. Not tried:
   a real tap on the keys.

Reading the pasteboard requires Full Access. The keyboard checks for the
custom type before reading, so iOS shows no paste prompt when there is nothing
to insert.

`DarwinNotificationCenter` never captures an object pointer in the C callback:
callbacks look up a token in a locked table, because they arrive on the main
thread when a run loop is active and on a background thread otherwise. Ending
the `AsyncStream` removes the observer.

## History

`HistoryStore` is an actor over a JSON file in Application Support
(`history.json`). Retention is day, week (default), month or forever, applied
on write and on demand with an injectable clock. Writes are atomic. A corrupt
file is moved aside and a new one started; a file with a newer schema is left
untouched and reported. `HistoryExport.jsonLines` produces the optional
`iphone-history.jsonl`.

## Future: Mac relay engine

A community Android client uses Hex on the Mac as a relay
([announcement](https://x.com/vkpdeveloper/status/2116843158386647161)). A
`MacRelayEngine` conforming to `TranscriptionEngine` could stream audio to Hex
on the Mac over the local network and get back text produced by the same model
and rules as the desktop. Nothing in the keyboard or pasteboard protocol would
change: `DictationPayload.engine` already records which engine produced a
result. This waits on Hex exposing a relay endpoint; its local API is
reachable only by its owner on localhost today.

## Device-unverified assumptions

- Darwin notifications between app and keyboard work without an App Group.
- A keyboard can open its host app via URL on iOS 27.
- `contextualStrings` measurably improves recognition of vocabulary terms.
- The accurate pass finishes in time on the iPhone (the Mac takes 0.2–0.9 s for
  clips of 4–104 s) and inside the background time of an Action Button start
  (about 32 s were left in the log of 1 Nov 2026); the 8 s budget after the stop
  holds on the phone.
- Foundation Models on the iPhone: available with Apple Intelligence on, fast
  enough (Mac: 0.5–1 s for a sentence, 2.5 s for 120 words), not `rateLimited`
  when the app runs in the background from the Action Button (the documentation
  says the limit applies in the background).
- The second pass and the cleanup improve what a person says, not only a
  synthetic voice.
- Whisper on the iPhone: that `devicectl device copy to` copies a folder the way
  `make push-whisper-model` expects; the real-time factor and the cost of a
  piece (the estimate is fitted on four phone runs of single windows; the simulator
  CPU measured 3.2–5.2 times the length); the memory peak against the app's limit (simulator:
  `phys_footprint` 225–236 MB, resident size 2.7–2.9 GB; the two disagree and
  which one predicts a kill is unknown); the Neural Engine being allowed in the
  background (Action Button); the model surviving a long flow session.
- The keyboard leak fix (batch 8): checked only on the simulator (see the
  paragraph «Keyboard memory leak» above). On a device the `appear` footprints and
  the `keyboard model deinit models=N` lines of a day of use will say; the +40 MB
  step of the device log is not explained (the old graphs rendering is a
  hypothesis, not a measurement).
- launchd `WatchPaths` on a file in iCloud Drive fires once the file is
  downloaded locally (the interval covers the rest).
- Retrying `audio.start()` for about 3 s, with a new `AVAudioEngine` after each
  `engine.start` failure and the Live Activity kept, gets a first Action Button
  press through. Doubtful: in the evening log of 1 Nov 2026 the old rounds
  (12 attempts over 3 s, with and without an activity) all failed, and the
  next invocation worked at once. The per-attempt lines in `diagnostics.log`
  (`attempt`, `elapsed`) will say. (The earlier assumption, that a Live
  Activity requested inside the same `perform()` is what lets the engine start,
  was ruled out by the same log.)
- `sysctl` (`KERN_PROC_PID`) is readable inside the app sandbox, so the
  diagnostics `t=` is the real process age; if it reads near 0 on a late
  attempt, the fallback to the first-log time is in use.
- Reading `needsInputModeSwitchKey` and `textDocumentProxy` in `viewDidAppear`
  no longer crashes a freshly launched keyboard (the crash was in
  `viewWillAppear`; the fix is not yet run on a device).
