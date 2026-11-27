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

#include "trust_controller.h"

#include "ability.h"
#include "common/earth_time.h"
#include "ai/helpers/gambits_container.h"
#include "ai/helpers/squad_cast_approach.h"
#include "ai/helpers/squad_follow.h"
#include "ai/helpers/squad_position.h"
#include "ai/helpers/squad_threat.h"
#include "ai/helpers/trust_cast_gate.h"
#include "ai/helpers/trust_enmity_target.h"
#include "ai/states/magic_state.h"
#include "ai/states/range_state.h"
#include "data/enums/mob_mod.h"
#include "enmity_container.h"
#include "entities/char_entity.h"
#include "entities/trust_entity.h"
#include "items/item_weapon.h"
#include "player_controller.h"
#include "recast_container.h"
#include "utils/charutils.h"
#include "entities/mob_entity.h"
#include "mob_spell_container.h"

#include <algorithm>
#include <optional>
#include <cmath>

namespace
{

enum TRUST_MOVEMENT_TYPE : int8
{
    // NOTE: If you need to add special movement types, add descending into the minus values.
    //     : All of the positive values are taken for the ranged movement range.
    // NOTE: You can use any positive value as a distance, and it will act as MID_RANGE or LONG_RANGE, but with the value you've provided.
    //     : For example:
    //     :     mob:setMobMod(xi.mobMod.TRUST_DISTANCE, 20)
    //     : Will set the combat distance the trust tries to stick to to 20'
    // NOTE: If a Trust doesn't immediately sprint to a certain distance at the start of battle, it's probably NO_MOVE or MELEE.
    NO_MOVE    = -1, // Will stand still providing they're within casting distance of their master and target when the fight starts. Otherwise will reposition to be within 9.0' of the target (the master is not considered)
    NON_COMBAT = -2, // Will follow the master if first trust in party and will follow the trust in front if lower in the list.
    MELEE      = 0,  // Default: will continually reposition to stay within melee range of the target
    MID_RANGE  = 6,  // Will path at the start of battle to 6' away from the target, and try to stay at that distance
    LONG_RANGE = 12, // Will path at the start of battle to 12' away from the target, and try to stay at that distance
};

// FFXI Offline squad camp (squad.lua: !squad camp / !squad pull). Squad mates (local var SQUAD_ID) with SQUAD_CAMP
// set hold a spot around the camp instead of following you, fight what comes within CampFightRadius of it (even when
// you are not engaged: a mate pulled it, or you are resting), and let go of anything farther than CampLeash.
// A mate with SQUAD_PULL_PHASE 1 runs out to SQUAD_PULL_TARGET (a mob's targid) and pulls it; once the mob is
// engaged (2) it runs back to camp, and at camp the phase goes back to 0, the puller engages it and the fight is on.
// (2026-11-24, levi) A puller with a pull spell or a ranged weapon pulls without engaging (no weapon out, no melee):
// it shoots or casts from range, runs home with its weapon away, and engages only at camp. One with neither (or
// whose three shots and three casts all failed) walks in and engages as before.
// The camp position is in SQUAD_CAMP_X / _Y / _Z, as yalms * 100 + 10000000 (local vars are unsigned).
constexpr float CampHoldRadius  = 2.5f;
constexpr float CampFightRadius = 20.0f;
constexpr float CampLeash       = 30.0f;

auto campDecode(const uint32 value) -> float
{
    return static_cast<float>(static_cast<int64>(value) - 10000000) / 100.0f;
}

auto campOf(const CBaseEntity* PTrust, position_t& camp) -> bool
{
    if (PTrust == nullptr || PTrust->GetLocalVar("SQUAD_ID") == 0 || PTrust->GetLocalVar("SQUAD_CAMP") == 0)
    {
        return false;
    }

    camp   = PTrust->loc.p;
    camp.x = campDecode(PTrust->GetLocalVar("SQUAD_CAMP_X"));
    camp.y = campDecode(PTrust->GetLocalVar("SQUAD_CAMP_Y"));
    camp.z = campDecode(PTrust->GetLocalVar("SQUAD_CAMP_Z"));
    return true;
}

} // namespace

// FFXI Offline squad (B1, 2026-11-25): the monsters fighting PMaster's party (the player, his party, the mates) within `radius`
// of `anchor`, nearest first. The rule is squad_threat.h; the monsters looked at are the ones the player can see (his spawn
// lists), which covers a camp he stands at and every fight a rule can reach.
auto CTrustController::PartyFoes(CCharEntity* PMaster, const position_t& anchor, const float radius) -> std::vector<CBattleEntity*>
{
    std::vector<CBattleEntity*> out;
    if (PMaster == nullptr)
    {
        return out;
    }

    std::vector<uint32> members;
    members.push_back(PMaster->id);
    // clang-format off
    PMaster->ForPartyWithTrusts([&](const CBattleEntity* PMember)
    {
        members.push_back(PMember->id);
    });
    // clang-format on
    for (const auto* PTrust : PMaster->PTrusts)
    {
        if (PTrust != nullptr)
        {
            members.push_back(PTrust->id);
        }
    }

    const auto isMember = [&](const uint32 id)
    {
        return std::find(members.begin(), members.end(), id) != members.end();
    };

    std::vector<std::pair<float, CBattleEntity*>> found;
    const auto consider = [&](CBaseEntity* PBase)
    {
        auto* PMob = dynamic_cast<CMobEntity*>(PBase);
        if (PMob == nullptr || PMob->PEnmityContainer == nullptr)
        {
            return;
        }

        squad::threat::Foe foe;
        foe.alive     = !PMob->isDead() && PMob->status != xi::Status::Disappear;
        foe.hostile   = PMob->allegiance == xi::Allegiance::Mob;
        foe.distance  = distance(PMob->loc.p, anchor);
        foe.heightGap = PMob->loc.p.y - anchor.y;
        if (const auto* PTarget = PMob->GetBattleTarget(); PTarget != nullptr)
        {
            foe.targetsParty = isMember(PTarget->id);
        }

        if (!foe.targetsParty)
        {
            for (const auto& [id, entry] : *PMob->PEnmityContainer->GetEnmityList())
            {
                if (entry.active && (entry.CE + entry.VE) > 0 && isMember(id))
                {
                    foe.partyEnmity = true;
                    break;
                }
            }
        }

        if (squad::threat::IsPartyFoe(foe, radius))
        {
            found.emplace_back(foe.distance, PMob);
        }
    };

    for (const auto& [id, PEntity] : PMaster->SpawnMOBList)
    {
        consider(PEntity);
    }

    for (const auto& [id, PEntity] : PMaster->SpawnPETList) // (a monster's pet: allegiance Mob; the players' pets are not)
    {
        consider(PEntity);
    }

    std::sort(found.begin(), found.end(), [](const auto& a, const auto& b)
              {
                  return a.first < b.first;
              });
    for (const auto& [d, PFoe] : found)
    {
        out.push_back(PFoe);
    }

    return out;
}

// FFXI Offline squad (B1): the nearest monster fighting the party at this camp. The one a mate is pulling in is left to the pull
// (squad.lua holds the camp until it is close, so nobody runs out to meet it), as before.
auto CTrustController::CampThreat(const position_t& camp) -> CBattleEntity*
{
    auto* PMaster = dynamic_cast<CCharEntity*>(POwner->PMaster);
    if (PMaster == nullptr)
    {
        return nullptr;
    }

    std::vector<uint16> pulling;
    for (const auto* PTrust : PMaster->PTrusts)
    {
        if (PTrust != nullptr && PTrust->GetLocalVar("SQUAD_PULL_PHASE") != 0 && PTrust->GetLocalVar("SQUAD_PULL_TARGET") != 0)
        {
            pulling.push_back(static_cast<uint16>(PTrust->GetLocalVar("SQUAD_PULL_TARGET")));
        }
    }

    for (auto* PFoe : PartyFoes(PMaster, camp, CampFightRadius))
    {
        if (std::find(pulling.begin(), pulling.end(), PFoe->targid) == pulling.end())
        {
            return PFoe;
        }
    }

    return nullptr;
}

// FFXI Offline squad (B5, 2026-11-25): walk toward `goal`, stopping `want` yalms short. Closer than `nearBand`, and for every
// trust that is not a squad mate, exactly as before: a fresh path every tick, else the wall-safe straight step. A squad mate
// further away keeps a path that still ends near the goal, asks for a new one at most once a second (squad_follow.h), and
// only takes the straight step when the navmesh has no path at all. step: walk the path now (false when the caller's own
// FollowPath right after does it, so the mate does not move twice in one tick).
void CTrustController::CatchUp(const position_t& goal, const float want, const float nearBand, const bool step)
{
    squad::follow::CatchUp(*POwner->PAI->PathFind, POwner->loc.p, goal, want, nearBand, POwner->GetLocalVar("SQUAD_ID") != 0, step,
                           POwner->GetSpeed() > 0, m_Tick, timer::count_milliseconds(m_Tick.time_since_epoch()), m_FollowRepathMs,
                           static_cast<uint8_t>(PATHFLAG_RUN),
                           [](const position_t& a, const position_t& b)
                           {
                               return distance(a, b);
                           });
}

// FFXI Offline squad (B5): who this mate follows out of a fight. The first mate (and everyone while the squad gathers) follows the
// player; the others the mate in front. A squad mate does not follow a mate in front that is down, that is further from the
// player than itself (it went the wrong way, or is stuck behind), or that cannot get any closer to the one it follows: it
// follows the player then, so one stuck mate does not hold the whole line. Ordinary trusts: the mate in front, as before.
auto CTrustController::FollowAnchor(CCharEntity* PMaster, const uint8 partyPos, const bool gather) -> CBattleEntity*
{
    if (partyPos == 0 || gather || static_cast<size_t>(partyPos - 1) >= PMaster->PTrusts.size())
    {
        return PMaster;
    }

    auto* PLead = PMaster->PTrusts.at(partyPos - 1);
    if (PLead == nullptr || PLead == POwner)
    {
        return PMaster;
    }

    if (POwner->GetLocalVar("SQUAD_ID") != 0)
    {
        bool leadStuck = PLead->isDead();
        if (auto* PLeadController = dynamic_cast<CTrustController*>(PLead->PAI->GetController()); PLeadController != nullptr)
        {
            leadStuck = leadStuck || PLeadController->IsStuck();
        }

        if (squad::follow::LeadLost(distance(PLead->loc.p, PMaster->loc.p), distance(POwner->loc.p, PMaster->loc.p), leadStuck))
        {
            return PMaster;
        }
    }

    return PLead;
}

CTrustController::CTrustController(CCharEntity* PChar, CTrustEntity* PTrust)
: CMobController(PTrust)
, m_GambitsContainer(std::make_unique<gambits::CGambitsContainer>(PTrust))
, m_failedRepositionAttempts(0)
, m_InTransit(false)
{
}

CTrustController::~CTrustController()
{
    if (POwner->PAI)
    {
        if (POwner->PAI->IsEngaged())
        {
            POwner->PAI->Internal_Disengage();
        }
        POwner->PAI->PathFind.reset();
    }

    POwner->allegiance = xi::Allegiance::Player;
    POwner->status     = xi::Status::Disappear;
}

void CTrustController::Despawn()
{
    POwner->PMaster   = nullptr;
    POwner->animation = xi::Animation::Despawn;
    CMobController::Despawn();
}

auto CTrustController::Tick(timer::time_point tick) -> Task<void>
{
    TracyZoneScoped;
    TracyZoneString(POwner->getName());

    m_Tick = tick;

    auto* PTrust = static_cast<CTrustEntity*>(POwner);

    // XI: Forever Offline: marker for scripts: this xi_map honours TRUST_HOLD (trust_hold.h). Nothing else reads it.
    if (PTrust->GetLocalVar("TRUST_HOLD_ENGINE") == 0)
    {
        PTrust->SetLocalVar("TRUST_HOLD_ENGINE", 1);
    }

    if (!PTrust->PMaster)
    {
        co_return;
    }

    if (PTrust->PMaster->isCharmed)
    {
        this->Despawn();
        co_return;
    }

    // XI: Forever Offline (2026-11-23): a fallen squad mate's body stays for a Raise (trust_entity.cpp Die): it does nothing
    if (PTrust->isDead())
    {
        co_return;
    }

    // FFXI Offline squad: local var SQUAD_IDLE (set by squad.lua / squad_moves.lua, "Forward to Gambits") = the stock trust AI does nothing for
    // this squad mate: no engaging, no following, no range keeping. Its gambits and the Lua movement lines still act. A mate that is still
    // engaged lets go once its master is not fighting.
    if (PTrust->GetLocalVar("SQUAD_ID") != 0 && PTrust->GetLocalVar("SQUAD_IDLE") != 0)
    {
        if (POwner->PAI->IsEngaged() && !PTrust->PMaster->PAI->IsEngaged())
        {
            POwner->PAI->Internal_Disengage();
        }

        co_return;
    }

    // XI: Forever Offline (F18, 2026-11-27): "Rest in fights": squad.lua sat this mate down while the party fights (its MP below
    // the setting, nothing attacking it). It stays out of the fight and in place; only its "Wake to act" rules run. One that
    // acts stands it up for that action (SQUAD_REST_FIGHT_ON 2, gambits_container.cpp): still out of the fight, still only those
    // rules, until squad.lua sits it down again. squad.lua ends the rest on damage, movement, MP back, or the fight's end.
    if (PTrust->GetLocalVar("SQUAD_ID") != 0 && PTrust->GetLocalVar("SQUAD_REST_FIGHT_ON") != 0)
    {
        if (POwner->PAI->IsEngaged())
        {
            POwner->PAI->Internal_Disengage();
        }

        if (POwner->PAI->PathFind->IsFollowingPath())
        {
            POwner->PAI->PathFind->Clear();
        }

        if (!POwner->PAI->IsCurrentState<CMagicState>() && !POwner->PAI->IsCurrentState<CRangeState>())
        {
            co_await m_GambitsContainer->Tick(tick, false, true);
        }

        co_return;
    }

    const bool nonCombatFollowTrust = PTrust->getMobMod(xi::MobMod::TrustDistance) == TRUST_MOVEMENT_TYPE::NON_COMBAT;

    position_t camp{};
    const bool inCamp = campOf(PTrust, camp);
    if (inCamp && PTrust->GetLocalVar("SQUAD_PULL_PHASE") != 0 && !POwner->isDead())
    {
        co_await DoCampPullTick(tick, camp);
    }
    else if (PTrust->PMaster->PAI->IsEngaged() && nonCombatFollowTrust && !inCamp)
    {
        co_await DoNonCombatTick(tick);
    }
    else if (POwner->PAI->IsEngaged())
    {
        co_await DoCombatTick(tick);
    }
    else if (!POwner->isDead())
    {
        co_await DoRoamTick(tick);
    }

    co_return;
}

auto CTrustController::DoCombatTick(timer::time_point tick) -> Task<void>
{
    TracyZoneScoped;

    CTrustEntity* PTrust  = static_cast<CTrustEntity*>(POwner);
    CCharEntity*  PMaster = static_cast<CCharEntity*>(POwner->PMaster);
    CMobEntity*   PMob    = dynamic_cast<CMobEntity*>(PMaster->GetBattleTarget());
    setTarget(POwner->GetBattleTarget());
    auto* PTarget = target().resolve<CBattleEntity>();

    position_t camp{};
    const bool inCamp = campOf(PTrust, camp);
    CBattleEntity* POrdered = nullptr; // (!squad attack) the monster the player sent the squad at, while he is not engaged
    if (inCamp)
    {
        // camp: the fight at camp goes on without you; anything that wanders off is let go
        if (PTarget == nullptr || PTarget->isDead() || distance(PTarget->loc.p, camp) > CampLeash)
        {
            PTrust->PAI->Internal_Disengage();
            m_CombatEndTime = m_Tick;
        }
    }
    else if (!PMaster->PAI->IsEngaged())
    {
        // (!squad attack, 2026-11-22) the player sent the squad at a monster and keeps out of the fight himself:
        // stay on that monster. Without such an order a mate lets go when its master is not fighting, as before.
        POrdered = OrderedTarget();
        if (POrdered == nullptr)
        {
            PTrust->PAI->Internal_Disengage();
            m_CombatEndTime = m_Tick;
        }
        else if (PTarget != POrdered)
        {
            PTrust->PAI->Internal_ChangeTarget(EntityId(POrdered));
        }
    }

    if (inCamp && PMob && distance(PMob->loc.p, camp) > CampFightRadius)
    {
        PMob = nullptr; // (what you are fighting out there is not the camp's fight)
    }

    if (PMaster && PMob && PTrust->battleTarget() != PMaster->battleTarget())
    {
        auto  masterID   = PMaster->id;
        auto* enmityList = PMob->PEnmityContainer->GetEnmityList();
        bool  hasEnmity  = false;

        if (auto it = enmityList->find(masterID); it != enmityList->end())
        {
            const EnmityObject_t& entry = it->second;
            // Only treat as "has enmity" if:
            // the entry is active,
            // the CE+VE is positive,
            // and the master is within enmity range (same checks used when adding enmity).
            if (entry.active && (entry.CE + entry.VE) > 0)
            {
                hasEnmity = true;
            }
        }

        if (hasEnmity)
        {
            PTrust->PAI->Internal_ChangeTarget(PMaster->battleTarget());
        }
    }

    // If busy, don't run around!
    if (PTrust->PAI->IsCurrentState<CMagicState>() || PTrust->PAI->IsCurrentState<CRangeState>())
    {
        co_return;
    }

    // XI: Forever Offline (B9): a walk-in for a chat request ends when a fight starts (said as such); the fight's movement is
    // unchanged
    if (IsApproaching())
    {
        ApproachTick();
    }

    // FFXI Offline squad: an area spell is waiting for this mate to step within reach of the player. The rules keep
    // running meanwhile, so a cure is not held up by it.
    if (StepInTick())
    {
        co_await m_GambitsContainer->Tick(tick);
        co_return;
    }

    if (PTarget)
    {
        if (PTrust->PAI->CanFollowPath() && PTrust->GetSpeed() > 0)
        {
            float currentDistanceToTarget = distance(PTrust->loc.p, PTarget->loc.p);
            float currentDistanceToMaster = distance(PTrust->loc.p, PMaster->loc.p);

            if (!inCamp && !PMaster->PAI->IsEngaged() && POrdered == nullptr && currentDistanceToTarget > WarpDistance)
            {
                PTrust->PAI->PathFind->WarpToOnMesh(PTarget->loc.p);
            }

            PTrust->PAI->PathFind->LookAt(PTarget->loc.p);

            // (squad thieves) local var SQUAD_FLANK, set by squad.lua: 1 = get behind the target for Sneak Attack,
            // 2 = stand right behind the party member the target is fighting, for Trick Attack. While the mate is on
            // its way there, the usual melee spacing below waits.
            bool flanking = false;
            if (const int32 flank = PTrust->GetLocalVar("SQUAD_FLANK"); flank != 0 && PTrust->GetSpeed() > 0)
            {
                std::optional<position_t> spot;
                if (flank == 1 && !behind(PTrust->loc.p, PTarget->loc.p, 64))
                {
                    spot = nearPosition(PTarget->loc.p, RoamDistance * 0.8f, 3.14159265f);
                }
                else if (flank == 2)
                {
                    CBattleEntity* PTank = PTarget->GetBattleTarget();
                    if (PTank != nullptr && PTank != PTrust && !PTank->isDead())
                    {
                        const float apart = distance(PTank->loc.p, PTarget->loc.p);
                        if (apart > 0.5f && apart < 3.5f)
                        {
                            position_t p = PTank->loc.p;
                            const float k = 0.7f / apart;
                            p.x += (PTank->loc.p.x - PTarget->loc.p.x) * k;
                            p.z += (PTank->loc.p.z - PTarget->loc.p.z) * k;
                            spot = p;
                        }
                    }
                }

                if (spot && distance(PTrust->loc.p, *spot) > 0.6f)
                {
                    flanking = true;
                    // (only the path here: the FollowPath at the end of this tick takes the step. Stepping here as
                    //  well moved the thief twice a tick, so players saw it snap behind the monster - Frost)
                    if (!PTrust->PAI->PathFind->PathTo(*spot, PATHFLAG_RUN))
                    {
                        PTrust->PAI->PathFind->StepToOnMesh(*spot, true);
                    }
                }
            }

            // (squad_position.h) the position the player chose for this mate: behind the enemy, or the TA partner spot.
            // Not while the thief logic above places it, and not for mates that stand still (NO_MOVE) or do not fight.
            const int16 trustDistance = PTrust->getMobMod(xi::MobMod::TrustDistance);
            bool        positioning   = false;
            m_PositionPlaced          = false;
            if (UsesPosition() && (flanking || PTrust->GetLocalVar("SQUAD_FLANK") != 0))
            {
                PTrust->SetLocalVar("SQUAD_POS_STATE", squad::position::StateThief); // (said by !squad position)
            }
            else if (UsesPosition() && trustDistance != TRUST_MOVEMENT_TYPE::NO_MOVE && trustDistance != TRUST_MOVEMENT_TYPE::NON_COMBAT)
            {
                const bool melee = trustDistance == TRUST_MOVEMENT_TYPE::MELEE;
                positioning      = PositionTick(PMaster, PTarget, melee,
                                                melee ? squad::position::MeleeRadius(PTrust->GetMeleeRange(PTarget)) : static_cast<float>(trustDistance));
            }

            switch (const int16 movementDistance = (flanking || positioning) ? static_cast<int16>(TRUST_MOVEMENT_TYPE::NON_COMBAT) : trustDistance)
            {
                case TRUST_MOVEMENT_TYPE::NO_MOVE:
                {
                    if (currentDistanceToMaster > CastingDistance || currentDistanceToTarget > CastingDistance)
                    {
                        PathOutToDistance(PTarget, 9.0f);
                    }
                    break;
                }
                case TRUST_MOVEMENT_TYPE::NON_COMBAT:
                {
                    // Non-combat followers should not use target-distance positioning.
                    break;
                }
                case TRUST_MOVEMENT_TYPE::MELEE:
                {
                    // CanAttack answers "would a swing land", not "am I standing next to
                    // it": the hitbox sizes are part of GetMeleeRange, so it reads true
                    // from 3+ yalms away and the mate stopped there, looking like it was
                    // swinging from the next camp. Keep closing until it is actually
                    // inside RoamDistance of the mob, whatever CanAttack says.
                    if (PTrust->GetSpeed() > 0 && currentDistanceToTarget > RoamDistance)
                    {
                        // (B5) far from the monster (below a ledge): a throttled navmesh path for squad mates, see CatchUp
                        CatchUp(PTarget->loc.p, RoamDistance, RoamDistance * 3.0f, false);
                    }
                    break;
                }
                case TRUST_MOVEMENT_TYPE::MID_RANGE:
                    [[fallthrough]];
                case TRUST_MOVEMENT_TYPE::LONG_RANGE:
                    [[fallthrough]];
                default: // Using the positive-non-zero movementDistance mobMod value
                {
                    PathOutToDistance(PTarget, static_cast<float>(movementDistance));
                    break;
                }
            }

            if (!PTrust->PAI->PathFind->IsFollowingPath() && PTrust->GetLocalVar("SQUAD_FLANK") == 0 && !m_PositionPlaced)
            {
                Declump(PMaster, PTarget); // (not a thief holding its spot behind the target or behind the tank, nor a mate
                                           //  with a chosen position: those have a spot of their own)
            }
        }

        if (!m_InTransit)
        {
            PTrust->PAI->PathFind->FollowPath(m_Tick);
        }

        co_await m_GambitsContainer->Tick(tick);

        PTrust->PAI->EventHandler.triggerListener("COMBAT_TICK", PTrust, PMaster, PTarget);
    }

    co_return;
}

auto CTrustController::DoNonCombatTick(const timer::time_point tick) -> Task<void>
{
    TracyZoneScoped;

    // Busy casting or shooting: stand still until it's out (walking after the player interrupts the spell)
    if (POwner->PAI->IsCurrentState<CMagicState>() || POwner->PAI->IsCurrentState<CRangeState>())
    {
        co_return;
    }

    auto* PTrust  = static_cast<CTrustEntity*>(POwner);
    auto* PMaster = static_cast<CCharEntity*>(POwner->PMaster);

    if (!PMaster)
    {
        co_return;
    }

    // Keep COMBAT_TICK target valid for listeners/gambits.
    setTarget(PMaster->GetBattleTarget());
    auto* PTarget = target().resolve<CBattleEntity>();

    // Non-combat trust follow order:
    // - first trust follows master
    // - others follow the trust directly in front of them
    uint8 currentPartyPos = GetPartyPosition();

    // (B5) a squad mate whose leader is lost or stuck follows the player instead (FollowAnchor)
    CBattleEntity* PFollowTarget = FollowAnchor(PMaster, currentPartyPos, false);

    // First trust keeps a bit more space from master.
    constexpr float FirstTrustFollowDistance = 3.0f; // tune as needed
    const float     desiredFollowDistance    = (currentPartyPos == 0) ? FirstTrustFollowDistance : RoamDistance;

    float currentDistance = distance(PTrust->loc.p, PFollowTarget->loc.p);

    // Simple declump so non-combat trusts don't stack on each other.
    for (auto* POtherTrust : PMaster->PTrusts)
    {
        if (POtherTrust != PTrust &&
            distance(POtherTrust->loc.p, PTrust->loc.p) < 1.0f &&
            !PTrust->PAI->PathFind->IsFollowingPath())
        {
            // Sidestep the trust we are stacked on, with odd/even party slots taking opposite sides.
            const float amount  = (currentPartyPos % 2) ? 1.0f : -1.0f;
            const auto  new_pos = sidestepPosition(PTrust->loc.p, POtherTrust->loc.p, amount);

            if (PTrust->PAI->PathFind->ValidPosition(new_pos) &&
                PTrust->PAI->PathFind->PathTo(new_pos, PATHFLAG_RUN))
            {
                PTrust->PAI->PathFind->FollowPath(m_Tick);
            }
            break;
        }
    }

    if (currentDistance > WarpDistance)
    {
        PTrust->PAI->PathFind->WarpToOnMesh(PFollowTarget->loc.p);
    }
    else if (currentDistance > desiredFollowDistance)
    {
        // (B5) far away: a throttled navmesh path for squad mates (the step is the FollowPath just below)
        CatchUp(PFollowTarget->loc.p, desiredFollowDistance, desiredFollowDistance * 3.0f, false);
    }

    m_Follow.Update(timer::count_milliseconds(m_Tick.time_since_epoch()), currentDistance, desiredFollowDistance * 2.0f, false);

    if (PTrust->PAI->PathFind->IsFollowingPath())
    {
        PTrust->PAI->PathFind->FollowPath(m_Tick);
    }

    // Keep gambits active in combat, but only while stationary.
    if (PMaster->PAI->IsEngaged() && !PTrust->PAI->PathFind->IsFollowingPath())
    {
        co_await m_GambitsContainer->Tick(tick);
        PTrust->PAI->EventHandler.triggerListener("COMBAT_TICK", PTrust, PMaster, PTarget);
    }

    co_return;
}

auto CTrustController::DoRoamTick(timer::time_point tick) -> Task<void>
{
    TracyZoneScoped;

    // Busy casting or shooting: stand still until it's out (walking after the player interrupts the spell)
    if (POwner->PAI->IsCurrentState<CMagicState>() || POwner->PAI->IsCurrentState<CRangeState>())
    {
        co_return;
    }

    auto*      PMaster              = static_cast<CCharEntity*>(POwner->PMaster);

    // FFXI Offline squad: an area spell is waiting for this mate to step within reach of the player
    if (StepInTick())
    {
        co_return;
    }

    // XI: Forever Offline (B9): walking in to cast a chat request (a Raise on a body out of reach)
    if (ApproachTick())
    {
        co_return;
    }

    position_t camp{};
    if (campOf(POwner, camp))
    {
        // camp: fight what reaches the camp (yours, or what another mate is fighting there), else hold the spot
        CBattleEntity* PFight = nullptr;
        if (PMaster->PAI->IsEngaged())
        {
            auto* PTarget = PMaster->GetBattleTarget();
            if (PTarget && !PTarget->isDead() && distance(PTarget->loc.p, camp) <= CampFightRadius)
            {
                PFight = PTarget;
            }
        }

        if (PFight == nullptr && !PMaster->PAI->IsEngaged())
        {
            // (!squad attack at a camp) a monster the player pointed out, if it is within the camp's reach
            if (auto* POrdered = OrderedTarget(); POrdered != nullptr && distance(POrdered->loc.p, camp) <= CampFightRadius)
            {
                PFight = POrdered;
            }
        }

        for (auto* POther : PMaster->PTrusts)
        {
            if (PFight != nullptr)
            {
                break;
            }

            if (POther != nullptr && POther != POwner && POther->PAI->IsEngaged())
            {
                auto* PTarget = POther->GetBattleTarget();
                if (PTarget && !PTarget->isDead() && distance(PTarget->loc.p, camp) <= CampFightRadius)
                {
                    PFight = PTarget;
                }
            }
        }

        // (B1, 2026-11-25) a link or a monster's pet still on the party after the pulled one died, with your weapon away and
        // nobody else on it: it is the camp's fight too. In follow mode this is not done: there the fight still starts from
        // your target, your !squad attack order, or a mate's fight, as before.
        if (PFight == nullptr)
        {
            PFight = CampThreat(camp);
        }

        if (PFight != nullptr && EngageDelayPassed(PFight))
        {
            POwner->PAI->Internal_Engage(EntityId(PFight));
        }
        else
        {
            if (PFight == nullptr)
            {
                m_EngageWaitTarget = 0;
            }

            CampHold(camp);

            // (B3b, 2026-11-25) holding camp with nothing to fight and you not engaged: the support rules (Sleep -> Cure,
            // Petrification -> Stona), once the mate stands on its spot
            if (POwner->GetLocalVar("SQUAD_ID") != 0 && !PMaster->PAI->IsEngaged() && !POwner->PAI->PathFind->IsFollowingPath())
            {
                co_await m_GambitsContainer->Tick(tick, true);
            }
        }

        co_return;
    }

    const auto masterLastAttackTime = static_cast<CPlayerController*>(PMaster->PAI->GetController())->getLastAttackTime();
    const bool masterMeleeSwing     = masterLastAttackTime > timer::now() - 1s;

    bool trustEngageCondition = false;
    // NOTE: charvars are now cached, this is essentially a localvar read now.
    switch (charutils::GetCharVar(PMaster, "TrustEngageType"))
    {
        case 1: // Master engages a monster, no melee swing required
        {
            trustEngageCondition = PMaster->GetBattleTarget();
            break;
        }
        case 0: // Nothing set
            // (XI: Forever Offline, 2026-11-22, the user: "when you press attack it will send your squad to attack even
            // if you don't hit them, so mages can do this apart") for squad mates nothing set means "as soon as you
            // engage". The retail rule below is !squad engage normal, which sets 2.
            if (POwner->GetLocalVar("SQUAD_ID") != 0)
            {
                trustEngageCondition = PMaster->GetBattleTarget();
                break;
            }

            [[fallthrough]];
        default: // Something invalid set
        {
            // Default retail behavior: Master engages a monster and executes a melee swing
            trustEngageCondition = PMaster->GetBattleTarget() && masterMeleeSwing;
            break;
        }
    }

    constexpr uint16 modelID_Cornelia = 3119; // Cornielia does not have an Attack Schedule so do not engage.

    // (2026-11-21, Jon Tanta: a mate with !squad delay 1-10 and the default engage type never engaged) the default rule only
    // counts the master's melee swing for one second, and every time that window closed the wait started over. A wait
    // already running for the master's current target now keeps going; it is only dropped when the master stops fighting
    // or changes target.
    const CBattleEntity* PMasterTarget   = PMaster->GetBattleTarget();
    const bool           waitingOnTarget = m_EngageWaitTarget != 0 && PMasterTarget != nullptr && m_EngageWaitTarget == PMasterTarget->id;

    if (PMaster->PAI->IsEngaged() && (trustEngageCondition || waitingOnTarget) && POwner->GetModelId() != modelID_Cornelia)
    {
        // FFXI Offline squad: a mate with an engage delay (!squad delay) waits that long after you engage, e.g. so the tank gets hate first
        if (EngageDelayPassed(PMasterTarget))
        {
            POwner->PAI->Internal_Engage(PMaster->battleTarget());
        }
    }
    else if (auto* POrdered = PMaster->PAI->IsEngaged() ? nullptr : OrderedTarget(); POrdered != nullptr && POwner->GetModelId() != modelID_Cornelia)
    {
        // (!squad attack, 2026-11-22, Hasuko: "I'm a WHM. I shouldn't have to pull my weapon") the player pointed at a
        // monster and stays out of the fight: go in without him. A mate's engage delay (!squad delay) counts from the order.
        if (EngageDelayPassed(POrdered))
        {
            POwner->PAI->Internal_Engage(EntityId(POrdered));
        }
    }
    else if (!PMaster->PAI->IsEngaged() || PMasterTarget == nullptr)
    {
        m_EngageWaitTarget = 0;
    }

    const uint8          currentPartyPos = GetPartyPosition();
    // FFXI Offline squad (2026-11-22): a mate about to cast an area spell asked the squad to close up (the player's local
    // var SQUAD_GATHER holds the time until which). Everyone then comes to the player himself, not to the mate in front,
    // each a little further out than the one before, and goes back to the usual line afterwards.
    const bool           gather          = POwner->GetLocalVar("SQUAD_ID") != 0 && PMaster->GetLocalVar("SQUAD_GATHER") > earth_time::timestamp();
    // (B5) a squad mate whose leader is lost or stuck follows the player instead (FollowAnchor; ordinary trusts as before)
    const CBattleEntity* PFollowTarget   = FollowAnchor(PMaster, currentPartyPos, gather);
    const float          currentDistance = distance(POwner->loc.p, PFollowTarget->loc.p);

    // Formation following thresholds (in yalms)
    // First trust follows master more closely than other trusts follow each other
    const bool isFirstTrust = (currentPartyPos == 0) || gather;

    // FFXI Offline squad: !squad follow close | normal | far (char var SQUAD_FOLLOW 1 / 0 / 2) for squad mates
    const int32 followStyle = POwner->GetLocalVar("SQUAD_ID") != 0 ? charutils::GetCharVar(PMaster, "SQUAD_FOLLOW") : 0;
    const float followScale = gather ? 1.0f + 0.35f * static_cast<float>(currentPartyPos) : (followStyle == 1 ? 0.7f : (followStyle == 2 ? 1.8f : 1.0f));

    const float declumpDistance = (isFirstTrust ? 1.0f : 1.5f) * std::min(followScale, 1.0f); // Too close, need to move away
    const float followMax       = (isFirstTrust ? 2.0f : 3.5f) * followScale;                 // Maximum follow distance before moving closer
    const float followTarget    = (isFirstTrust ? 1.5f : 3.0f) * followScale;                 // Ideal follow distance

    // Handle formation movement based on distance thresholds
    if (currentDistance < declumpDistance)
    {
        // Too close to follow target - push away to maintain formation spacing
        position_t awayFromTarget = PFollowTarget->loc.p;
        awayFromTarget.rotation   = worldAngle(PFollowTarget->loc.p, POwner->loc.p);
        const auto spacedPos      = nearPosition(awayFromTarget, followTarget + 0.5f, 0.0f);

        if (POwner->PAI->PathFind->ValidPosition(spacedPos) &&
            POwner->PAI->PathFind->PathTo(spacedPos, PATHFLAG_RUN))
        {
            POwner->PAI->PathFind->FollowPath(m_Tick);
        }
    }
    else if (currentDistance > followMax)
    {
        // Too far from follow target - move closer to maintain formation
        if (currentDistance > WarpDistance)
        {
            // Warp if extremely too far
            POwner->PAI->PathFind->WarpToOnMesh(PFollowTarget->loc.p);
        }
        else
        {
            // Path or step closer to follow target ((B5) far away: a throttled navmesh path for squad mates, see CatchUp)
            CatchUp(PFollowTarget->loc.p, followTarget, RoamDistance * 3.0f, true);
        }
    }

    m_Follow.Update(timer::count_milliseconds(m_Tick.time_since_epoch()), currentDistance, followMax, false);

    // (B3b, 2026-11-25) following you after a fight, you not engaged: the support rules (Sleep -> Cure, Petrification -> Stona),
    // only while the mate stands still (a cast would stop it). Ordinary trusts: unchanged.
    if (POwner->GetLocalVar("SQUAD_ID") != 0 && !PMaster->PAI->IsEngaged() && !POwner->PAI->PathFind->IsFollowingPath())
    {
        co_await m_GambitsContainer->Tick(tick, true);
    }
    else
    {
        // In formation range. Stop only once settled near the ideal spot: clearing the path the moment the mate
        // is inside followMax made it stop and restart every time the player took a step (the stop-start look).
        // Closer than followTarget + 0.5 still stops, so it still cannot circle.
        if (POwner->PAI->PathFind->IsFollowingPath())
        {
            if (currentDistance <= followTarget + 0.5f)
            {
                POwner->PAI->PathFind->Clear();
            }
            else
            {
                POwner->PAI->PathFind->FollowPath(m_Tick);
            }
        }
    }

    // Squad mates (FFXI Offline squad module) only recover while their player rests (/heal): no automatic regen.
    if (POwner->GetLocalVar("SQUAD_ID") == 0 && POwner->CanRest() && m_Tick - POwner->LastAttacked > m_tickDelays.at(0) && m_Tick - m_CombatEndTime > m_tickDelays.at(0) &&
        m_Tick - m_LastHealTickTime > m_tickDelays.at(m_NumHealingTicks))
    {
        if (POwner->health.hp != POwner->health.maxhp || POwner->health.mp != POwner->health.maxmp)
        {
            // recover 5% HP & MP
            const uint32 recoverHP = static_cast<uint32>(POwner->health.maxhp * 0.05);
            const uint32 recoverMP = static_cast<uint32>(POwner->health.maxmp * 0.05);
            POwner->addHP(recoverHP);
            POwner->addMP(recoverMP);
            m_LastHealTickTime = m_Tick;
            POwner->updatemask |= UPDATE_HP;
            m_NumHealingTicks = std::clamp(m_NumHealingTicks + 1, static_cast<std::size_t>(0U), m_tickDelays.size() - 1U);
        }
    }

    co_return;
}

// FFXI Offline squad (2026-11-22, Hasuko: "I'm a WHM. I shouldn't have to pull my weapon"): !squad attack sends the
// squad at the player's target without the player engaging. squad.lua writes the monster's targid, the zone and the
// time into the player's local vars SQUAD_ATTACK_TARGET / SQUAD_ATTACK_ZONE / SQUAD_ATTACK_SEEN. This returns that
// monster while the order stands, and drops the order when the monster is dead or gone, the player is dead or in
// another zone, the monster is farther than OrderLeash from the player, or no mate has looked at the order for
// OrderStaleSec (nobody was out: the same monster must not be attacked again after it comes back).
constexpr float  OrderLeash    = 60.0f;
constexpr uint32 OrderStaleSec = 15;

auto CTrustController::OrderedTarget() -> CBattleEntity*
{
    auto* PMaster = static_cast<CBattleEntity*>(POwner->PMaster);
    if (PMaster == nullptr || POwner->GetLocalVar("SQUAD_ID") == 0)
    {
        return nullptr;
    }

    const uint32 targid = PMaster->GetLocalVar("SQUAD_ATTACK_TARGET");
    if (targid == 0)
    {
        return nullptr;
    }

    const uint32 now  = earth_time::timestamp();
    const uint32 seen = PMaster->GetLocalVar("SQUAD_ATTACK_SEEN");
    auto*        PMob = dynamic_cast<CMobEntity*>(POwner->GetEntity(static_cast<uint16>(targid), TYPE_MOB));
    if (PMob == nullptr || PMob->isDead() || PMob->status == xi::Status::Disappear || PMob->allegiance != xi::Allegiance::Mob ||
        PMaster->isDead() || PMaster->GetLocalVar("SQUAD_ATTACK_ZONE") != static_cast<uint32>(static_cast<uint16>(PMaster->getZone())) ||
        now > seen + OrderStaleSec || distance(PMob->loc.p, PMaster->loc.p) > OrderLeash)
    {
        PMaster->SetLocalVar("SQUAD_ATTACK_TARGET", 0);
        return nullptr;
    }

    PMaster->SetLocalVar("SQUAD_ATTACK_SEEN", now);
    return PMob;
}

// camp: stand on its own spot around the camp (one per party slot)
// XI: Forever Offline: true while a script holds the stock engage (bit HoldEngage) or the stock weapon skills (HoldWeaponSkill) of this
// trust. The script writes the local vars TRUST_HOLD (mask) and TRUST_HOLD_SEQ (a counter it raises about once a second); the hold
// runs out three seconds after the last renewal, so a script that stops, reloads or crashes never leaves the trust frozen
// (trust_hold.h). Without TRUST_HOLD set, as on the stock server, this is always false and nothing changes.
auto CTrustController::ScriptHolds(const uint32 bit) -> bool
{
    const uint32 mask = POwner->GetLocalVar("TRUST_HOLD");
    if ((mask & bit) == 0)
    {
        return false;
    }

    const auto nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(m_Tick.time_since_epoch()).count();
    return m_ScriptHold.Active(mask, POwner->GetLocalVar("TRUST_HOLD_SEQ"), bit, nowMs);
}

// FFXI Offline squad: true once this mate's engage delay (local var SQUAD_ENGAGE_DELAY, ms) has passed for this monster
auto CTrustController::EngageDelayPassed(const CBattleEntity* PTarget) -> bool
{
    // XI: Forever Offline: a script holds the stock engage until its own test lets it go (ScriptHolds). The wait for this monster
    // keeps running meanwhile, so the engage follows the moment the hold is lifted even if the master's swing is long past.
    if (ScriptHolds(trust_hold::HoldEngage))
    {
        if (PTarget != nullptr && m_EngageWaitTarget != PTarget->id)
        {
            m_EngageWaitTarget = PTarget->id;
            m_EngageWaitSince  = m_Tick;
        }

        return false;
    }

    const uint32 delayMs = POwner->GetLocalVar("SQUAD_ENGAGE_DELAY");
    if (delayMs == 0 || PTarget == nullptr)
    {
        return true;
    }

    if (m_EngageWaitTarget != PTarget->id)
    {
        m_EngageWaitTarget = PTarget->id;
        m_EngageWaitSince  = m_Tick;
    }

    return m_Tick - m_EngageWaitSince >= std::chrono::milliseconds(delayMs);
}

void CTrustController::CampHold(const position_t& camp)
{
    const float angle = static_cast<float>(GetPartyPosition()) * 2.0f * 3.14159265f / 5.0f;
    position_t  spot  = camp;
    spot.x            = camp.x + CampHoldRadius * std::cos(angle);
    spot.z            = camp.z + CampHoldRadius * std::sin(angle);
    if (!POwner->PAI->PathFind->ValidPosition(spot))
    {
        spot = camp;
    }

    const float away = distance(POwner->loc.p, spot);
    if (away > 60.0f)
    {
        POwner->PAI->PathFind->WarpToOnMesh(spot);
    }
    else if (away > 1.0f)
    {
        if (!POwner->PAI->PathFind->IsFollowingPath() || m_Tick - m_CampRepath > 2s)
        {
            m_CampRepath = m_Tick;
            POwner->PAI->PathFind->PathTo(spot, PATHFLAG_RUN);
        }

        POwner->PAI->PathFind->FollowPath(m_Tick);
    }
    else if (POwner->PAI->PathFind->IsFollowingPath())
    {
        POwner->PAI->PathFind->Clear();
    }
}

// camp: the puller's run - out to the monster, engage it, and back to camp once it comes
// FFXI Offline squad camp: how a puller opens on its target from range, as players did. A caster uses a pull spell it
// knows (Dia, Bio, Poison, then a tier one nuke); a melee job with a ranged weapon (bow, gun, throwing) shoots it.
namespace
{
constexpr float CampPullCastRange  = 18.0f;
constexpr float CampPullShootRange = 20.0f;

auto knows(const std::vector<SpellID>& list, SpellID id) -> bool
{
    return std::find(list.begin(), list.end(), id) != list.end();
}

auto campPullSpell(CTrustEntity* PTrust) -> Maybe<SpellID>
{
    if (PTrust->SpellContainer == nullptr || !PTrust->SpellContainer->HasSpells())
    {
        return std::nullopt;
    }

    // (2026-11-18, sparkiie) a Bard pulls with a song first: Carnage / Battlefield Elegy, then Foe Requiem VI..I
    std::vector<uint16> order;
    if (PTrust->GetMJob() == xi::Job::BRD)
    {
        order = { 422, 421, 373, 372, 371, 370, 369, 368 };
    }
    // Dia, Dia II, Bio, Poison, Stone, Water, Aero, Fire, Blizzard, Thunder, Banish
    for (const uint16 n : { 23, 24, 230, 220, 159, 169, 154, 144, 149, 164, 28 })
    {
        order.push_back(n);
    }

    for (const uint16 n : order)
    {
        const auto id = static_cast<SpellID>(n);
        auto*      sc = PTrust->SpellContainer;
        if ((knows(sc->m_debuffList, id) || knows(sc->m_damageList, id)) && sc->GetAvailable(id))
        {
            return id;
        }
    }

    return std::nullopt;
}

auto hasRangedWeapon(const CTrustEntity* PTrust) -> bool
{
    // A squad mate's weapons are the trust's stand-ins (item id 0); squad.cpp copies the skill of the bow, gun or
    // boomerang it wears onto them, so the skill is what tells (2026-11-18).
    const auto* ranged = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_RANGED]);
    if (ranged && (ranged->getSkillType() == xi::SkillType::Archery || ranged->getSkillType() == xi::SkillType::Marksmanship ||
                   ranged->getSkillType() == xi::SkillType::Throwing))
    {
        return true;
    }

    const auto* ammo = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_AMMO]);
    return ammo && ammo->getSkillType() == xi::SkillType::Throwing;
}
} // namespace

auto CTrustController::DoCampPullTick(timer::time_point tick, const position_t& camp) -> Task<void>
{
    auto* PTrust = static_cast<CTrustEntity*>(POwner);
    auto* PMob   = dynamic_cast<CMobEntity*>(PTrust->GetEntity(static_cast<uint16>(PTrust->GetLocalVar("SQUAD_PULL_TARGET")), TYPE_MOB));
    if (PMob == nullptr || PMob->isDead() || PMob->status == xi::Status::Disappear)
    {
        PTrust->SetLocalVar("SQUAD_PULL_PHASE", 0);
        PTrust->SetLocalVar("SQUAD_PULL_TARGET", 0);
        co_return;
    }

    if (!PTrust->PAI->CanFollowPath() || PTrust->GetSpeed() == 0)
    {
        co_return;
    }

    if (PTrust->GetLocalVar("SQUAD_PULL_PHASE") == 1)
    {
        if (PMob->PAI->IsEngaged())
        {
            PTrust->SetLocalVar("SQUAD_PULL_PHASE", 2); // it is coming: back to camp
            PTrust->PAI->PathFind->Clear();
            co_return;
        }

        const float away = distance(PTrust->loc.p, PMob->loc.p);

        // from range: a pull spell (casters) or a shot (a ranged weapon); it waits for it to land before running again
        if (PTrust->PAI->IsCurrentState<CMagicState>() || PTrust->PAI->IsCurrentState<CRangeState>())
        {
            co_return;
        }

        // (2026-11-20, Altair: a THF puller with a bow ran in and shot from melee range) a squad mate is a mob to
        // the engine, and a mob's ranged attacks reach 14 yalms (GetRangedAttackRange), not a player's 25: it shoots
        // from inside that. At most three shots and three casts at one monster (no line of sight, no ammunition, no MP...).
        if (PTrust->GetLocalVar("SQUAD_PULL_SHOT_AT") != PMob->targid)
        {
            PTrust->SetLocalVar("SQUAD_PULL_SHOT_AT", PMob->targid);
            PTrust->SetLocalVar("SQUAD_PULL_SHOTS", 0);
            PTrust->SetLocalVar("SQUAD_PULL_CASTS", 0);
        }

        const auto  spell      = campPullSpell(PTrust);
        const bool  canCast    = spell.has_value() && PTrust->GetLocalVar("SQUAD_PULL_CASTS") < 3;
        const bool  canShoot   = hasRangedWeapon(PTrust) && PTrust->GetLocalVar("SQUAD_PULL_SHOTS") < 3;
        const float shootReach = std::min(CampPullShootRange, PTrust->GetRangedAttackRange() - 1.0f);

        if (canCast || canShoot)
        {
            // (2026-11-24, levi) a ranged pull: weapon away, no melee. It engages at camp (phase 2 below).
            if (PTrust->PAI->IsEngaged())
            {
                PTrust->PAI->Internal_Disengage();
                co_return;
            }

            const bool castNow  = canCast && away <= CampPullCastRange;
            const bool shootNow = canShoot && away <= shootReach;
            if (castNow || shootNow)
            {
                // in reach: it stands where it is and tries every 4 seconds, never walking up to the monster
                PTrust->PAI->PathFind->Clear();
                if (tick - m_CampPullTry > 4s)
                {
                    m_CampPullTry = tick;
                    if (castNow)
                    {
                        PTrust->SetLocalVar("SQUAD_PULL_CASTS", PTrust->GetLocalVar("SQUAD_PULL_CASTS") + 1);
                        Cast(EntityId(PMob), *spell);
                    }
                    else
                    {
                        PTrust->SetLocalVar("SQUAD_PULL_SHOTS", PTrust->GetLocalVar("SQUAD_PULL_SHOTS") + 1);
                        RangedAttack(EntityId(PMob));
                    }
                }

                co_return;
            }

            // not in reach yet: walk up until it is
            if (!PTrust->PAI->PathFind->IsFollowingPath() || tick - m_CampRepath > 1s)
            {
                m_CampRepath = tick;
                PTrust->PAI->PathFind->PathAround(PMob->loc.p, 2.0f, PATHFLAG_NONE);
            }

            PTrust->PAI->PathFind->FollowPath(tick);
            co_return;
        }

        // no ranged way to pull it: walk in and engage it, as before
        if (!PTrust->PAI->IsEngaged() || PTrust->GetBattleTarget() != PMob)
        {
            PTrust->PAI->Internal_Engage(EntityId(PMob));
        }

        if (away > 2.5f)
        {
            if (!PTrust->PAI->PathFind->IsFollowingPath() || tick - m_CampRepath > 1s)
            {
                m_CampRepath = tick;
                PTrust->PAI->PathFind->PathAround(PMob->loc.p, 2.0f, PATHFLAG_NONE); // (a player's pace: PATHFLAG_RUN is the mobs' x2.5 run)
            }

            PTrust->PAI->PathFind->FollowPath(tick);
        }

        // casters open from range with their own rules (Dia, Stone, Provoke, Flash...)
        if (away < CastingDistance && !PTrust->PAI->IsCurrentState<CMagicState>())
        {
            co_await m_GambitsContainer->Tick(tick);
        }

        co_return;
    }

    if (!PMob->PAI->IsEngaged())
    {
        PTrust->SetLocalVar("SQUAD_PULL_PHASE", 1); // (it lost interest: go get it again)
        co_return;
    }

    if (distance(PTrust->loc.p, camp) <= 3.0f)
    {
        PTrust->SetLocalVar("SQUAD_PULL_PHASE", 0); // back at camp with it: the fight is on
        PTrust->PAI->PathFind->Clear();
        // (2026-11-24, levi) only now does the puller draw its weapon on it
        if (!PTrust->PAI->IsEngaged() || PTrust->GetBattleTarget() != PMob)
        {
            PTrust->PAI->Internal_Engage(EntityId(PMob));
        }

        co_return;
    }

    // (2026-11-24, levi) the run home is with the weapon away: no turning to swing at it on the way
    if (PTrust->PAI->IsEngaged() && !PTrust->PAI->IsCurrentState<CMagicState>() && !PTrust->PAI->IsCurrentState<CRangeState>())
    {
        PTrust->PAI->Internal_Disengage();
    }

    if (!PTrust->PAI->PathFind->IsFollowingPath() || tick - m_CampRepath > 2s)
    {
        m_CampRepath = tick;
        PTrust->PAI->PathFind->PathTo(camp, PATHFLAG_NONE); // (back at a player's pace, the monster on its heels)
    }

    PTrust->PAI->PathFind->FollowPath(tick);
    co_return;
}

auto CTrustController::UsesPosition() const -> bool
{
    const auto mode = POwner->GetLocalVar("SQUAD_POSITION");
    return mode == squad::position::Behind || mode == squad::position::TaPartner;
}

// FFXI Offline squad: the position the player chose for this mate (!squad position, squad_position.h). Returns true
// while the mate has a spot of its own this tick: then the usual distance keeping (melee closing in, a caster's random
// spot at its distance) and the sidestepping wait, and the mate goes to that spot when it is clearly away from it.
auto CTrustController::PositionTick(CCharEntity* PMaster, CBattleEntity* PTarget, bool melee, float radius) -> bool
{
    namespace sp = squad::position;
    if (PMaster == nullptr || PTarget == nullptr || !UsesPosition())
    {
        return false;
    }

    const sp::Point enemy{ PTarget->loc.p.x, PTarget->loc.p.z };
    const float     facing = rotationToRadian(PTarget->loc.p.rotation);
    // (r3) the TA partner's spot: behind the enemy, turned towards the player (at most 60 degrees): always there in a fight
    const sp::Point partnerSpot = sp::PartnerSpot(enemy, facing, { PMaster->loc.p.x, PMaster->loc.p.z }, sp::PartnerDistance);

    // every mate of this master, in the master's order: who uses a position on this enemy, and of which kind
    std::vector<sp::Peer> peers;
    peers.reserve(PMaster->PTrusts.size());
    for (auto* PMate : PMaster->PTrusts)
    {
        if (PMate == nullptr)
        {
            continue;
        }
        const int16 dist     = PMate->getMobMod(xi::MobMod::TrustDistance);
        const bool  fighting = PMate->isAlive() && PMate->GetBattleTarget() == PTarget && dist != TRUST_MOVEMENT_TYPE::NO_MOVE &&
                              dist != TRUST_MOVEMENT_TYPE::NON_COMBAT;
        peers.push_back({
            .self     = PMate == POwner,
            .mode     = static_cast<int>(PMate->GetLocalVar("SQUAD_POSITION")),
            .melee    = dist == TRUST_MOVEMENT_TYPE::MELEE,
            .usable   = fighting && PTarget->GetBattleTarget() != PMate,
            .fighting = fighting,
        });
    }

    const auto place = sp::Place(peers, true);
    if (!place.positioned)
    {
        // (its usual place: the enemy is on this mate, or it is not fighting this enemy) - said by !squad position
        POwner->SetLocalVar("SQUAD_POS_STATE", PTarget->GetBattleTarget() == POwner ? sp::StateEnemyOnIt : sp::StateOtherFoe);
        return false;
    }

    // the melee arc keeps off the TA partner's line while a TA partner fights the enemy, so only the partner is in line for
    // the player's Trick Attack (the partner may be away for a moment, e.g. while the enemy is on it)
    const std::optional<float> avoid = (melee && place.lineReserved) ? std::optional<float>(sp::OffsetOf(enemy, facing, partnerSpot)) : std::nullopt;
    const sp::Point            spot  = place.partner ? partnerSpot : sp::BehindSpot(enemy, facing, radius, sp::ArcOffsetAvoiding(place.arcIndex, avoid));

    // a caster or ranged mate keeps the enemy's target (usually the tank) within reach of a heal; else its usual place
    if (!melee)
    {
        const CBattleEntity* PTank = PTarget->GetBattleTarget();
        if (PTank != nullptr && sp::Distance(spot, { PTank->loc.p.x, PTank->loc.p.z }) > sp::TankReach)
        {
            POwner->SetLocalVar("SQUAD_POS_STATE", sp::StateTankTooFar);
            return false;
        }
    }

    m_PositionPlaced = true;
    POwner->SetLocalVar("SQUAD_POS_STATE", place.partner ? sp::StatePartner : sp::StateArc);
    POwner->SetLocalVar("SQUAD_POS_ARC", place.partner ? 0 : static_cast<uint32>(place.arcIndex + 1));

    const auto   nowSec = static_cast<uint32>(std::chrono::duration_cast<std::chrono::seconds>(m_Tick.time_since_epoch()).count());
    const uint32 last   = POwner->GetLocalVar("SQUAD_POS_AT");
    const float  since  = last == 0 ? 1000.0f : static_cast<float>(nowSec - last);
    const float  away   = sp::Distance({ POwner->loc.p.x, POwner->loc.p.z }, spot);
    if (sp::ShouldMove(away, melee ? sp::MeleeSlack : sp::RangedSlack, since))
    {
        position_t goal = PTarget->loc.p; // (the enemy's height: the path finds the floor)
        goal.x          = spot.x;
        goal.z          = spot.z;
        POwner->SetLocalVar("SQUAD_POS_AT", nowSec);
        // (only the path here: the FollowPath at the end of the combat tick takes the step, as for the thief's flank)
        if (!POwner->PAI->PathFind->PathTo(goal, PATHFLAG_RUN))
        {
            POwner->PAI->PathFind->StepToOnMesh(goal, true);
        }
    }

    return true;
}

void CTrustController::Declump(const CCharEntity* PMaster, const CBattleEntity* PTarget) const
{
    TracyZoneScoped;

    const uint8 currentPartyPos = GetPartyPosition();

    // XI: Forever Offline (2026-11-18, sparkiie: mates walked circles around the monster). Two close mates both
    // sidestepped, often the same way round, landed next to the next mate and stepped again, forever. Now only the
    // mate called later steps aside, and each mate sidesteps at most once every 4 seconds.
    const auto nowSec = static_cast<uint32>(std::chrono::duration_cast<std::chrono::seconds>(m_Tick.time_since_epoch()).count());
    if (const uint32 last = POwner->GetLocalVar("DECLUMP_AT"); last != 0 && nowSec - last < 4)
    {
        return;
    }

    bool seenSelf = false;
    for (const auto* POtherTrust : PMaster->PTrusts)
    {
        if (POtherTrust == POwner)
        {
            seenSelf = true;
            continue;
        }

        if (seenSelf || POtherTrust->PAI->PathFind->IsFollowingPath() || distance(POtherTrust->loc.p, POwner->loc.p) >= 1.5f)
        {
            continue; // (a mate called after us steps aside, not us)
        }

        POwner->SetLocalVar("DECLUMP_AT", nowSec);

        // Sidestep relative to the shared target so trusts spread around the enemy rather than away from each other.
        const float moveAmount = xirand::GetRandomNumber(0.0f, 1.5f) * ((currentPartyPos % 2) ? 1.0f : -1.0f);
        const auto  newPos     = sidestepPosition(POwner->loc.p, PTarget->loc.p, moveAmount);

        if (POwner->PAI->PathFind->ValidPosition(newPos))
        {
            POwner->PAI->PathFind->PathTo(newPos, PATHFLAG_RUN);
        }
        break;
    }
}

void CTrustController::PathOutToDistance(const CBattleEntity* PTarget, const float amount)
{
    TracyZoneScoped;

    // XI: Forever Offline (2026-11-18, wildthing): a mage keeping its distance who has pulled hate kept running to a new
    // spot as the monster followed it, so the tank could never get it back. While the monster is on us: stand and cast.
    if (PTarget->GetBattleTarget() == POwner)
    {
        if (POwner->PAI->PathFind->IsFollowingPath())
        {
            POwner->PAI->PathFind->Clear();
        }
        FaceTarget(PTarget->entityId());
        m_InTransit = false;
        return;
    }

    const float currentDistanceToTarget = distance(POwner->loc.p, PTarget->loc.p);
    position_t  target_position         = POwner->loc.p;

    if (GetTopEnmity() == POwner)
    {
        ++m_failedRepositionAttempts;
    }
    else
    {
        m_failedRepositionAttempts = 0;
    }

    // Invalidate position and pick new one (limit: every 3s)
    if ((currentDistanceToTarget < amount - 2.5f || currentDistanceToTarget > amount + 2.5f || !POwner->PAI->PathFind->ValidPosition(POwner->loc.p)) &&
        m_Tick - m_LastRepositionTime > 3s && !m_InTransit)
    {
        std::vector<position_t> positions(5);
        for (auto& position : positions)
        {
            const int        random_angle       = xirand::GetRandomNumber(256);
            const position_t potential_position = {
                PTarget->loc.p.x - (cosf(rotationToRadian(random_angle)) * amount),
                PTarget->loc.p.y,
                PTarget->loc.p.z + (sinf(rotationToRadian(random_angle)) * amount),
                0,
                0,
            };
            position = potential_position;
        }

        bool position_found = false;
        for (auto& potential_position : positions)
        {
            // Validate position
            if (!position_found &&
                POwner->PAI->PathFind->ValidPosition(potential_position) &&
                POwner->CanSeeTarget(potential_position))
            {
                position_found  = true;
                target_position = potential_position;
                m_InTransit     = true;
            }
        }

        m_LastRepositionTime = m_Tick;
    }

    // Get somewhat close to the target destination
    if (distance(POwner->loc.p, target_position) > 2.0f && m_failedRepositionAttempts < 3)
    {
        POwner->PAI->PathFind->PathTo(target_position, PATHFLAG_RUN);
    }
    else
    {
        FaceTarget(PTarget->entityId());
        m_InTransit = false;
    }
}

auto CTrustController::Ability(const EntityId target, uint16 abilityid) -> bool
{
    TracyZoneScoped;

    // (XI: Forever Offline, squad audit N5) the ability-id recast, and for a squad mate a player's shared recast and charges
    auto* PAbility = ability::GetAbility(abilityid);
    if (PAbility != nullptr ? POwner->IsAbilityOnRecast(PAbility) : POwner->PRecastContainer->HasRecast(xi::RecastType::Ability, static_cast<xi::Recast>(abilityid), 0s))
    {
        return false;
    }

    if (POwner->PAI->CanChangeState())
    {
        return POwner->PAI->Internal_Ability(target, abilityid);
    }

    return false;
}

// XI: Forever Offline (F12): the WS gear set is on from the start of the weapon skill until its damage is done
// (CTrustEntity::OnWeaponSkillFinished), and the weapon skill state's Cleanup, Die and despawn take it off too. A refused
// start (no target, out of sight: CWeaponSkillState::init) never enters the state, so it is taken off here.
auto CTrustController::WeaponSkill(const EntityId target, const uint16 wsid) -> bool
{
    auto* PTrust = dynamic_cast<CTrustEntity*>(POwner);
    if (PTrust == nullptr || !PTrust->isSquadMate())
    {
        return CMobController::WeaponSkill(target, wsid);
    }

    PTrust->ApplySquadWsSet();
    const bool started = CMobController::WeaponSkill(target, wsid);
    if (!started)
    {
        PTrust->RestoreSquadWsSet();
    }

    return started;
}

auto CTrustController::RangedAttack(const EntityId target) -> bool
{
    TracyZoneScoped;

    timer::duration rangedDelay = 10s;
    if (const CItemWeapon* PRange = dynamic_cast<CItemWeapon*>(POwner->m_Weapons[SLOT_RANGED]))
    {
        rangedDelay = std::chrono::milliseconds(PRange->getDelay());
    }

    if (m_Tick - m_LastRangedAttackTime > rangedDelay && !m_InTransit)
    {
        FaceTarget(target);
        if (POwner->PAI->CanChangeState() && POwner->PAI->Internal_RangedAttack(target))
        {
            m_LastRangedAttackTime = m_Tick;
        }
        return true;
    }
    return false;
}

auto CTrustController::Cast(const EntityId target, SpellID spellid) -> bool
{
    TracyZoneScoped;

    FaceTarget(target);

    if (POwner->PRecastContainer->Has(xi::RecastType::Magic, static_cast<xi::Recast>(spellid)))
    {
        return false;
    }

    auto* PSpell = spell::GetSpell(spellid);

    // XI: Forever Offline: a spell id that is not in spell_list (e.g. castSpell(60000) from a script) has no CSpell: stop here instead
    // of dereferencing a null PSpell below (access violation about two seconds later).
    if (PSpell == nullptr)
    {
        return false;
    }

    // XI: Forever Offline (job expansion): a song is sung on the singer and reaches the party around it; a rule may name a
    // party member as the one it is for (e.g. "a melee member lacks Minuet"). Without Pianissimo such a song can only be
    // cast on oneself, so it is: before, it was aimed at that member and refused. Songs on enemies are unchanged.
    const auto validTargets = PSpell->getValidTarget();
    const bool songOnSelf   = PSpell->getSpellGroup() == SPELLGROUP_SONG && (validTargets & TARGET_SELF) != 0 &&
                            (validTargets & TARGET_ENEMY) == 0 && !POwner->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Pianissimo);
    const auto castTarget = (validTargets == TARGET_SELF || songOnSelf) ? EntityId(POwner) : target;

    const auto PTarget      = castTarget.resolve<CBattleEntity>();
    const auto PSpellFamily = PSpell->getSpellFamily();
    bool       canCast      = true;

    // clang-format off
    static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts(
        [&](const CBattleEntity* PMember)
    {
        if (PMember->objtype == TYPE_TRUST && PMember->PAI->IsCurrentState<CMagicState>())
        {
            const auto MState = static_cast<CMagicState*>(PMember->PAI->GetCurrentState());

            if (MState)
            {
                const auto MSpell       = MState->GetSpell();
                const auto MTarget      = MState->target().resolve();
                const auto MSpellFamily = MSpell->getSpellFamily();
                const auto MSpellID     = MSpell->getID();

                if (PSpell->isBuff())
                {
                    // (B4, 2026-11-25) trust_cast_gate.h: family 0 is "this spell only", and two mates casting a self-only buff
                    // each on herself (Blink, Aquaveil) no longer wait for each other
                    const auto selfOnly = [](const CSpell* S)
                    {
                        return S->getValidTarget() == TARGET_SELF && S->getAOE() != SPELLAOE_RADIAL && S->getSpellGroup() != SPELLGROUP_SONG;
                    };
                    const trust::castgate::Buff want{ .id = static_cast<uint16>(spellid), .family = static_cast<uint16>(PSpellFamily), .selfOnly = selfOnly(PSpell) };
                    const trust::castgate::Buff other{ .id = static_cast<uint16>(MSpellID), .family = static_cast<uint16>(MSpellFamily), .selfOnly = selfOnly(MSpell) };
                    if (trust::castgate::BuffWaits(want, other, PTarget != nullptr && PTarget == MTarget))
                    {
                        canCast = false;
                    }
                }
                if (PSpell->isCure())
                {
                    if (PTarget && PTarget == MTarget && PTarget->GetHPP() > 50)
                    {
                        canCast = false;
                    }
                }
                if (PSpell->isDebuff())
                {
                    if (PSpellFamily == MSpellFamily && spellid <= MSpellID)
                    {
                        canCast = false;
                    }
                }
                if (PSpell->isNa())
                {
                    if (PSpellFamily == MSpellFamily && spellid == MSpellID)
                    {
                        canCast = false;
                    }
                }
            }
        }
    });
    // clang-format on

    if (!canCast)
    {
        return false;
    }

    // (XI: Forever Offline, 2026-11-22, Hexblood: "the AoE buffs miss me"; the user: "can we have the caster step in
    // range, and if any mates are out of range they do as well") A spell that helps everyone around its caster
    // (Protectra, Shellra, the Bar spells) is held back while the player is out of its reach, or out of a fight any
    // squad mate near him. The caster walks in first (StepInTick, from the roam and combat ticks), the squad closes
    // up around the player (SQUAD_GATHER, read in DoRoamTick), and then it is cast. After a few seconds it is cast
    // from where she stands, so a mate that cannot get there still casts.
    if (!m_StepInCasting)
    {
        if (const float radius = StepInRadius(PSpell, PTarget); radius > 0.0f)
        {
            auto*      PMaster  = static_cast<CCharEntity*>(POwner->PMaster);
            const bool fighting = PMaster->PAI->IsEngaged();
            const bool waiting  = m_StepInSpell == spellid;
            if (AreaSpellCovers(radius) || (waiting && m_Tick - m_StepInSince > (fighting ? 4s : 7s)))
            {
                m_StepInSpell = SpellID::None;
            }
            else
            {
                if (!waiting)
                {
                    m_StepInSpell = spellid;
                    m_StepInSince = m_Tick;
                }

                if (!fighting)
                {
                    PMaster->SetLocalVar("SQUAD_GATHER", earth_time::timestamp() + 5);
                }

                return false;
            }
        }
        else if (m_StepInSpell == spellid)
        {
            m_StepInSpell = SpellID::None;
        }
    }

    return CMobController::Cast(castTarget, spellid);
}

// FFXI Offline squad: the reach of an area spell that is held back until its caster is near the player, or 0 when the
// spell is not one of those: not a squad mate, not an area spell cast on oneself, a song (the Bard has her own walk), a
// mate holding a camp (it does not leave its spot), or the player down or far away.
auto CTrustController::StepInRadius(const CSpell* PSpell, const CBattleEntity* PTarget) const -> float
{
    if (PSpell == nullptr || PTarget != POwner || POwner->PMaster == nullptr || POwner->GetLocalVar("SQUAD_ID") == 0)
    {
        return 0.0f;
    }

    if (PSpell->getAOE() != SPELLAOE_RADIAL || PSpell->getSpellGroup() == SPELLGROUP_SONG || PSpell->getRadius() < 5.0f ||
        (PSpell->getValidTarget() & TARGET_ENEMY) != 0)
    {
        return 0.0f;
    }

    position_t camp{};
    if (campOf(POwner, camp))
    {
        return 0.0f;
    }

    auto* PMaster = POwner->PMaster;
    if (PMaster->isDead() || PMaster->getZone() != POwner->getZone() || distance(POwner->loc.p, PMaster->loc.p) > 40.0f)
    {
        return 0.0f;
    }

    return PSpell->getRadius();
}

// true when everyone the spell is for stands inside it: the player, and out of a fight the squad mates around him
auto CTrustController::AreaSpellCovers(const float radius) const -> bool
{
    auto* PMaster = static_cast<CCharEntity*>(POwner->PMaster);
    if (distance(POwner->loc.p, PMaster->loc.p) > radius - 1.5f)
    {
        return false;
    }

    if (PMaster->PAI->IsEngaged())
    {
        return true; // in a fight nobody is called off the monster for it
    }

    for (auto* POther : PMaster->PTrusts)
    {
        if (POther == nullptr || POther == POwner || POther->isDead() || POther->GetLocalVar("SQUAD_ID") == 0 ||
            POther->GetLocalVar("SQUAD_PULL_PHASE") != 0 || POther->PAI->IsEngaged() || distance(POther->loc.p, PMaster->loc.p) > 25.0f)
        {
            continue; // (out pulling, fighting, or left behind: not waited for)
        }

        if (distance(POwner->loc.p, POther->loc.p) > radius - 1.0f)
        {
            return false;
        }
    }

    return true;
}

// Called at the top of the roam and combat ticks. true = an area spell is waiting and this tick walked towards the
// player (or cast it). Out of a fight the caster comes right up to the player, so the squad closing up around him is
// covered; in a fight only as near as the spell needs, to stay as far from the monster as she can.
auto CTrustController::StepInTick() -> bool
{
    if (m_StepInSpell == SpellID::None)
    {
        return false;
    }

    const SpellID spellid = m_StepInSpell;
    const float   radius  = StepInRadius(spell::GetSpell(spellid), POwner);
    if (radius <= 0.0f || POwner->isDead())
    {
        m_StepInSpell = SpellID::None;
        DeferResult(spellid, static_cast<uint8>(squad::castapproach::State::Failed), static_cast<uint8>(squad::castapproach::Why::Target));
        return false;
    }

    auto*      PMaster  = static_cast<CCharEntity*>(POwner->PMaster);
    const bool fighting = PMaster->PAI->IsEngaged();
    if (AreaSpellCovers(radius) || m_Tick - m_StepInSince > (fighting ? 4s : 7s))
    {
        m_StepInSpell = SpellID::None;
        POwner->PAI->PathFind->Clear();
        m_StepInCasting = true;
        // (B11, 2026-11-27) the outcome is kept for a chat request that is waiting on it (it was dropped: an "On it" with no cast)
        const bool started = Cast(EntityId(POwner), spellid);
        m_StepInCasting    = false;
        DeferResult(spellid, static_cast<uint8>(started ? squad::castapproach::State::Cast : squad::castapproach::State::Failed),
                    static_cast<uint8>(started ? squad::castapproach::Why::None : squad::castapproach::Why::Busy));
        return true;
    }

    if (!fighting)
    {
        PMaster->SetLocalVar("SQUAD_GATHER", earth_time::timestamp() + 4);
    }

    const float want = fighting ? radius - 3.0f : 2.5f;
    if (distance(POwner->loc.p, PMaster->loc.p) > want + 1.0f)
    {
        if (!POwner->PAI->PathFind->IsFollowingPath() && !POwner->PAI->PathFind->PathAround(PMaster->loc.p, want, PATHFLAG_RUN) &&
            POwner->GetSpeed() > 0)
        {
            POwner->PAI->PathFind->StepToOnMesh(PMaster->loc.p, true);
        }

        if (POwner->PAI->PathFind->IsFollowingPath())
        {
            POwner->PAI->PathFind->FollowPath(m_Tick);
        }
    }
    else if (POwner->PAI->PathFind->IsFollowingPath())
    {
        POwner->PAI->PathFind->Clear(); // there: stand and let the others close up
    }

    return true;
}

// (B9 / B11) the outcome of a chat cast that did not start at once: the Lua side (squad_requests.lua) polls these
void CTrustController::DeferResult(const SpellID spellid, const uint8 state, const uint8 why)
{
    POwner->SetLocalVar(squad::castapproach::VarSpell, static_cast<uint32>(spellid));
    POwner->SetLocalVar(squad::castapproach::VarState, state);
    POwner->SetLocalVar(squad::castapproach::VarWhy, why);
}

auto CTrustController::StartApproach(const EntityId& target, const SpellID spellid) -> bool
{
    if (m_ApproachSpell != SpellID::None)
    {
        return false;
    }

    m_ApproachSpell  = spellid;
    m_ApproachTarget = target;
    m_ApproachSince  = m_Tick;
    DeferResult(spellid, static_cast<uint8>(squad::castapproach::State::Waiting), 0);
    return true;
}

// (B9) one roam tick of the walk toward a chat request's target; everything is checked again before the cast. true while
// it walks (the rest of the roam tick waits).
auto CTrustController::ApproachTick() -> bool
{
    namespace ca = squad::castapproach;
    if (m_ApproachSpell == SpellID::None)
    {
        return false;
    }

    const SpellID spellid = m_ApproachSpell;
    CSpell*       PSpell  = spell::GetSpell(spellid);
    auto*         PTarget = m_ApproachTarget.resolve<CBattleEntity>();
    auto*         PMaster = static_cast<CCharEntity*>(POwner->PMaster);
    const bool    forDead = PSpell != nullptr && (PSpell->getValidTarget() & TARGET_PLAYER_DEAD) != 0;

    ca::StepFacts facts;
    facts.targetOk   = PSpell != nullptr && PTarget != nullptr && !POwner->isDead() && PTarget->getZone() == POwner->getZone() &&
                     PTarget->isDead() == forDead;
    facts.fighting   = POwner->PAI->IsEngaged() || (PMaster != nullptr && PMaster->PAI->IsEngaged());
    facts.spellReady = facts.targetOk && static_cast<CTrustEntity*>(POwner)->SpellContainer->GetAvailable(spellid).has_value() &&
                       !POwner->PRecastContainer->Has(xi::RecastType::Magic, static_cast<xi::Recast>(spellid));
    facts.canMove    = POwner->GetSpeed() > 0 && POwner->PAI->CanFollowPath();
    facts.elapsedSec = static_cast<int>(std::chrono::duration_cast<std::chrono::seconds>(m_Tick - m_ApproachSince).count());
    if (facts.targetOk)
    {
        facts.dist  = distance(POwner->loc.p, PTarget->loc.p);
        facts.reach = ca::Reach(PSpell->getRange(), PTarget->modelHitboxSize, POwner->modelHitboxSize);
    }

    const auto next = ca::Next(facts);
    if (next.step == ca::Step::Walk)
    {
        if (!POwner->PAI->PathFind->IsFollowingPath() &&
            !POwner->PAI->PathFind->PathAround(PTarget->loc.p, std::max(1.0f, facts.reach - 2.0f), PATHFLAG_RUN))
        {
            POwner->PAI->PathFind->StepToOnMesh(PTarget->loc.p, true);
        }

        if (POwner->PAI->PathFind->IsFollowingPath())
        {
            POwner->PAI->PathFind->FollowPath(m_Tick);
        }

        return true;
    }

    m_ApproachSpell = SpellID::None;
    m_ApproachTarget.clean();
    POwner->PAI->PathFind->Clear();
    if (next.step == ca::Step::Cast)
    {
        const bool started = Cast(PTarget->entityId(), spellid);
        DeferResult(spellid, static_cast<uint8>(started ? ca::State::Cast : ca::State::Failed),
                    static_cast<uint8>(started ? ca::Why::None : ca::Why::Busy));
        return started;
    }

    DeferResult(spellid, static_cast<uint8>(ca::State::Failed), static_cast<uint8>(next.why));
    return false;
}

auto CTrustController::GetTopEnmity() const -> CBattleEntity*
{
    TracyZoneScoped;

    // XI: Forever Offline (2026-11-23): a squad mate asks about the monster it is fighting itself; without one, and for
    // every other trust, the master's battle target as before (see trust_enmity_target.h).
    const bool  squadMate     = POwner->GetLocalVar("SQUAD_ID") != 0;
    const auto* POwnTarget    = squadMate ? dynamic_cast<CMobEntity*>(POwner->GetBattleTarget()) : nullptr;
    const auto* PMasterTarget = POwner->PMaster ? dynamic_cast<CMobEntity*>(POwner->PMaster->GetBattleTarget()) : nullptr;
    if (POwnTarget != nullptr && (POwnTarget->isDead() || POwnTarget->PEnmityContainer == nullptr))
    {
        POwnTarget = nullptr; // (nothing to read there any more)
    }

    CBattleEntity* PEntity = nullptr;
    if (const auto* PMob = trustenmity::TopEnmityTarget(squadMate, POwnTarget, PMasterTarget); PMob != nullptr && PMob->PEnmityContainer != nullptr)
    {
        return PMob->PEnmityContainer->GetHighestEnmity();
    }
    return PEntity;
}

auto CTrustController::GetPartyPosition() const -> uint8
{
    TracyZoneScoped;

    const auto& trustList = static_cast<CCharEntity*>(POwner->PMaster)->PTrusts;
    for (std::size_t i = 0; i < trustList.size(); ++i)
    {
        if (trustList.at(i)->id == POwner->id)
        {
            return static_cast<uint8>(i);
        }
    }
    return 0;
}
