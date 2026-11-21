-----------------------------------
-- Horro's Visit (XI: Forever Offline seasonal event)
-----------------------------------
-- Our version of retail's Dragon Quest X collaboration (2013-2026). The wandering sage Horro has sailed the
-- Astoltia Ark to Vana'diel for its treats, and his slimes came along (the she-slimes and metal slimes snuck on).
--
--  1. Talk to a slime next to the Home Point in Southern San d'Oria (Slarin), Bastok Markets (Sludge) or
--     Windurst Woods (Ultra Slime). It sends you to its slime camp.
--  2. The camp slime (Slabble in East Ronfaure, Slime Tarou in South Gustaberg, Sline in East Sarutabaruta)
--     goos you up: level restricted to 1. Only gooed-up adventurers can catch slimes.
--  3. Slime = 1 coin, She-Slime = 2, Metal Slime = 10. Metal Slimes sometimes show up after a slime is caught.
--     Wearing a full set (hat, shield, earring) of one slime family adds 1 coin per capture.
--  4. Spend the coins with the town slime: the slime, she-slime and metal slime gear sets and candies.
--     She-slime gear unlocks after your first She-Slime, metal slime gear after your first Metal Slime.
--  5. The first time you talk to a town slime you also get a Crystal Boy and the first Dragonland part (once per
--     character); the other four parts are prizes at 15 coins each. The five games ship in crystalboy-games, and
--     finishing one (8 hours each) is what the Crystal Boy addon reports back for the memories.
--
-- Runs on the DATES below unless the launcher's Seasonal events setting is Always on or Off (events_mode.lua).
-- Left out from retail: the Monstrosity rewards (Slime Fetish, spirits). Left out from Eventide: the shinies.
--
-- NOT FROM RETAIL CAPTURES: the NPC spots (next to the Home Points / where you arrive in each field zone), the
-- slime stats, the flee chances, the metal slime hit counter and the she/metal hat and shield prices are ours.
-- Check them in game. NPCs and slimes are server-made (zone:insertDynamicEntity); no core scripts are changed.
-----------------------------------
require('modules/module_utils')

local m = Module:new('horros_visit')

-- yyyymmdd, inclusive, the PC's local date. Add a line for each year's visit.
local DATES =
{
    { start = 20261119, finish = 20261203 },
}

local SLIMES_PER_CAMP     = 6
local SHE_SLIMES_PER_CAMP = 2
local RESPAWN_MS          = 20000
local METAL_CHANCE        = { slime = 0.08, she = 0.12 }
local METAL_LIFETIME_MS   = 120000
local METAL_HITS          = 4
local FLEE_LOW_HP_CHANCE  = 0.12      -- a hurt Slime/She-Slime (under 35% HP) may run off after a hit
local METAL_FLEE_CHANCE   = 0.15      -- a Metal Slime may run off after any hit
local AWARD_RANGE         = 40
local GOO_SECONDS         = 3600
local MOB_GROUP           = { id = 90, zone = 73 } -- Slime_Mold (a slime-family pool) used as the base for event slimes

local LOOK = { slime = 2881, she = 2907, metal = 2908, horro = 2430 }

local KIND =
{
    slime = { label = 'Slime',       coins = 1,  level = 1, hpp = 0   },
    she   = { label = 'She-Slime',   coins = 2,  level = 2, hpp = 30  },
    metal = { label = 'Metal Slime', coins = 10, level = 3, hpp = 900 },
}

local function itemId(name, fallback)
    return (xi.item and xi.item[name]) or fallback
end

local ITEM =
{
    SLIME_CAP          = itemId('SLIME_CAP', 27756),
    SLIME_SHIELD       = itemId('SLIME_SHIELD', 28655),
    SLIME_EARRING      = itemId('SLIME_EARRING', 28511),
    SHE_SLIME_HAT      = itemId('SHE_SLIME_HAT', 27726),
    SHE_SLIME_SHIELD   = itemId('SHE_SLIME_SHIELD', 28650),
    SHE_SLIME_EARRING  = itemId('SHE_SLIME_EARRING', 28509),
    METAL_SLIME_HAT    = itemId('METAL_SLIME_HAT', 27727),
    METAL_SLIME_SHIELD = itemId('METAL_SLIME_SHIELD', 28651),
    METAL_EARRING      = itemId('METAL_SLIME_EARRING', 28510),
    SLIME_CANDY        = itemId('SLIMEULATION_CANDY', 6187),
    SHE_CANDY          = itemId('SHE_SLIME_CANDY', 6188),
    METAL_CANDY        = itemId('METAL_SLIME_CANDY', 6189),
}

-- Horro brought his games along. The first part comes free with the Crystal Boy, the rest are prizes.
local CRYSTAL_BOY = itemId('CRYSTAL_BOY', 8100)

local DRAGONLAND =
{
    { id = 8105, name = 'Dragonland I'   },
    { id = 8106, name = 'Dragonland II'  },
    { id = 8107, name = 'Dragonland III' },
    { id = 8108, name = 'Dragonland IV'  },
    { id = 8109, name = 'Dragonland V'   },
}

-- Retail 2026 tiers: earring 5, shield 10, cap 15, she/metal earrings 15. The she/metal hats and shields (20/30)
-- are our split of retail's unnamed 20 and 30 coin tiers.
local SHOP =
{
    { id = ITEM.SLIME_EARRING,      name = 'Slime Earring',      cost = 5  },
    { id = ITEM.SLIME_SHIELD,       name = 'Slime Shield',       cost = 10 },
    { id = ITEM.SLIME_CAP,          name = 'Slime Cap',          cost = 15 },
    { id = ITEM.SHE_SLIME_EARRING,  name = 'She-Slime Earring',  cost = 15, needs = 'she' },
    { id = ITEM.SHE_SLIME_SHIELD,   name = 'She-Slime Shield',   cost = 20, needs = 'she' },
    { id = ITEM.SHE_SLIME_HAT,      name = 'She-Slime Hat',      cost = 20, needs = 'she' },
    { id = ITEM.METAL_EARRING,      name = 'Metal Slime Earring', cost = 15, needs = 'metal' },
    { id = ITEM.METAL_SLIME_SHIELD, name = 'Metal Slime Shield', cost = 30, needs = 'metal' },
    { id = ITEM.METAL_SLIME_HAT,    name = 'Metal Slime Hat',    cost = 30, needs = 'metal' },
    { id = ITEM.SLIME_CANDY,        name = 'Slimeulation Candy', cost = 1, candy = true },
    { id = ITEM.SHE_CANDY,          name = 'She-Slime Candy',    cost = 1, candy = true, needs = 'she' },
    { id = ITEM.METAL_CANDY,        name = 'Metal Slime Candy',  cost = 1, candy = true, needs = 'metal' },
}

for _, game in ipairs(DRAGONLAND) do
    table.insert(SHOP, { id = game.id, name = game.name, cost = 15 })
end

local SETS =
{
    { head = ITEM.SLIME_CAP,       sub = ITEM.SLIME_SHIELD,       ear = ITEM.SLIME_EARRING },
    { head = ITEM.SHE_SLIME_HAT,   sub = ITEM.SHE_SLIME_SHIELD,   ear = ITEM.SHE_SLIME_EARRING },
    { head = ITEM.METAL_SLIME_HAT, sub = ITEM.METAL_SLIME_SHIELD, ear = ITEM.METAL_EARRING },
}

-- Town slimes stand next to a Home Point (they send you to their camp); camp slimes stand where you arrive.
local CITIES =
{
    [xi.zone.SOUTHERN_SAN_DORIA] =
    {
        key = 'Slarin', name = 'Slarin', camp = xi.zone.EAST_RONFAURE,
        pos = { 46.5, 1.6, -32.4, 170 }, horro = { 44.22, 1.63, -32.1, 170 }, back = { 45.36, 1.6, -32.25, 170 }, where = 'next to Home Point #2 (a short walk east of the Auction House)',
    },
    [xi.zone.BASTOK_MARKETS] =
    {
        key = 'Sludge', name = 'Sludge', camp = xi.zone.SOUTH_GUSTABERG,
        pos = { -290.79, -10.4, -102.54, 160 }, horro = { -292.29, -10.4, -105.14, 160 }, back = { -291.54, -10.4, -103.84, 160 }, where = 'by the Home Point at the south end',
    },
    [xi.zone.WINDURST_WOODS] =
    {
        key = 'UltraSlime', name = 'Ultra Slime', camp = xi.zone.EAST_SARUTABARUTA,
        pos = { -42.0, -0.28, -142.4, 0 }, horro = { -44.28, -0.24, -142.1, 0 }, back = { -43.14, -0.26, -142.25, 0 }, where = 'by the Home Point at the south end',
    },
}

local CAMPS =
{
    [xi.zone.EAST_RONFAURE]     = { key = 'Slabble',    name = 'Slabble',     home = xi.zone.SOUTHERN_SAN_DORIA, arrive = { 86.131, -62.1, 273.861, 25 }, npc = { 88.63, -62.1, 273.86, 25 } },
    [xi.zone.SOUTH_GUSTABERG]   = { key = 'SlimeTarou', name = 'Slime Tarou', home = xi.zone.BASTOK_MARKETS,     arrive = { 579.0, 0.6, -305.0, 62 }, npc = { 581.0, 0.6, -303.0, 62 } },
    [xi.zone.EAST_SARUTABARUTA] = { key = 'Sline',      name = 'Sline',       home = xi.zone.WINDURST_WOODS,     arrive = { -125.0, -4.1, -519.0, 4 }, npc = { -122.5, -4.1, -519.0, 4 } },
}

local HORRO_LINES =
{
    "Ah, a fellow traveler! I'm Horro. I sailed the Astoltia Ark all the way here for Vana'diel's treats.",
    'My slimes came with me, all proper and permitted. Their cousins, the she-slimes and metal slimes... snuck aboard.',
    "If you'd round up the stowaways, my slimes will pay you in slime coins. They're terribly proud of their gear.",
    'Have you tried the pastries in this town? I bought three dozen. For research.',
}

-----------------------------------
-- State
-----------------------------------
local state =
{
    active = nil,     -- last applied on/off
    npcs   = {},      -- [zoneId] = { npc ids }
    camps  = {},      -- [zoneId] = { npc = id, points = {...}, mobs = { [id] = rec } }
    serial = 0,
}

local function eventsMode()
    if xi.eventsMode and xi.eventsMode.get then
        return xi.eventsMode.get()
    end

    package.loaded['modules/custom/lua/events_config'] = nil
    local ok, cfg = pcall(require, 'modules/custom/lua/events_config')
    return ok and type(cfg) == 'table' and cfg.mode or 'date'
end

local function isActive()
    local mode = eventsMode()
    if mode == 'off' or (xi.eventsMode and xi.eventsMode.allowed and not xi.eventsMode.allowed('horro')) then
        return false
    elseif mode == 'on' then
        return true
    end

    local today = tonumber(os.date('%Y%m%d')) or 0
    for _, d in ipairs(DATES) do
        if today >= d.start and today <= d.finish then
            return true
        end
    end

    return false
end

local channel = function(name)
    return (xi.msg and xi.msg.channel and xi.msg.channel[name]) or 0
end

local function say(player, who, text)
    player:printToPlayer(text, channel('NS_SAY'), who)
end

local function sys(player, text)
    player:printToPlayer(text, channel('SYSTEM_3'))
end

local function coins(player)
    return player:getCharVar('Horro_Coins')
end

local function isGooed(player)
    return player:getCharVar('Horro_Goo') == 1 and player:hasStatusEffect(xi.effect.LEVEL_RESTRICTION)
end

local function unGoo(player)
    if player:getCharVar('Horro_Goo') == 1 then
        player:setCharVar('Horro_Goo', 0)
        if player:hasStatusEffect(xi.effect.LEVEL_RESTRICTION) then
            player:delStatusEffect(xi.effect.LEVEL_RESTRICTION)
        end
    end
end

local function wearsFullSet(player)
    local head = player:getEquipID(xi.slot.HEAD)
    local sub  = player:getEquipID(xi.slot.SUB)
    local ear1 = player:getEquipID(xi.slot.EAR1)
    local ear2 = player:getEquipID(xi.slot.EAR2)
    for _, set in ipairs(SETS) do
        if head == set.head and sub == set.sub and (ear1 == set.ear or ear2 == set.ear) then
            return true
        end
    end

    return false
end

local function owns(player, id)
    local ok, has = pcall(function()
        return player:hasItem(id)
    end)
    return ok and has
end

-----------------------------------
-- Menus
-----------------------------------
local function sendMenu(player, menu)
    player:timer(50, function(p)
        p:customMenu(menu)
    end)
end

local shopPage -- forward

local function buy(player, who, entry)
    local have = coins(player)
    if entry.needs == 'she' and player:getCharVar('Horro_She') == 0 then
        say(player, who, 'Catch a She-Slime first, then I can sell you that!')
        return
    elseif entry.needs == 'metal' and player:getCharVar('Horro_Metal') == 0 then
        say(player, who, 'Catch a Metal Slime first, then I can sell you that!')
        return
    end

    if not entry.candy and owns(player, entry.id) then
        say(player, who, 'You already have a ' .. entry.name .. '!')
        return
    end

    if have < entry.cost then
        say(player, who, string.format('That one is %d slime coins. You have %d.', entry.cost, have))
        return
    end

    if player:getFreeSlotsCount() < 1 then
        say(player, who, 'Your bags are full! Make some room first.')
        return
    end

    if npcUtil.giveItem(player, entry.id) then
        player:setCharVar('Horro_Coins', have - entry.cost)
        say(player, who, string.format('Here you go! (%d slime coins left)', have - entry.cost))
    end
end

-- (2026-11-19, Bob Roberts) A menu travels in one chat packet: past about 150 characters the last choices are cut
-- off, and "(owned)" on a few lines was enough to lose "More...", so the later pages could not be reached. Pages are
-- now filled by length (MENU_ROOM characters for the title and every choice in quotes), not by a fixed count.
local MENU_ROOM = 125

shopPage = function(player, who, first)
    first = first or 1

    local title   = string.format('Slime coins: %d', coins(player))
    local used    = #title + 2
    local nav     = #'Back to the start' + 2
    local options = {}
    local last    = first - 1
    for i = first, #SHOP do
        local entry = SHOP[i]
        local tag   = ''
        if entry.needs == 'she' and player:getCharVar('Horro_She') == 0 then
            tag = ' (catch a She-Slime)'
        elseif entry.needs == 'metal' and player:getCharVar('Horro_Metal') == 0 then
            tag = ' (catch a Metal Slime)'
        elseif not entry.candy and owns(player, entry.id) then
            tag = ' (owned)'
        end

        local label = string.format('%s: %d%s', entry.name, entry.cost, tag)
        if #options > 0 and used + #label + 2 + nav > MENU_ROOM then
            break
        end

        used = used + #label + 2
        last = i
        table.insert(options, { label, function(p)
            buy(p, who, entry)
        end })
    end

    if last < #SHOP then
        table.insert(options, { 'More...', function(p)
            shopPage(p, who, last + 1)
        end })
    elseif first > 1 then
        table.insert(options, { 'Back to the start', function(p)
            shopPage(p, who, 1)
        end })
    end

    sendMenu(player, { title = title, options = options })
end

local function explain(player, who)
    say(player, who, "I'll send you to our camp outside town. My friend there will goo you up, so you'll be level 1.")
    say(player, who, 'Catch slimes for slime coins: Slime 1, She-Slime 2, Metal Slime 10! Earth magic works well on us.')
    say(player, who, 'Metal Slimes take hits badly but dodge a lot and run away fast. Wear a full slime set for +1 coin a catch!')
end

-- First visit: a Crystal Boy and the first Dragonland part, once per character. If the bags are full it is offered
-- again next time instead of being lost.
local function welcomeGift(player, who)
    if player:getCharVar('Horro_CB') ~= 0 then
        return
    end

    if player:getFreeSlotsCount() < 2 then
        say(player, who, 'Splish! I have a present for you, but your bags are full. Make room for two things and ask me again.')
        return
    end

    if npcUtil.giveItem(player, { CRYSTAL_BOY, DRAGONLAND[1].id }) then
        player:setCharVar('Horro_CB', 1)
        say(player, who, 'Splish! Take these: a Crystal Boy, and a Recollection that came all the way from Dragonland.')
        sys(player, 'The other four parts of Dragonland are prizes: 15 slime coins each, from this slime.')
    end
end

local function onTownSlime(player, npc)
    local city = CITIES[player:getZoneID()]
    if not city or not isActive() then
        return
    end

    local who  = npc:getPacketName()
    welcomeGift(player, who)
    local camp = CAMPS[city.camp]
    sendMenu(player,
    {
        title   = string.format('Slime hunting? (coins: %d)', coins(player)),
        options =
        {
            { 'Take me to the slime camp!', function(p)
                say(p, who, 'Off you go! Talk to ' .. camp.name .. ' when you get there.')
                local a = camp.arrive
                p:setPos(a[1], a[2], a[3], a[4], city.camp)
            end },
            { 'Trade slime coins', function(p)
                shopPage(p, who, 1)
            end },
            { 'How does this work?', function(p)
                explain(p, who)
            end },
            { 'Never mind', function(p)
            end },
        },
    })
end

local function onCampSlime(player, npc)
    local camp = CAMPS[player:getZoneID()]
    if not camp or not isActive() then
        return
    end

    local who  = npc:getPacketName()
    local city = CITIES[camp.home]
    local options = {}
    if not isGooed(player) then
        table.insert(options, { 'Goo me up!', function(p)
            if p:hasStatusEffect(xi.effect.LEVEL_RESTRICTION) then
                p:delStatusEffect(xi.effect.LEVEL_RESTRICTION)
            end

            -- (2026-11-19) this server's addStatusEffect takes a table; the old positional call failed, so nobody was gooed
            p:addStatusEffect(xi.effect.LEVEL_RESTRICTION, { origin = p, power = 1, duration = GOO_SECONDS })
            p:setCharVar('Horro_Goo', 1)
            say(p, who, 'Splish! Now you can catch slimes. Come back to me when you want to go home.')
        end })
    end

    table.insert(options, { 'Take me back to town', function(p)
        unGoo(p)
        local pos = city.back or city.pos
        p:setPos(pos[1], pos[2], pos[3], pos[4], camp.home)
    end })
    table.insert(options, { 'Never mind', function(p)
    end })

    sendMenu(player, { title = string.format('Slime coins: %d', coins(player)), options = options })
end

local function onHorro(player, npc)
    if not isActive() then
        return
    end

    local n = player:getCharVar('Horro_Talk') % #HORRO_LINES + 1
    player:setCharVar('Horro_Talk', n)
    say(player, npc:getPacketName(), HORRO_LINES[n])
end

-----------------------------------
-- Slimes
-----------------------------------
local spawnSlime -- forward

local function nearbyPlayers(mob, fn)
    local zone = mob:getZone()
    if not zone then
        return
    end

    for _, p in pairs(zone:getPlayers()) do
        if p:checkDistance(mob) <= AWARD_RANGE then
            fn(p)
        end
    end
end

local function campPoints(zone, camp)
    local a, pts = camp.arrive, {}
    local own = state.camps[zone:getID()] and state.camps[zone:getID()].mobs or {}
    for _, mob in pairs(zone:getMobs() or {}) do
        if not own[mob:getID()] then
            local x, y, z = mob:getXPos(), mob:getYPos(), mob:getZPos()
            local d = math.sqrt((x - a[1]) ^ 2 + (z - a[3]) ^ 2)
            if d > 10 and d < 110 then
                table.insert(pts, { x = x, y = y, z = z })
            end
        end
    end

    if #pts < 4 then
        for i = 1, 24 do
            local ang = (i / 24) * 2 * math.pi
            local r   = 12 + (i % 4) * 6
            local p   = { x = a[1] + r * math.cos(ang), y = a[2], z = a[3] + r * math.sin(ang) }
            if zone:isNavigablePoint(p) then
                table.insert(pts, p)
            end
        end
    end

    if #pts == 0 then
        table.insert(pts, { x = a[1] + 8, y = a[2], z = a[3] + 8 })
    end

    return pts
end

local function scheduleRespawn(zoneId, kind)
    local camp = state.camps[zoneId]
    local npc  = camp and GetNPCByID(camp.npc)
    if not npc or kind == 'metal' then
        return
    end

    npc:timer(RESPAWN_MS, function()
        if state.active then
            spawnSlime(zoneId, kind)
        end
    end)
end

local function gone(rec)
    if rec.gone then
        return false
    end

    rec.gone = true
    state.camps[rec.zone].mobs[rec.id] = nil
    scheduleRespawn(rec.zone, rec.kind)
    return true
end

-- (2026-11-19, Bob Roberts: "a slime can run away even if I defeat it") a slime that decided to run was marked as gone
-- at once and left 0.2 s later; a hit that defeated it in between (the same attack round, a squad mate) then counted
-- for nothing. Now it only counts as run away when it is still alive at that moment; defeated first = caught.
local function flee(mob, rec, text)
    if rec.gone or rec.fleeing then
        return
    end

    rec.fleeing = true
    mob:timer(200, function(mb)
        rec.fleeing = nil
        if rec.gone or not mb:isAlive() then
            return
        end

        if not gone(rec) then
            return
        end

        nearbyPlayers(mb, function(p)
            sys(p, text or ('The ' .. KIND[rec.kind].label .. ' ran away!'))
        end)
        DespawnMob(mb:getID())
    end)
end

local function onCaught(mob, rec)
    if not gone(rec) then
        return
    end

    if rec.spoiled then
        nearbyPlayers(mob, function(p)
            sys(p, 'The ' .. KIND[rec.kind].label .. ' got away: someone who is not gooed up hit it (bot players too). Only gooed-up adventurers and their squad mates can catch slimes.')
        end)
        return
    end

    local kind = KIND[rec.kind]
    nearbyPlayers(mob, function(p)
        if isGooed(p) then
            local n = kind.coins + (wearsFullSet(p) and 1 or 0)
            p:setCharVar('Horro_Coins', coins(p) + n)
            sys(p, string.format('You caught a %s! +%d slime coin%s (%d total).', kind.label, n, n == 1 and '' or 's', coins(p)))
            if rec.kind == 'she' and p:getCharVar('Horro_She') == 0 then
                p:setCharVar('Horro_She', 1)
                sys(p, 'She-slime gear is now for sale at the town slime!')
            elseif rec.kind == 'metal' and p:getCharVar('Horro_Metal') == 0 then
                p:setCharVar('Horro_Metal', 1)
                sys(p, 'Metal slime gear is now for sale at the town slime!')
            end
        end
    end)

    local chance = METAL_CHANCE[rec.kind]
    if chance and math.random() < chance then
        local x, y, z = mob:getXPos(), mob:getYPos(), mob:getZPos()
        local zoneId  = rec.zone
        local npc     = GetNPCByID(state.camps[zoneId].npc)
        if npc then
            npc:timer(1500, function()
                if state.active then
                    local metal = spawnSlime(zoneId, 'metal', { x = x + 1.5, y = y, z = z + 1.5 })
                    if metal then
                        nearbyPlayers(metal, function(p)
                            sys(p, 'A Metal Slime appears!')
                        end)
                    end
                end
            end)
        end
    end
end

spawnSlime = function(zoneId, kind, at)
    local camp = state.camps[zoneId]
    local zone = GetZone(zoneId)
    if not camp or not zone then
        return nil
    end

    if not at then
        local p = camp.points[math.random(1, #camp.points)]
        at = { x = p.x + math.random(-3, 3), y = p.y, z = p.z + math.random(-3, 3) }
    end

    local info = KIND[kind]
    state.serial = state.serial + 1
    local mob = zone:insertDynamicEntity({
        objtype              = xi.objType.MOB,
        name                 = 'HorroSlime' .. state.serial,
        packetName           = info.label,
        x                    = at.x,
        y                    = at.y,
        z                    = at.z,
        rotation             = math.random(0, 255),
        look                 = LOOK[kind],
        groupId              = MOB_GROUP.id,
        groupZoneId          = MOB_GROUP.zone,
        minLevel             = info.level,
        maxLevel             = info.level,
        releaseIdOnDisappear = true,
    })
    if not mob then
        return nil
    end

    mob:setSpawn(at.x, at.y, at.z, 0)
    mob:setMobMod(xi.mobMod.NO_DROPS, 1)
    mob:setMobMod(xi.mobMod.NO_AGGRO, 1)
    mob:setMobMod(xi.mobMod.NO_LINK, 1)
    mob:spawn()
    DisallowRespawn(mob:getID(), true)
    mob:setMagicCastingEnabled(false)
    mob:setMobAbilityEnabled(false)
    if info.hpp > 0 then
        mob:addMod(xi.mod.HPP, info.hpp)
    end

    if kind == 'metal' then
        mob:setMod(xi.mod.UDMGMAGIC, -10000) -- magic does nothing
        mob:addMod(xi.mod.EVA, 40)
    end

    mob:updateHealth()
    mob:setHP(mob:getMaxHP())

    local rec = { id = mob:getID(), kind = kind, zone = zoneId, hits = 0 }
    camp.mobs[rec.id] = rec

    mob:addListener('TAKE_DAMAGE', 'HORRO_TAKE_DAMAGE', function(mb, amount, attacker, attackType, damageType)
        if rec.gone or not mb:isAlive() then
            return
        end

        if attacker and attacker:getObjType() == xi.objType.PC and not isGooed(attacker) then
            local campSlime = CAMPS[zoneId].name
            sys(attacker, 'Slimes only play with gooed-up adventurers! Talk to ' .. campSlime .. ' first.')
            -- (2026-11-20, Sunie: bot players in the party keep their own level and one-shot the slimes) a slime that a
            -- player or bot player who is not gooed up has hit is never caught, even when that hit defeats it
            rec.spoiled = true
            flee(mb, rec)
            return
        end

        if kind == 'metal' then
            if amount and amount > 0 then
                rec.hits = rec.hits + 1
                if rec.hits >= METAL_HITS - 1 then
                    mb:setHP(1)                -- the next hit that lands catches it
                else
                    mb:setHP(mb:getMaxHP())
                end

                if math.random() < METAL_FLEE_CHANCE then
                    flee(mb, rec)
                end
            end
        elseif mb:getHPP() < 35 and math.random() < FLEE_LOW_HP_CHANCE then
            flee(mb, rec)
        end
    end)

    mob:addListener('DEATH', 'HORRO_DEATH', function(mb, killer)
        onCaught(mb, rec)
    end)

    if kind == 'metal' then
        local npc = GetNPCByID(camp.npc)
        if npc then
            npc:timer(METAL_LIFETIME_MS, function()
                local live = GetMobByID(rec.id)
                if not rec.gone and live and live:isAlive() and live:getHPP() == 100 then
                    flee(live, rec, 'The Metal Slime slipped away...')
                end
            end)
        end
    end

    return mob
end

local function fillCamp(zoneId)
    local camp = state.camps[zoneId]
    local zone = GetZone(zoneId)
    if not camp or not zone then
        return
    end

    camp.points = campPoints(zone, CAMPS[zoneId])
    local have = { slime = 0, she = 0 }
    for _, rec in pairs(camp.mobs) do
        if have[rec.kind] then
            have[rec.kind] = have[rec.kind] + 1
        end
    end

    for _ = have.slime + 1, SLIMES_PER_CAMP do
        spawnSlime(zoneId, 'slime')
    end

    for _ = have.she + 1, SHE_SLIMES_PER_CAMP do
        spawnSlime(zoneId, 'she')
    end
end

local function clearCamp(zoneId)
    local camp = state.camps[zoneId]
    if not camp then
        return
    end

    for id, rec in pairs(camp.mobs) do
        rec.gone = true
        local mob = GetMobByID(id)
        if mob and mob:isAlive() then
            DespawnMob(id)
        end
    end

    camp.mobs = {}
end

-----------------------------------
-- NPCs
-----------------------------------
local function addNpc(zone, key, name, look, pos, onTrigger)
    local npc = zone:insertDynamicEntity({
        objtype    = xi.objType.NPC,
        name       = 'Horro' .. key,
        packetName = name,
        look       = look,
        x          = pos[1],
        y          = pos[2],
        z          = pos[3],
        rotation   = pos[4] or 0,
        widescan   = 1,
        onTrigger  = onTrigger,
    })
    if npc then
        state.npcs[zone:getID()] = state.npcs[zone:getID()] or {}
        table.insert(state.npcs[zone:getID()], npc:getID())
    end

    return npc
end

local function showNpcs(zoneId, on)
    for _, id in ipairs(state.npcs[zoneId] or {}) do
        local npc = GetNPCByID(id)
        if npc then
            npc:setStatus(on and xi.status.NORMAL or xi.status.DISAPPEAR)
        end
    end
end

local function initCity(zone)
    local city = CITIES[zone:getID()]
    addNpc(zone, city.key, city.name, LOOK.slime, city.pos, onTownSlime)
    addNpc(zone, city.key .. 'Horro', 'Horro', LOOK.horro, city.horro, onHorro)
    showNpcs(zone:getID(), isActive())
end

local function initCamp(zone)
    local zoneId = zone:getID()
    local camp   = CAMPS[zoneId]
    local a      = camp.arrive
    local npc    = addNpc(zone, camp.key, camp.name, LOOK.slime, camp.npc or { a[1] + 2.0, a[2], a[3] + 2.0, a[4] }, onCampSlime)
    state.camps[zoneId] = { npc = npc and npc:getID(), points = {}, mobs = {} }
    local on = isActive()
    showNpcs(zoneId, on)
    if on and npc then
        npc:timer(5000, function()          -- let the zone's own mobs spawn first (their spots become slime spots)
            if isActive() then
                fillCamp(zoneId)
            end
        end)
    end
end

local function refresh()
    local on = isActive()
    if on == state.active then
        return
    end

    state.active = on
    print('[horros_visit] Horro\'s Visit is ' .. (on and 'on' or 'off'))
    for zoneId in pairs(CITIES) do
        showNpcs(zoneId, on)
    end

    for zoneId in pairs(CAMPS) do
        showNpcs(zoneId, on)
        if on then
            fillCamp(zoneId)
        else
            clearCamp(zoneId)
        end
    end
end

-----------------------------------
-- Hooks
-----------------------------------
for zoneId in pairs(CITIES) do
    local zoneName = ({ [xi.zone.SOUTHERN_SAN_DORIA] = 'Southern_San_dOria', [xi.zone.BASTOK_MARKETS] = 'Bastok_Markets',
                        [xi.zone.WINDURST_WOODS] = 'Windurst_Woods' })[zoneId]
    m:addOverride('xi.zones.' .. zoneName .. '.Zone.onInitialize', function(zone)
        super(zone)
        initCity(zone)
    end)
end

for zoneId in pairs(CAMPS) do
    local zoneName = ({ [xi.zone.EAST_RONFAURE] = 'East_Ronfaure', [xi.zone.SOUTH_GUSTABERG] = 'South_Gustaberg',
                        [xi.zone.EAST_SARUTABARUTA] = 'East_Sarutabaruta' })[zoneId]
    m:addOverride('xi.zones.' .. zoneName .. '.Zone.onInitialize', function(zone)
        super(zone)
        initCamp(zone)
    end)
end

m:addOverride('xi.server.onServerStart', function()
    super()
    state.active = isActive()
    print('[horros_visit] Horro\'s Visit is ' .. (state.active and 'on' or 'off'))
end)

m:addOverride('xi.server.onJSTMidnight', function()
    super()
    refresh()
end)

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    super(player, firstLogin, zoning)
    refresh()

    local zoneId = player:getZoneID()
    if not CAMPS[zoneId] then
        unGoo(player)          -- the goo stays at the camp
    end

    local city = CITIES[zoneId]
    if city and state.active then
        local today = tonumber(os.date('%Y%m%d')) or 0
        if player:getCharVar('Horro_Notice') ~= today then
            player:setCharVar('Horro_Notice', today)
            sys(player, "Horro's Visit is here! Slimes from Dragon Quest X have come to Vana'diel. Find " ..
                city.name .. ' ' .. city.where .. '.')
        end
    end
end)

return m
