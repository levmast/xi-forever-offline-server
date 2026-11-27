-- modules/module_utils.lua, applyOverride: one function can carry any number of overrides.
-- Regression (2026-11-25 to 2026-11-27, Tetsu, Neet, Josh, Quaiton: the 1 minute Chocobo's Wounds wait gone): an override
-- used to look its globals up through the environment of the function it wraps, that one through the one before it, and
-- so on. LuaJIT follows at most 100 such steps, so the 100th override of a function stopped at its first global with
-- "loop in gettable", and it and every override after it did nothing. xi.server.onServerStart reached 100 when
-- late/nm_timers.lua was added; the last one, late/quest_waits.lua, never ran again and the era waits came back.
-- If this test fails after an update of the server base, the fix in applyOverride was lost: put it back.
-- No server, no database; nothing is written.
--   luajit test_override_depth.lua <server>/modules
--   (the server runs LuaJIT; a plain Lua 5.1 works too. Lua 5.2 and later have no setfenv, which module_utils.lua needs.)
local MODULES = arg[1]
assert(MODULES, 'usage: test_override_depth.lua <modules folder>')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end

xi    = { settings = { main = { RESTRICT_CONTENT = 1 } } }
utils = { splitStr = function() return {} end }
assert(loadfile(MODULES .. '/module_utils.lua'))()

-- stack `count` overrides on xi.server.onServerStart the way the module loader does; each one touches globals
local function stack(count)
    local order = {}
    xi.server = { onServerStart = function(a) order[#order + 1] = 0 return 'base:' .. tostring(a) end }
    for k = 1, count do
        applyOverride(xi.server, 'onServerStart', function(a)
            local result = super(a)
            if type(xi.settings) ~= 'table' or type(pcall) ~= 'function' then
                error('override ' .. k .. ' cannot see the globals')
            end

            order[#order + 1] = k
            return result
        end, 'xi.server.onServerStart', 'test_override_depth.lua')
    end

    local ok, result = pcall(xi.server.onServerStart, 'x')
    return ok, result, order
end

section('as many overrides as the kit has today, and far more')
for _, count in ipairs({ 1, 99, 100, 101, 102, 150, 400, 2000 }) do
    local ok, result, order = stack(count)
    check(ok, count .. ' overrides run without an error (' .. tostring(result) .. ')')
    check(result == 'base:x', count .. ' overrides: the argument reaches the original and its result comes back')
    local inOrder = #order == count + 1
    for i = 1, #order do inOrder = inOrder and order[i] == i - 1 end
    check(inOrder, count .. ' overrides: the original runs first, then every override in the order it was declared (' .. #order - 1 .. ' ran)')
end

section('what an override sees is unchanged')
do
    -- a plain global assignment inside an override stays in that override (late/hardcore.lua relies on writing _G.x instead)
    xi.probe = { f = function() return 1 end }
    applyOverride(xi.probe, 'f', function() overrideDepthLeak = super() + 1 return overrideDepthLeak end, 'xi.probe.f', 'test')
    check(xi.probe.f() == 2, 'an override reads back a global it assigned itself')
    check(rawget(_G, 'overrideDepthLeak') == nil, 'that assignment does not reach the real globals')

    -- every override has its own super
    applyOverride(xi.probe, 'f', function() return super() * 10 end, 'xi.probe.f', 'test')
    applyOverride(xi.probe, 'f', function() return super() + 5 end, 'xi.probe.f', 'test')
    check(xi.probe.f() == 25, 'each override calls the one declared before it ((1 + 1) * 10 + 5 = 25, got ' .. tostring(xi.probe.f()) .. ')')

    -- the original function's own environment is where the overrides look
    local own = setmetatable({ marker = 'own' }, { __index = _G })
    xi.probe.g = setfenv(function() return marker end, own)
    for _ = 1, 150 do
        applyOverride(xi.probe, 'g', function() return (super()) end, 'xi.probe.g', 'test')
    end
    applyOverride(xi.probe, 'g', function() return super() .. '+' .. tostring(marker) .. '+' .. type(xi) end, 'xi.probe.g', 'test')
    local ok, result = pcall(xi.probe.g)
    check(ok and result == 'own+own+table', 'overrides see the globals of the function they override, 151 deep (' .. tostring(result) .. ')')

    -- applying the same overrides again on a fresh base function (a script reloaded while the server runs)
    local first  = function() return super() .. 'a' end
    local second = function() return super() .. 'b' end
    for round = 1, 3 do
        xi.probe.h = function() return 'base' .. round end
        applyOverride(xi.probe, 'h', first, 'xi.probe.h', 'test')
        applyOverride(xi.probe, 'h', second, 'xi.probe.h', 'test')
        check(xi.probe.h() == 'base' .. round .. 'ab', 'overrides applied again after a reload, round ' .. round)
    end
end

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
