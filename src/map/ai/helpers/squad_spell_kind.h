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

// XI: Forever Offline: what a spell asked for in party chat can be cast on (SquadSpellKind in modules/custom/cpp/squad.cpp, read by
// modules/custom/lua/squad_requests.lua).
//
// (2026-11-24, Ricc: "/p Protectra II" was answered "it only takes the caster") The spell table gives Protectra, Shellra, the Bar-ra
// spells, the Teleports and Escape the valid target "self", like Warp or Utsusemi: they are cast on the caster. What tells them apart
// is the area: such a spell reaches the party around its caster. A song is the same thing with its own area type (it is cast on the
// singer unless Pianissimo is up). These are requests a squad mate can answer, so they are "party", not "self".
//
// The two shapes below are exactly the ones CTrustController::Cast aims at the caster itself (valid target "self" only, or a song that
// can go on its singer), so a spell this header calls "party" for its area is one the cast path already knows how to cast.
//
// Free of engine types so it can be unit tested on its own (src/test/tests/squad_spell_kind_tests.cpp); squad.cpp asserts that the
// numbers below are the engine's (TARGETTYPE in battle_entity.h, SPELLAOE in spell.h).
namespace squad::spellkind
{

constexpr uint16_t TargetSelf     = 0x0001;
constexpr uint16_t TargetParty    = 0x0002;
constexpr uint16_t TargetAlliance = 0x0008;
constexpr uint16_t TargetDead     = 0x0020;

constexpr uint8_t AoeRadial     = 1;
constexpr uint8_t AoePianissimo = 5; // a song: around the singer, one member only under Pianissimo

enum class Kind : uint8_t
{
    Enemy,
    Dead,
    Party,
    Self,
};

struct Facts
{
    bool     canTargetEnemy = false;
    uint16_t validTargets   = 0;
    uint8_t  aoe            = 0;
    float    radius         = 0.0f; // yalms
    bool     song           = false;
};

// Cast on the caster, and it reaches the party members around it.
constexpr auto ReachesPartyAroundCaster(const Facts& spell) -> bool
{
    if (spell.canTargetEnemy || spell.radius <= 0.0f)
    {
        return false;
    }

    if (spell.song)
    {
        return spell.aoe == AoePianissimo && (spell.validTargets & TargetSelf) != 0;
    }

    return spell.aoe == AoeRadial && spell.validTargets == TargetSelf;
}

constexpr auto Classify(const Facts& spell) -> Kind
{
    if (spell.canTargetEnemy)
    {
        return Kind::Enemy;
    }

    if ((spell.validTargets & TargetDead) != 0)
    {
        return Kind::Dead;
    }

    if ((spell.validTargets & (TargetParty | TargetAlliance)) != 0 || ReachesPartyAroundCaster(spell))
    {
        return Kind::Party;
    }

    return Kind::Self;
}

constexpr auto Name(const Kind kind) -> const char*
{
    switch (kind)
    {
        case Kind::Enemy:
            return "enemy";
        case Kind::Dead:
            return "dead";
        case Kind::Party:
            return "party";
        default:
            return "self";
    }
}

} // namespace squad::spellkind
