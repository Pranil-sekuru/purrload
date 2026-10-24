#!/bin/zsh
# Run the Purrload engine under launchd, so it starts at login and comes back if it is ever killed or crashes.
# Usage: scripts/install-engine-agent.sh            install and start
#        scripts/install-engine-agent.sh --remove   stop and uninstall
LABEL="io.github.pranil-sekuru.purrload-engine"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ENGINE="${0:A:h}/../engine/purrload-engine.py"
ENGINE="${ENGINE:A}"
BASE="$HOME/Library/Application Support/Purrload"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
if [[ "$1" == "--remove" ]]; then rm -f "$PLIST"; echo "Engine agent removed."; exit 0; fi

mkdir -p "$BASE" "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/usr/bin/python3</string><string>-I</string><string>$ENGINE</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>$BASE/crash.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST" && echo "Engine agent installed and started. Crashes are written to $BASE/crash.log"
