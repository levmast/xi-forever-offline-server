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

#pragma once

#include <cstdint>

// XI: Forever Offline: when one trust's buff waits for another trust's buff (CTrustController::Cast).
//
// The rule kept from before: a buff is not started while another trust of the party is casting a buff of the same line that is
// the same tier or higher, so two mates never put the same Protect on the same person at once.
//
// (B4, 2026-11-25: "/p blink" had the mates cast one after the other) Two things made unrelated casts wait:
//  - Blink, Stoneskin, Aquaveil and many other buffs have no spell family in spell_list (family 0). "Same family" was then
//    "any other family-0 buff": a mate's Blink held back another mate's Aquaveil. Family 0 now means "this spell only".
//  - A spell that only lands on its caster (valid target "self", single target) cannot double up on anyone: each mate's Blink is
//    on herself. Two such casts by two mates no longer wait for each other. The same spell on the same target still does.
// Party-wide buffs (Protectra, the Bar-ra spells: an area around the caster) and targeted buffs (Haste, Protect) are unchanged.
//
// Free of engine types so it can be unit tested on its own (src/test/tests/trust_cast_gate_tests.cpp).
namespace trust::castgate
{

struct Buff
{
    uint16_t id       = 0;
    uint16_t family   = 0;
    bool     selfOnly = false; // valid target "self" only and no area: it can only ever land on its caster
};

// the same spell line: the same family, or for a spell without one, the same spell
constexpr auto SameLine(const Buff& a, const Buff& b) -> bool
{
    if (a.family == 0 || b.family == 0)
    {
        return a.id == b.id;
    }

    return a.family == b.family;
}

// true when `want` must wait because another trust is casting `casting`; sameTarget: both casts land on the same entity
constexpr auto BuffWaits(const Buff& want, const Buff& casting, const bool sameTarget) -> bool
{
    if (!SameLine(want, casting) || want.id > casting.id)
    {
        return false;
    }

    if (want.selfOnly && casting.selfOnly && !sameTarget)
    {
        return false;
    }

    return true;
}

} // namespace trust::castgate
