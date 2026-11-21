-----------------------------------
-- Seasonal events switch (XI: Forever Offline)
-----------------------------------
-- The launcher's CONFIG > Rates "Seasonal events" setting, written to events_config.lua every launch:
--   date = each event runs on its own dates (default)
--   on   = Harvest Festival, Starlight Celebration, Egg Hunt, Horro's Visit and the Sunbreeze Festival run all year
--   off  = no seasonal events
-- Each event also has its own launcher switch (harvest, starlight, egg_hunt, horro, sunbreeze): off = that one never runs.
-- Mog Bonanza and Strange Happenings are never forced on (they keep their own switches); Off stops them too.
-- No core scripts are changed: the events' own date checks are wrapped at server start.
-----------------------------------
require('modules/module_utils')

local m = Module:new('events_mode')

xi = xi or {}
xi.eventsMode = xi.eventsMode or {}

xi.eventsMode.get = function()
    package.loaded['modules/custom/lua/events_config'] = nil
    local ok, cfg = pcall(require, 'modules/custom/lua/events_config')
    local mode = ok and type(cfg) == 'table' and cfg.mode or 'date'
    if mode ~= 'on' and mode ~= 'off' then
        mode = 'date'
    end

    return mode
end

-- (2026-11-20) one launcher switch per event: harvest, starlight, egg_hunt, horro. A missing key counts as on.
xi.eventsMode.allowed = function(name)
    package.loaded['modules/custom/lua/events_config'] = nil
    local ok, cfg = pcall(require, 'modules/custom/lua/events_config')
    if ok and type(cfg) == 'table' and cfg[name] == false then
        return false
    end

    return true
end

-- the launcher's switch name for each event (SeasonalEvent id / xi.events table name)
local SWITCH = { StarlightCelebration = 'starlight', starlightCelebration = 'starlight', egg_hunt = 'egg_hunt', eggHunt = 'egg_hunt' }

-- Events "Always on" may switch on (by SeasonalEvent id)
local FORCEABLE = { StarlightCelebration = true, egg_hunt = true }

local function wrap(original, forceable, switch)
    return function(...)
        local mode = xi.eventsMode.get()
        if mode == 'off' or (switch and not xi.eventsMode.allowed(switch)) then
            return false
        elseif mode == 'on' and forceable then
            return true
        end

        return original(...)
    end
end

local function patchEvents()
    -- Seasonal events from scripts/events (the handler calls event.enableCheck)
    for _, event in pairs(xi.events and xi.events.registeredEvents or {}) do
        if type(event) == 'table' and type(event.enableCheck) == 'function' and not event.eventsModeWrapped then
            event.enableCheck       = wrap(event.enableCheck, FORCEABLE[event.id], SWITCH[event.id])
            event.eventsModeWrapped = true
        end
    end

    -- The same checks are also called straight from the event tables by NPC scripts
    for _, name in ipairs({ 'starlightCelebration', 'eggHunt' }) do
        local t = xi.events and xi.events[name]
        if t and type(t.enabledCheck) == 'function' and not t.eventsModeWrapped then
            t.enabledCheck      = wrap(t.enabledCheck, true, SWITCH[name])
            t.eventsModeWrapped = true
        end
    end

    -- Harvest Festival (returns 0 = off, 1 = the 2005 version)
    local harvest = xi.events and xi.events.harvestFestival
    if harvest and type(harvest.isHalloweenEnabled) == 'function' and not harvest.eventsModeWrapped then
        local original = harvest.isHalloweenEnabled
        harvest.isHalloweenEnabled = function(...)
            local mode = xi.eventsMode.get()
            if mode == 'off' or not xi.eventsMode.allowed('harvest') then
                return 0
            elseif mode == 'on' then
                return 1
            end

            return original(...)
        end

        harvest.eventsModeWrapped = true
    end
end

xi.eventsMode.patch = patchEvents

m:addOverride('xi.server.onServerStart', function()
    patchEvents()
    print('[events_mode] Seasonal events: ' .. xi.eventsMode.get())
    super()
end)

m:addOverride('xi.server.onJSTMidnight', function()
    patchEvents()
    super()
end)

return m
