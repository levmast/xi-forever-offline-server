-----------------------------------
-- Forever Track Pants (item 23868, internal name forever_jeans, XI: Forever Offline, 2026-11-25)
-- Track pants (with their sneakers) in the Forever Beta Shirt's colours: DEF:1 and Fishing skill +2 while worn (item_mods), and Warp when
-- used, like the Warp Ring (scripts/items/warp_ring.lua): to your home point. The wait after equipping, the single
-- charge that never runs out and the 10 minutes between uses are in modules/custom/sql/forever_jeans.sql.
-- There is no scripts/items/forever_jeans.lua: the server finds the item's functions in xi.items.<name>.
--
-- Everyone gets one, once (like the shirt and the patch):
--   * a new character: in their bags at creation (xi.player.charCreate)
--   * a character that already exists: sent to their delivery box at their next login (xi.player.onGameIn)
--   Bot players never get one. A character that already has one anywhere is only marked. Marker: [FJeans]Given.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('forever_jeans')

local ITEM  = 23868
local GIVEN = '[FJeans]Given'

xi.module.ensureTable('xi.items.forever_jeans')

m:addOverride('xi.items.forever_jeans.onItemCheck', function(target, item, caster)
    return 0
end)

m:addOverride('xi.items.forever_jeans.onItemUse', function(target, user)
    target:addStatusEffect(xi.effect.TELEPORT, { power = xi.teleport.id.WARP, duration = 3, origin = user or target, icon = 0 })
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
        print(string.format('[forever_jeans] delivery box send for %s failed (code %d)', player:getName(), code))
    else
        player:printToPlayer('Another gift from the XI: Forever Offline team is in your delivery box: the Forever Track Pants!', xi.msg.channel.SYSTEM_3)
    end

    return result
end)

return m
