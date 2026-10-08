# Wink

A small, free native macOS menu bar app to disconnect and reconnect external monitors while their cables stay plugged in. Built for Apple silicon and macOS 13 or newer; hardware support depends on macOS and the monitor connection.

## Install

Requires macOS 13+ on Apple silicon and the Xcode command line tools. Homebrew builds Wink on your Mac, so there's no Gatekeeper warning.

```sh
brew install xinding33/tap/wink
open "$(brew --prefix)/opt/wink/Wink.app"
```

Then choose **Open at Login** from its menu bar icon. Quit Wink before `brew upgrade wink`, then open it again.

To uninstall, turn off **Open at Login** and quit Wink from its menu, then run `brew uninstall wink`.

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

The build creates an ad-hoc signed app and ZIP for the current Mac architecture. It is not notarized for distribution to other Macs.

## Recovery and limitations

This uses the private `SLSConfigureDisplayEnabled` / `CGSConfigureDisplayEnabled` API loaded at runtime from SkyLight, inside a CoreGraphics transaction with `.forSession`. It makes no permanent display-configuration changes. Private APIs may change in future macOS releases. No SIP changes are needed.

Before turning off a monitor, the app writes its ID, UUID and current boot identifier to `~/Library/Application Support/Display Switch/recovery.json`. A small child process reconnects recorded displays if the app crashes or all remaining active screens disappear. Failed reconnect records are retained for another attempt. Relaunching the app attempts recovery; records from previous boots are ignored to avoid reusing stale display IDs. A disconnected or powered-off monitor may require reconnecting its cable. Logging out or restarting resets the session configuration; Wink then re-applies remembered monitors by UUID in `remembered.json` in the same folder when it next launches.

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

Wink retains its original bundle identifier and recovery directory for compatibility with the earlier Display Switch build.
