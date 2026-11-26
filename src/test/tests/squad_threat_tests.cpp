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

// XI: Forever Offline: which monsters are the party's fight (map/ai/helpers/squad_threat.h: B1 camp links and pets, F2 counts)
// and the comparisons of the count conditions; plus gambits_support.h (B3b: the rules a mate runs out of combat).

#include "map/ai/helpers/gambits_support.h"
#include "map/ai/helpers/squad_threat.h"

#include <catch2/catch_test_macros.hpp>

using squad::threat::CountMatches;
using squad::threat::Foe;
using squad::threat::IsPartyFoe;

namespace
{
constexpr auto foe(const float dist, const bool targetsParty, const bool partyEnmity) -> Foe
{
    return Foe{ .alive = true, .hostile = true, .distance = dist, .heightGap = 0.0f, .targetsParty = targetsParty, .partyEnmity = partyEnmity };
}
} // namespace

TEST_CASE("threat: a link that hits a party member inside the camp's reach is the camp's fight", "[squad][threat]")
{
    CHECK(IsPartyFoe(foe(12.0f, true, true), 20.0f));
    CHECK(IsPartyFoe(foe(12.0f, false, true), 20.0f)); // (enmity on one of you: a monster's pet that has not hit yet)
    CHECK(IsPartyFoe(foe(20.0f, true, false), 20.0f)); // (the edge counts)
}

TEST_CASE("threat: a monster only standing nearby is not", "[squad][threat]")
{
    CHECK_FALSE(IsPartyFoe(foe(5.0f, false, false), 20.0f));
}

TEST_CASE("threat: outside the reach, dead, not hostile, or on another floor is not", "[squad][threat]")
{
    CHECK_FALSE(IsPartyFoe(foe(20.5f, true, true), 20.0f));

    Foe dead = foe(5.0f, true, true);
    dead.alive = false;
    CHECK_FALSE(IsPartyFoe(dead, 20.0f));

    Foe pet = foe(5.0f, true, true);
    pet.hostile = false; // (a player's pet, a trust)
    CHECK_FALSE(IsPartyFoe(pet, 20.0f));

    Foe below = foe(5.0f, true, true);
    below.heightGap = -15.0f;
    CHECK_FALSE(IsPartyFoe(below, 20.0f));
    below.heightGap = 13.0f;
    CHECK(IsPartyFoe(below, 20.0f));
}

TEST_CASE("count: below, equal to and above the threshold, every comparison", "[squad][count]")
{
    // 0 at least, 1 exactly, 2 at most, 3 more than, 4 fewer than
    CHECK_FALSE(CountMatches(1, 0, 2));
    CHECK(CountMatches(2, 0, 2));
    CHECK(CountMatches(3, 0, 2));

    CHECK_FALSE(CountMatches(1, 1, 2));
    CHECK(CountMatches(2, 1, 2));
    CHECK_FALSE(CountMatches(3, 1, 2));

    CHECK(CountMatches(1, 2, 2));
    CHECK(CountMatches(2, 2, 2));
    CHECK_FALSE(CountMatches(3, 2, 2));

    CHECK_FALSE(CountMatches(1, 3, 2));
    CHECK_FALSE(CountMatches(2, 3, 2));
    CHECK(CountMatches(3, 3, 2));

    CHECK(CountMatches(1, 4, 2));
    CHECK_FALSE(CountMatches(2, 4, 2));
    CHECK_FALSE(CountMatches(3, 4, 2));

    CHECK(CountMatches(5, 7, 2)); // (an unknown comparison is "at least")
}

TEST_CASE("support rules: status-triggered spells on party members only", "[gambits][support]")
{
    using namespace gambits::support;
    // Party member has Sleep -> Cure; Self has Petrification -> Stona; lowest HP member has Poison -> Poisona
    CHECK(IsSupportRule(TargetParty, true, 1, 1));
    CHECK(IsSupportRule(TargetSelf, true, 1, 1));
    CHECK(IsSupportRule(TargetPartyLowestHpp, true, 1, 1));
    CHECK(IsSupportRule(TargetTank, true, 1, 1));
    CHECK(IsSupportRule(TargetMaster, true, 1, 1));

    CHECK_FALSE(IsSupportRule(TargetParty, false, 1, 1)); // "HP below 50% -> Cure" or "missing Protect -> Protect": in a fight only
    CHECK_FALSE(IsSupportRule(2, true, 1, 1));            // the enemy (TARGET)
    CHECK_FALSE(IsSupportRule(8, true, 1, 1));            // TOP_ENMITY needs a fight
    CHECK_FALSE(IsSupportRule(13, true, 1, 1));           // TRIGGER_TARGET_ACTION_SELF looks at the enemy
    CHECK_FALSE(IsSupportRule(TargetParty, true, 1, 0));  // a job ability
    CHECK_FALSE(IsSupportRule(TargetParty, true, 2, 1));  // a spell and an ability
    CHECK_FALSE(IsSupportRule(TargetParty, true, 0, 0));  // nothing to do

    CHECK(IsStatusCondition(ConditionStatus));
    CHECK(IsStatusCondition(ConditionStatusFlag));
    CHECK_FALSE(IsStatusCondition(10)); // NOT_STATUS ("missing Protect"): a buff timer, not part of this
}
