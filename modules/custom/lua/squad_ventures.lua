-----------------------------------
-- Ventures (2026-11-25): squad mates sent off from the XIFO app to level at a real exp camp. Used by squad.lua.
--
-- The launcher (launcher_ventures.py) keeps three files in <kit>/ventures/:
--   away.txt   char|slot|end|camp            mates out now: they can't be called, and one that is out gets sent home
--   in.txt     id|char|gil|camp|slot:exp,...   a venture that is over: each mate gets its exp, the character the gil
--   out.txt    id|ok                           written here once that is done (the launcher then delivers the items)
-- Exp goes straight to the mate's main job (AddSquadExp, capped at 75), the same as exp from a fight.
-----------------------------------
local V = {}

local DIR = (function()
    local ok, paths = pcall(require, 'modules/custom/lua/kit_paths')
    if ok and type(paths) == 'table' and type(paths.kit) == 'string' and paths.kit ~= '' then
        return paths.kit .. 'ventures/'
    end
    return 'C:/FFXISOLO/ventures/'
end)()

V.LOOK_SEC = 20
local MAX_LEVEL = 75
local cache = { at = 0, away = {} }
local done = nil

local function split(line)
    local out = {}
    for part in (line .. '|'):gmatch('(.-)|') do
        out[#out + 1] = part
    end
    return out
end

local function readAway()
    local now = os.time()
    if now - cache.at < 10 then
        return cache.away
    end
    cache.at, cache.away = now, {}
    local f = io.open(DIR .. 'away.txt', 'r')
    if f == nil then
        return cache.away
    end
    for line in f:lines() do
        local p = split(line)
        local char, slot, finish = p[1], tonumber(p[2]), tonumber(p[3])
        if char and slot and finish and finish > now then
            cache.away[char:lower() .. '#' .. slot] = { finish = finish, camp = p[4] or 'a camp' }
        end
    end
    f:close()
    return cache.away
end

local function readDone()
    if done ~= nil then
        return done
    end
    done = {}
    local f = io.open(DIR .. 'out.txt', 'r')
    if f ~= nil then
        for line in f:lines() do
            local id = line:match('^([^|]+)|ok')
            if id then
                done[id] = true
            end
        end
        f:close()
    end
    return done
end

local function left(sec)
    sec = math.max(0, sec)
    local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
    if h > 0 then
        return string.format('%dh %02dm', h, m)
    end
    return string.format('%d min', math.max(1, m))
end

local function commas(n)
    local s = tostring(math.floor(n))
    while true do
        local k
        s, k = s:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
        if k == 0 then
            return s
        end
    end
end

-- Is this mate away on a venture? Returns the line to say, or nil.
V.away = function(player, mate)
    local a = readAway()[player:getName():lower() .. '#' .. tostring(mate.slot)]
    if a == nil then
        return nil
    end
    return string.format('%s is away on a venture at %s (back in %s). You can call them home early from the XIFO app.',
        mate.name, a.camp, left(a.finish - os.time()))
end

-- Every few seconds while you play: send home mates who just left on a venture, and take in ventures that are over.
V.look = function(player, squad, dismiss, say)
    local away = readAway()
    local me = player:getName():lower()
    for _, mate in ipairs(squad or {}) do
        local a = away[me .. '#' .. tostring(mate.slot)]
        if a ~= nil then
            for _, member in pairs(player:getPartyWithTrusts()) do
                if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') == mate.id then
                    say(player, string.format('%s heads off on a venture to %s. See you in %s!', mate.name, a.camp,
                        left(a.finish - os.time())))
                    pcall(dismiss, member)
                end
            end
        end
    end

    local f = io.open(DIR .. 'in.txt', 'r')
    if f == nil then
        return
    end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    local seen = readDone()
    for _, line in ipairs(lines) do
        local p = split(line)
        local id, char, gil, camp, mates = p[1], p[2], tonumber(p[3]) or 0, p[4] or 'a camp', p[5] or ''
        if id and id ~= '' and char and char:lower() == me and not seen[id] then
            seen[id] = true
            local bySlot = {}
            for _, mate in ipairs(squad or {}) do
                bySlot[mate.slot] = mate
            end
            local names, news = {}, {}
            for part in mates:gmatch('[^,]+') do
                local slot, exp = part:match('^(%d+):(%d+)$')
                local mate = bySlot[tonumber(slot)]
                if mate ~= nil then
                    names[#names + 1] = mate.name
                    local gain = tonumber(exp) or 0
                    if gain > 0 and type(AddSquadExp) == 'function' then
                        local ok, outcome = pcall(AddSquadExp, mate.id, mate.mjob, gain, MAX_LEVEL)
                        if ok and type(outcome) == 'table' and (outcome.gained or 0) > 0 then
                            news[#news + 1] = string.format('%s reaches level %d!', mate.name, outcome.level)
                        end
                    end
                    news[#news + 1] = string.format('%s gains %s exp.', mate.name, commas(gain))
                end
            end
            if #names > 0 then
                say(player, string.format('%s %s back from %s!', table.concat(names, ' and '), #names == 1 and 'is' or 'are', camp))
                for _, text in ipairs(news) do
                    say(player, text)
                end
                if gil > 0 then
                    player:addGil(gil)
                    say(player, string.format('They hand you %s gil. Anything else they found is in your delivery box.', commas(gil)))
                else
                    say(player, 'Anything they found is in your delivery box.')
                end
            end
            local out = io.open(DIR .. 'out.txt', 'a')
            if out ~= nil then
                out:write(id .. '|ok\n')
                out:close()
            end
        end
    end
end

-- From xi.player.onGameIn: one look chain per character (a new zone-in replaces the old chain).
V.onGameIn = function(player, getSquad, dismiss, say)
    local token = (player:getLocalVar('VENTURE_TICK') or 0) + 1
    player:setLocalVar('VENTURE_TICK', token)
    local function step(entity)
        if entity == nil or entity:getLocalVar('VENTURE_TICK') ~= token then
            return
        end
        pcall(V.look, entity, getSquad(entity:getID()), dismiss, say)
        entity:timer(V.LOOK_SEC * 1000, step)
    end
    player:timer(5000, step)
end

return V
