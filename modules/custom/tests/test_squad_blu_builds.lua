-- "!squad blu <slot> clear | save <name> | load <name> | delete <name> | builds" (2026-11-25), and set / unset building on
-- what is STORED (two changes before a re-call no longer undo each other). The real squad.lua runs with stand-ins for
-- the engine (a Blue Mage mate that is out, its known blue magic, slots and points); no server, no database.
-- What is NOT run here: trustutils.cpp setting the spells when the mate is called (it gets squad.lua's blueSet: the
-- list, {} for automatic, { 0 } for an empty set of your own).
--   luajit test_squad_blu_builds.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua
--                                    <server>/scripts/enum/job_ability.lua <server>/sql
--   Lua 5.4: lua -e "unpack = unpack or table.unpack" test_squad_blu_builds.lua ...   (the server runs LuaJIT)
-- The stand-ins are those of test_squad_item_commands.lua: this file runs that file's set-up part and continues.
local here = (arg[0]:match('^(.*)[/\\][^/\\]*$') or '.')
local f = assert(io.open(here .. '/test_squad_item_commands.lua', 'rb'))
local base = f:read('*a'):gsub('\r\n', '\n')
f:close()
local cut = assert(base:find('\n%-%- =+ give\n'), 'test_squad_item_commands.lua: the first section was not found')
local prefix = base:sub(1, cut):gsub('__SQUAD_TEST = {}\n', "rawset(xi, 'squad', {})\n__SQUAD_TEST = {}\n", 1)

local body = [==[
do
local S = xi.magic.spell
-- the Blue Mage's known blue magic (SquadKnownBlue): id, name, level, set points
local KNOWN = {
    { 'SHEEP_SONG', 'Sheep Song', 16, 2 }, { 'COCOON', 'Cocoon', 8, 1 }, { 'POLLEN', 'Pollen', 1, 1 },
    { 'HEAD_BUTT', 'Head Butt', 12, 3 }, { 'JET_STREAM', 'Jet Stream', 38, 4 }, { 'WILD_CARROT', 'Wild Carrot', 30, 3 },
}
local id = {}
for _, k in ipairs(KNOWN) do id[k[1]] = S[k[1]] end
local UNKNOWN = S.MAGIC_FRUIT -- (a spell this mate does not know)

local function blu(opts)
    local vars = { SQUAD_ID = 8, SQUAD_BLU_SLOTS = opts.slots or 8, SQUAD_BLU_POINTS = opts.points or 15,
                   SQUAD_BLU_AUTO = opts.auto == false and 0 or 1 }
    local set = opts.set or { id.POLLEN, id.COCOON }
    vars.SQUAD_BLU_COUNT = #set
    for i, s in ipairs(set) do vars['SQUAD_BLU_' .. i] = s end
    local t = { name = 'Bran', vars = vars }
    function t:getObjType() return xi.objType.TRUST end
    function t:getLocalVar(k) return vars[k] or 0 end
    function t:setLocalVar(k, v) vars[k] = v end
    function t:isAlive() return true end
    return setmetatable(t, { __index = function() return function() return 0 end end })
end
SquadKnownBlue = function(member)
    local out, isSet = {}, {}
    for n = 1, member:getLocalVar('SQUAD_BLU_COUNT') do isSet[member:getLocalVar('SQUAD_BLU_' .. n)] = true end
    for _, k in ipairs(KNOWN) do
        out[#out + 1] = { spell = id[k[1]], name = k[2], level = k[3], points = k[4], set = isSet[id[k[1]]] == true }
    end
    return out
end
local function world(opts)
    local p = reset({})
    W.squad = { { id = 8, slot = 2, name = 'Bran', mjob = 16, sjob = 0, jobs = { [16] = { level = 40, exp = 0 } }, equip = {}, race = 1, face = 0 } }
    p.mate = blu(opts or {})
    function p:getPartyWithTrusts() return { self.mate } end
    return p
end
local function own(p) return H and squadBlueSetGet(p, 8) end

section('names: encode / decode')
for _, n in ipairs({ 'a', 'tank', 'nuke2', 'abcde', 'abcdef', 'z9z9z9z9z9', 'ab', 'ab0' }) do
    local a, b = SQUAD_BLUX.encode(n)
    check(a ~= nil and SQUAD_BLUX.decode(a, b) == n and a < 2 ^ 31 and b < 2 ^ 31, 'round trip "' .. n .. '"')
end
local a1 = SQUAD_BLUX.encode('ab')
local a2 = SQUAD_BLUX.encode('ab0')
check(a1 ~= a2, '"ab" and "ab0" are different names')
for _, bad in ipairs({ '', 'with space', 'toolongname1', 'åäö', 'a-b', 'a_b' }) do
    check(SQUAD_BLUX.encode(bad) == nil, 'not a name: "' .. bad .. '"')
end
check(SQUAD_BLUX.encode('TANK') == SQUAD_BLUX.encode('tank'), 'names ignore case')

section('clear: your own set with nothing in it (not automatic)')
local p = world()
local said = run(p, 'blu', '2', 'clear')
check(p:getCharVar('SQUAD_BLUN_8') == SQUAD_BLU_EMPTY and #squadBlueSetGet(p, 8) == 0, 'clear stores the empty-set mark')
local spawn = squadBlueSetSpawn(p, 8)
check(#spawn == 1 and spawn[1] == 0, 'the engine gets { 0 } (a set of your own, nothing in it), not {} (automatic)')
check(has(said, 'set is empty now') and has(said, 'Dismiss and call'), 'said: ' .. said)
said = run(p, 'blu', '2', 'set', 'sheep', 'song')
local list = squadBlueSetGet(p, 8)
check(#list == 1 and list[1] == id.SHEEP_SONG, 'set after clear (the mate still shows its automatic set until called): only Sheep Song - not the automatic set plus it')
run(p, 'blu', '2', 'auto')
check(p:getCharVar('SQUAD_BLUN_8') == 0 and #squadBlueSetSpawn(p, 8) == 0, 'auto: 0 again, the engine gets {} (automatic)')

section('set / unset build on what is stored: two changes before a re-call keep both (regression)')
p = world() -- (automatic: Pollen and Cocoon set now)
run(p, 'blu', '2', 'unset', 'pollen')
run(p, 'blu', '2', 'unset', 'cocoon')
list = squadBlueSetGet(p, 8)
check(#list == 0 and p:getCharVar('SQUAD_BLUN_8') == SQUAD_BLU_EMPTY,
      'unset Pollen, then unset Cocoon before a re-call: both gone, an empty set of your own (before: the second started from the automatic set again, Pollen came back; and an empty set fell back to automatic)')
run(p, 'blu', '2', 'set', 'jet', 'stream')
run(p, 'blu', '2', 'set', 'head_butt')
list = squadBlueSetGet(p, 8)
check(#list == 2 and list[1] == id.JET_STREAM and list[2] == id.HEAD_BUTT, 'two sets in a row: both kept, in order')

section('save: the set as you made it, or what the automatic set holds now')
p = world()
said = run(p, 'blu', '2', 'save', 'starter')
local b = SQUAD_BLUX.find(p, 'starter')
check(b ~= nil and #b.ids == 2 and b.ids[1] == id.POLLEN and b.ids[2] == id.COCOON, 'from automatic: what is set now (Pollen, Cocoon)')
check(has(said, 'Saved build "starter" (2 spells)'), 'said: ' .. said)
run(p, 'blu', '2', 'clear')
run(p, 'blu', '2', 'set', 'sheep', 'song')
run(p, 'blu', '2', 'set', 'jet', 'stream')
run(p, 'blu', '2', 'save', 'Sleeper')
b = SQUAD_BLUX.find(p, 'sleeper')
check(b ~= nil and #b.ids == 2 and b.ids[1] == id.SHEEP_SONG and b.ids[2] == id.JET_STREAM, 'from your own set (made before a re-call): Sheep Song, Jet Stream; the name in lower case')
run(p, 'blu', '2', 'unset', 'jet', 'stream')
run(p, 'blu', '2', 'save', 'sleeper')
b = SQUAD_BLUX.find(p, 'sleeper')
check(#b.ids == 1 and #SQUAD_BLUX.list(p) == 2, 'the same name again replaces that build (still 2 builds)')
said = run(p, 'blu', '2', 'save', 'bad', 'name') -- (the game splits the line into words: "save bad name")
check(SQUAD_BLUX.find(p, 'bad') ~= nil, 'only one word is the name: "save bad name" saves "bad"')
run(p, 'blu', '2', 'delete', 'bad')
said = run(p, 'blu', '2', 'save', 'a-b')
check(has(said, 'a name of 1-10 letters or digits') and #SQUAD_BLUX.list(p) == 2, 'a name with other characters is refused: ' .. said)
run(p, 'blu', '2', 'clear')
said = run(p, 'blu', '2', 'save', 'nothing')
check(has(said, 'nothing set to save') and SQUAD_BLUX.find(p, 'nothing') == nil, 'an empty set is not saved: ' .. said)

section('load: fitted to the mate as it is now')
p = world({ slots = 3, points = 6 })
SQUAD_BLUX.save(p, 'big', { id.SHEEP_SONG, UNKNOWN, id.JET_STREAM, id.COCOON, id.POLLEN })
said = run(p, 'blu', '2', 'load', 'big')
list = squadBlueSetGet(p, 8)
-- Sheep Song 2 + Jet Stream 4 = 6 points: Cocoon (1) has no points left; Pollen no slot... (3 slots, 6 points)
check(#list == 2 and list[1] == id.SHEEP_SONG and list[2] == id.JET_STREAM, 'kept: Sheep Song, Jet Stream (6/6 points)')
check(has(said, 'Left out: Magic Fruit (not known), Cocoon (no room), Pollen (no room)'), 'left out, with why: ' .. said)
check(has(said, 'Bran loads "big": 2 spells, 2/3 slots, 6/6 points') and has(said, 'Dismiss and call'), 'said: ' .. said)
said = run(p, 'blu', '2', 'load', 'nope')
check(has(said, 'No build named "nope"') and #squadBlueSetGet(p, 8) == 2, 'an unknown build: nothing changed')

section('builds (and load with no name): the list; delete')
said = run(p, 'blu', '2', 'builds')
check(has(said, 'big (5): Sheep Song, Magic Fruit, Jet Stream, Cocoon, Pollen') and has(said, 'load <name> | save <name> | delete <name>'), 'the list: ' .. said)
check(run(p, 'blu', '2', 'load') == said, 'load with no name lists them too')
said = run(p, 'blu', '2', 'delete', 'big')
check(has(said, 'Deleted build "big"') and SQUAD_BLUX.find(p, 'big') == nil and p:getCharVar('SQUAD_BLUB_1_C') == 0, 'deleted, its place free')
said = run(p, 'blu', '2', 'builds')
check(has(said, 'No saved builds'), 'none left: ' .. said)
said = run(p, 'blu', '2', 'delete', 'big')
check(has(said, 'No build named "big"'), 'deleting it again: ' .. said)

section('at most 10 builds')
p = world()
for n = 1, 10 do check(SQUAD_BLUX.save(p, 'b' .. n, { id.POLLEN }) == true, 'build ' .. n) end
said = run(p, 'blu', '2', 'save', 'eleven')
check(has(said, 'You have 10 builds saved already') and SQUAD_BLUX.find(p, 'eleven') == nil, 'the 11th is refused: ' .. said)
run(p, 'blu', '2', 'delete', 'b4')
run(p, 'blu', '2', 'save', 'eleven')
check(SQUAD_BLUX.find(p, 'eleven') ~= nil and SQUAD_BLUX.find(p, 'eleven').n == 4, 'after a delete it takes the free place')

section('the mate has to be out, on Blue Mage')
p = world()
function p:getPartyWithTrusts() return {} end
said = run(p, 'blu', '2', 'save', 'x')
check(has(said, 'needs to be out, on Blue Mage') and SQUAD_BLUX.find(p, 'x') == nil, 'not out: ' .. said)
end

io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
]==]

assert((loadstring or load)(prefix .. body, '=test_squad_blu_builds'))()
