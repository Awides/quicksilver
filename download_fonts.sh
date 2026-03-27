#!/usr/bin/env bash
set -e

# Download required Iosevka and Aile fonts from official releases.
# Requires: curl, unzip

FONTS_DIR="fonts"
mkdir -p "$FONTS_DIR"

echo "=== Iosevka font downloader ==="
echo "This will download the Iosevka and Iosevka Aile .ttc files from the official GitHub releases."
echo ""

# Iosevka
if [ ! -f "$FONTS_DIR/Iosevka-Thin.ttc" ] || [ ! -f "$FONTS_DIR/Iosevka-Heavy.ttc" ]; then
    echo "Downloading Iosevka 34.2.1..."
    curl -L -o /tmp/iosevka.zip "https://github.com/be5invis/Iosevka/releases/download/34.2.1/PkgTTC-Iosevka-34.2.1.zip"
    unzip -q /tmp/iosevka.zip "*.ttc"
    mv -f "Iosevka-Thin.ttc" "$FONTS_DIR/"
    mv -f "Iosevka-Heavy.ttc" "$FONTS_DIR/"
    rm -f /tmp/iosevka.zip
    echo "Iosevka fonts installed."
else
    echo "Iosevka fonts already present."
fi

# Iosevka Aile
if [ ! -f "$FONTS_DIR/IosevkaAile-Regular.ttc" ] || [ ! -f "$FONTS_DIR/IosevkaAile-SemiBold.ttc" ]; then
    echo "Downloading Iosevka Aile 34.2.1..."
    curl -L -o /tmp/iosevka-aile.zip "https://github.com/be5invis/Iosevka/releases/download/34.2.1/PkgTTC-IosevkaAile-34.2.1.zip"
    unzip -q /tmp/iosevka-aile.zip "IosevkaAile-*.ttc"
    mv -f "IosevkaAile-Regular.ttc" "$FONTS_DIR/"
    mv -f "IosevkaAile-SemiBold.ttc" "$FONTS_DIR/"
    rm -f /tmp/iosevka-aile.zip
    echo "Iosevka Aile fonts installed."
else
    echo "Iosevka Aile fonts already present."
fi

echo ""
echo "Fonts are ready in $FONTS_DIR/"
