#!/usr/bin/env bash
set -euo pipefail

# Stage 2 patch for SFCBespoke:
#   - Replace the initial SFCSynth MVP with a slightly more SFC-oriented voice engine.
#   - Add ADSR UI controls: vol/atk/dec/sus/rel/tone/bits/rate.
#   - Add explicit 8-voice allocation/stealing bookkeeping.
#   - Add basic bit-depth and sample-rate reduction.
#
# Usage:
#   cd /path/to/BespokeSynth
#   bash patch_sfcsynth_stage2_adsr_voice_ui.sh

ROOT="${1:-$(pwd)}"
cd "$ROOT"

H="Source/SFCSynth.h"
CPP="Source/SFCSynth.cpp"

if [[ ! -f "$H" || ! -f "$CPP" ]]; then
  echo "ERROR: Source/SFCSynth.h / Source/SFCSynth.cpp が見つかりません。" >&2
  echo "Stage 1 の SFCSynth 追加が済んでいるか確認してください。" >&2
  exit 1
fi

TS="$(date +%Y%m%d%H%M%S)"
cp "$H" "$H.bak.$TS"
cp "$CPP" "$CPP.bak.$TS"
echo "Backup:"
echo "  $H.bak.$TS"
echo "  $CPP.bak.$TS"

cat > "$H" <<'EOF_H'
#pragma once

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
      Decay,
      Sustain,
      Release
   };

   struct Voice
   {
      Stage stage{ Stage::Off };
      int pitch{ -1 };
      float velocity{ 0.0f };
      float phase{ 0.0f };
      float phaseInc{ 0.0f };
      float env{ 0.0f };
      float releaseStart{ 0.0f };
      uint64_t age{ 0 };
   };

   void DrawModule() override;
   void GetModuleDimensions(float& width, float& height) override;

   void StartVoice(const NoteMessage& note);
   void ReleaseVoice(int pitch);
   Voice* SelectVoiceForNote();
   float RenderVoice(Voice& voice);
   void BuildWaveTable();
   int CountVoices(Stage stage) const;
   const char* StageLabel(Stage stage) const;

   static constexpr int kNumVoices = 8;
   static constexpr int kWaveTableSize = 32;

   std::array<Voice, kNumVoices> mVoices;
   std::array<float, kWaveTableSize> mWaveTable{};

   // SFC-like first-pass controls.
   float mVolume{ 0.70f };
   float mAttackMs{ 2.0f };
   float mDecayMs{ 90.0f };
   float mSustain{ 0.72f };
   float mReleaseMs{ 110.0f };
   float mTone{ 0.65f };
   float mBitDepth{ 8.0f };
   float mRateDivide{ 1.0f };

   FloatSlider* mVolumeSlider{ nullptr };
   FloatSlider* mAttackSlider{ nullptr };
   FloatSlider* mDecaySlider{ nullptr };
   FloatSlider* mSustainSlider{ nullptr };
   FloatSlider* mReleaseSlider{ nullptr };
   FloatSlider* mToneSlider{ nullptr };
   FloatSlider* mBitDepthSlider{ nullptr };
   FloatSlider* mRateDivideSlider{ nullptr };

   float* mWriteBuffer{ nullptr };
   bool mEnabled{ true };
   uint64_t mVoiceAgeCounter{ 0 };
   uint64_t mVoiceStealCounter{ 0 };

   // Output sample-and-hold for crude lower internal rate character.
   int mRateCounter{ 0 };
   float mHeldSample{ 0.0f };
};
EOF_H

cat > "$CPP" <<'EOF_CPP'
#include "SFCSynth.h"

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

   int ClampInt(int value, int low, int high)
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
   // Tiny looping "sample" table.
   //
   // This is not BRR yet. It is the first SFC-like constraint layer:
   // short loop, no interpolation, coarse amplitude, 8 voices.
   for (int i = 0; i < kWaveTableSize; ++i)
   {
      const float phase = static_cast<float>(i) / static_cast<float>(kWaveTableSize);

      const float square = phase < 0.5f ? 1.0f : -1.0f;
      const float triangle = 1.0f - 4.0f * std::fabs(phase - 0.5f);

      // A little curvature keeps the first sound from being only a flat square.
      const float sineish = std::sin(phase * TWO_PI);

      const float hard = square * 0.82f + sineish * 0.18f;
      const float soft = triangle * 0.70f + sineish * 0.30f;
      const float blended = hard * mTone + soft * (1.0f - mTone);

      // 5-bit-ish source table before final output quantisation.
      mWaveTable[i] = std::round(ClampFloat(blended, -1.0f, 1.0f) * 31.0f) / 31.0f;
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
   FLOATSLIDER(mDecaySlider, "dec", &mDecayMs, 0, 500);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mSustainSlider, "sus", &mSustain, 0, 1);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mReleaseSlider, "rel", &mReleaseMs, 5, 800);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mToneSlider, "tone", &mTone, 0, 1);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mBitDepthSlider, "bits", &mBitDepth, 4, 16);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mRateDivideSlider, "rate", &mRateDivide, 1, 12);

   ENDUIBLOCK0();
}

void SFCSynth::Process(double time)
{
   IAudioReceiver* target = GetTarget();

   if (!mEnabled || target == nullptr)
      return;

   ChannelBuffer* buffer = target->GetBuffer();
   const int bufferSize = buffer->BufferSize();
   float* out = buffer->GetChannel(0);

   Clear(mWriteBuffer, bufferSize);

   for (int pos = 0; pos < bufferSize; ++pos)
   {
      ComputeSliders(pos);
      BuildWaveTable();

      float sample = 0.0f;

      for (auto& voice : mVoices)
      {
         if (voice.stage == Stage::Off)
            continue;

         sample += RenderVoice(voice);
      }

      // Headroom for 8 voices.
      sample *= mVolume * 0.18f;

      // Crude SFC-ish lower-rate output character.
      const int rateDivide = ClampInt(static_cast<int>(std::round(mRateDivide)), 1, 12);
      if (rateDivide <= 1 || mRateCounter <= 0)
      {
         mHeldSample = sample;
         mRateCounter = rateDivide - 1;
      }
      else
      {
         --mRateCounter;
      }

      sample = mHeldSample;

      // Output bit-depth reduction. 8 is the default "chiptune-ish" value,
      // but the slider allows cleaner debugging up to 16.
      const int bits = ClampInt(static_cast<int>(std::round(mBitDepth)), 4, 16);
      const float quantLevels = static_cast<float>((1 << (bits - 1)) - 1);
      sample = std::round(sample * quantLevels) / quantLevels;

      mWriteBuffer[pos] = ClampFloat(sample, -1.0f, 1.0f);

      time += gInvSampleRateMs;
   }

   GetVizBuffer()->WriteChunk(mWriteBuffer, bufferSize, 0);
   Add(out, mWriteBuffer, bufferSize);
}

float SFCSynth::RenderVoice(Voice& voice)
{
   const float attackSamples = std::max(1.0f, mAttackMs * 0.001f * gSampleRate);
   const float decaySamples = std::max(1.0f, mDecayMs * 0.001f * gSampleRate);
   const float releaseSamples = std::max(1.0f, mReleaseMs * 0.001f * gSampleRate);
   const float sustain = ClampFloat(mSustain, 0.0f, 1.0f);

   switch (voice.stage)
   {
      case Stage::Attack:
      {
         voice.env += 1.0f / attackSamples;
         if (voice.env >= 1.0f)
         {
            voice.env = 1.0f;
            voice.stage = Stage::Decay;
         }
         break;
      }

      case Stage::Decay:
      {
         voice.env -= (1.0f - sustain) / decaySamples;
         if (voice.env <= sustain)
         {
            voice.env = sustain;
            voice.stage = Stage::Sustain;
         }
         break;
      }

      case Stage::Sustain:
      {
         voice.env = sustain;
         break;
      }

      case Stage::Release:
      {
         voice.env -= voice.releaseStart / releaseSamples;
         if (voice.env <= 0.0f)
         {
            voice.env = 0.0f;
            voice.stage = Stage::Off;
            voice.pitch = -1;
            return 0.0f;
         }
         break;
      }

      case Stage::Off:
      default:
         return 0.0f;
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

SFCSynth::Voice* SFCSynth::SelectVoiceForNote()
{
   // 1. Prefer completely free voices.
   for (auto& voice : mVoices)
   {
      if (voice.stage == Stage::Off)
         return &voice;
   }

   // 2. Then steal the oldest releasing voice. This is least audible.
   Voice* selected = nullptr;
   for (auto& voice : mVoices)
   {
      if (voice.stage == Stage::Release && (selected == nullptr || voice.age < selected->age))
         selected = &voice;
   }

   if (selected != nullptr)
   {
      ++mVoiceStealCounter;
      return selected;
   }

   // 3. Finally steal the oldest active voice.
   selected = &mVoices[0];

   for (auto& voice : mVoices)
   {
      if (voice.age < selected->age)
         selected = &voice;
   }

   ++mVoiceStealCounter;
   return selected;
}

void SFCSynth::StartVoice(const NoteMessage& note)
{
   Voice* selected = SelectVoiceForNote();

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

int SFCSynth::CountVoices(Stage stage) const
{
   int count = 0;

   for (const auto& voice : mVoices)
   {
      if (voice.stage == stage)
         ++count;
   }

   return count;
}

const char* SFCSynth::StageLabel(Stage stage) const
{
   switch (stage)
   {
      case Stage::Attack: return "A";
      case Stage::Decay: return "D";
      case Stage::Sustain: return "S";
      case Stage::Release: return "R";
      case Stage::Off:
      default:
         return "-";
   }
}

void SFCSynth::DrawModule()
{
   if (Minimized() || !IsVisible())
      return;

   mVolumeSlider->Draw();
   mAttackSlider->Draw();
   mDecaySlider->Draw();
   mSustainSlider->Draw();
   mReleaseSlider->Draw();
   mToneSlider->Draw();
   mBitDepthSlider->Draw();
   mRateDivideSlider->Draw();

   int active = 0;
   for (const auto& voice : mVoices)
   {
      if (voice.stage != Stage::Off)
         ++active;
   }

   ofSetColor(255, 255, 255, 180);
   DrawTextNormal("SFC short-sample synth", 5, 165, 12);
   DrawTextNormal(("voices: " + ofToString(active) + "/8").c_str(), 5, 181, 12);
   DrawTextNormal(("steals: " + ofToString(mVoiceStealCounter)).c_str(), 5, 197, 12);

   // Small voice-state strip.
   for (int i = 0; i < kNumVoices; ++i)
   {
      const auto stage = mVoices[i].stage;

      if (stage == Stage::Off)
         ofSetColor(60, 60, 60, 180);
      else if (stage == Stage::Release)
         ofSetColor(255, 180, 80, 220);
      else
         ofSetColor(120, 220, 255, 230);

      ofRect(76 + i * 12, 181, 9, 9);

      ofSetColor(255, 255, 255, 190);
      DrawTextNormal(StageLabel(stage), 76 + i * 12, 207, 9);
   }
}

void SFCSynth::GetModuleDimensions(float& width, float& height)
{
   width = 210;
   height = 224;
}
EOF_CPP

echo
echo "Patched SFCSynth Stage 2."
echo
echo "Diff summary:"
git diff -- Source/SFCSynth.h Source/SFCSynth.cpp || true

cat <<'EOF_NEXT'

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

APP="$(pwd)/ignore/build/Source/BespokeSynth_artefacts/Release/SFCBespoke.app"
BIN="$APP/Contents/MacOS/SFCBespoke"

mkdir -p "$APP/Contents/Resources/resource"
rsync -a resource/ "$APP/Contents/Resources/resource/"

"$BIN"

EOF_NEXT
