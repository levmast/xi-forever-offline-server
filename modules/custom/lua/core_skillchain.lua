-----------------------------------
-- core_skillchain.lua: the common questions about skillchains, answered from core_skillchain_data.lua (generated from the server's own data).
-- Loading it changes nothing: it registers nothing and hooks nothing.
--
--   local sc = require('modules/custom/lua/core_skillchain')
--   sc.properties(ws)               ws = weapon skill id or name ('combo')  ->  { property ids }, primary first  (nil when it has none)
--   sc.property_name(id)            8 -> 'impaction'
--   sc.tier(id)                     level of a property (1 .. 4)
--   sc.form(resonance, skill)       resonance and skill are lists of property ids, the way the server's FormSkillchain takes them: the
--                                   skillchain that is formed (property id) or nil
--   sc.opens_into(first, second)    two weapon skills in a row on a fresh target: the skillchain id the second one forms, or nil
--   sc.window_after(links)          seconds the next link has, after `links` links have been made
--   sc.DELAY, sc.WINDOW             seconds before a link may be made, seconds a fresh skillchain stays open
-----------------------------------
local Data = require('modules/custom/lua/core_skillchain_data')

local M = { DELAY = Data.TIMING.delay, WINDOW = Data.TIMING.window }

local by_name
local function id_of(ws)
    if type(ws) == 'number' then return ws end
    if by_name == nil then
        by_name = {}
        for id, w in pairs(Data.WS) do by_name[w.name] = id end
    end
    local key = tostring(ws):lower():gsub("'", ''):gsub('[%s%-]+', '_')
    return by_name[key]
end

function M.properties(ws)
    local w = Data.WS[id_of(ws) or -1]
    if w == nil then return nil end
    local out = {}
    for i, p in ipairs(w.props) do out[i] = p end
    return out
end

function M.property_name(id)
    return Data.property_name[id]
end

function M.tier(id)
    return Data.TIER[id]
end

-- the server's rule (battleutils FormSkillchain): every resonance property in order against every property of the skill in order, the first
-- pair that is in the table wins
function M.form(resonance, skill)
    for _, r in ipairs(resonance or {}) do
        local row = Data.CHAIN[r]
        if row then
            for _, s in ipairs(skill or {}) do
                if row[s] then return row[s] end
            end
        end
    end
    return nil
end

function M.opens_into(first, second)
    local a, b = M.properties(first), M.properties(second)
    if a == nil or b == nil then return nil end
    return M.form(a, b)
end

function M.window_after(links)
    local w = Data.TIMING.window - (links or 0) * Data.TIMING.shrink
    if w < 0 then w = 0 end
    return w
end

return M
