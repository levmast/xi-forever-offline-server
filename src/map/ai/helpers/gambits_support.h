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

// XI: Forever Offline: which Gambits rules a squad mate runs out of combat (CGambitsContainer::Tick with supportOnly).
//
// (B3b, 2026-11-25: "Party member has Sleep -> Cure" did nothing once the last monster died; a member stayed asleep or petrified
// after the fight) The rules only ran in a fight. Now a squad mate that is not fighting, while you are not engaged either, runs a
// small part of its rules at the usual 2-3 second pace: the support rules. A support rule
//  - is for a party member (yourself, the party, the master, a Tank / Melee / Caster / Ranged member, the lowest HP member),
//    never for the enemy or "the target",
//  - is set off by a status: at least one of its conditions is "has status" or "has a status of a kind" (Sleep, Petrification,
//    Poison, Paralysis, a -na's effect ...),
//  - and does only spells (the spell itself must not be one cast on an enemy; checked where it is chosen).
// Everything else (buffs on a timer, weapon skills, attacks, job abilities) still runs in a fight only: a general out-of-combat
// buff scheduler is not part of this. In a fight every rule runs as before, in the order they are written.
//
// Free of engine types so it can be unit tested on its own (src/test/tests/gambits_support_tests.cpp). The numbers are those of
// G_TARGET, G_CONDITION and G_REACTION in gambits_container.h (asserted there).
namespace gambits::support
{

constexpr uint16_t TargetSelf           = 0;
constexpr uint16_t TargetParty          = 1;
constexpr uint16_t TargetMaster         = 3;
constexpr uint16_t TargetTank           = 4;
constexpr uint16_t TargetMelee          = 5;
constexpr uint16_t TargetRanged         = 6;
constexpr uint16_t TargetCaster         = 7;
constexpr uint16_t TargetPartyLowestHpp = 14;

constexpr uint16_t ConditionStatus     = 9;
constexpr uint16_t ConditionStatusFlag = 11;

constexpr uint16_t ReactionMagic = 2;

constexpr auto IsPartyTarget(const uint16_t target) -> bool
{
    switch (target)
    {
        case TargetSelf:
        case TargetParty:
        case TargetMaster:
        case TargetTank:
        case TargetMelee:
        case TargetRanged:
        case TargetCaster:
        case TargetPartyLowestHpp:
            return true;
        default:
            return false;
    }
}

constexpr auto IsStatusCondition(const uint16_t condition) -> bool
{
    return condition == ConditionStatus || condition == ConditionStatusFlag;
}

// target: the rule's target (its low byte, without the Bard role bits); anyStatus: one of its conditions is a status one;
// actions: how many actions; magicActions: how many of them are spells
constexpr auto IsSupportRule(const uint16_t target, const bool anyStatus, const int actions, const int magicActions) -> bool
{
    return IsPartyTarget(target) && anyStatus && actions > 0 && actions == magicActions;
}

} // namespace gambits::support
