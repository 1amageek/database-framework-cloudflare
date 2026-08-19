#!/bin/sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIRECTORY="$HERE/.build/runtime"
INPUT_WASM="$BUILD_DIRECTORY/out/Products/Release-webassembly-wasm32/DatabaseServiceLauncher.wasm"
OUTPUT_WASM="$HERE/../cloudflare/src/database.wasm"
STAGED_WASM="$HERE/.build/database.optimized.wasm"
SWIFT_SDK="{{service.swiftSDK}}"
SWIFT_SNAPSHOT="{{service.swiftSnapshot}}"
SWIFT_TOOLCHAIN="{{service.swiftToolchain}}"

if ! TOOLCHAINS="$SWIFT_TOOLCHAIN" /usr/bin/swift -print-target-info |
    grep -q '"swiftCompilerTag": "'"$SWIFT_SNAPSHOT"'"'; then
  echo "Cloudflare database toolchain and Embedded WASM SDK do not match" >&2
  exit 1
fi

TOOLCHAINS="$SWIFT_TOOLCHAIN" \
/usr/bin/swift build \
  --scratch-path "$BUILD_DIRECTORY" \
  --swift-sdk "$SWIFT_SDK" \
  --product DatabaseServiceLauncher \
  -c release \
  --disable-index-store \
  -debug-info-format none \
  -j 1 \
  -Xswiftc -Osize \
  -Xswiftc -whole-module-optimization \
  -Xswiftc -Xfrontend \
  -Xswiftc -disable-reflection-metadata \
  -Xswiftc -Xfrontend \
  -Xswiftc -internalize-at-link

mkdir -p "$(dirname "$OUTPUT_WASM")" "$(dirname "$STAGED_WASM")"
npx --yes --package binaryen@131.0.0 wasm-opt \
  "$INPUT_WASM" \
  -Oz --strip-debug \
  --enable-bulk-memory --enable-sign-ext --enable-nontrapping-float-to-int \
  -o "$STAGED_WASM"

node "$HERE/verify-exports.mjs" "$STAGED_WASM"
cp "$STAGED_WASM" "$OUTPUT_WASM"
OUTPUT_BYTES="$(wc -c < "$OUTPUT_WASM" | tr -d ' ')"
echo "wrote $OUTPUT_WASM ($OUTPUT_BYTES bytes)"
