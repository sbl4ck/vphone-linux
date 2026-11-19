# shellcheck shell=bash disable=SC2034  # the package lists are read by setup.sh
# The libimobiledevice 1.4 stack, built from its release tarballs, for Debian-family releases
# that do not package it: Ubuntu 24.04 and what is built on it (Linux Mint 22.x, Pop!_OS 24.04,
# Zorin 18...). Those have no libimobiledevice-glue or libtatsu and a libimobiledevice 1.3,
# older than the 1.4 vphone-cli's restore code links. Sourced by setup.sh.
#
# Installed under /usr/local with the multiarch libdir (/usr/local/lib/x86_64-linux-gnu): that
# folder comes first in the linker's and ld.so's search on Debian/Ubuntu, ahead of the distro's
# own /usr/lib/x86_64-linux-gnu, so an older runtime copy pulled in by gvfs or upower does not
# shadow these. /usr/local/include and /usr/local/.../pkgconfig likewise come first for the
# compiler, pkg-config and the Swift build's linkedLibrary()s.
#
# The build trees stay in $VSETUP_IMD_DIR (by default inside the checkout's .build): on a live
# USB session /usr/local is lost at every reboot, and imd_install puts the libraries back with
# `make install` alone, without rebuilding.

# The packages this stack replaces (their -dev names in DEBIAN_PKGS, setup/lib/packages.sh).
DEBIAN_IMD_PKGS=(libplist-dev libimobiledevice-glue-dev libusbmuxd-dev libtatsu-dev libimobiledevice-dev)
# What building them needs besides DEBIAN_PKGS (autotools are not: the tarballs ship configure).
DEBIAN_IMD_BUILD_PKGS=(build-essential pkg-config libssl-dev libcurl4-openssl-dev libusb-1.0-0-dev)

# name version, in dependency order
IMD_STACK=(
  "libplist 2.7.0"
  "libimobiledevice-glue 1.3.2"
  "libusbmuxd 2.1.0"
  "libtatsu 1.0.5"
  "libimobiledevice 1.4.0"
)
IMD_PREFIX=${IMD_PREFIX:-/usr/local}
VSETUP_IMD_DIR=${VSETUP_IMD_DIR:-$VSETUP_SRC/.build/imobiledevice}

imd_libdir() { echo "$IMD_PREFIX/lib/$(gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"; }

# True when every library of the stack is installed in IMD_PREFIX at its pinned version.
imd_installed() {
  local entry name ver pc
  for entry in "${IMD_STACK[@]}"; do
    read -r name ver <<<"$entry"
    case $name in
      libplist) pc=libplist-2.0 ;;
      libusbmuxd) pc=libusbmuxd-2.0 ;;
      libtatsu) pc=libtatsu-1.0 ;;
      *) pc=$name-1.0 ;;
    esac
    [ -f "$(imd_libdir)/pkgconfig/$pc.pc" ] &&
      grep -qx "Version: $ver" "$(imd_libdir)/pkgconfig/$pc.pc" || return 1
  done
}

# Build what is not built yet, then (re)install everything into IMD_PREFIX.
imd_install() {
  local entry name ver dir libdir
  libdir=$(imd_libdir)
  if imd_installed; then
    log " libimobiledevice 1.4 stack already installed in $IMD_PREFIX"
    return 0
  fi
  mkdir -p "$VSETUP_IMD_DIR"
  for entry in "${IMD_STACK[@]}"; do
    read -r name ver <<<"$entry"
    dir=$VSETUP_IMD_DIR/$name-$ver
    if [ ! -f "$dir/.vphone-built" ]; then
      log " Building $name $ver from source (this distro does not package it)"
      if [ ! -f "$dir/configure" ]; then
        curl -fL --retry 3 -o "$VSETUP_IMD_DIR/$name-$ver.tar.bz2" \
          "https://github.com/libimobiledevice/$name/releases/download/$ver/$name-$ver.tar.bz2"
        tar -xjf "$VSETUP_IMD_DIR/$name-$ver.tar.bz2" -C "$VSETUP_IMD_DIR"
      fi
      # The libraries built before this one live in IMD_PREFIX already (installed below).
      ( cd "$dir" || exit
        export PKG_CONFIG_PATH=$libdir/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
        # (--without-cython: libplist's and libimobiledevice's Python bindings, not needed;
        # the other configure scripts ignore it.) libimobiledevice uses OpenSSL by default.
        ./configure --prefix="$IMD_PREFIX" --libdir="$libdir" --disable-static \
          --without-cython >/dev/null
        make -j"$(nproc)" >/dev/null )
      touch "$dir/.vphone-built"
    fi
    log " Installing $name $ver into $IMD_PREFIX"
    sudo make -C "$dir" install >/dev/null
    sudo ldconfig
  done
  imd_installed || die "the libimobiledevice stack did not install into $IMD_PREFIX"
}
