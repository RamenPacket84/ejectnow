# EjectNow

A macOS menu-bar app that lists ejectable volumes, ejects them via Disk Arbitration, and helps when a volume is busy by showing which processes are blocking it.

## Requirements

- macOS 13 or later
- Xcode 15+ (to build from source)

## Features

- Menu-bar only (no Dock icon)
- Live list of removable / `/Volumes` mounts (excludes the boot volume and network shares)
- **Eject** and **Force Eject…** per volume
- **Show Blockers…** — uses `lsof` to list processes with open files on the volume
- **Kill & Eject** — terminates same-user blocker processes, then retries eject

## Build & run

1. Open `ejectnow.xcodeproj` in Xcode
2. Select the **ejectnow** scheme
3. Run (⌘R)

Look for the USB-drive icon in the menu bar.

## Notes

- This is a non-sandboxed, open-source tool (not distributed via the Mac App Store).
- Killing processes owned by other users / root will need a privileged helper (not included yet).
- Force eject can cause data loss if apps are still writing to the volume.

## License

MIT — see [LICENSE](LICENSE).
