# Translater

Minimal macOS menu bar translator.

## Build

```sh
swift build
```

## Run for development

```sh
swift run Translater
```

The first run prompts for Accessibility permission. The app reads selected text from the focused accessibility element after mouse selection and shows a small translation button.

## Build a `.app`

```sh
bash Scripts/build-app-bundle.sh
```

The app bundle is created at `dist/Translater.app`.

## Accessibility troubleshooting

If macOS shows Translater enabled in Accessibility but the menu still says it needs permission, quit Translater, remove or toggle the Translater entry in System Settings > Accessibility, then open the app again. The app bundle is ad-hoc signed during `Scripts/build-app-bundle.sh` with a stable designated requirement, so macOS can attach the permission to `local.vadim.translater`.
