# Yaku — Maintainer Instructions

This file is loaded as project context by Claude Code. It contains operational instructions that apply to every session working on Yaku, not user-facing documentation.

## Project at a glance

- macOS menu bar app, Swift Package Manager, deployment target macOS 14.
- Bundle ID: `local.vadim.yaku`. GitHub repo: `ChoiVadim/yaku` (`origin`).
- Single source file: `Sources/Yaku/App.swift` (everything except onboarding state lives here). `Sources/Yaku/Bootstrap.swift` covers Ollama setup wizard.
- Distribution: ad-hoc signed `.app` + universal DMG packaged via `Scripts/build-app-bundle.sh`. In-app updates via Sparkle 2.9.1.

## Cutting a release

The release flow is fully scripted. Do **not** run individual steps manually unless debugging.

```sh
# One-shot — bumps Info.plist, builds, signs, updates appcast, renames dmg.
export SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
bash Scripts/release.sh 0.2.0

# Then commit + tag + GitHub Release. Tag must be vX.Y.Z (the appcast item's
# enclosure URL is built as github.com/ChoiVadim/yaku/releases/download/vX.Y.Z/Yaku-X.Y.Z.dmg).
git add Resources/Info.plist appcast.xml
git commit -m "Release v0.2.0"
git tag v0.2.0 && git push origin main --tags
gh release create v0.2.0 dist/Yaku-0.2.0.dmg --title "v0.2.0" --notes "Release notes here"
```

What `Scripts/release.sh` does, in order:

1. Bumps `CFBundleShortVersionString` to the supplied version and increments `CFBundleVersion`.
2. Runs `Scripts/build-app-bundle.sh` to produce `dist/Yaku.app` and `dist/Yaku.dmg` (universal arm64 + x86_64, ad-hoc signed, Sparkle.framework bundled and signed).
3. Signs the DMG via Sparkle's `sign_update` (uses the EdDSA private key in macOS Keychain).
4. Appends an `<item>` to `appcast.xml` with `sparkle:edSignature`, length, version metadata.
5. Renames `dist/Yaku.dmg` → `dist/Yaku-<version>.dmg` so the URL in the appcast matches the GitHub Release asset name.

After the GitHub Release is published, all installed copies of Yaku will see the new version on their next daily Sparkle check (or immediately when the user clicks "Check for Updates...").

## Sparkle keys

- Public key is committed to `Resources/Info.plist` as `SUPublicEDKey`. **Never** rotate this casually — every shipped Yaku build has it baked in, and all updates must be signed with the matching private key.
- Private key lives in the maintainer's macOS Keychain (item name `https://sparkle-project.org`). It is **never** committed.
- If the private key is ever lost or compromised: generate a new pair (`./.build/artifacts/sparkle/Sparkle/bin/generate_keys`), update `SUPublicEDKey`, ship a new release manually (existing installs that haven't taken the rotation update will be stuck on the old key).

## Build script invariants

- `Scripts/build-app-bundle.sh` must remain idempotent. Running it twice should produce a clean `dist/Yaku.app`.
- The script signs Sparkle's inner XPC services and helpers individually (Downloader.xpc, Installer.xpc, Autoupdate, Updater.app) before signing the framework wrapper, then signs the app bundle with `--options runtime`. Hardened runtime is **required** by Sparkle 2.x.
- The Sparkle framework must come from the universal `Sparkle.xcframework/macos-arm64_x86_64` slice. The script falls back to a generic `find` only if the universal slice is missing (e.g. host-arch only build).
- Designated requirement is pinned to `identifier "local.vadim.yaku"` so accessibility/screen-recording permissions persist across rebuilds.

## When editing App.swift

- Do not introduce a second source file unless an entire subsystem is being extracted. The single-file layout is intentional — easier to grep, easier to ship as a one-shot.
- `TranslationMode` declares per-mode metadata (`resultLabel`, `loadingPlaceholder`, `systemPrompt`). New modes go through this enum, not via callsite branching.
- `OllamaModelOption.all` is the source of truth for which models the menu offers. Update it when adding model variants — do not hardcode model IDs in `OllamaClient` or `OllamaBootstrap`.
- The floating button uses a single `NSButton` whose `title` and `image` swap based on `TranslationMode`. Don't reintroduce overlapping `NSTextField` / `NSImageView` views — they break centering.
- For permissions (Accessibility, Screen Recording), prefer requesting at startup in `applicationDidFinishLaunching`. Don't add silent failure paths.

## Local development

```sh
swift run Yaku                    # debug build, no .app bundle, Sparkle inert.
bash Scripts/build-app-bundle.sh  # full universal release bundle + DMG.
```

In `swift run` mode Sparkle is fully inert: `updaterController` is `nil` and the "Check for Updates..." menu item is hidden. Sparkle requires a real `.app` bundle (Frameworks/Sparkle.framework + hardened runtime + Info.plist), so end-to-end update testing must use `bash Scripts/build-app-bundle.sh` and run `dist/Yaku.app`.
