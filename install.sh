#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
#  Claude Assistant Installer
#  Inštalátor osobnej AI asistentky na báze Claude Code
#  Štýl: PVE Community Scripts
# ─────────────────────────────────────────────────────────

VERSION="1.0.0"
WORKSPACE="$HOME/.claude-assistant"
LOG="$WORKSPACE/install.log"
CLAUDE_MD="$WORKSPACE/CLAUDE.md"
ENV_FILE="$WORKSPACE/.env"
STARTUP_SCRIPT="$WORKSPACE/start.sh"
SERVICE_FILE="/etc/systemd/system/claude-assistant.service"

# Detekcia prostredia — nastavené v detect_environment()
IS_LXC=false
HAS_SYSTEMD=false
HAS_NESTING=false

# ── Farby ──────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'
D='\033[2m'; N='\033[0m'; BOLD='\033[1m'

# ── UI helpery ────────────────────────────────────────
header() {
  clear
  echo -e "${C}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║        Claude Assistant Installer v${VERSION}        ║"
  echo "  ║   Osobná AI asistentka — email, faktúry, Telegram ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${N}"
}

step() {
  echo -e "\n${B}${BOLD}▶ $1${N}"
}

ok() {
  echo -e "  ${G}✓${N} $1"
}

warn() {
  echo -e "  ${Y}⚠${N}  $1"
}

err() {
  echo -e "  ${R}✗${N} $1" >&2
}

info() {
  echo -e "  ${D}$1${N}"
}

ask() {
  echo -ne "\n  ${W}$1${N} "
}

ask_secret() {
  echo -ne "\n  ${W}$1${N} "
  read -rs REPLY
  echo
  echo "$REPLY"
}

divider() {
  echo -e "  ${D}──────────────────────────────────────────────────${N}"
}

progress() {
  local msg="$1"
  echo -ne "  ${D}${msg}...${N}"
}

done_progress() {
  echo -e " ${G}hotovo${N}"
}

pause() {
  echo -e "\n  ${D}Stlač Enter pre pokračovanie...${N}"
  read -r
}

require_root_or_sudo() {
  if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    warn "Niektoré kroky vyžadujú sudo prístup."
    info "Budeš vyzvaný na heslo kde je to potrebné."
  fi
}

log() {
  mkdir -p "$WORKSPACE"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# ── Kontroly prerekvizít ───────────────────────────────
# ── Detekcia prostredia ───────────────────────────────
detect_environment() {
  step "Detekcia prostredia"

  # LXC detekcia — viacero metód pre istotu
  local is_lxc_detected=false
  grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && is_lxc_detected=true
  [[ "$is_lxc_detected" == false ]] && grep -qa 'lxc' /proc/self/cgroup 2>/dev/null && is_lxc_detected=true
  [[ "$is_lxc_detected" == false ]] && [[ -f /run/systemd/container ]] && grep -qa 'lxc' /run/systemd/container 2>/dev/null && is_lxc_detected=true
  [[ "$is_lxc_detected" == false ]] && systemd-detect-virt --container 2>/dev/null | grep -q lxc && is_lxc_detected=true
  if [[ "$is_lxc_detected" == true ]]; then
    IS_LXC=true
  fi

  # Systemd funkčnosť
  if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
    HAS_SYSTEMD=true
  elif command -v systemctl &>/dev/null && \
       systemctl list-units --type=service &>/dev/null 2>&1; then
    HAS_SYSTEMD=true
  fi

  # Nesting check — v LXC s nesting=1 funguje /sys/fs/cgroup normálne
  if [[ "$IS_LXC" == true ]]; then
    if [[ -w /sys/fs/cgroup ]] && [[ "$HAS_SYSTEMD" == true ]]; then
      HAS_NESTING=true
    fi
  fi

  # Výstup
  if [[ "$IS_LXC" == true ]]; then
    ok "Prostredie: Proxmox LXC kontajner"
    if [[ "$HAS_SYSTEMD" == true ]]; then
      ok "systemd: funkčný (nesting povolený)"
      HAS_NESTING=true
    else
      warn "systemd: nefunkčný — použijem tmux + cron"
      info "Pre systemd support: v Proxmox → kontajner → Options → Features → Nesting ✓"
    fi
  else
    ok "Prostredie: štandardný VPS / VM"
    if [[ "$HAS_SYSTEMD" == true ]]; then
      ok "systemd: dostupný"
    else
      warn "systemd: nedostupný — použijem tmux"
    fi
  fi

  log "IS_LXC=$IS_LXC HAS_SYSTEMD=$HAS_SYSTEMD HAS_NESTING=$HAS_NESTING"
}

check_os() {
  step "Kontrola operačného systému"
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ok "Detekovaný: $PRETTY_NAME"
    case "$ID" in
      ubuntu|debian|linuxmint) ok "Podporovaná distribúcia" ;;
      *)
        warn "Netestovaná distribúcia: $ID"
        info "Pokračujem, ale niektoré kroky môžu zlyhať."
        ;;
    esac
  else
    warn "Nepodarilo sa zistiť OS. Pokračujem..."
  fi
  log "OS: ${PRETTY_NAME:-neznámy}"
}

check_internet() {
  step "Kontrola internetového pripojenia"
  if curl -s --max-time 5 https://api.anthropic.com > /dev/null 2>&1; then
    ok "Pripojenie na Anthropic API: OK"
  else
    err "Žiadne internetové pripojenie alebo Anthropic API nedostupné."
    echo -e "\n  ${R}Inštalácia vyžaduje internet. Skontroluj pripojenie.${N}"
    exit 1
  fi
}

# ── Inštalácia závislostí ─────────────────────────────
install_deps() {
  step "Inštalácia systémových závislostí"

  progress "Aktualizácia balíčkov"
  sudo apt-get update -qq >> "$LOG" 2>&1
  done_progress

  for pkg in curl git tmux unzip jq; do
    if command -v "$pkg" &>/dev/null; then
      ok "$pkg — už nainštalovaný"
    else
      progress "Inštalácia $pkg"
      sudo apt-get install -y -qq "$pkg" >> "$LOG" 2>&1
      done_progress
      ok "$pkg nainštalovaný"
    fi
  done
}

install_node() {
  step "Node.js 20+"

  if command -v node &>/dev/null; then
    local ver
    ver=$(node --version)
    local major=${ver#v}; major=${major%%.*}
    if [[ $major -ge 20 ]]; then
      ok "Node.js $ver — vyhovuje"
      return
    else
      warn "Node.js $ver — príliš stará verzia, inštalujem 20.x"
    fi
  fi

  progress "Sťahovanie NodeSource repozitára"
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >> "$LOG" 2>&1
  done_progress

  progress "Inštalácia Node.js 20"
  sudo apt-get install -y -qq nodejs >> "$LOG" 2>&1
  done_progress

  ok "Node.js $(node --version) nainštalovaný"
}

install_bun() {
  step "Bun runtime (vyžaduje Claude Code Channels)"

  if command -v bun &>/dev/null; then
    ok "Bun $(bun --version) — už nainštalovaný"
    return
  fi

  progress "Inštalácia Bun"
  curl -fsSL https://bun.sh/install | bash >> "$LOG" 2>&1

  # Pridaj do PATH pre aktuálnu session
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"

  if command -v bun &>/dev/null; then
    ok "Bun $(bun --version) nainštalovaný"
  else
    warn "Bun sa nenašiel v PATH. Restartuj terminál ak treba."
  fi

  # Pridaj do .bashrc ak tam ešte nie je
  if ! grep -q 'BUN_INSTALL' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# Bun'
      echo 'export BUN_INSTALL="$HOME/.bun"'
      echo 'export PATH="$BUN_INSTALL/bin:$PATH"'
    } >> "$HOME/.bashrc"
  fi
}

install_claude_code() {
  step "Claude Code"

  if command -v claude &>/dev/null; then
    local ver
    ver=$(claude --version 2>/dev/null || echo "neznáma")
    ok "Claude Code $ver — už nainštalovaný"
  else
    progress "Inštalácia Claude Code (npm global)"
    npm install -g @anthropic-ai/claude-code >> "$LOG" 2>&1
    done_progress
    ok "Claude Code $(claude --version 2>/dev/null || echo 'nainštalovaný')"
  fi
}

install_gws() {
  step "Google Workspace CLI (gws)"
  info "Umožní čítanie Gmailu a Kalendára cez MCP"

  if command -v gws &>/dev/null; then
    ok "gws — už nainštalovaný"
    return
  fi

  progress "Inštalácia @googleworkspace/cli"
  npm install -g @googleworkspace/cli >> "$LOG" 2>&1
  done_progress
  ok "gws nainštalovaný"
}

# ── Claude Code autentifikácia ─────────────────────────
setup_claude_auth() {
  step "Claude Code autentifikácia"
  divider

  # Skontroluj či už je autentifikovaný
  if claude --version &>/dev/null && \
     [[ -f "$HOME/.claude.json" ]] && \
     grep -q '"accessToken"' "$HOME/.claude.json" 2>/dev/null; then
    ok "Claude Code je už autentifikovaný"
    return
  fi

  echo
  echo -e "  ${W}Metóda autentifikácie:${N}"
  echo -e "  ${G}1)${N} OAuth (claude.ai Pro/Max) — odporúčané"
  echo -e "  ${G}2)${N} API kľúč (ANTHROPIC_API_KEY)"
  echo
  ask "Vyber možnosť [1/2]:"
  read -r auth_choice

  case "${auth_choice:-1}" in
    1)
      echo
      echo -e "  ${Y}Headless OAuth postup:${N}"
      divider
      info "1. Na tomto VPS spusti:  claude"
      info "2. Zobrazí sa URL — skopíruj ju"
      info "3. Otvor URL v prehliadači (mobil / iný PC)"
      info "4. Prihlás sa na claude.ai"
      info "5. Sem zadaj OAuth token ktorý dostaneš"
      divider
      echo
      echo -e "  ${D}Alebo ak máš prístup k prehliadaču na tomto stroji,${N}"
      echo -e "  ${D}jednoducho spusti: ${W}claude${D} a postupuj podľa inštrukcií.${N}"
      echo
      ask "Stlač Enter keď si pripravený spustiť 'claude' pre autentifikáciu..."
      read -r

      echo
      warn "Spúšťam claude pre autentifikáciu. Po dokončení sa vráť sem."
      echo -e "  ${D}(Ak sa spýta na niečo, odpovedz a potom Ctrl+C pre návrat)${N}"
      echo
      # Spustí claude raz pre autentifikáciu
      claude --version || true
      echo
      ask "Je autentifikácia dokončená? [y/n]:"
      read -r done_auth
      if [[ "$done_auth" =~ ^[Yy]$ ]]; then
        ok "Claude Code autentifikovaný"
      else
        warn "Autentifikácia nedokončená — môžeš pokračovať a autentifikovať neskôr"
        warn "Spusti: claude"
      fi
      ;;
    2)
      echo
      local api_key
      api_key=$(ask_secret "Vlož ANTHROPIC_API_KEY:")
      if [[ -n "$api_key" ]]; then
        mkdir -p "$WORKSPACE"
        # Pridaj do .env
        grep -v 'ANTHROPIC_API_KEY' "$ENV_FILE" 2>/dev/null > /tmp/env_tmp || true
        echo "ANTHROPIC_API_KEY=$api_key" >> /tmp/env_tmp
        mv /tmp/env_tmp "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        export ANTHROPIC_API_KEY="$api_key"
        ok "API kľúč uložený do $ENV_FILE"
      fi
      ;;
  esac
}

# ── Google Workspace setup ─────────────────────────────
setup_google_workspace() {
  step "Google Workspace (Gmail + Kalendár)"
  divider

  echo
  echo -e "  ${W}Chceš nastaviť Gmail a Kalendár?${N}"
  echo -e "  ${D}(Umožní asistentke čítať maily, sledovať termíny)${N}"
  echo
  ask "Nastaviť Google Workspace? [y/n]:"
  read -r gws_choice

  if [[ ! "$gws_choice" =~ ^[Yy]$ ]]; then
    warn "Preskakujem — môžeš nastaviť neskôr cez: gws auth setup"
    return
  fi

  echo
  echo -e "  ${Y}Čo budeš potrebovať:${N}"
  divider
  info "1. Google Cloud Console projekt s povolenými Gmail + Calendar API"
  info "2. OAuth2 credentials (credentials.json)"
  info "   → console.cloud.google.com → APIs & Services → Credentials"
  info "   → Create OAuth Client → Desktop App → stiahnuť JSON"
  info "3. Seba ako Test User (External OAuth consent screen)"
  divider
  echo
  echo -e "  ${D}Viac info: https://docs.anthropic.com/gws-setup${N}"
  echo

  ask "Máš credentials.json? Zadaj cestu (Enter = preskočiť):"
  read -r creds_path

  if [[ -n "$creds_path" && -f "$creds_path" ]]; then
    mkdir -p "$WORKSPACE/gws"
    cp "$creds_path" "$WORKSPACE/gws/credentials.json"
    ok "credentials.json skopírovaný"

    echo
    info "Spúšťam Google OAuth flow..."
    info "Otvor URL ktorá sa zobrazí v prehliadači."
    echo

    export GOOGLE_OAUTH_CREDENTIALS="$WORKSPACE/gws/credentials.json"
    gws auth setup --credentials "$WORKSPACE/gws/credentials.json" || \
      warn "OAuth flow prerušený — dokonči neskôr cez: gws auth setup"

    # Pridaj MCP server do Claude Code
    progress "Registrácia gws MCP servera"
    claude mcp add --transport http gws-workspace http://localhost:3000 >> "$LOG" 2>&1 || \
      warn "MCP registrácia neskôr: claude mcp add gws-workspace ..."
    done_progress

    ok "Google Workspace nakonfigurovaný"
  else
    warn "Preskakujem Google Workspace — nastav neskôr"
    info "Spusti: gws auth setup"
  fi
}

# ── Telegram setup ────────────────────────────────────
setup_telegram() {
  step "Telegram bot"
  divider

  echo
  echo -e "  ${Y}Ako získaš Telegram bot token:${N}"
  divider
  info "1. Otvor Telegram → vyhľadaj @BotFather"
  info "2. Pošli: /newbot"
  info "3. Zadaj meno bota (napr. MojaAsistentka)"
  info "4. Zadaj username (musí končiť na 'bot', napr. moja_asistentka_bot)"
  info "5. BotFather ti pošle TOKEN — skopíruj ho"
  divider
  echo

  local tg_token
  tg_token=$(ask_secret "Vlož Telegram Bot Token (alebo Enter = preskočiť):")

  if [[ -z "$tg_token" ]]; then
    warn "Preskakujem Telegram — nastav neskôr"
    info "Spusti: /plugin install telegram@claude-plugins-official"
    info "Potom: /telegram:configure YOUR_TOKEN"
    return
  fi

  # Ulož token
  mkdir -p "$WORKSPACE"
  grep -v 'TELEGRAM_BOT_TOKEN' "$ENV_FILE" 2>/dev/null > /tmp/env_tmp || true
  echo "TELEGRAM_BOT_TOKEN=$tg_token" >> /tmp/env_tmp
  mv /tmp/env_tmp "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  ok "Token uložený"

  # Inštalácia pluginu
  progress "Inštalácia Telegram pluginu do Claude Code"
  # Plugin install je interaktívny, robíme to cez --print mode
  echo "/plugin install telegram@claude-plugins-official" | \
    claude --dangerously-skip-permissions -p "install telegram plugin" >> "$LOG" 2>&1 || true
  done_progress

  # Konfigurácia tokenu
  progress "Konfigurácia Telegram tokenu"
  echo "/telegram:configure $tg_token" | \
    claude --dangerously-skip-permissions -p "configure telegram" >> "$LOG" 2>&1 || true
  done_progress

  ok "Telegram plugin nakonfigurovaný"

  echo
  echo -e "  ${W}Párovanie:${N}"
  info "Keď spustíš asistentku, pošli správu svojmu botu v Telegrame."
  info "Bot ti pošle pairing kód — zadaj ho v termináli:"
  info "  /telegram:access pair KOD"
  info "Potom nastav allowlist:"
  info "  /telegram:access policy allowlist"
}

# ── CLAUDE.md generovanie ─────────────────────────────
generate_claude_md() {
  step "Konfigurácia asistentky (CLAUDE.md)"
  divider

  echo
  echo -e "  ${D}Pár otázok pre prispôsobenie asistentky:${N}"
  echo

  ask "Ako sa volá asistentka? (napr. Eva, Jana, AI):"
  read -r assistant_name
  assistant_name="${assistant_name:-Asistentka}"

  ask "Tvoje meno / ako sa má asistentka obracať na teba:"
  read -r user_name
  user_name="${user_name:-šéfe}"

  ask "Jazyk odpovedí [sk/en] (default: sk):"
  read -r lang
  lang="${lang:-sk}"

  echo
  echo -e "  ${W}Čo chceš aby asistentka robila? (viac možností, Enter = všetko)${N}"
  echo -e "  ${G}1)${N} Čítanie a triediaenie emailov"
  echo -e "  ${G}2)${N} Sledovanie faktúr a expirácií"
  echo -e "  ${G}3)${N} Kalendár a pripomienky"
  echo -e "  ${G}4)${N} Ranný brief"
  echo -e "  ${G}5)${N} Všetko vyššie"
  echo
  ask "Vyber [1-5] alebo viac čísel oddelených čiarkou:"
  read -r features_choice
  features_choice="${features_choice:-5}"

  mkdir -p "$WORKSPACE"

  cat > "$CLAUDE_MD" << HEREDOC
# ${assistant_name} — Osobná AI asistentka

Volám sa **${assistant_name}**. Som tvoja osobná asistentka.
Obracaj sa na mňa v ${lang} jazyku. Na teba sa obraciam: ${user_name}.

## Základné pravidlá

- Odpovedám vždy v **${lang}** jazyku
- Som stručná a vecná — žiadne zbytočné formality
- Dôverné informácie (heslá, tokeny) nikdy neposielam cez Telegram
- Pred každou akciou s nezvratným dopadom (platba, mazanie, odoslanie emailu) sa opýtam

## Štruktúra workspace

\`\`\`
${WORKSPACE}/
├── CLAUDE.md          ← tieto inštrukcie
├── .env               ← credentials (nikdy necommitovať)
├── expirations.md     ← faktúry a expirácie
├── notes.md           ← moje poznámky
└── inbox/             ← prijaté súbory z Telegramu
\`\`\`

## Expirácie a faktúry

Súbor \`${WORKSPACE}/expirations.md\` obsahuje tabuľku sledovaných termínov:

| Popis | Dátum splatnosti | Suma | Status | Poznámka |
|-------|-----------------|------|--------|----------|

### Automatické pravidlá
- Keď nájdeš v emaili faktúru → extrahuj dátum a sumu → pridaj do expirations.md
- **30 dní pred splatnosťou** → upozornenie cez Telegram
- **7 dní pred splatnosťou** → urgentné upozornenie
- **V deň splatnosti** → pripomenutie ráno

## Ranný brief (každý deň o 7:30)

Zostaví prehľad a pošle na Telegram:
1. Dôležité emaily (nie newslettery, nie reklamy)
2. Dnešné a zajtrajšie udalosti z Kalendára
3. Faktúry a expirácie splatné do 30 dní
4. Prípadné urgentné veci

Formát: krátky, štruktúrovaný, max 10 riadkov

## Email pravidlá

### Automaticky ignorujem:
- Newslettery, marketing, promo
- Notifikácie zo sociálnych sietí
- Automated CI/CD správy

### Vždy hlásim:
- Faktúry a platobné výzvy
- Zmluvy a dokumenty na podpis
- Správy od konkrétnych ľudí (nie boty)
- Urgentné veci so slovami: urgent, ASAP, dôležité, deadline

## Čo robím sama (bez pytania):
- Čítam emaily a Kalendár
- Pridávam záznamy do expirations.md
- Posielam ranný brief
- Odpovedám na otázky cez Telegram
- Sťahujem prijaté súbory do ${WORKSPACE}/inbox/

## Čo vždy konzultujem s tebou:
- Odoslanie akéhokoľvek emailu
- Platba alebo potvrdenie faktúry
- Mazanie súborov
- Akákoľvek akcia v mene teba voči tretím stranám

## Telegram príkazy

- \`brief\` alebo \`správa\` → okamžitý ranný brief
- \`faktúry\` alebo \`expirácie\` → zoznam splatných termínov
- \`email\` → zhrnutie nových emailov
- \`dnes\` → dnešný kalendár
- \`stav\` → stav systému (posledná aktivita, naplánované úlohy)
HEREDOC

  ok "CLAUDE.md vygenerovaný: $CLAUDE_MD"
}

# ── Startup script ─────────────────────────────────────
create_startup_script() {
  step "Startup script"

  mkdir -p "$WORKSPACE"

  cat > "$STARTUP_SCRIPT" << 'STARTUP'
#!/usr/bin/env bash
# Claude Assistant — štartovací skript

set -a
source "${HOME}/.claude-assistant/.env" 2>/dev/null || true
set +a

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

WORKSPACE="${HOME}/.claude-assistant"
LOG="${WORKSPACE}/agent.log"

mkdir -p "$WORKSPACE/inbox"

echo "[$(date)] Spúšťam Claude Assistant..." >> "$LOG"

# Spustenie gws MCP servera (Gmail + Calendar) ak je dostupný
if command -v gws &>/dev/null && [[ -f "${WORKSPACE}/gws/credentials.json" ]]; then
  export GOOGLE_OAUTH_CREDENTIALS="${WORKSPACE}/gws/credentials.json"
  gws mcp -s gmail,calendar,drive >> "${LOG}" 2>&1 &
  echo "[$(date)] gws MCP server spustený (PID $!)" >> "$LOG"
  sleep 2
fi

# Spustenie Claude Code s Telegram Channels
exec claude \
  --dangerously-skip-permissions \
  --channels plugin:telegram@claude-plugins-official \
  2>> "$LOG"
STARTUP

  chmod +x "$STARTUP_SCRIPT"
  ok "Startup script: $STARTUP_SCRIPT"
}

# ── Autostart — LXC-aware ─────────────────────────────
setup_autostart() {
  step "Autostart"
  divider

  if [[ "$IS_LXC" == true ]] && [[ "$HAS_SYSTEMD" == false ]]; then
    # LXC bez nesting — automaticky tmux + cron @reboot
    echo
    warn "LXC bez systemd — nastavujem tmux + cron @reboot"
    info "Asistentka sa spustí automaticky pri každom štarte kontajnera."
    echo
    setup_tmux_alias
    setup_cron_reboot
    return
  fi

  # Inak ponúkni výber
  echo
  echo -e "  ${W}Ako má asistentka bežať na pozadí?${N}"
  echo

  if [[ "$HAS_SYSTEMD" == true ]]; then
    echo -e "  ${G}1)${N} systemd service ${D}(beží aj po reštarte, odporúčané)${N}"
    echo -e "  ${G}2)${N} tmux + cron @reboot ${D}(odľahčená alternatíva)${N}"
    echo -e "  ${G}3)${N} Len startup skript — spustím manuálne"
  else
    echo -e "  ${G}1)${N} tmux + cron @reboot ${D}(automatický štart)${N}"
    echo -e "  ${G}2)${N} Len startup skript — spustím manuálne"
  fi

  echo
  ask "Vyber [1/2/3]:"
  read -r run_choice

  if [[ "$HAS_SYSTEMD" == true ]]; then
    case "${run_choice:-1}" in
      1) setup_systemd ;;
      2) setup_tmux_alias; setup_cron_reboot ;;
      3) ok "Skript: $STARTUP_SCRIPT"; info "Spusti: bash $STARTUP_SCRIPT" ;;
    esac
  else
    case "${run_choice:-1}" in
      1) setup_tmux_alias; setup_cron_reboot ;;
      2) ok "Skript: $STARTUP_SCRIPT"; info "Spusti: bash $STARTUP_SCRIPT" ;;
    esac
  fi
}

setup_systemd() {
  local current_user
  current_user=$(whoami)

  sudo tee "$SERVICE_FILE" > /dev/null << UNIT
[Unit]
Description=Claude Personal Assistant
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${current_user}
WorkingDirectory=${WORKSPACE}
EnvironmentFile=-${ENV_FILE}
ExecStart=${STARTUP_SCRIPT}
Restart=on-failure
RestartSec=30
StandardOutput=append:${WORKSPACE}/agent.log
StandardError=append:${WORKSPACE}/agent.log

[Install]
WantedBy=multi-user.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable claude-assistant.service >> "$LOG" 2>&1

  ok "systemd service vytvorený a povolený"
  info "Spusti:    sudo systemctl start claude-assistant"
  info "Status:    sudo systemctl status claude-assistant"
  info "Logy:      journalctl -u claude-assistant -f"
}

setup_tmux_alias() {
  # Pridaj alias do .bashrc
  if ! grep -q 'claude-assistant' "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" << 'BASHRC'

# Claude Assistant
alias assistant-start='tmux new-session -d -s claude-assistant "bash ~/.claude-assistant/start.sh" 2>/dev/null || echo "session uz bezi"'
alias assistant-attach='tmux attach -t claude-assistant'
alias assistant-stop='tmux kill-session -t claude-assistant'
alias assistant-log='tail -f ~/.claude-assistant/agent.log'
BASHRC
  fi

  ok "tmux aliasy pridané do ~/.bashrc"
  info "Spusti:   source ~/.bashrc && assistant-start"
  info "Pripojiť: assistant-attach"
  info "Stop:     assistant-stop"
}

setup_cron_reboot() {
  # @reboot cron — spustí asistentku pri štarte kontajnera
  local cron_line="@reboot sleep 10 && tmux new-session -d -s claude-assistant 'bash ${STARTUP_SCRIPT}' >> ${WORKSPACE}/cron.log 2>&1"

  # Pridaj len ak tam ešte nie je
  if ! (crontab -l 2>/dev/null || true) | grep -q 'claude-assistant'; then
    ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab -
    ok "cron @reboot nastavenoý — asistentka sa spustí automaticky pri štarte"
  else
    ok "cron @reboot — už existuje"
  fi

  info "Zobraziť crontab: crontab -l"
}

# ── Záverečné párovanie Telegramu ─────────────────────
telegram_pairing_guide() {
  step "Párovanie Telegram bota"
  divider

  echo
  echo -e "  ${W}Keď asistentka beží, urob toto:${N}"
  divider
  echo
  echo -e "  ${G}1.${N} Otvor Telegram → nájdi svojho bota (podľa username)"
  echo -e "  ${G}2.${N} Pošli mu akúkoľvek správu"
  echo -e "  ${G}3.${N} Bot odpovedá s pairing kódom (napr. ABC-123)"
  echo -e "  ${G}4.${N} V termináli (pripoj sa cez tmux/ssh) zadaj:"
  echo
  echo -e "     ${W}/telegram:access pair ABC-123${N}"
  echo -e "     ${W}/telegram:access policy allowlist${N}"
  echo
  echo -e "  ${G}5.${N} Hotovo! Pošli botovi: ${W}brief${N}"
  divider
}

# ── /loop ranný brief setup ────────────────────────────
setup_loop() {
  step "Automatické úlohy (/loop)"

  echo
  echo -e "  ${D}Po spustení asistentky zadaj tieto príkazy v Claude Code:${N}"
  echo

  local loop_cmds="$WORKSPACE/loop-commands.txt"
  cat > "$loop_cmds" << 'LOOPS'
# Vlož tieto príkazy do Claude Code po spustení:

/loop 1d o 7:30 urob ranný brief — skontroluj Gmail (nové dôležité emaily od včera), Kalendár (dnes a zajtra), expirations.md (splatné do 30 dní) — zhrň to a pošli na Telegram

/loop 1d o 18:00 skontroluj dnešné emaily — ak prišla faktúra alebo zmluva, extrahuj dátum splatnosti a sumu, pridaj do ~/.claude-assistant/expirations.md

/loop 7d každú nedeľu o 9:00 skontroluj všetky položky v expirations.md a zoš mi týždenný prehľad co expiruje nasledujúce 2 mesiace, pošli na Telegram
LOOPS

  ok "Loop príkazy uložené do: $loop_cmds"
  info "Skopíruj ich do Claude Code po prvom spustení."

  # Zobraz obsah
  echo
  echo -e "  ${D}────── Obsah $loop_cmds ──────${N}"
  cat "$loop_cmds" | sed 's/^/  /'
  echo
}

# ── Súhrn inštalácie ──────────────────────────────────
print_summary() {
  header

  echo -e "  ${G}${BOLD}✓ Inštalácia dokončená!${N}"
  echo
  divider
  echo
  echo -e "  ${W}Čo bolo nainštalované:${N}"
  command -v node &>/dev/null && ok "Node.js $(node --version)"
  command -v bun &>/dev/null && ok "Bun $(bun --version)"
  command -v claude &>/dev/null && ok "Claude Code $(claude --version 2>/dev/null)"
  command -v gws &>/dev/null && ok "Google Workspace CLI"
  [[ -f "$CLAUDE_MD" ]] && ok "CLAUDE.md — inštrukcie asistentky"
  [[ -f "$STARTUP_SCRIPT" ]] && ok "Startup script: $STARTUP_SCRIPT"
  [[ -f "$SERVICE_FILE" ]] && ok "systemd service: claude-assistant"
  echo
  divider
  echo
  echo -e "  ${W}Ďalšie kroky:${N}"
  echo
  echo -e "  ${G}1.${N} Spusti asistentku:"

  if [[ -f "$SERVICE_FILE" ]]; then
    echo -e "     ${C}sudo systemctl start claude-assistant${N}"
  else
    echo -e "     ${C}source ~/.bashrc && assistant-start${N}"
    echo -e "     ${C}# alebo: tmux new -s claude bash $STARTUP_SCRIPT${N}"
  fi

  echo
  echo -e "  ${G}2.${N} Páruj Telegram bota:"
  echo -e "     ${C}(pošli správu botu → zadaj pairing kód v termináli)${N}"
  echo
  echo -e "  ${G}3.${N} Nastav automatické úlohy v Claude Code:"
  echo -e "     ${C}cat $WORKSPACE/loop-commands.txt${N}"
  echo
  echo -e "  ${G}4.${N} Otestuj:"
  echo -e "     ${C}Pošli botovi: brief${N}"
  echo
  divider
  echo
  echo -e "  ${D}Log inštalácie: $LOG${N}"
  echo -e "  ${D}Workspace:      $WORKSPACE${N}"
  echo
}

# ── Hlavný tok ────────────────────────────────────────
main() {
  header
  require_root_or_sudo

  mkdir -p "$WORKSPACE"
  log "=== Začiatok inštalácie Claude Assistant v${VERSION} ==="

  echo -e "  ${D}Tento skript nainštaluje a nakonfiguruje Claude Code${N}"
  echo -e "  ${D}ako osobnú AI asistentku s Telegram prístupom.${N}"
  echo
  echo -e "  ${W}Čo bude nainštalované:${N}"
  echo -e "  ${D}• Node.js 20+, Bun, Claude Code, Google Workspace CLI${N}"
  echo -e "  ${D}• Telegram bot plugin pre Claude Code Channels${N}"
  echo -e "  ${D}• CLAUDE.md — konfigurácia asistentky${N}"
  echo -e "  ${D}• Autostart (systemd / tmux+cron podľa prostredia)${N}"
  echo
  ask "Pokračovať? [y/n]:"
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Zrušené."; exit 0; }

  detect_environment
  check_os
  check_internet
  install_deps
  install_node
  install_bun
  install_claude_code
  install_gws
  setup_claude_auth
  setup_google_workspace
  setup_telegram
  generate_claude_md
  create_startup_script
  setup_autostart
  setup_loop
  telegram_pairing_guide

  log "=== Inštalácia dokončená ==="
  print_summary
}

main "$@"
