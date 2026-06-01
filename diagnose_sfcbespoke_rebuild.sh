#!/usr/bin/env bash
set -euo pipefail

# Diagnose why Source/OpenFrameworksPort.cpp changes are not appearing in SFCBespoke binary.
#
# Usage:
#   cd /path/to/BespokeSynth
#   bash diagnose_sfcbespoke_rebuild.sh

ROOT="${1:-$(pwd)}"
cd "$ROOT"

echo "== Repo =="
pwd
echo

echo "== Source patch check =="
if grep -n "SFCBespoke patch: robust font lookup" Source/OpenFrameworksPort.cpp; then
  echo "OK: robust font lookup patch exists in source."
else
  echo "ERROR: robust font lookup patch is NOT in Source/OpenFrameworksPort.cpp" >&2
  exit 1
fi

if grep -n "SFCBespoke loading font" Source/OpenFrameworksPort.cpp; then
  echo "OK: diagnostic font logging exists in source."
else
  echo "ERROR: diagnostic font logging is NOT in Source/OpenFrameworksPort.cpp" >&2
  exit 1
fi
echo

echo "== CMake source list check =="
if grep -n "OpenFrameworksPort.cpp" Source/CMakeLists.txt; then
  echo "OK: OpenFrameworksPort.cpp is listed in Source/CMakeLists.txt."
else
  echo "ERROR: OpenFrameworksPort.cpp is not listed in Source/CMakeLists.txt." >&2
  echo "This would explain why the patched file is not compiled." >&2
  exit 1
fi
echo

echo "== Remove previous build =="
rm -rf ignore/build
echo "removed ignore/build"
echo

echo "== Configure =="
cmake -Bignore/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DBESPOKE_SFC_DAW=ON \
  -DBESPOKE_PORTABLE=OFF \
  -DBESPOKE_PYTHON_ROOT=/opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12 \
  -DPython_ROOT_DIR=/opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12 \
  -DPython_EXECUTABLE=/opt/homebrew/opt/python@3.12/bin/python3.12 \
  2>&1 | tee /tmp/sfcbespoke_configure.log
echo

echo "== Build verbose =="
cmake --build ignore/build --parallel 1 --verbose 2>&1 | tee /tmp/sfcbespoke_build.log
echo

echo "== Build log OpenFrameworksPort.cpp references =="
grep -n "OpenFrameworksPort.cpp" /tmp/sfcbespoke_build.log | tail -20 || true
echo

echo "== Build artifacts containing OpenFrameworksPort =="
find ignore/build -iname "*OpenFrameworksPort*" -print || true
echo

echo "== App/binary discovery =="
find ignore/build/Source/BespokeSynth_artefacts -name "*.app" -type d -print || true
APP="$(find ignore/build/Source/BespokeSynth_artefacts -name "SFCBespoke.app" -type d -print | head -1 || true)"

if [[ -z "$APP" ]]; then
  echo "ERROR: SFCBespoke.app was not found." >&2
  exit 1
fi

BIN="$APP/Contents/MacOS/SFCBespoke"
echo "APP=$APP"
echo "BIN=$BIN"
ls -l "$BIN"
echo

echo "== Binary string check =="
if strings "$BIN" | grep -n "SFCBespoke loading font"; then
  echo "OK: patched font logging string exists in binary."
else
  echo "ERROR: patched font logging string does NOT exist in binary." >&2
  echo "This means the binary was not linked from the patched OpenFrameworksPort.cpp." >&2
  exit 2
fi
echo

echo "== Copy resources =="
mkdir -p "$APP/Contents/Resources/resource"
rsync -a resource/ "$APP/Contents/Resources/resource/"
ls -l "$APP/Contents/Resources/resource/frabk.ttf"
echo

echo "== Launch with font debug =="
pkill -f SFCBespoke 2>/dev/null || true
pkill -f BespokeSynth 2>/dev/null || true
sleep 1

"$BIN" -o layout layouts/blank.json -o audio_output_device none -o audio_input_device none 2>&1 | tee /tmp/sfcbespoke_font_debug.log
