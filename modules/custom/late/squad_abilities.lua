-----------------------------------
-- Job abilities on squad mates (XI: Forever Offline, 2026-11-22)
--
-- The party-only job abilities could not be used on a squad mate. Two things stood in the way:
--   * the game itself only offers a mate as the target when the ability's own target list includes NPCs. The launcher
--     adds that to the game's ability table (client-patches\spell_targets.json, "abilities");
--   * for three of them the server's own check said "the target has to be a player": Cover (Paladin), Accomplice and
--     Collaborator (Thief). A squad mate in your party is let through here; everyone else is judged as before.
-- Martyr, Devotion, Shikikoyo, Healing Waltz and Carbuncle's Healing Ruby need nothing on the server.
-- Cover also has to find the covering Paladin through the mate's master, since a mate has no party of its own
-- (src/map/utils/battleutils.cpp, GetCoverAbilityUser).
-----------------------------------
require('modules/module_utils')
require('scripts/globals/job_utils/paladin')
require('scripts/globals/job_utils/thief')
-----------------------------------
local m = Module:new('squad_abilities')

-- a squad mate, not yourself (the game's own target check has already made sure it is in your party)
local function onMate(player, target)
    return target ~= nil and target:getID() ~= player:getID() and target:isSquadMate()
end

m:addOverride('xi.job_utils.paladin.checkCover', function(player, target, ability)
    if onMate(player, target) then
        return 0, 0
    end

    return super(player, target, ability)
end)

m:addOverride('xi.job_utils.thief.checkAccomplice', function(player, target, ability)
    if onMate(player, target) then
        return 0, 0
    end

    return super(player, target, ability)
end)

m:addOverride('xi.job_utils.thief.checkCollaborator', function(player, target, ability)
    if onMate(player, target) then
        return 0, 0
    end

    return super(player, target, ability)
end)

return m
