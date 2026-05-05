#!/bin/bash
# build_helper.sh — Compila AudioTapHelper.swift antes del empaquetado
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="$SCRIPT_DIR/src/helpers/AudioTapHelper.swift"
OUT="$SCRIPT_DIR/src/helpers/AudioTapHelper"

echo "[build_helper] Compilando AudioTapHelper.swift..."
swiftc \
  -target arm64-apple-macos14.2 \
  -framework CoreAudio \
  -framework AVFoundation \
  -framework Accelerate \
  -O \
  "$SRC" \
  -o "$OUT"

echo "[build_helper] Firmando binario..."
codesign --force --sign "Apple Development: alex.gess.ag@icloud.com (BAVSE8E72G)" \
  --entitlements "$SCRIPT_DIR/entitlements.mac.plist" \
  "$OUT"

echo "[build_helper] ✅ AudioTapHelper compilado y firmado: $OUT"
