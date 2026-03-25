#!/usr/bin/env bash
# Claude Assistant — spúšťa Telegram bridge
# Bridge sa postará o spustenie Claude Code v tmux session "claude"
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

set -a
source "${HOME}/.claude/.env" 2>/dev/null || true
set +a

exec python3 "${HOME}/.claude/telegram-bridge.py"
