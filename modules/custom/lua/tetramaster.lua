-----------------------------------
-- Tetra Master (XI: Forever Offline), v0.2: matches against the computer, tavern card shops, cards from monsters
-- and treasure caskets.
--
-- The server runs every match (rules: tetramaster_rules.lua, computer players: tetramaster_ai.lua); the tetramaster
-- addon draws the board and sends your moves. Card art, sounds and the original addon: Nalfey.
--
--   !tm play [easy|normal|hard]   start a match against the computer (normal if left out)
--   !tm move <hand 1-5> <x 1-4> <y 1-4>
--   !tm pick <n>                  which battle to fight when your card starts more than one
--   !tm quit                      give up the match (no gil)
--   !tm state                     send the whole match again (the addon asks after a reload)
--   !tm cards                     list your cards;  !tm deck <n> <n> <n> <n> <n> picks the 5 you play with
--   !tm buy <n> / !tm sell <card number>   at a tavern card trader (talk to the trader first)
--   !tmgive <card id> [count]     (GM) add cards to your collection, for testing
--   !tmshop add [name] / remove / list   (GM) put a card trader where you stand (or take away the nearest one)
--
-- New players get a free starter deck from Luto Mewrilah (Upper Jeuno), once per character (TM_STARTER).
-- Winning pays gil (no cards change hands for now). Cards are bought from the tavern card traders (40 starter cards,
-- 30 in each shop), dropped by monsters of their family and notorious monsters, and found in treasure caskets.
-- Tiers, prices and drop chances: tetramaster_data.lua; the launcher's multipliers on top (settings/main.lua TM_*). Card traders: tetramaster_shops.lua (written by !tmshop).
--
-- Replies to the addon are lines starting with "tetramaster:" (the addon hides them from the chat log).
-- Cards are saved in character variables starting with TM_ (they travel with the character on a passport):
--   TM_N = how many cards;  TM_A<i> = id + 256 * arrows + 65536 * class (0 P, 1 M, 2 X, 3 A);
--   TM_B<i> = hidden attack + 256 * physical defence + 65536 * magical defence;  TM_D1..TM_D5 = the deck (card numbers)
-----------------------------------
require('modules/module_utils')

local R     = require('modules/custom/lua/tetramaster_rules')
local AI    = require('modules/custom/lua/tetramaster_ai')
local Cards = require('modules/custom/lua/tetramaster_cards')
local D     = require('modules/custom/lua/tetramaster_data')

local m = Module:new('tetramaster')

local CONFIG =
{
    maxCards = D.MAX_CARDS,                                 -- most cards one character can keep
    gil      = { easy = 100, normal = 300, hard = 800 },    -- for a win against the computer
    perfectBonus = 2,                                       -- a perfect game pays this many times as much
}

-- The launcher's sliders (Rules > Tetra Master), written into settings/main.lua: multipliers, 1 = as tetramaster_data.lua
local function rate(key)
    local v = xi.settings and xi.settings.main and tonumber(xi.settings.main[key])
    if v == nil or v < 0 then
        return 1
    end
    return v
end

local function shopPrice(id)
    return math.max(1, math.floor(D.price(id) * rate('TM_PRICE_RATE') + 0.5))
end

local TYPES     = { 'P', 'M', 'X', 'A' }
local TYPE_CODE = { P = 0, M = 1, X = 2, A = 3 }
local LEVELS    = { easy = true, normal = true, hard = true }

local matches = {} -- [character id] = { m = match, level = , gil = }

local function send(player, text)
    player:printToPlayer('tetramaster:' .. text)
end

local function tell(player, text)
    player:printToPlayer(text)
end

-----------------------------------
-- The collection
-----------------------------------
local function packA(c)
    return c.id + 256 * c.arrows + 65536 * (TYPE_CODE[c.type] or 0)
end

local function packB(c)
    return c.atk + 256 * c.pdef + 65536 * c.mdef
end

local function unpackCard(a, b, index)
    if a <= 0 then
        return nil
    end

    local id = a % 256
    if Cards.get(id) == nil then
        return nil
    end

    return
    {
        uid    = index,
        id     = id,
        arrows = math.floor(a / 256) % 256,
        type   = TYPES[(math.floor(a / 65536) % 4) + 1],
        atk    = b % 256,
        pdef   = math.floor(b / 256) % 256,
        mdef   = math.floor(b / 65536) % 256,
    }
end

local function loadCards(player)
    local list = {}
    local n = player:getCharVar('TM_N')
    for i = 1, n do
        local c = unpackCard(player:getCharVar('TM_A' .. i), player:getCharVar('TM_B' .. i), i)
        if c ~= nil then
            list[#list + 1] = c
        end
    end

    return list, n
end

local function saveCard(player, index, c)
    player:setCharVar('TM_A' .. index, packA(c))
    player:setCharVar('TM_B' .. index, packB(c))
end

local function addCard(player, id)
    local n = player:getCharVar('TM_N')
    if n >= CONFIG.maxCards then
        return nil
    end

    local c = R.newCard(math.random, id)
    if c == nil then
        return nil
    end

    n = n + 1
    saveCard(player, n, c)
    player:setCharVar('TM_N', n)
    return c, n
end

-- Takes card <index> out of the collection: the last card moves into its place (and keeps its place in the deck).
local function removeCard(player, index)
    local n = player:getCharVar('TM_N')
    if index < 1 or index > n then
        return false
    end

    if index ~= n then
        player:setCharVar('TM_A' .. index, player:getCharVar('TM_A' .. n))
        player:setCharVar('TM_B' .. index, player:getCharVar('TM_B' .. n))
    end

    player:setCharVar('TM_A' .. n, 0)
    player:setCharVar('TM_B' .. n, 0)
    player:setCharVar('TM_N', n - 1)

    for k = 1, R.HAND_SIZE do
        local d = player:getCharVar('TM_D' .. k)
        if d == index then
            player:setCharVar('TM_D' .. k, 0)
        elseif d == n and index ~= n then
            player:setCharVar('TM_D' .. k, index)
        end
    end

    return true
end

local function cardName(id)
    local c = Cards.get(id)
    return c and c.name or ('card ' .. tostring(id))
end

-- A found card: saved, with a message. Returns the card or nil (collection full).
local function giveFound(player, id, where)
    local c = addCard(player, id)
    if c == nil then
        tell(player, string.format('Tetra Master: you found a %s card %s, but your collection is full (%d).',
            cardName(id), where, CONFIG.maxCards))
        return nil
    end

    tell(player, string.format('Tetra Master: you found a card %s: %s (%s, %s)!', where, cardName(id), R.cardCode(c),
        D.TIERS[D.tier(id)]))
    send(player, string.format('found|%d|%d|%s', id, c.arrows, R.cardCode(c)))
    return c
end

-- The 5 cards played with: the saved deck, filled up with the first cards not in it.
local function deckOf(player)
    local cards, n = loadCards(player)
    local byIndex = {}
    for _, c in ipairs(cards) do
        byIndex[c.uid] = c
    end

    local deck, used = {}, {}
    for k = 1, R.HAND_SIZE do
        local c = byIndex[player:getCharVar('TM_D' .. k)]
        if c ~= nil and not used[c.uid] then
            deck[#deck + 1] = c
            used[c.uid] = true
        end
    end

    for _, c in ipairs(cards) do
        if #deck >= R.HAND_SIZE then
            break
        end
        if not used[c.uid] then
            deck[#deck + 1] = c
            used[c.uid] = true
        end
    end

    return deck, #cards
end

local function power(id)
    local b = Cards.get(id)
    return b.attack + b.pdef + b.mdef
end

-- The computer's hand: random cards, weaker for easy and stronger for hard.
local function computerHand(level)
    local lo, hi = 0, 45
    if level == 'easy' then
        lo, hi = 0, 9
    elseif level == 'hard' then
        lo, hi = 12, 45
    end

    local pool = {}
    for id = 1, Cards.COUNT do
        local p = power(id)
        if p >= lo and p <= hi then
            pool[#pool + 1] = id
        end
    end

    local hand = {}
    for k = 1, R.HAND_SIZE do
        hand[k] = R.newCard(math.random, pool[math.random(1, #pool)])
    end

    return hand
end

-----------------------------------
-- Talking to the addon
-----------------------------------
local function cardText(c)
    return string.format('%d|%d|%s', c.id, c.arrows, R.cardCode(c))
end

-- The whole match, for a fresh board: start, blocks and cards on the board, your hand, the computer's hand size.
local function sendState(player, g)
    local mt = g.m
    send(player, string.format('start|%s|%s', g.level, mt.turn))
    for x = 1, 4 do
        for y = 1, 4 do
            local cell = mt.cells[x][y]
            if cell ~= nil then
                if cell.block then
                    send(player, string.format('block|%d|%d|%d', x, y, cell.block))
                else
                    send(player, string.format('cell|%d|%d|%s|%s', x, y, cell.side, cardText(cell)))
                end
            end
        end
    end

    for i, c in ipairs(mt.hands.blue) do
        send(player, string.format('hand|%d|%s', i, cardText(c)))
    end

    send(player, string.format('ohand|%d', #mt.hands.red))
    if mt.pending and mt.turn == 'blue' then
        local opts = {}
        for _, b in ipairs(mt.pending) do
            opts[#opts + 1] = b.x .. ',' .. b.y
        end
        send(player, 'choose|' .. table.concat(opts, ';'))
    end

    send(player, 'sync|' .. mt.turn)
end

local function sendEvents(player, events)
    for _, e in ipairs(events) do
        if e.type == 'place' then
            send(player, string.format('place|%s|%d|%d|%d|%d|%s', e.side, e.x, e.y, e.id, e.arrows, e.code))
        elseif e.type == 'capture' then
            send(player, string.format('capture|%d|%d|%s', e.x, e.y, e.side))
        elseif e.type == 'combo' then
            send(player, string.format('combo|%d|%d|%s|%d|%d|%d', e.x, e.y, e.side, e.from_x, e.from_y, e.count))
        elseif e.type == 'battle' then
            send(player, string.format('battle|%d|%d|%d|%d|%d|%d|%d|%d|%d', e.ax, e.ay, e.dx, e.dy,
                e.attacker_power, e.defender_power, e.attacker_final, e.defender_final, e.attacker_wins and 1 or 0))
        elseif e.type == 'upgrade' then
            send(player, string.format('upgrade|%d|%d|%s', e.x, e.y, e.to))
        elseif e.type == 'choose' and e.side == 'blue' then
            local opts = {}
            for _, b in ipairs(e.options) do
                opts[#opts + 1] = b.x .. ',' .. b.y
            end
            send(player, 'choose|' .. table.concat(opts, ';'))
        elseif e.type == 'turn' then
            send(player, 'turn|' .. e.side)
        end
    end
end

-----------------------------------
-- Running a match
-----------------------------------
local function finish(player, g)
    local mt = g.m
    local b, r = R.score(mt)
    local winner, perfect = R.result(mt)
    local gil = 0
    if winner == 'blue' then
        gil = CONFIG.gil[g.level] or 0
        if perfect then
            gil = gil * CONFIG.perfectBonus
        end
        gil = math.floor(gil * rate('TM_GIL_RATE') + 0.5)
    end

    -- your cards that moved up a class in this match keep it
    for x = 1, 4 do
        for y = 1, 4 do
            local c = R.cardAt(mt.cells, x, y)
            if c ~= nil and c.owner == 'blue' and c.uid ~= nil then
                local saved = unpackCard(player:getCharVar('TM_A' .. c.uid), player:getCharVar('TM_B' .. c.uid), c.uid)
                if saved ~= nil and saved.id == c.id and saved.type ~= c.type then
                    saved.type = c.type
                    saveCard(player, c.uid, saved)
                    tell(player, string.format('Tetra Master: your %s is now class %s.', Cards.get(c.id).name, c.type))
                end
            end
        end
    end

    send(player, string.format('end|%d|%d|%s|%d|%d', b, r, winner, perfect and 1 or 0, gil))
    if gil > 0 then
        player:addGil(gil)
        tell(player, string.format('Tetra Master: you win %d gil.', gil))
    end

    matches[player:getID()] = nil
end

-- The computer plays until it is your turn again (or the match ends).
local function computerTurns(player, g)
    local mt = g.m
    local guard = 0
    while not mt.over and mt.turn == 'red' and guard < 20 do
        guard = guard + 1
        local events
        if mt.pending then
            events = R.chooseBattle(mt, 'red', AI.chooseBattle(mt, 'red', g.level))
        else
            local mv = AI.chooseMove(mt, 'red', g.level)
            events = R.place(mt, 'red', mv.hand, mv.x, mv.y)
        end
        sendEvents(player, events or {})
    end
end

local function afterMove(player, g, events)
    sendEvents(player, events)
    computerTurns(player, g)
    if g.m.over then
        finish(player, g)
    end
end

local function startMatch(player, level)
    local deck = deckOf(player)
    if #deck < R.HAND_SIZE then
        tell(player, string.format('Tetra Master: you need %d cards to play (you have %d). Luto Mewrilah in Upper Jeuno gives new players a starter deck; card traders sell more.',
            R.HAND_SIZE, #deck))
        send(player, 'error|need ' .. R.HAND_SIZE .. ' cards')
        return
    end

    local g =
    {
        level = level,
        m     = R.newMatch({ rng = math.random, hands = { blue = deck, red = computerHand(level) },
                             first = (math.random(1, 2) == 1) and 'blue' or 'red' }),
    }
    matches[player:getID()] = g

    send(player, 'new')
    sendState(player, g)
    computerTurns(player, g)
end

local function listCards(player)
    local cards = loadCards(player)
    local inDeck = {}
    for k = 1, R.HAND_SIZE do
        inDeck[player:getCharVar('TM_D' .. k)] = true
    end

    send(player, string.format('cards|%d|%d', #cards, CONFIG.maxCards))
    for _, c in ipairs(cards) do
        send(player, string.format('card|%d|%s|%d|%d', c.uid, cardText(c), inDeck[c.uid] and 1 or 0, D.tier(c.id)))
    end
    send(player, 'cardsend')
end

local function setDeck(player, args)
    local cards = loadCards(player)
    local have = {}
    for _, c in ipairs(cards) do
        have[c.uid] = true
    end

    local pick, seen = {}, {}
    for _, v in ipairs(args) do
        local n = tonumber(v)
        if n == nil or not have[n] or seen[n] then
            tell(player, 'Tetra Master: a deck is 5 different card numbers from !tm cards.')
            return
        end
        seen[n] = true
        pick[#pick + 1] = n
    end

    if #pick ~= R.HAND_SIZE then
        tell(player, 'Tetra Master: a deck is 5 different card numbers from !tm cards.')
        return
    end

    for k = 1, R.HAND_SIZE do
        player:setCharVar('TM_D' .. k, pick[k])
    end

    tell(player, 'Tetra Master: deck saved.')
    listCards(player)
end

-----------------------------------
-- Tavern card traders
-----------------------------------
-- shops = { { n = shop number, zone = 'Southern_San_dOria', x, y, z, rot, name }, ... }  (tetramaster_shops.lua)
local shops = {}
local shopNpcs = {} -- [shop number] = npc id (this server run)

local function loadShops()
    local ok, list = pcall(dofile, D.SHOPS_FILE)
    if ok and type(list) == 'table' then
        shops = list
    else
        shops = {}
    end
end

local function saveShops()
    local lines = { '-- Tetra Master card traders, written by !tmshop (GM). One line per trader; you can edit or delete lines.',
                    'return', '{' }
    for _, sh in ipairs(shops) do
        lines[#lines + 1] = string.format('    { n = %d, zone = %q, x = %.3f, y = %.3f, z = %.3f, rot = %d, name = %q },',
            sh.n, sh.zone, sh.x, sh.y, sh.z, sh.rot or 0, sh.name or 'Card Trader')
    end
    lines[#lines + 1] = '}'
    local f = io.open(D.SHOPS_FILE, 'w')
    if not f then
        return false
    end
    f:write(table.concat(lines, '\n') .. '\n')
    f:close()
    return true
end

local function shopByNumber(n)
    if n == D.JEUNO.shop then
        return { n = n, name = D.JEUNO.name, zone = D.JEUNO.zone }
    end
    for _, sh in ipairs(shops) do
        if sh.n == n then
            return sh
        end
    end
    return nil
end

-- The trader you last talked to, if you are still standing next to it
local function nearShop(player)
    local n = player:getLocalVar('TM_SHOP')
    local npc = shopNpcs[n] and GetNPCByID(shopNpcs[n])
    if n == 0 or npc == nil or npc:getZoneID() ~= player:getZoneID() or player:checkDistance(npc) > D.SHOP_RANGE then
        return nil
    end
    return n
end

local function sendShop(player, n)
    local sh = shopByNumber(n)
    send(player, string.format('shop|%d|%s|%d', n, sh and sh.name or 'Card Trader', player:getGil()))
    send(player, 'sellprices|' .. table.concat(D.SELL, '|'))
    for i, id in ipairs(D.shopStock(n)) do
        local c = Cards.get(id)
        send(player, string.format('stock|%d|%d|%s|%d|%d', i, id, c.code, shopPrice(id), D.tier(id)))
    end
    send(player, 'stockend')
end

-- Luto's welcome: five different Common starter cards, made your deck, once per character
local function giveStarterDeck(player)
    local pool = {}
    for _, id in ipairs(D.shopStock(D.JEUNO.shop)) do
        if D.strength(id) <= D.JEUNO.starterMaxStrength then
            pool[#pool + 1] = id
        end
    end

    for i = #pool, 2, -1 do
        local j = math.random(1, i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    if player:getCharVar('TM_N') + R.HAND_SIZE > CONFIG.maxCards then
        tell(player, 'Luto Mewrilah: Your card collection is full! Sell a few and come back for your starrrter deck.')
        return
    end

    local names, slots = {}, {}
    for k = 1, math.min(R.HAND_SIZE, #pool) do
        local c, index = addCard(player, pool[k])
        if c then
            names[#names + 1] = string.format('%s (%s)', cardName(c.id), R.cardCode(c))
            slots[#slots + 1] = index
        end
    end

    if #slots == R.HAND_SIZE then
        for k = 1, R.HAND_SIZE do
            player:setCharVar('TM_D' .. k, slots[k])
        end
    end

    player:setCharVar('TM_STARTER', 1)
    for _, line in ipairs(D.JEUNO.welcome) do
        tell(player, line)
    end
    tell(player, 'Tetra Master: you receive a starter deck: ' .. table.concat(names, ', ') .. '.')
    send(player, 'starter|' .. #slots)
end

local function onShopTrigger(player, npc, n)
    player:setLocalVar('TM_SHOP', n)
    local sh = shopByNumber(n)
    if n == D.JEUNO.shop and player:getCharVar('TM_STARTER') == 0 then
        giveStarterDeck(player)
    elseif n == D.JEUNO.shop then
        tell(player, D.JEUNO.greeting)
    else
        tell(player, string.format('%s: Tetra Master cards! Have a look.', sh and sh.name or 'Card Trader'))
    end
    sendShop(player, n)
    listCards(player)
end

local function spawnShop(zone, sh)
    local npc = zone:insertDynamicEntity({
        objtype    = xi.objType.NPC,
        name       = 'TMShop' .. sh.n,
        packetName = sh.name or 'Card Trader',
        look       = sh.look or D.TRADER_LOOKS[((sh.n - 1) % #D.TRADER_LOOKS) + 1],
        x          = sh.x,
        y          = sh.y,
        z          = sh.z,
        rotation   = sh.rot or 0,
        widescan   = 1,
        onTrigger  = function(player, npcArg)
            onShopTrigger(player, npcArg, sh.n)
        end,
    })
    if npc then
        shopNpcs[sh.n] = npc:getID()
    end
    return npc
end

local function buy(player, index)
    local n = nearShop(player)
    if n == nil then
        tell(player, 'Tetra Master: talk to a card trader first (and stay next to them).')
        send(player, 'error|not at a shop')
        return
    end
    if matches[player:getID()] then
        send(player, 'error|finish your match first')
        return
    end

    local id = D.shopStock(n)[index]
    if id == nil then
        send(player, 'error|no such card')
        return
    end

    local price = shopPrice(id)
    if player:getGil() < price then
        tell(player, string.format('Tetra Master: %s costs %d gil.', cardName(id), price))
        send(player, 'error|not enough gil')
        return
    end
    if player:getCharVar('TM_N') >= CONFIG.maxCards then
        tell(player, string.format('Tetra Master: your collection is full (%d). Sell some cards first.', CONFIG.maxCards))
        send(player, 'error|collection full')
        return
    end

    player:delGil(price)
    local c = addCard(player, id)
    tell(player, string.format('Tetra Master: you buy %s (%s) for %d gil.', cardName(id), R.cardCode(c), price))
    send(player, string.format('bought|%d|%d|%s|%d', id, c.arrows, R.cardCode(c), player:getGil()))
    listCards(player)
end

local function sell(player, index)
    if nearShop(player) == nil then
        tell(player, 'Tetra Master: talk to a card trader first (and stay next to them).')
        send(player, 'error|not at a shop')
        return
    end
    if matches[player:getID()] then
        send(player, 'error|finish your match first')
        return
    end

    local c = index and unpackCard(player:getCharVar('TM_A' .. index), player:getCharVar('TM_B' .. index), index)
    if c == nil or index > player:getCharVar('TM_N') then
        send(player, 'error|no such card')
        return
    end

    local gil = D.SELL[D.tier(c.id)] or 0
    removeCard(player, index)
    player:addGil(gil)
    tell(player, string.format('Tetra Master: you sell %s (%s) for %d gil.', cardName(c.id), R.cardCode(c), gil))
    send(player, string.format('sold|%d|%d', gil, player:getGil()))
    listCards(player)
end

local function shopCommand(player, action, a1)
    action = (action or ''):lower()
    local zone = player:getZone()
    if action == 'add' then
        local pos = player:getPos()
        local n = 1
        for _, sh in ipairs(shops) do
            n = math.max(n, sh.n + 1)
        end
        local sh = { n = n, zone = zone:getName(), x = pos.x, y = pos.y, z = pos.z, rot = pos.rot,
                     name = (a1 and a1 ~= '') and a1:gsub('_', ' ') or 'Card Trader' }
        shops[#shops + 1] = sh
        if not saveShops() then
            tell(player, 'Tetra Master: could not write ' .. D.SHOPS_FILE)
        end
        spawnShop(zone, sh)
        local missing = {}
        local stock = {}
        for _, id in ipairs(D.shopStock(n)) do stock[id] = true end
        for _, name in ipairs(D.SHOP_CARDS) do
            local id = D.idsByName(name)[1]
            if id and not stock[id] then
                local weakest = id
                for _, other in ipairs(D.idsByName(name)) do
                    if D.strength(other) < D.strength(weakest) then weakest = other end
                end
                if not stock[weakest] then missing[#missing + 1] = name end
            end
        end
        tell(player, string.format('Tetra Master: card trader #%d (%s) placed here in %s. Not sold here: %s.', n, sh.name,
            sh.zone, table.concat(missing, ', ')))

    elseif action == 'remove' then
        local best, bestDist = nil, 10
        for i, sh in ipairs(shops) do
            local npc = shopNpcs[sh.n] and GetNPCByID(shopNpcs[sh.n])
            if npc and npc:getZoneID() == player:getZoneID() then
                local dist = player:checkDistance(npc)
                if dist < bestDist then
                    best, bestDist = i, dist
                end
            end
        end
        if best == nil then
            tell(player, 'Tetra Master: no card trader within 10 yalms.')
            return
        end
        local sh = table.remove(shops, best)
        saveShops()
        local npc = GetNPCByID(shopNpcs[sh.n])
        if npc then
            npc:setStatus(xi.status.DISAPPEAR)
        end
        shopNpcs[sh.n] = nil
        tell(player, string.format('Tetra Master: card trader #%d removed.', sh.n))

    else
        tell(player, string.format('Tetra Master: %d card traders (!tmshop add [name] / remove / list):', #shops))
        for _, sh in ipairs(shops) do
            tell(player, string.format('  #%d %s - %s (%.1f, %.1f, %.1f)', sh.n, sh.name or 'Card Trader', sh.zone, sh.x, sh.y, sh.z))
        end
    end
end

-----------------------------------
-- Cards from monsters and caskets
-----------------------------------
local familyKey = nil -- [family id] = 'GOBLIN', ... (built on first use, once the enums are loaded)
local function familyOf(mob)
    if familyKey == nil then
        familyKey = {}
        for k, v in pairs(xi.mobFamily or {}) do
            familyKey[v] = k
        end
    end
    return familyKey[mob:getFamily()]
end

local function pick(list)
    return list[math.random(1, #list)]
end

-- All ids of a family's cards, with their tiers
local function familyIds(key)
    local out = {}
    for _, name in ipairs(D.FAMILY_CARDS[key] or {}) do
        for _, id in ipairs(D.idsByName(name)) do
            out[#out + 1] = id
        end
    end
    return out
end

-- The card a kill gives, or nil
local function rollMonsterCard(mob)
    local mult = rate('TM_CARD_DROP_RATE')
    if mult <= 0 then
        return nil
    end

    local named = D.NAMED[mob:getName()]
    if named then
        if math.random() < named[2] * mult then
            local best = nil -- a name in the set twice (Garuda): the stronger card
            for _, id in ipairs(D.idsByName(named[1])) do
                if best == nil or D.strength(id) > D.strength(best) then best = id end
            end
            return best
        end
        return nil
    end

    local key = familyOf(mob)
    local ids = familyIds(key)
    if #ids == 0 then
        return nil
    end

    if mob:isNM() then
        if math.random() >= D.NM_FAMILY_CHANCE * mult then
            return nil
        end
        -- not Legendary: those only come from the named fights above
        local pool = {}
        for _, id in ipairs(ids) do
            if D.tier(id) <= 4 then pool[#pool + 1] = id end
        end
        return #pool > 0 and pick(pool) or nil
    end

    local level = mob:getMainLvl()
    local order = {}
    for _, id in ipairs(ids) do
        local t = D.tier(id)
        if t <= 3 and (t < 3 or level >= D.RARE_MIN_LEVEL) then
            order[#order + 1] = id
        end
    end

    for i = #order, 2, -1 do
        local j = math.random(1, i)
        order[i], order[j] = order[j], order[i]
    end

    for _, id in ipairs(order) do
        if math.random() < D.FAMILY_CHANCE[D.tier(id)] * mult then
            return id
        end
    end

    return nil
end

-- A card from a casket, or nil
local casketPool = nil
local function rollCasketCard(level)
    if math.random() >= D.CASKET_CHANCE * rate('TM_CASKET_CARD_RATE') then
        return nil
    end

    if casketPool == nil then
        -- every card that is not a monster card or a named fight's card
        local skip = {}
        for key in pairs(D.FAMILY_CARDS) do
            for _, id in ipairs(familyIds(key)) do skip[id] = true end
        end
        for _, v in pairs(D.NAMED) do
            for _, id in ipairs(D.idsByName(v[1])) do skip[id] = true end
        end
        casketPool = { {}, {}, {}, {}, {} }
        for id = 1, Cards.COUNT do
            if not skip[id] then
                table.insert(casketPool[D.tier(id)], id)
            end
        end
    end

    local total = 0
    for _, w in ipairs(D.CASKET_TIER_WEIGHTS) do total = total + w end
    local r = math.random() * total
    local tier = 1
    for t, w in ipairs(D.CASKET_TIER_WEIGHTS) do
        if r < w then tier = t break end
        r = r - w
    end
    if tier >= 4 and level < D.CASKET_EPIC_MIN_LEVEL then
        tier = 3
    end
    while tier > 1 and #casketPool[tier] == 0 do tier = tier - 1 end
    return #casketPool[tier] > 0 and pick(casketPool[tier]) or nil
end

-----------------------------------
-- !tm
-----------------------------------
local command = {}
command.cmdprops = { permission = 0, parameters = 'ssssss' }

local function run(player, action, a1, a2, a3, a4, a5)
    action = (action or ''):lower()
    local g = matches[player:getID()]

    if action == 'play' then
        local level = (a1 or 'normal'):lower()
        if not LEVELS[level] then
            level = 'normal'
        end
        if g ~= nil then
            tell(player, 'Tetra Master: your last match was given up.')
        end
        startMatch(player, level)

    elseif action == 'move' then
        if g == nil then
            send(player, 'error|no match')
            return
        end
        local events, why = R.place(g.m, 'blue', tonumber(a1), tonumber(a2), tonumber(a3))
        if events == nil then
            send(player, 'error|' .. tostring(why))
            sendState(player, g)
            return
        end
        afterMove(player, g, events)

    elseif action == 'pick' then
        if g == nil then
            send(player, 'error|no match')
            return
        end
        local events, why = R.chooseBattle(g.m, 'blue', tonumber(a1))
        if events == nil then
            send(player, 'error|' .. tostring(why))
            sendState(player, g)
            return
        end
        afterMove(player, g, events)

    elseif action == 'quit' then
        if g ~= nil then
            matches[player:getID()] = nil
            send(player, 'quit')
            tell(player, 'Tetra Master: you give up the match.')
        end

    elseif action == 'state' then
        if g ~= nil then
            sendState(player, g)
        else
            send(player, 'none')
        end

    elseif action == 'cards' then
        listCards(player)

    elseif action == 'deck' then
        setDeck(player, { a1, a2, a3, a4, a5 })

    elseif action == 'buy' then
        buy(player, tonumber(a1))

    elseif action == 'sell' then
        sell(player, tonumber(a1))

    elseif action == 'shop' then
        if nearShop(player) then
            sendShop(player, nearShop(player))
            listCards(player)
        else
            send(player, 'error|not at a shop')
        end

    else
        tell(player, 'Tetra Master: open the board with /tm (the tetramaster addon). Commands: !tm play [easy|normal|hard], !tm cards, !tm deck <5 numbers>, !tm buy <n>, !tm sell <n>, !tm quit')
    end
end

command.onTrigger = function(player, action, a1, a2, a3, a4, a5)
    local ok, err = pcall(run, player, action, a1, a2, a3, a4, a5)
    if not ok then
        print('[tetramaster] ' .. tostring(err))
        send(player, 'error|server')
    end
end

xi.module.registerCommand('tm', command)

-- !tmgive <card id> [count]: GM testing
local giveCommand = {}
giveCommand.cmdprops = { permission = 1, parameters = 'ss' }
giveCommand.onTrigger = function(player, idArg, countArg)
    local id = tonumber(idArg)
    if id == nil or Cards.get(id) == nil then
        tell(player, '!tmgive <card id 1-' .. Cards.COUNT .. '> [count]')
        return
    end

    for k = 1, math.max(1, math.min(tonumber(countArg) or 1, 20)) do
        if addCard(player, id) == nil then
            tell(player, 'Tetra Master: your collection is full.')
            return
        end
    end

    tell(player, 'Tetra Master: added ' .. Cards.get(id).name .. '.')
end

xi.module.registerCommand('tmgive', giveCommand)

-- !tmshop add [name] / remove / list (GM)
local shopCmd = {}
shopCmd.cmdprops = { permission = 1, parameters = 'ss' }
shopCmd.onTrigger = function(player, action, name)
    local ok, err = pcall(shopCommand, player, action, name)
    if not ok then
        print('[tetramaster] ' .. tostring(err))
        tell(player, 'Tetra Master: ' .. tostring(err))
    end
end

xi.module.registerCommand('tmshop', shopCmd)

-----------------------------------
-- Hooks
-----------------------------------
loadShops()

-- card traders appear when their area starts
local shopZones = {}
for _, sh in ipairs(shops) do
    shopZones[sh.zone] = true
end

for zoneName in pairs(shopZones) do
    m:addOverride('xi.zones.' .. zoneName .. '.Zone.onInitialize', function(zone)
        super(zone)
        for _, sh in ipairs(shops) do
            if sh.zone == zone:getName() and shopNpcs[sh.n] == nil then
                local ok, err = pcall(spawnShop, zone, sh)
                if not ok then
                    print('[tetramaster] card trader #' .. sh.n .. ': ' .. tostring(err))
                end
            end
        end
    end)
end

-- Luto Mewrilah in Upper Jeuno: the retail NPC if the zone has her (shown, and her clicks go to the card shop),
-- otherwise one made at her spot
local function setUpLuto(zone)
    local found = nil
    local ok, list = pcall(function() return zone:queryEntitiesByName(D.JEUNO.npc) end)
    if ok and type(list) == 'table' then
        found = list[1]
    end

    if found then
        shopNpcs[D.JEUNO.shop] = found:getID()
        if xi.status then
            found:setStatus(xi.status.NORMAL)
        end
        print('[tetramaster] Luto Mewrilah is the Jeuno card trader (zone NPC ' .. found:getID() .. ')')
    else
        local f = D.JEUNO.fallback
        spawnShop(zone, { n = D.JEUNO.shop, zone = D.JEUNO.zone, x = f.x, y = f.y, z = f.z, rot = f.rot,
                          name = D.JEUNO.name, look = D.JEUNO.look })
        print('[tetramaster] Luto Mewrilah was not in the zone data: made her at her spot')
    end
end

m:addOverride('xi.zones.' .. D.JEUNO.zone .. '.Zone.onInitialize', function(zone)
    super(zone)
    local ok, err = pcall(setUpLuto, zone)
    if not ok then
        print('[tetramaster] Luto Mewrilah: ' .. tostring(err))
    end
end)

-- clicks on the retail Luto Mewrilah: the map server calls InteractionGlobal.onTrigger for every NPC click; wrap it
-- once (like starlight_smilebringers.lua) and hand every other NPC on untouched
local function wrapInteraction()
    if type(InteractionGlobal) ~= 'table' or InteractionGlobal.tetramasterWrapped then
        return
    end

    local original = InteractionGlobal.onTrigger
    InteractionGlobal.onTrigger = function(player, npc, fallbackFn)
        local id = shopNpcs[D.JEUNO.shop]
        if id and npc and player and npc:getID() == id then
            local ok, err = pcall(onShopTrigger, player, npc, D.JEUNO.shop)
            if ok then
                return 0
            end
            print('[tetramaster] ' .. tostring(err))
        end

        return original(player, npc, fallbackFn)
    end
    InteractionGlobal.tetramasterWrapped = true
end

m:addOverride('xi.server.onServerStart', function()
    super()
    wrapInteraction()
end)

-- a monster dies: one roll per monster, for the first adventurer the game tells us about (usually you)
m:addOverride('xi.mob.onMobDeathEx', function(mob, player, isKiller, isWeaponSkillKill)
    super(mob, player, isKiller, isWeaponSkillKill)

    local ok, err = pcall(function()
        if player == nil or not player:isPC() or mob:getMaster() ~= nil or mob:getLocalVar('TM_ROLLED') == 1 then
            return
        end
        if xi.job and player:getMainJob() == xi.job.MON then
            return
        end
        mob:setLocalVar('TM_ROLLED', 1)

        local id = rollMonsterCard(mob)
        if id then
            giveFound(player, id, 'on ' .. mob:getName():gsub('_', ' '))
        end
    end)
    if not ok then
        print('[tetramaster] drop: ' .. tostring(err))
    end
end)

-- a treasure casket is opened for the first time
m:addOverride('xi.caskets.onTrigger', function(player, npc)
    super(player, npc)

    local ok, err = pcall(function()
        if npc:getLocalVar('[caskets]SPAWNSTATUS') ~= 2 or npc:getLocalVar('TM_ROLLED') == 1 or not player:isPC() then
            return
        end
        npc:setLocalVar('TM_ROLLED', 1)
        local id = rollCasketCard(player:getMainLvl())
        if id then
            giveFound(player, id, 'in the casket')
        end
    end)
    if not ok then
        print('[tetramaster] casket: ' .. tostring(err))
    end
end)

return m
