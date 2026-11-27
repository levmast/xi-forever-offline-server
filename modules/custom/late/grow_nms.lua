-----------------------------------
-- XI: Forever Offline (2026-11-26, Art-Machine: "V.Vilma NM not spawning as normal"; the user: "yes")
-- Monsters that grow into an NM when they are left alone keep their count between play sessions
--
-- Four NM lines have no spawn timer. An ordinary monster has to be left alone for hours and then turns into the next:
--   Yuhtunga Jungle    Overgrown Rose (one of them) -> Rose Garden -> Voluptuous Vilma      10 h, then 10 h
--   Uleguerand Range   Morozko (one of them) -> Snow Maiden -> Father Frost                 32-44 h, then 12-13 h
--   Ranguemont Pass    Taisai (one of three) -> Taisaijin                                   1-3 days
--   Lufaise Meadows    Leshy (any of eight) -> Colorful Leshy -> Defoliate Leshy            12-24 h, then 12-24 h
-- The game keeps that count in the monster's memory only (its 'timeToGrow'), so every server start began it again, and
-- a world that is on for a few hours at a time never got there. Bot players hunting the first monster began it again
-- too (bots_hunt.lua leaves the monsters in xi.growNm.leave alone now).
--
-- This follows main.NM_TIMER_MODE, the launcher's "Timed NMs between sessions", like nm_timers.lua:
--   0 = the game's own: a fresh count at every start
--   1 = paused (default): the count stops while your server is off and goes on where it was
--   2 = real time: the count keeps running while your server is off
-- A middle or last NM that was up when the server stopped is up again at the next start. Everything else is the
-- game's own script: a fight with the monster still begins its count again, and the NM appears when somebody is in
-- the area (monsters only think while an area has players).
--
-- Saved in server variables: "[GROW]<line>" = how far the line is (0 nothing to keep, 1 the first monster is
-- counting, 2 the middle NM is up and counting, 3 the last NM is up), "[GROW]<line>:t" = when the count runs out
-- (os.time), "[GROW]<line>:p" = which placeholder it is (Taisai 1-3, a Leshy's id), "[GROW]beat" = when they were
-- last saved (once a minute), so paused mode knows what was left when the server stopped.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('grow_nms')

xi = xi or {}
xi.growNm = xi.growNm or {}
xi.growNm.leave = xi.growNm.leave or {} -- [mob id] = true: bot players do not hunt these

local PREFIX     = '[GROW]'
local BEAT       = '[GROW]beat'
local SAVE_EVERY = 60          -- seconds between saves
local SOON       = 30          -- a count that ran out while the server was off: this long after the start
local LONGEST    = 4 * 86400   -- no count is longer than three days: a saved value beyond this is not believed

local lines    = nil -- the four lines, found once after the areas are loaded
local written  = {}  -- [variable] = the value last saved
local nextSave = 0
local putBack  = nil -- the counts restored at this start, checked once more at the first save

local function mode()
    local main  = xi.settings and xi.settings.main
    local value = main and tonumber(main.NM_TIMER_MODE)
    if value == nil then
        return 1
    end

    return value
end

local function mob(id)
    local ok, entity = pcall(GetMobByID, id)
    return ok and entity or nil
end

local function up(id)
    local entity = mob(id)
    if entity == nil then
        return false
    end

    local ok, spawned = pcall(function()
        return entity:isSpawned()
    end)

    return ok and spawned == true
end

local function var(id, name)
    local entity = mob(id)
    if entity == nil then
        return 0
    end

    local ok, value = pcall(function()
        return entity:getLocalVar(name)
    end)

    return ok and tonumber(value) or 0
end

local function setVar(id, name, value)
    local entity = mob(id)
    if entity ~= nil then
        pcall(function()
            entity:setLocalVar(name, value)
        end)
    end
end

local function left(deadline)
    return math.max(0, deadline - GetSystemTime())
end

-- the four lines, from each area's own id list (an area this server does not have is left out)
local function build()
    local out = {}
    local function ids(zoneKey)
        local zoneId = xi.zone and xi.zone[zoneKey]
        local ok, list = pcall(function()
            return zones[zoneId].mob
        end)

        return ok and type(list) == 'table' and list or nil
    end

    -- a chain: one placeholder (ph), a middle NM (mid), a last NM (last); each counts on itself
    local y = ids('YUHTUNGA_JUNGLE')
    if y and y.ROSE_GARDEN and y.VOLUPTUOUS_VILMA then
        out[#out + 1] = { key = 'rose', kind = 'chain', ph = y.ROSE_GARDEN - 1, mid = y.ROSE_GARDEN, last = y.VOLUPTUOUS_VILMA }
    end

    local u = ids('ULEGUERAND_RANGE')
    if u and u.SNOW_MAIDEN and u.FATHER_FROST then
        out[#out + 1] = { key = 'maiden', kind = 'chain', ph = u.SNOW_MAIDEN - 1, mid = u.SNOW_MAIDEN, last = u.FATHER_FROST }
    end

    -- Taisai: three placeholders (nm - 1 .. nm - 3); the one with 'phIndex' counts
    local r = ids('RANGUEMONT_PASS')
    if r and r.TAISAIJIN then
        out[#out + 1] = { key = 'taisai', kind = 'taisai', nm = r.TAISAIJIN }
    end

    -- Leshy: eight placeholders (first .. first + 7); the count for Colorful sits on Colorful (nm), the count for
    -- Defoliate on Defoliate (nm + 1); the NM that is up remembers its placeholder in 'phIndex'
    local l = ids('LUFAISE_MEADOWS')
    if l and l.COLORFUL_LESHY and l.LESHY_OFFSET then
        out[#out + 1] = { key = 'leshy', kind = 'leshy', first = l.LESHY_OFFSET, nm = l.COLORFUL_LESHY }
    end

    for _, line in ipairs(out) do
        if line.kind == 'chain' then
            for _, id in ipairs({ line.ph, line.mid, line.last }) do
                xi.growNm.leave[id] = true
            end
        elseif line.kind == 'taisai' then
            for id = line.nm - 3, line.nm do
                xi.growNm.leave[id] = true
            end
        else
            for id = line.first, line.first + 7 do
                xi.growNm.leave[id] = true
            end

            xi.growNm.leave[line.nm]     = true
            xi.growNm.leave[line.nm + 1] = true
        end
    end

    return out
end

-- how far a line is right now: stage, seconds left on its count, which placeholder
local function read(line)
    if line.kind == 'chain' then
        if up(line.last) then
            return 3, 0, 0
        elseif up(line.mid) then
            return 2, left(var(line.mid, 'timeToGrow')), 0
        elseif up(line.ph) and var(line.ph, 'timeToGrow') > 0 then
            return 1, left(var(line.ph, 'timeToGrow')), 0
        end

        return 0, 0, 0 -- the placeholder is down: it comes back with a fresh count, as in the game
    elseif line.kind == 'taisai' then
        if up(line.nm) then
            local p = var(line.nm, 'phIndex')
            return 3, 0, (p >= 1 and p <= 3) and p or 0
        end

        for i = 1, 3 do
            if var(line.nm - i, 'phIndex') > 0 and up(line.nm - i) then
                return 1, left(var(line.nm - i, 'timeToGrow')), i
            end
        end

        return 0, 0, 0
    end

    if up(line.nm + 1) then
        return 3, 0, var(line.nm + 1, 'phIndex')
    elseif up(line.nm) then
        return 2, left(var(line.nm + 1, 'timeToGrow')), var(line.nm, 'phIndex')
    elseif var(line.nm, 'timeToGrow') > 0 then
        return 1, left(var(line.nm, 'timeToGrow')), 0
    end

    return 0, 0, 0
end

-- the monster whose 'timeToGrow' is the count of this stage (nil: the last NM is up, nothing counts)
local function holder(line, stage, p)
    if line.kind == 'chain' then
        return (stage == 1 and line.ph) or (stage == 2 and line.mid) or nil
    elseif line.kind == 'taisai' then
        return stage == 1 and (line.nm - p) or nil
    end

    return (stage == 1 and line.nm) or (stage == 2 and (line.nm + 1)) or nil
end

local function put(name, value)
    if written[name] ~= value then
        SetServerVariable(name, value)
        written[name] = value
    end
end

local function save()
    local now = os.time()
    for _, line in ipairs(lines) do
        local ok, stage, secs, p = pcall(read, line)
        if ok then
            local key = PREFIX .. line.key
            put(key, stage)
            if stage ~= 0 then
                -- (a count that was not touched gives the same moment every time, give or take a second)
                local due = now + secs
                local old = written[key .. ':t']
                if old == nil or math.abs(old - due) > 5 then
                    put(key .. ':t', due)
                end

                put(key .. ':p', p)
            end
        end
    end

    SetServerVariable(BEAT, now)
end

-- a placeholder makes room for the NM that grew from it
local function park(id)
    DisallowRespawn(id, true)
    DespawnMob(id)
end

-- an NM is up again, where its placeholder stands
local function spawnAt(id, fromId)
    DisallowRespawn(id, false)
    local entity, from = mob(id), mob(fromId)
    if entity ~= nil and from ~= nil then
        pcall(function()
            local p = from:getSpawnPos()
            entity:setSpawn(p.x, p.y, p.z, p.rot)
        end)
    end

    SpawnMob(id)
end

local function apply(line, stage, secs, p)
    local due = GetSystemTime() + secs
    if line.kind == 'chain' then
        if stage == 1 then
            setVar(line.ph, 'timeToGrow', due)
        elseif stage == 2 then
            park(line.ph)
            spawnAt(line.mid, line.ph)
            setVar(line.mid, 'timeToGrow', due) -- (after its own onMobSpawn, which begins a fresh count)
        else
            park(line.ph)
            spawnAt(line.last, line.ph)
        end
    elseif line.kind == 'taisai' then
        if p < 1 or p > 3 then
            p = 1
        end

        -- (the area picked one of the three at random when it loaded: the saved one is the placeholder instead)
        for i = 1, 3 do
            setVar(line.nm - i, 'phIndex', (stage == 1 and i == p) and p or 0)
        end

        if stage == 1 then
            setVar(line.nm - p, 'timeToGrow', due)
        else
            park(line.nm - p)
            spawnAt(line.nm, line.nm - p)
            setVar(line.nm, 'phIndex', p)
        end
    else
        local ph = (p >= line.first and p <= line.first + 7) and p or line.first
        if stage == 1 then
            setVar(line.nm, 'timeToGrow', due)
        elseif stage == 2 then
            park(ph)
            spawnAt(line.nm, ph)
            setVar(line.nm, 'phIndex', ph)
            setVar(line.nm + 1, 'timeToGrow', due) -- (after Colorful's own onMobSpawn, which begins Defoliate's count)
        else
            park(ph)
            spawnAt(line.nm + 1, ph)
            setVar(line.nm + 1, 'phIndex', ph)
        end
    end
end

local function restore()
    local now  = os.time()
    local beat = GetServerVariable(BEAT)
    putBack = {}
    if beat == nil or beat <= 0 then
        return
    end

    for _, line in ipairs(lines) do
        local key   = PREFIX .. line.key
        local stage = GetServerVariable(key)
        if stage ~= nil and stage >= 1 and stage <= 3 and not (line.kind == 'taisai' and stage == 2) then
            local due  = GetServerVariable(key .. ':t') or 0
            local p    = GetServerVariable(key .. ':p') or 0
            -- paused: what was left at the last save; real time: what is left now
            local secs = (mode() == 2) and (due - now) or (due - beat)
            if stage == 3 then
                secs = 0
            elseif secs < SOON then
                secs = SOON
            elseif secs > LONGEST then
                secs = LONGEST
            end

            local ok, err = pcall(apply, line, stage, secs, p)
            if ok then
                putBack[#putBack + 1] = { line = line, stage = stage, p = p, due = GetSystemTime() + secs }
            else
                print(string.format('[grow_nms] could not restore %s: %s', line.key, tostring(err)))
            end
        end
    end
end

-- once, at the first save after the start: a placeholder that only appeared after the restore began a fresh count in
-- its own onMobSpawn; the restored one goes back (nobody has fought it yet: the world has just started)
local function checkRestored()
    local list = putBack or {}
    putBack = nil
    for _, entry in ipairs(list) do
        local ok, stage, _, p = pcall(read, entry.line)
        if ok and stage == entry.stage then
            local id = holder(entry.line, stage, (entry.line.kind == 'taisai') and p or entry.p)
            if id ~= nil and var(id, 'timeToGrow') > entry.due + 5 then
                setVar(id, 'timeToGrow', entry.due)
            end
        end
    end
end

m:addOverride('xi.server.onServerStart', function(...)
    local result = super(...)
    local ok, err = pcall(function()
        lines = build()
        if mode() ~= 0 then
            restore()
        end
    end)

    if not ok then
        print('[grow_nms] could not restore the counts: ' .. tostring(err))
    end

    nextSave = os.time() + SAVE_EVERY
    return result
end)

m:addOverride('xi.server.onTimeServerTick', function(...)
    local result = super(...)
    if lines ~= nil and mode() ~= 0 and os.time() >= nextSave then
        nextSave = os.time() + SAVE_EVERY
        local ok, err = pcall(function()
            if putBack ~= nil then
                checkRestored()
            end

            save()
        end)

        if not ok then
            print('[grow_nms] could not save the counts: ' .. tostring(err))
        end
    end

    return result
end)

return m
