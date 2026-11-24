/*
===========================================================================

  Copyright (c) 2024 LandSandBoat Dev Teams

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

#include "trustutils.h"

#include "common/utils.h"

#include <common/types/hash_map.h>

#include <algorithm>
#include <map>
#include <set>

#include "battleutils.h"
#include "data/loader.h"
#include "mobutils.h"
#include "itemutils.h"

#include "grades.h"
#include "mob_spell_list.h"

#include "ai/ai_container.h"
#include "ai/controllers/trust_controller.h"
#include "ai/helpers/gambits_container.h"
#include "entities/trust_entity.h"
#include "blue_spell.h"
#include "blue_trait.h"
#include "trait.h"
#include "items/item_weapon.h"
#include "mobskill.h"
#include "status_effect_container.h"
#include "weapon_skill.h"
#include "zone.h"

namespace
{

//
// Forward declarations
//

void BuildTrustData(uint32 TrustID);
auto LoadTrust(CCharEntity* PMaster, uint32 TrustID, const trustutils::SquadSpec* spec) -> CTrustEntity*;
void LoadTrustStatsAndSkills(CTrustEntity* PTrust);
void BuildSquadSkillsImpl(CTrustEntity* PTrust);

// List of trusts that are essentially walking GEO bubbles that should not be targetable
std::unordered_set<SpellID> passiveTrustIDs = {
    SpellID::Sakura,
    SpellID::Moogle,
    SpellID::Star_Sibyl,
    SpellID::Kuyin_Hathdenna,
    SpellID::Brygid,
    SpellID::Kupofried,
    SpellID::Cornelia,
};

struct TrustData
{
    uint32        trustID{};
    bool          isPassiveTrust{};
    uint32        pool{};
    look_t        look;        // appearance data
    std::string   name;        // script name string
    std::string   packet_name; // packet name string
    xi::Ecosystem EcoSystem{}; // ecosystem

    uint8  name_prefix{};
    uint8  modelSize{ 0 };
    float  modelHitboxSize{ 0.0f };
    uint16 m_Species{};

    uint8 mJob{};
    uint8 sJob{};
    float HPscale{ 1.f };
    float MPscale{ 1.f };

    uint8  cmbSkill{};
    uint16 cmbDmgMult{};
    uint16 cmbDelay{};
    uint8  baseSpeed{};
    uint8  animationSpeed{};

    // stat ranks
    uint8 strRank{};
    uint8 dexRank{};
    uint8 vitRank{};
    uint8 agiRank{};
    uint8 intRank{};
    uint8 mndRank{};
    uint8 chrRank{};
    uint8 attRank{};
    uint8 defRank{};
    uint8 evaRank{};
    uint8 accRank{};

    uint16 m_MobSkillList{};

    // magic stuff
    uint16 spellList{};

    // resists
    int16 slash_sdt{};
    int16 pierce_sdt{};
    int16 hth_sdt{};
    int16 impact_sdt{};

    int16 magical_sdt{};

    int16 fire_sdt{};
    int16 ice_sdt{};
    int16 wind_sdt{};
    int16 earth_sdt{};
    int16 thunder_sdt{};
    int16 water_sdt{};
    int16 light_sdt{};
    int16 dark_sdt{};

    int8 fire_res_rank{};
    int8 ice_res_rank{};
    int8 wind_res_rank{};
    int8 earth_res_rank{};
    int8 thunder_res_rank{};
    int8 water_res_rank{};
    int8 light_res_rank{};
    int8 dark_res_rank{};

    int8 paralyze_res_rank{};
    int8 bind_res_rank{};
    int8 silence_res_rank{};
    int8 slow_res_rank{};
    int8 poison_res_rank{};
    int8 light_sleep_res_rank{};
    int8 dark_sleep_res_rank{};
    int8 blind_res_rank{};
    int8 stun_res_rank{};
    int8 gravity_res_rank{};
};

HashMap<uint16, std::unique_ptr<TrustData>> g_PTrustData;

} // namespace

void trustutils::LoadTrustList()
{
    const auto rset = db::preparedStmt("SELECT "
                                       "spell_list.spellid, mob_pools.poolid "
                                       "FROM spell_list, mob_pools "
                                       "WHERE spell_list.spellid >= 896 AND mob_pools.poolid = (spell_list.spellid + 5000) ORDER BY spell_list.spellid");

    if (rset && rset->rowsCount())
    {
        while (rset->next())
        {
            const auto trustSpellId = rset->get<uint32>(0);
            BuildTrustData(trustSpellId);
        }
    }
}

auto trustutils::SpawnTrust(CCharEntity* PMaster, uint32 TrustID, const SquadSpec* spec) -> CTrustEntity*
{
    CTrustEntity* PTrust = LoadTrust(PMaster, TrustID, spec);
    if (PTrust == nullptr)
    {
        return nullptr;
    }

    if (PMaster->PParty == nullptr)
    {
        PMaster->PParty = new CParty(PMaster);
        PMaster->PParty->MarkFormedByTrusts();
    }

    PMaster->PTrusts.insert(PMaster->PTrusts.end(), PTrust);
    PMaster->StatusEffectContainer->CopyConfrontationEffect(PTrust);
    PTrust->setBattleID(PMaster->getBattleID());

    if (PMaster->PBattlefield)
    {
        PTrust->PBattlefield = PMaster->PBattlefield;
    }

    if (PMaster->PInstance)
    {
        PTrust->PInstance = PMaster->PInstance;
    }

    PMaster->loc.zone->InsertTRUST(PTrust);
    PTrust->Spawn();

    PMaster->PParty->ReloadParty();

    return PTrust;
}

void trustutils::BuildSquadSkills(CTrustEntity* PTrust)
{
    BuildSquadSkillsImpl(PTrust);
}

namespace
{

void BuildTrustData(uint32 TrustID)
{
    const auto rset = db::preparedStmt("SELECT "
                                       "mob_pools.poolid, "
                                       "mob_pools.name, "
                                       "mob_pools.packet_name, "
                                       "mob_pools.modelid, "
                                       "mob_pools.speciesid, "
                                       "mob_pools.mJob, "
                                       "mob_pools.sJob, "
                                       "mob_pools.spellList, "
                                       "mob_pools.cmbSkill, "
                                       "mob_pools.cmbDelay, "
                                       "mob_pools.cmbDmgMult, "
                                       "mob_pools.name_prefix, "
                                       "mob_pools.skill_list_id, "
                                       "mob_pools.modelSize, "
                                       "mob_pools.modelHitboxSize, "
                                       "spell_list.spellid, "
                                       "mob_resistances.slash_sdt, mob_resistances.pierce_sdt, "
                                       "mob_resistances.h2h_sdt, mob_resistances.impact_sdt, "
                                       "mob_resistances.magical_sdt, "
                                       "mob_resistances.fire_sdt, mob_resistances.ice_sdt, "
                                       "mob_resistances.wind_sdt, mob_resistances.earth_sdt, "
                                       "mob_resistances.lightning_sdt, mob_resistances.water_sdt, "
                                       "mob_resistances.light_sdt, mob_resistances.dark_sdt, "
                                       "mob_resistances.fire_res_rank, mob_resistances.ice_res_rank, "
                                       "mob_resistances.wind_res_rank, mob_resistances.earth_res_rank, "
                                       "mob_resistances.lightning_res_rank, mob_resistances.water_res_rank, "
                                       "mob_resistances.light_res_rank, mob_resistances.dark_res_rank, "
                                       "mob_resistances.paralyze_res_rank, mob_resistances.bind_res_rank, "
                                       "mob_resistances.silence_res_rank, mob_resistances.slow_res_rank, "
                                       "mob_resistances.poison_res_rank, mob_resistances.light_sleep_res_rank, "
                                       "mob_resistances.dark_sleep_res_rank, mob_resistances.blind_res_rank, "
                                       "mob_resistances.stun_res_rank, mob_resistances.gravity_res_rank "
                                       "FROM spell_list, mob_pools, mob_resistances "
                                       "WHERE spell_list.spellid = ? "
                                       "AND (spell_list.spellid + 5000) = mob_pools.poolid "
                                       "AND mob_pools.resist_id = mob_resistances.resist_id "
                                       "ORDER BY spell_list.spellid",
                                       TrustID);

    if (rset && rset->rowsCount())
    {
        while (rset->next())
        {
            auto data = std::make_unique<TrustData>();

            data->trustID = TrustID;

            if (passiveTrustIDs.contains(static_cast<SpellID>(data->trustID)))
            {
                data->isPassiveTrust = true;
            }

            data->pool        = rset->get<uint32>("poolid");
            data->name        = rset->get<std::string>("name");
            data->packet_name = rset->get<std::string>("packet_name");

            db::extractFromBlob(rset, "modelid", data->look);

            data->m_Species = rset->get<uint16>("speciesid");
            data->mJob      = rset->get<uint8>("mJob");
            data->sJob      = rset->get<uint8>("sJob");
            data->spellList = rset->get<uint16>("spellList");

            data->cmbSkill   = rset->get<uint8>("cmbSkill");
            data->cmbDelay   = rset->get<uint16>("cmbDelay");
            data->cmbDmgMult = rset->get<uint16>("cmbDmgMult");

            data->name_prefix    = rset->get<uint8>("name_prefix");
            data->m_MobSkillList = rset->get<uint16>("skill_list_id");

            data->modelSize       = rset->getOrDefault<uint8>("modelSize", 0);
            data->modelHitboxSize = std::max<float>(0.0f, rset->getOrDefault<float>("modelHitboxSize", 0) / 10.f);
            const auto& species   = mobutils::GetSpeciesData(data->m_Species);

            data->EcoSystem = species.Ecosystem;

            data->baseSpeed      = 62;
            data->animationSpeed = 50;

            mobutils::ApplyStatRanks(*data, species.MobAttributes.Stats);

            // resistances
            data->slash_sdt  = rset->get<int16>("slash_sdt");
            data->pierce_sdt = rset->get<int16>("pierce_sdt");
            data->hth_sdt    = rset->get<int16>("h2h_sdt");
            data->impact_sdt = rset->get<int16>("impact_sdt");

            data->magical_sdt = rset->get<int16>("magical_sdt"); // Modifier 389, base 10000 stored as signed integer. Positives signify less damage.

            data->fire_sdt    = rset->get<int16>("fire_sdt");      // Modifier 54, base 10000 stored as signed integer. Positives signify less damage.
            data->ice_sdt     = rset->get<int16>("ice_sdt");       // Modifier 55, base 10000 stored as signed integer. Positives signify less damage.
            data->wind_sdt    = rset->get<int16>("wind_sdt");      // Modifier 56, base 10000 stored as signed integer. Positives signify less damage.
            data->earth_sdt   = rset->get<int16>("earth_sdt");     // Modifier 57, base 10000 stored as signed integer. Positives signify less damage.
            data->thunder_sdt = rset->get<int16>("lightning_sdt"); // Modifier 58, base 10000 stored as signed integer. Positives signify less damage.
            data->water_sdt   = rset->get<int16>("water_sdt");     // Modifier 59, base 10000 stored as signed integer. Positives signify less damage.
            data->light_sdt   = rset->get<int16>("light_sdt");     // Modifier 60, base 10000 stored as signed integer. Positives signify less damage.
            data->dark_sdt    = rset->get<int16>("dark_sdt");      // Modifier 61, base 10000 stored as signed integer. Positives signify less damage.

            data->fire_res_rank    = rset->get<int8>("fire_res_rank");
            data->ice_res_rank     = rset->get<int8>("ice_res_rank");
            data->wind_res_rank    = rset->get<int8>("wind_res_rank");
            data->earth_res_rank   = rset->get<int8>("earth_res_rank");
            data->thunder_res_rank = rset->get<int8>("lightning_res_rank");
            data->water_res_rank   = rset->get<int8>("water_res_rank");
            data->light_res_rank   = rset->get<int8>("light_res_rank");
            data->dark_res_rank    = rset->get<int8>("dark_res_rank");

            data->paralyze_res_rank    = rset->get<int8>("paralyze_res_rank");
            data->bind_res_rank        = rset->get<int8>("bind_res_rank");
            data->silence_res_rank     = rset->get<int8>("silence_res_rank");
            data->slow_res_rank        = rset->get<int8>("slow_res_rank");
            data->poison_res_rank      = rset->get<int8>("poison_res_rank");
            data->light_sleep_res_rank = rset->get<int8>("light_sleep_res_rank");
            data->dark_sleep_res_rank  = rset->get<int8>("dark_sleep_res_rank");
            data->blind_res_rank       = rset->get<int8>("blind_res_rank");
            data->stun_res_rank        = rset->get<int8>("stun_res_rank");
            data->gravity_res_rank     = rset->get<int8>("gravity_res_rank");

            g_PTrustData[TrustID] = std::move(data);
        }
    }
}

// Squad mates: the spell list of the first (lowest id) non-passive trust whose main job is `job`.
// A squad mate's sub job spells come from that list, at the sub level.
auto SquadSubJobSpellList(uint8 job) -> uint16
{
    const TrustData* best = nullptr;
    for (const auto& entry : g_PTrustData)
    {
        const TrustData* data = entry.second.get();
        if (data != nullptr && data->mJob == job && !data->isPassiveTrust && (best == nullptr || data->trustID < best->trustID))
        {
            best = data;
        }
    }

    return best != nullptr ? best->spellList : 0;
}

auto LoadTrust(CCharEntity* PMaster, uint32 TrustID, const trustutils::SquadSpec* spec) -> CTrustEntity*
{
    const auto itr = g_PTrustData.find(TrustID);
    if (itr == g_PTrustData.end())
    {
        ShowError(fmt::format("Could not look up trust data for id: {}", TrustID));
        return nullptr;
    }

    auto* trustData = itr->second.get();

    // XI: Forever Offline: a squad mate that borrows the body of a passive template (Brygid, the GEO template; Cornelia, the body Squads gives
    // Summoner, Blue Mage, Corsair and Puppetmaster) is a real party member: targetable, able to cast. A passive trust is untargetable and
    // spell::CanUseSpell refuses every spell for an untargetable caster, so a squad GEO or BLU could never complete a cast.
    const bool passiveTemplate = trustData->isPassiveTrust && spec == nullptr;
    auto*      PTrust          = new CTrustEntity(PMaster, trustData->trustID, IsPassiveTrust{ passiveTemplate });

    PTrust->loc       = PMaster->loc;
    PTrust->m_OwnerID = EntityId(PMaster);

    // spawn me randomly around master
    PTrust->loc.p = nearPosition(PMaster->loc.p, CTrustController::SpawnDistance + (PMaster->PTrusts.size() * CTrustController::SpawnDistance), (float)M_PI);

    // Keep the spawn spot on the navmesh and on the master's side of any wall: walking the navmesh from the master
    // toward the spot stops at the first wall (pulled 1 yalm back so the body is not half in it), so a mate can no longer spawn inside or behind one.
    if (PMaster->loc.zone != nullptr)
    {
        if (auto* navMesh = PMaster->loc.zone->navMesh())
        {
            if (const auto walked = walkTowardsWithMargin(*navMesh, PMaster->loc.p, PTrust->loc.p, 1.0f))
            {
                PTrust->loc.p.x = walked->x;
                PTrust->loc.p.y = walked->y;
                PTrust->loc.p.z = walked->z;
            }
            else if (!navMesh->validPosition(PTrust->loc.p))
            {
                if (const auto closest = navMesh->findClosestValidPoint(PTrust->loc.p))
                {
                    PTrust->loc.p.x = closest->x;
                    PTrust->loc.p.y = closest->y;
                    PTrust->loc.p.z = closest->z;
                }
            }
        }
    }
    PTrust->look  = trustData->look;
    PTrust->name  = trustData->name;

    PTrust->m_Pool         = trustData->pool;
    PTrust->packetName     = trustData->packet_name;
    PTrust->m_name_prefix  = trustData->name_prefix;
    PTrust->m_Species      = trustData->m_Species;
    PTrust->m_MobSkillList = trustData->m_MobSkillList;
    PTrust->HPscale        = trustData->HPscale;
    PTrust->MPscale        = trustData->MPscale;
    PTrust->baseSpeed      = trustData->baseSpeed;
    PTrust->animationSpeed = trustData->animationSpeed;

    PTrust->UpdateSpeed();

    PTrust->status          = xi::Status::Normal;
    PTrust->modelSize       = trustData->modelSize;
    PTrust->modelHitboxSize = trustData->modelHitboxSize;
    PTrust->m_EcoSystem     = trustData->EcoSystem;

    if (spec != nullptr)
    {
        // Squad mate: job, subjob and level come from the squad record, not from the trust or the master
        PTrust->SetMJob(spec->mJob);
        PTrust->SetSJob(spec->sJob);
        PTrust->SetMLevel(spec->mLevel);

        uint8 squadSubLevel = 0;
        if (spec->sJob != 0)
        {
            squadSubLevel = spec->sLevel != 0 ? spec->sLevel : static_cast<uint8>(spec->mLevel / 2);
        }
        PTrust->SetSLevel(squadSubLevel);
        PTrust->setSquadId(spec->squadId);
        PTrust->setSquadRace(spec->race);

        // Player-style appearance (race, face and armor), set now so it is part of the first spawn message
        if (spec->hasLook)
        {
            PTrust->look.size   = 1; // MODEL_EQUIPPED
            PTrust->look.race   = spec->race;
            PTrust->look.face   = spec->face;
            PTrust->look.head   = spec->lookHead;
            PTrust->look.body   = spec->lookBody;
            PTrust->look.hands  = spec->lookHands;
            PTrust->look.legs   = spec->lookLegs;
            PTrust->look.feet   = spec->lookFeet;
            PTrust->look.main   = spec->lookMain;
            PTrust->look.sub    = spec->lookSub;
            PTrust->look.ranged = spec->lookRanged;
            if (spec->bodySize >= 1 && spec->bodySize <= 3)
            {
                PTrust->modelSize = static_cast<uint8>(spec->bodySize - 1); // sent as the body size in entity updates
            }
        }
        PTrust->SetLocalVar("SQUAD_ID", spec->squadId);
        PTrust->SetLocalVar("SQUAD_SIZE", spec->bodySize);

        // (XI: Forever Offline, squad audit N10) a squad mate is a player-like character: Humanoid, as CCharEntity sets
        // for players, not its template's species (Gessho, the NIN template, is a Yagudo: Beastmen). The hitbox is
        // still the template's (audit N9, a separate decision).
        PTrust->m_EcoSystem = xi::Ecosystem::Humanoid;
    }
    else
    {
        PTrust->SetMJob(trustData->mJob);
        PTrust->SetSJob(trustData->sJob);

        // assume level matches master
        PTrust->SetMLevel(PMaster->GetMLevel());
        PTrust->SetSLevel(std::floor(PMaster->GetMLevel() / 2));
    }

    LoadTrustStatsAndSkills(PTrust);

    // Use Mob formulas to work out base "weapon" damage, but scale down to reasonable values.
    // TODO: Verify trust base damage.
    const float  mobStyleDamage   = static_cast<float>(mobutils::GetBaseWeaponDamage(PTrust, SLOT_MAIN));
    const float  baseDamage       = mobStyleDamage * 0.5f;
    const float  damageMultiplier = static_cast<float>(trustData->cmbDmgMult) / 100.0f;
    const float  adjustedDamage   = baseDamage * damageMultiplier;
    const uint16 finalDamage      = static_cast<uint16>(std::max(adjustedDamage, 1.0f));

    // Trust do not really have weapons, but they are modelled internally as
    // if they do.
    if (auto* mainWeapon = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_MAIN]))
    {
        mainWeapon->setMaxHit(1);
        mainWeapon->setSkillType(static_cast<xi::SkillType>(trustData->cmbSkill));

        mainWeapon->setDamage(finalDamage);
        mainWeapon->setDelay(trustData->cmbDelay);
        mainWeapon->setBaseDelay(trustData->cmbDelay);

        // Compute DPS so rune/enchantment calculations that rely on getDPS() return meaningful values for trusts.
        // Use damage per second: damage / (delay_seconds). Delay is stored in ms.
        if (mainWeapon->getDelay() > 0)
        {
            double dps = static_cast<double>(mainWeapon->getDamage()) / (static_cast<double>(mainWeapon->getDelay()) / 1000.0);
            mainWeapon->setDPS(dps);
        }
    }

    if (auto* subWeapon = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_SUB]))
    {
        subWeapon->setDamage(finalDamage);
        subWeapon->setDelay(trustData->cmbDelay);
        subWeapon->setBaseDelay(trustData->cmbDelay);

        if (subWeapon->getDelay() > 0)
        {
            double dps = static_cast<double>(subWeapon->getDamage()) / (static_cast<double>(subWeapon->getDelay()) / 1000.0);
            subWeapon->setDPS(dps);
        }
    }

    if (auto* rangedWeapon = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_RANGED]))
    {
        rangedWeapon->setDamage(finalDamage);
        rangedWeapon->setDelay(trustData->cmbDelay);
        rangedWeapon->setBaseDelay(trustData->cmbDelay);

        if (rangedWeapon->getDelay() > 0)
        {
            double dps = static_cast<double>(rangedWeapon->getDamage()) / (static_cast<double>(rangedWeapon->getDelay()) / 1000.0);
            rangedWeapon->setDPS(dps);
        }
    }

    if (auto* ammoWeapon = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_AMMO]))
    {
        ammoWeapon->setDamage(finalDamage);
        ammoWeapon->setDelay(trustData->cmbDelay);
        ammoWeapon->setBaseDelay(trustData->cmbDelay);

        if (ammoWeapon->getDelay() > 0)
        {
            double dps = static_cast<double>(ammoWeapon->getDamage()) / (static_cast<double>(ammoWeapon->getDelay()) / 1000.0);
            ammoWeapon->setDPS(dps);
        }
    }

    // NOTE: Trusts don't really have weapons, and they don't really have combat skills. They only have
    // a damage type, and whether or not they are multi-hit. We handle this wrong everywhere.
    // To give any Trust multi-hit, you need to give them cmbSkill == xi::SkillType::HandToHand (1).
    if (trustData->cmbSkill == static_cast<uint8>(xi::SkillType::HandToHand))
    {
        PTrust->m_dualWield = true;
    }

    auto* spellList = trustData->spellList != 0 ? mobSpellList::GetMobSpellList(trustData->spellList) : nullptr;
    if (spellList != nullptr)
    {
        mobutils::SetSpellList(PTrust, trustData->spellList);
    }

    // Squad mates also get their sub job's spells: every spell on the sub job's list that fits the sub level.
    // This runs even when the main job's template has no spell list of its own (WAR, MNK, THF, SAM, RNG and
    // COR templates are like that), so a WAR/WHM still gets Cure and Protect from the sub job.
    if (spec != nullptr && spec->sJob != 0 && PTrust->SpellContainer != nullptr)
    {
        const uint16 subListId = SquadSubJobSpellList(spec->sJob);
        auto*        subList   = subListId != 0 ? mobSpellList::GetMobSpellList(subListId) : nullptr;
        if (subList != nullptr)
        {
            const uint8 subLevel  = PTrust->GetSLevel();
            const uint8 mainLevel = PTrust->GetMLevel();
            const auto* mainList  = PTrust->m_SpellListContainer;

            for (const auto& subSpell : subList->m_spellList)
            {
                if (subLevel < subSpell.min_level || subLevel > subSpell.max_level)
                {
                    continue;
                }

                // Skip spells the main job's list already gives at the main level
                const bool alreadyHave = mainList != nullptr && std::ranges::any_of(mainList->m_spellList, [&](const MobSpell_t& mainSpell)
                                                                                    { return mainSpell.spellId == subSpell.spellId && mainLevel >= mainSpell.min_level && mainLevel <= mainSpell.max_level; });
                if (!alreadyHave)
                {
                    PTrust->SpellContainer->AddSpell(subSpell.spellId);
                }
            }
        }
    }

    // Squad mates know every spell their jobs can learn at their levels, with no scrolls: the main job at the main
    // level and the sub job at the sub level. This list is what the game checks when a spell is cast on request.
    if (spec != nullptr)
    {
        auto*       known     = new CMobSpellList(Maybe<uint16>{});
        const uint8 mainLevel = PTrust->GetMLevel();
        const uint8 subLevel  = PTrust->GetSLevel();
        const auto  mainJob   = PTrust->GetMJob();
        const auto  subJob    = PTrust->GetSJob();

        // (2026-11-17) the trust template's own list only where the mate's jobs really have the spell at their levels: the
        // template is a Trust NPC's, whose list doesn't follow job levels (sparkiie: a level 39 RDM cast Phalanx II
        // and Distract). A template spell that no job at all learns (a Trust NPC's own spell) is kept as before; one that
        // other jobs learn but not the mate's is not (Joachim, Shikaree Z and Nashmeira are BRD/DRG/PUP with WHM sub jobs:
        // their Cure, -na spells and Erase went to a squad BRD/BLM).
        if (PTrust->m_SpellListContainer != nullptr)
        {
            for (const auto& entry : PTrust->m_SpellListContainer->m_spellList)
            {
                CSpell* PListed = spell::GetSpell(entry.spellId);
                if (PListed == nullptr)
                {
                    continue;
                }

                const uint8 byMain = PListed->getJob(mainJob);
                const uint8 bySub  = spec->sJob != 0 ? PListed->getJob(subJob) : 255;
                const bool  jobOk  = byMain <= mainLevel || bySub <= subLevel;
                bool        noJob  = true;
                for (uint8 job = 1; job < MAX_JOBTYPE && noJob; ++job)
                {
                    noJob = PListed->getJob(static_cast<xi::Job>(job)) == 255;
                }
                // (a job spell with no scroll is a monster's copy, e.g. Diaga II; blue magic and summons have none)
                const auto  group    = PListed->getSpellGroup();
                const bool  noScroll = group != SPELLGROUP_BLUE && group != SPELLGROUP_SUMMONING &&
                                      xi::items::lookup(static_cast<uint16>(0x1200 + static_cast<uint16>(entry.spellId))) == nullptr;
                if ((jobOk && !noScroll) || noJob)
                {
                    // A Trust NPC's list can give a spell later than the mate's jobs learn it (Excenmille: Flash at 45, a PLD
                    // learns it at 37, and Cure at 5, a PLD/WHM has it from level 2; Kupipi: Paralyze at 6, a WHM learns it at
                    // 4). A trust's casting check reads the first entry of a spell (CMobSpellList::GetSpellMinLevel), and this
                    // one comes first, so it gets the level the mate really has the spell at: the main job's level, or 0 when
                    // only the sub job gives it (as the job spells below). Template-only entries keep their level.
                    uint16 minLevel = entry.min_level;
                    if (byMain <= mainLevel)
                    {
                        minLevel = std::min<uint16>(minLevel, byMain);
                    }
                    else if (bySub <= subLevel)
                    {
                        minLevel = 0;
                    }

                    known->AddSpell(entry.spellId, minLevel, entry.max_level);
                }
            }
        }

        for (uint16 id = 1; id < MAX_SPELL_ID; ++id)
        {
            CSpell* PSpell = spell::GetSpell(static_cast<SpellID>(id));
            if (PSpell == nullptr)
            {
                continue;
            }

            const auto group = PSpell->getSpellGroup();
            // (geomancy is in: Indi and Geo spells are learned from the job's own levels, only a GEO has them)
            if (group == SPELLGROUP_TRUST || group == SPELLGROUP_SUMMONING)
            {
                continue;
            }

            // FFXI Offline: blue magic only for a squad Blue Mage (main or sub job)
            if (group == SPELLGROUP_BLUE && mainJob != xi::Job::BLU && subJob != xi::Job::BLU)
            {
                continue;
            }

            // (2026-11-18) a spell players learn comes on a scroll (item 4608 + spell id). One with no scroll item is a
            // monster's version that only shares the job levels in the data (wildthing: a RDM mate knew Diaga II).
            // Blue magic is learned from monsters, so it has no scrolls and is left alone.
            if (group != SPELLGROUP_BLUE && xi::items::lookup(static_cast<uint16>(0x1200 + id)) == nullptr)
            {
                continue;
            }

            const bool learnedByMain = PSpell->getJob(mainJob) <= mainLevel;
            const bool learnedBySub  = spec->sJob != 0 && PSpell->getJob(subJob) <= subLevel;
            if (!learnedByMain && !learnedBySub)
            {
                continue;
            }

            const bool alreadyListed = std::ranges::any_of(known->m_spellList, [&](const MobSpell_t& listed)
                                                           { return listed.spellId == static_cast<SpellID>(id) && mainLevel >= listed.min_level && mainLevel <= listed.max_level; });
            if (!alreadyListed)
            {
                known->AddSpell(static_cast<SpellID>(id), 0, 255);
            }
        }

        // (squad option "spells from scrolls") a spell this mate only gets at level 18 or above stays only when the
        // squad has learned it; spells from below 18 stay automatic. Entries no job of the mate learns are kept.
        if (spec->spellScrolls)
        {
            auto* kept = new CMobSpellList(Maybe<uint16>{});
            for (const auto& entry : known->m_spellList)
            {
                uint8 at = 255;
                if (CSpell* PSpell = spell::GetSpell(entry.spellId))
                {
                    const uint8 byMain = PSpell->getJob(mainJob);
                    if (byMain <= mainLevel)
                    {
                        at = byMain;
                    }

                    if (spec->sJob != 0)
                    {
                        const uint8 bySub = PSpell->getJob(subJob);
                        if (bySub <= subLevel && bySub < at)
                        {
                            at = bySub;
                        }
                    }
                }

                // (geomancy cannot be learned from a scroll in the squad window: a GEO keeps her Indi and Geo spells)
                const auto* PKept   = spell::GetSpell(entry.spellId);
                const bool  geomancy = PKept != nullptr && PKept->getSpellGroup() == SPELLGROUP_GEOMANCY;
                const bool learned = std::ranges::find(spec->learnedSpells, static_cast<uint16>(entry.spellId)) != spec->learnedSpells.end();
                if (at < 18 || at == 255 || learned || geomancy)
                {
                    kept->AddSpell(entry.spellId, entry.min_level, entry.max_level);
                }
            }

            delete known;
            known = kept;
        }

        // (2026-11-17) a squad Blue Mage sets its blue magic like a player: a player's slots and set points at that
        // level, the player's chosen set (spec->blueSet) or else an automatic one (spec->bluePrefer first, then the
        // strongest it knows). Blue magic that isn't set is dropped from what it can cast, and the set spells give
        // their stat bonuses and blue traits. What was set is left in local vars SQUAD_BLU_* for the Squad window.
        if (mainJob == xi::Job::BLU || subJob == xi::Job::BLU)
        {
            const uint8 bluLevel = mainJob == xi::Job::BLU ? mainLevel : subLevel;
            const int   slots    = bluLevel == 0 ? 0 : std::clamp(((bluLevel - 1) / 10) * 2 + 6, 6, 20);
            const int   points   = bluLevel == 0 ? 0 : std::clamp(((bluLevel - 1) / 10) * 5 + 10, 0, 55);

            auto knows = [&](uint16 id)
            {
                return std::ranges::any_of(known->m_spellList, [&](const MobSpell_t& e)
                                           { return static_cast<uint16>(e.spellId) == id; });
            };

            std::vector<uint16> order;
            if (!spec->blueSet.empty())
            {
                order = spec->blueSet;
            }
            else
            {
                order = spec->bluePrefer;
                std::vector<std::pair<uint8, uint16>> rest;
                for (const auto& e : known->m_spellList)
                {
                    if (auto* PBlue = dynamic_cast<CBlueSpell*>(spell::GetSpell(e.spellId)))
                    {
                        rest.emplace_back(PBlue->getJob(xi::Job::BLU), static_cast<uint16>(e.spellId));
                    }
                }

                std::ranges::sort(rest, [](const auto& a, const auto& b) { return a.first > b.first; });
                for (const auto& r : rest)
                {
                    order.push_back(r.second);
                }
            }

            std::vector<CBlueSpell*> set;
            int                      used = 0;
            for (const uint16 id : order)
            {
                if (static_cast<int>(set.size()) >= slots)
                {
                    break;
                }

                auto* PBlue = dynamic_cast<CBlueSpell*>(spell::GetSpell(static_cast<SpellID>(id)));
                if (!PBlue || !knows(id) || PBlue->getJob(xi::Job::BLU) > bluLevel || std::ranges::find(set, PBlue) != set.end())
                {
                    continue;
                }

                if (used + PBlue->getSetPoints() > points)
                {
                    continue;
                }

                used += PBlue->getSetPoints();
                set.push_back(PBlue);
            }

            auto* setOnly = new CMobSpellList(Maybe<uint16>{});
            for (const auto& entry : known->m_spellList)
            {
                auto* PBlue = dynamic_cast<CBlueSpell*>(spell::GetSpell(entry.spellId));
                if (PBlue && std::ranges::find(set, PBlue) == set.end())
                {
                    continue; // (blue magic that isn't set)
                }

                setOnly->AddSpell(entry.spellId, entry.min_level, entry.max_level);
            }

            delete known;
            known = setOnly;

            // stat bonuses and blue traits, the way blueutils::CalculateTraits works them out for a player
            std::map<uint8, uint16> weights;
            for (auto* PBlue : set)
            {
                PTrust->addModifiers(&PBlue->modList);
                weights[PBlue->getTraitCategory()] += PBlue->getTraitWeight();
            }

            std::vector<CBlueTrait*> traitsToAdd;
            if (TraitList_t* PTraitsList = traits::GetTraits(xi::Job::BLU))
            {
                for (const auto& [category, weight] : weights)
                {
                    for (auto* PTrait : *PTraitsList)
                    {
                        auto* PBlueTrait = dynamic_cast<CBlueTrait*>(PTrait);
                        if (PTrait->getLevel() != 0 || !PBlueTrait || PBlueTrait->getCategory() != category || weight < PBlueTrait->getPoints() ||
                            PBlueTrait->getJobPointsOnly())
                        {
                            continue;
                        }

                        std::erase_if(traitsToAdd, [&](CBlueTrait* have)
                                      { return have->getID() == PBlueTrait->getID() && have->getMod() == PBlueTrait->getMod() && have->getRank() <= PBlueTrait->getRank(); });
                        traitsToAdd.push_back(PBlueTrait);
                    }
                }
            }

            for (auto* PBlueTrait : traitsToAdd)
            {
                PTrust->addTrait(PBlueTrait);
            }

            PTrust->SetLocalVar("SQUAD_BLU_SLOTS", slots);
            PTrust->SetLocalVar("SQUAD_BLU_POINTS", points);
            PTrust->SetLocalVar("SQUAD_BLU_USED", used);
            PTrust->SetLocalVar("SQUAD_BLU_AUTO", spec->blueSet.empty() ? 1 : 0);
            PTrust->SetLocalVar("SQUAD_BLU_COUNT", static_cast<uint32>(set.size()));
            for (size_t i = 0; i < set.size(); ++i)
            {
                PTrust->SetLocalVar(fmt::format("SQUAD_BLU_{}", i + 1), static_cast<uint32>(set[i]->getID()));
            }

            PTrust->UpdateHealth();
        }

        PTrust->setSquadSpellList(known);
        PTrust->m_SpellListContainer = known;

        // Rebuild the castable container from the full known list. The template's own list is
        // often only one slice of the job (Rainemard, the RDM template, has nukes but no Dia,
        // Cure, Slow, Haste, Protect or Shell), so without this the gambits had nothing to cast.
        if (PTrust->SpellContainer != nullptr)
        {
            PTrust->SpellContainer->ClearSpells();
            std::set<SpellID> castable;
            for (const auto& entry : known->m_spellList)
            {
                if (mainLevel < entry.min_level || mainLevel > entry.max_level)
                {
                    continue;
                }

                if (castable.insert(entry.spellId).second)
                {
                    PTrust->SpellContainer->AddSpell(entry.spellId);
                }
            }
        }
    }

    return PTrust;
}

// XI: Forever Offline: a squad Dragoon borrows the body of the Dragoon trust template (Shikaree Z), and with it her pool
// modifier MPP +100 (mob_pool_mods). That is her own trait, not a Dragoon's, so a squad Dragoon (local var SQUAD_ID, main
// job DRG) gives that MPP back right after mobutils::AddSqlModifiers added it. Nothing else changes: other pool modifiers,
// other squad jobs, ordinary trusts (Shikaree Z herself), and MP from the job, sub job and gear.
void RemoveTemplateMppFromSquadDragoon(CTrustEntity* PTrust)
{
    if (PTrust == nullptr || PTrust->GetLocalVar("SQUAD_ID") == 0 || PTrust->GetMJob() != xi::Job::DRG)
    {
        return;
    }

    if (const ModsList_t* PPoolMods = mobutils::GetMobPoolMods(PTrust->m_Pool))
    {
        for (const auto* mod : PPoolMods->mods)
        {
            if (mod->getModID() == xi::Mod::MPP)
            {
                PTrust->delModifier(xi::Mod::MPP, mod->getModAmount());
            }
        }
    }
}

// (XI: Forever Offline, squad audit N1) a squad mate's skills, the way charutils::BuildingCharSkillsTable works them out
// for a player who has capped every skill: the main job's cap at the main level when the main job has the skill, else
// the sub job's cap at the sub level, plus the skill modifiers from gear and traits (mod = skill + 79). Combat skills
// 1-12, ranged and defensive skills 25-31 (Archery to Parry) and magic skills 32-45 (Singing and the instruments too).
// Automaton skills are left out: a squad Puppetmaster has no automaton. ALTER_EGO_SKILL_MULTIPLIER (1.0 by default)
// still applies, as it did before. Called when the mate is loaded and again after its gear is applied (squad.cpp).
void BuildSquadSkillsImpl(CTrustEntity* PTrust)
{
    if (PTrust == nullptr || !PTrust->isSquadMate())
    {
        return;
    }

    const xi::Job mJob = PTrust->GetMJob();
    const xi::Job sJob = PTrust->GetSJob();
    const uint8   mLvl = std::min<uint8>(PTrust->GetMLevel(), 99);
    const uint8   sLvl = std::min<uint8>(PTrust->GetSLevel(), 99);

    const float multiplier = settings::get<float>("map.ALTER_EGO_SKILL_MULTIPLIER");

    for (int i = 1; i < 46; ++i)
    {
        // unused skill ids, and the automaton's own skills
        if ((i >= 13 && i <= 24))
        {
            continue;
        }

        const auto   skill   = static_cast<xi::SkillType>(i);
        const uint16 mainCap = battleutils::GetMaxSkill(skill, mJob, mLvl);
        const uint16 subCap  = sLvl > 0 ? battleutils::GetMaxSkill(skill, sJob, sLvl) : 0;
        const uint16 cap     = mainCap != 0 ? mainCap : subCap;

        if (cap == 0)
        {
            PTrust->WorkingSkills.skill[i] = 0;
            continue;
        }

        const int32 bonus = PTrust->getMod(static_cast<xi::Mod>(i + 79)); // can be negative (Shiva's Shotel)
        const int32 value = static_cast<int32>(cap * multiplier) + bonus;

        PTrust->WorkingSkills.skill[i] = static_cast<uint16>(std::clamp<int32>(value, 0, 0x7FFF));
    }
}

void LoadTrustStatsAndSkills(CTrustEntity* PTrust)
{
    if (settings::get<uint8>("main.ENABLE_TRUST_ALTER_EGO_EXPO") > 0) // Alter Ego Expo HPP/MPP +50%, All Status Resistance +25%
    {
        PTrust->addModifier(xi::Mod::HPP, 50);
        PTrust->addModifier(xi::Mod::MPP, 50);
        PTrust->addModifier(xi::Mod::STATUSRES, 25);
    }

    // add mob pool mods ahead of applying stats
    mobutils::AddSqlModifiers(PTrust);
    RemoveTemplateMppFromSquadDragoon(PTrust);

    xi::Job mJob = PTrust->GetMJob();
    xi::Job sJob = PTrust->GetSJob();
    uint8   mLvl = PTrust->GetMLevel();
    uint8   sLvl = PTrust->GetSLevel();

    // Helpers to map HP/MPScale around 100 to 1-7 grades
    // std::clamp doesn't play nice with uint8, so -> unsigned int
    auto mapRanges = [](unsigned int inputStart, unsigned int inputEnd, unsigned int outputStart, unsigned int outputEnd, unsigned int inputVal) -> unsigned int
    {
        unsigned int inputRange  = inputEnd - inputStart;
        unsigned int outputRange = outputEnd - outputStart;

        unsigned int output = (inputVal - inputStart) * outputRange / inputRange + outputStart;

        return std::clamp(output, outputStart, outputEnd);
    };

    auto scaleToGrade = [mapRanges](float input) -> unsigned int
    {
        unsigned int multipliedInput    = static_cast<unsigned int>(input * 100U);
        unsigned int reverseMappedGrade = mapRanges(70U, 140U, 1U, 7U, multipliedInput);
        unsigned int outputGrade        = std::clamp(7U - reverseMappedGrade, 1U, 7U);
        return outputGrade;
    };

    // HP/MP ========================
    // This is the same system as used in charutils.cpp, but modified
    // to use parts from data/ecosystems.yaml instead of hardcoded player
    // race tables.

    // http://ffxi-stat-calc.sourceforge.net/cgi-bin/ffxistats.cgi?mode=document

    // HP
    float raceStat  = 0;
    float jobStat   = 0;
    float sJobStat  = 0;
    int32 bonusStat = 0;

    int32 baseValueColumn   = 0;
    int32 scaleTo60Column   = 1;
    int32 scaleOver30Column = 2;
    int32 scaleOver60Column = 3;
    int32 scaleOver75Column = 4;
    int32 scaleOver60       = 2;
    // int32 scaleOver75       = 3;

    uint8 grade = 0;

    int32 mainLevelOver30     = std::clamp(mLvl - 30, 0, 30);
    int32 mainLevelUpTo60     = (mLvl < 60 ? mLvl - 1 : 59);
    int32 mainLevelOver60To75 = std::clamp(mLvl - 60, 0, 15);
    int32 mainLevelOver75     = (mLvl < 75 ? 0 : mLvl - 75);

    int32 mainLevelOver10           = (mLvl < 10 ? 0 : mLvl - 10);
    int32 mainLevelOver50andUnder60 = std::clamp(mLvl - 50, 0, 10);
    int32 mainLevelOver60           = (mLvl < 60 ? 0 : mLvl - 60);

    int32 subLevelOver10 = std::clamp(sLvl - 10, 0, 20);
    int32 subLevelOver30 = (sLvl < 30 ? 0 : sLvl - 30);

    grade = scaleToGrade(PTrust->HPscale);

    raceStat = grade::GetHPScale(grade, baseValueColumn) + (grade::GetHPScale(grade, scaleTo60Column) * mainLevelUpTo60) +
               (grade::GetHPScale(grade, scaleOver30Column) * mainLevelOver30) + (grade::GetHPScale(grade, scaleOver60Column) * mainLevelOver60To75) +
               (grade::GetHPScale(grade, scaleOver75Column) * mainLevelOver75);

    grade = grade::GetJobGrade(mJob, 0);

    jobStat = grade::GetHPScale(grade, baseValueColumn) + (grade::GetHPScale(grade, scaleTo60Column) * mainLevelUpTo60) +
              (grade::GetHPScale(grade, scaleOver30Column) * mainLevelOver30) + (grade::GetHPScale(grade, scaleOver60Column) * mainLevelOver60To75) +
              (grade::GetHPScale(grade, scaleOver75Column) * mainLevelOver75);

    bonusStat = (mainLevelOver10 + mainLevelOver50andUnder60) * 2;

    if (sLvl > 0)
    {
        grade = grade::GetJobGrade(sJob, 0);

        sJobStat = grade::GetHPScale(grade, baseValueColumn) + (grade::GetHPScale(grade, scaleTo60Column) * (sLvl - 1)) +
                   (grade::GetHPScale(grade, scaleOver30Column) * subLevelOver30) + subLevelOver30 + subLevelOver10;
    }

    auto hpMultiplierTrust = settings::get<float>("map.ALTER_EGO_HP_MULTIPLIER");
    hpMultiplierTrust      = (hpMultiplierTrust >= 0.1f && hpMultiplierTrust <= 2.0f) ? hpMultiplierTrust : 1.0f;
    PTrust->health.maxhp   = (int16)((raceStat + jobStat + bonusStat + sJobStat) * hpMultiplierTrust);

    // MP
    raceStat = 0;
    jobStat  = 0;
    sJobStat = 0;

    grade = scaleToGrade(PTrust->MPscale);

    if (grade::GetJobGrade(mJob, 1) == 0)
    {
        if (grade::GetJobGrade(sJob, 1) != 0 && sLvl > 0)
        {
            raceStat = (grade::GetMPScale(grade, 0) + grade::GetMPScale(grade, scaleTo60Column) * (sLvl - 1)) / settings::get<uint8>("map.SJ_MP_DIVISOR");
        }
    }
    else
    {
        raceStat = grade::GetMPScale(grade, 0) + grade::GetMPScale(grade, scaleTo60Column) * mainLevelUpTo60 +
                   grade::GetMPScale(grade, scaleOver60) * mainLevelOver60;
    }

    grade = grade::GetJobGrade(mJob, 1);

    if (grade > 0)
    {
        jobStat = grade::GetMPScale(grade, 0) + grade::GetMPScale(grade, scaleTo60Column) * mainLevelUpTo60 +
                  grade::GetMPScale(grade, scaleOver60) * mainLevelOver60;
    }

    if (sLvl > 0)
    {
        grade    = grade::GetJobGrade(sJob, 1);
        sJobStat = grade::GetMPScale(grade, 0) + grade::GetMPScale(grade, scaleTo60Column);
    }

    auto mpMultiplierTrust = settings::get<float>("map.ALTER_EGO_MP_MULTIPLIER");
    mpMultiplierTrust      = (mpMultiplierTrust >= 0.1f && mpMultiplierTrust <= 2.0f) ? mpMultiplierTrust : 1.0f;
    PTrust->health.maxmp   = (int16)((raceStat + jobStat + sJobStat) * mpMultiplierTrust);

    // Squad mates grow like a real player of their race, job and level (the same tables the game uses for characters)
    uint8      squadRaceGroup = 0;
    const bool useRaceTables  = PTrust->squadRace() != 0;
    if (useRaceTables)
    {
        switch (PTrust->squadRace())
        {
            case 3:
            case 4:
                squadRaceGroup = 1; // Elvaan
                break;
            case 5:
            case 6:
                squadRaceGroup = 2; // Tarutaru
                break;
            case 7:
                squadRaceGroup = 3; // Mithra
                break;
            case 8:
                squadRaceGroup = 4; // Galka
                break;
            default:
                squadRaceGroup = 0; // Hume
                break;
        }

        // (XI: Forever Offline, 2026-11-22, delukard) the "Your HP" / "Your MP" rules count for squad mates too
        // (charutils::CalculateStats has the player's side). 1.0 is the era; missing or zero counts as 1.0.
        const auto vitalRate = [](std::string_view key) -> float
        {
            const float rate = settings::get<float>(key);
            return rate > 0.0f ? std::clamp(rate, 0.5f, 3.0f) : 1.0f;
        };

        const float squadBaseHP = static_cast<float>(grade::GetBaseHP(squadRaceGroup, grade::GetJobGrade(mJob, 0), mLvl, grade::GetJobGrade(sJob, 0), sLvl));
        const float squadBaseMP = static_cast<float>(grade::GetBaseMP(squadRaceGroup, grade::GetJobGrade(mJob, 1), mLvl, grade::GetJobGrade(sJob, 1), sLvl));

        PTrust->health.maxhp = static_cast<int16>(std::min(30000.0f, squadBaseHP * vitalRate("map.PLAYER_HP_MULTIPLIER")));
        PTrust->health.maxmp = static_cast<int16>(std::min(30000.0f, squadBaseMP * vitalRate("map.PLAYER_MP_MULTIPLIER")));
    }

    PTrust->health.tp = 0;
    PTrust->UpdateHealth();
    PTrust->health.hp = PTrust->GetMaxHP();
    PTrust->health.mp = PTrust->GetMaxMP();

    // Stats ========================
    uint16 fSTR = mobutils::GetBaseToRank(PTrust->strRank, mLvl);
    uint16 fDEX = mobutils::GetBaseToRank(PTrust->dexRank, mLvl);
    uint16 fVIT = mobutils::GetBaseToRank(PTrust->vitRank, mLvl);
    uint16 fAGI = mobutils::GetBaseToRank(PTrust->agiRank, mLvl);
    uint16 fINT = mobutils::GetBaseToRank(PTrust->intRank, mLvl);
    uint16 fMND = mobutils::GetBaseToRank(PTrust->mndRank, mLvl);
    uint16 fCHR = mobutils::GetBaseToRank(PTrust->chrRank, mLvl);

    uint16 mSTR = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetMJob(), 2), mLvl);
    uint16 mDEX = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetMJob(), 3), mLvl);
    uint16 mVIT = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetMJob(), 4), mLvl);
    uint16 mAGI = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetMJob(), 5), mLvl);
    uint16 mINT = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetMJob(), 6), mLvl);
    uint16 mMND = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetMJob(), 7), mLvl);
    uint16 mCHR = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetMJob(), 8), mLvl);

    uint16 sSTR = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetSJob(), 2), sLvl);
    uint16 sDEX = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetSJob(), 3), sLvl);
    uint16 sVIT = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetSJob(), 4), sLvl);
    uint16 sAGI = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetSJob(), 5), sLvl);
    uint16 sINT = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetSJob(), 6), sLvl);
    uint16 sMND = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetSJob(), 7), sLvl);
    uint16 sCHR = mobutils::GetBaseToRank(grade::GetJobGrade(PTrust->GetSJob(), 8), sLvl);

    if (sLvl > 15)
    {
        sSTR /= 2;
        sDEX /= 2;
        sAGI /= 2;
        sINT /= 2;
        sMND /= 2;
        sCHR /= 2;
        sVIT /= 2;
    }
    else
    {
        sSTR = 0;
        sDEX = 0;
        sAGI = 0;
        sINT = 0;
        sMND = 0;
        sCHR = 0;
        sVIT = 0;
    }

    auto statMultiplier = settings::get<float>("map.ALTER_EGO_STAT_MULTIPLIER");
    statMultiplier      = (statMultiplier >= 0.1f && statMultiplier <= 2.0f) ? statMultiplier : 1.0f;
    PTrust->stats.STR   = static_cast<uint16>((fSTR + mSTR + sSTR) * statMultiplier);
    PTrust->stats.DEX   = static_cast<uint16>((fDEX + mDEX + sDEX) * statMultiplier);
    PTrust->stats.VIT   = static_cast<uint16>((fVIT + mVIT + sVIT) * statMultiplier);
    PTrust->stats.AGI   = static_cast<uint16>((fAGI + mAGI + sAGI) * statMultiplier);
    PTrust->stats.INT   = static_cast<uint16>((fINT + mINT + sINT) * statMultiplier);
    PTrust->stats.MND   = static_cast<uint16>((fMND + mMND + sMND) * statMultiplier);
    PTrust->stats.CHR   = static_cast<uint16>((fCHR + mCHR + sCHR) * statMultiplier);

    if (useRaceTables)
    {
        // Player stat formula: race grade + job grade at main level + sub job grade at sub level (StatIndex 2-8 = STR..CHR)
        const auto playerStat = [&](uint8 statIndex) -> uint16
        {
            return static_cast<uint16>(grade::GetBaseStat(grade::GetRaceGrades(squadRaceGroup, statIndex), grade::GetJobGrade(mJob, statIndex), mLvl, grade::GetJobGrade(sJob, statIndex), sLvl));
        };

        PTrust->stats.STR = playerStat(2);
        PTrust->stats.DEX = playerStat(3);
        PTrust->stats.VIT = playerStat(4);
        PTrust->stats.AGI = playerStat(5);
        PTrust->stats.INT = playerStat(6);
        PTrust->stats.MND = playerStat(7);
        PTrust->stats.CHR = playerStat(8);
    }

    // Skills =======================
    for (int i = static_cast<int>(xi::SkillType::DivineMagic); i <= static_cast<int>(xi::SkillType::BlueMagic); i++)
    {
        uint16 maxSkill = battleutils::GetMaxSkill((xi::SkillType)i, mJob, std::min<uint8>(mLvl, 99));
        if (maxSkill != 0)
        {
            PTrust->WorkingSkills.skill[i] = static_cast<uint16>(maxSkill * settings::get<float>("map.ALTER_EGO_SKILL_MULTIPLIER"));
        }
        else // if the mob is WAR/BLM and can cast spell
        {
            // set skill as high as main level, so their spells won't get resisted
            uint16 maxSubSkill = battleutils::GetMaxSkill((xi::SkillType)i, sJob, std::min<uint8>(mLvl, 99));

            if (maxSubSkill != 0)
            {
                PTrust->WorkingSkills.skill[i] = static_cast<uint16>(maxSubSkill * settings::get<float>("map.ALTER_EGO_SKILL_MULTIPLIER"));
            }
        }
    }

    for (int i = static_cast<int>(xi::SkillType::HandToHand); i <= static_cast<int>(xi::SkillType::Staff); i++)
    {
        // (core trusts) the skill type number is used as the rank here, so every trust's combat skills depend on the
        // weapon type: great katana = rank E. A squad mate's skills are a player's instead: the best of its main job's
        // rank at its main level and its sub job's rank at its sub level (2026-11-19, sparkiie: a level 68 SAM never
        // reached Tachi: Yukikaze / Gekko). A weapon neither job has a rank for keeps the old value.
        uint16 maxSkill = battleutils::GetMaxSkill(static_cast<uint8>(i), std::min<uint8>(mLvl, 99));
        if (useRaceTables)
        {
            const uint16 mainCap = battleutils::GetMaxSkill(static_cast<xi::SkillType>(i), mJob, std::min<uint8>(mLvl, 99));
            const uint16 subCap  = sLvl > 0 ? battleutils::GetMaxSkill(static_cast<xi::SkillType>(i), sJob, std::min<uint8>(sLvl, 99)) : 0;
            if (std::max(mainCap, subCap) != 0)
            {
                maxSkill = std::max(mainCap, subCap);
            }
        }
        if (maxSkill != 0)
        {
            PTrust->WorkingSkills.skill[i] = static_cast<uint16>(maxSkill * settings::get<float>("map.ALTER_EGO_SKILL_MULTIPLIER"));
        }
    }

    if (PTrust->isSquadMate())
    {
        // (XI: Forever Offline, squad audit N1) a squad mate's skills follow the player table, and its attack, accuracy,
        // defense and evasion come from those skills through the player formulas (CBattleEntity::ATT, ACC, DEF, EVA,
        // RATT, RACC), so it gets no trust base rating on top.
        BuildSquadSkillsImpl(PTrust);
    }
    else
    {
        PTrust->addModifier(xi::Mod::DEF, mobutils::GetBaseSkill(PTrust, PTrust->defRank));
        PTrust->addModifier(xi::Mod::EVA, mobutils::GetBaseSkill(PTrust, PTrust->evaRank));
        PTrust->addModifier(xi::Mod::ATT, mobutils::GetBaseSkill(PTrust, PTrust->attRank));
        PTrust->addModifier(xi::Mod::ACC, mobutils::GetBaseSkill(PTrust, PTrust->accRank));

        PTrust->addModifier(xi::Mod::RATT, mobutils::GetBaseSkill(PTrust, PTrust->attRank));
        PTrust->addModifier(xi::Mod::RACC, mobutils::GetBaseSkill(PTrust, PTrust->accRank));
    }

    // Natural magic evasion
    PTrust->addModifier(xi::Mod::MEVA, mobutils::GetMagicEvasion(PTrust));

    // Add traits for sub and main
    battleutils::AddTraits(PTrust, traits::GetTraits(mJob), mLvl);
    battleutils::AddTraits(PTrust, traits::GetTraits(sJob), sLvl);

    mobutils::SetupJob(PTrust);

    // Skills
    using namespace gambits;
    auto* controller = dynamic_cast<CTrustController*>(PTrust->PAI->GetController());

    if (!controller)
    {
        ShowWarning("trustutils::LoadTrustStatsAndSkills() - Trust Controller was null.");
        return;
    }

    // Default TP selectors
    controller->m_GambitsContainer->tp_trigger = G_TP_TRIGGER::ASAP;
    controller->m_GambitsContainer->tp_select  = G_SELECT::RANDOM;

    auto skillList = battleutils::GetMobSkillList(PTrust->m_MobSkillList);
    for (uint16 skill_id : skillList)
    {
        TrustSkill_t skill;
        if (skill_id <= 255) // Player WSs
        {
            CWeaponSkill* PWeaponSkill = battleutils::GetWeaponSkill(skill_id);
            if (!PWeaponSkill)
            {
                ShowWarning("LoadTrustStatsAndSkills: Error loading WeaponSkill id %d for trust %s", skill_id, PTrust->name);
                break;
            }

            skill = TrustSkill_t{
                G_REACTION::WS,
                skill_id,
                PWeaponSkill->getPrimarySkillchain(),
                PWeaponSkill->getSecondarySkillchain(),
                PWeaponSkill->getTertiarySkillchain(),
                battleutils::isValidSelfTargetWeaponskill(skill_id) ? TARGET_SELF : TARGET_ENEMY,
            };
        }
        else // MobSkills
        {
            CMobSkill* PMobSkill = battleutils::GetMobSkill(skill_id);
            if (!PMobSkill)
            {
                ShowWarning("LoadTrustStatsAndSkills: Error loading MobSkill id %d for trust %s", skill_id, PTrust->name);
                break;
            }
            skill = {
                G_REACTION::MS,
                skill_id,
                PMobSkill->getPrimarySkillchain(),
                PMobSkill->getSecondarySkillchain(),
                PMobSkill->getTertiarySkillchain(),
                static_cast<TARGETTYPE>(PMobSkill->getValidTargets()),
            };

            controller->m_GambitsContainer->tp_skills.emplace_back(skill);
        }

        // Only get access to skills that produce Lv3 SCs after Lv60
        bool canFormLv3Skillchain = skill.primary >= std::to_underlying(xi::SkillchainType::Gravitation) || skill.secondary >= std::to_underlying(xi::SkillchainType::Gravitation) || skill.tertiary >= std::to_underlying(xi::SkillchainType::Gravitation);

        // Special case for Zeid II and others who only have Lv3+ skills
        bool onlyHasLv3Skillchains = canFormLv3Skillchain && controller->m_GambitsContainer->tp_skills.empty();

        if (!canFormLv3Skillchain || PTrust->GetMLevel() >= 60 || onlyHasLv3Skillchains)
        {
            controller->m_GambitsContainer->tp_skills.emplace_back(skill);
        }
    }
}

} // namespace
