# Contributing to Hex Mobile Sync

Thanks for helping. Hex Mobile Sync is an unofficial community companion to
[Hex](https://github.com/anomalyco/hex); keep that in mind when filing issues
(Hex desktop bugs belong to the Hex project).

## Ground rules

These come from the spec ([docs/PLAN.md](docs/PLAN.md)) and are checked in
review:

1. **Free Apple ID must keep working.** Do not add a capability a Personal
   Team cannot sign: no App Groups, no iCloud/CloudKit entitlement, no push,
   no Associated Domains.
2. **On-device only.** No network calls from the app or the extensions, no
   analytics, no third-party SDKs, no LLM.
3. **Hex is read through its CLI.** The Mac script must never write Hex's
   files. Reading `settings.json` read-only is only a fallback when Hex is not
   running. `post_processing` (LLM prompt and model) is never exported.
4. **Swift 6 language mode, complete strict concurrency, zero warnings** in our
   code.
5. **Generic code and data.** No personal names, paths, IP addresses, tokens
   or real vocabulary in code, tests, fixtures or docs. Fixtures are synthetic.
6. **English** for code, comments and docs. UI strings go through the String
   Catalogs (`*.xcstrings`); English is the base, Italian is maintained. If you
   add a string, add the Italian translation or mark it as needing review.
7. If you change a behavior, update the docs that describe it (README,
   `docs/ARCHITECTURE.md`, `mac/README.md`, `docs/PLAN.md`) in the same pull
   request.

## Setup

- Xcode 27.2 or later (iOS 27.2 SDK), XcodeGen (`brew install xcodegen`), `jq`.
- `cp Config/Local.xcconfig.example Config/Local.xcconfig` and set your
  `DEVELOPMENT_TEAM` and a unique `BUNDLE_ID_PREFIX` if you want to run on a
  device. Unsigned builds need neither.
- `make project` generates `HexMobile.xcodeproj` from `project.yml`. The
  project file is gitignored: edit `project.yml`, not the generated project.

## Checks to run before a pull request

The same checks run in CI (`.github/workflows/ci.yml`). The build and the
core tests need Xcode 27; while GitHub's macOS runners ship only Xcode 26,
CI skips them with a warning and only the Mac script tests really run, so run
the first three locally:

```sh
make test-core                 # swift test in Packages/HexMobileCore
make project && make build-device   # unsigned build, generic iOS device
make build-sim                 # unsigned build, iOS Simulator
bash tests/mac/test-sync.sh    # Mac script against a stub hex CLI
```

Build logs are written to `build/`. `tests/mac/test-sync.sh` never calls the
real Hex, launchd or iCloud Drive.

Things CI cannot check, so describe them in the pull request when you touch
them: behavior on a real iPhone (keyboard, Action Button, Control Center, Live
Activity, background recording) and a real run of the Mac script against Hex.

## Where things go

| Change | Place |
|---|---|
| Models, formats, text rules, history, IPC constants | `Packages/HexMobileCore` with tests |
| App UI, recording, transcription engines, sync I/O | `App/Sources` |
| Intents shared by the app and the widget extension | `Shared/` |
| Live Activity, Control Center control | `Widgets/` |
| Keyboard | `Keyboard/` |
| Mac export and pending vocabulary | `mac/` with tests in `tests/mac/` |

Logic that can be tested on macOS belongs in `HexMobileCore`. A new
transcription engine conforms to `TranscriptionEngine`
(`App/Sources/Transcription/TranscriptionEngine.swift`); see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Changing a sync file format means bumping `schema_version` and keeping old
readers safe: current decoders refuse newer versions with a clear error.

## Pull requests

- Keep them focused; one topic per pull request.
- Commit messages in the imperative mood, first line under 72 characters.
- Say what you verified and how (tests, simulator, which device and iOS
  version), and what you could not verify.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
