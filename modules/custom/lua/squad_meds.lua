-----------------------------------
-- XI: Forever Offline: squad mates use medicines (2026-11-25, Rysan's suggestion; a first step, to be refined)
--
-- Trade medicines to a squad mate (any number, one kind or several): that mate keeps them and uses one ON ITSELF when it
-- has a status the medicine removes (Silence only for a mate whose main or support job casts) - but only when the party's
-- healers cannot take care of it:
--   * nobody near it can cast the cure now (no WHM / RDM / PLD ... with the spell at their level, or they are silenced,
--     asleep, petrified, stunned or out of MP), or
--   * the status is still on after GRACE_SECS, although someone could have cured it (the healer is busy), or
--   * it is Doom (Holy Water at once: Doom does not wait).
-- Every use takes one of the medicines you gave it; there are no free ones. When it uses its last but one and its last of
-- a kind, it says so in party chat.
--
-- The effect is the item's own script (scripts/items/<item>.lua onItemUse): exactly what the medicine does for a player
-- (Holy Water's chance against Doom included). What each mate carries is kept on your character (char var
-- '[SqM]<mate id>:<item id>'). In game: !squad meds shows what each mate carries.
-- A library (no globals, registers nothing): squad.lua requires it as xi.squad.meds, as it does squad_juice.lua.
-----------------------------------
local meds = {}

meds.CHECK_SECS = 2  -- looks at most this often
meds.GRACE_SECS = 8  -- with a healer who could cure it: waits this long first
meds.HEALER_REACH = 20 -- yalms: a healer farther than this does not count

-- item id = { name, script (scripts/items/...), statuses it removes (names in xi.effect), spells that cure them }
meds.items =
{
    [4151] = { name = 'Echo Drops',  script = 'flask_of_echo_drops', cures = { 'SILENCE' } },
    [4148] = { name = 'Antidote',    script = 'antidote',            cures = { 'POISON' } },
    [4150] = { name = 'Eye Drops',   script = 'flask_of_eye_drops',  cures = { 'BLINDNESS' } },
    [4154] = { name = 'Holy Water',  script = 'flask_of_holy_water', cures = { 'DOOM', 'CURSE_I', 'CURSE_II', 'BANE' } },
    [4155] = { name = 'Remedy',      script = 'remedy',              cures = { 'SILENCE', 'BLINDNESS', 'POISON', 'PARALYSIS', 'DISEASE' } },
}

-- what is used for a status, best first: the medicine made for it, then Remedy
meds.order = { 4151, 4148, 4150, 4154, 4155 }

-- the spell a healer would cure each status with (xi.magic.spell names)
meds.cureSpell =
{
    SILENCE = 'SILENA', POISON = 'POISONA', BLINDNESS = 'BLINDNA', PARALYSIS = 'PARALYNA', DISEASE = 'VIRUNA',
    CURSE_I = 'CURSNA', CURSE_II = 'CURSNA', BANE = 'CURSNA', DOOM = 'CURSNA',
}

-- statuses that keep anyone from casting, or a mate from using an item
meds.blocksCasting = { 'SILENCE', 'SLEEP_I', 'SLEEP_II', 'LULLABY', 'PETRIFICATION', 'STUN', 'TERROR', 'CHARM_I', 'MUTE' }
meds.blocksItems   = { 'SLEEP_I', 'SLEEP_II', 'LULLABY', 'PETRIFICATION', 'STUN', 'TERROR', 'CHARM_I', 'MEDICINE' }

local function varName(mateId, itemId)
    return string.format('[SqM]%d:%d', mateId, itemId)
end

local function effect(name)
    return xi.effect and xi.effect[name]
end

local function hasAny(entity, names)
    for _, name in ipairs(names) do
        local id = effect(name)
        if id ~= nil and entity:hasStatusEffect(id) then
            return true
        end
    end

    return false
end

function meds.isMedicine(itemId)
    return meds.items[itemId] ~= nil
end

-- the medicines a mate carries: { [itemId] = count }
function meds.stock(owner, mateId)
    local out = {}
    for itemId in pairs(meds.items) do
        local n = owner:getCharVar(varName(mateId, itemId))
        if n > 0 then
            out[itemId] = n
        end
    end

    return out
end

-- A trade of medicines to a mate (squad.lua xi.squad.onTrade). Returns true when the item was a medicine.
function meds.onTrade(player, owner, trust, offer, say)
    local info = meds.items[offer.itemId]
    if info == nil then
        return false
    end

    local mateId = trust:getLocalVar('SQUAD_ID')
    local count = math.max(1, tonumber(offer.quantity) or 1)
    if mateId == 0 or not player:delItemAt(offer.itemId, count, xi.inv.INVENTORY, offer.slot) then
        say('failed')
        return true
    end

    local name = varName(mateId, offer.itemId)
    owner:setCharVar(name, owner:getCharVar(name) + count)
    say('thanks', { item = info.name })
    player:printToPlayer(string.format('%s now carries %d %s. It uses one when the healers cannot cure it in time.',
        trust:getPacketName(), owner:getCharVar(name), info.name), xi.msg.channel.SYSTEM_3)
    return true
end

-- the spell table: name -> { id, levels = { [job] = level } } (squad_spell_jobs_data.lua), read once
local spellLevels = nil
local function cureLevels(spellName)
    if spellLevels == nil then
        spellLevels = {}
        local ok, data = pcall(require, 'modules/custom/lua/squad_spell_jobs_data')
        if ok and type(data) == 'table' and type(data.spells) == 'table' then
            for id, row in pairs(data.spells) do
                if type(row) == 'table' and type(row[1]) == 'string' and type(row[2]) == 'table' then
                    spellLevels[row[1]] = { id = id, levels = row[2] }
                end
            end
        end
    end

    return spellLevels[spellName]
end

-- can this party member cast the cure for `statusName` now?
function meds.canCure(member, statusName)
    local spell = cureLevels(meds.cureSpell[statusName] or '')
    if spell == nil or not member:isAlive() or hasAny(member, meds.blocksCasting) then
        return false
    end

    local byMain = spell.levels[member:getMainJob()]
    local bySub = spell.levels[member:getSubJob()]
    local knows = (byMain ~= nil and byMain <= member:getMainLvl()) or (bySub ~= nil and bySub <= member:getSubLvl())
    if not knows then
        return false
    end

    -- a player has to have learned it; a squad mate has its job's spells (with "spells from scrolls" a mate may still lack
    -- it: the grace time covers that)
    if member:getObjType() == xi.objType.PC and member.hasSpell and not member:hasSpell(spell.id) then
        return false
    end

    return member:getMP() >= 12 -- (the cure spells cost 8-30 MP; a healer near empty is not counted)
end

-- is there someone near `mob` (not itself) who could cure `statusName` now?
function meds.healerNear(owner, mob, statusName)
    local party = owner.getPartyWithTrusts and owner:getPartyWithTrusts() or {}
    for _, member in pairs(party) do
        if member:getID() ~= mob:getID() and member:getZoneID() == mob:getZoneID() and mob:checkDistance(member) <= meds.HEALER_REACH
            and meds.canCure(member, statusName) then
            return true
        end
    end

    return false
end

-- the jobs that cast (xi.job ids): WHM 3, BLM 4, RDM 5, PLD 7, DRK 8, BRD 10, NIN 13 (ninjutsu: no MP), SMN 15, BLU 16,
-- SCH 20, GEO 21, RUN 22
meds.CASTER_JOBS = { [3] = true, [4] = true, [5] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true,
                     [16] = true, [20] = true, [21] = true, [22] = true }

-- Silence only matters to a mate that casts: its main or support job is one of CASTER_JOBS. By job, not by MP: MP from gear
-- (a WAR in an MP+ piece has MP) does not make a WAR cast. A WAR, MNK or THF without such a support job keeps its Echo Drops
-- (and its Remedies for what does matter to it).
function meds.silenceMatters(mob)
    return meds.CASTER_JOBS[mob:getMainJob()] == true or meds.CASTER_JOBS[mob:getSubJob()] == true
end

-- what to use now: itemId and the status it is for, or nil. `firstSeen` = { [statusName] = os.time() first seen on }
function meds.choose(owner, mob, stock, firstSeen, now)
    local silenceCounts = meds.silenceMatters(mob)
    for _, itemId in ipairs(meds.order) do
        if (stock[itemId] or 0) > 0 then
            for _, statusName in ipairs(meds.items[itemId].cures) do
                local id = effect(statusName)
                if id ~= nil and mob:hasStatusEffect(id) and (statusName ~= 'SILENCE' or silenceCounts) then
                    local since = firstSeen[statusName] or now
                    if statusName == 'DOOM' or not meds.healerNear(owner, mob, statusName) or now - since >= meds.GRACE_SECS then
                        return itemId, statusName
                    end
                end
            end
        end
    end

    return nil
end

local function itemScript(script)
    local ok, obj = pcall(require, 'scripts/items/' .. script)
    return ok and type(obj) == 'table' and type(obj.onItemUse) == 'function' and obj or nil
end

-- every AI tick of a squad mate (squad.lua's TICK listener)
function meds.tick(mob)
    local now = os.time()
    if now < mob:getLocalVar('SQUAD_MEDS_AT') then
        return
    end

    mob:setLocalVar('SQUAD_MEDS_AT', now + meds.CHECK_SECS)

    local owner = mob:getMaster()
    if owner == nil or owner:getObjType() ~= xi.objType.PC or not mob:isAlive() or mob:getLocalVar('SQUAD_IDLE') == 1 then
        return
    end

    local mateId = mob:getLocalVar('SQUAD_ID')
    local stock = meds.stock(owner, mateId)
    if next(stock) == nil then
        return
    end

    -- when each status was first seen on it (local vars, so a status that comes back starts a new wait)
    local firstSeen = {}
    for statusName in pairs(meds.cureSpell) do
        local id = effect(statusName)
        local key = 'SQUAD_MEDS_SEEN_' .. statusName
        if id ~= nil and mob:hasStatusEffect(id) then
            if mob:getLocalVar(key) == 0 then
                mob:setLocalVar(key, now)
            end
            firstSeen[statusName] = mob:getLocalVar(key)
        elseif mob:getLocalVar(key) ~= 0 then
            mob:setLocalVar(key, 0)
        end
    end

    if next(firstSeen) == nil or hasAny(mob, meds.blocksItems) then
        return
    end

    local itemId, statusName = meds.choose(owner, mob, stock, firstSeen, now)
    local info = itemId and meds.items[itemId]
    local obj = info and itemScript(info.script)
    if obj == nil then
        return
    end

    local okUse = pcall(obj.onItemUse, mob)
    if not okUse then
        return
    end

    local name = varName(mateId, itemId)
    local left = math.max(0, owner:getCharVar(name) - 1)
    owner:setCharVar(name, left)
    mob:setLocalVar('SQUAD_MEDS_SEEN_' .. statusName, 0)

    local text
    if left == 0 then
        text = string.format('*uses %s* That was my last %s!', info.name, info.name)
    elseif left == 1 then
        text = string.format('*uses %s* Only one %s left.', info.name, info.name)
    else
        text = string.format('*uses %s* (%d left)', info.name, left)
    end

    owner:printToPlayer(text, 4, mob:getPacketName())
end

-- !squad meds: what every mate carries
function meds.command(player, mates)
    local any = false
    for _, mate in ipairs(mates) do
        local parts = {}
        for itemId, n in pairs(meds.stock(player, mate.id)) do
            parts[#parts + 1] = string.format('%d %s', n, meds.items[itemId].name)
        end

        if #parts > 0 then
            any = true
            table.sort(parts)
            player:printToPlayer(string.format('%s: %s', mate.name, table.concat(parts, ', ')), xi.msg.channel.SYSTEM_3)
        end
    end

    if not any then
        player:printToPlayer('No mate carries any medicine. Trade Echo Drops, Antidotes, Eye Drops, Holy Water or Remedies to a mate:'
            .. ' it uses one on itself when the healers cannot cure it in time.', xi.msg.channel.SYSTEM_3)
    end
end

return meds
