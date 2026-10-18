# FastGlance

A macOS menu bar app that shows every device connected to your Mac — wired and wireless — remembers the ones that were ever connected, and puts quick actions one click away.

## Features

- **Devices:** Bluetooth (headphones, speakers, mice, keyboards, game controllers, phones), USB, external disks, audio inputs/outputs, displays, printers (CUPS), and devices on the local network (Bonjour + ARP scan). Offline devices stay listed under *Recently Seen*.
- **Quick actions:** *Play Here* (connect headphones and route audio in one click), connect/disconnect, use as output/input, mute, eject / eject all, global mic mute, make main display, mirroring, open a network device's web UI / SMB share / SSH / Screen Sharing, ping, Wake-on-LAN for sleeping devices, print a test page, cancel print jobs, and more. Pin any action to the top of the menu.
- **Controls:** volume and input level, sample rate, display brightness and resolution — inline in the menu or in the device window.
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

- Not sandboxed; needs Bluetooth and notification permission on first launch.
- Battery levels come from `system_profiler` (public, refreshed every minute).
- Built-in/Apple display brightness uses the private DisplayServices framework, loaded dynamically (`FastGlance/Private`). If a macOS update removes it, the slider just disappears.
- Network scan: one UDP datagram to each address in your subnet (capped at /22) fills the ARP table; nothing leaves the LAN. ARP entries linger ~20 minutes, so a device that just left can still look online for a while. Turn scanning off in Settings to rely on Bonjour only.
- Device history lives in `~/Library/Application Support/FastGlance/history.json`.
