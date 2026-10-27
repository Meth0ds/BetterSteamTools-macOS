#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:-"$ROOT/.build/LuaTools-macOS-development.zip"}
case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT" ;; esac
if [ "$(uname -m)" != arm64 ]; then printf '%s\n' 'Apple Silicon is required' >&2; exit 1; fi
if [ -e "$OUTPUT" ]; then printf 'Output already exists: %s\n' "$OUTPUT" >&2; exit 1; fi
mkdir -p "$(dirname -- "$OUTPUT")" "$ROOT/.build"
TEMP=$(mktemp -d "$ROOT/.build/luatools-package.XXXXXXXX")
trap 'rm -rf "$TEMP"' EXIT HUP INT TERM
swift build --package-path "$ROOT" -c release --product LuaToolsMac
swift build --package-path "$ROOT" -c release --product LuaToolsDaemon
BIN=$(swift build --package-path "$ROOT" -c release --show-bin-path)
APP="$TEMP/LuaTools.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LuaToolsMac" "$BIN/LuaToolsDaemon" "$APP/Contents/MacOS/"
ditto "$BIN/LuaToolsMac_LuaToolsMacCore.bundle" "$APP/Contents/Resources/LuaToolsMac_LuaToolsMacCore.bundle"
ditto "$ROOT/plugin-macos" "$APP/Contents/Resources/plugin-macos"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LuaToolsMac</string>
<key>CFBundleIdentifier</key><string>com.luatools.macos.development</string>
<key>CFBundleName</key><string>LuaTools</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/MacOS/LuaToolsDaemon"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/LuaToolsDaemon" --check-bundle
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP/archive.zip"
mkdir "$TEMP/verify"
ditto -x -k "$TEMP/archive.zip" "$TEMP/verify"
codesign --verify --deep --strict "$TEMP/verify/LuaTools.app"
"$TEMP/verify/LuaTools.app/Contents/MacOS/LuaToolsDaemon" --check-bundle
mv "$TEMP/archive.zip" "$OUTPUT"
shasum -a 256 "$OUTPUT"
printf '%s\n' 'Development ZIP only: ad-hoc signed, not notarized; BetterSteamTools release payload is not included.'
