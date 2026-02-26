#!/usr/bin/env bash
# Claude Code Telegram Hook — Uninstaller
# Removes hook entries from Claude Code settings.json

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# --- Cross-platform sed in-place ---
sed_inplace() {
  if sed --version &>/dev/null; then
    sed -i "$@"    # GNU sed (Linux)
  else
    sed -i '' "$@" # BSD sed (macOS)
  fi
}

# --- Find jq ---
find_jq() {
  if [[ -x /opt/homebrew/bin/jq ]]; then
    echo "/opt/homebrew/bin/jq"
  else
    command -v jq 2>/dev/null || true
  fi
}

# --- Remove hooks from a settings file ---
remove_hooks() {
  local settings_file="$1"
  local JQ="$2"
  local hook_script="$3"

  if [[ ! -f "$settings_file" ]]; then
    return 1
  fi

  # Check if our hook exists in the file
  local has_hook
  has_hook="$("$JQ" --arg cmd "$hook_script" '
    (.hooks.Notification // [] | any(.hooks[]?; .command == $cmd)) or
    (.hooks.Stop // [] | any(.hooks[]?; .command == $cmd))
  ' "$settings_file")"

  if [[ "$has_hook" != "true" ]]; then
    return 1
  fi

  local TEMP_FILE
  TEMP_FILE="$(mktemp)"

  # Remove our hook entries, then clean up empty arrays/objects
  "$JQ" --arg cmd "$hook_script" '
    # Remove matching entries from Notification
    .hooks.Notification = ([.hooks.Notification // [] | .[] | select(.hooks | all(.command != $cmd))])
    |
    # Remove matching entries from Stop
    .hooks.Stop = ([.hooks.Stop // [] | .[] | select(.hooks | all(.command != $cmd))])
    |
    # Clean up empty arrays
    if .hooks.Notification == [] then del(.hooks.Notification) else . end
    |
    if .hooks.Stop == [] then del(.hooks.Stop) else . end
    |
    # Clean up empty hooks object
    if .hooks == {} then del(.hooks) else . end
  ' "$settings_file" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$settings_file"
  return 0
}

# --- Main ---
main() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Claude Code — Telegram Notification Hook    ║"
  echo "║  Uninstaller                                 ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  local JQ
  JQ="$(find_jq)"
  if [[ -z "$JQ" ]]; then
    error "jq not found. Cannot proceed."
    exit 1
  fi

  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local HOOK_SCRIPT="${SCRIPT_DIR}/hooks/notify-telegram.sh"

  local removed=0

  # Check global settings
  local GLOBAL_SETTINGS="$HOME/.claude/settings.json"
  if remove_hooks "$GLOBAL_SETTINGS" "$JQ" "$HOOK_SCRIPT"; then
    ok "Removed from global settings: $GLOBAL_SETTINGS"
    removed=1
  fi

  # Check project settings
  local PROJECT_SETTINGS=".claude/settings.json"
  if remove_hooks "$PROJECT_SETTINGS" "$JQ" "$HOOK_SCRIPT"; then
    ok "Removed from project settings: $PROJECT_SETTINGS"
    removed=1
  fi

  if [[ $removed -eq 0 ]]; then
    warn "No Telegram hook entries found in any settings file"
  else
    echo ""
    ok "Hook entries removed from settings.json"
  fi

  # Clean env vars from shell RC files
  echo ""
  local cleaned_rc=0
  for RC_FILE in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if grep -q 'CLAUDE_HOOK_TG_BOT_TOKEN' "$RC_FILE" 2>/dev/null; then
      read -rp "Remove Telegram credentials from $RC_FILE? [y/N]: " CLEAN_RC
      if [[ "$CLEAN_RC" == "y" || "$CLEAN_RC" == "Y" ]]; then
        sed_inplace '/# Claude Code — Telegram Hook/d' "$RC_FILE"
        sed_inplace '/CLAUDE_HOOK_TG_BOT_TOKEN/d' "$RC_FILE"
        sed_inplace '/CLAUDE_HOOK_TG_CHAT_ID/d' "$RC_FILE"
        ok "Credentials removed from $RC_FILE"
        cleaned_rc=1
      fi
    fi
  done

  if [[ $cleaned_rc -eq 0 && $removed -gt 0 ]]; then
    info "Env vars in shell RC files were not modified."
    echo "  Remove manually if no longer needed."
  fi

  echo ""
  ok "Uninstall complete!"
  echo ""
}

main "$@"
