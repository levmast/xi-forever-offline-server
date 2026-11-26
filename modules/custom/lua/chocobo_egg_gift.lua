-----------------------------------
-- XI: Forever Offline (v0.3.12, 2026-11-25, the user): a Chocobo Egg for everyone
--
-- Every player character gets one Chocobo Egg (faintly warm, item 2312: the one Dabih Jajalioh in Ru'Lude Gardens sells,
-- ready for chocobo raising) in their delivery box at their next login, once. Hardcore and Randomized characters too
-- (items the server sends reach them; only player-to-player sending is closed to them).
-- Not given: to bot players, and in an open world such as The Hub (a visitor's character carries its marker from home,
-- and a gift there would leave with the visitor).
-- Marker: char var [Gift]Egg0312 (1 = sent). A clear failure (2 = no such player, 3 = no such item, 4 = database
-- error) is tried again at the next login.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('chocobo_egg_gift')

local ITEM  = 2312 -- Chocobo Egg (faintly warm)
local GIVEN = '[Gift]Egg0312'

local function isBot(player)
    if player:getCharVar('[Bot]Started') ~= 0 then
        return true
    end

    return BotIsBot ~= nil and BotIsBot(player:getID()) and true or false
end

local function openWorld()
    return xi.hardcore ~= nil and xi.hardcore.isHub == true
end

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)
    if zoning or player:getCharVar(GIVEN) ~= 0 or isBot(player) or openWorld() then
        return result
    end

    -- marked first, so a send can never repeat at every login
    player:setCharVar(GIVEN, 1)
    local code = tonumber(SendItemToDeliveryBox(player:getName(), ITEM, 1, 'Forever Offline'))
    if code ~= nil and code >= 2 then
        player:setCharVar(GIVEN, 0)
        print(string.format('[chocobo_egg_gift] delivery box send for %s failed (code %d)', player:getName(), code))
    else
        player:printToPlayer('A gift from the XI: Forever Offline team is waiting in your delivery box: a Chocobo Egg! Keep it warm.', xi.msg.channel.SYSTEM_3)
    end

    return result
end)

return m
