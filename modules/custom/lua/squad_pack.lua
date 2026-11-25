-----------------------------------
-- XI: Forever Offline: squad mates' lines from the dialogue pack (the Living World pack's squad section, built into
-- bots_dialogue_data.lua by C:\FFXISOLO\dialogue\build_dialogue.py). squad.lua loads it as xi.squad.pack.
--
-- These come on top of each mate's own voice lines (squad_dialogue.lua and the launcher's Squad tab), which still
-- come first most of the time:
--   - you call a mate: a first-meeting line for a brand-new mate (level 5 or lower, never called before), "we go
--     again" after you were knocked out, a word when you changed jobs, "welcome back" after 3+ days (mates you have
--     levelled to 50+), or now and then a line that fits how long you have been together, its race or its role;
--     a short scene once a tank, a healer and a damage dealer are out together;
--   - a mate is knocked out: now and then a pack line instead of its voice line;
--   - !squad camp / camp off: a short acknowledgement; !squad dismiss <slot>: a goodbye;
--   - fights and quiet moments (calls by role at the pull, low HP or MP, after a fight, idle talk in town and in the
--     field, a scene at camp rest or a hard fight): only while the squad chat AI is quiet (squad chat off, or the AI
--     has said nothing for 5 minutes), so the AI and these lines never talk over each other.
-- Nothing claims what did not happen: lines follow real events; the role comes from the mate's job, race and
-- gender from its look, and how long you have been together from its own level (it only levels fighting with you).
-- Some lines are for one voice only (bold, calm, cheerful or gruff: the mate's voice from squad_dialogue.lua), so a
-- gruff mate never says a cheerful line.
-- State (who was called when, your last job): squad_pack_state.txt.
-----------------------------------
local P = {}

local DATA_PATH  = 'modules/custom/lua/bots_dialogue_data'
local STATE_FILE = 'modules/custom/lua/squad_pack_state.txt'
local DAY        = 86400
local AI_QUIET   = 300               -- seconds without an AI line before written fight/idle lines may play
local IDLE_EVERY = { 300, 600 }      -- seconds between two idle moments (each one: a line or nothing)
local LINE_GAP   = { ambient = 6 * 3600, event = 1800 }

local ROLE  = { [7] = 'tank', [13] = 'tank', [3] = 'healer', [5] = 'hybrid', [10] = 'support', [17] = 'support' }
local RACE  = { 'Hume', 'Hume', 'Elvaan', 'Elvaan', 'Tarutaru', 'Tarutaru', 'Mithra', 'Galka' }
local SEX   = { 'male', 'female', 'male', 'female', 'male', 'female', 'female', 'male' }
-- event lines reuse the line used longest ago; ambient ones stay quiet when all were used lately
local EVENT = { ['s.recruit'] = true, ['s.ack_hold'] = true, ['s.ack_follow'] = true, ['s.ack_pull'] = true, ['s.down'] = true,
                ['s.bench'] = true, ['s.jobchange'] = true, ['s.jobchange_whm'] = true, ['s.reunion'] = true, ['s.wipe'] = true,
                ['s.lowhp'] = true, ['s.lowmp'] = true, ['s.battle'] = true }

local data, byTag, scenesByTag
local loaded = false
local state = { seen = {}, call = {}, job = {}, died = {}, scene = {}, line = {} }
local dirty, savedAt = false, 0
local mates = {}   -- [name] = { race, gender, role, fam }
local run = {}     -- [player id] = runtime: engaged, last line, per-mate timers, idle, queue
local tickAt = {}  -- [player id] = last second handled

local function now()
    return os.time()
end

local function rnd(a, b)
    return math.random(a, b)
end

local function pick(list)
    if not list or #list == 0 then
        return nil
    end

    return list[rnd(1, #list)]
end

-----------------------------------
-- data and state
-----------------------------------
local function loadState()
    local f = io.open(STATE_FILE, 'r')
    if not f then
        return
    end

    for line in f:lines() do
        local kind, key, value = line:match('^(%a+)\t([^\t]+)\t(%d+)$')
        if kind and state[kind] then
            state[kind][key] = tonumber(value)
        end
    end

    f:close()
end

local function saveState()
    local t = now()
    local rows = {}
    for kind, tbl in pairs(state) do
        for key, value in pairs(tbl) do
            -- line and scene times only matter for a few days; the rest is kept
            if not ((kind == 'line' or kind == 'scene' or kind == 'died') and t - value > 7 * DAY) then
                rows[#rows + 1] = kind .. '\t' .. key .. '\t' .. value
            end
        end
    end

    local f = io.open(STATE_FILE .. '.tmp', 'w')
    if f then
        f:write(table.concat(rows, '\n') .. '\n')
        f:close()
        os.remove(STATE_FILE)
        os.rename(STATE_FILE .. '.tmp', STATE_FILE)
    end

    dirty, savedAt = false, t
end

local function ensure()
    if loaded then
        return data ~= nil
    end

    loaded = true
    local ok, d = pcall(require, DATA_PATH)
    if not ok or type(d) ~= 'table' or type(d.squad) ~= 'table' then
        print('[squad] pack lines are off: bots_dialogue_data.lua has no squad lines (' .. tostring(ok and 'no squad section' or d) .. ')')
        return false
    end

    data = d.squad
    byTag, scenesByTag = {}, {}
    for _, l in ipairs(data.lines or {}) do
        for _, t in ipairs(l.t or {}) do
            byTag[t] = byTag[t] or {}
            table.insert(byTag[t], l)
        end
    end

    for _, s in ipairs(data.scenes or {}) do
        for _, t in ipairs(s.t or {}) do
            scenesByTag[t] = scenesByTag[t] or {}
            table.insert(scenesByTag[t], s)
        end
    end

    pcall(loadState)
    savedAt = now()
    return true
end

function P.available()
    return ensure()
end

-----------------------------------
-- who a mate is
-----------------------------------
local function famOf(level)
    if (level or 1) >= 50 then
        return 'trusted'
    elseif (level or 1) >= 20 then
        return 'steady'
    end

    return 'new'
end

function P.roleOf(jobId)
    return ROLE[jobId or 0] or 'damage'
end

-- a mate's voice, chosen the way squad.lua chooses it: voiceByName in squad_dialogue.lua, or else from the name
local voiceData
function P.voiceOf(name)
    if voiceData == nil then
        local ok, d = pcall(require, 'modules/custom/lua/squad_dialogue')
        voiceData = ok and type(d) == 'table' and d or false
    end

    if not voiceData or type(name) ~= 'string' or name == '' then
        return nil
    end

    local chosen = voiceData.voiceByName and voiceData.voiceByName[name]
    if chosen and voiceData.voices and voiceData.voices[chosen] then
        return chosen
    end

    local order = voiceData.voiceOrder or {}
    if #order == 0 then
        return nil
    end

    local sum = 0
    for i = 1, #name do
        sum = sum + string.byte(name, i)
    end

    return order[(sum % #order) + 1]
end

-- remember what is true about a mate (race and gender from its look; its role from its job; familiarity from its level)
function P.remember(name, raceCode, jobId, ownLevel)
    local m = mates[name] or {}
    m.race = RACE[raceCode or 0]
    m.gender = SEX[raceCode or 0]
    m.role = P.roleOf(jobId)
    m.fam = famOf(ownLevel)
    m.voice = P.voiceOf(name)
    mates[name] = m
    return m
end

local function fits(list, value)
    if not list or #list == 0 then
        return true
    end

    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end

    return false
end

-- one line for this mate and use; nil when none fits (or every fitting ambient line was used lately)
function P.line(tag, name)
    if not ensure() then
        return nil
    end

    local m = mates[name] or {}
    local voice = m.voice or P.voiceOf(name)
    local t = now()
    local gap = EVENT[tag] and LINE_GAP.event or LINE_GAP.ambient
    local fresh, all = {}, {}
    for _, l in ipairs(byTag[tag] or {}) do
        if fits(l.roles, m.role) and fits(l.races, m.race) and fits(l.genders, m.gender) and fits(l.fam, m.fam) and
            fits(l.voices, voice) then
            local last = state.line[l.id] or 0
            all[#all + 1] = { l = l, last = last }
            if t - last >= gap then
                fresh[#fresh + 1] = all[#all]
            end
        end
    end

    local chosen = pick(fresh)
    if not chosen and EVENT[tag] and #all > 0 then
        table.sort(all, function(a, b) return a.last < b.last end)
        chosen = all[1]
    end

    if not chosen then
        return nil
    end

    state.line[chosen.l.id] = t
    dirty = true
    return (chosen.l.text:gsub('{name}', name))
end

-----------------------------------
-- saying it (party chat, as the mate)
-----------------------------------
local function R(player)
    local id = player:getID()
    run[id] = run[id] or { queue = {}, at = {}, hpLow = {}, mpAt = {}, nextIdle = now() + rnd(IDLE_EVERY[1], IDLE_EVERY[2]) }
    return run[id]
end

local function sayNow(player, name, text)
    if text and text ~= '' then
        player:printToPlayer(text, 4, name)
        local r = R(player)
        r.last = now()
        r.at[name] = now()
    end
end

local function sayLater(player, name, text, delay)
    if not text or text == '' then
        return 0
    end

    local r = R(player)
    local at = now() + (delay or 0)
    table.insert(r.queue, { at = at, name = name, text = text })
    return at
end

-- the squad mates you have out now
function P.activeMates(player)
    local out = {}
    local ok, party = pcall(function() return player:getPartyWithTrusts() end)
    for _, member in pairs(ok and party or {}) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') > 0 and member:isAlive() and
            (type(xi.squad.mine) ~= 'function' or xi.squad.mine(player, member)) then
            out[#out + 1] = member
        end
    end

    return out
end

-- a scene: each role goes to a different mate who has it; skipped when a role has nobody
local function playScene(player, tag, active, delay)
    local t = now()
    for _, s in ipairs(scenesByTag[tag] or {}) do
        if t - (state.scene[s.id] or 0) >= (s.cd or 60) * 60 then
            local cast, used = {}, {}
            local ok = true
            for _, role in ipairs(s.roles) do
                local who
                for _, mob in ipairs(active) do
                    local n = mob:getPacketName()
                    local m = mates[n]
                    if not used[n] and m and (m.role == role or (role == 'support' and m.role ~= 'healer')) then
                        who = n
                        break
                    end
                end

                if not who then
                    ok = false
                    break
                end

                cast[role], used[who] = who, true
            end

            if ok then
                local at = delay or 0
                for _, line in ipairs(s.l) do
                    local done = sayLater(player, cast[line[1]], line[2], at)
                    at = done - now() + rnd(4, 9)
                end

                state.scene[s.id] = t
                dirty = true
                return true
            end
        end
    end

    return false
end

-----------------------------------
-- events from squad.lua
-----------------------------------
-- you called a mate: true when it said a pack line (squad.lua then skips its voice line)
function P.onCall(player, trust, name, raceCode, jobId, ownLevel)
    if not ensure() then
        return false
    end

    local m = P.remember(name, raceCode, jobId, ownLevel)
    local t = now()
    local pname = player:getName()
    local key = pname .. '|' .. name
    local firstSeen, lastCall = state.seen[key], state.call[key]
    state.call[key] = t
    if not firstSeen then
        state.seen[key] = t
    end

    local myJob = player:getMainJob()
    local lastJob = state.job[pname]
    state.job[pname] = myJob
    local died = state.died[pname]
    local wipe = died and t - died < 1800
    if wipe then
        state.died[pname] = nil
    end

    dirty = true
    local r = R(player)
    if not r.check then
        r.check = { at = t + 8, gap = lastCall and (t - lastCall) or 0, wipe = wipe }
    end

    local text
    if not firstSeen and (ownLevel or 99) <= 5 then
        text = (math.random() < 0.25 and P.line('s.gender', name)) or P.line('s.recruit', name)
    elseif wipe and math.random() < 0.7 then
        text = P.line('s.wipe', name)
    elseif lastJob and lastJob ~= myJob and math.random() < 0.6 then
        text = (myJob == 3 and m.role ~= 'healer' and P.line('s.jobchange_whm', name)) or P.line('s.jobchange', name)
    elseif lastCall and t - lastCall >= 3 * DAY and m.fam == 'trusted' and math.random() < 0.7 then
        text = P.line('s.reunion', name)
    elseif math.random() < 0.2 then
        text = P.line('s.bond', name)
    elseif math.random() < 0.1 then
        text = P.line('s.race', name)
    end

    if text then
        sayNow(player, name, text)
        if dirty and t - savedAt >= 60 then
            pcall(saveState)
        end

        return true
    end

    return false
end

-- a mate was knocked out: true when it said a pack line (squad.lua then skips its voice line)
function P.onDown(mob)
    if not ensure() or math.random() > 0.3 then
        return false
    end

    local master = mob:getMaster() or (GetPlayerByID and GetPlayerByID(mob:getLocalVar('MASTER_ID')))
    if not master then
        return false
    end

    local text = P.line('s.down', mob:getPacketName())
    if text then
        sayNow(master, mob:getPacketName(), text)
        return true
    end

    return false
end

-- you were knocked out (the next call within 30 minutes: "we go again")
function P.onPlayerDeath(player)
    state.died[player:getName()] = now()
    dirty = true
end

-- !squad camp (hold) / camp off (follow)
function P.onCommand(player, kind)
    if not ensure() or math.random() > 0.7 then
        return
    end

    local mob = pick(P.activeMates(player))
    if mob then
        local name = mob:getPacketName()
        sayLater(player, name, P.line('s.ack_' .. kind, name), 1)
    end
end

-- !squad dismiss <slot>
function P.onBench(player, name)
    if ensure() and math.random() < 0.6 then
        sayNow(player, name, P.line('s.bench', name))
    end
end

-----------------------------------
-- once a second per player (from each mate's TICK in squad.lua)
-----------------------------------
local function pct(entity, cur, max)
    local ok, a, b = pcall(function() return entity[cur](entity), entity[max](entity) end)
    if ok and b and b > 0 then
        return math.floor(a * 100 / b)
    end

    return 100
end

local function inTown(player)
    local ok, mask = pcall(function() return player:getZone():getTypeMask() end)
    return ok and type(mask) == 'number' and mask % 2 == 1
end

local function free(r, name, every)
    return now() - (r.at[name] or 0) >= every
end

function P.tick(mob)
    if not ensure() then
        return
    end

    local player = mob:getMaster()
    if not player or player:getObjType() ~= xi.objType.PC then
        return
    end

    local pid = player:getID()
    local t = now()
    if tickAt[pid] == t then
        return
    end

    tickAt[pid] = t
    local r = R(player)
    local active = P.activeMates(player)
    local names = {}
    for _, m in ipairs(active) do
        names[m:getPacketName()] = m
    end

    -- lines whose time has come (from a mate still out)
    for i = #r.queue, 1, -1 do
        local q = r.queue[i]
        if t >= q.at then
            table.remove(r.queue, i)
            if names[q.name] then
                sayNow(player, q.name, q.text)
            end
        end
    end

    -- a few seconds after a call: a scene if the right mates are out
    if r.check and t >= r.check.at then
        local c = r.check
        r.check = nil
        if #active >= 3 and c.wipe then
            playScene(player, 's.scene_wipe', active, 2)
        elseif #active >= 2 and c.gap >= 3 * DAY then
            playScene(player, 's.scene_return', active, 2)
        elseif #active >= 3 and not state.scene['first|' .. player:getName()] then
            if playScene(player, 's.scene_first', active, 2) then
                state.scene['first|' .. player:getName()] = t
            end
        end
    end

    -- you changed jobs while they were out
    local job = player:getMainJob()
    local pname = player:getName()
    if #active > 0 and state.job[pname] and state.job[pname] ~= job and not player:isEngaged() then
        local mob1 = pick(active)
        local n = mob1:getPacketName()
        local text = (job == 3 and (mates[n] or {}).role ~= 'healer' and P.line('s.jobchange_whm', n)) or P.line('s.jobchange', n)
        sayLater(player, n, text, 2)
    end

    if #active > 0 then
        state.job[pname] = job
    end

    if dirty and t - savedAt >= 300 then
        pcall(saveState)
    end

    -- fights and quiet moments: only while the AI is quiet
    local aiAt = xi.squad and tonumber(xi.squad.aiSaidAt) or 0
    local aiQuiet = player:getCharVar('SQUAD_CHAT_OFF') == 1 or t - aiAt >= AI_QUIET
    if not aiQuiet or #active == 0 then
        r.engaged = player:isEngaged()
        return
    end

    local engaged = player:isEngaged()
    local partyFree = t - (r.last or 0) >= 20
    if engaged and not r.engaged then
        r.closeCall = nil -- (a new fight: an old close call does not count)
        -- the pull: one mate calls it now and then
        if partyFree and math.random() < 0.25 then
            local m = pick(active)
            local n = m:getPacketName()
            if free(r, n, 45) then
                sayLater(player, n, P.line('s.battle', n), rnd(1, 3))
            end
        end
    elseif engaged then
        for _, m in ipairs(active) do
            local n = m:getPacketName()
            local hp = pct(m, 'getHP', 'getMaxHP')
            if hp < 30 and not r.hpLow[n] then
                r.hpLow[n] = true
                r.closeCall = true -- (2026-11-23) a close fight: s.scene_after may play when it ends
                if math.random() < 0.5 and free(r, n, 60) then
                    if #active >= 3 and math.random() < 0.3 and playScene(player, 's.scene_lowhp', active, 1) then
                        break
                    end

                    sayLater(player, n, P.line('s.lowhp', n), 1)
                end
            elseif hp > 50 then
                r.hpLow[n] = nil
            end

            if (mates[n] or {}).role == 'healer' and pct(m, 'getMP', 'getMaxMP') < 20 and t - (r.mpAt[n] or 0) >= 180 then
                r.mpAt[n] = t
                if math.random() < 0.5 then
                    sayLater(player, n, P.line('s.lowmp', n), 1)
                end
            end
        end
    elseif r.engaged and player:isAlive() then
        -- the fight just ended
        local close = r.closeCall
        r.closeCall = nil
        if close and partyFree and #active >= 2 and math.random() < 0.4 and playScene(player, 's.scene_after', active, 3) then
            -- (a short scene after a close call: J-NULL's "A Close Call", writing contribution #001)
        elseif partyFree and math.random() < 0.15 then
            local m = pick(active)
            local n = m:getPacketName()
            local at = sayLater(player, n, P.line('s.after', n), rnd(2, 4))
            if at > 0 and #active >= 2 and math.random() < 0.2 then
                local others = {}
                for _, o in ipairs(active) do
                    if o:getPacketName() ~= n then
                        others[#others + 1] = o
                    end
                end

                local o = pick(others):getPacketName()
                sayLater(player, o, P.line('s.reply', o), at - t + rnd(3, 6))
            end
        end
    else
        -- resting with you: now and then a short scene
        local resting = xi.animation and player:getAnimation() == xi.animation.HEALING
        if resting and not r.resting then
            r.resting = true
            if #active >= 2 and math.random() < 0.35 then
                playScene(player, 's.scene_rest', active, 3)
            end
        elseif not resting then
            r.resting = nil
        end

        -- a quiet moment: a line now and then
        if t >= r.nextIdle then
            r.nextIdle = t + rnd(IDLE_EVERY[1], IDLE_EVERY[2])
            if partyFree and not resting then
                local m = pick(active)
                local n = m:getPacketName()
                local roll = math.random()
                local text
                if roll < 0.15 then
                    text = P.line('s.race', n)
                elseif roll < 0.25 and #active >= 2 and not inTown(player) then
                    text = P.line('s.banter', n)
                elseif roll < 0.75 then
                    text = P.line(inTown(player) and 's.idle_town' or 's.idle_field', n)
                end

                sayLater(player, n, text, 0)
            end
        end
    end

    r.engaged = engaged
end

function P.save()
    if dirty then
        pcall(saveState)
    end
end

-- for the tests
P._reset = function()
    state = { seen = {}, call = {}, job = {}, died = {}, scene = {}, line = {} }
    mates, run, tickAt = {}, {}, {}
    voiceData = nil
end
P._run = function(player)
    return R(player)
end

return P
