// The ⚙ sheet's Video and Audio sections: Dolphin's settings, applied live
// (SetBaseOrCurrent) and kept by touchkit. Included by PlatformIOS.mm.

template <typename T>
static touchkit::HostSetting Choice(const char* section, const char* key, const char* title,
                                    const Config::Info<T>& info,
                                    std::vector<std::pair<const char*, T>> choices, int def)
{
  touchkit::HostSetting s;
  s.section = section;
  s.key = key;
  s.title = title;
  for (const auto& c : choices)
    s.options.push_back(c.first);
  s.defaultIndex = def;
  s.apply = [&info, choices](int i) {
    Config::SetBaseOrCurrent(info, choices[std::clamp<int>(i, 0, int(choices.size()) - 1)].second);
  };
  return s;
}

static touchkit::HostSetting Toggle(const char* section, const char* key, const char* title,
                                    const Config::Info<bool>& info, bool def)
{
  return Choice<bool>(section, key, title, info, {{"Off", false}, {"On", true}}, def ? 1 : 0);
}

// One tap for the rest of the Video rows. Not a saved state: it applies and
// goes back to "Choose…", so the rows can be tuned after and stay as set.
// On the iPad Air 4 (2360x1640) 3x already matches the screen; SSAA on top of
// 4x MSAA shades every pixel 4 times for next to nothing: High drops it.
static touchkit::HostSetting Preset()
{
  touchkit::HostSetting s;
  s.section = "Video";
  s.key = "preset";
  s.title = "Quality preset";
  s.options = {"Choose…", "Performance (native)", "Balanced (2x)", "High (3x, recommended)",
               "Ultra (4x)"};
  s.defaultIndex = 0;
  s.apply = [](int i) {
    if (i <= 0)
      return;
    // efb_scale, msaa, aniso indices into the rows below.
    static constexpr int kPresets[4][3] = {{0, 0, 3}, {1, 1, 4}, {2, 2, 5}, {3, 2, 5}};
    const auto& p = kPresets[i - 1];
    touchkit::SetHostSetting("efb_scale", p[0]);
    touchkit::SetHostSetting("msaa", p[1]);
    touchkit::SetHostSetting("aniso", p[2]);
    touchkit::SetHostSetting("ssaa", 0);
    touchkit::SetHostSetting("shaders", 3);
    touchkit::SetHostSetting("mipmap", 0);
    touchkit::SetHostSetting("preset", 0, false);
  };
  return s;
}

// Emulated CPU clock. In lots the game keeps the Gekko busy every frame, more
// than the iPad's CPU can run in real time (the whole game slowed to ~40%,
// sound too). Under 100% the game gets fewer cycles per frame instead: time,
// sound and the sims keep normal speed, fewer frames are drawn.
static touchkit::HostSetting CpuClock()
{
  touchkit::HostSetting s;
  s.section = "Video";
  s.key = "cpuclock";
  s.title = "Emulated CPU speed";
  s.options = {"100% (stock)", "85%", "70%", "60%", "50%"};
  s.defaultIndex = 0;
  s.apply = [](int i) {
    static constexpr float kClock[] = {1.0f, 0.85f, 0.7f, 0.6f, 0.5f};
    const float clock = kClock[std::clamp(i, 0, 4)];
    Config::SetBaseOrCurrent(Config::MAIN_OVERCLOCK, clock);
    Config::SetBaseOrCurrent(Config::MAIN_OVERCLOCK_ENABLE, clock != 1.0f);
  };
  return s;
}

// Read at launch by RunGame (PlatformIOS.mm): nothing to apply live.
static touchkit::HostSetting IntroMovies()
{
  touchkit::HostSetting s;
  s.section = "Video";
  s.key = "intro";
  s.title = "Intro movies (next launch)";
  s.options = {"Skip", "Play (needs the full disc)"};
  s.defaultIndex = 0;
  return s;
}

static std::vector<touchkit::HostSetting> HostSettings()
{
  using namespace Config;
  std::vector<touchkit::HostSetting> s = {
      Preset(),
      CpuClock(),
      IntroMovies(),
      Choice<int>("Video", "efb_scale", "Internal resolution", GFX_EFB_SCALE,
                  {{"Native (640x528)", 1}, {"2x (1280x1056)", 2}, {"3x (1920x1584)", 3},
                   {"4x (2560x2112, above the screen)", 4}},
                  1),
      Choice<u32>("Video", "msaa", "Anti-aliasing (MSAA)", GFX_MSAA,
                  {{"Off", 1}, {"2x", 2}, {"4x", 4}}, 0),
      Toggle("Video", "ssaa", "Supersampling (very heavy)", GFX_SSAA, false),
      Choice<AnisotropicFilteringMode>(
          "Video", "aniso", "Anisotropic filtering", GFX_ENHANCE_MAX_ANISOTROPY,
          {{"Game default", AnisotropicFilteringMode::Default},
           {"1x", AnisotropicFilteringMode::Force1x},
           {"2x", AnisotropicFilteringMode::Force2x},
           {"4x", AnisotropicFilteringMode::Force4x},
           {"8x", AnisotropicFilteringMode::Force8x},
           {"16x", AnisotropicFilteringMode::Force16x}},
          3),
      Choice<TextureFilteringMode>("Video", "texfilter", "Texture filtering",
                                   GFX_ENHANCE_FORCE_TEXTURE_FILTERING,
                                   {{"Game default", TextureFilteringMode::Default},
                                    {"Nearest (sharp)", TextureFilteringMode::Nearest},
                                    {"Linear (smooth)", TextureFilteringMode::Linear}},
                                   0),
      Choice<OutputResamplingMode>("Video", "resampling", "Output resampling",
                                   GFX_ENHANCE_OUTPUT_RESAMPLING,
                                   {{"Default", OutputResamplingMode::Default},
                                    {"Bilinear", OutputResamplingMode::Bilinear},
                                    {"B-Spline", OutputResamplingMode::BSpline},
                                    {"Mitchell-Netravali", OutputResamplingMode::MitchellNetravali},
                                    {"Catmull-Rom", OutputResamplingMode::CatmullRom},
                                    {"Sharp Bilinear", OutputResamplingMode::SharpBilinear},
                                    {"Area Sampling", OutputResamplingMode::AreaSampling}},
                                   0),
      Choice<AspectMode>("Video", "aspect", "Aspect ratio", GFX_ASPECT_RATIO,
                         {{"Auto", AspectMode::Auto},
                          {"Force 16:9", AspectMode::ForceWide},
                          {"Force 4:3", AspectMode::ForceStandard},
                          {"Stretch to screen", AspectMode::Stretch}},
                         0),
      Toggle("Video", "widescreen", "Widescreen hack", GFX_WIDESCREEN_HACK, false),
      Toggle("Video", "nofog", "Disable fog", GFX_DISABLE_FOG, false),
      Toggle("Video", "truecolor", "Force 24-bit color", GFX_ENHANCE_FORCE_TRUE_COLOR, true),
      Toggle("Video", "mipmap", "Arbitrary mipmap detection",
             GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION, false),
      Toggle("Video", "efbscaled", "Scaled EFB copies", GFX_HACK_COPY_EFB_SCALED, true),
      Toggle("Video", "efbtoram", "Skip EFB copies to RAM", GFX_HACK_SKIP_EFB_COPY_TO_RAM, true),
      Choice<ShaderCompilationMode>(
          "Video", "shaders", "Shader compilation", GFX_SHADER_COMPILATION_MODE,
          {{"Synchronous", ShaderCompilationMode::Synchronous},
           {"Ubershaders", ShaderCompilationMode::SynchronousUberShaders},
           {"Async + ubershaders (smooth)", ShaderCompilationMode::AsynchronousUberShaders},
           {"Async, skip drawing (smoothest)", ShaderCompilationMode::AsynchronousSkipRendering}},
          3),  // ubershaders are slow on the iPad's GPU: menus lagged while new shaders built
      Toggle("Video", "vsync", "V-Sync", GFX_VSYNC, true),
      Toggle("Video", "fps", "Show FPS", GFX_SHOW_FPS, false),
      Choice<int>("Audio", "volume", "Volume", MAIN_AUDIO_VOLUME,
                  {{"0%", 0}, {"10%", 10}, {"20%", 20}, {"30%", 30}, {"40%", 40}, {"50%", 50},
                   {"60%", 60}, {"70%", 70}, {"80%", 80}, {"90%", 90}, {"100%", 100}},
                  10),
      Toggle("Audio", "mute", "Mute", MAIN_AUDIO_MUTED, false),
      Choice<int>("Audio", "buffer", "Audio buffer (latency)", MAIN_AUDIO_BUFFER_SIZE,
                  {{"40 ms (low latency)", 40}, {"60 ms", 60}, {"80 ms (default)", 80},
                   {"120 ms", 120}, {"160 ms (fewest crackles)", 160}},
                  2),
  };
  // Volume and mute reach the stream only through UpdateSoundStream.
  for (auto& setting : s)
  {
    if (setting.section != "Audio")
      continue;
    setting.apply = [inner = setting.apply](int i) {
      inner(i);
      AudioCommon::UpdateSoundStream(Core::System::GetInstance());
    };
  }
  return s;
}
