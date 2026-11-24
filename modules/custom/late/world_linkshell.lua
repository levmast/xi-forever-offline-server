-----------------------------------
-- The world's own linkshell (XI: Forever Offline, 2026-11-23, the user: "when players spawn in on the online server
-- can we have a server linkshell called Forever, it can be a white linkshell")
--
-- In an open world (the launcher's CO-OP "who can come in: everyone", which is what The Hub runs as; coop_config.lua
-- open = true) every player who logs in gets one linkpearl of the linkshell "Forever" in the bag, once per character:
-- a chat channel for everyone who plays there. A world that is not open (every normal single-player world, and worlds
-- open to friends only) gives nothing. The shell is made the first time it is needed, white.
-- Linkshell items belong to a world: a visitor's pearl stays here when it goes home (launcher_passport.py) and is
-- there again on the next visit. Bot players get none. The pearl is not put on: it goes into the bag (equipping it
-- from code reloads the whole inventory), and the player is told how to put it on.
-- Loaded from custom/late. Lua only: a server restart is enough.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('xifo_world_linkshell')

local NAME  = 'Forever'
local COLOR = 0xFFFF            -- white
local GIVEN = '[World]LSGiven'  -- character variable: 1 once the pearl was given

local function worldIsOpen()
    local chunk = loadfile('modules/custom/lua/coop_config.lua')       -- written by the launcher / world setup
    if not chunk then
        return false
    end

    local ok, value = pcall(chunk)
    return ok and type(value) == 'table' and value.open == true
end

local function isBot(player)
    return BotIsBot ~= nil and BotIsBot(player:getID())
end

local function give(player)
    if player:getCharVar(GIVEN) == 1 or isBot(player) or not worldIsOpen() then
        return
    end

    if player:getFreeSlotsCount() < 1 then
        player:printToPlayer('Make room in your bag: there is a linkpearl of the world\'s linkshell "' .. NAME .. '" waiting for you (next log in).', xi.msg.channel.SYSTEM_3)
        return
    end

    local ok, added = pcall(function()
        return player:addLinkpearl(NAME, false)
    end)
    if not (ok and added) and BotMakeLinkshell then
        pcall(BotMakeLinkshell, NAME, COLOR)                            -- the first player of this world: make the shell
        ok, added = pcall(function()
            return player:addLinkpearl(NAME, false)
        end)
    end

    if ok and added then
        player:setCharVar(GIVEN, 1)
        player:printToPlayer('Welcome! A linkpearl of "' .. NAME .. '", the linkshell of everyone in this world, is in your bag. Put it on from the Linkshell menu to chat with everyone here.', xi.msg.channel.SYSTEM_3)
    end
end

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    super(player, firstLogin, zoning)
    if not zoning then
        pcall(give, player)
    end
end)

return m
