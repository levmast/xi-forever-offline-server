-----------------------------------
-- XI: Forever Offline: land kings on a timer (sparkiie, 2026-11-22)
--
-- main.LAND_KINGS_TIMED = 0 (the default): nothing changes. Fafnir / Nidhogg, Adamantoise / Aspidochelone and
-- Behemoth / King Behemoth are called at their ??? with the item, as they have been on this server.
--
-- 1: the era's way, which modules/era/lua/globals/era_hnm_system.lua does (it reads the same setting): the ??? is
-- gone, a king appears by itself 21 to 24 hours after the last one fell (the first one within a day), and from the
-- fourth kill in a row the big one can come in its place. The time is kept as a date in the server's variables, so
-- hours with the servers off count too.
--
-- This file adds the one thing that module leaves out: the kings' scripts tell them to leave after 90 seconds
-- without a fight, which is right for a king called at a ??? and wrong for one that has to stand and wait for you.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local function timed()
    local v = xi.settings and xi.settings.main and xi.settings.main.LAND_KINGS_TIMED
    return v == true or (type(v) == 'number' and v ~= 0)
end

local m = Module:new('xifo_land_kings', timed())

local kings =
{
    'xi.zones.Dragons_Aery.mobs.Fafnir',
    'xi.zones.Dragons_Aery.mobs.Nidhogg',
    'xi.zones.Valley_of_Sorrows.mobs.Adamantoise',
    'xi.zones.Valley_of_Sorrows.mobs.Aspidochelone',
    'xi.zones.Behemoths_Dominion.mobs.Behemoth',
    'xi.zones.Behemoths_Dominion.mobs.King_Behemoth',
}

for _, king in ipairs(kings) do
    m:addOverride(king .. '.onMobInitialize', function(mob)
        super(mob)
        mob:setMobMod(xi.mobMod.IDLE_DESPAWN, 0) -- stays until someone comes for it
    end)
end

return m
