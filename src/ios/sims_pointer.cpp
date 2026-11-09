// Tap-to-point for The Sims 2: Pets: puts the game's screen cursor (the
// neighbourhood's arrow, menus that have one) where a tap landed.
// The cursor is a heap object, found by its shape: s32 x, y (640x448
// screen space), the same two as floats 0x14 bytes on, and before them
// its bounds (max x, min, max y; 620, 20, 428 in the neighbourhood).
// Found on the Mac by diffing RAM while the stick moved it; writing x, y
// moves it. The address is cached and re-checked on every tap.
// ponytail: a full MEM1 scan when the cache misses (a few ms, taps only).

#include "sims_pointer.h"

#include <algorithm>
#include <bit>
#include <cstring>

#include "Core/Core.h"
#include "moderngekko/cpu_state.h"
#include "Core/HW/Memmap.h"
#include "Core/System.h"
#include "VideoCommon/Present.h"

namespace
{
constexpr u32 kMem1 = 0x80000000, kMem1Size = 24 * 1024 * 1024;
constexpr float kGameW = 640, kGameH = 448;
u32 s_cursor = 0;  // guest address of x (0: not known)

u32 Load(const u8* ram, u32 off)
{
  u32 v;
  std::memcpy(&v, ram + off, 4);
  return std::byteswap(v);
}

bool IsCursor(const u8* ram, u32 off)
{
  if (off < 12 || off + 28 > kMem1Size)
    return false;
  const u32 x = Load(ram, off), y = Load(ram, off + 4);
  if (x == 0 || x > 1024 || y == 0 || y > 1024)
    return false;
  if (std::bit_cast<float>(Load(ram, off + 0x14)) != float(x) ||
      std::bit_cast<float>(Load(ram, off + 0x18)) != float(y))
    return false;
  const u32 max_x = Load(ram, off - 12), min = Load(ram, off - 8), max_y = Load(ram, off - 4);
  return max_x >= x && max_x <= 1024 && min < max_x && min <= y && max_y >= y && max_y <= 1024;
}
}  // namespace

namespace sims
{
bool ToGame(float vx, float vy, float* gx, float* gy)
{
  if (!g_presenter)
    return false;
  const auto& r = g_presenter->GetTargetRectangle();
  if (r.GetWidth() <= 0 || r.GetHeight() <= 0)
    return false;
  const float px = vx * g_presenter->GetBackbufferWidth();
  const float py = vy * g_presenter->GetBackbufferHeight();
  *gx = (px - r.left) / r.GetWidth() * kGameW;
  *gy = (py - r.top) / r.GetHeight() * kGameH;
  return true;
}

bool PointCursorAt(float vx, float vy)
{
  float gx, gy;
  if (!ToGame(vx, vy, &gx, &gy))
    return false;
  auto& system = Core::System::GetInstance();
  const Core::CPUThreadGuard guard(system);
  u8* ram = system.GetMemory().GetPointerForRange(kMem1, kMem1Size);
  if (!ram)
    return false;
  u32 off = s_cursor ? s_cursor - kMem1 : 0;
  if (!s_cursor || !IsCursor(ram, off))
  {
    s_cursor = 0;
    for (off = 12; off + 28 <= kMem1Size; off += 4)
    {
      if (IsCursor(ram, off))
      {
        s_cursor = kMem1 + off;
        break;
      }
    }
    if (!s_cursor)
      return false;
  }
  const u32 max_x = Load(ram, off - 12), min = Load(ram, off - 8), max_y = Load(ram, off - 4);
  const u32 x = std::byteswap(u32(std::clamp(gx, float(min), float(max_x))));
  const u32 y = std::byteswap(u32(std::clamp(gy, float(min), float(max_y))));
  std::memcpy(ram + off, &x, 4);
  std::memcpy(ram + off + 4, &y, 4);
  return true;
}
}  // namespace sims

// Skip the startup movies (EA/Maxis logos, intro): the game's own
// "-nomovies" command-line switch. At 0x80208490 it tests HasArg("-nomovies")
// (0x8020848C) and on a hit sets skip_startup_movies (+952), skip_maxis_logo
// (+956) and skip_start_screen (+960) in the object in r30 (0x802084B0..BC).
// This mod patch sets the first two; +960 alone didn't remove Press START.
// The health warning and "Licensed by Nintendo" are the SDK's, still shown.
namespace
{
void SkipStartupMovies(CPUState* state)
{
  const u32 one = std::byteswap(1u);
  for (u32 offset : {952u, 956u})
  {
    const u32 address = (state->gpr[30] + offset) & 0x7FFFFFFF;
    if (address + 4 <= state->ram_size)
      std::memcpy(state->ram + address, &one, 4);
  }
  state->gpr[0] = 1;
  state->pc = 0x802084C0;  // past the three stores
}

const ModernGekkoModPatch kPatches[] = {{0x80208490, SkipStartupMovies, MODERNGEKKO_MOD_PATCH_ONCE}};
const ModernGekkoModDesc kSkipIntro = {
    MODERNGEKKO_MOD_ABI_VERSION, MODERNGEKKO_CPU_ABI_VERSION, sizeof(CPUState), "G4OE69",
    "sims2pets.skip-intro", "1.0.0", "Skip the startup movies",
    nullptr, 0, kPatches, 1, nullptr, 0, nullptr, 0, nullptr, 0, nullptr, 0, nullptr, 0,
    nullptr, nullptr};
}  // namespace

const ModernGekkoModDesc* sims::SkipIntroMod()
{
  return &kSkipIntro;
}
