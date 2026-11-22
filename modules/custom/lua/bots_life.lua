-----------------------------------
-- FFXI Offline: bot players, step 4.2 - the roster and town life. Used by bots.lua (not listed in init.txt).
--
-- The roster: up to 100 bot characters (launcher: CONFIG > Rates > "Bot roster"), made a few at a time while
-- you play, all level 1, generated names (the same name maker as the crowds), random race / face / job / nation.
-- Online: about 50 at a time ("Bots online"). While you are on, each bot plays a session of 20-120 minutes, logs
-- out, and another one logs in a little later - so /sea changes over time. They log in at a Home Point, the
-- Auction House or a shop of their own nation's towns (the crowds' spots) and live there: rest by the crystal,
-- browse the AH, stand around, walk between spots, emote, say a word when you are near.
-- A bot in your party is never logged out by the schedule.
-----------------------------------
local L = {}

local CONFIG_PATH = 'modules/custom/lua/bots_config'
local DATA_PATH   = 'modules/custom/lua/crowds_data'

local MAX_ROSTER, MAX_ONLINE = 600, 550
local CREATE_EVERY  = 1     -- seconds between two new characters while the roster fills
local FILL_EVERY    = { 1, 3 }      -- seconds between log ins while the online count is far below the target
local REFILL_EVERY  = { 20, 90 }    -- ... and once it is close (a replacement for someone who logged out)
local SESSION_MIN   = { 20, 120 }   -- minutes a bot stays on
local WALK_RANGE    = 80    -- yalms: walks go to a spot this close when there is one
local AWAY_HOME     = { 120, 300 }  -- seconds alone outside a town before a bot goes home

local HOME = { [0] = { 230, 231, 232 }, [1] = { 234, 235, 236 }, [2] = { 238, 239, 240, 241 } }
local NATION_OF = {}
for nation, zones in pairs(HOME) do
    for _, z in ipairs(zones) do
        NATION_OF[z] = nation
    end
end

local JOB_NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP' }
local RACE_WEIGHT = { 16, 14, 14, 10, 14, 12, 12, 8 }
local KIND_WEIGHT = { rest = 40, ah = 25, idle = 35 }
local EMOTES = { 'WAVE', 'LAUGH', 'THINK', 'YES', 'NO', 'BOW', 'CHEER', 'CLAP', 'SMILE', 'DOUBT', 'HUH', 'SIGH', 'STRETCH', 'GRIN', 'JOY' }

local cfg = { enabled = true, roster = 100, online = 50 }
local data = nil
local sessions = {}     -- [bot id] = os.time() the session ends
local offSince = {}     -- [bot id] = os.time() it logged out
local takenSpot = {}    -- ['zone:index'] = bot id
local perZone = {}      -- [zone id] = online bots there (refreshed every second)
local nextCreate, nextLogin, nextSay = 0, 0, 0
local lastList = {}
local created = 0

local function rnd(a, b)
    return math.random(a, b)
end

local function now()
    return os.time()
end

-----------------------------------
-- settings, spots, names
-----------------------------------
-- bots that stopped playing for good (they keep their character, they just never log in again)
local RETIRED_PATH = 'modules/custom/lua/bots_retired.lua'
-- The population grows on its own, like a server getting known: 25 new adventurers a day up to about 1000. From there
-- fewer join each day and some stop playing for good, so it settles around 1100 (1000-1200) and drifts there.
local GROW_PER_DAY = 25     -- new adventurers a day while it is under SETTLE_FROM (the launcher "Bot roster" is where it starts)
local SETTLE_FROM  = 1000   -- from here: fewer join, and people start to quit
local HARD_CAP     = 1250   -- never more than this
local RETIRE_SHARE = 0.0065 -- of the active bots, once a day, from SETTLE_FROM on (about 7 a day at 1100)
local ONLINE_SHARE = 0.6    -- online at a time: this share of the population, at most the launcher's "Bots online"
local POP_CAP      = SETTLE_FROM -- (older name, kept for the tests)
local retired = nil

local function loadRetired()
    if retired then
        return retired
    end

    retired = {}
    local f = io.open(RETIRED_PATH, 'r')
    if f then
        for id in (f:read('*a') or ''):gmatch('%[(%d+)%]') do
            retired[tonumber(id)] = true
        end

        f:close()
    end

    return retired
end

local function saveRetired()
    local f = io.open(RETIRED_PATH, 'w')
    if not f then
        return
    end

    f:write('-- Bot players who stopped playing (bots_life.lua). Delete a line to bring one back.\nreturn {\n')
    for id in pairs(retired) do
        f:write(string.format('    [%d] = true,\n', id))
    end

    f:write('}\n')
    f:close()
end

-- the population it is heading for: the launcher roster, grown by GROW_PER_DAY each real day, at most POP_CAP
function L.target()
    if cfg.roster <= 0 then
        return 0
    end

    local pop = 0
    pcall(function()
        pop = GetServerVariable('[Bots]Population')
    end)
    return math.min(HARD_CAP, math.max(cfg.roster, pop or 0))
end

-- new adventurers in one day for a population of pop: 25 while it is small, fewer and fewer above SETTLE_FROM
local function joinsFor(pop)
    if pop < SETTLE_FROM then
        return GROW_PER_DAY
    end

    return math.max(2, math.floor(12 * (HARD_CAP - pop) / (HARD_CAP - SETTLE_FROM) + 0.5))
end

L._joinsFor = joinsFor

-- how many bots are on at a time: a share of the population, at most the launcher setting (so a growing server gets busier)
function L.onlineTarget(total)
    return math.min(cfg.online, math.floor((total or 0) * ONLINE_SHARE + 0.5))
end

-- once a (real) day: new adventurers join and, once the server is big, some stop playing (days it was off count too)
local function turnover(list)
    local today = math.floor(os.time() / 86400)
    local last = GetServerVariable('[Bots]TurnoverDay')
    if last == today then
        return
    end

    SetServerVariable('[Bots]TurnoverDay', today)
    local before = L.target()
    local days = (last > 0 and today > last) and math.min(365, today - last) or 0
    local active = 0
    for id in pairs(list) do
        if not loadRetired()[id] then
            active = active + 1
        end
    end

    -- day by day: who joins, who quits (the quitters are picked below, all at once)
    local pop, joined, quits = before, 0, 0
    for _ = 1, days do
        local j = joinsFor(pop)
        local q = pop >= SETTLE_FROM and math.floor(pop * RETIRE_SHARE + math.random()) or 0
        joined, quits = joined + j, quits + q
        pop = math.max(0, math.min(HARD_CAP, pop + j - q))
    end

    SetServerVariable('[Bots]Population', pop)
    if days > 0 then
        print(string.format('[bots] %d new adventurers joined and %d stopped playing (population %d, settles around 1100)', joined, quits, pop))
    end

    if quits <= 0 or active < SETTLE_FROM then
        return -- (still growing: nobody quits yet)
    end

    local candidates = {}
    for id, row in pairs(list) do
        -- (a bot on a real player's friend list never stops playing: bots_friends.lua sets L.keep)
        if not row.online and not loadRetired()[id] and not (L.keep and L.keep(id)) then
            candidates[#candidates + 1] = id
        end
    end

    local n = quits
    for _ = 1, n do
        if #candidates == 0 then
            break
        end

        local id = table.remove(candidates, math.random(1, #candidates))
        retired[id] = true
        print(string.format('[bots] %s stopped playing (a new adventurer will join)', (list[id] and list[id].name) or tostring(id)))
    end

    if n > 0 then
        saveRetired()
    end
end

function L.loadConfig()
    package.loaded[CONFIG_PATH] = nil
    local ok, c = pcall(require, CONFIG_PATH)
    if ok and type(c) == 'table' then
        cfg.enabled = c.enabled ~= false
        cfg.roster = math.max(0, math.min(MAX_ROSTER, tonumber(c.roster) or 100))
        cfg.online = math.max(0, math.min(MAX_ONLINE, tonumber(c.online) or 50))
        cfg.growth = (c.growth == 'off' or c.growth == 'fast') and c.growth or 'realistic'
        cfg.passLoot = c.pass_loot ~= false
    end

    -- (2026-11-21) read by bots.cpp: bot players in a party with you pass every drop right away
    BOTS_PASS_LOOT = cfg.passLoot ~= false

    return cfg
end

function L.config()
    return cfg
end

local function crowdsData()
    if data == nil then
        local ok, d = pcall(require, DATA_PATH)
        data = (ok and type(d) == 'table') and d or { zones = {} }
    end

    return data
end

-- the crowds' spots (Home Points, Auction House, shops, marked spots), checked on the walking map
local function spotsOf(zoneId)
    if xi.crowds and xi.crowds.zoneSpots then
        local ok, list = pcall(xi.crowds.zoneSpots, zoneId)
        if ok and type(list) == 'table' then
            return list
        end
    end

    local zd = crowdsData().zones[zoneId]
    return zd and zd.spots or {}
end

local function weighted(weights)
    local total = 0
    for _, w in pairs(weights) do
        total = total + w
    end

    local roll = math.random() * total
    for k, w in pairs(weights) do
        roll = roll - w
        if roll <= 0 then
            return k
        end
    end

    return next(weights)
end

local function usedNames()
    local used = {}
    for _, row in pairs(lastList) do
        if row.name then
            used[row.name] = true
        end
    end

    return used
end

local SYL1 = { 'Al', 'Bra', 'Cel', 'Dar', 'El', 'Fa', 'Gi', 'Ha', 'Is', 'Jo', 'Ka', 'Le', 'Ma', 'Ne', 'Or', 'Pa', 'Ri', 'Sa', 'Te', 'Va' }
local SYL2 = { 'ran', 'lia', 'dor', 'mir', 'ten', 'sha', 'rik', 'nel', 'vos', 'ria', 'ton', 'na' }

local function makeName(race, used)
    if xi.crowds and xi.crowds.makeName then
        local ok, name = pcall(xi.crowds.makeName, race, used)
        if ok and type(name) == 'string' and name:match('^%u%l+$') and #name >= 3 and #name <= 15 then
            return name
        end
    end

    for _ = 1, 50 do
        local name = SYL1[rnd(1, #SYL1)] .. SYL2[rnd(1, #SYL2)]
        if not used[name] then
            used[name] = true
            return name
        end
    end

    return nil
end

-- a random free spot in one of a nation's towns (bigger towns more often)
local function homeSpot(nation)
    local zones = HOME[nation] or HOME[0]
    local weights = {}
    for _, z in ipairs(zones) do
        local n = #spotsOf(z)
        if n > 0 then
            weights[z] = n
        end
    end

    local zoneId = next(weights) and weighted(weights) or zones[1]
    local spots = spotsOf(zoneId)
    if #spots == 0 then
        return zoneId, nil
    end

    return zoneId, spots[rnd(1, #spots)]
end

-----------------------------------
-- the roster and the log in / log out schedule (xi.bots.onTick, once a second while you play)
-----------------------------------
local function realPlayerParty(bot)
    for _, member in pairs(bot:getParty() or {}) do
        if member:getObjType() == xi.objType.PC and not BotIsBot(member:getID()) then
            return true
        end
    end

    return false
end

-- force: the roster was turned down or off (then only your own party keeps a bot on)
local function canLeave(id, force)
    -- (2026-11-21) a bot on a real player's friend list stays online while bots are on (only "bots off" sends it home)
    if cfg.enabled and L.keep and L.keep(id) then
        return false
    end

    local bot = GetPlayerByID(id)
    if not bot then
        return true
    end

    -- a bot in a bot party stays until that party is over: its session ending used to log the leader or a
    -- member out in the middle of a camp
    if not force and bot:getPartySize() > 1 then
        return false
    end

    return not realPlayerParty(bot) and not bot:isEngaged()
end

local function createOne()
    local used = usedNames()
    local race = weighted(RACE_WEIGHT)
    local name = makeName(race, used)
    if not name then
        return
    end

    local nation = rnd(0, 2)
    local zoneId, spot = homeSpot(nation)
    if not spot then
        return
    end

    local id = BotCreate(name, race, rnd(0, 15), rnd(1, 6), nation, zoneId, spot.x, spot.y, spot.z)
    if id and id ~= 0 then
        created = created + 1
        offSince[id] = 0
    end
end

local function logIn(id, row)
    -- logs in at a spot of its own nation's towns (a bot left in the field went home while it was away)
    local nation = NATION_OF[row.zone or 0] or rnd(0, 2)
    local zoneId, spot = homeSpot(nation)
    if spot then
        local px, py, pz = spot.x + (math.random() - 0.5) * 1.5, spot.y, spot.z + (math.random() - 0.5) * 1.5
        if xi.navguard then
            px, py, pz = xi.navguard.spot(zoneId, px, py, pz, spot) -- (beside its spot, never in the wall behind it)
        end

        BotPlace(id, zoneId, px, py, pz, spot.rot or 0)
    end

    local ok = BotLogin(id)
    if ok then
        sessions[id] = now() + rnd(SESSION_MIN[1], SESSION_MIN[2]) * 60
    end

    return ok
end

local function logOut(id)
    if xi and xi.bots and xi.bots.beforeLogout then
        pcall(xi.bots.beforeLogout, id) -- (it may say bye in its linkshell first: bots_dialogue.lua)
    end

    BotHeal(id, false)
    BotLogout(id)
    sessions[id] = nil
    offSince[id] = now()
    for key, owner in pairs(takenSpot) do
        if owner == id then
            takenSpot[key] = nil
        end
    end
end

function L.tick()
    if not BotPlayerOnline() then
        return
    end

    local t = now()
    lastList = BotList()
    local total, online, offline = 0, {}, {}
    for z in pairs(perZone) do
        perZone[z] = nil
    end

    if GetServerVariable and SetServerVariable then
        local okT, errT = pcall(turnover, lastList)
        if not okT then print("[bots] turnover: " .. tostring(errT)) end
    end

    local gone = loadRetired()
    for id, row in pairs(lastList) do
        if gone[id] and not row.online then
            -- (stopped playing: not counted, never logs in again)
        elseif row.online then
            total = total + 1
            online[#online + 1] = id
            perZone[row.zone or 0] = (perZone[row.zone or 0] or 0) + 1
            sessions[id] = sessions[id] or (t + rnd(SESSION_MIN[1], SESSION_MIN[2]) * 60)
        else
            total = total + 1
            offline[#offline + 1] = id
        end
    end

    L.online = online

    -- the town chatter (shouts, small talk, two-bot exchanges) comes from the bots where you are (crowds_chat.lua)
    if t % 2 == 0 and xi.crowds and xi.crowds.botChatter then
        local byZone = {}
        for _, id in ipairs(online) do
            local z = lastList[id].zone or 0
            byZone[z] = byZone[z] or {}
            table.insert(byZone[z], id)
        end

        for zoneId, ids in pairs(byZone) do
            local zone = GetZone and GetZone(zoneId)
            local players = {}
            for _, p in ipairs(zone and zone:getPlayers() or {}) do
                if not BotIsBot(p:getID()) then
                    players[#players + 1] = p
                end
            end

            if #players > 0 then
                local speakers = {}
                for _, id in ipairs(ids) do
                    local e = GetPlayerByID(id)
                    -- (not a bot in a party: "going to sell some stuff" or "no pts?" from your party member was odd)
                    if e and e:isAlive() and e:getZoneID() == zoneId and e:getPartySize() <= 1 then
                        speakers[#speakers + 1] = e
                    end
                end

                pcall(xi.crowds.botChatter, zoneId, speakers, players, function(bot, kind, text)
                    if type(text) ~= 'string' or text == '' then
                        return
                    end

                    -- lines made for high levels (merits, endgame) do not fit a low level bot
                    local lower = text:lower()
                    if bot:getMainLvl() < 70 and (lower:find('meri') or text:find('75') or lower:find('endgame')) then
                        return
                    end

                    BotChat(bot:getID(), kind, text)
                end)
            end
        end
    end

    -- 1. the roster fills up, one character every few seconds
    if cfg.enabled and total < L.target() and t >= nextCreate then
        nextCreate = t + CREATE_EVERY
        createOne()
    end

    local target = cfg.enabled and math.min(L.onlineTarget(total), total) or 0

    -- 2. too many on (setting lowered, or bots turned off): one leaves per second
    if #online > target then
        for _, id in ipairs(online) do
            if canLeave(id, true) then
                logOut(id)
                break
            end
        end

        return
    end

    -- 3. a session is over: it logs out (never out of your party), someone else comes a bit later
    for _, id in ipairs(online) do
        if sessions[id] and t >= sessions[id] then
            if canLeave(id) then
                logOut(id)
                nextLogin = math.max(nextLogin, t + rnd(REFILL_EVERY[1], REFILL_EVERY[2]))
                return
            end

            sessions[id] = t + 10 * 60 -- busy with you: ask again later
        end
    end

    -- 3b. (2026-11-21) your bot friends are always online: an offline friend logs in now (one per tick)
    if cfg.enabled and L.keep then
        for _, id in ipairs(offline) do
            if lastList[id] and L.keep(id) then
                logIn(id, lastList[id])
                return
            end
        end
    end

    -- 4. fewer on than wanted: the one offline longest logs in
    if #online < target and #offline > 0 and t >= nextLogin then
        table.sort(offline, function(a, b)
            return (offSince[a] or 0) < (offSince[b] or 0)
        end)

        local pickFrom = math.min(#offline, 5)
        local id = offline[rnd(1, pickFrom)]
        -- your bot friends log in more while you are on, mostly at their usual hours (bots_friends.lua)
        if L.preferLogin then
            local okF, friendId = pcall(L.preferLogin, offline)
            if okF and friendId and lastList[friendId] then
                id = friendId
            end
        end

        logIn(id, lastList[id])
        local far = #online + 1 < math.min(L.onlineTarget(L.target()), L.target()) * 0.9
        local gap = far and FILL_EVERY or REFILL_EVERY
        nextLogin = t + rnd(gap[1], gap[2])
    end
end

-- online bots in an area (the crowds make room for them)
function L.countInZone(zoneId)
    return perZone[zoneId] or 0
end

function L.status()
    local total, online = 0, 0
    local gone = loadRetired()
    for id, row in pairs(lastList) do
        if not gone[id] or row.online then
            total = total + 1
        end

        if row.online then
            online = online + 1
        end
    end

    return total, online
end

-----------------------------------
-- town life: what a bot does when it is not in a party with you (called from its brain, once a second)
-----------------------------------
local function nearestRealPlayer(bot, range)
    local zone = bot:getZone()
    if not zone then
        return nil
    end

    local pos = bot:getPos()
    local best, bestD = nil, range * range
    for _, p in ipairs(zone:getPlayers()) do
        if not BotIsBot(p:getID()) then
            local pp = p:getPos()
            local d = (pp.x - pos.x) ^ 2 + (pp.z - pos.z) ^ 2
            if d <= bestD then
                best, bestD = p, d
            end
        end
    end

    return best
end

local function chooseSpot(bot, zoneId)
    local spots = spotsOf(zoneId)
    if #spots == 0 then
        return nil
    end

    local kinds = {}
    for _, s in ipairs(spots) do
        if KIND_WEIGHT[s.kind] then
            kinds[s.kind] = KIND_WEIGHT[s.kind]
        end
    end

    local kind = next(kinds) and weighted(kinds) or nil
    local pos = bot:getPos()
    local near, any = {}, {}
    for i, s in ipairs(spots) do
        local key = zoneId .. ':' .. i
        if (kind == nil or s.kind == kind) and (not takenSpot[key] or takenSpot[key] == bot:getID()) then
            any[#any + 1] = i
            if (s.x - pos.x) ^ 2 + (s.z - pos.z) ^ 2 <= WALK_RANGE * WALK_RANGE then
                near[#near + 1] = i
            end
        end
    end

    local list = #near > 0 and near or any
    if #list == 0 then
        return nil
    end

    local i = list[rnd(1, #list)]
    return i, spots[i]
end

function L.idle(bot, st)
    local id = bot:getID()
    local t = now()
    local life = st.life
    if not life then
        life = { phase = 'choose', at = t + rnd(2, 8) }
        st.life = life
    end

    if bot:isEngaged() then
        return
    end

    local zoneId = bot:getZoneID()
    if #spotsOf(zoneId) == 0 then
        -- left alone out in the field (you left the party, or it followed you out): it goes home after a while
        life.awayUntil = life.awayUntil or (t + rnd(AWAY_HOME[1], AWAY_HOME[2]))
        if t >= life.awayUntil then
            life.awayUntil = nil
            local nation = NATION_OF[zoneId] or rnd(0, 2)
            local homeZone, spot = homeSpot(nation)
            if spot then
                if xi.navguard then xi.navguard.setPos(bot, spot.x, spot.y, spot.z, spot.rot or 0, homeZone, nil) else bot:setPos(spot.x, spot.y, spot.z, spot.rot or 0, homeZone) end
                return 'zoning'
            end
        end

        return
    end

    life.awayUntil = nil

    if life.phase == 'walking' then
        if not BotIsMoving(id) or t >= life.giveUp then
            life.phase = 'there'
            if life.kind == 'rest' then
                BotHeal(id, true)
                life.at = t + rnd(120, 420)
            elseif life.kind == 'ah' then
                life.at = t + rnd(60, 240)
            else
                life.at = t + rnd(45, 200)
            end

            life.nextEmote = t + rnd(15, 60)
        end

        return
    end

    if life.phase == 'there' then
        local player = nearestRealPlayer(bot, 12) -- (emotes sometimes at you)
        if life.kind ~= 'rest' and t >= (life.nextEmote or 0) then
            life.nextEmote = t + rnd(30, 120)
            if math.random() < 0.35 and xi.emote then
                local which = xi.emote[EMOTES[rnd(1, #EMOTES)]]
                local target = player and math.random() < 0.5 and player or nil
                if which then
                    BotEmote(id, target, which, (xi.emoteMode and xi.emoteMode.MOTION) or 2)
                end
            end
        end

        if t < life.at then
            return
        end

        life.phase = 'choose'
    end

    if life.phase == 'choose' and t >= (life.at or 0) then
        BotHeal(id, false)
        if life.key and takenSpot[life.key] == id then
            takenSpot[life.key] = nil
        end

        local i, spot = chooseSpot(bot, zoneId)
        if not spot then
            life.at = t + 30
            return
        end

        life.key = zoneId .. ':' .. i
        takenSpot[life.key] = id
        life.kind = spot.kind
        life.phase = 'walking'
        life.giveUp = t + 60
        BotMoveTo(id, spot.x + (math.random() - 0.5) * 1.5, spot.y, spot.z + (math.random() - 0.5) * 1.5)
    end
end

-- back to its own nation's towns (after hunting): it zones
function L.goHome(bot)
    local ok, nation = pcall(function()
        return bot:getNation()
    end)
    local zoneId, spot = homeSpot((ok and nation) or NATION_OF[bot:getZoneID()] or 0)
    if not spot then
        return false
    end

    -- (2026-11-21) through the town gate: it arrives where you do when you zone in from that side, and walks in
    -- from there (bots_gates.lua). No way found, or switched off: on its spot, as before.
    local extras = xi.bots and xi.bots.extras or nil
    if extras and extras.homeArrival then
        local okGate, at = pcall(extras.homeArrival, bot, zoneId)
        if okGate and type(at) == 'table' and at.x then
            spot = at
        end
    end

    if xi.navguard then xi.navguard.setPos(bot, spot.x, spot.y, spot.z, spot.rot or 0, zoneId, nil) else bot:setPos(spot.x, spot.y, spot.z, spot.rot or 0, zoneId) end
    return true
end

-- it joined your party: stop resting, forget the town plan
function L.leaveTown(bot, st)
    if st.life then
        if st.life.key and takenSpot[st.life.key] == bot:getID() then
            takenSpot[st.life.key] = nil
        end

        st.life = nil
        BotHeal(bot:getID(), false)
    end
end

L.loadConfig()
return L
