#!/usr/bin/env bash
# net_mount_v01.sh - initial interactive scaffold for the SMB mount helper
# Minimal: welcome screen, a few test options, exit.
set -Eeuo pipefail
IFS=$'\n\t'

MENU_TOOL="none"

pick_menu_tool() {
  if command -v whiptail >/dev/null 2>&1; then
    MENU_TOOL="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    MENU_TOOL="dialog"
  else
    MENU_TOOL="none"
  fi
}

msgbox() {
  local txt="$1"
  if [[ "$MENU_TOOL" == "whiptail" ]]; then
    whiptail --msgbox "$txt" 10 70
  elif [[ "$MENU_TOOL" == "dialog" ]]; then
    dialog --msgbox "$txt" 10 70
  else
    echo -e "$txt"
  fi
}

menu() {
  # title height width [tag desc]...
  local title="$1"; shift
  local h="$1"; local w="$2"; shift 2
  if [[ "$MENU_TOOL" == "whiptail" ]]; then
    whiptail --clear --title "$title" --menu "$title" "$h" "$w" 10 "$@" 3>&1 1>&2 2>&3
  elif [[ "$MENU_TOOL" == "dialog" ]]; then
    dialog --clear --title "$title" --menu "$title" "$h" "$w" 10 "$@" 3>&1 1>&2 2>&3
  else
    # fallback: simple numbered menu
    echo "=== $title ==="
    local i=1
    local args=("$@")
    for ((idx=0; idx<${#args[@]}; idx+=2)); do
      printf "%3d) %s - %s\n" "$i" "${args[idx]}" "${args[idx+1]}"
      i=$((i+1))
    done
    printf "\nChoose number: "
    read -r choice
    echo "$choice"
  fi
}

input_box() {
  local prompt="$1"; local default="${2:-}"
  if [[ "$MENU_TOOL" == "whiptail" ]]; then
    whiptail --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3
  elif [[ "$MENU_TOOL" == "dialog" ]]; then
    dialog --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3
  else
    read -rp "$prompt [$default]: " val
    echo "${val:-$default}"
  fi
}

# ====== small utility tests ======
test_ping() {
  local host="${1:-8.8.8.8}"
  echo "Pinging $host (4 ICMP packets)..."
  ping -c 4 -W 2 "$host" 2>&1 | sed -n '1,200p'
}

test_deps() {
  local need=(nmap smbclient cifs-utils)
  printf "Checking for commands:\n"
  for p in "${need[@]}"; do
    if command -v "$p" >/dev/null 2>&1; then
      printf "  %-12s : OK\n" "$p"
    else
      printf "  %-12s : MISSING\n" "$p"
    fi
  done
}

detect_network_range() {
  local iface ip
  iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
  if [[ -n "$iface" ]]; then
    ip=$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | head -n1 || true)
  fi
  if [[ -z "${ip:-}" ]]; then
    ip=$(ip -4 -o addr show scope global | awk '{print $4; exit}' || true)
  fi
  echo "${ip:-(not-detected)}"
}

show_welcome() {
  cat <<EOF

==========================================
   SMB auto-mount helper - v0.1 (starter)
==========================================

This is a small interactive test harness.
It will:
 - show this welcome screen
 - offer a few test commands (ping, deps, detect network)
 - let you exit cleanly

Notes:
 - This script is intentionally non-destructive.
 - When ready, we'll add scanning, SMB queries, and fstab changes.

EOF
  if [[ "$MENU_TOOL" == "whiptail" || "$MENU_TOOL" == "dialog" ]]; then
    whiptail --msgbox "SMB auto-mount helper - v0.1\n\nThis is a test harness. Use the menu to run simple tests.\n\nPress OK to continue." 12 70
  fi
}

main_menu() {
  while true; do
    local choice
    # tag/description pairs; the fallback menu() function maps them to numbers
    choice=$(menu "Main menu" 20 70 \
      P "Ping test (connectivity)" \
      D "Check required commands (nmap, smbclient, cifs-utils)" \
      N "Detect network CIDR/address" \
      X "Exit script")
    # handle both numeric fallback and tags
    case "${choice}" in
      P|1)  # ping
        host=$(input_box "Enter host to ping (default 8.8.8.8):" "8.8.8.8")
        test_ping "$host"
        echo; read -rp "Press Enter to continue..." _ ;;
      D|2)
        test_deps
        echo; read -rp "Press Enter to continue..." _ ;;
      N|3)
        echo "Detected network: $(detect_network_range)"
        echo; read -rp "Press Enter to continue..." _ ;;
      X|4|"" )
        echo "Exiting. Goodbye."
        break ;;
      *)
        echo "Invalid choice: $choice"; sleep 1 ;;
    esac
  done
}

# ===== start =====
pick_menu_tool
show_welcome
main_menu
