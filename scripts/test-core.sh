#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
plugin="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
flags=()
if [[ -r "$plugin" ]]; then flags=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
swift test "${flags[@]}" --disable-sandbox --disable-xctest --cache-path "$PWD/.build/cache" -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH" "$@"
