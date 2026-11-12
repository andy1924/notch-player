# Notch Player

**Spotify and Apple Music in your MacBook notch.** An open-source Dynamic Island for macOS with playback controls, live album art, and a spinning record on the lock screen.

[Try it on your Mac](#quick-start) · [Find a first contribution](#contribute) · [Report a bug](https://github.com/andy1924/notch-player/issues/new?template=bug_report.md)

![Notch Player demo with an expanded MacBook notch player and a vinyl record above its lock-screen controls](assets/social-preview.png)

[![macOS build](https://github.com/andy1924/notch-player/actions/workflows/macos.yml/badge.svg)](https://github.com/andy1924/notch-player/actions/workflows/macos.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

## What you can do

- **Control music from the notch.** Hover to highlight and click to open. Play, pause, skip, scrub, or click the album art to jump to the Spotify or Music app.
- **See a record on the lock screen.** Switch between a spinning vinyl record and album art. Use **Preview Lock Screen** from the menu bar to try the player while unlocked.
- **Use it on a Mac without a notch.** The compact player appears as a floating pill on that display.

If you’d like to follow the project, [star Notch Player](https://github.com/andy1924/notch-player). A short report from your Mac is also a contribution.

## Quick start

Notch Player currently builds from source. You’ll need **macOS 14 or later** and **Xcode or its command-line tools**.

```sh
git clone https://github.com/andy1924/notch-player.git
cd notch-player
./scripts/build.sh
open "dist/Notch Player.app"
```

Play a track in Spotify or Music and allow the macOS Automation prompt. The record icon in the menu bar opens the player, lock-screen preview, and settings. If you denied access, check **System Settings → Privacy & Security → Automation**.

Want to try the UI first? Quit the app and reopen it with sample tracks.

```sh
open "dist/Notch Player.app" --args --demo
```

## Compatibility

GitHub Actions builds the app on Apple silicon and Intel. Live playback needs the Spotify or Music desktop app. Lock-screen placement uses private macOS WindowServer APIs, so visibility and click handling can vary by macOS version. The app tries AppKit presentation if the required symbols are unavailable.

To help verify the lock screen, play a track, press **Control–Command–Q**, then try pause and skip. Record your macOS version, Mac model, and display setup in the [compatibility issue](https://github.com/andy1924/notch-player/issues/1). A signed downloadable release is [tracked separately](https://github.com/andy1924/notch-player/issues/4).

## Contribute

| I can help with… | Start here |
| --- | --- |
| A small first PR | [Good first issues](https://github.com/andy1924/notch-player/labels/good%20first%20issue) |
| Testing Spotify or Music | [Playback verification](https://github.com/andy1924/notch-player/issues/2) |
| Testing the lock screen on my Mac | [Lock-screen compatibility](https://github.com/andy1924/notch-player/issues/1) |
| Building or changing the app | [Contributor guide](CONTRIBUTING.md) |

## Credits

Inspired by [Needle](https://needlemac.com/) and [Atoll](https://github.com/Ebullioscopic/Atoll). Lock-screen placement follows the WindowServer approach documented by [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow). Released under the [MIT License](LICENSE).
