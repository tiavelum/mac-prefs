#!/usr/bin/env bash
#
# install-snapshot-agent.sh -- run `macprefs.sh snapshot` on a schedule.
#
#   ./install-snapshot-agent.sh              # weekly, Sunday 10:00
#   ./install-snapshot-agent.sh --daily      # daily, 10:00
#   ./install-snapshot-agent.sh --at 21:30   # different time of day
#   ./install-snapshot-agent.sh --target ~/vc/macprefs-config
#   ./install-snapshot-agent.sh --uninstall
#
# Installs a LaunchAgent that snapshots your settings into the private
# settings repo and commits any change. It does not push -- git-autosync
# does that. If the Mac is asleep at the scheduled moment, launchd runs
# the job when it next wakes, so a sleeping laptop does not skip a week.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.tiavelum.macprefs-snapshot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/macprefs-snapshot.log"

TARGET="$HOME/vc/macprefs-config"
WEEKLY=1
HOUR=10
MINUTE=0
WEEKDAY=0          # 0 = Sunday
UNINSTALL=0

die() { printf 'fail  %s\n' "$*" >&2; exit 1; }
ok()  { printf '  ok  %s\n' "$*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --daily)     WEEKLY=0 ;;
    --weekly)    WEEKLY=1 ;;
    --at)        shift
                 case "${1:-}" in
                   [0-9]*:[0-9]*) HOUR="${1%%:*}"; MINUTE="${1##*:}" ;;
                   *) die "--at wants HH:MM, got '${1:-}'" ;;
                 esac
                 HOUR="$((10#$HOUR))"; MINUTE="$((10#$MINUTE))" ;;
    --target)    shift; TARGET="${1:-}" ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown option: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS"

if [ "$UNINSTALL" -eq 1 ]; then
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  ok "removed $LABEL"
  exit 0
fi

case "$TARGET" in "~"/*) TARGET="$HOME/${TARGET#~/}" ;; esac
[ -d "$TARGET" ] || die "settings repo not found: $TARGET
Clone it first, then re-run with --target if it lives elsewhere."
[ -x "$SCRIPT_DIR/macprefs.sh" ] || die "macprefs.sh not found next to this script"

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"

if [ "$WEEKLY" -eq 1 ]; then
  SCHEDULE="        <key>Weekday</key><integer>$WEEKDAY</integer>
        <key>Hour</key><integer>$HOUR</integer>
        <key>Minute</key><integer>$MINUTE</integer>"
  WHEN="Sundays at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
else
  SCHEDULE="        <key>Hour</key><integer>$HOUR</integer>
        <key>Minute</key><integer>$MINUTE</integer>"
  WHEN="daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
fi

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/macprefs.sh</string>
        <string>snapshot</string>
        <string>$TARGET</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
$SCHEDULE
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null || die "generated plist is invalid: $PLIST"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
if launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
  ok "loaded $LABEL"
else
  launchctl load -w "$PLIST" 2>/dev/null \
    && ok "loaded $LABEL (legacy launchctl)" \
    || die "could not load the agent -- check $PLIST"
fi

ok "snapshots $WHEN into $TARGET"
printf '      log: %s\n' "$LOG"
printf '      run now:    launchctl kickstart -k gui/%s/%s\n' "$UID" "$LABEL"
printf '      uninstall:  %s --uninstall\n' "$0"
