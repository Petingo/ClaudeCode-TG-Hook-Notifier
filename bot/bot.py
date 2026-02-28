#!/usr/bin/env python3
"""
Claude Code Telegram Bot
Polls Telegram for replies/button presses and routes commands back to Claude sessions.
"""

import json
import os
import subprocess
import sys
import time
import threading
import logging
import urllib.request
import urllib.error
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
CONFIG_FILE = SCRIPT_DIR / "config.json"
STATE_FILE = Path.home() / ".claude" / "tg-sessions.json"
LOG_FILE = SCRIPT_DIR / "bot.log"
PID_FILE = SCRIPT_DIR / "bot.pid"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()],
)
log = logging.getLogger(__name__)

# Short command codes → full commands
CMD_MAP = {
    "y":   "yes",
    "n":   "no",
    "s":   "What is the current status of the task?",
    "sum": "Please summarize what was just accomplished.",
}


# ── Telegram API ───────────────────────────────────────────────────────────────

def tg(token, method, payload=None, timeout=35):
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        log.error("TG %s %d: %s", method, e.code, e.read().decode())
    except Exception as e:
        log.error("TG %s: %s", method, e)
    return None


def send(token, chat_id, text, reply_to=None):
    payload = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    if reply_to:
        payload["reply_to_message_id"] = reply_to
    res = tg(token, "sendMessage", payload)
    return res["result"]["message_id"] if res and res.get("ok") else None


def edit(token, chat_id, msg_id, text):
    tg(token, "editMessageText", {
        "chat_id": chat_id,
        "message_id": msg_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    })


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ── Session state ──────────────────────────────────────────────────────────────

def load_state():
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except Exception:
            pass
    return {"by_msg": {}, "sessions": {}}


def session_for_msg(msg_id):
    state = load_state()
    sid = state["by_msg"].get(str(msg_id))
    if not sid:
        return None, None
    return sid, state["sessions"].get(sid)


# ── Claude runner ──────────────────────────────────────────────────────────────

def find_claude(config):
    path = config.get("claude_path", "")
    if path and os.access(path, os.X_OK):
        return path
    for p in [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        str(Path.home() / ".npm-global" / "bin" / "claude"),
        str(Path.home() / ".local" / "bin" / "claude"),
        str(Path.home() / ".nvm" / "versions" / "node" / "current" / "bin" / "claude"),
    ]:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    try:
        r = subprocess.run(["which", "claude"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return "claude"


def is_session_active(session_id):
    """Check if a Claude process is currently running for this session."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", f"claude.*{session_id}"],
            capture_output=True, text=True, timeout=3,
        )
        return result.returncode == 0
    except Exception:
        return False


def get_transcript_context(session_id, cwd):
    """Read last assistant message from the session transcript."""
    try:
        # Look in all project dirs for this session's jsonl
        for base in [Path(cwd), Path.home() / ".claude" / "projects"]:
            for jsonl in list(base.rglob(f"{session_id}.jsonl"))[:1]:
                lines = jsonl.read_text().strip().splitlines()
                for line in reversed(lines):
                    try:
                        entry = json.loads(line)
                        if entry.get("type") == "assistant":
                            content = entry.get("message", {}).get("content", "")
                            if isinstance(content, list):
                                texts = [c.get("text", "") for c in content if c.get("type") == "text"]
                                content = "\n".join(texts)
                            if content:
                                return content[:600]
                    except Exception:
                        continue
    except Exception:
        pass
    return None


def resume_session(session_id, cwd, command, config, reply_to_id=None):
    """Resume a COMPLETED session with a new command (only for Stop events)."""
    token = config["bot_token"]
    chat_id = config["chat_id"]

    thinking_id = send(
        token, chat_id,
        f"⏳ <b>Sending to Claude...</b>\n<code>{esc(command[:120])}</code>",
        reply_to=reply_to_id,
    )

    claude = find_claude(config)
    # Clean env: remove CLAUDECODE to avoid nested-session block
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/Users/hyang3/.local/bin:" + env.get("PATH", "")

    try:
        proc = subprocess.run(
            [claude, "-p", command, "--resume", session_id, "--output-format", "text"],
            capture_output=True,
            text=True,
            timeout=300,
            cwd=cwd if os.path.isdir(str(cwd)) else str(Path.home()),
            env=env,
        )
        output = (proc.stdout or proc.stderr or "(empty response)").strip()
        if len(output) > 3800:
            output = output[:3800] + "\n…(truncated)"
        result_text = f"✅ <b>Claude:</b>\n\n{esc(output)}"

    except subprocess.TimeoutExpired:
        result_text = "⏰ <b>Timeout</b> — command exceeded 5-minute limit."
    except FileNotFoundError:
        result_text = "❌ <code>claude</code> not found. Is Claude Code installed?"
    except Exception as e:
        result_text = f"❌ <b>Error:</b> {esc(str(e))}"

    if thinking_id:
        edit(token, chat_id, thinking_id, result_text)
    else:
        send(token, chat_id, result_text)


def notify_active_session(session_id, cwd, command, config, reply_to_id=None):
    """For active sessions: can't inject, tell user to type in terminal."""
    token = config["bot_token"]
    chat_id = config["chat_id"]

    context = get_transcript_context(session_id, cwd)
    ctx_text = f"\n\n<i>Last message:</i>\n{esc(context)}" if context else ""

    text = (
        f"⌨️ <b>Please type in your terminal:</b>\n"
        f"<code>{esc(command)}</code>"
        f"{ctx_text}\n\n"
        f"<i>Session <code>{session_id[:8]}</code> is still active — "
        f"direct input injection is not supported.</i>"
    )
    send(token, chat_id, text, reply_to=reply_to_id)


def dispatch(session_id, session, command, config, reply_to_id=None):
    """Route command based on whether the session is active or completed."""
    cwd = session.get("cwd", str(Path.home()))
    event = session.get("event", "Stop")

    if event == "Stop" and not is_session_active(session_id):
        resume_session(session_id, cwd, command, config, reply_to_id)
    else:
        notify_active_session(session_id, cwd, command, config, reply_to_id)


# ── Update handlers ────────────────────────────────────────────────────────────

def handle_callback(update, config):
    cb = update["callback_query"]
    data = cb.get("data", "")

    if not data.startswith("resume:"):
        tg(config["bot_token"], "answerCallbackQuery", {"callback_query_id": cb["id"]})
        return

    parts = data.split(":", 2)
    if len(parts) != 3:
        return
    _, session_id, cmd_code = parts
    command = CMD_MAP.get(cmd_code, cmd_code)

    state = load_state()
    session = state["sessions"].get(session_id)
    if not session:
        tg(config["bot_token"], "answerCallbackQuery", {
            "callback_query_id": cb["id"],
            "text": "Session not found or expired.",
            "show_alert": True,
        })
        return

    tg(config["bot_token"], "answerCallbackQuery", {
        "callback_query_id": cb["id"],
        "text": f"Processing: {command[:50]}",
    })

    msg_id = cb["message"]["message_id"]
    threading.Thread(
        target=dispatch,
        args=(session_id, session, command, config, msg_id),
        daemon=True,
    ).start()


def handle_message(update, config):
    msg = update.get("message", {})

    # Only accept from the authorised chat
    if str(msg.get("chat", {}).get("id", "")) != str(config["chat_id"]):
        return

    reply_to = msg.get("reply_to_message")
    if not reply_to:
        return

    text = msg.get("text", "").strip()
    if not text:
        return

    session_id, session = session_for_msg(reply_to["message_id"])
    if not session_id:
        return  # not one of our messages

    threading.Thread(
        target=dispatch,
        args=(session_id, session, text, config, msg["message_id"]),
        daemon=True,
    ).start()


# ── Config ─────────────────────────────────────────────────────────────────────

def load_config():
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            return json.load(f)
    return {
        "bot_token": os.environ.get("CLAUDE_HOOK_TG_BOT_TOKEN", ""),
        "chat_id":   os.environ.get("CLAUDE_HOOK_TG_CHAT_ID", ""),
    }


# ── Main loop ──────────────────────────────────────────────────────────────────

def main():
    PID_FILE.write_text(str(os.getpid()))
    config = load_config()

    if not config.get("bot_token") or not config.get("chat_id"):
        log.error("Missing bot_token or chat_id — check %s or env vars", CONFIG_FILE)
        sys.exit(1)

    log.info("Bot started (PID %d)", os.getpid())

    # Discard accumulated updates
    tg(config["bot_token"], "getUpdates", {"offset": -1, "timeout": 1})

    offset = 0
    while True:
        try:
            result = tg(config["bot_token"], "getUpdates", {
                "offset": offset,
                "timeout": 30,
                "allowed_updates": ["message", "callback_query"],
            })
            if not result or not result.get("ok"):
                time.sleep(5)
                continue

            for upd in result["result"]:
                offset = upd["update_id"] + 1
                try:
                    if "callback_query" in upd:
                        handle_callback(upd, config)
                    elif "message" in upd:
                        handle_message(upd, config)
                except Exception as e:
                    log.error("Handler error: %s", e, exc_info=True)

        except KeyboardInterrupt:
            log.info("Bot stopped")
            break
        except Exception as e:
            log.error("Poll error: %s", e)
            time.sleep(5)

    PID_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
