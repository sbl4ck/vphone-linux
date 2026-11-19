# Linux Mint (Cinnamon) live USB, with Surfshark VPN

This page covers running vphone-linux from a **Linux Mint 22.x Cinnamon live USB session** (the
"Try Linux Mint" desktop you get when you boot the USB stick), and sending the virtual iPhone's
traffic through **Surfshark**. Most of it also applies to an installed Mint 22 and to other
Ubuntu 24.04-based live sessions.

> **Status.** Mint 22 is built on Ubuntu 24.04, which does not package the libimobiledevice 1.4
> libraries. `setup.sh` now builds them from source, and that build has been tested on Ubuntu 24.04.
> The full flow from a Mint live session (building everything, creating a VM, booting it) and
> networking inside the iOS guest have **not** been tested end to end yet.

## What is different on a live USB

A live session keeps everything in RAM and forgets it at shutdown: files in your home folder,
packages you install, and anything under `/usr/local`. vphone-linux needs about 40 GB of build
trees and toolchains, plus about 60 GB per VM. So:

1. **You need a data drive formatted ext4**: a second USB SSD (best), a partition on an internal
   disk, or an extra partition on the stick itself. FAT32, exFAT and NTFS will not work: the build
   needs Unix permissions and symlinks, and the VM disk image is a sparse file. Plan for **150 GB or
   more**, and use a fast drive. The VM's disk is read constantly, and a USB 2 stick is far too slow.
2. **RAM:** at least 16 GB, 32 GB recommended. The live session itself, `/dev/shm` (where QEMU keeps
   the guest's RAM) and the builds all share it. `mint-live.sh` sets the guest to 6 GB below
   24 GB of RAM (8 GB otherwise) and offers to create a swap file on the data drive.
3. **After each reboot**, the system packages and the source-built libraries have to go back in.
   Running `mint-live.sh` again does that in a few minutes. Your builds, toolchains and VMs are
   still on the data drive, so nothing is rebuilt. If you make a *persistent* live USB (Ventoy or
   mkusb persistence), or install Mint onto the USB drive, that step finds everything in place.
4. **Kernel headers:** creating a VM builds a kernel module (linux-apfs-rw) for the running kernel,
   which needs that kernel's `linux-headers-<version>` package. Ubuntu's archive drops old kernel
   versions over time, so a live ISO that is a few months old may boot a kernel whose headers are no
   longer available. `setup.sh` warns when that happens. The fixes are a newer Mint ISO, Mint
   installed on the USB drive (it can then update its kernel), or creating the VM on another Linux PC
   and importing it with `tools/import-vm.sh`. *Running* an existing VM does not need the headers.
5. **GPU:**
   - **AMD (a Radeon card, or the integrated Radeon in a Ryzen APU):** this uses Mesa's RADV
     driver, which is already on the live USB (`mesa-vulkan-drivers`). AMD needs one extra thing:
     RADV refuses to take the guest's memory directly, so reims-vgpu passes it through
     `/dev/udmabuf`, and **a guest whose QEMU cannot open that device dies at boot**. On Mint the
     device belongs to the `kvm` group. `setup.sh` (host settings) loads the `udmabuf` module and
     installs a udev rule that gives the logged-in user access, which works in a live session
     without logging out again. `run-vphone.sh` stops with the fix if access is still missing.
     `tools/check-host.sh` checks both. reims-vgpu's developers booted a guest on a Radeon 780M
     (Ryzen APU) at udmabuf's stock limits. vphone-linux itself has not been run on AMD yet.
   - **APU memory:** an integrated GPU shares system RAM, so the guest (6-8 GB in `/dev/shm`), the
     GPU's share, the live session and the builds all come out of the same RAM. Use 32 GB if you can.
     If the guest gets killed with no message, lower the guest's RAM (`MEM=6G`) or set the iGPU's
     memory reservation ("UMA frame buffer size") to a small value in the firmware setup.
   - **CPU:** on AMD, `run-vphone.sh` leaves thread placement to the kernel. The core pinning only
     applies to Intel's hybrid CPUs. `mint-live.sh` lowers the guest's vCPUs (`SMP`) on CPUs with
     fewer than 10 threads.
   - **NVIDIA:** a live session has no proprietary NVIDIA driver (installing one needs a reboot,
     which the live session would forget), so `mint-live.sh` uses **lavapipe**, which renders on the
     CPU. It is slower but always works, and it is the same path [WSL](WSL.md) uses. On an installed
     Mint, install NVIDIA's driver with Driver Manager. That driver is the only one tested so far.
   - Intel GPUs use Mesa's ANV. To pick another driver, edit `VK_DRIVER_FILES` in `vphone-env.sh`.

## Steps

**1. Prepare the data drive (once).** In the live session, open **Disks**. Create an ext4 partition
(this erases whatever is on it) and name it, for example `VPHONE`. Then click it in the file
manager so it mounts at `/media/mint/VPHONE`.

**2. Get the code and run the live setup.** Open a terminal:

```sh
cd /media/mint/VPHONE
git clone https://github.com/YahiaAngelo/vphone-linux.git && cd vphone-linux
./setup/mint-live.sh --data /media/mint/VPHONE        # add -y to answer yes to every prompt
```

`mint-live.sh` checks the drive (filesystem, `noexec`, free space) and copies the checkout onto
the drive if it is somewhere else. It then writes `/media/mint/VPHONE/vphone-env.sh`, which points
every build, cache, toolchain (Rust, Swift), temporary folder and VM at the drive. Last, it runs
`setup/setup.sh` with those settings. On Mint 22 that includes building libplist 2.7,
libimobiledevice-glue 1.3, libusbmuxd 2.1, libtatsu 1.0 and libimobiledevice 1.4 into `/usr/local`
(about a minute). The rest of the first run takes as long as on any PC, mostly building reims-vgpu
and QEMU.

**3. Create the VM:**

```sh
./setup/mint-live.sh create-vm            # REQUIRE_VPN=1 ./setup/mint-live.sh create-vm  to insist on the VPN
```

This runs `setup/create-vm.sh` with the drive's settings. It also pauses Cinnamon's iPhone and
camera auto-mount helpers (gvfs) for the session, so they leave the virtual device alone during
the restore. If a "device connected" pop-up still appears, dismiss it.

**4. Later sessions (after a reboot):** mount the drive (click it in the file manager), then:

```sh
/media/mint/VPHONE/vphone-linux/setup/mint-live.sh -y         # packages and libraries back
/media/mint/VPHONE/vphone-linux/setup/mint-live.sh start-vm   # start and unlock the VM
```

`./setup/mint-live.sh shell` opens a shell with `vphone-env.sh` loaded. You can use it to run
the other scripts (`run-vphone.sh`, `tools/...`) by hand.

## Surfshark VPN

### How the iPhone's traffic reaches the VPN

The QEMU machine gives the guest a virtio-net network card on QEMU's *user-mode* network
(slirp): NAT done inside the QEMU process. Everything the guest sends goes out as ordinary
connections from QEMU, so it follows the host's routes, and **when Surfshark is connected on the
host, the iPhone's traffic goes through it as well**. Nothing has to be set up inside iOS, and
the VPN does not need to support the guest in any way. (The host-side connections vphone-linux
uses itself, such as vsock, the USB/IP link on 127.0.0.1 and the usbmuxd socket, are local and
never touch the VPN.)

### Connecting Surfshark on the host

Either use **Surfshark's Linux app** (a .deb from surfshark.com; on a non-persistent live USB you
would reinstall it after every reboot), or, simpler on a live USB, use **NetworkManager**, which
Mint already runs. `tools/surfshark.sh` covers the second way:

1. In Surfshark's web dashboard, go to **VPN → Manual setup → Desktop or mobile → WireGuard**.
   Generate a key pair, pick a location and download the `.conf` file. Keep it on the data drive,
   for example `/media/mint/VPHONE/surfshark/`. It contains your private key, so do not share it.
   (OpenVPN `.ovpn` files work too: install `network-manager-openvpn`, then set the service
   username and password shown on the same dashboard page.)
2. Import it once per session (the import is lost at reboot on a live USB), then connect:

   ```sh
   tools/surfshark.sh import /media/mint/VPHONE/surfshark/us-nyc.conf nyc
   tools/surfshark.sh up nyc
   tools/surfshark.sh status      # connections, which interface traffic uses, Surfshark's view
   ```

   The connection also appears in Cinnamon's network menu, so you can connect and disconnect it
   there too.

### Kill switch for the VM: `REQUIRE_VPN=1`

```sh
REQUIRE_VPN=1 ./setup/mint-live.sh start-vm      # or: REQUIRE_VPN=1 ./setup/start-vm.sh / run-vphone.sh
```

With `REQUIRE_VPN=1`, `run-vphone.sh`:

- **refuses to start the VM** unless the host's default route goes through a VPN interface
  (WireGuard, or a tun/tap device as used by OpenVPN and the Surfshark app). `tools/surfshark.sh
  check` makes that decision.
- gives the guest an explicit user-mode NIC **with IPv6 off**. Surfshark's WireGuard configs carry
  only IPv4, so guest IPv6 would otherwise leave outside the tunnel.
- starts `tools/vpn-guard.py`, which checks the route every second and **takes the guest's network
  link down while the VPN is down** (QMP `set_link`). iOS sees its cable unplugged, and nothing
  the guest sends in the meantime leaves the PC. The link comes back by itself when the VPN
  reconnects.

To make it the default, set `VPHONE_REQUIRE_VPN=1` in `vphone-env.sh`.

### Other network switches

| Variable | Effect |
|---|---|
| `NET=` (default) | QEMU's default NIC, user-mode NAT (as before this change) |
| `NET=user` | the same NIC, explicit (id `vnet0`); `NET_OPTS=hostfwd=tcp::2222-:22` adds options |
| `NET=none` | no network in the guest |
| `REQUIRE_VPN=1` | the VPN kill switch above (implies `NET=user`, IPv6 off) |

### Notes

- **Apple's servers through a VPN:** creating a VM downloads IPSWs from Apple's CDN and asks
  Apple's signing server (TSS) to sign the restore. Both are expected to work over a VPN. If a
  download or the signing step keeps failing, try another Surfshark location, or create the VM
  with the VPN off and use `REQUIRE_VPN=1` only for running it.
- **GitHub:** a shared VPN exit address can hit GitHub's rate limit for anonymous downloads during
  setup. Switching location fixes it.
- **Surfshark's own kill switch** (in its app) blocks the whole PC when the VPN drops. `REQUIRE_VPN=1`
  only protects the VM, and works with any VPN client.
