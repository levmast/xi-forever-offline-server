-----------------------------------
-- Forever Beta Shirt (item 25725, XI: Forever Offline, 2026-11-21)
-- The Chariot Band's experience bonus: Dedication +75%, up to 4000 bonus experience, 12 hours.
-- 5 charges (item_usable, counted by the server), 15 hours between uses. It cannot be recharged: no NPC takes it
-- (the Conquest Overseer recharge in custom/late/exp_band.lua is for the Chariot Band only).
-- There is no scripts/items/forever_beta_shirt.lua: the server finds the item's functions in xi.items.<name>.
--
-- Everyone gets one, once:
--   * a new character: in their bags at creation (xi.player.charCreate)
--   * a character that already exists: sent to their delivery box at their next login (xi.player.onGameIn)
--   Bot players never get one ([Bot]Started is set before their charCreate; BotIsBot from bots.cpp). A character that
--   already has the shirt anywhere is only marked as done. Marker: char var [FBShirt]Given.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('forever_beta_shirt')

local ITEM      = 25725
local GIVEN     = '[FBShirt]Given'
local POWER     = 75
local DURATION  = 43200
local MAX_BONUS = 4000

-- the item has no script file, so its table is made here and the loader fills in the two functions
xi.module.ensureTable('xi.items.forever_beta_shirt')

m:addOverride('xi.items.forever_beta_shirt.onItemCheck', function(target, item, caster)
    if target:hasStatusEffect(xi.effect.DEDICATION) then
        return xi.msg.basic.ITEM_UNABLE_TO_USE_2
    end

    return 0
end)

m:addOverride('xi.items.forever_beta_shirt.onItemUse', function(target)
    xi.itemUtils.addItemExpEffect(target, xi.effect.DEDICATION, POWER, DURATION, MAX_BONUS)
end)

-----------------------------------
-- everyone gets one
-----------------------------------
local function isBot(player)
    if player:getCharVar('[Bot]Started') ~= 0 then
        return true
    end

    return BotIsBot ~= nil and BotIsBot(player:getID()) and true or false
end

m:addOverride('xi.player.charCreate', function(player)
    super(player)
    if isBot(player) or player:getCharVar(GIVEN) ~= 0 then
        return
    end

    if not player:hasItem(ITEM) then
        player:addItem(ITEM)
    end

    player:setCharVar(GIVEN, 1)
end)

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)
    if zoning or firstLogin or player:getCharVar(GIVEN) ~= 0 or isBot(player) then
        return result
    end

    if player:hasItem(ITEM) then
        player:setCharVar(GIVEN, 1)
        return result
    end

    -- marked first, so a send can never repeat at every login; only a clear failure (2 = no such player,
    -- 3 = item not in the database, 4 = database error) is tried again next login
    player:setCharVar(GIVEN, 1)
    local code = tonumber(SendItemToDeliveryBox(player:getName(), ITEM, 1, 'Forever Offline'))
    if code ~= nil and code >= 2 then
        player:setCharVar(GIVEN, 0)
        print(string.format('[forever_beta_shirt] delivery box send for %s failed (code %d)', player:getName(), code))
    else
        player:printToPlayer('A gift from the XI: Forever Offline team is waiting in your delivery box: the Forever Beta Shirt!', xi.msg.channel.SYSTEM_3)
    end

    return result
end)

return m
