<p align="center">
  <img src="Resources/ShuoIcon.png" width="128" alt="Shuo icon">
</p>

# Shuo 說

[![CI](https://github.com/yilin-zhang/shuo/actions/workflows/ci.yml/badge.svg)](https://github.com/yilin-zhang/shuo/actions/workflows/ci.yml)

A private, native macOS push-to-talk dictation app. Hold the right Option key,
speak, and release to type the local transcription into the focused app.

- Choose WhisperKit or Qwen3-ASR; both run entirely on the Mac.
- Optional Qwen3 refinement runs with MLX on the Mac.
- Qwen3-ASR can use an optional one-term-per-line terminology list during
  decoding. Terminology can improve specialist vocabulary, but may over-correct
  similar-sounding words.
- Text is inserted without touching the clipboard.
- Permissions belong to the signed `Shuo.app`, not to Python.

## Requirements

- macOS 15 or later
- Xcode with the Swift 6.2 toolchain
- An Apple silicon Mac
- An internet connection for Swift dependencies and the initial model downloads

## Test

```sh
xcrun swift-format lint --strict --recursive Sources Tests
xcrun swift test --disable-sandbox
```

## Build

```sh
./scripts/build-app.sh
```

The app is written to `dist/Shuo.app`. By default, the script uses ad-hoc code
signing, so an Apple Developer certificate is not required. This is convenient
for a quick local build, but macOS may ask for Microphone, Accessibility, and
Input Monitoring permissions again after the app changes.

To use a specific signing identity, pass its name or SHA-1 hash:

```sh
SHUO_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./scripts/build-app.sh
```

## Install

The install script builds the app, replaces `~/Applications/Shuo.app`, and
launches it:

```sh
./scripts/install-app.sh
```

For regular local development, use an Apple Development identity so successive
builds keep a stable code identity and retain macOS permissions:

```sh
SHUO_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./scripts/install-app.sh
```

Passing the identity to `install-app.sh` is important because it performs its
own build. Signing `dist/Shuo.app` first and then running an unsigned install
command would rebuild the app with the default ad-hoc signature.

List the code-signing identities available on the Mac with:

```sh
security find-identity -v -p codesigning
```

Xcode can create an Apple Development identity under **Xcode → Settings →
Apple Accounts → Personal Team → Manage Certificates**. Signing identities
and private keys belong in the developer's Keychain; do not add them or
machine-specific identity values to the repository.

The first launch downloads the selected local models and asks for Microphone,
Accessibility, and Input Monitoring permission.

## Continuous integration

GitHub Actions checks formatting and runs the test suite for every pull request
and every push to `main`. Pushes to `main` also produce an ad-hoc signed
`Shuo.app.zip` artifact on the workflow run.

The artifact is intended for development testing. Public distribution still
requires Developer ID Application signing and Apple notarization. CI artifacts
do not provide a stable signing identity and may require permissions to be
granted again after an update.

## License

Shuo is licensed under the [Apache License 2.0](LICENSE).
