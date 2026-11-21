-----------------------------------
-- Artifact armor quests: a party mate's job counts
--
-- The AF quests only start for a player whose own main job is the quest's job. With this module, if one of your summoned
-- party mates (a squad mate) is on that job, the quest starts and carries on for you, as if you were that job.
--   * The job comes from the mate. The level rule (AF1_QUEST_LEVEL and so on) is checked against YOU, unless
--     LEVEL_FROM_MATE is set to true below.
--   * It only ever adds ways to pass a check. A check that passes for you passes exactly as before, and anything that
--     fails for another reason (the quest is already done, not started, ...) still fails.
--   * The quest reward comes to you. Trade it to the mate (!squad) to unlock it for the squad.
-- The list of AF quests is written by install-af-party.ps1 from your own server files (af_quest_list.lua).
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('af_party_job')

local LEVEL_FROM_MATE = false -- false: the quest's level rule is checked against you. true: against the mate.

local listOk, questList = pcall(require, 'modules/custom/lua/af_quest_list')
if not listOk or type(questList) ~= 'table' then
    print('[af_party] af_quest_list.lua not found - run install-af-party.ps1 again')
    questList = {}
end

-- The summoned mates in the player's party (not the player)
local function matesOf(player)
    local mates = {}
    local party = player:getPartyWithTrusts()
    if party == nil then
        return mates
    end

    local selfId = player:getID()
    for _, member in ipairs(party) do
        if member:getID() ~= selfId then
            local ok, isTrust = pcall(function()
                return member:getObjType() == xi.objType.TRUST
            end)

            if not ok or isTrust then
                mates[#mates + 1] = member
            end
        end
    end

    return mates
end

-- [job] = { quest log, quest id } of the quest that unlocks the job (filled in below, where the ids exist)
local UNLOCK_QUESTS = {}
pcall(function()
    UNLOCK_QUESTS[xi.job.SAM] = { xi.questLog.OUTLANDS, xi.quest.id.outlands.FORGE_YOUR_DESTINY }
end)

-- Something that looks like the player to a quest check, but answers "main job" (and maybe level) with the mate's
local function standIn(player, mate)
    local overrides =
    {
        getMainJob = function()
            return mate:getMainJob()
        end,

        getSubJob = function()
            return mate:getSubJob()
        end,
    }

    -- (2026-11-19, Yache: RNG with a SAM mate, Jaucribaix would not start The Sacred Katana) a mate can be on a job you
    -- never unlocked yourself, so the quest that unlocks the mate's job counts as done while its job stands in
    local unlock = UNLOCK_QUESTS[mate:getMainJob()]
    if unlock ~= nil then
        overrides.hasCompletedQuest = function(_, log, id)
            if log == unlock[1] and id == unlock[2] then
                return true
            end

            return player:hasCompletedQuest(log, id)
        end
    end

    -- (2026-11-19) Knight Stalker's ??? wants your wyvern out: a Dragoon mate's job stands in for it
    if mate:getMainJob() == xi.job.DRG then
        overrides.getPet = function()
            local pet = player:getPet()
            if pet ~= nil then
                return pet
            end

            return { getPetID = function() return xi.petId.WYVERN end }
        end
    end

    if LEVEL_FROM_MATE then
        overrides.getMainLvl = function()
            return mate:getMainLvl()
        end
    end

    return setmetatable({}, {
        __index = function(_, key)
            if overrides[key] ~= nil then
                return overrides[key]
            end

            local value = player[key]
            if type(value) == 'function' then
                return function(_, ...)
                    return value(player, ...)
                end
            end

            return value
        end,
    })
end

-- The original check first. Only if it fails is it asked again for each mate.
local function wrapCheck(original)
    return function(player, ...)
        local ok, result = pcall(original, player, ...)
        if ok and result then
            return result
        end

        for _, mate in ipairs(matesOf(player)) do
            local mateOk, mateResult = pcall(original, standIn(player, mate), ...)
            if mateOk and mateResult then
                return mateResult
            end
        end

        return ok and result or false
    end
end

-----------------------------------
-- (2026-11-19, Yache) The rest of the artifact quests. The first version only reached the quests whose job rule sits in
-- a section check. Three more kinds are covered here:
--   EXTRA_QUESTS   quest files the installer's list missed (job rule in a check, or inside a trigger handler),
--   LEGACY_NPCS    quests still written as plain NPC scripts (the NPC asks player:getMainJob() itself).
-- For those the handler runs with a stand-in for you that answers "main job" with the mate's job, and only when your
-- own job is not the one the quest wants and a called mate has it. If a handler fails with the stand-in, it runs again
-- with you, exactly as before this module.
-----------------------------------
local J = xi.job
local EXTRA_QUESTS =
{
    { 'scripts/quests/sandoria/Messenger_From_Beyond',       J.WHM }, -- WHM AF1
    { 'scripts/quests/sandoria/Prelude_of_Black_and_White',  J.WHM }, -- WHM AF2
    { 'scripts/quests/sandoria/Sharpening_the_Sword',        J.PLD }, -- PLD AF1
    { 'scripts/quests/jeuno/Wings_of_Gold',                  J.BST }, -- BST AF1
    { 'scripts/quests/jeuno/Scattered_into_Shadow',          J.BST }, -- BST AF2
    { 'scripts/quests/jeuno/Painful_Memory',                 J.BRD }, -- BRD AF1
    { 'scripts/quests/jeuno/The_Requiem',                    J.BRD }, -- BRD AF2
    { 'scripts/quests/jeuno/The_Circle_of_Time',             J.BRD }, -- BRD AF3
    { 'scripts/quests/outlands/Ill_Take_the_Big_Box',        J.NIN }, -- NIN AF2
    { 'scripts/quests/sandoria/Chasing_Quotas',              J.DRG }, -- DRG AF2
    -- (2026-11-21, Tasou: Guslam would not give Borghertz's Healing Hands with a WHM mate out) the Borghertz hands quests
    -- ask for the job inside Guslam's trigger, and his cutscene's finish asks again, so their event finishes are wrapped too
    { 'scripts/quests/jeuno/Borghertzs_Warring_Hands', J.WAR, true },
    { 'scripts/quests/jeuno/Borghertzs_Striking_Hands', J.MNK, true },
    { 'scripts/quests/jeuno/Borghertzs_Healing_Hands', J.WHM, true },
    { 'scripts/quests/jeuno/Borghertzs_Sorcerous_Hands', J.BLM, true },
    { 'scripts/quests/jeuno/Borghertzs_Vermillion_Hands', J.RDM, true },
    { 'scripts/quests/jeuno/Borghertzs_Sneaky_Hands', J.THF, true },
    { 'scripts/quests/jeuno/Borghertzs_Stalwart_Hands', J.PLD, true },
    { 'scripts/quests/jeuno/Borghertzs_Shadowy_Hands', J.DRK, true },
    { 'scripts/quests/jeuno/Borghertzs_Wild_Hands', J.BST, true },
    { 'scripts/quests/jeuno/Borghertzs_Harmonious_Hands', J.BRD, true },
    { 'scripts/quests/jeuno/Borghertzs_Chasing_Hands', J.RNG, true },
    { 'scripts/quests/jeuno/Borghertzs_Loyal_Hands', J.SAM, true },
    { 'scripts/quests/jeuno/Borghertzs_Lurking_Hands', J.NIN, true },
    { 'scripts/quests/jeuno/Borghertzs_Dragon_Hands', J.DRG, true },
    { 'scripts/quests/jeuno/Borghertzs_Calling_Hands', J.SMN, true },
}

local LEGACY_NPCS =
{
    { 'Chateau_dOraguille',    '_6h1',          J.WHM, { 'onTrigger', 'onEventFinish' } },            -- Pieuje's Decision (WHM AF3)
    { 'Heavens_Tower',         'Chumimi',       J.BLM, { 'onTrade', 'onTrigger', 'onEventFinish' } }, -- BLM AF1-3
    { 'Chateau_dOraguille',    'Curilla',       J.RDM, { 'onTrigger', 'onEventFinish' } },            -- Peace for the Spirit (RDM AF3)
    { 'Northern_San_dOria',    'Ailbeche',      J.PLD, { 'onTrade', 'onTrigger', 'onEventFinish' } }, -- A Boy's Dream (PLD AF2)
    { 'Chateau_dOraguille',    '_6h0',          J.PLD, { 'onTrigger', 'onEventFinish' } },            -- A Boy's Dream, Under Oath (PLD AF2-3)
    { 'Lower_Jeuno',           '_6t2',          J.BST, { 'onTrigger', 'onEventFinish' } },            -- A New Dawn (BST AF3)
    { 'Windurst_Woods',        'Perih_Vashai',  J.RNG, { 'onTrade', 'onTrigger', 'onEventFinish' } }, -- RNG AF2-3
    { 'Norg',                  'Ryoma',         J.NIN, { 'onTrigger', 'onEventFinish' } },            -- NIN AF1, AF3
    { 'Northern_San_dOria',    'Miaux',         J.DRG, { 'onTrigger', 'onEventFinish' } },            -- A Craftsman's Work (DRG AF1)
    { 'Chateau_dOraguille',    'Rahal',         J.DRG, { 'onTrigger', 'onEventFinish' } },            -- Knight Stalker (DRG AF3)
    { 'Temple_of_Uggalepih',   'qm15',          J.DRG, { 'onTrigger' } },                             -- Knight Stalker's ???
    { 'Windurst_Walls',        '_6n2',          J.SMN, { 'onTrigger', 'onEventFinish' } },            -- Class Reunion, Carbuncle Debacle (SMN AF2-3)
    { 'Aht_Urhgan_Whitegate',  'Iruki-Waraki',  J.PUP, { 'onTrade', 'onTrigger', 'onEventFinish' } }, -- PUP AF1-2
}

-- the called mate on this job, when you are not on it yourself
local function mateOnJob(player, job)
    local ok, mine = pcall(function()
        return player:getMainJob()
    end)
    if not ok or mine == job then
        return nil
    end

    for _, mate in ipairs(matesOf(player)) do
        if mate:getMainJob() == job then
            return mate
        end
    end

    return nil
end

local function withMateJob(original, job, label)
    return function(player, ...)
        local mate = mateOnJob(player, job)
        if mate == nil then
            return original(player, ...)
        end

        local results = { pcall(original, standIn(player, mate), ...) }
        if results[1] then
            return (unpack or table.unpack)(results, 2)
        end

        print(string.format('[af_party] %s: the mate\'s job could not be used (%s)', label, tostring(results[2])))
        return original(player, ...)
    end
end

-- changes a quest that is loaded already where it stands (a reload would throw away what the era modules changed in it)
local function modifyQuest(path, change)
    local loaded = package.loaded[path]
    if type(loaded) == 'table' and type(loaded.sections) == 'table' then
        InteractionGlobal.lookup:removeContainer(loaded)
        change(loaded)
        InteractionGlobal.lookup:addContainer(loaded)
    else
        xi.module.modifyInteractionEntry(path, change)
    end
end

local function wrapTriggers(quest, job, label, events)
    for _, section in ipairs(quest.sections) do
        for zoneKey, zone in pairs(section) do
            if type(zoneKey) == 'number' and type(zone) == 'table' then
                for npcName, entry in pairs(zone) do
                    if events and (npcName == 'onEventFinish' or npcName == 'onEventUpdate') and type(entry) == 'table' then
                        for csid, handler in pairs(entry) do
                            if type(handler) == 'function' then
                                entry[csid] = withMateJob(handler, job, label)
                            end
                        end
                    elseif type(npcName) == 'string' and type(entry) == 'table' then
                        for _, handler in ipairs({ 'onTrigger', 'onTrade' }) do
                            if type(rawget(entry, handler)) == 'function' then
                                entry[handler] = withMateJob(entry[handler], job, label)
                            end
                        end
                    end
                end
            end
        end
    end
end

for _, row in ipairs(LEGACY_NPCS) do
    local zone, npc, job, handlers = row[1], row[2], row[3], row[4]
    for _, handler in ipairs(handlers) do
        local label = zone .. '/' .. npc .. '.' .. handler
        m:addOverride(string.format('xi.zones.%s.npcs.%s.%s', zone, npc, handler), function(player, ...)
            local original = super
            return withMateJob(original, job, label)(player, ...)
        end)
    end
end

m:addOverride('xi.server.onServerStart', function()
    super()

    local wrapped, failed = 0, 0
    for _, path in ipairs(questList) do
        local ok = pcall(function()
            modifyQuest(path, function(quest)
                for _, section in ipairs(quest.sections) do
                    if type(section.check) == 'function' then
                        section.check = wrapCheck(section.check)
                    end
                end
            end)
        end)

        if ok then
            wrapped = wrapped + 1
        else
            failed = failed + 1
        end
    end

    for _, row in ipairs(EXTRA_QUESTS) do
        local path, job, events = row[1], row[2], row[3]
        local ok, problem = pcall(function()
            modifyQuest(path, function(quest)
                for _, section in ipairs(quest.sections) do
                    if type(section.check) == 'function' then
                        section.check = wrapCheck(section.check)
                    end
                end

                wrapTriggers(quest, job, path, events)
            end)
        end)

        if ok then
            wrapped = wrapped + 1
        else
            failed = failed + 1
            print(string.format('[af_party] %s could not be changed: %s', path, tostring(problem)))
        end
    end

    print(string.format('[af_party] a party mate\'s job now counts for %d artifact quests and %d quest NPCs (%d could not be changed)', wrapped, #LEGACY_NPCS, failed))
end)

return m
