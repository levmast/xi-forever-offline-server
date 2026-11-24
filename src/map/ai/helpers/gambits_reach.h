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

#include <algorithm>
#include <cstdint>
#include <optional>

// XI: Forever Offline (2026-11-21, Ricc: "my healer keeps running out of range and doesn't heal"). How far a gambit's
// party-type target (PARTY, PARTY_LOWEST_HPP, TANK, MELEE, RANGED, CASTER, TOP_ENMITY, CURILLA) may be from the caster.
//
// Inherited rule: 15 yalms for every action. Squad positioning (squad_space.lua) holds a White Mage 12.5-17.5 yalms from
// the monster at a random angle, so the tank was often 15-20 yalms away and no cure rule could pick it, although the cast
// itself is valid for a trust up to 28.5 yalms (CMagicState::CanCastSpell).
//
// Squad mates only, and only when the rule's action is a spell known before the target is chosen:
//   - a spell cast on a party member (Cure, Haste, -na ...): its own range plus both hitboxes, the rule players get in
//     CMagicState::CanCastSpell; never below the inherited 15 and never above the trust cast limit less a margin
//   - a self-only spell with an area (Protectra, Shellra): its radius, the rule CTargetFind::isWithinArea applies; a member
//     outside it would not be covered, so the rule no longer fires for them
//   - a self-only spell without an area: the caster only
//   - a song (sung on the singer, it reaches its radius of 10 like Protectra) and, under the retail area range
//     (map.TRUST_AOE_RANGE), a job ability used on oneself with an area (Corsair rolls, Warcry): the radius
// Everything else (job abilities without an area, ranged attacks, mixed or target-dependent actions) keeps 15 yalms.
// Ordinary trusts keep 15 yalms too, except for such an area effect on oneself (TrustPartyReach, retail area range only).
// The functions are free of engine types so they can be unit tested on their own (src/test/tests/gambits_reach_tests.cpp).
namespace gambits::reach
{

constexpr float InheritedPartyReach = 15.0f; // the radius every party-type target used before
constexpr float TrustCastLimit      = 28.5f; // CMagicState::CanCastSpell: mobs (and so trusts) beyond this cannot cast
constexpr float TrustCastMargin     = 1.5f;  // room for the target to move during the cast (checked again at the end)

// The two TARGETTYPE flags (entities/battle_entity.h) this file needs; gambits_container.cpp static_asserts they match
constexpr uint16_t TargetSelf                  = 0x0001;
constexpr uint16_t TargetPlayerParty           = 0x0002;
constexpr uint16_t TargetEnemy                 = 0x0004;
constexpr uint16_t TargetPlayerPartyPianissimo = 0x0080;

// What a rule's spell says about its reach, read from CSpell before any target is chosen
struct SpellReach
{
    bool  selfOnly; // valid target is the caster only (CTrustController::Cast then casts it on the caster)
    float range;    // CSpell::getRange(), yalms (spell_list.spell_range / 10)
    float radius;   // CSpell::getRadius(), yalms; 0 = single target
};

// From a spell's data (CSpell::getValidTarget/getRange/getRadius). Empty for a spell that is neither cast on the caster
// only nor on a party member (an enemy spell in a party rule): such a rule keeps the inherited reach.
//
// A song (valid targets 129: the singer plus a party member under Pianissimo, never an enemy) is sung on the singer and
// lands on whoever stands inside its radius (10 yalms), exactly like Protectra: CTrustController::Cast sings it on the
// caster unless Pianissimo is up. It used to fall through to the inherited 15 yalms, so a rule "a melee member lacks Minuet"
// kept choosing a member 10 to 15 yalms away that the song cannot reach.
inline auto FromSpellData(const uint16_t validTargets, const float range, const float radius) -> std::optional<SpellReach>
{
    if (validTargets == TargetSelf)
    {
        return SpellReach{ true, range, radius };
    }

    if ((validTargets & TargetSelf) != 0 && (validTargets & TargetPlayerPartyPianissimo) != 0 && (validTargets & (TargetPlayerParty | TargetEnemy)) == 0)
    {
        return SpellReach{ true, range, radius };
    }

    if ((validTargets & TargetPlayerParty) != 0)
    {
        return SpellReach{ false, range, radius };
    }

    return std::nullopt;
}

// From a job ability's data (CAbility::getValidTarget/getRadius): an ability used on oneself that works as an area effect
// around the user (the Corsair rolls 8 yalms, Warcry 14, Rampart 14 ...) reaches whoever stands inside the radius. Every other
// ability (single target, or self only without an area) keeps the inherited reach, as before.
inline auto FromAbilityData(const uint16_t validTargets, const float radius) -> std::optional<SpellReach>
{
    if (validTargets == TargetSelf && radius > 0.0f)
    {
        return SpellReach{ true, 0.0f, radius };
    }

    return std::nullopt;
}

// Ordinary trusts (not squad mates) keep the inherited 15 yalms for everything except an area effect cast on oneself, which
// reaches only its radius: Kupipi's Protectra, Qultada's rolls and a bard's songs fire for a member inside the radius
// and are not wasted on one just outside it.
inline auto TrustPartyReach(const std::optional<SpellReach>& spell) -> float
{
    if (spell.has_value() && spell->selfOnly && spell->radius > 0.0f)
    {
        return spell->radius;
    }

    return InheritedPartyReach;
}

// The furthest a party member may be from the caster for this rule. spell is empty when the rule is not a plain spell
// rule (or its spell cannot be known yet); squadMate is false for ordinary trusts.
inline auto PartyReach(const bool squadMate, const std::optional<SpellReach>& spell, const float casterHitbox, const float memberHitbox) -> float
{
    if (!squadMate || !spell.has_value())
    {
        return InheritedPartyReach;
    }

    if (spell->selfOnly)
    {
        // Lands on the caster; with an area it reaches whoever stands inside it, measured from the caster's centre
        return spell->radius > 0.0f ? spell->radius : 0.0f;
    }

    if (spell->range <= 0.0f)
    {
        return InheritedPartyReach; // (no range in the data: nothing better to go by)
    }

    const float castable = spell->range + std::max(casterHitbox, 0.0f) + std::max(memberHitbox, 0.0f);
    return std::clamp(castable, InheritedPartyReach, TrustCastLimit - TrustCastMargin);
}

// 3D distance test, the same measure as distance() in common/utils.h (vertical separation counts)
template <typename Position>
auto WithinReach(const Position& a, const Position& b, const float reach) -> bool
{
    if (reach < 0.0f)
    {
        return false;
    }

    const float dx = a.x - b.x;
    const float dy = a.y - b.y;
    const float dz = a.z - b.z;
    return dx * dx + dy * dy + dz * dz <= reach * reach;
}

} // namespace gambits::reach
