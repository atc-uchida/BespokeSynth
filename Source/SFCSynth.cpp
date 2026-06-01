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
