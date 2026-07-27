# OneClip Design Notes

## History retention

- History retention is configured directly in the main History card; it must not open a menu, popover, or secondary screen.
- Supported choices are 7, 14, 30, 60, 180, and 365 days, plus Permanent. The default is 60 days.
- The control uses compact rounded material tiles with a subtle highlight, accent border, and restrained shadow to stay consistent with the app's Liquid Glass settings cards.
- Automatic cleanup removes only non-favorite records older than the selected age. Permanent disables age cleanup, while favorite records are always retained.
- Storage settings contain only manual storage management so the retention setting has one clear source of truth.

## Clipboard item interaction

- Hovering or keyboard-selecting an item may change only its highlight; it must not reveal controls or change the row's layout.
- A primary click selects an item. A double click pastes it at the previously focused insertion point. Copy remains an explicit secondary action.
- Direct paste restores the previously active application before sending the paste command. Without macOS Accessibility permission, it safely falls back to copy and reports the permission requirement.
- Favorite, copy, paste, search, and delete actions live in the native macOS context menu so they inherit the system Liquid Glass treatment and accessibility behavior.
- The context menu orders the default paste action first, copy second, then organizational and destructive actions separated into clear groups.

## Clipboard presentation modes

- OneClip supports a bottom shelf and a classic window. The bottom shelf is the default for both new installs and settings migrated from versions without a presentation-mode value.
- The bottom shelf is anchored 12–14 points above the visible screen edge on the display containing the pointer. It spans the available width and enters with a short upward Liquid Glass transition.
- The shelf uses a compact search/category toolbar and a single horizontally scrolling row of fixed-size cards. Cards expose type, preview, content size, and the `⌘1–9` quick-copy mapping without showing a relative-time counter.
- Shelf cards and classic rows share the same interaction contract: single click selects, double click pastes, and the context menu owns explicit copy, favorite, search, paste, and delete actions.
- The classic window remains a centered 600 × 700 point vertical layout. Switching modes is available directly in Interface Settings and updates the current window without a secondary screen.
- Both modes use translucent system materials, restrained accent borders, continuous corners, and shallow depth so the result remains native to the existing Liquid Glass visual language.

## Accessibility onboarding

- Authorization uses one compact Liquid Glass guide instead of a text-heavy blocking alert.
- The guide demonstrates moving the OneClip icon into macOS Accessibility settings and also mentions the system `+` control.
- “Open System Settings” is the only emphasized action; defer and disable-reminder actions remain visually secondary.
- Permission state is detected automatically and transitions inline to a brief success state without opening another alert.
- Motion is subtle, runs only while permission is missing, and respects Reduce Motion.
- Permission copy explains the actual benefit—pasting at the current insertion point—and avoids implying that clipboard history requires this permission.
