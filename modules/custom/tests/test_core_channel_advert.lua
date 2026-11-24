-- The panel answer of the Squad command says squadpanel:chan|<version> only when this build handles the addon channel packet
-- (xi.addonChannel, set by the engine; packets/c2s/0x1f0_addon_channel.h), and says nothing otherwise, so the stock window keeps typing on a
-- build without the packet. Reuses the stand-ins of test_squad_role_clarity.lua. No server, no database.
--   luajit test_core_channel_advert.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua <server>/scripts/enum/job_ability.lua
local LUA, GAMBITS, JA_ENUM = arg[1], arg[2], arg[3]
assert(LUA and GAMBITS and JA_ENUM, 'usage: test_core_channel_advert.lua <lua folder> gambits.lua job_ability.lua')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
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

-- the stand-in xi invents a table for any name it is asked for; the real one has no xi.addonChannel unless the engine sets it
do
    local mt = getmetatable(xi)
    local invent = mt.__index
    mt.__index = function(t, k) if k == 'addonChannel' then return nil end return invent(t, k) end
end
local cmd = H.commandObj
local function panel()
    local p = newPlayer()
    local ok, err = pcall(cmd.onTrigger, p, 'panel')
    check(ok, 'the panel command ran: ' .. tostring(err))
    return table.concat(p.printed, '\n'), p.printed
end

section('a build without the packet says nothing')
rawset(xi, 'addonChannel', nil)
local text, lines = panel()
check(text:find('squadpanel:end', 1, true), 'the panel answer ends with squadpanel:end')
check(not text:find('squadpanel:chan', 1, true), 'no chan line')

section('a build with the packet says chan|1 before the end')
rawset(xi, 'addonChannel', { packet = 0x1F0, version = 1 })
text, lines = panel()
local chanAt, endAt
for i, l in ipairs(lines) do
    if l == 'squadpanel:chan|1' then chanAt = i end
    if l == 'squadpanel:end' then endAt = i end
end
check(chanAt ~= nil, 'squadpanel:chan|1 is there')
check(chanAt and endAt and chanAt < endAt and endAt == #lines, 'and comes before the closing squadpanel:end, which is still last')

section('a table that is not the engine\'s says nothing')
rawset(xi, 'addonChannel', 'yes')
text = panel()
check(not text:find('squadpanel:chan', 1, true), 'a string is not the channel table')

io.write(string.format('\ncore_channel_advert: %d passed, %d failed\n', passed, failed))
if rawget(_G, 'CORE_TEST_HARNESS') then return failed end
os.exit(failed == 0 and 0 or 1)
