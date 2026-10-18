# Contributing

Bug reports, focused fixes and hardware compatibility reports are welcome. Check existing issues before opening a new one. For a substantial feature, open an issue describing the task it helps with before writing a large change.

## Build and test

Follow the requirements and build instructions in [README.md](README.md). The default ad-hoc build requires no Apple Developer account. Run `xcodegen generate -q` after adding or removing files, then run the test command from the README.

Keep Swift 5 language mode: the IOKit, CoreAudio and Carbon callback integrations currently rely on it. Keep device identifiers and pinnable action keys stable. Prefer public APIs; private APIs belong in `FastGlance/Private` and must fail gracefully. Never force-unmount disks or veto system sleep.

Add a small XCTest for non-trivial parsing or decision logic. For a hardware change, include the device model, connection path (including docks), macOS version and actual result. State explicitly when behavior was reviewed in code but not tried on hardware.

Tests run inside an app host. Do not mutate the real user's history, pins, permissions or other preferences in tests; use temporary files and synthetic data. Do not commit offscreen-render scratch tests, generated projects, build output or local session notes.

## Pull requests

Explain the problem, the resulting behavior and how you checked it. Keep unrelated cleanup separate. Avoid adding dependencies for small tasks that native APIs can handle.

## Privacy

Use fictional device names and addresses in examples. Remove serial numbers, MAC/IP addresses, Wi-Fi names and personal paths from screenshots or logs. Do not post credentials, signing material or device history. Use the private reporting route in [SECURITY.md](SECURITY.md) for vulnerabilities.
