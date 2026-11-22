-----------------------------------
-- XI: Forever Offline comforts (2026-11-22). Off by default (the era); switched on in the launcher, Rules > Comforts.
--   main.CASKET_SHOW_CODE (Dugahst): a locked treasure casket tells your party its combination when you touch it.
--     The lock game itself is unchanged: enter the number and it opens.
--   main.GUILD_SHOPS_ALWAYS_STOCKED (delukard): guild shops never run out. Each item a shop stocks is back at its usual
--     daily amount every time you open the shop or buy, and items that were sold out at the start of the day are
--     offered anyway. Prices are the game's own.
--   map.FULL_MERITS (PTgamerguy, Ricc) is in the C++ (merit.cpp): no per-group merit caps.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/caskets')
require('scripts/globals/guild_shops')
-----------------------------------
local m = Module:new('comforts')

local function on(name)
    local v = xi.settings and xi.settings.main and xi.settings.main[name]
    return v == true or (type(v) == 'number' and v ~= 0)
end

-- Treasure caskets ------------------------------------------------------------
m:addOverride('xi.caskets.onTrigger', function(player, npc)
    if
        on('CASKET_SHOW_CODE') and
        npc:getLocalVar('[caskets]LOCKED') == 1 and
        player:getLeaderID() == npc:getLocalVar('[caskets]PARTYID')
    then
        local code = npc:getLocalVar('[caskets]CORRECT_NUM')
        if code >= 10 and code <= 99 then
            player:printToPlayer(string.format('The lock\'s combination is %d.', code), xi.msg.channel.SYSTEM_3)
        end
    end

    return super(player, npc)
end)

-- Guild shops -----------------------------------------------------------------
-- the shop's own state (scripts/globals/guild_shops.lua keeps it in xi.guildShops.state, by the shared shop's name)
local function refill(npc)
    if not on('GUILD_SHOPS_ALWAYS_STOCKED') or xi.data == nil or xi.data.guildShops == nil then
        return
    end

    local name  = npc:getName()
    local cfg   = xi.data.guildShops[name]
    local canon = (cfg and cfg.sharedStock) or name
    local shop  = xi.data.guildShops[canon]
    local state = xi.guildShops.state and xi.guildShops.state[canon]
    if shop == nil or state == nil or state.items == nil then
        return
    end

    for _, item in ipairs(shop.stock or {}) do
        local now = state.items[item.id]
        -- only what the guild stocks itself (not pieces it only resells when players sell them to it)
        if now ~= nil and ((item.initial or 0) > 0 or (item.restockRate or 0) > 0) then
            local full = (item.targetStock or 0) > 0 and item.targetStock or (item.maxStock or 0)
            if full > 0 and now.stock < full then
                now.stock = full
            end

            now.offered = full > 0 or now.offered
        end
    end
end

m:addOverride('xi.guildShops.onBuyList', function(player, npc)
    if not on('GUILD_SHOPS_ALWAYS_STOCKED') then
        return super(player, npc)
    end

    super(player, npc) -- (rolls the shop to today first)
    refill(npc)
    return super(player, npc)
end)

m:addOverride('xi.guildShops.onPlayerBuy', function(player, npc, itemId, quantity)
    refill(npc)
    return super(player, npc, itemId, quantity)
end)

return m
