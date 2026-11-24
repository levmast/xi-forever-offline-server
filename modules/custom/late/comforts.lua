-----------------------------------
-- XI: Forever Offline comforts (2026-11-22). Off by default (the era); switched on in the launcher, Rules > Comforts.
--   main.CASKET_SHOW_CODE (Dugahst): a locked treasure casket tells your party its combination when you touch it.
--     The lock game itself is unchanged: enter the number and it opens.
--   main.GUILD_SHOPS_ALWAYS_STOCKED (delukard): guild shops never run out. Each item a shop stocks is back at its usual
--     daily amount every time you open the shop or buy, and items that were sold out at the start of the day are
--     offered anyway. Prices are the game's own.
--   map.FULL_MERITS (PTgamerguy, Ricc) is in the C++ (merit.cpp): no per-group merit caps.
--   main.PLAYER_DAMAGE_TAKEN_MULTIPLIER (Poptart; experimental): the damage players and squad mates take, as a
--     multiplier (0.5 = half, 2 = double). Put on with the game's own "damage taken" stats that have no cap (the ones
--     gear does not use), so it does not eat into the -50% that gear can give.
--   main.GUILD_SHOPS_ALWAYS_OPEN (Dugahst; the user: on by default): guild shops have no closing hours and no weekly
--     holiday. Off = the era's hours (and the holiday, when main.GUILD_SHOP_HOLIDAYS is on).
--   main.ANCESTRY_MOOGLES (Yenkei; off by default): the Ancestry Moogles are there (zoneutils.cpp) and change your race,
--     face, hair and size for free, as often as you like (no 14-day wait, no paid eligibility).
--   main.TREASURE_WAIT_MULTIPLIER (Rysan, Frost; 1 = the era): scales the 15-60 minute "illusion" wait after a chest or
--     coffer is opened (main.CHEST_/COFFER_MIN/MAX_ILLUSION_TIME). 0 = every chest and coffer gives its loot.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/caskets')
require('scripts/globals/guild_shops')
require('scripts/globals/ancestry_moogle')
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

-- Damage taken -----------------------------------------------------------------
-- The four uncapped "damage taken" stats (physical, magic, breath, ranged): 10000 = 100%. What was put on is kept on
-- the entity itself (plus 20000, as these numbers cannot be negative), so it is put on once and follows a change of
-- the setting; a new entity (a zone line, a mate called again) starts clean and gets it again.
local DAMAGE_TAKEN = { 'UDMGPHYS', 'UDMGMAGIC', 'UDMGBREATH', 'UDMGRANGE' }

xi.comforts = xi.comforts or {}
xi.comforts.damageTaken = function(entity)
    local rate = tonumber(xi.settings.main.PLAYER_DAMAGE_TAKEN_MULTIPLIER) or 1
    rate = math.max(0.1, math.min(3, rate))
    local want  = math.floor((rate - 1) * 10000 + 0.5)
    local saved = entity:getLocalVar('XIFO_DMG_TAKEN')
    local have  = saved == 0 and 0 or saved - 20000
    if have == want then
        return 0
    end

    for _, name in ipairs(DAMAGE_TAKEN) do
        local id = xi.mod[name]
        if id ~= nil then
            entity:addMod(id, want - have)
        end
    end

    entity:setLocalVar('XIFO_DMG_TAKEN', want + 20000)
    return want - have
end

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)
    pcall(xi.comforts.damageTaken, player)
    return result
end)

-- Always open: the hours and the holiday live in the shop data (scripts/data/guild_shops.lua), which every check in
-- guild_shops.lua and the game's own "open" answer read. Open from 0 to 24 with no holiday is open all the time. The
-- setting is read when the servers start, so the data is changed once, the first time a guild shop is used.
local openedAllDay = false
local function alwaysOpen()
    if openedAllDay or not on('GUILD_SHOPS_ALWAYS_OPEN') or xi.data == nil or xi.data.guildShops == nil then
        return
    end

    openedAllDay = true
    for _, shop in pairs(xi.data.guildShops) do
        if type(shop) == 'table' and type(shop.hours) == 'table' then
            shop.hours   = { 0, 24 }
            shop.holiday = nil
        end
    end
end

m:addOverride('xi.guildShops.onTrigger', function(player, npc)
    alwaysOpen()
    return super(player, npc)
end)

-- Ancestry Moogles --------------------------------------------------------------
m:addOverride('xi.ancestryMoogle.onTrigger', function(player, npc)
    if on('ANCESTRY_MOOGLES') then
        local now = GetSystemTime()
        player:setCharVar('[RaceChange]Last', 0)                          -- no 14-day wait
        if player:getCharVar('[RaceChange]Eligible') <= now + 600 then
            player:setCharVar('[RaceChange]Eligible', now + 3600, now + 3600) -- the service, free (an hour to use it)
        end
    end

    return super(player, npc)
end)

-- Treasure chest and coffer wait ------------------------------------------------
do
    local main = xi.settings and xi.settings.main
    if main then
        local keys = { 'CHEST_MIN_ILLUSION_TIME', 'CHEST_MAX_ILLUSION_TIME', 'COFFER_MIN_ILLUSION_TIME', 'COFFER_MAX_ILLUSION_TIME' }
        xi.comfortsTreasureBase = xi.comfortsTreasureBase or {}            -- the values before scaling (a reload scales once)
        local scale = tonumber(main.TREASURE_WAIT_MULTIPLIER) or 1
        scale = math.max(0, scale)
        for _, key in ipairs(keys) do
            local base = xi.comfortsTreasureBase[key] or tonumber(main[key])
            if base then
                xi.comfortsTreasureBase[key] = base
                main[key] = math.floor(base * scale)
            end
        end
    end
end

return m
