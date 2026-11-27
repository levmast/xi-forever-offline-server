-- Feedback batch B7-F24 (2026-11-27), the camp and resting: B10 (you as the healer for Healer MP), F23 (the pull range line and
-- its push), F18 (Rest in fights: when a mate sits, when it gets up, the 20 s first recovery, no bobbing at the threshold, the
-- command and the menu's lines). The real squad.lua runs with the stand-ins of test_squad_item_commands.lua (as
-- test_squad_feedback_camp.lua does); the engine's side of F18 (keeping a resting mate out of the fight, Wake to act) is in C++
-- and checked in game. No server, no database; nothing is written.
--   luajit test_squad_feedback_b7_camp.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua
--                                          <server>/scripts/enum/job_ability.lua <server>/sql
local here = (arg[0]:match('^(.*)[/\\][^/\\]*$') or '.')
local f = assert(io.open(here .. '/test_squad_item_commands.lua', 'rb'))
local base = f:read('*a'):gsub('\r\n', '\n')
f:close()
local cut = assert(base:find('\n%-%- =+ give\n'), 'test_squad_item_commands.lua: the first section was not found')
local prefix = base:sub(1, cut):gsub('__SQUAD_TEST = {}\n', "rawset(xi, 'squad', {})\n__SQUAD_TEST = {}\n", 1)

local body = [==[
do
local camps, campTick = H.camps, H.campTick
assert(type(campTick) == 'function' and type(camps) == 'table', 'squad.lua without the camp test hooks')
local WAR, WHM = 1, 3
rawset(xi, 'job', { WAR = 1, WHM = 3, BLM = 4, RDM = 5 })
SquadHasPet = function() return false end

local function monster(id, name, target)
    local m = { id = id, name = name, target = target, alive = true }
    function m:getID() return self.id end
    function m:getTargID() return self.id end
    function m:getName() return self.name end
    function m:getHPP() return 100 end
    function m:isAlive() return self.alive end
    function m:getTarget() return rawget(self, 'target') end
    function m:isEngaged() return rawget(self, 'target') ~= nil end
    function m:isNM() return false end
    function m:getAllegiance() return 0 end
    function m:getMainLvl() return 70 end
    function m:getPos() return { x = 30, y = 0, z = 0 } end
    return setmetatable(m, { __index = function() return function() return 0 end end })
end

local function mate(id, name, job, mpp)
    local t = { vars = { SQUAD_ID = id }, name = name, job = job, hp = 100, mp = mpp or 100, maxmp = 100, anim = 0,
                pos = { x = 0, y = 0, z = 0 }, engaged = false, action = 16 }
    function t:getObjType() return xi.objType.TRUST end
    function t:getLocalVar(k) return self.vars[k] or 0 end
    function t:setLocalVar(k, v) self.vars[k] = v end
    function t:isAlive() return true end
    function t:getID() return 1000 + id end
    function t:getPacketName() return self.name end
    function t:getMainJob() return self.job end
    function t:getSubJob() return 0 end
    function t:getMainLvl() return 75 end
    function t:getHP() return self.hp end
    function t:getMaxHP() return 100 end
    function t:addHP(n) self.hp = math.min(100, self.hp + n) end
    function t:getMP() return self.mp end
    function t:getMaxMP() return self.maxmp end
    function t:addMP(n) self.mp = math.min(self.maxmp, self.mp + n) end
    function t:isEngaged() return self.engaged end
    function t:getTarget() return nil end
    function t:getPos() return self.pos end
    function t:getAnimation() return self.anim end
    function t:setAnimation(a) self.anim = a end
    function t:getCurrentAction() return self.action end
    return setmetatable(t, { __index = function() return function() return 0 end end })
end

local pullable = monster(99, 'Goblin Thug', nil)
local function world(mates, opts)
    opts = opts or {}
    local p = reset({})
    pullable.target = nil
    p.party = { p }
    for _, m in ipairs(mates) do p.party[#p.party + 1] = m; function m:getMaster() return p end end
    p.localVars = {}
    p.job, p.mpNow, p.engaged, p.anim = opts.job or WAR, opts.mp or 100, false, 0
    function p:getPartyWithTrusts() return self.party end
    function p:getParty() return { self } end
    function p:isEngaged() return self.engaged end
    function p:isAlive() return true end
    function p:getMainJob() return self.job end
    function p:getHP() return 100 end
    function p:getMaxHP() return 100 end
    function p:getMP() return self.mpNow end
    function p:getMaxMP() return 100 end
    function p:getAnimation() return self.anim end
    function p:getPos() return { x = 0, y = 0, z = 0 } end
    function p:getYPos() return 0 end
    function p:getXPos() return 0 end
    function p:getZPos() return 0 end
    function p:getLocalVar(k) return self.localVars[k] or 0 end
    function p:setLocalVar(k, v) self.localVars[k] = v end
    local zone = { mobs = { pullable } }
    function zone:getMobs() return self.mobs end
    function zone:getPlayers() return { p } end
    function p:getZone() return zone end
    if opts.camp ~= false then
        camps[p:getID()] = { zone = 116, x = 0, y = 0, z = 0, puller = opts.puller or 8, state = 'idle', pulls = 0, paused = false, nextPull = 0 }
    else
        camps[p:getID()] = nil
    end
    return p
end

local function tick(p, mates)
    camps[p:getID()].nextTick = 0
    campTick(mates[1])
    return camps[p:getID()]
end
local function pullTarget(m) return m:getLocalVar('SQUAD_PULL_TARGET') end
SquadPartyFoes = function() return 0, '', 0 end

-- ================================================================= B10
section('B10: you as the healer for Healer MP')
do
    local function warriors()
        local war, puller = mate(7, 'Mira', WAR), mate(8, 'Pull', WAR)
        war.maxmp, puller.maxmp = 0, 0
        return war, puller
    end

    -- a White Mage player at 10% MP, the only healer, Healer MP 60%: no pull (before: the pull went out)
    local war, puller = warriors()
    local p = world({ war, puller }, { job = WHM, mp = 10 })
    p.vars.SQUAD_PULL_HEALER_MP = 60
    local c = tick(p, { war, puller })
    check(pullTarget(puller) == 0, 'WHM player at 10%, Healer MP 60%: no pull')
    local why = LOG[#LOG] or ''
    check(has(why, '(healer)') and has(why, 'Healer MP'), 'and the camp says why: ' .. why)
    check(has(SQUAD_CAMPX.notReady(p, { war, puller }) or '', 'Testcharone (healer) MP 10%'), 'notReady names you: ' .. tostring(SQUAD_CAMPX.notReady(p, { war, puller })))

    p.mpNow = 60
    c.nextPull = 0
    tick(p, { war, puller })
    check(pullTarget(puller) == 99, 'at 60%: the pull goes')

    -- resting does not make a healer ready
    war, puller = warriors()
    p = world({ war, puller }, { job = WHM, mp = 30 })
    p.vars.SQUAD_PULL_HEALER_MP = 60
    p.anim = xi.animation.HEALING
    tick(p, { war, puller })
    check(pullTarget(puller) == 0, 'a resting White Mage player below the setting still holds the pull')

    -- a Warrior player is no healer: as before (camp wait off: the puller does not wait for your MP)
    war, puller = warriors()
    p = world({ war, puller }, { job = WAR, mp = 0 })
    p.vars.SQUAD_PULL_HEALER_MP = 60
    tick(p, { war, puller })
    check(pullTarget(puller) == 99, 'a Warrior player at 0% MP: the pull goes, as before')

    -- the setting at its default: unchanged for a White Mage player too
    war, puller = warriors()
    p = world({ war, puller }, { job = WHM, mp = 0 })
    tick(p, { war, puller })
    check(pullTarget(puller) == 99, 'Healer MP default: a White Mage player does not hold the pull (as before)')

    -- both heal: each one needs it
    local whm = mate(9, 'Heal', WHM, 70)
    war, puller = warriors()
    p = world({ whm, puller }, { job = WHM, mp = 50 })
    p.vars.SQUAD_PULL_HEALER_MP = 60
    tick(p, { whm, puller })
    check(pullTarget(puller) == 0, 'a White Mage mate at 70% and you at 50%: you hold the pull')
    p.mpNow, whm.mp = 65, 50
    camps[p:getID()].nextPull = 0
    tick(p, { whm, puller })
    check(pullTarget(puller) == 0, '... you at 65%, the mate at 50%: the mate holds it')
    whm.mp = 60
    camps[p:getID()].nextPull = 0
    tick(p, { whm, puller })
    check(pullTarget(puller) == 99, '... both at 60% or more: pull')

    -- the command names who counts
    p = world({ whm, puller }, { job = WHM, mp = 100 })
    local said = run(p, 'camp', 'healermp', '60')
    check(has(said, 'Testcharone (White Mage)') and has(said, 'Heal'), 'healermp says both healers: ' .. said)
end

-- ================================================================= F23
section('F23: the pull range in the menu')
do
    local war, puller = mate(7, 'Mira', WAR), mate(8, 'Pull', WAR)
    local p = world({ war, puller })
    check(SQUAD_CAMPX.rangeLine(p) == 'squadpanel:camprange|60|0', 'the default: 60, not set: ' .. SQUAD_CAMPX.rangeLine(p))
    p.vars.SQUAD_PULL_RANGE = 250
    check(SQUAD_CAMPX.rangeLine(p) == 'squadpanel:camprange|250|1', 'a value set with the command (250) is reported as it is')
    p.vars.SQUAD_PULL_RANGE = 0
    p.localVars.SQUAD_PANEL_SEEN = os.time()
    local said = run(p, 'camp', 'range', '90')
    check(p.vars.SQUAD_PULL_RANGE == 90 and has(said, 'squadpanel:camprange|90|1'), 'camp range 90: stored and pushed to the menu')
    local at, st = nil, nil
    for i, line in ipairs(p.printed) do
        if has(line, 'camprange|90') then at = i end
        if has(line, 'squadpanel:campst|') then st = i end
    end
    check(at and st and at < st, 'the range line comes before campst (an older menu reads campst as the last line, as before)')
    local q = world({ war, puller })
    said = run(q, 'panel')
    check(has(said, 'squadpanel:camprange|60|0') and has(said, 'camprange'), 'the panel answer has the range line and the cap')
end

-- ================================================================= F18
section('F18: rest in fights')
do
    local function campOf(pl) return camps[pl:getID()] end
    SquadFoesOn = function(m) return rawget(m, 'foes') or 0 end
    local function setup(opts)
        opts = opts or {}
        local blm = mate(7, 'Nuke', 4, opts.mp or 30)
        local war = mate(8, 'Tank', WAR)
        war.engaged = true -- (the party is fighting)
        local p = world({ blm, war }, { camp = opts.camp })
        blm.vars.SQUAD_RESTFIGHT = opts.threshold or 40
        return p, blm, war
    end

    local p, blm, war = setup()
    check(SQUAD_F18.tick(blm, p, campOf) == true and blm.vars.SQUAD_REST_FIGHT_ON == 1 and blm.anim == xi.animation.HEALING,
        'MP 30% under 40%, the party fighting, nothing on it, at its camp: it sits down out of the fight')
    local at = blm.vars.SQUAD_REST_AT
    check(at - os.time() >= 19 and at - os.time() <= 20, 'the first recovery comes after 20 s (as a player\'s /heal)')
    SQUAD_F18.tick(blm, p, campOf)
    check(blm.mp == 30, 'nothing before the 20 s')
    blm.vars.SQUAD_REST_AT = os.time() - 1
    SQUAD_F18.tick(blm, p, campOf)
    check(blm.mp > 30 and blm.vars.SQUAD_REST_AT - os.time() >= 9, 'then a recovery tick, and the next one 10 s later')

    -- hit: up, and not down again at once
    blm.hp = 80
    check(SQUAD_F18.tick(blm, p, campOf) == false and blm.vars.SQUAD_REST_FIGHT_ON == 0 and blm.anim == 0, 'hit: it gets up')
    check(SQUAD_F18.tick(blm, p, campOf) == false and blm.vars.SQUAD_REST_FIGHT_ON == 0, 'and does not sit again right away (no bobbing)')
    blm.vars.SQUAD_RF_NEXT = 0

    -- moved
    blm.mp = 30
    check(SQUAD_F18.tick(blm, p, campOf) == true, '(after the wait it sits again)')
    blm.pos = { x = 3, y = 0, z = 0 }
    check(SQUAD_F18.tick(blm, p, campOf) == false and blm.vars.SQUAD_REST_FIGHT_ON == 0, 'moved: it gets up')
    blm.pos, blm.vars.SQUAD_RF_NEXT = { x = 0, y = 0, z = 0 }, 0

    -- MP back: at the setting + 20 (not at the setting: no sit / stand at 40)
    blm.mp = 30
    check(SQUAD_F18.tick(blm, p, campOf) == true, '(sits again)')
    blm.mp = 45
    check(SQUAD_F18.tick(blm, p, campOf) == true, 'at 45% (above 40, below 60) it keeps resting')
    blm.mp = 60
    check(SQUAD_F18.tick(blm, p, campOf) == false and blm.vars.SQUAD_REST_FIGHT_ON == 0, 'at 60% (40 + 20) it is back in the fight')
    check(blm.vars.SQUAD_RF_NEXT == 0, 'MP back is no interruption (no wait)')
    blm.mp = 45
    check(SQUAD_F18.tick(blm, p, campOf) == false, 'at 45% it does not sit again (only below 40)')

    -- not while something attacks it, not while casting, not when the party is not fighting
    p, blm, war = setup()
    blm.foes = 1
    check(SQUAD_F18.tick(blm, p, campOf) == false, 'a monster on it: it does not sit')
    blm.foes, blm.action = 0, 30
    check(SQUAD_F18.tick(blm, p, campOf) == false, 'casting: it does not sit')
    blm.action, war.engaged = 16, false
    check(SQUAD_F18.tick(blm, p, campOf) == false, 'the party is not fighting: not this rest (the usual resting with you applies)')

    -- a Wake to act rule acted (the engine: state 2): up for that action only, out of the fight, down again when it is over
    p, blm, war = setup()
    SQUAD_F18.tick(blm, p, campOf)
    blm.vars.SQUAD_REST_FIGHT_ON, blm.vars.SQUAD_REST_WOKE, blm.anim = 2, os.time(), 0 -- (what the engine does)
    blm.action = 30 -- (casting its Cure)
    check(SQUAD_F18.tick(blm, p, campOf) == true and blm.vars.SQUAD_REST_FIGHT_ON == 2 and blm.anim == 0,
        'up for its Wake to act action: still in the rest (out of the fight, only Wake to act rules), standing')
    blm.action = 16
    check(SQUAD_F18.tick(blm, p, campOf) == true and blm.vars.SQUAD_REST_FIGHT_ON == 2, 'the action just ended: not down in the same second')
    local mpBefore = blm.mp
    blm.vars.SQUAD_REST_WOKE = os.time() - SQUAD_F18.RESIT_SEC
    check(SQUAD_F18.tick(blm, p, campOf) == true and blm.vars.SQUAD_REST_FIGHT_ON == 1 and blm.anim == xi.animation.HEALING,
        'the action over: it sits down again')
    local at2 = blm.vars.SQUAD_REST_AT
    check(at2 - os.time() >= 19 and at2 - os.time() <= 20 and blm.mp == mpBefore, 'and the 20 s start over (no recovery while it stood)')
    blm.vars.SQUAD_REST_FIGHT_ON, blm.vars.SQUAD_REST_WOKE = 2, os.time()
    blm.hp = blm.hp - 10
    check(SQUAD_F18.tick(blm, p, campOf) == false and blm.vars.SQUAD_REST_FIGHT_ON == 0 and (blm.vars.SQUAD_RF_NEXT or 0) > os.time(),
        'hit while up for its action: the rest ends, with the usual wait before it sits again')
    -- an older map server (cleared the state): it fights, and does not sit again at once
    p, blm, war = setup()
    SQUAD_F18.tick(blm, p, campOf)
    blm.vars.SQUAD_REST_FIGHT_ON, blm.vars.SQUAD_REST_WOKE, blm.anim = 0, os.time(), 0
    check(SQUAD_F18.tick(blm, p, campOf) == false and blm.anim == 0, 'an older map server woke it fully: up, and not down again at once')

    -- following you (no camp): sits near you, gets up when you go away
    p, blm, war = setup({ camp = false })
    check(SQUAD_F18.tick(blm, p, campOf) == true, 'following you, near you: it sits')
    blm.pos = { x = 0.5, y = 0, z = 0 }
    function p:getPos() return { x = 20, y = 0, z = 0 } end
    check(SQUAD_F18.tick(blm, p, campOf) == false, 'you went 20 yalms away: it gets up and follows')

    -- off (the default): nothing changes
    p, blm, war = setup({ threshold = 0 })
    local offResult = SQUAD_F18.tick(blm, p, campOf)
    check(offResult == false and (blm.vars.SQUAD_REST_FIGHT_ON or 0) == 0,
        'Rest in fights off: it fights through, as before (' .. tostring(offResult) .. ', ' .. tostring(blm.vars.SQUAD_RESTFIGHT) .. ')')

    -- an older xi_map (no SquadFoesOn): never
    local saved = SquadFoesOn
    SquadFoesOn = nil
    p, blm, war = setup()
    check(SQUAD_F18.tick(blm, p, campOf) == false, 'an older map server: never (it could not keep the mate out of the fight)')
    SquadFoesOn = saved

    -- the command and the menu
    p = world({ mate(7, 'Mira', WAR) })
    local said = run(p, 'restfight', '1', '40')
    check(p.vars.SQUAD_RESTFIGHT_7 == 40 and has(said, 'below 40% MP') and has(said, 'back at 60%'), 'restfight 1 40: ' .. said)
    said = run(p, 'restfight', '1', '95')
    check(p.vars.SQUAD_RESTFIGHT_7 == 40 and has(said, '10-90'), 'restfight 1 95: refused, kept 40')
    said = run(p, 'restfight', '1', 'off')
    check(p.vars.SQUAD_RESTFIGHT_7 == 0 and has(said, 'fights through'), 'restfight 1 off')
    p.vars.SQUAD_RESTFIGHT_7 = 30
    said = run(p, 'panel')
    check(has(said, 'squadpanel:rf|1|30|0') and has(said, 'restfight'),
        'the panel answer has rf|1|30|0 (Mira is out with no Wake to act rule) and the cap restfight')
    p.party[2].vars.SQUAD_WAKE_RULES = 2
    said = run(p, 'panel')
    check(has(said, 'squadpanel:rf|1|30|2'), 'with 2 Wake to act rules: rf|1|30|2')
    p.party = { p }
    said = run(p, 'panel')
    check(has(said, 'squadpanel:rf|1|30|-1'), 'not out: rf|1|30|-1 (the menu shows no warning)')
end
end
]==]

local tail = '\nio.write(string.format("\\n%d passed, %d failed\\n", passed, failed))\nos.exit(failed == 0 and 0 or 1)\n'
assert(load(prefix .. body .. tail, '=test_squad_feedback_b7_camp'))()
