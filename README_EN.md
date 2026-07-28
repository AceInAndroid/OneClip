<p align="right">
  <a href="README.md">中文</a> · <b>English</b>
</p>

<div align="center">
  <img src="src/OneClip/Assets.xcassets/AppIcon.appiconset/icon-256.png" alt="PasteLight icon" width="112" height="112">
  <h1>PasteLight</h1>
  <p><strong>A lighter path from clipboard history to paste.</strong></p>
  <p>A native, focused clipboard history utility for macOS.</p>
</div>

<p align="center">
  <a href="https://github.com/AceInAndroid/OneClip/releases/latest"><img src="https://img.shields.io/github/v/release/AceInAndroid/OneClip?style=flat-square&color=5E6AD2" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/SwiftUI-Native-F05138?style=flat-square&logo=swift&logoColor=white" alt="Native SwiftUI">
  <img src="https://img.shields.io/badge/Data-Local-22C55E?style=flat-square" alt="Local Data">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-F59E0B?style=flat-square" alt="MIT License"></a>
</p>

## Why PasteLight

PasteLight is not another always-open productivity dashboard. It stays quietly in the menu bar, appears when you press a shortcut, finds what you copied, and gets out of the way.

- **Lightweight presentation:** a bottom shelf appears on demand and hides after use; a classic window is also available.
- **Lightweight interaction:** click to select, double-click to paste, use arrow keys to move, and press Return to copy the selection.
- **Lightweight search:** start typing immediately or press `⌘F`—no need to click a search field first.
- **Lightweight storage:** history stays local, duplicate content is merged, and old records can expire automatically.
- **Native stack:** built with Swift, SwiftUI, AppKit, and macOS frameworks—no web runtime.

## Features

- Customizable global shortcut, defaulting to `⌘⇧V`.
- Text, image, file, media, document, and code history.
- Direct paste back into the previously active application.
- Bottom shelf and classic window presentation modes.
- Keyboard navigation, type-to-search, `⌘F`, and IME-friendly search flow.
- Local fingerprint-based deduplication.
- Retention options for 7, 14, 30, 60, 180, or 365 days, plus Forever; 60 days by default.
- Favorites that are preserved during automatic cleanup.
- Native context menu for copy, paste, favorite, search, and delete actions.

## Download

Get the latest build from [GitHub Releases](https://github.com/AceInAndroid/OneClip/releases/latest):

- `arm64.dmg` for Apple Silicon Macs.
- `x86_64.dmg` for Intel Macs.

Open the DMG and drag `PasteLight.app` into `Applications`.

> Community builds currently use a local signature and are not notarized with Apple Developer ID. If macOS blocks the first launch, review the app under System Settings → Privacy & Security and open it only if you trust the source.

## Accessibility permission

Accessibility permission is required only for direct paste at the current insertion point. Clipboard history, search, and explicit copy continue to work without it.

Open System Settings → Privacy & Security → Accessibility, add `PasteLight.app`, and enable it. The in-app guide walks through the same process.

## Privacy

- Clipboard history is stored locally and is not uploaded.
- Images and large files are loaded on demand to reduce resident memory.
- Content fingerprints are used only for on-device deduplication.
- The existing bundle identifier and data directories are retained so current users keep their history and settings after the rename.

## Build from source

Requirements: macOS 14+ and Xcode 15+.

```bash
git clone https://github.com/AceInAndroid/OneClip.git
cd OneClip/src
xcodebuild \
  -project OneClip.xcodeproj \
  -scheme OneClip \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

The Xcode target and scheme retain the internal name `OneClip`; the built application is `PasteLight.app`. See the [source build guide](src/README.md) for more details.

## Shortcuts

| Action | Default |
| --- | --- |
| Show or hide PasteLight | `⌘⇧V` |
| Select an item | Click / arrow keys |
| Paste an item | Double-click |
| Copy the selected item | Return |
| Search | Start typing / `⌘F` |
| Quick-copy the first 9 items | `⌘1`–`⌘9` |
| More actions | Right-click an item |
| Open Settings | `⌘,` |

## Contributing

Use [Issues](https://github.com/AceInAndroid/OneClip/issues) for bugs and feature requests. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting code.

## License

[MIT](LICENSE)
