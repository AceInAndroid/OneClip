# OneClip Design Notes

## History retention

- History retention is configured directly in the main History card; it must not open a menu, popover, or secondary screen.
- Supported choices are 7, 14, 30, 60, 180, and 365 days, plus Permanent. The default is 60 days.
- The control uses compact rounded material tiles with a subtle highlight, accent border, and restrained shadow to stay consistent with the app's Liquid Glass settings cards.
- Automatic cleanup removes only non-favorite records older than the selected age. Permanent disables age cleanup, while favorite records are always retained.
- Storage settings contain only manual storage management so the retention setting has one clear source of truth.

## Clipboard item interaction

- Hovering or keyboard-selecting an item may change only its highlight; it must not reveal controls or change the row's layout.
- A primary click pastes the item at the previously focused insertion point. Copy remains an explicit secondary action.
- Direct paste restores the previously active application before sending the paste command. Without macOS Accessibility permission, it safely falls back to copy and reports the permission requirement.
- Favorite, copy, paste, search, and delete actions live in the native macOS context menu so they inherit the system Liquid Glass treatment and accessibility behavior.
- The context menu orders the default paste action first, copy second, then organizational and destructive actions separated into clear groups.
