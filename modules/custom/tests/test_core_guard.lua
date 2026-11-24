-- core_guard.lua: the crash guard. No server, no database; nothing is written.
--   luajit test_core_guard.lua <server>/modules/custom/lua
--   (Lua 5.4 works too; the server runs LuaJIT. tools/core_files/run_checks.py runs this file for you.)
local LUA = arg[1]
assert(LUA, 'usage: test_core_guard.lua <modules/custom/lua folder>')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end

local chunk = assert(loadfile(LUA .. '/core_guard.lua'))
local guard = chunk()

local lines, now = {}, 1000
local function fresh(opts)
    guard.reset()
    lines = {}
    local o = { sink = function(s) lines[#lines + 1] = s end, clock = function() return now end, burst = 3, window = 60, max_tags = 200, max_text = 300 }
    for k, v in pairs(opts or {}) do o[k] = v end
    guard.configure(o)
end

section('a call that works')
fresh()
local ok, a, b, c = guard.call('t.ok', function(x, y) return x + y, 'two', nil end, 3, 4)
check(ok == true and a == 7 and b == 'two' and c == nil, 'results pass through, true first')
check(#lines == 0, 'a good call logs nothing')
check(next(guard.stats()) == nil, 'a good call counts nothing')
local ok2, n = guard.call('t.nil', function(...) return select('#', ...) end, nil, nil, 5)
check(ok2 == true and n == 3, 'nil arguments keep their place')
local safe = guard.wrap('t.wrap', function(x) return x * 2 end)
check(select(2, safe(21)) == 42, 'wrap runs the function with its arguments')

section('a call that fails')
fresh()
local okf, err = guard.call('t.bad', function() error('boom') end)
check(okf == false, 'false first')
check(type(err) == 'string' and err:find('boom', 1, true), 'the error text comes back')
check(#lines == 1 and lines[1]:find('[guard] t.bad: ', 1, true) == 1 and lines[1]:find('boom', 1, true), 'one log line: ' .. tostring(lines[1]))
check(not lines[1]:find('\n'), 'one line stays one line')
local st = guard.stats()['t.bad']
check(st and st.errors == 1 and st.logged == 1 and st.held == 0, 'counted')
check(select(1, guard.call('t.nofn', nil)) == false, 'a missing function is a failure, not a throw')
check(select(1, guard.call('t.tbl', function() error({ code = 5 }) end)) == false, 'a table error is caught')
check(select(1, guard.call('t.nilerr', function() error() end)) == false, 'an error with no value is caught')

section('rate limit')
fresh()
for _ = 1, 10 do guard.call('t.loop', function() error('same') end) end
check(#lines == 3, 'only the burst (3) is logged in one window, got ' .. #lines)
st = guard.stats()['t.loop']
check(st.errors == 10 and st.logged == 3 and st.held == 7 and st.held_total == 7, 'the rest are counted: ' .. tostring(st.held))
guard.call('t.other', function() error('other tag') end)
check(#lines == 4, 'another tag has its own allowance')
now = now + 30
guard.call('t.loop', function() error('same') end)
check(#lines == 4, 'still inside the window: still held')
now = now + 31
guard.call('t.loop', function() error('same') end)
check(#lines == 5 and lines[5]:find('(8 more held back)', 1, true), 'a new window says how many were held back: ' .. tostring(lines[5]))
guard.call('t.loop', function() error('same') end)
check(#lines == 6 and not lines[6]:find('held back', 1, true), 'and says it once')

section('limits')
fresh({ max_tags = 3 })
for i = 1, 8 do guard.call('tag' .. i, function() error('x') end) end
local count = 0
for _ in pairs(guard.stats()) do count = count + 1 end
check(count == 4, 'three tags plus the shared (other) entry, got ' .. count)
fresh({ max_text = 20 })
guard.call('t.long', function() error(('z'):rep(500)) end)
check(#lines[1] < 80, 'a long message is cut: ' .. #lines[1])

section('the guard never throws')
fresh({ sink = function() error('the log is broken') end })
local okb = guard.call('t.sinkdies', function() error('x') end)
check(okb == false, 'a failing log sink does not escape')
fresh()
guard.configure({ nonsense = 1 })
check(true, 'unknown options are ignored')

io.write(string.format('\ncore_guard: %d passed, %d failed\n', passed, failed))
if rawget(_G, 'CORE_TEST_HARNESS') then return failed end
os.exit(failed == 0 and 0 or 1)
