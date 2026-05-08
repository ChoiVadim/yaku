# Yaku

Minimal macOS menu bar translator powered by a local Ollama server.

## Build

```sh
swift build
```

## Run for development

```sh
swift run Yaku
```

The first run prompts for Accessibility permission. The app reads selected text from the focused accessibility element after mouse selection and shows a small translation button.
If an app does not expose selection through Accessibility, Yaku falls back to a temporary copy-and-restore clipboard read after drag or double-click selection outside editable text fields. `Control` + `Command` + `T` and `fn` + `T` can also use that fallback for explicit replace translation.

Use `Control` + `Command` + `S` or `fn` + `S` to translate text you read from a selected screen area.
Use `Control` + `Command` + `T` or `fn` + `T` to translate text you wrote into the separate writing language, then replace it after review.

## Build a `.app` and DMG

```sh
bash Scripts/build-app-bundle.sh
```

The app bundle is produced at `dist/Yaku.app` and packaged into `dist/Yaku.dmg` (universal arm64 + x86_64, ad-hoc signed).

Pass `UNIVERSAL=0` to build host-arch only:

```sh
UNIVERSAL=0 bash Scripts/build-app-bundle.sh
```

## App icon

`Resources/AppIcon.icns` is generated from `Scripts/generate-icon.swift`. Regenerate after editing the renderer:

```sh
swift Scripts/generate-icon.swift Resources/AppIcon.icns
```

## Accessibility troubleshooting

If macOS shows Yaku enabled in Accessibility but the menu still says it needs permission, quit Yaku, remove or toggle the Yaku entry in System Settings > Accessibility, then open the app again. The app bundle is ad-hoc signed during `Scripts/build-app-bundle.sh` with a stable designated requirement, so macOS attaches the permission to `local.vadim.yaku`.

## In-app updates (Sparkle)

Yaku ships an in-app updater. The running app polls `appcast.xml` daily and can download + install new versions in one click via "Check for Updates..." in the menu.

### One-time setup (maintainer only)

1. Download the latest Sparkle release archive: <https://github.com/sparkle-project/Sparkle/releases>
2. Generate an EdDSA key pair (private key goes into your macOS Keychain):
   ```sh
   /path/to/Sparkle/bin/generate_keys
   ```
3. Copy the printed public key into `Resources/Info.plist`, replacing the placeholder value of `SUPublicEDKey`.
4. Make `sign_update` discoverable. Either:
   - put `bin/` on PATH, or
   - export `SPARKLE_BIN=/path/to/Sparkle/bin` before running `Scripts/release.sh`.

### Cutting a release

```sh
bash Scripts/release.sh 0.2.0
```

The script:

- Bumps `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
- Builds `dist/Yaku.app` and `dist/Yaku.dmg` via `build-app-bundle.sh`.
- Signs the DMG with EdDSA via `sign_update`.
- Appends a new `<item>` to `appcast.xml`.
- Renames the DMG to `Yaku-<version>.dmg`.

Then commit, tag, and create the GitHub Release that hosts the DMG:

```sh
git add Resources/Info.plist appcast.xml
git commit -m "Release v0.2.0"
git tag v0.2.0 && git push origin main --tags
gh release create v0.2.0 dist/Yaku-0.2.0.dmg --title "v0.2.0" --notes "..."
```

The `appcast.xml` URL embedded in the bundle (`https://raw.githubusercontent.com/ChoiVadim/yaku/main/appcast.xml`) updates as soon as the commit lands on `main`. Existing Yaku installs will pick up the new version on the next daily check or when the user clicks "Check for Updates...".
