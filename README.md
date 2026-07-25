# Shuo

A private, native macOS push-to-talk dictation app. Hold the right Option key,
speak, and release to type the local transcription into the focused app.

- WhisperKit transcription runs on the Mac.
- Optional Qwen3 refinement runs with MLX on the Mac.
- Text is inserted without touching the clipboard.
- Permissions belong to the signed `Shuo.app`, not to Python.

## Build

```sh
./scripts/build-app.sh
```

The build uses ad-hoc code signing by default, so no Apple Developer
certificate is required. To sign with a specific certificate, provide its
name or SHA-1 hash:

```sh
SHUO_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./scripts/build-app.sh
```

## Install

```sh
./scripts/install-app.sh
```

The first launch downloads the selected local models and asks for Microphone,
Accessibility, and Input Monitoring permission.

## License

Shuo is licensed under the [Apache License 2.0](LICENSE).
