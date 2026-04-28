#!/usr/bin/env bash
# Gauss Chaos — End-to-end release script
# Builds universal binary, signs (Apple + PACE), packages, notarizes, staples.
# Outputs: installer/GaussChaos-{version}-mac.pkg ready to upload to Lemon Squeezy

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
PROJECT_DIR="/Users/adrianwalther/Desktop/_Projects/Gauss DSP"
PLUGIN_DIR="$PROJECT_DIR/RandomFX"
INSTALLER_DIR="$PROJECT_DIR/installer"
AAX_SDK="$PROJECT_DIR/aax-sdk-2-9-0"
BUILD_DIR="$PLUGIN_DIR/build-universal"
ARTEFACTS="$BUILD_DIR/RandomFX_artefacts/Release"

VERSION="${VERSION:-1.0.0}"
INCLUDE_AAX="${INCLUDE_AAX:-0}"   # set INCLUDE_AAX=1 once on PACE full subscription
APP_CERT="Developer ID Application: ADRIAN DOMINIC WALTHER (9RFBFTT3MC)"
INST_CERT="Developer ID Installer: ADRIAN DOMINIC WALTHER (9RFBFTT3MC)"
PACE_WCGUID="42E04A90-32B9-11F1-8115-00505692C25A"
WRAPTOOL="/Applications/PACEAntiPiracy/Eden/Fusion/Versions/5/bin/wraptool"
NOTARY_PROFILE="notarytool"

OUTPUT_PKG="$INSTALLER_DIR/GaussChaos-$VERSION-mac.pkg"

# ── Pretty printing ──────────────────────────────────────────────────────────
log()  { printf "\033[1;36m▶ %s\033[0m\n" "$1"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$1"; }
warn() { printf "\033[1;33m⚠ %s\033[0m\n" "$1"; }
err()  { printf "\033[1;31m✗ %s\033[0m\n" "$1"; exit 1; }

# ── Pre-flight checks ────────────────────────────────────────────────────────
log "Pre-flight checks"

[ -d "$PLUGIN_DIR" ] || err "Plugin source not found: $PLUGIN_DIR"
[ -d "$AAX_SDK" ] || err "AAX SDK not found: $AAX_SDK"
[ -d "$INSTALLER_DIR/stage" ] || err "Installer stage folder missing: $INSTALLER_DIR/stage"
[ -f "$WRAPTOOL" ] || err "PACE wraptool not found: $WRAPTOOL"

security find-identity -v -p codesigning | grep -q "$APP_CERT" \
  || err "Developer ID Application cert not in keychain"
security find-identity -v | grep -q "$INST_CERT" \
  || err "Developer ID Installer cert not in keychain"

if [ "$INCLUDE_AAX" = "1" ]; then
  if ! "$WRAPTOOL" sync 2>&1 | grep -q "License Verified"; then
    err "Eden Tools license not detected. Plug in your iLok 3rd Gen and try again."
  fi
  ok "All credentials present, iLok connected (AAX enabled)"
else
  ok "All credentials present (VST3 + AU only — set INCLUDE_AAX=1 to include AAX)"
fi

# ── Step 1: Build universal binary ───────────────────────────────────────────
log "Step 1/6 — Building universal binary (arm64 + x86_64)"

CMAKE_ARGS=(-DCMAKE_BUILD_TYPE=Release
            -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
            -DCMAKE_OSX_DEPLOYMENT_TARGET="11.0")
BUILD_TARGETS=(RandomFX_VST3 RandomFX_AU)
if [ "$INCLUDE_AAX" = "1" ]; then
  CMAKE_ARGS+=(-DENABLE_AAX=ON -DAAX_SDK_PATH="$AAX_SDK")
  BUILD_TARGETS+=(RandomFX_AAX)
fi

cmake -B "$BUILD_DIR" "${CMAKE_ARGS[@]}" "$PLUGIN_DIR" \
  > /tmp/gauss-cmake-config.log 2>&1 \
  || { tail -30 /tmp/gauss-cmake-config.log; err "CMake configure failed"; }

cmake --build "$BUILD_DIR" --config Release \
  --target "${BUILD_TARGETS[@]}" -j4 \
  > /tmp/gauss-cmake-build.log 2>&1 \
  || { tail -30 /tmp/gauss-cmake-build.log; err "Build failed"; }

ok "Built universal $([ "$INCLUDE_AAX" = "1" ] && echo "VST3 + AU + AAX" || echo "VST3 + AU")"

# ── Step 2: Sign VST3 + AU with Apple Developer ID ──────────────────────────
log "Step 2/6 — Apple Developer ID signing (VST3 + AU)"

for fmt in "VST3/Gauss Chaos.vst3" "AU/Gauss Chaos.component"; do
  codesign --force --deep --sign "$APP_CERT" \
    --options runtime --timestamp \
    "$ARTEFACTS/$fmt" 2>&1 | grep -v "^$" || true
done
ok "VST3 + AU signed"

# ── Step 3: PACE-sign AAX (Apple ID + Eden dsig) ────────────────────────────
if [ "$INCLUDE_AAX" = "1" ]; then
  log "Step 3/6 — PACE Eden signing (AAX)"

  AAX_BUILT="$ARTEFACTS/AAX/Gauss Chaos.aaxplugin"

  "$WRAPTOOL" sign \
    --wcguid "$PACE_WCGUID" \
    --localonly \
    --signid "$APP_CERT" \
    --in "$AAX_BUILT" \
    --out "$AAX_BUILT" 2>&1 | grep -vE "^(Warning|Version|command-line|places|Future|  )" || true

  "$WRAPTOOL" verify --in "$AAX_BUILT" 2>&1 | grep -q "WrapInstaller" \
    || err "PACE signing did not produce a valid Eden dsig"
  ok "AAX PACE-signed"
else
  log "Step 3/6 — Skipping AAX (INCLUDE_AAX=0)"
fi

# ── Step 4: Copy signed artefacts into installer stage ──────────────────────
log "Step 4/6 — Staging signed plugins for installer"

VST3_DEST="$INSTALLER_DIR/stage/vst3/Library/Audio/Plug-Ins/VST3"
AU_DEST="$INSTALLER_DIR/stage/au/Library/Audio/Plug-Ins/Components"

rm -rf "$VST3_DEST/Gauss Chaos.vst3" "$AU_DEST/Gauss Chaos.component"
cp -R "$ARTEFACTS/VST3/Gauss Chaos.vst3"    "$VST3_DEST/"
cp -R "$ARTEFACTS/AU/Gauss Chaos.component" "$AU_DEST/"

if [ "$INCLUDE_AAX" = "1" ]; then
  AAX_DEST="$INSTALLER_DIR/stage/aax/Library/Application Support/Avid/Audio/Plug-Ins"
  rm -rf "$AAX_DEST/Gauss Chaos.aaxplugin"
  cp -R "$AAX_BUILT" "$AAX_DEST/"
fi
ok "Staged"

# ── Step 5: Build & sign component + distribution pkgs ──────────────────────
log "Step 5/6 — Building installer"

pkgbuild --root "$INSTALLER_DIR/stage/vst3" \
  --identifier "com.gaussdsp.chaos.vst3" \
  --version "$VERSION" --install-location "/" \
  --sign "$INST_CERT" \
  "$INSTALLER_DIR/pkgs/GaussChaos-VST3.pkg" > /dev/null 2>&1

pkgbuild --root "$INSTALLER_DIR/stage/au" \
  --identifier "com.gaussdsp.chaos.au" \
  --version "$VERSION" --install-location "/" \
  --sign "$INST_CERT" \
  "$INSTALLER_DIR/pkgs/GaussChaos-AU.pkg" > /dev/null 2>&1

if [ "$INCLUDE_AAX" = "1" ]; then
  pkgbuild --root "$INSTALLER_DIR/stage/aax" \
    --identifier "com.gaussdsp.chaos.aax" \
    --version "$VERSION" --install-location "/" \
    --sign "$INST_CERT" \
    "$INSTALLER_DIR/pkgs/GaussChaos-AAX.pkg" > /dev/null 2>&1
  DIST_XML="$INSTALLER_DIR/distribution-with-aax.xml"
else
  DIST_XML="$INSTALLER_DIR/distribution.xml"
fi

productbuild \
  --distribution "$DIST_XML" \
  --package-path "$INSTALLER_DIR/pkgs" \
  --sign "$INST_CERT" \
  "$OUTPUT_PKG" > /dev/null 2>&1

ok "Installer signed: $(du -h "$OUTPUT_PKG" | cut -f1)"

# ── Step 6: Notarize + staple ────────────────────────────────────────────────
log "Step 6/6 — Apple notarization (this takes ~2 min)"

NOTARY_OUT=$(xcrun notarytool submit "$OUTPUT_PKG" \
  --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)

echo "$NOTARY_OUT" | grep -q "status: Accepted" \
  || { echo "$NOTARY_OUT" | tail -10; err "Notarization failed"; }

xcrun stapler staple "$OUTPUT_PKG" > /dev/null 2>&1
xcrun stapler validate "$OUTPUT_PKG" > /dev/null 2>&1 \
  || err "Stapler validation failed"

ok "Notarized + stapled"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
printf "\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "  Release ready\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
echo "  $OUTPUT_PKG"
echo "  Size: $(du -h "$OUTPUT_PKG" | cut -f1)"
echo ""
echo "  Next: upload this .pkg to Lemon Squeezy product files"
echo ""
