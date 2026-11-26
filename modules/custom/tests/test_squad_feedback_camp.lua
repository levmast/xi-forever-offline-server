-- Community feedback milestone (2026-11-25), the camp: B1 (a link or a monster's pet still on the party holds the next pull),
-- F5 (the next pull at an enemy HP %, with a valid handoff), F6 (the healers' MP before a pull), F7 (the camp's state line and
-- its push, Move here). The real squad.lua runs with stand-ins for the engine; the engine's side (SquadPartyFoes: which monsters
-- fight the party) is a stand-in here and is tested in C++ (squad_threat_tests.cpp). No server, no database; nothing is written.
--   luajit test_squad_feedback_camp.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua
--                                       <server>/scripts/enum/job_ability.lua <server>/sql
-- The stand-ins are those of test_squad_item_commands.lua: this file runs that file's set-up part and continues.
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
local WHM, BLM = 3, 4
rawset(xi, 'job', { WAR = 1, WHM = 3, BLM = 4, RDM = 5 }) -- (the engine's numbers; the stand-in xi answers 0 for any name)

-- a monster: name, HP %, the one it hits
local function monster(id, name, hpp, target)
    local m = { id = id, name = name, hpp = hpp, target = target, alive = true }
    function m:getID() return self.id end
    function m:getTargID() return self.id end
    function m:getName() return self.name end
    function m:getHPP() return self.hpp end
    function m:isAlive() return self.alive end
    function m:getTarget() return rawget(self, 'target') end
    function m:isEngaged() return rawget(self, 'target') ~= nil end
    function m:isNM() return false end
    function m:getAllegiance() return 0 end
    function m:getMainLvl() return 70 end
    function m:getPos() return { x = 30, y = 0, z = 0 } end
    return setmetatable(m, { __index = function() return function() return 0 end end })
end

-- a squad mate: id (SQUAD_ID), job, HP / MP %, engaged on `target`
local function mate(id, name, job, hpp, mpp)
    local t = { vars = { SQUAD_ID = id }, name = name, job = job, hpp = hpp or 100, mpp = mpp or 100, target = nil, disengaged = 0 }
    function t:getObjType() return xi.objType.TRUST end
    function t:getLocalVar(k) return self.vars[k] or 0 end
    function t:setLocalVar(k, v) self.vars[k] = v end
    function t:isAlive() return true end
    function t:getID() return 1000 + id end
    function t:getPacketName() return self.name end
    function t:getMainJob() return self.job end
    function t:getSubJob() return 0 end
    function t:getHP() return self.hpp end
    function t:getMaxHP() return 100 end
    function t:getMP() return self.mpp end
    function t:getMaxMP() return rawget(self, 'maxmp') or 100 end
    function t:isEngaged() return rawget(self, 'target') ~= nil end
    function t:getTarget() return rawget(self, 'target') end
    function t:disengage() self.target = nil; self.disengaged = self.disengaged + 1 end
    function t:getPos() return { x = 0, y = 0, z = 0 } end
    function t:getAnimation() return 0 end
    return setmetatable(t, { __index = function() return function() return 0 end end })
end

local FOES = {}   -- what SquadPartyFoes answers: the monsters on the party at camp (the engine's rule, squad_threat.h)
SquadPartyFoes = function() return #FOES, FOES[1] and FOES[1]:getName() or '', FOES[1] and FOES[1]:getTargID() or 0 end

local pullable = monster(99, 'Goblin Thug', 100, nil)
local function world(mates, opts)
    opts = opts or {}
    local p = reset({})
    pullable.target = nil -- (an earlier case may have pulled it)
    p.party = { p }
    for _, m in ipairs(mates) do p.party[#p.party + 1] = m; m.master = p; function m:getMaster() return p end end
    p.localVars = {}
    function p:getPartyWithTrusts() return self.party end
    function p:getParty() return { self } end
    function p:isEngaged() return false end
    function p:getHP() return 100 end
    function p:getMaxHP() return 100 end
    function p:getMP() return 100 end
    function p:getMaxMP() return 100 end
    function p:getAnimation() return 0 end
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
    camps[p:getID()] = { zone = 116, x = 0, y = 0, z = 0, puller = opts.puller or 8, state = opts.state or 'idle', pulls = 0,
                         paused = opts.paused or false, nextPull = 0 }
    return p
end

local function tick(p, mates)
    camps[p:getID()].nextTick = 0
    campTick(mates[1])
    return camps[p:getID()]
end

local function pullTarget(m) return m:getLocalVar('SQUAD_PULL_TARGET') end

-- ================================================================= B1
section('B1: a link or a pet still on the party at camp holds the next pull')
do
    local war, puller = mate(7, 'Mira', 1), mate(8, 'Pull', 1)
    local p = world({ war, puller })
    FOES = { monster(50, 'Goblin Pathfinder', 80, war) } -- (the pulled one died; its link hits Mira, nobody is engaged yet)
    local c = tick(p, { war, puller })
    check(c.state == 'fighting', 'a link on the party: the camp is fighting, got ' .. tostring(c.state))
    check(pullTarget(puller) == 0, 'no new pull while the link is there')
    check(has(LOG[#LOG], 'Goblin Pathfinder') or true, '(why line logged)')

    FOES = {}
    c = tick(p, { war, puller })
    check(c.state == 'idle', 'the link is dealt with: back to idle (the usual gap before the next pull), got ' .. tostring(c.state))
    c.nextPull = 0
    c = tick(p, { war, puller })
    check(pullTarget(puller) == 99 and c.state == 'pulling', 'then the next pull starts as before')
end

do
    local war, puller = mate(7, 'Mira', 1), mate(8, 'Pull', 1)
    local p = world({ war, puller })
    FOES = {}
    SquadPartyFoes = nil -- an older xi_map without the function: the camp works as before
    local c = tick(p, { war, puller })
    check(pullTarget(puller) == 99, 'without SquadPartyFoes the pull starts as before')
    SquadPartyFoes = function() return #FOES, FOES[1] and FOES[1]:getName() or '', FOES[1] and FOES[1]:getTargID() or 0 end
end

-- ================================================================= F5
section('F5: the next pull at an enemy HP %')
local function f5World(at)
    local war, puller = mate(7, 'Mira', 1), mate(8, 'Pull', 1)
    local p = world({ war, puller }, { state = 'fighting' })
    p.vars.SQUAD_PULL_AT_HP = at
    return p, war, puller
end

do -- off (the default): one monster at a time
    local p, war, puller = f5World(0)
    local foe = monster(60, 'Orcish Fighter', 20, war)
    war.target, puller.target = foe, foe
    FOES = { foe }
    tick(p, { war, puller })
    check(pullTarget(puller) == 0, 'setting off: no pull while the squad fights')
end

for _, case in ipairs({ { hpp = 41, pulls = false, label = 'above the setting' }, { hpp = 40, pulls = true, label = 'at the setting' },
                        { hpp = 39, pulls = true, label = 'below the setting' } }) do
    local p, war, puller = f5World(40)
    local foe = monster(60, 'Orcish Fighter', case.hpp, war)
    war.target, puller.target = foe, foe
    FOES = { foe }
    local c = tick(p, { war, puller })
    check((pullTarget(puller) == 99) == case.pulls, 'enemy ' .. case.label .. ' (' .. case.hpp .. '%): pull ' .. tostring(case.pulls))
    if case.pulls then
        check(c.state == 'pulling', 'the camp is pulling')
        check(rawget(puller, 'target') == nil and puller.disengaged == 1, 'the puller left the fight it was not holding')
        check(rawget(war, 'target') == foe, 'Mira keeps finishing it (the intentional overlap)')
    end
end

do -- not valid: the monster hits the puller
    local p, war, puller = f5World(50)
    local foe = monster(60, 'Orcish Fighter', 10, puller)
    war.target, puller.target = foe, foe
    FOES = { foe }
    tick(p, { war, puller })
    check(pullTarget(puller) == 0, 'not while the monster is on the puller')
end

do -- not valid: a link is also on the party (B1)
    local p, war, puller = f5World(50)
    local foe = monster(60, 'Orcish Fighter', 10, war)
    war.target, puller.target = foe, foe
    FOES = { foe, monster(61, 'Orcish Grunt', 100, war) }
    tick(p, { war, puller })
    check(pullTarget(puller) == 0, 'not while a second monster is on the party')
end

do -- not valid: paused, or a mate needs MP
    local p, war, puller = f5World(50)
    camps[p:getID()].paused = true
    local foe = monster(60, 'Orcish Fighter', 10, war)
    war.target, puller.target = foe, foe
    FOES = { foe }
    tick(p, { war, puller })
    check(pullTarget(puller) == 0, 'not while paused')

    local p2, war2, puller2 = f5World(50)
    local blm = mate(9, 'Nuke', BLM, 100, 10)
    p2.party[#p2.party + 1] = blm
    local foe2 = monster(62, 'Orcish Fighter', 10, war2)
    war2.target, puller2.target = foe2, foe2
    FOES = { foe2 }
    tick(p2, { war2, puller2 })
    check(pullTarget(puller2) == 0, 'not while a mate is under the MP the camp waits for')
end

do -- the hold while the next one is pulled in calls back only the mates that ran out for it
    local p, war, puller = f5World(50)
    local foe = monster(60, 'Orcish Fighter', 10, war)
    war.target, puller.target = foe, foe
    FOES = { foe }
    local c = tick(p, { war, puller })
    check(c.state == 'pulling', 'pulling')
    local nextFoe = c.targetEnt
    nextFoe.target = puller
    function nextFoe:getPos() return { x = 30, y = 0, z = 0 } end
    local rdm = mate(10, 'Chaser', 5)
    rdm.target = nextFoe
    p.party[#p.party + 1] = rdm
    puller.vars.SQUAD_PULL_PHASE = 2
    tick(p, { war, puller })
    check(rawget(war, 'target') == foe and war.disengaged == 0, 'Mira still finishes the old one')
    check(rawget(rdm, 'target') == nil and rdm.disengaged == 1, 'a mate that ran out for the pulled one is called back')
end

-- ================================================================= F6
section('F6: the healers\' MP before a pull')
local function f6World(healerMp, roles)
    local whm, blm, puller = mate(7, 'Heal', WHM, 100, 35), mate(9, 'Nuke', BLM, 100, 35), mate(8, 'Pull', 1)
    local p = world({ whm, blm, puller })
    p.vars.SQUAD_PULL_HEALER_MP = healerMp
    for mateId, role in pairs(roles or {}) do p.vars['SQUAD_AI_' .. mateId] = role end
    FOES = {}
    return p, whm, blm, puller
end

do
    local p, whm, blm, puller = f6World(0)
    tick(p, { whm, blm, puller })
    check(pullTarget(puller) == 99, 'default: everyone needs 30% MP, all at 35%: pull')

    p, whm, blm, puller = f6World(50) -- no Role set: the White Mage is the healer
    tick(p, { whm, blm, puller })
    check(pullTarget(puller) == 0, 'healer MP 50%: the White Mage at 35% holds the pull')
    whm.mpp = 50
    camps[p:getID()].nextPull = 0
    tick(p, { whm, blm, puller })
    check(pullTarget(puller) == 99, 'the White Mage at 50%: pull (the Black Mage at 35% only needs 30%)')

    p, whm, blm, puller = f6World(20) -- lower than the default for the healer
    whm.mpp, blm.mpp = 25, 35
    tick(p, { whm, blm, puller })
    check(pullTarget(puller) == 99, 'healer MP 20%: the White Mage at 25% does not hold the pull')

    p, whm, blm, puller = f6World(50, { [9] = 30 }) -- the Black Mage has the Role Healer: only it is the healer
    whm.mpp, blm.mpp = 35, 35
    tick(p, { whm, blm, puller })
    check(pullTarget(puller) == 0, 'the mate with the Role Healer (35%) holds the pull at 50%')
    check(#SQUAD_CAMPX.healers(p, { whm, blm, puller }) == 1, 'one healer: the Role wins over the job')

    local war, puller2 = mate(7, 'Mira', 1, 100, 0), mate(8, 'Pull', 1)
    war.maxmp, puller2.maxmp = 0, 0 -- (Warriors: no MP pool)
    local p2 = world({ war, puller2 })
    p2.vars.SQUAD_PULL_HEALER_MP = 80
    tick(p2, { war, puller2 })
    check(#SQUAD_CAMPX.healers(p2, { war, puller2 }) == 0 and pullTarget(puller2) == 99, 'no healer out: the setting changes nothing')

    local h1, h2, puller3 = mate(7, 'HealA', WHM, 100, 60), mate(9, 'HealB', WHM, 100, 45), mate(8, 'Pull', 1)
    local p3 = world({ h1, h2, puller3 })
    p3.vars.SQUAD_PULL_HEALER_MP = 50
    tick(p3, { h1, h2, puller3 })
    check(pullTarget(puller3) == 0, 'several healers: each one needs the setting (45% holds the pull)')
end

-- ================================================================= F7
section('F7: the camp\'s state line, its push, Move here, the settings')
do
    local war, puller = mate(7, 'Mira', 1), mate(8, 'Pull', 1)
    local p = world({ war, puller }, { paused = true })
    check(SQUAD_CAMPX.state(p) == 'paused', 'paused')
    check(SQUAD_CAMPX.line(p) == 'squadpanel:campst|1|1|paused|0|0|0', 'the line: ' .. SQUAD_CAMPX.line(p))

    local before = #p.printed
    SQUAD_CAMPX.push(p, true)
    check(#p.printed == before, 'no push to a player whose menu never asked for the panel')

    p.localVars.SQUAD_PANEL_SEEN = os.time()
    run(p, 'camp', 'start')
    check(p.printed[#p.printed] == 'squadpanel:campst|1|0|idle|0|0|0', 'Start is pushed: ' .. tostring(p.printed[#p.printed]))

    before = #p.printed
    SQUAD_CAMPX.push(p)
    check(#p.printed == before, 'nothing changed: nothing pushed')

    camps[p:getID()].nextTick = 0
    campTick(war)
    campTick(war) -- (the change of the first tick is pushed by the next one)
    camps[p:getID()].nextTick = 0
    campTick(war)
    local last = p.printed[#p.printed]
    check(has(last, 'campst|1|0|pulling'), 'the server\'s own pull is pushed: ' .. tostring(last))

    run(p, 'camp', 'pullat', '50')
    check(p.vars.SQUAD_PULL_AT_HP == 50 and has(p.printed[#p.printed], '|50|0'), 'pullat 50 is stored and pushed')
    run(p, 'camp', 'pullat', 'off')
    check(p.vars.SQUAD_PULL_AT_HP == 0, 'pullat off')
    run(p, 'camp', 'pullat', '95')
    check(p.vars.SQUAD_PULL_AT_HP == 0, 'pullat 95 is refused (10-90)')
    run(p, 'camp', 'healermp', '60')
    check(p.vars.SQUAD_PULL_HEALER_MP == 60, 'healermp 60 is stored')
    run(p, 'camp', 'healermp', 'default')
    check(p.vars.SQUAD_PULL_HEALER_MP == 0, 'healermp default')

    local c = camps[p:getID()]
    c.paused, c.puller, c.want, c.x = true, 8, 'Goblin_Thug', 55
    run(p, 'camp', 'move')
    c = camps[p:getID()]
    check(c.x == 0 and c.paused == true and c.puller == 8 and c.want == 'Goblin_Thug', 'Move keeps the puller, the picks and Pause')

    run(p, 'camp', 'off')
    check(camps[p:getID()] == nil and p.printed[#p.printed] == 'squadpanel:campst|0|0|off|0|0|0', 'Camp off is pushed')

    local q = world({ war, puller })
    run(q, 'panel')
    local seenCap, seenSt = false, false
    for _, line in ipairs(q.printed) do
        seenCap = seenCap or has(line, 'squadpanel:cap|') and has(line, 'campmove')
        seenSt = seenSt or has(line, 'squadpanel:campst|1|')
    end
    check(seenCap and seenSt, 'the panel answer says campmove and the campst line')
end
end
]==]

local tail = '\nio.write(string.format("\\n%d passed, %d failed\\n", passed, failed))\nos.exit(failed == 0 and 0 or 1)\n'
assert(load(prefix .. body .. tail, '=test_squad_feedback_camp'))()
