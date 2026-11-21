-----------------------------------
-- Sunbreeze Festival (XI: Forever Offline)
-----------------------------------
-- The summer festival, built for this server (the server has no Sunbreeze of its own). Written from the retail
-- event guides (bg-wiki.com) and the shape of HorizonXI's goldfish points (horizonffxi.wiki); no code is copied.
--
--  * Swimwear moogles (Northern San d'Oria, Bastok Mines, Windurst Waters): every swimsuit in the era item files,
--    5,000 gil each, +1 versions 7,500 (retail Sunbreeze prices). Pick a catalog from the menu.
--  * Summer goods moogles (same three cities): the yukata at retail prices, plus fireworks and snow cones.
--  * Goldfish scooping: Saradorial (West Ronfaure), Fish Eyes (South Gustaberg), Kesha Shopehllok (East
--    Sarutabaruta) and Mei (Rabao). Get a free Goldfish Basket, buy Super Scoops (100 gil), scoop, then trade the
--    fish back for points and spend them on fireworks, coloured drops, swimsuits and yukata.
--
-- Runs in August (Japan time), or as the launcher's Seasonal events setting says (events_mode.lua: By date /
-- Always on / Off), and never while its Sunbreeze Festival switch is off.
--
-- NOT FROM RETAIL CAPTURES: the server has no goldfish-scooping minigame (its fishing code only has the message
-- ids), so scooping here is a menu with dice rolls, not the real fishing window. Dialogue is our own text, and the
-- moogles are new NPCs placed beside the Starlight stalls. Check it all in game.
-----------------------------------
require('modules/module_utils')

local m = Module:new('sunbreeze')

xi = xi or {}
xi.sunbreeze = xi.sunbreeze or {}

local ZONE = xi.zone

local ITEM =
{
    SUPER_SCOOP     = 17003,
    GOLDFISH_BASKET = 17013,
}

-----------------------------------
-- Stock
-----------------------------------
local NQ   = 5000
local HQ   = 7500

local CATALOGS =
{
    {
        label = 'Race swimwear',
        stock =
        {
            { 14450, NQ }, { 14451, NQ }, { 15408, NQ }, { 15409, NQ }, -- Hume gilet/top, trunks/shorts
            { 14452, NQ }, { 14453, NQ }, { 15410, NQ }, { 15411, NQ }, -- Elvaan
            { 14454, NQ }, { 14471, NQ }, { 15412, NQ }, { 15423, NQ }, -- Tarutaru maillot/top, trunks/shorts
            { 14455, NQ }, { 15413, NQ },                               -- Mithra
            { 14456, NQ }, { 15414, NQ },                               -- Galka
        },
    },
    {
        label = 'Race swimwear +1',
        stock =
        {
            { 14457, HQ }, { 14458, HQ }, { 15415, HQ }, { 15416, HQ },
            { 14459, HQ }, { 14460, HQ }, { 15417, HQ }, { 15418, HQ },
            { 14461, HQ }, { 14472, HQ }, { 15419, HQ }, { 15424, HQ },
            { 14462, HQ }, { 15420, HQ },
            { 14463, HQ }, { 15421, HQ },
        },
    },
    {
        label = 'Custom, Magna, Wonder, Savage, Elder',
        stock =
        {
            { 11265, NQ }, { 11266, NQ }, { 16321, NQ }, { 16322, NQ }, -- Custom (Hume)
            { 11267, NQ }, { 11268, NQ }, { 16323, NQ }, { 16324, NQ }, -- Magna (Elvaan)
            { 11269, NQ }, { 11270, NQ }, { 16325, NQ }, { 16326, NQ }, -- Wonder (Tarutaru)
            { 11271, NQ }, { 16327, NQ },                               -- Savage (Mithra)
            { 11272, NQ }, { 16328, NQ },                               -- Elder (Galka)
        },
    },
    {
        label = 'Custom, Magna, Wonder, Savage, Elder +1',
        stock =
        {
            { 11273, HQ }, { 11274, HQ }, { 16329, HQ }, { 16330, HQ },
            { 11275, HQ }, { 11276, HQ }, { 16331, HQ }, { 16332, HQ },
            { 11277, HQ }, { 11278, HQ }, { 16333, HQ }, { 16334, HQ },
            { 11279, HQ }, { 16335, HQ },
            { 11280, HQ }, { 16336, HQ },
        },
    },
    {
        label = 'Marine, Woodsy, Creek, River, Dune',
        stock =
        {
            { 10256, NQ }, { 10257, NQ }, { 10331, NQ }, -- Marine (Hume)
            { 10258, NQ }, { 10259, NQ }, { 10333, NQ }, -- Woodsy (Elvaan)
            { 10260, NQ }, { 10261, NQ }, { 10335, NQ }, -- Creek (Tarutaru)
            { 10262, NQ }, { 10336, NQ },                -- River (Mithra)
            { 10263, NQ },                               -- Dune (Galka)
        },
    },
    {
        label = 'Marine, Woodsy, Creek, River, Dune +1',
        stock =
        {
            { 10264, HQ }, { 10265, HQ }, { 10339, HQ },
            { 10266, HQ }, { 10267, HQ }, { 10341, HQ },
            { 10268, HQ }, { 10269, HQ }, { 10343, HQ },
            { 10270, HQ }, { 10344, HQ },
            { 10271, HQ },
        },
    },
}

local YUKATA =
{
    { 13819, 2500 },  { 13820, 2500 },  -- Onoko / Omina
    { 13821, 3750 },  { 13822, 3750 },  -- Lord's / Lady's
    { 14532, 5000 },  { 14533, 5000 },  -- Otoko / Onago
    { 14534, 7500 },  { 14535, 7500 },  -- Otokogimi / Onnagimi
    { 11316, 10000 }, { 11317, 10000 }, -- Otokogusa / Onnagusa
    { 11318, 12500 }, { 11319, 12500 }, -- Otokoeshi / Ominaeshi
    { 11861, 15000 }, { 11862, 15000 }, -- Hikogami / Himegami
}

local GOODS =
{
    { 5882, 125 }, { 5883, 125 }, { 5881, 125 },  -- Marine Bliss, Falling Star, Shisai Kaboku
    { 4184, 50 },  { 4256, 50 },  { 5937, 50 },   -- Kongou Inaho, Ouka Ranman, Bubble Breeze
    { 5360, 150 }, { 5725, 300 },                 -- Muteppo, Goshikitenge
    { 5710, 200 }, { 5711, 200 }, { 5712, 200 }, { 5713, 200 }, -- snow cones
}

-- Two moogles per city, beside the (December-only) Starlight stalls: [1] swimwear, [2] summer goods
local MOOGLES =
{
    [ZONE.NORTHERN_SAN_DORIA] = { { -230.346, 7.999, 80.698, 64 }, { -227.346, 7.999, 80.698, 64 } },
    [ZONE.BASTOK_MINES]       = { { -39.500, 0.000, -88.000, 0 },  { -39.500, 0.000, -85.000, 0 } },
    [ZONE.WINDURST_WATERS]    = { { -12.140, -1.000, 19.609, 0 },  { -12.140, -1.000, 22.609, 0 } },
}

local MOOGLE_MODEL = 82 -- the Starlight moogles' model

-----------------------------------
-- Goldfish
-----------------------------------
-- The retail goldfish stall keepers (zone data, no scripts of their own)
local STALLS =
{
    [ZONE.WEST_RONFAURE]     = 'Saradorial',
    [ZONE.SOUTH_GUSTABERG]   = 'Fish_Eyes',
    [ZONE.EAST_SARUTABARUTA] = 'Kesha_Shopehllok',
    [ZONE.RABAO]             = 'Mei',
}

local STALL_IDS =
{
    [ZONE.WEST_RONFAURE]     = 17187570,
    [ZONE.SOUTH_GUSTABERG]   = 17216210,
    [ZONE.EAST_SARUTABARUTA] = 17253106,
    [ZONE.RABAO]             = 17789025,
}

-- weight = how often it swims up, catch = chance to land it, rip = extra chance the paper tears, points = trade-in value
local FISH =
{
    { id = 4310, name = 'Tiny Goldfish',    weight = 60, catch = 70, rip = 0,  points = 1,  line = 'A tiny goldfish approaches!' },
    { id = 4311, name = 'Black Bubble-Eye', weight = 25, catch = 55, rip = 5,  points = 2,  line = 'A plump, black goldfish approaches!' },
    { id = 4312, name = 'Lionhead',         weight = 10, catch = 40, rip = 10, points = 10, line = 'A fat, juicy goldfish approaches!' },
    { id = 5714, name = 'Pearlscale',       weight = 3,  catch = 30, rip = 15, points = 30, line = 'A shimmering goldfish approaches!' },
    { id = 5715, name = 'Calico Comet',     weight = 2,  catch = 30, rip = 15, points = 30, line = 'A speckled goldfish darts past!' },
}

local FISH_BY_ID = {}
for _, f in ipairs(FISH) do
    FISH_BY_ID[f.id] = f
end

local NO_FISH = 15  -- % of scoops where nothing comes near
local RIP     = 20  -- % base chance a scoop's paper tears after a try

-- Point rewards: { label, cost, items (one is chosen at random, or the player picks for 'pick') }
local REWARDS =
{
    { label = 'Super Scoop',                   cost = 5,  items = { ITEM.SUPER_SCOOP } },
    { label = 'Summer fireworks',              cost = 15, items = { 4184, 4256, 5937, 5360 }, random = true },
    { label = 'Festival fireworks',            cost = 25, items = { 5882, 5883, 5881, 5725 }, random = true },
    { label = 'Coloured drop',                 cost = 30, items = { 4258, 4259, 4260, 4261, 4262, 4263, 4264, 4265 }, random = true },
    { label = 'Swimsuit of my choice (NQ)',    cost = 60, pick = 'swim' },
    { label = 'Yukata of my choice',           cost = 80, pick = 'yukata' },
}

-----------------------------------
-- Helpers
-----------------------------------
local state =
{
    active  = nil,
    moogles = {}, -- [zoneId] = { npcId, npcId }
    shown   = {}, -- [npcId] = true for stall keepers this module made visible
}

local channel = function(name, fallback)
    return (xi.msg and xi.msg.channel and xi.msg.channel[name]) or fallback
end

local SAY = channel('NS_SAY', 13)
local SYS = channel('SYSTEM_3', 29)

local function say(player, npc, text)
    player:printToPlayer(text, SAY, type(npc) == 'string' and npc or npc:getPacketName())
end

local function sys(player, text)
    player:printToPlayer(text, SYS)
end

local function sendMenu(player, menu)
    player:timer(50, function(p)
        p:customMenu(menu)
    end)
end

local function openShop(player, stock)
    player:timer(50, function(p)
        xi.shop.general(p, stock)
    end)
end

local function isActive()
    local mode = (xi.eventsMode and xi.eventsMode.get) and xi.eventsMode.get() or 'date'
    if mode == 'off' or (xi.eventsMode and xi.eventsMode.allowed and not xi.eventsMode.allowed('sunbreeze')) then
        return false
    elseif mode == 'on' then
        return true
    end

    return JstMonth() == 8
end

xi.sunbreeze.isActive = isActive

local function itemName(id)
    local item = GetReadOnlyItem and GetReadOnlyItem(id)
    if item and item.getName then
        return (string.gsub(item:getName(), '_', ' '))
    end

    return 'item ' .. id
end

-- Points belong to one summer: a new year starts from zero
local function points(player)
    local year = tonumber(os.date('%Y')) or 0
    if player:getCharVar('[Sunbreeze]Year') ~= year then
        player:setCharVar('[Sunbreeze]Year', year)
        player:setCharVar('[Sunbreeze]Points', 0)
    end

    return player:getCharVar('[Sunbreeze]Points')
end

local function addPoints(player, n)
    player:setCharVar('[Sunbreeze]Points', points(player) + n)
end

-----------------------------------
-- Moogles
-----------------------------------
local function swimMoogle(player, npc)
    say(player, npc, 'Welcome to the Sunbreeze Festival, kupo! Swimwear for every adventurer!')
    local options = {}
    for _, cat in ipairs(CATALOGS) do
        table.insert(options, { cat.label, function(p)
            openShop(p, cat.stock)
        end })
    end

    table.insert(options, { 'Never mind', function(p)
    end })
    sendMenu(player, { title = 'Swimwear (choose a catalog)', options = options })
end

local function goodsMoogle(player, npc)
    say(player, npc, 'Kupo! Yukata for the festival, and fireworks for the night!')
    sendMenu(player,
    {
        title   = 'Summer goods',
        options =
        {
            { 'Yukata', function(p)
                openShop(p, YUKATA)
            end },
            { 'Fireworks and snow cones', function(p)
                openShop(p, GOODS)
            end },
            { 'Never mind', function(p)
            end },
        },
    })
end

local function spawnMoogles(zone)
    local zoneId = zone:getID()
    local spots  = MOOGLES[zoneId]
    if not spots then
        return
    end

    if state.moogles[zoneId] then
        return
    end

    local ids = {}
    for i, pos in ipairs(spots) do
        local npc = zone:insertDynamicEntity({
            objtype    = xi.objType.NPC,
            name       = 'SunbreezeMoogle' .. i,
            packetName = 'Moogle',
            look       = MOOGLE_MODEL,
            x          = pos[1],
            y          = pos[2],
            z          = pos[3],
            rotation   = pos[4],
            widescan   = 1,
            onTrigger  = function(player, n)
                if not state.active then
                    return
                end

                local ok, err = pcall(i == 1 and swimMoogle or goodsMoogle, player, n)
                if not ok then
                    print('[sunbreeze] ' .. tostring(err))
                end
            end,
        })
        if npc then
            table.insert(ids, npc:getID())
        end
    end

    state.moogles[zoneId] = ids
end

-----------------------------------
-- Goldfish scooping
-----------------------------------
local stallTrigger

local function rollFish()
    local total = 0
    for _, f in ipairs(FISH) do
        total = total + f.weight
    end

    local r = math.random(1, total)
    for _, f in ipairs(FISH) do
        r = r - f.weight
        if r <= 0 then
            return f
        end
    end

    return FISH[1]
end

local function scoop(player, npc)
    if not player:hasItem(ITEM.GOLDFISH_BASKET) then
        say(player, npc, "You'll need a Goldfish Basket to keep your catch in. I'll give you one for free!")
        return
    end

    if not player:hasItem(ITEM.SUPER_SCOOP, xi.inv.INVENTORY) then
        say(player, npc, "You're out of Super Scoops! I sell them for 100 gil.")
        return
    end

    local fish = nil
    if math.random(1, 100) > NO_FISH then
        fish = rollFish()
    end

    if not fish then
        sys(player, 'There are no goldfish to be found...')
    else
        sys(player, fish.line)
        if math.random(1, 100) <= fish.catch then
            if player:getFreeSlotsCount() < 1 then
                sys(player, 'You caught a ' .. fish.name .. ', but cannot carry any more items. You regretfully release it.')
            else
                npcUtil.giveItem(player, fish.id)
            end
        else
            sys(player, 'The goldfish slipped off your scoop...')
        end
    end

    if math.random(1, 100) <= RIP + (fish and fish.rip or 0) then
        player:delItem(ITEM.SUPER_SCOOP, 1, xi.inv.INVENTORY)
        sys(player, 'The paper on your Super Scoop ripped.')
    end

    -- straight back to the pond menu, so scooping is one click per try
    stallTrigger(player, npc, true)
end

local function pickMenu(player, npc, reward, page)
    local list = {}
    if reward.pick == 'yukata' then
        for _, e in ipairs(YUKATA) do
            table.insert(list, e[1])
        end
    else
        -- the three NQ catalogs, one page each (menus stay short)
        local cat = CATALOGS[({ 1, 3, 5 })[page]]
        for _, e in ipairs(cat.stock) do
            table.insert(list, e[1])
        end
    end

    -- keep menus to eight entries: show the list in chunks
    local CHUNK = 7
    local chunks = math.ceil(#list / CHUNK)
    local function show(p, c)
        local options = {}
        for i = (c - 1) * CHUNK + 1, math.min(#list, c * CHUNK) do
            local id = list[i]
            table.insert(options, { itemName(id), function(pp)
                if points(pp) < reward.cost then
                    say(pp, npc, "You don't have enough points for that.")
                    return
                end

                if npcUtil.giveItem(pp, id) then
                    addPoints(pp, -reward.cost)
                    say(pp, npc, 'Enjoy the summer! You have ' .. points(pp) .. ' points left.')
                end
            end })
        end

        if c < chunks then
            table.insert(options, { 'More...', function(pp)
                show(pp, c + 1)
            end })
        elseif reward.pick == 'swim' and page < 3 then
            table.insert(options, { 'Other swimsuit sets...', function(pp)
                pickMenu(pp, npc, reward, page + 1)
            end })
        end

        sendMenu(p, { title = reward.label .. ' (' .. reward.cost .. ' points)', options = options })
    end

    show(player, 1)
end

local function rewardMenu(player, npc)
    local have    = points(player)
    local options = {}
    for _, r in ipairs(REWARDS) do
        table.insert(options, { r.label .. ' (' .. r.cost .. ')', function(p)
            if points(p) < r.cost then
                say(p, npc, 'That takes ' .. r.cost .. ' points, and you have ' .. points(p) .. '. Keep scooping!')
                return
            end

            if r.pick then
                pickMenu(p, npc, r, 1)
                return
            end

            local id = r.items[math.random(1, #r.items)]
            if npcUtil.giveItem(p, id) then
                addPoints(p, -r.cost)
                say(p, npc, 'Here you go! You have ' .. points(p) .. ' points left.')
            end
        end })
    end

    table.insert(options, { 'Never mind', function(p)
    end })
    sendMenu(player, { title = 'Spend points (you have ' .. have .. ')', options = options })
end

stallTrigger = function(player, npc, again)
    if not again then
        say(player, npc, 'Sunbreeze greetings! Care to try your hand at goldfish scooping?')
    end

    local options = {}
    local scoops  = player:getItemCount(ITEM.SUPER_SCOOP)

    if player:hasItem(ITEM.GOLDFISH_BASKET) and scoops > 0 then
        table.insert(options, { 'Scoop! (' .. scoops .. ' Super Scoop' .. (scoops == 1 and '' or 's') .. ' left)', function(p)
            scoop(p, npc)
        end })
    end

    if not player:hasItem(ITEM.GOLDFISH_BASKET) then
        table.insert(options, { "I'd like a bowl (Goldfish Basket)", function(p)
            if npcUtil.giveItem(p, ITEM.GOLDFISH_BASKET) then
                say(p, npc, 'Here you are! Now you just need a Super Scoop or two.')
            end
        end })
    end

    table.insert(options, { 'Buy Super Scoops (100 gil)', function(p)
        openShop(p, { { ITEM.SUPER_SCOOP, 100 } })
    end })
    table.insert(options, { 'Spend points (' .. points(player) .. ')', function(p)
        rewardMenu(p, npc)
    end })
    table.insert(options, { 'How does this work?', function(p)
        say(p, npc, 'Pick "Scoop!" to dip your Super Scoop in the pond. The paper rips sooner or later, so bring a few.')
        say(p, npc, 'Trade me your goldfish for points: Tiny Goldfish 1, Black Bubble-Eye 2, Lionhead 10, Pearlscale and Calico Comet 30.')
        say(p, npc, 'Points buy fireworks, coloured drops, a swimsuit (60) or a yukata (80). They last until the end of the summer.')
    end })
    table.insert(options, { 'Never mind', function(p)
    end })

    sendMenu(player, { title = 'Goldfish scooping (' .. points(player) .. ' points)', options = options })
    return true
end

local function stallTrade(player, npc, trade)
    local total, count = 0, 0
    for id, f in pairs(FISH_BY_ID) do
        local qty = trade:getItemQty(id)
        if qty > 0 then
            total = total + qty * f.points
            count = count + qty
        end
    end

    if count == 0 then
        return false
    end

    if count ~= trade:getItemCount() then
        say(player, npc, 'Just the goldfish, please!')
        return true
    end

    player:tradeComplete()
    addPoints(player, total)
    say(player, npc, 'What a catch! That is ' .. total .. ' point' .. (total == 1 and '' or 's') .. '. You have ' .. points(player) .. ' now.')
    return true
end

-----------------------------------
-- Hooks
-----------------------------------
local function isStall(npc)
    local name = STALLS[npc:getZoneID()]
    return name ~= nil and npc:getName() == name
end

local function run(fn, ...)
    local ok, handled = pcall(fn, ...)
    if not ok then
        print('[sunbreeze] ' .. tostring(handled))
        return false
    end

    return handled == true
end

local function wrapInteraction()
    if type(InteractionGlobal) ~= 'table' or InteractionGlobal.sunbreezeWrapped then
        return
    end

    local originalTrigger = InteractionGlobal.onTrigger
    local originalTrade   = InteractionGlobal.onTrade

    InteractionGlobal.onTrigger = function(player, npc, fallbackFn)
        if state.active and player and npc and isStall(npc) and run(stallTrigger, player, npc) then
            return 0
        end

        return originalTrigger(player, npc, fallbackFn)
    end

    InteractionGlobal.onTrade = function(player, npc, trade, fallbackFn)
        if state.active and player and npc and trade and isStall(npc) and run(stallTrade, player, npc, trade) then
            return
        end

        return originalTrade(player, npc, trade, fallbackFn)
    end

    InteractionGlobal.sunbreezeWrapped = true
end

local ZONE_SCRIPT =
{
    [ZONE.NORTHERN_SAN_DORIA] = 'Northern_San_dOria',
    [ZONE.BASTOK_MINES]       = 'Bastok_Mines',
    [ZONE.WINDURST_WATERS]    = 'Windurst_Waters',
    [ZONE.WEST_RONFAURE]      = 'West_Ronfaure',
    [ZONE.SOUTH_GUSTABERG]    = 'South_Gustaberg',
    [ZONE.EAST_SARUTABARUTA]  = 'East_Sarutabaruta',
    [ZONE.RABAO]              = 'Rabao',
}

local function applyZone(zoneId, on)
    local zone = GetZone(zoneId)
    if not zone then
        return
    end

    local shown, hidden = xi.status.NORMAL, xi.status.DISAPPEAR

    if MOOGLES[zoneId] then
        if on then
            spawnMoogles(zone)
        end

        for _, id in ipairs(state.moogles[zoneId] or {}) do
            local npc = GetNPCByID(id)
            if npc then
                npc:setStatus(on and shown or hidden)
            end
        end
    end

    local stallId = STALL_IDS[zoneId]
    if stallId then
        local npc = GetNPCByID(stallId)
        if npc then
            if on then
                npc:setStatus(shown)
                state.shown[stallId] = true
            elseif state.shown[stallId] then
                npc:setStatus(hidden)
                state.shown[stallId] = nil
            end
        end
    end
end

local function refresh(force)
    local on = isActive()
    if on == state.active and not force then
        return
    end

    state.active = on
    print('[sunbreeze] Sunbreeze Festival is ' .. (on and 'on' or 'off'))
    for zoneId in pairs(ZONE_SCRIPT) do
        applyZone(zoneId, on)
    end
end

wrapInteraction()

for zoneId, zoneName in pairs(ZONE_SCRIPT) do
    m:addOverride('xi.zones.' .. zoneName .. '.Zone.onInitialize', function(zone)
        super(zone)
        if state.active == nil then
            state.active = isActive()
        end

        if state.active then
            applyZone(zoneId, true)
        end
    end)
end

m:addOverride('xi.server.onServerStart', function()
    super()
    wrapInteraction()
    refresh(true)
end)

m:addOverride('xi.server.onJSTMidnight', function()
    super()
    wrapInteraction()
    refresh(false)
end)

local NOTICE_ZONES =
{
    [ZONE.NORTHERN_SAN_DORIA] = true, [ZONE.SOUTHERN_SAN_DORIA] = true, [ZONE.BASTOK_MINES] = true,
    [ZONE.BASTOK_MARKETS] = true, [ZONE.PORT_BASTOK] = true, [ZONE.WINDURST_WATERS] = true,
    [ZONE.WINDURST_WOODS] = true, [ZONE.PORT_WINDURST] = true, [ZONE.PORT_SAN_DORIA] = true,
    [ZONE.RABAO] = true,
}

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    super(player, firstLogin, zoning)
    if not state.active or not NOTICE_ZONES[player:getZoneID()] then
        return
    end

    local day = tonumber(os.date('%Y%m%d')) or 0
    if player:getCharVar('[Sunbreeze]Notice') ~= day then
        player:setCharVar('[Sunbreeze]Notice', day)
        sys(player, "The Sunbreeze Festival is here! Swimwear and yukata moogles are in Northern San d'Oria, Bastok Mines " ..
            'and Windurst Waters. Goldfish scooping: Saradorial (West Ronfaure), Fish Eyes (South Gustaberg), ' ..
            'Kesha Shopehllok (East Sarutabaruta) and Mei (Rabao).')
    end
end)

return m
