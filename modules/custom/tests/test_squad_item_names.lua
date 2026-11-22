-- squad_item_names.lua against the real item names (the repository's SQL seed files). No server, no database.
--   luajit test_squad_item_names.lua <server>/modules/custom/lua <server>/sql
--   lua    test_squad_item_names.lua <server>/modules/custom/lua <server>/sql      (Lua 5.4)
local LUA, SQL = arg[1], arg[2]
assert(LUA and SQL, 'usage: test_squad_item_names.lua <modules/custom/lua> <sql>')
local here = (arg[0]:match('^(.*)[/\\][^/\\]*$') or '.')
local F = dofile(here .. '/squad_item_names_fixture.lua').load(SQL)
local N = dofile(LUA .. '/squad_item_names.lua')
local env = F.env()

local passed, failed = 0, 0
local function check(c, label)
    if c then passed = passed + 1 else failed = failed + 1 io.write('FAIL: ', label, '\n') end
end
local function section(name) io.write('\n== ', name, '\n') end
local function owns(...) local ids = { ... } return function() return ids end end
local none = owns()
local function expect(text, wantId, wantWhy, owned)
    local id, why = N.resolve(text, env, owned or none)
    check(id == wantId and (wantWhy == nil or why == wantWhy),
        string.format('%-28s -> %s (%s), expected %s (%s)', '"' .. text .. '"', tostring(id), tostring(why), tostring(wantId), tostring(wantWhy)))
end

section('the reported names')
expect('Light Crossbow +1', 17228, 'name')
expect('light_crossbow_+1', 17228, 'name')
expect('LIGHT CROSSBOW +1', 17228, 'name')
expect('Light_Crossbow_+1', 17228, 'name')
expect('  light   crossbow  +1 ', 17228, 'name')
expect('17228', 17228, 'id')
expect('LEATHER_BANDANA', 12440, 'name')
expect('Leather Bandana', 12440, 'name')
expect('leather bandana', 12440, 'name')
expect('LEATHER BANDANA', 12440, 'name')
expect('leather_bandana', 12440, 'name')
expect('Shortbow +1', 17175, 'name')
expect('shortbow_+1', 17175, 'name')
expect('Short Bow +1', nil, 'notfound') -- (the item is Shortbow +1)

section('full in-game names where item_equipment has the short one')
expect('Leather Bandana +1', 12542, 'fullname')
expect('leather_bandana_+1', 12542, 'fullname')
expect('lth._bandana_+1', 12542, 'name') -- (the short name still works)
expect('Lth. Bandana +1', 12542, 'name')

section('single words and ids, as before')
expect('bronze_harness', 12576, 'name')
expect('Bronze_Harness', 12576, 'name')
expect('12576', 12576, 'id')
expect('65000', 65000, 'id') -- (an id is passed on as it is; the command then says it is not equipment)
check(N.resolve('scroll_of_cure', env, none) == 4609, 'a spell scroll by name still resolves (not equipment, no name checks)')
expect('', nil, 'notfound')
expect('no such item', nil, 'notfound')
local before = F.calls.byName
expect('light%', nil, 'notfound') -- (a % is never sent to LIKE; the fixture asserts it)
check(F.calls.byName == before, 'a typed % does not reach GetItemIDByName')

section('a name several items share is never answered with an arbitrary one')
expect('Gastraphetes', nil, 'ambiguous')
expect('gastraphetes', 19001, 'owned', owns(19001))
expect('Gastraphetes', 19001, 'owned', owns(12440, 19001, 17228))
local id, why, matches = N.resolve('gastraphetes', env, owns(18981, 19001))
check(id == nil and why == 'ambiguous' and #matches == 2 and matches[1] == 18981 and matches[2] == 19001, 'two of them yours: ask for the id, list yours')
check(N.ambiguous('Gastraphetes', matches):find('18981, 19001', 1, true) ~= nil, 'the message lists your ids: ' .. N.ambiguous('Gastraphetes', matches))
-- male and female versions; the short name is not in item_basic at all (found by the neighbour check)
expect('dancers_shoes', nil, 'ambiguous')
expect("Dancers Toe Shoes", nil, 'ambiguous')
expect('dancers_shoes', 15747, 'owned', owns(15747))
expect('Dancers Toe Shoes', 15746, 'owned', owns(15746))

section('equip / lockstyle words with a trailing equip slot')
local function isSlot(w)
    local s = { main = 1, sub = 1, range = 1, ranged = 1, ammo = 1, head = 1, body = 1, hands = 1, legs = 1, feet = 1, neck = 1, waist = 1,
                ear1 = 1, ear2 = 1, ring1 = 1, ring2 = 1, back = 1 }
    return s[w:lower()] ~= nil
end
local function slotCase(words, wantId, wantSlot, wantText)
    local rid, rwhy, _, text, slot = N.resolveWithSlot(words, isSlot, env, none)
    check(rid == wantId and slot == wantSlot and (wantText == nil or text == wantText),
        string.format('{%s} -> %s slot %s text "%s" (%s)', table.concat(words, ','), tostring(rid), tostring(slot), tostring(text), tostring(rwhy)))
end
slotCase({ 'Leather', 'Bandana', 'head' }, 12440, 'head', 'Leather Bandana')
slotCase({ 'leather_bandana', 'head' }, 12440, 'head')
slotCase({ 'leather_bandana' }, 12440, nil)
slotCase({ 'Leather', 'Bandana' }, 12440, nil)
slotCase({ 'leather_bandana', 'hed' }, 12440, 'hed') -- (a mistyped slot is handed on: "does not fit that slot", as before)
slotCase({ '17228', 'range' }, 17228, 'range')
slotCase({ '17228' }, 17228, nil)
slotCase({ 'Light', 'Crossbow', '+1' }, 17228, nil)
slotCase({ 'Light', 'Crossbow', '+1', 'Range' }, 17228, 'Range')
slotCase({ 'Leather', 'Bandana', '+1', 'head' }, 12542, 'head')
slotCase({ 'Short', 'Bow', '+1', 'range' }, nil, nil)
slotCase({}, nil, nil)

section('every equipment item in the data, by full name and by equipment name')
local stats = { total = 0, resolved = 0, ambiguous = 0, ambiguousButUnique = 0, wrong = 0, notfound = 0, ownedOk = 0, ownedBad = 0 }
local samples = {}
local function sweep(id, key)
    local typed = key:gsub('_', ' ')
    local truth = F.named(key)
    local isTrue = {}
    for _, t in ipairs(truth) do isTrue[t] = true end
    stats.total = stats.total + 1
    local r, rwhy = N.resolve(typed, env, none)
    if r ~= nil then
        if isTrue[r] and #truth == 1 then
            stats.resolved = stats.resolved + 1
        else
            stats.wrong = stats.wrong + 1
            if #samples < 8 then samples[#samples + 1] = string.format('%s -> %s, named %s', key, tostring(r), table.concat(truth, '/')) end
        end
    elseif rwhy == 'ambiguous' then
        stats.ambiguous = stats.ambiguous + 1
        if #truth == 1 then stats.ambiguousButUnique = stats.ambiguousButUnique + 1 end
    else
        stats.notfound = stats.notfound + 1
        if #samples < 8 then samples[#samples + 1] = string.format('%s -> not found', key) end
    end

    local o, owhy = N.resolve(typed, env, owns(id))
    if o == id then
        stats.ownedOk = stats.ownedOk + 1
    else
        stats.ownedBad = stats.ownedBad + 1
        if #samples < 8 then samples[#samples + 1] = string.format('%s (yours: %d) -> %s (%s), named %s', key, id, tostring(o), tostring(owhy), table.concat(truth, '/')) end
    end
end
local ids = {}
for eid in pairs(F.eq) do ids[#ids + 1] = eid end
table.sort(ids)
for _, eid in ipairs(ids) do
    local b = F.basic[eid]
    if b and b.name ~= '' then sweep(eid, b.name) end
    if F.eq[eid].name ~= '' and (b == nil or F.eq[eid].name ~= b.name) then sweep(eid, F.eq[eid].name) end
end
io.write(string.format('sweep: %d names: %d resolved, %d ambiguous (%d of them name one item; another item shares the name or sortname),'
    .. ' %d not found, %d WRONG; with the item in your bags: %d ok, %d not\n', stats.total, stats.resolved, stats.ambiguous,
    stats.ambiguousButUnique, stats.notfound, stats.wrong, stats.ownedOk, stats.ownedBad))
for _, s in ipairs(samples) do io.write('   ', s, '\n') end
check(stats.wrong == 0, 'no name ever resolves to an item it does not name, or to one of several')
check(stats.ownedBad == 0, 'with the item in your bags its name (full or equipment) always resolves to it')
check(stats.notfound == 0, 'every equipment item is found by its full name and by its equipment name')
check(stats.ambiguousButUnique <= 10, 'at most a handful of single items need their id because another item shares the name')

io.write(string.format('\npassed %d, failed %d\n', passed, failed))
os.exit(failed == 0 and 0 or 1)
