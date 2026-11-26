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

// XI: Forever Offline: which monsters are "the party's fight" (CTrustController::PartyFoes).
//
// (B1, 2026-11-25: a camp squad stood still while a linked monster or a monster's pet chewed on the party after the pulled one
// died, and the puller went for the next one) A monster is part of the party's fight when it is alive, hostile, near enough to the
// place that matters (the camp, or the rule's target for a Gambits count), and it is fighting the party: a member of the player's
// party (the player or a mate) is its target, or it has live enmity on one. A monster that is merely nearby, asleep, or fighting
// somebody else is not. The pulled monster on its way in counts too once it is near enough, as it always did.
//
// Free of engine types so it can be unit tested on its own (src/test/tests/squad_threat_tests.cpp).
namespace squad::threat
{

struct Foe
{
    bool  alive        = false;
    bool  hostile      = false; // allegiance Mob (a monster or a monster's pet; never a player's pet or a trust)
    float distance     = 0.0f;  // yalms from the anchor (the camp, or the target of a rule)
    float heightGap    = 0.0f;  // yalms up or down from the anchor
    bool  targetsParty = false; // its battle target is the player or one of his party (mates included)
    bool  partyEnmity  = false; // it holds live enmity (active, CE + VE > 0) on one of them
};

constexpr float MaxHeightGap = 14.0f; // another floor (Crawlers' Nest) is not the camp's fight (CAMP_MAX_DY in squad.lua)

constexpr auto IsPartyFoe(const Foe& foe, const float radius) -> bool
{
    if (!foe.alive || !foe.hostile || foe.distance > radius)
    {
        return false;
    }

    if (foe.heightGap > MaxHeightGap || foe.heightGap < -MaxHeightGap)
    {
        return false;
    }

    return foe.targetsParty || foe.partyEnmity;
}

// F2 "count" conditions: `count` compared with `threshold` by `op` (0: at least, 1: exactly, 2: at most, 3: more than, 4: fewer than)
constexpr auto CountMatches(const int count, const int op, const int threshold) -> bool
{
    switch (op)
    {
        case 1:
            return count == threshold;
        case 2:
            return count <= threshold;
        case 3:
            return count > threshold;
        case 4:
            return count < threshold;
        default:
            return count >= threshold;
    }
}

} // namespace squad::threat
