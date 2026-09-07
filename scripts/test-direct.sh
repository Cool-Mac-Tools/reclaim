#!/usr/bin/env bash
# Run the real Swift Testing suite as an executable on Command Line Tools-only Macs.
# CLT includes Testing but not Xcode's XCTest host for a .xctest bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$PWD/.build/direct-tests"
mkdir -p "$BUILD"
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
INTEROP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources/ReclaimCore -name '*.swift' | sort)
xcrun swiftc -swift-version 6 -module-cache-path "$BUILD/module-cache" -enable-testing \
  -emit-library -emit-module -module-name ReclaimCore "${SOURCES[@]}" \
  -emit-module-path "$BUILD/ReclaimCore.swiftmodule" -o "$BUILD/libReclaimCore.dylib"
cat > "$BUILD/Runner.swift" <<'SWIFT'
import Testing
@main struct Runner {
    static func main() async {
        var options = Testing.__CommandLineArguments_v0()
        options.parallel = false
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--filter"), i + 1 < arguments.count { options.filter = [arguments[i + 1]] }
        if let i = arguments.firstIndex(of: "--skip"), i + 1 < arguments.count { options.skip = [arguments[i + 1]] }
        await Testing.__swiftPMEntryPoint(passing: options) as Never
    }
}
SWIFT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$BUILD/module-cache" \
  -plugin-path /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -I "$BUILD" -L "$BUILD" -lReclaimCore -F "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$BUILD" -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$INTEROP" Tests/ReclaimCoreTests/*.swift "$BUILD/Runner.swift" \
  -o "$BUILD/ReclaimTests"
exec "$BUILD/ReclaimTests" "$@"
