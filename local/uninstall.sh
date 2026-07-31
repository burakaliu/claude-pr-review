#!/usr/bin/env bash
#
# Stop and remove the launchd agent. Leaves your config, state, and logs alone
# so reinstalling picks up where it left off. Pass --purge to delete those too.

set -euo pipefail

LABEL="com.claude-pr-review.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/claude-pr-review"
STATE_DIR="$HOME/.local/state/claude-pr-review"
CACHE_DIR="$HOME/.cache/claude-pr-review"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
printf 'Agent stopped and removed.\n'

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$CONFIG_DIR" "$STATE_DIR" "$CACHE_DIR"
  printf 'Purged config, state, and the repo cache.\n'
else
  printf 'Config and state kept. Delete them with: %s --purge\n' "$0"
fi
