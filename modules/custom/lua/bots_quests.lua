-----------------------------------
-- FFXI Offline: bot players, step 4.4c - quests and nation missions ("goal trips"). Used by bots.lua.
--
-- The server's own quest and mission scripts (scripts/quests, scripts/missions) are the source: their
-- questgivers (the "!pos" lines in each file), their rewards (gil, items, fame, titles, rank points, rank)
-- and their order. A bot:
--   1. picks a quest of its nation / a town it knows, or its next nation mission (by level, like players do),
--   2. travels to the real questgiver and talks to it (a little while),
--   3. goes out to do it - real fights in an area for its level (missions always, quests often),
--   4. comes back to the questgiver, and the server records the quest / mission complete with its real rewards
--      (npcUtil.completeQuest / completeMission: gil, items, fame, title, rank points; rank ups 1->2 after x-3).
--   5. tells the people around it ("finally done with Lizard Skins!", "rank 3 now :)").
-- The cutscenes and menu answers are skipped (a bot has no game window): that is the only shortcut.
-- Era only: San d'Oria / Bastok / Windurst / Jeuno / other areas / outlands / Aht Urhgan quests, nation missions,
-- and the expansion storylines in order: Rise of the Zilart (from nation rank 6), Chains of Promathia (rank 3+)
-- and Treasures of Aht Urhgan, each gated by the levels players did them at. Progress per storyline is kept in
-- char vars ([Bot]ML_zilart / _cop / _toau = how many it has done), so a script that sets its next mission in a
-- cutscene does not stall the bot.
-----------------------------------
local Q = {}

local QUEST_LOGS = { [0] = 'sandoria', [1] = 'bastok', [2] = 'windurst', [3] = 'jeuno', [4] = 'otherAreas', [5] = 'outlands', [6] = 'ahtUrhgan' }
local QUEST_MIN_LVL = { [0] = 1, [1] = 1, [2] = 1, [3] = 25, [4] = 10, [5] = 20, [6] = 50 }
local NATION_FOLDER = { [0] = 'sandoria', [1] = 'bastok', [2] = 'windurst' }
-- nation missions: the level players do them at (tier-number)
local MISSION_LVL = {
    [1] = { 1, 8, 12 }, [2] = { 15, 20, 25 }, [3] = { 30, 35, 40 }, [4] = { 45 }, [5] = { 50, 60 },
    [6] = { 60, 65 }, [7] = { 65, 70 }, [8] = { 70, 75 }, [9] = { 75, 75 },
}
-- the expansion storylines: folder, the nation rank they need, the level of mission i (or of CoP chapter i)
local LINES = {
    { key = 'zilart', folder = 'rotz', label = 'ZM', rank = 6,
      lvl = function(n) return ({ 50, 50, 50, 50, 55, 60, 60, 65, 65, 70, 70, 70, 70, 75, 75, 75, 75 })[n] or 75 end,
      hub = { name = 'Norg', x = -25.8, y = 1.1, z = -41.0, zone = 252 } },
    { key = 'cop', folder = 'cop', label = 'PM', rank = 3,
      lvl = function(chapter) return ({ 30, 40, 50, 55, 60, 65, 70, 75 })[chapter] or 75 end,
      hub = { name = 'Upper Jeuno', x = 2.2, y = -3.2, z = 58.4, zone = 244 } },
    { key = 'toau', folder = 'toau', label = 'TOAU', rank = 1,
      lvl = function(n) return math.min(75, 20 + math.floor((n - 1) * 55 / 47)) end,
      hub = { name = 'Naja Salaheem', x = 22.7, y = -8.8, z = -45.6, zone = 50 } },
}
local SETTING = { zilart = 'ENABLE_ROTZ', cop = 'ENABLE_COP', toau = 'ENABLE_TOAU' }
local TALK_TIME   = { 8, 20 }    -- seconds at the questgiver
local ERRAND_MIN  = { 8, 25 }    -- minutes out doing it
local QUEST_GAP   = 40 * 60      -- seconds before the same bot tries a quest it gave up on again

local Q_state                    -- [bot id] = st (from bots.lua)
local hunt, life
local catalog                    -- { quests = { ... }, missions = { [nation] = { ... } } }
local gaveUp = {}                -- ['botid:file'] = os.time()

local function rnd(a, b)
    return math.random(a, b)
end

local function now()
    return os.time()
end

local function pick(list)
    return list[rnd(1, #list)]
end

local function note(text)
    print('[bots] ' .. text)
end

function Q.setup(brainState, huntModule, lifeModule)
    Q_state, hunt, life = brainState, huntModule, lifeModule
end

-----------------------------------
-- the catalog: every quest / mission script the server loaded, with its questgiver position
-----------------------------------
local function prettyName(file)
    local base = file:match('([^/]+)$') or file
    base = base:gsub('%.lua$', ''):gsub('^%d+_%d+_%d*_?', ''):gsub('^%d+_%d+_', ''):gsub('^%d+_', '')
    base = base:gsub('_[A-Z][a-z]+$', function(s)
        return s -- keep "Lure_of_the_Wildcat_Sandoria" readable
    end)
    return (base:gsub('_', ' '))
end

-- the first "Name : !pos x y z zone" line of the file
local function questgiver(path)
    local f = io.open(path, 'r')
    if not f then
        return nil
    end

    local found
    for _ = 1, 40 do
        local line = f:read('*l')
        if not line then
            break
        end

        -- ("Name : !pos x y z zone"; a few files write "Name - !pos ...", Windurst 2-2 among them)
        local name, x, y, z, zone = line:match('^%-%-%s*([^:]-)%s*[:%-]%s*!pos%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%d+)')
        if name then
            found = { name = name, x = tonumber(x), y = tonumber(y), z = tonumber(z), zone = tonumber(zone) }
            break
        end
    end

    f:close()
    return found
end

local function load(file)
    local mod = file:gsub('%.lua$', '')
    local ok, obj = pcall(require, mod)
    if ok and type(obj) == 'table' then
        return obj
    end

    return nil
end

local function buildCatalog()
    catalog = { quests = {}, missions = { [0] = {}, [1] = {}, [2] = {} }, lines = {} }
    for _, line in ipairs(LINES) do
        catalog.lines[line.key] = {}
    end

    -- (2026-11-26) The server hands this list over as a C++ list: it has a length and numbered entries, but it is
    -- not a Lua table and ipairs does not walk it. On Windows its paths also use backslashes. Either one left the
    -- catalog empty, so no bot ever did a real quest or mission (only the "job quest" trips, on the spot).
    local ok, listed = pcall(GetContainerFilenamesList)
    local files = {}
    if ok and listed ~= nil then
        local okCount, count = pcall(function()
            return #listed
        end)
        for i = 1, okCount and tonumber(count) or 0 do
            local okName, name = pcall(function()
                return listed[i]
            end)
            if okName and type(name) == 'string' then
                files[#files + 1] = name
            end
        end
    end

    for _, listedName in ipairs(files) do
        -- `file` (forward slashes) is for reading and for names; the script itself is asked for under the name the
        -- server loaded it by (`listedName`), so it is the same object and not a second copy
        local file = listedName:gsub('\\', '/')
        local function load()
            local okLoad, obj = pcall(require, (listedName:gsub('%.lua$', '')))
            return okLoad and type(obj) == 'table' and obj or nil
        end

        local folder, area = file:match('scripts/(%a+)/([%a]+)/')
        if folder == 'quests' then
            for logId, name in pairs(QUEST_LOGS) do
                if area == name and not file:find('/hiddenQuests/') then
                    local obj = load(file)
                    local giver = questgiver(file:find('%.lua$') and file or (file .. '.lua'))
                    if obj and obj.areaId == logId and obj.questId and giver and giver.zone then
                        local job = file:match('/([A-Z][A-Z][A-Z])_AF%d')
                        local af = tonumber(file:match('_AF(%d)'))
                        catalog.quests[#catalog.quests + 1] = {
                            file = file, obj = obj, logId = logId, giver = giver, name = prettyName(file),
                            minLvl = af and (30 + af * 10) or QUEST_MIN_LVL[logId], job = job,
                        }
                    end
                end
            end
        elseif folder == 'missions' then
            for nation, name in pairs(NATION_FOLDER) do
                if area == name then
                    local t, n, sub = file:match('/(%d)_(%d)_?(%d*)_')
                    t, n = tonumber(t), tonumber(n)
                    local obj = t and load(file)
                    if obj and obj.missionId and MISSION_LVL[t] then
                        local giver = questgiver(file:find('%.lua$') and file or (file .. '.lua'))
                        catalog.missions[nation][#catalog.missions[nation] + 1] = {
                            file = file, obj = obj, tier = t, num = n, sub = tonumber(sub) or 0, giver = giver, name = prettyName(file),
                            minLvl = MISSION_LVL[t][n] or MISSION_LVL[t][#MISSION_LVL[t]],
                        }
                    end
                end
            end

            for _, line in ipairs(LINES) do
                if area == line.folder then
                    local base = file:match('([^/]+)$') or ''
                    local a, b = base:match('^(%d+)_(%d+)_')
                    local order, lvl
                    if line.key == 'cop' and a then
                        order, lvl = tonumber(a) * 100 + tonumber(b), line.lvl(tonumber(a))
                    else
                        local n = tonumber(base:match('^(%d+)_'))
                        order, lvl = n, n and line.lvl(n)
                    end

                    local obj = order and load(file)
                    if obj and obj.missionId and obj.areaId then
                        local list = catalog.lines[line.key]
                        list[#list + 1] = {
                            file = file, obj = obj, order = order, line = line.key, label = line.label, rank = line.rank,
                            giver = questgiver(file:find('%.lua$') and file or (file .. '.lua')), name = prettyName(file),
                            minLvl = lvl, hub = line.hub,
                        }
                    end
                end
            end
        end
    end

    for key, list in pairs(catalog.lines) do
        table.sort(list, function(a, b)
            return a.order < b.order
        end)
        for i, m in ipairs(list) do
            m.idx = i
            m.label = key == 'cop' and string.format('PM%d-%d', math.floor(m.order / 100), m.order % 100) or (m.label .. m.order)
            m.giver = m.giver or (list[i - 1] and list[i - 1].giver) or m.hub -- (no "!pos" in the file: where the last one was)
        end
    end

    for nation = 0, 2 do
        table.sort(catalog.missions[nation], function(a, b)
            if a.tier ~= b.tier then
                return a.tier < b.tier
            elseif a.num ~= b.num then
                return a.num < b.num
            end

            return a.sub < b.sub
        end)
        -- (a mission file with no "!pos" line would stop that nation's bots at it for good: where the last one was)
        for i, m in ipairs(catalog.missions[nation]) do
            m.giver = m.giver or (catalog.missions[nation][i - 1] and catalog.missions[nation][i - 1].giver)
        end
    end

    note(string.format('quest catalog: %d quests, %d / %d / %d nation missions, %d Zilart / %d Promathia / %d Aht Urhgan missions',
        #catalog.quests, #catalog.missions[0], #catalog.missions[1], #catalog.missions[2],
        #catalog.lines.zilart, #catalog.lines.cop, #catalog.lines.toau))
    return catalog
end

function Q.catalog()
    return catalog or buildCatalog()
end

-----------------------------------
-- what is next for this bot
-----------------------------------
local function jobName(bot)
    local JOBS = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP' }
    return JOBS[bot:getMainJob()] or 'WAR'
end

local function nationOf(bot)
    local ok, n = pcall(function()
        return bot:getNation()
    end)
    return (ok and n) or 0
end

local function missionDone(bot, m)
    local ok, done = pcall(function()
        return bot:hasCompletedMission(m.obj.areaId, m.obj.missionId)
    end)
    return ok and done
end

-- its next nation mission (the first one not done), if its level and rank are enough
local function nationMission(bot)
    local list = Q.catalog().missions[nationOf(bot)] or {}
    local seen = {}
    local rank = 1
    pcall(function()
        rank = bot:getRank(nationOf(bot))
    end)
    for _, m in ipairs(list) do
        if not seen[m.obj.missionId] then
            seen[m.obj.missionId] = true
            if not missionDone(bot, m) then
                if bot:getMainLvl() >= m.minLvl and rank >= m.tier and m.giver then
                    return m
                end

                return nil
            end
        end
    end

    return nil
end

local function questOpen(bot, q)
    local ok, done = pcall(function()
        return bot:hasCompletedQuest(q.logId, q.obj.questId)
    end)
    if not ok or done then
        return false
    end

    if bot:getMainLvl() < q.minLvl or (q.job and q.job ~= jobName(bot)) then
        return false
    end

    return (gaveUp[bot:getID() .. ':' .. q.file] or 0) + QUEST_GAP < now()
end

-- quests of its own nation's towns first, then the other places it can reach
local function pickQuest(bot)
    local nation = nationOf(bot)
    local own, other = {}, {}
    for _, q in ipairs(Q.catalog().quests) do
        if questOpen(bot, q) then
            if q.logId == nation then
                own[#own + 1] = q
            else
                other[#other + 1] = q
            end
        end
    end

    if #own > 0 and (#other == 0 or math.random() < 0.7) then
        return pick(own)
    elseif #other > 0 then
        return pick(other)
    end

    return nil
end

local function lineOn(key)
    local ok, v = pcall(function()
        return xi.settings.main[SETTING[key]]
    end)
    return not (ok and v == 0) -- (only a setting that says 0 turns a storyline off)
end

-- how far it is in a storyline (missions done)
local function lineDone(bot, key)
    return math.max(0, bot:getCharVar('[Bot]ML_' .. key))
end

-- its next mission of a storyline, if its level and nation rank are enough
local function lineMission(bot, key)
    if not lineOn(key) then
        return nil
    end

    local list = Q.catalog().lines[key] or {}
    local m = list[lineDone(bot, key) + 1]
    if not m then
        return nil
    end

    local rank = 1
    pcall(function()
        rank = bot:getRank(nationOf(bot))
    end)
    if bot:getMainLvl() >= m.minLvl and rank >= m.rank and (gaveUp[bot:getID() .. ':' .. m.file] or 0) + QUEST_GAP < now() then
        return m
    end

    return nil
end

-- the missions it could do now: its nation's (preferred when it wants rank) and the storylines
local function nextMission(bot, preferNation)
    local nation = nationMission(bot)
    if nation and preferNation then
        return nation
    end

    local options = {}
    if nation then
        options[#options + 1] = nation
        options[#options + 1] = nation -- (its nation's story first, as most players did)
    end

    for _, line in ipairs(LINES) do
        local m = lineMission(bot, line.key)
        if m then
            options[#options + 1] = m
        end
    end

    return #options > 0 and pick(options) or nil
end

function Q.available(bot)
    return nextMission(bot) ~= nil or pickQuest(bot) ~= nil
end

-----------------------------------
-- the trip
-----------------------------------
local function goTo(bot, giver)
    local a = math.random() * 2 * math.pi
    local x, z = giver.x + 2.5 * math.cos(a), giver.z + 2.5 * math.sin(a)
    if bot:getZoneID() ~= giver.zone then
        if xi.navguard then xi.navguard.setPos(bot, x, giver.y, z, 0, giver.zone, { x = giver.x, y = giver.y, z = giver.z }) else bot:setPos(x, giver.y, z, 0, giver.zone) end
        return 'zoning'
    end

    BotMoveTo(bot:getID(), x, giver.y, z)
    return true
end

-- starts its next mission (preferred when it wants rank) or a quest; true / 'zoning' when started
function Q.start(bot, st, preferMission)
    local m = nextMission(bot, preferMission)
    local q = (not m or (not preferMission and math.random() < 0.5)) and pickQuest(bot) or nil
    local job
    if q then
        job = { kind = 'quest', item = q, errand = math.random() < 0.6 }
    elseif m then
        job = { kind = 'mission', item = m, errand = true }
    else
        return false
    end

    BotHeal(bot:getID(), false)
    st.life, st.task = nil, nil
    st.quest = { kind = job.kind, item = job.item, errand = job.errand, phase = 'talk', at = now() + rnd(TALK_TIME[1], TALK_TIME[2]) + 6 }
    pcall(function()
        job.item.obj:begin(bot) -- (addQuest / addMission, as accepting it from the questgiver does)
    end)
    note(string.format('%s starts the %s "%s" (Lv%d)', bot:getName(), job.kind, (job.item.label and (job.item.label .. ' ') or '') .. job.item.name, bot:getMainLvl()))
    return goTo(bot, job.item.giver)
end

-- a trip that is not in the quest scripts (the subjob quest, a job quest): done() runs when it reports back
function Q.startSpecial(bot, st, name, done)
    local givers = {}
    for _, q in ipairs(Q.catalog().quests) do
        if q.logId == nationOf(bot) then
            givers[#givers + 1] = q.giver
        end
    end

    local pos = bot:getPos()
    local giver = #givers > 0 and pick(givers) or { x = pos.x, y = pos.y, z = pos.z, zone = bot:getZoneID() }
    local item = {
        name = name, giver = giver, file = 'special:' .. name,
        obj = { begin = function() end, complete = function(_, b) done(b) return true end },
    }
    BotHeal(bot:getID(), false)
    st.life, st.task = nil, nil
    st.quest = { kind = 'quest', item = item, errand = true, phase = 'talk', at = now() + rnd(TALK_TIME[1], TALK_TIME[2]) + 6 }
    note(string.format('%s starts %s (Lv%d)', bot:getName(), name, bot:getMainLvl()))
    return goTo(bot, giver)
end

local function finish(bot, st)
    local qs = st.quest
    st.quest = nil
    local item = qs.item
    local id = bot:getID()
    local rankBefore = 1
    pcall(function()
        rankBefore = bot:getRank(nationOf(bot))
    end)
    local ok, done = pcall(function()
        return item.obj:complete(bot)
    end)
    if not ok or not done then
        gaveUp[id .. ':' .. item.file] = now()
        note(string.format('%s could not finish "%s" (%s)', bot:getName(), item.name, ok and 'no room for the reward' or tostring(done)))
        return
    end

    -- the rank ups the scripts do in their cutscenes: after x-3 (San d'Oria 1-3 / 2-3, Bastok, Windurst alike)
    if item.line then
        bot:setCharVar('[Bot]ML_' .. item.line, math.max(lineDone(bot, item.line), item.idx))
    end

    if qs.kind == 'mission' and not item.line and item.num == 3 then
        pcall(function()
            if bot:getRank(nationOf(bot)) < item.tier + 1 then
                bot:setRank(item.tier + 1)
            end
        end)
    end

    bot:setCharVar('[Bot]Quests', bot:getCharVar('[Bot]Quests') + 1)
    local rankNow = rankBefore
    pcall(function()
        rankNow = bot:getRank(nationOf(bot))
    end)
    local line
    if rankNow > rankBefore then
        line = pick({ 'rank ' .. rankNow .. ' now :)', 'finally rank ' .. rankNow .. '!', 'woo rank ' .. rankNow })
    elseif item.line and item.idx == #(Q.catalog().lines[item.line] or {}) then
        local story = ({ zilart = 'Zilart', cop = 'CoP', toau = 'ToAU' })[item.line]
        line = pick({ 'FINALLY finished ' .. story .. ' missions!!', story .. ' done, what a ride', 'beat the last ' .. story .. ' mission :)' })
    elseif item.line then
        line = pick({ item.label .. ' ' .. item.name .. ' done', 'finished ' .. item.name .. '!', 'one more ' .. (item.line == 'toau' and 'ToAU mission' or item.line == 'cop' and 'CoP mission' or 'ZM') .. ' down', 'that ' .. item.label .. ' fight was rough lol' })
    elseif qs.kind == 'mission' then
        line = pick({ 'mission done', 'finished ' .. item.name .. '!', 'one more mission down' })
    else
        line = pick({ 'finally done with ' .. item.name .. '!', item.name .. ' done :)', 'quest complete' })
    end

    note(string.format('%s completed the %s "%s"%s', bot:getName(), qs.kind, (item.label and (item.label .. ' ') or '') .. item.name, rankNow > rankBefore and (' - rank ' .. rankNow) or ''))
    if xi.bots and xi.bots.diary and not Q.quiet then
        xi.bots.diary(bot, rankNow > rankBefore and ('made nation rank ' .. rankNow) or ('finished the ' .. qs.kind .. ' ' .. item.name), rankNow > rankBefore)
    end
    if math.random() < 0.6 and not Q.quiet then
        BotChat(id, 0, line)
    end
end

-- for bots_growth.lua: a quest or its next mission done while you were away (rewards as usual); its name or nil
function Q.completeNow(bot, preferMission)
    local m = nextMission(bot, preferMission)
    local q = (not m or (not preferMission and math.random() < 0.5)) and pickQuest(bot) or nil
    local item, kind = q or m, q and 'quest' or 'mission'
    if not item then
        return nil
    end

    pcall(function()
        item.obj:begin(bot)
    end)
    local st = { quest = { kind = kind, item = item } }
    local before = bot:getCharVar('[Bot]Quests')
    Q.quiet = true
    pcall(finish, bot, st)
    Q.quiet = false
    return bot:getCharVar('[Bot]Quests') > before and item.name or nil
end

-- one second of a quest trip; returns 'zoning' or nil
function Q.think(bot, st)
    local qs = st.quest
    local t = now()
    local giver = qs.item.giver
    if bot:isDead() then
        gaveUp[bot:getID() .. ':' .. qs.item.file] = t
        st.quest = nil
        return
    end

    if bot:getZoneID() ~= giver.zone then
        if qs.phase == 'errand' then
            qs.phase = 'back' -- (the errand hunt ended without us: it died or was sent home)
        end

        return goTo(bot, giver) == 'zoning' and 'zoning' or nil
    end

    if qs.phase == 'errand' and not st.hunt then
        qs.phase, qs.at = 'back', t + rnd(TALK_TIME[1], TALK_TIME[2])
    end

    if BotIsMoving(bot:getID()) or t < qs.at then
        return
    end

    if qs.phase == 'talk' then
        if qs.errand and hunt then
            qs.phase = 'errand'
            local minutes = rnd(ERRAND_MIN[1], ERRAND_MIN[2])
            if hunt.start(bot, st, minutes) then
                return 'zoning'
            end

            if st.hunt then
                return
            end

            qs.phase = 'back' -- no camp for its level right now: it did the errand in town
        else
            qs.phase = 'back'
        end

        qs.at = t + rnd(TALK_TIME[1], TALK_TIME[2])
        return
    end

    if qs.phase == 'back' then
        finish(bot, st)
    end
end

-- the errand hunt is over (hunt returned 'home'): back to the questgiver instead of home
function Q.afterHunt(bot, st)
    local qs = st.quest
    if not qs or qs.phase ~= 'errand' then
        return nil
    end

    qs.phase = 'back'
    qs.at = now() + rnd(TALK_TIME[1], TALK_TIME[2])
    return goTo(bot, qs.item.giver)
end

function Q.drop(bot, st)
    st.quest = nil
end

function Q.describe(st)
    local qs = st.quest
    if not qs then
        return nil
    end

    local where = ({ talk = 'at the questgiver', errand = 'out doing it', back = 'reporting back' })[qs.phase] or qs.phase
    return string.format('%s "%s" (%s)', qs.kind, qs.item.name, where)
end

-- its place in the expansion stories, for its chat: "Zilart 5/17, CoP 2-3" (or nil)
function Q.story(bot)
    local parts = {}
    for _, line in ipairs(LINES) do
        local list = Q.catalog().lines[line.key] or {}
        local done = lineDone(bot, line.key)
        if done > 0 and #list > 0 then
            local name = ({ zilart = 'Zilart', cop = 'CoP', toau = 'ToAU' })[line.key]
            parts[#parts + 1] = done >= #list and (name .. ' finished') or string.format('%s %d of %d', name, done, #list)
        end
    end

    return #parts > 0 and table.concat(parts, ', ') or nil
end

function Q.summary(bot)
    local rank = 1
    pcall(function()
        rank = bot:getRank(nationOf(bot))
    end)
    return rank, bot:getCharVar('[Bot]Quests')
end

return Q
