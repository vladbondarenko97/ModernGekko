#pragma once

#include "moderngekko/mod_abi.h"

namespace sims
{
// View coordinates (0..1 of the game view) to the game's 640x448 screen.
bool ToGame(float vx, float vy, float* gx, float* gy);
// Moves the game's screen cursor there; false when no cursor is up (in a
// lot, where the stick walks the Sim). Any thread; pauses the CPU briefly.
bool PointCursorAt(float vx, float vy);
// A built-in mod: no startup movies (the game's own -nomovies path).
const ModernGekkoModDesc* SkipIntroMod();
}  // namespace sims
