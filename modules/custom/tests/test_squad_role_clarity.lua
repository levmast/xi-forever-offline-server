-- Squad Role clarity (2026-11-22): the Squad Role's filter on the default job rules is UNCHANGED, a Gambits Rule Set is
-- still not filtered, and the one new line after !squad job <slot> <job> (squad_jobs.lua J.roleKeptHint) appears only
-- when the main job really changes while a Role other than Auto is kept. No server, no database; nothing is written.
--   luajit test_squad_role_clarity.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua
--                                      <server>/scripts/enum/job_ability.lua [<baseline squad.lua>]
--   Lua 5.4: lua -e "unpack = unpack or table.unpack" test_squad_role_clarity.lua ...   (the server runs LuaJIT)
-- The optional baseline is the squad.lua this change started from (git show 0d6cad7e3f:modules/custom/lua/squad.lua):
-- with it, every job x role x mode below must give exactly the same gambits as before.
local LUA, GAMBITS, JA_ENUM, BASELINE = arg[1], arg[2], arg[3], arg[4]
assert(LUA and GAMBITS and JA_ENUM, 'usage: test_squad_role_clarity.lua <lua folder> gambits.lua job_ability.lua [baseline squad.lua]')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

local LOG = {}
print = function(...) local p = {} for i = 1, select('#', ...) do p[#p + 1] = tostring((select(i, ...))) end LOG[#LOG + 1] = table.concat(p, '\t') end

-- ---------------------------------------------------------------- the server bits squad.lua needs at load
dofile(GAMBITS)
local function registry(first, fixed, missing)
    local byId, nextId, t = {}, first, {}
    for name, id in pairs(fixed or {}) do t[name] = id; byId[id] = name end
    return setmetatable(t, { __index = function(self, name)
        if type(name) ~= 'string' or (missing and missing[name]) then return nil end
        local id = nextId
        nextId = nextId + 1
        rawset(self, name, id)
        byId[id] = name
        return id
    end }), byId
end
local spellIds, spellName = registry(1, nil, { NOT_A_SPELL = true })
local familyIds, familyName = registry(1, { NONE = 0 })
xi = { module = { registerCommand = function() end }, objType = { PC = 1, TRUST = 2, MOB = 3 },
       animation = { NONE = 0, ATTACK = 1, HEALING = 33 }, settings = { map = { EXP_RATE = 1, SUBJOB_RATIO = 1 } } }
setmetatable(xi, { __index = function(t, k) local v = setmetatable({}, { __index = function() return 0 end }) rawset(t, k, v) return v end })
xi.mobMod = { TRUST_DISTANCE = 77 }
xi.trust = { movementType = { NO_MOVE = -1, NON_COMBAT = -2, MELEE = 0, MID_RANGE = 6, LONG_RANGE = 12 } }
xi.magic = { spellFamily = familyIds, spell = spellIds }
rawset(xi, 'jobAbility', nil)
dofile(JA_ENUM)
local jaName = {}
for name, id in pairs(xi.ja or {}) do jaName[id] = name end
SquadOwnerMerit = function() return 0 end
xi.effect = registry(1)
xi.effectFlag = { ERASABLE = 1 }
xi.ecosystem = { UNDEAD = 19, VERMIN = 20, DRAGON = 10 }
Module = { new = function() return { addOverride = function() end } end }
package.preload['modules/module_utils'] = function() return true end
local DATA = nil
package.preload['modules/custom/lua/squad_rulesets_data'] = function()
    if DATA == nil then error("module 'modules/custom/lua/squad_rulesets_data' not found") end
    return DATA
end
for _, m in ipairs({ 'squad_starter_gear', 'squad_rulesets', 'squad_ability_rules', 'squad_ja_jobs_data', 'squad_jobs' }) do
    package.preload['modules/custom/lua/' .. m] = function() return dofile(LUA .. '/' .. m .. '.lua') end
end

local W = { squad = {}, saved = {} }
GetSquad = function() return W.squad end
GetSquadUnlocks = function() return {} end
UnlockSquadItem, SetSquadEquip = function() end, function() end
GetSquadItemInfo = function() return { valid = false } end
BuildStarterGear = function() return {} end
SaveSquadMate = function(charId, slot, mate) W.saved[#W.saved + 1] = { slot = slot, mjob = mate.mjob, sjob = mate.sjob } return 1 end

local function load(path)
    __SQUAD_TEST = {}
    assert(loadfile(path))()
    local hooks = __SQUAD_TEST.hooks
    assert(hooks and hooks.squadSpawn and hooks.commandObj, path .. ' without test hooks')
    return hooks
end
local HB = BASELINE and load(BASELINE) or nil
local H = load(LUA .. '/squad.lua')
local RS = require('modules/custom/lua/squad_rulesets')
local J = require('modules/custom/lua/squad_jobs')
local cmd = H.commandObj

-- ---------------------------------------------------------------- stand-ins for the player and a squad mate
local WAR, MNK, WHM, BLM, RDM, PLD, DRG = 1, 2, 3, 4, 5, 7, 14
local nextEntityId = 100
local function entity(kind, opts)
    nextEntityId = nextEntityId + 1
    local e = { kind = kind, vars = {}, level = opts.level or 1, id = opts.id or nextEntityId, printed = {}, mobMods = {}, gambits = {} }
    function e:getObjType() return self.kind end
    function e:getLocalVar(k) return self.vars[k] or 0 end
    function e:setLocalVar(k, v) self.vars[k] = v end
    function e:getMainLvl() return self.level end
    function e:getMainJob() return opts.job or 1 end
    function e:getSubJob() return opts.sub or 0 end
    function e:getSubLvl() return opts.subLevel or 0 end
    function e:getID() return self.id end
    function e:getName() return opts.name or 'Testcharone' end
    function e:getPacketName() return opts.name or 'Testcharone' end
    function e:getMaster() return self.master end
    function e:printToPlayer(text) self.printed[#self.printed + 1] = text end
    function e:getMobMod(id) return self.mobMods[id] or 0 end
    function e:setMobMod(id, v) self.mobMods[id] = v end
    function e:addGambit(target, condition, action, retry)
        self.gambits[#self.gambits + 1] = { target = target, condition = condition, action = action, retry = retry }
    end
    return setmetatable(e, { __index = function() return function() return 0 end end })
end
local function newPlayer()
    local p = entity(xi.objType.PC, { level = 75, id = 4 })
    function p:getCharVar(k) return self.vars[k] or 0 end
    function p:setCharVar(k, v) self.vars[k] = v end
    function p:getPartyWithTrusts() return {} end
    function p:getZoneID() return 116 end
    function p:getGMLevel() return 0 end
    function p:hasJob() return true end
    return p
end
local ROLE_CODE = { auto = 0, tank = 1, damage = 2, healer = 3, support = 4 }
local MODE_CODE = { balanced = 0, aggressive = 1, conserve = 2 }
local function spawn(hooks, p, job, level, sub, subLevel, role, mode)
    p.vars['SQUAD_AI_1'] = ROLE_CODE[role or 'auto'] * 10 + MODE_CODE[mode or 'balanced']
    local t = entity(xi.objType.TRUST, { level = level, job = job, sub = sub, subLevel = subLevel, name = 'Mira' })
    t.master = p
    t:setLocalVar('SQUAD_ID', 1)
    hooks.squadSpawn(t)
    return t
end
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
-- the name of a gambit's action: a family, a spell, a job ability, or nuke / burst / ranged
local function actionName(g)
    local a = g.action
    if a[1] == ai.r.JA then return jaName[a[3]] or ('ja' .. tostring(a[3])) end
    if a[1] == ai.r.RATTACK then return 'ranged' end
    if a[2] == ai.s.MB_ELEMENT then return 'burst' end
    if ai.s.BEST_AGAINST_TARGET ~= nil and a[2] == ai.s.BEST_AGAINST_TARGET then return 'nuke' end
    if a[2] == ai.s.HIGHEST then return familyName[a[3]] or 'family?' end
    return spellName[a[3]] or 'spell?'
end
local function names(t)
    local out = {}
    for _, g in ipairs(t.gambits) do out[actionName(g)] = (out[actionName(g)] or 0) + 1 end
    return out
end
-- every "HP below" number of the Cure gambits (family CURE or the spell CURE), sorted
local function hpLimits(c, out)
    if type(c[1]) == 'table' then hpLimits(c[1], out); hpLimits(c[2], out) return out end
    if c[1] == ai.c.HPP_LT then out[#out + 1] = c[2] end
    return out
end
local function cureLimits(t)
    local out = {}
    for _, g in ipairs(t.gambits) do
        if actionName(g) == 'CURE' then hpLimits(g.condition, out) end
    end
    table.sort(out)
    return table.concat(out, ',')
end
local function targetsOf(t, name)
    local out = {}
    for _, g in ipairs(t.gambits) do if actionName(g) == name then out[#out + 1] = g.target end end
    table.sort(out)
    return table.concat(out, ',')
end
local CLEANSE = { 'POISONA', 'PARALYNA', 'BLINDNA', 'SILENA', 'STONA', 'VIRUNA', 'CURSNA', 'ERASE' }
local function anyOf(n, keys) for _, k in ipairs(keys) do if n[k] then return true end end return false end

-- ================================================================= 1. the reported case: WHM 7 / BLM 3
section('WHM/BLM: Damage against Auto (the role filter is the one the texts describe)')
local p = newPlayer()
local auto = spawn(H, p, WHM, 7, BLM, 3, 'auto')
local na = names(auto)
check(cureLimits(auto) == '25,75', 'Auto: Cure below 25% and below 75%: ' .. cureLimits(auto))
check(anyOf(na, CLEANSE) and na.PROTECTRA and na.SHELLRA and na.BANISH and na.nuke, 'Auto: status removal, Protectra/Shellra, Banish and the /BLM nuke')
local dmg = spawn(H, p, WHM, 7, BLM, 3, 'damage')
local nd = names(dmg)
check(cureLimits(dmg) == '25,30', 'Damage: Cure only below 30% (25 stays, 75 -> 30): ' .. cureLimits(dmg))
check(not anyOf(nd, CLEANSE), 'Damage: no status removal (-na, Erase)')
check(not nd.PROTECTRA and not nd.SHELLRA, 'Damage: no Protectra / Shellra (party buffs; only buffs on itself stay)')
check(nd.PARALYZE and nd.SLOW and nd.FLASH and nd.DIA and nd.BANISH and nd.nuke and nd.burst, 'Damage: debuffs, Banish and the /BLM nuke and burst stay')
check(not dmg.printed[1] and not p.printed[1], 'a call says nothing about the Role (no U4 line at a spawn)')

section('WHM/BLM: Tank, Healer, Support and the modes')
local tank = spawn(H, p, WHM, 7, BLM, 3, 'tank')
local nt = names(tank)
check(cureLimits(tank) == '25,40', 'Tank: Cure only below 40%: ' .. cureLimits(tank))
check(not anyOf(nt, CLEANSE) and not nt.PROTECTRA and nt.FLASH and nt.PARALYZE and not nt.BANISH and not nt.nuke,
      'Tank: no status removal or party buffs, debuffs (Flash) stay, no nukes (Banish, /BLM)')
local heal = spawn(H, p, WHM, 7, BLM, 3, 'healer')
local nh = names(heal)
check(cureLimits(heal) == '25,75' and anyOf(nh, CLEANSE) and nh.PROTECTRA, 'Healer: normal cures, status removal, party buffs')
check(not nh.PARALYZE and not nh.FLASH and not nh.DIA and not nh.BANISH and not nh.nuke and not nh.burst, 'Healer: no debuffs (Flash, Dia, Paralyze), no nukes')
local sup = spawn(H, p, WHM, 7, BLM, 3, 'support')
local ns = names(sup)
check(cureLimits(sup) == '25,75' and anyOf(ns, CLEANSE) and ns.PROTECTRA and ns.PARALYZE and not ns.BANISH and not ns.nuke,
      'Support: normal cures, status removal, party buffs, debuffs; no nukes')
check(cureLimits(spawn(H, p, WHM, 7, BLM, 3, 'damage', 'aggressive')) == '40,45', 'Damage + Aggressive: below 45% (the text says 45%)')
check(cureLimits(spawn(H, p, WHM, 7, BLM, 3, 'damage', 'conserve')) == '15,15', 'Damage + Conserve: below 15% (the text says 15%)')
check(cureLimits(spawn(H, p, WHM, 7, BLM, 3, 'tank', 'aggressive')) == '40,55', 'Tank + Aggressive: below 55% (the text says 55%)')
check(cureLimits(spawn(H, p, WHM, 7, BLM, 3, 'tank', 'conserve')) == '15,25', 'Tank + Conserve: below 25% (the text says 25%)')
check(cureLimits(spawn(H, p, WHM, 7, BLM, 3, 'auto', 'aggressive')) == '40,90', 'Auto + Aggressive: at most 90% (75 + 15)')

-- ================================================================= 2. other jobs the UI note covers (or not)
section('RDM, PLD, WAR and a WHM sub job under Tank / Damage')
local rdmT, rdmD = spawn(H, p, RDM, 40, nil, nil, 'tank'), spawn(H, p, RDM, 40, nil, nil, 'damage')
check(cureLimits(rdmT) == '40' and cureLimits(rdmD) == '30', 'RDM: Cure below 50% becomes 40% (Tank) and 30% (Damage)')
check(targetsOf(rdmD, 'HASTE') == tostring(ai.t.SELF) and targetsOf(rdmD, 'REFRESH') == tostring(ai.t.SELF),
      'RDM Damage: Haste and Refresh only on itself (none on you): ' .. targetsOf(rdmD, 'HASTE'))
check(targetsOf(spawn(H, p, RDM, 40, nil, nil, 'auto'), 'HASTE') == table.concat({ math.min(ai.t.SELF, ai.t.MASTER), math.max(ai.t.SELF, ai.t.MASTER) }, ','),
      'RDM Auto: Haste on itself and on you')
local pldD, pldT = spawn(H, p, PLD, 40, nil, nil, 'damage'), spawn(H, p, PLD, 40, nil, nil, 'tank')
check(cureLimits(pldT) == '40' and names(pldT).SENTINEL and names(pldT).HOLY_CIRCLE, 'PLD Tank: Cure below 40%, Sentinel and Holy Circle stay')
check(cureLimits(pldD) == '30' and not names(pldD).SENTINEL and not names(pldD).HOLY_CIRCLE and names(pldD).FLASH,
      'PLD Damage: Cure below 30%, no Sentinel or Holy Circle, Flash stays')
local warD = spawn(H, p, WAR, 40, nil, nil, 'damage')
check(cureLimits(warD) == '' and not names(warD).PROVOKE and names(warD).BERSERK, 'WAR Damage: no cures to limit; no Provoke (a tank ability), Berserk stays')
local warWhm = spawn(H, p, WAR, 40, WHM, 20, 'damage')
check(cureLimits(warWhm) == '25,30' and not anyOf(names(warWhm), CLEANSE), 'WAR/WHM Damage: the WHM sub job\'s cures are limited too, no status removal')
check(cureLimits(spawn(H, p, MNK, 40, nil, nil, 'healer')) == '' and not names(spawn(H, p, MNK, 40, nil, nil, 'healer')).BOOST
      and names(spawn(H, p, MNK, 40, nil, nil, 'healer')).CHAKRA, 'MNK Healer: no job abilities except Chakra (the text says Convert and Chakra stay)')

-- ================================================================= 3. a Gambits Rule Set is not filtered
section('a Gambits Rule Set replaces the default rules and is not filtered by the Role')
local whmSet = { format = 'xifo-ruleset', version = 1, num = 1, id = 'custom.whm.role', name = 'WHM role', job = 'WHM',
                 rules = { { id = 'r1', on = true, target = 'PARTY', cond = { 'HPP_LT', 75 }, action = { 'family', 'CURE' } },
                           { id = 'r2', on = true, target = 'PARTY', cond = { 'STATUS', 'POISON' }, action = { 'spell', 'POISONA' } },
                           { id = 'r3', on = true, target = 'PARTY', cond = { 'NOT_STATUS', 'PROTECT' }, action = { 'family', 'PROTECTRA' } } } }
DATA = { format = 'xifo-ruleset-store', version = 1, sets = { whmSet } }
local ps = newPlayer()
ps.vars['SQUAD_RS_1_' .. WHM] = 1
ps.vars['SQUAD_RSH_1_' .. WHM] = RS.idHash('custom.whm.role')
for _, role in ipairs({ 'damage', 'tank', 'healer' }) do
    local withSet = spawn(H, ps, WHM, 7, BLM, 3, role)
    local n = names(withSet)
    check(#withSet.gambits == 3 and cureLimits(withSet) == '75' and n.POISONA and n.PROTECTRA,
          'Rule Set + Role ' .. role .. ': exactly the set\'s 3 rules, Cure at its own 75% (' .. #withSet.gambits .. ', ' .. cureLimits(withSet) .. ')')
end
ps.vars['SQUAD_RS_1_' .. WHM], ps.vars['SQUAD_RSH_1_' .. WHM] = nil, nil
check(cureLimits(spawn(H, ps, WHM, 7, BLM, 3, 'damage')) == '25,30', 'Restore default job rules: the Role filters the job rules again')
DATA = nil

-- ================================================================= 4. unchanged against the baseline squad.lua
section('every job x role x mode gives the same gambits as before this change')
if HB then
    local cases = { { WHM, 7, BLM, 3 }, { WHM, 40, nil, nil }, { RDM, 40, WHM, 20 }, { PLD, 40, WAR, 20 }, { WAR, 40, WHM, 20 },
                    { BLM, 40, nil, nil }, { DRG, 40, WHM, 20 }, { MNK, 40, nil, nil } }
    local same, total = 0, 0
    for _, c in ipairs(cases) do
        for role in pairs(ROLE_CODE) do
            for mode in pairs(MODE_CODE) do
                total = total + 1
                local a = list(spawn(H, newPlayer(), c[1], c[2], c[3], c[4], role, mode))
                local b = list(spawn(HB, newPlayer(), c[1], c[2], c[3], c[4], role, mode))
                -- (a BLM on Healer or Support keeps nothing at all, before and after: equal empty lists count as equal)
                if a == b then same = same + 1 else io.write('  differs: job ', c[1], ' ', role, ' ', mode, '\n') end
            end
        end
    end
    check(same == total, string.format('identical gambits in %d of %d cases (8 jobs x 5 roles x 3 modes)', same, total))
    check(H.behaviorFilter ~= HB.behaviorFilter, 'two separate loads were compared (not one file twice)')
else
    io.write('  (no baseline squad.lua given: comparison skipped)\n')
end

-- ================================================================= 5. U4: the line after !squad job
section('!squad job: one line when a kept Role meets a new main job')
local function reset(role, mode, mjob, sjob)
    W.squad = { { id = 7, slot = 1, name = 'Aldric', mjob = mjob or BLM, sjob = sjob or 0, jobs = {}, equip = {}, race = 1, face = 0 } }
    W.saved = {}
    local pl = newPlayer()
    pl.vars['SQUAD_AI_7'] = ROLE_CODE[role] * 10 + MODE_CODE[mode or 'balanced']
    return pl
end
local function run(pl, ...)
    local first = #pl.printed + 1
    local ok, err = pcall(cmd.onTrigger, pl, ...)
    check(ok, 'command ran: ' .. tostring(err))
    return table.concat(pl.printed, '\n', first)
end
local function count(text, needle)
    local n, at = 0, 1
    while true do
        local s, e = text:find(needle, at, true)
        if not s then return n end
        n, at = n + 1, e + 1
    end
end
local KEPT = 'retained (default rules only)'

local pd = reset('damage')
local said = run(pd, 'job', '1', 'WHM')
check(count(said, 'Squad: Aldric changed to WHM. Role Damage retained (default rules only).') == 1,
      'BLM -> WHM with Damage: the short line, once: ' .. said)
check(not has(said, 'remains assigned'), 'the old long wording is gone')
check(has(said, 'Saved: [1] Aldric  WHM'), 'and the job is saved as before')
check(pd.vars['SQUAD_AI_7'] == ROLE_CODE.damage * 10, 'the Role stays Damage (SQUAD_AI unchanged, nothing reset)')
check(W.saved[1] and W.saved[1].mjob == WHM, 'the saved main job is WHM')
check(#pd.printed == 2, 'two lines: the note and "Saved:" (' .. #pd.printed .. ')')

said = run(pd, 'job', '1', 'WHM')
check(not has(said, KEPT), 'the same job again: no line (no real change)')
said = run(pd, 'sub', '1', 'BLM')
check(not has(said, KEPT), 'a sub job change: no line')
said = run(pd, 'list')
check(not has(said, KEPT), '!squad list: no line')
said = run(pd, 'role', '1', 'damage')
check(not has(said, KEPT) and has(said, 'role damage'), '!squad role: its own reply only')
local mate = entity(xi.objType.TRUST, { level = 20, job = WHM, name = 'Aldric' })
mate.master = pd
mate:setLocalVar('SQUAD_ID', 7)
local before = #pd.printed
H.squadSpawn(mate); H.squadSpawn(mate)
check(#pd.printed == before and #mate.printed == 0, 'calling the mate (twice, as after a zone change): no line')

for _, case in ipairs({ { 'auto', 'balanced' }, { 'auto', 'aggressive' }, { 'auto', 'conserve' } }) do
    local pa = reset(case[1], case[2])
    said = run(pa, 'job', '1', 'WHM')
    check(not has(said, KEPT) and has(said, 'Saved:'), 'Auto (' .. case[2] .. '): no line, the job is saved')
end
for _, role in ipairs({ 'tank', 'healer', 'support' }) do
    local pr = reset(role, 'conserve', WAR)
    said = run(pr, 'job', '1', 'RDM')
    local word = role:sub(1, 1):upper() .. role:sub(2)
    check(count(said, 'Squad: Aldric changed to RDM. Role ' .. word .. ' retained (default rules only).') == 1
          and pr.vars['SQUAD_AI_7'] == ROLE_CODE[role] * 10 + MODE_CODE.conserve, 'Role ' .. role .. ': the line once, Role and Mode kept')
end
local pu = reset('damage')
said = run(pu, 'job', '1', 'NOTAJOB')
check(not has(said, KEPT) and has(said, 'Unknown job'), 'an unknown job: refused as before, no line')

section('J.roleKeptHint on its own')
check(J.roleKeptHint(nil, 'damage', 4, 3, 'WHM') == nil, 'no mate: nil')
check(J.roleKeptHint({ name = 'A', slot = 2 }, 'auto', 4, 3, 'WHM') == nil, 'Auto: nil')
check(J.roleKeptHint({ name = 'A', slot = 2 }, 'damage', 3, 3, 'WHM') == nil, 'same job: nil')
local line = J.roleKeptHint({ name = 'Aldric', slot = 2 }, 'damage', 4, 3, 'WHM') or ''
check(line == 'Squad: Aldric changed to WHM. Role Damage retained (default rules only).', 'the line: ' .. line)
check(not has(line, '{') and not has(line, '}') and not has(line, '%'), 'no braces (the squad print filter strips them), no %')
-- the longest it can be: a 15-letter name (validName allows 3-15 letters), a three-letter job, the longest role word
local longest = 0
for _, role in ipairs({ 'tank', 'damage', 'healer', 'support' }) do
    longest = math.max(longest, #(J.roleKeptHint({ name = 'Abcdefghijklmno', slot = 16 }, role, 4, 3, 'WHM') or ''))
end
check(longest == 82 and longest <= 100, 'the longest possible line is ' .. longest .. ' bytes (one chat line)')

io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
