-----------------------------------
-- Squad extras: skillchain and magic burst callouts (2026-11-22, levi). See squad_plus.lua.
--
-- What was already there (squad.lua, squad_chain.lua): one melee mate opens, the others close, the opener says
-- "Opening with <weapon skill>, close it!", and Black and Red Mages burst a formed chain through their job rules
-- (MB_AVAILABLE). This adds, the way a 2006 party talked:
--  - a closed chain is called in party chat with the elements to burst: "Fusion! Burst Fire or Light!" (by the mate
--    that closed it, or by a mage mate when you closed it yourself);
--  - a mate whose spell lands as a magic burst says so: "Magic Burst! Thunder III, 812!";
--  - !squad burst: a mate with elemental magic whose rules have no burst rule (an edited job list or a Rule Set without
--    one) still bursts a formed chain: a Black Mage, Red Mage or Dark Knight main, or a /BLM or /RDM sub job. Not for a
--    mate set to the tank or healer role, nor with its magic switch off. The rules that already burst are left alone
--    (squad.lua's addGambit marks a mate with a burst rule: SQUAD_HAS_MB).
-- Switches: !squad callouts on|off, !squad burst on|off.
-----------------------------------
require('modules/module_utils')
local P = require('modules/custom/lua/squad_plus')
-----------------------------------
local m = Module:new('squad_callouts')

local C = {}
SQUAD_CALLOUTS = C

C.CLOSE_GAP = 3   -- seconds between two chain calls for one player
C.MB_GAP    = 2   -- seconds between two burst calls for one mate

-- the elements that burst each skillchain (xi.skillchainType)
C.BURST = {
    [1]  = { 'Light' },                                  -- Transfixion
    [2]  = { 'Dark' },                                   -- Compression
    [3]  = { 'Fire' },                                   -- Liquefaction
    [4]  = { 'Earth' },                                  -- Scission
    [5]  = { 'Water' },                                  -- Reverberation
    [6]  = { 'Wind' },                                   -- Detonation
    [7]  = { 'Ice' },                                    -- Induration
    [8]  = { 'Thunder' },                                -- Impaction
    [9]  = { 'Earth', 'Dark' },                          -- Gravitation
    [10] = { 'Water', 'Ice' },                           -- Distortion
    [11] = { 'Fire', 'Light' },                          -- Fusion
    [12] = { 'Wind', 'Thunder' },                        -- Fragmentation
    [13] = { 'Fire', 'Wind', 'Thunder', 'Light' },       -- Light
    [14] = { 'Earth', 'Water', 'Ice', 'Dark' },          -- Darkness
    [15] = { 'Fire', 'Wind', 'Thunder', 'Light' },       -- Light II
    [16] = { 'Earth', 'Water', 'Ice', 'Dark' },          -- Darkness II
}

local scNames
local function chainName(power)
    if scNames == nil then
        scNames = {}
        for name, value in pairs(xi.skillchainType or {}) do
            scNames[value] = P.pretty(name)
        end
    end

    return scNames[power] or 'Skillchain'
end

-- the formed chain on a monster: power (xi.skillchainType), tier; nil while only opened (tier 0) or none
local function formedChain(target)
    local ok, power, tier = pcall(function()
        local effect = target:getStatusEffect(xi.effect.SKILLCHAIN)
        if effect == nil then
            return nil
        end

        return effect:getPower(), effect:getTier()
    end)
    if not ok or power == nil or tier == nil or tier < 1 or C.BURST[power] == nil then
        return nil
    end

    return power, tier
end

local function joinOr(list)
    if #list == 1 then
        return list[1]
    end

    return table.concat(list, ', ', 1, #list - 1) .. ' or ' .. list[#list]
end

-- a mage mate who can speak for the party (it would burst): BLM, RDM, or a /BLM, /RDM
local function mageMate(player)
    for _, trust in ipairs(P.trusts(player)) do
        local j, s = trust:getMainJob(), trust:getSubJob()
        if trust:isAlive() and (j == xi.job.BLM or j == xi.job.RDM or s == xi.job.BLM or s == xi.job.RDM) then
            return trust
        end
    end

    return nil
end

-- a weapon skill landed (a mate's or yours): a chain it closed is called
function C.onWeaponSkill(player, user, target)
    if target == nil or not P.on(player, 'callouts') then
        return
    end

    local power = formedChain(target)
    if power == nil or not P.every(player, 'SCCALL', C.CLOSE_GAP) then
        return
    end

    local speaker = user
    if speaker == nil or speaker:getObjType() ~= xi.objType.TRUST then
        speaker = mageMate(player) -- (you closed it: a mage calls the burst; nobody, then nothing is said)
        if speaker == nil then
            return
        end
    end

    local name, elements = chainName(power), joinOr(C.BURST[power])
    local lines = {
        '%s! Burst %s!',
        '%s! Magic burst now: %s!',
        'Skillchain, %s! %s burst!',
        '%s up! %s, go!',
    }
    P.say(player, speaker, string.format(lines[math.random(#lines)], name, elements))
end

-- a mate's spell finished: a magic burst is called
function C.onMagic(caster, target, spell, action)
    local player = P.master(caster)
    if player == nil or target == nil or spell == nil or action == nil or not P.on(player, 'callouts') then
        return
    end

    -- only a spell on a monster can be a magic burst (a cure's own "recovers HP" message can match its burst message)
    local okT, isMob = pcall(function() return target:getObjType() == xi.objType.MOB end)
    if not okT or not isMob then
        return
    end

    local okM, msg, burstMsg = pcall(function()
        return action:getMsg(target:getID()), spell:getMagicBurstMessage()
    end)
    if not okM or msg == nil or burstMsg == nil or burstMsg == 0 or msg ~= burstMsg then
        return
    end

    if not P.every(caster, 'MBCALL', C.MB_GAP) then
        return
    end

    local okD, damage = pcall(function() return action:getParam(target:getID()) end)
    local name = P.spellName(spell:getID())
    local lines = {
        'Magic Burst! %s, %d!',
        'Burst! %s for %d!',
        'Got the burst: %s, %d!',
    }
    P.say(player, caster, string.format(lines[math.random(#lines)], name, okD and tonumber(damage) or 0))
end

-- ---------------------------------------------------------------- the burst rule for mates without one
-- (MB_AVAILABLE: a formed chain, after the burst reaction; MB_ELEMENT: the best spell of the chain's element it knows)
local function nukeFloor(trust)
    local j, s = trust:getMainJob(), trust:getSubJob()
    if j == xi.job.BLM then
        return 0
    elseif j == xi.job.RDM or j == xi.job.DRK then
        return 30
    elseif s == xi.job.BLM or s == xi.job.RDM then
        return 50
    end

    return nil
end

function C.addBurstRule(player, trust)
    if not P.on(player, 'burst') or trust:getLocalVar('SQUAD_HAS_MB') ~= 0 then
        return false
    end

    local floor = nukeFloor(trust)
    local role = P.role(player, trust)
    if floor == nil or role == 'healer' or role == 'tank' or not P.allowed(player, trust, 'magic') then
        return false
    end

    if not (ai and ai.c and ai.c.MB_AVAILABLE and ai.s and ai.s.MB_ELEMENT and ai.c.MPP_GTE) then
        return false
    end

    trust:addGambit(ai.t.TARGET, { { ai.c.MPP_GTE, floor }, { ai.c.MB_AVAILABLE, 0 } },
        { ai.r.MA, ai.s.MB_ELEMENT, xi.magic.spellFamily.NONE })
    trust:setLocalVar('SQUAD_HAS_MB', 2) -- (2: added here)
    return true
end

-- ---------------------------------------------------------------- hooks
P.register('callouts', {
    title = 'skillchain and magic burst calls in party chat',
    words = { 'callouts', 'sc', 'mb' },
    onSpawn = function(player, trust, mate)
        trust:addListener('WEAPONSKILL_USE', 'SQX_SC_CALL', function(mob, target)
            local master = P.master(mob)
            if master then
                P.try('callouts ws', C.onWeaponSkill, master, mob, target)
            end
        end)

        trust:addListener('MAGIC_USE', 'SQX_MB_CALL', function(mob, target, spell, action)
            P.try('callouts mb', C.onMagic, mob, target, spell, action)
        end)

        -- your own weapon skills too (one listener per player; a second add replaces the first)
        player:addListener('WEAPONSKILL_USE', 'SQX_SC_CALL_ME', function(entity, target)
            P.try('callouts ws (you)', C.onWeaponSkill, entity, entity, target)
        end)
    end,
})

P.register('burst', {
    title = 'mages without a burst rule still magic burst the chains (from the next call)',
    words = { 'burst' },
    onSpawn = function(player, trust, mate)
        C.addBurstRule(player, trust)
    end,
})

return m
