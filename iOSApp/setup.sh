#!/usr/bin/env bash
# Fetch the prebuilt Tesseract xcframework (SwiftyTesseract/libtesseract 0.2.0, ~58 MB zip) that the
# iOS app links. Only needed once; the CLI and library build without it.
set -euo pipefail
cd "$(dirname "$0")/Vendor/libtesseract"
[ -d libtesseract.xcframework ] && { echo "libtesseract.xcframework already present"; exit 0; }
URL="https://github.com/SwiftyTesseract/libtesseract/releases/download/0.2.0/libtesseract-0.2.0.xcframework.zip"
SHA="cc42f3424047adc7064e6bb67d5039385629ee42199fcbb0553f57f1110d8c90"
curl -L --fail -o lt.zip "$URL"
echo "$SHA  lt.zip" | shasum -a 256 -c -
unzip -q lt.zip && rm lt.zip
echo "installed $(pwd)/libtesseract.xcframework"
