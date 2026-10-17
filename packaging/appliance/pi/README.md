# Skotiq Raspberry Pi appliance image

Builds a flashable Raspberry Pi OS Lite (arm64) image with the Skotiq
headless server pre-installed: boot the Pi at the telescope, pair from the
mobile app, image all night. No keyboard, monitor, or SSH session required.

## What ends up on the image

| Piece | Path on the Pi | Source |
|---|---|---|
| App bundle (arm64) | `/opt/skotiq/bundle/` | your release tarball |
| Hardened systemd unit | `/etc/systemd/system/skotiq-headless.service` | `../systemd/skotiq-headless.service` (shared with bare-metal installs) |
| Config + generated auth token | `/etc/skotiq/headless.env` | `../systemd/headless.env.example` |
| Astronomy USB permissions | `/etc/udev/rules.d/99-skotiq-astro.rules` | `../systemd/99-skotiq-astro.rules` |
| Service user (created at first boot) | `sysusers.d/skotiq.conf` | declarative — no chroot `useradd` needed |
| First-boot setup (installs xvfb/xauth if not baked in) | `skotiq-firstboot.{sh,service}` | `firstboot/` |
| Wi-Fi hotspot fallback provisioning | `skotiq-netprovision.{sh,service}`, `provision_portal.py` | `provisioning/` |
| Captive-DNS for the hotspot | `/etc/NetworkManager/dnsmasq-shared.d/skotiq-captive.conf` | written by the build script |

## Prerequisites on the build box (Arch / CachyOS)

```sh
sudo pacman -S --needed util-linux parted e2fsprogs dosfstools xz coreutils binutils rsync openssl
# Optional — lets the build bake xvfb into the image via an arm64 chroot,
# so first boot needs no internet:
sudo pacman -S --needed qemu-user-static qemu-user-static-binfmt
```

Plus:

1. **Base image** — Raspberry Pi OS **Lite, 64-bit (Bookworm)** from
   <https://www.raspberrypi.com/software/operating-systems/>. Bookworm is
   required: the provisioning flow drives **NetworkManager**, which is the
   default network stack from Bookworm on.
2. **An arm64 release bundle tarball** — see the next section. Flutter Linux
   desktop builds are host-architecture builds, so produce this on an arm64
   host or in an arm64 container/emulated environment.

## Getting the arm64 bundle (the honest part)

`scripts/docker_build_linux.sh` is the canonical Linux release pipeline
(rust `cargo build --release` → `melos bootstrap` → `flutter build linux
--release` → smoke test under xvfb → tarball). It detects the host
architecture and emits `skotiq-linux-x64-<version>.tar.gz` or
`skotiq-linux-arm64-<version>.tar.gz`. Flutter does not cross-compile
Linux desktop targets, so two real options remain:

* **On an arm64 host** (Pi 4/5 with 8 GB and swap, or any arm64 VM/CI
  runner) run the standard flow:

  ```sh
  docker run --rm -v "$PWD":/host:ro -v "$PWD/dist-linux":/out \
    ghcr.io/cirruslabs/flutter:stable bash /host/scripts/docker_build_linux.sh
  ```

  On arm64 the Flutter bundle lands in `build/linux/arm64/release/bundle`
  and the tarball lands in `dist-linux/skotiq-linux-arm64-4.0.0.tar.gz`
  unless `SKOTIQ_VERSION` or `SKOTIQ_ARTIFACT_NAME` overrides it.
  If you have redistributable arm64 vendor SDK `.so` files, place them in a
  staging directory and set `SKOTIQ_VENDOR_LIB_DIR=/path/to/vendor-libs`
  before running the build. The release script copies matching `.so`/`.so.*`
  files into `bundle/lib`, which the native SDK loaders search before system
  library paths.

* **Emulated on this box**: install `qemu-user-static{,-binfmt}` and add
  `--platform linux/arm64` to the same `docker run`. This works but takes
  hours (AOT compile + Rust release build under qemu).

`build_pi_image.sh` **verifies the ELF architecture** of
`skotiq_desktop` in the tarball and refuses an x86_64 bundle unless you
pass `--allow-arch-mismatch` (only useful to dry-run the image plumbing).

## Building the image

```sh
sudo ./build_pi_image.sh \
  --base-image     ~/Downloads/2025-05-13-raspios-bookworm-arm64-lite.img.xz \
  --bundle-tarball ./skotiq-linux-arm64-4.0.0.tar.gz \
  --out            ./skotiq-pi-arm64.img \
  --hostname       skotiq \
  --wifi-country   US \
  --enable-ssh --user pi --password 'change-me'
```

Notes:

* Run as root (loopback mounts). The script grows the rootfs by
  `--grow-mb` (default 2048) to fit the bundle; RPi OS still auto-expands
  to fill the whole SD card on first boot.
* The generated **auth token is printed at the end of the build** and
  stored in `/etc/skotiq/headless.env` on the image. The mobile app's
  pairing flow doesn't need it (pairing codes print to the journal because
  `SKOTIQ_PAIRING_PRINT_CODES=true`), but API/cURL access does.
* `--wifi-country` is strongly recommended — without a regulatory domain
  some kernels refuse to start the fallback **hotspot**.
* `--user/--password` writes `userconf.txt`; without it the appliance
  still runs (services are unaffected by the first-run user wizard) but
  you have no SSH/console account for debugging.
* If qemu binfmt is available, xvfb/xauth is baked in during the build;
  otherwise the **first boot needs internet once** to
  `apt install xvfb xauth` (the daemon is ordered after that step, so it
  simply starts a few minutes later on the very first boot).
* The image installs baseline udev rules for common astronomy USB devices
  (ZWO, QHY, Player One, ToupTek/Ogma-style cameras, Atik, and common
  USB-serial mount adapters). They grant `0660` access to the `skotiq`
  group plus logind `uaccess`, not world-writable `0666` permissions. Vendor
  packages may still be required for firmware loaders or device-specific SDKs.
* Native SDK libraries are not auto-extracted from `SDKs/` during image
  creation. Bundle redistributable arm64 `.so` files at Linux build time with
  `SKOTIQ_VENDOR_LIB_DIR`, or install vendor packages on the Pi and record
  that dependency in your release notes.

Flash with `rpi-imager`, balenaEtcher, or:

```sh
sudo dd if=skotiq-pi-arm64.img of=/dev/sdX bs=4M conv=fsync status=progress
```

## First boot, from the user's couch

1. Power the Pi. If Ethernet is plugged in or a known Wi-Fi profile
   exists, it's online within a minute — skip to step 4.
2. No network after ~90 s → the Pi raises a WPA2 hotspot
   **`Skotiq-XXXX`** (password **`skotiq`**, XXXX = last 4 of the
   Wi-Fi MAC).
3. Join it with your phone. The captive sheet pops automatically (wildcard
   DNS → portal); if not, browse to **http://10.42.0.1**. Pick your home
   Wi-Fi, enter the password, submit. The hotspot drops, the Pi joins your
   network (on a wrong password the hotspot returns within a minute with
   an error banner — just retry).
4. Open the Skotiq mobile app: the appliance is advertised as
   `_skotiq._tcp` over mDNS (via avahi-daemon, from the static service
   file at `/etc/avahi/services/skotiq.service` — the in-app `nsd` mDNS
   path has no Linux implementation, so the image ships this instead) and over
   UDP beacons on 45679, so it appears in discovery. Pair; the pairing code
   prints to the Pi's journal
   (`journalctl -u skotiq-headless`) and on accessory-less setups the
   in-app pairing flow handles it.

## Day-2 operations

* Logs: `journalctl -fu skotiq-headless`
* Config: `/etc/skotiq/headless.env` (TLS, OTA server, scoped tokens,
  push config path — see comments in the file), then
  `systemctl restart skotiq-headless`.
* Updates: set `SKOTIQ_UPDATE_SERVER` (+ optional
  `SKOTIQ_UPDATE_CHANNEL`) in the env file to enable the OTA endpoints
  (`/api/system/update/*`) that the mobile app drives; or re-run the
  bare-metal `../systemd/install.sh --tarball <new>.tar.gz` over SSH.
* Re-provision Wi-Fi (moved house / new router): the fallback hotspot
  comes back automatically whenever no known network connects within 90 s
  of boot. To force it: `nmcli connection delete <old-ssid>` and reboot.

## Verification status (what was actually tested)

* `bash -n` on all shell scripts and `python3 -m py_compile` on the portal
  pass on this machine; `systemd-analyze verify` was run against the
  units where the local systemd allows it.
* The **full image build and on-Pi boot were not exercised here** — this
  workstation has no base image, no arm64 bundle, and image building
  requires root loop devices. The script is written to fail loudly at
  every step (arch check, missing tools, partition surgery), so a first
  real run will surface problems instead of producing a silently broken
  image. Treat the first build as a validation run.
