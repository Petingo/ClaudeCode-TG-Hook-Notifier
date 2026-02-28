#!/usr/bin/env bash
# Stop the Claude Code Telegram bot daemon

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/bot.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "Bot is not running (no PID file)"
  exit 0
fi

PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  rm -f "$PID_FILE"
  echo "Bot stopped (PID $PID)"
else
  echo "Bot was not running"
  rm -f "$PID_FILE"
fi
