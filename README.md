# Nugumi

Minimal macOS menu bar translator powered by a local Ollama server.

## Build

```sh
swift build
```

## Run for development

```sh
swift run Nugumi
```

The first run prompts for Accessibility permission. The app reads selected text from the focused accessibility element after mouse selection and shows a small translation button.
If an app does not expose selection through Accessibility, Nugumi falls back to a temporary copy-and-restore clipboard read after drag or double-click selection outside editable text fields. `Control` + `1` can also use that fallback for explicit replace translation.

Use `Control` + `2` to translate text you read from a selected screen area.
Use `Control` + `1` to translate text you wrote into the separate writing language, then replace it after review.
Open Shortcuts > Edit keyboard shortcuts... from the menu bar item to customize shortcuts for the current macOS user.
Open the menu bar item to see a compact local usage summary with totals, streaks, workflow mix, and an activity map.

## Installing (end users)

Download the DMG from the [latest release](https://github.com/ChoiVadim/nugumi/releases/latest), open it, and drag `Nugumi.app` to `/Applications`.

If the DMG is ad-hoc signed (any release without Developer ID notarization), macOS Gatekeeper blocks the first launch with "Nugumi can't be opened because Apple cannot check it for malicious software." Right-click `Nugumi.app` and choose **Open** — confirm once and macOS trusts it from then on.

On first launch Nugumi asks for **Accessibility** and **Screen Recording** permissions. Both are required: Accessibility lets Nugumi read selected text, and Screen Recording is needed for "Translate screen area...". After enabling Screen Recording in System Settings, quit and relaunch Nugumi for the change to take effect.

## Build a `.app` and DMG

```sh
bash Scripts/build-app-bundle.sh
```

The app bundle is produced at `dist/Nugumi.app` and packaged into `dist/Nugumi.dmg` (universal arm64 + x86_64, ad-hoc signed).

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

If macOS shows Nugumi enabled in Accessibility but the menu still says it needs permission, quit Nugumi, remove or toggle the Nugumi entry in System Settings > Accessibility, then open the app again. The app bundle is ad-hoc signed during `Scripts/build-app-bundle.sh` with a stable designated requirement, so macOS attaches the permission to `com.nugumi.app`.

## In-app updates (Sparkle)

Nugumi ships an in-app updater. The running app polls `appcast.xml` daily and can download + install new versions in one click via "Check for Updates..." in the menu.

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
# Optional: signs with Developer ID and notarizes via Apple notary.
# Without these env vars the build is ad-hoc signed (works but shows
# "unidentified developer" on first launch).
export DEVELOPER_ID='Developer ID Application: Your Name (XXXXXXXXXX)'
export NOTARIZE_PROFILE='nugumi-notarize'   # see below

bash Scripts/release.sh 0.6.0
```

To enable Developer ID + notarization, do the one-time setup once:

1. Enroll in the Apple Developer Program ($99/yr).
2. Create a **Developer ID Application** certificate in Keychain Access. Copy the full identity name (e.g. `Developer ID Application: Vadim Choi (XXXXXXXXXX)`).
3. Generate an app-specific password at <https://account.apple.com>.
4. Store the notary credentials in keychain so notarytool can read them non-interactively:
   ```sh
   xcrun notarytool store-credentials nugumi-notarize \
       --apple-id "you@example.com" \
       --team-id "XXXXXXXXXX" \
       --password "abcd-efgh-ijkl-mnop"
   ```

Without `DEVELOPER_ID`/`NOTARIZE_PROFILE`, `release.sh` still produces a working `.dmg`, just ad-hoc signed.

The script:

- Bumps `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
- Builds `dist/Nugumi.app` and `dist/Nugumi.dmg` via `build-app-bundle.sh`.
- Signs the DMG with EdDSA via `sign_update`.
- Appends a new `<item>` to `appcast.xml`.
- Renames the DMG to `Nugumi-<version>.dmg`.

Then commit, tag, and create the GitHub Release that hosts the DMG:

```sh
git add Resources/Info.plist appcast.xml
git commit -m "Release v0.6.0"
git tag v0.6.0 && git push origin main --tags
gh release create v0.6.0 dist/Nugumi-0.6.0.dmg --title "v0.6.0" --notes "..."
```

The `appcast.xml` URL embedded in the bundle (`https://raw.githubusercontent.com/ChoiVadim/nugumi/main/appcast.xml`) updates as soon as the commit lands on `main`. Existing Nugumi installs will pick up the new version on the next daily check or when the user clicks "Check for Updates...".
