#!/bin/bash
# Instala o actualiza «Uso de Claude» desde GitHub y lo deja arrancando al iniciar sesión.
# Primera instalación (una sola vez por Mac):
#   curl -fsSL https://raw.githubusercontent.com/jorgemoraz/claude-usage-widget/main/instalar.sh | bash
# Desinstalar:
#   curl -fsSL https://raw.githubusercontent.com/jorgemoraz/claude-usage-widget/main/instalar.sh | bash -s -- desinstalar
# El propio widget llama a este script con «--auto <sha>» cuando detecta una versión nueva.
set -euo pipefail

REPO="jorgemoraz/claude-usage-widget"
NAME="Uso de Claude"
BIN="ClaudeUsage"
ID="info.jorgemora.claudeusage"
DEST="$HOME/Applications/${NAME}.app"
AGENT="$HOME/Library/LaunchAgents/${ID}.plist"
SUPPORT="$HOME/Library/Application Support/ClaudeUsage"
DOMAIN="gui/$(id -u)"
MODE="${1:-}"
SHA="${2:-}"

mkdir -p "$SUPPORT"

if [[ "$MODE" == "desinstalar" ]]; then
  launchctl bootout "$DOMAIN/$ID" 2>/dev/null || true
  pkill -x "$BIN" 2>/dev/null || true
  rm -rf "$DEST" "$AGENT" "$SUPPORT"
  security delete-generic-password -s "$ID" >/dev/null 2>&1 || true
  defaults delete "$ID" >/dev/null 2>&1 || true
  echo "Desinstalado."
  exit 0
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Faltan las Command Line Tools de Xcode. Ejecuta:  xcode-select --install  y repite."
  exit 1
fi

if [[ -z "$SHA" ]]; then
  SHA="$(curl -fsSL -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/${REPO}/commits/main")"
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/${NAME}.app"
mkdir -p "$APP/Contents/MacOS"

echo "Descargando versión ${SHA:0:7}…"
curl -fsSL "https://raw.githubusercontent.com/${REPO}/${SHA}/main.swift" -o "$BUILD_DIR/main.swift"

echo "Compilando…"
if ! xcrun swiftc -O "$BUILD_DIR/main.swift" -o "$APP/Contents/MacOS/$BIN"; then
  # Si falla, se apunta para no reintentar en bucle y se deja la versión anterior funcionando
  echo "$SHA" > "$SUPPORT/failed"
  echo "Error al compilar la versión ${SHA:0:7}. Sigue instalada la anterior."
  exit 1
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
  <key>CFBundleIdentifier</key><string>${ID}</string>
  <key>CFBundleExecutable</key><string>${BIN}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHA:0:7}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "$SHA" > "$SUPPORT/version"
rm -f "$SUPPORT/failed"

NEW_PLIST="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${ID}</string>
  <key>ProgramArguments</key>
  <array><string>${DEST}/Contents/MacOS/${BIN}</string></array>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
)"

if [[ "$MODE" == "--auto" ]] && [[ -f "$AGENT" ]] && [[ "$(cat "$AGENT")" == "$NEW_PLIST" ]]; then
  # Actualización automática: reinicia el widget sin tocar el agente
  launchctl kickstart -k "$DOMAIN/$ID" >/dev/null 2>&1 || open "$DEST"
else
  launchctl bootout "$DOMAIN/$ID" 2>/dev/null || true
  pkill -x "$BIN" 2>/dev/null || true
  sleep 1
  printf '%s\n' "$NEW_PLIST" > "$AGENT"
  launchctl bootstrap "$DOMAIN" "$AGENT"
fi

echo "Listo: «${NAME}» ${SHA:0:7} instalado. Se actualizará solo desde GitHub."
