#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift_executable=${SWIFT_EXECUTABLE:-}
swift_wasm_sdk=${SWIFT_EMBEDDED_WASM_SDK:-}
build_path=${DATABASE_RUNTIME_BUILD_PATH:-"$repository_root/.build/release-gate"}
case "$build_path" in
    /*) ;;
    *) build_path="$repository_root/$build_path" ;;
esac
artifact_directory="$build_path/artifacts"
source_artifact="$build_path/out/Products/Release-webassembly-wasm32/CloudflareDatabaseRuntimeVerification.wasm"
optimized_artifact="$artifact_directory/CloudflareDatabaseRuntimeVerification.wasm"
reactor_link_inputs="$build_path/out/Intermediates.noindex/database-framework-cloudflare.build/Release-webassembly-wasm32/CloudflareDatabaseRuntimeVerification-p.build/Objects-normal/wasm32/CloudflareDatabaseRuntimeVerification.LinkFileList"

maximum_raw_bytes=64000000
maximum_compressed_bytes=10000000
maximum_address_space_bytes=128000000
maximum_startup_milliseconds=1000

if [ -z "$swift_wasm_sdk" ]; then
    swift_wasm_sdk=$(
        "${swift_executable:-swift}" sdk list |
            awk '/^swift-6\.4.*_wasm-embedded$/ { selected = $0 } END { print selected }'
    )
fi
if [ -z "$swift_wasm_sdk" ]; then
    echo "A Swift 6.4 Embedded WASI SDK is required" >&2
    exit 1
fi
if [ -z "$swift_executable" ]; then
    matching_toolchain="${swift_wasm_sdk%_wasm-embedded}.xctoolchain"
    matching_swift="${HOME:?}/Library/Developer/Toolchains/$matching_toolchain/usr/bin/swift"
    if [ -x "$matching_swift" ]; then
        swift_executable=$matching_swift
    else
        swift_executable=swift
    fi
fi
expected_snapshot=${swift_wasm_sdk%_wasm-embedded}
if ! "$swift_executable" -print-target-info | grep -q \
    '"swiftCompilerTag": "'"$expected_snapshot"'"'; then
    echo "Swift toolchain and Embedded WASM SDK snapshots do not match" >&2
    "$swift_executable" --version >&2
    echo "sdk=$swift_wasm_sdk" >&2
    exit 1
fi
if ! command -v wasm-opt >/dev/null 2>&1; then
    echo "wasm-opt is required for the Cloudflare feasibility gate" >&2
    exit 1
fi
if [ ! -x "$repository_root/Workers/CloudflareDatabaseRuntime/node_modules/.bin/tsx" ]; then
    echo "Run npm install in Workers/CloudflareDatabaseRuntime first" >&2
    exit 1
fi

printf '%s\n' "toolchain=$expected_snapshot"
printf '%s\n' "swiftSDK=$swift_wasm_sdk"
printf '%s\n' "target=wasm32-unknown-wasip1"
printf '%s\n' "embeddedPlatform=Swift WASI SDK Embedded runtime"

"$swift_executable" build \
    --configuration release \
    --swift-sdk "$swift_wasm_sdk" \
    --target CloudflareDatabaseRuntimeVerification \
    --build-path "$build_path" \
    --disable-index-store \
    -j 1 \
    -Xswiftc -Osize \
    -Xswiftc -whole-module-optimization

if [ ! -f "$reactor_link_inputs" ]; then
    echo "The reactor link input manifest was not produced" >&2
    exit 1
fi
for required_product in \
    DatabaseTypes.o \
    DatabaseKit.o \
    DatabaseWire.o \
    QueryAST.o \
    StorageKit.o \
    CloudflareDurableObjectStorage.o \
    CloudflareDurableObjectStorageWire.o \
    CloudflareDurableObjectStorageHostTransport.o \
    DatabaseMath.o \
    DatabaseEngine.o \
    DatabaseRuntime.o \
    DatabaseServer.o \
    ScalarIndex.o \
    VectorIndex.o \
    SwiftHNSW.o \
    FullTextIndex.o \
    SpatialIndex.o \
    RankIndex.o \
    BitmapIndex.o \
    VersionIndex.o \
    PermutedIndex.o \
    AggregationIndex.o \
    LeaderboardIndex.o \
    RelationshipIndex.o \
    GraphIndex.o \
    OntologyIndex.o \
    CloudflareDatabase.o
do
    if ! grep -q "/$required_product$" "$reactor_link_inputs"; then
        echo "The Embedded reactor is missing a required runtime product: $required_product" >&2
        exit 1
    fi
done
for forbidden_product in \
    DatabaseTypesFoundation.o \
    DatabaseKitFoundation.o \
    StorageKitFoundation.o \
    StorageKitSystemClock.o \
    DatabaseServerFoundation.o \
    FDBStorage.o \
    SQLiteStorage.o \
    PostgreSQLStorage.o
do
    if grep -q "/$forbidden_product$" "$reactor_link_inputs"; then
        echo "The Embedded reactor links a forbidden adapter: $forbidden_product" >&2
        exit 1
    fi
done

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

workerd_measurements=$(
    cd "$repository_root/Workers/CloudflareDatabaseRuntime"
    DATABASE_RUNTIME_ARTIFACT="$optimized_artifact" npm run --silent smoke:workerd
)
printf '%s\n' "$workerd_measurements"

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
