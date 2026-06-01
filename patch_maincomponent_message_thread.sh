#!/usr/bin/env bash
set -euo pipefail

# Patch BespokeSynth/SFCBespoke startup so GUI/audio setup runs on the JUCE message thread,
# not on the OpenGL render thread.
#
# Usage:
#   cd /path/to/BespokeSynth
#   bash patch_maincomponent_message_thread.sh
#
# Optional:
#   bash patch_maincomponent_message_thread.sh /path/to/BespokeSynth

ROOT="${1:-$(pwd)}"
cd "$ROOT"

FILE="Source/MainComponent.cpp"

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

path = Path("Source/MainComponent.cpp")
s = path.read_text(encoding="utf-8")

def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)

def find_method(source: str, signature: str):
    start = source.find(signature)
    if start < 0:
        fail(f"method not found: {signature}")

    brace = source.find("{", start)
    if brace < 0:
        fail(f"opening brace not found for: {signature}")

    depth = 0
    i = brace
    while i < len(source):
        ch = source[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return start, brace, i + 1
        i += 1

    fail(f"closing brace not found for: {signature}")

if "void initialiseOnMessageThread()" in s:
    print("Already patched: initialiseOnMessageThread() が存在します。変更は行いません。")
    sys.exit(0)

# 1) Split MainContentComponent::initialise().
init_start, init_brace, init_end = find_method(s, "void initialise() override")
init_body = s[init_brace + 1:init_end - 1]

marker = "Push2Control::CreateStaticFramebuffer();"
marker_pos = init_body.find(marker)
if marker_pos < 0:
    fail(f"marker not found in initialise(): {marker}")

marker_end = marker_pos + len(marker)

# Keep OpenGL-context-dependent setup in initialise().
init_prefix = init_body[:marker_end]

# Move everything after Push2Control::CreateStaticFramebuffer() to the JUCE message thread.
moved_to_message_thread = init_body[marker_end:]

new_init_body = init_prefix + r'''

      juce::MessageManager::callAsync([this]
      {
         if (mDidMainThreadInitialise)
            return;

         mDidMainThreadInitialise = true;
         initialiseOnMessageThread();
      });
'''

new_initialise_method = (
    s[init_start:init_brace + 1]
    + new_init_body
    + "   }"
)

new_message_thread_method = (
    "\n\n"
    "   void initialiseOnMessageThread()\n"
    "   {\n"
    "      if (!juce::MessageManager::getInstance()->isThisTheMessageThread())\n"
    "      {\n"
    "         juce::MessageManager::callAsync([this]\n"
    "         {\n"
    "            if (!mDidMainThreadInitialise)\n"
    "            {\n"
    "               mDidMainThreadInitialise = true;\n"
    "               initialiseOnMessageThread();\n"
    "            }\n"
    "         });\n"
    "         return;\n"
    "      }\n"
    + moved_to_message_thread
    + "\n"
    "   }"
)

s = s[:init_start] + new_initialise_method + new_message_thread_method + s[init_end:]

# 2) Guard render() until message-thread setup is complete.
render_start, render_brace, render_end = find_method(s, "void render() override")
render_body = s[render_brace + 1:render_end - 1]
if "if (!mDidMainThreadInitialise)" not in render_body:
    guard = "\n      if (!mDidMainThreadInitialise)\n         return;\n"
    s = s[:render_brace + 1] + guard + s[render_brace + 1:]

# 3) Add member flag.
member_needle = "AudioDeviceConnectionState mAudioDeviceConnectionState{ AudioDeviceConnectionState::None };"
if "bool mDidMainThreadInitialise" not in s:
    if member_needle not in s:
        fail("member insertion point not found: mAudioDeviceConnectionState")
    s = s.replace(
        member_needle,
        "bool mDidMainThreadInitialise{ false };\n   " + member_needle,
        1,
    )

path.write_text(s, encoding="utf-8")
print("Patched: Source/MainComponent.cpp")
PY

echo
echo "Diff summary:"
git diff -- Source/MainComponent.cpp || true

cat <<'EOF'

次のコマンドで再ビルドしてください。

rm -rf ignore/build

cmake -Bignore/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DBESPOKE_SFC_DAW=ON \
  -DBESPOKE_PORTABLE=ON \
  -DBESPOKE_PYTHON_ROOT=/opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12 \
  -DPython_ROOT_DIR=/opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12 \
  -DPython_EXECUTABLE=/opt/homebrew/opt/python@3.12/bin/python3.12

cmake --build ignore/build --parallel 4 --config Release

APP="ignore/build/Source/BespokeSynth_artefacts/Release/SFCBespoke.app"
xattr -dr com.apple.quarantine "$APP"
codesign --force --deep --sign - "$APP"

"$APP/Contents/MacOS/SFCBespoke" -o layout layouts/blank.json

EOF
