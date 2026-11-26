-- "!squad reapply <slot>" (UI milestone, SV-1): one squad mate leaves and is called again; the others stay out. The
-- squad-wide "!squad reapply" is unchanged. The real squad.lua runs with stand-ins for the engine; no server, no
-- database, nothing is written. What is NOT run here: the spawn itself (callMate is followed only up to its first
-- check), so this is a test of the command's decisions, not of a mate appearing in the game.
--   luajit test_squad_reapply_slot.lua <server>/modules/custom/lua <server>/scripts/globals/gambits.lua
--                                      <server>/scripts/enum/job_ability.lua <server>/sql
--   Lua 5.4: lua -e "unpack = unpack or table.unpack" test_squad_reapply_slot.lua ...   (the server runs LuaJIT)
-- The stand-ins are those of test_squad_item_commands.lua: this file runs that file's set-up part and continues.
local here = (arg[0]:match('^(.*)[/\\][^/\\]*$') or '.')
local f = assert(io.open(here .. '/test_squad_item_commands.lua', 'rb'))
local base = f:read('*a'):gsub('\r\n', '\n')
f:close()
local cut = assert(base:find('\n%-%- =+ give\n'), 'test_squad_item_commands.lua: the first section was not found')
-- (as on the server, xi.squad is a plain table; the stand-in xi would otherwise invent a value for every name asked)
local prefix = base:sub(1, cut):gsub('__SQUAD_TEST = {}\n', "rawset(xi, 'squad', {})\n__SQUAD_TEST = {}\n", 1)

local body = [==[
do
local dismissed = {}
local function trust(id, name)
    local vars = { SQUAD_ID = id }
    local t = { name = name }
    function t:getObjType() return xi.objType.TRUST end
    function t:getLocalVar(k) return vars[k] or 0 end
    function t:setLocalVar(k, v) vars[k] = v end
    function t:isAlive() return true end
    function t:getPacketName() return name end
    return setmetatable(t, { __index = function() return function() return 0 end end })
end
-- a player with three mates; `out` = the slots that are called
local function world(out)
    local p = reset({})
    W.squad = {
        { id = 7, slot = 1, name = 'Mira', mjob = WAR, sjob = 0, jobs = { [WAR] = { level = 75, exp = 0 } }, equip = {}, race = 1, face = 0 },
        { id = 8, slot = 2, name = 'Bran', mjob = WAR, sjob = 0, jobs = { [WAR] = { level = 75, exp = 0 } }, equip = {}, race = 1, face = 0 },
        { id = 9, slot = 3, name = 'Cato', mjob = WAR, sjob = 0, jobs = { [WAR] = { level = 75, exp = 0 } }, equip = {}, race = 1, face = 0 },
    }
    p.party, p.timers, p.cleared, p.locals = {}, {}, 0, {}
    for _, slot in ipairs(out or {}) do p.party[#p.party + 1] = trust(W.squad[slot].id, W.squad[slot].name) end
    function p:getPartyWithTrusts() return self.party end
    function p:clearTrusts() self.cleared = self.cleared + 1; self.party = {} end
    function p:timer(ms, fn) self.timers[#self.timers + 1] = { ms = ms, fn = fn } end
    function p:getLocalVar(k) return self.locals[k] or 0 end
    function p:setLocalVar(k, v) self.locals[k] = v end
    dismissed = {}
    return p
end
local function is_out(p, id) for _, t in ipairs(p.party) do if t:getLocalVar('SQUAD_ID') == id then return true end end return false end
SquadDismissMate = function(t)
    dismissed[#dismissed + 1] = t
    return true
end
local function send_off(p) -- what the engine does after SquadDismissMate said yes
    for _, t in ipairs(dismissed) do
        for i = #p.party, 1, -1 do if p.party[i] == t then table.remove(p.party, i) end end
    end
end

section('this squad.lua says that it has the one-mate form')
check(rawget(xi.squad, 'reapplySlot') == true, 'xi.squad.reapplySlot is true (gambits_squad.lua reports capability reapply1 from it)')
local p = world({ 1, 2 })
local said = run(p, 'panel')
check(has(said, 'squadpanel:cap|reapply1') and has(said, 'squadpanel:end'), 'the panel answer carries squadpanel:cap|reapply1')
local keepDismiss = SquadDismissMate
SquadDismissMate = nil
said = run(world({ 1 }), 'panel')
-- (2026-11-25) the line is there for campmove; what matters is that it does not say reapply1
check(not has(said, 'reapply1'), 'a map server without SquadDismissMate: no reapply1 capability (the menu keeps the squad-wide Apply)')
SquadDismissMate = keepDismiss

section('!squad reapply <slot>: that mate only')
p = world({ 1, 2, 3 })
said = run(p, 'reapply', '2')
check(#dismissed == 1 and dismissed[1].name == 'Bran', 'Bran is sent off, nobody else (' .. #dismissed .. ' sent off)')
check(p.cleared == 0, 'player:clearTrusts() is not called: the others stay out')
check(#p.timers == 1 and p.timers[1].ms == RECALL_WAIT_MS, 'one call is planned, after RECALL_WAIT_MS (' .. tostring(p.timers[1] and p.timers[1].ms) .. ' ms)')
send_off(p)
check(is_out(p, 7) and is_out(p, 9) and not is_out(p, 8), 'Mira and Cato are still out')
-- a second request while the first is under way
local sentOff = #dismissed
said = run(p, 'reapply', '2')
check(has(said, 'Bran is already being called again') and #dismissed == sentOff and #p.timers == 1, 'a second request for Bran is refused: no second re-call')
-- another mate may be re-called meanwhile
said = run(p, 'reapply', '3')
check(#dismissed == sentOff + 1 and dismissed[#dismissed].name == 'Cato' and #p.timers == 2, 'Cato can be re-called while Bran is on its way')
send_off(p)
-- the planned call: the mate is called (followed up to callMate's first check: a full party says so)
local full = {}
for i = 1, 6 do full[i] = trust(100 + i, 'Other' .. i) end
local keepParty = p.party
p.party = full
local before = #p.printed
p.timers[1].fn(p)
check(has(table.concat(p.printed, '\n', before + 1), 'Your party is full'), 'when the wait is over callMate runs for Bran (stopped here at its "party is full" check)')
check(p:getLocalVar('SQUAD_REAPPLY_8') == 0, 'and Bran can be re-called again afterwards')
-- the mate was called by hand in the meantime: the planned call does nothing
p.party = { trust(7, 'Mira'), trust(9, 'Cato') }
before = #p.printed
p.timers[2].fn(p)
check(#p.printed == before, 'Cato is out again already when its wait ends: no second call, nothing said')

section('refusals: nothing is sent off')
p = world({ 1 })
said = run(p, 'reapply', '2')
check(has(said, 'Bran is not out') and #dismissed == 0 and p.cleared == 0 and #p.timers == 0, 'a mate that is away: ' .. said)
said = run(p, 'reapply', '9')
check(has(said, 'No squad mate in that slot') and #dismissed == 0 and p.cleared == 0, 'an unknown slot: ' .. said)
ADDON_OWNER = { owns = function(_, t) return t.name == 'Mira' end }
said = run(p, 'reapply', '1')
check(has(said, 'An add-on owns Mira: Squads reapply skipped') and #dismissed == 0 and #p.timers == 0, 'a mate an add-on owns is never touched: ' .. said)
ADDON_OWNER = nil
SquadDismissMate = function() return false end
said = run(p, 'reapply', '1')
check(has(said, 'could not be sent off') and #p.timers == 0 and p:getLocalVar('SQUAD_REAPPLY_7') == 0, 'the engine refused: no call is planned, nothing is left marked: ' .. said)
SquadDismissMate = nil
said = run(p, 'reapply', '1')
check(has(said, 'could not be sent off') and p.cleared == 0, 'a map server without SquadDismissMate: refused, the squad is NOT cleared instead')
SquadDismissMate = keepDismiss

section('the squad-wide !squad reapply is as it was')
p = world({ 1, 3 })
said = run(p, 'reapply')
check(p.cleared == 1 and #dismissed == 0 and #p.timers == 2, 'no slot: clearTrusts once, a call planned for each of the two mates that were out')
check(p.timers[1].ms == RECALL_WAIT_MS and p.timers[2].ms == RECALL_WAIT_MS + 1500, 'at RECALL_WAIT_MS and 1.5 s later')
p = world({ 2 })
said = run(p, 'reapply', 'all')
check(p.cleared == 1 and #p.timers == 1, '"all" is the squad-wide form too')
p = world({})
said = run(p, 'reapply')
check(has(said, 'None of your squad mates are out') and p.cleared == 1, 'nobody out: the old answer')

section('!squad sheet <slot> says whose sheet it is (the menu\'s Profile window can be on another mate by then)')
do
    local function text(v) if type(v) == 'table' then return table.concat(v, '\n') end return tostring(v) end
    for slot, name in ipairs({ 'Mira', 'Bran', 'Cato' }) do
        local t = text(run(world({}), 'sheet', tostring(slot)))
        local a = t:find('squadsheet:slot|' .. slot .. '\n', 1, true) or t:find('squadsheet:slot|' .. slot .. '$')
        local b = t:find('squadsheet:hdr|' .. name .. '|', 1, true)
        local _, count = t:gsub('squadsheet:slot|', '')
        check(a and b and a < b and count == 1 and t:find('squadsheet:end', 1, true), 'sheet ' .. slot .. ': one "squadsheet:slot|' .. slot .. '" line, before the hdr line of ' .. name)
    end
    local t = text(run(world({}), 'sheet', '9'))
    check(not t:find('squadsheet:slot|', 1, true) and not t:find('squadsheet:hdr|', 1, true), 'no such mate: no slot line and no sheet (the help line, as before)')
end
end

io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
]==]

local chunk, err = (loadstring or load)(prefix .. body, '=test_squad_reapply_slot')
assert(chunk, err)
chunk()
