#!/bin/bash
#
# install.sh: install hex-mobile-sync as a per-user launchd agent.
#
# Copies hex-mobile-sync.sh to the state folder, renders the plist template into
# ~/Library/LaunchAgents/<label>.plist and loads it with launchctl bootstrap.
# Re-running it replaces the previous installation with the same label.
#
# Exit codes: 0 installed (or printed), 1 failure, 2 usage error.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
readonly HERE
readonly TEMPLATE="$HERE/io.github.hexmobile.sync.plist.template"
readonly SOURCE_SCRIPT="$HERE/hex-mobile-sync.sh"

LABEL="io.github.hexmobile.sync"
HEX_CLI="${HEX_CLI:-/Applications/Hex.app/Contents/MacOS/hex}"
SYNC_DIR="${HEX_MOBILE_SYNC_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Hex Mobile}"
SETTINGS_FILE="${HEX_SETTINGS_FILE:-$HOME/Library/Application Support/hex/settings.json}"
LOG_FILE="${HEX_MOBILE_LOG:-$HOME/Library/Logs/hex-mobile-sync.log}"
INSTALL_DIR="$HOME/Library/Application Support/hex-mobile-sync"
PRINT_ONLY=0

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --label LABEL          launchd label (default io.github.hexmobile.sync)
  --sync-dir DIR         sync folder (default iCloud Drive/Hex Mobile)
  --hex-cli PATH         hex CLI (default /Applications/Hex.app/Contents/MacOS/hex)
  --settings-file PATH   Hex settings.json to watch
  --log PATH             log file (default ~/Library/Logs/hex-mobile-sync.log)
  --print                print the rendered plist and change nothing
  --help                 show this help

The same values can come from HEX_CLI, HEX_MOBILE_SYNC_DIR, HEX_SETTINGS_FILE
and HEX_MOBILE_LOG. Uninstall with uninstall.sh --label LABEL.
EOF
}

fail() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

need_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'install.sh: %s needs a value\n' "$1" >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label) need_value "$@"; LABEL="$2"; shift 2 ;;
        --sync-dir) need_value "$@"; SYNC_DIR="$2"; shift 2 ;;
        --hex-cli) need_value "$@"; HEX_CLI="$2"; shift 2 ;;
        --settings-file) need_value "$@"; SETTINGS_FILE="$2"; shift 2 ;;
        --log) need_value "$@"; LOG_FILE="$2"; shift 2 ;;
        --print) PRINT_ONLY=1; shift ;;
        --help | -h) usage; exit 0 ;;
        *) printf 'install.sh: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$LABEL" in
    '' | *[!A-Za-z0-9._-]*) fail "invalid label '$LABEL' (letters, digits, '.', '_', '-')" ;;
esac
[ -f "$TEMPLATE" ] || fail "template not found: $TEMPLATE"
[ -f "$SOURCE_SCRIPT" ] || fail "script not found: $SOURCE_SCRIPT"

readonly PROGRAM="$INSTALL_DIR/hex-mobile-sync.sh"
readonly PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Literal (non-regex) placeholder replacement with XML escaping, in awk so that
# paths containing '|', '&' or '\' are safe.
render() {
    R_LABEL="$LABEL" \
    R_PROGRAM="$PROGRAM" \
    R_HEX_CLI="$HEX_CLI" \
    R_SYNC_DIR="$SYNC_DIR" \
    R_SETTINGS_FILE="$SETTINGS_FILE" \
    R_PENDING_FILE="$SYNC_DIR/pending-vocabulary.json" \
    R_LOG="$LOG_FILE" \
    R_LAUNCHD_LOG="$LOG_FILE.launchd" \
    awk '
        function xml(s) {
            gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
            return s
        }
        function replace_all(line, key, value,    out, i) {
            out = ""
            while ((i = index(line, key)) > 0) {
                out = out substr(line, 1, i - 1) value
                line = substr(line, i + length(key))
            }
            return out line
        }
        BEGIN {
            n = split("LABEL PROGRAM HEX_CLI SYNC_DIR SETTINGS_FILE PENDING_FILE LOG LAUNCHD_LOG", keys, " ")
            for (k = 1; k <= n; k++) val[keys[k]] = xml(ENVIRON["R_" keys[k]])
        }
        {
            for (k = 1; k <= n; k++) $0 = replace_all($0, "__" keys[k] "__", val[keys[k]])
            print
        }' "$TEMPLATE"
}

if [ "$PRINT_ONLY" -eq 1 ]; then
    render
    exit 0
fi

command -v jq >/dev/null 2>&1 || command -v /opt/homebrew/bin/jq >/dev/null 2>&1 \
    || fail "jq is required (macOS 15+ ships /usr/bin/jq; otherwise: brew install jq)"
[ -x "$HEX_CLI" ] || printf 'install.sh: warning: hex CLI not found at %s; the agent will log an error until it exists\n' "$HEX_CLI" >&2
[ -d "$(dirname "$SYNC_DIR")" ] || fail "parent of the sync folder does not exist: $(dirname "$SYNC_DIR") (is iCloud Drive enabled?)"
[ -d "$HOME/Library/LaunchAgents" ] || mkdir "$HOME/Library/LaunchAgents" || fail "cannot create ~/Library/LaunchAgents"

mkdir -p "$INSTALL_DIR" || fail "cannot create $INSTALL_DIR"
install -m 0755 "$SOURCE_SCRIPT" "$PROGRAM" || fail "cannot copy the script to $PROGRAM"

tmp_plist=$(mktemp "${TMPDIR:-/tmp}/hex-mobile-sync-plist.XXXXXX") || fail "cannot create a temp file"
trap 'rm -f "$tmp_plist"' EXIT
render >"$tmp_plist"
plutil -lint "$tmp_plist" >/dev/null || fail "rendered plist is invalid"

domain="gui/$(id -u)"
# Replace a previous installation with the same label; "not loaded" is fine.
launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
install -m 0644 "$tmp_plist" "$PLIST" || fail "cannot write $PLIST"
launchctl bootstrap "$domain" "$PLIST" || fail "launchctl bootstrap failed for $PLIST"

printf 'Installed %s\n  agent:  %s\n  script: %s\n  sync:   %s\n  log:    %s\n' \
    "$LABEL" "$PLIST" "$PROGRAM" "$SYNC_DIR" "$LOG_FILE"
printf 'Check with: launchctl print %s/%s\n' "$domain" "$LABEL"
