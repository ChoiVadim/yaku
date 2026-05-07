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
If an app does not expose selection through Accessibility, Yaku falls back to a temporary copy-and-restore clipboard read after drag or double-click selection.

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
