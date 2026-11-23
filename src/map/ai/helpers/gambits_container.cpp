/*
===========================================================================

  Copyright (c) 2025 LandSandBoat Dev Teams

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

#include "gambits_container.h"
#include "gambits_reach.h"

#include "ability.h"
#include "ai/states/ability_state.h"
#include "ai/states/magic_state.h"
#include "ai/states/mobskill_state.h"
#include "ai/states/petskill_state.h"
#include "ai/states/range_state.h"
#include "ai/states/weaponskill_state.h"
#include "enmity_container.h"
#include "notoriety_container.h"
#include "recast_container.h"
#include "spell.h"
#include "utils/battleutils.h"
#include "weapon_skill.h"

#include "ai/controllers/player_controller.h"
#include "ai/controllers/trust_controller.h"

#include "packets/s2c/0x038_schedulor.h"
#include "zone.h"

#include <algorithm>
#include <ctime>

namespace gambits
{

namespace
{
// XI: Forever Offline (Bard song tiers): STATUS / NOT_STATUS. condition_arg = status effect id (low 16 bits) | tier << 16.
// Tier 0 = the effect at any tier (the argument every gambit had before, unchanged). A tier names one song of a song type:
// all Marches are the effect MARCH, Advancing March tier 1, Victory March tier 2 (enhancing_song.lua songPTable; the tier
// ApplyBardEffect keeps them apart by). Squad Rule Sets may give a tier only to song effects (squad_rulesets.lua).
auto HasStatusEffectTier(const CBattleEntity* target, uint32 arg) -> bool
{
    const auto effect = static_cast<xi::StatusEffect>(arg & 0xFFFF);
    const auto tier   = static_cast<uint16>(arg >> 16);
    if (tier == 0)
    {
        return target->StatusEffectContainer->HasStatusEffect(effect);
    }

    bool found = false;
    target->StatusEffectContainer->ForEachEffect([&](CStatusEffect& PEffect)
                                                 {
                                                     found = found || (PEffect.GetStatusID() == effect && PEffect.GetTier() == tier && !PEffect.isDeleted());
                                                 });
    return found;
}

// XI: Forever Offline (job expansion): a skillchain effect's resonance. Before a skillchain forms (tier 0, an opening)
// the power packs the opening weapon skill's three properties, 4 bits each; once a skillchain has formed (tier > 0) the
// power is that skillchain's type (battleutils::GetSkillChainEffect). Reading a formed chain as three nibbles split
// Darkness II (16) into None + Transfixion (a light burst / a wrong closer).
auto resonanceOf(CStatusEffect* PSCEffect) -> std::list<xi::SkillchainType>
{
    std::list<xi::SkillchainType> out;
    if (PSCEffect == nullptr || PSCEffect->GetPower() == 0)
    {
        return out;
    }

    const uint16 power = PSCEffect->GetPower();
    if (PSCEffect->GetTier() > 0)
    {
        out.emplace_back(static_cast<xi::SkillchainType>(power));
        return out;
    }

    out.emplace_back(static_cast<xi::SkillchainType>(power & 0xF));
    out.emplace_back(static_cast<xi::SkillchainType>((power >> 4) & 0xF));
    out.emplace_back(static_cast<xi::SkillchainType>((power >> 8) & 0xF));
    return out;
}

// XI: Forever Offline (job expansion): how long after a skillchain forms a mate reacts to it with a magic burst. A burst
// lands whenever the effect is still on the target (xi.combat.magicBurst.getMagicBurstTier); the old 3 s came from the
// weapon skill chaining rule (GetSkillChainEffect), which stays 3 s for SC_AVAILABLE and the weapon skill triggers. With the
// 2-3 s evaluation cadence this gives a human-like 1-4 s before the cast starts.
constexpr auto MagicBurstReaction = std::chrono::seconds(1);
constexpr auto MagicBurstMargin   = std::chrono::milliseconds(500); // the spell must land this long before the window closes

// XI: Forever Offline (job expansion): a party role set for one character by the squad (local var SQUAD_ROLE: 1 tank,
// 2 melee, 3 caster, 4 ranged; 0 = by main job, as before). Only the squad sets it (!squad partyrole).
auto squadRole(CBattleEntity* PMember) -> uint32
{
    return PMember != nullptr ? PMember->GetLocalVar("SQUAD_ROLE") : 0;
}

// XI: Forever Offline (Gambits 0.3.3, Bard role targeting): the role bit of a role target (Gambit_t role_include /
// role_exclude), 0 for any other target
auto RoleBit(G_TARGET target) -> uint8
{
    switch (target)
    {
        case G_TARGET::TANK:
            return 1;
        case G_TARGET::MELEE:
            return 2;
        case G_TARGET::CASTER:
            return 4;
        case G_TARGET::RANGED:
            return 8;
        default:
            return 0;
    }
}

auto nowSeconds() -> uint32
{
    return static_cast<uint32>(std::time(nullptr)); // (the epoch Lua's os.time() uses: squad.lua reads and writes these)
}

// XI: Forever Offline (Squad healer range, see gambits_reach.h): the spell a rule made only of spells will cast, when it
// is known before a target is chosen (a specific spell, or the best of a family), as the reach it gives the rule.
// Anything else - a job ability, a ranged attack, a spell picked against the target - gives no reach (the inherited 15).
auto RuleSpellReach(CTrustEntity* POwner, const Gambit_t& gambit) -> std::optional<reach::SpellReach>
{
    const Action_t* first = nullptr;
    for (const auto& action : gambit.actions)
    {
        if (action.reaction != G_REACTION::MA)
        {
            return std::nullopt;
        }

        if (first == nullptr)
        {
            first = &action; // (only the first spell of a rule is cast)
        }
    }

    if (first == nullptr || POwner->SpellContainer == nullptr)
    {
        return std::nullopt;
    }

    Maybe<SpellID> spellId = std::nullopt;
    if (first->select == G_SELECT::SPECIFIC)
    {
        spellId = POwner->SpellContainer->GetAvailable(static_cast<SpellID>(first->select_arg));
    }
    else if (first->select == G_SELECT::HIGHEST)
    {
        spellId = POwner->SpellContainer->GetBestAvailable(static_cast<SPELLFAMILY>(first->select_arg));
    }

    const CSpell* PSpell = spellId.has_value() ? spell::GetSpell(spellId.value()) : nullptr;
    if (PSpell == nullptr)
    {
        return std::nullopt;
    }

    return reach::FromSpellData(PSpell->getValidTarget(), PSpell->getRange(), PSpell->getRadius());
}

static_assert(reach::TargetSelf == TARGET_SELF && reach::TargetPlayerParty == TARGET_PLAYER_PARTY);

} // namespace

// Return a new unique identifier for a gambit
auto CGambitsContainer::NewGambitIdentifier(const Gambit_t& gambit) const -> std::string
{
    return fmt::format("{}_{}_{}", gambits.size(), gambit.predicate_groups.size(), gambit.actions.size());
}

// Validate gambit before it's inserted into the gambit list
// Check levels, etc.
auto CGambitsContainer::AddGambit(const Gambit_t& gambit) -> std::string
{
    TracyZoneScoped;

    bool available = true;
    for (const auto& action : gambit.actions)
    {
        if (action.reaction == G_REACTION::MA && action.select == G_SELECT::SPECIFIC)
        {
            if (!spell::CanUseSpell(static_cast<CBattleEntity*>(POwner), static_cast<SpellID>(action.select_arg)))
            {
                available = false;
                break;
            }
        }
    }

    if (!available)
    {
        return "";
    }

    // Make a modifiable copy, assign a new identifier and store it
    Gambit_t stored   = gambit;
    stored.identifier = NewGambitIdentifier(stored);

    // XI: Forever Offline (Gambits 0.3.3, Bard role targeting): a role target may carry role filters in the target
    // argument's high byte (include bits 8-11, exclude bits 12-15). Only for TANK / MELEE / CASTER / RANGED; on any other
    // target the high byte is refused (the rule is not added) instead of being read as another target.
    const auto raw = static_cast<uint16>(stored.target_selector);
    if (raw > 0xFF)
    {
        const auto base = static_cast<G_TARGET>(raw & 0xFF);
        if (base != G_TARGET::TANK && base != G_TARGET::MELEE && base != G_TARGET::CASTER && base != G_TARGET::RANGED)
        {
            return "";
        }

        stored.target_selector = base;
        stored.role_include    = static_cast<uint8>((raw >> 8) & 0x0F);
        stored.role_exclude    = static_cast<uint8>((raw >> 12) & 0x0F);
    }
    gambits.emplace_back(std::move(stored));
    return gambits.back().identifier;
}

void CGambitsContainer::RemoveGambit(const std::string& id)
{
    std::erase_if(gambits,
                  [&id](const Gambit_t& gambit)
                  {
                      return gambit.identifier == id;
                  });

    const auto prefix = fmt::format("{}:", id);
    std::erase_if(m_timerConditionLastTrigger, [&](const auto& kv)
                  {
                      return kv.first.starts_with(prefix);
                  });
}

void CGambitsContainer::RemoveAllGambits()
{
    gambits.clear();
    m_timerConditionLastTrigger.clear();
}

auto CGambitsContainer::Tick(timer::time_point tick) -> Task<void>
{
    TracyZoneScoped;

    auto* controller      = static_cast<CTrustController*>(POwner->PAI->GetController());
    uint8 currentPartyPos = controller->GetPartyPosition();
    auto  position_offset = static_cast<std::chrono::milliseconds>(currentPartyPos * 100);

    if ((tick + position_offset) < m_lastAction)
    {
        co_return;
    }

    // TODO: Is this necessary?
    // Not already doing something
    if (POwner->PAI->IsCurrentState<CAbilityState>() || POwner->PAI->IsCurrentState<CRangeState>() || POwner->PAI->IsCurrentState<CMagicState>() ||
        POwner->PAI->IsCurrentState<CWeaponSkillState>() || POwner->PAI->IsCurrentState<CMobSkillState>() ||
        POwner->PAI->IsCurrentState<CPetSkillState>())
    {
        co_return;
    }

    auto random_offset = static_cast<std::chrono::milliseconds>(xirand::GetRandomNumber(2000, 3000));
    m_lastAction       = tick + random_offset;

    // Deal with TP skills before any gambits
    // TODO: Should this be its own special gambit?
    if (POwner->health.tp >= 1000 && TryTrustSkill())
    {
        co_return;
    }

    // XI: Forever Offline (Squad healer range): squad mates' spell rules reach party members as far as the spell does
    const bool squadMate = POwner->GetLocalVar("SQUAD_ID") != 0;

    // Didn't WS/MS, go for other Gambits
    for (auto& gambit : gambits)
    {
        if (tick < gambit.last_used + std::chrono::seconds(gambit.retry_delay))
        {
            continue;
        }

        const auto ruleSpell = squadMate ? RuleSpellReach(POwner, gambit) : std::nullopt;

        auto isValidMember = [this, squadMate, &ruleSpell](CBattleEntity* PSettableTarget, CBattleEntity* PPartyTarget)
        {
            if (PSettableTarget || !PPartyTarget->isAlive() || POwner->loc.zone != PPartyTarget->loc.zone)
            {
                return false;
            }

            if (!squadMate)
            {
                return distance(POwner->loc.p, PPartyTarget->loc.p) <= 15.0f; // (other trusts: unchanged)
            }

            return reach::WithinReach(POwner->loc.p, PPartyTarget->loc.p,
                                      reach::PartyReach(true, ruleSpell, POwner->modelHitboxSize, PPartyTarget->modelHitboxSize));
        };

        G_TARGET targetType = gambit.target_selector;

        CBattleEntity* target = nullptr;

        // Capture all potential targets
        std::vector<CBattleEntity*> potentialTargets;

        if (targetType == G_TARGET::SELF || targetType == G_TARGET::TRIGGER_SELF_ACTION_TARGET)
        {
            potentialTargets.push_back(POwner);
        }
        else if (targetType == G_TARGET::TARGET || targetType == G_TARGET::TRIGGER_TARGET_ACTION_SELF)
        {
            auto* mob = POwner->GetBattleTarget();
            potentialTargets.push_back(mob);
        }
        else if (targetType == G_TARGET::PARTY)
        {
            // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    if (isValidMember(target, PMember))
                    {
                        potentialTargets.push_back(PMember);
                    }
                });
            // clang-format on
        }
        else if (targetType == G_TARGET::PARTY_LOWEST_HPP)
        {
            // XI: Forever Offline: the same members as PARTY (alive, same zone, within 15 yalms), tried from the lowest HP%
            // up; equal HP% keeps party order. The first one whose conditions all match is the target.
            // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    if (isValidMember(target, PMember))
                    {
                        potentialTargets.push_back(PMember);
                    }
                });
            // clang-format on
            std::stable_sort(potentialTargets.begin(), potentialTargets.end(),
                             [](const CBattleEntity* a, const CBattleEntity* b)
                             {
                                 return a->GetHPP() < b->GetHPP();
                             });
        }
        else if (targetType == G_TARGET::MASTER)
        {
            potentialTargets.push_back(POwner->PMaster);
        }
        else if (targetType == G_TARGET::PARTY_DEAD)
        {
            auto* mob = POwner->GetBattleTarget();
            if (mob != nullptr)
            {
                // clang-format off
                    static_cast<CCharEntity*>(POwner->PMaster)->ForParty([&](CBattleEntity* PMember) {
                        if (PMember->isDead())
                        {
                            potentialTargets.push_back(PMember);
                        }
                    });
                // clang-format on
            }
        }
        else if (RoleBit(targetType) != 0 && (gambit.role_include != 0 || gambit.role_exclude != 0))
        {
            // XI: Forever Offline (Gambits 0.3.3, Bard role targeting): a member qualifies when it has ANY of the included
            // roles (the target's own role and role_include) and NONE of the excluded ones; exclusion wins. Each member is
            // looked at once, so one that matches several included roles is never a target twice. The roles are exactly
            // the single-role targets' below (a party role set with !squad partyrole decides; else the main job).
            auto inRole = [this](CBattleEntity* PMember, uint8 bit) -> bool
            {
                const auto role = squadRole(PMember);
                const auto job  = PMember->GetMJob();
                switch (bit)
                {
                    case 1:
                        return role == 1 || (role == 0 && (job == xi::Job::PLD || job == xi::Job::RUN));
                    case 2:
                        return role == 2 || (role == 0 && melee_jobs.contains(job));
                    case 4:
                        return role == 3 || (role == 0 && caster_jobs.contains(job));
                    case 8:
                        return role == 4 || (role == 0 && (job == xi::Job::RNG || job == xi::Job::COR));
                    default:
                        return false;
                }
            };
            auto anyRole = [&inRole](CBattleEntity* PMember, uint8 bits) -> bool
            {
                for (uint8 bit = 1; bit <= 8; bit = static_cast<uint8>(bit << 1))
                {
                    if ((bits & bit) != 0 && inRole(PMember, bit))
                    {
                        return true;
                    }
                }

                return false;
            };

            const auto include = static_cast<uint8>(RoleBit(targetType) | gambit.role_include);
            // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    if (isValidMember(target, PMember) && anyRole(PMember, include) && !anyRole(PMember, gambit.role_exclude))
                    {
                        potentialTargets.push_back(PMember);
                    }
                });
            // clang-format on
        }
        else if (targetType == G_TARGET::TANK)
        {
            // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    // XI: Forever Offline (job expansion): a role the squad set for a member (!squad partyrole) decides; without
                    // one, the main job (as before)
                    const auto role = squadRole(PMember);
                    if (isValidMember(target, PMember) &&
                        (role == 1 || (role == 0 && (PMember->GetMJob() == xi::Job::PLD || PMember->GetMJob() == xi::Job::RUN))))
                    {
                        potentialTargets.push_back(PMember);
                    }
                });
            // clang-format on
        }
        else if (targetType == G_TARGET::MELEE)
        {
            // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    const auto role = squadRole(PMember);
                    if (isValidMember(target, PMember) &&
                        (role == 2 || (role == 0 && melee_jobs.contains(PMember->GetMJob()))))
                    {
                        potentialTargets.push_back(PMember);
                    }
                });
            // clang-format on
        }
        else if (targetType == G_TARGET::RANGED)
        {
            // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    const auto role = squadRole(PMember);
                    if (isValidMember(target, PMember) &&
                        (role == 4 || (role == 0 && (PMember->GetMJob() == xi::Job::RNG || PMember->GetMJob() == xi::Job::COR))))
                    {
                        potentialTargets.push_back(PMember);
                    }
                });
            // clang-format on
        }
        else if (targetType == G_TARGET::CASTER)
        {
            // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    const auto role = squadRole(PMember);
                    if (isValidMember(target, PMember) &&
                        (role == 3 || (role == 0 && caster_jobs.contains(PMember->GetMJob()))))
                    {
                        potentialTargets.push_back(PMember);
                    }
                });
            // clang-format on
        }
        else if (targetType == G_TARGET::TOP_ENMITY)
        {
            if (auto* PMob = dynamic_cast<CMobEntity*>(POwner->GetBattleTarget()))
            {
                // clang-format off
                    static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                    {
                        if (isValidMember(target, PMember) &&
                            PMob->PEnmityContainer->GetHighestEnmity() == PMember)
                        {
                            potentialTargets.push_back(PMember);
                        }
                    });
                // clang-format on
            }
        }
        else if (targetType == G_TARGET::CURILLA)
        {
            // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    if (isValidMember(target, PMember))
                    {
                        const auto& name = PMember->getName();
                        if (strcmpi(name.c_str(), "curilla") == 0)
                        {
                            potentialTargets.push_back(PMember);
                        }
                    }
                });
            // clang-format on
        }

        // For each potential target, check if the predicates resolves
        for (auto& potentialTarget : potentialTargets)
        {
            // All predicate groups must resolve successfully for the target to be considered
            bool targetMatchAllPredicates = true;
            for (size_t predicateGroupIndex = 0; predicateGroupIndex < gambit.predicate_groups.size(); ++predicateGroupIndex)
            {
                auto& predicateGroup = gambit.predicate_groups[predicateGroupIndex];
                if (!CheckTrigger(potentialTarget, gambit, predicateGroupIndex, predicateGroup))
                {
                    targetMatchAllPredicates = false;
                }
            }

            if (targetMatchAllPredicates)
            {
                if (gambit.target_selector == G_TARGET::TRIGGER_SELF_ACTION_TARGET)
                {
                    target = POwner->GetBattleTarget(); // switch back to target before action for correct target selection in actions
                    break;
                }
                else if (gambit.target_selector == G_TARGET::TRIGGER_TARGET_ACTION_SELF)
                {
                    target = POwner; // switch to self before action for correct target selection in actions
                    break;
                }
                target = potentialTarget;
                break;
            }
        }

        // No target matched, continue to next gambit
        if (!target)
        {
            continue;
        }

        // Pre resolve actions and perform simple recast/availability checks.
        // This prevents attempting to cast multiple spells in the same tick (which doesn't work)
        // and ensures all actions are available before starting.
        std::vector<bool>           canExecute(gambit.actions.size(), true);
        std::vector<Maybe<SpellID>> resolvedSpells(gambit.actions.size(), std::nullopt);

        // Helper to resolve a spell action to a valid SpellID if possible.
        auto ResolveMA = [&](const Action_t& action, CBattleEntity* resolvedTarget) -> Maybe<SpellID>
        {
            if (action.select == G_SELECT::SPECIFIC)
            {
                return POwner->SpellContainer->GetAvailable(static_cast<SpellID>(action.select_arg));
            }
            else if (action.select == G_SELECT::HIGHEST)
            {
                return POwner->SpellContainer->GetBestAvailable(static_cast<SPELLFAMILY>(action.select_arg));
            }
            else if (action.select == G_SELECT::LOWEST)
            {
                // Not implemented yet: treat as unavailable
                return std::nullopt;
            }
            else if (action.select == G_SELECT::BEST_INDI)
            {
                auto* PMaster = static_cast<CCharEntity*>(POwner->PMaster);
                return POwner->SpellContainer->GetBestIndiSpell(PMaster);
            }
            else if (action.select == G_SELECT::ENTRUSTED)
            {
                auto* PMaster = static_cast<CCharEntity*>(POwner->PMaster);
                // Entrusted spells target master
                return POwner->SpellContainer->GetBestEntrustedSpell(PMaster);
            }
            else if (action.select == G_SELECT::BEST_AGAINST_TARGET)
            {
                auto spell_to_cast = static_cast<SpellID>(action.select_arg);
                return POwner->SpellContainer->GetBestAgainstTargetWeakness(resolvedTarget, spell_to_cast);
            }
            else if (action.select == G_SELECT::DEF_BAR_ELEMENT)
            {
                auto maybeSpellId = POwner->SpellContainer->GetAvailable(SpellID::Barfire);
                auto element      = POwner->GetLocalVar("[Gambit]CastElement");

                if (element != 0)
                {
                    switch (element)
                    {
                        case ELEMENT_FIRE:
                            maybeSpellId = SpellID::Barfire;
                            break;
                        case ELEMENT_ICE:
                            maybeSpellId = SpellID::Barblizzard;
                            break;
                        case ELEMENT_WIND:
                            maybeSpellId = SpellID::Baraero;
                            break;
                        case ELEMENT_EARTH:
                            maybeSpellId = SpellID::Barstone;
                            break;
                        case ELEMENT_THUNDER:
                            maybeSpellId = SpellID::Barthunder;
                            break;
                        case ELEMENT_WATER:
                            maybeSpellId = SpellID::Barwater;
                            break;
                        default:
                            break;
                    }
                }
                return maybeSpellId;
            }
            else if (action.select == G_SELECT::STORM_DAY)
            {
                return POwner->SpellContainer->GetStormDay();
            }
            else if (action.select == G_SELECT::HELIX_DAY)
            {
                return POwner->SpellContainer->GetHelixDay();
            }
            else if (action.select == G_SELECT::EN_MOB_WEAKNESS)
            {
                CBattleEntity* battleTarget = POwner->GetBattleTarget();
                return POwner->SpellContainer->EnSpellAgainstTargetWeakness(battleTarget);
            }
            else if (action.select == G_SELECT::STORM_MOB_WEAKNESS)
            {
                return POwner->SpellContainer->StormDayAgainstTargetWeakness(resolvedTarget);
            }
            else if (action.select == G_SELECT::HELIX_MOB_WEAKNESS)
            {
                return POwner->SpellContainer->HelixAgainstTargetWeakness(resolvedTarget);
            }
            else if (action.select == G_SELECT::RANDOM)
            {
                return POwner->SpellContainer->GetSpell();
            }
            else if (action.select == G_SELECT::MB_ELEMENT)
            {
                // XI: Forever Offline (job expansion): the burst element, tier and timing are chosen from the real
                // skillchain effect: see BestBurstSpell. Nothing is cast when no spell can land inside the window.
                return BestBurstSpell(resolvedTarget);
            }

            return std::nullopt;
        };

        // First pass: validate availability and prevent executing multiple spells in the same tick.
        int firstMAIndex = -1;
        for (size_t i = 0; i < gambit.actions.size(); ++i)
        {
            const auto& action = gambit.actions[i];
            if (action.reaction == G_REACTION::MA)
            {
                if (firstMAIndex == -1)
                {
                    firstMAIndex    = static_cast<int>(i);
                    auto maybeSpell = ResolveMA(action, target);
                    if (!maybeSpell.has_value())
                    {
                        // Couldn't resolve first spell -> cannot use this gambit now
                        canExecute[i] = false;
                    }
                    else
                    {
                        resolvedSpells[i] = maybeSpell;
                    }
                }
                else
                {
                    // More than one spell present: skip additional spells to avoid casting two spells in a row.
                    canExecute[i] = false;
                }
            }
            else if (action.reaction == G_REACTION::JA)
            {
                // Basic validation: SPECIFIC must exist
                if (action.select == G_SELECT::SPECIFIC)
                {
                    if (ability::GetAbility(action.select_arg) == nullptr)
                    {
                        canExecute[i] = false;
                    }
                }
                // Other JA selects rely on TP checks; allow for now.
            }
            else if (action.reaction == G_REACTION::MS)
            {
                if (action.select == G_SELECT::SPECIFIC)
                {
                    // No further pre-check available here; assume ok.
                }
            }
            else if (action.reaction == G_REACTION::RATTACK)
            {
                // Always available
            }
        }

        // If none of the actions are executable, skip this gambit
        bool anyExecutable = std::ranges::any_of(canExecute, [](bool v)
                                                 {
                                                     return v;
                                                 });
        if (!anyExecutable)
        {
            continue;
        }

        // Execute actions that passed the pre-checks. Use resolvedSpells for spells where available.
        // XI: Forever Offline: an action counts as executed only when the controller started it (Cast/Ability/MobSkill
        // returned true; RangedAttack: its own delay passed). A refused action no longer starts the rule's retry timer.
        bool executedAnyAction = false;
        for (size_t i = 0; i < gambit.actions.size(); ++i)
        {
            if (!canExecute[i])
            {
                continue;
            }

            const auto& action = gambit.actions[i];

            if (action.reaction == G_REACTION::RATTACK)
            {
                executedAnyAction = controller->RangedAttack(target->entityId()) || executedAnyAction;
            }
            else if (action.reaction == G_REACTION::MA)
            {
                // Use the pre resolved spell if present, otherwise fall back
                if (resolvedSpells[i].has_value())
                {
                    executedAnyAction = controller->Cast(target->entityId(), resolvedSpells[i].value()) || executedAnyAction;
                }
                else
                {
                    // Fallback to original, keeps existing behavior for selection
                    if (action.select == G_SELECT::SPECIFIC)
                    {
                        auto spell_id = POwner->SpellContainer->GetAvailable(static_cast<SpellID>(action.select_arg));
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::HIGHEST)
                    {
                        auto spell_id = POwner->SpellContainer->GetBestAvailable(static_cast<SPELLFAMILY>(action.select_arg));
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::BEST_INDI)
                    {
                        auto* PMaster  = static_cast<CCharEntity*>(POwner->PMaster);
                        auto  spell_id = POwner->SpellContainer->GetBestIndiSpell(PMaster);
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::ENTRUSTED)
                    {
                        auto* PMaster  = static_cast<CCharEntity*>(POwner->PMaster);
                        auto  spell_id = POwner->SpellContainer->GetBestEntrustedSpell(PMaster);
                        target         = PMaster;
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::BEST_AGAINST_TARGET)
                    {
                        auto spell_to_cast = static_cast<SpellID>(action.select_arg);
                        auto spell_id      = POwner->SpellContainer->GetBestAgainstTargetWeakness(target, spell_to_cast);
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::DEF_BAR_ELEMENT)
                    {
                        auto maybeSpellId = POwner->SpellContainer->GetAvailable(SpellID::Barfire);
                        auto element      = POwner->GetLocalVar("[Gambit]CastElement");

                        if (element != 0)
                        {
                            switch (element)
                            {
                                case ELEMENT_FIRE:
                                    maybeSpellId = SpellID::Barfire;
                                    break;
                                case ELEMENT_ICE:
                                    maybeSpellId = SpellID::Barblizzard;
                                    break;
                                case ELEMENT_WIND:
                                    maybeSpellId = SpellID::Baraero;
                                    break;
                                case ELEMENT_EARTH:
                                    maybeSpellId = SpellID::Barstone;
                                    break;
                                case ELEMENT_THUNDER:
                                    maybeSpellId = SpellID::Barthunder;
                                    break;
                                case ELEMENT_WATER:
                                    maybeSpellId = SpellID::Barwater;
                                    break;
                                default:
                                    break;
                            }

                            if (maybeSpellId.has_value())
                            {
                                executedAnyAction = controller->Cast(target->entityId(), maybeSpellId.value()) || executedAnyAction;
                            }
                        }
                    }
                    else if (action.select == G_SELECT::STORM_DAY)
                    {
                        auto spell_id = POwner->SpellContainer->GetStormDay();
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::HELIX_DAY)
                    {
                        auto spell_id = POwner->SpellContainer->GetHelixDay();
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::EN_MOB_WEAKNESS)
                    {
                        CBattleEntity* battleTarget = POwner->GetBattleTarget();
                        auto           spell_id     = POwner->SpellContainer->EnSpellAgainstTargetWeakness(battleTarget);
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(POwner->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::STORM_MOB_WEAKNESS)
                    {
                        auto spell_id = POwner->SpellContainer->StormDayAgainstTargetWeakness(target);
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(POwner->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::HELIX_MOB_WEAKNESS)
                    {
                        auto spell_id = POwner->SpellContainer->HelixAgainstTargetWeakness(target);
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::RANDOM)
                    {
                        auto spell_id = POwner->SpellContainer->GetSpell();
                        if (spell_id.has_value())
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                    else if (action.select == G_SELECT::MB_ELEMENT)
                    {
                        // (not reached: ResolveMA already chose the burst; kept to the same choice for safety)
                        if (auto spell_id = BestBurstSpell(target))
                        {
                            executedAnyAction = controller->Cast(target->entityId(), spell_id.value()) || executedAnyAction;
                        }
                    }
                }
            }
            else if (action.reaction == G_REACTION::JA)
            {
                auto* PAbility = ability::GetAbility(action.select_arg);
                if (PAbility == nullptr)
                {
                    // If SPECIFIC was validated earlier this shouldn't happen; skip this action.
                    continue;
                }

                auto mLevel = POwner->GetMLevel();

                if (action.select == G_SELECT::HIGHEST_WALTZ)
                {
                    auto currentTP = POwner->health.tp;

                    // clang-format off
                        ABILITY wlist[5] =
                        {
                            ABILITY_CURING_WALTZ_V,
                            ABILITY_CURING_WALTZ_IV,
                            ABILITY_CURING_WALTZ_III,
                            ABILITY_CURING_WALTZ_II,
                            ABILITY_CURING_WALTZ,
                        };
                    // clang-format on

                    for (const auto& waltzId : wlist)
                    {
                        auto* PWaltzAbility = ability::GetAbility(waltzId);
                        if (PWaltzAbility == nullptr)
                        {
                            continue;
                        }

                        auto   waltzLevel = PWaltzAbility->getLevel();
                        uint16 tpCost     = 0;

                        if (mLevel >= waltzLevel)
                        {
                            switch (PWaltzAbility->getID())
                            {
                                case ABILITY_CURING_WALTZ_V:
                                    tpCost = 800;
                                    break;
                                case ABILITY_CURING_WALTZ_IV:
                                    tpCost = 650;
                                    break;
                                case ABILITY_CURING_WALTZ_III:
                                    tpCost = 500;
                                    break;
                                case ABILITY_CURING_WALTZ_II:
                                    tpCost = 350;
                                    break;
                                case ABILITY_CURING_WALTZ:
                                    tpCost = 200;
                                    break;
                                default:
                                    break;
                            }

                            if (tpCost != 0 && currentTP >= tpCost)
                            {
                                PAbility = PWaltzAbility;
                                executedAnyAction = controller->Ability(target->entityId(), PAbility->getID()) || executedAnyAction;
                            }
                        }
                    }
                }

                // XI: Forever Offline: an ability that can only be used on allies (no enemy flag, e.g. Cover: party) goes to the
                // rule's own target (MASTER, PARTY, TANK ...); before, every non-self ability went to the enemy and such a rule
                // could never work. Self-only abilities go to the mate, enemy abilities (Provoke, Shield Bash) to the enemy, as before.
                const auto validTargets = PAbility->getValidTarget();
                if (validTargets == TARGET_SELF)
                {
                    target = POwner;
                }
                else if ((validTargets & TARGET_ENEMY) == 0 &&
                         (validTargets & (TARGET_PLAYER_PARTY | TARGET_PLAYER_ALLIANCE | TARGET_PLAYER | TARGET_NPC)) != 0 && target != nullptr &&
                         target->objtype != TYPE_MOB)
                {
                    // keep the rule's resolved target (the ability's own target check refuses a wrong one)
                }
                else
                {
                    target = POwner->GetBattleTarget();
                }

                if (action.select == G_SELECT::SPECIFIC)
                {
                    // XI: Forever Offline (job expansion): a squad thief whose Rule Set uses Sneak Attack / Trick Attack
                    // (squad.lua sets SQUAD_SATA_MANAGED). The rule decides WHEN; the squad moves the thief into place
                    // (squadThiefTick -> SQUAD_FLANK) and says when the position is right (SQUAD_SATA_READY = the ability).
                    // Until then the ability is only requested, not used (not executed: no retry timer).
                    const auto abilityId = PAbility->getID();
                    if ((abilityId == ABILITY_SNEAK_ATTACK || abilityId == ABILITY_TRICK_ATTACK) && POwner->GetLocalVar("SQUAD_SATA_MANAGED") != 0 &&
                        POwner->GetLocalVar("SQUAD_SATA_READY") != abilityId)
                    {
                        // (on recast: nothing to prepare - no request, so the thief does not move for it. Trust recasts are
                        //  kept by ability id, CBattleEntity::OnAbility.)
                        if (POwner->PRecastContainer->HasRecast(xi::RecastType::Ability, static_cast<xi::Recast>(abilityId), 0s))
                        {
                            continue;
                        }

                        if (POwner->GetLocalVar("SQUAD_SATA_REQ") != abilityId)
                        {
                            POwner->SetLocalVar("SQUAD_SATA_REQ", abilityId);
                            POwner->SetLocalVar("SQUAD_SATA_REQ_AT", nowSeconds());
                        }
                        continue;
                    }

                    if (target != nullptr)
                    {
                        executedAnyAction = controller->Ability(target->entityId(), PAbility->getID()) || executedAnyAction;
                    }
                }

                if (action.select == G_SELECT::BEST_SAMBA)
                {
                    auto   currentTP = POwner->health.tp;
                    uint16 tpCost    = 0;

                    if (mLevel >= 5)
                    {
                        if (mLevel > 65)
                        {
                            if (PartyHasHealer())
                            {
                                if (auto* PSambaAbility = ability::GetAbility(ABILITY_HASTE_SAMBA))
                                {
                                    PAbility = PSambaAbility;
                                    tpCost   = 350;
                                }
                            }
                            else
                            {
                                if (auto* PSambaAbility = ability::GetAbility(ABILITY_DRAIN_SAMBA_III))
                                {
                                    PAbility = PSambaAbility;
                                    tpCost   = 400;
                                }
                            }
                        }
                        else if (mLevel < 65 && mLevel > 45)
                        {
                            if (PartyHasHealer())
                            {
                                if (auto* PSambaAbility = ability::GetAbility(ABILITY_HASTE_SAMBA))
                                {
                                    PAbility = PSambaAbility;
                                    tpCost   = 350;
                                }
                            }
                            else
                            {
                                if (auto* PSambaAbility = ability::GetAbility(ABILITY_DRAIN_SAMBA_II))
                                {
                                    PAbility = PSambaAbility;
                                    tpCost   = 250;
                                }
                            }
                        }
                        else if (mLevel < 45 && mLevel > 35)
                        {
                            if (auto* PSambaAbility = ability::GetAbility(ABILITY_DRAIN_SAMBA_II))
                            {
                                PAbility = PSambaAbility;
                                tpCost   = 250;
                            }
                        }
                        else
                        {
                            if (auto* PSambaAbility = ability::GetAbility(ABILITY_DRAIN_SAMBA))
                            {
                                PAbility = PSambaAbility;
                                tpCost   = 100;
                            }
                        }
                    }

                    if (tpCost != 0 && (currentTP >= tpCost))
                    {
                        executedAnyAction = controller->Ability(target->entityId(), PAbility->getID()) || executedAnyAction;
                    }
                }
                else if (action.select == G_SELECT::RUNE_DAY)
                {
                    uint32 localVarElement = POwner->GetLocalVar("[Gambit]CastElement");
                    uint32 element         = battleutils::GetDayElement();
                    auto   ability         = ABILITY_IGNIS;

                    if (localVarElement > 0)
                    {
                        element = localVarElement;
                    }

                    switch (element)
                    {
                        case ELEMENT_FIRE:
                            ability = ABILITY_UNDA;
                            break;
                        case ELEMENT_ICE:
                            ability = ABILITY_IGNIS;
                            break;
                        case ELEMENT_WIND:
                            ability = ABILITY_GELUS;
                            break;
                        case ELEMENT_EARTH:
                            ability = ABILITY_FLABRA;
                            break;
                        case ELEMENT_THUNDER:
                            ability = ABILITY_TELLUS;
                            break;
                        case ELEMENT_WATER:
                            ability = ABILITY_SULPOR;
                            break;
                        case ELEMENT_LIGHT:
                            ability = ABILITY_TENEBRAE;
                            break;
                        case ELEMENT_DARK:
                            ability = ABILITY_LUX;
                            break;
                        default:
                            ability = ABILITY_IGNIS;
                            break;
                    }
                    executedAnyAction = controller->Ability(target->entityId(), ability) || executedAnyAction;
                }
            }
            else if (action.reaction == G_REACTION::MS)
            {
                if (action.select == G_SELECT::SPECIFIC)
                {
                    executedAnyAction = controller->MobSkill(target->entityId(), action.select_arg, std::nullopt) || executedAnyAction;
                }
            }
            else if (action.reaction == G_REACTION::ANIM_STRING)
            {
                static constexpr std::array<const char*, 5> animationList = {
                    "sp00",
                    "sp10",
                    "sp20",
                    "sp30",
                    "sp40"
                };

                if (POwner->loc.zone == nullptr || !POwner->PMaster || POwner->PAI->PathFind->IsFollowingPath())
                {
                    continue;
                }

                if (action.select == G_SELECT::RANDOM_ANIMATION)
                {
                    // action.select_arg is the number of animations to include from the animationList.
                    // Clamp to [1, animationList.size()].
                    size_t usableCount = static_cast<size_t>(action.select_arg);
                    usableCount        = std::clamp<size_t>(usableCount, 1, animationList.size());

                    const auto  randomIndex = xirand::GetRandomNumber<size_t>(0, usableCount);
                    const auto* animString  = animationList[randomIndex];

                    POwner->loc.zone->PushPacket(
                        POwner,
                        CHAR_INRANGE,
                        std::make_unique<GP_SERV_COMMAND_SCHEDULOR>(POwner, target, animString));

                    executedAnyAction = true;
                }
                else if (action.select == G_SELECT::SPECIFIC)
                {
                    size_t animIndex = static_cast<size_t>(action.select_arg);

                    if (animIndex >= animationList.size())
                    {
                        animIndex = xirand::GetRandomNumber<size_t>(0, 3);
                    }

                    const auto* animString = animationList[animIndex];

                    POwner->loc.zone->PushPacket(
                        POwner,
                        CHAR_INRANGE,
                        std::make_unique<GP_SERV_COMMAND_SCHEDULOR>(POwner, target, animString));

                    executedAnyAction = true;
                }
            }
        }

        // If we executed any action and the gambit has a retry_delay, set last_used
        if (executedAnyAction && gambit.retry_delay != 0)
        {
            gambit.last_used = tick;
        }
    }
}

auto CGambitsContainer::CheckTrigger(const CBattleEntity* triggerTarget, const Gambit_t& gambit, size_t predicateGroupIndex, PredicateGroup_t& predicateGroup) -> bool
{
    TracyZoneScoped;

    if (triggerTarget == nullptr)
    {
        return false;
    }

    auto*             controller = static_cast<CTrustController*>(POwner->PAI->GetController());
    std::vector<bool> predicateResults;

    // Iterate and collect results from all predicates in the group
    for (size_t predicateIndex = 0; predicateIndex < predicateGroup.predicates.size(); ++predicateIndex)
    {
        auto& predicate = predicateGroup.predicates[predicateIndex];
        switch (predicate.condition)
        {
            case G_CONDITION::ALWAYS:
            {
                predicateResults.push_back(true);
                continue;
            }
            case G_CONDITION::HPP_LT:
            {
                predicateResults.push_back(triggerTarget->GetHPP() < predicate.condition_arg);
                continue;
            }
            case G_CONDITION::HPP_GTE:
            {
                predicateResults.push_back(triggerTarget->GetHPP() >= predicate.condition_arg);
                continue;
            }
            case G_CONDITION::MPP_LT:
            {
                predicateResults.push_back(triggerTarget->GetMPP() < predicate.condition_arg);
                continue;
            }
            case G_CONDITION::MPP_GTE:
            {
                predicateResults.push_back(triggerTarget->GetMPP() >= predicate.condition_arg);
                continue;
            }
            case G_CONDITION::TP_LT:
            {
                predicateResults.push_back(triggerTarget->health.tp < (int16)predicate.condition_arg);
                continue;
            }
            case G_CONDITION::TP_GTE:
            {
                predicateResults.push_back(triggerTarget->health.tp >= (int16)predicate.condition_arg);
                continue;
            }
            case G_CONDITION::STATUS:
            {
                predicateResults.push_back(HasStatusEffectTier(triggerTarget, predicate.condition_arg));
                continue;
            }
            case G_CONDITION::NOT_STATUS:
            {
                predicateResults.push_back(!HasStatusEffectTier(triggerTarget, predicate.condition_arg));
                continue;
            }
            case G_CONDITION::TIMER:
            {
                if (predicate.condition_arg == 0)
                {
                    predicateResults.push_back(true);
                    continue;
                }

                const auto key      = fmt::format("{}:{}:{}", gambit.identifier, predicateGroupIndex, predicateIndex);
                const auto interval = std::chrono::seconds(predicate.condition_arg);
                const auto now      = timer::now();

                auto [it, inserted] = m_timerConditionLastTrigger.try_emplace(key, now);

                if (inserted)
                {
                    // first evaluation is true, then gated by interval
                    predicateResults.push_back(true);
                }
                else if (now - it->second >= interval)
                {
                    it->second = now;
                    predicateResults.push_back(true);
                }
                else
                {
                    predicateResults.push_back(false);
                }
                continue;
            }
            case G_CONDITION::JA_ON_COOLDOWN:
            {
                // XI: Forever Offline: true while the mate cannot use that ability yet because of its recast. Before, this
                // tested the ability's fixed recast time (always true for any ability with a recast) and crashed on an
                // unknown id. (squad audit N5) It asks IsAbilityOnRecast, the check CTrustController::Ability uses: the
                // ability's own recast for every trust and, for a squad mate, also a player's shared recast group and
                // charges (one Phantom Roll puts every roll on cooldown; Quick Draw only with no charge left).
                const auto* PAbility = predicate.condition_arg != 0 ? ability::GetAbility(static_cast<ABILITY>(predicate.condition_arg)) : nullptr;
                predicateResults.push_back(PAbility != nullptr && POwner->PRecastContainer != nullptr &&
                                           POwner->IsAbilityOnRecast(const_cast<CAbility*>(PAbility)));
                continue;
            }
            case G_CONDITION::HAS_MP:
            {
                predicateResults.push_back(triggerTarget->GetMaxMP() > 0);
                continue;
            }
            case G_CONDITION::HAS_MP_MPP_LT:
            {
                predicateResults.push_back(triggerTarget->GetMaxMP() > 0 && triggerTarget->GetMPP() < predicate.condition_arg);
                continue;
            }
            case G_CONDITION::HAS_MP_MPP_GTE:
            {
                predicateResults.push_back(triggerTarget->GetMaxMP() > 0 && triggerTarget->GetMPP() >= predicate.condition_arg);
                continue;
            }
            case G_CONDITION::MOD_LT:
            {
                // XI: Forever Offline (job expansion): e.g. Utsusemi shadows left (Mod::UTSUSEMI counts them down as they
                // absorb hits; the Copy Image effect's power does not change), Blink images (Mod::BLINK)
                const auto mod   = static_cast<xi::Mod>(predicate.condition_arg & 0xFFFF);
                const auto below = static_cast<int32>(predicate.condition_arg >> 16);
                predicateResults.push_back(triggerTarget->getMod(mod) < below);
                continue;
            }
            case G_CONDITION::LVL_LT:
            {
                predicateResults.push_back(triggerTarget->GetMLevel() < predicate.condition_arg);
                continue;
            }
            case G_CONDITION::LVL_GTE:
            {
                predicateResults.push_back(triggerTarget->GetMLevel() >= predicate.condition_arg);
                continue;
            }
            case G_CONDITION::HAS_RUNES:
            {
                bool hasRunes = !triggerTarget->StatusEffectContainer->GetAllRuneEffects().empty();
                predicateResults.push_back(hasRunes);
                continue;
            }
            case G_CONDITION::NO_MAX_RUNE:
            {
                auto maxRuneEffect = 1;
                bool canUseRunes   = true;

                if (POwner->GetMJob() == xi::Job::RUN)
                {
                    if (POwner->GetMLevel() >= 65)
                    {
                        maxRuneEffect = 3;
                    }
                    else if (POwner->GetMLevel() >= 35)
                    {
                        maxRuneEffect = 2;
                    }
                }

                if (triggerTarget->StatusEffectContainer->GetAllRuneEffects().size() >= maxRuneEffect)
                {
                    canUseRunes = false;
                }

                predicateResults.push_back(canUseRunes);
                continue;
            }
            case G_CONDITION::NO_SAMBA:
            {
                bool noSamba = true;
                if (triggerTarget->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::DrainSamba) ||
                    triggerTarget->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::HasteSamba))
                {
                    noSamba = false;
                }
                predicateResults.push_back(noSamba);
                continue;
            }
            case G_CONDITION::NO_STORM:
            {
                bool noStorm = true;
                // clang-format off
                    if (triggerTarget->StatusEffectContainer->HasStatusEffect(
                    {
                        xi::StatusEffect::Firestorm,
                        xi::StatusEffect::Hailstorm,
                        xi::StatusEffect::Windstorm,
                        xi::StatusEffect::Sandstorm,
                        xi::StatusEffect::Thunderstorm,
                        xi::StatusEffect::Rainstorm,
                        xi::StatusEffect::Aurorastorm,
                        xi::StatusEffect::Voidstorm,
                        xi::StatusEffect::FirestormIi,
                        xi::StatusEffect::HailstormIi,
                        xi::StatusEffect::WindstormIi,
                        xi::StatusEffect::SandstormIi,
                        xi::StatusEffect::ThunderstormIi,
                        xi::StatusEffect::RainstormIi,
                        xi::StatusEffect::AurorastormIi,
                        xi::StatusEffect::VoidstormIi,
                    }))
                    {
                        noStorm = false;
                    }
                // clang-format on
                predicateResults.push_back(noStorm);
                continue;
            }
            case G_CONDITION::PT_HAS_TANK:
            {
                predicateResults.push_back(PartyHasTank());
                continue;
            }
            case G_CONDITION::NOT_PT_HAS_TANK:
            {
                predicateResults.push_back(!PartyHasTank());
                continue;
            }
            case G_CONDITION::STATUS_FLAG:
            {
                predicateResults.push_back(triggerTarget->StatusEffectContainer->HasStatusEffectByFlag(static_cast<xi::StatusEffectFlag>(predicate.condition_arg)));
                continue;
            }
            case G_CONDITION::HAS_TOP_ENMITY:
            {
                predicateResults.push_back((controller->GetTopEnmity()) ? controller->GetTopEnmity()->targid == POwner->targid : false);
                continue;
            }
            case G_CONDITION::NOT_HAS_TOP_ENMITY:
            {
                predicateResults.push_back((controller->GetTopEnmity()) ? controller->GetTopEnmity()->targid != POwner->targid : false);
                continue;
            }
            case G_CONDITION::SC_AVAILABLE:
            {
                auto* PSCEffect = triggerTarget->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);
                predicateResults.push_back(PSCEffect && PSCEffect->GetStartTime() + 3s < timer::now() && PSCEffect->GetTier() == 0);
                continue;
            }
            case G_CONDITION::NOT_SC_AVAILABLE:
            {
                auto* PSCEffect = triggerTarget->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);
                predicateResults.push_back(PSCEffect == nullptr);
                continue;
            }
            case G_CONDITION::MB_AVAILABLE:
            {
                // XI: Forever Offline (job expansion): a formed skillchain, after a short reaction (was 3 s, the weapon
                // skill chaining rule; a burst has no such wait)
                auto* PSCEffect = triggerTarget->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);
                predicateResults.push_back(PSCEffect && PSCEffect->GetStartTime() + MagicBurstReaction < timer::now() && PSCEffect->GetTier() > 0);
                continue;
            }
            case G_CONDITION::LUNGE_MB_AVAILABLE:
            {
                auto* PSCEffect     = triggerTarget->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);
                bool  maybeUseLunge = false;

                if (PSCEffect && PSCEffect->GetStartTime() + MagicBurstReaction < timer::now() && PSCEffect->GetTier() > 0)
                {
                    xi::SkillchainType sc = static_cast<xi::SkillchainType>(PSCEffect->GetPower());

                    if (sc != xi::SkillchainType::None)
                    {
                        // Only consider tier 3 or 4 skillchains (Light/Dark are tier 3/4)
                        const auto tier = battleutils::GetSkillchainTier(sc);
                        if (tier >= 3)
                        {
                            // Match Light/Dark enums (covers Light, Light II, Darkness, Darkness II)
                            if (sc == xi::SkillchainType::Light || sc == xi::SkillchainType::LightIi)
                            {
                                if (POwner->StatusEffectContainer->HasStatusEffect(
                                        {
                                            xi::StatusEffect::Lux,
                                            xi::StatusEffect::Ignis,
                                            xi::StatusEffect::Flabra,
                                            xi::StatusEffect::Sulpor,
                                        }))
                                {
                                    maybeUseLunge = true;
                                }
                            }
                            else if (sc == xi::SkillchainType::Darkness || sc == xi::SkillchainType::DarknessIi)
                            {
                                if (POwner->StatusEffectContainer->HasStatusEffect(
                                        {
                                            xi::StatusEffect::Tenebrae,
                                            xi::StatusEffect::Tellus,
                                            xi::StatusEffect::Unda,
                                            xi::StatusEffect::Gelus,
                                        }))
                                {
                                    maybeUseLunge = true;
                                }
                            }
                        }
                    }
                }

                predicateResults.push_back(maybeUseLunge);
                continue;
            }
            case G_CONDITION::READYING_WS:
            {
                predicateResults.push_back(triggerTarget->PAI->IsCurrentState<CWeaponSkillState>());
                continue;
            }
            case G_CONDITION::READYING_MS:
            {
                predicateResults.push_back(triggerTarget->PAI->IsCurrentState<CMobSkillState>());
                continue;
            }
            case G_CONDITION::READYING_JA:
            {
                predicateResults.push_back(triggerTarget->PAI->IsCurrentState<CAbilityState>());
                continue;
            }
            case G_CONDITION::CASTING_MA:
            {
                predicateResults.push_back(triggerTarget->PAI->IsCurrentState<CMagicState>());
                continue;
            }
            case G_CONDITION::CASTING_DEBUFF:
            {
                // Check if the target is currently casting a debuff magic spell
                bool isDebuff = false;
                if (triggerTarget->PAI->IsCurrentState<CMagicState>())
                {
                    auto spell = static_cast<CMagicState*>(triggerTarget->PAI->GetCurrentState())->GetSpell();

                    if (spell->isDebuff())
                    {
                        isDebuff = true;
                    }
                }
                predicateResults.push_back(isDebuff);
                continue;
            }
            case G_CONDITION::CASTING_ELE_MA_AOE:
            {
                bool isAOE = false;
                if (triggerTarget->PAI->IsCurrentState<CMagicState>())
                {
                    auto spellElement  = static_cast<CMagicState*>(triggerTarget->PAI->GetCurrentState())->GetSpell()->getElement();
                    auto isElementalMA = spellElement >= ELEMENT_FIRE && spellElement <= ELEMENT_WATER;
                    auto spellAOEType  = static_cast<CMagicState*>(triggerTarget->PAI->GetCurrentState())->GetSpell()->getAOE();
                    if (isElementalMA && spellAOEType == SPELLAOE_RADIAL)
                    {
                        isAOE = true;
                    }
                }
                predicateResults.push_back(isAOE);
                continue;
            }
            case G_CONDITION::CASTING_ELEMENT_MA:
            {
                bool isElementalMA = false;
                if (triggerTarget->PAI->IsCurrentState<CMagicState>())
                {
                    auto spellElement = static_cast<CMagicState*>(triggerTarget->PAI->GetCurrentState())->GetSpell()->getElement();
                    isElementalMA     = spellElement >= ELEMENT_FIRE && spellElement <= ELEMENT_WATER;
                }
                predicateResults.push_back(isElementalMA);
                continue;
            }
            case G_CONDITION::CAST_ELE_MA_SELF:
            {
                bool isElementalMAOnSelf = false;
                if (triggerTarget->PAI->IsCurrentState<CMagicState>())
                {
                    const auto* PState        = static_cast<CMagicState*>(triggerTarget->PAI->GetCurrentState());
                    const auto  spellElement  = PState->GetSpell()->getElement();
                    const auto  isElementalMA = spellElement >= ELEMENT_FIRE && spellElement <= ELEMENT_WATER;
                    if (PState->target() == POwner && isElementalMA)
                    {
                        isElementalMAOnSelf = true;
                    }
                }
                predicateResults.push_back(isElementalMAOnSelf);
                continue;
            }
            case G_CONDITION::NEED_ELE_BAREFFECT:
            {
                bool needBarEffect = false;
                if (triggerTarget->PAI->IsCurrentState<CMagicState>())
                {
                    auto spellElement = static_cast<CMagicState*>(triggerTarget->PAI->GetCurrentState())->GetSpell()->getElement();

                    switch (spellElement)
                    {
                        case ELEMENT_FIRE:
                            needBarEffect = !POwner->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Barfire);
                            break;
                        case ELEMENT_ICE:
                            needBarEffect = !POwner->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Barblizzard);
                            break;
                        case ELEMENT_WIND:
                            needBarEffect = !POwner->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Baraero);
                            break;
                        case ELEMENT_EARTH:
                            needBarEffect = !POwner->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Barstone);
                            break;
                        case ELEMENT_THUNDER:
                            needBarEffect = !POwner->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Barthunder);
                            break;
                        case ELEMENT_WATER:
                            needBarEffect = !POwner->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Barwater);
                            break;
                        default:
                            needBarEffect = false;
                            spellElement  = (uint16)battleutils::GetDayElement();
                            break;
                    }
                    POwner->SetLocalVar("[Gambit]CastElement", spellElement);
                }
                predicateResults.push_back(needBarEffect);
                continue;
            }
            case G_CONDITION::IS_ECOSYSTEM:
            {
                predicateResults.push_back(triggerTarget->m_EcoSystem == static_cast<xi::Ecosystem>(predicate.condition_arg));
                continue;
            }
            case G_CONDITION::RANDOM:
            {
                predicateResults.push_back(xirand::GetRandomNumber<uint16>(100) < (int16)predicate.condition_arg);
                continue;
            }
            case G_CONDITION::HP_MISSING:
            {
                predicateResults.push_back((triggerTarget->health.maxhp - triggerTarget->health.hp) >= (int16)predicate.condition_arg);
                continue;
            }
            case G_CONDITION::SUB_ANIMATION:
            {
                predicateResults.push_back(triggerTarget->animationsub == predicate.condition_arg);
                continue;
            }
            case G_CONDITION::VAL_URIEL_CHECK:
            {
                bool  canUseUriel = false;
                auto* PMaster     = dynamic_cast<CCharEntity*>(POwner->PMaster);
                auto* PMob        = dynamic_cast<CMobEntity*>(PMaster->GetBattleTarget());

                if (PMob != nullptr && PMob->PEnmityContainer != nullptr)
                {
                    bool masterHasEnmity         = PMob->PEnmityContainer->HasID(PMaster->id);
                    bool valHasEnmity            = PMob->PEnmityContainer->HasID(POwner->id);
                    bool valHasTopEnmity         = (controller->GetTopEnmity()) ? controller->GetTopEnmity()->targid == POwner->targid : false;
                    bool masterHasOffTargetAggro = false;

                    if (PMaster->PNotorietyContainer != nullptr && PMaster->PNotorietyContainer->hasEnmity())
                    {
                        for (auto it = PMaster->PNotorietyContainer->begin(); it != PMaster->PNotorietyContainer->end(); ++it)
                        {
                            if (masterHasOffTargetAggro)
                            {
                                break;
                            }

                            auto* PZoneMob = dynamic_cast<CMobEntity*>(*it);
                            if (!PZoneMob || !PZoneMob->isAlive())
                            {
                                continue;
                            }

                            if (distance(POwner->loc.p, PZoneMob->loc.p) > 10.0f)
                            {
                                continue;
                            }

                            const bool targetingMaster        = (PZoneMob->battleTarget() == PMaster);
                            const bool isMastersCurrentTarget = (PZoneMob->id == PMob->id);
                            const bool hostile                = (PZoneMob->allegiance != PMaster->allegiance);

                            if (targetingMaster && !isMastersCurrentTarget && hostile)
                            {
                                masterHasOffTargetAggro = true;
                            }
                        }
                    }

                    if ((masterHasEnmity && !valHasTopEnmity) || masterHasOffTargetAggro)
                    {
                        auto   timeNow          = std::chrono::system_clock::now();
                        uint32 lastUrielTime    = POwner->GetLocalVar("[Gambit]LastUrielTime");
                        auto   distanceToTarget = distance(POwner->loc.p, PMob->loc.p);

                        auto lastTimePoint = std::chrono::time_point<std::chrono::system_clock>(std::chrono::seconds(lastUrielTime));
                        auto timeDiff      = timeNow - lastTimePoint;
                        bool longCooldown  = (timeDiff >= std::chrono::seconds(30)); // Standard Cooldown
                        bool shortCooldown = (timeDiff >= std::chrono::seconds(5));  // New Target Cooldown

                        canUseUriel = (distanceToTarget <= 10.0f) &&
                                      ((valHasEnmity && longCooldown) || (!valHasEnmity && shortCooldown) || (masterHasOffTargetAggro && longCooldown));
                    }
                }
                predicateResults.push_back(canUseUriel);
                continue;
            }
            default:
            {
                predicateResults.push_back(false);
            }
        }
    }

    // Evaluate the group of predicates
    switch (predicateGroup.logic)
    {
        case G_LOGIC::AND:
        {
            return std::ranges::all_of(
                predicateResults,
                [](const bool result)
                {
                    return result;
                });
        }
        case G_LOGIC::OR:
        {
            return std::ranges::any_of(
                predicateResults,
                [](const bool result)
                {
                    return result;
                });
        }
        default:
            return false;
    }
}

auto CGambitsContainer::TryTrustSkill() -> bool
{
    TracyZoneScoped;

    auto* target = POwner->GetBattleTarget();

    if (!target)
    {
        return false;
    }

    // XI: Forever Offline (job expansion): a squad thief preparing Sneak Attack / Trick Attack keeps its TP for a moment
    if (HoldWeaponSkill(target))
    {
        return false;
    }

    // XI: Forever Offline: the Gambits weapon skill settings have their own path; the triggers above keep theirs unchanged
    if (tp_trigger >= G_TP_TRIGGER::OPEN_AT_TP && tp_trigger <= G_TP_TRIGGER::AT_TP)
    {
        return TrySettingsTrustSkill(target);
    }

    auto checkTPTrigger = [&]() -> bool
    {
        if (POwner->health.tp >= 3000)
        {
            return true;
        } // Go, go, go!

        switch (tp_trigger)
        {
            case G_TP_TRIGGER::ASAP:
            {
                return true;
            }
            case G_TP_TRIGGER::RANDOM:
            {
                bool result = false;
                // clang-format off
                if (tp_value <= 1000) // If the value provided by the script is missing or too low
                {
                    tp_value = 1000; // Apply the minimum TP Hold Threshold
                }
                if (POwner->health.tp >= tp_value && xirand::GetRandomNumber<uint16>(10000) < tp_value)
                {
                    result = true;
                }
                // clang-format on
                return result;
            }
            case G_TP_TRIGGER::OPENER:
            {
                bool result = false;
                // clang-format off
                static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
                {
                    if (tp_value <= 1000) // If the value provided by the script is missing or too low
                    {
                        tp_value = 1000; // Apply the minimum TP Hold Threshold
                    }
                    if (PMember->health.tp >= tp_value && PMember != POwner)
                    {
                        result = true;
                    }
                });
                // clang-format on
                return result;
            }
            case G_TP_TRIGGER::CLOSER: // Hold TP indefinitely to close a SC.
            {
                auto* PSCEffect = target->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);

                // TODO: ...and has a valid WS...

                return PSCEffect && PSCEffect->GetStartTime() + 3s < timer::now() && PSCEffect->GetTier() == 0;
            }
            case G_TP_TRIGGER::CLOSER_UNTIL_TP: // Will hold TP to close a SC, but WS immediately once specified value is reached.
            {
                if (tp_value <= 1500) // If the value provided by the script is missing or too low
                {
                    tp_value = 1500; // Apply the minimum TP Hold Threshold
                }
                if (POwner->health.tp >= tp_value) // tp_value reached
                {
                    return true; // Time to WS!
                }
                auto* PSCEffect = target->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);

                // TODO: ...and has a valid WS...

                return PSCEffect && PSCEffect->GetStartTime() + 3s < timer::now() && PSCEffect->GetTier() == 0;
            }
            default:
            {
                return false;
            }
        }
    };

    Maybe<TrustSkill_t> chosen_skill;
    xi::SkillchainType  chosen_skillchain = xi::SkillchainType::None;
    if (checkTPTrigger() && !tp_skills.empty())
    {
        switch (tp_select)
        {
            case G_SELECT::RANDOM:
            {
                auto* PSCEffect = target->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);

                if (!PSCEffect) // Opener, if no skillchain available select a random ws
                {
                    chosen_skill = xirand::GetRandomElement(tp_skills);
                    break;
                }

                // Closer, if a skillchain is available select a random ws that can close it, if multiple are available select the one that creates the best skillchain
                for (auto& skill : tp_skills)
                {
                    // XI: Forever Offline (job expansion): one type once a chain formed (Darkness II = 16 no longer splits)
                    std::list<xi::SkillchainType> resonanceProperties = resonanceOf(PSCEffect);

                    std::list<xi::SkillchainType> skillProperties;
                    skillProperties.emplace_back((xi::SkillchainType)skill.primary);
                    skillProperties.emplace_back((xi::SkillchainType)skill.secondary);
                    skillProperties.emplace_back((xi::SkillchainType)skill.tertiary);
                    if (xi::SkillchainType possible_skillchain = battleutils::FormSkillchain(resonanceProperties, skillProperties);
                        possible_skillchain != xi::SkillchainType::None)
                    {
                        if (possible_skillchain >= chosen_skillchain)
                        {
                            chosen_skill      = skill;
                            chosen_skillchain = possible_skillchain;
                        }
                    }
                }
                break;
            }
            case G_SELECT::HIGHEST: // Form the best possible skillchain
            {
                auto* PSCEffect = target->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);

                if (!PSCEffect) // Opener
                {
                    // TODO: This relies on the skills being passed in in some kind of correct order...
                    // Probably best to do this another way
                    chosen_skill = tp_skills.at(tp_skills.size() - 1);
                    break;
                }

                // Closer
                for (auto& skill : tp_skills)
                {
                    // XI: Forever Offline (job expansion): one type once a chain formed (Darkness II = 16 no longer splits)
                    std::list<xi::SkillchainType> resonanceProperties = resonanceOf(PSCEffect);

                    std::list<xi::SkillchainType> skillProperties;
                    skillProperties.emplace_back((xi::SkillchainType)skill.primary);
                    skillProperties.emplace_back((xi::SkillchainType)skill.secondary);
                    skillProperties.emplace_back((xi::SkillchainType)skill.tertiary);
                    if (xi::SkillchainType possible_skillchain = battleutils::FormSkillchain(resonanceProperties, skillProperties);
                        possible_skillchain != xi::SkillchainType::None)
                    {
                        if (possible_skillchain >= chosen_skillchain)
                        {
                            chosen_skill      = skill;
                            chosen_skillchain = possible_skillchain;
                        }
                    }
                }
                break;
            }
            case G_SELECT::SPECIAL_AYAME:
            {
                auto* PMaster                = static_cast<CCharEntity*>(POwner->PMaster);
                auto* PMasterController      = static_cast<CPlayerController*>(PMaster->PAI->GetController());
                auto* PMasterLastWeaponSkill = PMasterController->getLastWeaponSkill();

                if (PMasterLastWeaponSkill != nullptr)
                {
                    for (auto& skill : tp_skills)
                    {
                        std::list<xi::SkillchainType> resonanceProperties;
                        resonanceProperties.emplace_back((xi::SkillchainType)skill.primary);
                        resonanceProperties.emplace_back((xi::SkillchainType)skill.secondary);
                        resonanceProperties.emplace_back((xi::SkillchainType)skill.tertiary);

                        std::list<xi::SkillchainType> skillProperties;
                        skillProperties.emplace_back((xi::SkillchainType)PMasterLastWeaponSkill->getPrimarySkillchain());
                        skillProperties.emplace_back((xi::SkillchainType)PMasterLastWeaponSkill->getSecondarySkillchain());
                        skillProperties.emplace_back((xi::SkillchainType)PMasterLastWeaponSkill->getTertiarySkillchain());
                        if (xi::SkillchainType possible_skillchain = battleutils::FormSkillchain(resonanceProperties, skillProperties);
                            possible_skillchain != xi::SkillchainType::None)
                        {
                            if (possible_skillchain >= chosen_skillchain)
                            {
                                chosen_skill      = skill;
                                chosen_skillchain = possible_skillchain;
                            }
                        }
                    }
                }
                else
                {
                    chosen_skill = tp_skills.at(tp_skills.size() - 1);
                }

                break;
            }
            case G_SELECT::SPECIAL_AUGUST:
            {
                static const uint32                     NO_QUARTER  = 3658;
                static const std::unordered_set<uint32> daybreak_ws = { 3656, 3657 };
                static const std::unordered_set<uint32> regular_ws  = { 3653, 3654, 3655 };

                bool   maybeDaybreakActive = POwner->animationsub == 5; // Daybreak active is sub animation 5, retail does the same thing.
                uint32 lastSkillUsed       = POwner->GetLocalVar("[Gambit]LastDaybreakSkill");

                std::vector<TrustSkill_t> candidates;

                if (maybeDaybreakActive)
                {
                    // Only trigger No Quarter if the last skill used was ACTUALLY a Daybreak opener
                    if (daybreak_ws.contains(lastSkillUsed))
                    {
                        for (const auto& tskill : tp_skills)
                        {
                            if (tskill.skill_id == NO_QUARTER)
                            {
                                chosen_skill = tskill;
                                break;
                            }
                        }
                    }

                    // If we didn't pick No Quarter (either lastSkill was 0 or a regular skill)
                    if (!chosen_skill)
                    {
                        for (const auto& tskill : tp_skills)
                        {
                            if (daybreak_ws.contains(tskill.skill_id))
                            {
                                candidates.push_back(tskill);
                            }
                        }
                    }
                }
                else
                {
                    // Normal state: use standard rotation
                    for (const auto& tskill : tp_skills)
                    {
                        if (regular_ws.contains(tskill.skill_id))
                        {
                            candidates.push_back(tskill);
                        }
                    }
                    // Clear the localVar so the next Daybreak starts fresh
                    if (lastSkillUsed != 0)
                    {
                        POwner->SetLocalVar("[Gambit]LastDaybreakSkill", 0);
                    }
                }

                if (!candidates.empty() && !chosen_skill)
                {
                    chosen_skill = xirand::GetRandomElement(candidates);
                }

                // Only update the localVar if actually picked a skill
                applyTo(chosen_skill, [&](const TrustSkill_t& skill)
                        {
                            POwner->SetLocalVar("[Gambit]LastDaybreakSkill", skill.skill_id);
                        });

                break;
            }
            default:
            {
                break;
            }
        }
    }

    if (chosen_skill)
    {
        auto* controller = static_cast<CTrustController*>(POwner->PAI->GetController());
        if (chosen_skill->skill_type == G_REACTION::WS)
        {
            CWeaponSkill* PWeaponSkill = battleutils::GetWeaponSkill(chosen_skill->skill_id);
            if (PWeaponSkill == nullptr)
            {
                ShowError("G_REACTION::WS: PWeaponSkill was null.");
                return false;
            }

            if (chosen_skill->valid_targets & TARGET_SELF)
            {
                target = POwner;
            }
            else
            {
                target = POwner->GetBattleTarget();
                // XI: Forever Offline (beta polish): the weapon skill state spends the TP before CTrustEntity::OnWeaponSkillFinished
                // checks the range, so a weapon skill started too far away lost all TP. Wait (keep the TP) until in range.
                if (!InWeaponSkillRange(PWeaponSkill, target))
                {
                    return false;
                }
            }
            controller->WeaponSkill(target->entityId(), PWeaponSkill->getID());
        }
        else // Mobskill
        {
            if (chosen_skill->valid_targets & TARGET_SELF || chosen_skill->valid_targets & TARGET_PLAYER_PARTY)
            {
                target = POwner;
            }
            else
            {
                target = POwner->GetBattleTarget();
            }
            controller->MobSkill(target->entityId(), chosen_skill->skill_id, std::nullopt);
        }
        return true;
    }
    return false;
}

// XI: Forever Offline (beta polish): the range test CTrustEntity::OnWeaponSkillFinished applies after the TP is spent, used
// before the weapon skill starts so an out-of-range attempt keeps the TP instead of wasting it.
auto CGambitsContainer::InWeaponSkillRange(const CWeaponSkill* PWeaponSkill, const CBattleEntity* target) const -> bool
{
    if (PWeaponSkill == nullptr || target == nullptr)
    {
        return false;
    }

    return distance(POwner->loc.p, target->loc.p) <= PWeaponSkill->getRange() + target->modelHitboxSize + POwner->modelHitboxSize;
}

// XI: Forever Offline (Gambits weapon skill settings): is another party member ready to follow an opening weapon skill?
// Alive, in the same zone, within 20 yalms of the enemy, with at least 1000 TP, and - for a Trust or squad mate - with
// weapon skills and a TP setting that closes (not an opener: OPENER / OPEN_AT_TP; AT_TP only once its own threshold is
// reached). Players (and bots) count when they have the TP: they choose their own weapon skills.
auto CGambitsContainer::PotentialCloserReady(const CBattleEntity* target) const -> bool
{
    auto* PMaster = dynamic_cast<CCharEntity*>(POwner->PMaster);
    if (PMaster == nullptr || target == nullptr)
    {
        return false;
    }

    bool ready = false;
    // clang-format off
    PMaster->ForPartyWithTrusts([&](CBattleEntity* PMember)
    {
        if (ready || PMember == nullptr || PMember == POwner || !PMember->isAlive() || PMember->loc.zone != POwner->loc.zone ||
            PMember->health.tp < 1000 || distance(PMember->loc.p, target->loc.p) > 20.0f)
        {
            return;
        }

        if (PMember->objtype == TYPE_TRUST)
        {
            const auto* PController = dynamic_cast<CTrustController*>(PMember->PAI->GetController());
            if (PController == nullptr || PController->m_GambitsContainer == nullptr)
            {
                return;
            }

            const auto& other = *PController->m_GambitsContainer;
            if (other.tp_skills.empty() || other.tp_trigger == G_TP_TRIGGER::OPENER || other.tp_trigger == G_TP_TRIGGER::OPEN_AT_TP)
            {
                return;
            }

            if ((other.tp_trigger == G_TP_TRIGGER::AT_TP || other.tp_trigger == G_TP_TRIGGER::RANDOM) && PMember->health.tp < other.tp_value)
            {
                return;
            }
        }

        ready = true;
    });
    // clang-format on

    return ready;
}

// XI: Forever Offline (Gambits weapon skill settings): OPEN_AT_TP, CLOSE_ONLY, OPEN_CLOSE_AT_TP and AT_TP.
// "Window" = the engine's closing window (a skillchain effect older than 3 s, tier 0), the same test as CLOSER.
// Selection is the engine's HIGHEST: the closer that forms the best skillchain when the target has a skillchain effect,
// otherwise the last weapon skill of the list (the opening pick). tp_skills is already only the chosen weapon skill when
// the player chose one that the mate can use (squad.cpp limitWeaponSkills).
auto CGambitsContainer::TrySettingsTrustSkill(CBattleEntity* target) -> bool
{
    if (tp_skills.empty())
    {
        return false;
    }

    const auto  tp        = POwner->health.tp;
    const bool  forced    = tp >= 3000; // the engine's release: never hold TP at 3000
    const auto  threshold = std::clamp<uint16>(tp_value, 1000, 3000);
    auto*       PSCEffect = target->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);
    const bool  window    = PSCEffect != nullptr && PSCEffect->GetStartTime() + 3s < timer::now() && PSCEffect->GetTier() == 0;
    const auto  canOpen   = [&]()
    {
        return PSCEffect == nullptr && tp >= threshold && PotentialCloserReady(target);
    };

    bool fire          = false;
    bool allowFallback = false; // may use the opening pick when nothing closes
    switch (tp_trigger)
    {
        case G_TP_TRIGGER::OPEN_AT_TP:
            fire          = forced || canOpen();
            allowFallback = true;
            break;
        case G_TP_TRIGGER::CLOSE_ONLY:
            fire          = forced || window;
            allowFallback = forced;
            break;
        case G_TP_TRIGGER::OPEN_CLOSE_AT_TP:
            if (window)
            {
                fire          = true;
                allowFallback = forced;
            }
            else
            {
                fire          = forced || canOpen();
                allowFallback = true;
            }
            break;
        case G_TP_TRIGGER::AT_TP:
            fire          = forced || tp >= threshold;
            allowFallback = true;
            break;
        default:
            break;
    }

    if (!fire)
    {
        return false;
    }

    Maybe<TrustSkill_t> chosen_skill;
    if (PSCEffect != nullptr)
    {
        // XI: Forever Offline (job expansion): one type once a chain formed (Darkness II = 16 no longer splits)
        std::list<xi::SkillchainType> resonanceProperties = resonanceOf(PSCEffect);

        xi::SkillchainType chosen_skillchain = xi::SkillchainType::None;
        for (const auto& skill : tp_skills)
        {
            std::list<xi::SkillchainType> skillProperties;
            skillProperties.emplace_back((xi::SkillchainType)skill.primary);
            skillProperties.emplace_back((xi::SkillchainType)skill.secondary);
            skillProperties.emplace_back((xi::SkillchainType)skill.tertiary);
            if (xi::SkillchainType possible_skillchain = battleutils::FormSkillchain(resonanceProperties, skillProperties);
                possible_skillchain != xi::SkillchainType::None && possible_skillchain >= chosen_skillchain)
            {
                chosen_skill      = skill;
                chosen_skillchain = possible_skillchain;
            }
        }
    }

    if (!chosen_skill && allowFallback)
    {
        chosen_skill = tp_skills.back();
    }

    if (!chosen_skill || chosen_skill->skill_type != G_REACTION::WS)
    {
        return false;
    }

    CWeaponSkill* PWeaponSkill = battleutils::GetWeaponSkill(chosen_skill->skill_id);
    if (PWeaponSkill == nullptr)
    {
        return false;
    }

    auto* wsTarget = (chosen_skill->valid_targets & TARGET_SELF) ? static_cast<CBattleEntity*>(POwner) : target;
    if (wsTarget != POwner && !InWeaponSkillRange(PWeaponSkill, wsTarget))
    {
        return false; // too far: keep the TP and try again next tick (also at 3000 TP)
    }

    auto* controller = static_cast<CTrustController*>(POwner->PAI->GetController());
    return controller->WeaponSkill(wsTarget->entityId(), PWeaponSkill->getID());
}

// currently only used for Uka Totlihn to determin what samba to use.
auto CGambitsContainer::PartyHasHealer() -> bool
{
    bool hasHealer = false;
    // clang-format off
        static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
        {
            auto jobType = PMember->GetMJob();

            if (jobType == xi::Job::WHM || jobType == xi::Job::RDM || jobType == xi::Job::PLD || jobType == xi::Job::SCH)
            {
                hasHealer = true;
            }
        });
    // clang-format on
    return hasHealer;
}

// used to check for tanks in party (Volker, AA Hume)
auto CGambitsContainer::PartyHasTank() -> bool
{
    bool hasTank = false;
    // clang-format off
        static_cast<CCharEntity*>(POwner->PMaster)->ForPartyWithTrusts([&](CBattleEntity* PMember)
        {
            auto       jobType = PMember->GetMJob();
            const auto role    = squadRole(PMember); // XI: Forever Offline (job expansion): an explicit squad party role decides

            if (role == 1 || (role == 0 && (jobType == xi::Job::NIN || jobType == xi::Job::PLD || jobType == xi::Job::RUN)))
            {
                hasTank = true;
            }
        });
    // clang-format on
    return hasTank;
}

// XI: Forever Offline (job expansion): the cast time the mate would have for a spell, as battleutils::CalculateSpellCastTime
// computes it for the common cases (Fast Cast, Hasso/Seigan, the elemental/black magic cast-time modifier). Quick Magic
// and Arts are left out on purpose: the burst choice should rather leave a margin than count on a proc.
auto CGambitsContainer::EstimatedCastTime(CSpell* PSpell) const -> timer::duration
{
    if (PSpell == nullptr)
    {
        return 0s;
    }

    auto cast = std::chrono::duration_cast<std::chrono::milliseconds>(PSpell->getCastTime());
    if (POwner->StatusEffectContainer->HasStatusEffect({ xi::StatusEffect::Hasso, xi::StatusEffect::Seigan }))
    {
        cast = std::chrono::floor<std::chrono::milliseconds>(cast * 1.5);
    }

    if (PSpell->getSpellGroup() == SPELLGROUP_BLACK)
    {
        cast = std::chrono::floor<std::chrono::milliseconds>(cast * (1.0f + POwner->getMod(xi::Mod::BLACK_MAGIC_CAST) / 100.0f));
    }

    const auto fastCast = std::clamp<int16>(POwner->getMod(xi::Mod::FASTCAST), 0, 50);
    cast                = std::chrono::floor<std::chrono::milliseconds>(cast * (1.0f - fastCast / 100.0f));
    return std::max<timer::duration>(cast, 0s);
}

// XI: Forever Offline (job expansion): the magic burst for G_SELECT::MB_ELEMENT.
//  - only a formed skillchain (tier > 0); its type is read whole (Darkness II), see resonanceOf;
//  - the burst elements of that type, each with its single-target nuke family (Light: Banish, then Holy; Dark: Drain);
//  - every spell of those families the mate has, with MP and no recast (GetAvailable);
//  - only spells whose cast (EstimatedCastTime) ends MagicBurstMargin before the skillchain effect runs out;
//  - of those: the element the target resists least (its *_RES_RANK), then the highest tier (the higher spell id),
//    then the shorter cast. A weaker spell that lands inside the window beats a stronger one that would not.
// Nothing (no cast) when no spell fits. Before, the best tier of the first burst element was cast whatever the window.
auto CGambitsContainer::BestBurstSpell(CBattleEntity* target) -> Maybe<SpellID>
{
    if (target == nullptr || POwner->SpellContainer == nullptr)
    {
        return std::nullopt;
    }

    CStatusEffect* PSCEffect = target->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain, 0);
    if (PSCEffect == nullptr || PSCEffect->GetTier() == 0)
    {
        return std::nullopt;
    }

    const auto now = timer::now();
    const auto end = PSCEffect->GetStartTime() + PSCEffect->GetDuration();
    if (end <= now)
    {
        return std::nullopt;
    }

    const auto remaining = end - now;

    // clang-format off
    static const std::array<std::pair<ELEMENT, std::array<SPELLFAMILY, 2>>, 8> families = { {
        { ELEMENT_FIRE,    { SPELLFAMILY_FIRE,     SPELLFAMILY_NONE } },
        { ELEMENT_ICE,     { SPELLFAMILY_BLIZZARD, SPELLFAMILY_NONE } },
        { ELEMENT_WIND,    { SPELLFAMILY_AERO,     SPELLFAMILY_NONE } },
        { ELEMENT_EARTH,   { SPELLFAMILY_STONE,    SPELLFAMILY_NONE } },
        { ELEMENT_THUNDER, { SPELLFAMILY_THUNDER,  SPELLFAMILY_NONE } },
        { ELEMENT_WATER,   { SPELLFAMILY_WATER,    SPELLFAMILY_NONE } },
        { ELEMENT_LIGHT,   { SPELLFAMILY_BANISH,   SPELLFAMILY_HOLY } },
        { ELEMENT_DARK,    { SPELLFAMILY_DRAIN,    SPELLFAMILY_NONE } },
    } };
    static const std::array<xi::Mod, 8> resistRank = {
        xi::Mod::FIRE_RES_RANK, xi::Mod::ICE_RES_RANK, xi::Mod::WIND_RES_RANK, xi::Mod::EARTH_RES_RANK,
        xi::Mod::THUNDER_RES_RANK, xi::Mod::WATER_RES_RANK, xi::Mod::LIGHT_RES_RANK, xi::Mod::DARK_RES_RANK,
    };
    // clang-format on

    std::vector<ELEMENT> elements;
    for (const auto type : resonanceOf(PSCEffect))
    {
        if (type == xi::SkillchainType::None)
        {
            continue;
        }

        for (const auto element : battleutils::GetSkillchainMagicElement(type))
        {
            if (std::ranges::find(elements, element) == elements.end())
            {
                elements.emplace_back(element);
            }
        }
    }

    Maybe<SpellID>  best;
    int32           bestResist = 0;
    uint16          bestId     = 0;
    timer::duration bestCast   = 0s;
    for (const auto element : elements)
    {
        const auto entry = std::ranges::find_if(families, [&](const auto& e) { return e.first == element; });
        if (entry == families.end() || element < ELEMENT_FIRE || element > ELEMENT_DARK)
        {
            continue;
        }

        const int32 resist = target->getMod(resistRank[static_cast<size_t>(element) - 1]);
        for (const auto family : entry->second)
        {
            if (family == SPELLFAMILY_NONE)
            {
                continue;
            }

            for (const auto id : POwner->SpellContainer->m_damageList)
            {
                CSpell* PSpell = spell::GetSpell(id);
                if (PSpell == nullptr || PSpell->getSpellFamily() != family || !POwner->SpellContainer->GetAvailable(id).has_value())
                {
                    continue;
                }

                const auto cast = EstimatedCastTime(PSpell);
                if (cast + MagicBurstMargin > remaining)
                {
                    continue; // would land after the window
                }

                const auto spellId = static_cast<uint16>(id);
                const bool better  = !best.has_value() || resist < bestResist ||
                                    (resist == bestResist && (spellId > bestId || (spellId == bestId && cast < bestCast)));
                if (better)
                {
                    best       = id;
                    bestResist = resist;
                    bestId     = spellId;
                    bestCast   = cast;
                }
            }
        }
    }

    return best;
}

// XI: Forever Offline (job expansion): a squad thief's Rule Set uses Sneak Attack / Trick Attack before its weapon skill
// (squad.lua sets SQUAD_SATA_WSHOLD when such a rule needs TP). The weapon skill waits - TP is kept - while:
//  - the hold window has not run out (SQUAD_WS_HOLD_UNTIL, at most 8 s from its start; squad.lua ends it early, e.g. when
//    the thief takes the enemy's attention or the request is cancelled), and
//  - neither effect is on yet (once it is, the weapon skill goes and consumes it), and
//  - TP is below 3000 (the engine's release: TP is never held for ever), and
//  - no skillchain can be closed now (a closing opportunity is never given up for the position).
// The hold starts here, the moment the weapon skill would otherwise go, if Sneak Attack or Trick Attack is ready.
auto CGambitsContainer::HoldWeaponSkill(CBattleEntity* target) -> bool
{
    if (POwner->GetLocalVar("SQUAD_SATA_WSHOLD") == 0 || POwner->health.tp >= 3000 || target == nullptr)
    {
        return false;
    }

    if (POwner->StatusEffectContainer->HasStatusEffect({ xi::StatusEffect::SneakAttack, xi::StatusEffect::TrickAttack }))
    {
        return false;
    }

    auto* PSCEffect = target->StatusEffectContainer->GetStatusEffect(xi::StatusEffect::Skillchain);
    if (PSCEffect != nullptr && PSCEffect->GetTier() == 0 && PSCEffect->GetStartTime() + 3s < timer::now())
    {
        return false; // a window to close: the weapon skill (if it closes) is worth more than the position
    }

    const uint32 now   = nowSeconds();
    const uint32 until = POwner->GetLocalVar("SQUAD_WS_HOLD_UNTIL");
    if (until != 0)
    {
        return now < until;
    }

    auto ready = [&](ABILITY id)
    {
        const auto* PAbility = ability::GetAbility(id);
        return PAbility != nullptr && ability::CanLearnAbility(POwner, id) &&
               !POwner->PRecastContainer->HasRecast(xi::RecastType::Ability, static_cast<xi::Recast>(id), 0s);
    };

    if (ready(ABILITY_SNEAK_ATTACK) || ready(ABILITY_TRICK_ATTACK))
    {
        POwner->SetLocalVar("SQUAD_WS_HOLD_UNTIL", now + 8);
        return true;
    }

    return false;
}

} // namespace gambits
