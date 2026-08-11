#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift_executable=${SWIFT_EXECUTABLE:-}
swift_wasm_sdk=${SWIFT_EMBEDDED_WASM_SDK:-}
required_snapshot=swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a
required_swift_commit=ef761e567dc94ee
required_wasm_sdk=${required_snapshot}_wasm-embedded
runtime_traits=${DATABASE_RUNTIME_TRAITS:-AllRuntimeFeatures}
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

case "$runtime_traits" in
    "" | ","* | *"," | *",,"* | *[!A-Za-z,]*)
        echo "DATABASE_RUNTIME_TRAITS must be a comma-separated trait list" >&2
        exit 1
        ;;
esac
for runtime_trait in $(printf '%s' "$runtime_traits" | tr ',' ' '); do
    case "$runtime_trait" in
        AllRuntimeFeatures | ScalarIndexes | VectorIndexes | \
            FullTextIndexes | SpatialIndexes | RankIndexes | \
            BitmapIndexes | VersionIndexes | PermutedIndexes | \
            GraphIndexes | AggregationIndexes | LeaderboardIndexes | \
            Relationships | MultipleBases)
            ;;
        *)
            echo "Unknown database runtime trait: $runtime_trait" >&2
            exit 1
            ;;
    esac
done

runtime_trait_is_enabled() {
    requested_trait=$1
    if [ "$requested_trait" = "MultipleBases" ]; then
        case ",$runtime_traits," in
            *",MultipleBases,"*)
                return 0
                ;;
        esac
        return 1
    fi
    case ",$runtime_traits," in
        *",AllRuntimeFeatures,"* | *",$requested_trait,"*)
            return 0
            ;;
    esac
    if [ "$requested_trait" = "ScalarIndexes" ]; then
        case ",$runtime_traits," in
            *",GraphIndexes,"*)
                return 0
                ;;
        esac
    fi
    return 1
}

if [ -z "$swift_wasm_sdk" ]; then
    swift_wasm_sdk=$required_wasm_sdk
fi
if [ "$swift_wasm_sdk" != "$required_wasm_sdk" ]; then
    echo "The release gate requires Embedded WASI SDK $required_wasm_sdk" >&2
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
swift_version=$($swift_executable --version)
if ! printf '%s\n' "$swift_version" | grep -q \
    "Swift $required_swift_commit"; then
    echo "The release gate requires Swift compiler commit $required_swift_commit" >&2
    printf '%s\n' "$swift_version" >&2
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
printf '%s\n' "traits=$runtime_traits"

"$swift_executable" build \
    --configuration release \
    --swift-sdk "$swift_wasm_sdk" \
    --target CloudflareDatabaseRuntimeVerification \
    --disable-default-traits \
    --traits "$runtime_traits" \
    --build-path "$build_path" \
    --disable-index-store \
    -debug-info-format none \
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
    DatabaseWireRuntime.o \
    CloudflareDatabase.o
do
    if ! grep -q "/$required_product$" "$reactor_link_inputs"; then
        echo "The Embedded reactor is missing a required runtime product: $required_product" >&2
        exit 1
    fi
done

if runtime_trait_is_enabled MultipleBases; then
    runtime_multiple_bases=1
else
    runtime_multiple_bases=0
fi
if runtime_trait_is_enabled GraphIndexes; then
    runtime_graph_indexes=1
else
    runtime_graph_indexes=0
fi
if runtime_trait_is_enabled VectorIndexes; then
    runtime_vector_indexes=1
else
    runtime_vector_indexes=0
fi

required_feature_products=""
if runtime_trait_is_enabled ScalarIndexes; then
    required_feature_products="$required_feature_products ScalarIndex.o"
fi
if runtime_trait_is_enabled VectorIndexes; then
    required_feature_products="$required_feature_products VectorIndex.o SwiftHNSW.o CTurboQuantKernels.o"
fi
if runtime_trait_is_enabled FullTextIndexes; then
    required_feature_products="$required_feature_products FullTextIndex.o"
fi
if runtime_trait_is_enabled SpatialIndexes; then
    required_feature_products="$required_feature_products SpatialIndex.o"
fi
if runtime_trait_is_enabled RankIndexes; then
    required_feature_products="$required_feature_products RankIndex.o"
fi
if runtime_trait_is_enabled BitmapIndexes; then
    required_feature_products="$required_feature_products BitmapIndex.o"
fi
if runtime_trait_is_enabled VersionIndexes; then
    required_feature_products="$required_feature_products VersionIndex.o"
fi
if runtime_trait_is_enabled PermutedIndexes; then
    required_feature_products="$required_feature_products PermutedIndex.o"
fi
if runtime_trait_is_enabled GraphIndexes; then
    required_feature_products="$required_feature_products GraphIndex.o OntologyIndex.o"
fi
if runtime_trait_is_enabled AggregationIndexes; then
    required_feature_products="$required_feature_products AggregationIndex.o"
fi
if runtime_trait_is_enabled LeaderboardIndexes; then
    required_feature_products="$required_feature_products LeaderboardIndex.o"
fi
if runtime_trait_is_enabled Relationships; then
    required_feature_products="$required_feature_products RelationshipIndex.o"
fi

for required_product in $required_feature_products; do
    if ! grep -q "/$required_product$" "$reactor_link_inputs"; then
        echo "The Embedded reactor is missing a selected runtime product: $required_product" >&2
        exit 1
    fi
done

for optional_product in \
    ScalarIndex.o \
    VectorIndex.o \
    SwiftHNSW.o \
    CTurboQuantKernels.o \
    FullTextIndex.o \
    SpatialIndex.o \
    RankIndex.o \
    BitmapIndex.o \
    VersionIndex.o \
    PermutedIndex.o \
    GraphIndex.o \
    OntologyIndex.o \
    AggregationIndex.o \
    LeaderboardIndex.o \
    RelationshipIndex.o
do
    case " $required_feature_products " in
        *" $optional_product "*)
            ;;
        *)
            if grep -q "/$optional_product$" "$reactor_link_inputs"; then
                echo "The Embedded reactor links an unselected runtime product: $optional_product" >&2
                exit 1
            fi
            ;;
    esac
done

for forbidden_product in \
    DatabaseTypesFoundation.o \
    DatabaseKitFoundation.o \
    StorageKitFoundation.o \
    StorageKitSystemClock.o \
    DatabaseFoundation.o \
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
    DATABASE_RUNTIME_MULTIPLE_BASES="$runtime_multiple_bases" \
        DATABASE_RUNTIME_GRAPH_INDEXES="$runtime_graph_indexes" \
        DATABASE_RUNTIME_VECTOR_INDEXES="$runtime_vector_indexes" \
        node --import tsx \
        scripts/verify-reactor-instantiation.ts \
        "$optimized_artifact"
)
printf '%s\n' "$runtime_measurements"

workerd_measurements=$(
    cd "$repository_root/Workers/CloudflareDatabaseRuntime"
    DATABASE_RUNTIME_ARTIFACT="$optimized_artifact" \
        DATABASE_RUNTIME_MULTIPLE_BASES="$runtime_multiple_bases" \
        DATABASE_RUNTIME_GRAPH_INDEXES="$runtime_graph_indexes" \
        DATABASE_RUNTIME_VECTOR_INDEXES="$runtime_vector_indexes" \
        npm run --silent smoke:workerd
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
