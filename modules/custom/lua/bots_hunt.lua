-----------------------------------
-- FFXI Offline: bot players, step 4.4a - out in the field: fighting monsters for real exp. Used by bots.lua.
--
-- A bot that is not with you sometimes goes hunting (more often the lower its level):
--   alone (any level): monsters "easy prey" to "decent challenge" for its level, in its nation's starting areas,
--     then the next areas out (La Theine / Konschtat / Tahrongi, Valkurm, Jugner, Buburimu, Qufim ...).
--   in a bot party (level 10+): 3-6 bots of about the same level team up (a real party: one invites the others),
--     meet at a camp, the leader pulls, everyone attacks its target, the healer cures, they rest together.
-- Real fights through the same packets a game client sends: real exp, level ups, real deaths (then Home Point).
-- They learn their job's spells as they level (as if they bought the scrolls) and use weapon skills at 100% TP.
-- Same rules as the field parties: never a monster within 40 yalms of you or Kurami (unless you stand at its
-- camp and watch), never a monster someone is fighting, never camps near you, never NMs.
-----------------------------------
local H = {}

local DATA_PATH = 'modules/custom/lua/crowds_data'

local PLAYER_SPACE  = 40    -- yalms: monsters this close to a real player are left alone ...
local WATCH_RANGE   = 30    -- ... unless that player stands this close to the bot (watching it)
local CAMP_SPACE    = 60    -- yalms: no camp this close to a real player
local CAMP_RADIUS   = 45    -- yalms: a bot hunts this far around its camp
local SCAN_EVERY    = 4     -- seconds between two looks for a monster
local HUNT_MINUTES  = { 30, 90 }
local REST_BELOW_HP = 55    -- %: rest after a fight below this
local REST_BELOW_MP = 40
local REST_UNTIL_HP = 95
local REST_UNTIL_MP = 90
local CURE_BELOW    = 50    -- %: a healer cures a party member (or itself) below this
local MELEE_STOP    = 1.5   -- yalms: a melee bot stops this far from the mob's centre
                            -- (2.5 left it outside real hit range on anything bigger
                            --  than a small mob, which showed up as missed swings)
local HOME_AFTER_DEATH = { 15, 40 } -- seconds dead before "return to Home Point"
local PULL_IN       = 12    -- yalms: a monster this close to the camp is "at camp" (the party takes it)
local PARTY_MIN_LVL = 10
local PARTY_CHECK   = 20    -- seconds between two "does anyone form a party?" checks
-- Level Sync (Phoenix rules: the levels in the party within 10 of each other, the target 10+, gear is not synced):
-- about this share of bot parties are formed that way, synced to their lowest member, as players did
local SYNC_SHARE    = 0.3
local SYNC_SPAN     = 10

-- where to hunt, by level and nation (0 San d'Oria, 1 Bastok, 2 Windurst)
local AREAS = {
    { 1, 7,   { [0] = { 100, 101 }, [1] = { 106, 107 }, [2] = { 115, 116 } } },        -- Ronfaure, Gustaberg, Sarutabaruta
    { 8, 15,  { [0] = { 102, 101 }, [1] = { 108, 107 }, [2] = { 117, 116 } } },        -- La Theine, Konschtat, Tahrongi
    { 13, 20, { [0] = { 103, 104 }, [1] = { 103, 108 }, [2] = { 103, 118 } } },        -- Valkurm, Jugner, Buburimu
    { 19, 28, { [0] = { 126, 104, 196 }, [1] = { 126, 173, 196 }, [2] = { 126, 118, 120 } } }, -- Qufim, Gusgen, Korroloka, Sauromugue
    { 27, 40, { [0] = { 197, 120, 200 }, [1] = { 197, 200, 173 }, [2] = { 197, 120, 200 } } }, -- Crawlers' Nest, Garlaige
    { 38, 55, { [0] = { 174, 151, 149 }, [1] = { 174, 213, 205 }, [2] = { 174, 151, 213 } } }, -- Kuftal, Oztroja, Onzozo
    { 50, 75, { [0] = { 153, 205, 195 }, [1] = { 153, 212, 205 }, [2] = { 153, 160, 128 } } }, -- Boyahda, Gustav, Den of Rancor
}
-- where bot parties go (any nation): the classic exp camps of the era
local PARTY_AREAS = {
    { 10, 17, { 103 } },                    -- Valkurm Dunes
    { 15, 21, { 104, 118, 103 } },          -- Jugner, Buburimu
    { 18, 26, { 126, 126, 123 } },          -- Qufim, Yuhtunga
    { 22, 31, { 196, 173, 120, 124 } },     -- Gusgen, Korroloka, Sauromugue, Yhoator
    { 29, 40, { 197, 200, 4 } },            -- Crawlers' Nest, Garlaige, Bibiki Bay
    { 38, 55, { 174, 151, 213, 176, 68 } }, -- Kuftal, Oztroja, Onzozo, Sea Serpent, Aydeewa
    { 50, 75, { 153, 212, 160, 128, 205, 5, 61, 52, 54 } }, -- Boyahda, Gustav, Rancor, Valley, Ifrit's, Uleguerand, ToAU
}
local HOME_NATION = { [230] = 0, [231] = 0, [232] = 0, [100] = 0, [101] = 0, [102] = 0, [234] = 1, [235] = 1, [236] = 1, [106] = 1, [107] = 1, [108] = 1,
                      [238] = 2, [239] = 2, [240] = 2, [241] = 2, [115] = 2, [116] = 2, [117] = 2 }

local JOB_NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP' }
local HEALERS = { WHM = true, RDM = true }
local NUKERS = { BLM = true, RDM = true }
-- the job's starting weapon (xi.player.charCreate gives it but does not equip it)
local START_WEAPON = { WAR = 'ONION_SWORD', WHM = 'ONION_ROD', BLM = 'ONION_STAFF', RDM = 'ONION_DAGGER', THF = 'ONION_KNIFE' }
-- weapon skill ids by weapon type: skill type 1-12 (hand-to-hand ... staff) use ids (type-1)*16 + 1..16
local function wsFitsWeapon(wsId, skillType)
    if not skillType or skillType < 1 or skillType > 12 then
        return false
    end

    local lo = (skillType - 1) * 16
    return wsId >= lo and wsId <= lo + 15
end

local NUKES = { 'thunder', 'blizzard', 'fire', 'aero', 'water', 'stone' }   -- best first
local CURES = { 'cure_iv', 'cure_iii', 'cure_ii', 'cure' }

local data
local state                  -- the brains' state table from bots.lua ([bot id] = st)
local mobCache = {}          -- [zone id] = { at = os.time(), list = mobs }
local claimed = {}           -- [mob id] = bot id that went for it (so two bots do not run at the same monster)
local nextPartyCheck = 0

local function rnd(a, b)
    return math.random(a, b)
end

local function now()
    return os.time()
end

local function d2(a, b)
    return (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2
end

local function pick(list)
    return list[rnd(1, #list)]
end

local function gameData()
    if data == nil then
        local ok, d = pcall(require, DATA_PATH)
        data = (ok and type(d) == 'table') and d or {}
        data.spells, data.ws = data.spells or {}, data.ws or {}
    end

    return data
end

function H.setup(brainState)
    state = brainState
end

local function jobOf(bot)
    return JOB_NAMES[bot:getMainJob()] or 'WAR'
end

local function isBot(e)
    return e and BotIsBot(e:getID())
end

local function realPlayersIn(zone)
    local out = {}
    for _, p in ipairs(zone:getPlayers()) do
        if not isBot(p) then
            out[#out + 1] = p
        end
    end

    return out
end

local function mobsOf(zone)
    local zid = zone:getID()
    local c = mobCache[zid]
    if not c or now() - c.at >= 3 then
        c = { at = now(), list = zone:getMobs() }
        mobCache[zid] = c
    end

    return c.list
end

local function isEnemy(mob)
    local ok, a = pcall(function()
        return mob:getAllegiance()
    end)
    return ok and a == ((xi.allegiance and xi.allegiance.MOB) or 0)
end

-- a monster this bot (or its party) may take
local function freeMob(mob, bot, players, partyIds)
    if not isEnemy(mob) or not mob:isAlive() then
        return false
    end

    local ok, busy = pcall(function()
        -- (2026-11-26, Art-Machine) the monsters that grow into an NM when left alone (custom/late/grow_nms.lua) are
        -- left alone by bots: a fight begins the monster's count again, and Vilma never came
        return mob:isNM() or mob:isEngaged() or mob:getTarget() ~= nil or
            (xi.growNm ~= nil and xi.growNm.leave ~= nil and xi.growNm.leave[mob:getID()] == true)
    end)
    if not ok or busy then
        return false
    end

    local owner = claimed[mob:getID()]
    if owner and not (partyIds and partyIds[owner]) and owner ~= bot:getID() then
        local e = GetPlayerByID(owner)
        if e and e:isAlive() then
            return false
        end
    end

    local mp, bp = mob:getPos(), bot:getPos()
    for _, p in ipairs(players) do
        local pp = p:getPos()
        if d2(pp, mp) <= PLAYER_SPACE * PLAYER_SPACE and d2(pp, bp) > WATCH_RANGE * WATCH_RANGE then
            return false
        end
    end

    return true
end

-----------------------------------
-- spells, weapon, weapon skills
-----------------------------------
-- learns its job's spells up to its level (as if it bought the scrolls) and equips its weapon
local function prepare(bot)
    local job, lvl = jobOf(bot), bot:getMainLvl()
    for _, s in pairs(gameData().spells) do
        local need = s[2] and s[2][job]
        -- (spells from scrolls on: 18+ only bought as scrolls, bots_party.lua)
        local scrolls = xi.bots and xi.bots.scrollsOn and xi.bots.scrollsOn()
        if need and need <= lvl and (need < 18 or not scrolls) and not bot:hasSpell(s[1]) then
            pcall(function()
                bot:addSpell(s[1], { silentLog = true })
            end)
        end
    end

    local weapon = START_WEAPON[job]
    if weapon and xi.item and xi.item[weapon] and xi.slot and bot:getEquipID(xi.slot.MAIN) == 0 then
        pcall(function()
            bot:equipItem(xi.item[weapon])
        end)
    end
end

local function bestSpell(bot, names)
    local job, lvl = jobOf(bot), bot:getMainLvl()
    for _, name in ipairs(names) do
        local s = gameData().spells[name]
        if s and s[2][job] and s[2][job] <= lvl and bot:hasSpell(s[1]) then
            return s[1]
        end
    end

    return nil
end

local function weaponSkill(bot, h)
    if bot:getTP() < 1000 or now() < (h.wsWait or 0) then
        return nil
    end

    local skillType = xi.slot and bot:getWeaponSkillType(xi.slot.MAIN) or nil
    if skillType == 0 then
        skillType = 1 -- no weapon: hand-to-hand
    end

    local best
    for _, w in ipairs(gameData().ws[jobOf(bot)] or {}) do
        if w[1] <= bot:getMainLvl() and wsFitsWeapon(w[2], skillType) then
            best = w[2]
        end
    end

    return best
end

-----------------------------------
-- choosing where to hunt
-----------------------------------
local function nationOf(bot)
    local ok, n = pcall(function()
        return bot:getNation()
    end)
    return (ok and n) or HOME_NATION[bot:getZoneID()] or 0
end

-- monster levels a bot hunts: alone "easy prey" to "decent challenge"; a party of 3+ "even match" to "tough"
local function levelRange(lvl, party)
    if party then
        return math.max(1, lvl - 1), lvl + 4
    end

    return math.max(1, lvl - (lvl <= 10 and 3 or 5)), lvl + (lvl <= 5 and 1 or 0)
end

local function partyArea(lvl)
    local options = {}
    for _, a in ipairs(PARTY_AREAS) do
        if lvl >= a[1] and lvl <= a[2] then
            for _, z in ipairs(a[3]) do
                options[#options + 1] = z
            end
        end
    end

    return #options > 0 and pick(options) or 103
end

local function areaFor(lvl, nation)
    local options = {}
    for _, a in ipairs(AREAS) do
        if lvl >= a[1] and lvl <= a[2] then
            for _, z in ipairs(a[3][nation] or a[3][0]) do
                options[#options + 1] = z
            end
        end
    end

    if #options == 0 then
        options = AREAS[#AREAS][3][nation] or AREAS[#AREAS][3][0]
    end

    return pick(options)
end

-- a camp: next to a monster of the right level, far from real players, on walkable ground
local function findCamp(zoneId, lvl, partyLvl)
    local zone = GetZone(zoneId)
    if not zone then
        return nil
    end

    local players = realPlayersIn(zone)
    local lo, hi = levelRange(lvl, partyLvl)

    local candidates = {}
    for _, mob in ipairs(mobsOf(zone)) do
        local ml = mob:getMainLvl()
        if
            ml >= lo and ml <= hi and isEnemy(mob) and mob:isAlive() and not mob:isNM() and
            not (xi.growNm ~= nil and xi.growNm.leave ~= nil and xi.growNm.leave[mob:getID()] == true) -- (see freeMob)
        then
            local mp = mob:getPos()
            local far = true
            for _, p in ipairs(players) do
                if d2(p:getPos(), mp) <= (CAMP_SPACE + 20) ^ 2 then
                    far = false
                    break
                end
            end

            if far then
                candidates[#candidates + 1] = mob
            end
        end
    end

    for _ = 1, 10 do
        if #candidates == 0 then
            return nil
        end

        local mp = pick(candidates):getPos()
        for _ = 1, 6 do
            local a = math.random() * 2 * math.pi
            local r = 12 + math.random() * 10
            local camp = { x = mp.x + r * math.cos(a), y = mp.y, z = mp.z + r * math.sin(a) }
            if zone:isNavigablePoint(camp) then
                return camp
            end
        end
    end

    return nil
end

-- goes out hunting now (alone); returns true when it is on its way (it zones)
function H.start(bot, st, minutes)
    local lvl = bot:getMainLvl()
    local zoneId = areaFor(lvl, nationOf(bot))
    local extras = xi.bots and xi.bots.extras or nil
    -- (2026-11-21) an area it died in lately is passed over when its level has another one (bots_memory.lua)
    if extras and extras.chooseArea then
        local okArea, z = pcall(extras.chooseArea, bot, zoneId, function()
            return areaFor(lvl, nationOf(bot))
        end)
        if okArea and type(z) == 'number' then
            zoneId = z
        end
    end

    local camp = findCamp(zoneId, lvl)
    -- ... and not a camp next to where it died within the hour
    if camp and extras and extras.campOk then
        for _ = 1, 3 do
            local okCamp, fine = pcall(extras.campOk, bot, zoneId, camp)
            if not okCamp or fine ~= false then
                break
            end

            camp = findCamp(zoneId, lvl) or camp
        end
    end

    if not camp then
        return false
    end

    prepare(bot)
    BotHeal(bot:getID(), false)
    st.life = nil
    st.hunt = { zone = zoneId, camp = camp, phase = 'find', untilT = now() + (minutes or rnd(HUNT_MINUTES[1], HUNT_MINUTES[2])) * 60, scanAt = 0, lastHP = 0 }
    if bot:getZoneID() == zoneId then
        BotMoveTo(bot:getID(), camp.x, camp.y, camp.z)
        return false
    end

    -- (2026-11-21) it runs to the town gate first and leaves from there (bots_gates.lua). The walk takes a
    -- while: if someone stands at that camp by then, it takes another one.
    if extras and extras.leave then
        local h = st.hunt
        local function go(b)
            local zone = GetZone(zoneId)
            for _, p in ipairs(zone and realPlayersIn(zone) or {}) do
                if d2(p:getPos(), h.camp) <= (CAMP_SPACE + 20) ^ 2 then
                    h.camp = findCamp(zoneId, lvl) or h.camp
                    break
                end
            end

            b:setPos(h.camp.x, h.camp.y, h.camp.z, 0, zoneId)
        end

        local okLeave, walking = pcall(extras.leave, bot, st, zoneId, go)
        if okLeave and walking == true then
            return false -- (not zoning yet: bots.lua walks it to the gate, st.trip; st.hunt marks it as busy)
        end

        st.trip = nil -- (no gate walk: it leaves at once, as before)
    end

    bot:setPos(camp.x, camp.y, camp.z, 0, zoneId)
    return true
end

-- how keen it is to go hunting (lower levels more: new characters want exp)
function H.wantsToHunt(bot)
    local lvl = bot:getMainLvl()
    local chance = lvl < 10 and 0.6 or (lvl < 30 and 0.45 or 0.3)
    return math.random() < chance
end

function H.active(st)
    return st.hunt ~= nil
end

local function stopHunt(bot, st, goHome)
    local h = st.hunt
    st.hunt = nil
    if h and h.target then
        claimed[h.target] = nil
    end

    if bot:isEngaged() then
        BotAttackOff(bot:getID())
    end

    BotStop(bot:getID())
    if h and h.leaderOf then
        BotLeaveParty(bot:getID())
    end

    if goHome then
        return 'home'
    end
end

-----------------------------------
-- one second of hunting (alone or in a bot party)
-----------------------------------
local function partyBots(bot)
    local list = {}
    for _, m in pairs(bot:getParty() or {}) do
        if m:getObjType() == xi.objType.PC then
            list[#list + 1] = m
        end
    end

    return list
end

local function healTurn(bot, h)
    -- a bot that is casting (or has just started a cure) is busy: returning false here let the rest step sit it down,
    -- which interrupted the cure, so a hurt healer stood up, cast, sat, cast... forever (wildthing, 2026-11-16)
    local casting = xi.bots.isCasting and xi.bots.isCasting(bot)
    if casting then
        h.castSeen = true
    end

    if now() < (h.healBusy or 0) or casting then
        return true
    end

    -- (2026-11-23, K-Andy, Hasuko: a world party's healer in West Sarutabaruta stood up, sat down, stood up... forever)
    -- a cure that never started (refused: still sitting when it was sent, out of sight...) used to be tried again
    -- every 4 seconds, with the rest step sitting the bot down in between. Two in a row that never showed up as a
    -- cast: no cures for 30 seconds, so the party rests and the bot gets its MP and footing back.
    if h.castSent and not h.castSeen then
        h.castMissed = (h.castMissed or 0) + 1
        if h.castMissed >= 2 then
            h.castMissed = 0
            h.castWait = now() + 30
        end
    elseif h.castSent then
        h.castMissed = 0
    end
    h.castSent, h.castSeen = nil, nil

    local job = jobOf(bot)
    if not HEALERS[job] or now() < (h.castWait or 0) then
        return false
    end

    -- sitting (the party rests): only a real emergency gets it up; resting brings the rest back
    local sitting = bot:getAnimation() == 33
    local worst, worstHP = nil, sitting and 30 or CURE_BELOW
    for _, m in ipairs(partyBots(bot)) do
        if m:isAlive() and m:getZoneID() == bot:getZoneID() and m:getHPP() < worstHP and d2(m:getPos(), bot:getPos()) <= 20 * 20 then
            worst, worstHP = m, m:getHPP()
        end
    end

    if not worst then
        return false
    end

    -- the best cure it has the MP for: with too little MP for its best one it stood up, the cast was refused, it sat
    -- down, stood up again ... (the party "resting and standing, up and down" in the Dunes, 2026-11-17)
    local spell
    for _, name in ipairs(CURES) do
        local id = bestSpell(bot, { name })
        local okC, cost = pcall(function()
            return GetSpell(id):getMPCost()
        end)
        if id and okC and cost and cost <= bot:getMP() then
            spell = id
            break
        end
    end

    if spell then
        if sitting then
            -- stand up now and cast on the next turn: a spell sent in the same moment as standing up was refused, as
            -- the bot was still resting when it arrived
            BotHeal(bot:getID(), false)
            h.healBusy = now() + 2
            return true
        end

        BotCast(bot:getID(), spell, worst)
        h.castWait = now() + 4
        h.healBusy = now() + 2   -- until the cast shows up as the bot's current action
        h.castSent = true
        return true
    end

    return false
end

-- pets of the pet jobs (bots_pets.lua)
local okPets, pets = pcall(require, 'modules/custom/lua/bots_pets')
if not okPets or type(pets) ~= 'table' then
    print('[bots] pets are off: bots_pets.lua could not be loaded: ' .. tostring(pets))
    pets = nil
end

local partyPlay -- bots_party.lua (the squad mates' job profiles), when a bot hunts in a party

function H.setParty(p)
    partyPlay = p
end

local BACK_LINE = 14 -- yalms: where a mage that does not melee stands in a party (inside casting range)

local function fightTurn(bot, h, target)
    local id = bot:getID()
    local inParty = bot:getPartySize() > 1
    -- in a party a WHM / BLM / BRD / SMN stays back and casts, as it does in your party (it used to run into melee)
    local back = inParty and partyPlay and partyPlay.stayBack(bot) or false
    if back then
        h.attacking = nil
        BotFollow(id, target, BACK_LINE)
    else
        -- the attack is sent again (every 3 s) until the server really has the bot engaged: a refused packet
        -- (it was resting, stunned, asleep ...) used to leave it next to the monster doing nothing for the whole fight
        if not (xi.bots.isCasting and xi.bots.isCasting(bot)) and (h.attacking ~= target:getID() or (not bot:isEngaged() and now() >= (h.attackAt or 0))) then
            h.attackAt = now() + 3
            BotHeal(id, false)
            h.attacking = BotAttack(id, target) and target:getID() or nil
        end

        if not (xi.bots.thiefTurn and xi.bots.thiefTurn(bot, target)) then
            BotFollow(id, target, MELEE_STOP)
        end
    end

    -- the server only lets a character swing at, weapon skill or cast on something it faces
    if not BotIsMoving(id) then
        pcall(function()
            bot:lookAt(target:getPos())
        end)
    end

    -- a pet job: its pet is out and goes for the same monster (wyvern, jug pet, avatar + Blood Pact, automaton)
    if pets then
        pcall(pets.fight, bot, h, target)
    end

    -- its job abilities and spells, from the same job profiles the squad mates use. (This used to run only in a
    -- party: a bot hunting alone never used Berserk, Boost, Provoke, its buffs ... at all.)
    if partyPlay and partyPlay.act(bot, h, inParty and bot:getPartyLeader() or nil, target) then
        return
    end

    if healTurn(bot, h) then
        return
    end

    local ws = (not back) and weaponSkill(bot, h) or nil
    if ws then
        BotWeaponSkill(id, ws, target)
        h.wsWait = now() + 5
        return
    end

    -- a mage nukes now and then (not every chance: MP for cures and the next fight)
    if NUKERS[jobOf(bot)] and now() >= (h.castWait or 0) and bot:getMPP() >= 45 and math.random() < 0.35 then
        local spell = bestSpell(bot, NUKES)
        if spell then
            BotCast(id, spell, target)
            h.castWait = now() + rnd(8, 14)
        end
    end
end

-- a monster attacking this bot (it has to fight back, even when resting)
local function attacker(bot, zone)
    for _, mob in ipairs(mobsOf(zone)) do
        local ok, t = pcall(function()
            return mob:isEngaged() and mob:getTarget()
        end)
        if ok and t and t:getID() == bot:getID() and mob:isAlive() then
            return mob
        end
    end

    return nil
end

local function needsRest(bot, list)
    for _, m in ipairs(list) do
        if m:getHPP() < REST_BELOW_HP or (m:getMaxMP() > 0 and m:getMPP() < REST_BELOW_MP) then
            return true
        end
    end

    return false
end

local function rested(list)
    for _, m in ipairs(list) do
        if m:getHPP() < REST_UNTIL_HP or (m:getMaxMP() > 0 and m:getMPP() < REST_UNTIL_MP) then
            return false
        end
    end

    return true
end

-- returns 'zoning' when the bot changes area, 'home' when it stopped hunting and should go home
function H.think(bot, st)
    local h = st.hunt
    local id = bot:getID()
    local t = now()

    if bot:isDead() then
        h.deadAt = h.deadAt or t
        if t - h.deadAt >= (h.deadWait or rnd(HOME_AFTER_DEATH[1], HOME_AFTER_DEATH[2])) then
            h.deadWait = h.deadWait or 0
            st.hunt = nil
            if h.target then
                claimed[h.target] = nil
            end

            BotHomepoint(id)
            return 'zoning'
        end

        h.deadWait = h.deadWait or rnd(HOME_AFTER_DEATH[1], HOME_AFTER_DEATH[2])
        return
    end

    local zone = bot:getZone()
    if not zone then
        return
    end

    -- in a bot party, not the leader: go where the leader is, help it
    local leader = bot:getPartyLeader()
    if leader and leader:getID() ~= id and isBot(leader) then
        if leader:getZoneID() ~= bot:getZoneID() then
            h.awaySince = h.awaySince or t
            if t - h.awaySince >= 5 then
                h.awaySince = nil
                local lp = leader:getPos()
                if xi.navguard then xi.navguard.setPos(bot, lp.x + 1, lp.y, lp.z + 1, 0, leader:getZoneID(), lp) else bot:setPos(lp.x + 1, lp.y, lp.z + 1, 0, leader:getZoneID()) end
                return 'zoning'
            end

            return
        end

        h.awaySince = nil
        local mob = attacker(bot, zone)
        local target = mob or (leader:isEngaged() and leader:getTarget()) or nil
        local lh = state[leader:getID()] and state[leader:getID()].hunt or nil
        local camp = (lh and lh.camp) or h.camp
        if target and target:isAlive() then
            BotHeal(id, false)
            -- the leader is out pulling: the party holds the camp (each at its own place around it) and takes the
            -- monster when it is brought in. (Everyone used to run out with the leader and fight wherever it was.)
            if not mob and lh and lh.pullPhase and camp and d2(target:getPos(), camp) > PULL_IN * PULL_IN then
                h.attacking = nil
                local a = (id % 8) * math.pi / 4
                local px, pz = camp.x + 2.5 * math.cos(a), camp.z + 2.5 * math.sin(a)
                if d2(bot:getPos(), { x = px, z = pz }) > 2 * 2 and not BotIsMoving(id) then
                    BotMoveTo(id, px, camp.y, pz)
                end

                return
            end

            fightTurn(bot, h, target)
            return
        end

        h.attacking = nil
        if healTurn(bot, h) then
            return
        end

        -- resting when the leader rests
        if leader:getAnimation() == 33 then
            if pets then
                pcall(pets.rest, bot, h)
            end

            BotHeal(id, true)
        else
            BotHeal(id, false)
            BotFollow(id, leader, 4)
        end

        return
    end

    -- asked to join a bot party: wait (in town) for the invite, a minute at most
    if h.phase == 'member' then
        h.waitUntil = h.waitUntil or (t + 60)
        if t >= h.waitUntil then
            st.hunt = nil
        end

        return
    end

    -- alone, or leading a bot party
    local party = partyBots(bot)
    -- a new party leader at its camp: now it invites the others
    if h.invite and bot:getZoneID() == h.zone then
        for _, mid in ipairs(h.invite) do
            local m = GetPlayerByID(mid)
            if m and m:getPartySize() <= 1 then
                BotInvite(id, m)
            end
        end

        h.invite = nil
        h.scanAt = t + 25
        BotChat(id, 0, pick(h.syncTo and { 'sync party forming for exp, come along', 'lets go exp, ill sync us', 'inviting for xp, level sync' }
                                      or { 'party forming for exp, come along', 'lets go exp', 'inviting for xp' }))
        if h.syncTo then
            h.syncAt = t + 15
        end
    end

    -- Level Sync on its lowest member, once that member is here (tried again until it holds, a few minutes at most)
    if h.syncTo and t >= (h.syncAt or 0) and BotLevelSync then
        local target = GetPlayerByID(h.syncTo)
        local holds = BotSyncTarget and target and BotSyncTarget(id) == target:getName()
        if holds or not target or (h.syncTries or 0) >= 3 then -- (the server refused it 3 times: they hunt without it)
            h.syncTo, h.syncTries = nil, nil
        elseif target:getZoneID() == bot:getZoneID() and not bot:isEngaged() then
            h.syncTries = (h.syncTries or 0) + 1
            h.syncAt = t + 20
            if BotLevelSync(id, target:getName()) then
                print(string.format('[bots] %s puts Level Sync on %s (level %d)', bot:getName(), target:getName(), target:getMainLvl()))
            end
        else
            h.syncAt = t + 10
        end
    end
    local partyIds = {}
    for _, m in ipairs(party) do
        partyIds[m:getID()] = true
    end

    -- time is up: back to town (the party breaks up)
    if t >= h.untilT and not bot:isEngaged() then
        for _, m in ipairs(party) do
            if m:getID() ~= id and state[m:getID()] then
                state[m:getID()].hunt = nil
                state[m:getID()].goHome = true
                BotLeaveParty(m:getID())
            end
        end

        return stopHunt(bot, st, true)
    end

    -- someone attacks it: fight back
    local hp = bot:getHPP()
    if h.phase ~= 'fight' and (hp < (h.lastHP or 100) or t >= (h.aggroScan or 0)) then
        h.aggroScan = t + 6
        local mob = attacker(bot, zone)
        if mob and h.target ~= mob:getID() then
            if h.target then
                claimed[h.target] = nil
            end

            h.target, h.phase = mob:getID(), 'fight'
            claimed[h.target] = id
            BotHeal(id, false)
        end
    end

    h.lastHP = hp

    if h.phase == 'fight' then
        local target = h.target and GetMobByID(h.target)
        if target and target:isAlive() then
            h.fightAt = h.fightAt or t
            local untouched = target:getHPP() >= 100 and target:getTarget() == nil
            -- 40 s and it has not even been touched: no way to it (a ledge, a wall, water). Another one.
            if untouched and t - h.fightAt >= 40 then
                h.skip = h.skip or {}
                h.skip[h.target] = t + 600
                claimed[h.target] = nil
                if bot:isEngaged() then
                    BotAttackOff(id)
                end

                BotStop(id)
                h.target, h.attacking, h.fightAt, h.pullPhase = nil, nil, nil, nil
                h.phase = 'find'
                return
            end

            -- a party leader pulls: out to the monster, and once it is on someone it runs back so the fight is at camp
            if h.pullPhase == 'out' and not untouched then
                if d2(target:getPos(), h.camp) > PULL_IN * PULL_IN then
                    h.pullPhase, h.pullUntil = 'back', t + 25
                else
                    h.pullPhase = nil
                end
            end

            if h.pullPhase == 'back' then
                if d2(bot:getPos(), h.camp) <= 4 * 4 or t >= (h.pullUntil or 0) or bot:getHPP() < 45 then
                    h.pullPhase = nil
                else
                    if not BotIsMoving(id) then
                        BotMoveTo(id, h.camp.x, h.camp.y, h.camp.z)
                    end

                    return
                end
            end

            fightTurn(bot, h, target)
            return
        end

        claimed[h.target or 0] = nil
        h.target, h.attacking = nil, nil
        h.fightAt, h.pullPhase = nil, nil
        h.phase = needsRest(bot, party) and 'rest' or 'find'
        if h.phase == 'rest' then
            BotStop(id)
        end

        return
    end

    if healTurn(bot, h) then
        return
    end

    if h.phase == 'rest' then
        if rested(party) then
            BotHeal(id, false)
            h.phase = 'find'
        else
            if pets then
                pcall(pets.rest, bot, h) -- (a Summoner lets its avatar go: it costs MP)
            end

            BotHeal(id, true)
        end

        return
    end

    -- find: a monster near the camp (a party leader waits until everyone is there)
    if needsRest(bot, party) then
        h.phase = 'rest'
        return
    end

    if #party > 1 then
        local missing = false
        for _, m in ipairs(party) do
            if m:getZoneID() ~= bot:getZoneID() or d2(m:getPos(), bot:getPos()) > 15 * 15 then
                missing = true
            end
        end

        -- (a member that never arrives - dead, stuck, gone home - held the whole party up for good: 90 s at most)
        h.waitSince = missing and (h.waitSince or t) or nil
        if missing and t - h.waitSince < 90 then
            if d2(bot:getPos(), h.camp) > 3 * 3 and not BotIsMoving(id) then
                BotMoveTo(id, h.camp.x, h.camp.y, h.camp.z)
            end

            return
        end
    end

    if t < (h.scanAt or 0) then
        return
    end

    h.scanAt = t + SCAN_EVERY
    local lvl = math.min(bot:getMainLvl(), h.huntLvl or 99) -- (a sync party hunts at its lowest member's level)
    local lo, hi = levelRange(lvl, #party >= 3)

    local players = realPlayersIn(zone)
    local best, bestD
    for _, mob in ipairs(mobsOf(zone)) do
        local ml = mob:getMainLvl()
        if ml >= lo and ml <= hi then
            local mp = mob:getPos()
            local dc = d2(mp, h.camp)
            if dc <= CAMP_RADIUS * CAMP_RADIUS and not (h.skip and (h.skip[mob:getID()] or 0) > t) and freeMob(mob, bot, players, partyIds) then
                local d = d2(mp, bot:getPos())
                if not best or d < bestD then
                    best, bestD = mob, d
                end
            end
        end
    end

    if best then
        h.target, h.phase = best:getID(), 'fight'
        h.fightAt = t
        h.pullPhase = (#party >= 2) and 'out' or nil
        claimed[h.target] = id
        fightTurn(bot, h, best)
        return
    end

    -- nothing here: a new camp sometimes, or walk back to the camp
    h.empty = (h.empty or 0) + 1
    if h.empty >= 6 then
        h.empty = 0
        local camp = findCamp(bot:getZoneID(), lvl, #party >= 3)
        if camp then
            h.camp = camp
        end
    end

    if d2(bot:getPos(), h.camp) > 10 * 10 and not BotIsMoving(id) then
        BotMoveTo(id, h.camp.x, h.camp.y, h.camp.z)
    end
end

-----------------------------------
-- bot parties (level 10+), formed once in a while from bots that are free (xi.bots.onTick)
-----------------------------------
local function freeForParty(id)
    local bot = GetPlayerByID(id)
    if not bot or not bot:isAlive() or bot:getMainLvl() < PARTY_MIN_LVL or bot:getPartySize() > 1 then
        return nil
    end

    -- only a bot with nothing else going on. (Any bot not fighting at that very second used to count as free:
    -- a party being formed, its leader, a bot at the auction house or on a quest was picked again by the next
    -- party 20 seconds later, so the same bots were pulled from party to party and from job to job.)
    local st = state[id]
    if not st or st.hunt or st.task or st.quest or st.bf or bot:isEngaged() then
        return nil
    end

    return bot
end

function H.tick(onlineIds)
    local t = now()
    if t < nextPartyCheck then
        return
    end

    nextPartyCheck = t + PARTY_CHECK
    local free = {}
    for _, id in ipairs(onlineIds) do
        local bot = freeForParty(id)
        if bot then
            free[#free + 1] = bot
        end
    end

    if #free < 3 or math.random() > 0.5 then
        return
    end

    local leader = pick(free)
    local lvl = leader:getMainLvl()
    local members = {}
    -- linkshell mates first (an exp shell parties together), then anyone
    local lsOf = leader:getCharVar('[Bot]LS')
    if lsOf > 0 then
        table.sort(free, function(x, y)
            return (x:getCharVar('[Bot]LS') == lsOf and 1 or 0) > (y:getCharVar('[Bot]LS') == lsOf and 1 or 0)
        end)
    end

    -- most parties: about the same level (within 3). Some use Level Sync: anyone in a window of 10 levels (all 10+),
    -- synced to the lowest
    local sync = BotLevelSync ~= nil and lvl >= PARTY_MIN_LVL and math.random() < SYNC_SHARE
    local lo, hi = lvl - 3, lvl + 3
    if sync then
        lo = math.max(PARTY_MIN_LVL, lvl - rnd(0, SYNC_SPAN))
        hi = lo + SYNC_SPAN
    end

    local size = rnd(2, 5)
    for _, b in ipairs(free) do
        local bl = b:getMainLvl()
        if b:getID() ~= leader:getID() and bl >= lo and bl <= hi and #members < size then
            members[#members + 1] = b
        end
    end

    if #members < 2 then
        return
    end

    -- the level they hunt at: the lowest member's, when synced
    local lowest = leader
    for _, m in ipairs(members) do
        if m:getMainLvl() < lowest:getMainLvl() then
            lowest = m
        end
    end

    if sync and lowest:getMainLvl() == lvl then
        local spread = false
        for _, m in ipairs(members) do
            spread = spread or m:getMainLvl() ~= lvl
        end
        sync = spread -- (all the same level after all: no need for it)
    end

    local huntLvl = sync and lowest:getMainLvl() or lvl
    local zoneId = partyArea(huntLvl)
    local camp = findCamp(zoneId, huntLvl, true)
    if not camp then
        return
    end

    local lst = state[leader:getID()]
    prepare(leader)
    BotHeal(leader:getID(), false)
    lst.life = nil
    lst.hunt = { zone = zoneId, camp = camp, phase = 'find', untilT = t + rnd(45, 120) * 60, scanAt = t + 30, leaderOf = true, invite = {},
                 syncTo = sync and lowest:getID() or nil, sync = sync or nil, huntLvl = sync and huntLvl or nil }
    for _, m in ipairs(members) do
        prepare(m)
        BotHeal(m:getID(), false)
        local mst = state[m:getID()]
        mst.life = nil
        mst.hunt = { zone = zoneId, camp = camp, phase = 'member', untilT = lst.hunt.untilT }
        lst.hunt.invite[#lst.hunt.invite + 1] = m:getID()
    end

    if leader:getZoneID() ~= zoneId then
        leader:setPos(camp.x, camp.y, camp.z, 0, zoneId)
    end
end

-- a party member that joined later is lower than the synced level: the leader syncs to it instead (bots_invite.lua)
function H.resync(leader, member)
    local st = state[leader:getID()]
    if st and st.hunt and st.hunt.sync then
        st.hunt.syncTo, st.hunt.syncAt, st.hunt.syncTries = member:getID(), now() + 5, 0
    end
end

-- attacked while doing something else (gathering): fight back; returns true while fighting
function H.defend(bot, st)
    local zone = bot:getZone()
    if not zone then
        return false
    end

    st.defend = st.defend or {}
    local h = st.defend
    local target = h.target and GetMobByID(h.target) or nil
    if not (target and target:isAlive()) then
        h.target, h.attacking = nil, nil
        local mob = attacker(bot, zone)
        if not mob then
            st.defend = nil
            return false
        end

        h.target = mob:getID()
        target = mob
        BotHeal(bot:getID(), false)
    end

    fightTurn(bot, h, target)
    return true
end

-- a weapon skill at 100% TP that fits its weapon (for a bot in your party)
-- one fighting turn against a target (attack, follow, cures, weapon skill, nukes): bots_bcnm.lua uses it inside battlefields
function H.fight(bot, h, target)
    fightTurn(bot, h, target)
end

function H.weaponSkillTurn(bot, st, target)
    st.ws = st.ws or {}
    local ws = weaponSkill(bot, st.ws)
    if ws then
        BotWeaponSkill(bot:getID(), ws, target)
        st.ws.wsWait = now() + 5
        return true
    end

    return false
end

-- for !bots: how many are out hunting
function H.count()
    local n = 0
    for _, st in pairs(state or {}) do
        if st.hunt then
            n = n + 1
        end
    end

    return n
end

return H
