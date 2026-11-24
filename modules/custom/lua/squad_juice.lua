-----------------------------------
-- XI: Forever Offline: squad mates drink juices (2026-11-23, Frost and Syfin's suggestion; Hurami's rules)
--
-- Trade juices to a squad mate (any number, one kind or several): that mate keeps them and drinks one when its MP
-- runs low and it has no Refresh on, in a fight or out of it. Every drink uses up one of the juices you gave it.
-- With the launcher's "Squad mates: unlimited juice" on (main.SQUAD_UNLIMITED_JUICE, 0 by default) a mate with none of
-- yours left drinks a juice that fits its level, free.
--
-- The effects are the items' own (scripts/items/bottle_of_*_juice.lua): Refresh of the same power and length.
-- What each mate carries is kept on your character (char var '[SqJ]<mate id>:<item id>').
-- In game: !squad juice shows what each mate carries.
-----------------------------------
local juice = {}

juice.MP_BELOW   = 70    -- drinks when its MP is below this many percent
juice.CHECK_SECS = 3     -- looks at most this often

-- item id = { name, Refresh power, seconds, regen = Regen power (Vampire Juice) }
juice.items =
{
    [4422] = { name = 'Orange Juice',    power = 1, duration = 90 },
    [4423] = { name = 'Apple Juice',     power = 1, duration = 135 },
    [4425] = { name = 'Tomato Juice',    power = 1, duration = 180 },
    [4442] = { name = 'Pineapple Juice', power = 1, duration = 240 },
    [4441] = { name = 'Grape Juice',     power = 2, duration = 90 },
    [4424] = { name = 'Melon Juice',     power = 2, duration = 135 },
    [4512] = { name = 'Vampire Juice',   power = 2, duration = 90, regen = 2 },
    [5438] = { name = 'Strange Juice',   power = 2, duration = 300 },
    [5932] = { name = 'Kitron Juice',    power = 3, duration = 180 },
}

-- "Unlimited juice": what a mate drinks for free, by its level
juice.freeTiers =
{
    { from = 1,  item = 4422 }, -- Orange Juice
    { from = 25, item = 4423 }, -- Apple Juice
    { from = 45, item = 4441 }, -- Grape Juice
    { from = 60, item = 4424 }, -- Melon Juice
}

local function varName(mateId, itemId)
    return string.format('[SqJ]%d:%d', mateId, itemId)
end

function juice.isJuice(itemId)
    return juice.items[itemId] ~= nil
end

-- the launcher's "Squad mates: unlimited juice" (settings main.SQUAD_UNLIMITED_JUICE, 0 by default)
local function freeOn()
    local main = xi.settings and xi.settings.main
    return main ~= nil and (tonumber(main.SQUAD_UNLIMITED_JUICE) or 0) == 1
end

-- the juices a mate carries: { [itemId] = count }
function juice.stock(owner, mateId)
    local out = {}
    for itemId in pairs(juice.items) do
        local n = owner:getCharVar(varName(mateId, itemId))
        if n > 0 then
            out[itemId] = n
        end
    end

    return out
end

-- A trade of juices to a mate (squad.lua xi.squad.onTrade). owner = the mate's master; offer = { itemId, slot, quantity }.
-- Returns true when the item was a juice (taken, or told why not).
function juice.onTrade(player, owner, trust, offer, say)
    local info = juice.items[offer.itemId]
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
    player:printToPlayer(string.format('%s now carries %d %s. It drinks one when its MP runs low.',
        trust:getPacketName(), owner:getCharVar(name), info.name), xi.msg.channel.SYSTEM_3)
    return true
end

-- the best juice it carries (the most MP in total), else the free one for its level when that switch is on
local function pick(owner, mob)
    local mateId = mob:getLocalVar('SQUAD_ID')
    local bestId, bestMp = nil, -1
    for itemId, n in pairs(juice.stock(owner, mateId)) do
        local info = juice.items[itemId]
        local mp = info.power * info.duration
        if n > 0 and mp > bestMp then
            bestId, bestMp = itemId, mp
        end
    end

    if bestId then
        return bestId, false
    end

    if freeOn() then
        local level, freeId = mob:getMainLvl(), nil
        for _, tier in ipairs(juice.freeTiers) do
            if level >= tier.from then
                freeId = tier.item
            end
        end

        return freeId, true
    end

    return nil
end

-- every AI tick of a squad mate (squad.lua's TICK listener)
function juice.tick(mob)
    local now = os.time()
    if now < mob:getLocalVar('SQUAD_JUICE_AT') then
        return
    end

    mob:setLocalVar('SQUAD_JUICE_AT', now + juice.CHECK_SECS)

    local owner = mob:getMaster()
    if owner == nil or owner:getObjType() ~= xi.objType.PC or not mob:isAlive() or mob:getMaxMP() <= 0 then
        return
    end

    if mob:getLocalVar('SQUAD_IDLE') == 1 or mob:getMPP() >= juice.MP_BELOW or mob:hasStatusEffect(xi.effect.REFRESH) then
        return
    end

    local itemId, free = pick(owner, mob)
    local info = itemId and juice.items[itemId]
    if info == nil then
        return
    end

    mob:addStatusEffect(xi.effect.REFRESH, { power = info.power, duration = info.duration, origin = mob, tick = 3 })
    if info.regen then
        mob:addStatusEffect(xi.effect.REGEN, { power = info.regen, duration = info.duration, origin = mob, tick = 3 })
    end

    local left = nil
    if not free then
        local name = varName(mob:getLocalVar('SQUAD_ID'), itemId)
        left = math.max(0, owner:getCharVar(name) - 1)
        owner:setCharVar(name, left)
    end

    local who = mob:getPacketName()
    local text
    if free then
        text = string.format('*drinks a bottle of %s*', info.name)
    elseif left == 0 then
        text = string.format('*drinks a bottle of %s* That was my last one.', info.name)
    else
        text = string.format('*drinks a bottle of %s* (%d left)', info.name, left)
    end

    owner:printToPlayer(text, 4, who)
end

-- !squad juice: what every mate carries
function juice.command(player, mates)
    local any = false
    for _, mate in ipairs(mates) do
        local parts = {}
        for itemId, n in pairs(juice.stock(player, mate.id)) do
            parts[#parts + 1] = string.format('%d %s', n, juice.items[itemId].name)
        end

        if #parts > 0 then
            any = true
            table.sort(parts)
            player:printToPlayer(string.format('%s: %s', mate.name, table.concat(parts, ', ')), xi.msg.channel.SYSTEM_3)
        end
    end

    if not any then
        player:printToPlayer('No mate carries any juice. Trade juices to a mate: it drinks one when its MP runs low.', xi.msg.channel.SYSTEM_3)
    end

    if freeOn() then
        player:printToPlayer('Unlimited juice is on: a mate with none of yours drinks a juice for its level, free.', xi.msg.channel.SYSTEM_3)
    end
end

return juice
