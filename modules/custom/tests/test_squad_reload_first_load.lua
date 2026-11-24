-- squad_reload.lua (SC-03, Squads hot reload): the engine's FIRST load of a file is never taken for a watcher re-run.
-- Regression: the file used to mark every file covered by init.txt as already seen, including the files under the folder
-- line "custom/late", which the engine loads after squad_reload.lua. The first require('modules/module_utils') of
-- late/squad_gear_score.lua was then replaced by an ordered reload and the engine's own load was aborted with error(...),
-- which printed 3 new error lines at every boot. No server, no database; nothing is written.
--   luajit test_squad_reload_first_load.lua <server>/modules/custom/lua
--   Lua 5.4: lua -e "unpack = unpack or table.unpack" test_squad_reload_first_load.lua <server>/modules/custom/lua
local LUA = arg[1]
assert(LUA, 'usage: test_squad_reload_first_load.lua <modules/custom/lua>')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end

-- the init.txt this run sees: plain lines for the Squads files, the folder line custom/late, squad_reload.lua last
local INIT = table.concat({
    '# test init.txt',
    'custom/lua/squad.lua',
    'custom/lua/squad_logic.lua',
    'custom/late',
    'custom/lua/squad_reload.lua',
}, '\n') .. '\n'

local realOpen = io.open
io.open = function(path, mode)
    local norm = tostring(path):gsub('[\\]', '/')
    if norm == './modules/init.txt' then
        return { read = function() return INIT end, close = function() end }
    end
    return realOpen(path, mode)
end

local LOG = {}
print = function(...) local p = {} for i = 1, select('#', ...) do p[#p + 1] = tostring((select(i, ...))) end LOG[#LOG + 1] = table.concat(p, '\t') end

xi = { module = {} }
package.preload['modules/module_utils'] = function() return true end

local load_ = loadstring or load
assert(loadfile(LUA .. '/squad_reload.lua'))()
local R = SQUAD_RELOAD
check(R ~= nil and R.seen ~= nil, 'squad_reload loaded and exposes SQUAD_RELOAD')

local runs = {}
R.run = function(opts) runs[#runs + 1] = opts.files and opts.files[1] or '?' return { ok = true, ms = 0, files = {} } end

-- what the engine does: run a file's chunk, whose first statement is require('modules/module_utils')
local function engineRuns(chunkname)
    package.loaded['modules/module_utils'] = nil
    local fn = assert(load_("require('modules/module_utils') return true", '@' .. chunkname))
    return pcall(fn)
end

section('the engine\'s first load of a file under the folder line custom/late')
check(R.seen['late/squad_gear_score'] ~= true, 'late/squad_gear_score is not marked seen at boot')
local ok, err = engineRuns('./modules/custom/late/squad_gear_score.lua')
check(ok, 'first load of late/squad_gear_score.lua is not aborted: ' .. tostring(err))
check(#runs == 0, 'no reload ran during the engine\'s first load')
check(R.seen['late/squad_gear_score'] == true, 'the first load marks the file seen')

section('a later bare re-run of that file (the file watcher) is still replaced by the ordered reload')
ok, err = engineRuns('./modules/custom/late/squad_gear_score.lua')
check(not ok and tostring(err):find('ordered reload', 1, true) ~= nil, 'the watcher re-run is replaced: ' .. tostring(err))
check(runs[1] == 'late/squad_gear_score', 'the ordered reload ran for late/squad_gear_score')

section('files init.txt names itself are loaded before this file, so their next run is a re-run')
check(R.seen['squad_logic'] == true, 'squad_logic is marked seen at boot')
runs = {}
ok, err = engineRuns('./modules/custom/lua/squad_logic.lua')
check(not ok and tostring(err):find('ordered reload', 1, true) ~= nil, 'the watcher re-run of squad_logic is replaced')
check(runs[1] == 'squad_logic', 'the ordered reload ran for squad_logic')

io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
