-- Squad mates use the medicines you trade them (squad_meds.lua, 2026-11-25): what they keep, when they use one (only when
-- the party's healers cannot cure them in time; Doom at once), what it does (the item's OWN script from scripts/items),
-- and what they say. The real module, the server's spell data (squad_spell_jobs_data.lua), its effect ids and its item
-- scripts run here with stand-in entities and a stand-in clock; no server, no database. squad.lua's wiring is checked in
-- its source. What is NOT run: a real fight, the trade window, squad.lua's tick.
--   luajit test_squad_meds.lua <server root>
--   Lua 5.4: lua test_squad_meds.lua <server root>
local ROOT = assert(arg[1], 'usage: test_squad_meds.lua <server root>')
package.path = ROOT .. '/?.lua;' .. package.path
local passed, failed = 0, 0
local function check(c, l) if c then passed = passed + 1 else failed = failed + 1; io.write('FAIL: ', l, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

xi = { objType = { PC = 1, TRUST = 2 }, inv = { INVENTORY = 0 }, msg = { channel = { SYSTEM_3 = 121 }, basic = { NARROWLY_ESCAPE = 1, NO_EFFECT = 2 } },
       mod = { ENHANCES_HOLYWATER = 1 } }
dofile(ROOT .. '/scripts/enum/effect.codegen.lua')
local E = xi.effect
local roll = 1
math.randomInt = function(a, b) return roll end -- (Holy Water: 33 > roll removes Doom; Remedy: 1 = Disease removed)

local clock = 1000
local realTime = os.time
os.time = function(t) if t then return realTime(t) end return clock end

local meds = dofile(ROOT .. '/modules/custom/lua/squad_meds.lua')
-- job ids: WHM 3, WAR 1, SCH 20
local function ent(o)
    o = o or {}
    local e = { id = o.id or 10, vars = {}, effects = {}, job = o.job or 1, lvl = o.lvl or 75, sjob = o.sjob or 0, slvl = o.slvl or 0,
                mp = o.mp == nil and 100 or o.mp, alive = o.alive ~= false, zone = o.zone or 100, dist = o.dist or 5, pc = o.pc,
                spells = o.spells, said = {}, charvars = {}, party = {} }
    for _, name in ipairs(o.effects or {}) do e.effects[E[name]] = true end
    function e:getID() return self.id end
    function e:getLocalVar(k) return self.vars[k] or 0 end
    function e:setLocalVar(k, v) self.vars[k] = v end
    function e:getCharVar(k) return self.charvars[k] or 0 end
    function e:setCharVar(k, v) self.charvars[k] = v end
    function e:hasStatusEffect(id) return self.effects[id] == true end
    function e:getStatusEffect(id) return self.effects[id] and {} or nil end
    function e:delStatusEffect(id) self.effects[id] = nil end
    function e:messageBasic() end
    function e:getMod() return 0 end
    function e:isAlive() return self.alive end
    function e:getMainJob() return self.job end
    function e:getMainLvl() return self.lvl end
    function e:getSubJob() return self.sjob end
    function e:getSubLvl() return self.slvl end
    function e:getMP() return self.mp end
    e.maxmp = o.maxmp == nil and 100 or o.maxmp -- (a mate with MP unless said otherwise)
    function e:getMaxMP() return self.maxmp end
    function e:getZoneID() return self.zone end
    function e:checkDistance(other) return other.dist end
    function e:getObjType() return self.pc and xi.objType.PC or xi.objType.TRUST end
    function e:hasSpell(id) return self.spells == nil or self.spells[id] == true end
    function e:getPacketName() return 'Mate' .. self.id end
    function e:printToPlayer(text, mode, who) self.said[#self.said + 1] = { text = text, mode = mode, who = who } end
    function e:getPartyWithTrusts() return self.party end
    function e:getMaster() return self.master end
    return e
end

-- a player with one mate (slot id 7) and whoever else is in the party
local function world(mateOpts, others)
    local p = ent({ id = 1, pc = true, job = 1, dist = 0 })
    mateOpts = mateOpts or {}
    if mateOpts.job == nil then mateOpts.job = 5 end -- (a RDM unless said otherwise: Silence matters to it, it has no -na spells)
    local m = ent(mateOpts)
    m.id = 20
    m.vars.SQUAD_ID = 7
    m.master = p
    p.party = { p, m }
    for _, o in ipairs(others or {}) do p.party[#p.party + 1] = o end
    return p, m
end
local function give(p, itemId, n) p.charvars[string.format('[SqM]7:%d', itemId)] = n end
local function count(p, itemId) return p:getCharVar(string.format('[SqM]7:%d', itemId)) end
local ECHO, ANTIDOTE, EYE, HOLY, REMEDY = 4151, 4148, 4150, 4154, 4155
local function tick(m, dt) clock = clock + (dt or meds.CHECK_SECS); meds.tick(m) end
local function lastSaid(p) local s = p.said[#p.said]; return s and s.text or '' end

section('what a medicine is, and a trade')
check(meds.isMedicine(ECHO) and meds.isMedicine(REMEDY) and not meds.isMedicine(4422), 'medicines yes, a juice (4422) no')
do
    local p, m = world()
    local events = {}
    local deleted = {}
    function p:delItemAt(id, n) deleted[#deleted + 1] = { id, n }; return true end
    check(meds.onTrade(p, p, m, { itemId = ECHO, slot = 3, quantity = 4 }, function(ev, vars) events[#events + 1] = { ev, vars } end) == true,
          'a medicine trade is handled')
    check(count(p, ECHO) == 4 and deleted[1][1] == ECHO and deleted[1][2] == 4 and events[1][1] == 'thanks' and events[1][2].item == 'Echo Drops',
          'kept 4 Echo Drops, taken from the bag, "thanks" said')
    check(has(lastSaid(p), 'Mate20 now carries 4 Echo Drops'), 'the system line: ' .. lastSaid(p))
    meds.onTrade(p, p, m, { itemId = ECHO, slot = 3, quantity = 2 }, function() end)
    check(count(p, ECHO) == 6, 'a second trade adds up (6)')
    function p:delItemAt() return false end
    local said = nil
    meds.onTrade(p, p, m, { itemId = ANTIDOTE, slot = 1, quantity = 1 }, function(ev) said = ev end)
    check(said == 'failed' and count(p, ANTIDOTE) == 0, 'the bag refused: "failed", nothing kept')
    check(meds.onTrade(p, p, m, { itemId = 4422, slot = 1, quantity = 1 }, function() end) == false, 'not a medicine: not handled')
end

section('no healer able to cure it: used at once; the item\'s own script; what is said')
do
    local p, m = world({ effects = { 'SILENCE' } })
    give(p, ECHO, 3)
    tick(m)
    check(not m:hasStatusEffect(E.SILENCE) and count(p, ECHO) == 2, 'silenced, nobody can cast Silena: Echo Drops used, Silence gone, 2 left')
    check(lastSaid(p) == '*uses Echo Drops* (2 left)' and p.said[#p.said].mode == 4 and p.said[#p.said].who == 'Mate20', 'party chat as the mate: "*uses Echo Drops* (2 left)"')
    m.effects[E.SILENCE] = true; tick(m)
    check(lastSaid(p) == '*uses Echo Drops* Only one Echo Drops left.', 'the last but one: "Only one ... left"')
    m.effects[E.SILENCE] = true; tick(m)
    check(lastSaid(p) == '*uses Echo Drops* That was my last Echo Drops!' and count(p, ECHO) == 0, 'the last: "That was my last ...!"')
    m.effects[E.SILENCE] = true; local n = #p.said; tick(m)
    check(m:hasStatusEffect(E.SILENCE) and #p.said == n, 'none left: nothing happens (no free ones)')
end

section('a healer who could cure it: waits GRACE_SECS first')
do
    local whm = ent({ id = 30, job = 3, lvl = 40, mp = 200 })
    local p, m = world({ effects = { 'SILENCE' } }, { whm })
    give(p, ECHO, 5)
    tick(m, 0)
    check(m:hasStatusEffect(E.SILENCE) and count(p, ECHO) == 5, 'a WHM 40 near with MP: not used at once')
    tick(m, meds.GRACE_SECS - 3)
    check(m:hasStatusEffect(E.SILENCE), 'still waiting before ' .. meds.GRACE_SECS .. ' s')
    tick(m, 3)
    check(not m:hasStatusEffect(E.SILENCE) and count(p, ECHO) == 4, 'not cured within the grace time: used')
    -- the status goes away by itself (the healer cured it) and comes back: a new wait
    m.effects[E.SILENCE] = true; tick(m, 1)
    check(m:hasStatusEffect(E.SILENCE), 'a new Silence: waiting again')
    m.effects[E.SILENCE] = nil; tick(m, 1)
    m.effects[E.SILENCE] = true; tick(m, meds.GRACE_SECS - 1)
    check(m:hasStatusEffect(E.SILENCE) and count(p, ECHO) == 4, 'cured meanwhile and silenced again: the wait starts over (not used yet)')
end

section('a healer who cannot cure it now does not count')
local function usedAtOnce(healer, label)
    local p, m = world({ effects = { 'SILENCE' } }, { healer })
    give(p, ECHO, 1)
    tick(m, 0)
    check(count(p, ECHO) == 0, label)
end
usedAtOnce(ent({ id = 31, job = 3, lvl = 18 }), 'a WHM 18 (Silena at 19): used at once')
usedAtOnce(ent({ id = 31, job = 3, lvl = 40, effects = { 'SILENCE' } }), 'a silenced WHM: used at once')
usedAtOnce(ent({ id = 31, job = 3, lvl = 40, effects = { 'SLEEP_I' } }), 'a sleeping WHM: used at once')
usedAtOnce(ent({ id = 31, job = 3, lvl = 40, mp = 5 }), 'a WHM out of MP: used at once')
usedAtOnce(ent({ id = 31, job = 3, lvl = 40, dist = 30 }), 'a WHM 30 yalms away: used at once')
usedAtOnce(ent({ id = 31, job = 3, lvl = 40, zone = 101 }), 'a WHM in another zone: used at once')
usedAtOnce(ent({ id = 31, job = 3, lvl = 40, alive = false }), 'a fallen WHM: used at once')
usedAtOnce(ent({ id = 31, job = 1, lvl = 75 }), 'a WAR: used at once')
usedAtOnce(ent({ id = 31, job = 3, lvl = 40, pc = true, spells = {} }), 'a WHM player who has not learned Silena: used at once')
do
    local p, m = world({ effects = { 'SILENCE' } }, { ent({ id = 31, job = 1, lvl = 75, sjob = 3, slvl = 37 }) })
    give(p, ECHO, 1)
    tick(m, 0)
    check(count(p, ECHO) == 1, 'WAR75/WHM37 (Silena by the support job): counts as a healer - waits')
    local p2, m2 = world({ effects = { 'SILENCE' } }, { ent({ id = 31, job = 3, lvl = 40, pc = true, spells = { [17] = true } }) })
    give(p2, ECHO, 1)
    tick(m2, 0)
    check(count(p2, ECHO) == 1, 'a WHM player who knows Silena (spell 17): waits')
end
do
    -- the mate itself is the party's only WHM and is silenced: nobody else, so at once
    local p, m = world({ job = 3, lvl = 50, effects = { 'SILENCE' } })
    give(p, ECHO, 1)
    tick(m, 0)
    check(count(p, ECHO) == 0, 'a silenced WHM mate (itself the healer) uses Echo Drops at once')
end

section('which medicine: the one made for it, else Remedy; Doom at once')
do
    local p, m = world({ effects = { 'SILENCE' } })
    give(p, ECHO, 1); give(p, REMEDY, 1)
    tick(m, 0)
    check(count(p, ECHO) == 0 and count(p, REMEDY) == 1, 'Silence with Echo Drops and a Remedy: Echo Drops')
    m.effects[E.PARALYSIS] = true; tick(m)
    check(count(p, REMEDY) == 0 and not m:hasStatusEffect(E.PARALYSIS), 'Paralysis (only a Remedy cures it): Remedy')
    local p2, m2 = world({ effects = { 'POISON', 'BLINDNESS' } })
    give(p2, REMEDY, 1)
    tick(m2, 0)
    check(not m2:hasStatusEffect(E.POISON) and not m2:hasStatusEffect(E.BLINDNESS) and count(p2, REMEDY) == 0, 'one Remedy cures Poison and Blindness together (its script)')
    local whm = ent({ id = 30, job = 3, lvl = 75 })
    local p3, m3 = world({ effects = { 'DOOM' } }, { whm })
    give(p3, HOLY, 2)
    roll = 1
    tick(m3, 0)
    check(not m3:hasStatusEffect(E.DOOM) and count(p3, HOLY) == 1, 'Doom: Holy Water at once, even with a WHM who knows Cursna; the 33% roll removed it')
    m3.effects[E.DOOM] = true; roll = 90; tick(m3)
    check(m3:hasStatusEffect(E.DOOM) and count(p3, HOLY) == 0, 'the roll failed (Holy Water\'s own 33%): Doom stays, the Holy Water is still used up')
    roll = 1
    local p4, m4 = world({ effects = { 'CURSE_I' } })
    give(p4, HOLY, 1)
    tick(m4, 0)
    check(not m4:hasStatusEffect(E.CURSE_I), 'Curse with nobody to cast Cursna: Holy Water at once')
end

section('Silence only matters to a mate whose main or support job casts (by job, not by MP)')
do
    local p, m = world({ job = 1, maxmp = 0, effects = { 'SILENCE' } })
    give(p, ECHO, 2)
    tick(m, 0); tick(m, meds.GRACE_SECS + 1)
    check(count(p, ECHO) == 2 and m:hasStatusEffect(E.SILENCE), 'a WAR without MP, silenced: keeps its Echo Drops (also after the wait)')
    local p2, m2 = world({ job = 1, maxmp = 0, effects = { 'SILENCE' } })
    give(p2, REMEDY, 1)
    tick(m2, 0); tick(m2, meds.GRACE_SECS + 1)
    check(count(p2, REMEDY) == 1, 'nor a Remedy for Silence alone')
    m2.effects[E.POISON] = true; tick(m2)
    check(count(p2, REMEDY) == 0 and not m2:hasStatusEffect(E.POISON), 'but the Remedy for Poison (it matters to everyone)')
    local p3, m3 = world({ job = 1, maxmp = 0, sjob = 13, slvl = 37, effects = { 'SILENCE' } })
    give(p3, ECHO, 1)
    tick(m3, 0)
    check(count(p3, ECHO) == 0, 'WAR/NIN (no MP, Utsusemi): uses Echo Drops')
    local p4, m4 = world({ job = 13, maxmp = 0, effects = { 'SILENCE' } })
    give(p4, ECHO, 1)
    tick(m4, 0)
    check(count(p4, ECHO) == 0, 'a NIN: uses Echo Drops')
    local p5, m5 = world({ job = 1, maxmp = 40, sjob = 3, slvl = 37, effects = { 'SILENCE' } })
    give(p5, ECHO, 1)
    tick(m5, 0)
    check(count(p5, ECHO) == 0, 'WAR/WHM (MP from the support job): uses Echo Drops')
    check(meds.silenceMatters(ent({ job = 3, maxmp = 120 })) and not meds.silenceMatters(ent({ job = 2, maxmp = 0 })),
          'silenceMatters: a WHM yes, a MNK no')
    -- MP from gear (a WAR in an MP+ piece) does not make a WAR cast
    local p6, m6 = world({ job = 1, maxmp = 20, effects = { 'SILENCE' } })
    give(p6, ECHO, 1)
    tick(m6, 0); tick(m6, meds.GRACE_SECS + 1)
    check(count(p6, ECHO) == 1, 'a WAR/WAR with 20 MP from gear: keeps its Echo Drops')
    for _, job in ipairs({ 4, 7, 8, 10, 15, 16, 20, 21, 22 }) do
        check(meds.silenceMatters(ent({ job = job, maxmp = 0 })), 'job ' .. job .. ' casts')
    end
    for _, job in ipairs({ 1, 2, 6, 9, 11, 12, 14, 17, 18, 19 }) do
        check(not meds.silenceMatters(ent({ job = job, maxmp = 50 })), 'job ' .. job .. ' does not cast (whatever its MP)')
    end
    check(meds.silenceMatters(ent({ job = 6, sjob = 4 })), 'THF/BLM: the support job casts')
end

section('when a mate does nothing')
do
    local p, m = world({ effects = { 'SILENCE', 'SLEEP_I' } })
    give(p, ECHO, 1)
    tick(m, 0)
    check(count(p, ECHO) == 1, 'asleep: no item use')
    m.effects[E.SLEEP_I] = nil; m.effects[E.MEDICINE] = true; tick(m)
    check(count(p, ECHO) == 1, 'under "Medicine" (no medicines for a while): no use')
    m.effects[E.MEDICINE] = nil; m.vars.SQUAD_IDLE = 1; tick(m)
    check(count(p, ECHO) == 1, 'SQUAD_IDLE (stays put): no use')
    m.vars.SQUAD_IDLE = 0
    local n = #p.said
    clock = clock + 1; meds.tick(m) -- (1 s after the last look: within CHECK_SECS)
    check(count(p, ECHO) == 1 and #p.said == n, 'looked less than CHECK_SECS ago: nothing yet')
    tick(m)
    check(count(p, ECHO) == 0, 'then it is used')
    local p2, m2 = world()
    give(p2, ECHO, 1)
    tick(m2, 0)
    check(count(p2, ECHO) == 1, 'no status: nothing used')
    local p3, m3 = world({ effects = { 'SILENCE' } })
    tick(m3, 0)
    check(#p3.said == 0, 'carries nothing: nothing happens, nothing said')
end

section('!squad meds')
do
    local p = world()
    give(p, ECHO, 3); give(p, REMEDY, 1)
    meds.command(p, { { id = 7, name = 'Mira' }, { id = 9, name = 'Bran' } })
    check(#p.said == 1 and p.said[1].text == 'Mira: 1 Remedy, 3 Echo Drops', 'what Mira carries (Bran nothing): ' .. tostring(p.said[1] and p.said[1].text))
    local q = world()
    meds.command(q, { { id = 7, name = 'Mira' } })
    check(has(q.said[1].text, 'No mate carries any medicine'), 'nobody carries any: how to give them')
end

section('squad.lua: loaded as xi.squad.meds, ticked, traded, the command (source)')
do
    local f = assert(io.open(ROOT .. '/modules/custom/lua/squad.lua', 'rb'))
    local src = f:read('*a')
    f:close()
    check(src:find("require, 'modules/custom/lua/squad_meds'", 1, true) ~= nil and src:find('xi.squad.meds = okMeds', 1, true) ~= nil, 'required as xi.squad.meds')
    check(src:find('pcall(xi.squad.meds.tick, mobArg)', 1, true) ~= nil, 'ticked with the mates (next to the juices)')
    check(src:find('xi.squad.meds.isMedicine(offer.itemId)', 1, true) ~= nil and src:find('xi.squad.meds.onTrade(player, owner, trust, offer', 1, true) ~= nil, 'traded')
    check(src:find("action == 'meds'", 1, true) ~= nil and src:find('xi.squad.meds.command(player', 1, true) ~= nil, '!squad meds')
end

os.time = realTime
io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
