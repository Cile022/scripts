#!/usr/bin/env bash
# smb-autocfg.sh
# Debian/Ubuntu helper to scan network for SMB servers, list shares, create credentials, mount and add fstab entries with systemd automount.
# Usage: sudo ./smb-autocfg.sh
set -Eeuo pipefail
IFS=$'\n\t'

LOGFILE="/var/log/smb-mount-script.log"
CREDFOLDER="/etc/samba"
MNTROOT="/mnt"
FSTAB="/etc/fstab"

# ===== helpers =====
log() {
  local ts; ts="$(date +'%F %T')"
  echo "[$ts] $*" | tee -a "$LOGFILE"
}

die() { echo "ERROR: $*" | tee -a "$LOGFILE" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must be run as root. Use sudo."
  fi
}

pick_menu_tool() {
  if command -v whiptail >/dev/null 2>&1; then MENU_TOOL="whiptail"
  elif command -v dialog >/dev/null 2>&1; then MENU_TOOL="dialog"
  else MENU_TOOL="none"; fi
}

menu() {
  # menu title height width [tag desc]...
  if [[ "$MENU_TOOL" == "whiptail" ]]; then
    whiptail --clear --title "$1" --menu "$1" "$2" "$3" 10 "${@:4}" 3>&1 1>&2 2>&3
  elif [[ "$MENU_TOOL" == "dialog" ]]; then
    dialog --clear --title "$1" --menu "$1" "$2" "$3" 10 "${@:4}" 3>&1 1>&2 2>&3
  else
    # simple fallback: print menu
    echo "=== $1 ==="
    local i=1
    local args=("$@")
    # skip first 3 args: title,h,w
    for ((idx=4; idx<${#args[@]}; idx+=2)); do
      printf "%3d) %s - %s\n" "$i" "${args[idx-1]}" "${args[idx]}"
      i=$((i+1))
    done
    read -rp "Choose number: " choice
    echo "$choice"
  fi
}

input_box() {
  local title="$1" prompt="$2" default="${3:-}"
  if [[ "$MENU_TOOL" == "whiptail" ]]; then
    whiptail --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3
  elif [[ "$MENU_TOOL" == "dialog" ]]; then
    dialog --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3
  else
    read -rp "$prompt [$default]: " val
    echo "${val:-$default}"
  fi
}

password_box() {
  local prompt="${1:-Enter password: }"
  if [[ "$MENU_TOOL" == "whiptail" ]]; then
    whiptail --passwordbox "$prompt" 10 70 3>&1 1>&2 2>&3
  elif [[ "$MENU_TOOL" == "dialog" ]]; then
    dialog --passwordbox "$prompt" 10 70 3>&1 1>&2 2>&3
  else
    read -rsp "$prompt" val; echo; echo "$val"
  fi
}

confirm() {
  local q="${1:-Are you sure?}"
  if [[ "$MENU_TOOL" == "whiptail" ]]; then
    whiptail --yesno "$q" 8 60
    return $?
  elif [[ "$MENU_TOOL" == "dialog" ]]; then
    dialog --yesno "$q" 8 60
    return $?
  else
    read -rp "$q [y/N]: " ans; [[ "${ans,,}" =~ ^y(es)?$ ]]
    return $?
  fi
}

ensure_deps() {
  local need=(nmap smbclient cifs-utils)
  local to_install=()
  for p in "${need[@]}"; do
    if ! command -v "$p" >/dev/null 2>&1; then
      to_install+=("$p")
    fi
  done
  if (( ${#to_install[@]} )); then
    log "Missing packages: ${to_install[*]}. Installing..."
    apt-get update -y >>"$LOGFILE" 2>&1
    apt-get install -y "${to_install[@]}" >>"$LOGFILE" 2>&1 || die "Failed to install packages: ${to_install[*]}"
    log "Installed packages."
  else
    log "All dependencies present."
  fi
}

detect_network_range() {
  # prefer default route's interface
  local iface ip cidr
  iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)
  if [[ -n "$iface" ]]; then
    ip=$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | head -n1 || true)
  fi
  if [[ -z "${ip:-}" ]]; then
    # fallback: first non-loopback
    ip=$(ip -4 -o addr show scope global | awk '{print $4; exit}' || true)
  fi
  if [[ -z "${ip:-}" ]]; then
    read -rp "Could not detect network range. Enter CIDR (e.g. 192.168.1.0/24): " ip
  else
    # confirm with user
    read -rp "Detected network range '$ip'. Press Enter to use or type another CIDR: " resp
    if [[ -n "$resp" ]]; then ip="$resp"; fi
  fi
  echo "$ip"
}

scan_for_smb_hosts() {
  local range="$1"
  log "Scanning $range for SMB hosts (this may take a while)..."
  # Use nmap to find hosts with port 445 open. -Pn to skip ping (faster in some networks).
  # Output grepable mode and parse IPs
  local nmap_out
  nmap_out=$(nmap -p 445 --open -T4 -Pn "$range" -oG - 2>>"$LOGFILE") || true
  # parse hosts lines
  local hosts=()
  while IFS= read -r l; do
    if [[ "$l" =~ Host:\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      hosts+=("${BASH_REMATCH[1]}")
    fi
  done <<<"$nmap_out"
  # dedupe
  mapfile -t hosts < <(printf "%s\n" "${hosts[@]}" | awk '!seen[$0]++')
  echo "${hosts[@]}"
}

choose_from_list() {
  # args: title, prompt, items... (items are simple strings)
  local title="$1"; shift
  local prompt="$1"; shift
  local items=("$@")
  if [[ "$MENU_TOOL" == "whiptail" || "$MENU_TOOL" == "dialog" ]]; then
    # build tag desc pairs (tag=index)
    local params=()
    local i=1
    for it in "${items[@]}"; do
      params+=("$i" "$it")
      i=$((i+1))
    done
    local choice
    choice=$(menu "$title" 20 78 "${#items[@]}" "${params[@]}")
    if [[ -z "$choice" ]]; then
      echo ""
      return
    fi
    # if numeric tag returned -> map to item
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      echo "${items[$((choice-1))]}"
      return
    fi
    # otherwise return raw
    echo "$choice"
  else
    # fallback simple numbered prompt (allow multiple selection comma-separated)
    echo "=== $title ==="
    local idx=1
    for it in "${items[@]}"; do
      printf "%3d) %s\n" "$idx" "$it"
      idx=$((idx+1))
    done
    read -rp "$prompt (enter number or comma list): " sel
    if [[ -z "$sel" ]]; then echo ""; return; fi
    # support comma-separated
    local out=()
    IFS=',' read -ra arr <<<"$sel"
    for v in "${arr[@]}"; do
      v="${v// /}"
      if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=1 && v<=${#items[@]} )); then
        out+=("${items[$((v-1))]}")
      fi
    done
    printf "%s\n" "${out[@]}"
  fi
}

list_shares_on_server() {
  local server="$1"
  local credfile="$2"
  # use smbclient -L with credential file (-A)
  log "Querying shares on //$server ..."
  smbclient -L "//$server" -A "$credfile" 2>>"$LOGFILE" | sed -n '/Sharename/,/Server\|$/{/Sharename/!p}' | awk '{$1=$1;print}' || true
}

create_credentials_file() {
  local server="$1" user="$2" pass="$3"
  mkdir -p "$CREDFOLDER"
  local file="$CREDFOLDER/credentials_${server}"
  # write username/password in smbclient format
  {
    echo "username=${user}"
    echo "password=${pass}"
  } >"$file"
  chmod 600 "$file"
  chown root:root "$file"
  log "Wrote credentials to $file (mode 600)"
  echo "$file"
}

create_mount_and_fstab_entry() {
  local server="$1" share="$2" credfile="$3" uid="${4:-0}" gid="${5:-0}"
  # sanitize share name for path
  local share_safe sharepath
  share_safe=$(echo "$share" | sed 's#[/:]#_#g')
  sharepath="$MNTROOT/$server/$share_safe"
  mkdir -p "$sharepath"
  chown root:root "$sharepath"
  chmod 755 "$sharepath"
  # fstab entry
  local esc_share="//${server}/${share}"
  # create fstab options: use uid/gid if specified (if UID !=0 probably user wants own mounts)
  local opts="credentials=${credfile},_netdev,noauto,x-systemd.automount,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,iocharset=utf8"
  if [[ "$uid" -ne 0 || "$gid" -ne 0 ]]; then
    opts+=",uid=${uid},gid=${gid}"
  fi
  # escape spaces: fstab requires \040 for space; replace spaces with \040
  esc_share="${esc_share// /\\040}"
  local esc_mount="${sharepath// /\\040}"
  # append to /etc/fstab if not already present
  if ! grep -Fq "$esc_share" "$FSTAB"; then
    printf "%s %s cifs %s 0 0\n" "$esc_share" "$esc_mount" "$opts" >>"$FSTAB"
    log "Added fstab entry for //$server/$share -> $sharepath"
  else
    log "Fstab already contains //$server/$share; skipping fstab append"
  fi
  # try immediate mount (systemd automount will create .automount unit; mounting via mount may mount now)
  if mountpoint -q "$sharepath"; then
    log "$sharepath already mounted"
  else
    # attempt mount (this will trigger systemd automount) — use mount command to activate automount
    if mount "$sharepath" 2>>"$LOGFILE"; then
      log "Mounted //$server/$share on $sharepath"
    else
      log "Attempted mount via mount command (systemd automount should handle it), mount may occur on access."
    fi
  fi

  echo "$sharepath"
}

# ===== main flow =====
require_root
pick_menu_tool
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
log "=== smb-autocfg started ==="

ensure_deps

# network detection
NETRANGE="$(detect_network_range)"
if [[ -z "$NETRANGE" ]]; then
  die "No network range given. Exiting."
fi

# scan
hosts_raw=()
mapfile -t hosts_raw < <(scan_for_smb_hosts "$NETRANGE")
if (( ${#hosts_raw[@]} == 0 )); then
  log "No SMB hosts found on $NETRANGE."
  echo "No SMB hosts found on $NETRANGE. Exiting."
  exit 0
fi
log "Found ${#hosts_raw[@]} host(s): ${hosts_raw[*]}"

# let user pick one or more servers
echo
if [[ "$MENU_TOOL" == "whiptail" || "$MENU_TOOL" == "dialog" ]]; then
  # use simple single-select menu; allow repeated runs to process multiple servers
  while true; do
    srv=$(choose_from_list "SMB Servers" "Select a server to configure (or Cancel/empty to finish):" "${hosts_raw[@]}")
    if [[ -z "$srv" ]]; then break; fi
    SELECTED_SERVERS+=("$srv")
    # remove selected from hosts list so user won't pick again
    newhosts=()
    for h in "${hosts_raw[@]}"; do [[ "$h" != "$srv" ]] && newhosts+=("$h"); done
    hosts_raw=("${newhosts[@]}")
    if (( ${#hosts_raw[@]} == 0 )); then break; fi
    if ! confirm "Configure another server?"; then break; fi
  done
else
  # fallback: allow comma-separated picks
  echo "Select one or more servers from the list (comma separated):"
  idx=1
  for h in "${hosts_raw[@]}"; do printf "%3d) %s\n" "$idx" "$h"; idx=$((idx+1)); done
  read -rp "Enter numbers (e.g. 1,3): " picknums
  IFS=',' read -ra arr <<<"$picknums"
  for v in "${arr[@]}"; do v="${v// /}"; if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=1 && v<=${#hosts_raw[@]} )); then SELECTED_SERVERS+=("${hosts_raw[$((v-1))]}"); fi; done
fi

if (( ${#SELECTED_SERVERS[@]} == 0 )); then
  log "No servers selected. Exiting."
  echo "No servers selected. Exiting."
  exit 0
fi

# For each selected server: ask credentials -> create credfile -> list shares -> pick shares -> mount & fstab
CREATED_CRED_FILES=()
CREATED_MOUNTS=()
for server in "${SELECTED_SERVERS[@]}"; do
  log "Processing server: $server"
  # username
  user_default="$(whoami)"
  user=$(input_box "Credentials for $server" "Username for //$server (domain\\user or user):" "$user_default")
  pass=$(password_box "Password for $user@$server: ")
  credfile=$(create_credentials_file "$server" "$user" "$pass")
  CREATED_CRED_FILES+=("$credfile")

  # list shares
  shares_raw=$(list_shares_on_server "$server" "$credfile")
  # parse share names: smbclient output has a table like:
  # Sharename       Type      Comment
  # ---------       ----      -------
  # share           Disk      ...
  # We'll parse third column lines: first word is sharename
  mapfile -t shares < <(printf "%s\n" "$shares_raw" | awk 'NF && $1!~/^(Sharename|Server|IPC$|Comment|-----)/ {print $1}')
  # dedupe
  mapfile -t shares < <(printf "%s\n" "${shares[@]}" | awk '!seen[$0]++')
  if (( ${#shares[@]} == 0 )); then
    log "No shares discovered on //$server (or access denied). Output from smbclient below:"
    echo "---- smbclient output (tail 40) ----"
    printf "%s\n" "$shares_raw" | tail -n 40
    echo "------------------------------------"
    if ! confirm "No shares found or access denied. Continue to next server?"; then
      die "User aborted."
    else
      continue
    fi
  fi

  # choose shares (allow multiple)
  echo
  echo "Shares on //$server:"
  idx=1
  for s in "${shares[@]}"; do printf "%3d) %s\n" "$idx" "$s"; idx=$((idx+1)); done
  read -rp "Enter share numbers to mount (comma-separated, e.g. 1,2) or 'all': " share_sel
  sel_list=()
  if [[ "${share_sel,,}" == "all" ]]; then
    sel_list=("${shares[@]}")
  else
    IFS=',' read -ra arr2 <<<"$share_sel"
    for v in "${arr2[@]}"; do v="${v// /}"; if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=1 && v<=${#shares[@]} )); then sel_list+=("${shares[$((v-1))]}"); fi; done
  fi
  if (( ${#sel_list[@]} == 0 )); then
    log "No shares selected for //$server"
    continue
  fi

  # optional: ask default uid/gid to use for mount (use 0=root by default)
  read -rp "Enter UID for mounted files (default 0=root): " uid
  uid="${uid:-0}"
  read -rp "Enter GID for mounted files (default 0=root): " gid
  gid="${gid:-0}"

  for share in "${sel_list[@]}"; do
    mountpath=$(create_mount_and_fstab_entry "$server" "$share" "$credfile" "$uid" "$gid")
    CREATED_MOUNTS+=("$mountpath")
  done
done

# After modifying fstab, inform systemd to reload and start automounts
log "Reloading systemd daemon and triggering mount units..."
systemctl daemon-reload >>"$LOGFILE" 2>&1 || true
# Try to start automount units for created mounts
for mp in "${CREATED_MOUNTS[@]}"; do
  # generate unit name from path: replace / with -, remove leading -
  unitname="$(echo "${mp}" | sed 's#/#-#g' | sed 's/^-//').automount"
  if systemctl start "$unitname" >>"$LOGFILE" 2>&1; then
    log "Started automount unit $unitname"
  else
    log "Could not start $unitname now; systemd should automount on access or after boot."
  fi
done

# final summary
log "=== Summary ==="
echo
echo "Created credential files:"
for f in "${CREATED_CRED_FILES[@]}"; do
  printf " - %s (mode 600)\n" "$f"
done
echo
echo "Created mountpoints and fstab entries:"
for m in "${CREATED_MOUNTS[@]}"; do
  printf " - %s\n" "$m"
done
echo
echo "Log file: $LOGFILE"
log "Script finished."

# show content of created files list and fstab lines we added
echo
echo "---- fstab entries (relevant lines) ----"
for s in "${CREATED_MOUNTS[@]}"; do
  # show any fstab line that mounts to this path
  grep -F " $(echo "$s" | sed 's/ /\\040/g')" "$FSTAB" || true
done
echo "----------------------------------------"

echo
echo "If you want to remove any added fstab entry, edit $FSTAB and remove the corresponding line. Credentials are stored under $CREDFOLDER (mode 600)."

exit 0
