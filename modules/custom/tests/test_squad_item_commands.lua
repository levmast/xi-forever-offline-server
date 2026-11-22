-- !squad give / equip / lockstyle end to end through squad.lua's own command (its test hooks), with the item functions
-- from the repository's SQL seed files (squad_item_names_fixture.lua). No server, no database; nothing is written.
--   luajit test_squad_item_commands.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua
--                                       <server>/scripts/enum/job_ability.lua <server>/sql
--   Lua 5.4: lua -e "unpack = unpack or table.unpack" test_squad_item_commands.lua ...   (the server runs LuaJIT)
local LUA, GAMBITS, JA_ENUM, SQL = arg[1], arg[2], arg[3], arg[4]
assert(LUA and GAMBITS and JA_ENUM and SQL, 'usage: test_squad_item_commands.lua <lua folder> gambits.lua job_ability.lua <sql>')
local here = (arg[0]:match('^(.*)[/\\][^/\\]*$') or '.')
local F = dofile(here .. '/squad_item_names_fixture.lua').load(SQL)

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

local LOG = {}
print = function(...) local p = {} for i = 1, select('#', ...) do p[#p + 1] = tostring((select(i, ...))) end LOG[#LOG + 1] = table.concat(p, '\t') end

-- ---------------------------------------------------------------- the server bits squad.lua needs at load
dofile(GAMBITS)
local function registry(first)
    local nextId = first
    return setmetatable({}, { __index = function(self, name)
        if type(name) ~= 'string' then return nil end
        local id = nextId; nextId = nextId + 1; rawset(self, name, id); return id
    end })
end
xi = { module = { registerCommand = function() end }, objType = { PC = 1, TRUST = 2, MOB = 3 },
       animation = { NONE = 0, ATTACK = 1, HEALING = 33 }, settings = { map = { EXP_RATE = 1, SUBJOB_RATIO = 1 } } }
setmetatable(xi, { __index = function(t, k) local v = setmetatable({}, { __index = function() return 0 end }) rawset(t, k, v) return v end })
xi.mobMod = { TRUST_DISTANCE = 77 }
xi.trust = { movementType = { NO_MOVE = -1, NON_COMBAT = -2, MELEE = 0, MID_RANGE = 6, LONG_RANGE = 12 } }
xi.magic = { spellFamily = registry(1), spell = registry(1) }
rawset(xi, 'jobAbility', nil)
dofile(JA_ENUM)
xi.effect = registry(1)
xi.effectFlag = { ERASABLE = 1 }
Module = { new = function() return { addOverride = function() end } end }
package.preload['modules/module_utils'] = function() return true end
for _, m in ipairs({ 'squad_starter_gear', 'squad_rulesets', 'squad_ability_rules', 'squad_ja_jobs_data', 'squad_item_names' }) do
    package.preload['modules/custom/lua/' .. m] = function() return dofile(LUA .. '/' .. m .. '.lua') end
end

local W = { squad = {}, unlocks = {}, equip = {}, unlockCalls = {} }
GetSquad = function() return W.squad end
GetSquadUnlocks = function() return W.unlocks end
UnlockSquadItem = function(charId, itemId) W.unlockCalls[#W.unlockCalls + 1] = itemId; W.unlocks[itemId] = true end
SetSquadEquip = function(mateId, job, slot, itemId) W.equip[#W.equip + 1] = { mate = mateId, job = job, slot = slot, item = itemId } end
BuildStarterGear = function() return {} end
SaveSquadMate = function() return 1 end
FindSquadItem, GetItemIDByName, GetSquadItemInfo, GetReadOnlyItem = F.FindSquadItem, F.GetItemIDByName, F.GetSquadItemInfo, F.GetReadOnlyItem

__SQUAD_TEST = {}
assert(loadfile(LUA .. '/squad.lua'))()
local H = __SQUAD_TEST.hooks
assert(H and H.commandObj, 'squad.lua without test hooks')
local cmd = H.commandObj

-- ---------------------------------------------------------------- a player with bags, and one level 75 Warrior mate
local WAR = 1
local function newPlayer(bag)
    local p = { vars = {}, printed = {}, bag = {}, deleted = {} }
    for _, id in ipairs(bag or {}) do p.bag[id] = (p.bag[id] or 0) + 1 end
    function p:getID() return 4 end
    function p:getName() return 'Testcharone' end
    function p:getObjType() return xi.objType.PC end
    function p:getCharVar(k) return self.vars[k] or 0 end
    function p:setCharVar(k, v) self.vars[k] = v end
    function p:printToPlayer(text) self.printed[#self.printed + 1] = text end
    function p:getPartyWithTrusts() return {} end
    function p:getZoneID() return 116 end
    function p:getMainLvl() return 75 end
    function p:getGMLevel() return 0 end
    function p:hasItem(id) return (self.bag[id] or 0) > 0 end
    function p:delItem(id, n) self.bag[id] = (self.bag[id] or 0) - (n or 1); self.deleted[#self.deleted + 1] = id; return true end
    function p:getItems(container)
        local out = {}
        if container == 0 then
            for id, n in pairs(self.bag) do if n > 0 then out[#out + 1] = { getID = function() return id end } end end
        end
        return out
    end
    return setmetatable(p, { __index = function() return function() return 0 end end })
end
local function reset(bag, unlocks)
    W.squad = { { id = 7, slot = 1, name = 'Mira', mjob = WAR, sjob = 0, jobs = { [WAR] = { level = 75, exp = 0 } }, equip = {}, race = 1, face = 0 } }
    W.unlocks, W.equip, W.unlockCalls = {}, {}, {}
    for _, id in ipairs(unlocks or {}) do W.unlocks[id] = true end
    return newPlayer(bag)
end
local function run(p, ...)
    local first = #p.printed + 1
    local ok, err = pcall(cmd.onTrigger, p, ...)
    check(ok, 'command ran: ' .. tostring(err))
    return table.concat(p.printed, '\n', first)
end

-- ================================================================= give
section('!squad give')
local p = reset({ 17228 })
local said = run(p, 'give', 'Light', 'Crossbow', '+1')
check(W.unlockCalls[1] == 17228 and p.deleted[1] == 17228 and has(said, 'You give light_crossbow_+1 to your squad'), 'give Light Crossbow +1: ' .. said)
p = reset({ 17228 })
said = run(p, 'give', 'light_crossbow_+1')
check(W.unlockCalls[1] == 17228 and has(said, 'You give light_crossbow_+1'), 'give light_crossbow_+1 (one word, as before): ' .. said)
p = reset({ 17228 })
said = run(p, 'give', '17228')
check(W.unlockCalls[1] == 17228, 'give 17228 (an id, as before): ' .. said)
p = reset({ 12440 })
said = run(p, 'give', 'LEATHER_BANDANA')
check(W.unlockCalls[1] == 12440, 'give LEATHER_BANDANA: ' .. said)
p = reset({ 12440 })
said = run(p, 'give', 'Leather', 'Bandana')
check(W.unlockCalls[1] == 12440, 'give Leather Bandana: ' .. said)
p = reset({ 12542 })
said = run(p, 'give', 'Leather', 'Bandana', '+1')
check(W.unlockCalls[1] == 12542 and has(said, 'lth._bandana_+1'), 'give Leather Bandana +1 (full name, stored short): ' .. said)
p = reset({ 17175 })
said = run(p, 'give', 'Shortbow', '+1')
check(W.unlockCalls[1] == 17175, 'give Shortbow +1: ' .. said)
p = reset({ 17175 })
said = run(p, 'give', 'Short', 'Bow', '+1')
check(#W.unlockCalls == 0 and has(said, 'Item not found') and has(said, 'Shortbow, not Short Bow'), 'give Short Bow +1: not found, with the spelling hint: ' .. said)
p = reset({})
said = run(p, 'give', 'Light', 'Crossbow', '+1')
check(#W.unlockCalls == 0 and has(said, 'You do not have light_crossbow_+1 with you'), 'not carried: the old check still answers: ' .. said)
p = reset({ 17228 }, { 17228 })
said = run(p, 'give', 'Light', 'Crossbow', '+1')
check(#W.unlockCalls == 0 and has(said, 'already has'), 'already given: the old check still answers: ' .. said)
p = reset({ 19001 })
said = run(p, 'give', 'Gastraphetes')
check(W.unlockCalls[1] == 19001, 'an ambiguous name, one of them in your bags: that one: ' .. said)
p = reset({})
said = run(p, 'give', 'Gastraphetes')
check(#W.unlockCalls == 0 and has(said, 'More than one item is called "Gastraphetes"') and has(said, 'Use its id'), 'ambiguous, none yours: asks for the id: ' .. said)
p = reset({ 18981, 19001 })
said = run(p, 'give', 'Gastraphetes')
check(#W.unlockCalls == 0 and has(said, 'Yours: 18981, 19001'), 'ambiguous, two yours: asks for the id and lists them: ' .. said)
p = reset({ 12576 })
said = run(p, 'give', 'bronze_harness')
check(W.unlockCalls[1] == 12576, 'give bronze_harness (the help text example): ' .. said)

-- ================================================================= equip
section('!squad equip')
p = reset({}, { 12440, 12542, 17228 })
said = run(p, 'equip', '1', 'Leather', 'Bandana', 'head')
check(#W.equip == 1 and W.equip[1].item == 12440 and W.equip[1].slot == 4 and W.equip[1].job == WAR, 'equip 1 Leather Bandana head: ' .. said)
p = reset({}, { 12440 })
said = run(p, 'equip', '1', 'leather_bandana')
check(#W.equip == 1 and W.equip[1].item == 12440 and W.equip[1].slot == 4, 'equip 1 leather_bandana (no slot: the item\'s own): ' .. said)
p = reset({}, { 12542 })
said = run(p, 'equip', '1', 'Leather', 'Bandana', '+1', 'head')
check(#W.equip == 1 and W.equip[1].item == 12542, 'equip 1 Leather Bandana +1 head: ' .. said)
p = reset({}, { 17228 })
said = run(p, 'equip', '1', '17228', 'range')
check(#W.equip == 1 and W.equip[1].item == 17228 and W.equip[1].slot == 2, 'equip 1 17228 range (the Squad window\'s form): ' .. said)
p = reset({}, { 17228 })
said = run(p, 'equip', '1', 'Light', 'Crossbow', '+1')
check(#W.equip == 1 and W.equip[1].item == 17228 and W.equip[1].slot == 2, 'equip 1 Light Crossbow +1: ' .. said)
p = reset({}, { 12440 })
said = run(p, 'equip', '1', 'leather_bandana', 'hed')
check(#W.equip == 0 and has(said, 'does not fit that slot'), 'a mistyped equip slot: the old answer: ' .. said)
p = reset({}, { 12440 })
said = run(p, 'equip', '1', 'leather_bandana', 'body')
check(#W.equip == 0 and has(said, 'does not fit that slot'), 'a slot the item does not fit: the old answer: ' .. said)
p = reset({}, {})
said = run(p, 'equip', '1', 'Leather', 'Bandana')
check(#W.equip == 0 and has(said, 'has not been given to your squad yet. Use !squad give Leather Bandana first.'), 'not given yet: the hint repeats the name typed: ' .. said)
p = reset({}, { 19001 })
said = run(p, 'equip', '1', 'Gastraphetes')
check(#W.equip <= 1 and (#W.equip == 0 or W.equip[1].item == 19001), 'ambiguous: only the given one can be chosen: ' .. said)
check(not has(said, 'More than one item'), 'ambiguous, exactly one given to the squad: no question: ' .. said)
p = reset({}, {})
said = run(p, 'equip', '1', 'Short', 'Bow', '+1')
check(#W.equip == 0 and has(said, 'Item not found'), 'equip Short Bow +1: not found: ' .. said)

-- ================================================================= lockstyle
section('!squad lockstyle')
p = reset({}, { 12440 })
said = run(p, 'lockstyle', '1', 'Leather', 'Bandana', 'head')
check(p.vars['SQUAD_LS_7_4'] == 12440, 'lockstyle 1 Leather Bandana head: ' .. said)
p = reset({}, { 12542 })
said = run(p, 'lockstyle', '1', 'Leather', 'Bandana', '+1')
check(p.vars['SQUAD_LS_7_4'] == 12542, 'lockstyle 1 Leather Bandana +1 (no slot: the first look slot it fits): ' .. said)
p = reset({}, { 17228 })
said = run(p, 'lockstyle', '1', '17228', 'range')
check(p.vars['SQUAD_LS_7_2'] == 17228, 'lockstyle 1 17228 range (the Squad window\'s form): ' .. said)
p = reset({}, { 12440 })
said = run(p, 'lockstyle', '1', 'leather_bandana', 'hed')
check(p.vars['SQUAD_LS_7_4'] == 12440, 'a mistyped slot: the item\'s own look slot, as before: ' .. said)
p = reset({}, {})
said = run(p, 'lockstyle', '1', 'Short', 'Bow', '+1')
check(has(said, 'Item not found, or not something you can wear'), 'lockstyle Short Bow +1: ' .. said)
p = reset({}, { 12440 })
p.vars['SQUAD_LS_7_4'] = 12440
said = run(p, 'lockstyle', '1', 'off', 'head')
check(p.vars['SQUAD_LS_7_4'] == 0, 'lockstyle 1 off head (unchanged): ' .. said)

-- ================================================================= other commands are unaffected
section('other commands')
p = reset({}, {})
said = run(p, 'list')
check(has(said, 'Mira'), '!squad list: ' .. said)
said = run(p, 'unlocked')
check(has(said, 'Your squad has been given 0 item(s)'), '!squad unlocked: ' .. said)

io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
