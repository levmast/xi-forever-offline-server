-----------------------------------
-- Tetra Master (XI: Forever Offline): the rules engine.
--
-- A 1-to-1 port of the rules in Nalfey's TetraMaster addon (github.com/Nalfey/TetraMaster: card.lua, place_card.lua,
-- init.lua, game.lua), split away from the LOVE drawing code so the server can run matches. Same rules, same order of
-- dice rolls; tetramaster tests (FFXISOLO/dev/tetramaster-tests) replay matches in both and compare them move by move.
--
-- Pure Lua 5.1: no game objects, no globals, no drawing. Randomness comes from the rng passed in (rng(lo, hi) returns
-- an integer in [lo, hi], like math.random), so the server owns every roll and both players see the same match.
-- Every action returns a list of events the in-game board plays back as animations.
--
-- Board: cells[x][y], x and y 1-4. A cell is nil (empty), { block = 1 or 2 } (a blocked cell, two looks) or a card.
-- Sides: 'blue' and 'red'.
-- A library: registers nothing.
-----------------------------------
local Cards = require('modules/custom/lua/tetramaster_cards')

local R = {}

R.SIDES     = { 'blue', 'red' }
R.HAND_SIZE = 5

R.DIRS =
{
    { name = 'up',        dx =  0, dy = -1, counter = 'down'      },
    { name = 'down',      dx =  0, dy =  1, counter = 'up'        },
    { name = 'left',      dx = -1, dy =  0, counter = 'right'     },
    { name = 'right',     dx =  1, dy =  0, counter = 'left'      },
    { name = 'upleft',    dx = -1, dy = -1, counter = 'downright' },
    { name = 'upright',   dx =  1, dy = -1, counter = 'downleft'  },
    { name = 'downleft',  dx = -1, dy =  1, counter = 'upright'   },
    { name = 'downright', dx =  1, dy =  1, counter = 'upleft'    },
}

-- Arrow sets are stored as an 8-bit mask, bit n-1 = R.DIRS[n] (up = 1, down = 2, ... downright = 128).
local DIR_BIT = {}
for i, d in ipairs(R.DIRS) do
    DIR_BIT[d.name] = 2 ^ (i - 1)
end

function R.hasArrow(mask, name)
    local b = DIR_BIT[name]
    return math.floor(mask / b) % 2 == 1
end

function R.arrowsFromList(list)
    local mask = 0
    for _, name in ipairs(list) do
        if DIR_BIT[name] and not R.hasArrow(mask, name) then
            mask = mask + DIR_BIT[name]
        end
    end

    return mask
end

function R.arrowsToList(mask)
    local list = {}
    for _, d in ipairs(R.DIRS) do
        if R.hasArrow(mask, d.name) then
            list[#list + 1] = d.name
        end
    end

    return list
end

local function opposite(side)
    return side == 'blue' and 'red' or 'blue'
end

R.opposite = opposite

-----------------------------------
-- Cards
-----------------------------------

-- A hidden stat: printed digit * 16 plus 0-15 (card.lua roll_hidden_stat).
local function rollHidden(rng, digit)
    local base = digit * 16
    return rng(base, base + 15)
end

-- A new copy of card <id>: random arrows (each one 1 in 2), then hidden attack, physical and magical defence.
-- Roll order matches card.lua Card:initialize. Returns nil for an unknown id.
function R.newCard(rng, id)
    local base = Cards.get(id)
    if base == nil then
        return nil
    end

    local mask = 0
    for i = 1, #R.DIRS do
        if rng(1, 2) == 1 then
            mask = mask + 2 ^ (i - 1)
        end
    end

    return
    {
        id     = id,
        type   = base.type,
        arrows = mask,
        atk    = rollHidden(rng, base.attack),
        pdef   = rollHidden(rng, base.pdef),
        mdef   = rollHidden(rng, base.mdef),
    }
end

-- Copies a saved card (from a collection) for a match, so the match can change its side and class freely.
function R.copyCard(card)
    return
    {
        id     = card.id,
        type   = card.type,
        arrows = card.arrows,
        atk    = card.atk,
        pdef   = card.pdef,
        mdef   = card.mdef,
        uid    = card.uid,
    }
end

-- The code a card shows: printed attack, its current class, printed defences (hidden stats / 16).
function R.cardCode(card)
    local hex = '0123456789ABCDEF'
    local function d(v)
        local n = math.floor(v / 16) + 1
        return hex:sub(n, n)
    end

    return d(card.atk) .. card.type .. d(card.pdef) .. d(card.mdef)
end

-----------------------------------
-- Board
-----------------------------------

-- A new board with 0-6 blocked cells (init.lua init_grid): count, then x, y and look for each new block.
function R.newBoard(rng)
    local cells = {}
    for x = 1, 4 do
        cells[x] = {}
    end

    local blocks = rng(0, 6)
    local placed = 0
    while placed < blocks do
        local x = rng(1, 4)
        local y = rng(1, 4)
        if cells[x][y] == nil then
            cells[x][y] = { block = (rng(1, 2) == 1) and 2 or 1 }
            placed = placed + 1
        end
    end

    return cells
end

local function cardAt(cells, x, y)
    if x < 1 or x > 4 or y < 1 or y > 4 then
        return nil
    end

    local c = cells[x][y]
    if c ~= nil and c.side ~= nil then
        return c
    end

    return nil
end

R.cardAt = cardAt

-----------------------------------
-- Matches
-----------------------------------

-- opts: { rng = function, hands = { blue = { card, ... }, red = { card, ... } }, first = 'blue' | 'red',
--         cells = (optional, a board from R.newBoard) }
-- Cards in the hands are copied. Returns the match.
function R.newMatch(opts)
    local m =
    {
        rng     = opts.rng,
        cells   = opts.cells or R.newBoard(opts.rng),
        hands   = { blue = {}, red = {} },
        turn    = opts.first or 'blue',
        pending = nil,    -- set while the player who placed a card must choose which battle to fight
        over    = false,
        moves   = 0,
    }

    for _, side in ipairs(R.SIDES) do
        for _, card in ipairs(opts.hands[side]) do
            local c = R.copyCard(card)
            c.owner = side      -- who brought the card (used for the card exchange at the end)
            m.hands[side][#m.hands[side] + 1] = c
        end
    end

    return m
end

-- Free cells, in x then y order.
function R.freeCells(m)
    local list = {}
    for x = 1, 4 do
        for y = 1, 4 do
            if m.cells[x][y] == nil then
                list[#list + 1] = { x = x, y = y }
            end
        end
    end

    return list
end

-- Battle numbers for attacker vs defender by the attacker's class (place_card.lua get_battle_stat_values).
local function battleStats(a, d)
    if a.type == 'M' then
        return a.atk, d.mdef
    elseif a.type == 'X' then
        return a.atk, math.min(d.pdef, d.mdef)
    elseif a.type == 'A' then
        return math.max(a.atk, a.pdef, a.mdef), math.min(d.atk, d.pdef, d.mdef)
    end

    return a.atk, d.pdef -- 'P' and anything unknown
end

R.battleStats = battleStats

-- Each side rolls 0..its power and keeps power - roll; the attacker must end strictly higher (roll_card_battle).
local function rollBattle(rng, a, d)
    local ap, dp = battleStats(a, d)
    local aFinal = ap - rng(0, ap)
    local dFinal = dp - rng(0, dp)
    return { attacker_power = ap, defender_power = dp, attacker_final = aFinal, defender_final = dFinal,
             attacker_wins = aFinal > dFinal }
end

-- The winner of a battle may move up a class: P or M to X (1 in 64), X to A (1 in 128).
local function maybeUpgrade(rng, card, x, y, events)
    local before = card.type
    if card.type == 'P' or card.type == 'M' then
        if rng(1, 64) == 1 then
            card.type = 'X'
        end
    elseif card.type == 'X' then
        if rng(1, 128) == 1 then
            card.type = 'A'
        end
    end

    if card.type ~= before then
        events[#events + 1] = { type = 'upgrade', x = x, y = y, from = before, to = card.type }
    end
end

local function flip(card, x, y, side, events, ev)
    card.side = side
    ev.x, ev.y, ev.side = x, y, side
    events[#events + 1] = ev
end

-- Cards the card at (ox, oy) points at that are not on the winner's side (collect_arrow_targets).
local function arrowTargets(cells, ox, oy, winner, seen)
    local out = {}
    local card = cardAt(cells, ox, oy)
    if card == nil then
        return out
    end

    for _, d in ipairs(R.DIRS) do
        if R.hasArrow(card.arrows, d.name) then
            local nx, ny = ox + d.dx, oy + d.dy
            local key = nx * 10 + ny
            if not seen[key] then
                local t = cardAt(cells, nx, ny)
                if t ~= nil and t.side ~= winner then
                    seen[key] = true
                    out[#out + 1] = { x = nx, y = ny, card = t, ox = ox, oy = oy }
                end
            end
        end
    end

    return out
end

-- Battles the placed card can start: an enemy card it points at that points back.
local function pendingBattles(m, px, py)
    local list = {}
    local placed = cardAt(m.cells, px, py)
    for _, d in ipairs(R.DIRS) do
        local def = cardAt(m.cells, px + d.dx, py + d.dy)
        if def ~= nil and def.side ~= placed.side
            and R.hasArrow(placed.arrows, d.name) and R.hasArrow(def.arrows, d.counter) then
            list[#list + 1] = { x = px + d.dx, y = py + d.dy, dir = d.name }
        end
    end

    return list
end

local function fight(m, px, py, battle, events)
    local placed = cardAt(m.cells, px, py)
    local def    = cardAt(m.cells, battle.x, battle.y)
    local res    = rollBattle(m.rng, placed, def)

    events[#events + 1] =
    {
        type = 'battle', ax = px, ay = py, dx = battle.x, dy = battle.y,
        attacker_power = res.attacker_power, defender_power = res.defender_power,
        attacker_final = res.attacker_final, defender_final = res.defender_final,
        attacker_wins  = res.attacker_wins,
    }

    if res.attacker_wins then
        -- the loser flips, then one wave of combos from the loser and then from the attacker
        local winner = placed.side
        flip(def, battle.x, battle.y, winner, events, { type = 'capture' })

        local seen  = { [battle.x * 10 + battle.y] = true }
        local combo = arrowTargets(m.cells, battle.x, battle.y, winner, seen)
        for _, f in ipairs(arrowTargets(m.cells, px, py, winner, seen)) do
            combo[#combo + 1] = f
        end

        for i, f in ipairs(combo) do
            flip(f.card, f.x, f.y, winner, events, { type = 'combo', count = i, from_x = f.ox, from_y = f.oy })
        end

        maybeUpgrade(m.rng, placed, px, py, events)
    else
        -- the placed card loses: it takes the cards of its own side it points at with it, then flips itself
        local winner = def.side
        local loser  = placed.side
        local n = 0
        for _, d in ipairs(R.DIRS) do
            if R.hasArrow(placed.arrows, d.name) then
                local adj = cardAt(m.cells, px + d.dx, py + d.dy)
                if adj ~= nil and adj ~= placed and adj.side == loser then
                    n = n + 1
                    flip(adj, px + d.dx, py + d.dy, winner, events, { type = 'combo', count = n, from_x = px, from_y = py })
                end
            end
        end

        flip(placed, px, py, winner, events, { type = 'capture' })
        maybeUpgrade(m.rng, def, battle.x, battle.y, events)
    end
end

local function countSide(m, side)
    local n = 0
    for x = 1, 4 do
        for y = 1, 4 do
            local c = cardAt(m.cells, x, y)
            if c ~= nil and c.side == side then
                n = n + 1
            end
        end
    end

    return n
end

function R.score(m)
    return countSide(m, 'blue'), countSide(m, 'red')
end

-- 'blue', 'red' or 'draw', and whether it was a perfect game (the loser has no cards on the board).
function R.result(m)
    local b, r = R.score(m)
    if b == r then
        return 'draw', false
    elseif b > r then
        return 'blue', r == 0
    end

    return 'red', b == 0
end

local function endTurn(m, events)
    m.pending = nil
    m.moves   = m.moves + 1
    if #m.hands.blue == 0 and #m.hands.red == 0 then
        m.over = true
        local b, r = R.score(m)
        local winner, perfect = R.result(m)
        events[#events + 1] = { type = 'end', blue = b, red = r, winner = winner, perfect = perfect }
    else
        m.turn = opposite(m.turn)
        events[#events + 1] = { type = 'turn', side = m.turn }
    end
end

-- Keeps fighting while there are battles. With more than one, the player chooses (m.pending is set and the
-- function returns); the server then calls R.chooseBattle.
local function resolveBattles(m, events)
    while true do
        local px, py = m.placedX, m.placedY
        local list = pendingBattles(m, px, py)
        if #list == 0 then
            endTurn(m, events)
            return
        end

        if #list > 1 then
            m.pending = list
            events[#events + 1] = { type = 'choose', side = m.turn, options = list }
            return
        end

        fight(m, px, py, list[1], events)
    end
end

-- Places card number <handIndex> of <side>'s hand at (x, y).
-- Returns events, or nil and a reason when the move is not allowed.
function R.place(m, side, handIndex, x, y)
    if m.over then
        return nil, 'over'
    elseif m.pending then
        return nil, 'choose a battle first'
    elseif side ~= m.turn then
        return nil, 'not your turn'
    elseif type(x) ~= 'number' or type(y) ~= 'number' or x < 1 or x > 4 or y < 1 or y > 4 or m.cells[x][y] ~= nil then
        return nil, 'cell not free'
    end

    local hand = m.hands[side]
    local card = hand[handIndex]
    if card == nil then
        return nil, 'no such card'
    end

    table.remove(hand, handIndex)
    card.side = side
    m.cells[x][y] = card
    m.placedX, m.placedY = x, y

    local events = { { type = 'place', side = side, x = x, y = y, id = card.id, arrows = card.arrows, code = R.cardCode(card) } }

    -- cards it points at that do not point back are taken at once, before any battle
    for _, d in ipairs(R.DIRS) do
        if R.hasArrow(card.arrows, d.name) then
            local def = cardAt(m.cells, x + d.dx, y + d.dy)
            if def ~= nil and def.side ~= side and not R.hasArrow(def.arrows, d.counter) then
                flip(def, x + d.dx, y + d.dy, side, events, { type = 'capture' })
            end
        end
    end

    resolveBattles(m, events)
    return events
end

-- Picks battle number <index> from m.pending. Returns events, or nil and a reason.
function R.chooseBattle(m, side, index)
    if not m.pending then
        return nil, 'nothing to choose'
    elseif side ~= m.turn then
        return nil, 'not your turn'
    end

    local battle = m.pending[index]
    if battle == nil then
        return nil, 'no such battle'
    end

    m.pending = nil
    local events = {}
    fight(m, m.placedX, m.placedY, battle, events)
    resolveBattles(m, events)
    return events
end

-- Cards the winner may take at the end: the loser's own cards (the ones they brought). Perfect game: all of them.
function R.loserCards(m)
    local winner = R.result(m)
    if winner == 'draw' then
        return {}
    end

    local loser = opposite(winner)
    local list = {}
    for x = 1, 4 do
        for y = 1, 4 do
            local c = cardAt(m.cells, x, y)
            if c ~= nil and c.owner == loser then
                list[#list + 1] = c
            end
        end
    end

    return list
end

return R
