#!/bin/bash
# Installs a launch agent that keeps TrigIT running: it starts at login and,
# if TrigIT crashes or is killed, launchd relaunches it within a few seconds.
# Quitting TrigIT normally (⌘Q) leaves it quit.
#
#   scripts/install-launch-agent.sh [/Applications/TrigIT.app]
#   scripts/install-launch-agent.sh --uninstall
set -euo pipefail

LABEL=com.ncoab.trigit.keepalive
OLD_LABEL=com.trigit.TrigIT.keepalive  # before #32; removed on install and uninstall
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$PLIST"
    echo "Removed $LABEL"
    exit 0
fi

APP="$(cd "$(dirname "${1:-/Applications/TrigIT.app}")" && pwd)/$(basename "${1:-/Applications/TrigIT.app}")"
[[ -x "$APP/Contents/MacOS/TrigIT" ]] || { echo "No TrigIT app at $APP" >&2; exit 1; }

mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs/TrigIT"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/TrigIT</string></array>
    <key>RunAtLoad</key><true/>
    <!-- Relaunch after a crash or kill, not after a normal Quit. -->
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <!-- launchd waits this long between relaunches (default 10 s). -->
    <key>ThrottleInterval</key><integer>2</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/TrigIT/stderr.log</string>
</dict>
</plist>
PLIST
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $LABEL for $APP"
