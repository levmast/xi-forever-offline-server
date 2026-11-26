-----------------------------------
-- XI: Forever Offline (2026-11-25, the user: "a launcher switch"): timed NMs keep their timers between play sessions
--
-- The game rolls a fresh timer for every timed NM each time the server starts, so a world that is only on for short
-- sessions could go days without seeing Argus or Leaping Lizzy's timed cousins. main.NM_TIMER_MODE (RULES):
--   0 = the game's own: fresh timers at every start (what it always did)
--   1 = paused (default): a timer stops while your server is off and goes on where it was at the next start
--   2 = real time: a timer keeps running while your server is off (one that came due while you were away is up
--       shortly after the start)
--
-- Which NMs: notorious monsters in every area, except
--   * lottery NMs (they share a spawn slot with their placeholders: the RULES lottery settings cover those)
--   * the Land Kings' areas (Dragon's Aery, Valley of Sorrows, Behemoth's Dominion: era_hnm_system / land_kings keep them)
--   * an NM is only followed once it has had a real timer (5 minutes or more), so monsters that only appear from a
--     ???, a battlefield or a quest are never touched
--
-- Saved in server variables "[NMT]<mob id>": > 0 = when it is due (os.time), -1 = defeated and waiting for something
-- else (its partner, as Argus and Leech King take turns), -2 = up. "[NMT]beat" = when they were last saved (once a
-- minute), so paused mode knows how long the server was off. Only changes are written.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('nm_timers')

local PREFIX       = '[NMT]'
local BEAT         = '[NMT]beat'
local SAVE_EVERY   = 60  -- seconds between saves
local MIN_TIMER    = 300 -- an NM is followed once it has had a timer at least this long
local SOON         = 10  -- seconds: "due now" (or up when the server stopped) comes back this soon after the start
local MAX_ZONE     = 300

local candidates = nil -- { [mob id] = true }: NMs that may be followed
local written    = {}  -- [mob id] = the value last saved
local followed   = {}  -- [mob id] = true: has a saved state (read once at the start, then kept here)
local nextSave   = 0

local function mode()
    local main = xi.settings and xi.settings.main
    local value = main and tonumber(main.NM_TIMER_MODE)
    if value == nil then
        return 1
    end

    return value
end

local function skipZones()
    local out = {}
    for _, key in ipairs({ 'DRAGONS_AERY', 'VALLEY_OF_SORROWS', 'BEHEMOTHS_DOMINION' }) do
        local id = xi.zone and xi.zone[key]
        if id then
            out[id] = true
        end
    end

    return out
end

-- every NM that could be followed, found once after the areas are loaded
local function collect()
    candidates = {}
    local skip = skipZones()
    for zoneId = 0, MAX_ZONE do
        if not skip[zoneId] then
            local okZone, zone = pcall(GetZone, zoneId)
            if okZone and zone ~= nil then
                local okMobs, mobs = pcall(function()
                    return zone:getMobs()
                end)

                for _, mob in ipairs(okMobs and mobs or {}) do
                    local okNm, isNm = pcall(function()
                        return mob:isNM()
                    end)

                    if okNm and isNm then
                        local okSlot, slot = pcall(function()
                            return mob:getSpawnSlotMobs()
                        end)

                        if not okSlot or slot == nil or #slot <= 1 then
                            candidates[mob:getID()] = true
                        end
                    end
                end
            end
        end
    end
end

local function saved(id)
    return GetServerVariable(PREFIX .. id)
end

-- the NMs' timers back as they were at the last save
local function restore()
    local now = os.time()
    local beat = GetServerVariable(BEAT)
    local offFor = (beat > 0 and now > beat) and (now - beat) or 0
    local back, up, waiting = 0, 0, 0
    for id in pairs(candidates) do
        local value = saved(id)
        if value ~= 0 then
            followed[id] = true
        end

        local mob = value ~= 0 and GetMobByID(id) or nil
        if mob ~= nil then
            written[id] = value
            if value > 0 then
                -- paused: the time the server was off doesn't count; real time: it does
                local left = (mode() == 1) and (value - beat) or (value - now)
                if beat <= 0 then
                    left = value - now
                end

                if not mob:isSpawned() then
                    mob:setRespawnTime(math.max(left, SOON))
                    back = back + 1
                end

                -- the save to come writes its new due time
                written[id] = nil
            elseif value == -2 then
                if not mob:isSpawned() then
                    mob:setRespawnTime(SOON)
                    up = up + 1
                end

                written[id] = nil
            elseif value == -1 then
                if not mob:isSpawned() then
                    mob:setRespawnTime(0) -- (0 = no respawn until a script allows it again: its partner's turn)
                    waiting = waiting + 1
                end
            end
        end
    end

    print(string.format('[nm_timers] %s: %d timers back, %d NMs that were up, %d waiting their turn (the server was off %d minutes)',
        mode() == 1 and 'paused timers' or 'real-time timers', back, up, waiting, math.floor(offFor / 60)))
end

local function save()
    local now = os.time()
    for id in pairs(candidates) do
        local mob = GetMobByID(id)
        if mob ~= nil then
            local value
            local isFollowed = followed[id] == true
            if mob:isSpawned() then
                value = isFollowed and -2 or nil
            else
                local left = mob:getRespawnTime()
                if left > 0 and (isFollowed or left >= MIN_TIMER) then
                    value = now + left
                elseif isFollowed then
                    value = -1
                end
            end

            if value ~= nil then
                local before = written[id]
                local changed = before == nil or (value > 0) ~= (before > 0) or (value <= 0 and value ~= before) or
                    (value > 0 and math.abs(value - before) > 45)
                if changed then
                    SetServerVariable(PREFIX .. id, value)
                    written[id] = value
                    followed[id] = true
                end
            end
        end
    end

    SetServerVariable(BEAT, now)
end

m:addOverride('xi.server.onServerStart', function(...)
    local result = super(...)
    if mode() == 0 then
        return result
    end

    local ok, err = pcall(function()
        collect()
        restore()
    end)

    if not ok then
        print('[nm_timers] could not restore the timers: ' .. tostring(err))
        candidates = nil
    end

    nextSave = os.time() + SAVE_EVERY
    return result
end)

m:addOverride('xi.server.onTimeServerTick', function(...)
    local result = super(...)
    if candidates ~= nil and mode() ~= 0 and os.time() >= nextSave then
        nextSave = os.time() + SAVE_EVERY
        local ok, err = pcall(save)
        if not ok then
            print('[nm_timers] could not save the timers: ' .. tostring(err))
        end
    end

    return result
end)

return m
