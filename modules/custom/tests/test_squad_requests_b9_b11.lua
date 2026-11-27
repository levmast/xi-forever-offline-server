-- Feedback batch B7-F24 (2026-11-27), party chat requests through the real squad_requests.lua and its data:
--   B9  Raise on a body out of reach: "far" says how far and why there is no walking (a fight, the camp); "approach" says
--       "on my way" at once and then what happened (cast, or why not)
--   B11 a Bar-ra spell that waits for its caster to step in: received at once ("Getting closer"), "On it" only once the
--       effect is on you, and a deferred cast that never happened is said so; the Bar effects are checked like Protect
--   the self-only Barwater (Red Mage) keeps its answer
-- The engine (SquadCastSpell, SquadSpellKind, the mate's SQUAD_DEFER_* / SQUAD_FAR_* local vars) is a stand-in; the walk and
-- the step in are in C++ (trust_controller.cpp; their rules in squad_feedback_b7_tests.cpp). No server, nothing is written.
--   luajit test_squad_requests_b9_b11.lua <server>/modules/custom/lua
local LUA = assert(arg[1], 'usage: test_squad_requests_b9_b11.lua <server>/modules/custom/lua')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end
local LOG = {}
print = function(...) LOG[#LOG + 1] = table.concat({ ... }, '\t') end

-- ---------------------------------------------------------------- stand-ins
local ids = { RAISE = 12, RAISE_II = 13, RAISE_III = 140, BARWATERA = 71, BARWATER = 65, CURE = 1 }
xi = { objType = { PC = 1, TRUST = 2 }, squad = {},
       effect = { BARWATER = 105, SLEEP_I = 2, SLEEP_II = 19, LULLABY = 193 },
       magic = { spell = ids } }
package.preload['modules/module_utils'] = function() return true end
package.preload['modules/custom/lua/squad_requests_data'] = function() return dofile(LUA .. '/squad_requests_data.lua') end
GetSpell = function() return { getCastTime = function() return 1000 end } end
SquadSpellIdByName = function(name) return ids[string.upper(name)] end
SquadSpellKind = function(id)
    if id == ids.RAISE or id == ids.RAISE_II or id == ids.RAISE_III then return 'dead' end
    if id == ids.BARWATER then return 'self' end
    return 'party'
end

local RESULT = 'cast' -- what SquadCastSpell answers next
local CASTS = {}
SquadCastSpell = function(player, mate, id, named)
    CASTS[#CASTS + 1] = { mate = mate.name, id = id }
    return RESULT
end

local REPORTS = {}
xi.squad.onSpellCommand = function(player, mate, spellName, result) REPORTS[#REPORTS + 1] = { mate = mate.name, spell = spellName, result = result } end

local TIMERS = {}
local function entity(name, objType, job)
    local e = { name = name, effects = {}, hpp = 100, vars = {}, said = {}, dead = false }
    function e:getName() return self.name end
    function e:getPacketName() return self.name end
    function e:getID() return #self.name * 1000 + string.byte(self.name, 1) end
    function e:getObjType() return objType end
    function e:getMainJob() return job or 1 end
    function e:getMP() return 100 end
    function e:checkDistance() return 3 end
    function e:getZoneID() return 116 end
    function e:isDead() return self.dead end
    function e:isEngaged() return self.engaged == true end
    function e:getHPP() return self.hpp end
    function e:hasStatusEffect(id) return self.effects[id] == true end
    function e:getLocalVar(k) return self.vars[k] or 0 end
    function e:setLocalVar(k, v) self.vars[k] = v end
    function e:getCharVar(k) return self.vars[k] or 0 end
    function e:timer(ms, fn) TIMERS[#TIMERS + 1] = fn end
    function e:printToPlayer(text, _, who) self.said[#self.said + 1] = (who and (who .. ': ') or '') .. text end
    return e
end

local player, momo, whm, rdm
local function world()
    player = entity('Tester', 1)
    momo = entity('Momo', 1)
    whm = entity('Shiva', 2, 3)
    rdm = entity('Ayame', 2, 5)
    CASTS, TIMERS, REPORTS, RESULT = {}, {}, {}, 'cast'
    if SQUAD_REQ then SQUAD_REQ.claims, SQUAD_REQ.lines = {}, {} end
    local party = { player, momo, whm, rdm }
    function player:getPartyWithTrusts() return party end
    SQUAD_LOGIC = { mates = function() return { whm, rdm } end }
end

assert(loadfile(LUA .. '/squad_requests.lua'))()
local R = SQUAD_REQ

local function runTimers(times)
    for _ = 1, times or 1 do
        local list = TIMERS
        TIMERS = {}
        for _, fn in ipairs(list) do fn() end
    end
end
local function lastSaid() return player.said[#player.said] end

-- ================================================================= B11
section('B11: Bar spells, the step in, and "On it" only once it is on')
do
    check(R.EFFECT.barwatera == 'BARWATER' and R.EFFECT.barwater == 'BARWATER' and R.EFFECT.barfira == 'BARFIRE' and R.EFFECT.barstonra == 'BARSTONE',
        'the Bar spells and their -ra versions are checked by their effect')

    -- typed "barwatera": not a request word of the extras, so the plain spell path (R.cast) takes it; Auto-Translate gives the same text
    world()
    check(R.pre(player, 'barwatera', false) == false, '"barwatera" goes to the spell path (squad_logic.lua -> R.cast), as before')
    check(R.pre(player, 'barwatera', true) == false, 'with Auto-Translate the same line goes the same way')

    world()
    RESULT = 'stepin'
    check(R.cast(player, { whm, rdm }, false, ids.BARWATERA, 'barwatera', nil, 'barwatera') == true, 'the request is taken')
    check(#CASTS == 1 and CASTS[1].mate == 'Shiva', 'the first mate takes it (one cast)')
    check(has(lastSaid(), 'Getting closer for Barwatera') or has(lastSaid(), 'Barwatera as soon as'), 'received at once, said as such: ' .. tostring(lastSaid()))
    check(#REPORTS == 0, 'no "On it" yet: nothing is cast yet')
    check(R.taken(player, ids.BARWATERA, player), 'taken while it waits (a repeated line is not cast again)')

    whm.vars.SQUAD_DEFER_SPELL, whm.vars.SQUAD_DEFER_STATE = ids.BARWATERA, 1
    runTimers()
    check(#REPORTS == 0, 'still stepping in: still no "On it"')
    whm.vars.SQUAD_DEFER_STATE = 2 -- (the cast started after the step in)
    runTimers()
    check(#REPORTS == 0, 'cast started: "On it" waits for the effect')
    player.effects[xi.effect.BARWATER] = true
    runTimers(2)
    check(#REPORTS == 1 and REPORTS[1].result == 'cast', '"On it" once Barwater is on you')

    -- the deferred cast was refused (the mate was busy when it got there)
    world()
    RESULT = 'stepin'
    R.cast(player, { whm }, false, ids.BARWATERA, 'barwatera', nil, 'barwatera')
    whm.vars.SQUAD_DEFER_SPELL, whm.vars.SQUAD_DEFER_STATE, whm.vars.SQUAD_DEFER_WHY = ids.BARWATERA, 3, 6
    runTimers()
    check(has(lastSaid(), 'No Barwatera after all') and has(lastSaid(), 'busy'), 'a refused deferred cast is said: ' .. tostring(lastSaid()))
    check(#REPORTS == 0 and not R.taken(player, ids.BARWATERA, player), 'no "On it", and the claim is let go (asking again works)')

    -- cast, but it never landed
    world()
    RESULT = 'stepin'
    R.cast(player, { whm }, false, ids.BARWATERA, 'barwatera', nil, 'barwatera')
    whm.vars.SQUAD_DEFER_SPELL, whm.vars.SQUAD_DEFER_STATE = ids.BARWATERA, 2
    runTimers(5)
    check(has(lastSaid(), 'did not land') or has(lastSaid(), 'did not take'), 'cast but not on you: "did not land": ' .. tostring(lastSaid()))

    -- no outcome at all (an older xi_map, or lost): not silent
    world()
    RESULT = 'stepin'
    R.cast(player, { whm }, false, ids.BARWATERA, 'barwatera', nil, 'barwatera')
    runTimers(R.DEFER_TRIES + 1)
    check(has(lastSaid(), 'took too long'), 'no outcome: said after a while: ' .. tostring(lastSaid()))

    -- an ordinary cast that started at once: the old path (On it when it landed)
    world()
    RESULT = 'cast'
    R.cast(player, { whm }, false, ids.BARWATERA, 'barwatera', nil, 'barwatera')
    check(#REPORTS == 0, 'cast at once: "On it" waits for the effect (before, it was said at accept)')
    player.effects[xi.effect.BARWATER] = true
    runTimers()
    check(#REPORTS == 1 and REPORTS[1].result == 'cast', 'and comes once it is on')

    -- the self-only Barwater (Red Mage): the answer it had
    world()
    R.cast(player, { rdm }, false, ids.BARWATER, 'barwater', nil, 'barwater')
    check(has(lastSaid(), 'only') and #CASTS == 0, 'Barwater (self only): "only works on whoever casts it", not cast: ' .. tostring(lastSaid()))
end

-- ================================================================= B9
section('B9: Raise on a body out of reach')
do
    -- far: how far, and why the mate does not walk
    world()
    momo.dead = true
    RESULT = 'far'
    whm.vars.SQUAD_FAR_DIST, whm.vars.SQUAD_FAR_REACH = 255, 210
    check(R.pre(player, 'raise momo', false) == true, '"raise momo" is a request')
    runTimers(R.BUSY_RETRIES + 2)
    check(has(lastSaid(), 'Momo is too far away for Raise') and has(lastSaid(), '26 yalms') and has(lastSaid(), 'I reach 21'),
        'too far: the distance and the reach: ' .. tostring(lastSaid()))
    check(not has(table.concat(player.said, '\n'), 'busy'), 'not "busy" any more')

    world()
    momo.dead = true
    RESULT = 'far'
    whm.vars.SQUAD_FAR_DIST, whm.vars.SQUAD_FAR_REACH = 255, 210
    player.engaged = true
    R.pre(player, 'raise momo', false)
    runTimers(R.BUSY_RETRIES + 2)
    check(has(lastSaid(), 'do not leave a fight'), 'in a fight: says it does not leave the fight for it: ' .. tostring(lastSaid()))
    player.engaged = false

    world()
    momo.dead = true
    RESULT = 'far'
    whm.vars.SQUAD_FAR_DIST, whm.vars.SQUAD_FAR_REACH = 255, 210
    whm.vars.SQUAD_CAMP = 1
    R.pre(player, 'raise momo', false)
    runTimers(R.BUSY_RETRIES + 2)
    check(has(lastSaid(), 'holding the camp'), 'at a camp: says it holds the camp: ' .. tostring(lastSaid()))

    -- approach: on my way at once, then the outcome
    world()
    momo.dead = true
    RESULT = 'approach'
    R.pre(player, 'raise momo', false)
    check((has(lastSaid(), 'On my way: Raise') or has(lastSaid(), 'Coming over for Raise')) and has(lastSaid(), 'Momo'),
        'received at once (the best tier it has): ' .. tostring(lastSaid()))
    check(#REPORTS == 0, 'not "cast" yet')
    local raiseId = CASTS[1] and CASTS[1].id
    whm.vars.SQUAD_DEFER_SPELL, whm.vars.SQUAD_DEFER_STATE = raiseId, 2
    runTimers()
    check(#REPORTS == 1 and REPORTS[1].result == 'cast', 'cast once it got there (Raise has no effect to wait for)')

    world()
    momo.dead = true
    RESULT = 'approach'
    R.pre(player, 'raise momo', false)
    raiseId = CASTS[1] and CASTS[1].id
    whm.vars.SQUAD_DEFER_SPELL, whm.vars.SQUAD_DEFER_STATE, whm.vars.SQUAD_DEFER_WHY = raiseId, 3, 3
    runTimers()
    check(has(lastSaid(), 'No Raise') and has(lastSaid(), 'a fight started'), 'a fight started on the way: said, no cast: ' .. tostring(lastSaid()))
    world()
    momo.dead = true
    RESULT = 'approach'
    R.pre(player, 'raise momo', false)
    raiseId = CASTS[1] and CASTS[1].id
    whm.vars.SQUAD_DEFER_SPELL, whm.vars.SQUAD_DEFER_STATE, whm.vars.SQUAD_DEFER_WHY = raiseId, 3, 4
    runTimers()
    check(has(lastSaid(), 'the target changed'), 'the body got up or left: said: ' .. tostring(lastSaid()))

    -- in reach: as before
    world()
    momo.dead = true
    RESULT = 'cast'
    R.pre(player, 'raise momo', false)
    check(#REPORTS == 1 and REPORTS[1].result == 'cast', 'in reach: cast and answered at once, as before')
end

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
