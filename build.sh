#!/bin/zsh
set -eu
cd "${0:A:h}"
version="${VERSION:-0.1.0}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
identity="${SIGNING_IDENTITY:-}"
keychain="${SIGNING_KEYCHAIN:-}"
if [[ -z "$identity" ]]; then
  config="$HOME/.local/share/verification-code-shortcut-signing/identity.json"
  identity=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"])' "$config")
  keychain=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keychain"])' "$config")
  password_file=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["password_file"])' "$config")
  security unlock-keychain -p "$(cat "$password_file")" "$keychain"
fi
app='build/Chromakey.app'
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for arch in arm64 x86_64; do
  xcrun swiftc -Osize -whole-module-optimization -target "${arch}-apple-macos14.0" main.swift -o "build/$arch" -framework Cocoa -framework ApplicationServices -framework Carbon
done
lipo -create build/arm64 build/x86_64 -output "$app/Contents/MacOS/VerificationCodeShortcut"
strip -x "$app/Contents/MacOS/VerificationCodeShortcut"
python3 - "$app/Contents/Info.plist" "$version" "$build_number" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'local.zimeng.verification-code-shortcut','CFBundleName':'Chromakey','CFBundleDisplayName':'Chromakey','CFBundleExecutable':'VerificationCodeShortcut','CFBundlePackageType':'APPL','CFBundleVersion':sys.argv[3],'CFBundleShortVersionString':sys.argv[2],'CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSHighResolutionCapable':True},f)
PY
requirement="designated => identifier \"local.zimeng.verification-code-shortcut\" and certificate leaf = H\"$identity\""
args=(--force --sign "$identity" --timestamp=none --options runtime --requirements "=$requirement")
if [[ -n "$keychain" ]]; then args+=(--keychain "$keychain"); fi
codesign "${args[@]}" "$app"
codesign --verify --deep --strict "$app"
