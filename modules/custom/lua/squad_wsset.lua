-----------------------------------
-- F12 (2026-11-25): a squad mate's temporary weapon skill gear set (XI: Forever Offline).
--
-- One optional WS set per squad mate AND main job: armor and accessories only (head, body, hands, legs, feet, neck, waist,
-- both ears, both rings, back = equipment slots 4-15). The map server puts it on right before the mate starts a weapon
-- skill (both the normal weapon skill path and the SA/TA closer go through CTrustController::WeaponSkill) and takes it
-- off as soon as the damage is done - or at once when the weapon skill is refused, interrupted, or the mate is knocked
-- out or leaves (trust_entity.cpp; squad_wsset.h). The ordinary outfit is the default and is never changed; weapons,
-- ammo and the look are never touched. A mate without a set fights exactly as before.
--
-- Stored on the player, one char var per piece: SQUAD_WSX_<mate id>_<job id>_<slot> = item id (0 / none = keep the
-- outfit piece). Saving checks every piece by the rules !squad equip uses: an equippable item that fits the slot, given
-- to the squad first (unless "Squad gets all gear"), the mate's job, its level, and no clash with the rest of the
-- effective outfit (a Rare item once). When the mate is called (and when a set is saved while it is out) the set is
-- checked again against THAT call's outfit and level (Level Sync); a piece that fails is left out and that slot keeps
-- its outfit piece (said once). The map server checks level and job once more each time the set goes on.
-- This file defines no globals; squad.lua and gambits_squad.lua load it with require.
-----------------------------------
local W = {}

W.FIRST_SLOT, W.LAST_SLOT = 4, 15
W.SLOT_NAMES = { [4] = 'head', [5] = 'body', [6] = 'hands', [7] = 'legs', [8] = 'feet', [9] = 'neck', [10] = 'waist',
                 [11] = 'ear1', [12] = 'ear2', [13] = 'ring1', [14] = 'ring2', [15] = 'back' }
W.outfits = W.outfits or {} -- trust entity id -> { outfit = {slot = itemId}, level = n, mateId, job } (the last call)

function W.varName(mateId, job, slot)
    return string.format('SQUAD_WSX_%d_%d_%d', tonumber(mateId) or 0, tonumber(job) or 0, slot)
end

function W.isSetSlot(slot)
    return type(slot) == 'number' and slot >= W.FIRST_SLOT and slot <= W.LAST_SLOT and slot == math.floor(slot)
end

function W.slotByName(word)
    word = string.lower(tostring(word or ''))
    for slot = W.FIRST_SLOT, W.LAST_SLOT do
        if W.SLOT_NAMES[slot] == word then
            return slot
        end
    end

    return tonumber(word)
end

local function hasBit(mask, n)
    return math.floor((tonumber(mask) or 0) / (2 ^ n)) % 2 == 1
end

function W.engineReady()
    return type(rawget(_G, 'SquadSetWsSet')) == 'function' and type(rawget(_G, 'SquadWsSetEngine')) == 'function'
end

-- the stored set: { [slot] = itemId }
function W.get(player, mateId, job)
    local set = {}
    for slot = W.FIRST_SLOT, W.LAST_SLOT do
        local id = player:getCharVar(W.varName(mateId, job, slot))
        if id > 0 then
            set[slot] = id
        end
    end

    return set
end

function W.count(set)
    local n = 0
    for _ in pairs(set or {}) do
        n = n + 1
    end

    return n
end

local function unlocked(player, itemId)
    local need = not (xi.squad and xi.squad.requireUnlock == false)
    if not need or (type(rawget(_G, 'squadAllGear')) == 'function' and squadAllGear()) then
        return true
    end

    local ok, unlocks = pcall(function() return GetSquadUnlocks(player:getID()) end)
    return ok and type(unlocks) == 'table' and unlocks[itemId] ~= nil
end

-- why this piece cannot go in the set (nil = fine). outfit = the effective outfit {slot = itemId} it goes with
-- (the ordinary outfit with the set's other pieces on); level = the mate's main level to check against.
function W.pieceProblem(player, job, slot, itemId, outfit, level)
    if not W.isSetSlot(slot) then
        return 'only armor and accessories (head to back) go in a WS set'
    end

    local ok, info = pcall(function() return GetSquadItemInfo(itemId) end)
    if not ok or type(info) ~= 'table' or not info.valid then
        return 'that is not an equippable item'
    elseif not hasBit(info.slot, slot) then
        return string.format('%s does not fit the %s slot', info.name or 'that item', W.SLOT_NAMES[slot])
    elseif not unlocked(player, itemId) then
        return string.format('%s has not been given to your squad yet (!squad give)', info.name or 'that item')
    elseif not hasBit(info.jobs, job - 1) then
        return string.format('%s cannot be worn by that job', info.name or 'that item')
    elseif (info.level or 0) > level then
        return string.format('%s needs level %d', info.name or 'that item', info.level or 0)
    end

    if type(rawget(_G, 'squadGearConflict')) == 'function' then
        local okC, clash = pcall(squadGearConflict, outfit or {}, slot, itemId, info)
        if okC and clash then
            return clash
        end
    end

    return nil
end

-- the effective outfit of `outfit` with `set` on (a copy)
local function withSet(outfit, set)
    local out = {}
    for s, id in pairs(outfit or {}) do
        out[s] = id
    end

    for s, id in pairs(set or {}) do
        out[s] = id
    end

    return out
end

-- the pieces of `set` that pass for this outfit and level, and the problems { slot = why }
function W.check(player, job, set, outfit, level)
    local keep, problems = {}, {}
    for slot = W.FIRST_SLOT, W.LAST_SLOT do
        local id = set[slot]
        if id then
            local others = withSet(outfit, keep)
            others[slot] = nil -- (the set piece replaces this slot's outfit piece)
            local why = W.pieceProblem(player, job, slot, id, others, level)
            if why then
                problems[slot] = why
            else
                keep[slot] = id
            end
        end
    end

    return keep, problems
end

-- hand the checked set to the map server for this called mate
local function push(player, trust, mateId, job, outfit, level, quiet)
    if not W.engineReady() then
        return nil, {}
    end

    local keep, problems = W.check(player, job, W.get(player, mateId, job), outfit, level)
    SquadSetWsSet(trust, keep)
    if not quiet and next(problems) ~= nil then
        local parts = {}
        for slot, why in pairs(problems) do
            parts[#parts + 1] = W.SLOT_NAMES[slot] .. ': ' .. why
        end

        table.sort(parts)
        player:printToPlayer(string.format('%s: part of the WS gear set is left out (%s); those slots keep the normal gear.',
            trust:getPacketName(), table.concat(parts, '; ')))
    end

    return keep, problems
end

-- squad.lua callMate: outfit = the gear this call gives stats for (after Level Sync), main = this call's main level
function W.onSpawn(player, trust, mate, outfit, main)
    local copy = {}
    for s, id in pairs(outfit or {}) do
        if type(s) == 'number' and type(id) == 'number' and id > 0 then
            copy[s] = id
        end
    end

    W.outfits[trust:getID()] = { outfit = copy, level = main, mateId = mate.id, job = mate.mjob }
    push(player, trust, mate.id, mate.mjob, copy, main, false)
end

-- the set again on a called mate (after a save): its last call's outfit, its level now
function W.liveApply(player, mate, trust)
    local known = W.outfits[trust:getID()]
    local outfit = known and known.outfit or {}
    if known == nil then
        for slot = 0, 15 do
            outfit[slot] = (mate.equip and mate.equip[mate.mjob] or {})[slot]
        end
    end

    return push(player, trust, mate.id, trust:getMainJob(), outfit, trust:getMainLvl(), true)
end

-- store one piece (itemId 0 = none). Checked against the mate's normal outfit and its own level (no Level Sync: that
-- is checked again when it is called). true, or false + why
function W.setPiece(player, mate, job, slot, itemId, level)
    if not W.isSetSlot(slot) then
        return false, 'only armor and accessories (head to back) go in a WS set'
    end

    if itemId == 0 then
        player:setCharVar(W.varName(mate.id, job, slot), 0)
        return true
    end

    local set = W.get(player, mate.id, job)
    set[slot] = nil
    local outfit = withSet(mate.equip and mate.equip[job] or {}, set)
    local why = W.pieceProblem(player, job, slot, itemId, outfit, level)
    if why then
        return false, why
    end

    player:setCharVar(W.varName(mate.id, job, slot), itemId)
    return true
end

function W.clear(player, mateId, job)
    for slot = W.FIRST_SLOT, W.LAST_SLOT do
        player:setCharVar(W.varName(mateId, job, slot), 0)
    end
end

-- the items a WS set slot could take for this mate (the !squad equip picker's list: given gear, then with "Squad gets
-- all gear" everything the job can wear), best first: { { id, level, name } ... }, at most `limit`
function W.choices(player, job, slot, level, limit)
    limit = limit or 40
    local found, listed = {}, {}
    local ok, unlocks = pcall(function() return GetSquadUnlocks(player:getID()) end)
    for itemId in pairs(ok and type(unlocks) == 'table' and unlocks or {}) do
        local okI, info = pcall(function() return GetSquadItemInfo(itemId) end)
        if okI and type(info) == 'table' and info.valid and hasBit(info.slot, slot) and (info.level or 0) <= level and hasBit(info.jobs, job - 1) then
            found[#found + 1] = { id = itemId, level = info.level or 0, name = info.name or tostring(itemId) }
            listed[itemId] = true
        end
    end

    table.sort(found, function(a, b)
        return a.level > b.level or (a.level == b.level and a.name < b.name)
    end)

    if type(rawget(_G, 'squadAllGear')) == 'function' and squadAllGear() and type(rawget(_G, 'GetSquadGearChoices')) == 'function' then
        local okC, list = pcall(GetSquadGearChoices, slot, job, level, 80)
        for _, c in ipairs(okC and type(list) == 'table' and list or {}) do
            if #found >= limit then
                break
            end

            if not listed[c.id] then
                listed[c.id] = true
                found[#found + 1] = { id = c.id, level = c.level, name = c.name }
            end
        end
    end

    while #found > limit do
        table.remove(found)
    end

    return found
end

return W
