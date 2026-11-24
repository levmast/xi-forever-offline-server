-----------------------------------
-- Bot players: real trades behind the selling / buying shouts (2026-11-23). Used by crowds_chat.lua (not in init.txt).
--
-- "Selling Errant Cape 420k": the item is really in that bot's bags (something it crafted, gathered or looted, or a
--   crafted piece it made for the market), priced in its BAZAAR at about the fair price (the HorizonXI market data the
--   auction house uses, +-8%). Check its bazaar and buy it the normal way: the item comes to you, the gil goes to it.
-- "WTB Raxa, paying 9k": put the item in YOUR bazaar at or below that price; the bot sees it (or /tell it), walks
--   over and buys it from your bazaar. The gil really comes from the bot.
-- Not clogged: one offer per bot, a few per town at once (Jeuno 4, Whitegate 3, nation cities 2, small towns 1,
--   outposts none). An offer is shouted again every 4-6 minutes and ends after 15-20 minutes, or once it is done.
-- /tell a bot about its offer ("how much?", "still selling?", "I have one") and it answers about the real offer.
-- Needs xi_map.exe built with BotBazaarSet / BotBazaarItems / BotBazaarBuy (bots.cpp, 2026-11-23): without them
-- there are simply no selling/buying shouts (no fake ones).
-----------------------------------
local M = {}

local craftOk, craft = pcall(require, 'modules/custom/lua/bots_craft')
if not craftOk or type(craft) ~= 'table' then
    craft = nil
end

local namesOk, NAMES = pcall(require, 'modules/custom/lua/bots_trade_names')
if not namesOk or type(NAMES) ~= 'table' then
    NAMES = {}
end

local LIFE       = { 15 * 60, 20 * 60 } -- an offer lasts this long
local RESHOUT    = { 240, 360 }          -- seconds between shouts of the same offer
local SWEEP      = 15                    -- seconds between checks of the offers in an area
local LEFTOVER   = 120                   -- seconds between checks for bazaar prices left over (logout, restart)
local WALK_GIVEUP = 120                  -- a bot gives up walking over to your bazaar after this long
local BUY_RANGE  = 6                     -- yalms: it buys once it stands this close to you
local MIN_PRICE  = 100

local offers  = {} -- [botId] = { kind, zone, item, name, price, qty, untilT, nextShout, gil, target, goingSince }
local areas   = {} -- [zoneId] = { nextSweep, nextLeftover }

local function now()
    return os.time()
end

local function rnd(a, b)
    return math.random(a, b)
end

local function pick(list)
    if not list or #list == 0 then
        return nil
    end

    return list[math.random(#list)]
end

function M.available()
    return type(BotBazaarSet) == 'function' and type(BotBazaarItems) == 'function' and type(BotBazaarBuy) == 'function'
        and craft ~= nil and type(craft.priceOf) == 'function'
end

-- how many offers an area holds at once (crowds_chat.lua passes its area kind)
local CAP = { jeuno = 4, whitegate = 3, city = 2, small = 1, outpost = 0 }
function M.cap(kind)
    return CAP[kind] or 2
end

-----------------------------------
-- prices and names
-----------------------------------
local function round(gil)
    if gil < 1000 then
        return math.max(10, math.floor(gil / 10 + 0.5) * 10)
    elseif gil < 10000 then
        return math.floor(gil / 100 + 0.5) * 100
    elseif gil < 1000000 then
        return math.floor(gil / 1000 + 0.5) * 1000
    end

    return math.floor(gil / 10000 + 0.5) * 10000
end

-- the way people wrote prices in shouts: 450g, 4.5k, 420k, 1.2m
function M.priceText(gil)
    if gil < 1000 then
        return string.format('%dg', gil)
    elseif gil < 10000 then
        local s = string.format('%.1fk', gil / 1000)
        return (s:gsub('%.0k', 'k'))
    elseif gil < 1000000 then
        return string.format('%dk', math.floor(gil / 1000 + 0.5))
    end

    local s = string.format('%.1fm', gil / 1000000)
    return (s:gsub('%.0m', 'm'))
end

local function fair(id)
    local ok, p = pcall(craft.priceOf, id)
    return ok and tonumber(p) or nil
end

-----------------------------------
-- lines (only what is true: no "3 left", no stacks it does not have, no HQ claims)
-----------------------------------
local SELL = {
    'Selling {item} {price}, in my bazaar', 'WTS {item} {price}, bazaar', '{item} {price} in bazaar, come grab it',
    'wts {item}, {price}, check my bazaar', 'Selling {item} {price}, /t if you cant find me', 'wts {item} {price} obo, bazaar',
    'bazaar: {item} {price}', 'wts {item} {price}, cheaper than AH', 'selling {item} {price}, need the space',
    'wts {item} {price}, cheap because i need gil', 'clearing my bags, {item} {price} in bazaar',
}
local SELL_QTY = {
    'Selling {item} x{qty}, {price} each, bazaar', 'wts {item} x{qty} {price} ea, in bazaar', 'bazaar: {item} x{qty}, {price} each',
}
local BUY = {
    'WTB {item}, paying {price}. put it in bazaar and /t me', 'wtb {item} {price}, bazaar it and pst', 'Buying {item}, {price}, /t me',
    'wtb {item}, {price} is my max, bazaar is fine', 'need {item}, paying {price}, /t', 'wtb {item} {price}, need it for a synth',
    'looking to buy {item} for {price}, /t', 'someone sell me {item} for {price}? bazaar it',
}
local RESELL = { 'still selling {item} {price}, bazaar', '{item} {price} still up, bazaar', 'wts {item} {price}, still have it' }
local REBUY  = { 'still wtb {item} {price}', 'anyone have {item}? still paying {price}', 'wtb {item} {price}, still looking' }

local function fill(text, o)
    return (text:gsub('{(%w+)}', function(k)
        if k == 'item' then
            return o.name
        elseif k == 'price' then
            return M.priceText(o.price)
        elseif k == 'qty' then
            return tostring(o.qty or 1)
        end

        return ''
    end))
end

local function shoutFor(o, again)
    if o.kind == 'sell' then
        if again then
            return fill(pick(RESELL), o)
        end

        return fill(pick((o.qty or 1) > 1 and SELL_QTY or SELL), o)
    end

    return fill(pick(again and REBUY or BUY), o)
end

-----------------------------------
-- making an offer
-----------------------------------
local function countIn(zoneId)
    local n = 0
    for _, o in pairs(offers) do
        if o.zone == zoneId then
            n = n + 1
        end
    end

    return n
end

-- something real in its bags it can put in the bazaar
local function sellPick(e)
    local okS, rows = pcall(craft.sellables, e)
    local list = {}
    for _, r in ipairs((okS and rows) or {}) do
        local single = fair(r.id)
        if NAMES[r.id] and single and single >= MIN_PRICE then
            list[#list + 1] = { id = r.id, qty = r.qty or 1, single = single }
        end
    end

    return pick(list)
end

-- the crafted era items a bot might make for the market or need for a synth (crowds_data.lua's d.sell, by name)
local sellIds
local function marketIds()
    if sellIds then
        return sellIds
    end

    sellIds = {}
    local byName = {}
    for id, name in pairs(NAMES) do
        byName[name] = byName[name] or id
    end

    local okD, D = pcall(require, 'modules/custom/lua/crowds_data')
    for _, s in ipairs((okD and type(D) == 'table' and D.sell) or {}) do
        local id = byName[s[1]]
        if id then
            sellIds[#sellIds + 1] = id
        end
    end

    return sellIds
end

-- what it can afford to offer for (keeps a cushion of its own gil)
local function affordable(e, lvl)
    local gil = e:getGil()
    local roof = math.max(3000, lvl * lvl * 120) -- a level 20 buys up to ~48k things, a 75 up to ~675k
    local list = {}
    for _, id in ipairs(marketIds()) do
        local p = fair(id)
        if p and p >= MIN_PRICE and p <= roof and p * 1.2 + 1000 <= gil then
            list[#list + 1] = { id = id, single = p }
        end
    end

    return pick(list)
end

local function newSell(e, zoneId)
    local id, t = e:getID(), now()
    local got = sellPick(e)
    if not got and e:getFreeSlotsCount() >= 3 and math.random() < 0.5 then
        -- nothing of its own to sell: something it crafted for the market (it really gets the item)
        local itemId = pick(marketIds())
        local single = itemId and fair(itemId)
        local lvl = e:getMainLvl()
        if single and single >= MIN_PRICE and single <= math.max(5000, lvl * lvl * 150) then
            local okA = pcall(function()
                e:addItem(itemId, 1)
            end)
            if okA then
                got = { id = itemId, qty = 1, single = single }
            end
        end
    end

    if not got then
        return nil
    end

    local price = round(got.single * (0.92 + math.random() * 0.16))
    if not BotBazaarSet(id, got.id, price) then
        return nil
    end

    -- what it really put up (a stack shows its count; the price is per item, as in any bazaar)
    local qty = 1
    for _, r in ipairs(BotBazaarItems(id) or {}) do
        if r.id == got.id then
            qty = r.qty
            break
        end
    end

    local o = { kind = 'sell', zone = zoneId, item = got.id, name = NAMES[got.id], price = price, qty = qty,
                untilT = t + rnd(LIFE[1], LIFE[2]), nextShout = t + rnd(RESHOUT[1], RESHOUT[2]), gil = e:getGil() }
    offers[id] = o
    print(string.format('[bots] trade: %s sells %s x%d at %d gil in its bazaar (zone %d)', e:getName(), o.name, qty, price, zoneId))
    return o
end

local function newBuy(e, zoneId)
    local id, t = e:getID(), now()
    local got = affordable(e, e:getMainLvl())
    if not got or not NAMES[got.id] then
        return nil
    end

    local o = { kind = 'buy', zone = zoneId, item = got.id, name = NAMES[got.id], price = round(got.single * (0.95 + math.random() * 0.15)),
                qty = 1, untilT = t + rnd(LIFE[1], LIFE[2]), nextShout = t + rnd(RESHOUT[1], RESHOUT[2]) }
    offers[id] = o
    print(string.format('[bots] trade: %s wants %s for up to %d gil (zone %d)', e:getName(), o.name, o.price, zoneId))
    return o
end

-- crowds_chat.lua rolled a selling / buying shout for this bot: a line for a real new offer, or nil (it then shouts
-- something else). A bot with an offer already does not start a second one.
function M.newOffer(e, group, zoneId, cap)
    if not M.available() or (cap or 0) <= 0 then
        return nil
    end

    if offers[e:getID()] or countIn(zoneId) >= cap then
        return nil
    end

    local o
    if group == 'selling' then
        o = newSell(e, zoneId)
    elseif group == 'buying' then
        o = newBuy(e, zoneId)
    end

    return o and shoutFor(o, false) or nil
end

-----------------------------------
-- ending offers
-----------------------------------
local function clearBazaar(id)
    for _, r in ipairs(BotBazaarItems(id) or {}) do
        BotBazaarSet(id, r.id, 0)
    end
end

local function finish(id, why)
    local o = offers[id]
    offers[id] = nil
    if o and o.kind == 'sell' and BotIsOnline and BotIsOnline(id) then
        pcall(clearBazaar, id)
    end

    if o then
        print(string.format('[bots] trade: offer of bot %d ended (%s): %s', id, why, o.name))
    end
end

local function listed(charId, itemId)
    for _, r in ipairs(BotBazaarItems(charId) or {}) do
        if r.id == itemId then
            return r
        end
    end

    return nil
end

local function tell(e, to, text, delay)
    local id = e:getID()
    e:timer((delay or rnd(3, 7)) * 1000, function()
        if BotTell then
            BotTell(id, to, text)
        end
    end)
end

local function dist(a, b)
    local pa, pb = a:getPos(), b:getPos()
    local dx, dz = pa.x - pb.x, pa.z - pb.z
    return math.sqrt(dx * dx + dz * dz)
end

local function walkTo(e, p)
    local pos = p:getPos()
    BotMoveTo(e:getID(), pos.x + (math.random() - 0.5) * 3, pos.y, pos.z + (math.random() - 0.5) * 3)
end

-- a buyer bot on its way to someone's bazaar
local function buyStep(e, o, players, speak)
    local p
    for _, q in ipairs(players) do
        if q:getID() == o.target then
            p = q
            break
        end
    end

    local item = p and listed(p:getID(), o.item)
    if not p or not item or item.price > o.price then
        o.target, o.goingSince = nil, nil
        return
    end

    if dist(e, p) > BUY_RANGE then
        if now() - (o.goingSince or now()) > WALK_GIVEUP then
            o.target, o.goingSince = nil, nil
            return
        end

        walkTo(e, p)
        return
    end

    local paid = BotBazaarBuy(e:getID(), p:getID(), o.item, o.price, o.qty or 1)
    if paid and paid > 0 then
        print(string.format('[bots] trade: %s bought %s from %s for %d gil', e:getName(), o.name, p:getName(), paid))
        tell(e, p:getName(), pick({ 'got it, ty!', 'ty! exactly what i needed', 'bought, thanks a lot', 'ty :)' }), rnd(2, 4))
        finish(e:getID(), 'bought')
    else
        o.target, o.goingSince = nil, nil
    end
end

-----------------------------------
-- every couple of seconds, for an area with real players (crowds_chat.lua onBotThink)
-----------------------------------
function M.tick(zoneId, speakers, players, speak)
    if not M.available() then
        return
    end

    local t = now()
    local a = areas[zoneId] or { nextSweep = 0, nextLeftover = t + 20 }
    areas[zoneId] = a

    local here = {}
    for _, e in ipairs(speakers) do
        here[e:getID()] = e
    end

    -- buyers walking over act every tick (smooth walking); the rest every SWEEP seconds
    for id, o in pairs(offers) do
        if o.zone == zoneId and o.kind == 'buy' and o.target and here[id] then
            pcall(buyStep, here[id], o, players, speak)
        end
    end

    if t < a.nextSweep then
        return
    end

    a.nextSweep = t + SWEEP

    for id, o in pairs(offers) do
        local e = here[id]
        if o.zone == zoneId then
            if not e then
                finish(id, 'left the area') -- (zoned, logged out, joined a party elsewhere)
            elseif t >= o.untilT then
                finish(id, 'time')
                if o.kind == 'sell' then
                    speak(e, 0, pick({ 'meh, nobody wants it', 'guess ill AH it', 'closing bazaar' }))
                end
            elseif o.kind == 'sell' then
                local r = listed(id, o.item)
                if not r then
                    local sold = e:getGil() > (o.gil or 0)
                    finish(id, sold and 'sold' or 'gone')
                    if sold then
                        speak(e, 0, pick({ 'ty for buying!', 'sold, ty :)', 'ty!' }))
                    end
                else
                    o.qty = r.qty
                    if t >= o.nextShout then
                        o.nextShout = t + rnd(RESHOUT[1], RESHOUT[2])
                        speak(e, 1, shoutFor(o, true))
                    end
                end
            else -- buy: someone here has it in their bazaar at or below the price?
                if not o.target then
                    for _, p in ipairs(players) do
                        local r = listed(p:getID(), o.item)
                        if r and r.price <= o.price then
                            o.target, o.goingSince = p:getID(), t
                            tell(e, p:getName(), pick({ 'saw your ' .. o.name .. ' in bazaar, omw', 'omw to buy your ' .. o.name,
                                'you have ' .. o.name .. '? coming' }))
                            break
                        end
                    end
                end

                if not o.target and t >= o.nextShout then
                    o.nextShout = t + rnd(RESHOUT[1], RESHOUT[2])
                    speak(e, 1, shoutFor(o, true))
                end
            end
        elseif here[id] and o.zone ~= zoneId then
            finish(id, 'changed area')
        end
    end

    -- prices left in a bazaar from before (a logout or a server restart): taken down
    if t >= a.nextLeftover then
        a.nextLeftover = t + LEFTOVER
        for id in pairs(here) do
            if not offers[id] then
                local okL, rows = pcall(BotBazaarItems, id)
                if okL and rows and #rows > 0 then
                    pcall(clearBazaar, id)
                end
            end
        end
    end
end

-----------------------------------
-- you /tell a bot (bots.lua xi.bots.onTell): true when it answered about its offer
-----------------------------------
local ASK = { 'buy', 'sell', 'wts', 'wtb', 'price', 'much', 'still', 'bazaar', 'have', 'got', 'interest', 'want', 'take', 'sold',
    'where', 'gil', 'cost', 'offer', 'deal', 'mine', '?' }

local function zoneName(e)
    local ok, n = pcall(function()
        return e:getZone():getName()
    end)
    return ok and n and (tostring(n):gsub('_', ' ')) or 'town'
end

function M.onTell(bot, from, text)
    local o = offers[bot:getID()]
    if not o or not M.available() then
        return false
    end

    local lower = string.lower(text or '')
    local hit = lower:find(string.lower(o.name), 1, true) ~= nil
    if not hit then
        for _, w in ipairs(ASK) do
            if lower:find(w, 1, true) then
                hit = true
                break
            end
        end
    end

    if not hit then
        return false
    end

    local p = GetPlayerByName(from)
    local sameZone = p and p:getZoneID() == bot:getZoneID()
    if o.kind == 'sell' then
        local r = listed(bot:getID(), o.item)
        if not r then
            finish(bot:getID(), 'gone')
            tell(bot, from, 'sorry, just sold it')
            return true
        end

        if sameZone then
            tell(bot, from, string.format('%s is in my bazaar, %s%s. ill come to you', o.name, M.priceText(o.price),
                r.qty > 1 and (' each, have ' .. r.qty) or ''))
            o.untilT = math.max(o.untilT, now() + 5 * 60) -- (it waits for you)
            bot:timer(rnd(4, 7) * 1000, function()
                local q = GetPlayerByName(from)
                if q and q:getZoneID() == bot:getZoneID() and dist(bot, q) > 6 then
                    walkTo(bot, q)
                end
            end)
        else
            tell(bot, from, string.format('%s, %s in my bazaar. im in %s', o.name, M.priceText(o.price), zoneName(bot)))
        end

        return true
    end

    -- buy
    if not sameZone then
        tell(bot, from, string.format('im in %s, put %s in your bazaar for %s when youre here and /t me', zoneName(bot), o.name, M.priceText(o.price)))
        return true
    end

    local r = listed(p:getID(), o.item)
    if r and r.price <= o.price then
        o.target, o.goingSince = p:getID(), now()
        tell(bot, from, 'omw, buying it from your bazaar')
    elseif r then
        tell(bot, from, string.format('%s is too much for me, i can do %s', M.priceText(r.price), M.priceText(o.price)))
    else
        o.untilT = math.max(o.untilT, now() + 5 * 60)
        tell(bot, from, string.format('cool, put %s in your bazaar for %s and ill come grab it', o.name, M.priceText(o.price)))
    end

    return true
end

-- for !bots trade / the tests
function M.list()
    return offers
end

M._reset = function()
    offers, areas, sellIds = {}, {}, nil
end

return M
