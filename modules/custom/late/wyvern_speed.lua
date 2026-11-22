-----------------------------------
-- Wyvern keeps up with its Dragoon (XI: Forever Offline, 2026-11-21, report from a player running at speed 100)
-- A pet's speed comes from its own pet data (the wyvern's is the retail 40-50ish), not from the map.BASE_SPEED setting
-- that sets the player's run speed. With a raised run speed the wyvern falls far behind while its master runs.
-- When the wyvern is called (and every time it is called again), its base speed is set to the master's base speed.
-- At the retail 50 this changes nothing worth seeing; only worlds with a raised run speed are affected.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('wyvern_speed')

m:addOverride('xi.pets.wyvern.onMobSpawn', function(mob)
    super(mob)

    local ok, err = pcall(function()
        local master = mob:getMaster()
        if master ~= nil then
            local speed = master:getBaseSpeed()
            if speed ~= nil and speed > 0 then
                mob:setBaseSpeed(speed)
            end
        end
    end)

    if not ok then
        print('[wyvern_speed] ' .. tostring(err))
    end
end)

return m
