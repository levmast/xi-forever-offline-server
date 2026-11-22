-- Stand-ins for the server functions squad_item_names.lua uses, built from the repository's own SQL seed files
-- (sql/item_equipment.sql, sql/item_basic.sql), so the tests see the real item names. Read only; no database.
--   FindSquadItem    as squad.cpp findSquadItem: digits = the id; else lower case, spaces to _, item_equipment.name = ?
--                    LIMIT 1 (the primary key order: the lowest id); "scroll..." also item_basic.name = ?
--   GetItemIDByName  as luautils.cpp: item_basic name LIKE ? OR sortname LIKE ? (utf8mb4_general_ci: any case; _ is any
--                    one character, % any run); one row = its id, several = 0xFFFF - count + 1, none = 0
--   GetSquadItemInfo as squad.cpp: { valid, name, level, jobs, slot, shield } from item_equipment
--   GetReadOnlyItem  an object whose getName() is item_basic.name
local F = {}

local function rows(path, pattern, each)
    local f = assert(io.open(path, 'rb'), 'cannot read ' .. path)
    for line in f:lines() do
        local caps = { line:match(pattern) }
        if caps[1] then
            each(caps)
        end
    end

    f:close()
end

function F.load(sqlDir)
    local eq, eqByName, basic, basicByLen = {}, {}, {}, {}
    rows(sqlDir .. '/item_equipment.sql', "^INSERT INTO `item_equipment` VALUES %((%d+),'([^']*)',(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),", function(c)
        local id = tonumber(c[1])
        eq[id] = { name = c[2], level = tonumber(c[3]), jobs = tonumber(c[5]), shield = tonumber(c[7]), slot = tonumber(c[9]) }
        local list = eqByName[c[2]] or {}
        list[#list + 1] = id
        eqByName[c[2]] = list
    end)
    rows(sqlDir .. '/item_basic.sql', "^INSERT INTO `item_basic` VALUES %((%d+),%d+,'([^']*)','([^']*)'", function(c)
        local id, name, sort = tonumber(c[1]), c[2]:lower(), c[3]:lower()
        basic[id] = { name = name, sort = sort }
        for _, v in ipairs(name == sort and { name } or { name, sort }) do
            local list = basicByLen[#v] or {}
            list[#list + 1] = { id = id, v = v }
            basicByLen[#v] = list
        end
    end)
    for _, list in pairs(eqByName) do
        table.sort(list)
    end

    F.eq, F.eqByName, F.basic, F.basicByLen = eq, eqByName, basic, basicByLen
    F.calls = { find = 0, byName = 0 }
    return F
end

-- MySQL LIKE without % (the only kind the resolver sends): same length, _ matches any one character, case already folded
local function likeMatches(pattern)
    local out, seen = {}, {}
    for _, row in ipairs(F.basicByLen[#pattern] or {}) do
        local ok = true
        for i = 1, #pattern do
            local p = pattern:sub(i, i)
            if p ~= '_' and p ~= row.v:sub(i, i) then
                ok = false
                break
            end
        end

        if ok and not seen[row.id] then
            seen[row.id] = true
            out[#out + 1] = row.id
        end
    end

    return out
end

function F.FindSquadItem(text)
    F.calls.find = F.calls.find + 1
    text = tostring(text or '')
    if text ~= '' and text:match('^%d+$') then
        return tonumber(text)
    end

    text = text:gsub('%u', string.lower):gsub(' ', '_')
    local list = F.eqByName[text]
    if list then
        return list[1]
    end

    if text:sub(1, 6) == 'scroll' then
        local best = nil
        for id, b in pairs(F.basic) do
            if b.name == text and (best == nil or id < best) then
                best = id
            end
        end

        if best then
            return best
        end
    end

    return 0
end

function F.GetItemIDByName(name)
    F.calls.byName = F.calls.byName + 1
    assert(not tostring(name):find('%', 1, true), 'the resolver must not send a % to LIKE')
    local hits = likeMatches(tostring(name):lower())
    if #hits == 1 then
        return hits[1]
    elseif #hits > 1 then
        return 0xFFFF - #hits + 1
    end

    return 0
end

function F.GetSquadItemInfo(id)
    local e = F.eq[tonumber(id) or -1]
    if e == nil then
        return { valid = false, skill = 0, shield = 0 }
    end

    return { valid = true, name = e.name, level = e.level, jobs = e.jobs, slot = e.slot, shield = e.shield, skill = 0 }
end

function F.GetReadOnlyItem(id)
    local b = F.basic[tonumber(id) or -1]
    if b == nil then
        return nil
    end

    return { getName = function() return b.name end, getID = function() return id end }
end

function F.env()
    return { find = F.FindSquadItem, byName = F.GetItemIDByName, info = F.GetSquadItemInfo, item = F.GetReadOnlyItem }
end

-- equipment ids that a typed key names, by equipment name or full name (the truth the resolver must never contradict)
function F.named(key)
    local out, seen = {}, {}
    for _, id in ipairs(F.eqByName[key] or {}) do
        seen[id] = true
        out[#out + 1] = id
    end

    for _, row in ipairs(F.basicByLen[#key] or {}) do
        if row.v == key and F.basic[row.id].name == key and F.eq[row.id] and not seen[row.id] then
            seen[row.id] = true
            out[#out + 1] = row.id
        end
    end

    table.sort(out)
    return out
end

return F
