# whisper-bench

Reads one audio clip with Whisper on a Mac, through the very same code as the app:
`Packages/HexMobileWhisper` (`WhisperRecipe`) builds the decoding options, cuts a
long recording into pieces at the speaker's pauses and assembles the text. Only the
compute units differ from the phone (the Mac's Neural Engine). It prints the text on
stdout, so `asr-bench` can score it as an external recognizer.

```sh
swift build -c release --package-path tools/whisper-bench

# one clip, from the repo root (the model is read from build/whisper-models)
tools/whisper-bench/.build/release/whisper-bench /abs/clip.caf --terms /abs/terms.txt

# scored against a reference, next to Apple's accurate pass
export HEX_WHISPER_TERMS=/abs/terms.txt HEX_WHISPER_MODELS=/abs/build/whisper-models
swift run -c release --package-path tools/asr-bench asr-bench run /abs/clips \
  --reference /abs/clips/reference.tsv --variants accurate,external:whisper \
  --external whisper=/abs/tools/whisper-bench/.build/release/whisper-bench \
  --vocabulary /abs/terms.txt
```

| Option | |
| --- | --- |
| `--terms FILE` | the vocabulary, one term per line (asr-bench's `--vocabulary` format). `asr-bench --external` passes only the clip path, so the same file can come from the `HEX_WHISPER_TERMS` environment variable |
| `--models DIR` | where the model lives (`HEX_WHISPER_MODELS`; default `build/whisper-models` under the current folder): `models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo_632MB` and `tokenizers/models/openai/whisper-large-v3`, the layout of `make push-whisper-model` |
| `--no-pieces` | read the recording as one, in WhisperKit's own 30 s windows: this reproduces the text the phone lost on 2 Nov 2026 (a 42 s clip with the vocabulary prompt loses one to two sentences) |
| `--language CODE` | default `it` |
| `--cpu` | encoder and decoder on the CPU only, like the simulator and the fallback after a Core ML error |

stderr carries what the app logs: `whisper prompt terms=N/M tokens=K`,
`whisper pieces n= max= prompt= rec=`, the cut points (`whisper cuts at=`),
`whisper timings windows= steps= enc= dec= pipeline=`, `whisper join pieces= lowercased=` (when the pieces were joined) and `whisper run dt=`.

Notes:

- The first load after a build of this executable, or after the model changed, makes
  Core ML compile it for the Neural Engine (minutes: 203 s and 576 s were seen);
  later loads take 1.3 to 2 s. In an `asr-bench` table the latency of an external
  includes that load, because each clip starts the program anew: read the
  `whisper run dt=` line for the time of the run itself.
- A synthetic voice is easier than a person. The numbers order the options and
  prove the tool; they do not predict the phone.
- The vocabulary file is personal: keep it out of the repository.
