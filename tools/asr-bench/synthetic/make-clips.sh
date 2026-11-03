#!/bin/zsh
# Makes synthetic Italian clips for asr-bench with the macOS `say` voice and
# converts them to what the app records for the analyzer: 16 kHz mono 16-bit
# CAF. Writes <id>.caf and reference.tsv (id<TAB>correct text) in <outdir>.
#
#   tools/asr-bench/synthetic/make-clips.sh /abs/path/to/outdir [voice]
#
# A synthetic voice is easier than real speech: the numbers it gives order the
# variants and prove the tool, they do not predict the error rate on a person.
set -euo pipefail
OUT="${1:?usage: make-clips.sh <outdir> [voice]}"
VOICE="${2:-Alice}"
HERE="${0:A:h}"
mkdir -p "$OUT"
: > "$OUT/reference.tsv"
while IFS=$'\t' read -r id text; do
  [[ -z "$id" ]] && continue
  say -v "$VOICE" -o "$OUT/$id.aiff" -- "$text"
  afconvert -f caff -d LEI16@16000 -c 1 "$OUT/$id.aiff" "$OUT/$id.caf"
  rm -f "$OUT/$id.aiff"
  printf '%s\t%s\n' "$id" "$text" >> "$OUT/reference.tsv"
  echo "$id $(afinfo "$OUT/$id.caf" | awk '/estimated duration/ {print $3 " s"}')"
done < "$HERE/sentences.tsv"
