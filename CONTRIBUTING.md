# Contributing to Notch Player

A first contribution can be a small code change, a clearer instruction, or a compatibility report. You can try most UI work with sample tracks. Live playback and lock-screen reports are especially helpful when they include a Mac and macOS version we haven't covered.

## Pick a task

- Start with a [good first issue](https://github.com/andy1924/notch-player/labels/good%20first%20issue) for a small PR with a clear finish.
- Test [live playback](https://github.com/andy1924/notch-player/issues/2) or the [lock screen](https://github.com/andy1924/notch-player/issues/1) and share what worked and what didn't.
- For a larger change, describe it in an issue so contributors can coordinate before duplicating work.

## Build and test

1. Fork the repository and branch from `main`.
2. Run `./scripts/build.sh` on a Mac with Xcode or its command-line tools.
3. Run `open "dist/Notch Player.app" --args --demo` to check the notch and lock-screen preview with sample tracks. Quit any earlier instance before launching demo mode.
4. Verify the behavior you changed and open a focused PR. Include what you tried, your macOS version, and a screenshot or clip for visual changes when possible.

GitHub Actions builds pull requests on Apple silicon and Intel. For hardware or playback reports, include your display setup and music app version. Remove account details and personal media from logs or screenshots.

## Where things live

| Area | Source |
| --- | --- |
| Notch window, hover behavior, and menu bar | [App.swift](Sources/NotchPlayer/App.swift) |
| Notch and lock-screen player UI | [PlayerViews.swift](Sources/NotchPlayer/PlayerViews.swift) |
| Music integration | [Playback.swift](Sources/NotchPlayer/Playback.swift) |
| Lock-screen window placement | [LockScreenSpace.swift](Sources/NotchPlayer/LockScreenSpace.swift) |

Please follow the [code of conduct](CODE_OF_CONDUCT.md) in issues and pull requests.
