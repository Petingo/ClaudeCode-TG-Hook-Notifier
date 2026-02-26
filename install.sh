#!/usr/bin/env bash
# Claude Code Telegram Hook — Installer
# Merges hook configuration into Claude Code settings.json

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { printf "${CYAN}[INFO]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# --- Cross-platform sed in-place ---
sed_inplace() {
  if sed --version &>/dev/null; then
    sed -i "$@"    # GNU sed (Linux)
  else
    sed_inplace "$@" # BSD sed (macOS)
  fi
}

# --- Resolve script directory (handle symlinks) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="${SCRIPT_DIR}/hooks/notify-telegram.sh"

# --- Check dependencies ---
check_deps() {
  local missing=()

  if ! command -v jq &>/dev/null && [[ ! -x /opt/homebrew/bin/jq ]]; then
    missing+=("jq")
  fi
  if ! command -v curl &>/dev/null; then
    missing+=("curl")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing dependencies: ${missing[*]}"
    echo "  Install with: brew install ${missing[*]}"
    exit 1
  fi
}

# --- Find jq ---
find_jq() {
  if [[ -x /opt/homebrew/bin/jq ]]; then
    echo "/opt/homebrew/bin/jq"
  else
    command -v jq
  fi
}

# --- Main ---
main() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Claude Code — Telegram Notification Hook    ║"
  echo "║  Installer                                   ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  # Check dependencies
  check_deps
  local JQ
  JQ="$(find_jq)"
  ok "Dependencies found (jq, curl)"

  # Check hook script exists
  if [[ ! -f "$HOOK_SCRIPT" ]]; then
    error "Hook script not found: $HOOK_SCRIPT"
    exit 1
  fi
  chmod +x "$HOOK_SCRIPT"

  # Configure Telegram credentials
  echo ""
  local CURRENT_TOKEN="${CLAUDE_HOOK_TG_BOT_TOKEN:-}"
  local CURRENT_CHAT_ID="${CLAUDE_HOOK_TG_CHAT_ID:-}"

  if [[ -n "$CURRENT_TOKEN" ]]; then
    ok "CLAUDE_HOOK_TG_BOT_TOKEN is set (${CURRENT_TOKEN:0:10}...)"
    read -rp "  Update it? [y/N]: " UPDATE_TOKEN
    if [[ "$UPDATE_TOKEN" == "y" || "$UPDATE_TOKEN" == "Y" ]]; then
      CURRENT_TOKEN=""
    fi
  fi

  if [[ -z "$CURRENT_TOKEN" ]]; then
    echo ""
    info "Get your bot token from @BotFather on Telegram (/newbot)"
    read -rp "  Enter TELEGRAM_BOT_TOKEN: " CURRENT_TOKEN
    if [[ -z "$CURRENT_TOKEN" ]]; then
      error "Bot token is required"
      exit 1
    fi
  fi

  if [[ -n "$CURRENT_CHAT_ID" ]]; then
    ok "CLAUDE_HOOK_TG_CHAT_ID is set ($CURRENT_CHAT_ID)"
    read -rp "  Update it? [y/N]: " UPDATE_CHAT
    if [[ "$UPDATE_CHAT" == "y" || "$UPDATE_CHAT" == "Y" ]]; then
      CURRENT_CHAT_ID=""
    fi
  fi

  if [[ -z "$CURRENT_CHAT_ID" ]]; then
    echo ""
    info "Send any message to your bot, then press Enter to auto-detect your Chat ID..."
    read -r
    # Auto-detect chat ID from getUpdates
    local UPDATES
    UPDATES="$(curl -s --max-time 10 "https://api.telegram.org/bot${CURRENT_TOKEN}/getUpdates" 2>/dev/null)"
    CURRENT_CHAT_ID="$(echo "$UPDATES" | "$JQ" -r '.result[-1].message.chat.id // empty' 2>/dev/null)"

    if [[ -n "$CURRENT_CHAT_ID" ]]; then
      local CHAT_NAME
      CHAT_NAME="$(echo "$UPDATES" | "$JQ" -r '.result[-1].message.chat.first_name // .result[-1].message.chat.title // empty' 2>/dev/null)"
      ok "Auto-detected Chat ID: $CURRENT_CHAT_ID ($CHAT_NAME)"
    else
      warn "Could not auto-detect. Enter manually."
      read -rp "  Enter TELEGRAM_CHAT_ID: " CURRENT_CHAT_ID
      if [[ -z "$CURRENT_CHAT_ID" ]]; then
        error "Chat ID is required"
        exit 1
      fi
    fi
  fi

  # Detect shell RC file
  local RC_FILE
  case "$(basename "${SHELL:-/bin/zsh}")" in
    bash) RC_FILE="$HOME/.bashrc" ;;
    *)    RC_FILE="$HOME/.zshrc" ;;
  esac

  # Allow user to override
  if [[ ! -f "$RC_FILE" ]]; then
    # Fallback: try both
    if [[ -f "$HOME/.zshrc" ]]; then
      RC_FILE="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
      RC_FILE="$HOME/.bashrc"
    fi
  fi

  echo ""
  read -rp "Write credentials to $RC_FILE? [Y/n/other path]: " RC_CHOICE
  case "$RC_CHOICE" in
    n|N) info "Skipping — set env vars manually" ;;
    ""|y|Y) ;; # use detected RC_FILE
    *) RC_FILE="$RC_CHOICE" ;;
  esac

  if [[ "$RC_CHOICE" != "n" && "$RC_CHOICE" != "N" ]]; then
    # Remove old entries if present
    if grep -q 'CLAUDE_HOOK_TG_BOT_TOKEN' "$RC_FILE" 2>/dev/null; then
      sed_inplace '/# Claude Code — Telegram Hook/d' "$RC_FILE"
      sed_inplace '/CLAUDE_HOOK_TG_BOT_TOKEN/d' "$RC_FILE"
      sed_inplace '/CLAUDE_HOOK_TG_CHAT_ID/d' "$RC_FILE"
    fi

    {
      echo ""
      echo "# Claude Code — Telegram Hook"
      echo "export CLAUDE_HOOK_TG_BOT_TOKEN=\"${CURRENT_TOKEN}\""
      echo "export CLAUDE_HOOK_TG_CHAT_ID=\"${CURRENT_CHAT_ID}\""
    } >> "$RC_FILE"
    ok "Credentials written to $RC_FILE"
  fi

  # Export for current process (so test message works)
  export CLAUDE_HOOK_TG_BOT_TOKEN="$CURRENT_TOKEN"
  export CLAUDE_HOOK_TG_CHAT_ID="$CURRENT_CHAT_ID"

  # Choose installation scope
  echo ""
  info "Where should the hook be installed?"
  echo "  1) Global  (~/.claude/settings.json) — all projects"
  echo "  2) Project (.claude/settings.json)   — this project only"
  echo ""
  read -rp "Choose [1/2] (default: 1): " SCOPE_CHOICE
  SCOPE_CHOICE="${SCOPE_CHOICE:-1}"

  local SETTINGS_FILE
  case "$SCOPE_CHOICE" in
    2)
      SETTINGS_FILE=".claude/settings.json"
      mkdir -p .claude
      info "Installing to project: $SETTINGS_FILE"
      ;;
    *)
      SETTINGS_FILE="$HOME/.claude/settings.json"
      mkdir -p "$HOME/.claude"
      info "Installing globally: $SETTINGS_FILE"
      ;;
  esac

  # Initialize settings file if it doesn't exist
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo '{}' > "$SETTINGS_FILE"
    info "Created new settings file"
  fi

  # Check for existing hooks
  local EXISTING_HOOKS
  EXISTING_HOOKS="$("$JQ" -r '.hooks // empty' "$SETTINGS_FILE")"
  if [[ -n "$EXISTING_HOOKS" && "$EXISTING_HOOKS" != "null" && "$EXISTING_HOOKS" != "{}" ]]; then
    warn "Existing hooks detected in settings file:"
    "$JQ" '.hooks' "$SETTINGS_FILE"
    echo ""
    read -rp "Merge with existing hooks? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  # Build hook entry JSON
  local HOOK_ENTRY
  HOOK_ENTRY="$("$JQ" -n --arg cmd "$HOOK_SCRIPT" '{
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "async": true,
      "timeout": 30
    }]
  }')"

  # Deep merge into settings
  local TEMP_FILE
  TEMP_FILE="$(mktemp)"

  "$JQ" --argjson hook_entry "$HOOK_ENTRY" '
    .hooks.Notification = ((.hooks.Notification // []) + [$hook_entry] | unique_by(.hooks[0].command)) |
    .hooks.Stop = ((.hooks.Stop // []) + [$hook_entry] | unique_by(.hooks[0].command))
  ' "$SETTINGS_FILE" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$SETTINGS_FILE"

  ok "Hook configuration merged into $SETTINGS_FILE"
  echo ""
  info "Current hooks configuration:"
  "$JQ" '.hooks' "$SETTINGS_FILE"

  # Optional: send test message
  echo ""
  read -rp "Send a test notification to Telegram? [y/N]: " TEST_CHOICE
  if [[ "$TEST_CHOICE" == "y" || "$TEST_CHOICE" == "Y" ]]; then
    if [[ -z "${CLAUDE_HOOK_TG_BOT_TOKEN:-}" || -z "${CLAUDE_HOOK_TG_CHAT_ID:-}" ]]; then
      error "Cannot send test: CLAUDE_HOOK_TG_BOT_TOKEN and CLAUDE_HOOK_TG_CHAT_ID must be set"
    else
      info "Sending test notification..."
      echo '{"hook_event_name":"Notification","session_id":"test-install","cwd":"'"$(pwd)"'","notification_type":"idle_prompt","message":"Installation test — if you see this, the hook is working!","permission_mode":"default","transcript_path":"/tmp/test.jsonl"}' \
        | "$HOOK_SCRIPT"
      ok "Test notification sent! Check your Telegram."
    fi
  fi

  echo ""
  ok "Installation complete!"
  echo ""
  echo "  Next steps:"
  echo "  1. Open a NEW terminal (so shell RC takes effect)"
  echo "  2. Start a Claude Code session"
  echo "  3. You'll receive Telegram notifications when Claude needs attention"
  echo ""
  echo "  Per-project override: add CLAUDE_HOOK_TG_BOT_TOKEN / CLAUDE_HOOK_TG_CHAT_ID"
  echo "  to <project>/.claude/.env to send to a different bot or chat."
  echo ""
}

main "$@"
