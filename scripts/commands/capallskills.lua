-----------------------------------
-- func: capallskills (player)
-- desc: Caps all the skills of you, or of the player named (XI: Forever Offline, 2026-11-23, Garrett; a logged-out
--       character too, through modules/custom/late/gm_offline.lua).
-----------------------------------
---@type TCommand
local commandObj = {}

commandObj.cmdprops =
{
    permission = 1,
    parameters = 's'
}

commandObj.onTrigger = function(player, target)
    local gm = player
    if target ~= nil and target ~= '' then
        player = GetPlayerByName(target)
        if player == nil then
            gm:printToPlayer(string.format('Player named "%s" not found!', target))
            gm:printToPlayer('!capallskills (player)')
            return
        end
    end

    player:capAllSkills()

    local automatonSkills =
    {
        xi.skill.AUTOMATON_MELEE,
        xi.skill.AUTOMATON_RANGED,
        xi.skill.AUTOMATON_MAGIC,
    }

    for _, skillId in ipairs(automatonSkills) do
        player:setSkillLevel(skillId, 5000)
    end

    if gm ~= player then
        gm:printToPlayer(string.format('All skills capped for %s.', player:getName()))
    else
        player:printToPlayer('All skills capped!')
    end
end

return commandObj
