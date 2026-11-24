-----------------------------------
-- FFXI Offline: bot players (step 4.1 + 4.2 roster). The C++ side is modules/custom/cpp/bots.cpp; the roster and
-- town life are in bots_life.lua, hunting in bots_hunt.lua, personalities + crafting + HELM + auction house in bots_craft.lua,
-- quests + nation missions in bots_quests.lua (launcher: CONFIG > Rates > "Bot players", "Bot roster", "Bots online").
--
-- Bots are real characters (own accounts, accounts from 21000000, characters from 16000000; your squad mates are not touched). A bot plays
-- through the same packets a game client sends, so to the server - and to your game - it is a real player:
-- white name, /check, /sea, party list, real exp and claims.
--
-- In game (any of your characters):
--   !bots                         roster status (how many, how many online, in this area)
--   !bots list                    every bot and who is online
--   !bots online <0-1500>           how many are on at a time, right now (the launcher value is used again at the next PLAY)
--   !bots on / off                the roster logs in / everyone logs out (until the next PLAY)
--   !bots hunt <Name>             send a bot out hunting now (to watch it: !bots where <Name>)
--   !bots where <Name>            which area a bot is in, its level, what it is doing, its personality and gil
--   !bots craft|gather|market|fish <Name>   send a bot to craft / gather (HELM) / visit the auction house / fish now
--   !bots quest <Name> [mission]  send a bot on a quest (or its next nation mission) now
--   !bots news                    what the bots did while you were away (levels, ranks, crafts, new jobs)
--   !bots growth off|realistic|fast   how fast they grow while you are away (until the next PLAY)
--   !bots create <Name> [race] [job]   a new bot standing next to you
--                                 race: humem humef elvm elvf tarum taruf mithra galka   job: WAR MNK WHM BLM RDM THF
--   !bots login <Name|all>        log a bot in where it was last     !bots logout <Name|all>
--   !bots come <Name>             the bot comes to you (same area: it runs; other area: it teleports)
--   !bots say <Name> <text>       the bot says something
--   !bots invite <Name>           the bot sends YOU a party invite (answer with /join); it then makes you the leader
-- When you change area, a following bot comes after you about 5 seconds later.
-- Party: invite a bot as you invite anyone (/pcmd add Name), or !bots invite Name. Trusts (your squad) and players
-- cannot share a party: dismiss the squad first. It accepts, follows you, and attacks what you attack.
-- In party chat: "follow" / "stay" / "attack" (your target) / "stop".
-----------------------------------
require('modules/module_utils')
pcall(require, 'modules/custom/lua/nav_guard') -- (xi.navguard: keeps units out of walls, nav_guard.lua)
-----------------------------------
local m = Module:new('bot_players') -- (module names need 5+ letters)

xi.bots = xi.bots or {}

-- an attack (or stand-up) packet while casting cancels the spell, so a casting bot is left alone until it is out
xi.bots.isCasting = function(bot)
    local ok, action = pcall(function()
        return bot:getCurrentAction()
    end)
    return ok and action == xi.action.MAGIC_CASTING
end

-- Thief bots (THF main or sub, like squad mates): Sneak Attack from behind the monster (THF 15), Trick Attack from
-- right behind whoever the monster is fighting (THF 30). Called in place of the plain melee follow; returns true
-- when it moved the bot itself (the caller then skips its BotFollow).
local thiefSpots = {}
xi.bots.thiefTurn = function(bot, target)
    if type(BotMoveTo) ~= 'function' or type(BotAbility) ~= 'function' or target == nil or not target:isAlive() then
        return false
    end

    local lvl = 0
    if bot:getMainJob() == xi.job.THF then
        lvl = bot:getMainLvl()
    elseif bot:getSubJob() == xi.job.THF then
        lvl = bot:getSubLvl()
    end

    if lvl < 15 or xi.bots.isCasting(bot) then
        return false
    end

    local id      = bot:getID()
    local tank    = target:getTarget()
    local tanking = tank ~= nil and tank:getID() == id -- (it faces us: no getting behind it)
    local other   = tank ~= nil and not tanking and tank:isAlive() and tank:getZoneID() == bot:getZoneID()
    local tp      = target:getPos()
    local spot, use

    local saReady = not bot:hasRecast(xi.recast.ABILITY, 64)
    local taReady = lvl >= 30 and not bot:hasRecast(xi.recast.ABILITY, 66)
    if not tanking and (bot:hasStatusEffect(xi.effect.SNEAK_ATTACK) or saReady) then
        if bot:isBehind(target) and bot:checkDistance(target) < 3.5 then
            use = (saReady and not bot:hasStatusEffect(xi.effect.SNEAK_ATTACK)) and xi.jobAbility.SNEAK_ATTACK or nil
        else
            local rad = (tp.rot / 256) * 2 * math.pi + math.pi
            spot = { x = tp.x + math.cos(2 * math.pi - rad) * 1.2, y = tp.y, z = tp.z + math.sin(2 * math.pi - rad) * 1.2 }
        end
    elseif other and (bot:hasStatusEffect(xi.effect.TRICK_ATTACK) or taReady) then
        local kp    = tank:getPos()
        local apart = math.sqrt((kp.x - tp.x) ^ 2 + (kp.z - tp.z) ^ 2)
        if apart < 0.5 or apart > 3.5 then
            return false -- (the tank is not next to it: just fight)
        end

        local want = { x = kp.x + (kp.x - tp.x) * 0.7 / apart, y = kp.y, z = kp.z + (kp.z - tp.z) * 0.7 / apart }
        local bp   = bot:getPos()
        if (bp.x - want.x) ^ 2 + (bp.z - want.z) ^ 2 > 0.6 * 0.6 then
            spot = want
        elseif taReady and not bot:hasStatusEffect(xi.effect.TRICK_ATTACK) then
            use = xi.jobAbility.TRICK_ATTACK
        end
    else
        thiefSpots[id] = nil
        return false
    end

    if use then
        local last = thiefSpots[id]
        if not last or os.time() - (last.ja or 0) >= 3 then
            thiefSpots[id] = { ja = os.time() }
            BotAbility(id, use, bot)
        end
        return true -- (standing where it should: stay put)
    end

    if spot then
        local last = thiefSpots[id]
        local moved = not last or not last.x or (last.x - spot.x) ^ 2 + (last.z - spot.z) ^ 2 > 1
        if moved or not BotIsMoving(id) then
            thiefSpots[id] = { x = spot.x, z = spot.z, ja = last and last.ja }
            BotMoveTo(id, spot.x, spot.y, spot.z)
        end
        return true
    end

    return true -- (behind it with Sneak Attack up, or holding the Trick Attack spot)
end

-- spreading out around the monster (2026-11-17, Impending Descent): melee bots used to stand on one spot in front
-- of it. Whoever has the monster's attention stays in front; the others take their own place around its sides
-- and back, like the squad mates do. Returns true while it is walking to (or holding) its place.
local FLANK_ANGLES = { 110, -110, 150, -150, 180, 80, -80 } -- degrees from the monster's front, per party slot
xi.bots.flankTurn = function(bot, target, stop)
    if type(BotMoveTo) ~= 'function' or target == nil or not target:isAlive() or xi.bots.isCasting(bot) then
        return false
    end

    local id   = bot:getID()
    local tank = target:getTarget()
    if tank == nil or tank:getID() == id then
        return false -- (it is the one being hit: it stays in front)
    end

    local tp = target:getPos()
    if bot:checkDistance(target) > 6 then
        return false -- (still running to it: just follow)
    end

    -- its slot: its place among the party's melee members (by id), the tank left out
    local slot, n = 1, 0
    local ids = {}
    for _, m in pairs(bot:getParty() or {}) do
        if m:isAlive() and m:getID() ~= tank:getID() then
            ids[#ids + 1] = m:getID()
        end
    end
    table.sort(ids)
    for i, mid in ipairs(ids) do
        if mid == id then
            slot = i
        end
        n = i
    end

    local kp = tank:getPos()
    local front = math.atan2(kp.z - tp.z, kp.x - tp.x)
    if (kp.x - tp.x) ^ 2 + (kp.z - tp.z) ^ 2 < 0.01 then
        front = 2 * math.pi - (tp.rot / 256) * 2 * math.pi
    end

    local a = front + math.rad(FLANK_ANGLES[((slot - 1) % #FLANK_ANGLES) + 1])
    local r = stop or 1.5
    local spot = { x = tp.x + math.cos(a) * r, y = tp.y, z = tp.z + math.sin(a) * r }
    local bp = bot:getPos()
    if (bp.x - spot.x) ^ 2 + (bp.z - spot.z) ^ 2 > 0.9 * 0.9 then
        BotMoveTo(id, spot.x, spot.y, spot.z)
    end

    return true
end

-- (bots.cpp registers BotList & co. AFTER the Lua modules load, so this is checked when a command is used)
local function moduleBuilt()
    return type(BotList) == 'function'
end

local THINK_MS = 1000
local ZONE_FOLLOW_S = 5 -- seconds after you change area before a following bot comes after you
local MELEE_STOP = 1.5 -- yalms: how close a bot stands to a mob it is hitting
local RACES = { humem = 1, humef = 2, elvm = 3, elvf = 4, tarum = 5, taruf = 6, mithra = 7, galka = 8 }
local JOBS = { WAR = 1, MNK = 2, WHM = 3, BLM = 4, RDM = 5, THF = 6 }

local lifeOk, life = pcall(require, 'modules/custom/lua/bots_life')
if not lifeOk or type(life) ~= 'table' then
    print('[bots] roster and town life are off: bots_life.lua could not be loaded: ' .. tostring(life))
    life = nil
end

local huntOk, hunt = pcall(require, 'modules/custom/lua/bots_hunt')
if not huntOk or type(hunt) ~= 'table' then
    print('[bots] hunting is off: bots_hunt.lua could not be loaded: ' .. tostring(hunt))
    hunt = nil
end

local craftOk, craft = pcall(require, 'modules/custom/lua/bots_craft')
if not craftOk or type(craft) ~= 'table' then
    print('[bots] crafting, gathering and the auction house are off: bots_craft.lua could not be loaded: ' .. tostring(craft))
    craft = nil
end

if craft then
    craft.setup(hunt)
end

local chatOk, talk = pcall(require, 'modules/custom/lua/bots_chat')
if not chatOk or type(talk) ~= 'table' then
    print('[bots] bot conversations are off: bots_chat.lua could not be loaded: ' .. tostring(talk))
    talk = nil
end

local partyOk, partyPlay = pcall(require, 'modules/custom/lua/bots_party')
if not partyOk or type(partyPlay) ~= 'table' then
    print('[bots] party roles are off: bots_party.lua could not be loaded: ' .. tostring(partyPlay))
    partyPlay = nil
end

local jobsOk, jobs = pcall(require, 'modules/custom/lua/bots_jobs')
if not jobsOk or type(jobs) ~= 'table' then
    print('[bots] subjobs and job changes are off: bots_jobs.lua could not be loaded: ' .. tostring(jobs))
    jobs = nil
end

local lsOk, linkshells = pcall(require, 'modules/custom/lua/bots_ls')
if not lsOk or type(linkshells) ~= 'table' then
    print('[bots] linkshells are off: bots_ls.lua could not be loaded: ' .. tostring(linkshells))
    linkshells = nil
end

local inviteOk, invites = pcall(require, 'modules/custom/lua/bots_invite')
if not inviteOk or type(invites) ~= 'table' then
    print('[bots] bot invites are off: bots_invite.lua could not be loaded: ' .. tostring(invites))
    invites = nil
end

local bcnmOk, bcnm = pcall(require, 'modules/custom/lua/bots_bcnm')
if not bcnmOk or type(bcnm) ~= 'table' then
    print('[bots] battlefields are off: bots_bcnm.lua could not be loaded: ' .. tostring(bcnm))
    bcnm = nil
end

local gearOk, gear = pcall(require, 'modules/custom/lua/bots_gear')
if not gearOk or type(gear) ~= 'table' then
    print('[bots] bot gear is off: bots_gear.lua could not be loaded: ' .. tostring(gear))
    gear = nil
end

local petsOk, petsMod = pcall(require, 'modules/custom/lua/bots_pets')
if not petsOk or type(petsMod) ~= 'table' then
    print('[bots] pets are off: bots_pets.lua could not be loaded: ' .. tostring(petsMod))
    petsMod = nil
end

local growthOk, growth = pcall(require, 'modules/custom/lua/bots_growth')
if not growthOk or type(growth) ~= 'table' then
    print('[bots] growing while away is off: bots_growth.lua could not be loaded: ' .. tostring(growth))
    growth = nil
end

local questsOk, quests = pcall(require, 'modules/custom/lua/bots_quests')
if not questsOk or type(quests) ~= 'table' then
    print('[bots] quests and missions are off: bots_quests.lua could not be loaded: ' .. tostring(quests))
    quests = nil
end

-- teleport shouts: bots who want a Teleport, and a bot white mage who answers yours (bots_tele.lua)
local teleOk, tele = pcall(require, 'modules/custom/lua/bots_tele')
if not teleOk or type(tele) ~= 'table' then
    print('[bots] teleport shouts are off: bots_tele.lua could not be loaded: ' .. tostring(tele))
    tele = nil
end

-- written dialogue: linkshell chatter, hellos, reactions to what really happened, answers without the AI
-- (bots_dialogue.lua, lines from C:\FFXISOLO\dialogue)
local dialogueOk, dialogue = pcall(require, 'modules/custom/lua/bots_dialogue')
if not dialogueOk or type(dialogue) ~= 'table' then
    print('[bots] written dialogue is off: bots_dialogue.lua could not be loaded: ' .. tostring(dialogue))
    dialogue = nil
end

-- bot players on your friend list: how they feel about you, hellos, cheers, help offers (bots_friends.lua)
local friendsOk, friends = pcall(require, 'modules/custom/lua/bots_friends')
if not friendsOk or type(friends) ~= 'table' then
    print('[bots] bot friendships are off: bots_friends.lua could not be loaded: ' .. tostring(friends))
    friends = nil
end

-- (2026-11-21) emotes at the right moments, a memory for where it died, a life story, the town gates
-- (bots_extras.lua and the four files it loads; each has its own switch: !extras)
local botExtrasOk, botExtras = pcall(require, 'modules/custom/lua/bots_extras')
if not botExtrasOk or type(botExtras) ~= 'table' then
    print('[bots] the 2026-11-21 additions are off: bots_extras.lua could not be loaded: ' .. tostring(botExtras))
    botExtras = nil
end

xi.bots.extras = botExtras -- (bots_hunt.lua and bots_life.lua ask it where to go and how to leave)

local HUNT_CHECK = { 5 * 60, 15 * 60 } -- seconds in town between two "go hunting?" thoughts
local DEAD_ALONE = { 15, 40 }          -- seconds dead (not with you) before it returns to its Home Point
local DEAD_WITH_YOU = 180              -- with you: it waits this long for a Raise (when someone in the party can cast one)
local DEAD_NO_RAISE = 30               -- with you, but nobody in the party can Raise: it goes home after this
local REST_STILL_S = 8                 -- you stood still this long, out of a fight: a bot low on HP/MP sits down to rest

-- someone alive in the bot's party who can cast Raise (WHM 25+, RDM 35+)
local function partyCanRaise(bot)
    for _, m in pairs(bot:getParty() or {}) do
        if m:getID() ~= bot:getID() and m:isAlive() then
            local job, lvl = m:getMainJob(), m:getMainLvl()
            if (job == 3 and lvl >= 25) or (job == 5 and lvl >= 35) then
                return true
            end
        end
    end

    return false
end

local function tell(player, text)
    player:printToPlayer('[Bots] ' .. text, (xi.msg and xi.msg.channel and xi.msg.channel.SYSTEM_3) or 29)
end

-- id, entity (nil when offline), row
local function botByName(name)
    if not name then
        return nil
    end

    name = string.lower(name)
    for id, row in pairs(BotList()) do
        if row.name and string.lower(row.name) == name then
            return id, (row.online and GetPlayerByID(id) or nil), row
        end
    end

    return nil
end

local function allBotIds()
    local out = {}
    for id in pairs(BotList()) do
        out[#out + 1] = id
    end

    return out
end

-- a line a bot says in your party reaches your squad mates too (squad.lua: they hear it, may answer, remember it)
local function toSquad(bot, text)
    if not (xi.squad and xi.squad.onBotSay) then
        return
    end

    for _, member in pairs(bot:getParty() or {}) do
        if member:getObjType() == xi.objType.PC and not BotIsBot(member:getID()) then
            pcall(xi.squad.onBotSay, member, bot:getName(), text)
        end
    end
end

xi.bots.toSquad = toSquad

local function chat(bot, kind, text)
    BotChat(bot:getID(), kind, text)
    if kind == 4 then
        toSquad(bot, text)
    end
end

-----------------------------------
-- the brain: one decision per second per bot
-----------------------------------
local state = {} -- [bot id] = { mode = 'follow'|'stay', attacking = target id, life = town plan, hunt = field plan }

-- a bot that leaves a party on purpose (a teleport job done, its own plans) forgets who it played with, so the
-- zone-change rejoin in think() never pulls it back in. (Wrapped at the first brain start: the C++ side registers
-- BotLeaveParty after this file is loaded.)
local leaveWrapped = false
local function wrapLeaveParty()
    if leaveWrapped or type(BotLeaveParty) ~= 'function' then
        return
    end

    leaveWrapped = true
    local rawLeaveParty = BotLeaveParty
    BotLeaveParty = function(id, ...)
        local s = state[id]
        if s then
            s.withName, s.withLostAt = nil, nil
        end

        return rawLeaveParty(id, ...)
    end
end
if bcnm then
    bcnm.setup(state, hunt, craft)
end

if invites then
    invites.setup(state)
end

if craft and gear and craft.setGear then
    craft.setGear(gear)
end

if hunt then
    hunt.setup(state)
    if partyPlay and hunt.setParty then
        hunt.setParty(partyPlay)
    end
end

if botExtras then
    pcall(botExtras.setup, state)
end

if quests then
    quests.setup(state, hunt, life)
end

-- (tele.setup runs after joinAskedParty exists: see below)

if growth then
    growth.setup(craft, quests, jobs, life and life.config(), gear)
end

local function realLeader(bot)
    local leader = bot:getPartyLeader()
    -- a bot leading its own exp party or battlefield run (bots_invite.lua asked you along): the bots keep to their
    -- plan and you are a guest in it, not the one they follow
    if leader and BotIsBot(leader:getID()) then
        local lst = state[leader:getID()]
        if lst and ((lst.hunt and lst.hunt.leaderOf) or (lst.bf and lst.bf.role == 'leader')) then
            return nil
        end
    end
    if leader and leader:getID() ~= bot:getID() and leader:getObjType() == xi.objType.PC and not BotIsBot(leader:getID()) then
        return leader
    end

    -- the party leader may be another bot: then follow the first real player in the party
    for _, member in pairs(bot:getParty() or {}) do
        if member:getObjType() == xi.objType.PC and not BotIsBot(member:getID()) then
            return member
        end
    end

    return nil
end

-----------------------------------
-- Camps (2026-11-17): your squad camp (!squad camp, the Squad menu's Camp row) holds the bot players in your party
-- too. They stand around the camp spot instead of following you, fight whatever anyone in the party fights within
-- CAMP_FIGHT yalms of it, and rest there when low (the camp rest switch). One of them can pull (!squad pull <name>,
-- or the menu's Puller list): it picks a monster the way the squad puller does (your pull levels and monster
-- picks), shoots it if it has a ranged weapon or tags it, and runs it back to camp.
-----------------------------------
local CAMP_FIGHT = 20
local CAMP_PULL_GIVE_UP = 120  -- seconds before a pull that went nowhere is dropped
local CAMP_PULL_FLEE_HP = 40

local function campOf(leader)
    if not (xi.squad and xi.squad.campInfo) then
        return nil
    end

    local ok, c = pcall(xi.squad.campInfo, leader)
    return ok and c or nil
end

local function nearCamp(c, ent, range)
    local p = ent:getPos()
    return (p.x - c.x) ^ 2 + (p.z - c.z) ^ 2 <= range * range
end

-- what to fight at camp: anything someone in your party (squad mates included) fights near camp, or the monster
-- this bot brought back
local function campTarget(leader, c, st)
    for _, m in pairs(leader:getPartyWithTrusts() or {}) do
        if m:isEngaged() then
            local t = m:getTarget()
            if t and t:isAlive() and t:getObjType() == xi.objType.MOB and nearCamp(c, t, CAMP_FIGHT) then
                return t
            end
        end
    end

    if st.pullMob then
        local t = GetMobByID(st.pullMob)
        if t and t:isAlive() and t:isEngaged() then
            if nearCamp(c, t, CAMP_FIGHT) then
                return t
            end
        else
            st.pullMob = nil
        end
    end

    return nil
end

-- its own spot around the camp (so a few bots don't stand inside each other)
local function campSpot(bot, st, c)
    if not st.campSpot or st.campSpot.zone ~= c.zone or st.campSpot.cx ~= c.x or st.campSpot.cz ~= c.z then
        -- (2026-11-19, Impending Descent: still no rest at camp) a random spot could be inside a rock or off the
        -- navmesh; the bot then walked at it for ever and never counted as there, so it never sat. Only walkable spots
        -- now (else the camp spot itself), and campStuck() below settles a bot that can't get any closer.
        local zone = bot:getZone()
        local spot = nil
        for _ = 1, 8 do
            local a, r = math.random() * 2 * math.pi, 2 + math.random() * 2
            local p = { x = c.x + math.cos(a) * r, y = c.y, z = c.z + math.sin(a) * r }
            if not zone or not zone.isNavigablePoint or zone:isNavigablePoint(p) then
                spot = p
                break
            end
        end

        spot = spot or { x = c.x, y = c.y, z = c.z }
        st.campSpot = { zone = c.zone, cx = c.x, cz = c.z, x = spot.x, y = spot.y, z = spot.z }
        st.campNear, st.campStuck = nil, 0
    end

    return st.campSpot
end

-- true once a bot walking to its camp spot stops getting closer (a few checks in a row): it takes where it stands
local function campStuck(bot, st, d2)
    if st.campNear and d2 >= st.campNear - 0.25 then
        st.campStuck = (st.campStuck or 0) + 1
    else
        st.campStuck = 0
    end

    st.campNear = d2
    if (st.campStuck or 0) >= 4 and d2 < 10 * 10 then
        local bp = bot:getPos()
        st.campSpot.x, st.campSpot.y, st.campSpot.z = bp.x, bp.y, bp.z
        st.campNear, st.campStuck = nil, 0
        return true
    end

    return false
end

-- the bot puller, once a second; true while it is busy with a pull
local function campPullTurn(bot, st, leader, c)
    local id = bot:getID()
    if c.pullerBot ~= id or c.paused then
        st.pull = nil
        return false
    end

    local t = os.time()
    local p = st.pull
    if p == nil then
        if campTarget(leader, c, st) or t < (st.pullNext or 0) or bot:getHPP() < 70 or bot:isEngaged() then
            return false
        end

        local mob = xi.squad.campPickFor and xi.squad.campPickFor(leader)
        if not mob then
            st.pullNext = t + 5
            return false
        end

        st.pull = { mob = mob:getID(), since = t, phase = 'go' }
        if xi.squad.campCountPull then
            pcall(xi.squad.campCountPull, leader)
        end

        chat(bot, 4, ({ 'pulling ' .. mob:getName(), 'getting one', 'brb with a ' .. mob:getName(), 'pull incoming soon' })[math.random(1, 4)])
        return true
    end

    local mob = GetMobByID(p.mob)
    if not mob or not mob:isAlive() or t - p.since > CAMP_PULL_GIVE_UP then
        if mob and mob:isAlive() and p.phase == 'go' then
            chat(bot, 4, 'cant get to it, coming back')
        end

        st.pull, st.pullNext = nil, t + 10
        BotMoveTo(id, c.x, c.y, c.z)
        return false
    end

    if p.phase == 'go' then
        if mob:isEngaged() and not (mob:getTarget() and mob:getTarget():getID() == id) then
            st.pull, st.pullNext = nil, t + 5 -- (someone else got it)
            return false
        end

        local d = bot:checkDistance(mob)
        local ranged = false
        pcall(function()
            ranged = bot:getEquipID(xi.slot.RANGED) ~= 0
        end)

        if mob:isEngaged() then
            BotAttackOff(id)
            p.phase = 'back'
        elseif ranged and BotShoot and d <= 18 then
            BotStop(id)
            pcall(function()
                bot:lookAt(mob:getPos())
            end)
            if t >= (p.shotAt or 0) then
                p.shotAt = t + 4
                BotShoot(id, mob)
            end
        elseif d <= 3 then
            BotAttack(id, mob)
        else
            BotFollow(id, mob, 2)
        end

        return true
    end

    -- back to camp with it on its tail (or too hurt: it drops the pull and runs)
    if bot:getHPP() < CAMP_PULL_FLEE_HP then
        chat(bot, 4, 'too hurt, help!')
    end

    if nearCamp(c, bot, 4) then
        st.pullMob, st.pull, st.pullNext = p.mob, nil, t + 8 -- (the camp fight takes over)
        return false
    end

    BotAttackOff(id)
    BotMoveTo(id, c.x, c.y, c.z)
    return true
end

local think

-- its own story: a few things that happened to it lately (it brings them up when you chat: bots_chat_ai.py keeps them)
local function diary(bot, text, public)
    local st = state[bot:getID()]
    if not st or not text or text == '' then
        return
    end

    st.events = st.events or {}
    table.insert(st.events, { t = os.time(), text = text })
    while #st.events > 5 do
        table.remove(st.events, 1)
    end

    -- (2026-11-21) the ones worth remembering go into its life story (bots_story.lua)
    if botExtras then
        pcall(botExtras.onDiary, bot, text, public)
    end

    -- the bigger news gets around the server (other bots may talk about it)
    if public and growth and growth.addNews then
        pcall(growth.addNews, bot:getName() .. ' ' .. text)
    end

    -- in a linkshell you are in, it may mention it and the others react (bots_dialogue.lua)
    if linkshells and linkshells.onBotEvent then
        pcall(linkshells.onBotEvent, bot, text)
    end
end

xi.bots.diary = function(bot, text, public)
    pcall(diary, bot, text, public)
end

-- what changed since its last look: a level up, a new job, a death, the people in its party
local DIARY_JOBS = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP' }
local function noticeChanges(bot, st)
    local lvl, job = bot:getMainLvl(), bot:getMainJob()
    if st.lastLvl and lvl > st.lastLvl then
        diary(bot, string.format('hit level %d on %s', lvl, DIARY_JOBS[job] or '?'), lvl % 5 == 0)
    end

    if st.lastJob and job ~= st.lastJob then
        diary(bot, 'switched to ' .. (DIARY_JOBS[job] or '?'))
    end

    -- (2026-11-21) a real level up, one level more on the same job (not a job change, not the end of a level sync)
    if botExtras and st.lastLvl and st.lastJob == job and lvl == st.lastLvl + 1 then
        pcall(botExtras.onLevel, bot, st)
    end

    st.lastLvl, st.lastJob = lvl, job
    if bot:isDead() and not st.diedNoted then
        st.diedNoted = true
        if botExtras then
            pcall(botExtras.onDeath, bot, st) -- (out hunting: it stays away from there for a while, bots_memory.lua)
        end

        local zone = bot:getZone()
        diary(bot, 'got killed' .. (zone and (' in ' .. zone:getName():gsub('_', ' ')) or ''))
    elseif not bot:isDead() then
        st.diedNoted = nil
    end

    if bot:getPartySize() > 1 and os.time() >= (st.partyNoted or 0) then
        st.partyNoted = os.time() + 60
        local names = {}
        for _, m in pairs(bot:getParty() or {}) do
            if m:getID() ~= bot:getID() and m:getObjType() == xi.objType.PC and #names < 3 then
                names[#names + 1] = m:getName()
            end
        end

        if #names > 0 then
            st.lastParty = table.concat(names, ', ')
        end
    end
end

local function schedule(bot, token)
    bot:timer(THINK_MS, function(b)
        think(b, token)
    end)
end

think = function(bot, token)
    local id = bot:getID()
    if not BotIsBot(id) then
        return
    end

    local st = state[id]
    local online
    if BotIsOnline then
        online = BotIsOnline(id)
    else
        local list = BotList()
        online = list[id] and list[id].online
    end

    if not online or not st or st.token ~= token then
        return -- logged out, or logged in again (a newer brain runs): this one stops
    end

    pcall(noticeChanges, bot, st)
    if friends then
        pcall(friends.notice, bot, st) -- (time with you, being raised with you, its level ups for its friends)
    end

    if botExtras then
        pcall(botExtras.tick, bot, st) -- (2026-11-21: emotes at the right moments, bots_social.lua)
    end

    -- a Blue Mage bot: learns blue magic from what it defeats (spells from scrolls) and keeps its set spells up to
    -- date (bots_party.lua)
    if partyPlay and (bot:getMainJob() == 16 or bot:getSubJob() == 16) then
        if partyPlay.hookBlue and bot:getMainJob() == 16 then
            pcall(partyPlay.hookBlue, bot, st)
        end

        if partyPlay.learn then
            pcall(partyPlay.learn, bot)
        end

        if partyPlay.setBlue then
            pcall(partyPlay.setBlue, bot, st)
        end
    end

    -- asleep, petrified, stunned, terrorised, charmed: it can do nothing, and it must not walk either. (It kept
    -- trying to attack, cast and stand up every few seconds - the server refused each one - and its movement was
    -- still being sent, so a sleeping bot could slide along after its target.)
    if not bot:isDead() then
        local okHeld, held = pcall(function()
            return bot:hasPreventActionEffect()
        end)
        if okHeld and held then
            BotStop(id)
            schedule(bot, token)
            return
        end
    end
    local leader = realLeader(bot)

    -- you are a different character object once you zone, and a party entry can still name the old one for a
    -- moment. Look the name up in the live world every time: GetPlayerByName finds nothing between zones, so
    -- the bot waits a tick instead of using a dead handle (that is what crashed the map server).
    if leader then
        leader = GetPlayerByName(leader:getName()) or nil
        -- (2026-11-19, Impending Descent: a WHM came back from a party death as a BLM) between zones the lookup
        -- finds nothing, and with no leader the bot ran its town life for that tick: subjob levelling, back to its
        -- main job, job quests. A bot in your party just waits for you instead.
        if leader == nil then
            schedule(bot, token)
            return
        end
    end

    -- (2026-11-21, Sunie: a bot that joined by tell while her squad mate was out dropped out of the party when she
    -- zoned, and never followed) remember who it plays with; if the party is gone right after either of them changed
    -- area (not a kick or a leave: those happen in one area, and BotLeaveParty below forgets the player first), join
    -- that player again and keep following.
    if leader then
        st.withName, st.withZone, st.myZone, st.withLostAt = leader:getName(), leader:getZoneID(), bot:getZoneID(), nil
    elseif st.withName and st.mode == 'follow' then
        st.withLostAt = st.withLostAt or os.time()
        local p = GetPlayerByName(st.withName)
        if p then
            local zoned = p:getZoneID() ~= st.withZone or bot:getZoneID() ~= st.myZone
            local name = st.withName
            st.withName, st.withLostAt = nil, nil
            if zoned and bot:getPartySize() <= 1 and BotJoinParty and BotJoinParty(id, p:getID()) then
                print(string.format('[bots] %s lost %s\'s party on a zone change and joined again', bot:getName(), name))
                st.awaySince, st.attacking = nil, nil
                if p:getZoneID() == bot:getZoneID() then
                    BotFollow(id, p, 3)
                end

                schedule(bot, token)
                return
            end
        elseif os.time() - st.withLostAt > 60 then
            st.withName, st.withLostAt = nil, nil
        end
    end

    -- walls: inside one, behind one from its leader, or cut off from a leader it follows: walked back (then put back)
    if xi.navguard and not bot:isDead() then
        xi.navguard.watch(bot, { kind = 'bot', owner = leader, follow = leader ~= nil and st.mode == 'follow' and not st.hunt and not bot:isEngaged() })
    end

    -- when it was last seen playing (bots_growth.lua: what it does while you are away is counted from here).
    -- (This sat inside the "dead" branch below by mistake, so it only ran for a bot that had just died.)
    if growth and os.time() >= (st.seenAt or 0) then
        st.seenAt = os.time() + 300
        pcall(growth.seen, bot)
    end

    -- Level Sync stays on for 30 s after a synced party ends, and the server refuses every invite to someone
    -- who has it: a bot that is not in a party any more drops it at once, so you (or a bot leader) can invite it
    if bot:getPartySize() <= 1 and xi.effect and xi.effect.LEVEL_SYNC and bot:hasStatusEffect(xi.effect.LEVEL_SYNC) then
        pcall(function()
            bot:delStatusEffectSilent(xi.effect.LEVEL_SYNC)
        end)
    end

    if bot:isDead() and not (st.hunt and hunt) then
        st.deadAt = st.deadAt or os.time()
        local wait = leader and (partyCanRaise(bot) and DEAD_WITH_YOU or DEAD_NO_RAISE) or (st.deadWait or math.random(DEAD_ALONE[1], DEAD_ALONE[2]))
        if st.releaseNow then
            wait, st.releaseNow = 0, nil -- (you said "release" in party chat)
        end
        st.deadWait = wait
        if os.time() - st.deadAt >= wait and BotHomepoint then
            st.deadAt, st.deadWait = nil, nil
            BotHomepoint(id)
            return -- it zones to its Home Point: a new brain starts there
        end

        schedule(bot, token)
        return
    end

    st.deadAt, st.deadWait = nil, nil
    -- the bot invited you, so it leads: hand the leader role to you (tried at most every 10 s)
    if leader and bot:getPartyLeader() and bot:getPartyLeader():getID() == id and (st.leadAt or 0) <= os.time() then
        st.leadAt = os.time() + 10
        BotMakeLeader(id, leader:getName())
    end

    if leader and life then
        life.leaveTown(bot, st)
    end

    if leader and st.trip then
        st.trip = nil -- (2026-11-21: you invited it on its way to the gate; the hunt it had planned is off)
    end

    if leader and st.hunt then
        st.hunt = nil -- it joined you: its own hunt is over
    end

    if leader and st.task and craft then
        craft.drop(bot, st)
    end

    if leader and st.quest and quests then
        quests.drop(bot, st)
    end

    if leader and st.bf and bcnm then
        bcnm.drop(bot, st)
    end

    local camp = (leader and leader:getZoneID() == bot:getZoneID() and st.mode ~= 'stay') and campOf(leader) or nil
    if camp and campPullTurn(bot, st, leader, camp) then
        schedule(bot, token)
        return -- (out pulling for the camp)
    end

    if leader and leader:getZoneID() == bot:getZoneID() then
        local target
        if camp then
            target = campTarget(leader, camp, st)
        else
            target = leader:isEngaged() and leader:getTarget() or nil
        end

        if target and target:isAlive() and st.mode ~= 'stay' then
            st.resting = nil -- (BotHeal(id, false) below stands it up)
            -- assist: attack what the leader attacks, and stand next to it (a mage that does not melee stays behind you)
            local back = partyPlay and partyPlay.stayBack(bot)
            if back then
                if camp then
                    local spot = campSpot(bot, st, camp) -- (at camp: casts from its spot, not next to you)
                    local bp = bot:getPos()
                    if (bp.x - spot.x) ^ 2 + (bp.z - spot.z) ^ 2 > 2.5 * 2.5 and not BotIsMoving(id) then
                        BotMoveTo(id, spot.x, spot.y, spot.z)
                    end
                else
                    BotFollow(id, leader, 6)
                end
            else
                -- (the attack is sent again until the server really has it engaged: a refused packet used to
                --  leave the bot standing next to the monster, sure it was already fighting)
                if not xi.bots.isCasting(bot) and (st.attacking ~= target:getID() or (not bot:isEngaged() and os.time() >= (st.attackAt or 0))) then
                    st.attackAt = os.time() + 3
                    BotHeal(id, false)
                    st.attacking = BotAttack(id, target) and target:getID() or nil
                end

                if not xi.bots.thiefTurn(bot, target) and not xi.bots.flankTurn(bot, target, MELEE_STOP) then
                    BotFollow(id, target, MELEE_STOP)
                end
                -- the server only lets a character swing at (or weapon skill) something it faces
                if not BotIsMoving(id) then
                    pcall(function()
                        bot:lookAt(target:getPos())
                    end)
                end
            end

            -- a pet job in your party: its pet fights what you fight
            if petsMod then
                pcall(petsMod.fight, bot, st, target)
            end

            -- its job: the squad mates' job profile (cures, buffs, provoke, nukes ...), else a weapon skill at 100% TP
            local acted = partyPlay and partyPlay.act(bot, st, leader, target)
            if not acted and not back and hunt and hunt.weaponSkillTurn then
                hunt.weaponSkillTurn(bot, st, target)
            end
        else
            if st.attacking and bot:isEngaged() then
                BotAttackOff(id)
            end

            st.attacking = nil

            -- resting with you: when you /heal, or when it is low and you have stood still for a few seconds;
            -- up again when you move off or a fight starts
            local lp = leader:getPos()
            local moved = st.lpos ~= nil and ((lp.x - st.lpos.x) ^ 2 + (lp.z - st.lpos.z) ^ 2) > 1
            st.lpos = lp
            if moved or not st.stillSince then
                st.stillSince = os.time()
            end

            -- (casters sit for MP too, and stay down until full: 2026-11-17)
            local hurt = bot:getHPP() < 70 or (bot:getMaxMP() > 0 and bot:getMPP() < 75)
            local full = bot:getHPP() >= 100 and (bot:getMaxMP() == 0 or bot:getMPP() >= 100)
            local leaderRests = xi.animation and leader:getAnimation() == xi.animation.HEALING
            -- (2026-11-22, K-Andy: "when you sit down your group should also") when you /heal the bot sits with you even
            -- at full HP and MP, and gets up when you do; on its own it still only sits when it is low
            local wantRest = not camp and (leaderRests or (not full and hurt and os.time() - st.stillSince >= REST_STILL_S))
                and bot:checkDistance(leader) < 10
            if wantRest and not st.resting then
                st.resting = true
                BotStop(id)
                BotHeal(id, true)
            elseif st.resting and not camp and (moved or (full and not leaderRests)) then
                st.resting = nil
                BotHeal(id, false)
            end

            if camp then
                -- holding camp: back to its spot, then rest there when low (the camp rest switch)
                local spot = campSpot(bot, st, camp)
                local bp = bot:getPos()
                local d2 = (bp.x - spot.x) ^ 2 + (bp.z - spot.z) ^ 2
                if d2 > 2.5 * 2.5 and not campStuck(bot, st, d2) then
                    if st.resting then
                        st.resting = nil
                        BotHeal(id, false)
                    end

                    -- (a new plan every think made the walk restart each second: now when it stands, or every 3 s)
                    if not BotIsMoving(id) or os.time() >= (st.campMoveAt or 0) then
                        st.campMoveAt = os.time() + 3
                        BotMoveTo(id, spot.x, spot.y, spot.z)
                    end
                else
                    -- (2026-11-18, Impending Descent: at camp they never sat) they also sit when you /heal, and when a
                    -- little low (the same as away from camp); a last step towards the spot no longer keeps them up
                    local restOn = not (xi.squad and xi.squad.campRestOn) or xi.squad.campRestOn(leader)
                    local low = bot:getHPP() < 80 or (bot:getMaxMP() > 0 and bot:getMPP() < 75)
                    -- (2026-11-22, K-Andy) with you at camp too: full or not, it sits while you /heal
                    if restOn and (leaderRests or (low and not full)) and not st.resting then
                        st.resting = true
                        BotStop(id)
                        BotHeal(id, true)
                    elseif st.resting and full and not leaderRests then
                        st.resting = nil
                        BotHeal(id, false)
                    end
                end
            elseif st.resting then
                -- (sitting: it stays put)
            elseif st.mode == 'follow' then
                BotFollow(id, leader, 3)
            else
                BotStop(id)
            end

            -- between fights: cures and buffs. While resting only a real emergency (someone under 50% HP) gets it up;
            -- a buff or top-up cure used to stand it up for good, so a white mage healed once and then stood
            -- there with no MP (Impending Descent, 2026-11-17)
            local emergency = false
            if st.resting then
                for _, m in pairs(bot:getParty() or {}) do
                    if m:isAlive() and m:getZoneID() == bot:getZoneID() and m:getHPP() < 50 and bot:checkDistance(m) < 20 then
                        emergency = true
                    end
                end
            end

            -- (2026-11-22) a bot that sits only to keep you company (you /heal, it is full) still does its job: before it
            -- sat with you it stood there and cured you, and it must not stop now. Once a cure has cost it MP it is no
            -- longer full, so from then on it rests for itself and only an emergency gets it up.
            if partyPlay and (not st.resting or emergency or (leaderRests and full)) then
                partyPlay.act(bot, st, leader, nil)
            end

            -- still meant to be resting but standing (a cast stood it up): sit back down once the spell is done
            if st.resting and not xi.bots.isCasting(bot) and os.time() >= (st.partyWait or 0)
                and xi.animation and bot:getAnimation() ~= xi.animation.HEALING and not BotIsMoving(id) then
                BotHeal(id, true)
            end
        end
    elseif st.attacking then
        if bot:isEngaged() then
            BotAttackOff(id)
        end

        st.attacking = nil
    end

    -- the leader went to another area: follow a few seconds later (as if it ran after you)
    if leader and leader:getZoneID() ~= bot:getZoneID() and st.mode == 'follow' then
        st.awaySince = st.awaySince or os.time()
        if os.time() - st.awaySince >= ZONE_FOLLOW_S then
            st.awaySince = nil
            local pos = leader:getPos()
            if xi.navguard then xi.navguard.setPos(bot, pos.x + 1, pos.y, pos.z + 1, pos.rot, leader:getZoneID(), pos) else bot:setPos(pos.x + 1, pos.y, pos.z + 1, pos.rot, leader:getZoneID()) end
            return -- it zones now: a new brain starts in the new area (xi.bots.onZoneIn)
        end
    else
        st.awaySince = nil
    end

    -- not with you: crafting / gathering / at the auction house (bots_craft.lua), out hunting (bots_hunt.lua),
    -- or its own life in town (bots_life.lua)
    if not leader and st.trip then
        -- (2026-11-21) on its way to the town gate (bots_gates.lua); it leaves for its hunting area from there
        local okTrip, r = false, nil
        if botExtras then
            okTrip, r = pcall(botExtras.tripThink, bot, st)
        end

        if not okTrip then
            if st.trip and st.trip.hunt ~= nil and st.hunt == st.trip.hunt then
                st.hunt = nil
            end

            st.trip = nil
        elseif r == 'zoning' then
            return -- a new brain starts in the new area
        end
    elseif not leader and craft and st.task then
        local r = craft.think(bot, st)
        if r == 'zoning' then
            return
        elseif r == 'home' and life and life.goHome(bot) then
            return
        end
    elseif not leader and bcnm and st.bf then
        if bcnm.think(bot, st) == 'zoning' then
            return -- a new brain starts in the battlefield's zone
        end
    elseif not leader and hunt and st.hunt then
        local r = hunt.think(bot, st)
        if r == 'zoning' then
            return -- a new brain starts in the new area
        elseif r == 'home' and quests and st.quest and quests.afterHunt(bot, st) == 'zoning' then
            return -- a quest errand is done: back to the questgiver
        elseif r == 'home' and not st.quest and life and life.goHome(bot) then
            return
        end
    elseif not leader and quests and st.quest then
        if quests.think(bot, st) == 'zoning' then
            return
        end
    elseif not leader and life then
        if st.goHome then
            st.goHome = nil
            if life.goHome(bot) then
                return
            end
        end

        -- now and then: time to go out and get some exp
        local t = os.time()
        st.huntCheck = st.huntCheck or (t + math.random(5, 40))
        if t >= st.huntCheck and not bot:isEngaged() then
            st.huntCheck = t + math.random(HUNT_CHECK[1], HUNT_CHECK[2])
            -- new gear now and then (a level up, a job change, or a while since it last looked; bots_gear.lua)
            if gear then
                local okGear, bought = pcall(gear.check, bot)
                if okGear and bought then
                    diary(bot, 'bought some new gear at the ah')
                end
            end

            -- a Summoner (spells from scrolls on): an avatar fight for a pact it doesn't have yet (bots_pets.lua)
            if petsMod and petsMod.avatarFights then
                local okF, won = pcall(petsMod.avatarFights, bot)
                if okF and won then
                    diary(bot, 'won the pact with ' .. won .. '!', true)
                end
            end

            -- a Puppetmaster: automaton attachments it doesn't own yet (bots_pets.lua)
            if petsMod and petsMod.buyAttachments then
                local okA, n = pcall(petsMod.buyAttachments, bot)
                if okA and n and n > 0 then
                    diary(bot, 'bought new attachments for its automaton')
                end
            end

            -- (spells from scrolls) and the spell scrolls it is missing, when it can spare the gil (bots_party.lua)
            if partyPlay and partyPlay.buyScrolls then
                local okS, n = pcall(partyPlay.buyScrolls, bot)
                if okS and n and n > 0 then
                    diary(bot, n > 1 and 'bought a couple of spell scrolls' or 'bought a spell scroll')
                end
            end

            -- its jobs first: subjob quest at 18, levelling the subjob, back to the main job, advanced job quests (bots_jobs.lua)
            local jobPlan = jobs and jobs.next(bot)
            if jobPlan == 'backtomain' then
                jobs.backToMain(bot)
                if gear then
                    pcall(gear.check, bot, true) -- (its own gear back on, and what it needs now)
                end
            elseif jobPlan == 'limitbreak' and quests and math.random() < 0.4 then
                if quests.startSpecial(bot, st, 'a limit break quest', function(b) jobs.limitBreak(b) end) == 'zoning' then
                    return
                end
            elseif jobPlan == 'subquest' and quests and math.random() < 0.6 then
                if quests.startSpecial(bot, st, 'the subjob quest', function(b) jobs.unlockSub(b) end) == 'zoning' then
                    return
                end
            elseif jobPlan == 'levelsub' and hunt and math.random() < 0.5 then
                jobs.startLevelling(bot)
                if gear then
                    pcall(gear.check, bot, true) -- (gear for the job it now plays)
                end
                if hunt.start(bot, st) then
                    return
                end
            elseif jobPlan == 'jobquest' and quests and math.random() < 0.25 then
                local style = craft and craft.styleName(bot) or 'allround'
                if quests.startSpecial(bot, st, 'a job quest', function(b) jobs.unlockAdvanced(b, style) end) == 'zoning' then
                    return
                end
            end

            -- what next? its personality decides (bots_craft.lua); without it: hunting now and then
            local plan = st.quest and 'busy' or (craft and craft.choose(bot)) or ((hunt and hunt.wantsToHunt(bot)) and 'hunt' or 'town')
            if plan == 'busy' then
                plan = 'town'
            end
            -- (a subjob being levelled: mostly hunting)
            if jobs and bot:getCharVar('[Bot]Main') ~= 0 and math.random() < 0.7 then
                plan = 'hunt'
            end
            if plan == 'hunt' and hunt then
                if hunt.start(bot, st) then
                    return -- it zones to its hunting area
                end
            elseif plan == 'quest' then
                local r = quests and quests.start(bot, st, craft and craft.goalName(bot) == 'rank')
                if r == 'zoning' then
                    return
                end
            elseif plan ~= 'town' and craft then
                local r = craft.start(bot, st, plan)
                if r == 'zoning' then
                    return
                end

                if r and life.leaveTown then
                    life.leaveTown(bot, st) -- (stops resting, frees its town spot)
                end
            end
        end

        if not st.hunt and not st.task and not st.quest and life.idle(bot, st) == 'zoning' then
            return -- a new brain starts in the new area
        end
    end

    schedule(bot, token)
end

-----------------------------------
-- callbacks from bots.cpp
-----------------------------------
local loginCount = 0

-- a new brain (after a login or a zone change: the old character object and its timers are gone)
local function startBrain(bot, delay, hello)
    wrapLeaveParty()
    loginCount = loginCount + 1
    local token = loginCount
    local st = state[bot:getID()] or { mode = 'follow' }
    st.token, st.attacking, st.awaySince = token, nil, nil
    state[bot:getID()] = st
    if botExtras then
        pcall(botExtras.onBrain, bot, st) -- (2026-11-21: after a restart its diary is filled from its life story)
    end

    bot:timer(delay, function(b)
        if hello and math.random() < 0.5 then
            chat(b, 0, ({ 'o/', 'hi all', 'hello', 'back :)' })[math.random(1, 4)])
        end

        think(b, token)
    end)
end

xi.bots.onLogin = function(bot)
    state[bot:getID()] = { mode = 'follow' }

    -- the first time: the starting gear a new character gets (race gear, job weapon, nation map and ring)
    if bot:getCharVar('[Bot]Started') == 0 then
        bot:setCharVar('[Bot]Started', 1)
        local ok, err = pcall(xi.player.charCreate, bot)
        if not ok then
            print('[bots] starting gear for ' .. bot:getName() .. ' failed: ' .. tostring(err))
        end
    end

    if craft then
        pcall(craft.personality, bot) -- its personality (and starting gil) on its first day
    end

    if jobs and jobs.fixSub then
        pcall(jobs.fixSub, bot) -- (never WHM/WHM: older versions could leave a bot like that)
    end

    if growth and growth.headStart then
        local ok, err = pcall(growth.headStart, bot) -- (once: the history of a server that has run for months)
        if not ok then
            print('[bots] head start for ' .. bot:getName() .. ' failed: ' .. tostring(err))
        end
    end

    if linkshells then
        pcall(linkshells.onLogin, bot) -- it may join a linkshell
        if linkshells.onBotLogin then
            pcall(linkshells.onBotLogin, bot) -- (and say hi in it, if you are on)
        end
    end

    if growth then
        local ok, err = pcall(growth.catchUp, bot) -- what it did while you were away
        if not ok then
            print('[bots] catching up ' .. bot:getName() .. ' failed: ' .. tostring(err))
        end
    end

    if gear then
        pcall(gear.equipOwned, bot) -- (after a job change the server may have taken pieces off)
    end

    if craft and craft.collectSales then
        pcall(craft.collectSales, bot) -- (what sold while it was away)
    end

    if friends then
        pcall(friends.onLogin, bot) -- (a friend of yours may say hi)
    end

    startBrain(bot, 3000, true)
end

xi.bots.onZoneIn = function(bot)
    startBrain(bot, 1500, false)
end

-- once a second while you play (bots.cpp): the roster and the log in / log out schedule
-- real players who logged in (for linkshell chat and invites); declared here, before xi.bots.onTick uses it
local realPlayers = {}

-- How fast the bots run (bots.cpp moves them itself). RUN_SPEED is yalms per second at normal speed. To check it
-- against you: while you run in a straight line, the map log gets "[bots] your run speed: ..." every 30 seconds.
-- 5.0, not 4.0: your game draws another player running at 5 yalms a second (speed 50). A bot that really covers
-- only 4 reaches each spot late, so its figure ran, waited, ran, waited - the stop-start look. (The log line
-- below reads about 10% high: it counts a 'second' that is really 1.0-1.2 s. Your 5.3-5.7 is a true 5.0.)
local RUN_SPEED = 5.0
local runSpeedSet = false
local runCheck = {}

local function measureRunSpeed(player)
    local id = player:getID()
    local r = runCheck[id] or { dist = 0, secs = 0, logAt = os.time() + 30 }
    runCheck[id] = r
    local pos = player:getPos()
    if r.last and r.lastZone == player:getZoneID() then
        local d = math.sqrt((pos.x - r.last.x) ^ 2 + (pos.z - r.last.z) ^ 2)
        if d > 1.5 and d < 15 and player:getSpeed() == 50 then -- (running, normal speed, not zoning or warping)
            r.dist, r.secs = r.dist + d, r.secs + 1
        end
    end

    r.last, r.lastZone = pos, player:getZoneID()
    if os.time() >= r.logAt then
        r.logAt = os.time() + 30
        if r.secs >= 5 then
            print(string.format('[bots] your run speed: %.2f yalms/s over %d s (bots run at %.2f)', r.dist / r.secs, r.secs, RUN_SPEED))
        end

        r.dist, r.secs = 0, 0
    end
end

xi.bots.onTick = function()
    if not runSpeedSet and BotSetRunSpeed then
        runSpeedSet = true
        pcall(BotSetRunSpeed, RUN_SPEED)
    end

    for id in pairs(realPlayers) do
        local p = GetPlayerByID(id)
        if p then
            pcall(measureRunSpeed, p)
        end
    end

    if talk then
        talk.tick()
    end

    if friends then
        local list = {}
        for id in pairs(realPlayers) do
            local p = GetPlayerByID(id)
            if p then
                list[#list + 1] = p
            end
        end

        local okF, errF = pcall(friends.tick, list)
        if not okF then
            print('[bots] friends: ' .. tostring(errF))
        end
    end

    if linkshells then
        local list = {}
        for id in pairs(realPlayers) do
            local p = GetPlayerByID(id)
            if p then
                list[#list + 1] = p
            else
                realPlayers[id] = nil
            end
        end

        pcall(linkshells.tick, list)
    end

    if tele then
        local list = {}
        for pid in pairs(realPlayers) do
            local p = GetPlayerByID(pid)
            if p then
                list[#list + 1] = p
            end
        end

        local okTele, errTele = pcall(tele.tick, list)
        if not okTele then
            print('[bots] tele: ' .. tostring(errTele))
        end
    end

    if life then
        life.tick()
        if hunt and life.online then
            hunt.tick(life.online)
        end

        if bcnm and life.online then
            pcall(bcnm.tick, life.online)
        end

        if invites then
            local list = {}
            for pid in pairs(realPlayers) do
                local p = GetPlayerByID(pid)
                if p then
                    list[#list + 1] = p
                end
            end

            local ok, err = pcall(invites.tick, list)
            if not ok then
                print('[bots] invites: ' .. tostring(err))
            end
        end
    end
end

-- online bots in an area (crowds.lua makes room for them)
xi.bots.countInZone = function(zoneId)
    return life and life.countInZone(zoneId) or 0
end

-- what a bot knows about itself (for conversations)
local RACE_NAMES = { 'hume', 'hume', 'elvaan', 'elvaan', 'tarutaru', 'tarutaru', 'mithra', 'galka' }
local NATION_NAMES = { [0] = "San d'Oria", [1] = 'Bastok', [2] = 'Windurst' }
local JOB_NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP' }

local function facts(bot)
    local st = state[bot:getID()] or {}
    local f = { level = bot:getMainLvl(), job = JOB_NAMES[bot:getMainJob()] or 'WAR', gil = bot:getGil() }
    pcall(function()
        f.race = RACE_NAMES[bot:getRace()]
        f.nation = NATION_NAMES[bot:getNation()]
        local zone = bot:getZone()
        f.zone = zone and zone:getName():gsub('_', ' ') or nil
    end)
    local doing = (bcnm and bcnm.describe(st)) or (quests and quests.describe(st)) or (craft and craft.describe(st)) or (st.hunt and 'hunting monsters') or (st.life and 'hanging around town') or nil
    if realLeader(bot) then
        doing = 'in a party with ' .. realLeader(bot):getName()
        f.party = realLeader(bot):getName()
    end

    f.doing = (doing or 'hanging around') .. (f.zone and (' in ' .. f.zone) or '')
    f.busy = (st.hunt or st.quest or st.task) and true or false
    if linkshells then
        f.ls = linkshells.of(bot)
        f.lsKind = linkshells.kindOf and linkshells.kindOf(bot) or nil
    end
    if craft then
        pcall(function()
            local style, craftName, helm, craftLvl, goal = craft.styleName(bot)
            f.style, f.craft, f.craftLevel, f.goal, f.helm = style, craftName, craftLvl, goal, helm
        end)
    end

    if quests then
        pcall(function()
            f.rank, f.quests = quests.summary(bot)
            f.story = quests.story and quests.story(bot) or nil
            f.friend = bot:getCharVar('[Bot]Friend') == 1 or nil
            f.gear = gear and gear.describe(bot) or nil
        end)
    end

    -- its recent days, the people it knows, what goes around the server (bots_chat_ai.py: livelier chat)
    pcall(function()
        local ev = {}
        for _, e in ipairs(st.events or {}) do
            ev[#ev + 1] = e.text
        end

        if #ev > 0 then
            f.recent = table.concat(ev, ' | ')
        end

        if st.lastParty then
            f.lastParty = st.lastParty
        end

        if linkshells and linkshells.slotOf and linkshells.onlineMembers then
            local i = linkshells.slotOf(bot)
            if i then
                local mates = {}
                for _, m in ipairs(linkshells.onlineMembers(i)) do
                    if m:getID() ~= bot:getID() and #mates < 3 then
                        mates[#mates + 1] = m:getName()
                    end
                end

                if #mates > 0 then
                    f.lsMates = table.concat(mates, ', ')
                end
            end
        end

        if growth and growth.news then
            local heard = {}
            for _, line in ipairs(growth.news(15)) do
                if not line:find(bot:getName(), 1, true) then
                    heard[#heard + 1] = (line:gsub(' while you were away', ''))
                end
            end

            local pickN = {}
            for _ = 1, math.min(2, #heard) do
                pickN[#pickN + 1] = table.remove(heard, math.random(1, #heard))
            end

            if #pickN > 0 then
                f.gossip = table.concat(pickN, ' | ')
            end
        end
    end)

    -- its personality from the dialogue pack (the AI helper uses it too)
    if dialogue then
        pcall(function()
            local p = dialogue.persona(bot)
            if p then
                f.persona = p.id
            end
        end)
    end

    return f
end

if talk then
    talk.setup(facts)
end

if linkshells then
    linkshells.setup(talk)
end

if dialogue then
    dialogue.setup({ facts = facts })
end

-- (realPlayers, the real players who logged in, is declared before xi.bots.onTick, which uses it)
m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)
    if not (BotIsBot and BotIsBot(player:getID())) then
        realPlayers[player:getID()] = true
        if not zoning and linkshells and linkshells.onPlayerLogin then
            pcall(linkshells.onPlayerLogin, player) -- (your linkshell says hi)
        end

        if not zoning and friends then
            pcall(friends.onPlayerLogin, player) -- (a bot friend online may say hi)
        end
    end

    return result
end)

-- a bot is about to log out (bots_life.lua): it may say bye in its linkshell
xi.bots.beforeLogout = function(id)
    local bot = GetPlayerByID(id)
    if bot and linkshells and linkshells.onBotLogout then
        pcall(linkshells.onBotLogout, bot)
    end
end

xi.bots.lsName = function(bot)
    return linkshells and linkshells.of(bot) or nil
end

-- you shouted or yelled (bots.cpp): a bot white mage may answer a teleport request (bots_tele.lua)
xi.bots.playerShout = function(player, text)
    if tele and not BotIsBot(player:getID()) then
        realPlayers[player:getID()] = true
        local ok, err = pcall(tele.playerShout, player, text or '')
        if not ok then
            print('[bots] tele: ' .. tostring(err))
        end
    end
end

-- you talked in linkshell chat (bots.cpp)
xi.bots.lsChat = function(player, text)
    if linkshells and not BotIsBot(player:getID()) then
        realPlayers[player:getID()] = true
        linkshells.onPlayerChat(player, text or '')
    end

    -- (2026-11-22) your squad mates on the linkshell hear it too (squad_shell.lua)
    if not BotIsBot(player:getID()) and type(xi.squad) == 'table' and type(xi.squad.shell) == 'table' then
        local okShell, err = pcall(xi.squad.shell.onPlayerChat, player, text or '')
        if not okShell then
            print('[squad] linkshell chat: ' .. tostring(err))
        end
    end
end

-- you sent a bot a /tell (bots.cpp)
-- "do u want a party?" in a tell: the bot joins you instead of waiting for an invite. An invite cannot be
-- used for this - the client cannot target anyone in another area, and the server refuses an invite when you
-- are already in a party (you and Kurami normally are) - so the tell itself does the work. It joins, then the
-- follow brain sends it to you a few seconds later.
local function partyAsk(text)
    local lower = string.lower(text or '')
    local mentions = lower:find('party', 1, true)
        or lower:find('%f[%a]pt%f[%A]')
        or lower:find('invite', 1, true)
        or lower:find('%f[%a]inv%f[%A]')

    if not mentions then
        return false
    end

    return lower:find('?', 1, true) ~= nil
        or lower:find('want', 1, true) ~= nil
        or lower:find('need', 1, true) ~= nil
        or lower:find('join', 1, true) ~= nil
        or lower:find('invite', 1, true) ~= nil
end

local function joinAskedParty(bot, from)
    local id = bot:getID()
    local player = GetPlayerByName(from)

    if not player then
        return false
    end

    local playerId = player:getID()
    local party = player:getParty() or {}
    local withTrusts = 0
    local okTrusts, total = pcall(function()
        return #player:getPartyWithTrusts()
    end)

    if okTrusts and type(total) == 'number' then
        withTrusts = math.max(0, total - #party)
    end

    -- (squad mates take party places too; since 2026-11-11 a bot can join while they are out)
    if #party + withTrusts >= 6 then
        BotTell(id, from, 'your party is full, sorry')
        return true
    end

    local function joined()
        local st = state[id] or { mode = 'follow' }
        st.mode, st.awaySince, st.attacking = 'follow', nil, nil
        st.hunt, st.bf, st.task = nil, nil, nil
        state[id] = st

        local leader = GetPlayerByName(from)
        if leader then
            if bot:getPartyLeader() and bot:getPartyLeader():getID() == id then
                BotMakeLeader(id, from)
            end
            BotFollow(id, leader, 3)
        end

        BotTell(id, from, ({ 'ok, joining you - on my way', 'sure! coming to you', 'yes! otw' })[math.random(1, 3)])
    end

    local function tryJoin(attempt)
        if BotJoinParty(id, playerId) then
            joined()
            return
        end

        -- the leave, or a party update, can still be in flight: try again before giving up
        if attempt < 3 then
            bot:timer(1200, function()
                tryJoin(attempt + 1)
            end)
            return
        end

        BotTell(id, from, 'could not join you, sorry')
    end

    if bot:getPartySize() > 1 then
        -- it is in its own bot party: leaving is a packet, so join a moment after it lands
        BotLeaveParty(id)
        bot:timer(1800, function()
            tryJoin(1)
        end)
        return true
    end

    tryJoin(1)
    return true
end

if tele then
    tele.setup(state, { join = joinAskedParty })
end

if friends then
    friends.setup({ state = state, join = joinAskedParty, dialogue = dialogue, linkshells = linkshells, life = life })
end

xi.bots.onTell = function(bot, t)
    -- (in the log, so a tell that "did nothing" can be told apart from a tell that never arrived)
    if type(t) == 'table' then
        print(string.format('[bots] tell from %s to %s: %s', tostring(t.from), bot:getName(), tostring(t.text):sub(1, 80)))
    end

    if tele and type(t) == 'table' then
        local okTele, handled = pcall(tele.onTell, bot, t.from, t.text or '')
        if okTele and handled then
            return -- (it wanted a teleport, and you answered)
        end
    end

    -- (2026-11-23) about its selling / buying offer (bots_trade.lua): it answers about the real item and price
    if type(t) == 'table' then
        local okT, trade = pcall(require, 'modules/custom/lua/bots_trade')
        if okT and type(trade) == 'table' then
            local okH, handled = pcall(trade.onTell, bot, t.from, t.text or '')
            if okH and handled then
                return
            end
        end
    end

    if linkshells and type(t) == 'table' and linkshells.askedPearl(bot, t.from, t.text) then
        return -- (it sent you a pearl, and said so)
    end

    if friends and type(t) == 'table' then
        local okF, handled = pcall(friends.onTell, bot, t.from, t.text or '')
        if okF and handled then
            return -- ("can I add you?", or your answer to its offer to come and help)
        end
    end

    if type(t) == 'table' and type(t.text) == 'string' and partyAsk(t.text) and joinAskedParty(bot, t.from) then
        return -- the bot answered for itself (joining, or saying why it cannot)
    end

    if talk and type(t) == 'table' then
        talk.onTell(bot, t.from, t.text or '')
    end
end

-- you sent a bot a friend request (the friend list; bots.cpp sweeps the requests): true = accept, nil = not yet
-- (bots_friends.lua: it accepts when it knows you well enough); without bots_friends.lua it always accepts
xi.bots.onFriendRequest = function(bot, t)
    local from = type(t) == 'table' and t.from or nil
    if friends then
        local okF, answer = pcall(friends.onRequest, bot, from)
        if okF then
            return answer
        end

        print('[bots] friends: ' .. tostring(answer))
    end

    bot:setCharVar('[Bot]Friend', 1)
    print(string.format('[bots] %s accepts a friend request from %s', bot:getName(), tostring(from)))
    if from and from ~= '' then
        local lines = { 'accepted your friend request :)', 'added you back!', 'hey, accepted! hit me up anytime', 'friend request accepted o/', 'sure, added :)' }
        bot:timer(math.random(4, 15) * 1000, function(b)
            BotTell(b:getID(), from, lines[math.random(1, #lines)])
        end)
    end

    return true
end

-- a message you sent a bot (the friend list's mail; bots.cpp reads its mailbox while it is on): you are on, so it
-- answers by tell like any tell; you are off, it writes back (bots_friends.lua)
xi.bots.onMessage = function(bot, t)
    if type(t) ~= 'table' or not t.from or t.from == '' then
        return
    end

    local p = GetPlayerByName(t.from)
    if p and not BotIsBot(p:getID()) then
        xi.bots.onTell(bot, { from = t.from, text = t.text or '' })
    elseif friends then
        pcall(friends.onMessage, bot, t.from, t.text or '')
    end
end

-- your answer to a bot's friend request (accepted = true / false)
-- (2026-11-21) a player gave the bot something by trade (bots.cpp)
xi.bots.onGift = function(bot, t)
    if friends and type(t) == 'table' and friends.onGift then
        pcall(friends.onGift, bot, t.from)
    end
end

xi.bots.onFriendReply = function(bot, t)
    if friends and type(t) == 'table' then
        pcall(friends.onReply, bot, t.from, t.accepted == true)
    end
end

-- for squad.lua (squad chat): the bot players around you, your bot friends online, your bot linkshell, and the
-- bots in your party. { near = { {name, job, level}... }, friends = {...}, party = {...}, ls = name or nil }
local JOB_NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP' }
xi.bots.worldFor = function(player)
    local out = { near = {}, friends = {}, party = {} }
    local function row(e)
        return { name = e:getName(), job = JOB_NAMES[e:getMainJob()] or 'WAR', level = e:getMainLvl() }
    end

    local mine = {}
    for _, member in pairs(player:getParty() or {}) do
        if member:getObjType() == xi.objType.PC and BotIsBot(member:getID()) then
            out.party[#out.party + 1] = row(member)
            mine[member:getID()] = true
        end
    end

    local zone, pos = player:getZoneID(), player:getPos()
    for id, r in pairs(BotList()) do
        if r.online then
            local e = GetPlayerByID(id)
            if e then
                if e:getCharVar('[Bot]Friend') == 1 and #out.friends < 10 then
                    out.friends[#out.friends + 1] = row(e)
                end

                if e:getZoneID() == zone and #out.near < 6 then
                    local p = e:getPos()
                    local dx, dz = p.x - pos.x, p.z - pos.z
                    if dx * dx + dz * dz < 25 * 25 and not mine[id] then
                        out.near[#out.near + 1] = row(e)
                    end
                end
            end
        end
    end

    local i = player:getCharVar('[Bots]LS')
    if i > 0 and linkshells then
        out.ls = linkshells.names()[i]
    end

    return out
end

xi.bots.onInvite = function(bot, inviterName)
    local id = bot:getID()
    BotAnswerInvite(id, true)
    if tele then
        pcall(tele.onInvite, bot, inviterName)
    end

    bot:timer(2500, function(b)
        if b:getPartySize() <= 1 then
            return
        end

        local leader = b:getPartyLeader()
        if leader and leader:getObjType() == xi.objType.PC and not BotIsBot(leader:getID()) then
            -- joined a real player: follow them, and drop any bot-party plan it had
            local st = state[id] or { mode = 'follow' }
            st.mode, st.awaySince, st.attacking = 'follow', nil, nil
            st.hunt, st.bf, st.task = nil, nil, nil
            state[id] = st

            -- look the leader up by name again: the character object changes when they zone
            leader = GetPlayerByName(leader:getName())
            if leader then
                BotFollow(id, leader, 3)
            end
        end

        chat(b, 4, ({ 'o/ thanks for the invite!', 'hi! ty for inv', 'o/', 'hey, ready when you are' })[math.random(1, 4)])
    end)
end

-----------------------------------
-- !bots
-----------------------------------
local cmd = {}
cmd.cmdprops = { permission = 0, parameters = 'ssss' }

cmd.onTrigger = function(player, action, a1, a2, a3)
    -- co-op: a visitor from a friend's world cannot use the owner's commands (modules/custom/late/coop.lua)
    if xi.coop and xi.coop.blockGuest and xi.coop.blockGuest(player, 'bots', action) then
        return
    end

    if not moduleBuilt() then
        tell(player, 'The bot module is not built yet: run the rebuild (rebuild.ps1 -Reconfigure), then STOP and PLAY.')
        return
    end

    action = string.lower(action or '')

    if action == '' and life then
        local c = life.config()
        local total, online = life.status()
        tell(player, string.format('Roster %s: %d of %d characters, %d of %d online (%d in this area, %d out hunting). !bots list | online <n> | on | off',
            c.enabled and 'ON' or 'OFF', total, life.target and life.target() or c.roster, online, math.min(c.online, total), life.countInZone(player:getZoneID()), hunt and hunt.count() or 0))
    elseif action == 'friends' then
        if not friends then
            tell(player, 'Bot friendships are off (bots_friends.lua did not load: see the map server log).')
            return
        end

        for _, text in ipairs(friends.report(player)) do
            tell(player, text)
        end
    elseif action == 'dialogue' then
        if not dialogue then
            tell(player, 'Written dialogue is off (bots_dialogue.lua did not load: see the map server log).')
            return
        end

        tell(player, dialogue.stats())
        if string.lower(a1 or '') == 'test' and linkshells and linkshells.dialogueTest then
            tell(player, linkshells.dialogueTest(player))
        else
            tell(player, '!bots dialogue test - a member of your bot linkshell says something now')
        end
    elseif action == 'online' and life then
        local n = tonumber(a1)
        if not n then
            tell(player, 'Usage: !bots online <0-1500>')
            return
        end

        life.config().online = math.max(0, math.min(1500, math.floor(n)))
        tell(player, 'Bots online at a time: ' .. life.config().online .. ' (they log in or out over the next minutes)')
    elseif (action == 'on' or action == 'off') and life then
        life.config().enabled = action == 'on'
        tell(player, action == 'on' and 'Roster ON: bots log in over the next minutes.' or 'Roster OFF: the bots log out (not the ones in your party).')
    elseif action == 'hunt' and hunt then
        local id, bot = botByName(a1)
        if not id or not bot then
            tell(player, 'Usage: !bots hunt <Name>  (the bot must be online)')
            return
        end

        local st = state[id]
        if not st or bot:getPartySize() > 1 then
            tell(player, bot:getName() .. ' is busy (in a party).')
            return
        end

        if hunt.start(bot, st) or st.hunt then
            -- (2026-11-21: st.trip = it runs to the town gate first, bots_gates.lua)
            tell(player, string.format('%s (Lv%d) goes hunting in area %d%s.', bot:getName(), bot:getMainLvl(), st.hunt and st.hunt.zone or bot:getZoneID(),
                st.trip and ' (it runs to the town gate first)' or ''))
        else
            tell(player, bot:getName() .. ' found no camp for its level right now (try again in a minute).')
        end
    elseif (action == 'craft' or action == 'gather' or action == 'market' or action == 'fish') and craft then
        local id, bot = botByName(a1)
        if not id or not bot or not state[id] then
            tell(player, 'Usage: !bots ' .. action .. ' <Name>  (the bot must be online)')
            return
        end

        local st = state[id]
        if bot:getPartySize() > 1 then
            tell(player, bot:getName() .. ' is busy (in a party).')
            return
        end

        if not craft.ready() then
            tell(player, 'Crafting, gathering and the auction house need the rebuild (rebuild.ps1 -Reconfigure), then STOP and PLAY.')
            return
        end

        st.hunt = nil
        local r = craft.start(bot, st, action)
        tell(player, r and (bot:getName() .. ': ' .. (craft.describe(st) or action)) or (bot:getName() .. ' cannot do that right now (gil, materials, tools or no place for its level).'))
    elseif action == 'quest' and quests then
        local id, bot = botByName(a1)
        if not id or not bot or not state[id] then
            tell(player, 'Usage: !bots quest <Name>  (the bot must be online)')
            return
        end

        if bot:getPartySize() > 1 then
            tell(player, bot:getName() .. ' is busy (in a party).')
            return
        end

        local st = state[id]
        st.hunt = nil
        local r = quests.start(bot, st, a2 == 'mission')
        tell(player, r and (bot:getName() .. ': ' .. (quests.describe(st) or 'quest')) or (bot:getName() .. ' has no quest or mission for its level right now.'))
    elseif action == 'invites' and invites then
        local w = a1 and string.lower(a1) or ''
        if w == 'on' or w == 'off' then
            invites.setEnabled(player, w == 'on')
        end

        tell(player, 'Bot parties may invite you: ' .. (invites.enabled(player) and 'ON' or 'OFF') ..
            ' (only while your Seek Party flag is on, no trusts out, not in a party).  !bots invites on|off')
    elseif action == 'parties' then
        -- every bot party right now: where it is and who is in it (the leader first)
        local shown = 0
        for id in pairs(state) do
            local b = BotIsBot(id) and GetPlayerByID(id) or nil
            local leader = b and b:getPartySize() > 1 and b:getPartyLeader() or nil
            if leader and leader:getID() == id and shown < 15 then
                local names = { string.format('%s (%s%d)', b:getName(), DIARY_JOBS[b:getMainJob()] or '?', b:getMainLvl()) }
                for _, mbr in pairs(b:getParty() or {}) do
                    if mbr:getID() ~= id then
                        names[#names + 1] = string.format('%s (%s%d)', mbr:getName(), DIARY_JOBS[mbr:getMainJob()] or '?', mbr:getMainLvl())
                    end
                end

                local zone = b:getZone()
                local where = zone and zone:getName():gsub('_', ' ') or '?'
                tell(player, string.format('%s: %s', where, table.concat(names, ', ')))
                shown = shown + 1
            end
        end

        tell(player, shown == 0 and 'No bot parties right now (one forms every minute or so from level 10+ bots idling in town).' or (shown .. ' bot part' .. (shown == 1 and 'y' or 'ies') .. ' (leader first).'))
    elseif action == 'story' then
        -- (2026-11-21) a bot's life story (bots_story.lua): !bots story <Name>
        local lines = a1 and botExtras and botExtras.storyLines and botExtras.storyLines(a1, 12) or nil
        if not a1 then
            tell(player, 'Usage: !bots story <Name>')
        elseif not lines then
            tell(player, 'Life stories are not loaded (bots_story.lua).')
        elseif #lines == 0 then
            tell(player, a1 .. ' has no story yet (it starts with the next thing worth remembering; names are case sensitive).')
        else
            tell(player, a1 .. ', newest first:')
            for _, line in ipairs(lines) do
                tell(player, '  ' .. line)
            end
        end
    elseif action == 'news' and growth then
        local list = growth.news(10)
        tell(player, #list == 0 and 'No news yet (the bots catch up at their next log in).' or ('News (pace: ' .. growth.pace() .. '):'))
        for _, line in ipairs(list) do
            tell(player, '  ' .. line)
        end
    elseif action == 'growth' and growth then
        if a1 and growth.setPace(string.lower(a1)) then
            tell(player, 'Bots grow while you are away: ' .. growth.pace() .. ' (until the next PLAY; the launcher setting is used then)')
        else
            tell(player, 'Usage: !bots growth off|realistic|fast   (now: ' .. growth.pace() .. ')')
        end
    elseif action == 'where' then
        local id, bot = botByName(a1)
        if not id or not bot then
            tell(player, 'Usage: !bots where <Name>  (the bot must be online)')
            return
        end

        local st = state[id] or {}
        local doing = (bcnm and bcnm.describe(st)) or (quests and quests.describe(st)) or (craft and craft.describe(st)) or (st.hunt and ('hunting (' .. (st.hunt.phase or '?') .. ')')) or (st.life and ('in town (' .. (st.life.kind or st.life.phase or '?') .. ')')) or 'with you'
        local pos = bot:getPos()
        tell(player, string.format('%s Lv%d: area %d at (%.0f, %.0f), %s, HP %d%%.', bot:getName(), bot:getMainLvl(), bot:getZoneID(), pos.x, pos.z, doing, bot:getHPP()))
        if craft then
            local style, craftName, helm, craftLvl, goal = craft.styleName(bot)
            tell(player, string.format('  %s: %s, %s %d, likes %s, %d gil. Goal: %s.', bot:getName(), style, craftName, craftLvl, helm, bot:getGil(), goal or '?'))
            if jobs then
                local sub = bot:getSubJob()
                tell(player, string.format('  %s: %s%d%s%s.', bot:getName(), jobs.jobName(bot:getMainJob()), bot:getMainLvl(),
                    (sub and sub ~= 0) and ('/' .. jobs.jobName(sub) .. bot:getSubLvl()) or '',
                    bot:getCharVar('[Bot]Main') ~= 0 and (', levelling it as a subjob for ' .. jobs.jobName(bot:getCharVar('[Bot]Main'))) or ''))
            end
            if quests then
                local rank, done = quests.summary(bot)
                tell(player, string.format('  %s: nation rank %d, %d quests and missions done.', bot:getName(), rank, done))
            end
        end
    elseif action == '' or action == 'list' then
        local rows = {}
        for id, row in pairs(BotList()) do
            rows[#rows + 1] = string.format('%s%s', row.name or ('#' .. id), row.online and ' (online)' or '')
        end

        if #rows == 0 then
            tell(player, 'No bots yet. Make one: !bots create <Name>')
            return
        end

        table.sort(rows)
        tell(player, #rows .. ' bot(s):')
        for i = 1, #rows, 10 do
            tell(player, table.concat(rows, ', ', i, math.min(#rows, i + 9)))
        end
    elseif action == 'create' then
        local name = a1 and (string.upper(a1:sub(1, 1)) .. string.lower(a1:sub(2))) or nil
        if not name then
            tell(player, 'Usage: !bots create <Name> [race] [job]')
            return
        end

        local race = RACES[string.lower(a2 or '')] or math.random(1, 8)
        local job = JOBS[string.upper(a3 or '')] or math.random(1, 6)
        local pos = player:getPos()
        local id, msg = BotCreate(name, race, math.random(0, 15), job, player:getNation(), player:getZoneID(), pos.x + 1.5, pos.y, pos.z + 1.5)
        if id == 0 then
            tell(player, 'Could not create ' .. name .. ': ' .. tostring(msg))
            return
        end

        local ok, lmsg = BotLogin(id)
        tell(player, string.format('%s created (%s). %s', name, msg, ok and 'Logged in next to you.' or ('Log in failed: ' .. tostring(lmsg))))
    elseif action == 'login' or action == 'logout' then
        local ids = {}
        if string.lower(a1 or '') == 'all' then
            ids = allBotIds()
        else
            local id = botByName(a1)
            if id then
                ids = { id }
            end
        end

        if #ids == 0 then
            tell(player, 'Usage: !bots ' .. action .. ' <Name|all>  (name not found)')
            return
        end

        local done = 0
        for _, id in ipairs(ids) do
            if action == 'login' then
                local ok, msg = BotLogin(id)
                if ok then
                    done = done + 1
                else
                    tell(player, 'Bot #' .. id .. ': ' .. tostring(msg))
                end
            else
                BotLogout(id)
                done = done + 1
            end
        end

        tell(player, string.format('%s: %d', action == 'login' and 'Logged in' or 'Logged out', done))
    elseif action == 'come' then
        local id, bot = botByName(a1)
        if not id or not bot then
            tell(player, 'Usage: !bots come <Name>  (the bot must be online)')
            return
        end

        local pos = player:getPos()
        if bot:getZoneID() == player:getZoneID() then
            BotMoveTo(id, pos.x, pos.y, pos.z)
            tell(player, bot:getName() .. ' is coming.')
        else
            if xi.navguard then xi.navguard.setPos(bot, pos.x + 1, pos.y, pos.z + 1, pos.rot, player:getZoneID(), pos) else bot:setPos(pos.x + 1, pos.y, pos.z + 1, pos.rot, player:getZoneID()) end
            tell(player, bot:getName() .. ' is on the way (zoning).')
        end
    elseif action == 'invite' then
        local id, bot = botByName(a1)
        if not id or not bot then
            tell(player, 'Usage: !bots invite <Name>  (the bot must be online)')
            return
        end

        local ok, withTrusts = pcall(function()
            return #player:getPartyWithTrusts() > #player:getParty()
        end)
        if bot:getPartySize() > 1 then
            tell(player, bot:getName() .. ' is already in a party.')
            return
        end

        -- you already have a party (your squad is out, or Kurami is with you): an invite to you would be refused,
        -- so the bot joins yours directly
        if (ok and withTrusts) or player:getPartySize() > 1 then
            if BotJoinParty(id, player:getID()) then
                tell(player, bot:getName() .. ' joined your party.')
            else
                tell(player, bot:getName() .. ' could not join: your party is full (squad mates count), or you are not its leader.')
            end

            return
        end

        if BotInvite(id, player) then
            tell(player, bot:getName() .. ' sent you a party invite: type /join')
        else
            tell(player, bot:getName() .. ' could not send the invite.')
        end
    elseif action == 'say' then
        local id, bot = botByName(a1)
        if not id or not bot then
            tell(player, 'Usage: !bots say <Name> <text>')
            return
        end

        chat(bot, 0, table.concat({ a2 or '', a3 or '' }, ' '))
    else
        tell(player, 'Usage: !bots [list|create <Name> [race] [job]|login <Name|all>|logout <Name|all>|come <Name>|invite <Name>|say <Name> <text>|online <n>|on|off|hunt|craft|gather|market|fish|quest <Name>|where <Name>|parties|news|growth <pace>]')
    end
end

xi.module.registerCommand('bots', cmd)

-- co-op: the launcher's CO-OP page lowers (or raises) how many bots are online while friends are visiting, without a
-- restart (modules/custom/late/coop.lua reads its request). The same as !bots online <n>.
xi.bots.setOnline = function(n)
    n = tonumber(n)
    if not (life and n) then
        return false
    end

    life.config().online = math.max(0, math.min(1500, math.floor(n)))
    return true
end

-----------------------------------
-- party chat orders: "follow", "stay", "attack", "stop" (from a real player in the bot's party)
-----------------------------------
-- (2026-11-21, Sunie: "ask a bot to take an action") a bot player in your party casts a spell you ask for in party
-- chat, the way squad mates do: "/p protect", "/p cure ii sunie", "/p haste me", "/p Belan protect". The bot has to
-- know the spell, be able to use it on its current main or support job at its level, have the MP, and the spell must
-- be off recast. Returns true when the line was a spell request (handled or answered).
local REQUEST_FILLER = { please = true, pls = true, plz = true, can = true, could = true, you = true, someone = true,
    cast = true, give = true, some = true, a = true, on = true, to = true, ['for'] = true }

local function requestCanCast(bot, spellId)
    if not bot:hasSpell(spellId) then
        return false, 'unknown'
    end

    local okS, sp = pcall(GetSpell, spellId)
    if not okS or sp == nil then
        return false, 'unknown'
    end

    local okL, mainLvl = pcall(function() return sp:getLevel(bot:getMainJob()) end)
    local okS2, subLvl = pcall(function() return sp:getLevel(bot:getSubJob()) end)
    local usable = (okL and mainLvl and mainLvl > 0 and mainLvl <= bot:getMainLvl()) or
                   (okS2 and subLvl and subLvl > 0 and subLvl <= bot:getSubLvl())
    if not usable then
        return false, 'job'
    end

    if bot:getMP() < (sp:getMPCost() or 0) then
        return false, 'mp'
    end

    if bot:hasRecast(xi.recast.MAGIC, spellId) then
        return false, 'recast'
    end

    return true
end

local function spellRequest(player, text)
    local words = {}
    -- (v0.3.3, G10) apostrophes disappear, the way the squad mates read a line ("Mage's Ballad" is MAGES_BALLAD; before it was the key MAGE'S_BALLAD)
    local lowered, wordPattern = string.lower(text or ''), "[%a']+"
    if xi.squad ~= nil and xi.squad.requestsOn ~= nil and xi.squad.requestsOn(player) then
        lowered, wordPattern = lowered:gsub("'", ''), '%a+'
    end

    for w in string.gmatch(lowered, wordPattern) do
        if not REQUEST_FILLER[w] then
            words[#words + 1] = w
        end
    end

    if #words == 0 or #words > 6 then
        return false
    end

    local bots, people = {}, {}
    for _, member in pairs(player:getPartyWithTrusts() or {}) do
        if member:getZoneID() == player:getZoneID() then
            people[string.lower(member:getName())] = member
            if member:getObjType() == xi.objType.TRUST then
                people[string.lower(member:getPacketName())] = member -- (a squad mate goes by its own name)
            end
            if member:getObjType() == xi.objType.PC and BotIsBot(member:getID()) and member:isAlive() then
                bots[#bots + 1] = member
            end
        end
    end

    if #bots == 0 then
        return false
    end

    -- an optional bot name first ("Belan protect")
    local first, asked = 1, nil
    local named = people[words[1]]
    if named and named:getObjType() == xi.objType.PC and BotIsBot(named:getID()) then
        asked, first = named, 2
    end

    -- the longest spell name from there (cure ii, protect, haste...)
    local spellId, last = nil, nil
    for n = math.min(3, #words - first + 1), 1, -1 do
        local key = string.upper(table.concat(words, '_', first, first + n - 1))
        if xi.magic.spell[key] then
            spellId, last = xi.magic.spell[key], first + n - 1
            break
        end
    end

    if not spellId then
        return false
    end

    -- who it is for: a party member's name after the spell, or you
    local target = player
    local rest = words[last + 1]
    if rest and rest ~= 'me' and rest ~= 'myself' and people[rest] then
        target = people[rest]
    end

    -- (v0.3.3, G1/G16) a squad mate took this request (or the same one is on its way): one answerer, one cast
    local squad = xi.squad
    if squad ~= nil and squad.requestTaken ~= nil and squad.requestTaken(player, spellId, target) then
        return true
    end

    local spellName = table.concat(words, ' ', first, last)

    -- (v0.3.3, G9) a Raise goes on someone who is knocked out. "raise" with nobody named means the first fallen member of your party; a standing
    -- target is no Raise. Before the bot said "sure, raise coming" and cast it at you standing there.
    local kind = type(SquadSpellKind) == 'function' and SquadSpellKind(spellId) or ''
    if kind == 'dead' and squad ~= nil and squad.requestsOn ~= nil and squad.requestsOn(player) then
        if target == player and player:isAlive() then
            for _, member in pairs(player:getParty() or {}) do
                if target == player and member:getObjType() == xi.objType.PC and member:isDead() and member:getZoneID() == player:getZoneID() then
                    target = member
                end
            end
        end

        if target:isAlive() then
            if asked then
                asked:timer(math.random(800, 1600), function(b)
                    chat(b, 4, target:getID() == player:getID() and 'you are standing, nobody needs a raise' or (target:getName() .. ' is standing'))
                end)
            end

            return true
        end
    end

    -- (v0.3.3, G6) a spell that only works on its caster (Warp, Escape, Reraise, Utsusemi) cannot be put on you: no "sure, warp coming" and a cast the
    -- server refuses. A bot you named says so; a general request stays quiet like any request nobody can do.
    -- (2026-11-24) Barwatera, Protectra and the other -ra spells are aimed at the caster but cover the party: not self-only
    local aroundCaster = squad ~= nil and squad.areaAroundCaster ~= nil and squad.areaAroundCaster(spellId)
    if kind == 'self' and not aroundCaster and squad ~= nil and squad.requestsOn ~= nil and squad.requestsOn(player) then
        if asked then
            asked:timer(math.random(800, 1600), function(b)
                chat(b, 4, spellName .. ' only works on myself')
            end)
        end

        return true
    end

    local caster, why = nil, nil
    for _, bot in ipairs(asked and { asked } or bots) do
        local ok, reason = requestCanCast(bot, spellId)
        if ok and bot:checkDistance(target) <= 20 then
            caster = bot
            break
        end

        why = why or reason
    end

    if not caster then
        -- only a bot you named answers "can't"; a general request nobody can do stays quiet
        if asked then
            local line = ({ job = "can't cast " .. spellName .. ' on this job', mp = 'not enough mp for that',
                            recast = 'not ready yet, gimme a sec', unknown = "don't have " .. spellName })[why or 'unknown']
            asked:timer(math.random(800, 1600), function(b)
                chat(b, 4, line)
            end)
        end

        return true
    end

    -- (v0.3.3, G11; extras: !sqreq more on) one price for a Teleport: a bot white mage that you shout for asks for gil, and the same Teleport asked in
    -- party chat was free. Asked in party chat it now costs what the shout would have, paid when it casts.
    if squad ~= nil and squad.requestsMore ~= nil and squad.requestsMore(player) and teleOk and tele ~= nil and tele.priceForSpell ~= nil then
        local fee, crag = tele.priceForSpell(spellId)
        if fee ~= nil then
            if player:getGil() < fee then
                caster:timer(math.random(800, 1600), function(b)
                    chat(b, 4, 'Teleport-' .. crag .. ' is ' .. fee .. ' gil from me, you need that first')
                end)

                return true
            end

            player:delGil(fee)
            caster:addGil(fee)
            spellName = spellName .. ' (' .. fee .. ' gil)'
        end
    end

    if squad ~= nil and squad.requestClaim ~= nil then
        squad.requestClaim(player, spellId, target)
    end

    local st = state[caster:getID()] or {}
    state[caster:getID()] = st
    st.partyWait = os.time() + 6 -- (its own party play waits for this cast)
    local forYou = target:getID() == player:getID()
    caster:timer(math.random(700, 1500), function(b)
        chat(b, 4, forYou and ('sure, ' .. spellName .. ' coming') or (spellName .. ' on ' .. target:getName()))
        BotCast(b:getID(), spellId, target)
    end)

    return true
end

xi.bots.partyOrder = function(player, text)
    -- (v0.3.3, G1) a line a squad mate already took is not answered a second time, by a spell request or by chatter
    if xi.squad ~= nil and xi.squad.lineTaken ~= nil and xi.squad.lineTaken(player, text) then
        return
    end

    if spellRequest(player, text) then
        return
    end

    local word = string.lower((text or ''):match('^%s*(%a+)') or '')
    if word ~= 'follow' and word ~= 'stay' and word ~= 'attack' and word ~= 'stop' and word ~= 'release' then
        -- not an order: party talk (a bot may answer)
        if talk then
            local list = {}
            for _, member in pairs(player:getParty() or {}) do
                if member:getObjType() == xi.objType.PC and BotIsBot(member:getID()) and member:getZoneID() == player:getZoneID() then
                    list[#list + 1] = member
                end
            end

            talk.onParty(player, text or '', list)
        end

        return
    end

    -- (v0.3.3, G18) every bot obeys, one of them answers: five "k, following" for one "follow" was five lines for one order
    local answered = false
    local oneVoice = xi.squad ~= nil and xi.squad.requestsOn ~= nil and xi.squad.requestsOn(player)
    for _, member in pairs(player:getParty() or {}) do
        local id = member:getID()
        if member:getObjType() == xi.objType.PC and BotIsBot(id) then
            local st = state[id] or {}
            state[id] = st
            if word == 'follow' then
                st.mode = 'follow'
            elseif word == 'stay' then
                st.mode = 'stay'
                BotStop(id)
            elseif word == 'release' then
                if member:isDead() then
                    st.releaseNow = true -- (the dead branch of its brain sends it to its Home Point)
                end
            elseif word == 'stop' then
                st.attacking = nil
                BotAttackOff(id)
                BotStop(id)
            elseif word == 'attack' then
                local t = player:getCursorTarget() or player:getTarget()
                if t and t:isAlive() and t:getObjType() == xi.objType.MOB then
                    st.attacking = t:getID()
                    BotAttack(id, t)
                    BotFollow(id, t, MELEE_STOP)
                end
            end

            member:timer(math.random(500, 1500), function(b)
                local line = ({ follow = 'k, following', stay = 'k, staying here', stop = 'stopping', attack = 'on it',
                                release = b:isDead() and 'ok, see you back in town' or nil })[word]
                if line and not (oneVoice and answered) then
                    answered = true
                    chat(b, 4, line)
                end
            end)
        end
    end
end

-- (2026-11-23, Yenkei) !squad attack / !squad stop (squad.lua) order the bot players in your party too, as "attack" /
-- "stop" in party chat do. Returns how many bots took the order.
xi.bots.partyOrder = function(player, word, mob)
    local n = 0
    for _, member in pairs(player:getParty() or {}) do
        local id = member:getID()
        if member:getObjType() == xi.objType.PC and BotIsBot and BotIsBot(id) and member:getZoneID() == player:getZoneID() and member:isAlive() then
            local st = state[id] or {}
            state[id] = st
            if word == 'attack' and mob ~= nil then
                st.attacking = mob:getID()
                BotAttack(id, mob)
                BotFollow(id, mob, MELEE_STOP)
            elseif word == 'stop' then
                st.attacking = nil
                BotAttackOff(id)
                BotStop(id)
            end

            n = n + 1
        end
    end

    return n
end

return m
