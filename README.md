# Wink

A small, free native macOS menu bar app to disconnect and reconnect external monitors while their cables stay plugged in. Built for Apple silicon and macOS 13 or newer; hardware support depends on macOS and the monitor connection.

## Install

Requires macOS 13+ on Apple silicon. Releases are signed with a Developer ID and notarized by Apple.

```sh
brew install --cask xinding33/tap/wink
```

Or download `Wink-x.y.z.zip` from the [latest release](https://github.com/xinding33/wink/releases/latest), unzip it, and move `Wink.app` to Applications.

Open Wink, then choose **Open at Login** from its menu bar icon. `brew upgrade` quits Wink, which reconnects your displays; open it again afterwards.

To uninstall, turn off **Open at Login** and quit Wink from its menu, then run `brew uninstall --cask wink` (or delete `Wink.app`).

If you installed the earlier source-build formula, switch with `brew uninstall wink && brew install --cask xinding33/tap/wink`. Wink moves its remembered displays to the new location on first launch.

To build it yourself instead, see [Build](#build).

## Use

Open Wink. Click the two-displays icon in the menu bar, then click a checked monitor to turn it off. Click its “off” entry to reconnect it, or choose **Reconnect All**. **Quit & Reconnect Displays** restores monitors before exiting.

Wink remembers the monitors you turn off and turns them off again whenever they appear while it is running: at launch, after sleep, and after a cable change. Turn on **Open at Login** (a LaunchAgent in `~/Library/LaunchAgents`) to keep them off after a restart. Quitting reconnects them only until Wink launches again; reconnecting a monitor from the menu (or **Reconnect All**) forgets it. A remembered monitor that is not plugged in is listed as “off when connected”; click it to forget it. Hold Option while launching Wink to leave remembered monitors on for that session. If a monitor fails to turn off automatically, Wink stops retrying it until you turn it off again from the menu.

The app keeps the built-in screen and at least one active screen on. Mirrored displays must be changed to extended displays in System Settings first. Reconnecting a monitor can cause macOS to reposition windows.

## Build

Requires Xcode or the Swift command-line tools. No packages, subscription, administrator access, or network service is required at runtime.

```sh
swift test
bash scripts/build.sh
open "dist/Wink.app"
```

The build creates an ad-hoc signed Apple silicon app and ZIP for your own Mac.

### Release

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, signs with the hardened runtime, notarizes and staples the app, publishes `Wink-x.y.z.zip` to a GitHub Release, and updates the cask in [xinding33/homebrew-tap](https://github.com/xinding33/homebrew-tap). It needs these secrets in a `release` environment restricted to `v*` tags: `DEVELOPER_ID_P12` and `DEVELOPER_ID_P12_PASSWORD` (the base64-encoded Developer ID Application certificate and its password), `NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` (a base64-encoded App Store Connect API key), and `TAP_DEPLOY_KEY` (a deploy key with write access to the tap).

To produce the same notarized ZIP locally, save notary credentials once with `xcrun notarytool store-credentials wink-notary`, then run `bash scripts/release.sh`.

## Recovery and limitations

This uses the private `SLSConfigureDisplayEnabled` / `CGSConfigureDisplayEnabled` API loaded at runtime from SkyLight, inside a CoreGraphics transaction with `.forSession`. It makes no permanent display-configuration changes. Private APIs may change in future macOS releases. No SIP changes are needed.

Before turning off a monitor, the app writes its ID, UUID and current boot identifier to `~/Library/Application Support/Wink/recovery.json`. A small child process reconnects recorded displays if the app crashes or all remaining active screens disappear. Failed reconnect records are retained for another attempt. Relaunching the app attempts recovery; records from previous boots are ignored to avoid reusing stale display IDs. A disconnected or powered-off monitor may require reconnecting its cable. Logging out or restarting resets the session configuration; Wink then re-applies remembered monitors by UUID in `remembered.json` in the same folder when it next launches.

Only displays disabled by this app are restored. Recovery is best-effort: a macOS/WindowServer failure or simultaneous termination of the app and helper can require a relaunch, cable reconnect, or logout. The app does not override monitors disabled by other utilities.

Read-only diagnostics:

```sh
"dist/Wink.app/Contents/MacOS/Wink" --diagnose
```

Hardware integration test (briefly disconnects the specified external display and then reconnects it):

```sh
"dist/Wink.app/Contents/MacOS/Wink" --test-cycle DISPLAY_ID
```

## API references

- [CoreGraphics display configuration](https://developer.apple.com/documentation/coregraphics/cgcompletedisplayconfiguration(_:_:))
- [ScreenTune: private display API declarations](https://github.com/antonorlov/screen_tune)
- [displaytoggle: display disconnection on Apple silicon](https://github.com/calvincchan/displaytoggle)

The application implementation is original; those projects were consulted to verify the private function signatures.

## Verified on this Mac

On October 8, 2026, on an Apple M5 Max running macOS 27.0.1:

- All 12 automated safety and recovery tests passed.
- The Dell P2715Q disappeared from the online display list and successfully reconnected, with the BenQ RD280UA remaining online.
- Force-killing the test process while the Dell was disconnected triggered the independent helper, which restored the original display set.
- The app bundle's signature and property list passed validation.

Native UI automation was unavailable in the build environment (computer-use connection timed out), so menu appearance and mouse interaction have not been visually verified.

## Development

Wink's implementation, tests, and documentation were developed with AI assistance.

## License

Copyright 2026 Xin Ding. Licensed under the [Apache License, Version 2.0](LICENSE).
