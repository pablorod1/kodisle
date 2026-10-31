# Contributing

Thanks for helping! A few guidelines:

- **Read [SECURITY.md](SECURITY.md) first.** Any PR that stores a secret, forwards the environment,
  reads process arguments or transcript contents will be declined.
- Setup: `brew install xcodegen && xcodegen generate && open Kodisle.xcodeproj`. The `.xcodeproj` is
  generated and not committed; edit `project.yml` for build settings.
- **Adding a widget**: add a case to `WidgetID` (`Core/Models.swift`), a data source in `Providers/`
  if needed, polling in `KodisleStore`, then a tile in `WidgetTile`, a glyph in `CompactGlyph` and a
  panel in `WidgetPanel` (`UI/Widgets/`).
- Shell out only through `Shell.run` and use ephemeral networking via `Net.session`.
- Mark user-identifying text with `.privacySensitive()` so Privacy mode works.
- Never block the main thread: file I/O goes through `Task.detached`, processes through `Shell.run`.
- Keep UI strings in English; localizations are welcome via a String Catalog.
