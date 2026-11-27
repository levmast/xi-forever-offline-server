//
// XI: Forever Offline (2026-11-26, Quaiton: "we need a !deliverybox command to unload the whole queue (until inventory
// is full)"; the user said yes). Ventures and phone fishing fill the delivery box with many stacks, and the game hands
// them out one at a time.
//
//   Lua:
//     DeliveryTakeAll(charId) -> taken, left, why
//         Moves the incoming delivery box's items (every waiting one, also those queued past the 8 visible slots) into
//         the inventory, oldest first, until the inventory is full. Gil goes straight to the gil.
//         taken = how many cells came out, left = how many are still waiting,
//         why = "" | "open" (the delivery box window is open: close it first) | "full" (inventory full) | "offline"
//         A Rare item the character already holds stays in the box (the game's own rule), like taking it by hand.
//
//   The command is !deliverybox (modules/custom/lua/delivery_take.lua).
//

#include "map/utils/moduleutils.h"

#include "common/database.h"
#include "common/lua.h"

#include "map/entities/char_entity.h"
#include "map/item_container.h"
#include "map/items.h"
#include "map/items/item.h"
#include "map/items/transactions/item_claim.h"
#include "map/packets/s2c/0x01d_item_same.h"
#include "map/utils/charutils.h"
#include "map/utils/dboxutils.h"
#include "map/utils/itemutils.h"
#include "map/utils/zoneutils.h"

#include <algorithm>
#include <stdexcept>
#include <tuple>
#include <vector>

namespace
{
    struct Waiting
    {
        uint8  slot;
        uint16 itemId;
        uint16 subId;
        uint32 quantity;
        std::vector<uint8> extra;
        std::string sender;
    };
} // namespace

class DeliveryTakeModule : public CPPModule
{
    void OnInit() override
    {
        TracyZoneScoped;

        ::lua.set_function("DeliveryTakeAll", [](uint32 charId) -> std::tuple<uint32, uint32, std::string>
                           {
                               CCharEntity* PChar = zoneutils::GetChar(charId);
                               if (PChar == nullptr)
                               {
                                   return { 0, 0, "offline" };
                               }

                               if (dboxutils::IsAnyDeliveryBoxOpen(PChar))
                               {
                                   return { 0, 0, "open" };
                               }

                               std::vector<Waiting> waiting;
                               {
                                   const auto rset = db::preparedStmt("SELECT slot, itemid, itemsubid, quantity, extra, sender FROM delivery_box "
                                                                      "WHERE charid = ? AND box = 1 ORDER BY slot",
                                                                      PChar->id);
                                   if (rset)
                                   {
                                       while (rset->next())
                                       {
                                           Waiting w{};
                                           w.slot     = rset->get<uint8>("slot");
                                           w.itemId   = rset->get<uint16>("itemid");
                                           w.subId    = rset->get<uint16>("itemsubid");
                                           w.quantity = rset->get<uint32>("quantity");
                                           w.sender   = rset->get<std::string>("sender");
                                           uint8 blob[CItem::extra_size]{};
                                           db::extractFromBlob(rset, "extra", blob);
                                           w.extra.assign(blob, blob + CItem::extra_size);
                                           waiting.push_back(std::move(w));
                                       }
                                   }
                               }

                               uint32      taken = 0;
                               std::string why;
                               for (const auto& w : waiting)
                               {
                                   auto PItem = xi::items::spawn(w.itemId);
                                   if (!PItem)
                                   {
                                       continue; // not an item of this server: left where it is
                                   }

                                   PItem->setSubID(w.subId);
                                   PItem->setQuantity(w.quantity);
                                   std::copy_n(w.extra.begin(), std::min<size_t>(w.extra.size(), sizeof(PItem->m_extra)), PItem->m_extra);

                                   if (!PItem->isType(ITEM_CURRENCY) && PChar->getStorage(LOC_INVENTORY)->GetFreeSlotsCount() == 0)
                                   {
                                       why = "full";
                                       break;
                                   }

                                   if (PItem->hasFlag(xi::ItemFlag::Rare) && charutils::HasItem(PChar, PItem->getID()))
                                   {
                                       continue; // (as by hand: the game keeps it in the box)
                                   }

                                   auto transaction = ItemClaimTransaction::start(PChar);
                                   if (!transaction)
                                   {
                                       break;
                                   }

                                   bool       given   = false;
                                   const auto success = db::transaction([&]()
                                   {
                                       const auto rset = db::preparedStmt("DELETE FROM delivery_box WHERE charid = ? AND box = 1 AND slot = ? AND itemid = ? LIMIT 1",
                                                                          PChar->id, w.slot, w.itemId);
                                       if (rset && rset->rowsAffected() && transaction->give(LOC_INVENTORY, std::move(PItem), Silence::Yes))
                                       {
                                           given = true;
                                           return;
                                       }

                                       throw std::runtime_error(fmt::format("DeliveryTakeAll: could not move slot {} (item {}) for {}", w.slot, w.itemId, PChar->getName()));
                                   });

                                   if (!success || !given || !transaction->commit())
                                   {
                                       break;
                                   }

                                   ++taken;
                               }

                               if (taken > 0)
                               {
                                   PChar->pushPacket<GP_SERV_COMMAND_ITEM_SAME>(PChar);
                               }

                               uint32 left = 0;
                               if (const auto rset = db::preparedStmt("SELECT COUNT(*) AS n FROM delivery_box WHERE charid = ? AND box = 1", PChar->id); rset && rset->next())
                               {
                                   left = rset->get<uint32>("n");
                               }

                               return { taken, left, why };
                           });
    }
};

REGISTER_CPP_MODULE(DeliveryTakeModule);
