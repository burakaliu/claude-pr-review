#!/usr/bin/env bash
#
# Install the local reviewer as a launchd agent. Re-running this is safe: it
# reloads the agent and leaves an existing config alone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.claude-pr-review.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/claude-pr-review"
STATE_DIR="$HOME/.local/state/claude-pr-review"
DAEMON="$SCRIPT_DIR/review-daemon.sh"

POLL_SECONDS="${POLL_SECONDS:-300}"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "this installer is macOS only (it uses launchd)"

for cmd in jq gh git claude perl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found on PATH. Install it first."
done

gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

chmod +x "$DAEMON"
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$HOME/Library/LaunchAgents"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
  cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
  say "Wrote a starter config to $CONFIG_DIR/config.json"
  say "Edit it before the first run. Every repo in it is disabled until you say otherwise."
else
  say "Keeping the existing config at $CONFIG_DIR/config.json"
fi

[ -f "$STATE_DIR/reviewed.json" ] || echo '{}' >"$STATE_DIR/reviewed.json"

# launchd starts with a bare environment, so hand it the PATH the daemon needs.
DAEMON_PATH="$(dirname "$(command -v claude)"):$(dirname "$(command -v gh)"):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>$DAEMON</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$DAEMON_PATH</string>
    <key>HOME</key>
    <string>$HOME</string>
  </dict>

  <key>StartInterval</key>
  <integer>$POLL_SECONDS</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>$STATE_DIR/launchd.out.log</string>

  <key>StandardErrorPath</key>
  <string>$STATE_DIR/launchd.err.log</string>

  <key>ProcessType</key>
  <string>Background</string>

  <key>LowPriorityIO</key>
  <true/>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"

say ""
say "Installed. It wakes every $POLL_SECONDS seconds."
say ""
say "  config   $CONFIG_DIR/config.json"
say "  state    $STATE_DIR/reviewed.json"
say "  log      $STATE_DIR/daemon.log"
say ""
say "Run one pass by hand to check it:"
say "  $DAEMON && tail -20 $STATE_DIR/daemon.log"
say ""
say "Stop it with: $SCRIPT_DIR/uninstall.sh"
