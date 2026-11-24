/*
===========================================================================

  Copyright (c) 2026 LandSandBoat Dev Teams

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see http://www.gnu.org/licenses/

===========================================================================
*/

// XI: Forever Offline: the script hold on a trust's stock engage / weapon skills (map/ai/controllers/trust_hold.h)

#include "map/ai/controllers/trust_hold.h"

#include <catch2/catch_test_macros.hpp>

using trust_hold::HoldEngage;
using trust_hold::HoldWeaponSkill;
using trust_hold::State;

namespace
{
constexpr int64_t Second = 1000;
} // namespace

TEST_CASE("trust hold: a trust no script holds is never held", "[trust][hold]")
{
    State state;
    for (int64_t t = 0; t < 20 * Second; t += Second)
    {
        CHECK_FALSE(state.Active(0, 0, HoldEngage, t));
        CHECK_FALSE(state.Active(0, 5, HoldWeaponSkill, t)); // (a stray counter without a mask is nothing)
    }
}

TEST_CASE("trust hold: a mask with a counter that never moved is not a hold", "[trust][hold]")
{
    State state;
    CHECK_FALSE(state.Active(HoldEngage, 0, HoldEngage, 0));
    CHECK_FALSE(state.Active(HoldEngage, 0, HoldEngage, Second));
}

TEST_CASE("trust hold: a renewed hold holds, only the bits asked for", "[trust][hold]")
{
    State state;
    uint32_t seq = 1;
    CHECK(state.Active(HoldEngage, seq, HoldEngage, 0));
    CHECK_FALSE(state.Active(HoldEngage, seq, HoldWeaponSkill, 0)); // the weapon skill bit is not set

    for (int64_t t = Second; t <= 30 * Second; t += Second)
    {
        ++seq; // the script renews once a second
        CHECK(state.Active(HoldEngage, seq, HoldEngage, t));
    }

    CHECK(state.Active(HoldEngage | HoldWeaponSkill, seq + 1, HoldWeaponSkill, 31 * Second));
    CHECK(state.Active(HoldEngage | HoldWeaponSkill, seq + 1, HoldEngage, 31 * Second)); // (one counter serves both bits)
}

TEST_CASE("trust hold: three seconds after the last renewal the trust is back on the stock AI", "[trust][hold]")
{
    State state;
    CHECK(state.Active(HoldEngage, 1, HoldEngage, 0));
    CHECK(state.Active(HoldEngage, 2, HoldEngage, Second));

    // the script stops (reload, crash, !stop): the mask stays set, the counter stops
    CHECK(state.Active(HoldEngage, 2, HoldEngage, 2 * Second));
    CHECK(state.Active(HoldEngage, 2, HoldEngage, 3 * Second));
    CHECK(state.Active(HoldEngage, 2, HoldEngage, 3999));
    CHECK_FALSE(state.Active(HoldEngage, 2, HoldEngage, 4 * Second));
    CHECK_FALSE(state.Active(HoldEngage, 2, HoldEngage, 600 * Second));
}

TEST_CASE("trust hold: renewing again after a lapse holds again", "[trust][hold]")
{
    State state;
    CHECK(state.Active(HoldEngage, 1, HoldEngage, 0));
    CHECK_FALSE(state.Active(HoldEngage, 1, HoldEngage, 10 * Second));
    CHECK(state.Active(HoldEngage, 2, HoldEngage, 11 * Second));
    CHECK(state.Active(HoldEngage, 2, HoldEngage, 13 * Second));
}

TEST_CASE("trust hold: clearing the mask lets go at once", "[trust][hold]")
{
    State state;
    CHECK(state.Active(HoldEngage, 1, HoldEngage, 0));
    CHECK_FALSE(state.Active(0, 1, HoldEngage, Second));
    CHECK_FALSE(state.Active(HoldWeaponSkill, 2, HoldEngage, 2 * Second)); // (only the weapon skill bit is left)
}
