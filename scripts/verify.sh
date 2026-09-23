#!/usr/bin/env bash
# Verifica build y tests automáticos (Fases 0 y 1). Requiere macOS con Xcode 16+ y XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> xcodegen generate"
xcodegen generate

echo "==> Tests de LevelDeckKit"
swift test --package-path Packages/LevelDeckKit

echo "==> Tests de LevelDeckAgentKit"
swift test --package-path Packages/LevelDeckAgentKit

echo "==> Build LevelDeckAgent (macOS)"
xcodebuild -project LevelDeck.xcodeproj -scheme LevelDeckAgent \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -quiet build

echo "==> Build LevelDeck (iOS Simulator)"
xcodebuild -project LevelDeck.xcodeproj -scheme LevelDeck \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO -quiet build

echo "==> Todo OK"
