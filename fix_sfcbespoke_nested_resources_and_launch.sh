#!/usr/bin/env bash
set -euo pipefail

# Correct BespokeSynth resource placement for macOS app bundles.
#
# Bespoke's ofToResourcePath("frabk.ttf") resolves to:
#   <App>.app/Contents/Resources/resource/frabk.ttf
#
# Therefore copying files directly into Contents/Resources is not enough.
#
# Usage:
#   cd /path/to/BespokeSynth
#   bash fix_sfcbespoke_nested_resources_and_launch.sh
#
# Optional:
#   bash fix_sfcbespoke_nested_resources_and_launch.sh /path/to/BespokeSynth

ROOT="${1:-$(pwd)}"
cd "$ROOT"

echo "Repo: $PWD"

APP_DEFAULT="ignore/build/Source/BespokeSynth_artefacts/Release/SFCBespoke.app"

if [[ -d "$APP_DEFAULT" ]]; then
  APP="$APP_DEFAULT"
else
  APP="$(find ignore/build/Source/BespokeSynth_artefacts -name "SFCBespoke.app" -type d 2>/dev/null | head -1 || true)"
fi

if [[ -z "${APP:-}" || ! -d "$APP" ]]; then
  echo "ERROR: SFCBespoke.app が見つかりません。" >&2
  exit 1
fi

BIN="$APP/Contents/MacOS/SFCBespoke"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: 実行ファイルが見つかりません: $BIN" >&2
  exit 1
fi

if [[ ! -d "resource" ]]; then
  echo "ERROR: resource/ ディレクトリが見つかりません。BespokeSynthリポジトリ直下で実行してください。" >&2
  exit 1
fi

DEST="$APP/Contents/Resources/resource"

echo "App:  $APP"
echo "From: resource/"
echo "To:   $DEST"

echo
echo "Copying resource/ into Contents/Resources/resource/ ..."
mkdir -p "$DEST"
rsync -a --delete resource/ "$DEST"/

echo
echo "Checking required fonts at the exact expected location..."
for f in frabk.ttf frabk_m.ttf iosevka-type-light.ttf; do
  if [[ ! -f "$DEST/$f" ]]; then
    echo "ERROR: $DEST/$f が見つかりません。" >&2
    exit 1
  fi
  ls -l "$DEST/$f"
done

echo
echo "Stopping stale SFCBespoke processes..."
pkill -x SFCBespoke 2>/dev/null || true
sleep 1

echo
echo "Launching..."
echo "$BIN -o layout layouts/blank.json -o audio_output_device none -o audio_input_device none"
"$BIN" -o layout layouts/blank.json -o audio_output_device none -o audio_input_device none
