-----------------------------------
-- Forever Patch (item 23867, XI: Forever Offline, 2026-11-25)
-- An eyepatch in the Forever Beta Shirt's colours: DEF:1 and Fishing skill +1 while worn (item_mods), and the shirt's
-- experience bonus when used: Dedication +75%, up to 4000 bonus experience, 12 hours. 5 charges (counted by the
-- server), 15 hours between uses, never recharged. Using it changes nothing about the fishing skill.
-- There is no scripts/items/forever_patch.lua: the server finds the item's functions in xi.items.<name>.
--
-- Everyone gets one, once (like the shirt):
--   * a new character: in their bags at creation (xi.player.charCreate)
--   * a character that already exists: sent to their delivery box at their next login (xi.player.onGameIn)
--   Bot players never get one. A character that already has one anywhere is only marked. Marker: [FPatch]Given.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('forever_patch')

local ITEM      = 23867
local GIVEN     = '[FPatch]Given'
local POWER     = 75
local DURATION  = 43200
local MAX_BONUS = 4000

xi.module.ensureTable('xi.items.forever_patch')

m:addOverride('xi.items.forever_patch.onItemCheck', function(target, item, caster)
    if target:hasStatusEffect(xi.effect.DEDICATION) then
        return xi.msg.basic.ITEM_UNABLE_TO_USE_2
    end

    return 0
end)

m:addOverride('xi.items.forever_patch.onItemUse', function(target)
    xi.itemUtils.addItemExpEffect(target, xi.effect.DEDICATION, POWER, DURATION, MAX_BONUS)
end)

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

    -- marked first, so a send never repeats; only a clear failure (2-4) is tried again at the next login
    player:setCharVar(GIVEN, 1)
    local code = tonumber(SendItemToDeliveryBox(player:getName(), ITEM, 1, 'Forever Offline'))
    if code ~= nil and code >= 2 then
        player:setCharVar(GIVEN, 0)
        print(string.format('[forever_patch] delivery box send for %s failed (code %d)', player:getName(), code))
    else
        player:printToPlayer('Another gift from the XI: Forever Offline team is in your delivery box: the Forever Patch!', xi.msg.channel.SYSTEM_3)
    end

    return result
end)

return m
