# rpi-self-update

Tools for building a Raspberry Pi initramfs that can re-flash the same Pi
it is currently running on, or be booted on a different Pi over `rpiboot`.

There are three executables, layered on top of each other:

| Tool | Layer | What it does |
|------|-------|--------------|
| `rpi-initramfs`        | low    | Builds a busybox-based initramfs and either deploys it to the local `/boot/firmware` via Pi tryboot, or assembles a `rpiboot`-compatible directory. |
| `rpi-self-update`      | middle | Builds on `rpi-initramfs` by adding a fixed payload (`flash.sh` + `preserve-*.sh` + a `selfupdate.conf` + a cloud-init directory) that downloads an OS image, writes it to a target block device, and verifies it. |
| `rpi-self-update-cli`  | top    | Builds on `rpi-self-update` by pulling the official Raspberry Pi image catalogue, asking the user what to install, and generating the cloud-init for them (preserving user, password hash, SSH authorized keys, SSH host keys, Pi Connect state, WiFi). |

Each tool can be used on its own. Pick the layer that matches how much
you want to drive yourself.

## How a flash works

The Raspberry Pi bootloader supports **tryboot** — a one-shot boot where
the firmware loads `tryboot.txt` instead of `config.txt`. If anything
goes wrong, a hard reboot or power cycle automatically falls back to the
normal `config.txt`, so the original system is never at risk.

All three tools use tryboot to load a custom initramfs that can manipulate
the very disk it booted from:

1. Build a busybox initramfs containing the tools, drivers and payload
   needed to bring up the network, SSH in, and write a new image.
2. Drop `initramfs-tryboot.gz` + `tryboot.txt` + `cmdline-tryboot.txt`
   into `/boot/firmware`.
3. `reboot "0 tryboot"`.
4. The Pi boots the initramfs, runs the payload, then reboots — which
   either lands on the newly-flashed image (success) or on the original
   system (failure or power cycle).

The boot partition is unmounted before flashing in the self-update case
so the running OS isn't reading from the disk it's about to overwrite.

---

## Installation

Build the Debian package and install it on a Pi:

```sh
dpkg-buildpackage -us -uc -b
sudo apt install ./rpi-self-update_*.deb
```

Or download a pre-built `.deb` from the
[GitHub Releases page](../../releases) and `sudo apt install ./<file>.deb`.

### Cutting a release

Releases are built by the `Build .deb` GitHub Actions workflow on a tag
push:

1. Bump `debian/changelog` with a new entry (`X.Y.Z-1`).
2. Commit.
3. `git tag vX.Y.Z && git push origin vX.Y.Z`.

The workflow runs on a native arm64 runner, verifies the tag matches
`debian/changelog`, builds the `.deb`, and attaches it to a freshly
created GitHub Release with auto-generated notes.

Runtime dependencies (pulled in by the `.deb`):
`busybox-static`, `dropbear-bin`, `wpasupplicant`, `iw`, `firmware-brcm80211`,
`e2fsprogs`, `fdisk`, `ca-certificates`, `util-linux`, `jq`, `curl`.

The package installs:

- `/usr/sbin/rpi-initramfs`, `/usr/sbin/rpi-self-update`, `/usr/sbin/rpi-self-update-cli`
- `/usr/share/rpi-self-update/initramfs/` — the init script and helpers
- `/usr/share/rpi-self-update/payload/` — `flash.sh`, `preserve-home.sh`, `preserve-ssh.sh`, `initramfs-run`

All three commands must be run as root.

---

## `rpi-initramfs` — build a custom initramfs

The lowest layer. Builds a self-contained busybox initramfs with
networking, SSH (via dropbear), WiFi (wpa_supplicant + brcmfmac
firmware), and any payload files / extra binaries you ask for. Useful on
its own when you want to drop a Pi into a recovery shell, run your own
flashing payload, or test something against the bare hardware.

### Tryboot mode (default)

```sh
sudo rpi-initramfs [--add-file PATH]... [--add-binary PATH]... [--add-module NAME]... [-y]
```

Deploys to `/boot/firmware/initramfs-tryboot.gz` and reboots into
tryboot. `config.txt` is **not** modified — recovery is a hard reboot.

| Flag | Meaning |
|------|---------|
| `--add-file PATH`    | File or directory to copy into `/payload/` inside the initramfs (by basename). Repeat as needed. |
| `--add-binary PATH`  | Host binary to install alongside its shared libraries (resolved via `ldd`). Repeat as needed. |
| `--add-module NAME`  | Extra kernel module to include beyond the WiFi defaults (e.g. `nvme`, `hid-logitech`). |
| `--wifi-ssid SSID`   | WiFi SSID to use if Ethernet has no carrier in the initramfs. Without this, a WiFi-only Pi rebooted into a bare initramfs comes up with no network. |
| `--wifi-psk PSK`     | Plain-text PSK; hashed with `wpa_passphrase` before being written into the initramfs. |
| `--dry-run`          | Build but only show what would be deployed. |
| `-y`, `--yes`        | Skip the confirmation prompt and reboot immediately. |

If no `--add-file` is given, there is **no** entry point and the
initramfs drops to a shell on boot, with SSH (dropbear) available using
your existing `authorized_keys` and the current user's `/etc/shadow`
password hash. Useful as a "rescue mode":

```sh
sudo rpi-initramfs        # builds with no payload, prompts, then reboots into a shell-only initramfs
```

If you do provide a payload, the file named `initramfs-run` (if present)
is sourced by `/init` once the boot partition is mounted. Inside it you
have access to:

- `BOOT_DEV` — the device the boot partition was mounted from
- `PAYLOAD_DIR` — `/payload`
- `restore_boot` — remove the tryboot files so the next reboot is normal
- `start_network_and_ssh` — bring up the network (Ethernet first, then
  WiFi if `WIFI_SSID` is set) and start dropbear
- `drop_to_shell` — leave the user in a busybox shell on the console

A `restore` command is also installed at `/sbin/restore` for the user to
type from any shell once they're in.

### Usbboot mode

```sh
sudo rpi-initramfs --usbboot /tmp/usbboot-dir [--add-file PATH]... [--add-binary PATH]...
```

Instead of deploying to the local `/boot/firmware`, assembles a directory
suitable for `rpiboot -d`. Includes GPU firmware, kernels, device-tree
blobs and overlays for **every** 64-bit-capable Pi (Pi 3/4/5, CM3/4/5,
Zero 2). USB gadget serial modules (`libcomposite`, `g_serial`) are
included for both the v8 and 2712 kernels, and the boot config enables
the dwc2 USB gadget so you get a serial console on `/dev/ttyGS0` on the
booted Pi.

Then boot a Pi over USB:

```sh
rpiboot -d /tmp/usbboot-dir
```

### What the initramfs always contains

Beyond `--add-file` / `--add-binary`:

- Static busybox + the applets needed for setup, networking, flashing
  and filesystem work.
- A default set of WiFi kernel modules (`brcmfmac`, `brcmutil`,
  `cfg80211`, `mac80211` plus transitive deps), loaded multi-pass in
  `/init` so dependencies resolve without modprobe. Use `--add-module`
  to include others (e.g. `nvme` if your target storage isn't built
  into the kernel, `hid-logitech` for USB keyboard support in the
  recovery shell).
- `dropbear` and `dropbearkey`, with your current `authorized_keys`
  copied in and your shadow password hash carried across so password
  login works.
- The host's existing OpenSSH host keys converted to dropbear format, so
  the initramfs SSH listener has the same fingerprint as the running system.
- `wpa_supplicant`, `iw`, `wpa_passphrase`, and `/lib/firmware/brcm/brcmfmac*`
  plus the regulatory database — enough to bring up WiFi.
- `/etc/ssl/certs/ca-certificates.crt` and `/etc/mke2fs.conf` from the host.
- The framebuffer is bound to vtcon0 so the keyboard and display work on
  the console.

---

## `rpi-self-update` — scripted flash

Builds on `rpi-initramfs` by always shipping a fixed payload that
downloads an OS image and writes it to a target block device. Use this
when you want to drive the flash from a script, or when you want to
flash a *different* disk (e.g. an attached USB drive) rather than the
running system.

```sh
sudo rpi-self-update \
  --url      https://downloads.raspberrypi.com/.../rpi-os.img.xz \
  --device   /dev/nvme0n1 \
  --cloudinit ./my-cloudinit/
```

### Required arguments

| Flag | Meaning |
|------|---------|
| `--url URL`         | HTTPS/HTTP URL of the image. `.xz` archives are decompressed in-line. |
| `--device DEV`      | Whole-disk block device to write to. If it equals the running boot disk, **self-update** mode kicks in: boot is unmounted, `/home` and `/etc/ssh` keys can be preserved across the flash, and the new boot partition is re-mounted afterwards to install cloud-init. |
| `--cloudinit DIR`   | Directory containing at least `user-data`. `meta-data`, `network-config` and `cmdline-append` are optional — `cmdline-append` is auto-generated as `ds=nocloud;i=selfupdate-<timestamp>` if you don't provide one. |

### Optional arguments

| Flag | Meaning |
|------|---------|
| `--sha256 HASH`     | Expected SHA256 of the *extracted* image. Verified after writing by reading the disk back. |
| `--image-size N`    | Exact byte count of the extracted image. Required alongside `--sha256` so the verifier reads back the right number of bytes. |
| `--image-name NAME` | Human-readable label, shown in logs and the summary. |
| `--no-verify`       | Skip SHA256 verification (and clear any `--sha256` / `--image-size`). |
| `--preserve-home`   | Self-update only. Tars `/home` to tmpfs before flashing, restores it onto the new rootfs (after expanding p2 to fill the disk). Aborts the flash if `/home` is too big to fit in RAM. |
| `--preserve-ssh`    | Self-update only. Backs up `/etc/ssh/ssh_host_*_key{,.pub}` to tmpfs and restores them onto the new rootfs, so existing SSH clients don't get host-key-mismatch warnings after the flash. |
| `--wifi-ssid SSID`  | WiFi SSID to use as a fallback inside the initramfs if Ethernet has no carrier. |
| `--wifi-psk PSK`    | Plain-text PSK; hashed with `wpa_passphrase` before being embedded, so the plaintext never lands on the vfat boot partition. |
| `-y`, `--yes`       | Skip the final confirmation and reboot into tryboot immediately. |

### Example: flash a USB drive without touching the running system

```sh
sudo rpi-self-update \
  --url     https://downloads.raspberrypi.com/.../rpi-os.img.xz \
  --device  /dev/sda \
  --sha256  3a7f...  \
  --image-size 5368709120 \
  --image-name "Raspberry Pi OS Lite" \
  --cloudinit /etc/my-pi-cloudinit \
  -y
```

### Example: scripted self-update of the running Pi

```sh
sudo rpi-self-update \
  --url      https://downloads.raspberrypi.com/.../rpi-os.img.xz \
  --device   /dev/mmcblk0 \
  --cloudinit /etc/my-pi-cloudinit \
  --preserve-home --preserve-ssh \
  --wifi-ssid 'HomeNet' --wifi-psk 'correcthorse' \
  -y
```

---

## `rpi-self-update-cli` — interactive

Builds on `rpi-self-update` by handling the image catalogue lookup and
cloud-init generation for you. The simplest way to re-flash a Pi.

```sh
sudo rpi-self-update-cli
```

What it does, in order:

1. Auto-detects the boot disk (`/dev/mmcblk0`, `/dev/nvme0n1`, etc.).
2. Downloads the image catalogue from
   `downloads.raspberrypi.com/os_list_imagingutility_v4.json`, filters
   for `pi5-64bit` images, and prints a numbered menu.
3. Asks whether to preserve `/home` (and refuses up front if the home
   directory wouldn't fit in tmpfs during the flash).
4. Detects an active WiFi connection via NetworkManager and reads the
   stored PSK; if it can't, prompts for one. The hashed PSK is embedded
   into the initramfs so the flashed system stays online if the Ethernet
   cable is unplugged in the recovery environment.
5. Builds a cloud-init payload for the new image carrying over:
   - the current hostname
   - the current username + the password hash from `/etc/shadow`
   - the user's `~/.ssh/authorized_keys`
   - the existing SSH host keys (so SSH clients don't see a key change)
   - Raspberry Pi Connect state if `~/.config/com.raspberrypi.connect/state.json` exists
   - WiFi creds in `network-config` so the freshly flashed system reconnects.
6. Hands everything to `rpi-self-update`.
7. Prompts for final confirmation, then reboots into tryboot.

After the reboot the new image runs cloud-init on first boot and you can
SSH back in using the same key, username and host fingerprint.

---

## What gets preserved across a self-update flash

The flash overwrites the entire target disk with a fresh image, so by
default nothing of the old install survives. To work around that, the
self-update flow optionally backs things up into tmpfs (RAM) before the
flash and restores them afterwards:

| Option | What is backed up | Mechanism |
|--------|-------------------|-----------|
| `--preserve-home` | `/home` (everything under it) | Tarball in `/tmp`, restored after the new rootfs is resized to fill the disk and `e2fsck`'d. Aborts the flash up front if it wouldn't fit in tmpfs. |
| `--preserve-ssh`  | `/etc/ssh/ssh_host_*_key` and the matching `.pub` files | Tarball in `/tmp`, overlaid onto the new image's `/etc/ssh`. Only host keys — `sshd_config` and `authorized_keys` are intentionally not touched. |

When you use `rpi-self-update-cli`, the cloud-init it builds *also*
carries forward the user account, password, authorized keys and host
keys via the user-data file — so even without `--preserve-home` you keep
SSH access and the same login. Pi Connect state is preserved the same way.

---

## Recovery and debugging

- **Tryboot is one-shot.** If anything goes wrong before the new image is
  flashed, a hard reboot or power cycle returns you to the original system.
- From inside the initramfs shell, type `restore` to delete the tryboot
  files and reboot back to normal.
- The initramfs logs everything to `/tmp/selfupdate.log`, including a
  `dmesg` snapshot after module load and another just before the log is
  persisted to disk — so WiFi-firmware and module-load failures are
  always captured. On network failure the log is copied to
  `/boot/selfupdate-failure.log` before rebooting. On success it is
  copied to `/boot/selfupdate-flash.log` on the *new* boot partition.
- The initramfs runs dropbear on port 22 once the network is up. The IP
  is printed to the console; SSH in as `root` using either your existing
  key or your existing password.
- After a network failure the initramfs waits 30 seconds before
  auto-rebooting. Touch `/tmp/hold` from an SSH session to cancel the
  auto-reboot and stay in the shell.

---

## Repo layout

```
rpi-initramfs            # initramfs builder (top-level layer)
rpi-self-update          # flash orchestrator (middle layer)
rpi-self-update-cli      # interactive wrapper (top layer)

initramfs/
  init                   # PID 1 — runs inside the initramfs
  scripts/
    network.sh           # Ethernet-first, WiFi-fallback bring-up
    udhcpc.script        # busybox DHCP callback
    restore              # /sbin/restore inside the initramfs

payload/
  initramfs-run          # entry point sourced by /init when MODE=flash
  flash.sh               # download + dd + verify
  preserve-home.sh       # tar /home to tmpfs, restore after flash
  preserve-ssh.sh        # tar /etc/ssh host keys to tmpfs, restore after flash

debian/                  # Debian packaging
```
