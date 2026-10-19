#!/bin/zsh
# Builds Transcriber.app and installs it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

swift build -c release --package-path Transcriber

APP=build/Transcriber.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Transcriber/.build/release/Transcriber "$APP/Contents/MacOS/"
cp transcribe.py Transcriber/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Transcriber</string>
  <key>CFBundleExecutable</key><string>Transcriber</string>
  <key>CFBundleIdentifier</key><string>local.transcriber</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.movie</string></array>
  </dict></array>
</dict></plist>
EOF
codesign --force -s - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/Transcriber.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Transcriber.app"
