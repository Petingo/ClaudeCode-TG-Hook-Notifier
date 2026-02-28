#!/usr/bin/env bash
# Start the Claude Code Telegram bot daemon

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/bot.pid"
LOG_FILE="$SCRIPT_DIR/bot.log"

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "Bot is already running (PID $PID)"
    exit 0
  fi
fi

PYTHON="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
if [[ -z "$PYTHON" ]]; then
  echo "Error: python3 not found" >&2
  exit 1
fi

nohup "$PYTHON" "$SCRIPT_DIR/bot.py" >> "$LOG_FILE" 2>&1 &
BOT_PID=$!
echo "$BOT_PID" > "$PID_FILE"
echo "Bot started (PID $BOT_PID) — logs: $LOG_FILE"
