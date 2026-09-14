#!/bin/bash
# Stop and remove the mxmasterd launch agent (leaves the built binary in place).
set -euo pipefail

LABEL="io.github.mxmasterd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "Removed $LABEL. The mouse reverts to firmware defaults."
