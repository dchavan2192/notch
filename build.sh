#!/bin/bash
# Builds Notch.app locally with the Swift compiler and launches it.
# Requires Xcode or the Command Line Tools:  xcode-select --install
set -e
cd "$(dirname "$0")"

APP="Notch.app"
pkill -x Notch 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.2" \
  main.swift -o "$APP/Contents/MacOS/Notch"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP - launching..."
open "$APP"
