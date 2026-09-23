#!/usr/bin/env bash
# Verifica build y tests automáticos. Requiere macOS con Xcode 16+ y XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA=build/DerivedData
PRODUCTS="$DERIVED_DATA/Build/Products"
# Marca del transporte en claro: el nombre del caso de TransportSecurity (SPEC §5.3).
INSECURE_MARKER=insecurePlaintext

echo "==> xcodegen generate"
xcodegen generate

echo "==> Tests de LevelDeckKit (incluye integración en loopback)"
swift test --package-path Packages/LevelDeckKit

echo "==> Tests de LevelDeckAgentKit"
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

# El transporte en claro existe en Debug y no puede existir en Release. El chequeo en Debug
# es el control positivo: prueba que la marca sería visible si el código estuviera compilado.
check_insecure_transport() {
  local app=$1 configuration=$2 expected=$3
  if grep -rqa "$INSECURE_MARKER" "$app"; then found=yes; else found=no; fi
  if [[ $found != "$expected" ]]; then
    echo "ERROR: transporte en claro en $app ($configuration): esperado=$expected, encontrado=$found" >&2
    exit 1
  fi
  echo "    $configuration $(basename "$app"): transporte en claro presente=$found"
}

echo "==> Transporte en claro: solo en Debug"
check_insecure_transport "$PRODUCTS/Debug/LevelDeckAgent.app" Debug yes
check_insecure_transport "$PRODUCTS/Debug-iphonesimulator/LevelDeck.app" Debug yes
check_insecure_transport "$PRODUCTS/Release/LevelDeckAgent.app" Release no
check_insecure_transport "$PRODUCTS/Release-iphonesimulator/LevelDeck.app" Release no

echo "==> Todo OK"
