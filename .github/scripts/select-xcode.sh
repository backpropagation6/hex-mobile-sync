#!/usr/bin/env bash
# Select the newest Xcode on the runner. Writes ok=true to $GITHUB_OUTPUT when
# it is Xcode 27 or later (the project needs the iOS 27 SDK), ok=false with a
# warning otherwise, so the build steps skip instead of failing.
set -euo pipefail
required=27
best=""; best_major=0
for app in /Applications/Xcode*.app; do
  [ -d "$app" ] || continue
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo 0)
  major=${v%%.*}
  echo "found $app ($v)"
  if [ "$major" -gt "$best_major" ] 2>/dev/null; then best="$app"; best_major=$major; fi
done
out=${GITHUB_OUTPUT:-/dev/stdout}
if [ -n "$best" ] && [ "$best_major" -ge "$required" ]; then
  sudo xcode-select -s "$best/Contents/Developer"
  xcodebuild -version
  swift --version
  echo "ok=true" >> "$out"
else
  echo "::warning title=Xcode $required not available::Newest Xcode on this runner is ${best:-none} (major $best_major). Build and tests skipped; they run locally with 'make test-core' and 'make build-device'."
  echo "ok=false" >> "$out"
fi
