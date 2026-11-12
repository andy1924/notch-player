# Notch Player

[![macOS build](https://github.com/andy1924/notch-player/actions/workflows/macos.yml/badge.svg)](https://github.com/andy1924/notch-player/actions/workflows/macos.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

An open-source macOS Dynamic Island for Spotify and Apple Music. See what's playing in your MacBook's notch, control playback, and show a spinning record on the lock screen.

- **MacBook notch player** — hover to highlight, click to expand or collapse, or use the floating pill on displays without a notch.
- **Now Playing** — see album art, track details, and playback progress, with play, pause, and skip controls.
- **Lock-screen player** — click the spinning record to switch to the album cover. Use **Preview Lock Screen** in the menu bar to try the card on your desktop.

## Build and run

Requires macOS 14 or later and Xcode or its command-line tools.

```sh
git clone https://github.com/andy1924/notch-player.git
cd notch-player
./scripts/build.sh
open "dist/Notch Player.app"
```

Play a track in the Spotify or Music desktop app and allow the macOS Automation prompt. Use the record icon in the menu bar to open the notch player, change lock-screen options, or quit. Spotify album covers load from Spotify's artwork URLs.

To try the interface with sample data, quit the app and reopen it in demo mode.

```sh
open "dist/Notch Player.app" --args --demo
```

## Lock-screen compatibility

Play a track, press Control–Command–Q, and check whether the card appears and responds. Lock-screen visibility varies by macOS version because placement uses private WindowServer APIs. The app tries AppKit presentation if the required symbols are unavailable. If the card is missing or unresponsive, please [share your setup in Issues](https://github.com/andy1924/notch-player/issues).

## Contribute

[Open issues](https://github.com/andy1924/notch-player/issues) · [Good first issues](https://github.com/andy1924/notch-player/labels/good%20first%20issue) · [Contribution guide](CONTRIBUTING.md)

Notch Player is inspired by [Needle](https://needlemac.com/) and [Atoll](https://github.com/Ebullioscopic/Atoll). The lock-screen implementation follows the WindowServer approach documented by [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow).

Released under the [MIT License](LICENSE).
