#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift_executable=${SWIFT_EXECUTABLE:-}
swift_wasm_sdk=${SWIFT_WASM_SDK:-}
build_path=${DATABASE_RUNTIME_BUILD_PATH:-"$repository_root/.build/release-gate"}
case "$build_path" in
    /*) ;;
    *) build_path="$repository_root/$build_path" ;;
esac
artifact_directory="$build_path/artifacts"
source_artifact="$build_path/out/Products/Release-webassembly-wasm32/CloudflareDatabaseRuntimeVerification.wasm"
optimized_artifact="$artifact_directory/CloudflareDatabaseRuntimeVerification.wasm"

maximum_raw_bytes=64000000
maximum_compressed_bytes=10000000
maximum_address_space_bytes=128000000
maximum_startup_milliseconds=1000

if [ -z "$swift_wasm_sdk" ]; then
    swift_wasm_sdk=$(
        "${swift_executable:-swift}" sdk list |
            awk '/^swift-6\.4.*_wasm$/ { selected = $0 } END { print selected }'
    )
fi
if [ -z "$swift_wasm_sdk" ]; then
    echo "A Swift 6.4 standard WASI SDK is required" >&2
    exit 1
fi
if [ -z "$swift_executable" ]; then
    matching_toolchain="${swift_wasm_sdk%_wasm}.xctoolchain"
    matching_swift="${HOME:?}/Library/Developer/Toolchains/$matching_toolchain/usr/bin/swift"
    if [ -x "$matching_swift" ]; then
        swift_executable=$matching_swift
    else
        swift_executable=swift
    fi
fi
if ! command -v wasm-opt >/dev/null 2>&1; then
    echo "wasm-opt is required for the Cloudflare feasibility gate" >&2
    exit 1
fi
if [ ! -x "$repository_root/Workers/CloudflareDatabaseRuntime/node_modules/.bin/tsx" ]; then
    echo "Run npm install in Workers/CloudflareDatabaseRuntime first" >&2
    exit 1
fi

"$swift_executable" build \
    --configuration release \
    --swift-sdk "$swift_wasm_sdk" \
    --target CloudflareDatabaseRuntimeVerification \
    --build-path "$build_path" \
    --disable-index-store \
    -j 1 \
    -Xswiftc -Osize \
    -Xswiftc -whole-module-optimization

mkdir -p "$artifact_directory"
wasm-opt -Oz --strip-debug "$source_artifact" -o "$optimized_artifact"

raw_bytes=$(wc -c < "$optimized_artifact" | tr -d ' ')
compressed_bytes=$(gzip -9 -c "$optimized_artifact" | wc -c | tr -d ' ')

node "$repository_root/scripts/verify-reactor-abi.mjs" "$optimized_artifact"

runtime_measurements=$(
    cd "$repository_root/Workers/CloudflareDatabaseRuntime"
    node --import tsx \
        scripts/verify-reactor-instantiation.ts \
        "$optimized_artifact"
)
printf '%s\n' "$runtime_measurements"

address_space_bytes=$(
    printf '%s' "$runtime_measurements" |
        node -e '
            let input = "";
            process.stdin.on("data", chunk => input += chunk);
            process.stdin.on("end", () => {
                process.stdout.write(
                    String(JSON.parse(input).addressSpaceBytes)
                );
            });
        '
)
startup_milliseconds=$(
    printf '%s' "$runtime_measurements" |
        node -e '
            let input = "";
            process.stdin.on("data", chunk => input += chunk);
            process.stdin.on("end", () => {
                process.stdout.write(
                    String(JSON.parse(input).startupMilliseconds)
                );
            });
        '
)

if [ "$raw_bytes" -gt "$maximum_raw_bytes" ]; then
    echo "Runtime raw size exceeds the 64 MB Worker limit: $raw_bytes" >&2
    exit 1
fi
if [ "$compressed_bytes" -gt "$maximum_compressed_bytes" ]; then
    echo "Runtime compressed size exceeds the 10 MB paid Worker limit: $compressed_bytes" >&2
    exit 1
fi
if [ "$address_space_bytes" -gt "$maximum_address_space_bytes" ]; then
    echo "Runtime address space exceeds the 128 MB isolate limit: $address_space_bytes" >&2
    exit 1
fi
if ! awk \
    -v actual="$startup_milliseconds" \
    -v maximum="$maximum_startup_milliseconds" \
    'BEGIN { exit !(actual <= maximum) }'; then
    echo "Runtime startup exceeds the 1 second Worker limit: ${startup_milliseconds} ms" >&2
    exit 1
fi

printf '%s\n' "Cloudflare feasibility gate passed"
printf '%s\n' "rawBytes=$raw_bytes"
printf '%s\n' "compressedBytes=$compressed_bytes"
printf '%s\n' "addressSpaceBytes=$address_space_bytes"
printf '%s\n' "startupMilliseconds=$startup_milliseconds"
