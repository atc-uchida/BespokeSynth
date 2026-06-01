#!/usr/bin/env bash
set -euo pipefail

# Patch BespokeSynth/SFCBespoke fallback text renderer.
#
# Current crash:
#   DrawFallbackText -> sSimplexFont[ch - 32]
#
# If the fallback text contains UTF-8 bytes, Japanese path characters, or any byte
# outside printable ASCII, ch - 32 can become out of range and crash.
#
# Usage:
#   cd /path/to/BespokeSynth
#   bash patch_drawfallbacktext_ascii_guard.sh
#
# Optional:
#   bash patch_drawfallbacktext_ascii_guard.sh /path/to/BespokeSynth

ROOT="${1:-$(pwd)}"
cd "$ROOT"

FILE="Source/SynthGlobals.cpp"

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

path = Path("Source/SynthGlobals.cpp")
s = path.read_text(encoding="utf-8")

def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

if "SFCBespoke patch: keep fallback font renderer ASCII-safe" in s:
    print("Already patched: DrawFallbackText ASCII guard exists. 変更は行いません。")
    sys.exit(0)

old = '''void DrawFallbackText(const char* text, float posX, float posY)
{
   float scale = .5f;
   ofVec2f pen;
   pen.set(posX, posY);

   for (const auto* c = text; *c; ++c)
   {
      const auto ch = *c;

      if (ch == '\\n')
      {
         pen.set(posX, pen.y + scale * 60);
         continue;
      }

      const auto* it = sSimplexFont[ch - 32];

      const auto nvtcs = *it++;
      const auto spacing = *it++;

      auto from = ofVec2f(-1, -1);

      for (size_t i = 0; i < nvtcs; ++i)
      {
         const auto x = *it++;
         const auto y = *it++;

         const auto to = ofVec2f(x, y);

         if ((from.x != -1 || from.y != -1) && (to.x != -1 || to.y != -1))
            ofLine(pen.x + from.x * scale, pen.y - from.y * scale, pen.x + to.x * scale, pen.y - to.y * scale);

         from = to;
      }

      pen += ofVec2f(spacing * scale, 0);
   }
}
'''

new = '''void DrawFallbackText(const char* text, float posX, float posY)
{
   // SFCBespoke patch: keep fallback font renderer ASCII-safe.
   //
   // sSimplexFont only covers printable ASCII. When the fallback error text
   // contains UTF-8 bytes, e.g. Japanese path names, indexing with ch - 32 can
   // go out of range and crash before the real error message is visible.
   if (text == nullptr)
      return;

   float scale = .5f;
   ofVec2f pen;
   pen.set(posX, posY);

   for (const unsigned char* c = reinterpret_cast<const unsigned char*>(text); *c; ++c)
   {
      const unsigned char ch = *c;

      if (ch == '\\n')
      {
         pen.set(posX, pen.y + scale * 60);
         continue;
      }

      if (ch < 32 || ch > 126)
      {
         // Skip non-printable/UTF-8 continuation bytes safely.
         // Advance slightly so long paths/messages still remain readable enough
         // once ASCII portions resume.
         pen += ofVec2f(20 * scale, 0);
         continue;
      }

      const auto* it = sSimplexFont[ch - 32];

      const auto nvtcs = *it++;
      const auto spacing = *it++;

      auto from = ofVec2f(-1, -1);

      for (size_t i = 0; i < nvtcs; ++i)
      {
         const auto x = *it++;
         const auto y = *it++;

         const auto to = ofVec2f(x, y);

         if ((from.x != -1 || from.y != -1) && (to.x != -1 || to.y != -1))
            ofLine(pen.x + from.x * scale, pen.y - from.y * scale, pen.x + to.x * scale, pen.y - to.y * scale);

         from = to;
      }

      pen += ofVec2f(spacing * scale, 0);
   }
}
'''

if old not in s:
    fail("DrawFallbackText の元コードが想定と一致しません。既に変更済みか、上流のコード差分があります。")

s = s.replace(old, new, 1)
path.write_text(s, encoding="utf-8")
print("Patched: Source/SynthGlobals.cpp")
PY

echo
echo "Diff:"
git diff -- Source/SynthGlobals.cpp || true

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

"$BIN" -o layout layouts/blank.json -o audio_output_device none -o audio_input_device none

EOF
