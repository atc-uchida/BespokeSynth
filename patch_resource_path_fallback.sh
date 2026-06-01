#!/usr/bin/env bash
set -euo pipefail

# Patch BespokeSynth resource path resolution for SFCBespoke development builds.
#
# The app may still fail to load fonts even when resources have been copied into
# the bundle, because ofToResourcePath() only uses the app-bundle factory path.
# This patch makes ofToResourcePath() try:
#
#   1. absolute paths as-is
#   2. <current working dir>/resource/<file>
#   3. <current working dir>/resources/<file>
#   4. app bundle Contents/Resources/resource/<file>
#   5. executable sibling resource/<file>
#
# This is intentionally development-friendly and keeps the original bundle path
# as the final fallback.
#
# Usage:
#   cd /path/to/BespokeSynth
#   bash patch_resource_path_fallback.sh

ROOT="${1:-$(pwd)}"
cd "$ROOT"

FILE="Source/OpenFrameworksPort.cpp"

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: $FILE が見つかりません。BespokeSynthのリポジトリ直下で実行してください。" >&2
  exit 1
fi

BACKUP="${FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$FILE" "$BACKUP"
echo "Backup: $BACKUP"

python3 - <<'PY'
from pathlib import Path
import sys

path = Path("Source/OpenFrameworksPort.cpp")
s = path.read_text(encoding="utf-8")

def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

if "SFCBespoke patch: robust resource lookup" in s:
    print("Already patched: robust resource lookup exists. 変更は行いません。")
    sys.exit(0)

old = '''std::string ofToResourcePath(const std::string& path)
{
   if (!path.empty() && (path[0] == '.' || juce::File::isAbsolutePath(path)))
      return path;

   static const auto sResourceDir = ofToFactoryPath("resource") + '/';
   return sResourceDir + path;
}
'''

new = '''std::string ofToResourcePath(const std::string& path)
{
   // SFCBespoke patch: robust resource lookup for local development builds.
   //
   // Original Bespoke expects bundled resources at:
   //   <App>.app/Contents/Resources/resource/<file>
   //
   // During fork/development builds, the bundle path can vary and direct
   // execution from Terminal is common, so also allow resources to be loaded
   // from the repository working directory.
   if (!path.empty() && (path[0] == '.' || juce::File::isAbsolutePath(path)))
      return path;

   auto cwdResource = juce::File::getCurrentWorkingDirectory().getChildFile("resource").getChildFile(path);
   if (cwdResource.existsAsFile())
      return cwdResource.getFullPathName().toStdString();

   auto cwdResources = juce::File::getCurrentWorkingDirectory().getChildFile("resources").getChildFile(path);
   if (cwdResources.existsAsFile())
      return cwdResources.getFullPathName().toStdString();

#if BESPOKE_MAC
   auto bundleResource = juce::File::getSpecialLocation(juce::File::SpecialLocationType::currentApplicationFile)
                            .getChildFile("Contents/Resources/resource")
                            .getChildFile(path);
   if (bundleResource.existsAsFile())
      return bundleResource.getFullPathName().toStdString();
#endif

   auto exeSiblingResource = juce::File::getSpecialLocation(juce::File::SpecialLocationType::currentExecutableFile)
                                .getSiblingFile("resource")
                                .getChildFile(path);
   if (exeSiblingResource.existsAsFile())
      return exeSiblingResource.getFullPathName().toStdString();

   try
   {
      static const auto sResourceDir = ofToFactoryPath("resource") + '/';
      return sResourceDir + path;
   }
   catch (...)
   {
      return cwdResource.getFullPathName().toStdString();
   }
}
'''

if old not in s:
    fail("ofToResourcePath の元コードが想定と一致しません。既に変更済みか、上流差分があります。")

s = s.replace(old, new, 1)
path.write_text(s, encoding="utf-8")
print("Patched: Source/OpenFrameworksPort.cpp")
PY

echo
echo "Diff:"
git diff -- Source/OpenFrameworksPort.cpp || true

cat <<'EOF'

次のコマンドで再ビルドしてください。

rm -rf ignore/build

cmake -Bignore/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DBESPOKE_SFC_DAW=ON \
  -DBESPOKE_PORTABLE=OFF \
  -DBESPOKE_PYTHON_ROOT=/opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12 \
  -DPython_ROOT_DIR=/opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12 \
  -DPython_EXECUTABLE=/opt/homebrew/opt/python@3.12/bin/python3.12

cmake --build ignore/build --parallel 4 --config Release

APP="ignore/build/Source/BespokeSynth_artefacts/Release/SFCBespoke.app"
BIN="$APP/Contents/MacOS/SFCBespoke"

# 念のためbundleにもresourceを入れる
mkdir -p "$APP/Contents/Resources/resource"
rsync -a resource/ "$APP/Contents/Resources/resource/"

pkill -x SFCBespoke 2>/dev/null || true
"$BIN" -o layout layouts/blank.json -o audio_output_device none -o audio_input_device none

EOF
