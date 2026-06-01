#!/usr/bin/env bash
set -euo pipefail

# Copy BespokeSynth resources into the generated SFCBespoke.app bundle,
# verify required fonts, terminate any stale running instance, and relaunch.
#
# Usage:
#   cd /path/to/BespokeSynth
#   bash fix_sfcbespoke_resources_and_launch.sh
#
# Optional:
#   bash fix_sfcbespoke_resources_and_launch.sh /path/to/BespokeSynth

ROOT="${1:-$(pwd)}"
cd "$ROOT"

echo "Repo: $PWD"

# Locate app bundle.
APP_DEFAULT="ignore/build/Source/BespokeSynth_artefacts/Release/SFCBespoke.app"

if [[ -d "$APP_DEFAULT" ]]; then
  APP="$APP_DEFAULT"
else
  APP="$(find ignore/build/Source/BespokeSynth_artefacts -name "SFCBespoke.app" -type d 2>/dev/null | head -1 || true)"
fi

if [[ -z "${APP:-}" || ! -d "$APP" ]]; then
  echo "ERROR: SFCBespoke.app が見つかりません。先にReleaseビルドを実行してください。" >&2
  exit 1
fi

BIN="$APP/Contents/MacOS/SFCBespoke"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: 実行ファイルが見つかりません: $BIN" >&2
  exit 1
fi

# Locate resource source directory.
if [[ -d "resource" ]]; then
  RESOURCE_SRC="resource"
elif [[ -d "resources" ]]; then
  RESOURCE_SRC="resources"
else
  echo "ERROR: resource/ または resources/ ディレクトリが見つかりません。" >&2
  echo "現在の場所がBespokeSynthリポジトリ直下か確認してください。" >&2
  exit 1
fi

echo "App: $APP"
echo "Resource source: $RESOURCE_SRC"

echo
echo "Checking source fonts..."
for f in frabk.ttf frabk_m.ttf iosevka-type-light.ttf; do
  if [[ ! -f "$RESOURCE_SRC/$f" ]]; then
    echo "ERROR: $RESOURCE_SRC/$f が見つかりません。" >&2
    echo "次で実際の場所を確認してください:" >&2
    echo "  find . -name '$f'" >&2
    exit 1
  fi
  ls -l "$RESOURCE_SRC/$f"
done

echo
echo "Copying resources into app bundle..."
mkdir -p "$APP/Contents/Resources"
rsync -a "$RESOURCE_SRC"/ "$APP/Contents/Resources"/

echo
echo "Checking bundled fonts..."
for f in frabk.ttf frabk_m.ttf iosevka-type-light.ttf; do
  if [[ ! -f "$APP/Contents/Resources/$f" ]]; then
    echo "ERROR: コピー後も $APP/Contents/Resources/$f が見つかりません。" >&2
    exit 1
  fi
  ls -l "$APP/Contents/Resources/$f"
done

echo
echo "Removing quarantine xattr if present..."
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo
echo "Stopping stale SFCBespoke processes..."
pkill -x SFCBespoke 2>/dev/null || true
sleep 1

echo
echo "Launching..."
echo "$BIN -o layout layouts/blank.json -o audio_output_device none -o audio_input_device none"
"$BIN" -o layout layouts/blank.json -o audio_output_device none -o audio_input_device none
