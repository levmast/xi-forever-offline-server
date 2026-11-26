-- Squad teleports by party chat (2026-11-25, JØ: "teleport, D2 and Recall by typing the name of the spell"), through the real
-- squad_requests.lua and its data: the six Teleports, Escape, and Warp II on you ("d2", "warp", "warp ii", "warp 2", "go home").
-- Recall is Wings of the Goddess (not in this era). The harness is test_squad_feedback_requests.lua's (stand-in engine, no server).
--   luajit test_squad_teleport_requests.lua <server>/modules/custom/lua
--   luajit test_squad_feedback_requests.lua <server>/modules/custom/lua
local LUA = assert(arg[1], 'usage: test_squad_feedback_requests.lua <server>/modules/custom/lua')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
local LOG = {}
print = function(...) LOG[#LOG + 1] = table.concat({ ... }, '\t') end

-- ---------------------------------------------------------------- stand-ins
ids = { ESCAPE = 263, CURE = 1, CURE_II = 2, CURE_III = 3, CURE_IV = 4, CURE_V = 5, BLINK = 53, STONESKIN = 54, AQUAVEIL = 55,
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


-- ================================================================= teleports (2026-11-25, JØ: "teleport, D2 and Recall by typing the spell")
ids.TELEPORT_HOLLA, ids.TELEPORT_DEM, ids.TELEPORT_MEA, ids.TELEPORT_YHOAT, ids.TELEPORT_ALTEP, ids.TELEPORT_VAHZL, ids.WARP_II = 120, 121, 122, 123, 124, 125, 140
local function teleWorld()
    local blm = world()
    KNOWS.Shiva[ids.TELEPORT_HOLLA] = true; KNOWS.Shiva[ids.TELEPORT_DEM] = true; KNOWS.Shiva[ids.TELEPORT_MEA] = true
    KNOWS.Shiva[ids.TELEPORT_YHOAT] = true; KNOWS.Shiva[ids.TELEPORT_ALTEP] = true; KNOWS.Shiva[ids.TELEPORT_VAHZL] = true
    KNOWS.Nox[ids.WARP_II] = true
    return blm
end
section('teleports by party chat')
for _, case in ipairs({ { 'teleport holla', 'TELEPORT_HOLLA' }, { 'tele dem', 'TELEPORT_DEM' }, { 'mea', 'TELEPORT_MEA' },
                        { 'teleport-yhoat', 'TELEPORT_YHOAT' }, { 'tele altep', 'TELEPORT_ALTEP' }, { 'teleport vahzl', 'TELEPORT_VAHZL' },
                        { 'escape', 'ESCAPE' } }) do
    teleWorld()
    local ok = say(case[1])
    check(ok == true and #CASTS == 1 and CASTS[1].id == ids[case[2]],
        string.format('"%s" -> %s (%s)', case[1], case[2], CASTS[1] and (CASTS[1].mate .. ' ' .. CASTS[1].id) or 'nothing'))
end
section('warp ii (D2) on you')
for _, word in ipairs({ 'd2', 'warp', 'warp ii', 'warp 2', 'go home' }) do
    teleWorld()
    local ok = say(word)
    check(ok == true and #CASTS == 1 and CASTS[1].mate == 'Nox' and CASTS[1].id == ids.WARP_II,
        string.format('"%s" -> Nox casts Warp II (%s)', word, CASTS[1] and (CASTS[1].mate .. ' ' .. CASTS[1].id .. ' on ' .. CASTS[1].target) or 'nothing'))
end
section('nobody knows it')
do
    world()
    check(say('teleport holla') == true and #CASTS == 0, 'no cast when no mate knows Teleport-Holla')
    io.write(table.concat(player.said, ' | '), '\n')
end

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
