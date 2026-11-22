-----------------------------------
-- XI: Forever Offline: bot players - through the gates (2026-11-21). Used by bots_extras.lua.
-- The idea is from MimicXI's world bots (hotactionsock/MimicXI, GPL-3.0: real travel); this is a first step of it.
--
-- Until now a bot going hunting vanished from its spot in town, and one coming home appeared on a spot. Now:
--   * going out: it runs to the gate that leads towards its hunting area (or as far as it gets in WALK_S seconds)
--     and leaves from there;
--   * coming home: it arrives where you do when you zone into that town, coming from that side, and walks in.
-- The way between two areas is worked out from the game's own zone lines (gates_data.lua, build_gates_data.py).
-- NOT in this step: walking the areas in between, the walk from an area's entrance to the camp (it still arrives
-- at its camp, out of your sight as before), outpost and Home Point warps, Sneak and Invisible.
-- No gate, no way found, or switched off (!extras bot_gates off): exactly as before.
-----------------------------------
local G = {}

local WALK_S   = 100 -- seconds it runs towards the gate before it leaves from where it is
local REACHED  = 4   -- yalms: at the gate
local MAX_HOPS = 8   -- areas: no way this short = no gate walk (it leaves as before)
local RETRIES  = 6   -- times a walk that stopped short is started again

local data = nil      -- gates_data.lua
local neighbours = nil -- [area] = { [next area] = true }
local routes = {}     -- ['from:to'] = { from, ..., to } or false

local function now()
    return os.time()
end

local function load()
    if data ~= nil then
        return data ~= false
    end

    local ok, d = pcall(require, 'modules/custom/lua/gates_data')
    if not ok or type(d) ~= 'table' or type(d.gates) ~= 'table' then
        data = false
        return false
    end

    data = d
    neighbours = {}
    for zoneId, list in pairs(d.gates) do
        neighbours[zoneId] = neighbours[zoneId] or {}
        for _, g in ipairs(list) do
            if g.to ~= zoneId then
                neighbours[zoneId][g.to] = true
            end
        end
    end

    return true
end

-- the areas you pass from one to the other, both ends included (fewest zone lines), or nil
function G.route(from, to)
    if not load() or from == to then
        return nil
    end

    local key = from .. ':' .. to
    if routes[key] ~= nil then
        return routes[key] or nil
    end

    local prev, queue, head, found = { [from] = false }, { from }, 1, false
    local depth = { [from] = 0 }
    while queue[head] do
        local z = queue[head]
        head = head + 1
        if z == to then
            found = true
            break
        end

        if depth[z] < MAX_HOPS then
            for n in pairs(neighbours[z] or {}) do
                if prev[n] == nil then
                    prev[n] = z
                    depth[n] = depth[z] + 1
                    queue[#queue + 1] = n
                end
            end
        end
    end

    if not found then
        routes[key] = false
        return nil
    end

    local path, z = {}, to
    while z do
        table.insert(path, 1, z)
        z = prev[z]
    end

    routes[key] = path
    return path
end

-- in `from`: the zone line towards `to` (the first step of the way), nearest to pos when there are several
function G.exitTowards(from, to, pos)
    local path = G.route(from, to)
    if not path or not path[2] then
        return nil
    end

    local best, bestD
    for _, g in ipairs(data.gates[from] or {}) do
        if g.to == path[2] then
            local d = pos and ((g.x - pos.x) ^ 2 + (g.z - pos.z) ^ 2) or 0
            if bestD == nil or d < bestD then
                best, bestD = g, d
            end
        end
    end

    if not best then
        return nil
    end

    -- the zone line itself is mostly off the walking map: it runs to the spot just inside the gate
    if best.px then
        return { x = best.px, y = best.py, z = best.pz }
    end

    return { x = best.x, y = best.y, z = best.z }
end

-- in `to`: where you stand after zoning in on the way from `from` (the last step of the way)
function G.arrivalFrom(from, to)
    local path = G.route(from, to)
    if not path or #path < 2 then
        return nil
    end

    local last = path[#path - 1]
    local options = {}
    for _, g in ipairs(data.gates[last] or {}) do
        if g.to == to then
            options[#options + 1] = g
        end
    end

    if #options == 0 then
        return nil
    end

    local g = options[math.random(1, #options)]
    local at = { x = g.ax, y = g.ay, z = g.az, rot = g.arot }
    -- (a few arrival points are not on the walking map, a pier or a platform: then it comes home the old way)
    if xi.navguard then
        local x, y, z, how = xi.navguard.snap(to, at, nil, 'goal')
        if how == 'failed' then
            return nil
        end

        at.x, at.y, at.z = x, y, z
    end

    return at
end

-- going out: go(bot) is what it did before (it zones to its camp). Returns true when it is walking to a gate
-- first (st.trip). Its hunt stays in st.hunt meanwhile, so everything that looks for a free bot (bot parties,
-- battlefield runs, teleport shouts, invites) sees a busy one, exactly as if it had already left.
function G.leave(bot, st, destZone, go)
    if st.trip or bot:isDead() or bot:isEngaged() then
        return false
    end

    local from = bot:getZoneID()
    local gate = G.exitTowards(from, destZone, bot:getPos())
    if not gate then
        return false
    end

    if xi.navguard then
        local x, y, z, how = xi.navguard.snap(from, gate, nil, 'goal')
        if how == 'failed' then
            return false
        end

        gate = { x = x, y = y, z = z }
    end

    local id = bot:getID()
    st.trip = { gate = gate, go = go, hunt = st.hunt, untilT = now() + WALK_S, tries = 0, zone = from }
    if BotHeal then
        BotHeal(id, false)
    end

    BotMoveTo(id, gate.x, gate.y, gate.z)
    return true
end

local function finish(bot, st)
    local trip = st.trip
    st.trip = nil
    st.life = nil -- (no town plan while it is out, as when it left from its spot)
    trip.go(bot)
    return 'zoning'
end

-- the trip is off without leaving: the hunt it was for goes with it (unless something else replaced that hunt)
local function drop(st)
    local trip = st.trip
    st.trip = nil
    if trip and trip.hunt ~= nil and st.hunt == trip.hunt then
        st.hunt = nil
    end
end

-- once a second while it is on its way to the gate (bots.lua think)
function G.think(bot, st)
    local trip = st.trip
    local t = now()
    if not trip then
        return nil
    end

    -- it died, changed area some other way, or this trip is from long ago (it logged out on the way): forget it
    if bot:isDead() or bot:getZoneID() ~= trip.zone or t > trip.untilT + 300 or (trip.hunt ~= nil and st.hunt ~= trip.hunt) then
        drop(st)
        return nil
    end

    if bot:isEngaged() then
        return nil -- (something attacked it: its brain deals with that first)
    end

    local pos = bot:getPos()
    if (pos.x - trip.gate.x) ^ 2 + (pos.z - trip.gate.z) ^ 2 <= REACHED * REACHED or t >= trip.untilT then
        return finish(bot, st)
    end

    if not BotIsMoving(bot:getID()) then
        trip.tries = trip.tries + 1
        if trip.tries > RETRIES then
            return finish(bot, st) -- it cannot get any closer: it leaves from here, as it always did
        end

        BotMoveTo(bot:getID(), trip.gate.x, trip.gate.y, trip.gate.z)
    end

    return nil
end

-- you invited it on the way: the trip (and the hunt it had planned) is off
function G.cancel(st)
    drop(st)
end

return G
