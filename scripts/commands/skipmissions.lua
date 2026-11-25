-----------------------------------
-- func: skipmissions <logID> <missionID> (player)
-- desc: (2026-11-24, XI: Forever Offline; Blitzace, Quaiton, Mikoto) skip missions you have already done many times:
--       every mission of that log before <missionID> is marked done (so it shows in the mission log), <missionID>
--       becomes the current mission, and the key items those missions hand out are given, minus the ones a skipped
--       mission takes back again (a delivered letter, a used pass). GM only, so it takes a GM character.
--       Nation missions: the rank is not changed; use !setrank for that.
--       Examples: !skipmissions cop 230      !skipmissions sandoria 10      !skipmissions zilart ARK_ANGELS
-----------------------------------
local logIdHelpers = require('scripts/globals/log_ids')
-----------------------------------
---@type TCommand
local commandObj = {}

commandObj.cmdprops =
{
    permission = 1,
    parameters = 'sss'
}

local function error(player, msg)
    player:printToPlayer(msg)
    player:printToPlayer('!skipmissions <logID> <missionID> (player)')
end

-- key item names a mission script gives and takes back
local function keyItemsIn(filename)
    local f = io.open(filename .. '.lua', 'r')
    if not f then
        return {}, {}
    end

    local text = f:read('*a')
    f:close()
    local given, taken = {}, {}
    local function names(list, chunk)
        for name in chunk:gmatch('xi%.keyItem%.([%w_]+)') do
            list[#list + 1] = name
        end

        for name in chunk:gmatch('xi%.ki%.([%w_]+)') do
            list[#list + 1] = name
        end
    end

    for chunk in text:gmatch('giveKeyItem%(%s*[%w_]+%s*,%s*(%b{})') do
        names(given, chunk)
    end

    for name in text:gmatch('giveKeyItem%(%s*[%w_]+%s*,%s*xi%.keyItem%.([%w_]+)') do
        given[#given + 1] = name
    end

    for name in text:gmatch('giveKeyItem%(%s*[%w_]+%s*,%s*xi%.ki%.([%w_]+)') do
        given[#given + 1] = name
    end

    for chunk in text:gmatch('addKeyItem%(([^%)]*)%)') do
        names(given, chunk)
    end

    for chunk in text:gmatch('keyItem%s*=%s*([^\n]*)') do
        names(given, chunk)
    end

    for chunk in text:gmatch('delKeyItem%(([^%)]*)%)') do
        names(taken, chunk)
    end

    return given, taken
end

commandObj.onTrigger = function(player, logId, missionId, target)
    local logInfo = logIdHelpers.getMissionLogInfo(logId)
    if logInfo == nil then
        error(player, 'Invalid logID.')
        return
    end

    local logName = logInfo.full_name
    logId = logInfo.mission_log

    local areaMissionIds = xi.mission.id[xi.mission.area[logId]]
    if missionId ~= nil and areaMissionIds then
        missionId = tonumber(missionId) or areaMissionIds[string.upper(missionId)]
    end

    if missionId == nil or missionId < 0 then
        error(player, 'Invalid missionID.')
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

    -- the missions of this log that exist on this server, in order
    local skipped = {}
    local files   = {}
    for _, id in pairs(areaMissionIds or {}) do
        if type(id) == 'number' and id < missionId then
            skipped[#skipped + 1] = id
        end
    end

    table.sort(skipped)

    for _, filename in ipairs(GetContainerFilenamesList()) do
        if filename:find('scripts/missions/', 1, true) then
            local ok, container = pcall(require, filename)
            if ok and type(container) == 'table' and container.areaId == logId and
                type(container.missionId) == 'number' and container.missionId < missionId
            then
                files[#files + 1] = filename
            end
        end
    end

    for _, id in ipairs(skipped) do
        targ:addMission(logId, id)
        targ:completeMission(logId, id)
    end

    targ:addMission(logId, missionId)

    -- key items: everything handed out, minus what a skipped mission takes back
    local takenSet, order, seen = {}, {}, {}
    for _, filename in ipairs(files) do
        local given, taken = keyItemsIn(filename)
        for _, name in ipairs(given) do
            if not seen[name] then
                seen[name] = true
                order[#order + 1] = name
            end
        end

        for _, name in ipairs(taken) do
            takenSet[name] = true
        end
    end

    local gave = {}
    for _, name in ipairs(order) do
        local ki = xi.keyItem[name]
        if ki and not takenSet[name] and not targ:hasKeyItem(ki) then
            targ:addKeyItem(ki)
            gave[#gave + 1] = name
        end
    end

    player:printToPlayer(string.format('%s: %d missions marked done, now on mission %u, for %s.', logName, #skipped, missionId, targ:getName()))
    if #gave > 0 then
        player:printToPlayer('Key items given: ' .. table.concat(gave, ', '):lower():gsub('_', ' '))
    end

    if logId <= xi.mission.log_id.WINDURST then
        player:printToPlayer('Nation missions: set the matching rank with !setrank <rank> if needed.')
    end

    player:printToPlayer('Zone once so the mission log and key items show. Final rewards (rings, gear) are not given: use !additem.')
end

return commandObj
