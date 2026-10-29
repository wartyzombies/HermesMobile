#!/usr/bin/env bash
# Run the full HermesMobile verification suite.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build"
swift build 2>&1 | tee log-build.txt

echo "==> swift test"
swift test 2>&1 | tee log-test.txt

echo "==> xcodebuild (iOS Simulator)"
xcodebuild -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tee log-xcode.txt

echo "All checks passed."
