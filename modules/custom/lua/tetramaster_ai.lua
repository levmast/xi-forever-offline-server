-----------------------------------
-- Tetra Master (XI: Forever Offline): computer opponents.
--
--   easy   - Nalfey's AI (hand.lua Hand:ai_move): a random free cell, a random card, a random battle. Same rolls.
--   normal - tries every card on every free cell and plays the one that leaves it the most cards ahead, counting
--            each battle by its real odds of winning.
--   hard   - like normal, then looks at the other player's best answer to its 10 best moves.
--
-- Used by NPC card players, squad mates and bots. A library: registers nothing.
-----------------------------------
local R = require('modules/custom/lua/tetramaster_rules')

local A = {}

A.LEVELS = { 'easy', 'normal', 'hard' }
A.HARD_CANDIDATES = 10 -- moves the hard level looks at more closely

-- Chance that a card with <ap> beats <dp>: each side keeps a whole number from 0 to its power (uniform), and the
-- attacker must end strictly higher.
function A.winChance(ap, dp)
    local wins = 0
    for a = 0, ap do
        wins = wins + math.min(a, dp + 1)
    end

    return wins / ((ap + 1) * (dp + 1))
end

local function cloneMatch(m)
    local c =
    {
        cells   = {},
        hands   = { blue = {}, red = {} },
        turn    = m.turn,
        pending = nil,
        over    = m.over,
        moves   = m.moves,
        placedX = m.placedX,
        placedY = m.placedY,
    }

    for x = 1, 4 do
        c.cells[x] = {}
        for y = 1, 4 do
            local cell = m.cells[x][y]
            if cell ~= nil then
                local copy = {}
                for k, v in pairs(cell) do
                    copy[k] = v
                end
                c.cells[x][y] = copy
            end
        end
    end

    for _, side in ipairs(R.SIDES) do
        for i, card in ipairs(m.hands[side]) do
            local copy = {}
            for k, v in pairs(card) do
                copy[k] = v
            end
            c.hands[side][i] = copy
        end
    end

    return c
end

-- A fixed outcome for the "what if" copies: the attacker rolls 0 and the defender everything (attacker wins with
-- its full power) or the other way round, and no class upgrades.
local function fixedRng(attackerWins)
    local n = 0
    return function(lo, hi)
        if lo == 0 then
            n = n + 1
            local attackerRoll = (n % 2 == 1)
            if attackerWins then
                return attackerRoll and lo or hi
            end
            return attackerRoll and hi or lo
        end
        return hi -- upgrade rolls (1..64 / 1..128): never 1
    end
end

local function lead(m, side)
    local b, r = R.score(m)
    if side == 'blue' then
        return b - r
    end
    return r - b
end

-- The possible boards after a placement or battle choice, with their chances: { { p = , m = }, ... }.
-- act(copy) makes the move on a copy. Only one battle per step is weighed by its odds; if a choice between battles
-- follows, the copy picks the battle with the best odds of winning (as the normal AI would).
local function outcomes(m, act)
    local probe = cloneMatch(m)
    probe.rng = fixedRng(true)
    local events = act(probe)
    if events == nil then
        return nil
    end

    local p = nil
    for _, e in ipairs(events) do
        if e.type == 'battle' then
            p = A.winChance(e.attacker_power, e.defender_power)
            break
        end
    end

    local list
    if p == nil then
        list = { { p = 1, m = probe } }
    else
        local lose = cloneMatch(m)
        lose.rng = fixedRng(false)
        act(lose)
        list = { { p = p, m = probe }, { p = 1 - p, m = lose } }
    end

    -- a choice between battles: follow the one with the best odds (expanding its outcomes)
    local out = {}
    for _, o in ipairs(list) do
        if o.m.pending then
            local k = A.chooseBattle(o.m, o.m.turn, 'normal', function() return 1 end)
            local side = o.m.turn
            local sub = outcomes(o.m, function(c) return R.chooseBattle(c, side, k) end) or { { p = 1, m = o.m } }
            for _, s2 in ipairs(sub) do
                out[#out + 1] = { p = o.p * s2.p, m = s2.m }
            end
        else
            out[#out + 1] = o
        end
    end

    return out
end

local function placeOutcomes(m, side, i, x, y)
    return outcomes(m, function(c) return R.place(c, side, i, x, y) end)
end

-- Expected lead for <side> after playing hand card i at (x, y).
local function evalMove(m, side, i, x, y)
    local list = placeOutcomes(m, side, i, x, y)
    if list == nil then
        return nil
    end

    local v = 0
    for _, o in ipairs(list) do
        v = v + o.p * lead(o.m, side)
    end

    return v
end

-- The other player's best expected lead from position m, or nil if they have no move.
local function bestReply(m, side)
    local best = nil
    for i = 1, #m.hands[side] do
        for _, cell in ipairs(R.freeCells(m)) do
            local v = evalMove(m, side, i, cell.x, cell.y)
            if v ~= nil and (best == nil or v > best) then
                best = v
            end
        end
    end

    return best
end

-- Nalfey's random AI, with the same rolls in the same order.
local function easyMove(m, side, rng)
    while true do
        local x = rng(1, 4)
        local y = rng(1, 4)
        if m.cells[x][y] == nil then
            return { hand = rng(1, #m.hands[side]), x = x, y = y }
        end
    end
end

-- Picks a move for <side>: { hand = index, x = , y = }. level: 'easy', 'normal' or 'hard'.
function A.chooseMove(m, side, level, rng)
    rng = rng or m.rng
    if level ~= 'normal' and level ~= 'hard' then
        return easyMove(m, side, rng)
    end

    local other = R.opposite(side)
    local scored = {}
    for i = 1, #m.hands[side] do
        for _, cell in ipairs(R.freeCells(m)) do
            local list = placeOutcomes(m, side, i, cell.x, cell.y)
            if list ~= nil then
                local v = 0
                for _, o in ipairs(list) do
                    v = v + o.p * lead(o.m, side)
                end
                scored[#scored + 1] = { hand = i, x = cell.x, y = cell.y, v = v, list = list }
            end
        end
    end

    -- hard: the best few moves are scored again by what the other player can answer (keeps the server quick)
    if level == 'hard' and #m.hands[other] > 0 then
        table.sort(scored, function(a, b) return a.v > b.v end)
        local keep = {}
        for n = 1, math.min(A.HARD_CANDIDATES, #scored) do
            local s = scored[n]
            local v = 0
            for _, o in ipairs(s.list) do
                local value = lead(o.m, side)
                if not o.m.over then
                    local reply = bestReply(o.m, other)
                    if reply ~= nil then
                        value = -reply
                    end
                end
                v = v + o.p * value
            end
            s.v = v
            keep[#keep + 1] = s
        end
        scored = keep
    end

    -- best score; ties broken at random so the computer does not always play the same way
    local bestV = nil
    for _, s in ipairs(scored) do
        if bestV == nil or s.v > bestV then
            bestV = s.v
        end
    end

    local top = {}
    for _, s in ipairs(scored) do
        if s.v >= bestV - 1e-9 then
            top[#top + 1] = s
        end
    end

    return top[rng(1, #top)]
end

-- Picks one of m.pending for <side>.
function A.chooseBattle(m, side, level, rng)
    rng = rng or m.rng
    if level ~= 'normal' and level ~= 'hard' then
        return rng(1, #m.pending)
    end

    local bestK, bestV = 1, nil
    for k, b in ipairs(m.pending) do
        local att = R.cardAt(m.cells, m.placedX, m.placedY)
        local def = R.cardAt(m.cells, b.x, b.y)
        local ap, dp = R.battleStats(att, def)
        local p = A.winChance(ap, dp)
        if bestV == nil or p > bestV then
            bestK, bestV = k, p
        end
    end

    return bestK
end

return A
