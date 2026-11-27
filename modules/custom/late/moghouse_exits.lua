-----------------------------------
-- Mog House exits for finished exit quests (XI: Forever Offline, 2026-11-26)
--
-- Hasuko: "Moghouse multi-exit quest does not seem to have come over properly on captured character": the quests were
-- finished in the log, and the Mog House still had one exit, in every city.
--
-- Each of the five exit quests sets a bit of its own in the Mog House flag at the moment it is finished here
-- (scripts/quests: Growing_Flowers, A_Ladys_Heart, Flower_Child, Pretty_Little_Things, Keeping_Notes). A character
-- whose quest log arrived finished another way never got the bit: one transferred from another server (the game does
-- not send that flag, so char_import.py could not carry it), or a quest completed with a GM command.
-- At log in, a finished exit quest whose bit is missing gets its bit. Bits are only added, never taken away.
-- The game reads the flag when you enter an area, so the exits show from the next area change on.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('moghouse_exits')

-- quest log, quest table, quest, Mog House flag bit
local exits =
{
    { 'SANDORIA',   'sandoria',  'GROWING_FLOWERS',      0x0001 },
    { 'BASTOK',     'bastok',    'A_LADYS_HEART',        0x0002 },
    { 'WINDURST',   'windurst',  'FLOWER_CHILD',         0x0004 },
    { 'JEUNO',      'jeuno',     'PRETTY_LITTLE_THINGS', 0x0008 },
    { 'AHT_URHGAN', 'ahtUrhgan', 'KEEPING_NOTES',        0x0010 },
}

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)

    if zoning or not player or not player:isPC() then
        return result
    end

    local flag  = player:getMoghouseFlag()
    local added = 0
    for _, exit in ipairs(exits) do
        local log = xi.questLog[exit[1]]
        local ids = xi.quest.id[exit[2]]
        local id  = ids and ids[exit[3]]
        if
            log and id and
            bit.band(flag, exit[4]) == 0 and
            player:getQuestStatus(log, id) == xi.questStatus.QUEST_COMPLETED
        then
            added = added + exit[4]
        end
    end

    if added > 0 then
        player:setMoghouseFlag(flag + added)
    end

    return result
end)

return m
