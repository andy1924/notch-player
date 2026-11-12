# Contributing

Pick an [open issue](https://github.com/andy1924/notch-player/issues) or start with a [good first issue](https://github.com/andy1924/notch-player/labels/good%20first%20issue). Comment on an issue to coordinate before tackling a larger change.

1. Fork the repository and branch from `main`.
2. Run `./scripts/build.sh` on a Mac with Xcode or its command-line tools.
3. Launch the app and verify the affected behavior. Use `--demo` for UI changes that do not require a live music app.
4. Open a focused pull request with what changed, how you tested it, and the related issue. Include a screenshot or clip for visual changes when possible.

For hardware or playback reports, include your macOS version, Mac model, display setup, and music app version. Remove account details and personal media from logs or screenshots.

| Area | Source |
| --- | --- |
| Notch window, hover behavior, and menu bar | [App.swift](Sources/NotchPlayer/App.swift) |
| Notch and lock-screen player UI | [PlayerViews.swift](Sources/NotchPlayer/PlayerViews.swift) |
| Music integration | [Playback.swift](Sources/NotchPlayer/Playback.swift) |
| Lock-screen window placement | [LockScreenSpace.swift](Sources/NotchPlayer/LockScreenSpace.swift) |
