# asr-bench

Compares the recognizer variants of Hex Mobile on the same audio clips, on a Mac.
It links the app's own `HexMobileSpeech` package (the final pass, the cleanup,
the clip transcriber), so a number here is a number about the app's pipeline.
Everything runs on the Mac with Apple's on-device models; no audio leaves it.

```sh
# once: Apple's it-IT speech models (a download from Apple; needs a network)
swift run -c release --package-path tools/asr-bench asr-bench install

# a folder of clips and what was really said
swift run -c release --package-path tools/asr-bench asr-bench run /abs/clips \
  --reference /abs/clips/reference.tsv --json /abs/out.json
```

## Variants

| Name | What it is |
| --- | --- |
| `fast` | `SpeechTranscriber` with `fastResults`, on the file: the live transcript's recognizer |
| `accurate` | `SpeechTranscriber` without `fastResults`, on the file: the final pass |
| `dictation` | `DictationTranscriber` with punctuation: the keyboard dictation model |
| `live` | the clip streamed in 100 ms buffers to the fast recognizer, like the microphone; reports the time to the first result and from the stop to the end of the analysis |
| `app` | the app's pipeline after the stop: `live`, the final pass with its timeout and fallbacks, the cleanup, started only if its estimate fits what is left until 7.55 s after the stop, and then run to that deadline (`FinalPassPolicy.cleanupPlan`; otherwise `cleanup fallback reason=budget`), then the vocabulary spelling. The number in the `s` column is stop to text |
| `clean` | the `accurate` text through the language-model cleanup (the same `TextCleaner`, 3 s timeout unless `--cleanup-timeout`) |
| `external:<name>` | another recognizer, see below |
| `phone-live`, `phone-final`, `phone-whisper`, `phone-clean`, `phone-inserted` | what the phone produced, read from `<id>.json` next to the clip when the app kept it. `phone-final` is Apple's final pass; `phone-whisper` is the Whisper pass (text and time, or the reason it did not run) and appears only when Whisper was the chosen engine; `phone-inserted` carries `final_engine` (whose text went to the cleanup) as its note |

The WER is normalized (case, punctuation, apostrophes and hyphens ignored,
accents counted) and corpus-level: total errors over total reference words of the
clips that have a reference. `S D I` are substitutions, deletions, insertions.
Without `--realtime` the live variants take the clip as fast as the analyzer
accepts it, so their latencies are not those of a person speaking: use
`--realtime` for the timing (the run then lasts as long as the clips).

## Reference file

The right text of each clip, as a JSON object `{"clip-id": "text"}` or as lines
`clip-id<TAB>text`. A `.caf` suffix on the id is ignored, `#` starts a comment.

## Clips

- From the phone: Settings, "Keep Audio to Improve Recognition". The app keeps the
  last 20 dictations in `Library/Application Support/clips/` of its container as
  `<id>.caf` (16 kHz mono) and `<id>.json`. Copy them with
  `xcrun devicectl device copy from --device <identifier> --domain-type appDataContainer --domain-identifier <BUNDLE_ID_PREFIX>.HexMobile --source "Library/Application Support/clips" --destination <dir>`
  (copying a folder this way has not been tried). Read a script aloud (one
  dictation per sentence), then write the `reference.tsv` with the sentence for each
  clip id.
- Synthetic: `tools/asr-bench/synthetic/make-clips.sh /abs/outdir [voice]` makes
  clips with the macOS `say` voice (default `Alice`) from `synthetic/sentences.tsv`,
  converted to 16 kHz mono, plus `reference.tsv`. `s01` to `s10` are single sentences,
  `mid01` is 24 s (the length at which the recording is cut into two pieces for
  Whisper) and `long01` to `long03` run from 42 to 104 s. **A synthetic voice is easier
  than real speech.** Its numbers order the variants and prove the tool; they do
  not predict the error rate on a person.

## Adding a recognizer (Whisper, a cloud API)

Nothing external is part of the app or of this tool. Two ways to add one:

- Without code: `--external whisper=/abs/path/to/script`. The program gets the clip
  path as its only argument and prints the text on stdout (exit 0).
- In code: append `("whisper", { url in ... })` to `ExternalVariants.registered`
  in `Sources/asr-bench/External.swift`: a function from an audio file to its text.

It then appears as `external:whisper` next to the others, with WER and latency.
[`tools/whisper-bench`](../whisper-bench/README.md) is such a program for Whisper: it
runs the app's own Whisper recipe on the Mac (terms through `HEX_WHISPER_TERMS`).

## Other options

`--variants a,b,c` to run only some, `--locale`, `--vocabulary FILE` (one term per
line: contextual strings for the recognizers and the case-respelling after the
cleanup), `--no-warmup` (by default the models are loaded on the first clip
first, and that run is not counted).
