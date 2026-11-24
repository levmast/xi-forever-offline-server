-----------------------------------
-- Casket changes for the solo server.
--   Blue caskets:  hold real everyday items (not temporary items).
--   Brown caskets: hold weapons and armor.
--   Every casket also holds gil, paid out when the casket is opened.
--   One casket in twenty is a golden "super casket" holding one level 1 cosmetic costume piece.
-- Everything else is the game's own: the drop chance (CASKET_DROP_RATE), the blue/brown mix, the lock game,
-- the 3 minute timer and the rule that only your party can open it.
-- The item lists come from casket_loot_custom.lua, which build_casket_loot.py writes from your own database.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/caskets')
local loot = require('modules/custom/lua/casket_loot_custom')
-----------------------------------
local m = Module:new('casket_tweaks')

-- Settings you can change ---------------------------------------------------
local SUPER_CHANCE = 0.05                          -- chance that a casket is a super casket (0.05 = 1 in 20 caskets)
local SUPER_MODEL  = 969                           -- the golden chest model

local BLUE_COUNTS  = { 1, 1, 2, 1, 2, 1, 3, 1, 2, 1 }   -- how many items a blue casket holds (one of these is picked at random)
local BROWN_COUNTS = { 1, 1, 2, 1, 1, 2, 1, 3, 1, 1 }   -- the same for brown caskets

-- Gil in a casket = (BASE_GIL + the monster's level x a random number in the range) x GIL_SCALE
-- A level 20 monster's blue casket holds 300-500 gil, a level 50 one 600-1100, a level 75 one 850-1600.
local BASE_GIL  = 100                              -- every casket holds at least this much, however low the level
local BLUE_GIL  = { 10, 20 }
local BROWN_GIL = { 15, 30 }                       -- brown (locked) caskets pay half as much again
local SUPER_GIL = { 30, 60 }
local GIL_SCALE = 1.0                              -- multiplies everything (2.0 = double)
-----------------------------------------------------------------------------

local ITEM_LOOT_TYPE = 2 -- the game's own "items" chest type (1 = temporary items)
local STATUS_CLOSED  = 1
local STATUS_OPEN    = 2

local function say(player, text)
    local channel = (xi.msg and xi.msg.channel and xi.msg.channel.SYSTEM_3) or 0
    for _, member in pairs(player:getAlliance()) do
        if member:getZoneID() == player:getZoneID() then
            member:printToPlayer(text, channel)
        end
    end
end

local function pickWeighted(pool)
    local total = 0
    for _, entry in ipairs(pool) do
        total = total + entry[2]
    end

    local roll = math.randomFloat(0, total)
    for _, entry in ipairs(pool) do
        roll = roll - entry[2]
        if roll <= 0 then
            return entry[1]
        end
    end

    return pool[#pool][1]
end

local function poolFor(tbl, level)
    local band = math.min(75, math.max(5, math.ceil(level / 5) * 5))
    return tbl[band]
end

-- Picks several different items; unused slots stay 0
local function rollItems(pool, counts)
    local wanted = utils.randomEntry(counts)
    local items  = {}
    local seen   = {}

    for _ = 1, wanted do
        for _ = 1, 6 do
            local itemId = pickWeighted(pool)
            if not seen[itemId] then
                seen[itemId] = true
                items[#items + 1] = itemId
                break
            end
        end
    end

    while #items < 4 do
        items[#items + 1] = 0
    end

    return items
end

local function rollGil(level, range)
    return math.max(1, math.floor((BASE_GIL + level * math.randomInt(range[1], range[2])) * GIL_SCALE))
end

-- Fills the casket with ready-made items using the game's own variables, so its normal open/take logic does the rest
local function fillChest(npc, items, gil)
    npc:setLocalVar('[caskets]LOOT_TYPE', ITEM_LOOT_TYPE)
    for slot = 1, 4 do
        npc:setLocalVar('[caskets]ITEM' .. slot, items[slot] or 0)
    end

    npc:setLocalVar('[caskets]ITEMS_SET', 1)
    npc:setLocalVar('[caskets]GIL', gil)
end

-- (2026-11-23) a Randomized character's casket holds random items of the area instead (custom/late/hardcore.lua)
local function randomized(player, items)
    if xi.hardcore and type(xi.hardcore.randomCasket) == 'function' then
        local ok, swapped = pcall(xi.hardcore.randomCasket, player, items)
        if ok and type(swapped) == 'table' then
            return swapped
        end
    end

    return items
end

local function tweakNewCaskets(player, zone, since)
    for _, npc in ipairs(zone:queryEntitiesByName('Treasure_Casket')) do
        if
            npc:getLocalVar('[caskets]SPAWNSTATUS') == STATUS_CLOSED and
            npc:getLocalVar('[caskets]SPAWNTIME') >= since and
            npc:getLocalVar('[caskets]TWEAKED') == 0
        then
            npc:setLocalVar('[caskets]TWEAKED', 1)

            local level  = npc:getLocalVar('[caskets]MOBLVL')
            local locked = npc:getLocalVar('[caskets]LOCKED') == 1

            if #loot.cosmetics > 0 and math.randomFloat(0, 1) < SUPER_CHANCE then
                npc:setModelId(SUPER_MODEL)
                npc:setLocalVar('[caskets]LOCKED', 0)
                npc:setLocalVar('[caskets]SUPER', 1)
                fillChest(npc, { utils.randomEntry(loot.cosmetics), 0, 0, 0 }, rollGil(level, SUPER_GIL))
                say(player, '...and it is a golden super casket!')
            elseif locked then
                fillChest(npc, randomized(player, rollItems(poolFor(loot.brown, level), BROWN_COUNTS)), rollGil(level, BROWN_GIL))
            else
                fillChest(npc, randomized(player, rollItems(poolFor(loot.blue, level), BLUE_COUNTS)), rollGil(level, BLUE_GIL))
            end
        end
    end
end

-- A monster has been killed: let the game decide whether a casket appears, then fill whatever appeared
m:addOverride('xi.caskets.spawnCasket', function(player, mob, x, y, z, r)
    local since = GetSystemTime()
    super(player, mob, x, y, z, r)
    tweakNewCaskets(player, mob:getZone(), since)
end)

-- The casket was touched: after the game has handled it, pay out the gil the first time it is open
m:addOverride('xi.caskets.onTrigger', function(player, npc)
    super(player, npc)

    if
        npc:getLocalVar('[caskets]SPAWNSTATUS') == STATUS_OPEN and
        npc:getLocalVar('[caskets]GIL_PAID') == 0 and
        player:getLeaderID() == npc:getLocalVar('[caskets]PARTYID')
    then
        local gil = npc:getLocalVar('[caskets]GIL')
        npc:setLocalVar('[caskets]GIL_PAID', 1)

        if gil > 0 then
            player:addGil(gil)
            local channel = (xi.msg and xi.msg.channel and xi.msg.channel.SYSTEM_3) or 0
            player:printToPlayer(string.format('You find %d gil inside.', gil), channel)
        end
    end
end)

return m
