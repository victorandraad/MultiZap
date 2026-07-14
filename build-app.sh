#!/bin/bash
# Compila o MultiZap e monta um MultiZap.app pronto pra usar.
set -e

cd "$(dirname "$0")"

APP_NAME="MultiZap"
BUNDLE_ID="com.victor.multizap"
BUILD_DIR=".build/release"
APP_DIR="$APP_NAME.app"

echo "==> Compilando (release)..."
swift build -c release

echo "==> Montando $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Ícone do app (se existir).
if [ -f assets/AppIcon.icns ]; then
    cp assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSCameraUsageDescription</key>       <string>Para chamadas de vídeo no WhatsApp.</string>
    <key>NSMicrophoneUsageDescription</key>   <string>Para chamadas de voz e vídeo no WhatsApp.</string>
</dict>
</plist>
PLIST

# Assina com a identidade estável (se existir), senão cai no ad-hoc.
IDENTITY="MultiZap Local"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> Assinando com \"$IDENTITY\" (estável)..."
    codesign --force --deep --sign "$IDENTITY" "$APP_DIR" >/dev/null 2>&1 || true
else
    echo "==> Sem certificado estável — assinando ad-hoc."
    echo "    (rode ./setup-signing.sh uma vez pra parar de pedir senha do Keychain)"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo ""
echo "Pronto! Abra com:  open $APP_DIR"
