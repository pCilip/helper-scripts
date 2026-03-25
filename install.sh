#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
#  Claude Assistant Installer v2
#  Osobná AI asistentka — Telegram bridge + Claude Code
#  Beží ako user 'claude', nie root
# ─────────────────────────────────────────────────────────

VERSION="2.0.0"
CLAUDE_USER="claude"
CLAUDE_HOME="/home/${CLAUDE_USER}"
WORKSPACE="${CLAUDE_HOME}/.claude"
LOG="/tmp/claude-assistant-install.log"
REPO_URL="https://raw.githubusercontent.com/pCilip/helper-scripts/main"

# ── Farby ──────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'
D='\033[2m'; N='\033[0m'; BOLD='\033[1m'

# ── UI helpery ────────────────────────────────────────
header() {
  clear
  echo -e "${C}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║      Claude Assistant Installer v${VERSION}         ║"
  echo "  ║   Osobná AI asistentka — Telegram + Claude Code  ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${N}"
}

step()  { echo -e "\n${B}${BOLD}▶ $1${N}"; }
ok()    { echo -e "  ${G}✓${N} $1"; }
warn()  { echo -e "  ${Y}⚠${N}  $1"; }
err()   { echo -e "  ${R}✗${N} $1" >&2; }
info()  { echo -e "  ${D}$1${N}"; }
ask()   { echo -ne "\n  ${W}$1${N} "; }
divider() { echo -e "  ${D}──────────────────────────────────────────────────${N}"; }

progress() { echo -ne "  ${D}${1}...${N}"; }
done_progress() { echo -e " ${G}hotovo${N}"; }

ask_secret() {
  echo -ne "\n  ${W}$1${N} "
  read -rs REPLY
  echo
  echo "$REPLY"
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ── Detekcia prostredia ───────────────────────────────
detect_environment() {
  step "Detekcia prostredia"

  local is_lxc=false
  grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && is_lxc=true
  [[ "$is_lxc" == false ]] && grep -qa 'lxc' /proc/self/cgroup 2>/dev/null && is_lxc=true
  [[ "$is_lxc" == false ]] && [[ -f /run/systemd/container ]] && grep -qa 'lxc' /run/systemd/container 2>/dev/null && is_lxc=true
  [[ "$is_lxc" == false ]] && systemd-detect-virt --container 2>/dev/null | grep -q lxc && is_lxc=true

  if [[ "$is_lxc" == true ]]; then
    ok "Prostredie: LXC kontajner"
  else
    ok "Prostredie: VPS / VM"
  fi

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ok "OS: $PRETTY_NAME"
  fi

  log "LXC=$is_lxc OS=${PRETTY_NAME:-unknown}"
}

check_internet() {
  step "Kontrola internetu"
  if curl -s --max-time 5 https://api.anthropic.com > /dev/null 2>&1; then
    ok "Internet OK"
  else
    err "Žiadne internetové pripojenie."
    exit 1
  fi
}

# ── Systémové závislosti ──────────────────────────────
install_deps() {
  step "Systémové závislosti"

  # Timezone
  ln -sf /usr/share/zoneinfo/Europe/Prague /etc/localtime
  echo "Europe/Prague" > /etc/timezone
  ok "Timezone: Europe/Prague ($(date +%Z))"

  progress "Aktualizácia balíčkov"
  apt-get update -qq >> "$LOG" 2>&1
  done_progress

  for pkg in curl git tmux unzip jq python3 sudo openssh-server; do
    if command -v "$pkg" &>/dev/null || dpkg -l "$pkg" &>/dev/null 2>&1; then
      ok "$pkg — OK"
    else
      progress "Inštalácia $pkg"
      apt-get install -y -qq "$pkg" >> "$LOG" 2>&1
      done_progress
    fi
  done
}

# ── Vytvorenie claude usera ───────────────────────────
create_claude_user() {
  step "Užívateľ '${CLAUDE_USER}'"

  if id "$CLAUDE_USER" &>/dev/null; then
    ok "Užívateľ už existuje"
  else
    useradd -m -s /bin/bash "$CLAUDE_USER"
    ok "Užívateľ vytvorený"
  fi

  # Heslo
  ask "Nastav heslo pre usera '${CLAUDE_USER}' (pre SSH prístup):"
  read -rs user_pass
  echo
  if [[ -n "$user_pass" ]]; then
    echo "${CLAUDE_USER}:${user_pass}" | chpasswd
    ok "Heslo nastavené"
  fi

  # SSH
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
  systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true

  mkdir -p "$WORKSPACE" "${WORKSPACE}/gws" "${WORKSPACE}/channels/telegram" "${WORKSPACE}/inbox"
  chown -R "${CLAUDE_USER}:${CLAUDE_USER}" "$CLAUDE_HOME"
}

# ── Node.js ───────────────────────────────────────────
install_node() {
  step "Node.js 20+"

  if command -v node &>/dev/null; then
    local ver major
    ver=$(node --version)
    major=${ver#v}; major=${major%%.*}
    if [[ $major -ge 20 ]]; then
      ok "Node.js $ver — OK"
      return
    fi
  fi

  progress "Inštalácia Node.js 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >> "$LOG" 2>&1
  apt-get install -y -qq nodejs >> "$LOG" 2>&1
  done_progress
  ok "Node.js $(node --version)"
}

# ── Bun ───────────────────────────────────────────────
install_bun() {
  step "Bun runtime"

  if [[ -f "${CLAUDE_HOME}/.bun/bin/bun" ]]; then
    ok "Bun — už nainštalovaný"
  else
    progress "Inštalácia Bun (ako ${CLAUDE_USER})"
    su - "$CLAUDE_USER" -c 'curl -fsSL https://bun.sh/install | bash' >> "$LOG" 2>&1
    done_progress
  fi

  # Symlink do global PATH
  ln -sf "${CLAUDE_HOME}/.bun/bin/bun" /usr/local/bin/bun
  ok "Bun dostupný globálne: $(bun --version 2>/dev/null || echo 'OK')"
}

# ── Claude Code ───────────────────────────────────────
install_claude_code() {
  step "Claude Code"

  if command -v claude &>/dev/null; then
    ok "Claude Code $(claude --version 2>/dev/null) — OK"
  else
    progress "Inštalácia Claude Code"
    npm install -g @anthropic-ai/claude-code >> "$LOG" 2>&1
    done_progress
    ok "Claude Code nainštalovaný"
  fi
}

# ── Google Cloud + gws CLI ────────────────────────────
install_gcloud() {
  step "Google Cloud CLI"

  if command -v gcloud &>/dev/null; then
    ok "gcloud — už nainštalovaný"
    return
  fi

  progress "Sťahovanie gcloud CLI"
  curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | \
    tar -xz -C /opt >> "$LOG" 2>&1
  done_progress

  progress "Inštalácia"
  /opt/google-cloud-sdk/install.sh --quiet >> "$LOG" 2>&1
  done_progress

  source /opt/google-cloud-sdk/path.bash.inc 2>/dev/null || true
  if ! grep -q 'google-cloud-sdk' "${CLAUDE_HOME}/.bashrc" 2>/dev/null; then
    echo 'source /opt/google-cloud-sdk/path.bash.inc' >> "${CLAUDE_HOME}/.bashrc"
  fi
  ok "gcloud CLI nainštalovaný"
}

install_gws() {
  step "Google Workspace CLI (gws)"

  install_gcloud

  if command -v gws &>/dev/null; then
    ok "gws — už nainštalovaný"
  else
    progress "Inštalácia gws"
    npm install -g @googleworkspace/cli >> "$LOG" 2>&1
    done_progress
    ok "gws nainštalovaný"
  fi
}

# ── Google Workspace auth (headless) ──────────────────
setup_google_auth() {
  step "Google Workspace autentifikácia"
  divider

  echo
  echo -e "  ${W}Chceš nastaviť Gmail a Kalendár?${N}"
  info "(gws vyžaduje OAuth token z PC s browserom)"
  echo
  ask "Nastaviť Google Workspace? [y/n]:"
  read -r gws_choice

  if [[ ! "$gws_choice" =~ ^[Yy]$ ]]; then
    warn "Preskakujem — nastav neskôr"
    return
  fi

  echo
  echo -e "  ${Y}Headless postup — spusti na PC s browserom:${N}"
  divider
  info "1. npm install -g @googleworkspace/cli"
  info "2. gws auth login"
  info "3. gws auth export --unmasked > gws-token.json"
  info "4. Skopíruj gws-token.json na tento server"
  divider
  echo

  ask "Cesta k gws-token.json (alebo Enter = preskočiť):"
  read -r token_path

  if [[ -n "$token_path" && -f "$token_path" ]]; then
    cp "$token_path" "${WORKSPACE}/gws/gws-token.json"
    chmod 600 "${WORKSPACE}/gws/gws-token.json"
    chown "${CLAUDE_USER}:${CLAUDE_USER}" "${WORKSPACE}/gws/gws-token.json"

    # Pridaj do .env
    cat >> "${WORKSPACE}/.env" << EOF
GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=${WORKSPACE}/gws/gws-token.json
GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
EOF
    ok "Google Workspace token nakonfigurovaný"
  else
    warn "Preskakujem — nastav neskôr"
    info "Skopíruj gws-token.json do: ${WORKSPACE}/gws/"
  fi
}

# ── Claude Code auth ──────────────────────────────────
setup_claude_auth() {
  step "Claude Code prihlásenie"
  divider

  echo
  info "Claude Code vyžaduje prihlásenie cez claude.ai"
  info "Spustím 'claude' ako user '${CLAUDE_USER}' — postupuj podľa inštrukcií."
  echo
  ask "Stlač Enter pre spustenie prihlasovania..."
  read -r

  su - "$CLAUDE_USER" -c "claude" || true

  echo
  ask "Prihlásenie úspešné? [y/n]:"
  read -r auth_ok
  if [[ "$auth_ok" =~ ^[Yy]$ ]]; then
    ok "Claude Code prihlásený"
  else
    warn "Dokonči prihlásenie neskôr: su - ${CLAUDE_USER} -c 'claude'"
  fi
}

# ── Telegram ──────────────────────────────────────────
setup_telegram() {
  step "Telegram bot"
  divider

  echo
  echo -e "  ${Y}Ako získaš Telegram bot token:${N}"
  divider
  info "1. Telegram → @BotFather → /newbot"
  info "2. Zadaj meno a username bota"
  info "3. Skopíruj TOKEN"
  divider
  echo

  local tg_token
  tg_token=$(ask_secret "Telegram Bot Token (Enter = preskočiť):")

  if [[ -z "$tg_token" ]]; then
    warn "Preskakujem Telegram"
    return
  fi

  echo "TELEGRAM_BOT_TOKEN=${tg_token}" >> "${WORKSPACE}/.env"

  echo
  info "Teraz pošli botovi správu na Telegrame a spusti:"
  info "  curl -s 'https://api.telegram.org/bot${tg_token}/getUpdates' | python3 -m json.tool"
  info "Nájdi tam svoje chat ID (číslo v chat.id)"
  echo
  ask "Tvoje Telegram Chat ID:"
  read -r chat_id

  if [[ -n "$chat_id" ]]; then
    echo "TELEGRAM_CHAT_ID=${chat_id}" >> "${WORKSPACE}/.env"
    ok "Telegram nakonfigurovaný (token + chat ID)"

    # Token pre channels plugin (keby v budúcnosti fungoval)
    echo "TELEGRAM_BOT_TOKEN=${tg_token}" > "${WORKSPACE}/channels/telegram/.env"
    chmod 600 "${WORKSPACE}/channels/telegram/.env"
  else
    warn "Chat ID chýba — doplň neskôr do ${WORKSPACE}/.env"
  fi
}

# ── Stiahnutie súborov z repa ─────────────────────────
download_files() {
  step "Sťahovanie súborov"

  local files=("files/telegram-bridge.py" "files/start.sh" "files/settings.json" "files/CLAUDE.md.template")
  for f in "${files[@]}"; do
    local dest="${WORKSPACE}/$(basename "$f" .template)"
    progress "$(basename "$f")"
    if curl -fsSL "${REPO_URL}/${f}" -o "$dest" 2>/dev/null; then
      done_progress
    else
      err "Nepodarilo sa stiahnuť $f"
    fi
  done

  chmod +x "${WORKSPACE}/telegram-bridge.py" "${WORKSPACE}/start.sh"
}

# ── CLAUDE.md generovanie ─────────────────────────────
generate_claude_md() {
  step "Konfigurácia asistentky"

  ask "Meno asistentky [Asistentka]:"
  read -r assistant_name
  assistant_name="${assistant_name:-Asistentka}"

  ask "Tvoje meno [Peťo]:"
  read -r user_name
  user_name="${user_name:-Peťo}"

  ask "Jazyk [slovenčine]:"
  read -r lang
  lang="${lang:-slovenčine}"

  # Nahradenie premenných v template
  if [[ -f "${WORKSPACE}/CLAUDE.md.template" ]]; then
    sed -e "s|{{ASSISTANT_NAME}}|${assistant_name}|g" \
        -e "s|{{USER_NAME}}|${user_name}|g" \
        -e "s|{{LANG}}|${lang}|g" \
        "${WORKSPACE}/CLAUDE.md.template" > "${WORKSPACE}/CLAUDE.md"
    rm -f "${WORKSPACE}/CLAUDE.md.template"
  fi

  # Aktualizuj bridge prefix
  sed -i "s|Telegram od Peťa|Telegram od ${user_name}|g" "${WORKSPACE}/telegram-bridge.py" 2>/dev/null || true

  ok "CLAUDE.md vygenerovaný pre ${assistant_name}"
}

# ── Claude Code nastavenia ────────────────────────────
setup_claude_settings() {
  step "Claude Code nastavenia"

  # Trusted directories
  if [[ -f "${CLAUDE_HOME}/.claude.json" ]]; then
    python3 -c "
import json
with open('${CLAUDE_HOME}/.claude.json') as f: d=json.load(f)
d['trustedDirectories'] = {'${CLAUDE_HOME}': True, '${WORKSPACE}': True}
with open('${CLAUDE_HOME}/.claude.json', 'w') as f: json.dump(d, f, indent=2)
" 2>/dev/null || true
  fi

  # Settings.json je už stiahnutý
  ok "Permissions a trusted directories nastavené"
}

# ── Autostart ─────────────────────────────────────────
setup_autostart() {
  step "Autostart (tmux + cron)"

  # cron @reboot pre claude usera
  local cron_line="@reboot sleep 10 && tmux new-session -d -s bridge 'bash ${WORKSPACE}/start.sh' >> ${WORKSPACE}/cron.log 2>&1"

  if ! (su - "$CLAUDE_USER" -c 'crontab -l' 2>/dev/null || true) | grep -q 'claude'; then
    (su - "$CLAUDE_USER" -c 'crontab -l' 2>/dev/null || true; echo "$cron_line") | su - "$CLAUDE_USER" -c 'crontab -'
    ok "cron @reboot nastavený"
  else
    ok "cron @reboot — už existuje"
  fi

  info "Asistentka sa spustí automaticky pri štarte"
}

# ── Finalizácia ───────────────────────────────────────
finalize() {
  # Vlastníctvo
  chown -R "${CLAUDE_USER}:${CLAUDE_USER}" "$CLAUDE_HOME"
  chmod 600 "${WORKSPACE}/.env"

  # .env nastavenia
  local env="${WORKSPACE}/.env"
  chmod 600 "$env"
}

# ── Prvé spustenie ────────────────────────────────────
first_start() {
  step "Prvé spustenie"

  ask "Spustiť asistentku teraz? [y/n]:"
  read -r start_now

  if [[ "$start_now" =~ ^[Yy]$ ]]; then
    su - "$CLAUDE_USER" -c "tmux new-session -d -s bridge 'bash ${WORKSPACE}/start.sh'"
    sleep 5

    if su - "$CLAUDE_USER" -c "tmux has-session -t bridge" 2>/dev/null; then
      ok "Bridge beží"
      if su - "$CLAUDE_USER" -c "tmux has-session -t claude" 2>/dev/null; then
        ok "Claude Code session beží"
      else
        warn "Claude Code session sa ešte štartuje..."
      fi
    else
      warn "Bridge sa nepodarilo spustiť — pozri ${WORKSPACE}/bridge.log"
    fi
  fi
}

# ── Súhrn ─────────────────────────────────────────────
print_summary() {
  header
  echo -e "  ${G}${BOLD}✓ Inštalácia dokončená!${N}"
  echo
  divider
  echo
  echo -e "  ${W}Nainštalované:${N}"
  command -v node &>/dev/null && ok "Node.js $(node --version)"
  command -v bun &>/dev/null && ok "Bun $(bun --version 2>/dev/null)"
  command -v claude &>/dev/null && ok "Claude Code"
  command -v gws &>/dev/null && ok "Google Workspace CLI"
  [[ -f "${WORKSPACE}/CLAUDE.md" ]] && ok "CLAUDE.md"
  [[ -f "${WORKSPACE}/telegram-bridge.py" ]] && ok "Telegram bridge"
  echo
  divider
  echo
  echo -e "  ${W}Správa:${N}"
  echo
  echo -e "  ${G}Pripojiť sa k agentovi:${N}"
  echo -e "     ${C}su - ${CLAUDE_USER} -c 'tmux attach -t claude'${N}"
  echo -e "     ${D}(Ctrl+B, D pre detach)${N}"
  echo
  echo -e "  ${G}Reštart:${N}"
  echo -e "     ${C}su - ${CLAUDE_USER} -c 'tmux kill-server; tmux new-session -d -s bridge bash ${WORKSPACE}/start.sh'${N}"
  echo
  echo -e "  ${G}Logy:${N}"
  echo -e "     ${C}tail -f ${WORKSPACE}/bridge.log${N}"
  echo
  echo -e "  ${G}SSH:${N}"
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  echo -e "     ${C}ssh ${CLAUDE_USER}@${ip:-<IP>}${N}"
  echo
  divider
  echo
}

# ── Hlavný tok ────────────────────────────────────────
main() {
  header

  if [[ $EUID -ne 0 ]]; then
    err "Spusti ako root: sudo bash install.sh"
    exit 1
  fi

  echo -e "  ${D}Nainštaluje Claude Code ako osobnú AI asistentku${N}"
  echo -e "  ${D}s Telegram prístupom. Beží ako user '${CLAUDE_USER}'.${N}"
  echo
  ask "Pokračovať? [y/n]:"
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Zrušené."; exit 0; }

  log "=== Inštalácia v${VERSION} ==="

  detect_environment
  check_internet
  install_deps
  create_claude_user
  install_node
  install_bun
  install_claude_code
  install_gws
  setup_claude_auth
  setup_google_auth
  setup_telegram
  download_files
  generate_claude_md
  setup_claude_settings
  finalize
  setup_autostart
  first_start

  log "=== Inštalácia dokončená ==="
  print_summary
}

main "$@"
