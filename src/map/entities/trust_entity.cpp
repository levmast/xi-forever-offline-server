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

#include <map/entities/trust_entity.h>

#include "action/action.h"
#include "action/interrupts.h"
#include "ai/ai_container.h"
#include "ai/controllers/trust_controller.h"
#include "ai/helpers/pathfind.h"
#include "ai/helpers/targetfind.h"
#include "ai/states/magic_state.h"
#include "ai/states/weaponskill_state.h"
#include "data/enums/mob_mod.h"
#include "enmity_container.h"
#include "entities/char_entity.h"
#include "enums/msg_basic.h"
#include "lua/luautils.h"
#include "mob_spell_list.h"
#include "packets/entity_set_name.h"
#include "packets/s2c/0x0df_group_attr.h"
#include "recast_container.h"
#include "status_effect_container.h"
#include "utils/battleutils.h"
#include "utils/itemutils.h"  // F12: the WS gear set's items
#include "utils/trustutils.h" // F12: BuildSquadSkills after a gear swap
#include "items/item_equipment.h"
#include "zone.h"
#include "common/settings.h" // main.SQUAD_MATES_RAISABLE

namespace
{

constexpr int8 kTrustDefaultShieldSize = 3;

} // namespace

CTrustEntity::CTrustEntity(CCharEntity* PChar, uint32 trustId, IsPassiveTrust isPassiveTrust)
: CMobEntity()
, trustID_(trustId)
, passiveTrust_(isPassiveTrust)
{
    objtype                     = TYPE_TRUST;
    m_EcoSystem                 = xi::Ecosystem::Unclassified;
    allegiance                  = xi::Allegiance::Player;
    m_MobSkillList              = 0;
    PMaster                     = PChar;
    m_bReleaseTargIDOnDisappear = true;
    spawnAnimation              = xi::SpawnAnimation::Special; // Initial spawn has the special spawn-in animation

    PAI = std::make_unique<CAIContainer>(this,
                                         std::make_unique<CPathFind>(this),
                                         std::make_unique<CTrustController>(PChar, this),
                                         std::make_unique<CTargetFind>(this));
}

CTrustEntity::~CTrustEntity()
{
    TracyZoneScoped;

    // The squad mate's own spell list (see trustutils.cpp) belongs to this trust
    if (squadSpellList_ != nullptr)
    {
        if (m_SpellListContainer == squadSpellList_)
        {
            m_SpellListContainer = nullptr;
        }

        delete squadSpellList_;
        squadSpellList_ = nullptr;
    }

    // Never leave a pet pointing at a deleted master (it despawns itself on its next tick once it has no master)
    if (PPet != nullptr)
    {
        if (PPet->PMaster == this)
        {
            PPet->PMaster = nullptr;
        }

        PPet = nullptr;
    }
}

auto CTrustEntity::trustID() const -> uint32
{
    return trustID_;
}

auto CTrustEntity::shieldSize() -> int8
{
    const auto shieldSizeMod = static_cast<int8>(getMobMod(xi::MobMod::TrustShieldSize));
    return shieldSizeMod > 0 ? shieldSizeMod : kTrustDefaultShieldSize;
}

auto CTrustEntity::released() const -> bool
{
    return released_;
}

void CTrustEntity::setReleased(bool released)
{
    released_ = released;
}

auto CTrustEntity::passiveTrust() -> IsPassiveTrust
{
    return passiveTrust_;
}

void CTrustEntity::PostTick()
{
    // CMobEntity::PostTick has no Disappear guard, and its pet sync only fires for a charmed mob. Trusts
    // send party HP updates instead, and none while despawning.
    // NOLINTNEXTLINE(bugprone-parent-virtual-call): Grandparent call, skips CMobEntity's impl on purpose.
    CBattleEntity::PostTick();
    timer::time_point now = timer::now();
    if (loc.zone && updatemask && status != xi::Status::Disappear && now > m_nextUpdateTimer)
    {
        m_nextUpdateTimer = now + 250ms;
        loc.zone->UpdateEntityPacket(this, ENTITY_UPDATE, updatemask);

        if (PMaster && PMaster->PParty && updatemask & UPDATE_HP)
        {
            PMaster->ForParty(
                [this](auto PMember)
                {
                    static_cast<CCharEntity*>(PMember)->pushPacket<GP_SERV_COMMAND_GROUP_ATTR>(this);
                });
        }

        updatemask = 0;
    }
}

void CTrustEntity::FadeOut()
{
    // CMobEntity::FadeOut also clears enmity. Die clears it for a defeated trust, and a released
    // trust is never reused, since every summon builds a new entity.
    // NOLINTNEXTLINE(bugprone-parent-virtual-call): Grandparent call, skips CMobEntity's impl on purpose.
    CBaseEntity::FadeOut();
    loc.zone->UpdateEntityPacket(this, ENTITY_DESPAWN, UPDATE_NONE);
}

namespace
{

// Squad mates can have pets (a wyvern, an avatar). The pet goes when its master does.
void ReleasePet(CBattleEntity* PMaster)
{
    CBattleEntity* PPet = PMaster->PPet;
    if (PPet == nullptr)
    {
        return;
    }

    PMaster->PPet = nullptr;
    if (!PPet->isDead())
    {
        PPet->Die();
    }

    if (PPet->PMaster == PMaster)
    {
        PPet->PMaster = nullptr;
    }
}

} // namespace

void CTrustEntity::Die()
{
    RestoreSquadWsSet(); // (F12) a mate knocked out in the middle of a weapon skill keeps no set modifiers
    ReleasePet(this);
    luautils::OnMobDeath(this, nullptr);
    PEnmityContainer->Clear();
    PAI->ClearStateStack();

    // XI: Forever Offline (2026-11-23, Meli; the user: "when squad mates die you should be able to raise them"): a squad mate
    // that falls stays where it fell, in your party, and can be Raised (scripts/actions/spells/white/raise*.lua and arise.lua
    // call xi.squad.onRaised, squad.lua). squad.lua takes the body away if nobody raises it in time. main.SQUAD_MATES_RAISABLE
    // = 0: gone at once, as before.
    const bool keepBody = GetLocalVar("SQUAD_ID") != 0 && settings::get<uint8>("main.SQUAD_MATES_RAISABLE") == 1;
    if (keepBody)
    {
        m_Behavior |= xi::Behavior::Raisable; // (the death state keeps it; the raise spells accept it)
    }

    PAI->Internal_Die(0s);
    if (!keepBody)
    {
        static_cast<CCharEntity*>(PMaster)->RemoveTrust(this);
    }
    m_OwnerID.clean();

    // CMobEntity::Die runs battlefield and spawn slot deaths, exp, drops and the defeat message, and
    // starts a 15 s death timer. Trusts give no rewards, and the steps above replace the rest.
    // NOLINTNEXTLINE(bugprone-parent-virtual-call): Grandparent call, skips CMobEntity's impl on purpose.
    CBattleEntity::Die();
}

void CTrustEntity::Spawn()
{
    // CMobEntity::Spawn rolls a level, recalculates stats from mob data, moves to the spawn point and
    // starts roaming. A trust's level and stats are set at summon, and it spawns next to its master.
    // XI: Forever Offline: a squad Blue Mage's set (SQUAD_BLU_*, written when the mate was built) is read by the Squad window and by other add-ons,
    // and the spawn clears local variables: keep it across the spawn.
    std::vector<std::pair<std::string, uint32>> keptBlue;
    for (const auto& [name, value] : GetLocalVars())
    {
        if (name.rfind("SQUAD_BLU_", 0) == 0)
        {
            keptBlue.emplace_back(name, value);
        }
    }

    // NOLINTNEXTLINE(bugprone-parent-virtual-call): Grandparent call, skips CMobEntity's impl on purpose.
    CBattleEntity::Spawn();

    // Squad mates: spawning clears local variables, so put the squad tag back before the spawn script runs
    if (squadId_ != 0)
    {
        SetLocalVar("SQUAD_ID", squadId_);
        for (const auto& [name, value] : keptBlue)
        {
            SetLocalVar(name, value);
        }
    }

    luautils::OnMobSpawn(this);

    // Recompute derived HP/MP after spawn-time modifiers (e.g. HPP/MPP)
    // and force current HP/MP to max so trusts start in a fully synchronized state.
    UpdateHealth();
    health.hp = GetMaxHP();
    health.mp = GetMaxMP();
    updatemask |= UPDATE_HP;

    static_cast<CCharEntity*>(PMaster)->pushPacket<CEntitySetNamePacket>(this);
}

auto CTrustEntity::ValidTarget(CBattleEntity* PInitiator, uint16 targetFlags) -> bool
{
    // Passive GEO trusts like Sakura etc are basically walking indicolures and cant be targeted
    if (passiveTrust_)
    {
        return false;
    }

    if (PInitiator->objtype == TYPE_TRUST && PMaster == PInitiator->PMaster)
    {
        return true;
    }

    if ((targetFlags & TARGET_PLAYER_PARTY_PIANISSIMO) && PInitiator->allegiance == allegiance && PMaster && PInitiator != this)
    {
        if (PInitiator->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::Pianissimo))
        {
            return true;
        }
    }

    if ((targetFlags & TARGET_PLAYER_PARTY_ENTRUST) && PInitiator->allegiance == allegiance && PMaster && PInitiator != this)
    {
        return true;
    }

    if (targetFlags & TARGET_PLAYER_PARTY && PInitiator->objtype == TYPE_PET && PInitiator->allegiance == allegiance)
    {
        return true;
    }

    if (targetFlags & TARGET_PLAYER_PARTY && PInitiator->allegiance == allegiance && PMaster)
    {
        // FFXI Offline (co-op): a trust has no party of its own, it belongs to its master's. So the squad mate of
        // another player in the same party is a party member too, and may heal and buff this one. (Stock: only
        // trusts of the same master, above, so one player's healer never helped another player's squad mates.)
        const auto* PInitiatorParty = PInitiator->PParty;
        if (PInitiatorParty == nullptr && PInitiator->objtype == TYPE_TRUST && PInitiator->PMaster != nullptr)
        {
            PInitiatorParty = PInitiator->PMaster->PParty;
        }

        return PInitiatorParty == PMaster->PParty;
    }

    return CMobEntity::ValidTarget(PInitiator, targetFlags);
}

void CTrustEntity::OnDespawn(CDespawnState& /*unused*/)
{
    RestoreSquadWsSet(); // (F12)
    ReleasePet(this);

    if (GetHPP() > 0)
    {
        // Don't call this when despawning after being killed
        luautils::OnMobDespawn(this);
    }
    FadeOut();
    PAI->EventHandler.triggerListener("DESPAWN", this);
}

void CTrustEntity::OnCastFinished(CMagicState& state, action_t& action)
{
    // CMobEntity::OnCastFinished sets the MagicCool cooldown and taps the deaggro timer. CTrustController
    // replaces the mob ticks that read both, and trusts gate spells on the recast below instead.
    // NOLINTNEXTLINE(bugprone-parent-virtual-call): Grandparent call, skips CMobEntity's impl on purpose.
    CBattleEntity::OnCastFinished(state, action);

    auto* PSpell = state.GetSpell();

    PRecastContainer->Add(xi::RecastType::Magic, static_cast<xi::Recast>(PSpell->getID()), action.recast);
}

void CTrustEntity::OnMobSkillFinished(CMobSkillState& state, action_t& action)
{
    CMobEntity::OnMobSkillFinished(state, action);
}

void CTrustEntity::OnWeaponSkillFinished(CWeaponSkillState& state, action_t& action)
{
    // (F12) the WS gear set was put on when the weapon skill started (CTrustController::WeaponSkill): take it off as soon
    // as the damage below is done, on every way out of this function. The state's Cleanup restores it again (harmless).
    struct WsSetRestore
    {
        CTrustEntity* self;
        ~WsSetRestore()
        {
            self->RestoreSquadWsSet();
        }
    } wsSetRestore{ this };

    // CMobEntity::OnWeaponSkillFinished only taps the deaggro timer. CTrustController replaces the mob
    // ticks that read it.
    // NOLINTNEXTLINE(bugprone-parent-virtual-call): Grandparent call, skips CMobEntity's impl on purpose.
    CBattleEntity::OnWeaponSkillFinished(state, action);

    auto* PWeaponSkill  = state.GetSkill();
    auto* PBattleTarget = state.target().resolve<CBattleEntity>();
    if (!PBattleTarget)
    {
        return;
    }

    int16 tp = state.GetSpentTP();
    tp       = battleutils::CalculateWeaponSkillTP(this, PWeaponSkill, tp);

    if (distance(loc.p, PBattleTarget->loc.p) <= PWeaponSkill->getRange() + PBattleTarget->modelHitboxSize + modelHitboxSize)
    {
        PAI->TargetFind->reset();
        if (PWeaponSkill->isAoE())
        {
            PAI->TargetFind->findWithinArea(PBattleTarget, AOE_RADIUS::TARGET, PWeaponSkill->getRadius(), FINDFLAGS_NONE, TARGET_NONE);
        }
        else
        {
            PAI->TargetFind->findSingleTarget(PBattleTarget, FINDFLAGS_NONE, TARGET_NONE);
        }

        if (PAI->TargetFind->m_targets.empty())
        {
            // There used to be an assumed interrupt handler
            // Add a test and capture before reintroducing.
            return;
        }

        for (auto&& PTarget : PAI->TargetFind->m_targets)
        {
            bool             primary      = PTarget == PBattleTarget;
            action_target_t& actionTarget = action.addTarget(PTarget->id);
            action_result_t& actionResult = actionTarget.addResult();

            uint16         tpHitsLanded    = 0;
            uint16         extraHitsLanded = 0;
            int32          damage          = 0;
            CBattleEntity* taChar          = battleutils::getAvailableTrickAttackChar(this, PTarget);

            actionResult.resolution                         = ActionResolution::Hit;
            actionResult.animation                          = PWeaponSkill->getAnimationId();
            std::tie(damage, tpHitsLanded, extraHitsLanded) = luautils::OnUseWeaponSkill(this, PTarget, PWeaponSkill, tp, primary, action, taChar);

            if (!battleutils::isValidSelfTargetWeaponskill(PWeaponSkill->getID()))
            {
                if (primary && PBattleTarget->objtype == TYPE_MOB)
                {
                    luautils::OnWeaponskillHit(PBattleTarget, this, PWeaponSkill->getID());
                }
            }
            else // Self-targetting WS restoring MP
            {
                actionResult.messageID  = primary ? MsgBasic::UsesSkillRecoversMP : MsgBasic::TargetRecoversMP;
                actionResult.resolution = ActionResolution::Hit;
                damage                  = std::max(damage, 0);
                actionResult.param      = addMP(damage);
            }

            if (primary)
            {
                if (actionResult.resolution == ActionResolution::Hit)
                {
                    if (PBattleTarget->health.hp > 0 && PWeaponSkill->getPrimarySkillchain() != 0)
                    {
                        // NOTE: GetSkillChainEffect is INSIDE this if statement because it
                        //  ALTERS the state of the resonance, which misses and non-elemental skills should NOT do.
                        const auto effect = battleutils::GetSkillChainEffect(
                            PBattleTarget,
                            PWeaponSkill->getPrimarySkillchain(),
                            PWeaponSkill->getSecondarySkillchain(),
                            PWeaponSkill->getTertiarySkillchain());
                        if (effect != ActionProcSkillChain::None)
                        {
                            actionResult.recordSkillchain(effect, battleutils::TakeSkillchainDamage(this, PBattleTarget, damage, taChar));
                        }
                    }
                }
            }
        }
    }
    else
    {
        ActionInterrupts::WeaponSkillOutOfRange(this, PBattleTarget);
    }

    this->processActionEffectFlags(action);
}

auto CTrustEntity::GetUntargetable() const -> bool
{
    // Passive GEO trusts like Sakura etc are basically walking indicolures and cant be targeted
    if (passiveTrust_)
    {
        return true;
    }

    return CMobEntity::GetUntargetable();
}

// ---------------------------------------------------------------- XI: Forever Offline (F12): the WS gear set
namespace
{

void addItemMods(CTrustEntity* PTrust, const uint16 itemId)
{
    if (const auto* item = xi::items::lookup<CItemEquipment>(itemId))
    {
        auto mods = item->modList; // (a copy: addModifiers takes a non-const pointer, as in squad.cpp applyEquipment)
        PTrust->addModifiers(&mods);
    }
}

void delItemMods(CTrustEntity* PTrust, const uint16 itemId)
{
    if (const auto* item = xi::items::lookup<CItemEquipment>(itemId))
    {
        auto mods = item->modList;
        PTrust->delModifiers(&mods);
    }
}

// After a swap: max HP/MP and the skills follow the gear; current HP/MP are clamped to the new maximum, never refilled
void afterSwap(CTrustEntity* PTrust)
{
    trustutils::BuildSquadSkills(PTrust);
    PTrust->UpdateHealth(); // (clamps hp/mp to the new maximum, battle_entity.cpp)
    PTrust->updatemask |= UPDATE_HP;
}

} // namespace

auto CTrustEntity::ApplySquadWsSet() -> bool
{
    if (!isSquadMate() || isDead() || squadWsLedger_.active())
    {
        return false;
    }

    squad::wsset::Gear outfit{};
    for (uint8 slot = 0; slot < squad::wsset::SlotCount; ++slot)
    {
        outfit[slot] = squadEquip(slot);
    }

    const uint8  level  = GetMLevel();
    const uint32 jobBit = 1u << (static_cast<uint8>(GetMJob()) - 1);
    const auto   plan   = squad::wsset::MakePlan(
        squadWsSet_, outfit,
        [level, jobBit](const uint16 itemId)
        {
            // (checked again here: a Level Sync or a level drop since the set was saved)
            const auto* item = xi::items::lookup<CItemEquipment>(itemId);
            return item != nullptr && item->getReqLvl() <= level && (item->getJobs() & jobBit) != 0;
        },
        [](const uint16 itemId)
        {
            const auto* item = xi::items::lookup(itemId);
            return item != nullptr && item->hasFlag(xi::ItemFlag::Rare);
        });

    const bool done = squadWsLedger_.Apply(
        plan,
        [this](const uint16 itemId)
        {
            delItemMods(this, itemId);
        },
        [this](const uint16 itemId)
        {
            addItemMods(this, itemId);
        });

    if (done)
    {
        afterSwap(this);
    }

    return done;
}

auto CTrustEntity::RestoreSquadWsSet() -> bool
{
    const bool done = squadWsLedger_.Restore(
        [this](const uint16 itemId)
        {
            delItemMods(this, itemId);
        },
        [this](const uint16 itemId)
        {
            addItemMods(this, itemId);
        });

    if (done && !isDead())
    {
        afterSwap(this);
    }

    return done;
}
