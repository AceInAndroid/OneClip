# OneClip Design Notes

## History retention

- History retention is configured directly in the main History card; it must not open a menu, popover, or secondary screen.
- Supported choices are 7, 14, 30, 60, 180, and 365 days, plus Permanent. The default is 60 days.
- The control uses compact rounded material tiles with a subtle highlight, accent border, and restrained shadow to stay consistent with the app's Liquid Glass settings cards.
- Automatic cleanup removes only non-favorite records older than the selected age. Permanent disables age cleanup, while favorite records are always retained.
- Storage settings contain only manual storage management so the retention setting has one clear source of truth.
