-----------------------------------
-- Squad extras: buff upkeep (2026-11-22, levi). See squad_plus.lua.
--
-- What was already there: the White and Red Mage job rules cast Protect, Shell, Haste, Refresh and the rest when the
-- buff is missing ("not status"), so every buff fell off and stayed off until the next free moment. This keeps them up
-- the way a 2006 buffer did:
--  - a buff a mate can cast is recast on whoever has it shortly before it wears off (under 25 seconds left): Protect,
--    Shell (Protectra, Shellra when two or more around the White Mage need it), Haste, Refresh, Regen, and on itself
--    Phalanx and Aquaveil. Stoneskin and Blink are left to the rules (they cannot be recast while up);
--  - it only chooses who keeps a buff, never who gets one: the job rules still decide that;
--  - never while someone in the party is under 50% HP, never below a quarter of its MP, not with its magic switch off;
--  - a quiet note to you when a buff on you or a mate has 15 seconds left and nobody renewed it: "Haste wearing on Tig."
-- Bard songs are left to the Bard code. Switch: !squad buffs on|off.
-----------------------------------
require('modules/module_utils')
local P = require('modules/custom/lua/squad_plus')
-----------------------------------
local m = Module:new('squad_buffs')

local B = {}
SQUAD_BUFFS = B

B.RENEW_MS = 25000 -- recast under this much time left
B.WARN_MS  = 15000 -- the note under this much
B.RANGE    = 20    -- yalms to the member
B.RA_RANGE = 10    -- yalms from the White Mage for Protectra and Shellra
B.MP_KEEP  = 0.25  -- share of max MP kept for cures
B.HURT     = 50    -- nobody buffs while a party member is under this HP%

-- effect -> the spells that renew it (best first), whether only on oneself, and the party version
B.BUFFS = {
    { effect = 'PROTECT', spells = { 'PROTECT_IV', 'PROTECT_III', 'PROTECT_II', 'PROTECT' },
      ra = { 'PROTECTRA_V', 'PROTECTRA_IV', 'PROTECTRA_III', 'PROTECTRA_II', 'PROTECTRA' } },
    { effect = 'SHELL', spells = { 'SHELL_IV', 'SHELL_III', 'SHELL_II', 'SHELL' },
      ra = { 'SHELLRA_V', 'SHELLRA_IV', 'SHELLRA_III', 'SHELLRA_II', 'SHELLRA' } },
    { effect = 'HASTE',    spells = { 'HASTE' } },
    { effect = 'REFRESH',  spells = { 'REFRESH' } },
    { effect = 'REGEN',    spells = { 'REGEN_II', 'REGEN' } },
    { effect = 'PHALANX',  spells = { 'PHALANX' }, self = true },
    { effect = 'AQUAVEIL', spells = { 'AQUAVEIL' }, self = true },
}

B.lastCast = B.lastCast or {} -- ['member:effect'] = time a mate tried to renew it (until it is renewed or gone)
B.warned   = B.warned or {}   -- ['member:effect'] = true once noted

local function remaining(member, effectId)
    local ok, ms = pcall(function()
        local fx = member:getStatusEffect(effectId)
        return fx and fx:getTimeRemaining() or nil
    end)
    return ok and ms or nil
end

local function anyoneHurt(player)
    for _, member in ipairs(P.party(player)) do
        local ok, hurt = pcall(function() return member:isAlive() and member:getHPP() < B.HURT end)
        if ok and hurt then
            return true
        end
    end

    return false
end

-- the members (in range of the mate) whose buff is about to wear off and nobody renewed lately
local function due(player, trust, buff, effectId, range)
    local out = {}
    for _, member in ipairs(P.party(player)) do
        if not buff.self or member:getID() == trust:getID() then
            local ms = remaining(member, effectId)
            local key = member:getID() .. ':' .. effectId
            local okD, near = pcall(function() return member:isAlive() and trust:checkDistance(member) <= range end)
            if ms == nil or ms >= B.RENEW_MS then
                B.lastCast[key] = nil -- (renewed, or gone: the job rules cast it again)
            elseif ms > 0 and okD and near and B.lastCast[key] == nil then
                -- (one try per wear-off: a cast that did not take, an interrupted one or a stronger tier from someone
                -- else is not repeated)
                out[#out + 1] = member
            end
        end
    end

    return out
end

function B.tick(player, trust)
    if not P.free(trust) or not P.allowed(player, trust, 'magic') then
        return
    end

    if trust:getMP() < trust:getMaxMP() * B.MP_KEEP or anyoneHurt(player) then
        return
    end

    local reserve = math.floor(trust:getMaxMP() * B.MP_KEEP)
    for _, buff in ipairs(B.BUFFS) do
        local effectId = xi.effect[buff.effect]
        local single = effectId and P.bestKnown(player, trust, buff.spells)
        local ra = effectId and buff.ra and P.bestKnown(player, trust, buff.ra)
        if single or ra then
            local list = due(player, trust, buff, effectId, B.RANGE)
            if ra and #list >= 2 then
                local close = due(player, trust, buff, effectId, B.RA_RANGE)
                if #close >= 2 and P.cast(trust, ra, trust, reserve) then
                    for _, member in ipairs(close) do
                        B.lastCast[member:getID() .. ':' .. effectId] = os.time()
                    end

                    return
                end
            end

            if single and list[1] ~= nil and P.cast(trust, single, list[1], reserve) then
                B.lastCast[list[1]:getID() .. ':' .. effectId] = os.time()
                return
            end
        end
    end
end

-- the quiet notes (one mate a second per player does this)
B.voice = B.voice or {}
function B.warnTick(player, trust)
    local now = os.time()
    local v = B.voice[player:getID()]
    if v ~= nil and v.at == now and v.id ~= trust:getID() then
        return
    end

    B.voice[player:getID()] = { at = now, id = trust:getID() }
    for _, member in ipairs(P.party(player)) do
        for _, buff in ipairs(B.BUFFS) do
            local effectId = xi.effect[buff.effect]
            local ms = effectId and remaining(member, effectId)
            local key = member:getID() .. ':' .. tostring(effectId)
            if ms ~= nil and ms > 0 and ms <= B.WARN_MS then
                if not B.warned[key] and B.lastCast[key] == nil then -- (not while a mate is renewing it)
                    B.warned[key] = true
                    local who = member:getID() == player:getID() and 'you' or member:getPacketName()
                    P.note(player, string.format('%s wearing on %s.', P.pretty(buff.effect), who))
                end
            elseif ms == nil or ms > B.WARN_MS then
                B.warned[key] = nil
            end
        end
    end
end

P.register('buffs', {
    title = 'buffs recast before they wear off, quiet wear warnings',
    words = { 'buffs', 'buff' },
    tick = function(player, trust)
        B.tick(player, trust)
        B.warnTick(player, trust)
    end,
})

return m
