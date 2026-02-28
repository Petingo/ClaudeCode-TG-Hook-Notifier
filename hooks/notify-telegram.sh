#!/usr/bin/env bash
# Claude Code Telegram Notification Hook
# Handles: Notification + Stop events
# Sends notifications via Telegram Bot API when Claude needs attention or completes a task.
# Supports inline keyboards and session-state tracking for two-way bot interaction.

set -euo pipefail

# --- Dependencies ---
JQ="/opt/homebrew/bin/jq"
if [[ ! -x "$JQ" ]]; then
  JQ="$(command -v jq 2>/dev/null || true)"
fi
if [[ -z "$JQ" ]]; then
  exit 0
fi

# --- Read stdin ---
INPUT="$(cat)"
if [[ -z "$INPUT" ]]; then
  exit 0
fi

# --- Parse common fields ---
HOOK_EVENT="$("$JQ" -r '.hook_event_name // empty' <<< "$INPUT")"
SESSION_ID="$("$JQ" -r '.session_id // "unknown"' <<< "$INPUT")"
CWD="$("$JQ" -r '.cwd // "unknown"' <<< "$INPUT")"
TRANSCRIPT_PATH="$("$JQ" -r '.transcript_path // empty' <<< "$INPUT")"

# --- Load per-project env (fallback to system env) ---
PROJECT_ENV_FILE="${CWD}/.claude/.env"
if [[ -f "$PROJECT_ENV_FILE" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    case "$key" in
      CLAUDE_HOOK_TG_BOT_TOKEN) PROJECT_TG_BOT_TOKEN="$value" ;;
      CLAUDE_HOOK_TG_CHAT_ID)   PROJECT_TG_CHAT_ID="$value" ;;
    esac
  done < "$PROJECT_ENV_FILE"
fi

CLAUDE_HOOK_TG_BOT_TOKEN="${PROJECT_TG_BOT_TOKEN:-${CLAUDE_HOOK_TG_BOT_TOKEN:-}}"
CLAUDE_HOOK_TG_CHAT_ID="${PROJECT_TG_CHAT_ID:-${CLAUDE_HOOK_TG_CHAT_ID:-}}"

if [[ -z "$CLAUDE_HOOK_TG_BOT_TOKEN" || -z "$CLAUDE_HOOK_TG_CHAT_ID" ]]; then
  exit 0
fi

# --- Metadata ---
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
HOSTNAME="$(hostname -s)"
PROJECT_NAME="$(basename "$CWD")"

# --- Helpers ---
html_escape() {
  local text="$1"
  text="${text//&/&amp;}"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  printf '%s' "$text"
}

truncate_text() {
  local text="$1"
  local max_len="${2:-3500}"
  if [[ ${#text} -gt $max_len ]]; then
    printf '%s…(truncated)' "${text:0:$max_len}"
  else
    printf '%s' "$text"
  fi
}

# Build inline keyboard JSON for a session
# Buttons use callback_data: "resume:<SESSION_ID>:<cmd_code>"
# cmd_code: y=yes  n=no  s=status  sum=summary
make_keyboard() {
  local sid="$1"
  printf '{"inline_keyboard":[[{"text":"✅ Yes","callback_data":"resume:%s:y"},{"text":"❌ No","callback_data":"resume:%s:n"},{"text":"📊 Status","callback_data":"resume:%s:s"}]]}' \
    "$sid" "$sid" "$sid"
}

make_keyboard_stop() {
  local sid="$1"
  printf '{"inline_keyboard":[[{"text":"📊 Summary","callback_data":"resume:%s:sum"}]]}' \
    "$sid"
}

# Read last assistant message from transcript JSONL
# Returns plain text (not HTML-escaped), truncated to ~500 chars
last_assistant_message() {
  local transcript="$1"
  [[ -z "$transcript" || ! -f "$transcript" ]] && return
  # Walk lines in reverse, find first assistant entry with text content
  "$JQ" -rs '
    [ .[] | select(.type == "assistant") ] | last |
    .message.content |
    if type == "array" then
      [ .[] | select(.type == "text") | .text ] | join("\n")
    elif type == "string" then .
    else "" end
  ' "$transcript" 2>/dev/null | tr -d '\000-\010\013\014\016-\037'
}

# --- Build message and keyboard based on event type ---
MESSAGE=""
REPLY_MARKUP=""

case "$HOOK_EVENT" in
  Notification)
    NOTIFICATION_TYPE="$("$JQ" -r '.notification_type // "unknown"' <<< "$INPUT")"
    NOTIFICATION_MSG="$("$JQ" -r '.message // ""' <<< "$INPUT")"
    TOOL_NAME="$("$JQ" -r '.tool_name // ""' <<< "$INPUT")"

    case "$NOTIFICATION_TYPE" in
      permission_granted)
        EMOJI="🔐"
        LABEL="Permission Required"
        ;;
      idle_prompt)
        EMOJI="💤"
        LABEL="Idle — Waiting for Input"
        ;;
      input_needed)
        EMOJI="📝"
        LABEL="Input Needed"
        ;;
      *)
        EMOJI="🔔"
        LABEL="Notification"
        ;;
    esac

    DETAIL=""
    if [[ -n "$NOTIFICATION_MSG" ]]; then
      DETAIL="$(html_escape "$NOTIFICATION_MSG")"
    fi
    if [[ -n "$TOOL_NAME" ]]; then
      DETAIL="Claude needs your permission to use <b>$(html_escape "$TOOL_NAME")</b>"
    fi

    MESSAGE="${EMOJI} <b>Claude Code — ${LABEL}</b>

<b>Host:</b>      ${HOSTNAME}
<b>Project:</b>   $(html_escape "$PROJECT_NAME")
<b>Session:</b>   ${SESSION_ID}
<b>Directory:</b> $(html_escape "$CWD")
<b>Time:</b>      ${TIMESTAMP}"

    if [[ -n "$DETAIL" ]]; then
      MESSAGE="${MESSAGE}

${DETAIL}"
    fi

    # Append last assistant message from transcript as context
    LAST_CTX="$(last_assistant_message "$TRANSCRIPT_PATH")"
    LAST_CTX="$(truncate_text "$LAST_CTX" 500)"
    if [[ -n "$LAST_CTX" ]]; then
      MESSAGE="${MESSAGE}

📋 <b>Last message:</b>
<code>$(html_escape "$LAST_CTX")</code>"
    fi

    MESSAGE="${MESSAGE}

💬 <i>Reply to this message or tap a button to send a command</i>"

    REPLY_MARKUP="$(make_keyboard "$SESSION_ID")"
    ;;

  Stop)
    STOP_HOOK_ACTIVE="$("$JQ" -r '.stop_hook_active // false' <<< "$INPUT")"
    if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
      exit 0
    fi

    LAST_MSG="$("$JQ" -r '.last_assistant_message // ""' <<< "$INPUT")"
    LAST_MSG="$(truncate_text "$LAST_MSG" 3500)"
    LAST_MSG="$(html_escape "$LAST_MSG")"

    MESSAGE="✅ <b>Claude Code — Task Completed</b>

<b>Host:</b>      ${HOSTNAME}
<b>Project:</b>   $(html_escape "$PROJECT_NAME")
<b>Session:</b>   ${SESSION_ID}
<b>Directory:</b> $(html_escape "$CWD")
<b>Time:</b>      ${TIMESTAMP}"

    if [[ -n "$LAST_MSG" ]]; then
      MESSAGE="${MESSAGE}

${LAST_MSG}"
    fi

    MESSAGE="${MESSAGE}

💬 <i>Reply to this message to start a new task</i>"

    REPLY_MARKUP="$(make_keyboard_stop "$SESSION_ID")"
    ;;

  *)
    exit 0
    ;;
esac

# --- Append separator ---
MESSAGE="${MESSAGE}

——————————————"

# --- Send to Telegram ---
if [[ -z "$MESSAGE" ]]; then
  exit 0
fi

# Build JSON payload (includes reply_markup if present)
if [[ -n "$REPLY_MARKUP" ]]; then
  PAYLOAD="$("$JQ" -n \
    --arg chat_id  "$CLAUDE_HOOK_TG_CHAT_ID" \
    --arg text     "$MESSAGE" \
    --argjson markup "$REPLY_MARKUP" \
    '{chat_id: $chat_id, text: $text, parse_mode: "HTML",
      disable_web_page_preview: true, reply_markup: $markup}')"
else
  PAYLOAD="$("$JQ" -n \
    --arg chat_id "$CLAUDE_HOOK_TG_CHAT_ID" \
    --arg text    "$MESSAGE" \
    '{chat_id: $chat_id, text: $text, parse_mode: "HTML",
      disable_web_page_preview: true}')"
fi

RESPONSE="$(curl -s --max-time 10 \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "https://api.telegram.org/bot${CLAUDE_HOOK_TG_BOT_TOKEN}/sendMessage" 2>/dev/null || true)"

# --- Persist session state for bot two-way routing ---
(
  MSG_ID="$("$JQ" -r '.result.message_id // empty' <<< "$RESPONSE" 2>/dev/null || true)"
  if [[ -z "$MSG_ID" || "$MSG_ID" == "null" ]]; then
    exit 0
  fi

  STATE_FILE="$HOME/.claude/tg-sessions.json"
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ ! -f "$STATE_FILE" ]]; then
    printf '{"by_msg":{},"sessions":{}}' > "$STATE_FILE"
  fi

  TMP_STATE="$(mktemp)"
  "$JQ" \
    --arg msg_id   "$MSG_ID" \
    --arg sid      "$SESSION_ID" \
    --arg cwd      "$CWD" \
    --arg project  "$PROJECT_NAME" \
    --arg event    "$HOOK_EVENT" \
    '.by_msg[$msg_id] = $sid |
     .sessions[$sid] = {
       "session_id": $sid,
       "cwd":        $cwd,
       "project":    $project,
       "event":      $event,
       "updated":    (now | todate)
     }' \
    "$STATE_FILE" > "$TMP_STATE" 2>/dev/null \
  && mv "$TMP_STATE" "$STATE_FILE" \
  || rm -f "$TMP_STATE"
) 2>/dev/null || true

exit 0
