-- Rule Set live status (2026-11-24): what a called squad mate really runs (a Gambits Rule Set or its default job rules),
-- written at the call as local vars on the mate (squad_rulesets.lua R.markLive) and reported to the Squads menu as
-- squadpanel:rs|... (R.liveStatus / R.panelLine). No combat change: the gambits of every case below are compared with
-- the squad.lua and squad_rulesets.lua this change started from. No server, no database; nothing is written.
--   luajit test_squad_ruleset_status.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua
--                                        <server>/scripts/enum/job_ability.lua [<baseline lua folder>]
--   Lua 5.4: lua -e "unpack = unpack or table.unpack" test_squad_ruleset_status.lua ...   (the server runs LuaJIT)
-- The optional baseline folder holds squad.lua and squad_rulesets.lua of the base commit (git show 2dd815c19a:...).
local LUA, GAMBITS, JA_ENUM, BASE = arg[1], arg[2], arg[3], arg[4]
assert(LUA and GAMBITS and JA_ENUM, 'usage: test_squad_ruleset_status.lua <lua folder> gambits.lua job_ability.lua [baseline folder]')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

local LOG = {}
print = function(...) local p = {} for i = 1, select('#', ...) do p[#p + 1] = tostring((select(i, ...))) end LOG[#LOG + 1] = table.concat(p, '\t') end

-- ---------------------------------------------------------------- the server bits squad.lua needs at load
dofile(GAMBITS)
local function registry(first, fixed, missing)
    local nextId, t = first, {}
    for name, id in pairs(fixed or {}) do t[name] = id end
    return setmetatable(t, { __index = function(self, name)
        if type(name) ~= 'string' or (missing and missing[name]) then return nil end
        local id = nextId
        nextId = nextId + 1
        rawset(self, name, id)
        return id
    end })
end
xi = { module = { registerCommand = function() end }, objType = { PC = 1, TRUST = 2, MOB = 3 },
       animation = { NONE = 0, ATTACK = 1, HEALING = 33 }, settings = { map = { EXP_RATE = 1, SUBJOB_RATIO = 1 }, main = {} } }
setmetatable(xi, { __index = function(t, k) local v = setmetatable({}, { __index = function() return 0 end }) rawset(t, k, v) return v end })
xi.mobMod = { TRUST_DISTANCE = 77 }
xi.trust = { movementType = { NO_MOVE = -1, NON_COMBAT = -2, MELEE = 0, MID_RANGE = 6, LONG_RANGE = 12 } }
xi.magic = { spellFamily = registry(1, { NONE = 0 }), spell = registry(1, nil, { NOT_A_SPELL = true }) }
rawset(xi, 'jobAbility', nil)
dofile(JA_ENUM)
SquadOwnerMerit = function() return 0 end
xi.effect = registry(1)
xi.effectFlag = { ERASABLE = 1 }
xi.ecosystem = { UNDEAD = 19, VERMIN = 20, DRAGON = 10 }
local OVERRIDES = {}
Module = { new = function() return { addOverride = function(_, name, fn) OVERRIDES[name] = fn end } end }
SUPER_CALLS = 0
super = function() SUPER_CALLS = SUPER_CALLS + 1 end
package.preload['modules/module_utils'] = function() return true end
local DATA = nil
package.preload['modules/custom/lua/squad_rulesets_data'] = function()
    if DATA == nil then error("module 'modules/custom/lua/squad_rulesets_data' not found") end
    return DATA
end
local function preload(folder)
    for _, m in ipairs({ 'squad_starter_gear', 'squad_rulesets', 'squad_ability_rules', 'squad_ja_jobs_data', 'squad_jobs' }) do
        package.loaded['modules/custom/lua/' .. m] = nil
        package.preload['modules/custom/lua/' .. m] = function()
            local f = io.open(folder .. '/' .. m .. '.lua', 'rb')
            local path = f and (folder .. '/' .. m .. '.lua') or (LUA .. '/' .. m .. '.lua')
            if f then f:close() end
            return dofile(path)
        end
    end
end

local W = { squad = {}, saved = {} }
GetSquad = function() return W.squad end
GetSquadUnlocks = function() return {} end
UnlockSquadItem, SetSquadEquip = function() end, function() end
GetSquadItemInfo = function() return { valid = false } end
BuildStarterGear = function() return {} end
SaveSquadMate = function(charId, slot, mate) W.saved[#W.saved + 1] = { slot = slot, mjob = mate.mjob } return 1 end

local function load(folder)
    preload(folder)
    __SQUAD_TEST = {}
    assert(loadfile(folder .. '/squad.lua'))()
    local hooks = __SQUAD_TEST.hooks
    assert(hooks and hooks.squadSpawn and hooks.commandObj, folder .. ' without test hooks')
    hooks.RS = require('modules/custom/lua/squad_rulesets')
    return hooks
end
local HB = BASE and load(BASE) or nil
local OVERRIDES_BASE = OVERRIDES
OVERRIDES = {}
local H = load(LUA)
local RS = H.RS
check(type(RS.liveStatus) == 'function' and type(RS.markLive) == 'function' and type(RS.panelLine) == 'function',
      'squad_rulesets.lua has markLive, liveStatus and panelLine')
check(not HB or HB.RS ~= RS, 'baseline and new squad_rulesets.lua are separate loads')

-- ---------------------------------------------------------------- stand-ins for the player and a squad mate
local WAR, WHM, BLM, RDM, SCH = 1, 3, 4, 5, 20
local nextEntityId = 100
local function entity(kind, opts)
    nextEntityId = nextEntityId + 1
    local e = { kind = kind, vars = {}, level = opts.level or 1, id = opts.id or nextEntityId, printed = {}, mobMods = {}, gambits = {}, job = opts.job or 1 }
    function e:getObjType() return self.kind end
    function e:getLocalVar(k) return self.vars[k] or 0 end
    function e:setLocalVar(k, v) self.vars[k] = v end
    function e:getMainLvl() return self.level end
    function e:getMainJob() return self.job end
    function e:getSubJob() return opts.sub or 0 end
    function e:getSubLvl() return opts.subLevel or 0 end
    function e:getID() return self.id end
    function e:getName() return opts.name or 'Testcharone' end
    function e:getPacketName() return opts.name or 'Testcharone' end
    function e:getMaster() return self.master end
    function e:printToPlayer(text) self.printed[#self.printed + 1] = text end
    function e:getMobMod(id) return self.mobMods[id] or 0 end
    function e:setMobMod(id, v) self.mobMods[id] = v end
    function e:isAlive() return true end
    function e:addGambit(target, condition, action, retry)
        self.gambits[#self.gambits + 1] = { target = target, condition = condition, action = action, retry = retry }
    end
    return setmetatable(e, { __index = function() return function() return 0 end end })
end
local function newPlayer()
    local p = entity(xi.objType.PC, { level = 75, id = 4 })
    p.party = {}
    function p:getCharVar(k) return self.vars[k] or 0 end
    function p:setCharVar(k, v) self.vars[k] = v end
    function p:getPartyWithTrusts() return self.party end
    function p:getParty() return {} end
    function p:getZoneID() return 116 end
    function p:getGMLevel() return 0 end
    function p:hasJob() return true end
    return p
end
local ROLE_CODE = { auto = 0, tank = 1, damage = 2, healer = 3, support = 4 }
local MODE_CODE = { balanced = 0, aggressive = 1, conserve = 2 }
local MATE_ID = 7
-- calls the mate (squadSpawn, as the trust's onMobSpawn does) and puts it in the party
local function call(hooks, p, job, level, role, mode, sub, subLevel)
    if role then p.vars['SQUAD_AI_' .. MATE_ID] = ROLE_CODE[role] * 10 + MODE_CODE[mode or 'balanced'] end
    local t = entity(xi.objType.TRUST, { level = level or 30, job = job, sub = sub, subLevel = subLevel, name = 'Aldric' })
    t.master = p
    t:setLocalVar('SQUAD_ID', MATE_ID)
    local handled = hooks.squadSpawn(t)
    p.party = { t }
    return t, handled
end
local function dismiss(p) p.party = {} end
local function serialize(v)
    if type(v) ~= 'table' then return tostring(v) end
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = serialize(v[i]) end
    return '{' .. table.concat(parts, ',') .. '}'
end
local function list(t)
    local out = {}
    for _, g in ipairs(t.gambits) do out[#out + 1] = string.format('%s|%s|%s|%s', tostring(g.target), serialize(g.condition), serialize(g.action), tostring(g.retry)) end
    return table.concat(out, '\n')
end
local function vars(t, prefix)
    local out = {}
    for k, v in pairs(t.vars) do
        local keep = prefix and k:sub(1, #prefix) == prefix or (prefix == nil and k:sub(1, 9) ~= 'SQUAD_RS_')
        if keep then out[#out + 1] = k .. '=' .. tostring(v) end
    end
    table.sort(out)
    return table.concat(out, ',')
end

-- ---------------------------------------------------------------- Rule Sets
local function blmSet(num, id, name, rules)
    return { format = 'xifo-ruleset', version = 1, num = num, id = id, name = name, job = 'BLM', rules = rules or {
        { id = 'r1', on = true, target = 'TARGET', cond = { 'NOT_HAS_TOP_ENMITY' }, action = { 'nuke' } },
        { id = 'r2', on = true, target = 'TARGET', cond = { 'MB_AVAILABLE' }, action = { 'burst' } } } }
end
local BASIC = blmSet(1, 'custom.blm.basic', 'Basic Black Mage')
local DEF = blmSet(2, 'custom.blm.defensive', 'Defensive Black Mage', {
    { id = 'r1', on = true, target = 'TARGET', cond = { 'NOT_HAS_TOP_ENMITY' }, cond2 = { 'MPP_GTE', 30 }, action = { 'nuke' } } })
local WHMSET = { format = 'xifo-ruleset', version = 1, num = 3, id = 'custom.whm.cure', name = 'WHM Cure', job = 'WHM',
                 rules = { { id = 'r1', on = true, target = 'PARTY', cond = { 'HPP_LT', 80 }, action = { 'family', 'CURE' } } } }
local function store(...) return { format = 'xifo-ruleset-store', version = 1, sets = { ... } } end
local function choose(p, job, set)
    p.vars['SQUAD_RS_' .. MATE_ID .. '_' .. job] = set and set.num or 0
    p.vars['SQUAD_RSH_' .. MATE_ID .. '_' .. job] = set and RS.idHash(set.id) or 0
end
local function squadOf(job) W.squad = { { id = MATE_ID, slot = 2, name = 'Aldric', mjob = job, sjob = 0, jobs = { [job] = { level = 30 } }, equip = {}, race = 1, face = 0 } } return W.squad[1] end
local function status(p, mate) return RS.liveStatus(p, mate, p.party[1]) end

-- ================================================================= 1. active custom Rule Set
section('1. an applied Rule Set: state "set", the installed set and the choice agree')
DATA = store(BASIC, DEF, WHMSET)
local p = newPlayer()
local mate = squadOf(BLM)
choose(p, BLM, BASIC)
local t = call(H, p, BLM, 30, 'damage')
check(#t.gambits == 2, 'the set\'s two rules are installed (' .. #t.gambits .. ')')
local s = status(p, mate)
check(s.state == 'set' and s.live == 1 and s.liveName == 'Basic Black Mage' and s.sel == 1 and s.selName == 'Basic Black Mage',
      'state set, live 1 "Basic Black Mage", selected 1: ' .. s.state .. ' ' .. s.live .. ' ' .. s.liveName)
check(t.vars.SQUAD_RS_MARK == 1 and t.vars.SQUAD_RS_LIVE == 1 and t.vars.SQUAD_RS_LIVEH == RS.idHash(BASIC.id)
      and t.vars.SQUAD_RS_JOB == BLM and t.vars.SQUAD_RS_FB == 0 and t.vars.SQUAD_RS_DROP == 0, 'the local vars on the mate: ' .. vars(t, 'SQUAD_RS'))
check(t.vars.SQUAD_RS_BEH == ROLE_CODE.damage * 10, 'the Role and Mode at the call are recorded')
local line = RS.panelLine(p, mate, t)
check(line == 'rs|2|set|-|1|Basic Black Mage|1|Basic Black Mage|0|0|BLM', 'the menu line: ' .. line)

-- ================================================================= 2. default job rules
section('2. no Rule Set chosen: state "job"')
local p2 = newPlayer()
local t2 = call(H, p2, BLM, 30, 'damage')
local s2 = status(p2, mate)
check(s2.state == 'job' and s2.live == 0 and s2.sel == 0 and s2.fb == 0, 'state job, nothing live, nothing chosen: ' .. s2.state)
check(#t2.gambits > 0 and t2.vars.SQUAD_RS_LIVE == 0 and t2.vars.SQUAD_RS_MARK == 1, 'job rules installed, mark written, live 0')
check(RS.panelLine(p2, mate, t2) == 'rs|2|job|-|0|-|0|-|0|0|BLM', 'the menu line: ' .. RS.panelLine(p2, mate, t2))

-- ================================================================= 3. selected but not applied
section('3. a Rule Set chosen after the call: "pending" (choice), never "set"')
choose(p2, BLM, BASIC)
local s3 = status(p2, mate)
check(s3.state == 'pending' and s3.why == 'choice' and s3.live == 0 and s3.sel == 1 and s3.selName == 'Basic Black Mage',
      'pending/choice, live 0, selected 1: ' .. s3.state .. '/' .. s3.why)
check(list(t2) == list(call(H, newPlayer(), BLM, 30, 'damage')), 'choosing does not touch the running mate\'s gambits')
local t3 = call(H, p2, BLM, 30)   -- Apply now: called again
check(status(p2, mate).state == 'set' and #t3.gambits == 2, 'after the call (Apply now): set')

-- ================================================================= 4. switching Rule Sets
section('4. switching from one set to another, editing, renumbering, turning off')
choose(p2, BLM, DEF)
local s4 = status(p2, mate)
check(s4.state == 'pending' and s4.why == 'choice' and s4.liveName == 'Basic Black Mage' and s4.selName == 'Defensive Black Mage',
      'B chosen while A runs: pending/choice, live A, selected B')
check(RS.panelLine(p2, mate, t3) == 'rs|2|pending|choice|1|Basic Black Mage|2|Defensive Black Mage|0|0|BLM', 'line: ' .. RS.panelLine(p2, mate, t3))
local t4 = call(H, p2, BLM, 30)
check(status(p2, mate).state == 'set' and status(p2, mate).liveName == 'Defensive Black Mage' and #t4.gambits == 1, 'after the call: B runs')
local DEF2 = blmSet(2, 'custom.blm.defensive', 'Defensive Black Mage', {
    { id = 'r1', on = true, target = 'TARGET', cond = { 'NOT_HAS_TOP_ENMITY' }, cond2 = { 'MPP_GTE', 50 }, action = { 'nuke' } } })
DATA = store(BASIC, DEF2, WHMSET)
check(status(p2, mate).state == 'pending' and status(p2, mate).why == 'edited', 'the running set saved with a change: pending/edited')
DATA = store(BASIC, blmSet(2, 'custom.blm.defensive', 'Defensive Black Mage (renamed)', DEF.rules), WHMSET)
check(status(p2, mate).state == 'set' and status(p2, mate).liveName == 'Defensive Black Mage (renamed)', 'only renamed: still set, the new name')
DATA = store(BASIC, WHMSET, blmSet(9, 'custom.blm.defensive', 'Defensive Black Mage', DEF.rules))
local s4r = status(p2, mate)
check(s4r.state == 'set' and s4r.sel == 9, 'the set got a new number (same id): still set, followed by its id (sel ' .. s4r.sel .. ')')
DATA = store(BASIC, DEF, WHMSET)
choose(p2, BLM, nil)
check(status(p2, mate).state == 'pending' and status(p2, mate).why == 'choice' and status(p2, mate).sel == 0, 'Use job rules (off) while B runs: pending/choice')
local t4b = call(H, p2, BLM, 30)
check(status(p2, mate).state == 'job' and #t4b.gambits > 2, 'after the call: job rules')

-- ================================================================= 5. job changes
section('5. a main job change (!squad job) applies at the next call')
local p5 = newPlayer()
choose(p5, BLM, BASIC)
local t5 = call(H, p5, BLM, 30)
mate = squadOf(WHM)                           -- !squad job: the saved main job is WHM, the called mate is still BLM
local s5 = status(p5, mate)
check(s5.state == 'pending' and s5.why == 'job' and s5.live == 1 and s5.sel == 0, 'job changed to WHM: pending/job, the BLM set still live, nothing chosen for WHM')
check(has(RS.panelLine(p5, mate, t5), '|BLM'), 'the line names the job at the call (BLM)')
choose(p5, WHM, WHMSET)
call(H, p5, WHM, 30)
check(status(p5, mate).state == 'set' and status(p5, mate).liveName == 'WHM Cure', 'called as WHM with a WHM set: set "WHM Cure"')
mate = squadOf(BLM)
check(status(p5, mate).state == 'pending' and status(p5, mate).sel == 1, 'back to BLM (not called yet): pending, the BLM choice (1) comes back')
call(H, p5, BLM, 30)
check(status(p5, mate).state == 'set' and status(p5, mate).live == 1, 'called: the BLM set again')

-- ================================================================= 6. summoning and dismissal
section('6. not called, dismissed, and a mate called without a report')
dismiss(p5)
local s6 = status(p5, mate)
check(s6.state == 'off' and s6.live == 0 and s6.sel == 1 and s6.selName == 'Basic Black Mage', 'dismissed: off, the choice still shown')
check(RS.panelLine(p5, mate, nil) == 'rs|2|off|-|0|-|1|Basic Black Mage|0|0|-', 'line: ' .. RS.panelLine(p5, mate, nil))
local bare = entity(xi.objType.TRUST, { level = 30, job = BLM })
bare.master = p5; bare:setLocalVar('SQUAD_ID', MATE_ID)
check(RS.liveStatus(p5, mate, bare).state == 'unknown', 'a called mate with nothing recorded (an older call path): unknown, never set')
bare:setLocalVar('ADDON_OWNED', 1)
check(RS.liveStatus(p5, mate, bare).state == 'addon', 'a mate an add-on owns: addon')
local t6 = call(H, p5, BLM, 30)
check(status(p5, mate).state == 'set', 'called again: set')
local fresh = entity(xi.objType.TRUST, { level = 30, job = BLM })
check(fresh.vars.SQUAD_RS_MARK == nil, 'a new entity (zoning, a new call) starts with no status: nothing is carried over')

-- ================================================================= 7. Role and Mode changes
section('7. Role / Mode changes')
local before = list(t6)
for role in pairs(ROLE_CODE) do
    for mode in pairs(MODE_CODE) do
        p5.vars['SQUAD_AI_' .. MATE_ID] = ROLE_CODE[role] * 10 + MODE_CODE[mode]
        local st = status(p5, mate)
        check(st.state == 'set' and st.why == '-', 'set running, Role ' .. role .. ' / ' .. mode .. ': still set (' .. st.state .. ')')
    end
end
check(list(t6) == before, 'the running mate\'s gambits are untouched by the Role changes')
local tr = call(H, p5, BLM, 30, 'healer', 'conserve')
check(list(tr) == before, 'called again under Healer / Conserve: exactly the same set gambits')
local p7 = newPlayer()
local t7 = call(H, p7, WHM, 30, 'auto')
local m7 = squadOf(WHM)
check(status(p7, m7).state == 'job', 'job rules under Auto: job')
p7.vars['SQUAD_AI_' .. MATE_ID] = ROLE_CODE.damage * 10
check(status(p7, m7).state == 'pending' and status(p7, m7).why == 'role', 'job rules, Role changed to Damage: pending/role (applies at the next call)')
call(H, p7, WHM, 30)
check(status(p7, m7).state == 'job', 'called again: job')
mate = squadOf(BLM)

-- ================================================================= 8. fallback
section('8. a chosen set that cannot be used: fallback, never set')
local p8 = newPlayer()
choose(p8, BLM, BASIC)
DATA = store(DEF, WHMSET)                     -- the set was deleted
LOG = {}
local t8 = call(H, p8, BLM, 30)
local s8 = status(p8, mate)
check(s8.state == 'fallback' and s8.fb == RS.LIVE_FB.GONE and s8.live == 0 and s8.selName == '?', 'set gone: fallback (gone), job rules: ' .. s8.state .. ' fb ' .. s8.fb)
check(#t8.gambits > 2 and has(table.concat(p8.printed, '\n'), 'so it uses its job rules'), 'job rules installed and the existing message told the player')
local logged = #LOG
for _ = 1, 5 do RS.panelLine(p8, mate, t8) end
check(#LOG == logged, 'asking the status says nothing in the server log (quiet resolve)')
DATA = store(BASIC, DEF, WHMSET)              -- the set is back
check(status(p8, mate).state == 'pending' and status(p8, mate).why == 'choice', 'the set is usable again: pending (Apply now), not set')
DATA = store(blmSet(1, 'custom.blm.other', 'Another set'), DEF, WHMSET)
local t8b = call(H, p8, BLM, 30)
check(status(p8, mate).state == 'fallback' and status(p8, mate).fb == RS.LIVE_FB.REPLACED, 'the number now names another set: fallback (replaced)')
DATA = store(blmSet(1, 'custom.blm.basic', 'Basic Black Mage', { { id = 'r1', on = true, target = 'TARGET', cond = { 'ALWAYS' }, action = { 'nuke' }, level = 75 } }), DEF, WHMSET)
local t8c = call(H, p8, BLM, 30)
local s8c = status(p8, mate)
check(s8c.state == 'fallback' and s8c.fb == RS.LIVE_FB.UNUSABLE and s8c.dropped == 1, 'no rule usable at level 30: fallback (unusable), 1 left out')
DATA = store(blmSet(1, 'custom.blm.basic', 'Basic Black Mage', { BASIC.rules[1], { id = 'r9', on = true, target = 'TARGET', cond = { 'ALWAYS' }, action = { 'nuke' }, level = 75 } }), DEF, WHMSET)
local t8d = call(H, p8, BLM, 30)
local s8d = status(p8, mate)
check(s8d.state == 'set' and s8d.dropped == 1 and #t8d.gambits == 1, 'one of two rules usable: set, 1 rule left out')
check(has(RS.panelLine(p8, mate, t8d), '|0|1|BLM'), 'the line carries the rules left out')
DATA = store(BASIC, DEF, WHMSET)
-- a job Squads has no rules for: the template override marks it (the trust's own rules run)
local p8s = newPlayer()
local sch = entity(xi.objType.TRUST, { level = 30, job = SCH, name = 'Aldric' })
sch.master = p8s; sch:setLocalVar('SQUAD_ID', MATE_ID)
local spawnOverride = nil
for name, fn in pairs(OVERRIDES) do if name:match('%.onMobSpawn$') then spawnOverride = fn break end end
check(spawnOverride ~= nil, 'the template onMobSpawn override is registered')
local superBefore = SUPER_CALLS
spawnOverride(sch)
check(SUPER_CALLS == superBefore + 1 and sch.vars.SQUAD_RS_MARK == 1 and sch.vars.SQUAD_RS_FB == RS.LIVE_FB.NOJOB, 'SCH: the template rules run (super), marked "no job rules"')
p8s.party = { sch }
local sSch = RS.liveStatus(p8s, { id = MATE_ID, slot = 2, mjob = SCH }, sch)
check(sSch.state == 'fallback' and sSch.fb == RS.LIVE_FB.NOJOB, 'SCH status: fallback (no job rules): ' .. sSch.state)
local normal = entity(xi.objType.TRUST, { level = 30, job = BLM })
spawnOverride(normal)
check(normal.vars.SQUAD_RS_MARK == nil, 'a normal trust (no SQUAD_ID) is not marked')

-- ================================================================= 9. missing, stale or odd data
section('9. missing or odd data never gives "set"')
check(RS.liveStatus(p8, mate, nil).state == 'off', 'no mate: off')
local fake = entity(xi.objType.TRUST, { level = 30, job = BLM })
fake.vars = { SQUAD_RS_LIVE = 1, SQUAD_RS_LIVEH = RS.idHash(BASIC.id) }   -- live vars without the mark
check(RS.liveStatus(p8, mate, fake).state == 'unknown', 'live numbers without the mark: unknown')
local weird = blmSet(4, 'custom.blm.weird', 'A|B{c}%d' .. string.rep('x', 60))
DATA = store(weird)
local pw = newPlayer()
choose(pw, BLM, weird)
local tw = call(H, pw, BLM, 30)
local lw = RS.panelLine(pw, mate, tw)
check(not lw:find('[{}%%]') and select(2, lw:gsub('|', '')) == 10, 'name with | { } %: cleaned, still 11 fields: ' .. lw)
check(#lw < 200, 'one chat line (' .. #lw .. ' bytes)')
-- the panel command: the rs line after the mate line, nothing else changed
DATA = store(BASIC, DEF, WHMSET)
W.squad = { { id = MATE_ID, slot = 2, name = 'Aldric', mjob = BLM, sjob = 0, jobs = { [BLM] = { level = 30 } }, equip = {}, race = 1, face = 0 } }
local pp = newPlayer()
choose(pp, BLM, BASIC)
call(H, pp, BLM, 30)
local ok, err = pcall(H.commandObj.onTrigger, pp, 'panel')
check(ok, 'the panel command runs: ' .. tostring(err))
local said = table.concat(pp.printed, '\n')
check(has(said, 'squadpanel:2|Aldric|BLM|30|') and has(said, 'squadpanel:rs|2|set|-|1|Basic Black Mage|1|Basic Black Mage|0|0|BLM')
      and has(said, 'squadpanel:end'), 'the panel answer has the mate line, the rs line and end')
local mateAt, rsAt, endAt = said:find('squadpanel:2|', 1, true), said:find('squadpanel:rs|2|', 1, true), said:find('squadpanel:end', 1, true)
check(mateAt and rsAt and endAt and mateAt < rsAt and rsAt < endAt, 'order: mate line, rs line, end')
if HB then
    local pb = newPlayer()
    choose(pb, BLM, BASIC)
    call(HB, pb, BLM, 30)
    pcall(HB.commandObj.onTrigger, pb, 'panel')
    local a = {}
    for _, l in ipairs(pp.printed) do if not l:find('squadpanel:rs|', 1, true) then a[#a + 1] = l end end
    check(table.concat(a, '\n') == table.concat(pb.printed, '\n'), 'without the rs line the panel answer is byte-identical to the baseline')
end
-- without squad_rulesets.lua: no rs line, the rest unchanged
local saved = package.preload['modules/custom/lua/squad_rulesets']
package.loaded['modules/custom/lua/squad_rulesets'] = nil
package.preload['modules/custom/lua/squad_rulesets'] = function() error('missing') end
local pm = newPlayer()
call(H, pm, BLM, 30)
pcall(H.commandObj.onTrigger, pm, 'panel')
local saidM = table.concat(pm.printed, '\n')
check(not has(saidM, 'squadpanel:rs|') and has(saidM, 'squadpanel:end'), 'no squad_rulesets.lua: no rs line, the answer still ends')
package.preload['modules/custom/lua/squad_rulesets'] = saved
package.loaded['modules/custom/lua/squad_rulesets'] = RS

-- ================================================================= 10. gameplay unchanged
section('10. the installed gambits are exactly those of the base commit')
if HB then
    local same, total = 0, 0
    local function compare(label, setup, job, level, sub, subLevel)
        for role in pairs(ROLE_CODE) do
            for mode in pairs(MODE_CODE) do
                total = total + 1
                local pa, pb = newPlayer(), newPlayer()
                setup(pa); setup(pb)
                local a = list((call(H, pa, job, level, role, mode, sub, subLevel)))
                local b = list((call(HB, pb, job, level, role, mode, sub, subLevel)))
                if a == b then same = same + 1 else io.write('  differs: ', label, ' ', role, ' ', mode, '\n') end
            end
        end
    end
    DATA = store(BASIC, DEF, WHMSET)
    compare('BLM set', function(pl) choose(pl, BLM, BASIC) end, BLM, 30)
    compare('WHM set', function(pl) choose(pl, WHM, WHMSET) end, WHM, 30, BLM, 15)
    compare('BLM job', function() end, BLM, 30)
    compare('WHM/BLM job', function() end, WHM, 30, BLM, 15)
    compare('RDM job', function() end, RDM, 40)
    compare('WAR/WHM job', function() end, WAR, 40, WHM, 20)
    DATA = store(DEF, WHMSET)
    compare('BLM gone set', function(pl) choose(pl, BLM, BASIC) end, BLM, 30)
    check(same == total, string.format('identical gambits in %d of %d cases (7 set-ups x 5 roles x 3 modes)', same, total))
    -- only SQUAD_RS_* local vars are new on the mate
    local pa, pb = newPlayer(), newPlayer()
    DATA = store(BASIC)
    choose(pa, BLM, BASIC); choose(pb, BLM, BASIC)
    local ta, tb = call(H, pa, BLM, 30), call(HB, pb, BLM, 30)
    check(vars(ta) == vars(tb), 'the other local vars of the mate are the same as before')
    check(vars(pa, nil) == vars(pb, nil) and #pa.printed == #pb.printed, 'no char var and no chat line added at a call')
else
    io.write('  (no baseline folder given: comparison skipped)\n')
end
DATA = nil

io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
