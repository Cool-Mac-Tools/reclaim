#!/bin/sh
# Runs the test suite. The extra flags are needed on machines with only
# Command Line Tools (no full Xcode): CLT ships swift-testing's framework
# and interop dylib outside the default search paths.
set -e
cd "$(dirname "$0")/.."
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
    exec bash scripts/test-direct.sh "$@"
fi
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
INTEROP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F"$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    "$@"
