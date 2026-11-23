-----------------------------------
-- Squad extras: camp fight (2026-11-23, levi). See squad_plus.lua.
--
-- At a camp (!squad camp) the mates already fight what you fight there and what another mate fights there
-- (trust_controller.cpp DoRoamTick), even when you are not engaged. Two fights were still left to you:
--  - a monster hitting you (or a bot player, a second character, a pet) at camp while you rest or heal: nobody was
--    engaged on it, so the mates stood and watched until you engaged it yourself;
--  - the monster a bot player pulled (!squad pull <bot name>) or is fighting at camp: the engine only looks at you and
--    your mates, so the mates waited for you to engage.
-- With this on, a mate at camp who is not fighting picks up any monster within CF.RADIUS yalms of the camp that has
-- someone in your party on its hate list, or that a party member is engaged with: the one going for you first (the
-- healer sitting there), then the one going for a mate, then any. Once engaged, the engine's camp fight takes over
-- (it lets go past 30 yalms from camp, as before). squad.lua also stops holding the next pull just because you sit
-- down; your HP, and your MP when you are the healer, still hold it.
-- Mates that are stopped (!idle, Actions OFF, resting mid-fight for MP) or out pulling are left alone.
-- Switch: !squad campfight on|off (char var SQUAD_X_CAMPFIGHT, on by default). Without a camp nothing changes.
-----------------------------------
require('modules/module_utils')
local P = require('modules/custom/lua/squad_plus')
-----------------------------------
local m = Module:new('squad_campfight')

local CF = rawget(_G, 'SQUAD_CAMPFIGHT') or {}
SQUAD_CAMPFIGHT = CF

CF.RADIUS = 20 -- yalms from camp (the engine's CampFightRadius)
CF.MAX_DY = 14 -- up or down from camp (squad.lua CAMP_MAX_DY: zones with floors)

-- the switch, for squad.lua's pull check
function CF.on(player)
    return P.on(player, 'campfight')
end

local function nearCamp(c, entity)
    local p = entity:getPos()
    local dx, dz = p.x - c.x, p.z - c.z
    return dx * dx + dz * dz <= CF.RADIUS * CF.RADIUS and math.abs(p.y - c.y) <= CF.MAX_DY
end

-- the monsters at camp the party is in a fight with, best first. Kept for a second per player (every mate asks).
CF.cache = CF.cache or {} -- [player id] = { at, list }
function CF.foes(player, c)
    local now = os.time()
    local cached = CF.cache[player:getID()]
    if cached and cached.at == now then
        return cached.list
    end

    local seen, scored = {}, {}
    local inParty = {}
    local members = P.party(player)
    for _, member in ipairs(members) do
        inParty[member:getID()] = member
    end

    local function add(foe)
        if foe == nil or seen[foe:getID()] then
            return
        end

        seen[foe:getID()] = true
        if foe:getObjType() ~= xi.objType.MOB or not foe:isAlive() or not nearCamp(c, foe) then
            return
        end

        -- you first (you are the one sitting there), then a party member, then whatever else
        local score = 3
        local okT, target = pcall(function() return foe:getTarget() end)
        if okT and target ~= nil then
            if target:getID() == player:getID() then
                score = 1
            elseif inParty[target:getID()] then
                score = 2
            end
        end

        scored[#scored + 1] = { foe = foe, score = score }
    end

    for _, member in ipairs(members) do
        P.try('campfight notoriety', function()
            for _, foe in pairs(member:getNotorietyList() or {}) do
                add(foe)
            end
        end)

        P.try('campfight pet', function()
            local pet = member:getPet()
            if pet ~= nil then
                for _, foe in pairs(pet:getNotorietyList() or {}) do
                    add(foe)
                end
            end
        end)

        -- a bot player (or a second character) fighting at camp
        P.try('campfight engaged', function()
            if member:getObjType() == xi.objType.PC and member:isEngaged() then
                add(member:getTarget())
            end
        end)
    end

    table.sort(scored, function(a, b) return a.score < b.score end)
    local list = {}
    for i, entry in ipairs(scored) do
        list[i] = entry.foe
    end

    CF.cache[player:getID()] = { at = now, list = list }
    return list
end

function CF.tick(player, trust)
    if trust:isEngaged() or trust:getLocalVar('SQUAD_CAMP') == 0 or trust:getLocalVar('SQUAD_IDLE') ~= 0 or
        trust:getLocalVar('SQUAD_PULL_PHASE') ~= 0 or trust:getZoneID() ~= player:getZoneID()
    then
        return
    end

    local c = xi.squad and xi.squad.campInfo and xi.squad.campInfo(player)
    if c == nil then
        return
    end

    local foe = CF.foes(player, c)[1]
    if foe == nil then
        return
    end

    if trust:getAnimation() == xi.animation.HEALING then
        trust:setAnimation(xi.animation.NONE) -- (resting at camp: up for the fight)
    end

    trust:engage(foe:getTargID())
end

P.register('campfight', {
    title = 'at camp the squad fights what attacks you or a bot, without you engaging',
    words = { 'campfight', 'campfights' },
    tick = CF.tick,
})

return m
