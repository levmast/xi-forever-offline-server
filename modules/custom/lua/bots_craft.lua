-----------------------------------
-- FFXI Offline: bot players, step 4.4b - personalities, crafting, HELM gathering and the auction house.
-- Used by bots.lua (not listed in init.txt). Data: bots_craft_data.lua (made by build_bots_craft.py).
--
-- Every bot has a personality, kept on the character (char vars), chosen on its first day:
--   style: hunter / crafter / gatherer / merchant / all-rounder  (what it likes to do with its time)
--   main craft (woodworking ... cooking), favourite HELM (mining, logging, harvesting, excavation)
--   thrift: how hard it bargains on the auction house
-- In town it picks what to do next from its style: go hunting (bots_hunt.lua), craft, go gathering, or visit
-- the auction house. Everything goes through the real game:
--   crafting: real synthesis packets, real recipes of its craft just above its skill, real skill-ups (era rules),
--     breaks and HQs; it ranks up when it hits its rank's cap (as if it passed the guild's test item).
--     Materials: what it has, cheap auction listings, else bought "from a guild or vendor" for gil (its gil goes down).
--   HELM: it buys tools (gil), goes to a gathering area for its level, walks to the real gathering points and
--     trades its tool to them (the server's own HELM rules: items, breaks, moving points, daily caps).
--   auction house: lists what it made, gathered or looted at a fair price (some bargain, some ask more), and buys
--     listings below the fair price - yours too: if a bot buys your item, the gil reaches you as with any sale.
-----------------------------------
local C = {}

local DATA_PATH = 'modules/custom/lua/bots_craft_data'

local STYLES = { 'hunter', 'crafter', 'gatherer', 'merchant', 'allround' }
local STYLE_WEIGHT = { hunter = 30, crafter = 20, gatherer = 15, merchant = 10, allround = 25 }
-- what each style does when it has time (weights); "town" = stay and hang around
local PLAN = {
    hunter   = { hunt = 55, craft = 5, gather = 5, market = 15, town = 10, quest = 10, fish = 3 },
    crafter  = { hunt = 15, craft = 40, gather = 10, market = 20, town = 10, quest = 5, fish = 5 },
    gatherer = { hunt = 15, craft = 10, gather = 30, market = 20, town = 10, quest = 5, fish = 15 },
    merchant = { hunt = 15, craft = 15, gather = 10, market = 35, town = 20, quest = 5, fish = 5 },
    allround = { hunt = 25, craft = 15, gather = 15, market = 15, town = 10, quest = 20, fish = 8 },
}
local CRAFT_SKILL = { 49, 50, 51, 52, 53, 54, 55, 56 } -- woodworking smithing goldsmithing clothcraft leathercraft bonecraft alchemy cooking
local CRAFT_NAMES = { 'woodworking', 'smithing', 'goldsmithing', 'clothcraft', 'leathercraft', 'bonecraft', 'alchemy', 'cooking' }
local START_GIL = { 1500, 6000 }
-- a goal it works towards (kept on the character); it pushes what the bot chooses to do
local GOALS = {
    { name = 'level', weight = 40, push = { hunt = 25 } },     -- "reach level N"
    { name = 'craft', weight = 25, push = { craft = 25 } },    -- "reach N in its craft"
    { name = 'gil', weight = 20, push = { market = 15, gather = 15 } }, -- "save up N gil"
    { name = 'helm', weight = 10, push = { gather = 25 } },    -- "gather a lot"
    { name = 'rank', weight = 20, push = { quest = 30 } },     -- "reach nation rank N" (missions)
    { name = 'quests', weight = 10, push = { quest = 25 } },   -- "do every quest in town"
}

local SYNTH_EVERY   = { 18, 24 }    -- seconds between two syntheses (the server wants 15)
local SYNTHS        = { 4, 10 }     -- per crafting session
local MAX_LISTINGS  = 6             -- auction listings per bot
local MARKET_STEP   = { 3, 7 }      -- seconds between two auction actions
local GATHER_TRIES  = { 2, 4 }      -- tries at one gathering point before the next one
local GATHER_MIN    = { 15, 35 }    -- minutes out gathering
local TOOLS_BUY     = { 6, 12 }
local TOOL_PRICE    = { [605] = 200, [1020] = 300, [1021] = 500 } -- pickaxe, sickle, hatchet (vendor prices)
local PLAYER_SPACE  = 40

local HELM_TYPES = { 'MINING', 'LOGGING', 'HARVESTING', 'EXCAVATION' }
local HELM_NPC = { MINING = 'Mining_Point', LOGGING = 'Logging_Point', HARVESTING = 'Harvesting_Point', EXCAVATION = 'Excavation_Point' }
-- era gathering areas and the level a bot wants before going there
local HELM_ZONES = {
    MINING     = { { 172, 1 }, { 143, 12 }, { 142, 20 }, { 196, 22 }, { 11, 35 }, { 12, 45 }, { 205, 55 } },  -- Zeruhn, Palborough, Yughott, Gusgen, Oldton, Newton, Ifrit's
    LOGGING    = { { 101, 1 }, { 140, 8 }, { 104, 15 }, { 118, 18 }, { 123, 30 }, { 124, 35 } },             -- East Ronfaure, Ghelsba, Jugner, Buburimu, Yuhtunga, Yhoator
    HARVESTING = { { 115, 1 }, { 145, 12 }, { 123, 30 }, { 124, 35 } },                                       -- West Sarutabaruta, Giddeus, Yuhtunga, Yhoator (Pashhow has no points here)
    EXCAVATION = { { 117, 8 }, { 198, 15 }, { 173, 25 } },                                                    -- Tahrongi, Maze of Shakhrami, Korroloka
}
local HOME = { [0] = { 230, 231, 232 }, [1] = { 234, 235, 236 }, [2] = { 238, 239, 240, 241 } }

local data
local hunt                     -- bots_hunt.lua (fighting back while gathering)
local busyPoint = {}           -- [npc id] = bot id gathering there

local function note(text)
    print('[bots] ' .. text)
end

local function rnd(a, b)
    return math.random(a, b)
end

local function now()
    return os.time()
end

local function pick(list)
    return list[rnd(1, #list)]
end

local function weighted(weights)
    local total = 0
    for _, w in pairs(weights) do
        total = total + w
    end

    local roll = math.random() * total
    for k, w in pairs(weights) do
        roll = roll - w
        if roll <= 0 then
            return k
        end
    end

    return next(weights)
end

local function d2(a, b)
    return (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2
end

local function craftData()
    if data == nil then
        local ok, d = pcall(require, DATA_PATH)
        data = (ok and type(d) == 'table') and d or { recipes = {}, items = {}, made = {} }
        if not ok then
            print('[bots] crafting data missing (run build_bots_craft.py): ' .. tostring(d))
        end
    end

    return data
end

-- bots.cpp registers these only when it is built with step 4.4b (an older xi_map.exe does not have them)
local function cppReady()
    return type(BotInventory) == 'function' and type(BotSynth) == 'function' and type(BotTrade) == 'function'
        and type(BotAucSell) == 'function' and type(BotAucBuy) == 'function' and type(BotAucCount) == 'function'
end

C.ready = cppReady

local gearMod                  -- bots_gear.lua (gear it keeps instead of selling)

function C.setup(huntModule)
    hunt = huntModule
end

function C.setGear(g)
    gearMod = g
end

-- its gil from sales: the server puts it in the delivery box (bots.cpp BotCollectSales takes it out)
function C.collectSales(bot)
    if type(BotCollectSales) ~= 'function' then
        return 0
    end

    local ok, gil = pcall(BotCollectSales, bot:getID())
    if ok and gil and gil > 0 then
        bot:addGil(gil)
        note(string.format('%s collects %d gil from its auction house sales', bot:getName(), gil))
        return gil
    end

    return 0
end

-- loot it keeps rather than sells: gear it can use (now or soon), and now and then something valuable it just likes
-- (the same choice every time for the same bot and item; a hard bargainer keeps more)
local function keeps(bot, id, single)
    if gearMod and gearMod.useful and gearMod.useful(bot, id) then
        return true
    end

    if (single or 0) >= 5000 then
        local thrift = math.max(1, math.min(3, bot:getCharVar('[Bot]Thrift')))
        return (bot:getID() * 31 + id * 17) % 100 < 5 + thrift * 8
    end

    return false
end

-----------------------------------
-- personality
-----------------------------------
function C.personality(bot)
    local style = bot:getCharVar('[Bot]Style')
    if style == 0 then
        local name = weighted(STYLE_WEIGHT)
        for i, s in ipairs(STYLES) do
            if s == name then
                style = i
            end
        end

        bot:setCharVar('[Bot]Style', style)
        bot:setCharVar('[Bot]Craft', rnd(1, 8))
        bot:setCharVar('[Bot]Helm', rnd(1, 4))
        bot:setCharVar('[Bot]Thrift', rnd(1, 3)) -- 1 generous ... 3 hard bargainer
        local gw = {}
        for i, g in ipairs(GOALS) do
            gw[i] = g.weight
        end

        local goal = weighted(gw)
        bot:setCharVar('[Bot]Goal', goal)
        bot:setCharVar('[Bot]GoalN', ({ rnd(2, 7) * 10, rnd(2, 6) * 10, rnd(5, 50) * 10000, 0, rnd(3, 10), 0 })[goal])
        if bot:getGil() < 500 then
            bot:addGil(rnd(START_GIL[1], START_GIL[2])) -- what it brought from home on its first day
        end
    end

    local goal = GOALS[bot:getCharVar('[Bot]Goal')] or GOALS[1]
    return {
        goal = goal, goalN = bot:getCharVar('[Bot]GoalN'),
        style = STYLES[style] or 'allround',
        craft = math.max(1, math.min(8, bot:getCharVar('[Bot]Craft'))),
        helm = HELM_TYPES[math.max(1, math.min(4, bot:getCharVar('[Bot]Helm')))],
        thrift = math.max(1, math.min(3, bot:getCharVar('[Bot]Thrift'))),
    }
end

-- what it does next in town: 'hunt', 'craft', 'gather', 'market' or 'town'
function C.choose(bot)
    local p = C.personality(bot)
    if not cppReady() then
        return math.random() < 0.5 and 'hunt' or 'town' -- (no crafting before the rebuild)
    end

    local weights = {}
    for k, v in pairs(PLAN[p.style]) do
        weights[k] = v
    end

    -- its goal pushes it (until it is reached)
    local rankNow = 1
    pcall(function()
        rankNow = bot:getRank(bot:getNation())
    end)
    local reached = (p.goal.name == 'level' and bot:getMainLvl() >= p.goalN) or (p.goal.name == 'gil' and bot:getGil() >= p.goalN)
        or (p.goal.name == 'rank' and rankNow >= p.goalN)
    if not reached then
        for k, v in pairs(p.goal.push) do
            weights[k] = (weights[k] or 0) + v
        end
    end

    -- level 1-9 adventurers want exp first, whatever their style
    if bot:getMainLvl() < 10 then
        weights.hunt = weights.hunt + 30
    end

    if not C.hasSellables(bot) then
        weights.market = math.floor(weights.market / 4)
    elseif bot:getFreeSlotsCount() <= 2 then
        return 'market' -- (its bag is full: it sells before anything else)
    end

    return weighted(weights)
end

-----------------------------------
-- inventory helpers
-----------------------------------
local function inventory(bot)
    local inv = BotInventory(bot:getID()) or {}
    local count, rows = {}, {}
    for _, r in ipairs(inv) do
        count[r.id] = (count[r.id] or 0) + r.qty
        rows[#rows + 1] = r
    end

    return count, rows
end

local function equippedIds(bot)
    local out = {}
    for slot = 0, 15 do
        local ok, id = pcall(function()
            return bot:getEquipID(slot)
        end)
        if ok and id and id ~= 0 then
            out[id] = true
        end
    end

    return out
end

-- (2026-11-21, Tasou) the launcher's "Auction house prices" rate (main.AH_PRICE_RATE): bots price and bid with it too
local function priceRate()
    local r = tonumber(xi.settings and xi.settings.main and xi.settings.main.AH_PRICE_RATE) or 1
    return math.max(0.1, math.min(10, r))
end

local function priceOf(id)
    local it = craftData().items[id]
    local rate = priceRate()
    local single = it and it[1] or nil
    local stack = it and it[2] or nil
    if rate ~= 1 then
        single = single and math.max(1, math.floor(single * rate)) or nil
        stack = stack and math.max(1, math.floor(stack * rate)) or nil
    end

    return single, stack, it and it[3] or 1, it and it[4] == 1
end

-- seals (traded to Shami for orbs, bots_bcnm.lua) and the orbs themselves are never put on the auction house
local KEEP_FOR_ORBS = {
    [1126] = true, [1127] = true, [2955] = true, [2956] = true, [2957] = true,                 -- seals and crests
    [1551] = true, [1552] = true, [1131] = true, [1177] = true, [1130] = true,                 -- Cloudy .. Moon Orb
    [1175] = true, [1178] = true, [1180] = true, [1553] = true,                                -- Clotho .. Themis Orb
}
-- fair single price of an item (for other modules: bots_bcnm.lua's orbs)
function C.priceOf(id)
    return (priceOf(id))
end

-- items it would put on the auction house: crafted, gathered or looted things with a known fair price
local function sellables(bot, keep)
    local _, rows = inventory(bot)
    local equipped = equippedIds(bot)
    local out = {}
    for _, r in ipairs(rows) do
        local single, _, _, ahOk = priceOf(r.id)
        local crystal = r.id >= 4096 and r.id <= 4103
        if r.ah and ahOk and single and single >= 50 and not equipped[r.id] and not crystal and not TOOL_PRICE[r.id] and r.id ~= 17391 and r.id ~= 17396 and not KEEP_FOR_ORBS[r.id] and not (keep and keep[r.id]) and not keeps(bot, r.id, single) then
            out[#out + 1] = r
        end
    end

    return out
end

-- (bots_trade.lua: what it can put in its bazaar)
function C.sellables(bot)
    return sellables(bot)
end

function C.hasSellables(bot)
    return #sellables(bot) > 0
end

-----------------------------------
-- crafting
-----------------------------------
local function craftLevel(bot, craft)
    local skill = CRAFT_SKILL[craft]
    local ok, real = pcall(function()
        return bot:getCharSkillLevel(skill)
    end)
    return math.floor(((ok and real) or 0) / 10), skill
end

-- at its rank's cap it ranks up (as if it had passed the guild's test item)
local function rankUp(bot, craft)
    local lvl, skill = craftLevel(bot, craft)
    local ok, rank = pcall(function()
        return bot:getSkillRank(skill)
    end)
    rank = (ok and rank) or 0
    if lvl >= (rank + 1) * 10 and rank < 9 then
        pcall(function()
            bot:setSkillRank(skill, rank + 1)
        end)
        return true
    end

    return false
end

-- a recipe of its craft just above its skill (where skill-ups happen), whose materials it can get
local function chooseRecipe(bot, craft, lvl)
    local list, near = {}, {}
    for _, r in ipairs(craftData().recipes) do
        if r[1] == craft then
            if r[2] > lvl and r[2] <= lvl + 6 then
                list[#list + 1] = r
            elseif r[2] >= lvl - 3 and r[2] <= lvl + 10 then
                near[#near + 1] = r
            end
        end
    end

    local count = inventory(bot)
    local made = craftData().made
    local function obtainable(r)
        for _, ing in ipairs(r[4]) do
            if made[ing] and (count[ing] or 0) == 0 then
                return false -- a crafted part it does not have (it may still buy one on the auction house later)
            end
        end

        return true
    end

    for _, pool in ipairs({ list, near }) do
        local ok = {}
        for _, r in ipairs(pool) do
            if obtainable(r) then
                ok[#ok + 1] = r
            end
        end

        if #ok > 0 then
            return pick(ok)
        end
    end

    return nil
end

-- buys what is missing for n syntheses: cheap auction listings first, else from a guild or vendor (gil)
local function buyMaterials(bot, r, n)
    local id = bot:getID()
    local need = {}
    need[r[3]] = n
    for _, ing in ipairs(r[4]) do
        need[ing] = (need[ing] or 0) + n
    end

    local count = inventory(bot)
    local cost, missing = 0, {}
    for item, qty in pairs(need) do
        local short = qty - (count[item] or 0)
        if short > 0 then
            local single = priceOf(item) or 100
            missing[item] = short
            cost = cost + single * short
        end
    end

    if cost == 0 then
        return true
    end

    if bot:getGil() < cost + 300 then
        return false
    end

    local slots = 0
    for _ in pairs(missing) do
        slots = slots + 1
    end

    if bot:getFreeSlotsCount() < slots + 1 then
        return false
    end

    for item, qty in pairs(missing) do
        local single = priceOf(item) or 100
        bot:delGil(single * qty)
        bot:addItem(item, qty)
    end

    return true
end

local function startCraft(bot, st, p)
    -- a synthesis needs a free place for what it makes: with a full bag the server refuses every attempt
    if bot:getFreeSlotsCount() < 1 then
        return false
    end

    rankUp(bot, p.craft)
    local lvl = craftLevel(bot, p.craft)
    local r = chooseRecipe(bot, p.craft, lvl)
    if not r then
        return false
    end

    local n = rnd(SYNTHS[1], SYNTHS[2])
    while n > 1 and not buyMaterials(bot, r, n) do
        n = n - 2
    end

    if n < 1 or not buyMaterials(bot, r, math.max(1, n)) then
        return false
    end

    st.task = { kind = 'craft', recipe = r, left = math.max(1, n), at = now() + rnd(4, 10), craft = p.craft, startLvl = lvl }
    note(string.format('%s crafts %s x%d (%s %d, recipe level %d)', bot:getName(), r[7], math.max(1, n), CRAFT_NAMES[p.craft], lvl, r[2]))
    BotHeal(bot:getID(), false)
    BotStop(bot:getID())
    return true
end

local function thinkCraft(bot, st)
    local task = st.task
    local t = now()
    if t < task.at then
        return
    end

    if task.left <= 0 then
        st.task = nil
        rankUp(bot, task.craft)
        local lvl = craftLevel(bot, task.craft)
        if lvl > task.startLvl and math.random() < 0.3 then
            BotChat(bot:getID(), 0, pick({ 'skill up :)', 'finally a skill up', CRAFT_NAMES[task.craft] .. ' ' .. lvl .. ' now', 'woo ' .. CRAFT_NAMES[task.craft] .. ' up' }))
        end

        return
    end

    local r = task.recipe
    local count = inventory(bot)
    if (count[r[3]] or 0) < 1 then
        st.task = nil
        return
    end

    for _, ing in ipairs(r[4]) do
        if (count[ing] or 0) < 1 then
            st.task = nil
            return
        end
    end

    if bot:getFreeSlotsCount() < 1 then
        st.task = nil -- (bag full: it stops; C.choose sends it to the auction house next)
        return
    end

    BotSynth(bot:getID(), r[3], r[4])
    task.left = task.left - 1
    task.at = t + rnd(SYNTH_EVERY[1], SYNTH_EVERY[2])
end

-----------------------------------
-- the auction house
-----------------------------------
local function ahSpot(bot)
    -- an auction house spot of the crowds in its nation's towns (only towns with an auction house have them)
    local ok, nation = pcall(function()
        return bot:getNation()
    end)
    local zones = HOME[(ok and nation) or 0] or HOME[0]
    local here = {}
    if xi.crowds and xi.crowds.zoneSpots then
        for _, s in ipairs(xi.crowds.zoneSpots(bot:getZoneID()) or {}) do
            if s.kind == 'ah' then
                here[#here + 1] = s
            end
        end

        if #here > 0 then
            return bot:getZoneID(), pick(here)
        end

        for _, z in ipairs(zones) do
            local list = {}
            for _, s in ipairs(xi.crowds.zoneSpots(z) or {}) do
                if s.kind == 'ah' then
                    list[#list + 1] = s
                end
            end

            if #list > 0 then
                return z, pick(list)
            end
        end
    end

    return nil
end

local function startMarket(bot, st, p)
    local zoneId, spot = ahSpot(bot)
    if not spot then
        return false
    end

    st.task = { kind = 'market', at = now() + rnd(6, 12), sold = 0, bought = 0, steps = rnd(3, 7), thrift = p.thrift, craft = p.craft }
    BotHeal(bot:getID(), false)
    if bot:getZoneID() ~= zoneId then
        if xi.navguard then xi.navguard.setPos(bot, spot.x, spot.y, spot.z, spot.rot or 0, zoneId, nil) else bot:setPos(spot.x, spot.y, spot.z, spot.rot or 0, zoneId) end
        return 'zoning'
    end

    BotMoveTo(bot:getID(), spot.x, spot.y, spot.z)
    return true
end

-- materials of its own craft near its level (it does not sell those, it may buy them)
local function wanted(bot, craft)
    local lvl = craftLevel(bot, craft)
    local out = {}
    for _, r in ipairs(craftData().recipes) do
        if r[1] == craft and r[2] > lvl - 2 and r[2] <= lvl + 8 then
            out[r[3]] = true
            for _, ing in ipairs(r[4]) do
                out[ing] = true
            end
        end
    end

    return out
end

local function marketStep(bot, task)
    local id = bot:getID()
    local keep = wanted(bot, task.craft)
    if not task.collected then
        task.collected = true
        C.collectSales(bot) -- (the gil from what sold since its last visit)
    end

    -- 1. sell: one listing per step while it has fewer than MAX_LISTINGS up
    if BotAucCount(id) < MAX_LISTINGS then
        -- full stacks first; a partial stack is mostly kept until it is full (now and then a single goes up)
        local list = sellables(bot, keep)
        table.sort(list, function(x, y)
            return (x.qty >= x.stack and 1 or 0) > (y.qty >= y.stack and 1 or 0)
        end)
        for _, r in ipairs(list) do
            local single, stackPrice, stackSize = priceOf(r.id)
            local keepForNow = stackSize > 1 and r.qty < stackSize and math.random() > 0.25
            local mood = 0.85 + math.random() * 0.3 + (task.thrift - 2) * 0.05
            if keepForNow then
                -- (waits for a full stack)
            elseif stackSize > 1 and r.qty == stackSize and stackPrice and stackPrice > 0 then
                if BotAucSell(id, r.id, math.max(1, math.floor(stackPrice * mood)), true) then
                    note(string.format('%s puts a stack of item %d on the auction house for %d gil', bot:getName(), r.id, math.floor(stackPrice * mood)))
                    task.sold = task.sold + 1
                    return
                end
            elseif BotAucSell(id, r.id, math.max(1, math.floor(single * mood)), false) then
                note(string.format('%s puts item %d on the auction house for %d gil', bot:getName(), r.id, math.floor(single * mood)))
                task.sold = task.sold + 1
                return
            end
        end
    end

    -- 2. buy: a bargain (below fair, more so for a hard bargainer) or a material it needs at about fair price
    if task.bought >= 2 then
        return
    end

    local gil = bot:getGil()
    local budget = gil * 0.3
    local listings = BotAucListings(id, 200) or {}
    for _ = 1, 20 do
        if #listings == 0 then
            break
        end

        local l = table.remove(listings, rnd(1, #listings))
        local single, stackPrice = priceOf(l.id)
        local fair = l.stack and stackPrice or single
        if fair and fair > 0 and l.price <= budget then
            local limit = keep[l.id] and fair * 1.05 or fair * (0.85 - (task.thrift - 1) * 0.1)
            if l.price <= limit and (keep[l.id] or math.random() < 0.4) then
                if BotAucBuy(id, l.id, l.price, l.stack) then
                    note(string.format('%s bids %d gil for item %d%s (seller %d)', bot:getName(), l.price, l.id, l.stack and ' (stack)' or '', l.seller))
                    task.bought = task.bought + 1
                    return
                end
            end
        end
    end
end

local function thinkMarket(bot, st)
    local task = st.task
    local t = now()
    if BotIsMoving(bot:getID()) or t < task.at then
        return
    end

    if task.steps <= 0 then
        note(string.format('%s leaves the auction house: %d listed, %d bought (%d things it could sell, %d gil)', bot:getName(), task.sold, task.bought,
            #sellables(bot, wanted(bot, task.craft)), bot:getGil()))
        st.task = nil
        return
    end

    marketStep(bot, task)
    task.steps = task.steps - 1
    task.at = t + rnd(MARKET_STEP[1], MARKET_STEP[2])
end

-----------------------------------
-- HELM gathering
-----------------------------------
local function helmInfo(kind)
    local ok, info = pcall(function()
        return xi.helm.dataTable[xi.helmType[kind]]
    end)
    return ok and info or nil
end

local function gatherZone(bot, kind)
    local info = helmInfo(kind)
    if not info or not info.zone then
        return nil
    end

    local lvl, options = bot:getMainLvl(), {}
    for _, z in ipairs(HELM_ZONES[kind]) do
        if lvl >= z[2] and info.zone[z[1]] then
            options[#options + 1] = z[1]
        end
    end

    return #options > 0 and options[#options - math.min(#options - 1, rnd(0, 1))] or nil
end

local function realPlayersIn(zone)
    local out = {}
    for _, p in ipairs(zone:getPlayers()) do
        if not BotIsBot(p:getID()) then
            out[#out + 1] = p
        end
    end

    return out
end

local function freePoints(zone, kind, botId)
    local ok, list = pcall(function()
        return zone:queryEntitiesByName(HELM_NPC[kind])
    end)
    if not ok or not list then
        return {}
    end

    local players = realPlayersIn(zone)
    local out = {}
    for _, npc in ipairs(list) do
        local ok2, visible = pcall(function()
            return npc:getStatus() == 0 -- shown (a moved point is hidden until it comes back)
        end)
        local np = npc:getPos()
        local near = false
        for _, p in ipairs(players) do
            if d2(p:getPos(), np) <= PLAYER_SPACE * PLAYER_SPACE then
                near = true
            end
        end

        local owner = busyPoint[npc:getID()]
        if (not ok2 or visible) and not near and (not owner or owner == botId) then
            out[#out + 1] = npc
        end
    end

    return out
end

local function startGather(bot, st, p)
    local kind = p.helm
    local zoneId = gatherZone(bot, kind)
    if not zoneId then
        kind = 'LOGGING' -- every nation has an easy logging area nearby
        zoneId = gatherZone(bot, kind)
    end

    local info = helmInfo(kind)
    if not zoneId or not info then
        return false
    end

    local tool = info.tool
    local count = inventory(bot)
    if (count[tool] or 0) < 2 then
        local n = rnd(TOOLS_BUY[1], TOOLS_BUY[2])
        local price = TOOL_PRICE[tool] or 300
        if bot:getGil() < price * n + 200 or bot:getFreeSlotsCount() < 3 then
            return false
        end

        bot:delGil(price * n)
        bot:addItem(tool, n)
    end

    local zone = GetZone(zoneId)
    local points = zone and freePoints(zone, kind, bot:getID()) or {}
    if #points == 0 then
        return false
    end

    local npc = pick(points)
    local np = npc:getPos()
    st.task = { kind = 'gather', helm = kind, tool = tool, zone = zoneId, point = npc:getID(), tries = rnd(GATHER_TRIES[1], GATHER_TRIES[2]),
                at = now() + 4, untilT = now() + rnd(GATHER_MIN[1], GATHER_MIN[2]) * 60, lastHP = 100 }
    busyPoint[npc:getID()] = bot:getID()
    BotHeal(bot:getID(), false)
    st.life = nil
    local a = math.random() * 2 * math.pi
    if bot:getZoneID() ~= zoneId then
        if xi.navguard then xi.navguard.setPos(bot, np.x + 6 * math.cos(a), np.y, np.z + 6 * math.sin(a), 0, zoneId, np) else bot:setPos(np.x + 6 * math.cos(a), np.y, np.z + 6 * math.sin(a), 0, zoneId) end
        return 'zoning'
    end

    BotMoveTo(bot:getID(), np.x, np.y, np.z)
    return true
end

local function endGather(bot, st)
    local task = st.task
    if task and task.point and busyPoint[task.point] == bot:getID() then
        busyPoint[task.point] = nil
    end

    st.task = nil
    return 'home'
end

local function thinkGather(bot, st)
    local task = st.task
    local id = bot:getID()
    local t = now()
    local zone = bot:getZone()
    if not zone or bot:getZoneID() ~= task.zone then
        return -- (still zoning in)
    end

    if bot:isDead() then
        endGather(bot, st)
        return 'dead'
    end

    -- attacked while gathering: fight back first (bots_hunt.lua)
    local hp = bot:getHPP()
    if (hp < task.lastHP or task.fighting) and hunt and hunt.defend then
        task.fighting = hunt.defend(bot, st)
    end

    task.lastHP = hp
    if task.fighting then
        return
    end

    if t >= task.untilT then
        return endGather(bot, st)
    end

    if BotIsMoving(id) or t < task.at then
        return
    end

    local count = inventory(bot)
    if (count[task.tool] or 0) == 0 then
        return endGather(bot, st) -- out of tools: home to sell what it found
    end

    if bot:getFreeSlotsCount() == 0 then
        return endGather(bot, st)
    end

    local npc = GetNPCByID and GetNPCByID(task.point) or nil
    if not npc or task.tries <= 0 then
        -- the next point
        busyPoint[task.point] = nil
        local points = freePoints(zone, task.helm, id)
        if #points == 0 then
            return endGather(bot, st)
        end

        npc = pick(points)
        task.point, task.tries = npc:getID(), rnd(GATHER_TRIES[1], GATHER_TRIES[2])
        busyPoint[task.point] = id
        local np = npc:getPos()
        BotMoveTo(id, np.x, np.y, np.z)
        task.at = t + 2
        return
    end

    local np = npc:getPos()
    if d2(np, bot:getPos()) > 4 * 4 then
        BotMoveTo(id, np.x, np.y, np.z)
        task.at = t + 2
        return
    end

    BotTrade(id, npc, task.tool, 1)
    task.tries = task.tries - 1
    task.at = t + rnd(5, 9)
end

-----------------------------------
-- fishing (the minigame is skipped): rod and bait, a port town's dock, the server's own fish for that place
-----------------------------------
local ROD, BAIT = 17391, 17396           -- Willow Fishing Rod, Little Worm
local ROD_PRICE, BAIT_PRICE = 250, 4
local FISH_SKILL = 48
local FISH_MIN = { 15, 40 }              -- minutes at the water
local BITE_EVERY = { 20, 55 }            -- seconds between two bites
local FISH_HOME = { [0] = { 232 }, [1] = { 236 }, [2] = { 240 } }
local ANIM_FISHING, ANIM_CAUGHT, ANIM_STOP = 38, 39, 43

-- (2026-11-21, Sunie: a bot fishing in the middle of Port San d'Oria) bot players fish only at spots marked at the
-- water with !crowd mark fish (crowds_spots_user.lua). Before, any of the crowd's standing spots in the port was
-- used, most of them nowhere near the water. A town with no fishing spot marked has no bots fishing.
local function fishSpots(zoneId)
    local out = {}
    if xi.crowds and xi.crowds.zoneSpots then
        for _, s in ipairs(xi.crowds.zoneSpots(zoneId) or {}) do
            if s.kind == 'fish' then
                out[#out + 1] = s
            end
        end
    end

    return out
end

local function fishZones(bot)
    local ok, nation = pcall(function()
        return bot:getNation()
    end)
    local list = {}
    for _, z in ipairs(FISH_HOME[(ok and nation) or 0] or FISH_HOME[0]) do
        list[#list + 1] = z
    end

    if bot:getMainLvl() >= 15 then
        for _, z in ipairs({ 248, 249 }) do -- Selbina, Mhaura
            list[#list + 1] = z
        end
    end

    local out = {}
    for _, z in ipairs(list) do
        if (craftData().fishing or {})[z] and #fishSpots(z) > 0 then
            out[#out + 1] = z
        end
    end

    return out
end

local function setAnim(bot, a)
    pcall(function()
        bot:setAnimation(a)
    end)
end

local function startFish(bot, st, p)
    local zones = fishZones(bot)
    if #zones == 0 or not xi.crowds or not xi.crowds.zoneSpots then
        return false
    end

    local zoneId = pick(zones)
    local spots = fishSpots(zoneId)

    if #spots == 0 then
        return false
    end

    local count = inventory(bot)
    local cost = ((count[ROD] or 0) == 0 and ROD_PRICE or 0) + ((count[BAIT] or 0) < 6 and BAIT_PRICE * 36 or 0)
    if bot:getGil() < cost + 200 or bot:getFreeSlotsCount() < 4 then
        return false
    end

    if (count[ROD] or 0) == 0 then
        bot:delGil(ROD_PRICE)
        bot:addItem(ROD, 1)
    end

    if (count[BAIT] or 0) < 6 then
        bot:delGil(BAIT_PRICE * 36)
        bot:addItem(BAIT, 36)
    end

    -- Only the rod is worn. The bait used to be worn too: when the worn stack ran out (others still in the bag) the
    -- ammo slot kept pointing at that bag place, and the next thing caught landed in it - "Item 14117 (rusty
    -- leggings) is not equipable in equip slot 3". The catches here do not need bait to be equipped.
    pcall(function()
        bot:equipItem(ROD)
        if bot:getEquipID(3) == BAIT then
            bot:unequipItem(3)
        end
    end)
    local spot = pick(spots)
    st.task = { kind = 'fish', zone = zoneId, at = now() + rnd(8, 15), untilT = now() + rnd(FISH_MIN[1], FISH_MIN[2]) * 60, caught = 0 }
    BotHeal(bot:getID(), false)
    st.life = nil
    note(string.format('%s goes fishing (fishing %d)', bot:getName(), math.floor(((bot:getCharSkillLevel(FISH_SKILL) or 0)) / 10)))
    if bot:getZoneID() ~= zoneId then
        if xi.navguard then xi.navguard.setPos(bot, spot.x, spot.y, spot.z, spot.rot or 0, zoneId, nil) else bot:setPos(spot.x, spot.y, spot.z, spot.rot or 0, zoneId) end
        return 'zoning'
    end

    BotMoveTo(bot:getID(), spot.x, spot.y, spot.z)
    return true
end

local function endFish(bot, st)
    setAnim(bot, ANIM_STOP)
    local task = st.task
    st.task = nil
    if task and task.caught > 0 then
        note(string.format('%s stops fishing: %d caught', bot:getName(), task.caught))
    end
end


-- one bait used up. The last one is taken off first: the server would free an item that is still worn (and then save
-- garbage for that slot, which crashes the next login)
local function useBait(bot)
    pcall(function()
        if bot:getItemCount(BAIT) <= 1 and bot:getEquipID(3) == BAIT then
            bot:unequipItem(3)
        end
    end)

    bot:delItem(BAIT, 1)
end

local function thinkFish(bot, st)
    local task = st.task
    local t = now()
    if bot:getZoneID() ~= task.zone or BotIsMoving(bot:getID()) then
        return
    end

    if bot:isEngaged() or bot:isDead() then
        return endFish(bot, st)
    end

    local count = inventory(bot)
    if t >= task.untilT or (count[BAIT] or 0) == 0 or (count[ROD] or 0) == 0 or bot:getFreeSlotsCount() == 0 then
        endFish(bot, st)
        return
    end

    if not task.casting then
        task.casting = true
        setAnim(bot, ANIM_FISHING)
    end

    if t < task.at then
        return
    end

    task.at = t + rnd(BITE_EVERY[1], BITE_EVERY[2])
    -- something bites: what lives here, rarer fish less often, fish far above its skill seldom land
    local real = bot:getCharSkillLevel(FISH_SKILL) or 0
    local skill = math.floor(real / 10)
    local weights = {}
    for i, f in ipairs(craftData().fishing[task.zone] or {}) do
        if f[2] <= skill + 15 then
            weights[i] = math.max(1, f[3])
        end
    end

    if next(weights) == nil then
        return endFish(bot, st)
    end

    local f = craftData().fishing[task.zone][weighted(weights)]
    local landChance = math.max(0.1, math.min(0.9, 0.85 - (f[2] - skill) * 0.04))
    if math.random() < landChance then
        bot:addItem(f[1], 1)
        useBait(bot)
        task.caught = task.caught + 1
        setAnim(bot, ANIM_CAUGHT)
        task.casting = false
        -- a skill-up for a fish above its skill (era style: 0.1 - 0.3 at a time, up to 100)
        if f[2] > skill and real < 1000 and math.random() < 0.35 then
            pcall(function()
                bot:setSkillLevel(FISH_SKILL, real + rnd(1, 3))
            end)
        end
    elseif math.random() < 0.5 then
        useBait(bot) -- it got away with the bait
    end
end

-----------------------------------
-- the bot's next thing to do in town (called from bots.lua); returns true / 'zoning' when a task started
-----------------------------------
function C.start(bot, st, kind)
    if not cppReady() then
        return false
    end

    local p = C.personality(bot)
    if kind == 'craft' then
        return startCraft(bot, st, p)
    elseif kind == 'market' then
        return startMarket(bot, st, p)
    elseif kind == 'gather' then
        return startGather(bot, st, p)
    elseif kind == 'fish' then
        return startFish(bot, st, p)
    end

    return false
end

-- one second of the current task; returns 'zoning', 'home' (back to town) or nil
function C.think(bot, st)
    local task = st.task
    if not task then
        return
    end

    if not cppReady() then
        st.task = nil
        return
    end

    if task.kind == 'craft' then
        return thinkCraft(bot, st)
    elseif task.kind == 'market' then
        return thinkMarket(bot, st)
    elseif task.kind == 'gather' then
        return thinkGather(bot, st)
    elseif task.kind == 'fish' then
        return thinkFish(bot, st)
    end

    st.task = nil
end

-- it joined your party: drop what it was doing
function C.drop(bot, st)
    if st.task then
        if st.task.point and busyPoint[st.task.point] == bot:getID() then
            busyPoint[st.task.point] = nil
        end

        st.task = nil
    end
end

function C.describe(st)
    local task = st.task
    if not task then
        return nil
    end

    if task.kind == 'craft' then
        return string.format('crafting (%s, %s)', CRAFT_NAMES[task.craft], task.recipe[7])
    elseif task.kind == 'market' then
        return 'at the auction house'
    elseif task.kind == 'gather' then
        return 'gathering (' .. string.lower(task.helm) .. ')'
    elseif task.kind == 'fish' then
        return string.format('fishing (%d caught)', task.caught or 0)
    end

    return task.kind
end

-- for bots_growth.lua: what it likes to spend time on (weights), and its craft
function C.planWeights(bot)
    local p = C.personality(bot)
    local w = {}
    for k, v in pairs(PLAN[p.style]) do
        w[k] = v
    end

    for k, v in pairs(p.goal.push) do
        w[k] = (w[k] or 0) + v
    end

    w.town = nil
    return w
end

function C.craftOf(bot)
    local p = C.personality(bot)
    local lvl, skill = craftLevel(bot, p.craft)
    return p.craft, lvl, skill, CRAFT_NAMES[p.craft]
end

C.rankUp = rankUp

function C.goalName(bot)
    return C.personality(bot).goal.name
end

function C.styleName(bot)
    local p = C.personality(bot)
    local goal = ({ level = 'reach level ' .. p.goalN, craft = 'reach ' .. p.goalN .. ' in ' .. CRAFT_NAMES[p.craft],
                    gil = 'save up ' .. p.goalN .. ' gil', helm = 'gather a lot', rank = 'reach rank ' .. p.goalN,
                    quests = 'do every quest in town' })[p.goal.name]
    return p.style, CRAFT_NAMES[p.craft], string.lower(p.helm), craftLevel(bot, p.craft), goal
end

return C
