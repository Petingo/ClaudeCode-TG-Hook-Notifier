#!/usr/bin/env bash
# Claude Code Telegram Notification Hook
# Handles: Notification + Stop events
# Sends notifications via Telegram Bot API when Claude needs attention or completes a task.

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

# --- Load per-project env (fallback to system env) ---
# Priority: project .claude/.env > system env vars
PROJECT_ENV_FILE="${CWD}/.claude/.env"
if [[ -f "$PROJECT_ENV_FILE" ]]; then
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ -z "$key" || "$key" == \#* ]] && continue
    # Remove surrounding quotes from value
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

# Silent exit if credentials not configured
if [[ -z "$CLAUDE_HOOK_TG_BOT_TOKEN" || -z "$CLAUDE_HOOK_TG_CHAT_ID" ]]; then
  exit 0
fi

# --- Metadata ---
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
HOSTNAME="$(hostname -s)"
PROJECT_NAME="$(basename "$CWD")"

# --- HTML escape helper ---
html_escape() {
  local text="$1"
  text="${text//&/&amp;}"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  printf '%s' "$text"
}

# --- Truncate helper ---
truncate_text() {
  local text="$1"
  local max_len="${2:-3500}"
  if [[ ${#text} -gt $max_len ]]; then
    printf '%s…(truncated)' "${text:0:$max_len}"
  else
    printf '%s' "$text"
  fi
}

# --- Build message based on event type ---
MESSAGE=""

case "$HOOK_EVENT" in
  Notification)
    NOTIFICATION_TYPE="$("$JQ" -r '.notification_type // "unknown"' <<< "$INPUT")"
    NOTIFICATION_MSG="$("$JQ" -r '.message // ""' <<< "$INPUT")"
    TOOL_NAME="$("$JQ" -r '.tool_name // ""' <<< "$INPUT")"

    # Map notification_type to emoji and label
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

    # Build detail line
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
    ;;

  Stop)
    # Check stop_hook_active to avoid infinite notification loops
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
    ;;

  *)
    # Unknown event, silently exit
    exit 0
    ;;
esac

# --- Append separator ---
MESSAGE="${MESSAGE}

——————————————"

# --- Send to Telegram ---
if [[ -n "$MESSAGE" ]]; then
  curl -s --max-time 10 \
    --data-urlencode "chat_id=${CLAUDE_HOOK_TG_CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" \
    "https://api.telegram.org/bot${CLAUDE_HOOK_TG_BOT_TOKEN}/sendMessage" \
    > /dev/null 2>&1 || true
fi

exit 0
