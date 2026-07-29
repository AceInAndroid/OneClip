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
  <img src="https://img.shields.io/badge/WebDAV-E2EE-22C55E?style=flat-square" alt="WebDAV E2EE">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-F59E0B?style=flat-square" alt="MIT License"></a>
</p>

## Why PasteLight

PasteLight is not another always-open productivity dashboard. It stays quietly in the menu bar, appears when you press a shortcut, finds what you copied, and gets out of the way.

- **Lightweight presentation:** a bottom shelf appears on demand and hides after use; a classic window is also available.
- **Lightweight interaction:** click to select, double-click to paste, use arrow keys to move, and press Return to copy the selection.
- **Lightweight search:** start typing immediately or press `⌘F`—no need to click a search field first.
- **Lightweight storage:** history stays local by default, duplicate content is merged, old records can expire automatically, and encrypted WebDAV sync is available when needed.
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

## Encrypted WebDAV Sync & Backup

- Disabled by default. Choose **Encrypted Backup** or **Bidirectional Sync** under Settings → Sync & Backup.
- Syncs plain text, rich text, and images between PasteLight installations on multiple Macs. Files, audio/video, archives, and applications always remain local.
- Encrypts manifests and attachments end to end with AES-GCM. The sync password is processed with PBKDF2-HMAC-SHA256 using at least 600,000 iterations; WebDAV credentials and the derived key are stored separately in macOS Keychain.
- Bidirectional sync merges new records, favorites, and manual deletions. Automatic retention cleanup stays device-local and does not remove records from other Macs.
- Remote records are added to history without replacing the current system clipboard. Identical content is merged by fingerprint.
- Encrypted backup runs automatically at most once per day or on demand, retains the latest seven successful snapshots per device, and restores by safely merging with local history.
- Images are limited to 20 MB and rich text to 8 MB. Oversized records remain local and appear in the skipped-item count.

### Getting started

1. Prepare an HTTPS WebDAV endpoint with a certificate trusted by macOS.
2. Enter the server URL, remote path, username, and WebDAV password under Sync & Backup.
3. Set a sync password of at least 12 characters. Enter the exact same password on every Mac.
4. Run Test Connection, then select a mode and confirm the estimated item count and upload size.

> PasteLight rejects HTTP endpoints and does not bypass invalid or self-signed certificates. If your NAS uses a private CA, add that CA to macOS system trust first.

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

- Sync and backup are disabled by default; clipboard history remains entirely local until you enable them.
- When WebDAV is enabled, only end-to-end encrypted manifests, backups, and supported attachments are uploaded to the server you configure. The server cannot directly read clipboard plaintext.
- WebDAV credentials and the derived encryption key are stored in macOS Keychain, never in `settings.json`, and are not synchronized through iCloud Keychain.
- Disconnecting or resetting removes only local configuration and Keychain entries; encrypted remote data is not automatically deleted.
- Images and large files are loaded on demand to reduce resident memory.
- Content fingerprints support local and encrypted-sync deduplication; remote objects use keyed hashes that do not expose the original fingerprint.
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
