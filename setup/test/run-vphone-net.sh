#!/usr/bin/env bash
# run-vphone.sh's NET / REQUIRE_VPN options, against a stub QEMU and a stub `ip`.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
cleanup() { pkill -f "vpn-guard.py --qmp $tmp" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
vm=$tmp/vm
mkdir -p "$vm" "$tmp/bin"
printf '0x1234\n' > "$vm/ecid"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$vm/config.plist"
: > "$vm/nvram.bin"; : > "$vm/Disk.img"
: > "$vm/AVPBooter.vresearch1.bin"; : > "$vm/AVPSEPBooter.vresearch1.bin"

cat > "$tmp/qemu" <<'QEMU'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$QEMU_ARGS_FILE"
QEMU
chmod +x "$tmp/qemu"
# `ip` reporting the default route on $FAKE_DEV, a WireGuard interface when it is wg0
cat > "$tmp/bin/ip" <<'IP'
#!/usr/bin/env bash
case "$*" in
  *"route get"*) [ "$1" = -6 ] && exit 2; echo "1.1.1.1 dev $FAKE_DEV src 10.0.0.2 uid 1000" ;;
  *"link show dev wg0"*) printf '5: wg0: <POINTOPOINT,NOARP,UP> mtu 1420\n    link/none\n    wireguard addrgenmode none\n' ;;
  *"link show dev"*) printf '2: eth0: <UP> mtu 1500\n    link/ether 00:11:22:33:44:55\n' ;;
esac
IP
chmod +x "$tmp/bin/ip"

run() { rm -f "$tmp/qemu-args"
  env PATH="$tmp/bin:$PATH" QEMU="$tmp/qemu" QEMU_ARGS_FILE="$tmp/qemu-args" GFX=0 CID=0 \
    XDG_RUNTIME_DIR="$tmp" "$@" bash "$root/run-vphone.sh" "$vm" > /dev/null 2>&1; }
fail() { echo "FAIL: $*" >&2; exit 1; }

run FAKE_DEV=eth0
! grep -q -- '^-nic$' "$tmp/qemu-args" || fail "default adds a -nic"
run NET=none FAKE_DEV=eth0
grep -Fxq 'none' "$tmp/qemu-args" || fail "NET=none"
run NET=user NET_OPTS=hostfwd=tcp::2222-:22 FAKE_DEV=eth0
grep -Fxq 'user,id=vnet0,model=virtio-net-pci,hostfwd=tcp::2222-:22' "$tmp/qemu-args" || fail "NET=user"
if run NET=bogus FAKE_DEV=eth0; then fail "NET=bogus accepted"; fi
if run REQUIRE_VPN=1 FAKE_DEV=eth0; then fail "REQUIRE_VPN=1 started without a VPN"; fi
[ ! -e "$tmp/qemu-args" ] || fail "QEMU ran without a VPN"
run REQUIRE_VPN=1 FAKE_DEV=wg0 || fail "REQUIRE_VPN=1 refused a WireGuard route"
grep -Fxq 'user,id=vnet0,model=virtio-net-pci,ipv6=off' "$tmp/qemu-args" || fail "REQUIRE_VPN NIC"
grep -q '^unix:.*vphone-vpn-guard-.*\.sock,server=on,wait=off$' "$tmp/qemu-args" || fail "REQUIRE_VPN QMP socket"
echo 'ok: NET and REQUIRE_VPN build the expected network arguments'
