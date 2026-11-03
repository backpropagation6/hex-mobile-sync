#!/bin/bash
#
# uninstall.sh: unload and remove the hex-mobile-sync launchd agent.
#
# Leaves the sync folder (and the files the iPhone reads) untouched. The log and
# the state folder are removed only with --purge.
#
# Exit codes: 0 removed (or nothing to remove), 1 failure, 2 usage error.

set -euo pipefail

LABEL="io.github.hexmobile.sync"
INSTALL_DIR="$HOME/Library/Application Support/hex-mobile-sync"
LOG_FILE="${HEX_MOBILE_LOG:-$HOME/Library/Logs/hex-mobile-sync.log}"
PURGE=0

usage() {
    cat <<'EOF'
Usage: uninstall.sh [--label LABEL] [--purge] [--help]

  --label LABEL  launchd label used at install (default io.github.hexmobile.sync)
  --purge        also delete the installed script folder, its state and the log
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "uninstall.sh: --label needs a value" >&2; exit 2; }
            LABEL="$2"; shift 2 ;;
        --purge) PURGE=1; shift ;;
        --help | -h) usage; exit 0 ;;
        *) printf 'uninstall.sh: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$LABEL" in
    '' | *[!A-Za-z0-9._-]*) echo "uninstall.sh: invalid label '$LABEL'" >&2; exit 2 ;;
esac

plist="$HOME/Library/LaunchAgents/$LABEL.plist"
domain="gui/$(id -u)"

if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$domain/$LABEL" || { echo "uninstall.sh: launchctl bootout failed" >&2; exit 1; }
    echo "Unloaded $LABEL"
else
    echo "$LABEL is not loaded"
fi

if [ -f "$plist" ]; then
    rm -f "$plist"
    echo "Removed $plist"
fi

if [ "$PURGE" -eq 1 ]; then
    # Only the known files, never a recursive delete of a computed path.
    rm -f "$INSTALL_DIR/hex-mobile-sync.sh" "$INSTALL_DIR"/notified-*
    rmdir "$INSTALL_DIR/lock" 2>/dev/null || true
    rmdir "$INSTALL_DIR" 2>/dev/null || true
    rm -f "$LOG_FILE" "$LOG_FILE.1" "$LOG_FILE.launchd"
    echo "Purged script, state and log"
else
    echo "Kept $INSTALL_DIR and the log (use --purge to delete them)"
fi
