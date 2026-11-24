/*
===========================================================================

  Copyright (c) 2018 Darkstar Dev Teams

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

#include "common/macros.h"
#include <memory>

#include "mob_controller.h"
#include "trust_hold.h"

class CCharEntity;
class CTrustEntity;
class CSpell;
class CBattleEntity;

namespace gambits
{

class CGambitsContainer;

}

class CTrustController : public CMobController
{
public:
    CTrustController(CCharEntity*, CTrustEntity*);
    ~CTrustController() override;

    DISALLOW_COPY_AND_MOVE(CTrustController);

    auto Tick(timer::time_point) -> Task<void> override;
    void Despawn() override;
    auto Ability(EntityId target, uint16 abilityid) -> bool override;
    auto Cast(EntityId target, SpellID spellid) -> bool override;
    auto RangedAttack(EntityId target) -> bool override;

    // 1.5: melee trusts used to path around at 3.0 yalms from the mob's centre and
    // then stop there, which is outside real hit range on anything larger than a
    // small mob - the swings simply missed. 1.5 keeps them inside attack range.
    static constexpr float RoamDistance    = { 1.5f };
    static constexpr float SpawnDistance   = { 3.0f };
    static constexpr float CastingDistance = { 15.0f };
    static constexpr float WarpDistance    = { 30.0f };

    auto GetTopEnmity() const -> CBattleEntity*;
    auto GetPartyPosition() const -> uint8;

    // XI: Forever Offline: a script can hold the stock engage / weapon skill decisions (trust_hold.h). true while the hold for
    // this bit (trust_hold::HoldEngage, HoldWeaponSkill) is on and its script keeps renewing it.
    auto ScriptHolds(uint32 bit) -> bool;

    std::unique_ptr<gambits::CGambitsContainer> m_GambitsContainer;

protected:
    auto DoCombatTick(timer::time_point tick) -> Task<void> override;
    auto DoRoamTick(timer::time_point tick) -> Task<void> override;

private:
    auto DoNonCombatTick(timer::time_point tick) -> Task<void>;
    auto DoCampPullTick(timer::time_point tick, const position_t& camp) -> Task<void>; // FFXI Offline squad camp
    void CampHold(const position_t& camp);
    auto EngageDelayPassed(const CBattleEntity* PTarget) -> bool; // FFXI Offline squad: per-mate engage delay
    auto OrderedTarget() -> CBattleEntity*;                       // FFXI Offline squad: !squad attack (the player's SQUAD_ATTACK_* local vars)
    void Declump(const CCharEntity* PMaster, const CBattleEntity* PTarget) const;
    void PathOutToDistance(const CBattleEntity* PTarget, float amount);

    timer::time_point m_LastRepositionTime;
    uint8             m_failedRepositionAttempts;
    bool              m_InTransit;

    timer::time_point                 m_CombatEndTime;
    timer::time_point                 m_LastHealTickTime;
    std::vector<std::chrono::seconds> m_tickDelays      = { 15s, 10s, 10s, 3s };
    std::size_t                       m_NumHealingTicks = { 0 };

    timer::time_point m_LastRangedAttackTime;
    timer::time_point m_CampRepath; // FFXI Offline squad camp: last re-path towards the camp spot or the pull target
    timer::time_point m_CampPullTry; // FFXI Offline squad camp: the puller's last pull spell or ranged shot
    uint32            m_EngageWaitTarget = 0; // FFXI Offline squad: the monster this mate is waiting to engage (engage delay)
    timer::time_point m_EngageWaitSince;      // ...and since when
    trust_hold::State m_ScriptHold;           // XI: Forever Offline: the script hold, one state for both bits (trust_hold.h)

    // FFXI Offline squad (2026-11-22): an area spell cast on oneself (Protectra, Shellra, the Bar spells) is held back
    // until its caster has stepped within reach of the player; see Cast and StepInTick
    SpellID           m_StepInSpell   = SpellID::None; // the spell that is waiting
    timer::time_point m_StepInSince;                   // ...since when (it is cast anyway after a few seconds)
    bool              m_StepInCasting = false;         // StepInTick is casting it now: do not hold it back again
    auto StepInRadius(const CSpell* PSpell, const CBattleEntity* PTarget) const -> float;
    auto AreaSpellCovers(float radius) const -> bool;
    auto StepInTick() -> bool;

public:
    // true while an area spell waits for its caster to step in (a spell asked for in party chat counts as started)
    auto IsSteppingIn() const -> bool
    {
        return m_StepInSpell != SpellID::None;
    }
};
