/*
===========================================================================

  XI: Forever Offline (2026-11-23): hardcore modes (Iron / Steel / Silver) and Randomized.

  A hardcore character carries the char var "[HC]Mode" (1 = Iron, 2 = Steel, 3 = Silver). Its rates come from the
  mode's profile, which modules/custom/late/hardcore.lua keeps in xi.hardcore.rates[mode]["map.EXP_RATE"] and so on.
  Any key the profile does not list (and every character without a mode) uses the world's own setting, so this
  header changes nothing at all until hardcore.lua is loaded and a character has a mode.

  Header only on purpose: the core does not depend on the hardcore module being in modules/init.txt.

===========================================================================
*/

#pragma once

#include "common/database.h"
#include "common/earth_time.h"
#include "common/lua.h"
#include "common/settings.h"
#include "entities/char_entity.h"
#include "utils/charutils.h"

#include <string>

namespace hardcoreutils
{
    inline const std::string ModeVar = "[HC]Mode";

    inline auto cleanMode(int32 value) -> int32
    {
        return (value >= 1 && value <= 4) ? value : 0;
    }

    // Iron, Steel and Silver are hardcore (no auction house or trades); 4 = Randomized is not
    inline auto isHardcore(int32 mode) -> bool
    {
        return mode >= 1 && mode <= 3;
    }

    // 0 = a normal character, 1 = Iron, 2 = Steel, 3 = Silver, 4 = Randomized
    inline auto mode(const CCharEntity* PChar) -> int32
    {
        if (PChar == nullptr)
        {
            return 0;
        }

        return cleanMode(PChar->getCharVar(ModeVar));
    }

    // the same for a character that may not be loaded in this zone (reads the database)
    inline auto modeOf(uint32 charId) -> int32
    {
        if (charId == 0)
        {
            return 0;
        }

        return cleanMode(charutils::FetchCharVar(charId, ModeVar).first);
    }

    // Iron parties with anyone; Steel and Silver only with other hardcore characters (Iron, Steel, Silver) and with
    // Randomized characters, who may join anyone. Bot players have no mode, so they never join a Steel or Silver party.
    inline auto canGroup(int32 a, int32 b) -> bool
    {
        if (a >= 2 || b >= 2)
        {
            return a > 0 && b > 0;
        }

        return true;
    }

    // The rate for this character: its mode's value for the key when the profile has one, else the world's setting.
    inline auto rate(const CCharEntity* PChar, const std::string& key) -> double
    {
        const double base = settings::get<double>(key);
        const int32  m    = mode(PChar);
        if (m == 0)
        {
            return base;
        }

        const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
        if (!xiTable)
        {
            return base;
        }

        const sol::optional<sol::table> hcTable = (*xiTable)["hardcore"].get<sol::optional<sol::table>>();
        if (!hcTable)
        {
            return base;
        }

        const sol::optional<sol::table> rates = (*hcTable)["rates"].get<sol::optional<sol::table>>();
        if (!rates)
        {
            return base;
        }

        const sol::optional<sol::table> row = (*rates)[m].get<sol::optional<sol::table>>();
        if (!row)
        {
            return base;
        }

        const sol::optional<double> value = (*row)[key].get<sol::optional<double>>();
        return value ? *value : base;
    }

    // The mode's own title (the client's title list has empty slots 1078 - 1115; the launcher writes these four
    // names into the game's title file, see launcher_client.py). A character with a mode always wears its title.
    inline auto modeTitle(int32 m) -> uint16
    {
        switch (m)
        {
            case 1:
                return 1078; // Iron: Forged in Solitude
            case 2:
                return 1079; // Steel: Tempered by Ruin
            case 3:
                return 1080; // Silver: Bearer of a Single Flame
            case 4:
                return 1081; // Randomized: Altana's Wild Card
            default:
                return 0;
        }
    }

    inline auto isModeTitle(uint16 title) -> bool
    {
        return title >= 1078 && title <= 1081;
    }

    // The search server shows a Randomized character its own auction house (common/hardcore_market.h), but it only
    // sees the address a request comes from. So whoever uses the auction house writes when it did ("[HC]AHSeen");
    // with two characters on one address, the newest one is taken. At most one write in 15 seconds a character.
    inline const std::string SeenVar = "[HC]AHSeen";

    inline void noteAuctionViewer(CCharEntity* PChar)
    {
        if (PChar == nullptr)
        {
            return;
        }

        const auto now = static_cast<int32>(earth_time::timestamp());
        if (now - PChar->getCharVar(SeenVar) < 15)
        {
            return;
        }

        PChar->updateCharVarCache(SeenVar, now);
        db::preparedStmt("INSERT INTO char_vars (charid, varname, value) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)",
                         PChar->id,
                         SeenVar,
                         now);
    }

    // xi.hardcore.<name> from custom/late/hardcore.lua, or an empty function when it is not loaded
    inline auto hardcoreFunction(const char* name) -> sol::protected_function
    {
        const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
        if (!xiTable)
        {
            return sol::protected_function();
        }

        const sol::optional<sol::table> hcTable = (*xiTable)["hardcore"].get<sol::optional<sol::table>>();
        if (!hcTable)
        {
            return sol::protected_function();
        }

        const sol::optional<sol::protected_function> fn = (*hcTable)[name].get<sol::optional<sol::protected_function>>();
        return fn ? *fn : sol::protected_function();
    }

    // Randomized: xi.hardcore.randomLoot(player, mob, itemId) -> the item that drops instead (custom/late/hardcore.lua)
    inline auto randomLootFunction() -> sol::protected_function
    {
        const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
        if (!xiTable)
        {
            return sol::protected_function();
        }

        const sol::optional<sol::table> hcTable = (*xiTable)["hardcore"].get<sol::optional<sol::table>>();
        if (!hcTable)
        {
            return sol::protected_function();
        }

        const sol::optional<sol::protected_function> fn = (*hcTable)["randomLoot"].get<sol::optional<sol::protected_function>>();
        return fn ? *fn : sol::protected_function();
    }
} // namespace hardcoreutils
