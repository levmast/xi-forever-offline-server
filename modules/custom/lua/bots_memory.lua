-----------------------------------
-- XI: Forever Offline: bot players - learning from a bad day (2026-11-21). Used by bots_extras.lua.
-- The idea is from MimicXI's world bots (hotactionsock/MimicXI, GPL-3.0); written here for our own bot players.
--
-- A bot that dies while it is out hunting on its own remembers the area (kept on the bot, so it survives restarts:
-- char vars '[BotM]<area>' = when, '[BotMd]<area>' = how bad x 1000 + its level then) and, for the rest of this
-- session, the camp it died at.
--   * How much a death still counts ("danger"): fully at first, half after HALF_LIFE, and less for every level
--     it has gained since (nothing once it is OUTLEVEL levels higher).
--   * Picking a hunting area: one with danger AVOID or more (two fresh deaths) is passed over when its level has
--     another area to go to. If every choice is that bad it takes the least bad one: it has to hunt somewhere.
--   * Picking a camp: not within CAMP_RANGE yalms of where it died in the last CAMP_FOR seconds.
-- It only steers WHERE a bot goes hunting. How it fights is not touched. Switch: !extras bot_memory off.
-----------------------------------
local M = {}

local HALF_LIFE  = 24 * 3600 -- seconds
local AVOID      = 2.0
local OUTLEVEL   = 5
local MAX_DANGER = 9.9
local CAMP_RANGE = 60
local CAMP_FOR   = 3600
local TRIES      = 4

local camps = {} -- [bot id] = { { zone, x, z, t }, ... } (this session only)

local function now()
    return os.time()
end

local function decayed(n, age)
    if n <= 0 then
        return 0
    end

    return n * 0.5 ^ (math.max(0, age) / HALF_LIFE)
end

-- the stored danger as it stands now (level not counted in), and the level it had at its last death there
local function read(bot, zoneId)
    local last = bot:getCharVar('[BotM]' .. zoneId)
    if not last or last == 0 then
        return 0, 0
    end

    local packed = bot:getCharVar('[BotMd]' .. zoneId) or 0
    local tenths, lvl = math.floor(packed / 1000), packed % 1000
    return decayed(tenths / 10, now() - last), lvl
end

function M.danger(bot, zoneId)
    local n, lvl = read(bot, zoneId)
    if n <= 0 then
        return 0
    end

    local gained = bot:getMainLvl() - lvl
    if gained >= OUTLEVEL then
        return 0
    elseif gained > 0 then
        n = n * (1 - gained / OUTLEVEL)
    end

    return n
end

-- it died out hunting (bots.lua noticeChanges, once per death)
function M.onDeath(bot, st)
    local h = st and st.hunt
    if not h then
        return false -- with you, on an errand, in a battlefield: not a hunting spot to stay away from
    end

    local zoneId = bot:getZoneID()
    local n = read(bot, zoneId)
    n = math.min(MAX_DANGER, n + 1)
    bot:setCharVar('[BotM]' .. zoneId, now())
    bot:setCharVar('[BotMd]' .. zoneId, math.floor(n * 10 + 0.5) * 1000 + math.min(999, bot:getMainLvl()))

    local pos = bot:getPos()
    local list = camps[bot:getID()] or {}
    camps[bot:getID()] = list
    list[#list + 1] = { zone = zoneId, x = (h.camp and h.camp.x) or pos.x, z = (h.camp and h.camp.z) or pos.z, t = now() }
    while #list > 6 do
        table.remove(list, 1)
    end

    return true
end

-- first: the area it was going to; again(): another pick of the same kind. Returns the area to go to.
function M.chooseArea(bot, first, again)
    local best, bestDanger = first, M.danger(bot, first)
    if bestDanger < AVOID then
        return first
    end

    for _ = 1, TRIES do
        local z = again()
        if type(z) == 'number' then
            local d = M.danger(bot, z)
            if d < AVOID then
                return z
            elseif d < bestDanger then
                best, bestDanger = z, d
            end
        end
    end

    return best
end

function M.campOk(bot, zoneId, camp)
    local list = camps[bot:getID()]
    if not list or not camp then
        return true
    end

    local t = now()
    for _, c in ipairs(list) do
        if c.zone == zoneId and t - c.t <= CAMP_FOR and (c.x - camp.x) ^ 2 + (c.z - camp.z) ^ 2 <= CAMP_RANGE * CAMP_RANGE then
            return false
        end
    end

    return true
end

-- for !bots where / story: the areas it is wary of right now, worst first: { { zone, danger }, ... }
function M.wary(bot, zoneIds)
    local out = {}
    for _, z in ipairs(zoneIds or {}) do
        local d = M.danger(bot, z)
        if d >= 0.5 then
            out[#out + 1] = { zone = z, danger = d }
        end
    end

    table.sort(out, function(a, b)
        return a.danger > b.danger
    end)
    return out
end

return M
