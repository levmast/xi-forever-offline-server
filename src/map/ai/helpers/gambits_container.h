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

#pragma once

#include "common/cbasetypes.h"
#include "common/macros.h"

#include <common/types/hash_map.h>

#include "gambits_backoff.h"
#include "squad_add_target.h"

#include "ai/ai_container.h"
#include "ai/controllers/trust_controller.h"
#include "entities/char_entity.h"
#include "entities/trust_entity.h"
#include "mob_spell_container.h"
#include "status_effect.h"
#include "status_effect_container.h"

#include <optional>
#include <set>
#include <utility>

class CWeaponSkill;

namespace gambits
{

enum class G_TARGET : uint16
{
    SELF                       = 0,
    PARTY                      = 1,
    TARGET                     = 2,
    MASTER                     = 3,
    TANK                       = 4,
    MELEE                      = 5,
    RANGED                     = 6,
    CASTER                     = 7,
    TOP_ENMITY                 = 8,
    CURILLA                    = 9, // Special case for Rainemard
    PARTY_DEAD                 = 10,
    PARTY_MULTI                = 11,
    TRIGGER_SELF_ACTION_TARGET = 12,
    TRIGGER_TARGET_ACTION_SELF = 13,
    PARTY_LOWEST_HPP           = 14, // XI: Forever Offline: the living party member in range with the lowest HP% that matches
    // XI: Forever Offline (F21, 2026-11-27): the nearest awake add: a monster fighting the party that is not the party's
    // combat target, within the rule's spell reach, not reserved by another mate (squad_add_target.h)
    ENEMY_ADD                  = 15,
};

enum class G_LOGIC : uint16
{
    AND = 0,
    OR  = 1,
};

enum class G_CONDITION : uint16
{
    ALWAYS             = 0,
    HPP_LT             = 1,
    HPP_GTE            = 2,
    MPP_LT             = 3,
    MPP_GTE            = 4,
    TP_LT              = 5,
    TP_GTE             = 6,
    LVL_LT             = 7,
    LVL_GTE            = 8,
    STATUS             = 9,
    NOT_STATUS         = 10,
    STATUS_FLAG        = 11,
    HAS_TOP_ENMITY     = 12,
    NOT_HAS_TOP_ENMITY = 13,
    SC_AVAILABLE       = 14,
    NOT_SC_AVAILABLE   = 15,
    MB_AVAILABLE       = 16,
    READYING_WS        = 17,
    READYING_MS        = 18,
    READYING_JA        = 19,
    CASTING_MA         = 20,
    CASTING_DEBUFF     = 21,
    RANDOM             = 22,
    NO_SAMBA           = 23,
    NO_STORM           = 24,
    PT_HAS_TANK        = 25,
    NOT_PT_HAS_TANK    = 26,
    IS_ECOSYSTEM       = 27,
    HP_MISSING         = 28,
    CASTING_ELEMENT_MA = 29,
    CAST_ELE_MA_SELF   = 30,
    CASTING_ELE_MA_AOE = 31,
    NEED_ELE_BAREFFECT = 32,
    NO_MAX_RUNE        = 33,
    HAS_RUNES          = 34,
    LUNGE_MB_AVAILABLE = 35,
    SUB_ANIMATION      = 36,
    JA_ON_COOLDOWN     = 37,
    VAL_URIEL_CHECK    = 38,
    TIMER              = 39, // condition_arg in seconds
    // XI: Forever Offline: MP conditions that are false for a target without an MP pool (max MP 0)
    HAS_MP             = 40,
    HAS_MP_MPP_LT      = 41,
    HAS_MP_MPP_GTE     = 42,
    // XI: Forever Offline (job expansion): a modifier of the target below a number. condition_arg = modifier id
    // (low 16 bits) | number << 16. E.g. Utsusemi shadows left (Mod::UTSUSEMI) below 2. Rule Sets may only name the
    // modifiers squad_rulesets.lua R.MODS lists (UTSUSEMI, BLINK).
    MOD_LT             = 43,
    // XI: Forever Offline (F1, 2026-11-25): the enemy is a monster of this family (condition_arg = family id, data/ecosystems.yaml,
    // xi.mobFamily: Goblin 58). The enemy is the rule's target when that is a monster, else the mate's battle target, so a rule
    // for yourself or the party can ask about the enemy ("Goblin -> Barfira"). False with no enemy.
    ENEMY_FAMILY       = 44,
    // XI: Forever Offline (F2, 2026-11-25): counts. condition_arg = filter (low 16 bits) | number << 16 (8 bits) | comparison << 24
    // (0 at least, 1 exactly, 2 at most, 3 more than, 4 fewer than: squad_threat.h CountMatches).
    // PARTY_COUNT filter: a status effect id the member has (0 = every member, 0xFFFE = asleep: Sleep, Sleep II or Lullaby).
    //   Counted: living party members (you, the party, the mates) in this zone within PartyCountReach of the mate, the mate included.
    // ENEMY_COUNT filter: HP% the monster must be above (low 8 bits, 0 = any) | radius in yalms (bits 8-15, 0 = 10) around the
    //   mate's battle target. Counted: the monsters fighting the party (squad_threat.h, CTrustController::PartyFoes), the target
    //   included; monsters that are only standing nearby are not. 0 with no enemy.
    PARTY_COUNT        = 45,
    ENEMY_COUNT        = 46,
    // XI: Forever Offline (F20, 2026-11-27): the target has an effect Erase can remove now (CStatusEffectContainer::
    // HasErasableEffect: the Erasable flag and a duration, so a permanent effect never triggers it). No argument.
    ERASABLE           = 47,
    // XI: Forever Offline (F18, 2026-11-27): always true; marks a rule "Wake to act": a mate resting in a fight runs only
    // these rules (squad.lua adds it to a Rule Set rule with wake = true). An older xi_map makes it false: the rule never runs.
    WAKE               = 48,
};

enum class G_REACTION : uint16
{
    ATTACK      = 0,
    RATTACK     = 1,
    MA          = 2,
    JA          = 3,
    WS          = 4,
    MS          = 5,
    ANIM_STRING = 6,
};

enum class G_SELECT : uint16
{
    HIGHEST             = 0,
    LOWEST              = 1,
    SPECIFIC            = 2,
    RANDOM              = 3,
    MB_ELEMENT          = 4,
    SPECIAL_AYAME       = 5,
    SPECIAL_AUGUST      = 6,
    BEST_AGAINST_TARGET = 7,
    BEST_SAMBA          = 8,
    HIGHEST_WALTZ       = 9,
    ENTRUSTED           = 10,
    BEST_INDI           = 11,
    STORM_DAY           = 12,
    HELIX_DAY           = 13,
    EN_MOB_WEAKNESS     = 14,
    STORM_MOB_WEAKNESS  = 15,
    HELIX_MOB_WEAKNESS  = 16,
    DEF_BAR_ELEMENT     = 17,
    RUNE_DAY            = 18,
    RANDOM_ANIMATION    = 19,
};

enum class G_TP_TRIGGER : uint16
{
    ASAP            = 0,
    RANDOM          = 1,
    OPENER          = 2,
    CLOSER          = 3, // Will Hold TP Indefinitely to close a SC
    CLOSER_UNTIL_TP = 4, // Will Hold TP to close a SC until a certain threshold
    // XI: Forever Offline (Gambits weapon skill settings). tp_value = the threshold (1000-3000). At 3000 TP each of these
    // always uses a weapon skill (the engine's forced release), falling back to the opening pick when nothing closes.
    OPEN_AT_TP       = 5, // Opens only: own TP >= value, no skillchain effect on the target, another party member ready to close
    CLOSE_ONLY       = 6, // Closes only: an open skillchain window, from 1000 TP (value not used); otherwise waits
    OPEN_CLOSE_AT_TP = 7, // Closes a window from 1000 TP; otherwise opens like OPEN_AT_TP
    AT_TP            = 8, // Own TP >= value, whatever the others do: closes a window if it can, otherwise still uses its skill
};

struct Predicate_t
{
    G_CONDITION condition{};
    uint32      condition_arg;

    Predicate_t()
    : condition_arg(0)
    {
    }

    Predicate_t(G_CONDITION _condition, uint32 _condition_arg)
    : condition(_condition)
    , condition_arg(_condition_arg)
    {
    }

    auto parseInput(const std::string& key, uint32 value) -> bool
    {
        if (key.compare("condition") == 0)
        {
            condition = static_cast<G_CONDITION>(value);
        }
        else if (key.compare("argument") == 0)
        {
            condition_arg = value;
        }
        else
        {
            // TODO: Log error
            return false;
        }
        return true;
    }
};

struct PredicateGroup_t
{
    G_LOGIC                  logic;
    std::vector<Predicate_t> predicates;

    PredicateGroup_t(G_LOGIC _logic, std::vector<Predicate_t> _predicates)
    : logic(_logic)
    , predicates(std::move(_predicates))
    {
    }
};

struct Action_t
{
    G_REACTION reaction;
    G_SELECT   select;
    uint32     select_arg = 0;

    Action_t(G_REACTION reaction, G_SELECT select, uint32 select_arg)
    : reaction(reaction)
    , select(select)
    , select_arg(select_arg)
    {
    }

    auto parseInput(const std::string& key, uint32 value) -> bool
    {
        if (key.compare("reaction") == 0)
        {
            reaction = static_cast<G_REACTION>(value);
        }
        else if (key.compare("select") == 0)
        {
            select = static_cast<G_SELECT>(value);
        }
        else if (key.compare("argument") == 0)
        {
            select_arg = value;
        }
        else
        {
            // TODO: Log error
            return false;
        }
        return true;
    }
};

struct Gambit_t
{
    std::vector<PredicateGroup_t> predicate_groups;
    std::vector<Action_t>         actions;
    G_TARGET                      target_selector{};
    uint16                        retry_delay;
    timer::time_point             last_used;
    std::string                   identifier;
    // XI: Forever Offline (Gambits 0.3.3, Bard role targeting): for a TANK / MELEE / CASTER / RANGED target, more roles
    // that also qualify (OR) and roles that never do (any of them excludes; exclusion wins). Bits: 1 tank, 2 melee,
    // 4 caster, 8 ranged. 0 / 0 = the target's own role only, as before. Set by AddGambit from the target argument's
    // high byte (squad Rule Sets: target | include << 8 | exclude << 12).
    uint8                         role_include{ 0 };
    uint8                         role_exclude{ 0 };

    Gambit_t()
    : retry_delay(0)
    {
    }
};

// TODO
struct Chain_t
{
    std::vector<Gambit_t> gambits;

    Chain_t() = default;
};

// TODO: smaller types, make less bad.
struct TrustSkill_t
{
    G_REACTION skill_type{};
    uint32     skill_id;
    uint8      primary;
    uint8      secondary;
    uint8      tertiary;
    TARGETTYPE valid_targets{};

    TrustSkill_t()
    : skill_id(0)
    , primary(0)
    , secondary(0)
    , tertiary(0)
    {
    }

    TrustSkill_t(G_REACTION _skill_type, uint32 _skill_id, uint8 _primary, uint8 _secondary, uint8 _tertiary, TARGETTYPE _valid_targets)
    : skill_type(_skill_type)
    , skill_id(_skill_id)
    , primary(_primary)
    , secondary(_secondary)
    , tertiary(_tertiary)
    , valid_targets(_valid_targets)
    {
    }
};

class CGambitsContainer
{
public:
    CGambitsContainer(CTrustEntity* trust)
    : POwner(trust)
    {
    }

    ~CGambitsContainer() = default;

    DISALLOW_COPY_AND_MOVE(CGambitsContainer);

    auto NewGambitIdentifier(const Gambit_t& gambit) const -> std::string;
    auto AddGambit(const Gambit_t& gambit) -> std::string;
    void RemoveGambit(const std::string& id);
    void RemoveAllGambits();
    // supportOnly (XI: Forever Offline, B3b): out of combat, only the support rules (gambits_support.h)
    // wakeOnly (F18): resting in a fight, only the rules marked "Wake to act" (G_CONDITION::WAKE); one that acts stands the mate up for that action only
    auto Tick(timer::time_point tick, bool supportOnly = false, bool wakeOnly = false) -> Task<void>;

    // TODO: make private
    std::vector<TrustSkill_t> tp_skills;
    G_TP_TRIGGER              tp_trigger{};
    G_SELECT                  tp_select{};
    uint16                    tp_value{};

private:
    auto CheckTrigger(const CBattleEntity* triggerTarget, const Gambit_t& gambit, size_t predicateGroupIndex, PredicateGroup_t& predicateGroup) -> bool;
    auto TryTrustSkill(bool dryRun = false) -> bool;                            // (dryRun: XI: Forever Offline, gambits_sata.h)
    auto TrySettingsTrustSkill(CBattleEntity* target, bool dryRun = false) -> bool; // the OPEN_AT_TP .. AT_TP triggers
    auto WeaponSkillWouldFire() -> bool;                                        // XI: Forever Offline: squad SA/TA pairing
    auto CloserOpening(const CBattleEntity* target) const -> std::optional<std::pair<int64, int64>>; // (option B) ms since, duration
    auto PotentialCloserReady(const CBattleEntity* target) const -> bool;
    auto InWeaponSkillRange(const CWeaponSkill* PWeaponSkill, const CBattleEntity* target) const -> bool;
    auto PartyHasHealer() -> bool;
    auto PartyHasTank() -> bool;
    auto BestBurstSpell(CBattleEntity* target, uint32 maxTier = 0) -> Maybe<SpellID>; // XI: Forever Offline (job expansion): MB_ELEMENT; (F10) tier cap
    // XI: Forever Offline (F21, 2026-11-27): the add for an ENEMY_ADD rule (squad_add_target.h), or nullptr
    auto PickAdds(float reach) -> std::vector<CBattleEntity*>; // eligible adds, nearest first
    HashMap<uint32, squad::addtarget::Tries> m_AddTries;        // (F21) this caster's tries per add (the resist backoff)
    auto EstimatedCastTime(CSpell* PSpell) const -> timer::duration;
    auto HoldWeaponSkill(CBattleEntity* target) -> bool; // XI: Forever Offline (job expansion): squad SA/TA before a WS
    // XI: Forever Offline (2026-11-23, final batch, gambits_sata.h)
    auto SataOpeningStart(const CBattleEntity* target) const -> std::optional<timer::time_point>; // a tier-0 opening's start
    auto TryUseSataWhenReady(timer::time_point tick, bool busy) -> bool;                       // I-B
    auto SataAbilityEndsThisTick(timer::time_point tick) const -> bool;                        // I-C
    void WithdrawSataAfterWeaponSkill(const CBattleEntity* target);                            // R

    CTrustEntity*         POwner;
    timer::time_point     m_lastAction;
    std::vector<Gambit_t> gambits;

    // XI: Forever Offline (2026-11-23, gambits_sata.h): a paired Sneak/Trick Attack was used; until m_sataFollowUpUntil the
    // weapon skill is tried on every tick
    bool              m_sataFollowUp{ false };
    timer::time_point m_sataFollowUpUntil{};
    // (option B) the opening (its start) for which an open window was already held one pass: never held twice
    timer::time_point m_sataHeldOpening{};
    // (final batch) the request the rule's gate made: its ability, the opening (start) it was made for, and whether it was the
    // first action-taking rule of that pass (no earlier rule acted). I-B completes only such a request, for that opening.
    uint16            m_sataReqAbility{ 0 };
    timer::time_point m_sataReqOpening{};
    bool              m_sataReqClean{ false };
    // (final batch, I-C) the paired ability that was used and when (taken right after the use: at or after the state's entry)
    uint16            m_sataUsedAbility{ 0 };
    timer::time_point m_sataUsedAt{};

    HashMap<std::string, timer::time_point> m_timerConditionLastTrigger;

    // XI: Forever Offline: area rules that keep acting on a member they do not reach rest for a while (gambits_backoff.h)
    backoff::Guard m_AreaGuard;

    std::set<xi::Job> melee_jobs = {
        xi::Job::WAR,
        xi::Job::MNK,
        xi::Job::THF,
        xi::Job::PLD,
        xi::Job::DRK,
        xi::Job::BST,
        xi::Job::SAM,
        xi::Job::NIN,
        xi::Job::DRG,
        xi::Job::BLU,
        xi::Job::PUP,
        xi::Job::DNC,
        xi::Job::RUN,
    };

    std::set<xi::Job> caster_jobs = {
        xi::Job::WHM,
        xi::Job::BLM,
        xi::Job::RDM,
        xi::Job::BRD,
        xi::Job::SMN,
        xi::Job::BLU,
        xi::Job::SCH,
        xi::Job::GEO,
        xi::Job::RUN,
    };
};

} // namespace gambits
