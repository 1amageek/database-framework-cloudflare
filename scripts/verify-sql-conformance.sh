#!/bin/sh

# Builds the portable SQL conformance reactor in Verification/SQLConformance
# for standard and Embedded WASI and executes every SQL group (S05 through
# S17) under the Node Durable Object host.
#
# The fixtures use testable imports, QueryAST and the client projection
# check, so they live in a separate measurement package that resolves this
# working tree by path and never enters the release gate reactor. Debug
# builds are required by the testable imports. Both lanes are pinned to the
# Swift 6.4.0 release and its matching WASM SDKs.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package_path="$repository_root/Verification/SQLConformance"
required_release=swift-6.4.0-RELEASE
swift_executable=${SWIFT_EXECUTABLE:-"${HOME:?}/Library/Developer/Toolchains/$required_release.xctoolchain/usr/bin/swift"}
build_root=${DATABASE_SQL_CONFORMANCE_BUILD_PATH:-"$repository_root/.build/sql-conformance"}
case "$build_root" in
    /*) ;;
    *) build_root="$repository_root/$build_root" ;;
esac
lanes=${DATABASE_SQL_CONFORMANCE_LANES:-"wasm embedded"}

if [ ! -x "$swift_executable" ]; then
    echo "The SQL conformance lanes require $required_release ($swift_executable)" >&2
    exit 1
fi
if ! "$swift_executable" -print-target-info | grep -q \
    '"swiftCompilerTag": "'"$required_release"'"'; then
    echo "The SQL conformance lanes require compiler tag $required_release" >&2
    "$swift_executable" --version >&2
    exit 1
fi
if [ ! -x "$repository_root/Workers/CloudflareDatabaseRuntime/node_modules/.bin/tsx" ]; then
    echo "Run npm ci in Workers/CloudflareDatabaseRuntime first" >&2
    exit 1
fi

for lane in $lanes; do
    case "$lane" in
        wasm) swift_sdk=${required_release}_wasm ;;
        embedded) swift_sdk=${required_release}_wasm-embedded ;;
        *)
            echo "Unknown SQL conformance lane: $lane" >&2
            exit 1
            ;;
    esac
    if ! "$swift_executable" sdk list | grep -qx "$swift_sdk"; then
        echo "Swift SDK $swift_sdk is not installed" >&2
        exit 1
    fi
    build_path="$build_root/$lane"
    artifact="$build_path/wasm32-unknown-wasip1/debug/SQLConformanceVerification.wasm"

    printf '%s\n' "lane=$lane"
    printf '%s\n' "toolchain=$required_release"
    printf '%s\n' "swiftSDK=$swift_sdk"
    printf '%s\n' "target=wasm32-unknown-wasip1"

    # The native build system applies the reactor linker settings directly to
    # the debug product; its deprecation notice is expected.
    "$swift_executable" build \
        --package-path "$package_path" \
        --build-system native \
        --configuration debug \
        --swift-sdk "$swift_sdk" \
        --product SQLConformanceVerification \
        --build-path "$build_path" \
        --disable-index-store

    if [ ! -f "$artifact" ]; then
        echo "The $lane SQL conformance reactor artifact was not produced" >&2
        exit 1
    fi
    shasum -a 256 "$artifact"

    (
        cd "$repository_root/Workers/CloudflareDatabaseRuntime"
        node --import tsx scripts/verify-sql-conformance-reactor.ts "$artifact"
    )
done
