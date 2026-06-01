#!/usr/bin/env bash
set -euo pipefail

if [ ! -f "Source/CMakeLists.txt" ] || [ ! -f "Source/ModuleFactory.cpp" ]; then
  echo "Run this script from the BespokeSynth repository root." >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path

root = Path('.')

def replace_once(path, old, new):
    p = root / path
    text = p.read_text()
    if new in text:
        return
    if old not in text:
        raise SystemExit(f"Pattern not found in {path}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))

# 1) Top-level CMake: add SFC variant metadata without renaming the CMake target.
replace_once(
    'CMakeLists.txt',
    'option(BESPOKE_USE_ASAN "Build with ASAN" OFF)\n',
    '''option(BESPOKE_USE_ASAN "Build with ASAN" OFF)\noption(BESPOKE_SFC_DAW "Build the SFC-focused Bespoke fork" OFF)\nset(BESPOKE_APP_NAME "BespokeSynth" CACHE STRING "Application display name")\nset(BESPOKE_BUNDLE_ID "com.ryanchallinor.bespokesynth" CACHE STRING "Application bundle identifier")\nset(BESPOKE_ICON "${CMAKE_SOURCE_DIR}/bespoke_icon.png" CACHE STRING "Application icon path")\nif(BESPOKE_SFC_DAW)\n    set(BESPOKE_APP_NAME "SFCBespoke" CACHE STRING "Application display name" FORCE)\n    set(BESPOKE_BUNDLE_ID "com.pepsico4646.sfcbespoke" CACHE STRING "Application bundle identifier" FORCE)\n    set(BESPOKE_ICON "${CMAKE_SOURCE_DIR}/sfcbespoke_icon.png" CACHE STRING "Application icon path" FORCE)\nendif()\n'''
)

# 2) VersionInfo: make JUCE application name match the SFC variant.
replace_once(
    'Source/VersionInfo.cpp.in',
    '    const char* APP_NAME = "@CMAKE_PROJECT_NAME@";\n',
    '    const char* APP_NAME = "@BESPOKE_APP_NAME@";\n'
)

# 3) Main window title/settings name.
replace_once(
    'Source/Main.cpp',
    '      mainWindow = std::make_unique<MainWindow>("bespoke synth");\n',
    '      mainWindow = std::make_unique<MainWindow>(Bespoke::APP_NAME);\n'
)
replace_once(
    'Source/Main.cpp',
    '      options.applicationName = "Bespoke Synth";\n',
    '      options.applicationName = Bespoke::APP_NAME;\n'
)

# 4) Source CMake: product name, icon, bundle id, compile definition, sources.
replace_once(
    'Source/CMakeLists.txt',
    '''juce_add_gui_app(BespokeSynth\n    PRODUCT_NAME BespokeSynth\n    ICON_BIG ${CMAKE_SOURCE_DIR}/bespoke_icon.png\n''',
    '''juce_add_gui_app(BespokeSynth\n    PRODUCT_NAME ${BESPOKE_APP_NAME}\n    ICON_BIG ${BESPOKE_ICON}\n'''
)
replace_once(
    'Source/CMakeLists.txt',
    '    BUNDLE_ID                     com.ryanchallinor.bespokesynth\n',
    '    BUNDLE_ID                     ${BESPOKE_BUNDLE_ID}\n'
)
replace_once(
    'Source/CMakeLists.txt',
    '    SignalGenerator.cpp\n    SignalGenerator.h\n',
    '    SignalGenerator.cpp\n    SignalGenerator.h\n    SFCSynth.cpp\n    SFCSynth.h\n'
)
replace_once(
    'Source/CMakeLists.txt',
    '''if(BESPOKE_PORTABLE)\n    set_source_files_properties(ScriptModule.cpp PROPERTIES\n        COMPILE_DEFINITIONS BESPOKE_PORTABLE_PYTHON="$<IF:$<BOOL:${WIN32}>,python.exe,bin/python>"\n        )\nendif()\n''',
    '''if(BESPOKE_PORTABLE)\n    set_source_files_properties(ScriptModule.cpp PROPERTIES\n        COMPILE_DEFINITIONS BESPOKE_PORTABLE_PYTHON="$<IF:$<BOOL:${WIN32}>,python.exe,bin/python>"\n        )\nendif()\n\nif(BESPOKE_SFC_DAW)\n    target_compile_definitions(BespokeSynth PRIVATE BESPOKE_SFC_DAW=1)\nendif()\n'''
)
replace_once(
    'Source/CMakeLists.txt',
    '    JUCE_JACK_CLIENT_NAME="BespokeSynth"\n',
    '    JUCE_JACK_CLIENT_NAME="${BESPOKE_APP_NAME}"\n'
)

# 5) Default layout for SFC mode.
replace_once(
    'Source/UserPrefs.h',
    '   UserPrefString layout{ "layout", "layouts/blank.json", 70, UserPrefCategory::Paths };\n',
    '''#if BESPOKE_SFC_DAW\n   UserPrefString layout{ "layout", "layouts/sfc_default.json", 70, UserPrefCategory::Paths };\n#else\n   UserPrefString layout{ "layout", "layouts/blank.json", 70, UserPrefCategory::Paths };\n#endif\n'''
)

# 6) ModuleFactory: register a small SFC-focused module set when BESPOKE_SFC_DAW=ON.
replace_once(
    'Source/ModuleFactory.cpp',
    '#include "SignalGenerator.h"\n',
    '#include "SignalGenerator.h"\n#include "SFCSynth.h"\n'
)
replace_once(
    'Source/ModuleFactory.cpp',
    'ModuleFactory::ModuleFactory()\n{\n   REGISTER(LooperRecorder, looperrecorder, kModuleCategory_Audio);\n',
    '''ModuleFactory::ModuleFactory()\n{\n#if BESPOKE_SFC_DAW\n   REGISTER(NoteCanvas, notecanvas, kModuleCategory_Instrument);\n   REGISTER(NoteStepSequencer, notesequencer, kModuleCategory_Instrument);\n   REGISTER(StepSequencer, drumsequencer, kModuleCategory_Instrument);\n   REGISTER(SFCSynth, sfcsynth, kModuleCategory_Synth);\n   REGISTER(Sampler, sampler, kModuleCategory_Synth);\n   REGISTER(SamplePlayer, sampleplayer, kModuleCategory_Synth);\n   REGISTER(Amplifier, gain, kModuleCategory_Audio);\n   REGISTER(Panner, panner, kModuleCategory_Audio);\n   REGISTER(Splitter, splitter, kModuleCategory_Audio);\n   REGISTER(MultitapDelay, multitapdelay, kModuleCategory_Audio);\n   REGISTER(EQModule, eq, kModuleCategory_Audio);\n   REGISTER(AudioMeter, audiometer, kModuleCategory_Audio);\n   REGISTER(InputChannel, input, kModuleCategory_Audio);\n   REGISTER(OutputChannel, output, kModuleCategory_Audio);\n   REGISTER(CommentDisplay, comment, kModuleCategory_Other);\n   REGISTER(LabelDisplay, label, kModuleCategory_Other);\n   REGISTER(Metronome, metronome, kModuleCategory_Synth);\n   REGISTER(TapTempo, taptempo, kModuleCategory_Other);\n   return;\n#endif\n\n   REGISTER(LooperRecorder, looperrecorder, kModuleCategory_Audio);\n'''
)

# 7) New SFCSynth module files.
(root / 'Source/SFCSynth.h').write_text(r'''#pragma once

#include "IAudioSource.h"
#include "INoteReceiver.h"
#include "IDrawableModule.h"
#include "Slider.h"

#include <array>
#include <cstdint>

class SFCSynth : public IAudioSource,
                 public INoteReceiver,
                 public IDrawableModule,
                 public IFloatSliderListener
{
public:
   SFCSynth();
   ~SFCSynth() override;

   static IDrawableModule* Create() { return new SFCSynth(); }
   static bool AcceptsAudio() { return false; }
   static bool AcceptsNotes() { return true; }
   static bool AcceptsPulses() { return false; }

   void CreateUIControls() override;

   // IAudioSource
   void Process(double time) override;

   // INoteReceiver
   void PlayNote(NoteMessage note) override;
   void SendCC(int control, int value, int voiceIdx = -1) override {}

   // IFloatSliderListener
   void FloatSliderUpdated(FloatSlider* slider, float oldVal, double time) override {}

   void SetEnabled(bool enabled) override { mEnabled = enabled; }
   bool IsEnabled() const override { return mEnabled; }

private:
   enum class Stage
   {
      Off,
      Attack,
      Sustain,
      Release
   };

   struct Voice
   {
      Stage stage{ Stage::Off };
      int pitch{ -1 };
      float velocity{ 0 };
      float phase{ 0 };
      float phaseInc{ 0 };
      float env{ 0 };
      float releaseStart{ 0 };
      uint64_t age{ 0 };
   };

   void DrawModule() override;
   void GetModuleDimensions(float& width, float& height) override;

   void StartVoice(const NoteMessage& note);
   void ReleaseVoice(int pitch);
   float RenderVoice(Voice& voice);
   void BuildWaveTable();

   static constexpr int kNumVoices = 8;
   static constexpr int kWaveTableSize = 32;

   std::array<Voice, kNumVoices> mVoices;
   std::array<float, kWaveTableSize> mWaveTable{};

   float mVolume{ 0.7f };
   float mAttackMs{ 2.0f };
   float mReleaseMs{ 90.0f };
   float mTone{ 0.65f };

   FloatSlider* mVolumeSlider{ nullptr };
   FloatSlider* mAttackSlider{ nullptr };
   FloatSlider* mReleaseSlider{ nullptr };
   FloatSlider* mToneSlider{ nullptr };

   float* mWriteBuffer{ nullptr };
   bool mEnabled{ true };
   uint64_t mVoiceAgeCounter{ 0 };
};
''')

(root / 'Source/SFCSynth.cpp').write_text(r'''#include "SFCSynth.h"

#include "IAudioReceiver.h"
#include "SynthGlobals.h"
#include "UIControlMacros.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace
{
   float MidiPitchToHz(int pitch)
   {
      return 440.0f * std::pow(2.0f, (pitch - 69) / 12.0f);
   }

   float ClampFloat(float value, float low, float high)
   {
      return std::max(low, std::min(high, value));
   }
}

SFCSynth::SFCSynth()
{
   mWriteBuffer = new float[gBufferSize];
   BuildWaveTable();
}

SFCSynth::~SFCSynth()
{
   delete[] mWriteBuffer;
}

void SFCSynth::BuildWaveTable()
{
   // A deliberately tiny looping "sample" table. This is not BRR yet; it is the
   // first SFC-like constraint layer: short sample, 8 voices, coarse amplitude.
   for (int i = 0; i < kWaveTableSize; ++i)
   {
      const float phase = static_cast<float>(i) / static_cast<float>(kWaveTableSize);
      const float square = phase < 0.5f ? 1.0f : -1.0f;
      const float triangle = 1.0f - 4.0f * std::fabs(phase - 0.5f);
      const float blended = square * mTone + triangle * (1.0f - mTone);
      mWaveTable[i] = std::round(blended * 31.0f) / 31.0f;
   }
}

void SFCSynth::CreateUIControls()
{
   IDrawableModule::CreateUIControls();

   UIBLOCK0();
   UIBLOCK_PUSHSLIDERWIDTH(150);
   FLOATSLIDER(mVolumeSlider, "vol", &mVolume, 0, 1);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mAttackSlider, "atk", &mAttackMs, 0, 120);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mReleaseSlider, "rel", &mReleaseMs, 5, 500);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mToneSlider, "tone", &mTone, 0, 1);
   ENDUIBLOCK0();
}

void SFCSynth::Process(double time)
{
   IAudioReceiver* target = GetTarget();

   if (!mEnabled || target == nullptr)
      return;

   BuildWaveTable();

   ChannelBuffer* buffer = target->GetBuffer();
   const int bufferSize = buffer->BufferSize();
   float* out = buffer->GetChannel(0);

   Clear(mWriteBuffer, bufferSize);

   for (int pos = 0; pos < bufferSize; ++pos)
   {
      ComputeSliders(pos);

      float sample = 0;
      int activeVoices = 0;

      for (auto& voice : mVoices)
      {
         if (voice.stage == Stage::Off)
            continue;

         sample += RenderVoice(voice);
         ++activeVoices;
      }

      // Coarse amplitude quantisation to keep the first version chippy.
      sample *= mVolume * 0.18f;
      sample = std::round(sample * 127.0f) / 127.0f;
      mWriteBuffer[pos] = ClampFloat(sample, -1.0f, 1.0f);

      (void)activeVoices;
      time += gInvSampleRateMs;
   }

   GetVizBuffer()->WriteChunk(mWriteBuffer, bufferSize, 0);
   Add(out, mWriteBuffer, bufferSize);
}

float SFCSynth::RenderVoice(Voice& voice)
{
   const float attackSamples = std::max(1.0f, mAttackMs * 0.001f * gSampleRate);
   const float releaseSamples = std::max(1.0f, mReleaseMs * 0.001f * gSampleRate);

   if (voice.stage == Stage::Attack)
   {
      voice.env += 1.0f / attackSamples;
      if (voice.env >= 1.0f)
      {
         voice.env = 1.0f;
         voice.stage = Stage::Sustain;
      }
   }
   else if (voice.stage == Stage::Release)
   {
      voice.env -= voice.releaseStart / releaseSamples;
      if (voice.env <= 0.0f)
      {
         voice.env = 0.0f;
         voice.stage = Stage::Off;
         return 0;
      }
   }

   const int index = static_cast<int>(voice.phase * kWaveTableSize) % kWaveTableSize;
   const float sample = mWaveTable[index] * voice.env * voice.velocity;

   voice.phase += voice.phaseInc;
   while (voice.phase >= 1.0f)
      voice.phase -= 1.0f;

   return sample;
}

void SFCSynth::PlayNote(NoteMessage note)
{
   if (note.velocity > 0)
      StartVoice(note);
   else
      ReleaseVoice(note.pitch);
}

void SFCSynth::StartVoice(const NoteMessage& note)
{
   Voice* selected = nullptr;

   for (auto& voice : mVoices)
   {
      if (voice.stage == Stage::Off)
      {
         selected = &voice;
         break;
      }
   }

   if (selected == nullptr)
   {
      selected = &mVoices[0];
      for (auto& voice : mVoices)
      {
         if (voice.age < selected->age)
            selected = &voice;
      }
   }

   selected->stage = Stage::Attack;
   selected->pitch = note.pitch;
   selected->velocity = ClampFloat(note.velocity / 127.0f, 0.0f, 1.0f);
   selected->phase = 0.0f;
   selected->phaseInc = MidiPitchToHz(note.pitch) / gSampleRate;
   selected->env = 0.0f;
   selected->releaseStart = 0.0f;
   selected->age = ++mVoiceAgeCounter;
}

void SFCSynth::ReleaseVoice(int pitch)
{
   for (auto& voice : mVoices)
   {
      if (voice.pitch == pitch && voice.stage != Stage::Off && voice.stage != Stage::Release)
      {
         voice.releaseStart = voice.env;
         voice.stage = Stage::Release;
      }
   }
}

void SFCSynth::DrawModule()
{
   if (Minimized() || !IsVisible())
      return;

   mVolumeSlider->Draw();
   mAttackSlider->Draw();
   mReleaseSlider->Draw();
   mToneSlider->Draw();

   int active = 0;
   for (const auto& voice : mVoices)
   {
      if (voice.stage != Stage::Off)
         ++active;
   }

   ofSetColor(255, 255, 255, 180);
   DrawTextNormal("8 voice short-sample MVP", 5, 93, 12);
   DrawTextNormal(("voices: " + ofToString(active) + "/8").c_str(), 5, 109, 12);
}

void SFCSynth::GetModuleDimensions(float& width, float& height)
{
   width = 190;
   height = 124;
}
''')

# 8) SFC starter layout. Existing userprefs may override this; see final instructions.
layout_dir = root / 'resource/userdata_original/layouts'
layout_dir.mkdir(parents=True, exist_ok=True)
(layout_dir / 'sfc_default.json').write_text('''{
   "modules" : [
      {
         "name" : "transport",
         "position" : [ 14.0, 95.0 ],
         "type" : "transport"
      },
      {
         "name" : "scale",
         "position" : [ 158.0, 95.0 ],
         "type" : "scale"
      },
      {
         "name" : "note canvas",
         "position" : [ 90.0, 240.0 ],
         "target" : "sfc synth",
         "type" : "notecanvas"
      },
      {
         "name" : "sfc synth",
         "position" : [ 760.0, 270.0 ],
         "target" : "gain",
         "type" : "sfcsynth"
      },
      {
         "name" : "gain",
         "position" : [ 1030.0, 310.0 ],
         "target" : "splitter",
         "type" : "gain"
      },
      {
         "name" : "splitter",
         "position" : [ 1210.0, 350.0 ],
         "target" : "output 1",
         "target2" : "output 2",
         "type" : "splitter"
      },
      {
         "channels" : 0,
         "name" : "output 1",
         "position" : [ 1400.0, 320.0 ],
         "type" : "output"
      },
      {
         "channels" : 1,
         "name" : "output 2",
         "position" : [ 1490.0, 320.0 ],
         "type" : "output"
      }
   ],
   "zoomlocations" : []
}
''')
PY

# 9) Icon path is now separate. Keep build passing by copying the original until a custom icon is created.
if [ ! -f sfcbespoke_icon.png ]; then
  cp bespoke_icon.png sfcbespoke_icon.png
fi

echo "SFCBespoke stage 1 changes applied. Review with: git diff --stat && git diff"
