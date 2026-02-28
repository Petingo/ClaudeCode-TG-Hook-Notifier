# feat: Two-way Telegram interaction for Claude Code hooks

## Overview

This PR transforms the existing one-way Telegram notification system into a **two-way interactive interface**. Users can now respond to Claude Code notifications directly from Telegram — clicking inline keyboard buttons or replying to messages — without needing to return to the terminal.

---

## Changes

### Modified: `hooks/notify-telegram.sh`

**Inline keyboard buttons**
- Switched from `--data-urlencode` to a JSON request body (`Content-Type: application/json`) to support `reply_markup` in the Telegram `sendMessage` call.
- Notification events now include an inline keyboard: **✅ Yes / ❌ No / ▶️ Continue / 📊 Status**.
- Stop (task-completed) events include: **▶️ Continue / 📊 Summary**.

**Session state tracking**
- Captures `message_id` from the Telegram API response (previously discarded).
- Persists a mapping of `message_id → {session_id, cwd, event, project}` to `~/.claude/tg-sessions.json`, enabling the bot to look up which Claude session a reply or button press belongs to.

**Transcript context**
- Added `last_assistant_message()`: reads the session's JSONL transcript, extracts the last assistant message's text content via `jq`, and appends it to the notification as a `📋 Last message:` block.
- This surfaces Claude's most recent question or statement (e.g. option prompts) directly in the Telegram message, since the Hook API's `Notification` event does not expose interactive option content.

---

### New: `bot/bot.py`

A lightweight Telegram bot daemon written in **pure Python 3 stdlib** (no third-party packages). It runs as a persistent background process and bridges Telegram replies/button presses back to Claude Code sessions.

**Long polling** — no public URL or webhook infrastructure required.

**`dispatch()` — event-aware routing**

The bot distinguishes between two session states before deciding how to respond:

| Session state | Detection | Action |
|---|---|---|
| **Completed** (`Stop` event, no active process) | `event == "Stop"` + `pgrep` check | `resume_session()` → `claude -p CMD --resume SID` |
| **Active** (`Notification` event, process running) | `event == "Notification"` or process found | `notify_active_session()` → echo command for user to type, with transcript context |

This prevents the critical failure mode where attempting to `--resume` an actively-running interactive Claude session causes the subprocess to hang indefinitely.

**`CLAUDECODE` env var stripping**

When spawning `claude -p --resume`, the bot explicitly removes the `CLAUDECODE` environment variable from the subprocess environment. Without this, Claude Code raises a "nested session" error and refuses to launch.

**Thread-per-request** — each callback or message reply is handled in a daemon thread, keeping the polling loop responsive.

---

### New: `bot/start-bot.sh` / `bot/stop-bot.sh`

Convenience scripts for manually managing the bot daemon process (PID-file based).

---

### New: `~/Library/LaunchAgents/com.claudecode.tg-bot.plist`

A macOS **launchd** agent that:
- Starts the bot automatically on user login (`RunAtLoad: true`)
- Restarts it on crash (`KeepAlive: true`)
- Sets a minimal `PATH` including common Claude Code install locations

---

## Architecture

```
Claude Code
    │  hook event (Notification / Stop)
    ▼
notify-telegram.sh
    │  sendMessage (JSON + reply_markup)    ┌─ ~/.claude/tg-sessions.json
    │  ◀── message_id ──────────────────── ┤  msg_id → session_id, cwd, event
    ▼                                       └─ (written by hook, read by bot)
Telegram
    │  user taps button / replies
    ▼
bot.py  (long-polling)
    │
    ├─ Stop event + session inactive
    │       └─▶  claude -p "<command>" --resume <session_id>
    │                   └─▶ response sent back to Telegram
    │
    └─ Notification event (session active)
            └─▶ "Please type in terminal: <command>"
                + last assistant message from transcript
```

---

## Limitations

- **Active session input injection is not supported**: The Claude Code Hook API (`Notification` event) does not expose the interactive option content shown in the terminal UI (e.g. `1. Yes  2. No  3. Type something`). The transcript context is the closest available approximation.
- **`--resume` only works for completed sessions**: Attempting to resume an active interactive session hangs indefinitely; the bot detects this case and falls back to terminal instructions.
- **macOS only** for the launchd auto-start; Linux users can adapt the plist to a systemd unit file.

---

## Testing

```bash
# Manually trigger a Notification hook
echo '{
  "hook_event_name": "Notification",
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "cwd": "/your/project",
  "notification_type": "permission_prompt",
  "message": "Claude Code needs your attention",
  "permission_mode": "default",
  "transcript_path": "/path/to/session.jsonl"
}' | CLAUDE_HOOK_TG_BOT_TOKEN="..." CLAUDE_HOOK_TG_CHAT_ID="..." \
    ./hooks/notify-telegram.sh

# Check bot is running
launchctl list | grep tg-bot

# View bot logs
tail -f bot/bot.log
```

---

## Files Changed

```
hooks/notify-telegram.sh   modified   inline keyboard, session state, transcript context
bot/bot.py                 new        Telegram long-polling bot daemon
bot/start-bot.sh           new        daemon start script
bot/stop-bot.sh            new        daemon stop script
bot/config.json            new        bot credentials (gitignored)
```
