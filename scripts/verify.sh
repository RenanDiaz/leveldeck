#!/usr/bin/env bash
# Verifies the build and automated tests. Requires macOS with Xcode 16+ and XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA=build/DerivedData
PRODUCTS="$DERIVED_DATA/Build/Products"
KIT_BUILD=Packages/LevelDeckKit/.build
# Plaintext transport marker: the name of the TransportSecurity case (SPEC §5.3).
INSECURE_MARKER=insecurePlaintext

echo "==> xcodegen generate"
xcodegen generate

echo "==> LevelDeckKit tests (includes loopback integration with TLS-PSK)"
swift test --package-path Packages/LevelDeckKit

echo "==> LevelDeckAgentKit tests"
swift test --package-path Packages/LevelDeckAgentKit

build() {
  local scheme=$1 destination=$2 configuration=$3
  echo "==> Build $scheme ($configuration, $destination)"
  xcodebuild -project LevelDeck.xcodeproj -scheme "$scheme" \
    -configuration "$configuration" -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO -quiet build
}

for configuration in Debug Release; do
  build LevelDeckAgent 'generic/platform=macOS' "$configuration"
  build LevelDeck 'generic/platform=iOS Simulator' "$configuration"
done

# The plaintext transport exists only in LevelDeckKit's Debug build (where the tests run)
# and must not exist in the Release apps. The check on the package's Debug build is the
# positive control: it proves the marker would be visible if the code were compiled in.
check_insecure_transport() {
  local what=$1 path=$2 expected=$3
  if grep -rqa "$INSECURE_MARKER" "$path"; then found=yes; else found=no; fi
  if [[ $found != "$expected" ]]; then
    echo "ERROR: plaintext transport in $what: expected=$expected, found=$found" >&2
    exit 1
  fi
  echo "    $what: plaintext transport present=$found"
}

echo "==> Plaintext transport: only in LevelDeckKit's Debug build"
check_insecure_transport "LevelDeckKit (Debug, swift test)" "$KIT_BUILD" yes
check_insecure_transport "LevelDeckAgent.app (Release)" "$PRODUCTS/Release/LevelDeckAgent.app" no
check_insecure_transport "LevelDeck.app (Release)" "$PRODUCTS/Release-iphonesimulator/LevelDeck.app" no

echo "==> Localization: app strings translated to Spanish"
python3 scripts/check-localizations.py

echo "==> All OK"
