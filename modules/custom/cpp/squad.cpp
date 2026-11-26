//
// Squad Mates (v1.9)
//
//   Persistent, customizable Trust-style party members.
//
//   - Each squad mate (squad_mate) has a level and exp for every job (squad_job).
//   - Spawns a squad mate as a Trust: the trust that matches the chosen main job is used as the
//     template for AI, spells and weaponskills, while job, subjob and level come from the record.
//   - Optionally gives the mate a player race and face.
//   - Equipment (squad_equip): item modifiers, main hand weapon stats and armor appearance.
//   - Needs trustutils.patch applied (adds trustutils::SquadSpec).
//
//   Lua:
//   - SpawnSquadMate(player, { id, mjob, sjob, mlevel, slevel, template, race, face, equip }) -> trust entity or nil
//   - GetSquad(charId)                       -> array of squad mates, each with a .jobs[jobId] = { level, exp }
//   - SaveSquadMate(charId, slot, record)    -> creates or updates a squad mate, returns its id
//   - SetSquadJob(squadId, job, level, exp)
//   - AddSquadExp(squadId, job, exp, cap)    -> { level, exp, gained }
//   - GetSquadExpNeeded(level)               -> exp needed for the next level
//   - DeleteSquadMate(charId, slot)
//   - SetSquadEquip(squadId, job, slot, itemId)   (itemId 0 removes the item)
//   - FindSquadItem(text)                         -> item id from a numeric id or an item name, 0 if not found
//   - GetSquadItemInfo(itemId)                    -> { valid, name, level, jobs, slot, skill, shield, dmg, delay, mods } for equipment
//   - Trading: when a player trades items to one of their squad mates, the offered items are handed to the Lua function
//              xi.squad.onTrade(player, trust, items), where items = array of { itemId, slot, quantity }.
//   - BuildStarterGear(job)                       -> { [slot] = itemId } basic level 1 gear for that job
//   - SquadSpawnPet(mate, petId) -> bool     summons a pet (needs trust-squad-pets.patch)
//   - SquadHasPet(mate) -> bool
//   - SquadPetAttack(mate, target)           sends the pet at the enemy, if it is not already fighting
//   - Party chat: typing a spell name casts it. Results go to xi.squad.onSpellCommand(player, mate, spellName, result).
//   - Party chat: typing a job ability name (or "2hr") uses it. Results go to
//     xi.squad.onAbilityCommand(player, mate, abilityName, result, abilityId).
//   - SquadUseAbility(player, mate, abilityId) -> result ("cast", "unknown", "notready", "notarget", "busy")
//   - SquadNewSpells(job, oldLevel, newLevel) -> names of spells that job learns between those levels
//   - UnlockSquadItem(charId, itemId)             -> adds an item to the shared squad collection
//   - GetSquadUnlocks(charId)                     -> table with [itemId] = true for each unlocked item
//   - GetSquadWeaponSkillIds(mate)                -> { { id, name } ... } every weapon skill a called mate can use now
//   - SquadApplyWeaponSkills(mate, wsId) -> bool  rebuilds a called mate's weapon skills now, narrowed to wsId (0 = all)
//

#include "common/database.h"
#include <algorithm>
#include "map/ability.h"
#include "map/recast_container.h"
#include "map/ai/ai_container.h"
#include "map/autotranslate.h"
#include "common/lua.h"
#include "map/entities/char_entity.h"
#include "map/merit.h" // Gambits v2 U13: the owner's merit unlocks (CMeritPoints::GetMerit)
#include "map/entities/mob_entity.h"
#include "map/entities/trust_entity.h"
#include "map/item_container.h"
#include "map/items/item.h"
#include "map/items/item_equipment.h"
#include "map/items/item_weapon.h"
#include "map/lua/lua_base_entity.h"
#include "map/utils/charutils.h"
#include "map/utils/itemutils.h"
#include "map/map_session.h"
#include "map/party.h"
#include "map/enums/msg_std.h"
#include "map/packets/c2s/0x077_group_change2.h"
#include "map/mob_spell_container.h"
#include "map/spell.h"
#include "map/blue_spell.h"
#include "map/packets/basic.h"
#include "map/packets/entity_update.h" // MODEL_EQUIPPED (squadRefreshLook)
#include "map/ai/controllers/trust_controller.h"
#include "map/ai/helpers/gambits_container.h"
#include "map/ai/helpers/squad_spell_kind.h"
#include "map/packets/c2s/0x032_trade_req.h"
#include "map/packets/c2s/0x0b5_chat_std.h"
#include "map/packets/c2s/0x036_item_transfer.h"
#include "map/utils/moduleutils.h"
#include "map/utils/petutils.h"
#include "map/utils/trustutils.h"
#include "map/utils/battleutils.h"
#include "map/weapon_skill.h"
#include "map/mobskill.h"

#include <algorithm>
#include <cctype>
#include <set>
#include <sstream>
#include <map>
#include <optional>
#include <string>
#include <tuple>

namespace
{

// Main job id -> trust spell id used as the template for that job
std::map<int, uint32> jobTemplates;

// Entity id -> squad id for squad mates we have spawned, so they are recognised even if their SQUAD_ID tag is lost
std::map<uint32, uint32> squadEntities;

bool isPassiveTemplate(std::string name)
{
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c)
                   { return static_cast<char>(std::tolower(c)); });

    // Walking GEO bubbles are untargetable, so they make poor squad mates
    for (const char* bad : { "sakura", "moogle", "star_sibyl", "star sibyl", "kuyin" })
    {
        if (name.find(bad) != std::string::npos)
        {
            return true;
        }
    }

    return false;
}

// What a squad mate wears, as the appearance values sent to the game client. Characters that are not players are sent these values
// as they are stored, so each armor piece carries its slot (head 0x1000, body 0x2000, hands 0x3000, legs 0x4000, feet 0x5000,
// main 0x6000, sub 0x7000, ranged 0x8000). 0 means nothing is shown in that slot.
struct OutfitLook
{
    uint16 head{ 0 }, body{ 0 }, hands{ 0 }, legs{ 0 }, feet{ 0 }, main{ 0 }, sub{ 0 }, ranged{ 0 };
};

// `equip` maps equipment slot index -> item id (0 main, 1 sub, 2 ranged, 3 ammo, 4 head, 5 body, 6 hands, 7 legs, 8 feet, ...)
auto outfitLook(const sol::table& equip) -> OutfitLook
{
    OutfitLook look{};

    for (const auto& entry : equip)
    {
        const int    slot   = entry.first.as<int>();
        const uint16 itemId = static_cast<uint16>(entry.second.as<uint32>());

        const auto* item = xi::items::lookup<CItemEquipment>(itemId);
        if (item == nullptr)
        {
            continue;
        }

        const uint16 model    = item->getModelId();
        const auto   withSlot = [model](const uint16 slotBase) -> uint16
        {
            return model != 0 ? static_cast<uint16>(slotBase + model) : static_cast<uint16>(0);
        };

        switch (slot)
        {
            case 0:
                look.main = withSlot(0x6000);
                // (2026-11-18, Rysan) hand-to-hand weapons are worn on both hands: a player's sub look carries the
                // same model, so without it the mate showed the weapon on one hand only
                if (const auto* h2h = dynamic_cast<const CItemWeapon*>(item); h2h != nullptr && h2h->isHandToHand())
                {
                    look.sub = withSlot(0x7000);
                }
                break;
            case 1: look.sub = withSlot(0x7000); break;
            case 2: look.ranged = withSlot(0x8000); break;
            case 4: look.head = withSlot(0x1000); break;
            case 5: look.body = withSlot(0x2000); break;
            case 6: look.hands = withSlot(0x3000); break;
            case 7: look.legs = withSlot(0x4000); break;
            case 8: look.feet = withSlot(0x5000); break;
            default: break;
        }
    }

    return look;
}

// squad mates spawned with nothing in the main hand (barehanded MNK/PUP: hand-to-hand weapon skills)
std::set<uint32> squadMainEmpty;

// the most hits a weapon can make in one swing (item_weapon.hit; 1 for most weapons)
auto weaponMaxHit(const uint16 itemId) -> uint8
{
    const auto rset = db::preparedStmt("SELECT hit FROM item_weapon WHERE itemId = ? LIMIT 1", itemId);
    FOR_DB_SINGLE_RESULT(rset)
    {
        return static_cast<uint8>(std::clamp<int>(rset->get<int>("hit"), 1, 8));
    }

    return 1;
}

// Applies a squad mate's outfit stats: item modifiers and the main hand weapon.
// (How the mate looks is set before spawning, see spawnSquadMate.)
void applyEquipment(CTrustEntity* PTrust, const sol::table& equip)
{
    bool any = false;

    for (const auto& entry : equip)
    {
        const int    slot   = entry.first.as<int>();
        const uint16 itemId = static_cast<uint16>(entry.second.as<uint32>());

        const auto* item = xi::items::lookup<CItemEquipment>(itemId);
        if (item == nullptr)
        {
            continue;
        }

        any = true;

        // (squad audit N2) remember what is worn in each slot: player combat code that reads the equipped item (shield
        // blocking, parry, guard) looks it up for a squad mate through this
        if (slot >= 0 && slot < 16)
        {
            PTrust->setSquadEquip(static_cast<uint8>(slot), itemId);
        }

        // Item modifiers (stats). Copy the list because addModifiers takes a non-const pointer.
        auto mods = item->modList;
        PTrust->addModifiers(&mods);

        // Main hand weapon: use the real damage, delay and weapon type
        if (slot == 0)
        {
            const auto* weapon     = dynamic_cast<const CItemWeapon*>(item);
            auto*       mainWeapon = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_MAIN]);
            if (weapon != nullptr && mainWeapon != nullptr)
            {
                mainWeapon->setSkillType(weapon->getSkillType());
                mainWeapon->setDamage(weapon->getDamage());
                // setDelay takes the item's delay (1/60 s) and converts it to ms itself; getDelay() is already
                // in ms, so passing it converted twice: 4000 ms became 65 s, and the mate swung once a fight
                mainWeapon->setDelay(weapon->getBaseDelay());
                mainWeapon->setBaseDelay(weapon->getBaseDelay());
                // the most hits it can make (Mercurial Kris & co.): from the item data. getHitCount() is one random roll
                // of it, so copying that usually made every multi-hit weapon a single-hit one (sparkiie, 2026-11-18)
                mainWeapon->setMaxHit(weaponMaxHit(itemId));
                // (2026-11-19, sparkiie: Kraken Club and Mercurial Kris still single-hit) the attack round only uses a
                // weapon's hit count when the weapon's required level is not above the wielder's, and the trust's stand-in
                // weapon keeps the item default of 255, so the count set above was never read
                mainWeapon->setReqLvl(0);
                mainWeapon->setDmgType(const_cast<CItemWeapon*>(weapon)->getDmgType()); // (getDmgType isn't const)

                if (mainWeapon->getDelay() > 0)
                {
                    mainWeapon->setDPS(static_cast<double>(mainWeapon->getDamage()) / (static_cast<double>(mainWeapon->getDelay()) / 1000.0));
                }
            }
        }

        // (2026-11-18, Egon/ChazDingle) a bow, gun, boomerang or throwing ammo: the mate's own ranged "weapon" only ever
        // had the trust stand-in (no skill), so a camp puller never saw a ranged weapon and ran in to melee.
        if (slot == 2 || slot == 3)
        {
            const auto* weapon = dynamic_cast<const CItemWeapon*>(item);
            auto*       target = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[slot == 2 ? SLOT_RANGED : SLOT_AMMO]);
            // (2026-11-19, Yache) only real shooting or throwing weapons: a bard's instrument sits in the ranged slot
            // too, and with its skill copied here the bard "shot" with it (see squad.lua, the BRD profile)
            const auto  skillType = weapon != nullptr ? weapon->getSkillType() : xi::SkillType::None;
            const bool  shoots    = skillType == xi::SkillType::Archery || skillType == xi::SkillType::Marksmanship || skillType == xi::SkillType::Throwing;
            if (weapon != nullptr && target != nullptr && shoots)
            {
                target->setSkillType(weapon->getSkillType());
                // (squad audit N1) the player ranged formulas (RATT, RACC) skip a weapon without a damage type
                target->setDmgType(const_cast<CItemWeapon*>(weapon)->getDmgType()); // (getDmgType isn't const)
                if (weapon->getDamage() > 0)
                {
                    target->setDamage(weapon->getDamage());
                }
                if (weapon->getBaseDelay() > 0)
                {
                    target->setDelay(weapon->getBaseDelay());
                    target->setBaseDelay(weapon->getBaseDelay());
                }
            }
        }
    }

    // (2026-11-18) a second weapon in the sub slot: dual wield, as a player with the trait (NIN 10+ and the like:
    // the DUAL_WIELD mod the job traits give). Before this only the main hand ever swung (sparkiie).
    PTrust->m_dualWield = false;
    for (const auto& entry : equip)
    {
        if (entry.first.as<int>() != 1)
        {
            continue;
        }

        const uint16 subId     = static_cast<uint16>(entry.second.as<uint32>());
        const auto*  subItem   = dynamic_cast<const CItemWeapon*>(xi::items::lookup<CItemEquipment>(subId));
        auto*        subWeapon = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_SUB]);
        if (subItem == nullptr || subWeapon == nullptr || subItem->getDamage() == 0 || PTrust->getMod(xi::Mod::DUAL_WIELD) <= 0)
        {
            continue; // (a shield, a grip, or no Dual Wield)
        }

        subWeapon->setSkillType(subItem->getSkillType());
        subWeapon->setDamage(subItem->getDamage());
        subWeapon->setDelay(subItem->getBaseDelay());
        subWeapon->setBaseDelay(subItem->getBaseDelay());
        subWeapon->setMaxHit(weaponMaxHit(subId));
        subWeapon->setReqLvl(0); // (as for the main hand: else its hit count is ignored)
        subWeapon->setDmgType(const_cast<CItemWeapon*>(subItem)->getDmgType());
        PTrust->m_dualWield = true;
    }

    // (squad audit N1) "+skill" gear counts, as for a player: the skills are worked out again with the outfit's mods
    // (and with the trait mods added after the first pass in trustutils)
    trustutils::BuildSquadSkills(PTrust);

    if (!any)
    {
        return;
    }

    // Item bonuses can change max HP/MP, so refresh and top up. No look update is flagged: a renamed character's later
    // update packets would garble the armor, and the appearance is already part of the spawn packet.
    PTrust->UpdateHealth();
    PTrust->health.hp = PTrust->GetMaxHP();
    PTrust->health.mp = PTrust->GetMaxMP();
    PTrust->updatemask |= UPDATE_HP;
}

void limitWeaponSkills(CTrustEntity* PTrust, uint16 onlyWs = 0); // below: weapon skills like a player's

// Every weapon skill each squad mate could use when it was called (before a chosen one narrows the list), for the menu
std::map<uint32, std::vector<uint16>> squadWeaponSkills;

auto spawnSquadMate(CLuaBaseEntity* master, const sol::table& spec) -> std::optional<CLuaBaseEntity>
{
    if (master == nullptr || master->GetBaseEntity() == nullptr || master->GetBaseEntity()->objtype != TYPE_PC)
    {
        return std::nullopt;
    }

    auto* PChar = static_cast<CCharEntity*>(master->GetBaseEntity());

    const int mJob   = spec.get_or("mjob", 0);
    const int sJob   = spec.get_or("sjob", 0);
    const int mLevel = spec.get_or("mlevel", 0);
    const int sLevel = spec.get_or("slevel", 0);
    const int id     = spec.get_or("id", 0);
    const int race   = spec.get_or("race", 0);
    const int face   = spec.get_or("face", 0);
    const int size   = spec.get_or("size", 0); // body size 1-3 (small / medium / large), 0 = not chosen
    int       templ  = spec.get_or("template", 0);

    if (mJob < 1 || mJob > 22 || mLevel < 1 || mLevel > 99)
    {
        ShowWarning("[SQUAD] SpawnSquadMate: invalid job (%i) or level (%i)", mJob, mLevel);
        return std::nullopt;
    }

    if (templ == 0)
    {
        const auto it = jobTemplates.find(mJob);
        if (it == jobTemplates.end())
        {
            ShowWarning("[SQUAD] SpawnSquadMate: no trust template found for job %i", mJob);
            return std::nullopt;
        }
        templ = static_cast<int>(it->second);
    }

    trustutils::SquadSpec squadSpec{};
    squadSpec.mJob    = static_cast<uint8>(mJob);
    squadSpec.sJob    = static_cast<uint8>(std::clamp(sJob, 0, 22));
    squadSpec.mLevel  = static_cast<uint8>(mLevel);
    squadSpec.sLevel  = static_cast<uint8>(std::clamp(sLevel, 0, 99));
    squadSpec.squadId = static_cast<uint32>(std::max(id, 0));
    squadSpec.race    = static_cast<uint8>((race >= 1 && race <= 8) ? race : 0);

    // (squad option "spells from scrolls") what the squad has learned: squad_unlock rows 60000 + spell id
    if (spec.get_or("scrolls", false))
    {
        squadSpec.spellScrolls = true;
        const auto lrset = db::preparedStmt("SELECT itemid FROM squad_unlock WHERE charid = ? AND itemid >= 60000", PChar->id);
        FOR_DB_MULTIPLE_RESULTS(lrset)
        {
            squadSpec.learnedSpells.push_back(static_cast<uint16>(lrset->get<uint16>("itemid") - 60000));
        }
    }

    // (2026-11-17) a Blue Mage's set: blueSet = the spells the player chose (empty = automatic), bluePrefer = the job
    // rules' spells, tried first by the automatic set (trustutils.cpp works out slots, points and traits)
    for (const char* key : { "blueSet", "bluePrefer" })
    {
        if (const auto list = spec.get<sol::optional<sol::table>>(key))
        {
            auto& out = std::string_view(key) == "blueSet" ? squadSpec.blueSet : squadSpec.bluePrefer;
            for (const auto& kv : *list)
            {
                if (kv.second.is<int>())
                {
                    out.push_back(static_cast<uint16>(kv.second.as<int>()));
                }
            }
        }
    }

    // The appearance is handed to the spawn itself, so the very first message the game receives already shows the right race,
    // face and armor. (Changing it afterwards does not work: a renamed character's update packets garble the armor.)
    const sol::optional<sol::table> equip = spec.get<sol::optional<sol::table>>("equip");
    OutfitLook                      outfit = equip ? outfitLook(*equip) : OutfitLook{};

    // (2026-11-18) lockstyle: the look the player chose for this mate replaces what its gear shows, slot by slot.
    // Only the look: stats still come from `equip` (applyEquipment below).
    if (const auto lockstyle = spec.get<sol::optional<sol::table>>("lockstyle"); lockstyle && !lockstyle->empty())
    {
        const OutfitLook locked = outfitLook(*lockstyle);
        bool             has[9] = {};
        for (const auto& kv : *lockstyle)
        {
            if (kv.first.is<int>())
            {
                if (const int slot = kv.first.as<int>(); slot >= 0 && slot <= 8)
                {
                    has[slot] = true;
                }
            }
        }
        outfit.main   = has[0] ? locked.main : outfit.main;
        outfit.sub    = has[1] ? locked.sub : ((has[0] && locked.sub != 0) ? locked.sub : outfit.sub); // (a locked hand-to-hand look fills both hands)
        outfit.ranged = has[2] ? locked.ranged : outfit.ranged;
        outfit.head   = has[4] ? locked.head : outfit.head;
        outfit.body   = has[5] ? locked.body : outfit.body;
        outfit.hands  = has[6] ? locked.hands : outfit.hands;
        outfit.legs   = has[7] ? locked.legs : outfit.legs;
        outfit.feet   = has[8] ? locked.feet : outfit.feet;
    }
    if (race >= 1 && race <= 8)
    {
        squadSpec.hasLook    = true;
        squadSpec.face       = static_cast<uint8>(std::clamp(face, 0, 15));
        squadSpec.bodySize   = static_cast<uint8>(std::clamp(size, 0, 3));
        squadSpec.lookHead   = outfit.head;
        squadSpec.lookBody   = outfit.body;
        squadSpec.lookHands  = outfit.hands;
        squadSpec.lookLegs   = outfit.legs;
        squadSpec.lookFeet   = outfit.feet;
        squadSpec.lookMain   = outfit.main;
        squadSpec.lookSub    = outfit.sub;
        squadSpec.lookRanged = outfit.ranged;
    }

    auto* PTrust = trustutils::SpawnTrust(PChar, static_cast<uint32>(templ), &squadSpec);
    if (PTrust == nullptr)
    {
        return std::nullopt;
    }

    // Remember this squad mate, and make sure the SQUAD_ID tag is still on it after spawning
    ShowInfo("[SQUAD] spawned squad mate %s (entity %u, squad id %u): SQUAD_ID reads back as %u",
             PTrust->getName(), static_cast<unsigned>(PTrust->id), static_cast<unsigned>(squadSpec.squadId), static_cast<unsigned>(PTrust->GetLocalVar("SQUAD_ID")));
    squadEntities[PTrust->id] = squadSpec.squadId;
    PTrust->SetLocalVar("SQUAD_ID", squadSpec.squadId);

    if (squadSpec.hasLook)
    {
        ShowInfo("[SQUAD] outfit for %s: head %04X body %04X hands %04X legs %04X feet %04X main %04X sub %04X ranged %04X (0000 = nothing shown)",
                 PTrust->getName(), outfit.head, outfit.body, outfit.hands, outfit.legs, outfit.feet, outfit.main, outfit.sub, outfit.ranged);
    }

    {
        bool mainHeld = false;
        if (equip)
        {
            for (const auto& entry : *equip)
            {
                mainHeld = mainHeld || (entry.first.as<int>() == 0 && entry.second.as<uint32>() != 0);
            }
        }
        if (mainHeld) { squadMainEmpty.erase(PTrust->id); } else { squadMainEmpty.insert(PTrust->id); }
        if (!mainHeld && (PTrust->GetMJob() == xi::Job::MNK || PTrust->GetMJob() == xi::Job::PUP))
        {
            if (auto* fists = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_MAIN]))
            {
                fists->setSkillType(xi::SkillType::HandToHand); // barehanded: hand-to-hand skill and weapon skills
                // (2026-11-22, Altair: an unarmed squad Monk swung far too fast) the barehanded delay is a player's
                // (xi::items::unarmedH2H, 480), not the trust template's stand-in delay (240). Martial Arts, the two
                // fists per round and haste are still worked out in CBattleEntity::GetWeaponDelay.
                const uint16 unarmedDelay = xi::items::unarmedH2H()->getBaseDelay();
                fists->setDelay(unarmedDelay);
                fists->setBaseDelay(unarmedDelay);
                if (fists->getDelay() > 0)
                {
                    fists->setDPS(static_cast<double>(fists->getDamage()) / (static_cast<double>(fists->getDelay()) / 1000.0));
                }
            }
        }
    }

    if (equip)
    {
        applyEquipment(PTrust, *equip);
    }

    // "ws" = a weapon skill the player chose for this mate (!squad ws): it then uses only that one, when it can
    limitWeaponSkills(PTrust, static_cast<uint16>(std::clamp(spec.get_or("ws", 0), 0, 0xFFFF)));

    return CLuaBaseEntity(PTrust);
}

// Weapon skills like a player's (squad 1.16): a Trust gets every move on its template's list from level 1, including
// Trust-only moves. A squad mate instead gets exactly the player weapon skills for the weapon in its main hand that its
// job may use, that need no quest (or whose quest its player has done), and that its skill in that weapon has reached (its skills are the max for job and level).
void limitWeaponSkills(CTrustEntity* PTrust, const uint16 onlyWs)
{
    auto* controller = dynamic_cast<CTrustController*>(PTrust->PAI->GetController());
    if (controller == nullptr || controller->m_GambitsContainer == nullptr)
    {
        return;
    }

    const auto* weapon     = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[SLOT_MAIN]);
    const auto  job        = PTrust->GetMJob();
    auto        weaponType = weapon != nullptr ? static_cast<uint8>(weapon->getSkillType()) : static_cast<uint8>(0);
    // (2026-11-18) a MNK or PUP mate with nothing in the main hand fights barehanded, like a player: hand-to-hand
    // weapon skills. Before this an empty hand meant no weapon skills at all (Rysan).
    if ((job == xi::Job::MNK || job == xi::Job::PUP) && squadMainEmpty.count(PTrust->id) != 0)
    {
        weaponType = static_cast<uint8>(xi::SkillType::HandToHand);
    }

    // (squad audit N1) a ranged weapon's weapon skills too, as for a player (Hot Shot, Sidewinder, Slug Shot...): the
    // bow, gun or throwing weapon applyEquipment put in the ranged (or ammo) slot. Before this a squad Ranger or Corsair
    // only ever had its main hand's weapon skills.
    uint8 rangedType = 0;
    for (const SLOTTYPE slot : { SLOT_RANGED, SLOT_AMMO })
    {
        const auto* shooter = dynamic_cast<CItemWeapon*>(PTrust->m_Weapons[slot]);
        const auto  type    = shooter != nullptr ? shooter->getSkillType() : xi::SkillType::None;
        if (rangedType == 0 && (type == xi::SkillType::Archery || type == xi::SkillType::Marksmanship || type == xi::SkillType::Throwing) &&
            (slot == SLOT_RANGED || type == xi::SkillType::Throwing))
        {
            rangedType = static_cast<uint8>(type);
        }
    }

    // Exactly the weapon skills a player of this job could use with this weapon right now: no Trust-only moves
    // (Peacebreaker and the like), none for another weapon, none above the skill level, none whose quest the player has not done.
    auto* owner = dynamic_cast<CCharEntity*>(PTrust->PMaster);
    auto& skills = controller->m_GambitsContainer->tp_skills;
    skills.clear();
    std::string kept;
    for (uint16 id = 1; id < MAX_WEAPONSKILL_ID; ++id)
    {
        auto* ws = battleutils::GetWeaponSkill(id);
        if (ws == nullptr || ws->getJob(job) == 0)
        {
            continue;
        }

        const bool meleeMatch  = weaponType != 0 && ws->getType() == weaponType;
        const bool rangedMatch = rangedType != 0 && ws->getType() == rangedType;
        if (!meleeMatch && !rangedMatch)
        {
            continue;
        }

        // (2026-11-20, sparkiie) weapon skills that need a quest (Asuran Fists, Evisceration, Rampage...): the mate gets
        // the ones its player has unlocked. Ones with no skill level of their own need level 75, as for a player
        // (battleutils::CanUseWeaponskill). Before this they were always left out.
        if (ws->getUnlockId() != 0)
        {
            if (owner == nullptr || !charutils::hasLearnedWeaponskill(owner, ws->getUnlockId()) ||
                (ws->getSkillLevel() == 0 && PTrust->GetMLevel() < 75))
            {
                continue;
            }
        }

        if (PTrust->GetSkill(static_cast<xi::SkillType>(ws->getType())) < ws->getSkillLevel())
        {
            continue;
        }

        gambits::TrustSkill_t skill;
        skill.skill_type    = gambits::G_REACTION::WS;
        skill.skill_id      = id;
        skill.primary       = ws->getPrimarySkillchain();
        skill.secondary     = ws->getSecondarySkillchain();
        skill.tertiary      = ws->getTertiarySkillchain();
        skill.valid_targets = battleutils::isValidSelfTargetWeaponskill(id) ? TARGET_SELF : TARGET_ENEMY;
        skills.push_back(skill);
        kept += (kept.empty() ? "" : ", ") + ws->getName();
    }

    {
        auto& usable = squadWeaponSkills[PTrust->id];
        usable.clear();
        for (const auto& s : skills)
        {
            usable.push_back(s.skill_id);
        }
    }

    // (2026-11-22, levi) The engine's "Best" (HIGHEST) opens with the LAST weapon skill of this list and, among closers
    // that form equally good skillchains, also keeps the last one. The list is in weapon skill id order, which put e.g.
    // Shoulder Tackle above Combo, Moonlight above Seraph Strike and Leg Sweep above Double Thrust. Order each weapon's
    // skills by damage at 1000 TP instead (this server's Adoulin values: hits x fTP, multi-hit fTP, stat modifiers).
    // Utility skills (stuns, breaks, MP/HP drain, Starlight/Moonlight, AoE that can wake slept mobs) go first, so they
    // are only ever picked to close a skillchain. Skills not listed (past ToAU) rank above all listed ones of their
    // weapon. The menu list above keeps id order; a weapon skill chosen in Gambits still narrows the list to itself.
    {
        // per weapon, weakest first (weapon skill ids, see data/weapon_skills.yaml)
        static const std::vector<std::vector<uint16>> weakestFirst = {
            // hand-to-hand: Shoulder Tackle, Spinning Attack, One Inch Punch, Backhand Blow, Combo, Dragon Kick,
            // Raging Fists, Howling Fist, Final Heaven, Asuran Fists, Ascetic's Fury, Stringing Pummel
            { 2, 6, 3, 4, 1, 8, 5, 7, 10, 9, 11, 12 },
            // dagger: Energy Steal, Energy Drain, Shadowstitch, Wasp Sting, Cyclone, Viper Bite, Gust Slash, Dancing Edge,
            // Shark Bite, Evisceration, Mercy Stroke, Mandalic Stab, Mordant Rime, Pyrrhic Kleos
            { 21, 22, 18, 16, 20, 17, 19, 23, 24, 25, 26, 27, 28, 29 },
            // sword: Spirits Within, Flat Blade, Circle Blade, Atonement, Burning Blade, Fast Blade, Red Lotus Blade,
            // Shining Blade, Seraph Blade, Swift Blade, Vorpal Blade, Savage Blade, Knights of Round, Expiacion, Death Blossom
            { 39, 35, 38, 45, 33, 32, 34, 36, 37, 41, 40, 42, 43, 46, 44 },
            // great sword: Shockwave, Power Slash, Hard Slash, Frostbite, Freezebite, Crescent Moon, Sickle Moon,
            // Spinning Slash, Ground Strike, Scourge
            { 52, 49, 48, 50, 51, 53, 54, 55, 56, 57 },
            // axe: Smash Axe, Gale Axe, Raging Axe, Avalanche Axe, Spinning Axe, Calamity, Mistral Axe, Rampage,
            // Decimation, Onslaught, Primal Rend
            { 65, 66, 64, 67, 68, 70, 71, 69, 72, 73, 74 },
            // great axe: Shield Break, Armor Break, Weapon Break, Full Break, Iron Tempest, Keen Edge, Sturmwind,
            // Raging Rush, Steel Cyclone, King's Justice, Metatron Torment
            { 80, 83, 85, 87, 81, 84, 82, 86, 88, 90, 89 },
            // scythe: Spinning Scythe, Nightmare Scythe, Slice, Dark Harvest, Shadow of Death, Vorpal Scythe, Spiral Hell,
            // Cross Reaper, Guillotine, Insurgency, Catastrophe
            { 100, 99, 96, 97, 98, 101, 104, 103, 102, 106, 105 },
            // polearm: Leg Sweep, Double Thrust, Raiden Thrust, Thunder Thrust, Vorpal Thrust, Skewer, Wheeling Thrust,
            // Penta Thrust, Impulse Drive, Drakesbane, Geirskogul
            { 115, 112, 114, 113, 117, 118, 119, 116, 120, 122, 121 },
            // katana: Blade: Chi, Retsu, Rin, Teki, To, Ei, Jin, Ten, Ku, Kamu, Metsu
            { 132, 129, 128, 130, 131, 133, 134, 135, 136, 138, 137 },
            // great katana: Tachi: Hobaku, Enpi, Goten, Kagero, Jinpu, Koki, Yukikaze, Gekko, Kasha, Rana, Kaiten
            { 145, 144, 146, 147, 148, 149, 150, 151, 152, 154, 153 },
            // club: Starlight, Moonlight, Brainshaker, Skullbreaker, Shining Strike, True Strike, Seraph Strike, Judgment,
            // Black Halo, Hexa Strike, Mystic Boon, Randgrith
            { 163, 164, 162, 165, 160, 166, 161, 167, 169, 168, 171, 170 },
            // staff: Spirit Taker, Earth Crusher, Shell Crusher, Heavy Swing, Rock Crusher, Starburst, Sunburst,
            // Full Swing, Retribution, Omniscience, Vidohunir, Garland of Bliss, Gate of Tartarus
            { 183, 178, 181, 176, 177, 179, 180, 182, 184, 188, 186, 187, 185 },
            // archery: Flaming Arrow, Piercing Arrow, Dulling Arrow, Blast Arrow, Empyreal Arrow, Arching Arrow,
            // Sidewinder, Namas Arrow
            { 192, 193, 194, 197, 199, 198, 196, 200 },
            // marksmanship: Hot Shot, Split Shot, Sniper Shot, Blast Shot, Detonator, Heavy Shot, Slug Shot, Coronach,
            // Trueflight, Leaden Salute
            { 208, 209, 210, 213, 215, 214, 212, 216, 217, 218 },
        };
        static const std::map<uint16, int> dpsRank = []()
        {
            std::map<uint16, int> out;
            for (const auto& weapon : weakestFirst)
            {
                for (std::size_t i = 0; i < weapon.size(); ++i)
                {
                    out[weapon[i]] = static_cast<int>(i) + 1;
                }
            }
            return out;
        }();
        const auto rank = [](const gambits::TrustSkill_t& s)
        {
            const auto found = dpsRank.find(s.skill_id);
            return found != dpsRank.end() ? found->second : 1000 + static_cast<int>(s.skill_id);
        };
        std::stable_sort(skills.begin(), skills.end(), [&rank](const gambits::TrustSkill_t& a, const gambits::TrustSkill_t& b)
                         { return rank(a) < rank(b); });
        if (!skills.empty())
        {
            kept += " (opens with " + battleutils::GetWeaponSkill(skills.back().skill_id)->getName() + ")";
        }
    }

    // The player chose one weapon skill for this mate: keep only it, if the mate can use it now (else keep them all)
    if (onlyWs != 0)
    {
        const auto chosen = std::find_if(skills.begin(), skills.end(), [onlyWs](const gambits::TrustSkill_t& s)
                                         { return s.skill_id == onlyWs; });
        if (chosen != skills.end())
        {
            const gambits::TrustSkill_t only = *chosen;
            skills.clear();
            skills.push_back(only);
            kept = "only " + battleutils::GetWeaponSkill(onlyWs)->getName() + " (chosen)";
        }
        else
        {
            kept += " (the chosen weapon skill is not usable yet: weapon or skill level)";
        }
    }

    ShowInfo("[SQUAD] %s: weapon skills like a player's (skill type %u, ranged %u): %s", PTrust->getName(), static_cast<unsigned>(weaponType), static_cast<unsigned>(rangedType), kept.empty() ? "none yet" : kept.c_str());
}

// GetSquadWeaponSkills(mate) -> names of the weapon skills this called mate can use, like "Raging_Axe" (for the menu)
auto getSquadWeaponSkills(CLuaBaseEntity* mate) -> sol::table
{
    auto out = ::lua.create_table();
    if (mate == nullptr || mate->GetBaseEntity() == nullptr)
    {
        return out;
    }

    const auto found = squadWeaponSkills.find(mate->GetBaseEntity()->id);
    if (found == squadWeaponSkills.end())
    {
        return out;
    }

    int index = 1;
    for (const auto id : found->second)
    {
        if (auto* ws = battleutils::GetWeaponSkill(id))
        {
            std::string name = ws->getName();
            std::replace(name.begin(), name.end(), ' ', '_');
            out[index++] = name;
        }
    }

    return out;
}

// (Gambits weapon skill settings) GetSquadWeaponSkillIds(mate) -> { { id = n, name = "Raging_Axe" }, ... }: the complete list
// this called mate can use now, the same list as GetSquadWeaponSkills (taken before a chosen weapon skill narrows the skills
// it uses), with the ids the settings store. Empty for anything that is not a called squad mate.
auto getSquadWeaponSkillIds(CLuaBaseEntity* mate) -> sol::table
{
    auto out = ::lua.create_table();
    if (mate == nullptr || mate->GetBaseEntity() == nullptr)
    {
        return out;
    }

    const auto found = squadWeaponSkills.find(mate->GetBaseEntity()->id);
    if (found == squadWeaponSkills.end())
    {
        return out;
    }

    int index = 1;
    for (const auto id : found->second)
    {
        if (auto* ws = battleutils::GetWeaponSkill(id))
        {
            std::string name = ws->getName();
            std::replace(name.begin(), name.end(), ' ', '_');
            auto entry    = ::lua.create_table();
            entry["id"]   = id;
            entry["name"] = name;
            out[index++]  = entry;
        }
    }

    return out;
}

// (Gambits weapon skill settings, live apply) SquadApplyWeaponSkills(mate, wsId) -> usable
// Builds the called squad mate's weapon skills again for the weapon it holds now (as a call does) and narrows them to
// wsId (0 = all it can use). Returns true when wsId is 0 or usable; false when the chosen one is not usable now (then the
// mate keeps all its weapon skills, exactly as at a call) or when this is not a called squad mate (nothing changed).
auto squadApplyWeaponSkills(CLuaBaseEntity* mate, const uint16 wsId) -> bool
{
    auto* PTrust = mate != nullptr ? dynamic_cast<CTrustEntity*>(mate->GetBaseEntity()) : nullptr;
    if (PTrust == nullptr || PTrust->GetLocalVar("SQUAD_ID") == 0 || PTrust->PAI == nullptr)
    {
        return false;
    }

    limitWeaponSkills(PTrust, wsId);
    if (wsId == 0)
    {
        return true;
    }

    const auto& usable = squadWeaponSkills[PTrust->id];
    return std::find(usable.begin(), usable.end(), wsId) != usable.end();
}

auto getSquad(const uint32 charId) -> sol::table
{
    auto squad = ::lua.create_table();

    std::map<uint32, sol::table> jobTables;
    std::map<uint32, sol::table> equipTables;

    const auto rset = db::preparedStmt("SELECT id, slot, name, race, face, nation, mjob, sjob, template "
                                       "FROM squad_mate WHERE charid = ? ORDER BY slot",
                                       charId);

    auto index = 1;
    FOR_DB_MULTIPLE_RESULTS(rset)
    {
        const auto id = rset->get<uint32>("id");

        auto jobs = ::lua.create_table();
        jobTables.insert_or_assign(id, jobs);

        auto equip = ::lua.create_table();
        equipTables.insert_or_assign(id, equip);

        auto entry        = ::lua.create_table();
        entry["id"]       = id;
        entry["slot"]     = rset->get<uint8>("slot");
        entry["name"]     = rset->get<std::string>("name");
        entry["race"]     = rset->get<uint8>("race");
        entry["face"]     = rset->get<uint8>("face");
        entry["nation"]   = rset->get<uint8>("nation");
        entry["mjob"]     = rset->get<uint8>("mjob");
        entry["sjob"]     = rset->get<uint8>("sjob");
        entry["template"] = rset->get<uint16>("template");
        entry["jobs"]     = jobs;
        entry["equip"]    = equip;
        squad[index++]    = entry;
    }

    const auto jrset = db::preparedStmt("SELECT squad_id, job, level, exp FROM squad_job "
                                        "WHERE squad_id IN (SELECT id FROM squad_mate WHERE charid = ?)",
                                        charId);

    FOR_DB_MULTIPLE_RESULTS(jrset)
    {
        const auto it = jobTables.find(jrset->get<uint32>("squad_id"));
        if (it != jobTables.end())
        {
            auto info     = ::lua.create_table();
            info["level"] = jrset->get<uint8>("level");
            info["exp"]   = jrset->get<uint32>("exp");

            const int job = static_cast<int>(jrset->get<uint8>("job"));
            it->second[job] = info;
        }
    }

    const auto erset = db::preparedStmt("SELECT squad_id, job, slot, itemid FROM squad_equip "
                                        "WHERE squad_id IN (SELECT id FROM squad_mate WHERE charid = ?)",
                                        charId);

    FOR_DB_MULTIPLE_RESULTS(erset)
    {
        const auto it = equipTables.find(erset->get<uint32>("squad_id"));
        if (it != equipTables.end())
        {
            const int job = static_cast<int>(erset->get<uint8>("job"));

            const sol::optional<sol::table> existing = it->second[job].get<sol::optional<sol::table>>();
            sol::table                      jobEquip = existing ? *existing : ::lua.create_table();

            jobEquip[static_cast<int>(erset->get<uint8>("slot"))] = erset->get<uint16>("itemid");
            it->second[job]                                       = jobEquip;
        }
    }

    return squad;
}

auto saveSquadMate(const uint32 charId, const uint32 slot, const sol::table& record) -> uint32
{
    const std::string name   = record.get_or<std::string>("name", "Squad");
    const uint32      race   = record.get_or("race", 0);
    const uint32      face   = record.get_or("face", 0);
    const uint32      nation = record.get_or("nation", 0);
    const uint32      mJob   = record.get_or("mjob", 1);
    const uint32      sJob   = record.get_or("sjob", 0);
    const uint32      templ  = record.get_or("template", 0);

    db::preparedStmt("INSERT INTO squad_mate (charid, slot, name, race, face, nation, mjob, sjob, template) "
                     "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                     "ON DUPLICATE KEY UPDATE name = VALUES(name), race = VALUES(race), face = VALUES(face), "
                     "nation = VALUES(nation), mjob = VALUES(mjob), sjob = VALUES(sjob), template = VALUES(template)",
                     charId,
                     slot,
                     name,
                     race,
                     face,
                     nation,
                     mJob,
                     sJob,
                     templ);

    const auto rset = db::preparedStmt("SELECT id FROM squad_mate WHERE charid = ? AND slot = ?", charId, slot);
    FOR_DB_SINGLE_RESULT(rset)
    {
        return rset->get<uint32>("id");
    }

    return 0;
}

void setSquadJob(const uint32 squadId, const uint32 job, const uint32 level, const uint32 exp)
{
    db::preparedStmt("INSERT INTO squad_job (squad_id, job, level, exp) VALUES (?, ?, ?, ?) "
                     "ON DUPLICATE KEY UPDATE level = VALUES(level), exp = VALUES(exp)",
                     squadId,
                     job,
                     level,
                     exp);
}

auto addSquadExp(const uint32 squadId, const uint32 job, const uint32 gain, const uint32 cap) -> sol::table
{
    uint32 level = 1;
    uint32 exp   = 0;

    const auto rset = db::preparedStmt("SELECT level, exp FROM squad_job WHERE squad_id = ? AND job = ?", squadId, job);
    FOR_DB_SINGLE_RESULT(rset)
    {
        level = rset->get<uint8>("level");
        exp   = rset->get<uint32>("exp");
    }

    const uint32 startLevel = level;
    const uint32 maxLevel   = std::clamp<uint32>(cap, 1, 99);

    exp += gain;
    while (level < maxLevel)
    {
        const uint32 needed = charutils::GetExpNEXTLevel(static_cast<uint8>(level));
        if (needed == 0 || exp < needed)
        {
            break;
        }

        exp -= needed;
        level++;
    }

    if (level >= maxLevel)
    {
        level = maxLevel;
        exp   = 0;
    }

    setSquadJob(squadId, job, level, exp);

    auto result      = ::lua.create_table();
    result["level"]  = level;
    result["exp"]    = exp;
    result["gained"] = level - startLevel;
    return result;
}

auto getSquadExpNeeded(const uint32 level) -> uint32
{
    return charutils::GetExpNEXTLevel(static_cast<uint8>(std::clamp<uint32>(level, 0, 255)));
}

void setSquadEquip(const uint32 squadId, const uint32 job, const uint32 slot, const uint32 itemId)
{
    if (itemId == 0)
    {
        db::preparedStmt("DELETE FROM squad_equip WHERE squad_id = ? AND job = ? AND slot = ?", squadId, job, slot);
        return;
    }

    db::preparedStmt("INSERT INTO squad_equip (squad_id, job, slot, itemid) VALUES (?, ?, ?, ?) "
                     "ON DUPLICATE KEY UPDATE itemid = VALUES(itemid)",
                     squadId,
                     job,
                     slot,
                     itemId);
}

// Accepts a numeric item id or an item name ("Bronze Harness" and "bronze_harness" both work)
auto findSquadItem(std::string text) -> uint32
{
    if (!text.empty() && std::all_of(text.begin(), text.end(), [](unsigned char c)
                                     { return std::isdigit(c) != 0; }))
    {
        return static_cast<uint32>(std::stoul(text));
    }

    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c)
                   { return static_cast<char>(c == ' ' ? '_' : std::tolower(c)); });

    const auto rset = db::preparedStmt("SELECT itemId FROM item_equipment WHERE name = ? LIMIT 1", text);
    FOR_DB_SINGLE_RESULT(rset)
    {
        return rset->get<uint32>("itemId");
    }

    // (squad option "spells from scrolls") spell scrolls by name too, e.g. scroll_of_cure_iii
    if (text.rfind("scroll", 0) == 0)
    {
        const auto srset = db::preparedStmt("SELECT itemid FROM item_basic WHERE name = ? LIMIT 1", text);
        FOR_DB_SINGLE_RESULT(srset)
        {
            return srset->get<uint32>("itemid");
        }
    }

    return 0;
}

// (squad option "spells from scrolls") a spell scroll: { spell, name, level = the lowest level any job learns it } or nil.
// Scrolls are items 4609-5631, item id = 4608 + spell id.
auto squadScrollSpell(const uint32 itemId) -> sol::object
{
    if (itemId < 4609 || itemId > 5631)
    {
        return sol::lua_nil;
    }

    const CItem* PItem = xi::items::lookup(static_cast<uint16>(itemId));
    if (PItem == nullptr || PItem->getName().find("scroll") == std::string::npos)
    {
        return sol::lua_nil;
    }

    CSpell* PSpell = spell::GetSpell(static_cast<SpellID>(itemId - 4608));
    if (PSpell == nullptr)
    {
        return sol::lua_nil;
    }

    uint8 lowest = 255;
    for (uint8 job = 1; job < MAX_JOBTYPE; ++job)
    {
        const uint8 at = PSpell->getJob(static_cast<xi::Job>(job));
        if (at > 0 && at < lowest)
        {
            lowest = at;
        }
    }

    auto t     = ::lua.create_table();
    t["spell"] = itemId - 4608;
    t["name"]  = PSpell->getName();
    t["level"] = lowest;
    return sol::make_object(::lua, t);
}

// (squad option "spells from scrolls") the blue magic a monster can teach (its skill list x blue_spell_list):
// { { spell, name, level }, ... } with level = the Blue Mage level of the spell
auto squadBlueSpellsOf(CLuaBaseEntity* mob) -> sol::table
{
    auto out = ::lua.create_table();
    auto* PMob = mob ? dynamic_cast<CMobEntity*>(mob->GetBaseEntity()) : nullptr;
    if (PMob == nullptr || PMob->m_MobSkillList == 0)
    {
        return out;
    }

    const auto rset = db::preparedStmt("SELECT DISTINCT b.spellid FROM blue_spell_list b JOIN mob_skill_lists l ON l.mob_skill_id = b.mob_skill_id "
                                       "WHERE l.skill_list_id = ?",
                                       PMob->m_MobSkillList);
    int index = 1;
    FOR_DB_MULTIPLE_RESULTS(rset)
    {
        const auto spellId = rset->get<uint16>("spellid");
        CSpell*    PSpell  = spell::GetSpell(static_cast<SpellID>(spellId));
        if (PSpell == nullptr)
        {
            continue;
        }

        auto e       = ::lua.create_table();
        e["spell"]   = spellId;
        e["name"]    = PSpell->getName();
        e["level"]   = PSpell->getJob(xi::Job::BLU);
        out[index++] = e;
    }

    return out;
}

// (2026-11-17) the blue magic a squad Blue Mage could set, for the Squad window and !squad blu: every blue spell the
// mate is high enough for (and, with "spells from scrolls", has learned when it is 18+), with its level and set
// points, and whether it is set now (the mate's SQUAD_BLU_* local vars, from trustutils.cpp)
auto squadKnownBlue(CLuaBaseEntity* mate, bool scrolls) -> sol::table
{
    auto  out    = ::lua.create_table();
    auto* PTrust = mate ? dynamic_cast<CTrustEntity*>(mate->GetBaseEntity()) : nullptr;
    if (PTrust == nullptr || (PTrust->GetMJob() != xi::Job::BLU && PTrust->GetSJob() != xi::Job::BLU))
    {
        return out;
    }

    const uint8 bluLevel = PTrust->GetMJob() == xi::Job::BLU ? PTrust->GetMLevel() : PTrust->GetSLevel();
    std::set<uint16> learned;
    if (scrolls)
    {
        if (auto* PMaster = dynamic_cast<CCharEntity*>(PTrust->PMaster))
        {
            const auto rset = db::preparedStmt("SELECT itemid FROM squad_unlock WHERE charid = ? AND itemid >= 60000", PMaster->id);
            FOR_DB_MULTIPLE_RESULTS(rset)
            {
                learned.insert(static_cast<uint16>(rset->get<uint16>("itemid") - 60000));
            }
        }
    }

    std::set<uint16> isSet;
    const uint32     count = PTrust->GetLocalVar("SQUAD_BLU_COUNT");
    for (uint32 i = 1; i <= count && i <= 20; ++i)
    {
        isSet.insert(static_cast<uint16>(PTrust->GetLocalVar(fmt::format("SQUAD_BLU_{}", i))));
    }

    int index = 1;
    for (uint16 id = 0x200; id < 0x300; ++id)
    {
        auto* PBlue = dynamic_cast<CBlueSpell*>(spell::GetSpell(static_cast<SpellID>(id)));
        if (PBlue == nullptr)
        {
            continue;
        }

        const uint8 level = PBlue->getJob(xi::Job::BLU);
        if (level == 0 || level > bluLevel || (scrolls && level >= 18 && !learned.contains(id)))
        {
            continue;
        }

        auto e       = ::lua.create_table();
        e["spell"]   = id;
        e["name"]    = PBlue->getName();
        e["level"]   = level;
        e["points"]  = PBlue->getSetPoints();
        e["set"]     = isSet.contains(id);
        out[index++] = e;
    }

    return out;
}

auto getSquadItemInfo(const uint32 itemId) -> sol::table
{
    auto info     = ::lua.create_table();
    info["valid"] = false;

    info["skill"]  = 0; // weapon skill (item_weapon: 1 hand-to-hand, 4 great sword, ... 25 archery, 26 marksmanship, 27 throwing)
    info["shield"] = 0; // shield size (0 = not a shield)

    const auto rset = db::preparedStmt("SELECT name, level, jobs, slot, shieldSize FROM item_equipment WHERE itemId = ?", itemId);
    FOR_DB_SINGLE_RESULT(rset)
    {
        info["valid"]  = true;
        info["name"]   = rset->get<std::string>("name");
        info["level"]  = rset->get<uint8>("level");
        info["jobs"]   = rset->get<uint32>("jobs");
        info["slot"]   = rset->get<uint32>("slot");
        info["shield"] = rset->get<uint8>("shieldSize");
    }

    // (for the squad's auto-equip: two-handed weapons, grips and shields, ammo that fits the ranged weapon;
    //  2026-11-22, lilibun: damage and delay too, so a weapon can be rated for a job)
    info["dmg"]   = 0;
    info["delay"] = 0;
    const auto rsetW = db::preparedStmt("SELECT skill, dmg, delay FROM item_weapon WHERE itemId = ?", itemId);
    FOR_DB_SINGLE_RESULT(rsetW)
    {
        info["skill"] = rsetW->get<uint8>("skill");
        info["dmg"]   = rsetW->get<uint32>("dmg");
        info["delay"] = rsetW->get<int32>("delay");
    }

    // (2026-11-22, lilibun: "a Warrior equips a Silver Hairpin") what the piece adds: mods[modId] = value, for
    // SQUAD_GEAR_SCORE.rate (modules/custom/late/squad_gear_score.lua). Lua's auto-equip keeps what it read.
    auto       mods  = ::lua.create_table();
    const auto rsetM = db::preparedStmt("SELECT modId, value FROM item_mods WHERE itemId = ?", itemId);
    FOR_DB_MULTIPLE_RESULTS(rsetM)
    {
        mods[rsetM->get<uint16>("modId")] = rsetM->get<int16>("value");
    }

    info["mods"] = mods;

    return info;
}

// (2026-11-21, Tasou/Yache: "Squad gets all gear" showed only the given gear in the gear picker) every piece of gear a
// job can wear in one equipment slot up to a level, best first: { { id, level, name } ... } (at most `limit`)
auto getSquadGearChoices(const uint32 equipSlot, const uint32 job, const uint32 level, const uint32 limit) -> sol::table
{
    auto list = ::lua.create_table();
    if (equipSlot > 15 || job < 1 || job > 22)
    {
        return list;
    }

    const uint32 count = std::clamp<uint32>(limit, 1, 200);
    const auto   rset  = db::preparedStmt("SELECT itemId, level, name FROM item_equipment "
                                          "WHERE (slot & ?) <> 0 AND (jobs & ?) <> 0 AND level <= ? AND ilevel = 0 "
                                          "ORDER BY level DESC, name ASC LIMIT 200",
                                          1u << equipSlot, 1u << (job - 1), level);
    int index = 1;
    FOR_DB_MULTIPLE_RESULTS(rset)
    {
        if (index > static_cast<int>(count))
        {
            break;
        }

        auto e     = ::lua.create_table();
        e["id"]    = rset->get<uint32>("itemId");
        e["level"] = rset->get<uint8>("level");
        e["name"]  = rset->get<std::string>("name");
        list[index++] = e;
    }

    return list;
}

// (2026-11-22, the user: with "Squad gets all gear" on, auto-equip did nothing: it only looked at gear that was given)
// Everything a job can wear up to a level, with what getSquadItemInfo tells about each piece, in three queries instead
// of three per piece: pool[itemId] = { valid, name, level, jobs, slot, shield, skill, dmg, delay, mods = { [modId] = value } }.
// squad.lua (squadGearPool) asks once per job and keeps the answer while the server runs.
auto getSquadGearPool(const uint32 job, const uint32 level) -> sol::table
{
    auto pool = ::lua.create_table();
    if (job < 1 || job > 22)
    {
        return pool;
    }

    const uint32                 jobBit = 1u << (job - 1);
    std::map<uint32, sol::table> pieces;

    const auto rset = db::preparedStmt("SELECT itemId, name, level, jobs, slot, shieldSize FROM item_equipment "
                                       "WHERE (jobs & ?) <> 0 AND level <= ? AND ilevel = 0",
                                       jobBit, level);
    FOR_DB_MULTIPLE_RESULTS(rset)
    {
        const auto itemId = rset->get<uint32>("itemId");
        auto       info   = ::lua.create_table();
        info["valid"]     = true;
        info["name"]      = rset->get<std::string>("name");
        info["level"]     = rset->get<uint8>("level");
        info["jobs"]      = rset->get<uint32>("jobs");
        info["slot"]      = rset->get<uint32>("slot");
        info["shield"]    = rset->get<uint8>("shieldSize");
        info["skill"]     = 0;
        info["dmg"]       = 0;
        info["delay"]     = 0;
        info["mods"]      = ::lua.create_table();
        pieces.emplace(itemId, info);
        pool[itemId] = info;
    }

    const auto rsetW = db::preparedStmt("SELECT w.itemId, w.skill, w.dmg, w.delay FROM item_weapon w "
                                        "JOIN item_equipment e ON e.itemId = w.itemId "
                                        "WHERE (e.jobs & ?) <> 0 AND e.level <= ? AND e.ilevel = 0",
                                        jobBit, level);
    FOR_DB_MULTIPLE_RESULTS(rsetW)
    {
        if (const auto it = pieces.find(rsetW->get<uint32>("itemId")); it != pieces.end())
        {
            it->second["skill"] = rsetW->get<uint8>("skill");
            it->second["dmg"]   = rsetW->get<uint32>("dmg");
            it->second["delay"] = rsetW->get<int32>("delay");
        }
    }

    const auto rsetM = db::preparedStmt("SELECT m.itemId, m.modId, m.value FROM item_mods m "
                                        "JOIN item_equipment e ON e.itemId = m.itemId "
                                        "WHERE (e.jobs & ?) <> 0 AND e.level <= ? AND e.ilevel = 0",
                                        jobBit, level);
    FOR_DB_MULTIPLE_RESULTS(rsetM)
    {
        if (const auto it = pieces.find(rsetM->get<uint32>("itemId")); it != pieces.end())
        {
            sol::table mods                   = it->second["mods"];
            mods[rsetM->get<uint16>("modId")] = rsetM->get<int16>("value");
        }
    }

    return pool;
}

// Basic level 1 gear a job can wear: main hand, head, body, hands, legs and feet.
// For each slot we take the lowest-numbered plain (no script, no item level) level 1 item that the job can equip.
auto buildStarterGear(const uint32 job) -> sol::table
{
    auto gear = ::lua.create_table();

    if (job < 1 || job > 22)
    {
        return gear;
    }

    for (const uint32 slot : { 0u, 4u, 5u, 6u, 7u, 8u })
    {
        const auto rset = db::preparedStmt("SELECT itemId FROM item_equipment "
                                           "WHERE level = 1 AND ilevel = 0 AND scriptType = 0 "
                                           "AND ((jobs >> ?) & 1) = 1 AND (slot & ?) <> 0 "
                                           "ORDER BY itemId LIMIT 1",
                                           job - 1,
                                           1u << slot);
        FOR_DB_SINGLE_RESULT(rset)
        {
            gear[static_cast<int>(slot)] = rset->get<uint16>("itemId");
        }
    }

    return gear;
}

// ---- Pets: a squad mate's wyvern or avatar (the game's pet code is used as it is) ----

auto toSquadMate(CLuaBaseEntity* mate) -> CTrustEntity*
{
    if (mate == nullptr || mate->GetBaseEntity() == nullptr)
    {
        return nullptr;
    }

    return dynamic_cast<CTrustEntity*>(mate->GetBaseEntity());
}

bool squadSpawnPet(CLuaBaseEntity* mate, const int petId)
{
    auto* PTrust = toSquadMate(mate);
    if (PTrust == nullptr || PTrust->PPet != nullptr || petId < 0 || petId >= MAX_PETID)
    {
        return false;
    }

    petutils::SpawnPet(PTrust, static_cast<uint32>(petId), false);
    return PTrust->PPet != nullptr;
}

// One squad mate leaves (the Squad window's per-mate Dismiss, !squad dismiss <slot>): the same as releasing a Trust
// by talking to it, without the 2 s wait. The others stay out.
bool squadDismissMate(CLuaBaseEntity* mate)
{
    auto* PTrust = toSquadMate(mate);
    if (PTrust == nullptr || PTrust->released())
    {
        return false;
    }

    auto* PChar = dynamic_cast<CCharEntity*>(PTrust->PMaster);
    if (PChar == nullptr)
    {
        return false;
    }

    PTrust->setReleased(true);
    PTrust->animation = xi::Animation::Death; // (the Trust's own leaving effect)
    PTrust->updatemask |= UPDATE_HP;
    PChar->RemoveTrust(PTrust);
    return true;
}

// (2026-11-23, Jker_s81, Rysan, Meli, krazy: the first mate out after zoning or a warp showed no armor, or the template's
// outfit) the look goes out once, in the spawn packet; a client still loading the area drops it and draws the mate from
// the later partial updates. squad.lua calls this a few seconds after a mate comes out: the look is sent again (the
// renamed look layout in entity_update.cpp keeps it whole), so a lost spawn look is redrawn. Harmless when it was fine.
bool squadRefreshLook(CLuaBaseEntity* mate)
{
    auto* PTrust = toSquadMate(mate);
    if (PTrust == nullptr || PTrust->released() || PTrust->look.size != MODEL_EQUIPPED)
    {
        return false;
    }

    // (2026-11-24, Ricc: mates standing at a camp vanished a few seconds after they were called) for a renamed entity with an equipped
    // look, the update that carries the look is always sent as position + claim + general + look (CEntityUpdatePacket::updateWith
    // sets its flags to 0x57), but the packet only fills the parts its own mask asks for. With the look alone, a mate that stood
    // still (nothing else pending) went out with a position of 0, 0, 0 and no HP, and the client put it there. Ask for those parts
    // too, so what the flags announce is in the packet: the same parts the spawn packet carries.
    PTrust->updatemask |= UPDATE_COMBAT | UPDATE_LOOK;
    return true;
}

// (F12, 2026-11-25) SquadSetWsSet(mate, { [slot] = itemId, ... }): the mate's weapon skill gear set (armor slots 4-15
// only; anything else is ignored). squad_wsset.lua has already checked it (unlocks, job, level, slot, Rare, the
// outfit); the map server checks level and job again each time the set goes on (Level Sync). An empty table clears it.
// Returns the number of pieces kept (-1: not a squad mate). A set that is on right now is taken off first, so a change
// never leaks modifiers.
auto squadSetWsSet(CLuaBaseEntity* mate, const sol::table& set) -> int32
{
    auto* PTrust = toSquadMate(mate);
    if (PTrust == nullptr)
    {
        return -1;
    }

    PTrust->RestoreSquadWsSet();

    squad::wsset::Gear gear{};
    int32              kept = 0;
    for (const auto& kv : set)
    {
        if (!kv.first.is<int>() || !kv.second.is<int>())
        {
            continue;
        }

        const int slot   = kv.first.as<int>();
        const int itemId = kv.second.as<int>();
        if (squad::wsset::IsSetSlot(slot) && itemId > 0 && itemId <= 0xFFFF &&
            xi::items::lookup<CItemEquipment>(static_cast<uint16>(itemId)) != nullptr)
        {
            gear[slot] = static_cast<uint16>(itemId);
            ++kept;
        }
    }

    PTrust->setSquadWsSet(gear);
    return kept;
}

// (F12) SquadWsSetInfo(mate) -> { active = bool, [slot] = itemId ... }: what the map server holds for the mate
auto squadWsSetInfo(CLuaBaseEntity* mate) -> sol::table
{
    auto  out    = ::lua.create_table();
    auto* PTrust = toSquadMate(mate);
    if (PTrust == nullptr)
    {
        return out;
    }

    out["active"]   = PTrust->squadWsSetActive();
    const auto& set = PTrust->squadWsSet();
    for (int slot = squad::wsset::FirstSlot; slot <= squad::wsset::LastSlot; ++slot)
    {
        if (set[slot] != 0)
        {
            out[slot] = set[slot];
        }
    }

    return out;
}

// !squad sync <name> | off: the party menu's Level Sync, by name (a player, a bot or a squad mate in your party).
// The same call the menu's packet makes, so the same rules apply (you lead the party, the target is 10+ and here).
// Returns: 1 done (the server's own messages tell the result), 0 no party, -1 not the leader.
int squadLevelSync(CLuaBaseEntity* player, const std::string& name)
{
    auto* PChar = player ? dynamic_cast<CCharEntity*>(player->GetBaseEntity()) : nullptr;
    if (PChar == nullptr || PChar->PParty == nullptr)
    {
        return 0;
    }

    if (PChar->PParty->GetLeader() != PChar)
    {
        return -1;
    }

    if (name.empty())
    {
        PChar->PParty->SetSyncTarget("", MsgStd::LevelSyncRemoveLeftParty);
    }
    else
    {
        PChar->PParty->AssignPartyRole(name, GP_CLI_COMMAND_GROUP_CHANGE2_CHANGEKIND::SetLevelSync);
    }

    return 1;
}

// a squad mate levelled up: a party synced to it follows its new level
void squadSyncLevelled(CLuaBaseEntity* player, const std::string& name, const int level)
{
    auto* PChar = player ? dynamic_cast<CCharEntity*>(player->GetBaseEntity()) : nullptr;
    if (PChar != nullptr && PChar->PParty != nullptr)
    {
        PChar->PParty->SquadMateLevelled(name, static_cast<uint8>(std::clamp(level, 0, 99)));
    }
}

bool squadHasPet(CLuaBaseEntity* mate)
{
    const auto* PTrust = toSquadMate(mate);
    return PTrust != nullptr && PTrust->PPet != nullptr && !PTrust->PPet->isDead();
}

void squadPetAttack(CLuaBaseEntity* mate, CLuaBaseEntity* target)
{
    auto* PTrust = toSquadMate(mate);
    if (PTrust == nullptr || PTrust->PPet == nullptr || PTrust->PPet->isDead() || target == nullptr)
    {
        return;
    }

    auto* PTarget = dynamic_cast<CBattleEntity*>(target->GetBaseEntity());
    if (PTarget == nullptr || PTarget->isDead() || PTrust->PPet->PAI->IsEngaged())
    {
        return;
    }

    petutils::AttackTarget(PTrust, PTarget);
}

// ---- Spells ----

bool isLearnableGroup(const SPELLGROUP group)
{
    return group != SPELLGROUP_TRUST && group != SPELLGROUP_BLUE && group != SPELLGROUP_SUMMONING && group != SPELLGROUP_GEOMANCY;
}

// Names of the spells a job learns when going from oldLevel to newLevel
auto squadNewSpells(const int job, const int oldLevel, const int newLevel) -> sol::table
{
    auto names = ::lua.create_table();
    if (job < 1 || job > 22)
    {
        return names;
    }

    int count = 1;
    for (uint16 id = 1; id < MAX_SPELL_ID; ++id)
    {
        CSpell* PSpell = spell::GetSpell(static_cast<SpellID>(id));
        if (PSpell == nullptr || !isLearnableGroup(PSpell->getSpellGroup()))
        {
            continue;
        }

        // (2026-11-18) the level-up line only names spells a player could learn: no Trust-only ones without a scroll
        // (Diaga II), like the known-spell list itself (trustutils)
        if (PSpell->getSpellGroup() != SPELLGROUP_BLUE && xi::items::lookup(static_cast<uint16>(0x1200 + id)) == nullptr)
        {
            continue;
        }

        const int needed = PSpell->getJob(static_cast<xi::Job>(job));
        if (needed > oldLevel && needed <= newLevel)
        {
            names[count++] = PSpell->getName();
        }
    }

    return names;
}

enum class SpellCastResult
{
    Cast,
    Unknown,
    NotReady,
    NoTarget,
    Busy,
};

auto spellResultName(const SpellCastResult result) -> const char*
{
    switch (result)
    {
        case SpellCastResult::Cast: return "cast";
        case SpellCastResult::Unknown: return "unknown";
        case SpellCastResult::NotReady: return "notready";
        case SpellCastResult::NoTarget: return "notarget";
        default: return "busy";
    }
}

// Asks one squad mate to cast a spell: beneficial spells go on the player (or on the party member named in the chat,
// e.g. "Kasumi cure Momo"), attack and debuff spells on their enemy
auto trySquadCast(CCharEntity* PChar, CTrustEntity* PTrust, const SpellID spellId, CBattleEntity* PNamed = nullptr) -> SpellCastResult
{
    CSpell* PSpell = spell::GetSpell(spellId);
    if (PSpell == nullptr || !spell::CanUseSpell(PTrust, PSpell))
    {
        return SpellCastResult::Unknown;
    }

    CBattleEntity* PTarget = nullptr;
    if (PSpell->canTargetEnemy())
    {
        PTarget = PChar->GetBattleTarget();
        if (PTarget == nullptr)
        {
            PTarget = PTrust->GetBattleTarget();
        }

        // (2026-11-21, sparkiie: "/p sleepga ii" did nothing before a fight) nobody engaged yet: the monster you have
        // targeted (the one the game's own <t> means), if it is a monster in this area
        if (PTarget == nullptr && PChar->m_TargID != 0)
        {
            auto* PSeen = dynamic_cast<CBattleEntity*>(PChar->GetEntity(PChar->m_TargID, TYPE_MOB));
            if (PSeen != nullptr && PSeen->objtype == TYPE_MOB && !PSeen->isDead())
            {
                PTarget = PSeen;
            }
        }
    }
    else if (PNamed != nullptr)
    {
        // someone else than the caster needs a spell that may go on party members (not a self-only spell like Utsusemi)
        const bool partySpell = (PSpell->getValidTarget() & (TARGET_PLAYER_PARTY | TARGET_PLAYER_ALLIANCE | TARGET_PLAYER_DEAD)) != 0; // (Raise: dead only)
        if (PNamed != PTrust && !partySpell)
        {
            return SpellCastResult::NoTarget;
        }

        PTarget = PNamed;
    }
    else
    {
        PTarget = PChar;
    }

    // (2026-11-21, Tasou in co-op: "/p raise tasou" did nothing) a Raise goes on someone who is knocked out; every other
    // spell needs a target that is still standing
    const bool forTheDead = (PSpell->getValidTarget() & TARGET_PLAYER_DEAD) != 0;
    if (PTarget == nullptr || PTarget->isDead() != forTheDead || PTarget->getZone() != PTrust->getZone())
    {
        return SpellCastResult::NoTarget;
    }

    if (!PTrust->SpellContainer->GetAvailable(spellId).has_value())
    {
        return SpellCastResult::NotReady; // not enough MP, or the spell is still recasting
    }

    auto* controller = dynamic_cast<CTrustController*>(PTrust->PAI->GetController());
    if (controller == nullptr)
    {
        return SpellCastResult::Busy;
    }

    // (2026-11-22) an area spell that waits for its caster to step within reach of you is on its way: not "busy"
    if (controller->Cast(PTarget->entityId(), spellId) || controller->IsSteppingIn())
    {
        return SpellCastResult::Cast;
    }

    return SpellCastResult::Busy;
}

// Party chat is also handed to Lua (xi.squad.onPartyChat), where it goes to the squad-chat sidecar and comes back
// as in-character lines in party chat. The message itself is never blocked or changed.
void forwardPartyChat(CCharEntity* PChar, CBasicPacket& packet)
{
    if (PChar == nullptr)
    {
        return;
    }

    const auto* chat = packet.as<GP_CLI_COMMAND_CHAT_STD>();
    if (chat->Kind != static_cast<uint8_t>(GP_CLI_COMMAND_CHAT_STD_KIND::Party))
    {
        return;
    }

    const std::size_t total = static_cast<std::size_t>(chat->header.size) * 4;
    if (total <= 6)
    {
        return;
    }

    const std::size_t length = std::min<std::size_t>(total - 6, sizeof(chat->Str));
    std::string       text(reinterpret_cast<const char*>(chat->Str), length);
    text = text.substr(0, text.find('\0'));

    // Commands stay out of the AI chat, except /p !note, which the sidecar turns into a journal entry.
    const bool noteCommand = text == "!note" || text.rfind("!note ", 0) == 0;
    if (text.empty() || text[0] == '/' || (text[0] == '!' && !noteCommand))
    {
        return;
    }

    // Auto-translate phrases arrive as raw bytes (FD 02 02 xx xx FD); decode them the same way the spell commands do.
    if (text.find('\xFD') != std::string::npos)
    {
        text = autotranslate::replaceBytes(text);
    }

    const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
    if (!xiTable)
    {
        return;
    }

    const sol::optional<sol::table> squadTable = (*xiTable)["squad"].get<sol::optional<sol::table>>();
    if (!squadTable)
    {
        return;
    }

    sol::protected_function handler = (*squadTable)["onPartyChat"];
    if (!handler.valid())
    {
        return;
    }

    const auto outcome = handler(CLuaBaseEntity(PChar), text);
    if (!outcome.valid())
    {
        const sol::error err = outcome;
        ShowError("[SQUAD] party chat handler failed: %s", err.what());
    }
}

// ---- Job abilities ----

auto findAbilityByName(const std::string& name) -> CAbility*
{
    for (uint16 id = 0; id < MAX_ABILITY_ID; ++id)
    {
        CAbility* PAbility = ability::GetAbility(id);
        if (PAbility != nullptr && !PAbility->isPetAbility() && PAbility->getName() == name)
        {
            return PAbility;
        }
    }

    return nullptr;
}

// (Gambits v2 U13) How many upgrades a player has in a merit, whatever job they have on now: the count the server's own
// check uses (charutils::CheckAbilityAddtype), not CMeritPoints::GetMeritValue (that one is 0 unless the merit's job is
// the current main job at 75+). 0 for no player, no merit data or an unknown merit id (GetMerit returns nullptr then).
auto ownerMeritCount(CCharEntity* PChar, const uint16 meritId) -> uint8
{
    if (PChar == nullptr || PChar->PMeritPoints == nullptr || meritId == 0)
    {
        return 0;
    }

    const Merit_t* PMerit = PChar->PMeritPoints->GetMerit(static_cast<xi::Merit>(meritId));
    return PMerit != nullptr ? PMerit->count : 0;
}

// Lua: SquadOwnerMerit(player, meritId) -> upgrades (squad_ability_rules.lua: merit abilities of the player's squad mates)
// (int32, not uint8: sol2 must hand Lua a number, never a one-character string)
auto squadOwnerMerit(CLuaBaseEntity* player, const uint16 meritId) -> int32
{
    auto* PChar = player != nullptr ? dynamic_cast<CCharEntity*>(player->GetBaseEntity()) : nullptr;
    return static_cast<int32>(ownerMeritCount(PChar, meritId));
}

// Asks one squad mate to use a job ability: self abilities on themselves, enemy abilities on your enemy, the rest on you
auto trySquadAbility(CCharEntity* PChar, CTrustEntity* PTrust, CAbility* PAbility) -> SpellCastResult
{
    if (PAbility == nullptr || !ability::CanLearnAbility(PTrust, PAbility->getID()))
    {
        return SpellCastResult::Unknown;
    }

    // Thin C++ step 2: the player rules (main job and level, sub job, never a pet or two hour ability as the sub job, the owner's merits)
    // are SQ_LOGIC.mayUse in sq_logic.lua, checked in Lua before this function is reached (SquadTryAbility and SquadUseAbility there).

    const uint16   valid   = PAbility->getValidTarget();
    CBattleEntity* PTarget = nullptr;
    if (valid & TARGET_ENEMY)
    {
        PTarget = PChar->GetBattleTarget();
        if (PTarget == nullptr)
        {
            PTarget = PTrust->GetBattleTarget();
        }
    }
    else if (valid & TARGET_SELF)
    {
        PTarget = PTrust;
    }
    else
    {
        PTarget = PChar;
    }

    if (PTarget == nullptr || PTarget->isDead())
    {
        return SpellCastResult::NoTarget;
    }

    // (squad audit N5) the ability's own recast and the player's shared recast group / charges
    if (PTrust->IsAbilityOnRecast(PAbility))
    {
        return SpellCastResult::NotReady;
    }

    auto* controller = dynamic_cast<CTrustController*>(PTrust->PAI->GetController());
    if (controller == nullptr)
    {
        return SpellCastResult::Busy;
    }

    return controller->Ability(PTarget->entityId(), PAbility->getID()) ? SpellCastResult::Cast : SpellCastResult::Busy;
}

// Lua: SquadUseAbility(player, mate, abilityId) -> result name (used to try again while the mate is busy)
auto squadUseAbility(CLuaBaseEntity* player, CLuaBaseEntity* mate, const uint16 abilityId) -> std::string
{
    auto* PChar  = player != nullptr ? dynamic_cast<CCharEntity*>(player->GetBaseEntity()) : nullptr;
    auto* PTrust = toSquadMate(mate);
    if (PChar == nullptr || PTrust == nullptr || PTrust->isDead())
    {
        return "busy";
    }

    return spellResultName(trySquadAbility(PChar, PTrust, ability::GetAbility(abilityId)));
}

// (2026-11-23, Frost: "a way to know which spells they can even cast") the spells and job abilities a called mate can use
// right now, for the profile window's Spells and abilities list: { spells = { {name, mp}, ... }, abilities = { {name, level}, ... } }.
// Spells: what its spell lists hold (they follow its jobs, levels and, with the scroll rule on, the scrolls it was given).
// Abilities: its main and support jobs' abilities it has the level for (squad.lua then applies SQ_LOGIC.mayUse).
auto squadKnownActions(CLuaBaseEntity* mate) -> sol::table
{
    auto out       = ::lua.create_table();
    auto spells    = ::lua.create_table();
    auto abilities = ::lua.create_table();
    out["spells"]    = spells;
    out["abilities"] = abilities;

    auto* PTrust = toSquadMate(mate);
    if (PTrust == nullptr)
    {
        return out;
    }

    if (PTrust->SpellContainer != nullptr)
    {
        std::set<uint16> seen;
        int              n    = 0;
        auto*            cont = PTrust->SpellContainer;
        for (const auto* list : { &cont->m_healList, &cont->m_naList, &cont->m_raiseList, &cont->m_buffList, &cont->m_debuffList,
                                  &cont->m_damageList, &cont->m_gaList, &cont->m_severeList })
        {
            for (const auto spellId : *list)
            {
                auto* PSpell = spell::GetSpell(spellId);
                if (PSpell == nullptr || !seen.insert(static_cast<uint16>(spellId)).second)
                {
                    continue;
                }

                auto row  = ::lua.create_table();
                row["id"]   = static_cast<uint16>(spellId);
                row["name"] = PSpell->getName();
                row["mp"]   = PSpell->getMPCost();
                spells[++n] = row;
            }
        }
    }

    std::set<uint16> seenAbility;
    int              n = 0;
    for (const auto job : { PTrust->GetMJob(), PTrust->GetSJob() })
    {
        if (job == xi::Job::NONE)
        {
            continue;
        }

        for (auto* PAbility : ability::GetAbilities(job))
        {
            // (the player rules - main job only, two hour, pets, merits - are SQ_LOGIC.mayUse in sq_logic.lua: squad.lua filters this list)
            if (PAbility == nullptr || !seenAbility.insert(PAbility->getID()).second || !ability::CanLearnAbility(PTrust, PAbility->getID()))
            {
                continue;
            }

            auto row     = ::lua.create_table();
            row["id"]    = PAbility->getID();
            row["name"]  = PAbility->getName();
            row["level"] = PAbility->getLevel();
            abilities[++n] = row;
        }
    }

    return out;
}

// ---- Thin C++ step 1: the engine calls squad_logic.lua needs (stable signatures, no decisions) ----

// Lua: SquadSpellIdByName(name) -> spell id | nil (the server's spell name table)
auto squadSpellIdByName(const std::string& name) -> std::optional<uint16>
{
    const auto id = spell::lookupIdByName(name);
    return id.has_value() ? std::optional<uint16>(static_cast<uint16>(id.value())) : std::nullopt;
}

// Lua: SquadAbilityIdByName(name) -> job ability id | nil (never a pet ability)
auto squadAbilityIdByName(const std::string& name) -> std::optional<uint16>
{
    CAbility* PAbility = findAbilityByName(name);
    return PAbility != nullptr ? std::optional<uint16>(PAbility->getID()) : std::nullopt;
}

// Lua: SquadAbilityName(abilityId) -> the ability's name | nil
auto squadAbilityName(const uint16 abilityId) -> std::optional<std::string>
{
    CAbility* PAbility = ability::GetAbility(abilityId);
    return PAbility != nullptr ? std::optional<std::string>(PAbility->getName()) : std::nullopt;
}

// Lua: SquadTwoHourAbilityId(mate) -> the two-hour ability of the mate's main job | nil
auto squadTwoHourAbilityId(CLuaBaseEntity* mate) -> std::optional<uint16>
{
    auto* PTrust = toSquadMate(mate);
    if (PTrust == nullptr)
    {
        return std::nullopt;
    }

    CAbility* PAbility = ability::GetTwoHourAbility(PTrust->GetMJob());
    return PAbility != nullptr ? std::optional<uint16>(PAbility->getID()) : std::nullopt;
}

// Lua: SquadCastSpell(player, mate, spellId, target | nil) -> result name (cast, unknown, notready, notarget, busy)
// The check and the cast of a spell typed in party chat: beneficial spells go on the player (or on `target`), attack and
// debuff spells on the enemy.
auto squadCastSpell(CLuaBaseEntity* player, CLuaBaseEntity* mate, const uint16 spellId, CLuaBaseEntity* target) -> std::string
{
    auto* PChar  = player != nullptr ? dynamic_cast<CCharEntity*>(player->GetBaseEntity()) : nullptr;
    auto* PTrust = toSquadMate(mate);
    if (PChar == nullptr || PTrust == nullptr || PTrust->isDead())
    {
        return "busy";
    }

    auto* PNamed = target != nullptr ? dynamic_cast<CBattleEntity*>(target->GetBaseEntity()) : nullptr;
    return spellResultName(trySquadCast(PChar, PTrust, static_cast<SpellID>(spellId), PNamed));
}

// Lua: SquadSpellKind(spellId) -> "enemy" | "dead" | "party" | "self" | "" (unknown spell)
// What a spell can be cast on, read from the server's spell table with the same flags trySquadCast uses: an attack or debuff spell goes on an
// enemy, a Raise on a fallen party member, a buff or heal on a party member, and anything else (Warp, Utsusemi, Reraise) only on its caster.
// (2026-11-24) A spell cast on the caster that reaches the party around it (Protectra, Shellra, the Bar-ra spells, a Teleport, a song) is
// "party" too: the rule is in map/ai/helpers/squad_spell_kind.h.
static_assert(squad::spellkind::TargetSelf == TARGET_SELF && squad::spellkind::TargetParty == TARGET_PLAYER_PARTY &&
              squad::spellkind::TargetAlliance == TARGET_PLAYER_ALLIANCE && squad::spellkind::TargetDead == TARGET_PLAYER_DEAD);
static_assert(squad::spellkind::AoeRadial == SPELLAOE_RADIAL && squad::spellkind::AoePianissimo == SPELLAOE_PIANISSIMO);

auto squadSpellKind(const uint16 spellId) -> std::string
{
    CSpell* PSpell = spell::GetSpell(static_cast<SpellID>(spellId));
    if (PSpell == nullptr)
    {
        return "";
    }

    const squad::spellkind::Facts facts{
        .canTargetEnemy = PSpell->canTargetEnemy(),
        .validTargets   = PSpell->getValidTarget(),
        .aoe            = PSpell->getAOE(),
        .radius         = PSpell->getRadius(),
        .song           = PSpell->getSpellGroup() == SPELLGROUP_SONG,
    };

    return squad::spellkind::Name(squad::spellkind::Classify(facts));
}

// Lua: SquadPartyFoes(player, x, y, z, radius) -> count, name of the nearest ("" when none), its targid (0 when none)
// (B1, 2026-11-25) the monsters fighting the player's party within `radius` of the point: a link or a monster's pet still on the
// party at camp keeps the next pull back (squad.lua campTick). The rule is CTrustController::PartyFoes / squad_threat.h.
auto squadPartyFoes(CLuaBaseEntity* player, const float x, const float y, const float z, const float radius) -> std::tuple<int32, std::string, int32>
{
    auto* PChar = player != nullptr ? dynamic_cast<CCharEntity*>(player->GetBaseEntity()) : nullptr;
    if (PChar == nullptr)
    {
        return { 0, "", 0 };
    }

    position_t anchor = PChar->loc.p;
    anchor.x          = x;
    anchor.y          = y;
    anchor.z          = z;
    const auto foes   = CTrustController::PartyFoes(PChar, anchor, radius > 0.0f ? radius : CTrustController::CampFightReach);
    if (foes.empty())
    {
        return { 0, "", 0 };
    }

    return { static_cast<int32>(foes.size()), std::string(foes.front()->getName()), static_cast<int32>(foes.front()->targid) };
}

// Lua: SquadTryAbility(player, mate, abilityId) -> result name (cast, unknown, notready, notarget, busy)
auto squadTryAbility(CLuaBaseEntity* player, CLuaBaseEntity* mate, const uint16 abilityId) -> std::string
{
    auto* PChar  = player != nullptr ? dynamic_cast<CCharEntity*>(player->GetBaseEntity()) : nullptr;
    auto* PTrust = toSquadMate(mate);
    if (PChar == nullptr || PTrust == nullptr || PTrust->isDead())
    {
        return "busy";
    }

    return spellResultName(trySquadAbility(PChar, PTrust, ability::GetAbility(abilityId)));
}

// Typing a spell or job ability in party chat (optionally "all" or a squad mate's name first) makes squad mates use it.
// The chat message itself is never blocked. Thin layer: the packet is decoded here, everything else (clean-up, who is
// asked, spell or ability, the order, the failure ranking, the reply lines) is xi.squad.onChatCommand in squad_logic.lua.
void handleSpellChat(CCharEntity* PChar, CBasicPacket& packet)
{
    if (PChar->PTrusts.empty())
    {
        return;
    }

    const auto* chat = packet.as<GP_CLI_COMMAND_CHAT_STD>();
    if (chat->Kind != static_cast<uint8_t>(GP_CLI_COMMAND_CHAT_STD_KIND::Party))
    {
        return;
    }

    const std::size_t total = static_cast<std::size_t>(chat->header.size) * 4;
    if (total <= 6)
    {
        return;
    }

    const std::size_t length = std::min<std::size_t>(total - 6, sizeof(chat->Str));
    std::string       text(reinterpret_cast<const char*>(chat->Str), length);
    text = text.substr(0, text.find('\0'));

    if (text.empty() || text[0] == '!' || text[0] == '/')
    {
        return;
    }

    // Auto-translate phrases arrive as raw bytes (FD 02 02 xx xx FD). The game's own decoder turns them into plain English text,
    // so {Cure IV} works exactly like typing Cure IV.
    const bool hadAutoTranslate = text.find('\xFD') != std::string::npos;
    if (hadAutoTranslate)
    {
        text = autotranslate::replaceBytes(text);
    }

    const sol::optional<sol::table> xiTable    = ::lua["xi"].get<sol::optional<sol::table>>();
    const sol::optional<sol::table> squadTable = xiTable ? (*xiTable)["squad"].get<sol::optional<sol::table>>() : sol::nullopt;
    if (!squadTable)
    {
        return;
    }

    sol::protected_function handler = (*squadTable)["onChatCommand"];
    if (!handler.valid())
    {
        return;
    }

    const auto outcome = handler(CLuaBaseEntity(PChar), text, hadAutoTranslate);
    if (!outcome.valid())
    {
        const sol::error err = outcome;
        ShowError("[SQUAD] chat command handler failed: %s", err.what());
    }
}

void unlockSquadItem(const uint32 charId, const uint32 itemId)
{
    db::preparedStmt("INSERT IGNORE INTO squad_unlock (charid, itemid) VALUES (?, ?)", charId, itemId);
}

auto getSquadUnlocks(const uint32 charId) -> sol::table
{
    auto result = ::lua.create_table();

    const auto rset = db::preparedStmt("SELECT itemid FROM squad_unlock WHERE charid = ?", charId);
    FOR_DB_MULTIPLE_RESULTS(rset)
    {
        result[static_cast<int>(rset->get<uint16>("itemid"))] = true;
    }

    return result;
}

void deleteSquadMate(const uint32 charId, const uint32 slot)
{
    db::preparedStmt("DELETE FROM squad_equip WHERE squad_id IN (SELECT id FROM squad_mate WHERE charid = ? AND slot = ?)", charId, slot);
    db::preparedStmt("DELETE FROM squad_job WHERE squad_id IN (SELECT id FROM squad_mate WHERE charid = ? AND slot = ?)", charId, slot);
    db::preparedStmt("DELETE FROM squad_mate WHERE charid = ? AND slot = ?", charId, slot);
}

} // namespace

class SquadModule : public CPPModule
{
    // The game only lets you trade with NPCs and monsters, so a trade to a squad mate would be ignored.
    // We catch it here and hand the offered items to Lua (xi.squad.onTrade), which decides what to do with them.
    auto OnIncomingPacket(MapSession* session, CCharEntity* PChar, CBasicPacket& packet) -> bool override
    {
        const auto type = static_cast<unsigned>(packet.getType());

        if (type == 0x0B5)
        {
            // (v0.3.3, G19) the mates read the line first: a request they take is marked in Lua, and the chat sidecar (xi.squad.onPartyChat)
            // then leaves it alone instead of answering it as conversation
            handleSpellChat(PChar, packet);
            forwardPartyChat(PChar, packet);
            return false; // the chat message always goes through
        }

        // Trade packets are rare, so log them: it shows which kind of trade the client starts with a squad mate
        if (type == 0x032 || type == 0x033 || type == 0x034 || type == 0x036)
        {
            ShowInfo("[SQUAD] trade packet 0x%03X from %s", type, PChar->getName());
        }

        if (type == 0x032)
        {
            // A player-style trade request. The game only answers these for real players.
            const auto* request = packet.as<GP_CLI_COMMAND_TRADE_REQ>();
            const auto* PTarget = PChar->GetEntity(request->ActIndex, TYPE_TRUST);
            ShowInfo("[SQUAD] player-style trade request to index %u: %s", static_cast<unsigned>(request->ActIndex), PTarget != nullptr ? "that is a trust" : "not a trust");
            return false;
        }

        if (type != 0x036)
        {
            return false;
        }

        const auto* transfer = packet.as<GP_CLI_COMMAND_ITEM_TRANSFER>();

        auto* PTrust = dynamic_cast<CTrustEntity*>(PChar->GetEntity(transfer->ActIndex, TYPE_TRUST));
        if (PTrust == nullptr)
        {
            ShowInfo("[SQUAD] 0x036 trade to index %u (id %u): no trust found there, passing it on", static_cast<unsigned>(transfer->ActIndex), static_cast<unsigned>(transfer->UniqueNo));
            return false;
        }

        const auto   known   = squadEntities.find(PTrust->id);
        const uint32 squadId = known != squadEntities.end() ? known->second : PTrust->GetLocalVar("SQUAD_ID");

        // Your own squad mates, or those of someone in your party (the dualbox character trading to the main
        // character's squad); the gear then joins the owner's collection (xi.squad.onTrade uses the trust's master).
        const bool partyMateOwner = PTrust->PMaster != nullptr && PTrust->PMaster != PChar && PChar->PParty != nullptr &&
                                    PTrust->PMaster->objtype == TYPE_PC && PTrust->PMaster->PParty == PChar->PParty;
        if (PTrust->id != transfer->UniqueNo || (PTrust->PMaster != PChar && !partyMateOwner) || squadId == 0)
        {
            ShowInfo("[SQUAD] 0x036 trade to trust %s (shown as '%s'): not one of your squad mates (id match %i, yours %i, squad id %u, in squad list %i), passing it on",
                     PTrust->getName(), PTrust->packetName.c_str(), PTrust->id == transfer->UniqueNo ? 1 : 0, PTrust->PMaster == PChar ? 1 : 0,
                     static_cast<unsigned>(squadId), known != squadEntities.end() ? 1 : 0);
            return false; // not one of our squad mates: let the game handle it
        }

        PTrust->SetLocalVar("SQUAD_ID", squadId);

        const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
        if (!xiTable)
        {
            return false;
        }

        const sol::optional<sol::table> squadTable = (*xiTable)["squad"].get<sol::optional<sol::table>>();
        if (!squadTable)
        {
            return false;
        }

        sol::protected_function handler = (*squadTable)["onTrade"];
        if (!handler.valid())
        {
            ShowInfo("[SQUAD] trade to a squad mate, but xi.squad.onTrade is not defined");
            return false;
        }

        auto  items   = ::lua.create_table();
        int   count   = 1;
        auto* storage = PChar->getStorage(LOC_INVENTORY);

        for (uint8 i = 0; i < transfer->ItemNum && i < 10; ++i)
        {
            const uint8  invSlot  = transfer->PropertyItemIndexTbl[i];
            const uint32 quantity = transfer->ItemNumTbl[i];

            const CItem* PItem = storage->GetItem(invSlot);
            if (PItem == nullptr || quantity == 0 || PItem->isBusy())
            {
                continue;
            }

            auto offer        = ::lua.create_table();
            offer["itemId"]   = static_cast<int>(PItem->getID());
            offer["slot"]     = static_cast<int>(invSlot);
            offer["quantity"] = std::min<uint32>(quantity, PItem->getQuantity());
            items[count++]    = offer;
        }

        ShowInfo("[SQUAD] trade to squad mate %s: %i item(s) offered, calling xi.squad.onTrade", PTrust->getName(), count - 1);

        const auto result = handler(CLuaBaseEntity(PChar), CLuaBaseEntity(PTrust), items);
        if (!result.valid())
        {
            const sol::error err = result;
            ShowError("[SQUAD] trade handler failed: %s", err.what());
        }

        return true;
    }

    void OnInit() override
    {
        TracyZoneScoped;

        // The first non-passive trust of each main job becomes that job's template. Prefer a trust that
        // actually has usable weapon skills: Lhu Mhakaracca (the first BST trust) points at a skill list
        // with no rows, while Aamr has axe weapon skills, so without this a squad BST would get TP settings
        // with no skills behind them. The subquery counts real rows because a non-zero list id can be empty.
        const auto rset = db::preparedStmt("SELECT sl.spellid AS spellid, mp.mJob AS mjob, mp.name AS name, "
                                           "mp.skill_list_id AS skill_list_id, "
                                           "(SELECT COUNT(*) FROM mob_skill_lists msl WHERE msl.skill_list_id = mp.skill_list_id) AS skill_count "
                                           "FROM spell_list sl INNER JOIN mob_pools mp ON mp.poolid = sl.spellid + 5000 "
                                           "WHERE sl.spellid >= 896 ORDER BY sl.spellid");

        std::map<int, uint16> templateSkillCounts;

        FOR_DB_MULTIPLE_RESULTS(rset)
        {
            const auto spellId    = rset->get<uint32>("spellid");
            const auto job        = static_cast<int>(rset->get<uint8>("mjob"));
            const auto name       = rset->get<std::string>("name");
            const auto skillCount = rset->get<uint16>("skill_count");

            if (!isPassiveTemplate(name))
            {
                const auto existing = jobTemplates.find(job);
                if (existing == jobTemplates.end() || (templateSkillCounts[job] == 0 && skillCount != 0))
                {
                    jobTemplates[job]         = spellId;
                    templateSkillCounts[job]  = skillCount;
                }
            }
        }

        // There is no Summoner trust in the data at all (no trust pool with mJob 15), so a squad SMN would
        // normally fail with "no trust template found". Cornelia (trust 1002) has no spell list and no
        // weapon-skill list, so it is a clean body template: the squad record supplies the SMN job, level
        // and equipment, and the avatar comes from the normal pet data. A caster trust here would also leak
        // its own spell list onto the Summoner.
        if (jobTemplates.find(15) == jobTemplates.end())
        {
            jobTemplates.emplace(15, 1002); // Cornelia
        }

        // Blue Mage (16) has no trust either; Corsair (17) and Puppetmaster (18) normally do (Luzaf / Qultada,
        // Nashmeira), but an era database may not carry them. The same clean body template covers all three.
        for (const int toauJob : { 16, 17, 18 })
        {
            if (jobTemplates.find(toauJob) == jobTemplates.end())
            {
                jobTemplates.emplace(toauJob, 1002); // Cornelia
            }
        }

        ShowInfo("[SQUAD] Loaded trust templates for %zu jobs", jobTemplates.size());

        ::lua.set_function("SpawnSquadMate", spawnSquadMate);
        ::lua.set_function("SquadUseAbilityRaw", squadUseAbility);
        ::lua.set_function("SquadSpellIdByName", squadSpellIdByName);       // thin C++ step 1 (squad_logic.lua)
        ::lua.set_function("SquadAbilityIdByName", squadAbilityIdByName);
        ::lua.set_function("SquadAbilityName", squadAbilityName);
        ::lua.set_function("SquadTwoHourAbilityId", squadTwoHourAbilityId);
        ::lua.set_function("SquadCastSpell", squadCastSpell);
        ::lua.set_function("SquadSpellKind", squadSpellKind);
        ::lua.set_function("SquadPartyFoes", squadPartyFoes); // (B1) links and pets still on the party at camp
        ::lua.set_function("SquadTryAbilityRaw", squadTryAbility);
        ::lua.set_function("GetSquad", getSquad);
        ::lua.set_function("SaveSquadMate", saveSquadMate);
        ::lua.set_function("SetSquadJob", setSquadJob);
        ::lua.set_function("AddSquadExp", addSquadExp);
        ::lua.set_function("GetSquadExpNeeded", getSquadExpNeeded);
        ::lua.set_function("GetSquadWeaponSkills", getSquadWeaponSkills);
    ::lua.set_function("GetSquadWeaponSkillIds", getSquadWeaponSkillIds);     // Gambits weapon skill settings
    ::lua.set_function("SquadApplyWeaponSkills", squadApplyWeaponSkills);     // Gambits weapon skill settings (live apply)
    // (Gambits job expansion) this xi_map has MOD_LT, the magic burst timing, managed Sneak/Trick Attack, the weapon skill
    // hold and squad song recipients: the Lua side offers those only when this answers
    ::lua.set_function("SquadJobExpansionEngine", []() -> int32 { return 1; });
    // (Gambits Bard song tiers) this xi_map's STATUS / NOT_STATUS read a song tier in the argument's high 16 bits
    // (gambits_container.cpp HasStatusEffectTier): squad_rulesets.lua accepts { effect = NAME, tier = n } only then
    ::lua.set_function("SquadStatusTierEngine", []() -> int32 { return 1; });
    // (Gambits 0.3.3, Bard role targeting) role targets read include / exclude role bits from the target argument's high
    // byte (gambits_container.cpp AddGambit): squad_rulesets.lua accepts a rule's include / exclude only then
    ::lua.set_function("SquadRoleFilterEngine", []() -> int32 { return 1; });
    // (2026-11-25, community feedback milestone) marker: this xi_map has ENEMY_FAMILY, PARTY_COUNT, ENEMY_COUNT, the out of combat
    // support rules and SquadPartyFoes (squad_rulesets.lua R.engine3Ready)
    ::lua.set_function("SquadFeedbackEngine", []() -> int32 { return 1; });
    // (2026-11-25) marker: this xi_map places a mate by its local var SQUAD_POSITION (trust_controller.cpp PositionTick,
    // squad_position.h); squad.lua offers !squad position to the menu (cap matepos) only then
    ::lua.set_function("SquadPositionEngine", []() -> int32 { return 1; });
        ::lua.set_function("DeleteSquadMate", deleteSquadMate);
        ::lua.set_function("SetSquadEquip", setSquadEquip);
        ::lua.set_function("FindSquadItem", findSquadItem);
        ::lua.set_function("GetSquadItemInfo", getSquadItemInfo);
        ::lua.set_function("GetSquadGearChoices", getSquadGearChoices); // "Squad gets all gear" in the gear picker
        ::lua.set_function("GetSquadGearPool", getSquadGearPool);       // ...and for auto-equip: everything a job can wear
        ::lua.set_function("SquadScrollSpell", squadScrollSpell);
        ::lua.set_function("SquadBlueSpellsOf", squadBlueSpellsOf);
        ::lua.set_function("SquadKnownBlue", squadKnownBlue);
        ::lua.set_function("BuildStarterGear", buildStarterGear);
        ::lua.set_function("SquadSpawnPet", squadSpawnPet);
        ::lua.set_function("SquadHasPet", squadHasPet);
        ::lua.set_function("SquadDismissMate", squadDismissMate);
        ::lua.set_function("SquadKnownActions", squadKnownActions); // the profile window's spells and abilities
        ::lua.set_function("SquadRefreshLook", squadRefreshLook); // re-send a mate's look after zoning (see above)
        ::lua.set_function("SquadLevelSync", squadLevelSync);
        ::lua.set_function("SquadSyncLevelled", squadSyncLevelled);
        ::lua.set_function("SquadPetAttack", squadPetAttack);
        ::lua.set_function("SquadNewSpells", squadNewSpells);
        ::lua.set_function("UnlockSquadItem", unlockSquadItem);
        ::lua.set_function("GetSquadUnlocks", getSquadUnlocks);
        ::lua.set_function("SquadOwnerMerit", squadOwnerMerit); // Gambits v2 U13
        // (F12) the weapon skill gear set (squad_wsset.lua) and what the map server holds for it
        ::lua.set_function("SquadSetWsSet", squadSetWsSet);
        ::lua.set_function("SquadWsSetInfo", squadWsSetInfo);
        // (F13) this map server charges a squad Summoner's avatar perpetuation, gives its avatar no monster TP moves and
        // has the WS gear set: squad_summoner.lua / squad_wsset.lua check these markers (an older xi_map has none)
        ::lua.set_function("SquadSmnEngine", []() -> int32 { return 1; });
        ::lua.set_function("SquadWsSetEngine", []() -> int32 { return 1; });
    }
};

REGISTER_CPP_MODULE(SquadModule);
