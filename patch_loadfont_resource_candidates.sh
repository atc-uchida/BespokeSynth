#!/usr/bin/env bash
set -euo pipefail

# Patch RetinaTrueTypeFont::LoadFont to robustly locate fonts in development builds.
#
# This fixes the case where the font exists in the repo or app bundle, but the
# original LoadFont path normalization still fails and keeps mLoaded=false.
#
# Usage:
#   cd /path/to/BespokeSynth
#   bash patch_loadfont_resource_candidates.sh

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

if "#include <iostream>" not in s:
    s = s.replace('#include <VersionInfo.h>\n', '#include <VersionInfo.h>\n#include <iostream>\n', 1)

if "SFCBespoke patch: robust font lookup" in s:
    print("Already patched: robust font lookup exists. 変更は行いません。")
    path.write_text(s, encoding="utf-8")
    sys.exit(0)

old = '''void RetinaTrueTypeFont::LoadFont(std::string path)
{
   mFontPath = ofToDataPath(path);
   File file(mFontPath.c_str());
   if (file.existsAsFile())
   {
      for (int i = 0; i < (int)NanoVGRenderContext::Num; ++i) // load font in each render context
      {
         int fontHandle = nvgCreateFont(gNanoVGRenderContexts[i], path.c_str(), path.c_str());
         if (i == (int)NanoVGRenderContext::Main)
            mFontHandle = fontHandle;
         if (i == (int)NanoVGRenderContext::FontBounds)
            mFontBoundsHandle = fontHandle;
      }

      mLoaded = true;
   }
   else
   {
      mLoaded = false;
   }
}
'''

new = '''void RetinaTrueTypeFont::LoadFont(std::string path)
{
   // SFCBespoke patch: robust font lookup for local development builds.
   //
   // The original implementation only checked ofToDataPath(path), and then
   // passed the original path to nvgCreateFont(). That makes startup fragile
   // when running directly from a build tree or when the app bundle name/path
   // has been changed.
   mLoaded = false;
   mFontHandle = -1;
   mFontBoundsHandle = -1;

   juce::File inputFile(path);
   const auto fileName = inputFile.getFileName();

   std::vector<juce::File> candidates;

   if (path.empty())
      return;

   candidates.push_back(inputFile);

   if (!juce::File::isAbsolutePath(path))
   {
      candidates.push_back(juce::File(ofToDataPath(path)));
      candidates.push_back(juce::File(ofToResourcePath(path)));
   }

   candidates.push_back(juce::File::getCurrentWorkingDirectory().getChildFile("resource").getChildFile(fileName));
   candidates.push_back(juce::File::getCurrentWorkingDirectory().getChildFile("resources").getChildFile(fileName));

#if BESPOKE_MAC
   auto appFile = juce::File::getSpecialLocation(juce::File::SpecialLocationType::currentApplicationFile);
   candidates.push_back(appFile.getChildFile("Contents/Resources").getChildFile(fileName));
   candidates.push_back(appFile.getChildFile("Contents/Resources/resource").getChildFile(fileName));
   candidates.push_back(appFile.getChildFile("Contents/Resources/resources").getChildFile(fileName));
#endif

   auto exeFile = juce::File::getSpecialLocation(juce::File::SpecialLocationType::currentExecutableFile);
   candidates.push_back(exeFile.getSiblingFile(fileName));
   candidates.push_back(exeFile.getSiblingFile("resource").getChildFile(fileName));
   candidates.push_back(exeFile.getSiblingFile("resources").getChildFile(fileName));

   juce::File selected;

   for (const auto& candidate : candidates)
   {
      if (candidate.existsAsFile())
      {
         selected = candidate;
         break;
      }
   }

   if (!selected.existsAsFile())
   {
      mFontPath = candidates.empty() ? path : candidates.front().getFullPathName().toStdString();

      std::cerr << "SFCBespoke font lookup failed for: " << path << std::endl;
      for (const auto& candidate : candidates)
         std::cerr << "  tried: " << candidate.getFullPathName().toStdString() << std::endl;

      return;
   }

   mFontPath = selected.getFullPathName().toStdString();
   const auto fontName = selected.getFileName().toStdString();

   std::cerr << "SFCBespoke loading font: " << mFontPath << std::endl;

   bool loadedMainFont = false;

   for (int i = 0; i < (int)NanoVGRenderContext::Num; ++i) // load font in each render context
   {
      int fontHandle = nvgCreateFont(gNanoVGRenderContexts[i], fontName.c_str(), mFontPath.c_str());

      if (i == (int)NanoVGRenderContext::Main)
      {
         mFontHandle = fontHandle;
         loadedMainFont = fontHandle >= 0;
      }

      if (i == (int)NanoVGRenderContext::FontBounds)
         mFontBoundsHandle = fontHandle;
   }

   mLoaded = loadedMainFont;
}
'''

if old not in s:
    fail("RetinaTrueTypeFont::LoadFont の元コードが想定と一致しません。既に手修正済みか、上流差分があります。")

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

mkdir -p "$APP/Contents/Resources/resource"
rsync -a resource/ "$APP/Contents/Resources/resource/"

pkill -f SFCBespoke 2>/dev/null || true
pkill -f BespokeSynth 2>/dev/null || true
sleep 1

"$BIN" -o layout layouts/blank.json -o audio_output_device none -o audio_input_device none 2>&1 | tee /tmp/sfcbespoke_font_debug.log

EOF
