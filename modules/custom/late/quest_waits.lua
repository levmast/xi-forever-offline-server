-----------------------------------
-- Quest waits (XI: Forever Offline, 2026-11-18; Frost, Miniberg, Yache asked)
--
-- A launcher switch (CONFIG > Rates, "Short quest waits", on by default) shortens waits that only make sense on a
-- busy retail server. Off = the era waits again. The launcher writes modules/custom/lua/quest_waits_config.lua.
--   * Chocobo's Wounds: era = one Vana'diel day between feedings (about 58 minutes, six times); short = 1 minute.
--   * The Fanged One (RNG): era = the old tiger wanders for about 3.5 minutes before it dies; short = about 1 minute.
--   * Forge Your Destiny (SAM, Mumeito): era = three Vana'diel days at the forge (about 2.9 hours); short = 1 hour.
-- Both store the wait as a real time (seconds), so switching mid-quest never leaves anyone stuck.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('quest_waits')

local function shortWaits()
    package.loaded['modules/custom/lua/quest_waits_config'] = nil
    local ok, cfg = pcall(require, 'modules/custom/lua/quest_waits_config')
    if ok and type(cfg) == 'table' and cfg.short ~= nil then
        return cfg.short == true
    end

    return true -- (no file yet: the default)
end

-- seconds until the next Vana'diel day starts (a Vana'diel hour = 144 s, a minute = 2.4 s)
local function toNextVanaDay()
    return math.max(60, math.floor((24 - VanadielHour()) * 144 - VanadielMinute() * 2.4))
end

m:addOverride('xi.server.onServerStart', function()
    super()

    local short = shortWaits()

    -- Chocobo's Wounds: take the retail quest (real-time Timer) and set the wait after each feeding ourselves. The era
    -- module had replaced it with a Vana'diel day check; this keeps that wait in era mode, measured in real seconds.
    -- modifyInteractionEntry loads the quest file again, so the era module's feeding check goes with its copy of the
    -- quest: the feeding is the game's own, which reads Timer as a real time, and a Timer the era module wrote before
    -- (a Vana'diel day number) counts as over.
    -- (2026-11-27, Tetsu, Neet, Josh; 2026-11-26, Quaiton: the era waits again, or "it ain't hungry" for good, with
    -- short waits on) Nothing here was wrong. From 2026-11-25 this was the 100th override of xi.server.onServerStart:
    -- it stopped at its first global ("loop in gettable" in the map log), so the era module's quest stayed and Forge
    -- Your Destiny kept its long wait too. Fixed in modules/module_utils.lua (applyOverride); the copy of the feeding
    -- added here on 2026-11-26 never ran and was not needed, so it is gone again.
    local okC, errC = pcall(xi.module.modifyInteractionEntry, 'scripts/quests/jeuno/Chocobos_Wounds', function(quest)
        local finish = quest.sections[2][xi.zone.UPPER_JEUNO].onEventFinish
        for _, csid in ipairs({ 57, 58, 59, 60, 99 }) do
            local original = finish[csid]
            if original then
                finish[csid] = function(player, ...)
                    original(player, ...)
                    quest:setVar(player, 'Timer', GetSystemTime() + (short and 60 or toNextVanaDay()))
                end
            end
        end
    end)
    if not okC then
        print('[quest_waits] Chocobo\'s Wounds not changed: ' .. tostring(errC))
    end

    -- Forge Your Destiny: the forging wait after trading the Bomb Steel and Sacred Branch
    local okF, errF = pcall(xi.module.modifyInteractionEntry, 'scripts/quests/outlands/Forge_Your_Destiny', function(quest)
        for _, section in ipairs(quest.sections) do
            for _, zoneTable in pairs(section) do
                if type(zoneTable) == 'table' and type(zoneTable.onEventFinish) == 'table' and zoneTable.onEventFinish[27] and
                    zoneTable['Jaucribaix'] then
                    local original = zoneTable.onEventFinish[27]
                    zoneTable.onEventFinish[27] = function(player, ...)
                        original(player, ...)
                        if short then
                            quest:setVar(player, 'waitTime', GetSystemTime() + 3600)
                        end
                    end
                end
            end
        end
    end)
    if not okF then
        print('[quest_waits] Forge Your Destiny not changed: ' .. tostring(errF))
    end

    print(string.format('[quest_waits] %s waits (Chocobo\'s Wounds, Forge Your Destiny)', short and 'short' or 'era'))
end)

-- The Fanged One (2026-11-19, Yache: "it takes minutes, players may think the quest is stuck"): the old tiger walks the
-- same path with short stops and its poison finishes it in about a minute instead of 3.5. Still: don't attack it.
local FANGED_PATH =
{
    { x = 653.744, y =  -9.640, z = -328.601, rotation = 146, wait =  6000 },
    { x = 659.830, y = -10.235, z = -331.406, rotation = 017, wait =  2000 },
    { x = 666.793, y = -10.053, z = -338.386, rotation = 032, wait =  3000 },
    { x = 671.675, y =  -9.494, z = -346.934, rotation = 042, wait =  3000 },
    { x = 675.301, y = -10.208, z = -356.221, rotation = 063               },
    { x = 677.547, y = -10.064, z = -361.535, rotation = 075               },
    { x = 667.100, y =  -9.474, z = -378.066, rotation = 086, wait = 100000 }, -- resting place
}

m:addOverride('xi.zones.Sauromugue_Champaign.mobs.Old_Sabertooth.onMobSpawn', function(mob)
    super(mob)

    if not shortWaits() then
        return
    end

    local ok, problem = pcall(function()
        mob:delStatusEffectSilent(xi.effect.POISON)
        -- poison ticks every 3 seconds: a twentieth of its HP each tick = about 60 seconds
        mob:addStatusEffect(xi.effect.POISON, { power = math.max(1, math.ceil(mob:getHP() / 20)), duration = 1800, origin = mob })
        mob:pathThrough(FANGED_PATH, xi.path.flag.COORDS)
    end)
    if not ok then
        print('[quest_waits] The Fanged One not shortened: ' .. tostring(problem))
    end
end)

-- (2026-11-21, PTgamerguy) Aht Urhgan missions: with short waits, the waits between missions are about a minute too.
-- Two kinds share the names Mission[4][<n>]Timer: the game's own "next Vana'diel day" (the value is the day to wait
-- for) and the era module's "next Japanese midnight" (a 1 that expires then). A minute after a timer appears, a
-- check that runs while you play clears it. You still have to zone once where the mission asks it.
local TOAU_TIMER_CHECK_MS = 20000
local TOAU_SHORT_WAIT_S   = 60

local function toauWaits(player)
    if player == nil or not shortWaits() then
        return
    end

    local t = os.time()
    player:setLocalVar('QW_TOAU_RUN', t)
    for n = 1, 48 do
        local name  = string.format('Mission[%d][%d]Timer', xi.mission.log_id.TOAU, n)
        local value = player:getCharVar(name)
        local seen  = 'QW_TOAU_' .. n
        if value == 0 then
            player:setLocalVar(seen, 0)
        elseif player:getLocalVar(seen) == 0 then
            player:setLocalVar(seen, t)
        elseif t - player:getLocalVar(seen) >= TOAU_SHORT_WAIT_S then
            if value == 1 then
                player:setCharVar(name, 0)                    -- (era: the Japanese-midnight flag)
            elseif value > VanadielUniqueDay() then
                player:setCharVar(name, VanadielUniqueDay())  -- (game: the day it waits for is today)
            end

            player:setLocalVar(seen, 0)
        end
    end

    player:timer(TOAU_TIMER_CHECK_MS, toauWaits)
end

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    super(player, firstLogin, zoning)

    -- one running check (started again after a zone change if that stopped it)
    if os.time() - player:getLocalVar('QW_TOAU_RUN') > TOAU_TIMER_CHECK_MS / 1000 + 10 then
        player:timer(TOAU_TIMER_CHECK_MS, toauWaits)
    end
end)

return m
