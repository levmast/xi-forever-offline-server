-- Community feedback milestone (2026-11-25), party chat requests through the real squad_requests.lua and its data:
--   B2  "/p escape" with the request extras on (the default) is cast by the Black Mage, not refused as caster-only
--   B3a "/p cure Momo" while Momo sleeps at full HP is cast (a Cure wakes); an untargeted "cure" still means you
--   B4  "/p blink" / "/p aquaveil": every mate that knows it casts it on herself, at the same time; each landing is checked on
--       that caster; a named mate only; naming somebody else is the self-only answer
-- The engine (SquadCastSpell, SquadSpellKind) is a stand-in that records the casts; the cast gate that let the mates cast at
-- the same time is tested in C++ (trust_cast_gate_tests.cpp). No server, no database; nothing is written.
--   luajit test_squad_feedback_requests.lua <server>/modules/custom/lua
local LUA = assert(arg[1], 'usage: test_squad_feedback_requests.lua <server>/modules/custom/lua')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
local LOG = {}
print = function(...) LOG[#LOG + 1] = table.concat({ ... }, '\t') end

-- ---------------------------------------------------------------- stand-ins
local ids = { ESCAPE = 263, CURE = 1, CURE_II = 2, CURE_III = 3, CURE_IV = 4, CURE_V = 5, BLINK = 53, STONESKIN = 54, AQUAVEIL = 55,
              PHALANX = 106, PROTECT = 43, SNEAK = 137 }
xi = { objType = { PC = 1, TRUST = 2 }, squad = {},
       effect = { SLEEP_I = 2, SLEEP_II = 19, LULLABY = 193, BLINK = 36, AQUAVEIL = 39, STONESKIN = 37, PHALANX = 116, PROTECT = 40, SNEAK = 71 },
       magic = { spell = ids } }
package.preload['modules/module_utils'] = function() return true end
package.preload['modules/custom/lua/squad_requests_data'] = function() return dofile(LUA .. '/squad_requests_data.lua') end
GetSpell = function() return { getCastTime = function() return 1000 end } end
SquadSpellIdByName = function(name) return ids[string.upper(name)] end
SquadSpellKind = function(id)
    if id == ids.BLINK or id == ids.STONESKIN or id == ids.AQUAVEIL or id == ids.PHALANX then return 'self' end
    return 'party' -- (Escape: party since the Protectra II fix; Cure, Protect, Sneak: party)
end

local CASTS = {}
local KNOWS = {}       -- [mate name] = { [spell id] = true }
local ON_CAST = nil    -- a function(mate, id, target) that puts the effect on, as the engine would
SquadCastSpell = function(player, mate, id, named)
    if not (KNOWS[mate.name] or {})[id] then
        return 'unknown'
    end

    CASTS[#CASTS + 1] = { mate = mate.name, id = id, target = named and named.name or 'player' }
    if ON_CAST then ON_CAST(mate, id, named or player) end
    return 'cast'
end

local TIMERS = {}
local function entity(name, objType, job)
    local e = { name = name, effects = {}, hpp = 100, vars = {}, said = {} }
    function e:getName() return self.name end
    function e:getPacketName() return self.name end
    function e:getID() return #self.name * 1000 + string.byte(self.name, 1) end
    function e:getObjType() return objType end
    function e:getMainJob() return job or 1 end
    function e:getMP() return 100 end
    function e:checkDistance() return 3 end
    function e:getZoneID() return 116 end
    function e:isDead() return false end
    function e:getHPP() return self.hpp end
    function e:hasStatusEffect(id) return self.effects[id] == true end
    function e:getLocalVar(k) return self.vars[k] or 0 end
    function e:getCharVar(k) return self.vars[k] or 0 end
    function e:timer(ms, fn) TIMERS[#TIMERS + 1] = fn end
    function e:printToPlayer(text, _, who) self.said[#self.said + 1] = (who and (who .. ': ') or '') .. text end
    return e
end

local player, momo, ayame, shiva, war
local function world()
    player = entity('Tester', 1)
    momo = entity('Momo', 1)                -- another player in the party
    ayame = entity('Ayame', 2, 5)          -- RDM mate: Blink, Aquaveil, Phalanx, Cure
    shiva = entity('Shiva', 2, 3)          -- WHM mate: Blink, Aquaveil, Stoneskin, Cure
    war = entity('Rolf', 2, 1)             -- WAR mate: none of them
    local blm = entity('Nox', 2, 4)        -- BLM mate: Escape
    KNOWS = {
        Ayame = { [ids.BLINK] = true, [ids.AQUAVEIL] = true, [ids.PHALANX] = true, [ids.CURE] = true, [ids.CURE_II] = true },
        Shiva = { [ids.BLINK] = true, [ids.AQUAVEIL] = true, [ids.STONESKIN] = true, [ids.CURE] = true, [ids.CURE_II] = true, [ids.CURE_III] = true },
        Nox = { [ids.ESCAPE] = true },
    }
    CASTS, TIMERS, ON_CAST = {}, {}, nil
    if SQUAD_REQ then SQUAD_REQ.claims, SQUAD_REQ.lines = {}, {} end -- (a request's claim lasts a few seconds: each case starts clean)
    local party = { player, momo, ayame, shiva, war, blm }
    function player:getPartyWithTrusts() return party end
    SQUAD_LOGIC = { mates = function() return { war, ayame, shiva, blm } end }
    return blm
end

assert(loadfile(LUA .. '/squad_requests.lua'))()
local R = SQUAD_REQ

local function say(text)
    return R.pre(player, text, false)
end

local function runTimers()
    local list = TIMERS
    TIMERS = {}
    for _, fn in ipairs(list) do fn() end
end

-- ================================================================= B2
section('B2: escape')
do
    local blm = world()
    check(say('escape') == true, 'the line is a request')
    check(#CASTS == 1 and CASTS[1].mate == 'Nox' and CASTS[1].id == ids.ESCAPE and CASTS[1].target == 'player',
        'the Black Mage casts Escape (on herself; the engine aims it at the caster): ' .. (CASTS[1] and (CASTS[1].mate .. ' ' .. CASTS[1].id) or 'nothing'))
    local refused = false
    for _, who in ipairs({ war, ayame, shiva, blm }) do
        for _, line in ipairs(player.said) do refused = refused or line:find('only takes the caster', 1, true) ~= nil end
    end
    check(not refused, 'not answered as caster-only')

    world()
    player.vars.SQREQ_MORE_OFF = 1 -- (!sqreq more off: the plain spell path, unchanged)
    check(say('escape') == false, 'with the extras off the line goes to the plain spell path (squad_logic.lua), as before')
end

-- ================================================================= B3a
section('B3a: cure on a sleeping member')
do
    world()
    momo.effects[xi.effect.SLEEP_I] = true
    say('cure momo')
    check(#CASTS == 1 and CASTS[1].target == 'Momo', 'Momo asleep at full HP: cured (it wakes her)')

    world()
    momo.effects[xi.effect.LULLABY] = true
    say('cure momo')
    check(#CASTS == 1 and CASTS[1].target == 'Momo', 'Lullaby counts as asleep')

    world()
    say('cure momo')
    check(#CASTS == 0, 'Momo awake at full HP: nothing to cure, as before')
    check(player.said[#player.said] ~= nil and player.said[#player.said]:find('Momo', 1, true) ~= nil, 'and the mate says so')

    world()
    momo.effects[xi.effect.SLEEP_I] = true
    say('cure')
    check(#CASTS == 0, 'an untargeted "cure" still means you (full HP: nothing), not the sleeper')

    world()
    player.hpp = 50
    say('cure')
    check(#CASTS == 1 and CASTS[1].target == 'player', 'an untargeted "cure" at 50% HP: on you, as before')
end

-- ================================================================= B4
section('B4: self-only buffs')
do
    world()
    ON_CAST = function(mate, id) if id == ids.BLINK then mate.effects[xi.effect.BLINK] = true end end
    say('blink')
    check(#CASTS == 2, 'two mates know Blink: two casts in the same pass (no waiting), got ' .. #CASTS)
    local by = {}
    for _, c in ipairs(CASTS) do by[c.mate] = c.target end
    check(by.Ayame == 'Ayame' and by.Shiva == 'Shiva', 'each on herself')
    check(#TIMERS == 2, 'each mate checks her own landing (one check each)')
    runTimers()
    local failedLine = false
    for _, line in ipairs(player.said) do failedLine = failedLine or line:find('did not land', 1, true) ~= nil or line:find('fizzled', 1, true) ~= nil end
    check(not failedLine, 'no false "did not land": the effect is checked on the caster')

    world()
    ON_CAST = nil
    say('aquaveil')
    runTimers(); runTimers(); runTimers()
    local fails = 0
    for _, line in ipairs(player.said) do if line:find('did not land', 1, true) or line:find('fizzled', 1, true) then fails = fails + 1 end end
    check(#CASTS == 2 and fails == 2, 'an Aquaveil that never lands is reported by each caster (' .. fails .. ')')

    world()
    ayame.effects[xi.effect.BLINK] = true
    say('blink')
    check(#CASTS == 1 and CASTS[1].mate == 'Shiva', 'a mate that already has Blink does not cast it again')

    world()
    say('ayame blink')
    check(#CASTS == 1 and CASTS[1].mate == 'Ayame' and CASTS[1].target == 'Ayame', 'a named mate only')

    world()
    say('blink ayame')
    check(#CASTS == 1 and CASTS[1].mate == 'Ayame', '"blink Ayame": Ayame casts it on herself')

    world()
    say('blink momo')
    check(#CASTS == 0, 'Blink cannot be put on Momo')
    local selfonly = false
    for _, line in ipairs(player.said) do selfonly = selfonly or line:find('only', 1, true) ~= nil end
    check(selfonly, 'the self-only answer')

    world()
    say('stoneskin')
    check(#CASTS == 1 and CASTS[1].mate == 'Shiva' and CASTS[1].target == 'Shiva', 'Stoneskin: the White Mage on herself')

    world()
    say('blink')
    check(#CASTS == 2, 'Rolf (no Blink) is skipped quietly')
    local unknownLine = false
    for _, line in ipairs(player.said) do unknownLine = unknownLine or line:find('Rolf', 1, true) ~= nil end
    check(not unknownLine, 'and does not answer')
end

-- ================================================================= unchanged
section('unchanged: a targeted buff is one cast on you')
do
    world()
    KNOWS.Shiva[ids.PROTECT] = true
    KNOWS.Ayame[ids.PROTECT] = true
    say('protect')
    check(#CASTS == 1 and CASTS[1].target == 'player', 'protect: one cast, on you')
end

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
