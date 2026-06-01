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
