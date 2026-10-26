#!/bin/zsh
# Build Purrload.app into ./build (needs Xcode or the Command Line Tools).
#   scripts/build.sh            build only
#   scripts/build.sh --install  also copy to ~/Applications and relaunch
set -euo pipefail
ROOT=${0:A:h:h}
APP="$ROOT/build/Purrload.app"
VERSION="0.1.0"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[[ -f "$ROOT/app/Resources/AppIcon.icns" ]] && cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/engine" "$APP/Contents/Resources/purrload-engine.py"
mkdir -p "$APP/Contents/Resources/engine"      # all of it: the engine runs inspect.py
cp "$ROOT"/engine/*.py "$APP/Contents/Resources/engine/"
swiftc -O -swift-version 5 -parse-as-library "$ROOT"/app/*.swift -o "$APP/Contents/MacOS/Purrload"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Purrload</string>
  <key>CFBundleDisplayName</key><string>Purrload</string>
  <key>CFBundleIdentifier</key><string>io.github.pranil-sekuru.purrload</string>
  <key>CFBundleExecutable</key><string>Purrload</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Magnet link</string>
    <key>CFBundleURLSchemes</key><array><string>magnet</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>BitTorrent file</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Default</string>
    <key>LSItemContentTypes</key><array><string>org.bittorrent.torrent</string></array>
  </dict></array>
  <key>UTImportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>org.bittorrent.torrent</string>
    <key>UTTypeDescription</key><string>BitTorrent file</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>torrent</string></array>
      <key>public.mime-type</key><array><string>application/x-bittorrent</string></array>
    </dict>
  </dict></array>
</dict></plist>
PLIST
codesign --force -s - "$APP"     # ad-hoc signature; real releases need a Developer ID + notarization
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Purrload 2>/dev/null || true
  rm -rf "$HOME/Applications/Purrload.app"
  cp -R "$APP" "$HOME/Applications/Purrload.app"
  open "$HOME/Applications/Purrload.app"
  echo "installed ~/Applications/Purrload.app"
fi
