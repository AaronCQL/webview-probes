#!/bin/bash
# Builds the macOS probe executable into build/macos/probe
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/macos
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  apple/Probe.swift apple/macos/main.swift \
  -framework AppKit -framework WebKit \
  -o build/macos/probe
echo "built build/macos/probe"
