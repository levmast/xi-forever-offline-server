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

// XI: Forever Offline (F13): the avatar perpetuation of one regen tick (map/utils/avatar_perpetuation.h), the rule a
// player and a squad Summoner both pay by. The expected values follow the order of the original TickRegen code.

#include "map/utils/avatar_perpetuation.h"

#include <catch2/catch_test_macros.hpp>

TEST_CASE("avatar perpetuation: no gear, the base cost", "[perpetuation]")
{
    avatarperp::Inputs in{};
    in.base   = 13; // an elemental avatar at level 75 (job_utils/summoner.lua avatarPerpThresholds)
    in.hasPet = true;
    CHECK(avatarperp::Cost(in) == 13);
}

TEST_CASE("avatar perpetuation: gear reductions, day, weather and affinity", "[perpetuation]")
{
    avatarperp::Inputs in{};
    in.base      = 13;
    in.hasPet    = true;
    in.reduction = 3; // PERPETUATION_REDUCTION gear
    CHECK(avatarperp::Cost(in) == 10);

    in.affinity = 2; // the avatar element's affinity gear
    CHECK(avatarperp::Cost(in) == 8);

    in.dayReduction = 1;
    CHECK(avatarperp::Cost(in) == 8); // (no day match: no effect)
    in.dayMatch = true;
    CHECK(avatarperp::Cost(in) == 7);

    in.weatherReduction = 2;
    in.weatherMatch     = true;
    CHECK(avatarperp::Cost(in) == 5);
}

TEST_CASE("avatar perpetuation: halving comes first and is floored; Avatar's Favor multiplies last", "[perpetuation]")
{
    avatarperp::Inputs in{};
    in.base      = 13;
    in.hasPet    = true;
    in.halved    = true; // 13 / 2 = 6
    in.reduction = 1;    // 5
    CHECK(avatarperp::Cost(in) == 5);

    in.avatarsFavor = true; // 5 * 1.2 = 6
    CHECK(avatarperp::Cost(in) == 6);
}

TEST_CASE("avatar perpetuation: at least 1, and 0 under Astral Flow", "[perpetuation]")
{
    avatarperp::Inputs in{};
    in.base      = 4;
    in.hasPet    = true;
    in.reduction = 10;
    CHECK(avatarperp::Cost(in) == 1);

    in.astralFlow = true;
    CHECK(avatarperp::Cost(in) == 0);
}

TEST_CASE("avatar perpetuation: without a pet only the base applies (a player whose mod was not cleared)", "[perpetuation]")
{
    avatarperp::Inputs in{};
    in.base      = 9;
    in.reduction = 5; // ignored without a pet, as before
    CHECK(avatarperp::Cost(in) == 9);
}
