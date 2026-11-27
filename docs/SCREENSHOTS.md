# Region screenshot implementation

## Reference study

Studied [ntfstool/wxShot](https://github.com/ntfstool/wxShot) at commit
`a97f137a66feb5b56765246c6d1518249a8a194a`, specifically
`ScreenSnapshotProvider.swift`, `ScreenCapturer.swift`, and `AppPermissions.swift`.
wxShot is MIT licensed (copyright 2026 ntfstool). PasteLight's implementation
is independently written; no upstream source or dependencies are bundled.

The adopted approach is to acquire a single static image before displaying the
selection overlay, draw the frozen desktop behind the selection, and convert
AppKit point coordinates into actual image pixels for the final crop.

Apple APIs: [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager),
[SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter),
and [CGRequestScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess()).
SCScreenshotManager supports the existing macOS 14 deployment target.

## Integration and limits

- A MainActor manager owns permissions, the Carbon shortcut, capture lifecycle,
  and per-display AppKit selection panels. Default shortcut: Command–Shift–X.
- ScreenCaptureKit excludes PasteLight windows, hides the cursor, disables audio,
  and captures each display once, sequentially. Overlays appear only after all
  snapshots finish, avoiding capture of the overlay itself.
- Snapshot pixels are capped at 64 million across all displays (about 256 MiB
  of raw BGRA pixels, excluding rendering and encoding overhead). No background
  screen stream is kept. Very large display arrangements are rejected.
- A 20-second preparation timeout and session IDs discard stale completions.
  Display reconfiguration and user cancellation release overlays and snapshots.
- ImageIO PNG encoding runs off the main actor. Only PNG data is written to the
  clipboard: no file URL or path text. The existing image ingestion path handles
  history, deduplication, persistence, and configured sync. The existing 50 MB
  image import limit applies.
- After selecting a region, a floating Liquid Glass toolbar offers rectangle,
  ellipse, arrow, pen, and sequential numbered badges, four colors, and three line
  weights. macOS 26 uses native glass; earlier supported systems use material.
- Return or the checkmark confirms; double-click confirms only in the selection
  tool. Escape, right-click, or Cancel aborts. ⌘Z undoes and ⇧⌘Z redoes. Reframing
  clears annotations. Selection remains confined to one display; no OCR or recording.
- Undo stores bounded vector commands rather than bitmap snapshots. Markup is
  clipped and rendered into the crop at native resolution, excluding overlay UI.
- Selection panels explicitly disable NSPanel's default hide-on-deactivation
  behavior. A repeated capture action brings the existing selection back to the
  front, rather than ignoring the action while an invisible session remains busy.
  No decision depends on WeChat or any other external application's identity.
- Permission checks do not prompt on startup. A user action requests system
  permission and can open the privacy pane. Accessibility is not required for
  capture or shortcut registration.
- Hotkeys are suspended while recording a shortcut. Conflicts between PasteLight
  actions are rejected; failed OS registration is shown in settings.

## Validation

Unit tests cover drag normalization/clamping, Retina pixel mapping and Y-axis
conversion, PNG crop dimensions and clipboard types, legacy configuration
decoding, custom shortcut persistence, shortcut recorder rejection/cancellation,
and synthetic AppKit Return/double-click/cancel interactions.

Real screen recording permission prompts, multi-display Spaces, and pasting into
external applications require an interactive macOS acceptance test. Automated
tests do not grant permissions or modify the TCC database.
