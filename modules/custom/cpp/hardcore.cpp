//
// XI: Forever Offline (2026-11-23): hardcore modes, the packet side.
//
//   A hardcore character carries the char var "[HC]Mode": 1 = Iron, 2 = Steel, 3 = Silver
//   (src/map/utils/hardcoreutils.h; the rules and the rates are in modules/custom/late/hardcore.lua).
//
//   Here, for every mode:
//     * no auction house (packet 0x04E), no buying from bazaars (0x106)
//     * no trades with other characters (0x032 request, 0x033 accepting), either way round
//     * no delivery box sending (0x04D), neither from a hardcore character nor to one. Items the server sends (the
//       milestone rewards) still arrive: they do not come through this packet.
//   And the party rule, with a message: Iron parties with anyone; Steel and Silver only with hardcore characters
//   (0x06E invite, 0x074 accepting). The core refuses any other way in (party.cpp AddMember).
//
//   Lua:
//     HardcoreResetJob(charId) -> bool   Steel: the main job back to level 1 with 0 exp (an online character)
//     HardcoreSetJobs(charId, mask)     Randomized: the jobs the character may play (char_jobs.unlocked)
//     HardcoreCanSwap(itemId) -> bool   Randomized: may this drop be swapped (sold on the AH, not Rare/Ex, no crystal)
//     HardcoreLootPool(zoneId) -> {ids} Randomized: what the area's monsters (not NMs) can drop, swappable items only
//     HardcoreNMPool() -> {ids}         Randomized: what every NM can drop, swappable items only
//     HardcoreLootTable(zoneId)         Randomized (round 4): the area's drops with their weight and level
//     HardcoreNMTable()                 Randomized (round 4): every NM's drops with weight, level and the NM's level
//
//   Randomized characters (mode 4) are not hardcore: none of the blocks below apply to them, and they party with anyone.
//
//   GMs are held to the same rules (step the character down to test without them).
//

#include "map/utils/moduleutils.h"

#include "common/database.h"
#include "common/lua.h"

#include "map/enums/chat_message_type.h"
#include "map/entities/char_entity.h"
#include "map/lua/lua_base_entity.h"
#include "map/map_session.h"
#include "map/packets/basic.h"
#include "map/packets/c2s/0x032_trade_req.h"
#include "map/packets/c2s/0x033_trade_res.h"
#include "map/packets/c2s/0x04d_pbx.h"
#include "map/packets/c2s/0x04e_auc.h"
#include "map/packets/c2s/0x06e_group_solicit_req.h"
#include "map/packets/c2s/0x074_group_solicit_res.h"
#include "map/packets/s2c/0x017_chat_std.h"
#include "map/packets/s2c/0x061_clistatus.h"
#include "map/packets/s2c/0x01b_job_info.h"
#include "map/entities/mob_entity.h"
#include "map/items/item_equipment.h"
#include "map/items/item_weapon.h"
#include "map/utils/itemutils.h"
#include "map/zone.h"
#include "map/party.h"
#include "map/utils/charutils.h"
#include "map/utils/hardcoreutils.h"
#include "map/utils/zoneutils.h"

#include <array>
#include <cstring>
#include <map>
#include <set>
#include <string>

namespace
{
    const char* modeName(int32 mode)
    {
        switch (mode)
        {
            case 1:
                return "Iron";
            case 2:
                return "Steel";
            case 3:
                return "Silver";
            case 4:
                return "Randomized";
            default:
                return "normal";
        }
    }

    void tell(CCharEntity* PChar, const std::string& text)
    {
        if (PChar != nullptr)
        {
            PChar->pushPacket<GP_SERV_COMMAND_CHAT_STD>(PChar, MESSAGE_SYSTEM_3, text);
        }
    }

    // a character's mode by name (for the delivery box: the recipient is usually not online)
    auto modeByName(const std::string& name) -> int32
    {
        if (name.empty())
        {
            return 0;
        }

        if (auto rset = db::preparedStmt("SELECT charid FROM chars WHERE charname = ? LIMIT 1", name); rset && rset->next())
        {
            return hardcoreutils::modeOf(rset->get<uint32>("charid"));
        }

        return 0;
    }

    auto modeById(uint32 charId) -> int32
    {
        if (CCharEntity* PChar = zoneutils::GetChar(charId))
        {
            return hardcoreutils::mode(PChar);
        }

        return hardcoreutils::modeOf(charId);
    }

    auto exempt(const CCharEntity* PChar) -> bool
    {
        return PChar == nullptr;
    }

    // true when PChar may join the party PLeader is in (or start one with PLeader); else names who is in the way
    auto partyAllows(const CCharEntity* PChar, CCharEntity* PLeader, std::string& blocker) -> bool
    {
        const int32 mine = hardcoreutils::mode(PChar);
        if (PLeader == nullptr)
        {
            return true;
        }

        if (PLeader->PParty == nullptr)
        {
            if (!hardcoreutils::canGroup(mine, hardcoreutils::mode(PLeader)))
            {
                blocker = PLeader->getName();
                return false;
            }

            return true;
        }

        for (const auto* PMember : PLeader->PParty->members)
        {
            if (const auto* POther = dynamic_cast<const CCharEntity*>(PMember); POther != nullptr && POther != PChar &&
                                                                               !hardcoreutils::canGroup(mine, hardcoreutils::mode(POther)))
            {
                blocker = POther->getName();
                return false;
            }
        }

        return true;
    }

    // Randomized: a drop that may be swapped for another (one the auction house sells, not Rare/Ex, no crystals)
    auto canSwap(uint16 itemId) -> bool
    {
        if (itemId == 0 || (itemId >= 4096 && itemId <= 4111))
        {
            return false;
        }

        const CItem* item = xi::items::lookup(itemId);
        if (item == nullptr || item->hasFlag(xi::ItemFlag::Rare) || item->hasFlag(xi::ItemFlag::Exclusive))
        {
            return false;
        }

        const uint8 cat = item->getAHCat();
        return cat > 0 && cat < 99;
    }

    void collect(const DropList_t* list, std::set<uint16>& out)
    {
        if (list == nullptr)
        {
            return;
        }

        for (const auto& item : list->Items)
        {
            if (canSwap(item.ItemID))
            {
                out.insert(item.ItemID);
            }
        }

        for (const auto& group : list->Groups)
        {
            for (const auto& item : group.Items)
            {
                if (canSwap(item.ItemID))
                {
                    out.insert(item.ItemID);
                }
            }
        }
    }

    // (2026-11-24, Randomized round 4) the level a swappable item needs (0 = no level: not equipment)
    auto itemLevel(uint16 itemId) -> uint8
    {
        if (const auto* PEquip = xi::items::lookup<CItemEquipment>(itemId))
        {
            return PEquip->getReqLvl();
        }

        return 0;
    }

    // Randomized round 4: like collect(), but each item keeps how often it really drops (per 1000; a grouped item gets
    // its share of the group's rate) so a random drop is as rare or as common as the item it stands for. Steal and
    // Despoil items are left out (they are not drops).
    void collectWeighted(const DropList_t* list, std::map<uint16, double>& out)
    {
        if (list == nullptr)
        {
            return;
        }

        for (const auto& item : list->Items)
        {
            if ((item.DropType == DROP_NORMAL || item.DropType == DROP_GROUPED) && canSwap(item.ItemID))
            {
                out[item.ItemID] += std::max<double>(item.DropRate, 1.0);
            }
        }

        for (const auto& group : list->Groups)
        {
            double total = 0;
            for (const auto& item : group.Items)
            {
                total += item.DropRate;
            }

            for (const auto& item : group.Items)
            {
                if (canSwap(item.ItemID))
                {
                    const double share = total > 0 ? static_cast<double>(item.DropRate) / total : 1.0;
                    out[item.ItemID] += std::max<double>(group.GroupRate * share, 1.0);
                }
            }
        }
    }

    auto isNM(const CMobEntity* PMob) -> bool
    {
        return (PMob->m_Type & xi::MobType::Notorious) != xi::MobType::Normal;
    }

    auto toTable(const std::set<uint16>& ids) -> sol::table
    {
        auto table = ::lua.create_table();
        int  n     = 1;
        for (const uint16 id : ids)
        {
            table[n++] = id;
        }

        return table;
    }
} // namespace

class HardcoreModule : public CPPModule
{
    void OnInit() override
    {
        TracyZoneScoped;

        ::lua.set_function("HardcoreResetJob", [](uint32 charId) -> bool
                           {
                               CCharEntity* PChar = zoneutils::GetChar(charId);
                               if (PChar == nullptr || PChar->isDead())
                               {
                                   return false;
                               }

                               const auto job = PChar->GetMJob();
                               CLuaBaseEntity(PChar).setLevel(1); // stats, skills, abilities, traits, gear check, packets
                               PChar->jobs.exp[static_cast<uint8>(job)] = 0;
                               charutils::SaveCharExp(PChar, job);
                               PChar->pushPacket<GP_SERV_COMMAND_CLISTATUS>(PChar);
                               ShowInfoFmt("[hardcore] {}: {} is back to level 1 (Steel)", PChar->getName(), static_cast<int>(job));
                               return true;
                           });

        ::lua.set_function("HardcoreSetJobs", [](uint32 charId, uint32 mask) -> bool
                           {
                               CCharEntity* PChar = zoneutils::GetChar(charId);
                               if (PChar == nullptr)
                               {
                                   return false;
                               }

                               PChar->jobs.unlocked = mask;
                               charutils::SaveCharJob(PChar, PChar->GetMJob());
                               PChar->pushPacket<GP_SERV_COMMAND_JOB_INFO>(PChar);
                               return true;
                           });

        ::lua.set_function("HardcoreCanSwap", [](uint16 itemId) -> bool
                           {
                               return canSwap(itemId);
                           });

        ::lua.set_function("HardcoreLootPool", [](uint16 zoneId) -> sol::table
                           {
                               std::set<uint16> ids;
                               if (CZone* PZone = zoneutils::GetZone(static_cast<xi::ZoneId>(zoneId)))
                               {
                                   PZone->ForEachMob([&](CMobEntity* PMob)
                                                     {
                                                         if (PMob != nullptr && !isNM(PMob))
                                                         {
                                                             collect(PMob->dropList(), ids);
                                                         }
                                                     });
                               }

                               return toTable(ids);
                           });

        ::lua.set_function("HardcoreNMPool", []() -> sol::table
                           {
                               std::set<uint16> ids;
                               zoneutils::ForEachZone([&](CZone* PZone)
                                                      {
                                                          PZone->ForEachMob([&](CMobEntity* PMob)
                                                                            {
                                                                                if (PMob != nullptr && isNM(PMob))
                                                                                {
                                                                                    collect(PMob->dropList(), ids);
                                                                                }
                                                                            });
                                                      });
                               return toTable(ids);
                           });

        // Randomized round 4 (2026-11-24): the area's drop table with weights and levels, for drops that stay as rare
        // as what they replace and fit the monster's level: { {id=, w=, lvl=}, ... } (non-NM monsters only)
        ::lua.set_function("HardcoreLootTable", [](uint16 zoneId) -> sol::table
                           {
                               std::map<uint16, double> weights;
                               if (CZone* PZone = zoneutils::GetZone(static_cast<xi::ZoneId>(zoneId)))
                               {
                                   std::set<const DropList_t*> seen;
                                   PZone->ForEachMob([&](CMobEntity* PMob)
                                                     {
                                                         if (PMob != nullptr && !isNM(PMob) && seen.insert(PMob->dropList()).second)
                                                         {
                                                             collectWeighted(PMob->dropList(), weights);
                                                         }
                                                     });
                               }

                               auto table = ::lua.create_table();
                               int  n     = 1;
                               for (const auto& [id, w] : weights)
                               {
                                   table[n++] = ::lua.create_table_with("id", id, "w", w, "lvl", itemLevel(id));
                               }

                               return table;
                           });

        // Randomized round 4: every NM's drops with the NM's level, so an NM gives what NMs of about its level give:
        // { {id=, w=, lvl=, nm=}, ... } (one entry per NM and item)
        ::lua.set_function("HardcoreNMTable", []() -> sol::table
                           {
                               auto table = ::lua.create_table();
                               int  n     = 1;
                               std::set<std::pair<const DropList_t*, uint8>> seen;
                               zoneutils::ForEachZone([&](CZone* PZone)
                                                      {
                                                          PZone->ForEachMob([&](CMobEntity* PMob)
                                                                            {
                                                                                if (PMob == nullptr || !isNM(PMob))
                                                                                {
                                                                                    return;
                                                                                }

                                                                                const uint8 level = std::max<uint8>(PMob->m_minLevel, 1);
                                                                                if (!seen.insert({ PMob->dropList(), level }).second)
                                                                                {
                                                                                    return;
                                                                                }

                                                                                std::map<uint16, double> weights;
                                                                                collectWeighted(PMob->dropList(), weights);
                                                                                for (const auto& [id, w] : weights)
                                                                                {
                                                                                    table[n++] = ::lua.create_table_with("id", id, "w", w, "lvl", itemLevel(id), "nm", level);
                                                                                }
                                                                            });
                                                      });
                               return table;
                           });

        // Randomized (2026-11-23): the level 1 gear a new character of this job and race can wear, by equipment slot
        // (0 main .. 15 back, the game's slot numbers), for its random starting set. Only items sold on the auction house
        // (no event, GM or reward pieces) and no item level. "twoHanded" lists main-hand weapons that leave no room
        // for a shield (two-handed and hand-to-hand); "shields" are the sub-slot items that are shields.
        ::lua.set_function("HardcoreStarterPool", [](uint8 job, uint8 race) -> sol::table
                           {
                               auto result    = ::lua.create_table();
                               auto twoHanded = ::lua.create_table();
                               auto shields   = ::lua.create_table();
                               std::array<int, 16> count{};
                               std::array<sol::table, 16> slots;
                               for (uint8 slot = 0; slot < 16; ++slot)
                               {
                                   slots[slot] = ::lua.create_table();
                                   result[slot] = slots[slot];
                               }

                               if (job < 1 || job > 22)
                               {
                                   return result;
                               }

                               for (uint32 id = 1; id < MAX_ITEMID; ++id)
                               {
                                   const auto* PItem = xi::items::lookup<CItemEquipment>(static_cast<uint16>(id));
                                   if (PItem == nullptr || PItem->getReqLvl() > 1 || PItem->getILvl() > 0 ||
                                       !(PItem->getJobs() & (1U << (job - 1))) || !PItem->isEquippableByRace(race))
                                   {
                                       continue;
                                   }

                                   const uint8 cat = PItem->getAHCat();
                                   if (cat == 0 || cat >= 99)
                                   {
                                       continue;
                                   }

                                   const uint16 mask = PItem->getEquipSlotId();
                                   for (uint8 slot = 0; slot < 16; ++slot)
                                   {
                                       if (mask & (1U << slot))
                                       {
                                           if (slot == 1 && !PItem->IsShield())
                                           {
                                               continue; // a second weapon or a grip needs more than level 1 brings
                                           }

                                           slots[slot][++count[slot]] = static_cast<uint16>(id);
                                           if (slot == 1)
                                           {
                                               shields[static_cast<uint16>(id)] = true;
                                           }
                                       }
                                   }

                                   if (mask & 1U)
                                   {
                                       if (const auto* PWeapon = dynamic_cast<const CItemWeapon*>(PItem);
                                           PWeapon != nullptr && (PWeapon->isTwoHanded() || PWeapon->isHandToHand()))
                                       {
                                           twoHanded[static_cast<uint16>(id)] = true;
                                       }
                                   }
                               }

                               result["twoHanded"] = twoHanded;
                               result["shields"]   = shields;
                               return result;
                           });

        ShowInfo("[hardcore] hardcore modes loaded (Iron / Steel / Silver / Randomized)");
    }

    auto OnIncomingPacket(MapSession* session, CCharEntity* PChar, CBasicPacket& packet) -> bool override
    {
        if (exempt(PChar))
        {
            return false;
        }

        const uint16 type = packet.getType();
        const int32  mine = hardcoreutils::mode(PChar);

        // auction house
        if (type == 0x04E && hardcoreutils::isHardcore(mine))
        {
            const auto* auc = packet.as<GP_CLI_COMMAND_AUC>();
            if (auc->Command == GP_CLI_COMMAND_AUC_COMMAND::AskCommit || auc->Command == GP_CLI_COMMAND_AUC_COMMAND::LotIn ||
                auc->Command == GP_CLI_COMMAND_AUC_COMMAND::Bid || auc->Command == GP_CLI_COMMAND_AUC_COMMAND::WorkCheck)
            {
                tell(PChar, fmt::format("{} characters can't use the auction house. Everything you have, you found yourself.", modeName(mine)));
                return true;
            }

            return false;
        }

        // buying from a bazaar
        if (type == 0x106 && hardcoreutils::isHardcore(mine))
        {
            tell(PChar, fmt::format("{} characters can't buy from bazaars.", modeName(mine)));
            return true;
        }

        // trading with another character
        if (type == 0x032)
        {
            const auto* req     = packet.as<GP_CLI_COMMAND_TRADE_REQ>();
            const int32 theirs  = modeById(req->UniqueNo);
            if (hardcoreutils::isHardcore(mine) || hardcoreutils::isHardcore(theirs))
            {
                tell(PChar, hardcoreutils::isHardcore(mine) ? fmt::format("{} characters can't trade with other characters.", modeName(mine))
                                     : fmt::format("That character is {} hardcore and can't trade with anyone.", modeName(theirs)));
                return true;
            }

            return false;
        }

        if (type == 0x033 && hardcoreutils::isHardcore(mine))
        {
            const auto* res  = packet.as<GP_CLI_COMMAND_TRADE_RES>();
            const auto  kind = static_cast<GP_CLI_COMMAND_TRADE_RES_KIND>(res->Kind);
            if (kind == GP_CLI_COMMAND_TRADE_RES_KIND::Start || kind == GP_CLI_COMMAND_TRADE_RES_KIND::Make)
            {
                tell(PChar, fmt::format("{} characters can't trade with other characters. Cancel the trade.", modeName(mine)));
                return true;
            }

            return false;
        }

        // delivery box: sending
        if (type == 0x04D)
        {
            const auto* pbx = packet.as<GP_CLI_COMMAND_PBX>();
            const auto  cmd = static_cast<GP_CLI_COMMAND_PBX_COMMAND>(pbx->Command);
            if (cmd != GP_CLI_COMMAND_PBX_COMMAND::Set && cmd != GP_CLI_COMMAND_PBX_COMMAND::Send)
            {
                return false;
            }

            if (hardcoreutils::isHardcore(mine))
            {
                tell(PChar, fmt::format("{} characters can't send items through the delivery box.", modeName(mine)));
                return true;
            }

            std::string target(reinterpret_cast<const char*>(pbx->TargetName), strnlen(reinterpret_cast<const char*>(pbx->TargetName), sizeof(pbx->TargetName)));
            if (const int32 theirs = modeByName(target); hardcoreutils::isHardcore(theirs))
            {
                tell(PChar, fmt::format("{} is a {} hardcore character and can't receive items from other characters.", target, modeName(theirs)));
                return true;
            }

            return false;
        }

        // party invite: the inviter's party (or the inviter) and the one invited
        if (type == 0x06E)
        {
            const auto* inv    = packet.as<GP_CLI_COMMAND_GROUP_SOLICIT_REQ>();
            const int32 theirs = modeById(inv->UniqueNo);
            if (!hardcoreutils::canGroup(mine, theirs))
            {
                tell(PChar, theirs >= 2 ? fmt::format("That character is {} hardcore: they only party with Iron, Steel and Silver characters.", modeName(theirs))
                                        : fmt::format("{} characters only party with Iron, Steel and Silver characters.", modeName(mine)));
                return true;
            }

            if (PChar->PParty != nullptr && theirs > 0)
            {
                for (const auto* PMember : PChar->PParty->members)
                {
                    if (const auto* POther = dynamic_cast<const CCharEntity*>(PMember); POther != nullptr && POther != PChar &&
                                                                                       !hardcoreutils::canGroup(theirs, hardcoreutils::mode(POther)))
                    {
                        tell(PChar, fmt::format("That character is {} hardcore and can't share a party with {}.", modeName(theirs), POther->getName()));
                        return true;
                    }
                }
            }

            return false;
        }

        // accepting an invite
        if (type == 0x074)
        {
            const auto* res = packet.as<GP_CLI_COMMAND_GROUP_SOLICIT_RES>();
            if (static_cast<GP_CLI_COMMAND_GROUP_SOLICIT_RES_RES>(res->Res) != GP_CLI_COMMAND_GROUP_SOLICIT_RES_RES::Accept)
            {
                return false;
            }

            CCharEntity* PInviter = zoneutils::GetCharFromWorld(PChar->InvitePending.entity.UniqueNo, PChar->InvitePending.entity.ActIndex);
            std::string  blocker;
            if (PInviter != nullptr && !partyAllows(PChar, PInviter, blocker))
            {
                tell(PChar, mine >= 2 ? fmt::format("{} characters only party with Iron, Steel and Silver characters ({} is not one).", modeName(mine), blocker)
                                      : fmt::format("{} is a Steel or Silver hardcore character: they only party with hardcore characters.", blocker));
                tell(PInviter, fmt::format("{} could not join: Steel and Silver characters only party with hardcore characters.", PChar->getName()));
                PChar->InvitePending.clean();
                return true;
            }

            return false;
        }

        return false;
    }
};

REGISTER_CPP_MODULE(HardcoreModule);
