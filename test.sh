#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/build"
swiftc -swift-version 5 -o "$DIR/build/tests" \
    "$DIR/Sources/Mapping.swift" "$DIR/Sources/Extent.swift" "$DIR/Sources/Chain.swift" "$DIR/Sources/ShiftTap.swift" \
    "$DIR/Tests/main.swift"
"$DIR/build/tests"
