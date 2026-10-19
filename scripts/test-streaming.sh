#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${SHUO_STREAMING_MODEL_DIR:?Set the path to an already-downloaded Qwen3-ASR model}"
: "${SHUO_QWEN_AUDIO_FIXTURE:?Set the path to a 16 kHz mono WAV}"
: "${SHUO_QWEN_EXPECTED_TEXT:?Set an expected phrase}"
cd "$PROJECT_DIR"
xcrun swift build --disable-sandbox --build-tests
BIN_DIR=$(xcrun swift build --disable-sandbox --show-bin-path)

# Xcode's Swift Testing host may not expose dependency bundles to MLX's lookup.
# Colocate the freshly built Metal library with the test binaries instead.
METAL_LIBRARY="$BIN_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ ! -f "$METAL_LIBRARY" ]]; then
    METAL_LIBRARY="$BIN_DIR/mlx-swift_Cmlx.bundle/default.metallib"
fi
for TEST_BUNDLE in "$BIN_DIR"/*.xctest; do
    [[ -d "$TEST_BUNDLE/Contents/MacOS" ]] || continue
    cp "$METAL_LIBRARY" "$TEST_BUNDLE/Contents/MacOS/mlx.metallib"
    codesign --force --sign - "$TEST_BUNDLE/Contents/MacOS/mlx.metallib"
    codesign --force --sign - --preserve-metadata=entitlements "$TEST_BUNDLE"
done
SHUO_RUN_STREAMING_INTEGRATION=1 xcrun swift test --disable-sandbox --skip-build \
    --filter mlxStreamingDecodesCumulativeAudioWithPrefixAndTail
