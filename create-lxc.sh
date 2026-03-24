#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
#  Claude Assistant — LXC Creator
#  Spúšťa sa na Proxmox VE HOST node
#  Vytvorí a nakonfiguruje LXC kontajner pre asistentku
# ─────────────────────────────────────────────────────────

VERSION="1.0.0"
INSTALL_URL="https://raw.githubusercontent.com/pCilip/helper-scripts/main/install.sh"

# ── Farby ──────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'
D='\033[2m'; N='\033[0m'; BOLD='\033[1m'

# ── UI helpery ────────────────────────────────────────
header() {
  clear
  echo -e "${C}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║     Claude Assistant — LXC Creator v${VERSION}      ║"
  echo "  ║        Spúšťaj na Proxmox VE HOST node           ║"
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

# ── Kontrola PVE host ─────────────────────────────────
check_pve_host() {
  if ! command -v pct &>/dev/null; then
    err "Tento skript musí bežať na Proxmox VE HOST node."
    err "Nie je to LXC kontajner ani bežný server."
    echo
    info "Ak chceš nainštalovať asistentku do existujúceho kontajnera,"
    info "spusti priamo vo vnútri kontajnera:"
    info "  bash <(curl -s ${INSTALL_URL})"
    exit 1
  fi

  if ! command -v pvesh &>/dev/null; then
    err "pvesh nenájdený — nie je to PVE host?"
    exit 1
  fi

  ok "Proxmox VE host detekovaný"
  local pve_ver
  pve_ver=$(pveversion 2>/dev/null | head -1 || echo "neznáma")
  ok "Verzia: $pve_ver"
}

# ── Zber konfigurácie od užívateľa ─────────────────────
collect_config() {
  step "Konfigurácia LXC kontajnera"
  divider
  echo

  # CT ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  ask "CT ID [$next_id]:"
  read -r CT_ID
  CT_ID="${CT_ID:-$next_id}"

  # Hostname
  ask "Hostname [claude-assistant]:"
  read -r CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-claude-assistant}"

  # RAM
  echo
  echo -e "  ${W}RAM:${N}"
  echo -e "  ${G}1)${N} 512 MB ${D}(minimálne — bez Google Workspace)${N}"
  echo -e "  ${G}2)${N} 1024 MB ${D}(odporúčané)${N}"
  echo -e "  ${G}3)${N} 2048 MB ${D}(ak plánuješ browser/Playwright)${N}"
  ask "Vyber [1/2/3] alebo zadaj MB:"
  read -r ram_choice
  case "${ram_choice:-2}" in
    1) CT_RAM=512 ;;
    2) CT_RAM=1024 ;;
    3) CT_RAM=2048 ;;
    *) CT_RAM="${ram_choice:-1024}" ;;
  esac
  ok "RAM: ${CT_RAM} MB"

  # Disk
  ask "Veľkosť disku v GB [8]:"
  read -r CT_DISK
  CT_DISK="${CT_DISK:-8}"

  # Storage
  echo
  echo -e "  ${W}Dostupné storage pooly:${N}"
  pvesm status 2>/dev/null | awk 'NR>1 {printf "  %s  %s  %s\n", $1, $2, $7}' || true
  echo
  ask "Storage pool [local-lvm]:"
  read -r CT_STORAGE
  CT_STORAGE="${CT_STORAGE:-local-lvm}"

  # Sieť
  echo
  echo -e "  ${W}Sieť:${N}"
  echo -e "  ${G}1)${N} DHCP ${D}(automatická IP)${N}"
  echo -e "  ${G}2)${N} Statická IP"
  ask "Vyber [1/2]:"
  read -r net_choice

  if [[ "${net_choice:-1}" == "2" ]]; then
    ask "IP adresa (napr. 192.168.1.50/24):"
    read -r CT_IP
    ask "Gateway (napr. 192.168.1.1):"
    read -r CT_GW
    CT_NET="ip=${CT_IP},gw=${CT_GW}"
  else
    CT_NET="ip=dhcp"
  fi

  # Bridge
  ask "Network bridge [vmbr0]:"
  read -r CT_BRIDGE
  CT_BRIDGE="${CT_BRIDGE:-vmbr0}"

  # Password
  echo
  echo -e "  ${W}Root heslo pre kontajner:${N}"
  local pw1 pw2
  while true; do
    echo -ne "  ${W}Heslo:${N} "; read -rs pw1; echo
    echo -ne "  ${W}Znovu:${N} "; read -rs pw2; echo
    if [[ "$pw1" == "$pw2" ]] && [[ ${#pw1} -ge 8 ]]; then
      CT_PASSWORD="$pw1"
      ok "Heslo nastavené"
      break
    elif [[ "$pw1" != "$pw2" ]]; then
      warn "Heslá sa nezhodujú, skús znova."
    else
      warn "Heslo musí mať aspoň 8 znakov."
    fi
  done

  # Nesting — pre systemd v LXC
  echo
  ask "Povoliť nesting (odporúčané — umožní systemd)? [y/n] [y]:"
  read -r nest_choice
  if [[ "${nest_choice:-y}" =~ ^[Nn]$ ]]; then
    CT_NESTING=0
  else
    CT_NESTING=1
  fi

  # Zhrnutie
  echo
  step "Zhrnutie konfigurácie"
  divider
  echo
  echo -e "  CT ID:       ${W}$CT_ID${N}"
  echo -e "  Hostname:    ${W}$CT_HOSTNAME${N}"
  echo -e "  RAM:         ${W}${CT_RAM} MB${N}"
  echo -e "  Disk:        ${W}${CT_DISK} GB${N}"
  echo -e "  Storage:     ${W}$CT_STORAGE${N}"
  echo -e "  Sieť:        ${W}$CT_NET${N}"
  echo -e "  Bridge:      ${W}$CT_BRIDGE${N}"
  echo -e "  Nesting:     ${W}$( [[ $CT_NESTING -eq 1 ]] && echo 'áno' || echo 'nie' )${N}"
  echo
  ask "Pokračovať s vytvorením kontajnera? [y/n]:"
  read -r final_confirm
  [[ "$final_confirm" =~ ^[Yy]$ ]] || { echo "Zrušené."; exit 0; }
}

# ── Stiahnutie template ────────────────────────────────
download_template() {
  step "LXC template"

  # Vyber template — preferujeme debian-12
  local template=""
  local storage_path

  # Nájdi kde sú uložené templates
  storage_path=$(pvesm path "$CT_STORAGE" 2>/dev/null || echo "/var/lib/vz")

  # Skontroluj existujúce templates
  echo
  echo -e "  ${D}Dostupné templates:${N}"
  pveam list "$CT_STORAGE" 2>/dev/null | grep -E 'debian|ubuntu' | head -6 || \
    info "(žiadne lokálne — stiahnem)"

  echo
  echo -e "  ${W}Vyber template:${N}"
  echo -e "  ${G}1)${N} Debian 12 ${D}(odporúčané — stabilné, malé)${N}"
  echo -e "  ${G}2)${N} Ubuntu 24.04 LTS"
  echo -e "  ${G}3)${N} Ubuntu 22.04 LTS"
  ask "Vyber [1/2/3]:"
  read -r tmpl_choice

  case "${tmpl_choice:-1}" in
    2) TMPL_NAME="ubuntu-24.04-standard" ;;
    3) TMPL_NAME="ubuntu-22.04-standard" ;;
    *) TMPL_NAME="debian-12-standard" ;;
  esac

  # Nájdi presný názov súboru template
  local full_tmpl
  full_tmpl=$(pveam available --section system 2>/dev/null | \
    grep "$TMPL_NAME" | head -1 | awk '{print $2}') || true

  if [[ -z "$full_tmpl" ]]; then
    # Fallback — skús všetky
    pveam update >> /tmp/claude-lxc-create.log 2>&1 || true
    full_tmpl=$(pveam available --section system 2>/dev/null | \
      grep "$TMPL_NAME" | head -1 | awk '{print $2}') || true
  fi

  if [[ -z "$full_tmpl" ]]; then
    err "Template '$TMPL_NAME' nenájdený."
    info "Dostupné templates:"
    pveam available --section system 2>/dev/null | grep -E 'debian|ubuntu' | head -10
    ask "Zadaj meno template manuálne:"
    read -r full_tmpl
  fi

  CT_TEMPLATE="$full_tmpl"

  # Skontroluj či je template už stiahnutý
  local tmpl_file
  tmpl_file=$(pveam list "$CT_STORAGE" 2>/dev/null | grep "${CT_TEMPLATE%%_*}" | awk '{print $1}' | head -1) || true

  if [[ -n "$tmpl_file" ]]; then
    ok "Template už existuje: $tmpl_file"
    CT_TEMPLATE_PATH="${CT_STORAGE}:vztmpl/${CT_TEMPLATE}"
  else
    info "Sťahujem $CT_TEMPLATE ..."
    if pveam download "$CT_STORAGE" "$CT_TEMPLATE" >> /tmp/claude-lxc-create.log 2>&1; then
      :
    else
      err "Stiahnutie template zlyhalo (exit code: $?)."
      err "Pozri log: /tmp/claude-lxc-create.log"
      tail -5 /tmp/claude-lxc-create.log 2>/dev/null || true
      exit 1
    fi
    CT_TEMPLATE_PATH="${CT_STORAGE}:vztmpl/${CT_TEMPLATE}"
    ok "Template stiahnutý"
  fi
}

# ── Vytvorenie LXC ────────────────────────────────────
create_container() {
  step "Vytváram LXC kontajner CT${CT_ID}"

  # Zostav pct create príkaz
  local pct_args=(
    "$CT_ID"
    "$CT_TEMPLATE_PATH"
    --hostname   "$CT_HOSTNAME"
    --memory     "$CT_RAM"
    --swap       "512"
    --rootfs     "${CT_STORAGE}:${CT_DISK}"
    --net0       "name=eth0,bridge=${CT_BRIDGE},${CT_NET},firewall=1"
    --ostype     "debian"
    --password   "$CT_PASSWORD"
    --unprivileged 1
    --features   "nesting=${CT_NESTING}"
    --onboot     1
    --start      0
  )

  # Pridaj DNS
  pct_args+=(--nameserver "1.1.1.1" --searchdomain "local")

  echo -ne "  ${D}Vytvárám kontajner...${N}"
  if pct create "${pct_args[@]}" >> /tmp/claude-lxc-create.log 2>&1; then
    echo -e " ${G}hotovo${N}"
    ok "Kontajner CT${CT_ID} vytvorený"
  else
    echo
    err "Vytvorenie kontajnera zlyhalo."
    info "Log: cat /tmp/claude-lxc-create.log"
    cat /tmp/claude-lxc-create.log | tail -20
    exit 1
  fi
}

# ── Konfigurácia kontajnera ────────────────────────────
configure_container() {
  step "Konfigurácia kontajnera"

  # Extra LXC options pre lepšiu kompatibilitu
  local conf_file="/etc/pve/lxc/${CT_ID}.conf"

  # Pridaj lxc options pre nesting a tty
  if [[ $CT_NESTING -eq 1 ]]; then
    cat >> "$conf_file" << EOF

# Claude Assistant optimizations
lxc.apparmor.profile: unconfined
lxc.cap.drop:
EOF
    ok "AppArmor unconfined (potrebné pre Node.js + Bun)"
  fi

  ok "Konfigurácia uložená: $conf_file"
}

# ── Štart a základné nastavenie ────────────────────────
start_and_prepare() {
  step "Štart kontajnera CT${CT_ID}"

  echo -ne "  ${D}Spúšťam...${N}"
  pct start "$CT_ID" >> /tmp/claude-lxc-create.log 2>&1
  echo -e " ${G}hotovo${N}"

  # Počkaj na sieť
  echo -ne "  ${D}Čakám na sieť...${N}"
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    if pct exec "$CT_ID" -- ping -c1 -W1 1.1.1.1 &>/dev/null 2>&1; then
      echo -e " ${G}OK${N}"
      break
    fi
    sleep 2
    ((attempts++))
  done

  if [[ $attempts -ge 30 ]]; then
    warn "Sieť nie je dostupná po 60s — skontroluj manuálne."
    warn "pct exec $CT_ID -- ip addr"
  else
    ok "Sieť funguje"
  fi

  # Základné balíčky
  echo -ne "  ${D}Aktualizácia balíčkov...${N}"
  pct exec "$CT_ID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl git tmux sudo ca-certificates
  " >> /tmp/claude-lxc-create.log 2>&1
  echo -e " ${G}hotovo${N}"
  ok "Základné balíčky nainštalované"
}

# ── Spustenie install.sh vo vnútri ────────────────────
run_installer() {
  step "Spúšťam inštalátor asistentky vo vnútri CT${CT_ID}"
  divider
  echo

  echo -e "  ${W}Možnosti:${N}"
  echo
  echo -e "  ${G}1)${N} Spustiť inštalátor teraz ${D}(interaktívne cez pct exec)${N}"
  echo -e "  ${G}2)${N} Len pripraviť — spustím manuálne neskôr"
  echo
  ask "Vyber [1/2]:"
  read -r install_choice

  if [[ "${install_choice:-1}" == "1" ]]; then
    echo
    info "Pripájam sa do kontajnera CT${CT_ID}..."
    info "Inštalátor sa spustí interaktívne."
    divider
    echo

    # Stiahni install.sh do kontajnera
    if pct exec "$CT_ID" -- curl -fsSL "$INSTALL_URL" -o /root/install.sh 2>/dev/null; then
      pct exec "$CT_ID" -- chmod +x /root/install.sh
      ok "install.sh stiahnutý"
    else
      warn "Nepodarilo sa stiahnuť z URL — kopírujem lokálne"
      # Fallback — skúsime skopírovať lokálny súbor ak existuje
      local local_install
      local_install="$(dirname "$0")/install.sh"
      if [[ -f "$local_install" ]]; then
        pct push "$CT_ID" "$local_install" /root/install.sh
        pct exec "$CT_ID" -- chmod +x /root/install.sh
        ok "install.sh skopírovaný lokálne"
      else
        err "install.sh nenájdený. Skopíruj ho manuálne."
        print_manual_steps
        exit 1
      fi
    fi

    echo
    echo -e "  ${Y}Spúšťam interaktívny inštalátor v CT${CT_ID}...${N}"
    echo -e "  ${D}(Klávesa Ctrl+C ťa vráti na PVE host)${N}"
    echo
    sleep 2

    # Spusti interaktívne
    pct exec "$CT_ID" -- bash /root/install.sh

  else
    print_manual_steps
  fi
}

print_manual_steps() {
  step "Manuálny postup"
  divider
  echo
  echo -e "  ${W}Kontajner CT${CT_ID} je pripravený. Ďalšie kroky:${N}"
  echo
  echo -e "  ${G}1.${N} Pripojiť sa:"
  echo -e "     ${C}pct enter ${CT_ID}${N}"
  echo -e "     ${C}# alebo: ssh root@<IP_KONTAJNERA>${N}"
  echo
  echo -e "  ${G}2.${N} Spustiť inštalátor asistentky:"
  echo -e "     ${C}bash <(curl -fsSL ${INSTALL_URL})${N}"
  echo
  echo -e "  ${G}3.${N} Alebo ak máš install.sh lokálne:"
  echo -e "     ${C}pct push ${CT_ID} ./install.sh /root/install.sh${N}"
  echo -e "     ${C}pct exec ${CT_ID} -- bash /root/install.sh${N}"
  echo
}

# ── Zistenie IP kontajnera ────────────────────────────
get_container_ip() {
  local ip
  ip=$(pct exec "$CT_ID" -- ip -4 addr show eth0 2>/dev/null | \
    grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "")
  echo "$ip"
}

# ── Záverečný súhrn ───────────────────────────────────
print_summary() {
  header

  local ct_ip
  ct_ip=$(get_container_ip)

  echo -e "  ${G}${BOLD}✓ LXC kontajner CT${CT_ID} je pripravený!${N}"
  echo
  divider
  echo
  echo -e "  CT ID:       ${W}${CT_ID}${N}"
  echo -e "  Hostname:    ${W}${CT_HOSTNAME}${N}"
  echo -e "  IP adresa:   ${W}${ct_ip:-zisti cez: pct exec ${CT_ID} -- ip addr}${N}"
  echo -e "  RAM:         ${W}${CT_RAM} MB${N}"
  echo -e "  Nesting:     ${W}$( [[ $CT_NESTING -eq 1 ]] && echo 'áno (systemd funguje)' || echo 'nie (tmux+cron)' )${N}"
  echo
  divider
  echo
  echo -e "  ${W}Užitočné príkazy:${N}"
  echo
  echo -e "  ${D}Vstup do kontajnera:${N}  ${C}pct enter ${CT_ID}${N}"
  echo -e "  ${D}Štart/stop:${N}           ${C}pct start ${CT_ID} / pct stop ${CT_ID}${N}"
  echo -e "  ${D}Konzola:${N}              ${C}pct console ${CT_ID}${N}"
  echo -e "  ${D}Log inštalácie:${N}       ${C}cat /tmp/claude-lxc-create.log${N}"
  echo -e "  ${D}SSH (ak máš IP):${N}      ${C}ssh root@${ct_ip:-<IP>}${N}"
  echo
  divider
  echo
}

# ── Hlavný tok ────────────────────────────────────────
main() {
  header

  echo -e "  ${D}Tento skript vytvorí LXC kontajner na Proxmox VE${N}"
  echo -e "  ${D}a v ňom nainštaluje Claude AI asistentku.${N}"
  echo
  echo -e "  ${Y}Spúšťaj VÝHRADNE na Proxmox VE HOST node, nie v kontajneri!${N}"
  echo

  check_pve_host
  collect_config
  download_template
  create_container
  configure_container
  start_and_prepare
  run_installer

  print_summary
}

main "$@"
