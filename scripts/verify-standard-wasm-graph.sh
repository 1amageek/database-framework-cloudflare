#!/bin/sh

# Builds the runtime verification reactor for standard (non-Embedded) WASI
# with GraphIndexes and executes it under the Node Durable Object host.
#
# Graph-enabled Embedded builds do not terminate with Swift 6.4.0 because of
# swiftlang/swift#93133, so this lane owns graph runtime evidence until a
# pinned 6.4.x release carries that fix. It is pinned to the Swift 6.4.0
# release and its matching standard WASM SDK, separately from the Embedded
# release gate in verify-runtime-feasibility.sh.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
required_release=swift-6.4.0-RELEASE
required_wasm_sdk=${required_release}_wasm
swift_executable=${SWIFT_EXECUTABLE:-"${HOME:?}/Library/Developer/Toolchains/$required_release.xctoolchain/usr/bin/swift"}
build_path=${DATABASE_RUNTIME_BUILD_PATH:-"$repository_root/.build/standard-wasm-graph"}
case "$build_path" in
    /*) ;;
    *) build_path="$repository_root/$build_path" ;;
esac
artifact="$build_path/wasm32-unknown-wasip1/debug/CloudflareDatabaseRuntimeVerification.wasm"

if [ ! -x "$swift_executable" ]; then
    echo "The standard WASM graph lane requires $required_release ($swift_executable)" >&2
    exit 1
fi
if ! "$swift_executable" -print-target-info | grep -q \
    '"swiftCompilerTag": "'"$required_release"'"'; then
    echo "The standard WASM graph lane requires compiler tag $required_release" >&2
    "$swift_executable" --version >&2
    exit 1
fi
if ! "$swift_executable" sdk list | grep -qx "$required_wasm_sdk"; then
    echo "Swift SDK $required_wasm_sdk is not installed" >&2
    exit 1
fi

# Package.swift links swiftUnicodeDataTables for every WASI build. The
# standard SDK ships that archive only beside its Embedded libraries.
unicode_data_directory=
for sdk_root in "$HOME/Library/org.swift.swiftpm/swift-sdks" "$HOME/.swiftpm/swift-sdks"; do
    candidate="$sdk_root/$required_wasm_sdk.artifactbundle/$required_wasm_sdk/wasm32-unknown-wasip1/swift.xctoolchain/usr/lib/swift/embedded/wasm32-unknown-wasip1"
    if [ -f "$candidate/libswiftUnicodeDataTables.a" ]; then
        unicode_data_directory=$candidate
        break
    fi
done
if [ -z "$unicode_data_directory" ]; then
    echo "libswiftUnicodeDataTables.a was not found in $required_wasm_sdk" >&2
    exit 1
fi
if [ ! -x "$repository_root/Workers/CloudflareDatabaseRuntime/node_modules/.bin/tsx" ]; then
    echo "Run npm ci in Workers/CloudflareDatabaseRuntime first" >&2
    exit 1
fi

printf '%s\n' "toolchain=$required_release"
printf '%s\n' "swiftSDK=$required_wasm_sdk"
printf '%s\n' "target=wasm32-unknown-wasip1"
printf '%s\n' "traits=GraphIndexes"

# The native build system applies the package's reactor linker settings
# directly to the debug product. SwiftPM reports it as deprecated; that notice
# is expected until this lane adopts the release gate's relink procedure.

"$swift_executable" build \
    --build-system native \
    --configuration debug \
    --swift-sdk "$required_wasm_sdk" \
    --product CloudflareDatabaseRuntimeVerification \
    --disable-default-traits \
    --traits GraphIndexes \
    --build-path "$build_path" \
    --disable-index-store \
    -Xlinker -L -Xlinker "$unicode_data_directory"

if [ ! -f "$artifact" ]; then
    echo "The standard WASM reactor artifact was not produced" >&2
    exit 1
fi
shasum -a 256 "$artifact"

cd "$repository_root/Workers/CloudflareDatabaseRuntime"
DATABASE_RUNTIME_MULTI_BASE=0 \
DATABASE_RUNTIME_GRAPH_INDEXES=1 \
DATABASE_RUNTIME_VECTOR_INDEXES=0 \
    node --import tsx scripts/verify-reactor-instantiation.ts "$artifact"
