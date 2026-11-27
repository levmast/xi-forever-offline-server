-----------------------------------
-- func: resetmissions <logID> (player)
-- desc: (2026-11-26, XI: Forever Offline; Quaiton: "for those who like to do cop many times", and for testing)
--       starts one mission line over, the opposite of !skipmissions: every mission of that log is unmarked, the log
--       goes back to where a new character has it (the nation logs to "none"), the line's own progress notes are
--       cleared, and the key items its missions hand out are taken back. Your own nation's log also puts your rank
--       back to 1 (!setrank puts it where you want it). GM only, so it takes a GM character.
--       What stays: rewards already received (gear, gil, titles), the airship pass, the adventurer's certificate, maps
--       and badges (they are used all over the game), and everything that is not part of that mission line.
--       Examples: !resetmissions cop      !resetmissions zilart      !resetmissions bastok Playername
-----------------------------------
local logIdHelpers = require('scripts/globals/log_ids')
-----------------------------------
---@type TCommand
local commandObj = {}

commandObj.cmdprops =
{
    permission = 1,
    parameters = 'ss'
}

local function error(player, msg)
    player:printToPlayer(msg)
    player:printToPlayer('!resetmissions <logID> (player)   logs: sandoria, bastok, windurst, zilart, cop, toau, wotg, acp, amk, asa, soa, rov, tvr')
end

-- MAX_MISSIONID in src/map/entities/char_entity.h: the lists also hold NONE = 65535, which is not a mission
local MAX_MISSION_ID = 851

-- key items a mission line hands out that are used all over the game: a reset leaves them alone
local keepKeyItem =
{
    AIRSHIP_PASS            = true,
    ADVENTURERS_CERTIFICATE = true,
    PSC_WILDCAT_BADGE       = true,
    PIONEERS_BADGE          = true,
}

local function kept(name)
    return keepKeyItem[name] or name:sub(1, 7) == 'MAP_OF_'
end

-- character variables a mission script writes itself (player:setCharVar('[COP]TalesBeginning', 1)): the line's own
-- notes. A variable a script only reads belongs to something else and is left alone.
local function varsWrittenIn(filename)
    local f = io.open(filename .. '.lua', 'r')
    if not f then
        return {}
    end

    local text = f:read('*a')
    f:close()
    local found = {}
    for _, call in ipairs({ 'setCharVar', 'incrementCharVar', 'setVar' }) do
        for name in text:gmatch(call .. '%(%s*[\'"]([^\'"]+)[\'"]') do
            found[#found + 1] = name
        end
    end

    return found
end

-- The reset itself. Returns the missions unmarked, the key items taken back, the notes cleared and whether the rank
-- was put back to 1; nil when the log has no mission list on this server.
commandObj.reset = function(targ, logId)
    local areaMissionIds = xi.mission.id[xi.mission.area[logId]]
    if type(areaMissionIds) ~= 'table' then
        return nil
    end

    -- the mission scripts of this log (see !skipmissions for the list and its Windows paths)
    local files = {}
    local containerFiles = GetContainerFilenamesList()
    for i = 1, #containerFiles do
        local filename = containerFiles[i]
        if type(filename) == 'string' and (filename:gsub('\\', '/')):find('scripts/missions/', 1, true) then
            local ok, container = pcall(require, filename)
            if ok and type(container) == 'table' and container.areaId == logId then
                files[#files + 1] = filename
            end
        end
    end

    -- key items: what the line gives, and what it gives for a while and takes back
    local skipper  = require('scripts/commands/skipmissions')
    local tookBack = {}
    local seen     = {}
    local vars     = {}
    for _, filename in ipairs(files) do
        local given, taken = skipper.keyItemsIn(filename)
        for _, list in ipairs({ given, taken }) do
            for _, name in ipairs(list) do
                local ki = xi.keyItem[name]
                if ki and not seen[name] then
                    seen[name] = true
                    if not kept(name) and targ:hasKeyItem(ki) then
                        targ:delKeyItem(ki)
                        tookBack[#tookBack + 1] = name
                    end
                end
            end
        end

        for _, name in ipairs(varsWrittenIn(filename)) do
            vars[name] = true
        end
    end

    -- notes: the scripts' own variables, then everything the mission framework keeps for this log
    local cleared = 0
    for name in pairs(vars) do
        if targ:getCharVar(name) ~= 0 then
            targ:setCharVar(name, 0)
            cleared = cleared + 1
        end
    end

    targ:clearVarsWithPrefix(string.format('Mission[%d][', logId))

    -- missions: every one unmarked; unmarking the current one puts the log back to its start
    local ids   = {}
    local known = {}
    for _, id in pairs(areaMissionIds) do
        if type(id) == 'number' and id < MAX_MISSION_ID and not known[id] then
            known[id] = true
            ids[#ids + 1] = id
        end
    end

    -- the "done" marks are kept for ids 0 to 63: those too, in case the list above leaves one out
    -- (not Chains of Promathia: it has no marks, only how far the story is)
    if logId ~= xi.mission.log_id.COP then
        for id = 0, 63 do
            if not known[id] then
                ids[#ids + 1] = id
            end
        end
    end

    table.sort(ids)

    local unmarked = 0
    local current  = targ:getCurrentMission(logId)
    for _, id in ipairs(ids) do
        if id == current or targ:hasCompletedMission(logId, id) then
            unmarked = unmarked + 1
        end

        targ:delMission(logId, id)
    end

    targ:setMissionStatus(logId, 0)

    local rankReset = false
    if logId <= xi.mission.log_id.WINDURST and logId == targ:getNation() then
        targ:setRank(1)
        targ:setRankPoints(0)
        rankReset = true
    end

    return unmarked, tookBack, cleared, rankReset
end

commandObj.onTrigger = function(player, logId, target)
    if logId == nil then
        error(player, 'You must give a mission log.')
        return
    end

    local logInfo = logIdHelpers.getMissionLogInfo(logId)
    if logInfo == nil then
        error(player, 'Invalid logID.')
        return
    end

    local logName = logInfo.full_name
    logId = logInfo.mission_log
    if logId == xi.mission.log_id.ASSAULT or logId == xi.mission.log_id.CAMPAIGN then
        error(player, logName .. ' is not a story line: use !delmission for a single entry.')
        return
    end

    local targ = player
    if target ~= nil then
        targ = GetPlayerByName(target)
        if targ == nil then
            error(player, string.format('Player named "%s" not found!', target))
            return
        end
    end

    local unmarked, tookBack, cleared, rankReset = commandObj.reset(targ, logId)
    if unmarked == nil then
        error(player, logName .. ' has no missions on this server.')
        return
    end

    player:printToPlayer(string.format('%s: started over for %s. %d missions unmarked, %d notes cleared.', logName, targ:getName(), unmarked, cleared))
    if #tookBack > 0 then
        player:printToPlayer('Key items taken back: ' .. table.concat(tookBack, ', '):lower():gsub('_', ' '))
    end

    if rankReset then
        player:printToPlayer('Rank put back to 1. !setrank <rank> changes it.')
    end

    player:printToPlayer('Zone once so the mission log and key items show. Rewards already received stay with the character.')
end

return commandObj
