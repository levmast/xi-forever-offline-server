-----------------------------------
-- Co-op (XI: Forever Offline, 2026-11-16): visitors from a friend's world
--
-- The launcher's CO-OP page brings a friend's character into this world on a guest account (launcher_passport.py puts
-- the character variable COOP_GUEST = 1 on it) and takes it home again later. This script is the server's small part:
--   * a visitor is told where it is and how to go home when it logs in;
--   * a visitor cannot use the commands that belong to the owner of the world (!bots on/off/online..., !crowd ...);
--   * a visitor's squad mates come with it (the launcher copies them over) and !squad works for them, but with a
--     visitor in the party each player's squad is its own (xi.coop.ownMate), and a visitor's squad stays out of the
--     owner's AI squad chat (xi.coop.isGuestMate; squad.lua asks);
--   * lines the launcher writes to modules/custom/lua/coop_in.txt ("<time>|<number>|SAY|<text>") are shown to
--     everyone within a few seconds ("... is visiting this world", "This world closes in a minute"); a line
--     "<time>|<number>|BOTS|<n>" changes how many bot players are online, like !bots online <n>;
--   * a line "<time>|<number>|KICK|<character id>" logs that visitor out (the host pressed KICK, or a moderator did
--     in an open world). Only visitors: the owner's own characters are never logged out this way.
-- Nothing here runs for a world that never has visitors, apart from one small file check every few seconds.
-- Loaded from custom/late (the last line of modules/init.txt). Lua only: a server restart is enough.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('coop_visits') -- (module names need 5+ letters: 'coop' failed to load)

xi = xi or {}
xi.coop = xi.coop or {}

local IN_FILE = 'modules/custom/lua/coop_in.txt'
local CHECK_EVERY = 4       -- seconds between looks at the launcher's file
local FRESH = 90            -- a line older than this many seconds was for an earlier session

local config = { hosting = false, open = false, world = 'this world' }
do
    local chunk = loadfile('modules/custom/lua/coop_config.lua')      -- written by the launcher at every PLAY
    if chunk then
        local ok, value = pcall(chunk)
        if ok and type(value) == 'table' then
            config.hosting = value.hosting == true
            config.open = value.open == true       -- an open world: anyone with its link may visit, not only friends
            if type(value.world) == 'string' and value.world ~= '' then
                config.world = value.world
            end
        end
    end
end

local function tell(player, text)
    player:printToPlayer(text, xi.msg.channel.SYSTEM_3)
end

local function isBot(player)
    return BotIsBot ~= nil and BotIsBot(player:getID())
end

xi.coop.isGuest = function(player)
    return player ~= nil and player:getObjType() == xi.objType.PC and player:getCharVar('COOP_GUEST') == 1
end

-- A squad mate of a visitor? (asked on every tick of a mate, so the answer is kept on the mate: 1 = yes, 2 = no)
xi.coop.isGuestMate = function(mob)
    local known = mob:getLocalVar('COOP_MATE')
    if known == 0 then
        local master = mob:getMaster()
        if master == nil then
            master = GetPlayerByID(mob:getLocalVar('MASTER_ID'))
        end

        if master == nil then
            return false
        end

        known = xi.coop.isGuest(master) and 1 or 2
        mob:setLocalVar('COOP_MATE', known)
    end

    return known == 1
end

-- Is a visitor among the players of this player's party?
local function visitorInParty(player)
    for _, member in pairs(player:getParty()) do
        if xi.coop.isGuest(member) then
            return true
        end
    end

    return false
end

-- May this player count that squad mate as its own (pay it exp, move it with !squad camp, name it in squad chat)?
-- Its own mates: always. Someone else's: as before co-op (yes: a second character of the owner's shares the squad),
-- unless a visitor is in the party: then every squad belongs to its own player only, so each mate is paid once
-- whoever else is in the party. Any error counts as "yes", the way it was before.
xi.coop.ownMate = function(player, mate)
    local ok, result = pcall(function()
        local master = mate:getMaster()
        if master == nil or player == nil or master:getID() == player:getID() then
            return true
        end

        return not (xi.coop.isGuest(player) or xi.coop.isGuest(master) or visitorInParty(player))
    end)

    return not ok or result
end

-- what a visitor may still do with the owner's commands (everything else in them changes the world)
local allowed =
{
    bots  = { [''] = true, list = true, news = true, where = true, invites = true, parties = true, invite = true, come = true },
    crowd = { [''] = true, status = true },
}

-- commands a visitor uses like anyone else, apart from these actions (each with the line the visitor is told)
local closed =
{
    squad =
    {
        chat = 'Your squad mates fight here, but their AI chat stays home: this world\'s squad chat belongs to its owner.',
        lore = 'Your squad mates fight here, but their AI chat stays home: this world\'s squad chat belongs to its owner.',
    },
}

local refusal =
{
    bots  = 'Only the owner of this world can change its bot players.',
    crowd = 'Only the owner of this world can change its crowds.',
}

-- Called first thing by !squad, !bots and !crowd. True = the command stops here (the visitor has been told why).
xi.coop.blockGuest = function(player, command, action)
    if not xi.coop.isGuest(player) then
        return false
    end

    action = string.lower(tostring(action or ''))
    if closed[command] then
        if closed[command][action] then
            tell(player, closed[command][action])
            return true
        end

        return false
    end

    local list = allowed[command]
    if list and list[action] then
        return false
    end

    local where = config.open and 'this world' or 'a friend\'s world'
    tell(player, refusal[command] or ('Visitors cannot use that command in ' .. where .. '.'))
    return true
end

-----------------------------------
-- Lines from the launcher
-----------------------------------
local seen = {}
local seenCount = 0
local nextLook = 0
local watching = {}          -- [character id] = the number of that character's current watch loop
local kicks = {}             -- [character id] = the time until which that visitor is to be logged out

-- Logs out the visitors the launcher asked for. A character that is between two areas is not found, so its request
-- waits here and is tried again at every look, until the line that asked is too old. Once done it is forgotten: a
-- visitor who comes straight back is not logged out again (closing its account is the launcher's BAN).
local function sendOut()
    local now = os.time()
    for id, untilTime in pairs(kicks) do
        if now > untilTime then
            kicks[id] = nil
        else
            local target = GetPlayerByID(id)
            if target ~= nil then
                kicks[id] = nil
                if xi.coop.isGuest(target) then
                    local name = target:getName()
                    tell(target, 'The host of this world has logged you out.')
                    target:leaveGame()
                    print(string.format('[coop] %s (%d) was logged out by the host', tostring(name), id))
                else
                    print(string.format('[coop] character %d is not a visitor: left alone', id))
                end
            end
        end
    end
end

local function readLines(player)
    local handle = io.open(IN_FILE, 'r')
    if not handle then
        return
    end

    local text = handle:read('*a') or ''
    handle:close()

    local now = os.time()
    for line in string.gmatch(text, '[^\r\n]+') do
        local stamp, _, kind, body = string.match(line, '^(%d+)|(%d+)|(%u+)|(.*)$')
        if stamp and not seen[line] then
            seen[line] = true
            seenCount = seenCount + 1
            if kind == 'SAY' and body ~= '' and now - tonumber(stamp) <= FRESH then
                local ok = pcall(function()
                    player:printToArea(body, xi.msg.channel.SYSTEM_3, xi.msg.area.SYSTEM, '', false)
                end)
                if not ok then
                    tell(player, body)
                end

                print('[coop] ' .. body)
            elseif kind == 'BOTS' and now - tonumber(stamp) <= FRESH then
                -- the owner moved "Bots online right now" on the launcher's CO-OP page
                if xi.bots and xi.bots.setOnline and xi.bots.setOnline(body) then
                    print('[coop] bots online at a time: ' .. tostring(body))
                end
            elseif kind == 'KICK' and string.match(body, '^%d+$') and #body <= 10 and now - tonumber(stamp) <= FRESH then
                kicks[tonumber(body)] = tonumber(stamp) + FRESH
            end
        end
    end

    if seenCount > 400 then
        seen, seenCount = {}, 0
        for line in string.gmatch(text, '[^\r\n]+') do
            seen[line] = true
            seenCount = seenCount + 1
        end
    end
end

local function watch(player, number)
    player:timer(CHECK_EVERY * 1000, function(playerArg)
        if watching[playerArg:getID()] ~= number then
            return -- a newer loop took over (the character changed area)
        end

        if os.time() >= nextLook then
            nextLook = os.time() + CHECK_EVERY - 1
            local ok, err = pcall(readLines, playerArg)
            if not ok then
                print('[coop] could not read ' .. IN_FILE .. ': ' .. tostring(err))
            end

            if next(kicks) ~= nil then
                ok, err = pcall(sendOut)
                if not ok then
                    print('[coop] could not log a visitor out: ' .. tostring(err))
                end
            end
        end

        watch(playerArg, number)
    end)
end

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)

    if player:getObjType() == xi.objType.PC and not isBot(player) then
        local id = player:getID()
        watching[id] = (watching[id] or 0) + 1
        watch(player, watching[id])

        if not zoning and xi.coop.isGuest(player) then
            player:timer(5000, function(playerArg)
                tell(playerArg, string.format('You are visiting %s. Everything you earn here goes home with you.', config.world))
                tell(playerArg, 'To go home: log out, then press COME HOME in your launcher.')
                -- its squad came along (GetSquad is squad.cpp's; without the squad module there is nothing to say)
                local ok, squad = pcall(function() return GetSquad(playerArg:getID()) end)
                if ok and type(squad) == 'table' and #squad > 0 then
                    tell(playerArg, 'Your squad mates came with you: !squad call brings them out. Joining a party sends them off, so call them again after.')
                end
            end)
        end
    end

    return result
end)

local state = config.hosting and ((config.open and 'open world ' or 'hosting ') .. config.world) or 'not hosting'
print(string.format('[coop] ready (%s)', state))

return m
