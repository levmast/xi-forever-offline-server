-- "!squad position <slot> normal | behind | ta" (2026-11-25): where a squad mate stands in a fight. Stored on the player
-- (SQUAD_POS_<mate id>), given to a mate that is out at once and to every mate when it is called (local var
-- SQUAD_POSITION, read by the trust controller, squad_position.h), reported to the menu (squadpanel:pos|<slot>|<n>), and
-- offered to it (cap matepos) only by a map server that places mates by it (SquadPositionEngine).
-- The real squad.lua runs with stand-ins for the engine; no server, no database. The placing itself is C++
-- (src/test/tests/squad_position_tests.cpp) and is seen only in game.
--   luajit test_squad_mate_position.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua
--                                       <server>/scripts/enum/job_ability.lua <server>/sql
--   Lua 5.4: lua -e "unpack = unpack or table.unpack" test_squad_mate_position.lua ...   (the server runs LuaJIT)
-- The stand-ins are those of test_squad_item_commands.lua: this file runs that file's set-up part and continues.
local here = (arg[0]:match('^(.*)[/\\][^/\\]*$') or '.')
local f = assert(io.open(here .. '/test_squad_item_commands.lua', 'rb'))
local base = f:read('*a'):gsub('\r\n', '\n')
f:close()
local cut = assert(base:find('\n%-%- =+ give\n'), 'test_squad_item_commands.lua: the first section was not found')
local prefix = base:sub(1, cut):gsub('__SQUAD_TEST = {}\n', "rawset(xi, 'squad', {})\n__SQUAD_TEST = {}\n", 1)

local body = [==[
do
local function trust(id, name)
    local vars = { SQUAD_ID = id }
    local t = { name = name, vars = vars }
    function t:getObjType() return xi.objType.TRUST end
    function t:getLocalVar(k) return vars[k] or 0 end
    function t:setLocalVar(k, v) vars[k] = v end
    function t:isAlive() return true end
    function t:getPacketName() return name end
    return setmetatable(t, { __index = function() return function() return 0 end end })
end
local function world(out)
    local p = reset({})
    W.squad = {
        { id = 7, slot = 1, name = 'Mira', mjob = WAR, sjob = 0, jobs = { [WAR] = { level = 75, exp = 0 } }, equip = {}, race = 1, face = 0 },
        { id = 8, slot = 2, name = 'Bran', mjob = WAR, sjob = 0, jobs = { [WAR] = { level = 75, exp = 0 } }, equip = {}, race = 1, face = 0 },
        { id = 9, slot = 3, name = 'Cato', mjob = WAR, sjob = 0, jobs = { [WAR] = { level = 75, exp = 0 } }, equip = {}, race = 1, face = 0 },
    }
    p.party = {}
    for _, slot in ipairs(out or {}) do p.party[#p.party + 1] = trust(W.squad[slot].id, W.squad[slot].name) end
    function p:getPartyWithTrusts() return self.party end
    return p
end
local function outMate(p, id) for _, t in ipairs(p.party) do if t:getLocalVar('SQUAD_ID') == id then return t end end end

SquadPositionEngine = function() return 1 end

section('!squad position: stored, applied at once to a mate that is out')
local p = world({ 2 })
local said = run(p, 'position', '2')
check(has(said, 'Bran: position normal') and has(said, '!squad position <slot> normal | behind | ta'), 'no choice: what it is now, and the usage: ' .. said)
said = run(p, 'position', '2', 'behind')
check(p:getCharVar('SQUAD_POS_8') == 1, 'behind: SQUAD_POS_8 = 1')
check(outMate(p, 8):getLocalVar('SQUAD_POSITION') == 1, 'Bran is out: its SQUAD_POSITION is 1 at once (no call needed)')
check(has(said, 'Bran stands behind the monster in a fight') and not has(said, 'Dismiss') and not has(said, 'does not place'),
      'said: stands behind the monster (no "dismiss and call again", no engine note): ' .. said)
said = run(p, 'position', '2', 'ta')
check(p:getCharVar('SQUAD_POS_8') == 2 and outMate(p, 8):getLocalVar('SQUAD_POSITION') == 2 and has(said, 'Trick Attack partner'), 'ta: 2, and said so: ' .. said)
run(p, 'pos', '2', 'normal')
check(p:getCharVar('SQUAD_POS_8') == 0 and outMate(p, 8):getLocalVar('SQUAD_POSITION') == 0, '"pos" is the short form; normal: 0')
run(p, 'position', '2', 'BACK')
check(p:getCharVar('SQUAD_POS_8') == 1, '"back" (any case) is behind')
run(p, 'position', '2', 'partner')
check(p:getCharVar('SQUAD_POS_8') == 2, '"partner" is ta')
said = run(p, 'position', '2', 'sideways')
check(p:getCharVar('SQUAD_POS_8') == 2 and has(said, '!squad position <slot> normal | behind | ta'), 'an unknown word: nothing changed, the usage: ' .. said)
said = run(p, 'position', '3', 'behind')
check(p:getCharVar('SQUAD_POS_9') == 1 and has(said, 'Cato stands behind'), 'a mate that is away: stored, for its next call')
said = run(p, 'position', '8', 'behind')
check(p:getCharVar('SQUAD_POS_8') == 2 and not has(said, 'stands behind'), 'an unknown slot: nothing stored: ' .. said)

section('!squad position <slot> on its own says what a mate that is out does right now')
do
    local q = world({ 1 })
    run(q, 'position', '1', 'ta')
    local mira = outMate(q, 7)
    local engaged = true
    function mira:isEngaged() return engaged end
    local cases = {
        { 2, 0, 'on the Trick Attack partner spot' },
        { 1, 2, 'in the arc behind the monster (spot 2)' },
        { 3, 0, 'the monster is attacking it' },
        { 4, 0, 'not fighting the monster your party fights' },
        { 5, 0, 'out of a heal\'s reach' },
        { 6, 0, 'placed by its Thief abilities' },
    }
    for _, c in ipairs(cases) do
        mira:setLocalVar('SQUAD_POS_STATE', c[1]); mira:setLocalVar('SQUAD_POS_ARC', c[2])
        local s = run(q, 'position', '1')
        check(has(s, 'Mira: position ta') and has(s, 'Now: ') and has(s, c[3]), 'state ' .. c[1] .. ': ' .. s)
    end
    engaged = false
    local s = run(q, 'position', '1')
    check(has(s, 'not placed right now'), 'not in a fight: "not placed right now" (an old state is not reported): ' .. s)
    run(q, 'position', '1', 'normal')
    s = run(q, 'position', '1')
    check(not has(s, 'Now:'), 'Normal: no "Now" line')
    s = run(q, 'position', '2')
    check(has(s, 'Bran: position normal') and not has(s, 'Now:'), 'a mate that is away: no "Now" line')
end

section('the choice reaches a mate when it is called (squadSpawn), for any job')
do
    local mob = trust(9, 'Cato')
    function mob:getMaster() return p end
    function mob:getMainJob() return 20 end -- (a job Squads has no rules for: squadSpawn leaves early)
    H.squadSpawn(mob)
    check(mob:getLocalVar('SQUAD_POSITION') == 1, 'Cato called (no job rules): SQUAD_POSITION 1 from SQUAD_POS_9')
    local mira = trust(7, 'Mira')
    function mira:getMaster() return p end
    function mira:getMainJob() return 20 end
    H.squadSpawn(mira)
    check(mira:getLocalVar('SQUAD_POSITION') == 0, 'Mira (never set): 0, normal')
end

section('the menu: pos| per mate, and cap matepos only with the map server that places mates')
p = world({ 1 })
run(p, 'position', '1', 'ta')
run(p, 'position', '3', 'behind')
said = run(p, 'panel')
check(has(said, 'squadpanel:pos|1|2') and has(said, 'squadpanel:pos|2|0') and has(said, 'squadpanel:pos|3|1'), 'one pos| line per mate with its choice')
local optAt, posAt = said:find('squadpanel:opt|1|', 1, true), said:find('squadpanel:pos|1|', 1, true)
check(optAt and posAt and optAt < posAt, 'each pos| line comes after that mate\'s opt| line')
check(said:find('squadpanel:cap|[^\n]*matepos') ~= nil, 'cap says matepos')
local keepEngine = SquadPositionEngine
SquadPositionEngine = nil
said = run(p, 'panel')
check(not has(said, 'matepos') and has(said, 'squadpanel:cap|'), 'an older map server (no SquadPositionEngine): no matepos, the menu shows no Position row')
said = run(p, 'position', '1', 'behind')
check(p:getCharVar('SQUAD_POS_7') == 1 and has(said, 'does not place mates by it yet'), 'the command still stores it, and says the map server does not place mates yet')
SquadPositionEngine = keepEngine

section('a mate taken off the squad forgets its position (source)')
do
    local fh = assert(io.open(LUA .. '/squad.lua', 'rb'))
    local src = fh:read('*a')
    fh:close()
    local a = src:find("player:setCharVar('SQUAD_RANGE_' .. mate.id, 0)", 1, true)
    check(a ~= nil and src:find("player:setCharVar('SQUAD_POS_' .. mate.id, 0)", a, true) ~= nil and src:find("player:setCharVar('SQUAD_POS_' .. mate.id, 0)", a, true) - a < 200,
          'SQUAD_POS_<id> is reset with SQUAD_RANGE_<id> where a mate\'s settings are cleared')
end
end

io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
]==]

assert((loadstring or load)(prefix .. body, '=test_squad_mate_position'))()
