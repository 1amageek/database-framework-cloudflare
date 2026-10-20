#!/bin/sh

# Builds the runtime verification reactor for standard (non-Embedded) WASI
# with GraphIndexes and executes it under the Node Durable Object host.
#
# This lane owns standard WASI graph runtime evidence. The Embedded release
# gate in verify-runtime-feasibility.sh runs the same sql:graph invocation
# without debug information, because graph-enabled Embedded debug builds do
# not terminate with Swift 6.4.0 (swiftlang/swift#93133). This lane is pinned
# to the Swift 6.4.0 release and its matching standard WASM SDK.

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
    --disable-index-store

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
