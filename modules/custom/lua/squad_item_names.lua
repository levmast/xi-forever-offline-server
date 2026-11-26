-----------------------------------
-- Squad item names (!squad give, !squad equip, !squad lockstyle): an item as a player types it.
--
--   Light Crossbow +1, light crossbow +1, LIGHT_CROSSBOW_+1, light_crossbow_+1 and 17228 all mean the same item.
--
-- The lookup itself is unchanged: FindSquadItem (squad.cpp) matches item_equipment.name, already ignoring capitals and
-- turning spaces into underscores. This file only adds what the chat command could not do:
--   * the name may be several words (the command splits the line into words);
--   * a full in-game name works where item_equipment holds the game's short name (Leather Bandana +1 is stored as
--     lth._bandana_+1), through the core GetItemIDByName (item_basic name or sortname) and an exact name check;
--   * a name several items share (relic stages, male and female versions) is never resolved to an arbitrary one: the one
--     you have is taken when exactly one of them is yours, otherwise you are asked for the id.
-- No database access of its own and no state: everything comes in through `env`, so it is tested without a server.
-----------------------------------
local N = {}

-- GetItemIDByName's answer for "more than one row" is 0xFFFF - count + 1 (luautils.cpp)
local MANY = 65000

-- the item words of a command, nil ones (not typed) left out
function N.words(...)
    local out = {}
    for i = 1, select('#', ...) do
        local w = select(i, ...)
        if w ~= nil and tostring(w) ~= '' then
            out[#out + 1] = tostring(w)
        end
    end

    return out
end

-- how item names are stored: lower case, underscores for spaces (FindSquadItem does the same to what it gets)
function N.key(text)
    local s = tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    return (s:lower():gsub(' ', '_'))
end

function N.isId(text)
    return tostring(text or ''):match('^%d+$') ~= nil
end

local function call(fn, ...)
    if type(fn) ~= 'function' then
        return nil
    end

    local ok, value = pcall(fn, ...)
    return ok and value or nil
end

local function info(env, id)
    return call(env.info, id) or { valid = false }
end

-- the full in-game name of an item (item_basic.name), lower case
local function fullName(env, id)
    local item = call(env.item, id)
    if item == nil then
        return nil
    end

    local name = call(function() return item:getName() end)
    return name and tostring(name):lower() or nil
end

-- is this item called `key`, by its equipment name or its full name?
local function named(env, id, key)
    local i = info(env, id)
    return (i.valid and tostring(i.name or ''):lower() == key) or fullName(env, id) == key
end

-- how many items item_basic has under this name or sortname, and the one when it is exactly one
local function basicMatches(env, key)
    if key:find('[%%\\]') then
        return 0, nil -- (GetItemIDByName uses LIKE: a typed % or \ is a wildcard there, so it is not asked)
    end

    local r = tonumber(call(env.byName, key)) or 0
    if r >= MANY then
        return 65536 - r, nil
    elseif r > 0 then
        return 1, r
    end

    return 0, nil
end

-- another piece of equipment beside this id with the same equipment name (male and female versions are neighbours,
-- 11393/11394; the few names GetItemIDByName cannot see are all within a few ids of each other)
local NEIGHBOURS = 8
local function hasTwin(env, id)
    local name = info(env, id).name
    for other = math.max(1, id - NEIGHBOURS), id + NEIGHBOURS do
        if other ~= id then
            local o = info(env, other)
            if o.valid and o.name == name then
                return true
            end
        end
    end

    return false
end

-- the longest whole word of a name (no "." abbreviation, not "+1"): a short equipment name keeps one, and the full name
-- has it too (lth._bandana_+1 / leather_bandana_+1, b._carrion_broth / jug_of_bubbling_carrion_broth)
local function longestWord(key)
    local best = ''
    for word in key:gmatch('[^_]+') do
        if not word:find('.', 1, true) and not word:find('^[%+%-]') and #word > #best then
            best = word
        end
    end

    return best
end

-- one name, several items: the one you have, when exactly one of yours has that name. The full name is read from the
-- item templates (no database); the equipment name (a database read) only for items whose full name contains the name's
-- longest whole word, at most OWNED_LOOKUPS of them, so a full set of bags stays cheap.
local OWNED_LOOKUPS = 200
local function fromOwned(env, key, owned)
    local seen, matches, lookups = {}, {}, 0
    local word = longestWord(key)
    for _, id in ipairs(call(owned) or {}) do
        id = tonumber(id)
        if id and not seen[id] then
            seen[id] = true
            local full = fullName(env, id)
            local candidate = full == key
            if not candidate and (full == nil or word == '' or full:find(word, 1, true)) and lookups < OWNED_LOOKUPS then
                lookups = lookups + 1
                candidate = tostring(info(env, id).name or ''):lower() == key
            end

            if candidate and info(env, id).valid then
                matches[#matches + 1] = id
            end
        end
    end

    table.sort(matches)
    if #matches == 1 then
        return matches[1], matches
    end

    return nil, matches
end

-- text: what was typed (words joined with spaces), env: { find, byName, info, item }, owned: function() -> item ids the
-- player has for this command. Returns id or nil, and why: 'id', 'name', 'fullname', 'owned', 'notfound', 'ambiguous'
-- (with the matching ids the player has, maybe none).
function N.resolve(text, env, owned)
    if N.isId(text) then
        local id = tonumber(call(env.find, tostring(text))) or 0
        if id == 0 then
            return nil, 'notfound'
        end

        return id, 'id' -- (an id is what you asked for: no name checks)
    end

    local key = N.key(text)
    if key == '' then
        return nil, 'notfound'
    end

    local id = tonumber(call(env.find, key)) or 0
    if id ~= 0 and not info(env, id).valid then
        return id, 'name' -- (not equipment, a spell scroll: as before)
    end

    local count, single = basicMatches(env, key)
    if id ~= 0 then
        local ambiguous = count > 1 or (count == 1 and single ~= id and info(env, single).valid) or (count == 0 and hasTwin(env, id))
        if not ambiguous then
            return id, 'name'
        end
    elseif count == 1 then
        -- the full name of an item whose equipment name is the short one; LIKE could also have taken an _ as any letter,
        -- so the name is checked exactly before it is used
        if info(env, single).valid and named(env, single, key) then
            return single, 'fullname'
        end

        -- (2026-11-25, jainfarstrider: "!squad give Sneak" said Item not found) a spell scroll by the spell's own name:
        -- the game files a scroll's short name as the spell (sneak, cure_ii). Scrolls are items 4609-5631.
        if single >= 4609 and single <= 5631 then
            return single, 'name'
        end

        return nil, 'notfound'
    elseif count == 0 then
        return nil, 'notfound'
    end

    local mine, matches = fromOwned(env, key, owned)
    if mine then
        return mine, 'owned'
    end

    return nil, 'ambiguous', matches
end

-- equip and lockstyle: <item words> [equip slot]. The last word is the equip slot when it is one (and the rest names an
-- item); otherwise every word is the item, and a last word that is no item is still handed on as the slot, so a
-- mistyped slot gets the old "does not fit that slot" answer.
function N.resolveWithSlot(words, isSlot, env, owned)
    local function attempt(n)
        local text = table.concat(words, ' ', 1, n)
        local id, why, extra = N.resolve(text, env, owned)
        return id, why, extra, text
    end

    local last = #words
    if last == 0 then
        return nil, 'notfound', nil, '', nil
    end

    local slotFirst = last >= 2 and isSlot(words[last])
    if slotFirst then
        local id, why, extra, text = attempt(last - 1)
        if why ~= 'notfound' then
            return id, why, extra, text, words[last]
        end
    end

    local id, why, extra, text = attempt(last)
    if why ~= 'notfound' or last < 2 or slotFirst then
        return id, why, extra, text, nil
    end

    local id2, why2, extra2, text2 = attempt(last - 1)
    if why2 ~= 'notfound' then
        return id2, why2, extra2, text2, words[last]
    end

    return id, why, extra, text, nil
end

-- what to tell the player
function N.notFound(wearable)
    return 'Item not found' .. (wearable and ', or not something you can wear' or '') ..
        '. Type its name as the game shows it (Light Crossbow +1, light_crossbow_+1, any capitals) or its id, and check the spelling (Shortbow, not Short Bow).'
end

function N.ambiguous(text, matches)
    local yours = ''
    if matches and #matches > 1 then
        local ids = {}
        for i, id in ipairs(matches) do
            ids[i] = tostring(id)
        end

        yours = ' Yours: ' .. table.concat(ids, ', ') .. '.'
    end

    return string.format('More than one item is called "%s". Use its id instead.%s', tostring(text), yours)
end

return N
