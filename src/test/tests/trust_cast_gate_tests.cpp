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

// XI: Forever Offline: when one trust's buff waits for another trust's buff (map/ai/helpers/trust_cast_gate.h).
// Spell ids and families are those of sql/spell_list.sql: Blink 53, Stoneskin 54, Aquaveil 55 (family 0, self only),
// Phalanx 106 (family 27, self only), Protect 43 / Protect II 44 (family 10), Haste 57 (family 13), Protectra 125 / II 126 (family 39).

#include "map/ai/helpers/trust_cast_gate.h"

#include <catch2/catch_test_macros.hpp>

using trust::castgate::Buff;
using trust::castgate::BuffWaits;
using trust::castgate::SameLine;

namespace
{
constexpr Buff Blink{ .id = 53, .family = 0, .selfOnly = true };
constexpr Buff Stoneskin{ .id = 54, .family = 0, .selfOnly = true };
constexpr Buff Aquaveil{ .id = 55, .family = 0, .selfOnly = true };
constexpr Buff Phalanx{ .id = 106, .family = 27, .selfOnly = true };
constexpr Buff Protect{ .id = 43, .family = 10, .selfOnly = false };
constexpr Buff ProtectII{ .id = 44, .family = 10, .selfOnly = false };
constexpr Buff Haste{ .id = 57, .family = 13, .selfOnly = false };
constexpr Buff Protectra{ .id = 125, .family = 39, .selfOnly = false };
constexpr Buff ProtectraII{ .id = 126, .family = 39, .selfOnly = false };
constexpr Buff Sneak{ .id = 137, .family = 0, .selfOnly = false };
constexpr Buff Invisible{ .id = 136, .family = 0, .selfOnly = false };
} // namespace

TEST_CASE("cast gate: two mates' Blink, each on herself, do not wait (B4)", "[trust][castgate]")
{
    CHECK_FALSE(BuffWaits(Blink, Blink, false));
    CHECK_FALSE(BuffWaits(Aquaveil, Aquaveil, false));
    CHECK_FALSE(BuffWaits(Phalanx, Phalanx, false));
}

TEST_CASE("cast gate: family 0 is not one family (Blink does not hold Aquaveil or Stoneskin)", "[trust][castgate]")
{
    CHECK_FALSE(SameLine(Blink, Aquaveil));
    CHECK_FALSE(BuffWaits(Blink, Aquaveil, false));
    CHECK_FALSE(BuffWaits(Blink, Stoneskin, false));
    CHECK_FALSE(BuffWaits(Sneak, Invisible, true)); // (two different spells on you, from two mates)
}

TEST_CASE("cast gate: the same spell on the same target still waits", "[trust][castgate]")
{
    CHECK(BuffWaits(Blink, Blink, true)); // (cannot happen for a self-only spell from two casters, kept as before)
    CHECK(BuffWaits(Sneak, Sneak, true));
    CHECK(BuffWaits(Haste, Haste, true));
}

TEST_CASE("cast gate: targeted buffs of one family wait as before, whoever they are for", "[trust][castgate]")
{
    CHECK(BuffWaits(Protect, Protect, true));
    CHECK(BuffWaits(Protect, Protect, false));
    CHECK(BuffWaits(Protect, ProtectII, false)); // a lower tier waits for the higher one being cast
    CHECK_FALSE(BuffWaits(ProtectII, Protect, false)); // a higher tier does not
    CHECK(BuffWaits(Sneak, Sneak, false));
}

TEST_CASE("cast gate: party-wide buffs keep their coordination", "[trust][castgate]")
{
    CHECK(BuffWaits(Protectra, Protectra, false));
    CHECK(BuffWaits(Protectra, ProtectraII, false));
    CHECK_FALSE(BuffWaits(ProtectraII, Protectra, false));
}

TEST_CASE("cast gate: different families never wait", "[trust][castgate]")
{
    CHECK_FALSE(BuffWaits(Haste, Protect, true));
    CHECK_FALSE(BuffWaits(Phalanx, Protect, true));
}
