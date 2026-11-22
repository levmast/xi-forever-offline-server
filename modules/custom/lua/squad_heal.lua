-----------------------------------
-- Squad extras: hate-aware healing (2026-11-22, levi). See squad_plus.lua.
--
-- The job rules heal with "best Cure of the family" (the engine's HIGHEST): a White Mage answers a scratch at 74% with
-- Cure IV, takes the monster off the tank and dies. With this on, the everyday cures go through here instead, the way a
-- 2006 healer cured:
--  - the cure that covers the damage: the smallest tier that heals what is missing (Cure II for a scratch, Cure IV for a
--    big hit), Curaga when three or more are hurt and close together (White Mage);
--  - early in a fight, while the tank has little hate, nothing above Cure II unless someone is in danger;
--  - when the healer's own hate on a monster nears the tank's, one tier lower and it lets light damage wait, with a quiet
--    "Easing off the cures, I'm pulling hate." now and then;
--  - below 35% HP (H.EMERGENCY) anything goes: the biggest cure needed, straight away.
-- How: squad.lua's addGambit asks H.skipGambit about each rule while a mate is built; a "best Cure" rule above 35% HP is
-- left out and its HP line kept on the mate (SQX_HEAL), so the mate heals the same people at the same point, from here.
-- The emergency rules (25%), cures that wake a sleeping member and any rule naming a specific Cure stay as they were.
-- Not for a mate with its magic switch off. Switch: !squad heal on|off (from the next call of a mate).
-----------------------------------
require('modules/module_utils')
local P = require('modules/custom/lua/squad_plus')
-----------------------------------
local m = Module:new('squad_heal')

local H = {}
SQUAD_HEAL = H

H.EMERGENCY  = 35   -- HP% at or below which hate does not matter
H.RANGE      = 20   -- yalms to the member healed
H.CURAGA_R   = 8    -- yalms: members within this of the one hurt worst count for Curaga
H.YOUNG_HATE = 1500 -- the tank's hate (CE + VE) on the monster under which the fight is still young
H.HOT        = 0.7  -- healer hate / tank hate at which the healer eases off

-- rough HP each cure heals at a fitting level (the era's healing skill and MND); the pick only needs the order of size
H.CURES = {
    { name = 'CURE',     heal = 60 },
    { name = 'CURE_II',  heal = 140 },
    { name = 'CURE_III', heal = 300 },
    { name = 'CURE_IV',  heal = 560 },
}
H.CURAGAS = {
    { name = 'CURAGA',     heal = 120 },
    { name = 'CURAGA_II',  heal = 260 },
    { name = 'CURAGA_III', heal = 450 },
}

-- ---------------------------------------------------------------- the rule filter (from squad.lua addGambit)
local function hppLimit(condition)
    if type(condition) ~= 'table' then
        return nil
    end

    if type(condition[1]) == 'table' then
        return hppLimit(condition[1]) or hppLimit(condition[2])
    end

    if condition[1] == ai.c.HPP_LT then
        return tonumber(condition[2])
    end

    return nil
end

local HEAL_TARGETS = { 'PARTY', 'PARTY_LOWEST_HPP', 'TANK', 'MASTER', 'SELF', 'MELEE', 'CASTER', 'RANGED' }
function H.skipGambit(mob, target, condition, action)
    if type(action) ~= 'table' or action[1] ~= ai.r.MA or action[2] ~= ai.s.HIGHEST or
        action[3] ~= xi.magic.spellFamily.CURE then
        return false
    end

    local isHealTarget = false
    for _, name in ipairs(HEAL_TARGETS) do
        if ai.t[name] ~= nil and ai.t[name] == target then
            isHealTarget = true
        end
    end

    local limit = hppLimit(condition)
    local player = P.master(mob)
    if not isHealTarget or limit == nil or limit <= H.EMERGENCY or player == nil or not P.on(player, 'heal') then
        return false
    end

    if limit > mob:getLocalVar('SQX_HEAL') then
        mob:setLocalVar('SQX_HEAL', limit)
    end

    return true
end

-- ---------------------------------------------------------------- hate
-- the healer's and the tank's hate (CE + VE) on the monsters fighting the party: the worst ratio, the tank's hate there
local function hateRatio(player, healer)
    local tank
    for _, member in ipairs(P.party(player)) do
        if member:getID() ~= healer:getID() and member:isAlive() and P.partRole(player, member) == 'tank' then
            tank = member
            break
        end
    end

    if tank == nil then
        return 0, nil -- (no tank: whoever has hate has it; only the cure size matters)
    end

    local worst, tankHate = 0, nil
    for _, foe in ipairs(P.foes(player, 30)) do
        pcall(function()
            local theirs = foe:getCE(tank) + foe:getVE(tank)
            local onMe = foe:getTarget() ~= nil and foe:getTarget():getID() == healer:getID()
            if theirs > 0 or onMe then -- (a slept add only the cures woke up is not the tank's monster yet)
                local mine = foe:getCE(healer) + foe:getVE(healer)
                local ratio = onMe and 99 or mine / theirs
                worst = math.max(worst, ratio)
                tankHate = math.max(tankHate or 0, theirs)
            end
        end)
    end

    local main = P.mainTarget(player)
    if main ~= nil then
        pcall(function() tankHate = main:getCE(tank) + main:getVE(tank) end)
    end

    return worst, tankHate
end

-- ---------------------------------------------------------------- picking the cure
-- the known tiers of a list (in order), as { id, heal }
local function knownTiers(player, trust, list)
    local set = P.knownSpells(player, trust)
    local out = {}
    if set == nil then
        return out
    end

    for _, tier in ipairs(list) do
        local id = xi.magic.spell[tier.name]
        if id and set[id] then
            out[#out + 1] = { id = id, heal = tier.heal, name = tier.name }
        end
    end

    return out
end

-- index of the smallest tier that heals `missing` (the biggest when none does), capped at `maxIndex`
local function fit(tiers, missing, maxIndex)
    local pick = #tiers
    for i, tier in ipairs(tiers) do
        if tier.heal >= missing * 0.9 then
            pick = i
            break
        end
    end

    return math.max(1, math.min(pick, maxIndex or pick))
end
H.fit = fit

function H.tick(player, trust)
    local line = trust:getLocalVar('SQX_HEAL')
    if line <= 0 or not P.free(trust) or not P.allowed(player, trust, 'magic') then
        return
    end

    -- who needs it: the lowest HP% under the mate's line, in range
    local worst, worstHpp, hurt = nil, 101, {}
    for _, member in ipairs(P.party(player)) do
        local ok, hpp = pcall(function()
            if member:isAlive() and trust:checkDistance(member) <= H.RANGE then
                return member:getHPP()
            end
        end)
        if ok and hpp ~= nil and hpp < line then
            hurt[#hurt + 1] = member
            if hpp < worstHpp then
                worst, worstHpp = member, hpp
            end
        end
    end

    if worst == nil then
        return
    end

    local emergency = worstHpp <= H.EMERGENCY
    local ratio, tankHate = hateRatio(player, trust)
    local hot = not emergency and ratio >= H.HOT
    local young = not emergency and tankHate ~= nil and tankHate < H.YOUNG_HATE

    if hot and worstHpp > 60 then
        if P.every(trust, 'HEAL_HOT', 45) then
            P.say(player, trust, 'Easing off the cures, I\'m pulling hate.')
        end

        return -- (light damage waits while the tank gets the monster back)
    end

    local missing = worst:getMaxHP() - worst:getHP()
    local cures = knownTiers(player, trust, H.CURES)
    if #cures == 0 then
        return
    end

    -- Curaga: three or more hurt, close to the one hurt worst (and the mate knows one)
    local near = {}
    for _, member in ipairs(hurt) do
        local okD, d = pcall(function() return worst:checkDistance(member) end)
        if member:getID() == worst:getID() or (okD and d and d <= H.CURAGA_R) then
            near[#near + 1] = member
        end
    end

    local spellId, target, tiers, index
    if #near >= 3 then
        local curagas = knownTiers(player, trust, H.CURAGAS)
        if #curagas > 0 then
            local need = 0
            for _, member in ipairs(near) do
                need = need + (member:getMaxHP() - member:getHP())
            end

            tiers, target = curagas, worst
            index = fit(curagas, need / #near)
        end
    end

    if tiers == nil then
        tiers, target = cures, worst
        index = fit(cures, missing)
    end

    if young then
        index = math.min(index, 2) -- (nothing above the second tier while the tank builds hate)
    end

    if hot then
        index = math.max(1, index - 1)
    end

    -- the tier, or the next lower one the mate has MP and recast for
    for i = math.min(index, #tiers), 1, -1 do
        if P.cast(trust, tiers[i].id, target, 0) then
            return
        end
    end
end

P.register('heal', {
    title = 'healers pick the cure that fits the damage and mind the tank\'s hate (from the next call)',
    words = { 'heal', 'heals' },
    tick = H.tick,
})

return m
