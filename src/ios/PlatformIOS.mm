// ModernGekko's iOS host: a UIKit app whose one view is a CAMetalLayer for
// Dolphin's Metal backend, with touchkit's pad over it. The game
// module is linked in (staticrecomp_get_module), the runtime runs on a thread
// of its own (UIKit keeps the main one), and the pad reaches the emulated
// GameCube controller on port 1 through Dolphin's input overrider.
// The game is Documents/game (sys/main.dol, files/), Dolphin's user folder
// Documents/User (memory cards, config).

#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <thread>
#include <unistd.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>

#include "Common/Config/Config.h"
#include "Core/Config/StaticRecompSettings.h"
#include "AudioCommon/AudioCommon.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/MainSettings.h"
#include "Core/Core.h"
#include "VideoCommon/VideoConfig.h"
#include "VideoCommon/PerformanceMetrics.h"
#include "Core/HW/Memmap.h"
#include "Core/System.h"
#include "DolphinNoGUI/Platform.h"
#include "InputCommon/ControllerInterface/Touch/InputOverrider.h"
#include "moderngekko/module_abi.h"
#include "moderngekko/runtime.hpp"
#include "save_sync.h"
#include "sims_pointer.h"
#include <touchkit/touchkit.h>

extern "C" const ModernGekkoModuleDesc* staticrecomp_get_module(void);
void StaticRecompPerfCounters(u64* native, u64* fallback);  // StaticRecompCore.cpp
void StaticRecompGuestRegs(u32* pc, u32* lr, u32* sp);    // StaticRecompCore.cpp

static CAMetalLayer* s_layer = nil;

// The pointer (one-finger drag = main stick, tap = A, two fingers = C-stick) is
// touchkit's now; this view is just the CAMetalLayer.
// ponytail: relative (stick-driven) cursor; an absolute tap-to-point needs the
// game's cursor position in RAM (see the TODO in PushPad).
@interface MGGameView : UIView
@end
@implementation MGGameView
+ (Class)layerClass
{
  return [CAMetalLayer class];
}
@end

namespace
{
// GameCube pad bits for touchkit::Sample::buttons.
enum : uint32_t { kA = 1 << 0, kB = 1 << 1, kX = 1 << 2, kY = 1 << 3, kZ = 1 << 4, kStart = 1 << 5,
                  kDUp = 1 << 6, kDDown = 1 << 7, kDLeft = 1 << 8, kDRight = 1 << 9 };

#include "settings.inc"

std::filesystem::path DocumentsPath()
{
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
      .firstObject.fileSystemRepresentation;
}

void ShowMessage(UIViewController* from, NSString* title, NSString* message)
{
  UIAlertController* a = [UIAlertController alertControllerWithTitle:title message:message
                                                      preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
  [from presentViewController:a animated:YES completion:nil];
}

// ⚙ "Cloud saves": sign this device in to a save server (save_sync.mm), or out.
void CloudSaves(UIViewController* from)
{
  const std::filesystem::path docs = DocumentsPath();
  if (savesync::Configured(docs))
  {
    UIAlertController* a = [UIAlertController
        alertControllerWithTitle:@"Cloud saves"
                         message:@"This device is signed in: saves upload a few seconds after the game saves, and the newest save comes down when the game starts."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Sign Out" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction*) {
                                          std::error_code ec;
                                          std::filesystem::remove(docs / "save_sync.txt", ec);
                                          ShowMessage(from, @"Signed out", @"Takes effect the next time the game starts. Your saves stay on this device.");
                                        }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [from presentViewController:a animated:YES completion:nil];
    return;
  }
  UIAlertController* a = [UIAlertController
      alertControllerWithTitle:@"Cloud saves"
                       message:@"Sign in to a save server to keep your memory card in step across your devices."
                preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField* f) {
    f.placeholder = @"Server, e.g. https://saves.example.com";
    f.keyboardType = UIKeyboardTypeURL;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [a addTextFieldWithConfigurationHandler:^(UITextField* f) {
    f.placeholder = @"This device's name";
    f.text = UIDevice.currentDevice.model.lowercaseString;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [a addTextFieldWithConfigurationHandler:^(UITextField* f) {
    f.placeholder = @"Password";
    f.secureTextEntry = YES;
  }];
  __weak UIAlertController* weak = a;
  [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:@"Sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
    const std::string url = weak.textFields[0].text.UTF8String ?: "";
    const std::string device = weak.textFields[1].text.UTF8String ?: "";
    const std::string password = weak.textFields[2].text.UTF8String ?: "";
    std::thread([=] {
      const std::string why = savesync::CheckLogin(url, device, password);
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!why.empty())
        {
          ShowMessage(from, @"Couldn't sign in", @(why.c_str()));
          return;
        }
        savesync::SaveLogin(docs, url, device, password);
        // Uploads start now; a newer cloud save loads the next time the game starts.
        if (!savesync::Started())
          std::thread([docs] { savesync::Start(docs, docs / "User/GC/USA/Card A"); }).detach();
        ShowMessage(from, @"Signed in",
                    @"Your saves now upload a few seconds after the game saves. If the server has a newer save, restart the game to load it.");
      });
    }).detach();
  }]];
  [from presentViewController:a animated:YES completion:nil];
}

touchkit::Config MakeTouchConfig()
{
  using touchkit::Kind;
  touchkit::Config c;
  c.settings = HostSettings();
  c.prefsPrefix = "sims2.touch";
  c.tapBit = kA;
  // Saved layouts name these rows by index: only ever append.
  c.controls = {
      {"A", Kind::Button, kA, 0, 0.90f, 0.72f, 44, false},
      {"B", Kind::Button, kB, 0, 0.79f, 0.83f, 30, false},
      {"X", Kind::Button, kX, 0, 0.975f, 0.60f, 30, false},
      {"Y", Kind::Button, kY, 0, 0.88f, 0.46f, 30, false},
      {"Z", Kind::Button, kZ, 0, 0.84f, 0.11f, 24, false},
      {"L", Kind::Trigger, 0, 0, 0.05f, 0.11f, 28, false},
      {"R", Kind::Trigger, 0, 1, 0.95f, 0.11f, 28, false},
      {"START", Kind::Button, kStart, 0, 0.50f, 0.11f, 26, false},
      {"\u25B2", Kind::Button, kDUp, 0, 0.09f, 0.495f, 20, false},
      {"\u25BC", Kind::Button, kDDown, 0, 0.09f, 0.625f, 20, false},
      {"\u25C0", Kind::Button, kDLeft, 0, 0.045f, 0.56f, 20, false},
      {"\u25B6", Kind::Button, kDRight, 0, 0.135f, 0.56f, 20, false},
      {"", Kind::Stick, 0, 0, 0.09f, 0.84f, 60, false},
      {"", Kind::Stick, 0, 1, 0.68f, 0.72f, 40, false},
      {"DRAG", Kind::PointerToggle, 0, 0, 0.72f, 0.11f, 24, false},  // appended (saved layouts index rows)
      {"HIDE", Kind::HideToggle, 0, 0, 0.42f, 0.11f, 22, false},  // appended (saved layouts index rows)
  };
  c.addable = {
      {"A", "A", Kind::Button, kA, 0},         {"B", "B", Kind::Button, kB, 0},
      {"X", "X", Kind::Button, kX, 0},         {"Y", "Y", Kind::Button, kY, 0},
      {"Z", "Z", Kind::Button, kZ, 0},         {"Start", "START", Kind::Button, kStart, 0},
      {"D-pad Up", "D-Up", Kind::Button, kDUp, 0},       {"D-pad Down", "D-Down", Kind::Button, kDDown, 0},
      {"D-pad Left", "D-Left", Kind::Button, kDLeft, 0}, {"D-pad Right", "D-Right", Kind::Button, kDRight, 0},
      {"L", "L", Kind::Trigger, 0, 0},         {"R", "R", Kind::Trigger, 0, 1},
  };
  // Hardware keyboard (shown read-only under the gear's "Keyboard..." row).
  auto btn = [](GCKeyCode k, uint32_t bit, const char* label) { return touchkit::KeyBind{uint16_t(k), bit, -1, 0, 0, -1, label}; };
  auto axis = [](GCKeyCode k, int stick, int ax, float v, const char* label) {
    return touchkit::KeyBind{uint16_t(k), 0, stick, ax, v, -1, label};
  };
  auto trig = [](GCKeyCode k, int t, const char* label) { return touchkit::KeyBind{uint16_t(k), 0, -1, 0, 0, t, label}; };
  c.keys = {
      axis(GCKeyCodeKeyW, 0, 1, +1, "Move up"),    axis(GCKeyCodeKeyS, 0, 1, -1, "Move down"),
      axis(GCKeyCodeKeyA, 0, 0, -1, "Move left"),  axis(GCKeyCodeKeyD, 0, 0, +1, "Move right"),
      axis(GCKeyCodeLeftArrow, 1, 0, -1, "Camera left"),  axis(GCKeyCodeComma, 1, 0, -1, "Camera left"),
      axis(GCKeyCodeRightArrow, 1, 0, +1, "Camera right"), axis(GCKeyCodePeriod, 1, 0, +1, "Camera right"),
      axis(GCKeyCodeUpArrow, 1, 1, +1, "Zoom in"), axis(GCKeyCodeEqualSign, 1, 1, +1, "Zoom in"),
      axis(GCKeyCodePageUp, 1, 1, +1, "Zoom in"),
      axis(GCKeyCodeDownArrow, 1, 1, -1, "Zoom out"), axis(GCKeyCodeHyphen, 1, 1, -1, "Zoom out"),
      axis(GCKeyCodePageDown, 1, 1, -1, "Zoom out"),
      btn(GCKeyCodeSpacebar, kA, "A"), btn(GCKeyCodeReturnOrEnter, kA, "A"), btn(GCKeyCodeKeyE, kA, "A"),
      btn(GCKeyCodeDeleteOrBackspace, kB, "B"), btn(GCKeyCodeKeyQ, kB, "B"),
      btn(GCKeyCodeKeyX, kX, "X"),
      btn(GCKeyCodeKeyY, kY, "Y"), btn(GCKeyCodeKeyC, kY, "Y"),
      btn(GCKeyCodeKeyZ, kZ, "Z"),
      trig(GCKeyCodeTab, 0, "L"), trig(GCKeyCodeKeyR, 1, "R"),
      btn(GCKeyCodeEscape, kStart, "Start"), btn(GCKeyCodeKeyP, kStart, "Start"),
      btn(GCKeyCodeOne, kDUp, "D-pad up"),    btn(GCKeyCodeKeyI, kDUp, "D-pad up"),
      btn(GCKeyCodeTwo, kDDown, "D-pad down"), btn(GCKeyCodeKeyK, kDDown, "D-pad down"),
      btn(GCKeyCodeThree, kDLeft, "D-pad left"), btn(GCKeyCodeKeyJ, kDLeft, "D-pad left"),
      btn(GCKeyCodeFour, kDRight, "D-pad right"), btn(GCKeyCodeKeyL, kDRight, "D-pad right"),
  };
  c.pinch = {1, 1, 1.0f, 1.0f, true};  // C-stick Y; spreading zooms in
  c.actions = {{[] { return std::string(savesync::Configured(DocumentsPath()) ? "Cloud saves: on" : "Cloud saves: sign in…"); },
                [](void* presenter) { CloudSaves((__bridge UIViewController*)presenter); }}};
  return c;
}
}  // namespace

@interface MGViewController : UIViewController
@end
@implementation MGViewController
- (void)loadView
{
  MGGameView* view = [[MGGameView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  view.contentScaleFactor = UIScreen.mainScreen.nativeScale;
  view.backgroundColor = UIColor.blackColor;
  s_layer = (CAMetalLayer*)view.layer;
  self.view = view;
}
- (BOOL)prefersStatusBarHidden
{
  return YES;
}
- (BOOL)prefersHomeIndicatorAutoHidden
{
  return YES;
}
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures
{
  return UIRectEdgeAll;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
  return UIInterfaceOrientationMaskLandscape;
}
@end

namespace
{
class PlatformIOS final : public Platform
{
public:
  void MainLoop() override
  {
    while (IsRunning())
    {
      UpdateRunningFlag();
      Core::HostDispatchJobs(Core::System::GetInstance());
      PushPad();
      std::this_thread::sleep_for(std::chrono::milliseconds(4));
    }
  }

  // Called about once a second (the runtime's title thread): the perf log.
  void SetTitle(const std::string&) override
  {
    const auto& perf = Core::System::GetInstance().GetPerfMetrics();
    static u64 last_native = 0, last_fallback = 0;
    u64 native = 0, fallback = 0;
    StaticRecompPerfCounters(&native, &fallback);
    // Where the game is (pc, lr, then the saved LRs up the guest stack): a
    // hang shows its loop here.
    u32 pc, lr, sp;
    StaticRecompGuestRegs(&pc, &lr, &sp);
    char where[96];
    int n = std::snprintf(where, sizeof(where), "pc=%08x lr=%08x bt=", pc, lr);
    auto& memory = Core::System::GetInstance().GetMemory();
    for (int i = 0; i < 5 && sp >= 0x80000000u && sp < 0x817FFFF0u && n < 80; ++i)
    {
      sp = memory.Read_U32(sp & 0x01FFFFFFu);
      if (sp < 0x80000000u || sp >= 0x817FFFF0u)
        break;
      n += std::snprintf(where + n, sizeof(where) - n, "%08x,", memory.Read_U32((sp + 4) & 0x01FFFFFFu));
    }
    std::fprintf(stderr, "[perf] fps=%.1f vps=%.1f speed=%.0f%% native=%llu interp=%llu %s\n",
                 perf.GetFPS(), perf.GetVPS(), perf.GetSpeed() * 100,
                 (unsigned long long)(native - last_native),
                 (unsigned long long)(fallback - last_fallback), where);
    last_native = native;
    last_fallback = fallback;
  }

  WindowSystemInfo GetWindowSystemInfo() const override
  {
    WindowSystemInfo wsi;
    wsi.type = WindowSystemType::MacOS;  // what Metal takes; the surface is the layer itself
    wsi.render_window = (__bridge void*)s_layer;
    wsi.render_surface = (__bridge void*)s_layer;
    wsi.render_surface_scale = s_layer.contentsScale;
    return wsi;
  }

private:
  static void PushPad()
  {
    using namespace ciface::Touch;
    const touchkit::Sample s = touchkit::Read();
    uint32_t buttons = s.buttons;
    // Tap to point (absolute pointer mode). Where the game has a screen
    // cursor (the neighbourhood, menus with the arrow) it goes to the tap,
    // then A. In a lot the stick walks the Sim, whom the camera keeps near
    // the middle: the tap walks it that way for a time by the distance, and
    // a second tap near the first, soon after, is A (interact).
    // ponytail: the Sim's place on screen is assumed, not read.
    static double s_a_from = 0, s_a_until = 0, s_walk_until = 0, s_last_walk = -10;
    static float s_walk_x = 0, s_walk_y = 0, s_last_gx = 0, s_last_gy = 0;
    const double now = CACurrentMediaTime();
    touchkit::Tap tap;
    while (touchkit::PopTap(&tap))
    {
      float gx, gy;
      if (sims::PointCursorAt(tap.x, tap.y))
      {
        s_a_from = now + 0.05;  // the game sees the cursor move first
        s_a_until = now + 0.15;
      }
      else if (sims::ToGame(tap.x, tap.y, &gx, &gy))
      {
        if (now - s_last_walk < 1.5 && std::hypot(gx - s_last_gx, gy - s_last_gy) < 60)
        {
          s_walk_until = 0;
          s_a_from = now;
          s_a_until = now + 0.1;
          s_last_walk = -10;
          continue;
        }
        const float dx = gx - 320, dy = 250 - gy, dist = std::hypot(dx, dy);
        if (dist < 1)
          continue;
        s_walk_x = dx / dist;
        s_walk_y = dy / dist;
        s_walk_until = now + std::clamp(dist / 180.0, 0.15, 1.5);
        s_last_walk = now;
        s_last_gx = gx;
        s_last_gy = gy;
      }
    }
    if (now >= s_a_from && now < s_a_until)
      buttons |= kA;
    // Only write when something changed, so remote (automation) presses aren't overwritten.
    const bool walking = now < s_walk_until && s.stick[0][0] == 0 && s.stick[0][1] == 0;
    const float state[] = {float(buttons), s.trigger[0], s.trigger[1],
                           walking ? s_walk_x : s.stick[0][0], walking ? s_walk_y : s.stick[0][1],
                           s.stick[1][0], s.stick[1][1]};
    static float s_last_state[std::size(state)] = {-1};
    if (std::equal(std::begin(state), std::end(state), s_last_state))
      return;
    std::copy(std::begin(state), std::end(state), s_last_state);
    static constexpr std::pair<uint32_t, ControlID> kButtons[] = {
        {kA, GCPAD_A_BUTTON},         {kB, GCPAD_B_BUTTON},
        {kX, GCPAD_X_BUTTON},         {kY, GCPAD_Y_BUTTON},
        {kZ, GCPAD_Z_BUTTON},         {kStart, GCPAD_START_BUTTON},
        {kDUp, GCPAD_DPAD_UP},        {kDDown, GCPAD_DPAD_DOWN},
        {kDLeft, GCPAD_DPAD_LEFT},    {kDRight, GCPAD_DPAD_RIGHT},
    };
    for (const auto& [bit, id] : kButtons)
      SetControlState(0, id, (buttons & bit) ? 1.0 : 0.0);
    SetControlState(0, GCPAD_L_ANALOG, s.trigger[0]);
    SetControlState(0, GCPAD_R_ANALOG, s.trigger[1]);
    SetControlState(0, GCPAD_L_DIGITAL, s.trigger[0] > 0.9f ? 1.0 : 0.0);
    SetControlState(0, GCPAD_R_DIGITAL, s.trigger[1] > 0.9f ? 1.0 : 0.0);
    SetControlState(0, GCPAD_MAIN_STICK_X, walking ? s_walk_x : s.stick[0][0]);
    SetControlState(0, GCPAD_MAIN_STICK_Y, walking ? s_walk_y : s.stick[0][1]);
    SetControlState(0, GCPAD_C_STICK_X, s.stick[1][0]);
    SetControlState(0, GCPAD_C_STICK_Y, s.stick[1][1]);
  }
};

// Sampling profiler for perf work over ssh: `touch Documents/profile_go` while playing; every
// 1 ms it records the pc (and lr) of each running thread for 15 s into Documents/profile.txt as
// offsets into the app binary (symbolize with atos -l 0 on the Mac), then deletes profile_go.
// PGO builds (module compiled with -fprofile-instr-generate): `touch Documents/pgo_dump` writes
// the counters so far to Documents/sims.profraw. Weak, and build_ipa.sh links with -U for them,
// so normal builds (no profile runtime) see null.
extern "C" int __llvm_profile_write_file(void) __attribute__((weak));
extern "C" void __llvm_profile_set_filename(const char*) __attribute__((weak));
extern "C" void __llvm_profile_reset_counters(void) __attribute__((weak));

static void StartProfilerWatcher(const std::filesystem::path& root)
{
  std::thread([root] {
    const auto go = root / "profile_go";
    for (;;)
    {
      std::this_thread::sleep_for(std::chrono::seconds(2));
      std::error_code ec;
      // pgo_reset: zero the counters (e.g. right after loading the benchmark state).
      const auto reset_counters = &__llvm_profile_reset_counters;
      const auto set_filename = &__llvm_profile_set_filename;
      const auto write_file = &__llvm_profile_write_file;
      if (reset_counters && std::filesystem::exists(root / "pgo_reset", ec))
      {
        reset_counters();
        std::filesystem::remove(root / "pgo_reset", ec);
      }
      if (set_filename && write_file && std::filesystem::exists(root / "pgo_dump", ec))
      {
        set_filename((root / "sims.profraw").c_str());
        write_file();
        std::filesystem::remove(root / "pgo_dump", ec);
      }
      if (!std::filesystem::exists(go, ec))
        continue;
      const uintptr_t slide = _dyld_get_image_vmaddr_slide(0);
      FILE* out = std::fopen((root / "profile.tmp").c_str(), "w");
      const thread_act_t self = mach_thread_self();
      const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(15);
      while (out && std::chrono::steady_clock::now() < end)
      {
        thread_act_array_t threads;
        mach_msg_type_number_t count = 0;
        if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
          break;
        for (mach_msg_type_number_t i = 0; i < count; ++i)
        {
          thread_basic_info_data_t info;
          mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
          if (threads[i] != self &&
              thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &n) == KERN_SUCCESS &&
              info.run_state == TH_STATE_RUNNING && thread_suspend(threads[i]) == KERN_SUCCESS)
          {
            arm_thread_state64_t st;
            mach_msg_type_number_t sn = ARM_THREAD_STATE64_COUNT;
            const bool got = thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st,
                                              &sn) == KERN_SUCCESS;
            // Resume before writing: the suspended thread may hold the malloc/stdio lock.
            thread_resume(threads[i]);
            if (got)
              std::fprintf(out, "%u %llx %llx\n", threads[i],
                           (unsigned long long)(arm_thread_state64_get_pc(st) - slide),
                           (unsigned long long)(arm_thread_state64_get_lr(st) - slide));
          }
          mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      mach_port_deallocate(mach_task_self(), self);
      if (out)
        std::fclose(out);
      std::filesystem::rename(root / "profile.tmp", root / "profile.txt", ec);
      std::filesystem::remove(go, ec);
    }
  }).detach();
}

void RunGame()
{
  const std::filesystem::path root = DocumentsPath();
  std::error_code ec;  // the last run's log kept, for a crash
  std::filesystem::rename(root / "ModernGekko.log", root / "ModernGekko.prev.log", ec);
  std::freopen((root / "ModernGekko.log").c_str(), "w", stderr);
  std::freopen((root / "ModernGekko.log").c_str(), "a", stdout);
  setvbuf(stderr, nullptr, _IONBF, 0);

  // Cloud saves: newer saves come down before the game reads its memory card.
  savesync::Start(root, root / "User/GC/USA/Card A");
  StartProfilerWatcher(root);
  // Diagnostics over ssh: Documents/env.txt, one KEY=VALUE per line, set before the runtime starts.
  if (FILE* env = std::fopen((root / "env.txt").c_str(), "r")) {
    char line[512];
    while (std::fgets(line, sizeof line, env)) {
      line[std::strcspn(line, "\r\n")] = 0;
      if (char* eq = std::strchr(line, '='); eq && eq != line) {
        *eq = 0;
        setenv(line, eq + 1, 1);
      }
    }
    std::fclose(env);
  }

  moderngekko::RuntimeConfig config;
  // The game: Documents/game (copied in with Finder/Files, or pushed), else
  // the one built into the app (scripts/build_ios.sh --with-game).
  config.game_root = root / "game";
  if (std::error_code ec; !std::filesystem::exists(config.game_root / "sys/main.dol", ec))
    config.game_root = std::filesystem::path(NSBundle.mainBundle.resourcePath.fileSystemRepresentation) / "game";
  config.user_directory = root / "User";
  config.module = moderngekko::ModuleSource::AttachedDescriptor(staticrecomp_get_module());
  // ⚙ Video "Intro movies" (read before boot; the mod is loaded at Create).
  if ([NSUserDefaults.standardUserDefaults integerForKey:@"sims2.touch.setting.intro"] == 1)
    setenv("SIMS2_INTRO", "1", 1);
  config.mod_directories.push_back(root / "Mods");
  // Remote testing over ssh: create Documents/automation to accept the runner's command files.
  if (std::error_code ec; std::filesystem::is_directory(root / "automation", ec))
    config.automation.directory = root / "automation";
  config.graphics.backend = "Metal";
  config.fullscreen = true;
  config.show_fps_in_title = true;  // SetTitle above logs perf
  config.allow_interpreter = true;  // the one self-modifying chunk (0x803CB4C0)

  auto created = moderngekko::Runtime::Create(std::move(config));
  if (!created)
  {
    std::fprintf(stderr, "initialization failed: %s\n", created.error->message.c_str());
    return;
  }
  ciface::Touch::RegisterGameCubeInputOverrider(0);
  touchkit::ApplyHostSettings();  // the saved Video/Audio settings, over the runtime's
  const moderngekko::RuntimeRunResult result = created.runtime->Run();
  if (result.error)
    std::fprintf(stderr, "runtime failed: %s\n", result.error->message.c_str());
  std::fflush(stderr);
}
}  // namespace

std::unique_ptr<Platform> MGCreateIOSPlatform()
{
  return std::make_unique<PlatformIOS>();
}

@interface MGAppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow* window;
@end
@implementation MGAppDelegate
- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  MGViewController* vc = [MGViewController new];
  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];
  application.idleTimerDisabled = YES;
  [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
  [AVAudioSession.sharedInstance setActive:YES error:nil];
  touchkit::Attach((__bridge void*)vc.view, MakeTouchConfig());
  // Which build is installed: a few seconds at launch (stamp from build_ipa.sh).
  if (NSString* stamp = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MGBuildStamp"])
  {
    UILabel* label = [UILabel new];
    label.text = [@"  Build " stringByAppendingFormat:@"%@  ", stamp];
    label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    label.layer.cornerRadius = 8;
    label.layer.masksToBounds = YES;
    [label sizeToFit];
    CGRect f = label.frame;
    f.size.height += 8;
    f.origin = CGPointMake((self.window.bounds.size.width - f.size.width) / 2,
                           self.window.safeAreaInsets.top + 12);
    label.frame = f;
    label.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.window addSubview:label];
    [UIView animateWithDuration:1.0 delay:6.0 options:0
                     animations:^{ label.alpha = 0; }
                     completion:^(BOOL) { [label removeFromSuperview]; }];
  }
  // The layer has its size once laid out; the runtime starts after that.
  dispatch_async(dispatch_get_main_queue(), ^{
    std::thread([] { RunGame(); }).detach();
  });
  return YES;
}
// Quitting (swiped away): out now. Dolphin's threads are still running, and
// exit()'s static destructors trap on them (AsyncShaderCompiler). Saves are
// already on disk (the memory card writes as the game saves).
- (void)applicationWillTerminate:(UIApplication*)application
{
  [NSUserDefaults.standardUserDefaults synchronize];
  _exit(0);
}
@end

extern "C" int moderngekko_ios_main(int argc, char** argv)
{
  @autoreleasepool
  {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([MGAppDelegate class]));
  }
}
