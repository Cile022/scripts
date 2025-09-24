#!/usr/bin/env bash
# proxmox-helper.sh
set -Eeuo pipefail

#============= CONFIG / GLOBALS =============#
DRY_RUN=0
MENU_TOOL=""
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE="local-lvm"
DEFAULT_ISO_STORAGE="local"
DEFAULT_BACKUP_STORAGE="local"

#============= UTILITIES =============#
log()  { printf "[%s] %s\n" "$(date +'%F %T')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
shdry(){ if ((DRY_RUN)); then echo "[dry-run] $*"; else eval "$@"; fi; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root."
}

need_proxmox() {
  command -v pveversion >/dev/null 2>&1 || die "This script must run on Proxmox VE."
}

pick_menu_tool() {
  if command -v whiptail >/dev/null 2>&1; then MENU_TOOL="whiptail"
  elif command -v dialog >/dev/null 2>&1;  then MENU_TOOL="dialog"
  else MENU_TOOL="none"; fi
}

menu() {
  # $1=title, $2=height, $3=width, shift 3 => items "tag desc" ...
  if [[ $MENU_TOOL == "whiptail" ]]; then
    whiptail --clear --title "$1" --menu "$1" "$2" "$3" 10 "${@:4}" 3>&1 1>&2 2>&3
  elif [[ $MENU_TOOL == "dialog" ]]; then
    dialog --clear --title "$1" --menu "$1" "$2" "$3" 10 "${@:4}" 3>&1 1>&2 2>&3
  else
    # naive fallback
    echo "$1"
    local i=1; while (( "$#" )); do
      shift 3 || true; break
    done
    local idx=1
    while (( "$#" )); do
      local tag="$1"; local desc="$2"; shift 2 || true
      printf "  %d) %s - %s\n" "$idx" "$tag" "$desc"
      idx=$((idx+1))
    done
    read -rp "Choose number: " choice
    echo "$choice"
  fi
}

input_box() {
  # $1=title $2=prompt $3=default
  if [[ $MENU_TOOL == "whiptail" ]]; then
    whiptail --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3
  elif [[ $MENU_TOOL == "dialog" ]]; then
    dialog --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3
  else
    read -rp "$2 [$3]: " val; echo "${val:-$3}"
  fi
}

password_box() {
  if [[ $MENU_TOOL == "whiptail" ]]; then
    whiptail --passwordbox "Enter password" 10 70 3>&1 1>&2 2>&3
  elif [[ $MENU_TOOL == "dialog" ]]; then
    dialog --passwordbox "Enter password" 10 70 3>&1 1>&2 2>&3
  else
    read -rsp "Enter password: " val; echo; echo "$val"
  fi
}

msgbox() {
  local txt="$1"
  if [[ $MENU_TOOL == "whiptail" ]]; then
    whiptail --msgbox "$txt" 12 70
  elif [[ $MENU_TOOL == "dialog" ]]; then
    dialog --msgbox "$txt" 12 70
  else
    echo -e "$txt"
  fi
}

confirm() {
  local q="${1:-Are you sure?}"
  if [[ $MENU_TOOL == "whiptail" ]]; then
    whiptail --yesno "$q" 8 60
    return $?
  elif [[ $MENU_TOOL == "dialog" ]]; then
    dialog --yesno "$q" 8 60
    return $?
  else
    read -rp "$q [y/N]: " yn; [[ ${yn,,} == y* ]]
  fi
}

#============= TASKS =============#
task_update_system() {
  log "Updating apt & Proxmox packages"
  shdry apt-get update
  shdry apt-get -y dist-upgrade
  shdry apt-get -y autoremove --purge
}

task_refresh_templates() {
  log "Refreshing LXC template index (pveam update)"
  shdry pveam update
}

task_list_templates() {
  log "Listing LXC templates (top 30)"
  pveam available | sort | tail -n +1 | head -n 30
}

task_create_lxc_interactive() {
  log "Interactive LXC creation"
  local ctid hostname storage template pw cores mem bridge
  ctid=$(input_box "LXC" "CT ID (e.g., 101)" "101")
  hostname=$(input_box "LXC" "Hostname" "lxc-$ctid")
  storage=$(input_box "LXC" "Storage (thin block or dir)" "$DEFAULT_STORAGE")
  bridge=$(input_box "LXC" "Network bridge" "$DEFAULT_BRIDGE")
  cores=$(input_box "LXC" "CPU cores" "2")
  mem=$(input_box "LXC" "Memory (MiB)" "2048")

  # pick template
  log "Fetching templates…"
  local tmpl_list
  tmpl_list=$(pveam available | awk '{print $1}' | grep -E '\.tar\.(gz|xz)$' || true)
  if [[ -z "$tmpl_list" ]]; then
    msgbox "No templates found. Run 'Refresh templates' first."
    return 1
  fi
  # simplest: auto-pick debian bookworm if exists, else the first
  local default_tmpl
  default_tmpl=$(echo "$tmpl_list" | grep -m1 -E 'debian.*bookworm.*amd64' || true)
  template=$(input_box "LXC" "Template (exact from 'pveam available')" "${default_tmpl:-$(echo "$tmpl_list" | head -n1)}")

  pw=$(password_box)

  # Ensure template is downloaded to storage (dir)
  local tmpl_store="local"
  if ! pveam list "$tmpl_store" | grep -q "$(basename "$template")"; then
    log "Downloading template to $tmpl_store: $template"
    shdry pveam download "$tmpl_store" "$template"
  fi
  local tmpl_path="/var/lib/vz/template/cache/$(basename "$template")"
  [[ -f "$tmpl_path" ]] || die "Template not present at $tmpl_path"

  confirm "Create LXC CTID $ctid ($hostname) on $storage?" || { log "Canceled."; return; }

  shdry pct create "$ctid" "$tmpl_path" \
    -hostname "$hostname" \
    -password "$pw" \
    -storage "$storage" \
    -net0 "name=eth0,bridge=$bridge,ip=dhcp" \
    -cores "$cores" \
    -memory "$mem" \
    -onboot 1

  shdry pct start "$ctid"
  msgbox "LXC $ctid ($hostname) created and started."
}

task_create_vm_interactive() {
  log "Interactive VM creation"
  local vmid name iso_storage iso_file storage cores mem disk_gb bridge
  vmid=$(input_box "VM" "VMID (e.g., 200)" "200")
  name=$(input_box "VM" "Name" "vm-$vmid")
  iso_storage=$(input_box "VM" "ISO storage (content=iso)" "$DEFAULT_ISO_STORAGE")

  # pick ISO
  local iso_list
  iso_list=$(pvesh get /nodes/$(hostname)/storage/$iso_storage/content | jq -r '.[] | select(.content=="iso") | .volid' 2>/dev/null || true)
  if [[ -z "$iso_list" ]]; then
    msgbox "No ISOs on storage '$iso_storage'. Upload an ISO first (Datacenter → Storage → ISO)."
    return 1
  fi
  local default_iso
  default_iso=$(echo "$iso_list" | head -n1)
  iso_file=$(input_box "VM" "ISO volid (exact)" "$default_iso")

  storage=$(input_box "VM" "Disk storage" "$DEFAULT_STORAGE")
  cores=$(input_box "VM" "CPU cores" "2")
  mem=$(input_box "VM" "Memory (MiB)" "4096")
  disk_gb=$(input_box "VM" "Disk size (GB)" "32")
  bridge=$(input_box "VM" "Network bridge" "$DEFAULT_BRIDGE")

  confirm "Create VM $vmid ($name) using $iso_file?" || { log "Canceled."; return; }

  shdry qm create "$vmid" --name "$name" --ostype l26
  shdry qm set "$vmid" --memory "$mem" --cores "$cores" --cpu host
  shdry qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$storage:$((${disk_gb}))"
  shdry qm set "$vmid" --ide2 "$iso_file",media=cdrom
  shdry qm set "$vmid" --boot order=scsi0;ide2
  shdry qm set "$vmid" --net0 virtio,bridge="$bridge"
  shdry qm set "$vmid" --agent enabled=1
  shdry qm start "$vmid"
  msgbox "VM $vmid ($name) created and started."
}

task_backup_interactive() {
  log "Interactive backup"
  local target what
  target=$(input_box "Backup" "Backup storage (content=backup)" "$DEFAULT_BACKUP_STORAGE")
  what=$(input_box "Backup" "Guest ID(s) (e.g., 101 or 101,102)" "")
  [[ -z "$what" ]] && die "No guest IDs provided."
  confirm "Run vzdump to $target for $what?" || { log "Canceled."; return; }
  shdry vzdump $what --storage "$target" --mode snapshot --compress zstd
  msgbox "Backup triggered for: $what"
}

task_clean_images() {
  log "Cleaning unused templates, cache & orphaned images (safe)"
  shdry pveam update
  # Clean template cache older than 60 days
  find /var/lib/vz/template/cache -type f -mtime +60 -name "*.tar.*" -print -exec bash -c '((DRY_RUN)) && echo "[dry-run] rm -f \"$1\"" || rm -f "$1"' _ {} \;
  # Show orphaned volumes on local-lvm (manual action advised)
  log "Listing possibly orphaned volumes on $DEFAULT_STORAGE (manual remove via GUI recommended):"
  lvs | awk 'NR==1 || $1 ~ /^vm|^base/ {print}'
}

task_update_all_lxc() {
  log "Updating all running LXC containers (apt-get dist-upgrade)"
  local ids
  ids=$(pct list | awk 'NR>1 {print $1}')
  [[ -z "$ids" ]] && { log "No containers found."; return; }
  for id in $ids; do
    log "Updating CT $id"
    if ((DRY_RUN)); then
      echo "[dry-run] pct exec $id -- sh -c 'apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove --purge'"
    else
      pct exec "$id" -- sh -c 'apt-get update && apt-get -y dist-upgrade && apt-get -y autoremove --purge'
    fi
  done
  msgbox "Updates complete."
}

#============= MENU =============#
show_menu() {
  pick_menu_tool
  while true; do
    local choice
    choice=$(menu "Proxmox Helper" 20 78 \
      U "Update host system" \
      R "Refresh LXC templates (pveam)" \
      L "List LXC templates" \
      X "Create LXC (interactive)" \
      V "Create VM (interactive)" \
      B "Backup guest(s) (interactive)" \
      A "Update all LXC (apt)" \
      C "Clean old template cache" \
      Q "Quit") || true

    # dialog/whiptail returns string tags; fallback returns number
    case "$choice" in
      1|U) task_update_system;;
      2|R) task_refresh_templates;;
      3|L) task_list_templates | ${PAGER:-cat};;
      4|X) task_create_lxc_interactive;;
      5|V) task_create_vm_interactive;;
      6|B) task_backup_interactive;;
      7|A) task_update_all_lxc;;
      8|C) task_clean_images;;
      9|Q|"" ) break;;
      *) msgbox "Invalid choice: $choice";;
    esac
  done
}

#============= CLI ARG PARSING =============#
usage() {
cat <<EOF
Proxmox Helper Script

Usage:
  $0 [options]

Options:
  --menu                  Launch interactive TUI menu.
  --update                Update host (apt dist-upgrade, autoremove).
  --refresh-templates     Refresh LXC template index (pveam update).
  --list-templates        List available LXC templates.
  --create-lxc            Interactive LXC creation wizard.
  --create-vm             Interactive VM creation wizard.
  --backup                Interactive backup (vzdump).
  --update-all-lxc        apt update/upgrade in all containers.
  --clean                 Clean old template caches (safe).
  --dry-run               Print commands without executing.
  -h, --help              Show this help.

Environment defaults:
  DEFAULT_BRIDGE="$DEFAULT_BRIDGE"
  DEFAULT_STORAGE="$DEFAULT_STORAGE"
  DEFAULT_ISO_STORAGE="$DEFAULT_ISO_STORAGE"
  DEFAULT_BACKUP_STORAGE="$DEFAULT_BACKUP_STORAGE"
EOF
}

main() {
  need_root
  need_proxmox

  local action="menu"
  while (( $# )); do
    case "$1" in
      --menu) action="menu";;
      --update) action="update";;
      --refresh-templates) action="refresh";;
      --list-templates) action="list";;
      --create-lxc) action="lxc";;
      --create-vm) action="vm";;
      --backup) action="backup";;
      --update-all-lxc) action="update_all_lxc";;
      --clean) action="clean";;
      --dry-run) DRY_RUN=1;;
      -h|--help) usage; exit 0;;
      *) die "Unknown option: $1";;
    esac
    shift
  done

  case "$action" in
    menu) show_menu;;
    update) task_update_system;;
    refresh) task_refresh_templates;;
    list) task_list_templates;;
    lxc) task_create_lxc_interactive;;
    vm) task_create_vm_interactive;;
    backup) task_backup_interactive;;
    update_all_lxc) task_update_all_lxc;;
    clean) task_clean_images;;
  esac
}

main "$@"
