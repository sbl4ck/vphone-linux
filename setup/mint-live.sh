#!/usr/bin/env bash
# vphone-linux from a Linux Mint (Cinnamon) live USB session -- or any Ubuntu-based live session.
#
#   ./setup/mint-live.sh --data /media/mint/VPHONE      first time: prepare the drive, then setup.sh
#   ./setup/mint-live.sh                                after a reboot: same again (fast, reuses the builds)
#   ./setup/mint-live.sh create-vm [args]               setup/create-vm.sh with the drive's settings
#   ./setup/mint-live.sh start-vm  [args]               setup/start-vm.sh  with the drive's settings
#   ./setup/mint-live.sh shell                          a shell with the drive's settings (vphone-env.sh)
#
# A live session keeps its files and installed packages in RAM and forgets them at shutdown, and
# vphone-linux needs ~40 GB of build trees and toolchains plus ~60 GB per VM. So everything goes
# on a data drive (a second USB SSD/HDD, an internal disk partition, or the stick's own extra
# partition) formatted ext4 -- not FAT/exFAT/NTFS, which lack the permissions, symlinks and sparse
# files the build and the VM disk need:
#   <data>/vphone-linux/      this checkout (copied there on the first run if it is elsewhere)
#   <data>/vphone-work/       toolchains (Rust, Swift), firmware cache, VM bundles, tmp, swap
#   <data>/vphone-env.sh      the settings, for: source <data>/vphone-env.sh
# After a reboot the system packages and the source-built libimobiledevice are put back (apt and
# `make install`, a few minutes, no rebuild). With a persistent live USB (Ventoy/mkusb persistence)
# or Mint installed on the USB drive, that step finds everything in place.
#
# Surfshark: see tools/surfshark.sh. REQUIRE_VPN=1 in front of create-vm/start-vm keeps the VM off
# the network unless the VPN is up. Set VPHONE_REQUIRE_VPN=1 in vphone-env.sh to make it the default.
set -Eeuo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/lib/common.sh"

DATA=${VPHONE_DATA:-}
cmd=setup
while [ $# -gt 0 ]; do
  case $1 in
    --data) DATA=$2; shift ;;
    --data=*) DATA=${1#--data=} ;;
    create-vm|start-vm|shell|setup) cmd=$1; shift; break ;;
    -y|--yes|deps|sources|build|release|all) break ;;   # setup.sh's own options
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac; shift
done

is_live() { grep -qE 'boot=(casper|live)' /proc/cmdline 2>/dev/null || [ -d /run/casper ] || [ -d /rofs ] ||
            [ "$(findmnt -no FSTYPE / 2>/dev/null)" = overlay ]; }

# The data drive: --data, VPHONE_DATA, or the drive this checkout already sits on.
if [ -z "$DATA" ] && [ -f "$here/../../vphone-env.sh" ]; then DATA=$(cd "$here/../.." && pwd); fi
if [ -z "$DATA" ]; then
  echo "Mounted drives that could hold the data (need ext4 and ~150 GB free):" >&2
  findmnt -rno TARGET,FSTYPE,SIZE,AVAIL -t ext4,ext3,xfs,btrfs,f2fs 2>/dev/null |
    awk '$1 != "/" && $1 !~ /^\/(boot|cdrom|rofs|snap)/ { printf "  %-40s %-6s size %-6s free %s\n", $1, $2, $3, $4 }' >&2
  die "pass the data drive: ./setup/mint-live.sh --data /media/$(id -un)/<label>
     (open it once in the file manager to mount it; format a drive as ext4 with the Disks app)"
fi
DATA=$(cd "$DATA" && pwd) || die "no such folder: $DATA"

ENV_FILE=$DATA/vphone-env.sh
WORK=$DATA/vphone-work
CHECKOUT=$DATA/vphone-linux

# ------------------------------------------------------------ the drive ---
check_drive() {
  local fstype opts avail
  fstype=$(findmnt -no FSTYPE -T "$DATA")
  opts=$(findmnt -no OPTIONS -T "$DATA")
  case $fstype in
    ext4|ext3|xfs|btrfs|f2fs) ;;
    vfat|exfat|ntfs|ntfs3|fuseblk)
      die "$DATA is $fstype: it cannot hold the build (no Unix permissions/symlinks) or the VM disk.
     Reformat it (or a partition of it) as ext4 with the Disks app, then re-run." ;;
    tmpfs|overlay|squashfs)
      die "$DATA is in the live session's RAM ($fstype), lost at shutdown: pick a real drive." ;;
    *) warn "$DATA is $fstype, untested: ext4 is recommended" ;;
  esac
  case ",$opts," in *,noexec,*)
    log " $DATA is mounted noexec: remounting it exec (the build runs its own binaries)"
    sudo mount -o remount,exec "$(findmnt -no TARGET -T "$DATA")" ;;
  esac
  avail=$(df -P -BG "$DATA" | awk 'NR == 2 { sub(/G$/, "", $4); print $4 }')
  if [ "${avail:-0}" -lt 100 ]; then
    warn "$DATA has ${avail} GB free: the build needs ~40 GB and each VM ~60 GB (plus the IPSW downloads)"
  fi
  # A freshly formatted ext4 filesystem belongs to root: give its top folder to the live user.
  if [ ! -w "$DATA" ]; then
    log " $DATA belongs to $(stat -c %U "$DATA"): handing it to $(id -un)"
    sudo chown "$(id -u):$(id -g)" "$DATA"
  fi
  mkdir -p "$WORK"/{tmp,cache,devices,release,cargo,rustup,swiftly}
  [ -w "$WORK" ] || die "$WORK is not writable by $(id -un)"
}

# This checkout must live on the drive (VSETUP_SRC is the checkout itself: builds land in it).
ensure_checkout() {
  local src; src=$(cd "$here/.." && pwd)
  [ "$src" = "$CHECKOUT" ] && return 0
  if [ ! -e "$CHECKOUT/.git" ]; then
    log " Copying this checkout to $CHECKOUT (it must live on the drive, not in the session's RAM)"
    cp -a "$src/." "$CHECKOUT/"
  fi
  log " Continuing from $CHECKOUT"
  exec "$CHECKOUT/setup/mint-live.sh" --data "$DATA" "$cmd" "$@"
}

write_env() {
  local mem_gb icd='' vk=''
  mem_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1048576 }' /proc/meminfo)
  # The Vulkan driver every GPU process uses (run-vphone.sh picks NVIDIA's proprietary one by
  # itself). A live session has no NVIDIA driver (nouveau's Vulkan cannot import guest memory):
  # lavapipe, which renders on the CPU, always works; Intel and AMD use Mesa's drivers.
  if [ ! -f /usr/share/vulkan/icd.d/nvidia_icd.json ]; then
    case $(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' | head -1) in
      *'[8086:'*) icd=/usr/share/vulkan/icd.d/intel_icd.x86_64.json ;;
      *'[1002:'*) icd=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json ;;
      *)          icd=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json ;;
    esac
  fi
  [ -f "$ENV_FILE" ] && return 0      # the user may have edited it: keep it
  [ -z "$icd" ] || vk="export VK_DRIVER_FILES=\${VK_DRIVER_FILES:-$icd}
export LP_NUM_THREADS=\${LP_NUM_THREADS:-4}"
  log " Writing $ENV_FILE"
  cat > "$ENV_FILE" <<EOF
# vphone-linux settings for this data drive (written by setup/mint-live.sh; edit freely).
#   source $ENV_FILE
VPHONE_DATA=$DATA
export VSETUP_SRC=$CHECKOUT
export VSETUP_RELEASE=$WORK/release
export VSETUP_DEVICES=$WORK/devices
export VSETUP_CACHE=$WORK/cache
export VSETUP_IMD_DIR=$WORK/imobiledevice
export TMPDIR=$WORK/tmp
export CARGO_HOME=$WORK/cargo RUSTUP_HOME=$WORK/rustup
export SWIFTLY_HOME_DIR=$WORK/swiftly
export PATH=\$CARGO_HOME/bin:\$PATH
# Guest RAM (QEMU keeps it in /dev/shm, i.e. in this PC's RAM, next to the live session itself).
export MEM=\${MEM:-$([ "$mem_gb" -ge 24 ] && echo 8G || echo 6G)}
# Vulkan driver (empty: run-vphone.sh / the Vulkan loader decide). lavapipe = CPU rendering.
$vk
# 1: the VM boots only with the VPN up and loses its network while the VPN is down.
export REQUIRE_VPN=\${REQUIRE_VPN:-\${VPHONE_REQUIRE_VPN:-0}}
EOF
}

# ------------------------------------------------- live-session tuning ---
live_tuning() {
  local mem_gb shm_need shm_gb swap
  mem_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1048576 }' /proc/meminfo)
  [ "$mem_gb" -ge 15 ] || warn "this PC has ${mem_gb} GB RAM: 16 GB is the minimum (the live session itself lives in RAM too)"
  # No swap on a live session: a swap file on the drive keeps the Rust/Swift builds and the
  # guest from running the session out of memory.
  swap=$WORK/swapfile
  if ! swapon --show=NAME --noheadings | grep -q .; then
    if [ ! -f "$swap" ] && confirm "No swap: create a 16 GB swap file on the drive ($swap)?"; then
      sudo fallocate -l 16G "$swap" || sudo dd if=/dev/zero of="$swap" bs=1M count=16384 status=none
      sudo chmod 600 "$swap"; sudo mkswap -q "$swap"
    fi
    [ -f "$swap" ] && { sudo swapon "$swap" && log " Swap on: $swap"; } || true
  fi
  # /dev/shm must hold the guest's RAM (run-vphone.sh checks).
  shm_need=$(numfmt --from=iec "${MEM:-8G}"); shm_gb=$(( shm_need / 1073741824 + 1 ))
  if [ "$(( $(stat -f -c '%a * %S' /dev/shm) ))" -lt "$shm_need" ]; then
    log " Enlarging /dev/shm to ${shm_gb} GB for the guest's RAM"
    sudo mount -o remount,size="${shm_gb}G" /dev/shm
  fi
}

# Cinnamon's gvfs volume monitors grab an Apple USB device as soon as it appears (the guest
# during a restore) and pop up mount dialogs: pause them for this session.
quiet_gvfs() {
  systemctl --user stop gvfs-afc-volume-monitor.service gvfs-gphoto2-volume-monitor.service 2>/dev/null || true
}

# ------------------------------------------------------------------ main ---
check_drive
ensure_checkout "$@"
write_env
# shellcheck disable=SC1090
source "$ENV_FILE"
is_live || log " Not a live session: the drive layout works the same on an installed system"

case $cmd in
  setup)
    live_tuning
    log " Running setup.sh (re-runnable: after a reboot it reinstalls packages and reuses the builds)"
    "$CHECKOUT/setup/setup.sh" "$@"
    log "Next: $CHECKOUT/setup/mint-live.sh create-vm    (Surfshark: tools/surfshark.sh, REQUIRE_VPN=1)" ;;
  create-vm|start-vm)
    live_tuning
    [ "$cmd" = create-vm ] && quiet_gvfs
    if [ "${REQUIRE_VPN:-0}" = 1 ]; then "$CHECKOUT/tools/surfshark.sh" check || die "REQUIRE_VPN=1: connect the VPN first (tools/surfshark.sh up)"; fi
    exec "$CHECKOUT/setup/$cmd.sh" "$@" ;;
  shell)
    log " Shell with $ENV_FILE loaded (exit to leave)"
    exec "${SHELL:-bash}" -i ;;
esac
