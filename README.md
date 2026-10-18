# FastGlance

A macOS menu bar app that shows every device connected to your Mac — wired and wireless — remembers the ones that were ever connected, and puts quick actions one click away.

## Features

- **Internet:** what you're online through — Wi-Fi (name, signal, band, link rate, security), Ethernet, or your iPhone's Personal Hotspot with data used this session.
- **USB doctor:** shows the real link speed of every USB device and external drive and explains slow ones ("supports USB 3 but runs at USB 2 — likely a charging cable", "behind a USB 2 hub").
- **Lid-close safety:** external disks are safely unmounted (never forced) before the Mac sleeps from closing the lid, and mount again on wake if still plugged in.
- **Brightness sync:** external monitors follow the built-in display, including auto-brightness, with a per-monitor offset.
- **Devices:** Bluetooth (headphones, speakers, mice, keyboards, game controllers, phones), USB, external disks, audio inputs/outputs, displays (with DDC for external monitors), cameras (shows when an app is using one), printers (CUPS), and devices on the local network (Bonjour + ARP scan). Offline devices stay listed under *Recently Seen*.
- **Quick actions:** *Play Here* (connect headphones and route audio in one click), connect/disconnect, use as output/input, mute, eject / eject all, global mic mute, make main display, mirroring, open a network device's web UI / SMB share / SSH / Screen Sharing, ping, Wake-on-LAN for sleeping devices, print a test page, cancel print jobs, and more. Pin any action to the top of the menu.
- **Controls:** volume and input level, sample rate, display brightness and resolution; external monitor brightness, contrast, speaker volume and input source over DDC; DualSense light color and vibration test; live camera preview — inline in the menu or in the device window.
- **Keyboard shortcuts:** ⌃⌥1…⌃⌥9 run pinned actions in order, ⌃⌥M mutes the microphone (can be turned off in Settings).
- **Icon:** quiet glyph; optional battery % next to it; orange dot = low battery, red dot = microphone muted. Option-click runs your first pin, right-click opens a small menu.
- **Notifications** for connect/disconnect (per device type) and low battery.

## Build

Requires Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project FastGlance.xcodeproj -scheme FastGlance -derivedDataPath build build
# install where launch-at-login can find it after rebuilds
rm -rf ~/Applications/FastGlance.app && cp -R build/Build/Products/Debug/FastGlance.app ~/Applications/
open ~/Applications/FastGlance.app
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your own team ID (the `OU` of your Apple Development certificate).

## Notes

- Not sandboxed; asks for Bluetooth, notifications, local network and location on first launch. Location is only how macOS gates Wi-Fi network names; FastGlance never reads where you are.
- Battery levels come from `system_profiler` (public, refreshed every minute).
- Built-in/Apple display brightness uses the private DisplayServices framework, loaded dynamically (`FastGlance/Private`). If a macOS update removes it, the slider just disappears.
- Network scan: one UDP datagram to each address in your subnet (capped at /22) fills the ARP table; nothing leaves the LAN. ARP entries linger ~20 minutes, so a device that just left can still look online for a while. Turn scanning off in Settings to rely on Bonjour only.
- DDC uses the private IOAVService API (Apple Silicon, `FastGlance/Private/DDC.swift`). With several external monitors they're paired with AV services by order; Apple displays use DisplayServices instead. Input codes vary by vendor (USB-C especially).
- Device history lives in `~/Library/Application Support/FastGlance/history.json`.
