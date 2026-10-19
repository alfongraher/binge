#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ClangCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/SwiftCache"
drift_build_args=(-c "${BINGE_BUILD_CONFIGURATION:-release}" --disable-sandbox --cache-path "$PWD/.build/PackageCache")
swift build "${drift_build_args[@]}"
bin_path=$(swift build "${drift_build_args[@]}" --show-bin-path)
app="$PWD/build/binge.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_path/Drift" "$app/Contents/MacOS/Drift"
mkdir -p "$app/Contents/Resources"
cp -R "$PWD/Engine" "$app/Contents/Resources/"
if [[ -d "$PWD/.runtime" ]]; then
    mkdir -p "$app/Contents/Resources/Runtime"
    cp -R "$PWD/.runtime/python" "$app/Contents/Resources/Runtime/"
    mkdir -p "$app/Contents/Resources/Runtime/node_modules/ffmpeg-static"
    cp "$PWD/.runtime/node_modules/ffmpeg-static/ffmpeg" "$app/Contents/Resources/Runtime/node_modules/ffmpeg-static/"
fi
cp -R "$PWD/iPadProof/Fixture/Notices" "$app/Contents/Resources/"
cp "$PWD/Assets/binge.icns" "$app/Contents/Resources/binge.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Drift</string>
<key>CFBundleIdentifier</key><string>local.drift.app</string>
<key>CFBundleName</key><string>binge</string>
<key>CFBundleDisplayName</key><string>binge</string>
<key>CFBundleIconFile</key><string>binge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>12</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSLocalNetworkUsageDescription</key><string>binge finds your paired devices to sync viewing progress and your library on this network.</string>
<key>NSBonjourServices</key><array><string>_binge-sync._tcp</string></array>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
binge_sign_identity="${BINGE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development:/ { print $2; exit }')}"
if [[ -n "$binge_sign_identity" ]]; then
    codesign --force --deep --sign "$binge_sign_identity" "$app"
else
    codesign --force --deep --sign - "$app"
fi
printf 'App built: %s\n' "$app"
