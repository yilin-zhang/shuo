<p align="center">
  <img src="Resources/ShuoIcon.png" width="128" alt="Shuo icon">
</p>

# Shuo 說

[![CI](https://github.com/yilin-zhang/shuo/actions/workflows/ci.yml/badge.svg)](https://github.com/yilin-zhang/shuo/actions/workflows/ci.yml)

A private, native macOS push-to-talk dictation app. Hold the right Option key,
speak, and release to type the local transcription into the focused app.

- Qwen3-ASR runs entirely on the Mac.
- Qwen3-ASR shows a revisable live transcript using cumulative audio and token
  prefix rollback. No forced-alignment companion is needed. Live transcription
  can be disabled in Settings. Refinement runs after the final transcription.
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

## Qwen streaming module

`Sources/QwenStreaming` is an independent library target, separate from Shuo's
microphone, UI, and text injection. `QwenStreamingSession` accepts ordered 16 kHz
mono Float PCM and an injectable asynchronous decoder; `QwenMLXDecoder` supplies
the MLX implementation using public mlx-audio-swift APIs. No patched checkout or
custom Metal operator is required.

The algorithm follows [Qwen's reference streaming implementation](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py):
accumulate audio, decode every 2 seconds, leave the first two decodes unprefixed,
then roll back five tokens of the previous raw output and append the retained
prefix to the assistant prompt. Unicode replacement-character boundaries are
rolled back further. Each decode gets a fresh KV cache because its audio input
has changed. This is cumulative re-decoding, not a cached incremental encoder.

Shuo coalesces pending previews if inference falls behind rather than building a
queue of stale decodes. On release it supplies the complete capture and performs
one final decode, including sub-chunk tail audio. Previews remain revisable;
refinement and text injection use only the final result. Audio is not trimmed
using alignment timestamps or short energy-based pauses.

Long utterances increase recomputation cost and memory use. Benchmark on the
target Mac before choosing shorter update intervals. Prefix conditioning can
retain earlier mistakes; this does not guarantee the accuracy of an independent
full-utterance transcription. Token-budget exhaustion is reported as an error
instead of silently emitting truncated text.

Run the optional model-backed streaming smoke test with an existing model folder
and a 16 kHz mono WAV (it does not download models or open the microphone):

```sh
SHUO_STREAMING_MODEL_DIR='/path/to/downloaded/qwen-model' \
SHUO_QWEN_AUDIO_FIXTURE='/path/to/16k-mono.wav' \
SHUO_QWEN_EXPECTED_TEXT='expected phrase' \
SHUO_QWEN_EXPECTED_TAIL='expected last phrase' \
./scripts/test-streaming.sh
```

This checks actual cumulative decoding, assistant-prefix preservation, Unicode,
and the final audio tail. The normal suite uses an injected decoder to check
session scheduling, cancellation, error propagation, and undelivered audio.

The helper colocates the built Metal library with test binaries for Xcode test
hosts that do not discover dependency resource bundles. GPU access is required.
