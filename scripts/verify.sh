#!/usr/bin/env bash
# Verifica build y tests automáticos. Requiere macOS con Xcode 16+ y XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA=build/DerivedData
PRODUCTS="$DERIVED_DATA/Build/Products"
KIT_BUILD=Packages/LevelDeckKit/.build
# Marca del transporte en claro: el nombre del caso de TransportSecurity (SPEC §5.3).
INSECURE_MARKER=insecurePlaintext

echo "==> xcodegen generate"
xcodegen generate

echo "==> Tests de LevelDeckKit (incluye integración en loopback con TLS-PSK)"
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

# El transporte en claro existe solo en el build Debug de LevelDeckKit (donde corren los
# tests) y no puede existir en las apps Release. El chequeo del build Debug del paquete es el
# control positivo: prueba que la marca sería visible si el código estuviera compilado.
check_insecure_transport() {
  local what=$1 path=$2 expected=$3
  if grep -rqa "$INSECURE_MARKER" "$path"; then found=yes; else found=no; fi
  if [[ $found != "$expected" ]]; then
    echo "ERROR: transporte en claro en $what: esperado=$expected, encontrado=$found" >&2
    exit 1
  fi
  echo "    $what: transporte en claro presente=$found"
}

echo "==> Transporte en claro: solo en el build Debug de LevelDeckKit"
check_insecure_transport "LevelDeckKit (Debug, swift test)" "$KIT_BUILD" yes
check_insecure_transport "LevelDeckAgent.app (Release)" "$PRODUCTS/Release/LevelDeckAgent.app" no
check_insecure_transport "LevelDeck.app (Release)" "$PRODUCTS/Release-iphonesimulator/LevelDeck.app" no

echo "==> Localización: textos de las apps traducidos al español"
python3 scripts/check-localizations.py

echo "==> Todo OK"
