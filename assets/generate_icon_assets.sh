#!/bin/bash
# ============================================================
# generate_icon_assets.sh
# Genera las variantes multi-resolución de macOS a partir del
# icono PNG de alta resolución usando sips y actualiza el
# Contents.json de Assets.xcassets para Xcode.
#
# 100% PORTABLE Y AUTÓNOMO (Sin referencias externas)
# ============================================================
set -e

# Obtener rutas relativas al script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

SOURCE_IMAGE="$PROJECT_ROOT/assets/icon.png"
TARGET_DIR="$PROJECT_ROOT/EstudioAg/EstudioAg/EstudioAg/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "❌ ERROR: No se encontró el icono origen en: $SOURCE_IMAGE"
    exit 1
fi

echo "🎨 Generando variantes de iconos usando sips..."
mkdir -p "$TARGET_DIR"

sips -z 16 16 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_512x512@2x.png" >/dev/null
sips -z 1024 1024 "$SOURCE_IMAGE" --out "$TARGET_DIR/icon_1024x1024.png" >/dev/null

echo "📝 Escribiendo Contents.json actualizado sin advertencias..."
cat << 'EOF' > "$TARGET_DIR/Contents.json"
{
  "images" : [
    {
      "filename" : "icon_1024x1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "✅ Proceso completado. Iconos generados con éxito en Assets.xcassets de forma autónoma."
