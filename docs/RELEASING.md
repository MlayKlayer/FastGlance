# Release preparation

The repository currently provides source builds. CI verifies compilation and unit tests; its test-results artifact is not an installer. Do not advertise an ad-hoc or Apple Development build as a notarized public release.

## Before tagging

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, regenerate the project, and run the README test command from a clean checkout.
2. Review the current limitations and test actual hardware: Bluetooth connect/Play Here, all microphone inputs and mute indication, busy-disk eject and lid-close sleep/wake, two external displays and DDC, camera permission/preview, printers, controller features, search keyboard navigation, pin reorder, nickname persistence and login startup.
3. Check tracked files and commit history for credentials, signing material, personal device data and generated output. Keep the MIT license in source and distribution packages.
4. Write release notes with concrete changes and unresolved limitations. Use a prerelease while hardware validation remains incomplete.

## Public macOS binaries

Public binary distribution needs its own signing and notarization work. Follow Apple's [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

- Use your **Developer ID Application** identity, rather than an Apple Development certificate. Keep credentials in the keychain or protected CI secrets.
- Enable and validate Hardened Runtime for the release build. It is currently disabled in `project.yml`; changing it requires testing the camera permission flow and every private-API feature. Add only entitlements demonstrated to be necessary.
- Build a Release configuration, verify its signature and runtime behavior, then package the application as a ZIP or DMG with standard macOS tools.
- Submit the package using `xcrun notarytool`, inspect the result, and staple the accepted ticket to the supported bundle/container. Repackage if necessary, then validate the final download with `codesign`, `stapler` and Gatekeeper on a separate Mac or fresh account.
- Publish a checksum and install instructions alongside the verified asset. Keep signing details and unpublished credentials out of logs and release notes.

Example Release build with signing overrides (after choosing the required entitlements and reviewing the signing setup):

```sh
xcodegen generate -q
xcodebuild -project FastGlance.xcodeproj -scheme FastGlance \
  -configuration Release -derivedDataPath build \
  DEVELOPMENT_TEAM="YOUR_TEAM_ID" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  ENABLE_HARDENED_RUNTIME=YES build
```

This command alone does not notarize the app or establish that it is ready for distribution. Do not ask users to disable Gatekeeper globally.
