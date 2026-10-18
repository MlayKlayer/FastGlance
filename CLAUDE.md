# FastGlance

macOS menu bar app (Swift/SwiftUI + AppKit, macOS 14+, Apple Silicon) that lists devices connected to the Mac — wired, wireless and on the LAN — remembers past ones, and offers quick actions. UI language: English.

**Start of a session:** read `HANDOFF.md` (if present) for current state and next steps. **End of a session:** run `/handoff`.

## Build, test, run

```sh
xcodegen generate -q   # after adding/removing any source file — new files aren't in the project until then
xcodebuild -project FastGlance.xcodeproj -scheme FastGlance -derivedDataPath build test
rm -rf ~/Applications/FastGlance.app && cp -R build/Build/Products/Debug/FastGlance.app ~/Applications/ && open ~/Applications/FastGlance.app
```

- Run from `~/Applications`, not `build/` — launch-at-login (SMAppService) registers the path.
- `.xcodeproj` is generated and gitignored; edit `project.yml` (Info.plist keys, Bonjour types, signing).
- Signing: ad-hoc by default, no developer account required. For a stable development identity, pass `CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="YOUR_TEAM_ID"` to xcodebuild. Never commit signing credentials. See `docs/RELEASING.md` for distribution.
- Swift 5 language mode on purpose: C callbacks (IOKit, CoreAudio, Carbon) fight Swift 6 strict concurrency. Sources are `@MainActor`; callbacks hop with `MainActor.assumeIsolated` on the main run loop.

## Architecture

- `Model.swift` — `Device`, `DeviceKind`, `DeviceAction` (id `"<deviceID>|<key>"`, pinnable), `DeviceControl`, `DeviceSource` protocol.
- `Hub.swift` — merges sources + `DeviceHistory`, pins (resolved by slot), `Prefs` keys and defaults.
- `Sources/` — one file per source: Internet, Bluetooth (+ Gamepads), Audio, USB (+ USBDoctor), Disks, Displays, Cameras, Printers, Network.
- `Private/` — private APIs, loaded with `dlopen`/`dlsym`, degrade to "unavailable": DisplayServices brightness, IOAVService DDC.
- `LidGuard.swift` — unmount disks before lid-close sleep, remount on wake. `Hotkeys.swift` — Carbon hot keys ⌃⌥1–9, ⌃⌥M.
- History: `~/Library/Application Support/FastGlance/history.json` (device ID, system name, kind, last connected, optional nickname and hidden state).

## Rules of thumb

- Device ids must be stable across launches and permissions (e.g. Internet row keyed by gateway MAC, not SSID) — an id change creates a duplicate in history.
- Pinnable actions keep the same key in every device state; flip the title instead of swapping actions.
- Never force-unmount; pass `.withoutUI`. Never veto system sleep; cap waits at 10 s.
- Prefer public APIs and command-line tools (`system_profiler`, `lpstat`, `ipptool`, `arp`, `diskutil`) over private frameworks.
- Each non-trivial parser/decision gets one small XCTest in `FastGlanceTests/`.

## Gotchas found so far

- `USBSpeed` uses XHCI numbering (1 full, 2 low, 3 high, 4 5G, 5 10G, 6 20G); `USBDoctor.speed` normalises it. bcdUSB 0x0210 at high speed = USB 3 device on a USB 2 link.
- DDC read request checksum seeds with 0x6E only and reads at offset 0; writes seed 0x6E^0x51 at offset 0x51 (MonitorControl's layout). Unverified on real monitors.
- Paired Bluetooth `recentAccessDate()` is touched by our own queries — useless as "last seen".
- Continuity "iPhone Camera" comes and goes; cameras are muted in notifications by default.
- Wi-Fi SSID needs Location permission on macOS 14+. Personal Hotspot = Wi-Fi path with `isExpensive`.
- The computer-use tool can't see LSUIElement apps and `osascript` has no Accessibility. To look at the UI, render views offscreen in a throwaway XCTest (`NSHostingView` → `cacheDisplay` → PNG, light appearance, white background), read the PNG, delete the test.
