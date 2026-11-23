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
#pragma once

#include "common/cbasetypes.h"

#include <vector>

class CCharEntity;
class CTrustEntity;

namespace trustutils
{

// Optional overrides used by the squad system (modules/custom/cpp/squad.cpp).
// When supplied to SpawnTrust, the trust spawns with this job/subjob/level instead of the
// trust's own job and the master's level. Everything else (spell list, skills, AI) still
// comes from the trust that TrustID points at.
struct SquadSpec
{
    uint8  mJob{ 0 };     // main job (required)
    uint8  sJob{ 0 };     // sub job, 0 = none
    uint8  mLevel{ 0 };   // main level (required)
    uint8  sLevel{ 0 };   // sub level, 0 = half of main level (when a sub job is set)
    uint32 squadId{ 0 };  // stored on the entity as local var SQUAD_ID so Lua can recognise squad mates
    uint8  race{ 0 };     // player race 1-8 (Hume M/F, Elvaan M/F, Taru M/F, Mithra, Galka): stats use that race's player tables. 0 = the trust's own

    // Appearance, applied BEFORE the character spawns so the very first spawn message already shows it
    // (a renamed character's later update messages garble the armor). Armor values carry their slot: head 0x1000, body 0x2000,
    // hands 0x3000, legs 0x4000, feet 0x5000, main 0x6000, sub 0x7000, ranged 0x8000. 0 = nothing shown in that slot.
    bool   hasLook{ false };
    uint8  face{ 0 };
    uint8  bodySize{ 0 }; // 0 = not chosen (the client's default), 1-3 = small / medium / large (sent as 0-2, like a player's)
    uint16 lookHead{ 0 };
    uint16 lookBody{ 0 };
    uint16 lookHands{ 0 };
    uint16 lookLegs{ 0 };
    uint16 lookFeet{ 0 };
    uint16 lookMain{ 0 };
    uint16 lookSub{ 0 };
    uint16 lookRanged{ 0 };

    // (squad option "spells from scrolls", 2026-11-17) spells a mate's jobs learn at level 18 or above are known only
    // when the squad learned them: a scroll given to the squad, or blue magic learned from a monster
    bool                spellScrolls{ false };
    std::vector<uint16> learnedSpells;

    // (2026-11-17) a squad Blue Mage's set blue magic, like a player's Set Spells menu: blueSet = the spells the player
    // chose (empty = automatic), bluePrefer = the order the automatic set tries first (the job rules' spells). The
    // slots and set points are a player's at that level; the mate only casts what is set and gets its traits.
    std::vector<uint16> blueSet;
    std::vector<uint16> bluePrefer;
};

// We cache all of this so we don't have to hit the database every time a trust is spawned
void LoadTrustList();
auto SpawnTrust(CCharEntity* PMaster, uint32 TrustID, const SquadSpec* spec = nullptr) -> CTrustEntity*;

// (XI: Forever Offline) a squad mate's skills from the player skill table plus its gear's skill modifiers; squad.cpp
// calls it again after the outfit is applied. Does nothing for an ordinary trust.
void BuildSquadSkills(CTrustEntity* PTrust);

}; // namespace trustutils
