-----------------------------------
-- GM commands on logged-out characters (XI: Forever Offline, 2026-11-23)
--
-- The stock GM commands that change a character (!addquest, !completemission, !addkeyitem, !givegil, !setplayerlevel,
-- !setrank, !additem ...) look the target up with GetPlayerByName, which only finds characters that are logged in.
-- Here, while one of those commands runs, a name that is not logged in but is a character in this world gives a
-- stand-in that writes down what the command does to it. The next time that character logs in, the same calls are
-- made on it for real (a few seconds after it arrives), and it is told how many were waiting.
--   * Only the commands in OFFLINE_OK do this; commands that only read (!checkquest, !getskill ...) still say
--     "not found" for a logged-out character: there is nothing to read without it.
--   * What the command asks about the character while it runs (has it this key item, how much gil) is a guess, so
--     its own message can be off (e.g. "now has 0 gil"); the line "(saved for ... )" after it says what was kept.
--   * Queue: modules/custom/lua/gm_offline.txt, one call per line: <charid>|<command>|<method>|<args>.
-- Lua only: a server restart (or the launcher's reload) is enough.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('gm_offline_edits')

xi = xi or {}
xi.gmOffline = xi.gmOffline or {}
local M = xi.gmOffline

local QUEUE = 'modules/custom/lua/gm_offline.txt'

-- the commands that may target a logged-out character (all of them only change it)
local OFFLINE_OK =
{
    'addquest', 'completequest', 'delquest', 'setquestvar',
    'addmission', 'completemission', 'delmission', 'setmissionstatus',
    'addkeyitem', 'delkeyitem', 'addallmaps', 'addallmounts',
    'addspell', 'delspell', 'addallspells', 'addallweaponskills', 'addallwarps', 'addallattachments',
    'addtitle', 'givegil', 'setgil', 'takegil', 'additem', 'giveitem', 'delitem',
    'setplayerlevel', 'setskill', 'capallskills', 'capskill', 'setcraftrank', 'setmerits', 'setjobpoints', 'givexp',
    'setrank', 'setfamelevel', 'setplayernation', 'setallegiance', 'setplayervar', 'addcurrency', 'racechange',
}

-- what a getter answers while the command runs, by its name (anything else: 0)
local function guess(ctx, method)
    if method == 'getName' then
        return ctx.name
    elseif method == 'getID' then
        return ctx.charid
    elseif method == 'getZoneID' then
        return ctx.gm:getZoneID()                   -- for zones[...].text lookups; the message itself goes nowhere
    elseif method == 'getFreeSlotsCount' then
        return 80
    elseif method == 'getMainLvl' then
        return 1
    elseif method == 'getObjType' then
        return xi.objType.PC
    elseif method == 'getItemCount' then
        return #ctx.calls                           -- 0 before !additem's addItem, 1 after: "gave" rather than "could not"
    elseif method == 'isPC' then
        return true
    elseif string.sub(method, 1, 3) == 'has' then
        return string.sub(ctx.cmd, 1, 3) == 'del'  -- !delitem/!delkeyitem go ahead, !addkeyitem gives it
    end

    return 0
end

local NOT_KEPT = { printToPlayer = true, messageSpecial = true, messageBasic = true, messageText = true,
    messageName = true, PrintToPlayer = true, despawnPet = true, timer = true }

local function isGetter(method)
    return string.match(method, '^get') or string.match(method, '^has') or string.match(method, '^is') or
        string.match(method, '^check') or string.match(method, '^can')
end

-- a stand-in for the character: getters guess, everything else is written down
local function standIn(ctx)
    local proxy = {}
    setmetatable(proxy, {
        __index = function(_, method)
            if type(method) ~= 'string' then
                return nil
            end

            return function(_, ...)
                if NOT_KEPT[method] then
                    return nil
                end

                if isGetter(method) then
                    return guess(ctx, method)
                end

                table.insert(ctx.calls, { method = method, n = select('#', ...), args = { ... } })
                return true
            end
        end,
    })
    return proxy
end

-----------------------------------
-- the queue file
-----------------------------------
local function enc(value)
    local t = type(value)
    if t == 'number' then
        return 'n' .. tostring(value)
    elseif t == 'boolean' then
        return value and 'b1' or 'b0'
    elseif t == 'string' then
        return 's' .. string.gsub(value, '[%%\t\r\n|]', function(c)
            return string.format('%%%02X', string.byte(c))
        end)
    end

    return 'x'                                       -- nil (and anything that cannot be kept)
end

local function dec(text)
    local kind, body = string.sub(text, 1, 1), string.sub(text, 2)
    if kind == 'n' then
        return tonumber(body)
    elseif kind == 'b' then
        return body == '1'
    elseif kind == 's' then
        return (string.gsub(body, '%%(%x%x)', function(h)
            return string.char(tonumber(h, 16))
        end))
    end

    return nil
end

local function readQueue()
    local lines = {}
    local handle = io.open(QUEUE, 'r')
    if handle then
        for line in handle:lines() do
            if line ~= '' then
                table.insert(lines, line)
            end
        end

        handle:close()
    end

    return lines
end

local function writeQueue(lines)
    local handle = io.open(QUEUE, 'w')
    if not handle then
        return false
    end

    for _, line in ipairs(lines) do
        handle:write(line, '\n')
    end

    handle:close()
    return true
end

local pending = {}                                   -- charid -> true: something waits for it (bots log in often)

local function save(ctx)
    local handle = io.open(QUEUE, 'a')
    if not handle then
        return false
    end

    for _, call in ipairs(ctx.calls) do
        local parts = {}
        for i = 1, call.n do
            parts[i] = enc(call.args[i])
        end

        handle:write(string.format('%d|%s|%s|%s\n', ctx.charid, ctx.cmd, call.method, table.concat(parts, '\t')))
    end

    pending[ctx.charid] = true

    handle:close()
    return true
end

M.parseLine = function(line)
    local charid, cmd, method, rest = string.match(line, '^(%d+)|([^|]*)|([^|]*)|(.*)$')
    if not charid then
        return nil
    end

    local args, n = {}, 0
    if rest ~= '' then
        for piece in string.gmatch(rest .. '\t', '([^\t]*)\t') do
            n = n + 1
            args[n] = dec(piece)
        end
    end

    return { charid = tonumber(charid), cmd = cmd, method = method, args = args, n = n }
end

M.encode = enc                                       -- (for the tests)

for _, line in ipairs(readQueue()) do                -- what was waiting when the server started
    local call = M.parseLine(line)
    if call then
        pending[call.charid] = true
    end
end

-----------------------------------
-- while a command runs
-----------------------------------
local current = nil                                  -- { gm, cmd, name, charid, calls }

local realGetPlayerByName = M.realGetPlayerByName or GetPlayerByName
M.realGetPlayerByName = realGetPlayerByName

GetPlayerByName = function(name, ...)
    local found = realGetPlayerByName(name, ...)
    if found ~= nil or current == nil or type(name) ~= 'string' or name == '' then
        return found
    end

    local charid = GetPlayerIDByName(name)
    if charid == nil or charid == 0 then
        return nil
    end

    current.name = string.upper(string.sub(name, 1, 1)) .. string.lower(string.sub(name, 2))
    current.charid = charid
    return standIn(current)
end

for _, name in ipairs(OFFLINE_OK) do
    m:addOverride('xi.commands.' .. name .. '.onTrigger', function(player, ...)
        local ctx = { gm = player, cmd = name, calls = {} }
        local outer = current
        current = ctx
        local ok, err = pcall(super, player, ...)
        current = outer

        if ctx.charid and #ctx.calls > 0 then
            if save(ctx) then
                player:printToPlayer(string.format('(%s is logged out: saved, and it happens when %s next logs in.)',
                    ctx.name, ctx.name), xi.msg.channel.SYSTEM_3)
            else
                player:printToPlayer('(Could not write ' .. QUEUE .. ': nothing was saved.)', xi.msg.channel.SYSTEM_3)
            end
        end

        if not ok then
            error(err, 0)
        end
    end)
end

-----------------------------------
-- at login: do what was waiting
-----------------------------------
M.apply = function(player)
    local id = player:getID()
    local lines = readQueue()
    local keep, mine = {}, {}
    for _, line in ipairs(lines) do
        local call = M.parseLine(line)
        if call and call.charid == id then
            table.insert(mine, call)
        else
            table.insert(keep, line)
        end
    end

    pending[id] = nil
    if #mine == 0 then
        return 0
    end

    if not writeQueue(keep) then
        pending[id] = true
        return 0                                     -- try again next login rather than twice
    end

    local done, failed = 0, 0
    for _, call in ipairs(mine) do
        local ok = pcall(function()
            player[call.method](player, unpack(call.args, 1, call.n))
        end)
        if ok then
            done = done + 1
        else
            failed = failed + 1
            print(string.format('[gm_offline] %s: %s from !%s failed', player:getName(), call.method, call.cmd))
        end
    end

    player:printToPlayer(string.format('A GM changed this character while you were away: %d change%s made%s.', done,
        done == 1 and '' or 's', failed > 0 and string.format(' (%d could not be)', failed) or ''), xi.msg.channel.SYSTEM_3)
    return done
end

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)

    if not zoning and pending[player:getID()] and player:getObjType() == xi.objType.PC then
        player:timer(6000, function(playerArg)
            pcall(M.apply, playerArg)
        end)
    end

    return result
end)

return m
