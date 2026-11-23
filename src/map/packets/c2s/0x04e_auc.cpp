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

#include "0x04e_auc.h"

#include "common/settings.h"

#include "data/enums/zone_misc.h"
#include "entities/char_entity.h"
#include "packets/c2s/validation.h"
#include "utils/auctionutils.h"
#include "utils/jailutils.h"

auto GP_CLI_COMMAND_AUC::validate(MapSession* PSession, const CCharEntity* PChar) const -> PacketValidationResult
{
    auto pv = PacketValidator(PChar)
                  .blockedBy({ BlockedState::InEvent });

    // (XI: Forever Offline, 2026-11-22, Velderen) map.AH_ANYWHERE: the auction house answers in every area, so the
    // ahgo add-on's /ah can bid and sell out in the field. Off (the era): only in areas that have an Auction House.
    if (settings::get<uint8>("map.AH_ANYWHERE") == 0)
    {
        pv.hasZoneMiscFlag(xi::ZoneMisc::AuctionHouse);
    }

    pv
        .mustEqual(jailutils::InPrison(PChar), false, "Character in jail")
        .oneOf<GP_CLI_COMMAND_AUC_COMMAND>(this->Command)
        .mustEqual(this->Result, 0, "Result not 0")
        .mustEqual(this->ResultStatus, 0, "Result status");

    switch (this->Command)
    {
        case GP_CLI_COMMAND_AUC_COMMAND::AskCommit:
        {
            pv
                .range("Commission", this->Param.AskCommit.Commission, 1, 999999999)
                .range("ItemStacks", this->Param.AskCommit.ItemStacks, 0, 1);
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::Info:
        {
            // No specific parameter to validate for Info command
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::WorkCheck:
        {
            pv.mustEqual(this->AucWorkIndex, -1, "AucWorkIndex not -1");
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::LotIn:
        {
            pv
                .range("AucWorkIndex", this->AucWorkIndex, 0, 6)
                .range("LimitPrice", this->Param.LotIn.LimitPrice, 1, 999999999)
                .range("ItemStacks", this->Param.LotIn.ItemStacks, 0, 1);
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::Bid:
        {
            pv
                .range("AucWorkIndex", this->AucWorkIndex, 0, 6)
                .range("BidPrice", this->Param.Bid.BidPrice, 1, 999999999)
                .range("ItemStacks", this->Param.Bid.ItemStacks, 0, 1);
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::LotCancel:
        case GP_CLI_COMMAND_AUC_COMMAND::LotCheck:
        {
            pv.range("AucWorkIndex", this->AucWorkIndex, 0, 6);
        }
        break;
        default:
            break;
    }

    return pv;
}

void GP_CLI_COMMAND_AUC::process(MapSession* PSession, CCharEntity* PChar) const
{
    switch (this->Command)
    {
        case GP_CLI_COMMAND_AUC_COMMAND::AskCommit:
        {
            auctionutils::SellingItems(PChar, this->Param.AskCommit);
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::Info:
        {
            auctionutils::OpenListOfSales(PChar);
            [[fallthrough]];
        }
        // FALLTHROUGH!
        case GP_CLI_COMMAND_AUC_COMMAND::WorkCheck:
        {
            auctionutils::RetrieveListOfItemsSoldByPlayer(PChar);
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::LotIn:
        {
            auctionutils::ProofOfPurchase(PChar, this->Param.LotIn);
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::Bid:
        {
            auctionutils::PurchasingItems(PChar, this->Param.Bid);
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::LotCancel:
        {
            auctionutils::CancelSale(PChar, this->AucWorkIndex);
        }
        break;
        case GP_CLI_COMMAND_AUC_COMMAND::LotCheck:
        {
            auctionutils::UpdateSaleListByPlayer(PChar, this->AucWorkIndex);
        }
        break;
        default:
            break;
    }
}
