-- core_spell_data.lua: the generated spell and ability table. No server, no database; nothing is written.
--   luajit test_core_spell_data.lua <server>/modules/custom/lua
--   (the file itself is generated; tools/core_files/gen_spell_tables.py --check says whether it matches sql/. run_checks.py runs both.)
local LUA = arg[1]
assert(LUA, 'usage: test_core_spell_data.lua <modules/custom/lua folder>')

local passed, failed = 0, 0
local function check(c, label) if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end end
local function section(n) io.write('\n== ', n, '\n') end
local function band(a, b) -- a bit test that works in LuaJIT and in Lua 5.4
    local bit = rawget(_G, 'bit')
    if bit then return bit.band(a, b) end
    return load('return ... & ...')(a, b)
end

local D = assert(loadfile(LUA .. '/core_spell_data.lua'))()
local S, A, T = D.SPELL, D.ABILITY, D.TARGET

section('shape')
local ns, na = 0, 0
for _ in pairs(S) do ns = ns + 1 end
for _ in pairs(A) do na = na + 1 end
check(ns >= 890, 'spells: ' .. ns)
check(na >= 600, 'abilities: ' .. na)
local seen = {}
local ok = true
for name, s in pairs(S) do
    if seen[s.id] then ok = false end
    seen[s.id] = true
    if D.spell_by_id[s.id] ~= name then ok = false end
    if type(s.tier) ~= 'number' or s.tier < 1 or type(s.range) ~= 'number' or type(s.target) ~= 'number' or type(s.lv) ~= 'table' then ok = false end
    for job, level in pairs(s.lv) do
        if job < 1 or job > 22 or level < 1 or level > 99 then ok = false end
    end
end
check(ok, 'every spell id is unique, found again by id, and has tier, range, target and levels in range')
seen, ok = {}, true
for name, a in pairs(A) do
    if seen[a.id] then ok = false end
    seen[a.id] = true
    if D.ability_by_id[a.id] ~= name then ok = false end
    if type(a.tier) ~= 'number' or a.tier < 1 or a.job < 0 or a.job > 23 or type(a.range) ~= 'number' or type(a.target) ~= 'number' then ok = false end
end
check(ok, 'every ability id is unique, found again by id, and has tier, job, range and target in range')

section('values the game is known for')
local cure = S.CURE
check(cure and cure.id == 1 and cure.tier == 1 and cure.range == 20 and cure.mp == 8 and cure.cast == 2000, 'Cure: id, tier, range 20 yalms, 8 mp, 2 s cast')
check(cure.lv[3] == 1 and cure.lv[5] == 3 and cure.lv[7] == 5 and cure.lv[1] == nil, 'Cure: WHM 1, RDM 3, PLD 5, not WAR')
check(S.CURE_II.tier == 2 and S.CURE_II.lv[3] == 11, 'Cure II: tier 2, WHM 11')
check(S.CURE_V.tier == 5 and S.CURE_V.lv[3] == 61, 'Cure V: tier 5, WHM 61')
check(S.KATON_NI and S.KATON_NI.tier == 2 and S.KATON_NI.mp == 0 and S.KATON_ICHI.tier == 1 and S.KATON_SAN.tier == 3, 'ninjutsu forms: Ichi 1, Ni 2, San 3, no mp')
check(S.DIA.tier == 1 and S.DIA_II.tier == 2, 'Dia, Dia II tiers')
check(S.RAISE and band(S.RAISE.target, T.player_dead) ~= 0, 'Raise can target a dead player')
check(band(cure.target, T.self) ~= 0 and band(cure.target, T.player_party) ~= 0, 'Cure can target self and a party member')
check(band(S.DIA.target, T.enemy) ~= 0 and band(S.DIA.target, T.player_party) == 0, 'Dia targets an enemy, not the party')
local ms, bz = A.MIGHTY_STRIKES, A.BERSERK
check(ms and ms.job == 1 and ms.level == 0 and ms.recast == 3600, 'Mighty Strikes: WAR, level 0, 3600 s (the two hour)')
check(bz and bz.job == 1 and bz.level == 15 and bz.recast == 300 and bz.range == 0, 'Berserk: WAR 15, 300 s, self')
check(A.PROVOKE and band(A.PROVOKE.target, T.enemy) ~= 0 and A.PROVOKE.range > 0, 'Provoke: targets an enemy, has a range')
check(A.WARCRY and A.WARCRY.aoe == 1, 'Warcry hits the area')

section('tier comes only from the name')
local bad = 0
for name, s in pairs(S) do
    local roman = name:match('_(I+)$') or name:match('_(IV)$') or name:match('_(VI?)$')
    if roman and s.tier < 2 and roman ~= 'I' then bad = bad + 1 end
end
check(bad == 0, 'no spell whose name ends in a numeral above I has tier 1')

section('loading does nothing')
local before = 0
for _ in pairs(_G) do before = before + 1 end
assert(loadfile(LUA .. '/core_spell_data.lua'))()
local after = 0
for _ in pairs(_G) do after = after + 1 end
check(before == after, 'loading the table adds no global')

io.write(string.format('\ncore_spell_data: %d passed, %d failed\n', passed, failed))
if rawget(_G, 'CORE_TEST_HARNESS') then return failed end
os.exit(failed == 0 and 0 or 1)
