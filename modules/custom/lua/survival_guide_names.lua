-----------------------------------
-- XI: Forever Offline (2026-11-26, Syfin: the Survival Guides in Valkurm Dunes, North Gustaberg and the Sanctuary of
-- Zi'Tah are named "Summoner" when you target them).
--
-- A name over an NPC's head comes from the game's own name list for the area, by the NPC's number. The era game files
-- carry an older list for some areas, in which the Survival Guide's number belongs to its neighbour. The server can
-- send a name along with the NPC, and the game then shows that one: every Survival Guide is sent as "Survival Guide".
-- Nothing else about the guides changes.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('survival_guide_names')

m:addOverride('xi.server.onServerStart', function()
    super()

    local ok, problem = pcall(function()
        local survival = require('scripts/globals/teleports/survival_guide_map')
        local named    = 0
        for zoneId in pairs(survival.zoneIdToGuideIdMap or {}) do
            local zone = GetZone(zoneId)
            if zone ~= nil then
                for _, npc in ipairs(zone:queryEntitiesByName('Survival_Guide')) do
                    npc:renameEntity('Survival Guide', true)
                    named = named + 1
                end
            end
        end

        print(string.format('[survival_guide_names] %d Survival Guides carry their own name', named))
    end)
    if not ok then
        print('[survival_guide_names] left as they are: ' .. tostring(problem))
    end
end)

return m
