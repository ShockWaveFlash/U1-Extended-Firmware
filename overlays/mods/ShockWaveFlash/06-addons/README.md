# Mod overlay: Add-ons (Spoolman + Git)

Adds an **Add-ons** settings group to the firmware-config web UI
(`http://<printer-ip>/firmware-config/`, requires Advanced Mode) with
Installed / Not Installed toggles for optional software that is intentionally
not baked into the image. Each toggle runs an idempotent on-device install
recipe (both support `--uninstall`), output streamed to the browser.

| Add-on | Effect |
|---|---|
| Spoolman | Filament spool tracking (Donkie/Spoolman v0.26.0, SQLite). Web UI + API on port 7912, wired into Moonraker (`[spoolman]`) so Fluidd/Mainsail get the spool picker. DB lives in `printer_data` and survives uninstall + firmware upgrades. |
| Git | Working `git` binary (aarch64, from Debian's official arm64 `.deb`) plus the `libcurl-gnutls.so.4` ABI shim its HTTPS remote helper needs. |

Both recipes hard-require **Overlay Persistence** (`/oem/.debug`), so this
overlay also adds a **Settings > System > Overlay Persistence** toggle. Without
it, everything written to the root overlay (`/etc`, `/usr/local`, ...) is wiped
on the next reboot.

`S65spoolman-boot` ships in the squashfs (so it is in the frozen boot glob) and
starts the overlay-installed Spoolman service at boot — overlay-only init
scripts are otherwise invisible to the boot glob (frozen from the read-only
squashfs before the overlay pivot).

HelixScreen is **not** part of this overlay: it is provided upstream by
`firmware-extended/69-app-helixscreen` (paxx12 PR #590), the maintained
integration, selectable under **Snapmaker Components > Touchscreen GUI**.

## Attribution

The Spoolman and Git install recipes, the `S65spoolman-boot` delegate and the
Add-ons / Overlay-Persistence firmware-config settings are adapted from
[St0rmingBr4in's add-on-installers mod (PR #568)](https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware/pull/568),
trimmed to Spoolman + Git (HelixScreen dropped in favour of the upstream #590
integration).
