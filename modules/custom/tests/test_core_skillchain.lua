-- core_skillchain_data.lua and core_skillchain.lua: the generated skillchain table and the helper over it. No server, no database.
--   luajit test_core_skillchain.lua <server>/modules/custom/lua
--   (gen_skillchain_table.py --check says whether the table matches data/ and battleutils.cpp; tools/core_files/run_checks.py runs both.)
local LUA = arg[1]
assert(LUA, 'usage: test_core_skillchain.lua <modules/custom/lua folder>')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end

-- the helper requires the data by its server path: map that path to the folder given on the command line
local real_require = require
local loaded = {}
local function load_mod(name)
    if loaded[name] then return loaded[name] end
    loaded[name] = assert(loadfile(LUA .. '/' .. name .. '.lua'))()
    return loaded[name]
end
require = function(path)
    local short = path:match('^modules/custom/lua/(.+)$')
    if short then return load_mod(short) end
    return real_require(path)
end

local D = load_mod('core_skillchain_data')
local sc = load_mod('core_skillchain')
local P = D.PROPERTY

section('the properties')
check(P.none == 0 and P.transfixion == 1 and P.impaction == 8 and P.light == 13 and P.darkness_ii == 16, "property numbers are the server's")
check(D.property_name[8] == 'impaction' and sc.property_name(13) == 'light', 'names both ways')
check(sc.tier(P.scission) == 1 and sc.tier(P.fusion) == 2 and sc.tier(P.light) == 3 and sc.tier(P.light_ii) == 4 and sc.tier(P.darkness_ii) == 4, 'tiers: level 1, 2, 3, 4')

section('weapon skills')
local n = 0
for _ in pairs(D.WS) do n = n + 1 end
check(n >= 150, 'weapon skills with properties: ' .. n)
local ok = true
for _, w in pairs(D.WS) do
    if type(w.name) ~= 'string' or #w.props < 1 or #w.props > 3 then ok = false end
    for _, p in ipairs(w.props) do if p < 1 or p > 16 then ok = false end end
end
check(ok, 'every weapon skill has one to three properties, each a real property')
local combo = sc.properties('combo')
check(combo and #combo == 1 and combo[1] == P.impaction, 'Combo is impaction')
local sp = sc.properties('Spinning Attack')
check(sp and sp[1] == P.liquefaction and sp[2] == P.impaction, 'a name with capitals and spaces is found (Spinning Attack: liquefaction, impaction)')
check(sc.properties(2)[1] == P.reverberation and sc.properties('no such skill') == nil, 'by id, and an unknown skill gives nil')
local fh = sc.properties('final_heaven')
check(fh and fh[1] == P.light and fh[2] == P.fusion, 'Final Heaven: light, fusion')
local copy = sc.properties('combo')
copy[1] = 99
check(sc.properties('combo')[1] == P.impaction, 'the answer is a copy: changing it does not change the table')

section("the closing rules (the server's skillchain_map)")
local c = D.CHAIN
check(c[P.transfixion][P.scission] == P.distortion, 'transfixion then scission = distortion')
check(c[P.impaction][P.liquefaction] == P.liquefaction, 'impaction then liquefaction = liquefaction')
check(c[P.liquefaction][P.impaction] == P.fusion, 'liquefaction then impaction = fusion')
check(c[P.light][P.light] == P.light_ii and c[P.darkness][P.darkness] == P.darkness_ii, 'light + light = light II, darkness + darkness = darkness II')
check(c[P.gravitation][P.distortion] == P.darkness and c[P.fragmentation][P.fusion] == P.light, 'level 2 pairs make level 3')
check(c[P.impaction][P.impaction] == nil and c[P.light_ii] == nil, 'the same property twice does not chain, and a level 4 skillchain does not continue')
local entries = 0
for _, row in pairs(c) do for _ in pairs(row) do entries = entries + 1 end end
check(entries >= 25, 'closing rules: ' .. entries)

section("form: the server's order")
check(sc.form({ P.impaction }, { P.liquefaction }) == P.liquefaction, 'one resonance, one property')
check(sc.form({ P.impaction }, { P.reverberation, P.liquefaction }) == P.liquefaction, 'the second property of the skill can be the one that closes')
check(sc.form({}, { P.scission }) == nil and sc.form({ P.scission }, nil) == nil and sc.form(nil, nil) == nil, 'empty answers nil, never an error')
-- resonance outer, skill inner: transfixion + scission = distortion is tried before liquefaction + scission = scission
check(sc.form({ P.transfixion, P.liquefaction }, { P.scission }) == P.distortion, 'the first resonance property that closes wins')
check(sc.form({ P.liquefaction, P.transfixion }, { P.scission }) == P.scission, 'and with the order swapped the other one wins')

section('two weapon skills in a row')
check(sc.opens_into('combo', 'spinning_attack') == P.liquefaction, 'Combo then Spinning Attack = liquefaction (impaction resonates, liquefaction closes)')
check(sc.opens_into('combo', 'combo') == nil, 'Combo then Combo = nothing')
check(sc.opens_into('combo', 'no such skill') == nil, 'an unknown skill = nothing')

section('timing')
check(sc.DELAY == 3 and sc.WINDOW == 10, 'the server waits 3 s, the window is 10 s')
check(sc.window_after(0) == 10 and sc.window_after(1) == 9 and sc.window_after(5) == 5 and sc.window_after(99) == 0, 'each link shortens the window by 1 s, never below 0')
check(D.TIMING.max_links == 5, 'links count up to 5')

require = real_require
io.write(string.format('\ncore_skillchain: %d passed, %d failed\n', passed, failed))
if rawget(_G, 'CORE_TEST_HARNESS') then return failed end
os.exit(failed == 0 and 0 or 1)
