-----------------------------------
-- FFXI Offline: bot players - playing their job in a party (step 4.3). Used by bots.lua and bots_hunt.lua.
--
-- A bot uses the same job profiles as your squad mates (squad.lua: the gambit lists for each job and level,
-- main job + sub job, including your own Gambits sheet rules), read through xi.squad.profileFor. Each line is
-- "target / condition / action": cure a party member under 75% HP, Protect whoever lacks it, Provoke when the
-- monster is not on the tank, Berserk when it is not up, Dia on the target, and so on. The bot checks them in
-- order (about every 2 seconds) and does the first one that fits, through the same packets a player sends
-- (spells it really knows, its MP, its job abilities). Weapon skills and skillchains stay with the fight brain.
-- Mages that do not melee (WHM, BLM, SMN, BRD) stay behind you instead of running to the monster.
-----------------------------------
local P = {}

local CHECK_EVERY = 2      -- seconds between two decisions
local CAST_WAIT   = 5      -- seconds after a spell before the next action
local JA_WAIT     = 2
local JA_RECAST   = 60     -- seconds before the same job ability is tried again (the server refuses earlier ones anyway)
local RANGE       = 20     -- yalms: party members it helps

local NO_MELEE = { [3] = true, [4] = true, [10] = true, [15] = true } -- WHM, BLM, BRD, SMN
local TANKS = { [1] = true, [7] = true, [13] = true }                 -- WAR, PLD, NIN
local CASTERS = { [3] = true, [4] = true, [5] = true, [10] = true, [15] = true, [16] = true }

local profiles = {}        -- ['job:lvl:sub:sublvl'] = gambit list
local families             -- [family id] = { spell ids, best last }

local function now()
    return os.time()
end

local function dist2(a, b)
    local pa, pb = a:getPos(), b:getPos()
    return (pa.x - pb.x) ^ 2 + (pa.z - pb.z) ^ 2
end

function P.available()
    return xi.squad ~= nil and type(xi.squad.profileFor) == 'function' and ai ~= nil and ai.c ~= nil
end

function P.stayBack(bot)
    return NO_MELEE[bot:getMainJob()] == true
end

local function profileOf(bot)
    local key = string.format('%d:%d:%d:%d', bot:getMainJob(), bot:getMainLvl(), bot:getSubJob(), bot:getSubLvl())
    if not profiles[key] then
        local ok, list = pcall(xi.squad.profileFor, bot:getMainJob(), bot:getMainLvl(), bot:getSubJob(), bot:getSubLvl())
        profiles[key] = (ok and type(list) == 'table') and list or {}
    end

    return profiles[key]
end

-- every spell of a family, lowest first (once)
local function familySpells(fam)
    if not families then
        families = {}
        for id = 1, 1023 do
            local ok, f = pcall(function()
                local s = GetSpell(id)
                return s and s:getSpellFamily() or nil
            end)
            if ok and f and f ~= 0 then
                families[f] = families[f] or {}
                table.insert(families[f], id)
            end
        end
    end

    return families[fam] or {}
end

local function mpCost(id)
    local ok, c = pcall(function()
        return GetSpell(id):getMPCost()
    end)
    return (ok and c) or 0
end

-- (2026-11-24, Mikoto: a healer bot stopped healing once level sync brought it down) knowing the spell is not enough:
-- its main or support job has to be high enough for it NOW. Synced down, it still knows Cure III and picked it every
-- time, the server refused it, and it never fell back to Cure II.
local function levelOk(bot, id)
    local ok, fit = pcall(function()
        local sp = GetSpell(id)
        if not sp then
            return true
        end

        local main = sp:getLevel(bot:getMainJob())
        if main ~= nil and main > 0 and main < 255 and main <= bot:getMainLvl() then
            return true
        end

        local subJob = bot:getSubJob()
        if subJob == nil or subJob == 0 then
            return false
        end

        local sub = sp:getLevel(subJob)
        return sub ~= nil and sub > 0 and sub < 255 and sub <= bot:getSubLvl()
    end)
    return not ok or fit
end

local function canCast(bot, id)
    return bot:hasSpell(id) and bot:getMP() >= mpCost(id) and levelOk(bot, id)
end

-----------------------------------
-- conditions
-----------------------------------
local function hasTop(entity, mob)
    if not mob then
        return false
    end

    local t = mob:getTarget()
    return t ~= nil and t:getID() == entity:getID()
end

local check -- forward

local function one(c, who, ctx)
    local kind, value = c[1], c[2] or 0
    local C = ai.c
    -- MP checks on a line aimed at the monster ("nuke while I have MP") are about the caster, not the monster: a
    -- black mage's "MP 0% or more" was asked of the monster (no MP at all), so it never cast (2026-11-17)
    if (kind == C.MPP_LT or kind == C.MPP_GTE) and ctx.self and ctx.mob and who == ctx.mob then
        who = ctx.self
    end
    if kind == C.ALWAYS then
        return true
    elseif kind == C.HPP_LT then
        return who:getHPP() < value
    elseif kind == C.HPP_GTE then
        return who:getHPP() >= value
    elseif kind == C.MPP_LT then
        return who:getMaxMP() > 0 and who:getMPP() < value
    elseif kind == C.MPP_GTE then
        return who:getMaxMP() > 0 and who:getMPP() >= value
    elseif kind == C.TP_LT then
        return who:getTP() < value
    elseif kind == C.TP_GTE then
        return who:getTP() >= value
    elseif kind == C.LVL_LT then
        return who:getMainLvl() < value
    elseif kind == C.LVL_GTE then
        return who:getMainLvl() >= value
    elseif kind == C.STATUS then
        return who:hasStatusEffect(value)
    elseif kind == C.NOT_STATUS then
        return not who:hasStatusEffect(value)
    elseif kind == C.HAS_TOP_ENMITY then
        return hasTop(who, ctx.mob)
    elseif kind == C.NOT_HAS_TOP_ENMITY then
        return ctx.mob ~= nil and not hasTop(who, ctx.mob)
    elseif kind == C.RANDOM then
        return math.random(100) <= value
    elseif kind == C.PT_HAS_TANK then
        return ctx.tank ~= nil
    elseif kind == C.NOT_PT_HAS_TANK then
        return ctx.tank == nil
    elseif kind == C.HP_MISSING then
        return (who:getMaxHP() - who:getHP()) >= value
    elseif C.STATUS_FLAG ~= nil and kind == C.STATUS_FLAG then
        return who:hasStatusEffectByFlag(value) -- (e.g. something Erase can remove)
    elseif C.IS_ECOSYSTEM ~= nil and kind == C.IS_ECOSYSTEM then
        return who.getEcosystem ~= nil and who:getEcosystem() == value
    elseif C.NOT_SC_AVAILABLE ~= nil and kind == C.NOT_SC_AVAILABLE then
        return true  -- (a bot can't see an open skillchain: treated as none, so a BLM's "nuke when no skillchain" works)
    end

    return false -- (conditions a bot cannot judge: skipped)
end

check = function(c, who, ctx)
    if type(c) ~= 'table' then
        return false
    end

    if c.logic ~= nil and c.conditions then -- ai.logic.OR(...)
        for _, sub in ipairs(c.conditions) do
            if check(sub, who, ctx) then
                return true
            end
        end

        return false
    end

    if type(c[1]) == 'table' then -- both(a, b)
        for _, sub in ipairs(c) do
            if not check(sub, who, ctx) then
                return false
            end
        end

        return true
    end

    return one(c, who, ctx)
end

-----------------------------------
-- targets and actions
-----------------------------------
local function candidates(bot, target, ctx)
    local T = ai.t
    if target == T.SELF or target == T.TRIGGER_TARGET_ACTION_SELF then
        return { bot }
    elseif target == T.TARGET or target == T.TRIGGER_SELF_ACTION_TARGET then
        return ctx.mob and { ctx.mob } or {}
    elseif target == T.MASTER then
        return ctx.leader and { ctx.leader } or {}
    elseif target == T.TANK then
        return ctx.tank and { ctx.tank } or {}
    elseif target == T.TOP_ENMITY then
        local t = ctx.mob and ctx.mob:getTarget()
        return t and { t } or {}
    end

    local out = {}
    for _, m in ipairs(ctx.members) do
        local job = m:getMainJob()
        if target == T.PARTY or target == T.PARTY_MULTI or (target == T.MELEE and not CASTERS[job]) or (target == T.CASTER and CASTERS[job]) then
            out[#out + 1] = m
        end
    end

    return out
end

-- elemental nukes, best tier first: for profile lines that say "the highest" or "the best against the target"
-- with no spell family (a black mage's nukes). A random element of the best tier the bot knows and has MP for.
local NUKE_ELEMENTS = { 'STONE', 'WATER', 'AERO', 'FIRE', 'BLIZZARD', 'THUNDER' }
local NUKE_TIERS = { '_IV', '_III', '_II', '' }
local function bestNuke(bot)
    for _, tier in ipairs(NUKE_TIERS) do
        local ok = {}
        for _, el in ipairs(NUKE_ELEMENTS) do
            local id = xi.magic.spell[el .. tier]
            if id and canCast(bot, id) then
                ok[#ok + 1] = id
            end
        end

        if #ok > 0 then
            return ok[math.random(1, #ok)]
        end
    end

    return nil
end

local function doAction(bot, st, action, who)
    local R, S = ai.r, ai.s
    local id = bot:getID()
    if action[1] == R.MA then
        local spell
        if S.MB_ELEMENT ~= nil and action[2] == S.MB_ELEMENT then
            return false -- (magic bursts need the skillchain a bot can't see)
        elseif (action[2] == S.HIGHEST or (S.BEST_AGAINST_TARGET ~= nil and action[2] == S.BEST_AGAINST_TARGET))
            and (action[3] == nil or action[3] == 0 or (xi.magic.spellFamily and action[3] == xi.magic.spellFamily.NONE)
                or (S.BEST_AGAINST_TARGET ~= nil and action[2] == S.BEST_AGAINST_TARGET)) then
            spell = bestNuke(bot)
        elseif action[2] == S.SPECIFIC then
            spell = canCast(bot, action[3]) and action[3] or nil
        else
            local list = familySpells(action[3])
            for i = #list, 1, -1 do
                if canCast(bot, list[i]) then
                    spell = list[i]
                    break
                end
            end
        end

        if spell then
            BotCast(id, spell, who)
            st.partyWait = now() + CAST_WAIT
            return true
        end
    elseif R.RATTACK ~= nil and action[1] == R.RATTACK then
        -- a ranged attack (RNG, COR, a thrower): only with a ranged weapon or throwing item on, and needs bots.cpp's
        -- BotShoot (server rebuild of 2026-11-17)
        if not BotShoot or not who or who == bot then
            return false
        end

        local okR, ranged = pcall(function()
            return bot:getEquipID(xi.slot.RANGED) ~= 0 or bot:getEquipID(xi.slot.AMMO) ~= 0
        end)
        if okR and ranged and BotShoot(id, who) then
            st.partyWait = now() + 4
            return true
        end
    elseif action[1] == R.JA and action[2] == S.SPECIFIC then
        st.jaUsed = st.jaUsed or {}
        if now() >= (st.jaUsed[action[3]] or 0) then
            st.jaUsed[action[3]] = now() + JA_RECAST
            BotAbility(id, action[3], who)
            st.partyWait = now() + JA_WAIT
            return true
        end
    end

    return false
end

-- "Spells from scrolls" (the launcher's option, squad_config.lua spell_scrolls; the same switch as for squad mates,
-- 2026-11-17): on = a bot gets the spells it learns below level 18 by itself, but the ones from 18 up it has to buy as
-- scrolls with its own gil (P.buyScrolls, in town), and a Blue Mage learns blue magic from 18 up from monsters it
-- defeats (P.hookBlue). Spells it already knows stay. Off = everything up to its level, as before.
local SCROLL_LEVEL = 18
local SCROLL_ITEM  = 4608   -- scroll item id = 4608 + spell id
local BLU          = 16
-- is there a scroll for this spell? (2026-11-19, Paturu: a level 9 white mage bot never cast Protectra) this used to ask
-- GetItemByID, which does not work from Lua on this server, so since 0.1.45 a bot learned no white/black magic, songs
-- or ninjutsu at all beyond what it already knew. SquadScrollSpell (squad.cpp) answers from the item table.
local function hasScroll(id)
    if SquadScrollSpell == nil then
        return true
    end

    local ok, found = pcall(SquadScrollSpell, SCROLL_ITEM + id)
    return ok and found ~= nil
end

local scrollsCache, scrollsAt = false, 0
function P.scrollsOn()
    if os.time() >= scrollsAt then
        scrollsAt = os.time() + 60
        local ok, on = pcall(function()
            return squadScrollsOn ~= nil and squadScrollsOn() or false
        end)
        scrollsCache = ok and on == true
    end

    return scrollsCache
end

xi.bots = xi.bots or {}
xi.bots.scrollsOn = P.scrollsOn

-- the level a job learns this spell at, or nil
local function learnLevel(sp, job)
    if not job or job == 0 then
        return nil
    end

    local l = sp:getLevel(job)
    if l and l > 0 and l < 255 then
        return l
    end

    return nil
end

-- the spells of its main and sub job up to their levels, as if it had bought the scrolls (once per job/level):
-- a bot that joined you straight from town only knew the few spells its field hunts had taught it, so a white mage
-- had no Protectra and a black mage could have no nuke at all (2026-11-17). White, black, songs, ninjutsu and
-- summoning (ids below 512), and blue magic (512-767) for a Blue Mage.
local learnedKey = {}
function P.learn(bot)
    local on = P.scrollsOn()
    local key = string.format('%d:%d:%d:%d:%s', bot:getMainJob(), bot:getMainLvl(), bot:getSubJob(), bot:getSubLvl(), tostring(on))
    if learnedKey[bot:getID()] == key then
        return
    end

    learnedKey[bot:getID()] = key
    local main, mlvl, sub, slvl = bot:getMainJob(), bot:getMainLvl(), bot:getSubJob(), bot:getSubLvl()
    local last = (main == BLU or sub == BLU) and 767 or 511
    for id = 1, last do
        local ok, need = pcall(function()
            local sp = GetSpell(id)
            if not sp then
                return false
            end

            -- (switch on) avatars other than Carbuncle come from their fights (bots_pets.lua), not by level
            if on and id >= 297 and id <= 307 then
                return false
            end

            -- a spell players learn comes on a scroll (item 4608 + id): one without is a monster's (Diaga II).
            -- Summons (288-310) and blue magic (512+) don't come on scrolls.
            if id < 288 or (id > 310 and id < 512) then
                if not hasScroll(id) then
                    return false
                end
            end

            local a, b = learnLevel(sp, main), learnLevel(sp, sub)
            return (a ~= nil and a <= mlvl and (not on or a < SCROLL_LEVEL))
                or (b ~= nil and b <= slvl and (not on or b < SCROLL_LEVEL))
        end)
        if ok and need and not bot:hasSpell(id) then
            pcall(function()
                bot:addSpell(id, { silentLog = true })
            end)
        end
    end
end

-- (spells from scrolls) in town now and then: buys up to two scrolls it is missing (18+ for its jobs and levels,
-- lowest first) when it can spare the gil. Returns how many it learned.
function P.buyScrolls(bot)
    if not P.scrollsOn() then
        return 0
    end

    local main, mlvl, sub, slvl = bot:getMainJob(), bot:getMainLvl(), bot:getSubJob(), bot:getSubLvl()
    local want = {}
    for id = 1, 511 do
        pcall(function()
            local sp = GetSpell(id)
            if sp and not bot:hasSpell(id) then
                local a, b = learnLevel(sp, main), learnLevel(sp, sub)
                local lvl = (a and a >= SCROLL_LEVEL and a <= mlvl and a) or (b and b >= SCROLL_LEVEL and b <= slvl and b) or nil
                if lvl and hasScroll(id) then
                    want[#want + 1] = { id = id, lvl = lvl }
                end
            end
        end)
    end

    table.sort(want, function(x, y)
        return x.lvl < y.lvl
    end)

    local bought = 0
    for _, w in ipairs(want) do
        if bought >= 2 then
            break
        end

        local okP, price = pcall(function()
            return GetItemByID(SCROLL_ITEM + w.id):getBasePrice()
        end)
        price = (okP and tonumber(price) and price > 0) and price or (w.lvl * w.lvl * 15)
        price = math.floor(price * 1.5) -- (the auction house asks a bit more than the shop price)
        if bot:getGil() >= price * 2 then -- (keeps half its gil for gear and food)
            bot:delGil(price)
            bot:addSpell(w.id, { silentLog = true })
            bought = bought + 1
        end
    end

    return bought
end

-- A Blue Mage bot sets its blue magic the way a player does in the Set Spells menu (BotSetBlueSpells, bots.cpp):
-- the spells its job rules use first (heals, Cocoon, the physical damage spells), then the rest of what it knows,
-- strongest first, while it has the slots and points. Done again when its level, job or known spells change.
local BLUE_PREFER = { 'MAGIC_FRUIT', 'WILD_CARROT', 'HEALING_BREEZE', 'POLLEN', 'COCOON', 'METALLIC_BODY', 'JET_STREAM',
    'UPPERCUT', 'SCREWDRIVER', 'BLUDGEON', 'HEAD_BUTT', 'BATTLE_DANCE', 'POWER_ATTACK', 'SPROUT_SMACK', 'WILD_OATS' }
function P.setBlue(bot, st)
    if not BotSetBlueSpells or (bot:getMainJob() ~= BLU and bot:getSubJob() ~= BLU) or os.time() < (st.bluSetAt or 0) then
        return
    end

    st.bluSetAt = os.time() + 60
    local known = {}
    for id = 512, 767 do
        if bot:hasSpell(id) then
            known[#known + 1] = id
        end
    end

    local key = string.format('%d:%d:%d:%d:%d', bot:getMainJob(), bot:getMainLvl(), bot:getSubJob(), bot:getSubLvl(), #known)
    if st.bluSetKey == key then
        return
    end

    st.bluSetKey = key
    local order, seen = {}, {}
    for _, name in ipairs(BLUE_PREFER) do
        local id = xi.magic and xi.magic.spell and xi.magic.spell[name]
        if id and bot:hasSpell(id) and not seen[id] then
            order[#order + 1], seen[id] = id, true
        end
    end

    local rest = {}
    for _, id in ipairs(known) do
        if not seen[id] then
            local okL, l = pcall(function()
                return GetSpell(id):getLevel(BLU)
            end)
            l = (okL and tonumber(l)) or 255
            if l < 255 then
                rest[#rest + 1] = { id = id, l = l }
            end
        end
    end

    table.sort(rest, function(a, b)
        return a.l > b.l
    end)
    for _, r in ipairs(rest) do
        order[#order + 1] = r.id
    end

    pcall(BotSetBlueSpells, bot:getID(), order)
end

-- (spells from scrolls) a Blue Mage bot learns blue magic (18+) from what it defeats, 15% per spell, like a squad
-- Blue Mage. The listener is added again after each zone change (they do not follow the entity across areas).
function P.hookBlue(bot, st)
    if st.bluHookZone == bot:getZoneID() or not SquadBlueSpellsOf then
        return
    end

    st.bluHookZone = bot:getZoneID()
    bot:addListener('DEFEATED_MOB', 'BOT_BLU_LEARN', function(mob)
        if mob == nil or bot:getMainJob() ~= BLU or not P.scrollsOn() then
            return
        end

        for _, sp in ipairs(SquadBlueSpellsOf(mob) or {}) do
            if sp.level >= SCROLL_LEVEL and bot:getMainLvl() >= sp.level and not bot:hasSpell(sp.spell)
                and math.random(100) <= (SQUAD_BLUE_LEARN_CHANCE or 15) then
                bot:addSpell(sp.spell, { silentLog = true })
            end
        end
    end)
end

-- one decision for a bot in a party (with you or with other bots); mob = the monster being fought (or nil).
-- Returns true when it did something.
function P.act(bot, st, leader, mob)
    if not P.available() or bot:isDead() or now() < (st.partyWait or 0) or now() < (st.partyCheck or 0) then
        return false
    end

    st.partyCheck = now() + CHECK_EVERY
    P.learn(bot)
    local ctx = { self = bot, leader = leader, mob = (mob and mob:isAlive()) and mob or nil, members = {} }
    -- (2026-11-20, Sunie: a bot healer cured the player and ignored the squad mate at low HP next to it) the party as the
    -- bot sees it includes the squad mates of its members: they are trusts, which getParty() leaves out
    local okParty, party = pcall(function()
        return bot:getPartyWithTrusts()
    end)
    if not okParty or type(party) ~= 'table' or #party == 0 then
        party = bot:getParty() or {}
    end

    for _, m in pairs(party) do
        if m:getZoneID() == bot:getZoneID() and m:isAlive() and dist2(m, bot) <= RANGE * RANGE then
            ctx.members[#ctx.members + 1] = m
            if not ctx.tank and TANKS[m:getMainJob()] then
                ctx.tank = m
            end
        end
    end

    for _, g in ipairs(profileOf(bot)) do
        if type(g.action) == 'table' and (g.action[1] == ai.r.MA or g.action[1] == ai.r.JA or (ai.r.RATTACK ~= nil and g.action[1] == ai.r.RATTACK)) then
            local list = candidates(bot, g.target, ctx)
            -- for HP conditions: the most hurt first
            table.sort(list, function(a, b)
                return a:getHPP() < b:getHPP()
            end)
            for _, who in ipairs(list) do
                local subject = who
                if g.target == ai.t.TRIGGER_SELF_ACTION_TARGET then
                    subject = bot
                elseif g.target == ai.t.TRIGGER_TARGET_ACTION_SELF then
                    subject, who = ctx.mob, bot
                end

                if subject and check(g.condition, subject, ctx) and doAction(bot, st, g.action, who) then
                    return true
                end
            end
        end
    end

    return false
end

-- for the tests
P._check = check

return P
