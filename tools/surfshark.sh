#!/usr/bin/env bash
# Surfshark (or any WireGuard/OpenVPN) VPN for the vphone-linux host, through NetworkManager --
# what Linux Mint, Ubuntu and Fedora desktops already run, so nothing else needs installing (on a
# live USB session that matters: the official Surfshark app would be gone after each reboot).
#
#   tools/surfshark.sh import <file.conf|file.ovpn> [name]   add a Surfshark config to NetworkManager
#   tools/surfshark.sh up [name]       connect (the only/first imported Surfshark connection by default)
#   tools/surfshark.sh down [name]     disconnect
#   tools/surfshark.sh status          the VPN connections and where the host's traffic goes
#   tools/surfshark.sh check [-q]      exit 0 only if the default route goes through a VPN
#
# Configs: Surfshark's web dashboard, VPN > Manual setup > Desktop or mobile > WireGuard (make a
# key pair, pick a location, download the .conf), or OpenVPN (the .ovpn files plus the service
# credentials shown on that page; needs network-manager-openvpn). Keep them on a private disk:
# a WireGuard .conf holds your private key.
#
# The VM needs nothing more: QEMU's user-mode network sends the guest's traffic from the host,
# so it follows the VPN. REQUIRE_VPN=1 on run-vphone.sh / start-vm.sh / create-vm.sh refuses to
# boot the VM without the VPN and cuts the guest's link while the VPN is down (tools/vpn-guard.py).
# The official Surfshark Linux app works as well; `check` sees its tunnel the same way.
set -euo pipefail

PREFIX=${SURFSHARK_PREFIX:-surfshark-}   # NetworkManager names given to imported configs
QUIET=0

die() { echo "surfshark.sh: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# The interface the host's IPv4 default route uses (policy routing included: NetworkManager's
# WireGuard connections route through their own table with a fwmark rule).
route_dev() { ip -4 route get "${1:-1.1.1.1}" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1 || true; }
route_dev6() { ip -6 route get "${1:-2606:4700:4700::1111}" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1 || true; }

# A VPN interface: WireGuard, a tun/tap device (OpenVPN, the Surfshark app's OpenVPN/IKEv2), or
# an interface named like one.
is_vpn_dev() {
  local dev=$1 details
  [ -n "$dev" ] || return 1
  details=$(ip -d link show dev "$dev" 2>/dev/null) || return 1
  case $details in *" wireguard "*|*" tun "*|*" tap "*|*"tun type"*) return 0 ;; esac
  case $dev in wg*|tun*|tap*|surfshark*|nordlynx*|ipsec*|vti*|ppp*) return 0 ;; esac
  return 1
}

surfshark_conns() { nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: -v p="$PREFIX" \
  'index($1, p) == 1 && ($2 == "wireguard" || $2 == "vpn") { print $1 }' || true; }

pick_conn() {
  local name=${1:-}
  if [ -n "$name" ]; then
    nmcli -t -f NAME connection show | grep -qxF "$name" && { echo "$name"; return; }
    nmcli -t -f NAME connection show | grep -qxF "$PREFIX$name" && { echo "$PREFIX$name"; return; }
    die "no NetworkManager connection '$name' (tools/surfshark.sh status lists them)"
  fi
  name=$(surfshark_conns | head -1)
  [ -n "$name" ] || die "no Surfshark connection imported yet: tools/surfshark.sh import <file.conf>"
  echo "$name"
}

cmd_import() {
  local file=${1:?usage: surfshark.sh import <file.conf|file.ovpn> [name]} name base
  [ -r "$file" ] || die "cannot read $file"
  have nmcli || die "nmcli not found (NetworkManager): import the config in your VPN app instead"
  base=$(basename "$file"); base=${base%.*}
  name=$PREFIX${2:-$base}
  if nmcli -t -f NAME connection show | grep -qxF "$name"; then
    echo "$name is already imported"; return 0
  fi
  case $file in
    *.conf)
      # nmcli names a WireGuard connection (and its interface) after the file: copy it to a
      # short name first, interface names are at most 15 characters.
      local tmp ifname
      ifname="wg-$(printf '%s' "${2:-$base}" | tr -cd 'a-zA-Z0-9' | cut -c1-12)"
      tmp=$(mktemp -d)
      install -m 600 "$file" "$tmp/$ifname.conf"
      if ! nmcli connection import type wireguard file "$tmp/$ifname.conf" >/dev/null; then
        rm -rf "$tmp"; die "NetworkManager could not import $file"
      fi
      rm -rf "$tmp"
      nmcli connection modify "$ifname" connection.id "$name" connection.autoconnect no ;;
    *.ovpn)
      nmcli connection import type openvpn file "$file" >/dev/null ||
        die "OpenVPN import failed: sudo apt install network-manager-openvpn (then retry)"
      nmcli connection modify "$base" connection.id "$name" connection.autoconnect no
      echo "Set the Surfshark service credentials (not your account login): nmcli connection modify '$name' vpn.user-name <user> +vpn.secrets password=<pass>"
      ;;
    *) die "expected a WireGuard .conf or an OpenVPN .ovpn file" ;;
  esac
  echo "imported $name (connect: tools/surfshark.sh up '${name#"$PREFIX"}')"
}

cmd_up() {
  local name; name=$(pick_conn "${1:-}")
  nmcli connection up "$name" >/dev/null
  sleep 1
  if cmd_check -q; then echo "connected: $name (traffic leaves through $(route_dev))"
  else die "$name is up but the default route does not go through it"; fi
}

cmd_down() { local name; name=$(pick_conn "${1:-}"); nmcli connection down "$name" >/dev/null && echo "disconnected: $name"; }

cmd_check() {
  [ "${1:-}" = -q ] && QUIET=1
  local dev dev6
  dev=$(route_dev); dev6=$(route_dev6)
  if ! is_vpn_dev "$dev"; then
    [ "$QUIET" = 1 ] || echo "NOT protected: IPv4 traffic leaves through ${dev:-nothing (no route)}"
    return 1
  fi
  [ "$QUIET" = 1 ] || echo "protected: IPv4 traffic goes through the VPN interface $dev"
  if [ -n "$dev6" ] && ! is_vpn_dev "$dev6"; then
    # The VM is not affected with REQUIRE_VPN=1 (its user-mode network has IPv6 off then).
    [ "$QUIET" = 1 ] || echo "note: IPv6 leaves outside the VPN ($dev6); the guest's IPv6 is off with REQUIRE_VPN=1"
  fi
  return 0
}

cmd_status() {
  echo "VPN connections:"
  if have nmcli; then
    nmcli -t -f NAME,TYPE,DEVICE connection show 2>/dev/null |
      awk -F: '$2 == "wireguard" || $2 == "vpn" { printf "  %-28s %-10s %s\n", $1, $2, ($3 == "" ? "(down)" : "up on " $3) }' || true
  else
    echo "  (no NetworkManager here: only the routing check below)"
  fi
  cmd_check || true
  # Surfshark's own "are you protected" endpoint (best effort; any VPN shows its exit address).
  if have curl; then
    local info
    info=$(curl -fsS --max-time 8 https://surfshark.com/api/v1/server/user 2>/dev/null || true)
    if [ -n "$info" ]; then echo "Surfshark sees: $info"; fi
  fi
}

case ${1:-status} in
  import) shift; cmd_import "$@" ;;
  up)     shift; cmd_up "$@" ;;
  down)   shift; cmd_down "$@" ;;
  check)  shift; cmd_check "$@" ;;
  status) cmd_status ;;
  -h|--help|help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (import, up, down, status, check)" ;;
esac
