-----------------------------------
-- Squad extras: sleep the links (2026-11-22, levi). See squad_plus.lua.
--
-- When a pull links, a Black Mage, Red Mage or Bard mate (or a /BLM, /RDM) puts the extra monsters to sleep, the way a
-- 2006 party handled a link: the tank keeps the one you fight, the mage calls "Add! Sleeping Goblin Smithy." and sleeps
-- it, and sleeps it again when it wakes. The party finishes the first monster and then takes the next.
--  - a monster somebody in the party is fighting (yours, the tank's, a mate's target) is never slept, so nobody's
--    swings break the sleep: the next one is taken on when you (or the tank) engage it;
--  - Bards sing Foe Lullaby, the others cast Sleep II, else Sleep (never the area ones: Sleepga, Horde Lullaby would
--    catch the monster you fight);
--  - one mate per monster; a monster that resists three times in a row is left alone (undead, an NM that will not
--    sleep), and NMs are tried once;
--  - not for a mate set to the tank role, nor with its magic switch off; it keeps 20 MP back.
-- Switch: !squad sleep on|off.
-----------------------------------
require('modules/module_utils')
local P = require('modules/custom/lua/squad_plus')
-----------------------------------
local m = Module:new('squad_cc')

local CC = {}
SQUAD_CC = CC

CC.RANGE    = 20  -- yalms from the mate to the monster it sleeps
CC.FOE_AREA = 25  -- yalms from you: the monsters that count as part of this fight
CC.RESERVE  = 20  -- MP kept back
CC.TRIES    = 3   -- casts on one monster without it falling asleep, then it is left alone
CC.CLAIM    = 6   -- seconds one mate keeps a monster to itself after starting a cast on it

CC.claims = CC.claims or {} -- [foe id] = { by = mate id, at = time }
CC.tries  = CC.tries or {}  -- [foe id] = casts that did not sleep it
CC.slept  = CC.slept or {}  -- [foe id] = true once it was asleep (the next cast is a "again")

local SLEEPS = { 'SLEEP_I', 'SLEEP_II', 'LULLABY' }
local function asleep(foe)
    for _, name in ipairs(SLEEPS) do
        local effect = xi.effect[name]
        if effect and foe:hasStatusEffect(effect) then
            return true
        end
    end

    return false
end
CC.asleep = asleep

-- the sleep spell this mate would use (id, name), or nil
function CC.sleepSpell(player, trust)
    local j, s = trust:getMainJob(), trust:getSubJob()
    if j == xi.job.BRD then
        return P.bestKnown(player, trust, { 'FOE_LULLABY' })
    end

    if j == xi.job.BLM or j == xi.job.RDM or s == xi.job.BLM or s == xi.job.RDM then
        return P.bestKnown(player, trust, { 'SLEEP_II', 'SLEEP' })
    end

    return nil
end

-- the monsters party members are fighting (as a set of ids)
local function fought(player)
    local set = {}
    for _, member in ipairs(P.party(player)) do
        pcall(function()
            local target = member:isEngaged() and member:getTarget() or nil
            if target ~= nil then
                set[target:getID()] = true
            end
        end)
    end

    local main = P.mainTarget(player)
    if main ~= nil then
        set[main:getID()] = true
    end

    return set
end

local function forget(now)
    local count = 0
    for id, claim in pairs(CC.claims) do
        count = count + 1
        if now - claim.at > 120 then
            CC.claims[id], CC.tries[id], CC.slept[id] = nil, nil, nil
        end
    end

    if count > 300 then
        CC.claims, CC.tries, CC.slept = {}, {}, {}
    end
end

function CC.tick(player, trust)
    if not P.free(trust) or P.role(player, trust) == 'tank' or not P.allowed(player, trust, 'magic') then
        return
    end

    local spellId = CC.sleepSpell(player, trust)
    if spellId == nil then
        return
    end

    local foes = P.foes(player, CC.FOE_AREA)
    if #foes < 2 then
        return
    end

    local now = os.time()
    local busy = fought(player)
    local myId = trust:getID()
    forget(now)

    for _, foe in ipairs(foes) do
        local id = foe:getID()
        local claim = CC.claims[id]
        local mine = claim ~= nil and claim.by == myId
        local claimedByOther = claim ~= nil and not mine and now - claim.at < CC.CLAIM
        local isNM = false
        pcall(function() isNM = foe:isNM() and true or false end)
        local limit = isNM and 1 or CC.TRIES

        if asleep(foe) then
            CC.tries[id] = 0
            CC.slept[id] = true
        elseif not busy[id] and not claimedByOther and (CC.tries[id] or 0) < limit and
            trust:checkDistance(foe) <= CC.RANGE then
            -- (my last cast may still be landing; once it has, no sleep since then counts as a resist below)
            if mine and now - claim.at < 5 then
                return
            end

            if P.cast(trust, spellId, foe, CC.RESERVE) then
                local first = claim == nil
                if claim ~= nil and now - claim.at < 30 and not CC.slept[id] then
                    CC.tries[id] = (CC.tries[id] or 0) + 1
                end

                CC.claims[id] = { by = myId, at = now }
                local name = foe:getName()
                pcall(function() name = foe:getPacketName() end)
                name = string.gsub(tostring(name), '_', ' ')
                if first then
                    local lines = { 'Add! Sleeping %s.', 'Link! I\'ll sleep the %s.', 'Got the add: sleeping %s.' }
                    P.say(player, trust, string.format(lines[math.random(#lines)], name))
                elseif CC.slept[id] and P.every(trust, 'CC_' .. id, 20) then
                    P.say(player, trust, string.format('%s is awake, sleeping it again.', name))
                end

                CC.slept[id] = nil
                return
            end
        end
    end
end

P.register('sleep', {
    title = 'Black Mage, Red Mage and Bard mates sleep the extra monsters of a link',
    words = { 'sleep', 'cc' },
    tick = CC.tick,
})

return m
