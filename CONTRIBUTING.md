# Contributing

Thanks for helping! A few guidelines:

- **Read [SECURITY.md](SECURITY.md) first.** Any PR that stores a secret, forwards the environment,
  reads process arguments or transcript contents will be declined.
- Setup: `brew install xcodegen && xcodegen generate && open Kodisle.xcodeproj`. The `.xcodeproj` is
  generated and not committed; edit `project.yml` for build settings.
- **Stable local signing**: builds are ad-hoc signed by default, so macOS forgets privacy grants
  (Downloads, Automation…) after every rebuild. To keep them, copy your identity into the git-ignored
  `Signing.xcconfig.local`, using its SHA-1 from `security find-identity -v -p codesigning`:
  `CODE_SIGN_IDENTITY = <sha1>` and `DEVELOPMENT_TEAM = <team id>`.
- **Adding a widget**: add a case to `WidgetID` (`Core/Models.swift`), a data source in `Providers/`
  if needed, polling in `KodisleStore`, then a tile in `WidgetTile`, a glyph in `CompactGlyph` and a
  panel in `WidgetPanel` (`UI/Widgets/`).
- Shell out only through `Shell.run` and use ephemeral networking via `Net.session`.
- Mark user-identifying text with `.privacySensitive()` so Privacy mode works.
- Never block the main thread: file I/O goes through `Task.detached`, processes through `Shell.run`.
- Keep UI strings in English; localizations are welcome via a String Catalog.

## Releasing

1. Push a tag: `git tag v0.2.0 && git push origin v0.2.0`.
2. The *Release* workflow builds a universal app, publishes `Kodisle.zip` + `Kodisle.zip.sha256` to GitHub Releases
   and bumps the Homebrew cask in `pablorod1/homebrew-tap` (needs a `TAP_TOKEN` secret: a fine-grained token with
   *Contents: read & write* on that repo only). Without the secret, update `Casks/kodisle.rb` (version + sha256) by hand.
3. Installed apps pick up the new version within a day (Settings › General › Updates).
