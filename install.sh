#!/bin/bash
# Build mxmasterd and install it as a per-user launchd agent.
# No paths are hardcoded — everything is derived from where this repo lives.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="io.github.mxmasterd"
BIN="$REPO/bin/mxmasterd"
LOG="$HOME/Library/Logs/mxmasterd.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Building…"
mkdir -p "$REPO/bin"
swiftc -O -parse-as-library -o "$BIN" "$REPO/src/mxmasterd.swift"

echo "Writing $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__BIN__|$BIN|g" -e "s|__LOG__|$LOG|g" \
    "$REPO/mxmasterd.plist.template" > "$PLIST"

echo "Loading launch agent…"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

echo
echo "Installed. Grant these once in System Settings → Privacy & Security:"
echo "  • Input Monitoring  → mxmasterd"
echo "  • Accessibility     → mxmasterd"
echo "Dashboard: http://localhost:8722    Logs: $LOG"
