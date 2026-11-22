-----------------------------------
-- Squad extras: pet jobs (2026-11-22, levi). See squad_plus.lua.
--
-- What was already there (squad.lua petTick, pets_data.lua, squad_jobs.lua petCare): a Dragoon's wyvern, a Summoner's
-- Carbuncle and then an avatar by level with a Blood Pact: Rage about once a minute (paid in MP) and Carbuncle's Healing
-- Ruby on you under half HP, a Beastmaster's jug pet by level that follows its target and is tended under half HP every
-- 90 seconds, a Dragoon's Spirit Link. Puppetmasters had no pet. This adds, the way those jobs played in 2006:
--  - Summoner: each avatar's Blood Pact: Ward when it helps: Shining Ruby (Carbuncle 24), Aerial Armor (Garuda 25),
--    Frost Armor (Shiva 28), Rolling Thunder (Ramuh 31), Crimson Howl (Ifrit 38), Earthen Ward (Titan 46) at the start
--    of a fight when you lack the buff; Whispering Wind (Garuda 36) and Spring Water (Leviathan 47) when two or more of
--    the party are under 65% HP. Same MP price and the same one-minute ward timer as Healing Ruby, and it keeps a
--    quarter of its MP. On a notorious monster under 75% HP: Astral Flow and the avatar's own pact ("Astral Flow!
--    Ifrit, Inferno!"), once an hour per mate;
--  - Beastmaster: the tending is called as Reward ("Good boy, Courier Carrie! Here's a treat.");
--  - Puppetmaster: a stand-in automaton: a jug pet of its level in an automaton's shape, named Automaton, that fights
--    its target, with Repair under 40% HP every 90 seconds (the game's own automaton needs a character's frame and
--    attachments, so a squad mate cannot own one);
--  - every pet job: a word when the pet is called and when it falls.
-- Charm is not built (a charmed monster that breaks free in the middle of the party is not worth the risk).
-- Switch: !squad pets on|off.
-----------------------------------
require('modules/module_utils')
local P = require('modules/custom/lua/squad_plus')
-----------------------------------
local m = Module:new('squad_petjobs')

local PJ = {}
SQUAD_PETJOBS = PJ

PJ.WARD_SECS   = 60     -- the ward timer (shared with squad.lua's Healing Ruby: SQUAD_WARD_NEXT)
PJ.AF_SECS     = 3600   -- Astral Flow, once an hour
PJ.REPAIR_SECS = 90
PJ.PUP_RESUMMON = 120
PJ.AUTOMATON_MODEL = 3029 -- the automaton the Aht Urhgan NPCs use
PJ.MP_KEEP = 0.25

local okData, petsData = pcall(require, 'modules/custom/lua/pets_data')
if not okData or type(petsData) ~= 'table' then
    petsData = nil
end

-- { level, ward (job ability name), the buff it gives (effect name) or nil for a healing ward }
PJ.WARDS = {
    CARBUNCLE = { { 24, 'SHINING_RUBY', 'SHINING_RUBY' } },
    IFRIT     = { { 38, 'CRIMSON_HOWL', 'WARCRY' } },
    TITAN     = { { 46, 'EARTHEN_WARD', 'STONESKIN' } },
    LEVIATHAN = { { 47, 'SPRING_WATER' } },
    GARUDA    = { { 25, 'AERIAL_ARMOR', 'BLINK' }, { 36, 'WHISPERING_WIND' } },
    SHIVA     = { { 28, 'FROST_ARMOR', 'ICE_SPIKES' } },
    RAMUH     = { { 31, 'ROLLING_THUNDER', 'ENTHUNDER' } },
}
PJ.ASTRAL = {
    CARBUNCLE = 'SEARING_LIGHT', IFRIT = 'INFERNO', TITAN = 'EARTHEN_FURY', LEVIATHAN = 'TIDAL_WAVE',
    GARUDA = 'AERIAL_BLAST', SHIVA = 'DIAMOND_DUST', RAMUH = 'JUDGMENT_BOLT', FENRIR = 'HOWLING_MOON',
}

local function petOf(trust)
    local ok, pet = pcall(function() return trust:getPet() end)
    return ok and pet or nil
end

local function hasPet(trust)
    local fn = rawget(_G, 'SquadHasPet')
    if type(fn) == 'function' then
        local ok, has = pcall(fn, trust)
        return ok and has
    end

    return petOf(trust) ~= nil
end

local function petName(pet)
    local name = 'my pet'
    pcall(function() name = pet:getPacketName() end)
    return name
end

local function avatarOf(pet)
    if petsData == nil or pet == nil then
        return nil
    end

    local ok, name = pcall(function() return petsData.avatarName(pet:getPetID()) end)
    return ok and name or nil
end

local function bpCost(trust)
    return 8 + math.floor(trust:getMainLvl() * 1.2) -- (squad.lua's Blood Pact price)
end

local function engagedTarget(trust)
    local ok, target = pcall(function() return trust:getTarget() end)
    if ok and target ~= nil and target:isAlive() then
        return target
    end

    return nil
end

-- ---------------------------------------------------------------- Summoner
function PJ.astralFlow(player, trust, pet, target, avatar)
    local pact = PJ.ASTRAL[avatar or '']
    local id = pact and xi.jobAbility and xi.jobAbility[pact]
    if id == nil then
        return false
    end

    local isNM = false
    pcall(function() isNM = target:isNM() and target:getHPP() <= 75 end)
    local var = 'SQX_AF_' .. trust:getLocalVar('SQUAD_ID')
    if not isNM or os.time() - player:getCharVar(var) < PJ.AF_SECS then
        return false
    end

    player:setCharVar(var, os.time())
    pcall(function()
        if type(rawget(_G, 'SquadUseAbility')) == 'function' and xi.jobAbility.ASTRAL_FLOW then
            SquadUseAbility(player, trust, xi.jobAbility.ASTRAL_FLOW) -- (the two-hour itself, where the rules allow it)
        end
    end)
    P.say(player, trust, string.format('Astral Flow! %s, %s!', P.pretty(avatar), P.pretty(pact)))
    pet:usePetAbility(id, target)
    return true
end

function PJ.ward(player, trust, pet, target, avatar)
    local now = os.time()
    if now < trust:getLocalVar('SQUAD_WARD_NEXT') then
        return false
    end

    local cost = bpCost(trust)
    if trust:getMP() < cost + trust:getMaxMP() * PJ.MP_KEEP then
        return false
    end

    -- how many of the party are hurt (for the healing wards)
    local hurt = 0
    for _, member in ipairs(P.party(player)) do
        local ok, low = pcall(function() return member:isAlive() and member:getHPP() < 65 end)
        if ok and low then
            hurt = hurt + 1
        end
    end

    local lvl = trust:getMainLvl()
    for _, w in ipairs(PJ.WARDS[avatar or ''] or {}) do
        local id = xi.jobAbility and xi.jobAbility[w[2]]
        if id and lvl >= w[1] then
            local want
            if w[3] then
                local fx = xi.effect[w[3]]
                want = target ~= nil and fx ~= nil and not player:hasStatusEffect(fx)
            else
                want = hurt >= 2
            end

            if want then
                trust:setLocalVar('SQUAD_WARD_NEXT', now + PJ.WARD_SECS)
                trust:delMP(cost)
                pet:usePetAbility(id, player)
                if P.every(trust, 'PET_WARD', 20) then
                    P.say(player, trust, string.format('%s, %s!', petName(pet), P.pretty(w[2])))
                end

                return true
            end
        end
    end

    return false
end

-- ---------------------------------------------------------------- Puppetmaster
local function automatonJug(trust)
    local pick
    if petsData then
        pcall(function() pick = petsData.jugFor(trust:getMainLvl()) end)
    end

    return pick or (xi.petId and xi.petId.COURIER_CARRIE) or 24
end

function PJ.puppet(player, trust)
    local now = os.time()
    if not hasPet(trust) then
        if trust:getLocalVar('SQX_PET_HAD') == 1 then -- (it just fell: a minute before the next one)
            trust:setLocalVar('SQX_PUP_NEXT', math.max(trust:getLocalVar('SQX_PUP_NEXT'), now + 60))
        end

        if now >= trust:getLocalVar('SQX_PUP_NEXT') and type(rawget(_G, 'SquadSpawnPet')) == 'function' then
            trust:setLocalVar('SQX_PUP_NEXT', now + PJ.PUP_RESUMMON)
            local ok, spawned = pcall(SquadSpawnPet, trust, automatonJug(trust))
            if ok and spawned then
                P.say(player, trust, 'Activate! Come on out, partner.')
            end
        end

        return
    end

    local pet = petOf(trust)
    if pet == nil then
        return
    end

    if trust:getLocalVar('SQX_PUP_SKIN') ~= pet:getID() then
        trust:setLocalVar('SQX_PUP_SKIN', pet:getID())
        pcall(function()
            pet:setModelId(PJ.AUTOMATON_MODEL)
            pet:renameEntity('Automaton', true)
        end)
    end

    local target = engagedTarget(trust)
    if target ~= nil and type(rawget(_G, 'SquadPetAttack')) == 'function' then
        pcall(SquadPetAttack, trust, target)
    end

    local hpp = pet:getHPP()
    if trust:getMainLvl() >= 15 and hpp > 0 and hpp < 40 and now >= trust:getLocalVar('SQX_REPAIR_NEXT') then
        trust:setLocalVar('SQX_REPAIR_NEXT', now + PJ.REPAIR_SECS)
        pet:addHP(math.floor(pet:getMaxHP() * 0.35))
        P.say(player, trust, 'Repair! Hang in there, partner.')
    end
end

-- ---------------------------------------------------------------- Beastmaster (squad.lua's tending calls this)
function PJ.onTend(mob, pet)
    local player = P.master(mob)
    if player == nil or not P.on(player, 'pets') then
        return
    end

    local lines = { 'Good job, %s! Here\'s a treat.', 'Reward! Eat up, %s.', 'Hang in there, %s. Have a treat!' }
    P.say(player, mob, string.format(lines[math.random(#lines)], petName(pet)))
end

-- ---------------------------------------------------------------- the tick
local PET_JOBS = { BST = true, SMN = true, DRG = true, PUP = true }
local function jobName(id)
    for name, value in pairs(xi.job) do
        if value == id then
            return name
        end
    end

    return nil
end

function PJ.tick(player, trust)
    local job = jobName(trust:getMainJob())
    if not PET_JOBS[job or ''] then
        return
    end

    if job == 'PUP' then
        PJ.puppet(player, trust)
    end

    -- the pet called, the pet fallen
    local has = hasPet(trust)
    local had = trust:getLocalVar('SQX_PET_HAD') == 1
    if has and not had then
        local pet = petOf(trust)
        if pet ~= nil and job ~= 'PUP' and P.every(trust, 'PET_CALL', 30) then
            local lines = {
                SMN = { 'I call upon you, %s!', '%s, lend me your strength!' },
                BST = { 'Go get them, %s!', 'Come on out, %s!' },
                DRG = { 'Come, %s!', 'To my side, %s!' },
            }
            local pool = lines[job]
            P.say(player, trust, string.format(pool[math.random(#pool)], petName(pet)))
        end
    elseif had and not has and trust:isAlive() and engagedTarget(trust) ~= nil then
        local lines = { 'No! My pet!', 'Ugh, I lost my partner!', 'They got my pet!' }
        P.say(player, trust, lines[math.random(#lines)])
    end
    trust:setLocalVar('SQX_PET_HAD', has and 1 or 0)

    if job ~= 'SMN' or not has or not P.free(trust) then
        return
    end

    local pet = petOf(trust)
    local avatar = avatarOf(pet)
    if pet == nil or avatar == nil then
        return
    end

    local target = engagedTarget(trust)
    if target ~= nil and PJ.astralFlow(player, trust, pet, target, avatar) then
        return
    end

    PJ.ward(player, trust, pet, target, avatar)
end

P.register('pets', {
    title = 'Summoner wards and Astral Flow, Beastmaster Reward, a Puppetmaster automaton, pet calls',
    words = { 'pets', 'pet' },
    tick = PJ.tick,
})

return m
