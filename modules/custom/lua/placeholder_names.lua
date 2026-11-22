-----------------------------------
-- Placeholder names (levi, 2026-11-22)
--
-- Every lottery NM placeholder (PH) shows the name "placeholder" over its head and in the target window,
-- so you can tell at a glance which mob to kill to give the NM its chance. Only the PH mob IDs change:
-- the NM and the PH's other look-alikes in the zone keep their names.
--
-- The renaming happens once, when the first character logs in after a server start.
--
-- Which mobs: data file placeholder_names_data.lua, made by tools/gen_placeholder_names.py from the
-- spawn slots in data/zones/*/mobs.yaml (+ module overrides): a slot member without a chance, in a slot
-- where an NM has one. Re-run that tool after a server update. Lua lottery NMs (entity.phList, used by
-- Dynamis) are picked up too.
--
-- Off switch: comment out this file's line in modules/init.txt and restart the server.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('placeholder_names')

local NAME = 'placeholder'

local function renameAll()
    local ids   = {}
    local data  = require('modules/custom/lua/placeholder_names_data')

    for id in pairs(data) do
        ids[id] = true
    end

    -- Lua lottery lists: xi.zones.<zone>.mobs.<NM>.phList = { [phId] = nmId, ... }
    for _, zone in pairs(xi.zones or {}) do
        if type(zone) == 'table' and type(zone.mobs) == 'table' then
            for _, mobTable in pairs(zone.mobs) do
                if type(mobTable) == 'table' and type(mobTable.phList) == 'table' then
                    for phId in pairs(mobTable.phList) do
                        if type(phId) == 'number' then
                            ids[phId] = true
                        end
                    end
                end
            end
        end
    end

    local count = 0
    for id in pairs(ids) do
        local mob = GetMobByID(id)
        if mob then
            mob:renameEntity(NAME, true) -- silent; the name sticks through respawns
            count = count + 1
        end
    end

    print(string.format('[placeholder_names] %d placeholders renamed to "%s"', count, NAME))
end

-- Runs once, at the first login after a server start. Not on xi.server.onServerStart on purpose: every override adds a
-- level to that function's environment chain, it already has close to LuaJIT's limit of 100, and one more made the last
-- one (custom/late/quest_waits.lua) fail with "loop in gettable".
local done = false

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    if not done then
        done = true

        local ok, err = pcall(renameAll)
        if not ok then
            print('[placeholder_names] ' .. tostring(err))
        end
    end

    return super(player, firstLogin, zoning)
end)

return m
