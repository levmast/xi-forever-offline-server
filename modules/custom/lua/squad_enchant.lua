-----------------------------------
-- Squad mates use their gear's enchantments (2026-11-22, levi: "Tig now wears vision_ring" but never used it).
--
-- A player has to /item a Vision Ring, Haste Belt, Sacred Sword and so on to get its effect. A squad mate never did,
-- so the enchantment did nothing on them. Now each called mate checks its worn gear every few seconds and, for each
-- piece with an "equipped item" enchantment that is not on it, runs that item's own script (scripts/items/<name>.lua,
-- onItemUse), the same effect a player gets. It is used again when it wears off. Charges and the item's reuse timer
-- are not tracked (a mate has no inventory copy of the item).
--
-- Only gear the mate is really wearing for stats counts: under a Level Sync, armour above the synced level is shown
-- as a look only (squad.lua callMate) and its enchantment is not used either.
-- This file defines no globals; squad.lua loads it with require and calls onSpawn for each mate it calls.
-----------------------------------
local E = {}

E.CHECK_SEC = 10 -- how often a mate looks at its gear
E.RETRY_SEC = 60 -- after a use that did not land (e.g. Astral Pot with no pet out), wait this long before trying again

-- enchantments a mate should not use by itself
E.SKIP =
{
    invisible_mantle = true, -- (Invisible on a fighting mate)
}

local worn    = {} -- [entity id] = { item ids }
local checkAt = {} -- [entity id] = os.time() of the next check
local retryAt = {} -- [entity id .. ':' .. item id] = os.time() before which that item is not tried again
local scripts = {} -- [item id] = the item's script table, or false (no usable equipped enchantment)

-- The item's own script, when it has an equipped-item enchantment (its onItemUse checks target:hasEquipped).
local function scriptFor(itemId)
    if scripts[itemId] ~= nil then
        return scripts[itemId] or nil
    end

    scripts[itemId] = false
    local info = GetSquadItemInfo(itemId)
    if not (info and info.valid and type(info.name) == 'string') or E.SKIP[info.name] then
        return nil
    end

    local path   = './scripts/items/' .. info.name .. '.lua'
    local handle = io.open(path, 'r')
    if handle == nil then
        return nil
    end

    local text = handle:read('*a')
    handle:close()
    if text == nil or not text:find('EQUIPPED_ITEM', 1, true) or not text:find('hasEquipped', 1, true) then
        return nil
    end

    local chunk = loadstring(text, '@' .. path)
    if chunk == nil then
        return nil
    end

    local ok, obj = pcall(chunk)
    if ok and type(obj) == 'table' and type(obj.onItemUse) == 'function' then
        scripts[itemId] = obj
        return obj
    end

    return nil
end

-- the use animation of each item (sql/item_usable.sql, item_usable.animation), read once, for the chat line below
local animations
local function animationFor(itemId)
    if animations == nil then
        animations = {}
        local handle = io.open('./sql/item_usable.sql', 'r')
        if handle ~= nil then
            for line in handle:lines() do
                local id, anim = line:match("VALUES %((%d+),'[^']*',%d+,[%d%.]+,(%d+),")
                if id ~= nil then
                    animations[tonumber(id)] = tonumber(anim)
                end
            end
            handle:close()
        end
    end

    return animations[itemId] or 0
end

-- "<mate> uses <item>." in the chat log, with the item's use animation, like a player using it (and like the mates eating)
local function showUse(mob, itemId)
    pcall(function()
        -- category 5 = item use finished, resolution 0 = hit, message 28 = "<actor> uses <item>."
        mob:injectActionPacket(mob:getID(), 5, animationFor(itemId), 0, 0, 28, itemId, itemId)
    end)
end

-- The mate as the item script's target: everything goes to the mate, but hasEquipped(item) is true for this item
-- (a trust has no equipment container, so the real hasEquipped is always false for it).
local function asWearer(mob, itemId)
    return setmetatable({}, {
        __index = function(_, key)
            if key == 'hasEquipped' then
                return function(_, id)
                    return id == itemId
                end
            end

            local value = mob[key]
            if type(value) == 'function' then
                return function(_, ...)
                    return value(mob, ...)
                end
            end

            return value
        end,
    })
end

-- the item ids whose equipped enchantment is on the mob now
local function activeEnchantments(mob)
    local active = {}
    for _, effect in pairs(mob:getStatusEffects() or {}) do
        if effect:getSourceType() == xi.effectSourceType.EQUIPPED_ITEM then
            active[effect:getSourceTypeParam()] = true
        end
    end

    return active
end

function E.tick(mob)
    local id   = mob:getID()
    local list = worn[id]
    local now  = os.time()
    if list == nil or now < (checkAt[id] or 0) then
        return
    end

    checkAt[id] = now + E.CHECK_SEC
    if not mob:isAlive() or mob:getLocalVar('SQUAD_IDLE') == 1 then -- (a stopped mate does nothing, like eating)
        return
    end

    local active = activeEnchantments(mob)
    for _, itemId in ipairs(list) do
        local key = id .. ':' .. itemId
        if not active[itemId] and now >= (retryAt[key] or 0) then
            local script = scriptFor(itemId)
            if script ~= nil then
                local ok, err = pcall(script.onItemUse, asWearer(mob, itemId), mob)
                local landed  = ok and activeEnchantments(mob)[itemId]
                if not landed then
                    retryAt[key] = now + E.RETRY_SEC
                end

                if not ok then
                    print(string.format('[squad] %s could not use item %d: %s', mob:getPacketName(), itemId, tostring(err)))
                elseif landed then
                    showUse(mob, itemId)
                    print(string.format('[squad] %s uses the enchantment on item %d', mob:getPacketName(), itemId))
                end
            end
        end
    end
end

-- squad.lua callMate: the mate just spawned wearing `outfit` ([slot] = item id, the gear that gives stats)
function E.onSpawn(trust, outfit)
    local id   = trust:getID()
    local list = {}
    for _, itemId in pairs(outfit or {}) do
        if type(itemId) == 'number' and itemId > 0 then
            list[#list + 1] = itemId
        end
    end

    worn[id]    = list
    checkAt[id] = os.time() + 3 -- (a moment after the call, once the mate is in the party)
    for key in pairs(retryAt) do
        if key:find('^' .. id .. ':') then
            retryAt[key] = nil
        end
    end

    trust:addListener('TICK', 'SQUAD_ENCHANT', E.tick)
end

return E
