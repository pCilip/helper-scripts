#!/usr/bin/env python3
"""
Telegram -> Claude Code bridge.
Polluje Telegram, posiela správy do bežiacej Claude Code session cez tmux send-keys.
Claude Code odpovedá sám cez Telegram API (curl) — vie to z CLAUDE.md.
"""

import os, json, time, subprocess, urllib.request, urllib.parse, sys, signal

HOME = os.path.expanduser("~")
CLAUDE_DIR = os.path.join(HOME, ".claude")
ENV_FILE = os.path.join(CLAUDE_DIR, ".env")
OFFSET_FILE = os.path.join(CLAUDE_DIR, "telegram_offset")
LOG_FILE = os.path.join(CLAUDE_DIR, "bridge.log")
TMUX_SESSION = "claude"

# Load .env
try:
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                if k not in os.environ:
                    os.environ[k] = v
except FileNotFoundError:
    pass

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
API = f"https://api.telegram.org/bot{BOT_TOKEN}"

if not BOT_TOKEN or not CHAT_ID:
    print("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID required in ~/.claude/.env")
    sys.exit(1)


def log(msg):
    ts = time.strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")
    print(line, flush=True)


def api_call(method, data=None):
    url = f"{API}/{method}"
    try:
        if data:
            encoded = urllib.parse.urlencode(data).encode()
            req = urllib.request.Request(url, data=encoded)
        else:
            req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=35) as resp:
            return json.loads(resp.read())
    except Exception as e:
        log(f"API error ({method}): {e}")
        return None


def get_offset():
    try:
        with open(OFFSET_FILE) as f:
            return int(f.read().strip())
    except:
        return 0


def save_offset(offset):
    with open(OFFSET_FILE, "w") as f:
        f.write(str(offset))


def tmux_session_exists():
    result = subprocess.run(
        ["tmux", "has-session", "-t", TMUX_SESSION],
        capture_output=True, timeout=5
    )
    return result.returncode == 0


def send_to_claude(text):
    """Send message to Claude Code via tmux send-keys."""
    # Escape special characters for tmux
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", TMUX_SESSION, escaped, "Enter"],
            capture_output=True, timeout=5
        )
        return True
    except Exception as e:
        log(f"tmux send-keys error: {e}")
        return False


def start_claude_session():
    """Start Claude Code in a tmux session."""
    env_str = (
        f"export BUN_INSTALL={HOME}/.bun && "
        f"export PATH=$BUN_INSTALL/bin:/usr/local/bin:/usr/bin:/bin:$PATH && "
        f"export TELEGRAM_BOT_TOKEN={BOT_TOKEN} && "
        f"export TELEGRAM_CHAT_ID={CHAT_ID} && "
        f"export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE={CLAUDE_DIR}/gws/gws-token.json && "
        f"export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file && "
        f"cd {CLAUDE_DIR} && claude"
    )
    subprocess.run(
        ["tmux", "new-session", "-d", "-s", TMUX_SESSION, "bash", "-c", env_str],
        capture_output=True, timeout=10
    )
    # Wait for Claude Code to start
    time.sleep(8)
    log("Claude Code session spustená")


# === Main ===

log(f"Bridge spustený. Chat ID: {CHAT_ID}")

# Start Claude Code session if not running
if not tmux_session_exists():
    log("Spúšťam Claude Code session...")
    start_claude_session()
else:
    log("Claude Code session už beží")

# Skip old messages on first start
offset = get_offset()
if offset == 0:
    skip_data = api_call("getUpdates", {"offset": -1})
    if skip_data and skip_data.get("ok") and skip_data.get("result"):
        last = skip_data["result"][-1]
        offset = last.get("update_id", 0) + 1
        save_offset(offset)
        log(f"Preskočené staré správy. Offset: {offset}")

log(f"Offset: {offset}")

# Graceful shutdown
def shutdown(sig, frame):
    log("Bridge ukončený.")
    sys.exit(0)

signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

# Main loop
while True:
    try:
        # Check if Claude Code session is alive
        if not tmux_session_exists():
            log("Claude Code session zomrela, reštartujem...")
            start_claude_session()
            continue

        # Poll Telegram
        data = api_call("getUpdates", {"offset": offset, "timeout": 30})
        if not data or not data.get("ok"):
            time.sleep(5)
            continue

        for update in data.get("result", []):
            update_id = update.get("update_id", 0)
            msg = update.get("message", {})
            chat_id = str(msg.get("chat", {}).get("id", 0))
            text = msg.get("text", "")

            offset = update_id + 1
            save_offset(offset)

            if chat_id != CHAT_ID or not text:
                continue

            log(f"← {text}")

            # Send to Claude Code session
            prefix = f"[Telegram od Peťa]: "
            if send_to_claude(prefix + text):
                log(f"→ poslaná do Claude Code session")
            else:
                log("✗ nepodarilo sa poslať do session")
                api_call("sendMessage", {
                    "chat_id": CHAT_ID,
                    "text": "Prepáč, agent momentálne nereaguje. Skúsim reštartovať."
                })
                start_claude_session()

    except Exception as e:
        log(f"Chyba: {e}")
        time.sleep(5)
