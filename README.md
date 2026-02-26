# Claude Code — Telegram Notification Hook

Get Telegram notifications when Claude Code needs your attention or completes a task. No more staring at the terminal waiting.

<p align="center">
  <img src="img/demo.png" alt="Telegram notification demo" width="400">
</p>

## What You Get

- **Permission Required** — Claude needs approval for a tool (e.g., Bash, file edit)
- **Idle / Input Needed** — Claude is waiting for your input
- **Task Completed** — Claude finished its response (with a summary of what it said)

## Prerequisites

- macOS or Linux
- `jq` and `curl` installed (`brew install jq curl` or `apt install jq curl`)
- [Claude Code](https://claude.com/claude-code) CLI installed
- A Telegram account

## Setup

### 1. Create a Telegram Bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot` and follow the prompts
3. Copy the **Bot Token** (looks like `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

### 2. Get Your Chat ID

1. Start a conversation with your new bot (send any message)
2. Open this URL in your browser (replace `YOUR_BOT_TOKEN`):
   ```
   https://api.telegram.org/botYOUR_BOT_TOKEN/getUpdates
   ```
3. Find `"chat":{"id":123456789}` in the response — that number is your **Chat ID**

**Tip:** For group notifications, add the bot to a group and use the group's chat ID (negative number).

### 3. Set Environment Variables

The hook uses namespaced env vars to avoid collisions: `CLAUDE_HOOK_TG_BOT_TOKEN` and `CLAUDE_HOOK_TG_CHAT_ID`.

**Option A — Global fallback** (all projects, in `~/.zshrc` or `~/.bashrc`):

```bash
export CLAUDE_HOOK_TG_BOT_TOKEN="your-bot-token-here"
export CLAUDE_HOOK_TG_CHAT_ID="your-chat-id-here"
```

Then reload: `source ~/.zshrc` (or `source ~/.bashrc`)

**Option B — Per-project override** (in `<project>/.claude/.env`):

```bash
CLAUDE_HOOK_TG_BOT_TOKEN=project-specific-bot-token
CLAUDE_HOOK_TG_CHAT_ID=project-specific-chat-id
```

**Priority**: Project `.claude/.env` > System env vars. This lets you send different projects' notifications to different bots or chats, while keeping a global default as fallback.

### 4. Install the Hook

```bash
git clone https://github.com/stevenyu113228/ClaudeCode-TG-Hook-Notifier.git
cd ClaudeCode-TG-Hook-Notifier
./install.sh
```

The installer will:
- Check that `jq` and `curl` are available
- Ask for your Bot Token and auto-detect Chat ID
- Write credentials to `~/.zshrc` or `~/.bashrc` (auto-detected, or specify a custom path)
- Ask you to choose global or project-level hook installation
- Merge hook config into your Claude Code `settings.json`
- Optionally send a test notification

### 5. Verify

Start a new Claude Code session and trigger a permission prompt. You should receive a Telegram notification.

## Manual Test

You can test the hook directly without installing:

```bash
# Test Notification event
echo '{"hook_event_name":"Notification","session_id":"test-123","cwd":"'"$(pwd)"'","notification_type":"idle_prompt","message":"Test notification","permission_mode":"default","transcript_path":"/tmp/test.jsonl"}' | ./hooks/notify-telegram.sh

# Test Stop event
echo '{"hook_event_name":"Stop","session_id":"test-123","cwd":"'"$(pwd)"'","stop_hook_active":false,"last_assistant_message":"Task completed successfully.","permission_mode":"default","transcript_path":"/tmp/test.jsonl"}' | ./hooks/notify-telegram.sh
```

## Uninstall

```bash
./uninstall.sh
```

The uninstaller will:
- Remove hook entries from `settings.json` (global + project)
- Ask whether to remove credentials from `~/.zshrc` and `~/.bashrc`
- Project `.claude/.env` files are not touched — remove them manually if needed.

## How It Works

A single script (`hooks/notify-telegram.sh`) handles two Claude Code hook events:

| Event | Trigger | Notification |
|-------|---------|-------------|
| `Notification` | Claude needs attention (permission, idle, input) | Emoji + type + project info |
| `Stop` | Claude finishes a response | Summary of last message (truncated to 3500 chars) |

### Key Design Choices

- **`async: true`** — Network I/O happens in background, never blocks Claude
- **`exit 0` always** — Hook failures are silent, never interrupt your workflow
- **`stop_hook_active` guard** — Prevents infinite notification loops on Stop events
- **HTML escaping** — Safe handling of `<`, `>`, `&` in messages
- **`--max-time 10`** — Hard timeout on curl to prevent hangs

### Message Format

```
🔐 Claude Code — Permission Required

Host:      MacBook
Project:   my-web-app
Session:   abc123-def456
Directory: /Users/you/projects/my-web-app
Time:      2026-02-26 14:30:45

Claude needs your permission to use Bash
```

## Settings Structure

The installer merges this into your `settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [{
          "type": "command",
          "command": "/path/to/hooks/notify-telegram.sh",
          "async": true,
          "timeout": 30
        }]
      }
    ],
    "Stop": [
      {
        "hooks": [{
          "type": "command",
          "command": "/path/to/hooks/notify-telegram.sh",
          "async": true,
          "timeout": 30
        }]
      }
    ]
  }
}
```

Existing settings (model, permissions, other hooks) are preserved.

## Troubleshooting

**No notifications received?**
- Check `echo $CLAUDE_HOOK_TG_BOT_TOKEN $CLAUDE_HOOK_TG_CHAT_ID` — both must be set
- Or check your project's `.claude/.env` file
- Make sure you started a conversation with the bot first
- Run the manual test command above and check for curl errors

**Permission errors?**
- Run `chmod +x hooks/notify-telegram.sh`

**jq not found?**
- Install with `brew install jq`
- The script checks `/opt/homebrew/bin/jq` first, then `$PATH`

## License

MIT
