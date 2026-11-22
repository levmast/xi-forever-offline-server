-----------------------------------
-- Squad Mates (v1.15): !squad command   (1.7: level sync; 1.8: rest together; 1.9: adventure journal events for squad chat; 1.10: BST Courier Carrie pets; 1.11: pet skill lists + DRG support magic; 1.12: SMN coverage + pet support skills target the mate; 1.13: per-mate on/off switches for melee, ranged, abilities and spells, and melee-off holds the back line; 1.14: !squad sheet, the stats-and-gear sheet behind the panel's Sheet window; 1.15: exp line on the sheet)
--
-- Persistent, customizable Trust-style party members. Each squad mate has its own level and exp for
-- every job, like a real character. Needs modules/custom/cpp/squad.cpp.
-- Squad mates do not go through xi.trust.canCast, so the usual Trust zone/battlefield limits do not apply.
-----------------------------------
require('modules/module_utils')

-- (2026-11-19, from Jon Tanta's Squad Update) the server's Lua print goes through a format string, so a "{" or "}" in a message threw
-- "Encountered logging exception: argument not found" (hundreds of times a session, hiding real errors). Braces are dropped; the rest
-- prints as before. Global, so every module's print is covered.
if SQUAD_PRINT_RAW == nil then
    SQUAD_PRINT_RAW = print
    print = function(...)
        local n, parts = select('#', ...), {}
        for i = 1, n do
            parts[i] = tostring((select(i, ...)))
        end

        SQUAD_PRINT_RAW((table.concat(parts, '\t'):gsub('[{}]', '')))
    end
end
-----------------------------------

local MAX_SLOTS = 6         -- squad mates you can keep
local MAX_ACTIVE = 5        -- a party holds 6 including you
local MAX_LEVEL = 75        -- 75-era server
local SUB_UNLOCK_LEVEL = 18 -- sub job unlocks at main level 18, like retail
local REQUIRE_UNLOCK = true -- gear must be given to the squad once (!squad give) before any mate can wear it

-- Jobs available on this server (15 base jobs)
local jobIds =
{
    WAR = 1, MNK = 2, WHM = 3, BLM = 4, RDM = 5, THF = 6, PLD = 7, DRK = 8,
    BST = 9, BRD = 10, RNG = 11, SAM = 12, NIN = 13, DRG = 14, SMN = 15,
    BLU = 16, COR = 17, PUP = 18, -- v1.17 (Treasures of Aht Urhgan jobs; your character must have unlocked them)
}

local jobNames = {}
for name, id in pairs(jobIds) do
    jobNames[id] = name
end

-- Spoken job names, for the lines that can say what a mate is on ("Ready as {job}").
local jobTitles =
{
    [1] = 'Warrior', [2] = 'Monk', [3] = 'White Mage', [4] = 'Black Mage', [5] = 'Red Mage',
    [6] = 'Thief', [7] = 'Paladin', [8] = 'Dark Knight', [9] = 'Beastmaster', [10] = 'Bard',
    [11] = 'Ranger', [12] = 'Samurai', [13] = 'Ninja', [14] = 'Dragoon', [15] = 'Summoner',
}

local raceIds =
{
    humem = 1, humef = 2, elvm = 3, elvf = 4, tarum = 5, taruf = 6, mithra = 7, galka = 8,
}

local raceNames = { 'Hume M', 'Hume F', 'Elvaan M', 'Elvaan F', 'Tarutaru M', 'Tarutaru F', 'Mithra', 'Galka' }

-- Equipment slot indexes, same numbering the game uses
local equipSlots =
{
    main = 0, sub = 1, range = 2, ranged = 2, ammo = 3, head = 4, body = 5, hands = 6, legs = 7, feet = 8,
    neck = 9, waist = 10, ear1 = 11, ear2 = 12, ring1 = 13, ring2 = 14, back = 15,
}

local equipSlotNames = { [0] = 'main', 'sub', 'range', 'ammo', 'head', 'body', 'hands', 'legs', 'feet', 'neck', 'waist', 'ear1', 'ear2', 'ring1', 'ring2', 'back' }

-- True if bit n of mask is set (items store allowed jobs and slots as bit masks)
local function hasBit(mask, n)
    return math.floor(mask / (2 ^ n)) % 2 == 1
end

-- Roles and modes of squad mates (v1.5, described under "Roles and modes" further down). Stored on the player as SQUAD_AI_<mate id> = role * 10 + mode.
-- They are defined here, above the !squad command, because a Lua name can only be used below the line that declares it.
local ROLES = { 'auto', 'tank', 'damage', 'healer', 'support' }
local MODES = { 'balanced', 'aggressive', 'conserve' }

local function decodeBehavior(code)
    code = tonumber(code) or 0
    return ROLES[math.floor(code / 10) + 1] or 'auto', MODES[code % 10 + 1] or 'balanced'
end

-- On/off switches per mate (v1.13, the idea borrowed from the TitanXI Gambits window): which kinds of action a mate may use
-- at all, whatever its role says. Stored on the player as SQUAD_SW_<mate id> = mask + 1, so a stored 0 means "never set" (all on)
-- and a stored 1 means every switch is off.
local SWITCHES = { 'melee', 'ranged', 'ja', 'magic' }
local SW_BIT    = { melee = 0, ranged = 1, ja = 2, magic = 3 }
local SW_ALL    = 15

local function withBit(mask, n, on)
    local value = 2 ^ n
    local has   = math.floor(mask / value) % 2 == 1
    if on and not has then
        return mask + value
    elseif not on and has then
        return mask - value
    end

    return mask
end

local function switchesOf(player, mateId)
    local raw = tonumber(player:getCharVar('SQUAD_SW_' .. mateId)) or 0
    if raw <= 0 then
        return SW_ALL
    end

    return raw - 1
end

local function switchSummary(mask)
    local parts = {}
    for _, name in ipairs(SWITCHES) do
        parts[#parts + 1] = name .. ' ' .. (hasBit(mask, SW_BIT[name]) and 'on' or 'off')
    end

    return table.concat(parts, ', ')
end

local commandObj = {}

commandObj.cmdprops =
{
    permission = 0,
    parameters = 'sssss',
}

local function say(player, msg)
    player:printToPlayer(msg)
end

-- Dialogue lives in squad_dialogue.lua so you can edit what your squad mates say
local dialogueLoaded, dialogue = pcall(require, 'modules/custom/lua/squad_dialogue')
if not dialogueLoaded or type(dialogue) ~= 'table' then
    print('[squad] could not load squad_dialogue.lua - squad mates will stay quiet')
    dialogue = { voices = {}, voiceOrder = {}, voiceByName = {}, wsShoutChance = 0 }
end

-- More lines from the dialogue pack (squad_pack.lua): variety on call and knock-out, camp acknowledgements, and fight
-- and idle talk while the squad chat AI is quiet. (A field of xi.squad: this file is close to Lua's 200-local limit.)
xi = xi or {}
xi.squad = xi.squad or {}
do
    local okPack, pack = pcall(require, 'modules/custom/lua/squad_pack')
    if okPack and type(pack) == 'table' then
        xi.squad.pack = pack
    else
        xi.squad.pack = false
        print('[squad] pack lines are off: squad_pack.lua could not be loaded: ' .. tostring(pack))
    end
end

-- Used when a voice has no lines for an event (for example an older, edited squad_dialogue.lua)
local fallbackLines =
{
    eat = { 'Time for a bite: {food}.', 'Hold on, I am having some {food}.', 'Let me grab a {food} first.' },
    spellcast = { 'On it: {spell}!', '{spell}, coming up.', 'Casting {spell}.' },
    spellunknown = { 'I have not learned {spell}.', 'I do not know {spell} yet.', '{spell}? That is beyond me for now.' },
    spellnotready = { 'I cannot cast {spell} right now (not enough MP, or it is still recasting).', 'Not ready for {spell} yet.' },
    spellnotarget = { 'There is nothing to cast {spell} on.', 'I need a target for {spell}.' },
    spellbusy = { 'Give me a moment, I am busy.', 'Hold on, I cannot cast that this second.' },
    abilitycast = { '{ability}!', 'Using {ability}!', '{ability}, here we go!' },
    abilityunknown = { '{ability} is not one of my abilities.', 'I cannot use {ability} as a {job}.' },
    abilitynotready = { '{ability} is not ready yet, it is still recharging.', 'I already used {ability}. Give it time.' },
    abilitynotarget = { 'I need an enemy for {ability}.', 'Pick a target first for {ability}.' },
    abilitybusy = { 'I could not get {ability} off, try again in a moment.' },
}

-- 'cure_iv' -> 'Cure IV'
local function prettySpellName(name)
    local text = string.gsub(name, '_', ' ')
    text = string.gsub(text, '(%a)([%w\']*)', function(first, rest)
        local word = first .. rest
        if string.match(word, '^[ivxIVX]+$') then
            return string.upper(word)
        end

        return string.upper(first) .. rest
    end)

    return text
end

-- A mate's voice is chosen from their name (or voiceByName in squad_dialogue.lua), so it never changes
local function voiceFor(name)
    local chosen = dialogue.voiceByName[name]
    if chosen ~= nil and dialogue.voices[chosen] ~= nil then
        return chosen
    end

    if #dialogue.voiceOrder == 0 then
        return nil
    end

    local sum = 0
    for i = 1, #name do
        sum = sum + string.byte(name, i)
    end

    return dialogue.voiceOrder[(sum % #dialogue.voiceOrder) + 1]
end

-- Makes a squad mate say a line for this event in your party chat. The mate's own lines (edited in the launcher's
-- Squad tab) come first; otherwise the lines of their voice are used. vars fills in {item}, {level}, {zone}, {job}, ...
local function speak(player, name, event, vars)
    local voiceName = voiceFor(name)
    local text

    -- pickLine also remembers the last few lines of each kind, so two mates never say the same line together.
    if type(dialogue.pickLine) == 'function' then
        text = dialogue.pickLine(name, event, voiceName)
    end

    if text == nil then
        local voice = dialogue.voices[voiceName or '']
        local lines = voice and voice[event]
        if lines == nil or #lines == 0 then
            lines = fallbackLines[event]
        end

        if lines == nil or #lines == 0 then
            return
        end

        text = lines[math.random(#lines)]
    end

    local values = vars or {}
    values.name = name
    values.master = player:getName()
    values.zone = values.zone or player:getZoneName()

    text = string.gsub(text, '{(%w+)}', function(key)
        return tostring(values[key] or '')
    end)

    player:printToPlayer(text, 4, name) -- shows in party chat as if the mate said it
end

-- Same, from the squad mate's own entity (looks the player up by the id saved at spawn when needed)
local function speakFromMob(mob, event, vars)
    local master = mob:getMaster()
    if master == nil then
        master = GetPlayerByID(mob:getLocalVar('MASTER_ID'))
    end

    if master ~= nil then
        speak(master, mob:getPacketName(), event, vars)
    end
end

local jobList = 'WAR MNK WHM BLM RDM THF PLD DRK BST BRD RNG SAM NIN DRG SMN'

local function usage(player)
    say(player, '!squad - list your squad mates')
    say(player, '!squad new <name> <job> [level]   e.g. !squad new Bob WAR 10   (a new mate starts at up to level 12, not above yours)')
    say(player, '!squad job <slot> <job>   |   !squad sub <slot> <job or none>')
    say(player, '!squad levels <slot>   - their job levels (mates level up by fighting with you)')
    say(player, '!squad look <slot> <race> <face 1-16>   races: humem humef elvm elvf tarum taruf mithra galka (once: the look is for good)')
    say(player, '!squad size <slot> small | medium | large   (once: the size is for good)')
    say(player, '!squad ws <slot> chain | <TP 1000-3000> [weapon_skill | best]   - when and which weapon skill a mate uses')
    say(player, '!squad range <slot> melee | mid | far | auto   - how far a mate stands from the monster')
    say(player, '!squad give <item name or id>   - give an item to your squad once; every mate can then wear it')
    say(player, '!squad unlocked   - show what your squad has been given')
    say(player, '!squad equip <slot> <item name or id> [equip slot]   |   !squad unequip <slot> <equip slot or all>')
    say(player, '!squad lockstyle <slot> <item> [equip slot] | set | off [equip slot]   - how a mate looks, whatever it wears')
    say(player, '!squad gear <slot>   (gear is saved per job; equip slots: head body hands legs feet main sub range ammo neck waist ear1 ear2 ring1 ring2 back)')
    say(player, '!squad rename <slot> <name>   |   !squad delete <slot>')
    say(player, '!squad call [slot or all]   |   !squad dismiss [slot]   |   !squad food   (what they have eaten)')
    say(player, '!squad ai   |   !squad role <slot> <auto|tank|damage|healer|support>   |   !squad mode <slot> <balanced|aggressive|conserve>')
    say(player, '!squad engage first | normal   - mates join as soon as you engage, or after your first swing (retail)')
    say(player, '!squad sync <name> | off   - Level Sync to a player, bot or squad mate in your party (party menu works too)')
    say(player, '!squad autoequip on | off   - mates wear the best gear you gave the squad (picked again at each call)')
    say(player, '!squad spells   - spells your squad learned from scrolls (when the launcher option is on; trade scrolls to a mate)')
    say(player, '!squad spells <slot>   - every spell one squad mate has now')
    say(player, '!squad delay <slot> <0-10>   - seconds a mate waits before joining a fight (let the tank get hate first)')
    say(player, '!squad blu <slot> [set | unset <spell>] | auto   - a Blue Mage mate\'s set blue magic (automatic until you pick)')
    say(player, '!squad follow close | normal | far   - how closely your mates follow you')
    say(player, '!squad order <slots, e.g. 3,1,2,4,5>   - who "call all" brings out first (and party order)   |   !squad order reset')
    say(player, '!squad camp rest on | off   - mates sit and rest at camp while the pull is out')
    say(player, '!squad camp levels <low> <high> | reset   - monster levels the puller goes for, against yours (e.g. -10 0)')
    say(player, '!squad sw <slot> <melee|ranged|ja|magic|all> <on|off>   - stop one kind of action, e.g. stop a healer from meleeing')
    say(player, '!squad lore <slot>   - write (or rewrite) that mate\'s backstory')
    say(player, '!squad chat [on|off|test]   - in-character party chat with your mates')
    say(player, 'Party chat: /p !note <text>   - add a memory to their adventure journal')
    say(player, '!startergear   - basic level 1 gear for you and every squad mate   (!startergear me | !startergear squad)')
    say(player, 'Jobs: ' .. jobList)
end

local function parseJob(text)
    if text == nil then
        return nil
    end

    return jobIds[string.upper(text)]
end

-- Food: squad mates eat free, modest food once they are level 11 or higher (see squad_food.lua)
local foodLoaded, food = pcall(require, 'modules/custom/lua/squad_food')
if not foodLoaded or type(food) ~= 'table' then
    print('[squad] could not load squad_food.lua - squad mates will not eat')
    food = { enabled = false }
end

local function chooseFood(job, level)
    local role = food.roleByJob and food.roleByJob[job]
    if role == nil then
        return nil
    end

    for _, tier in ipairs(food.tiers or {}) do
        if level >= tier.from and level <= tier.to then
            return food.foods[tier.foods[role]]
        end
    end

    return nil
end

local function changeFoodMods(mob, meal, sign)
    for _, entry in ipairs(meal.mods) do
        local modId = xi.mod[entry[1]]
        if modId == nil then
            print(string.format('[squad] unknown stat %s in %s - skipped', entry[1], meal.name))
        elseif sign > 0 then
            mob:addMod(modId, entry[2])
        else
            mob:delMod(modId, entry[2])
        end
    end
end

-- Pets: a dragoon calls a wyvern, a summoner calls Carbuncle, and a beastmaster calls Courier Carrie
-- when a fight starts, and sends the pet at the enemy. The beastmaster pet is a free squad jug, not a jug item;
-- charm and the other avatars are not supported yet. Set ENABLE_PETS to false to turn this off.
local ENABLE_PETS = true
local PET_RESUMMON_SECONDS = 120 -- a pet that dies is called again after this long

local petByJob =
{
    [jobIds.DRG] = 48, -- wyvern
    [jobIds.SMN] = 8,  -- Carbuncle
    [jobIds.BST] = 24, -- Courier Carrie (the classic starter jug pet)
}

-- (in a do-block: this file is close to Lua's limit of 200 local variables at file level, so the new names
--  below must not be added to it)
local petTick
do
    -- v1.16: which pet, by level (modules/custom/lua/pets_data.lua). A Beastmaster gets the jug pet of its level
    -- instead of always Courier Carrie; a Summoner gets Carbuncle until 10, then one of the avatars (kept for as long
    -- as the mate is out), and its avatar uses a Blood Pact: Rage about once a minute, paid for with the mate's MP.
    -- Carbuncle also uses Healing Ruby on you under half health. A Beastmaster tends a pet under half health every
    -- 90 seconds (what Reward does). Without pets_data.lua everything is as before.
    local okPetsData, petsData = pcall(require, 'modules/custom/lua/pets_data')
    if not okPetsData or type(petsData) ~= 'table' then
        print('[squad] pets_data.lua could not be loaded, pets stay as before: ' .. tostring(petsData))
        petsData = nil
    end

    local BLOOD_PACT_SECONDS = 60
    local TEND_SECONDS       = 90

    local function squadPetId(mob)
        local job = mob:getMainJob()
        local fixed = petByJob[job]
        if fixed == nil or not petsData or job == jobIds.DRG then
            return fixed
        end

        -- (chosen once per summoned mate; pet ids here are never 0)
        local chosen = mob:getLocalVar('SQUAD_PET_PICK')
        if chosen == 0 then
            local lvl = mob:getMainLvl()
            local okPick, picked = pcall(function()
                if job == jobIds.SMN then
                    -- (spells from scrolls on) a squad Summoner has the avatars you have pacts with: you win them in
                    -- the avatar fights, and the whole squad shares them. Off: every avatar for its level.
                    local master = mob:getMaster()
                    if squadScrollsOn() and master and xi.magic and type(xi.magic.spell) == 'table' then
                        return petsData.avatarFor(lvl, function(name)
                            local sid = xi.magic.spell[name]
                            return sid ~= nil and master:hasSpell(sid)
                        end)
                    end

                    return petsData.avatarFor(lvl)
                end

                return petsData.jugFor(lvl)
            end)
            chosen = (okPick and picked and picked ~= 0) and picked or fixed
            mob:setLocalVar('SQUAD_PET_PICK', chosen)
        end

        return chosen
    end

    petTick = function(mob)
        if not ENABLE_PETS then
            return
        end

        local petId = squadPetId(mob)
        if petId == nil then
            return
        end

        local now = GetSystemTime()
        if not SquadHasPet(mob) and now >= mob:getLocalVar('SQUAD_PET_NEXT') then
            mob:setLocalVar('SQUAD_PET_NEXT', now + PET_RESUMMON_SECONDS)
            SquadSpawnPet(mob, petId)
        end

        local target = mob:getTarget()
        if target ~= nil then
            SquadPetAttack(mob, target)
        end

        if not petsData or not SquadHasPet(mob) then
            return
        end

        -- the pet's own actions (never allowed to stop the mate: everything in a pcall)
        pcall(function()
            local pet = mob:getPet()
            if not pet then
                return
            end

            local job, lvl = mob:getMainJob(), mob:getMainLvl()
            if job == jobIds.SMN then
                local cost = 8 + math.floor(lvl * 1.2)
                local master = mob:getMaster()
                local ward = petsData.wardFor(pet:getPetID())
                if ward and master and master:isAlive() and master:getHPP() < 50 and mob:getMP() >= cost and now >= mob:getLocalVar('SQUAD_WARD_NEXT') then
                    mob:setLocalVar('SQUAD_WARD_NEXT', now + BLOOD_PACT_SECONDS)
                    mob:delMP(cost)
                    pet:usePetAbility(ward, master)
                elseif target ~= nil and target:isAlive() and now >= mob:getLocalVar('SQUAD_BP_NEXT') then
                    local pact = petsData.rageFor(pet:getPetID(), lvl)
                    if pact and mob:getMP() >= cost then
                        mob:setLocalVar('SQUAD_BP_NEXT', now + BLOOD_PACT_SECONDS)
                        mob:delMP(cost)
                        pet:usePetAbility(pact, target)
                    else
                        mob:setLocalVar('SQUAD_BP_NEXT', now + 10)
                    end
                end
            elseif job == jobIds.BST then
                local hpp = pet:getHPP()
                if hpp > 0 and hpp < 50 and now >= mob:getLocalVar('SQUAD_TEND_NEXT') then
                    mob:setLocalVar('SQUAD_TEND_NEXT', now + TEND_SECONDS)
                    pet:addHP(math.floor(pet:getMaxHP() * 0.3))
                end
            end

            -- (job expansion) the pet follows its master's target; a dragoon's Spirit Link (squad_jobs.lua)
            require('modules/custom/lua/squad_jobs').petCare(mob, pet, target, now)
        end)
    end
end

-- the eating animation each dish plays for a player (item_usable.animation), and the "<mate> uses <item>." line
local FOOD_ANIM = { [4456] = 25, [4535] = 25, [4561] = 25, [5166] = 28, [4381] = 28, [5773] = 24, [5701] = 24, [5942] = 29, [5752] = 24,
                    [4538] = 25, [5729] = 24, [5552] = 24, [5144] = 26, [5676] = 27, [5158] = 26, [4371] = 28, [4437] = 28, [5174] = 24 }

local function showEating(mob, meal)
    pcall(function()
        -- category 5 = item use finished, resolution 0 = hit, message 28 = "<actor> uses <item>."
        mob:injectActionPacket(mob:getID(), 5, FOOD_ANIM[meal.id] or 24, 0, 0, 28, meal.id, meal.id)
    end)
end

-- Runs every combat tick: takes off worn-out food, and eats a fresh meal if the mate is not currently eating one
local function eatIfNeeded(mob)
    if not food.enabled or mob:getLocalVar('SQUAD_IDLE') == 1 then -- (Jon Tanta, 2026-11-21) a stopped mate does not eat either
        return
    end

    local level = mob:getMainLvl()
    local now = GetSystemTime()
    local mealId = mob:getLocalVar('SQUAD_FOOD_ID')

    if mealId ~= 0 and now >= mob:getLocalVar('SQUAD_FOOD_UNTIL') then
        -- (a meal eaten as the real Food effect wears off by itself; the older way took its stats off here)
        if mob:getLocalVar('SQUAD_FOOD_FX') == 0 then
            for _, meal in pairs(food.foods) do
                if meal.id == mealId then
                    changeFoodMods(mob, meal, -1)
                end
            end
        end

        mob:setLocalVar('SQUAD_FOOD_ID', 0)
        mob:setLocalVar('SQUAD_FOOD_FX', 0)
        mealId = 0
    end

    -- the Food effect is still on (eaten as a real meal): nothing to do
    if mealId ~= 0 and mob:getLocalVar('SQUAD_FOOD_FX') == 1 and not mob:hasStatusEffect(xi.effect.FOOD) then
        mob:setLocalVar('SQUAD_FOOD_ID', 0)
        mob:setLocalVar('SQUAD_FOOD_FX', 0)
        mealId = 0
    end

    if mealId ~= 0 or level < (food.minLevel or 11) then
        return
    end

    local meal = chooseFood(mob:getMainJob(), level)
    if meal == nil then
        return
    end

    -- eat it as the real Food effect (the item's own stats, the food icon on the party list), like a player eating;
    -- if that does not work for some reason, the stats are added directly as before
    local ate = false
    if not mob:hasStatusEffect(xi.effect.FOOD) then
        ate = pcall(function()
            mob:addStatusEffect(xi.effect.FOOD, { duration = meal.duration, origin = mob, sourceType = xi.effectSourceType.FOOD, sourceTypeParam = meal.id })
        end) and mob:hasStatusEffect(xi.effect.FOOD)
    end

    if not ate then
        changeFoodMods(mob, meal, 1)
    end

    mob:setLocalVar('SQUAD_FOOD_FX', ate and 1 or 0)
    mob:setLocalVar('SQUAD_FOOD_ID', meal.id)
    mob:setLocalVar('SQUAD_FOOD_UNTIL', now + meal.duration)
    print(string.format('[squad] %s eats %s (%d min%s)', mob:getPacketName(), meal.name, math.floor(meal.duration / 60), ate and '' or ', stats added directly'))
    showEating(mob, meal)

    if food.speakOnEat ~= false and dialogue.speakOnEat ~= false then
        speakFromMob(mob, 'eat', { food = meal.name })
    end
end

-- WAR MNK WHM BLM RDM THF (job ids 1-6) are available from the start. The other jobs are advanced jobs and
-- only work for squad mates once your character has unlocked them (like the job unlock quests in the game).
local STARTER_JOB_MAX = 6

local function jobUnlocked(player, job)
    return job <= STARTER_JOB_MAX or player:hasJob(job)
end

local function lockedMessage(player, job)
    return string.format('%s is an advanced job that %s has not unlocked yet.', jobNames[job], player:getName())
end

local function validName(name)
    return type(name) == 'string' and string.match(name, '^%a+$') ~= nil and #name >= 3 and #name <= 15
end

local function clampLevel(value)
    return math.max(1, math.min(MAX_LEVEL, math.floor(value)))
end

local function findMate(squad, slot)
    for _, mate in ipairs(squad) do
        if mate.slot == slot then
            return mate
        end
    end

    return nil
end

-- A job the mate has never used is level 1, like a fresh job on a real character
local function jobLevel(mate, job)
    local info = mate.jobs[job]
    return info and info.level or 1
end

-- Main level is the main job's own level. The sub job works once YOU have support jobs (your quest, or main level
-- SUB_UNLOCK_LEVEL), or once any of the mate's own jobs has reached SUB_UNLOCK_LEVEL, at any mate level:
-- its level is half the main level, but never higher than the sub job's own level.
-- cap: the highest main level allowed (level sync to your character); nil = the mate's own level
local function levelsFor(mate, cap, player)
    local main = jobLevel(mate, mate.mjob)
    if cap ~= nil and cap >= 1 and main > cap then
        main = cap
    end
    local sub = 0
    local subLevel = 0

    local unlocked = main >= SUB_UNLOCK_LEVEL
    for _, info in pairs(mate.jobs or {}) do -- (any of the mate's own jobs at 18 or more unlocks it for good, Yache)
        if not unlocked and type(info) == 'table' and (info.level or 0) >= SUB_UNLOCK_LEVEL then
            unlocked = true
        end
    end

    if not unlocked and player ~= nil then
        local ok, has = pcall(function()
            return player:hasJob(0) or player:getMainLvl() >= SUB_UNLOCK_LEVEL -- (bit 0 of the unlocked jobs: support jobs)
        end)
        unlocked = ok and has
    end

    -- (2026-11-21, Bob Roberts) the support job follows the server's map.SUBJOB_RATIO like a player's: 0 none, 1 half
    -- (75/37, the default), 2 two thirds (75/50), 3 equal (75/75). It was always half before.
    local ratio = tonumber(xi.settings and xi.settings.map and xi.settings.map.SUBJOB_RATIO) or 1
    local subCap = ratio == 3 and main or ratio == 2 and math.floor(main * 2 / 3) or ratio == 0 and 0 or math.floor(main / 2)
    if mate.sjob ~= 0 and mate.sjob ~= mate.mjob and unlocked and subCap > 0 then
        sub = mate.sjob
        subLevel = math.max(1, math.min(jobLevel(mate, sub), subCap))
    end

    return main, sub, subLevel
end

-- (Gambits v2, 2026-11-20) read-only access for the Squad Rule Set editor (gambits_squad.lua): the same levels a call uses
xi.squad.levelsFor = levelsFor

local function describe(mate, player)
    local main, sub, subLevel = levelsFor(mate, nil, player)
    local subText = sub ~= 0 and string.format('/%s%d', jobNames[sub], subLevel) or ''
    local race = mate.race > 0 and mate.race or 1 -- a mate with no race chosen is a Hume male
    local look = ' - ' .. raceNames[race] .. ' face ' .. (mate.face + 1)
    return string.format('[%d] %s  %s%d%s%s', mate.slot, mate.name, jobNames[mate.mjob] or '???', main, subText, look)
end

local function summonedMate(player, squadId)
    for _, member in pairs(player:getPartyWithTrusts()) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') == squadId then
            return member
        end
    end

    return nil
end

local function isSummoned(player, squadId)
    return summonedMate(player, squadId) ~= nil
end

-----------------------------------
-- Camp and pull (!squad camp, !squad pull): the squad holds a spot while someone pulls monsters to it.
-- This file keeps the camp and picks what to pull. The trust controller (core trust_controller.cpp) does the holding,
-- the run out and back, and the fighting at camp, through the mates' local vars SQUAD_CAMP* and SQUAD_PULL_*.
-----------------------------------
CAMP_MAX_DY = CAMP_MAX_DY or 14 -- (2026-11-19) only monsters within this height of the camp: zones with floors (Crawlers' Nest) stack monsters over each other
local CAMP_PULL_RANGE   = 60        -- yalms from camp the puller goes for a monster: your own area, not the far
                                    -- side of the zone (!squad camp range <10-500> changes yours)
local CAMP_RANGE_LIMITS = { 10, 500 }
local CAMP_WANT_ABOVE   = 25        -- a kind of monster you picked: pulled up to this many levels above you
local CAMP_LIST_MAX     = 80        -- kinds of monster listed in the menu

-- the kinds of monster around the camp (within the pull range), for the menu: { name, lo, hi, count, fits }
local function campKinds(player, c)
    local zone = player:getZone()
    if zone == nil or c == nil then
        return {}
    end

    local lvl, range = player:getMainLvl(), CAMP_PULL_RANGE
    local own = player:getCharVar('SQUAD_PULL_RANGE')
    if own >= CAMP_RANGE_LIMITS[1] and own <= CAMP_RANGE_LIMITS[2] then
        range = own
    end

    local byName = {}
    local kd = { all = 0, flat = 0, high = 0 }
    for _, mob in ipairs(zone:getMobs() or {}) do
        pcall(function()
            if mob:isNM() or (xi.allegiance and xi.allegiance.MOB and mob:getAllegiance() ~= xi.allegiance.MOB) then
                return
            end

            local pos = mob:getPos()
            local dx, dz = pos.x - c.x, pos.z - c.z
            kd.all = kd.all + 1
            if dx * dx + dz * dz > range * range then
                return
            end

            kd.flat = kd.flat + 1
            if math.abs(pos.y - c.y) > CAMP_MAX_DY then
                kd.high = kd.high + 1
                return
            end

            local name, ml = mob:getName(), mob:getMainLvl()
            local k = byName[name]
            if k == nil then
                k = { name = name, lo = ml, hi = ml, count = 0 }
                byName[name] = k
            end

            -- (2026-11-20, Altair: the menu said "Hill Lizard x2" while the puller said none were around) the zone's list
            -- also holds monsters that are defeated and waiting to respawn; the count is now only the ones that are up
            k.lo, k.hi, k.count = math.min(k.lo, ml), math.max(k.hi, ml), k.count + (mob:isAlive() and 1 or 0)
        end)
    end

    local nowK = os.time()
    if nowK - (SQUAD_KINDDIAG or 0) >= 10 then
        SQUAD_KINDDIAG = nowK
        print(string.format('[squad] camp kinds: camp at %.0f,%.0f,%.0f; %d monsters in the zone, %d within %d yalms flat, %d of those on another floor (more than %d up or down)',
            c.x, c.y, c.z, kd.all, kd.flat, range, kd.high, CAMP_MAX_DY))
    end

    local list = {}
    for _, k in pairs(byName) do
        k.fits = k.lo <= lvl + CAMP_WANT_ABOVE
        list[#list + 1] = k
    end

    table.sort(list, function(a, b)
        if a.fits ~= b.fits then
            return a.fits
        end

        return a.lo < b.lo or (a.lo == b.lo and a.name < b.name)
    end)

    while #list > CAMP_LIST_MAX do
        table.remove(list)
    end

    return list
end

local function campRange(player)
    local own = player:getCharVar('SQUAD_PULL_RANGE')
    if own >= CAMP_RANGE_LIMITS[1] and own <= CAMP_RANGE_LIMITS[2] then
        return own
    end

    return CAMP_PULL_RANGE
end
local CAMP_LEVELS       = { -6, 2 } -- monster level against yours (easy prey up to a decent challenge)
-- (!squad camp levels <low> <high>, Velderen) your own window, as levels below/above yours; char vars SQUAD_PULL_LOW /
-- SQUAD_PULL_HIGH hold offset + 100 (0 = not set, the default window). Global: squad.lua is at the local limit.
function squadCampLevels(player)
    local lo, hi = player:getCharVar('SQUAD_PULL_LOW'), player:getCharVar('SQUAD_PULL_HIGH')
    if lo > 0 and hi > 0 then
        return lo - 100, hi - 100, true
    end

    return CAMP_LEVELS[1], CAMP_LEVELS[2], false
end
local CAMP_PULL_TIMEOUT = 300       -- seconds before a pull that did not work is given up (a 400 yalm run out and back)
local CAMP_PULL_GAP     = { 4, 8 }  -- seconds of quiet at camp before the next pull
local CAMP_READY_HP     = 60        -- everyone at least this much HP (%) before a pull
local CAMP_READY_MP     = 30        -- and everyone with MP (you, your second character, the mates) at least this much
local CAMP_PULL_FLEE_HP = 40        -- a puller this hurt while dragging a monster home drops it and runs for camp
local CAMP_OTHERS_SPACE = 10        -- never a monster this close to another player (bots included)
local camps = {}                    -- [player id] = { zone, x, y, z, puller (mate id, 0 = you), state, since, nextPull, nextTick }

local function campEncode(value)
    return math.floor(value * 100 + 0.5) + 10000000
end

local function squadTrusts(player)
    local out = {}
    for _, member in pairs(player:getPartyWithTrusts()) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') > 0 and xi.squad.mine(player, member) then
            out[#out + 1] = member
        end
    end

    return out
end

-- puts the camp (or no camp) on one mate
local function campApply(player, trust)
    local c = camps[player:getID()]
    if c ~= nil and c.zone == player:getZoneID() then
        trust:setLocalVar('SQUAD_CAMP_X', campEncode(c.x))
        trust:setLocalVar('SQUAD_CAMP_Y', campEncode(c.y))
        trust:setLocalVar('SQUAD_CAMP_Z', campEncode(c.z))
        trust:setLocalVar('SQUAD_CAMP', 1)
    else
        trust:setLocalVar('SQUAD_CAMP', 0)
        trust:setLocalVar('SQUAD_PULL_PHASE', 0)
        trust:setLocalVar('SQUAD_PULL_TARGET', 0)
    end
end

local function campApplyAll(player)
    for _, trust in ipairs(squadTrusts(player)) do
        campApply(player, trust)
    end
end

local function campDistance(c, pos)
    local dx, dz = pos.x - c.x, pos.z - c.z
    return math.sqrt(dx * dx + dz * dz)
end

local function percentOf(entity, now, max)
    local top = entity[max](entity)
    if top == nil or top <= 0 then
        return 100
    end

    return math.floor(entity[now](entity) * 100 / top)
end

-- What the puller may go for: c.want holds one or more monster names, comma separated.
local function campWants(c)
    local list = {}
    if c == nil or c.want == nil then
        return list
    end

    for name in tostring(c.want):gmatch('[^,]+') do
        name = name:match('^%s*(.-)%s*$')
        if name ~= '' then
            list[#list + 1] = name
        end
    end

    return list
end

local function campNameMatches(a, b)
    return tostring(a):lower():gsub('_', ' ') == tostring(b):lower():gsub('_', ' ')
end

local function campWantLabel(c)
    local list = campWants(c)
    if #list == 0 then
        return nil
    end

    local out = {}
    for _, name in ipairs(list) do
        out[#out + 1] = tostring(name):gsub('_', ' ')
    end

    return table.concat(out, ', ')
end

-- Links: monsters of the same kind close together come as a group when one is pulled. The puller counts the ones around a
-- target and leaves a target with more than `max` of them beside it (global: squad.lua is at the local limit).
SQUAD_LINK = SQUAD_LINK or { on = true }
-- (set every load, so a reload applies them) 2026-11-19: Nishiko kept pulling links. Now a target is skipped when ANY same-kind
-- monster is within `radius`, or any other monster is within `near` (they wake to the fight, or link by family); the nearest clean one wins.
SQUAD_LINK.radius = 20
SQUAD_LINK.max = 0
SQUAD_LINK.near = 12

function squadLinkPool(zone)
    local pool = {}
    pcall(function()
        for _, m in ipairs(zone:getMobs() or {}) do
            if m:isAlive() and not m:isEngaged() then
                local pos = m:getPos()
                pool[#pool + 1] = { id = m:getID(), name = m:getName(), x = pos.x, z = pos.z }
            end
        end
    end)

    return pool
end

function squadLinkCount(pool, mob, pos)
    local n, name, id, R = 0, mob:getName(), mob:getID(), SQUAD_LINK.radius
    for _, o in ipairs(pool) do
        if o.id ~= id then
            local dx, dz = o.x - pos.x, o.z - pos.z
            local d2 = dx * dx + dz * dz
            if (o.name == name and d2 <= R * R) or d2 <= (SQUAD_LINK.near or 12) ^ 2 then
                n = n + 1
            end
        end
    end

    return n
end

-- the next monster for the puller: in range of camp, the right level, nobody else's, nearest to camp first
local function campPick(player, c)
    local zone = player:getZone()
    if zone == nil then
        return nil
    end

    local others = {}
    for _, p in ipairs(zone:getPlayers() or {}) do
        local inParty = false
        for _, member in pairs(player:getPartyWithTrusts()) do
            if member:getID() == p:getID() then
                inParty = true
            end
        end

        if not inParty then
            others[#others + 1] = p:getPos()
        end
    end

    -- 2026-11-19: the level window is measured from the weakest one in the party, not from you (Nishiko pulled a level 46 Doom Scorpion
    -- onto a level 40 squad because you are higher): a pull has to be fair for everyone who has to fight it
    local lvl = player:getMainLvl()
    pcall(function()
        for _, t in ipairs(squadTrusts(player)) do
            if t:isAlive() and t:getMainLvl() > 0 and t:getMainLvl() < lvl then
                lvl = t:getMainLvl()
            end
        end
    end)

    local range = campRange(player)
    local wants = campWants(c)
    local best, bestD = nil, math.huge
    local linkPool = SQUAD_LINK.on and squadLinkPool(zone) or {}
    local skippedLinks = 0
    local dg = { alive = 0, kind = 0, range = 0, others = 0 }
    for _, mob in ipairs(zone:getMobs() or {}) do
        local ok, usable = pcall(function()
            if not mob:isAlive() or mob:isNM() or mob:isEngaged() then
                return false
            end

            if xi.allegiance and xi.allegiance.MOB and mob:getAllegiance() ~= xi.allegiance.MOB then
                return false
            end

            -- the kinds you picked in the menu (any level up to a little above yours), or the usual level window
            local ml = mob:getMainLvl()
            if #wants > 0 then
                if ml > lvl + CAMP_WANT_ABOVE then
                    return false
                end

                local name = mob:getName()
                for _, wanted in ipairs(wants) do
                    if campNameMatches(name, wanted) then
                        return true
                    end
                end

                return false
            end

            local low, high = squadCampLevels(player)
            return ml >= lvl + low and ml <= lvl + high
        end)
        if ok and usable then
            local pos = mob:getPos()
            local d = campDistance(c, pos)
            if math.abs(pos.y - c.y) > CAMP_MAX_DY then
                d = math.huge -- (another floor)
            end

            dg.kind = dg.kind + 1
            if d <= range then
                dg.range = dg.range + 1
            end

            -- 2026-11-19: a monster whose pull ran far off the leash (a detour round a ledge or wall) is left alone for two minutes
            if c.skip ~= nil and (c.skip[mob:getID()] or 0) > os.time() then
                d = math.huge
            end

            if d <= range then
                local free = true
                for _, op in ipairs(others) do
                    local dx, dz = op.x - pos.x, op.z - pos.z
                    if dx * dx + dz * dz < CAMP_OTHERS_SPACE * CAMP_OTHERS_SPACE then
                        free = false
                    end
                end

                -- 2026-11-19: the puller goes for the CLOSEST monster. One that would link counts as farther away by SQUAD_LINK.penalty yalms
                -- (25), so a clean one is taken only when it is not much farther than the closest; a linked one is never a hard "no".
                local score = d
                if free and SQUAD_LINK.on then
                    local okL, links = pcall(squadLinkCount, linkPool, mob, pos)
                    if okL and links > SQUAD_LINK.max then
                        score = score + (SQUAD_LINK.penalty or 25)
                        skippedLinks = skippedLinks + 1
                    end
                end

                if free and score < bestD then
                    best, bestD = mob, score
                end
            end
        end
    end

    if best == nil then
        -- (2026-11-19) why nothing was picked: how many monsters matched the kind or level window, and how many of those are inside the range
        local nowT = os.time()
        if nowT - (SQUAD_PICKDIAG or 0) >= 15 then
            SQUAD_PICKDIAG = nowT
            print(string.format('[squad] pull: nothing to pull: %d match the kind or level window (party level %d, window %s), %d of them within %d yalms of camp, %d skipped as links',
                dg.kind, lvl, (#wants > 0) and ('kinds ' .. table.concat(wants, ',') .. ' up to +' .. CAMP_WANT_ABOVE) or table.concat({ squadCampLevels(player) }, '..', 1, 2), dg.range, range, skippedLinks))
        end
    end

    if best == nil and skippedLinks > 0 then
        print(string.format('[squad] pull: %d target(s) skipped, too many of the same kind close together (they link)', skippedLinks))
    end

    return best
end

local function campSay(player, mate, text)
    -- The puller can be gone by the time a line is said (died, dismissed,
    -- zoned out). printToPlayer with a nil name is what threw inside the TICK
    -- listener at 06:18, so a missing mate falls back to an unnamed line.
    local name = nil
    if mate ~= nil then
        pcall(function()
            name = mate:getPacketName()
        end)
    end

    if name then
        player:printToPlayer(text, 4, name)
    else
        player:printToPlayer(text)
    end
end

-----------------------------------
-- Skillchains, the way a party did them: one melee mate opens (only when someone else, you included, has the TP to
-- close), the others hold their TP (up to 2000) for an opening and close it about 3 seconds after it lands, with the
-- best chain they have. Your own weapon skills open for them too. A lone melee mate holds for yours (up to 1500).
-- The opener calls it in party chat, so you can close it yourself. Mages magic burst (their job rules).
-----------------------------------
local SC_MELEE    = { [1] = true, [2] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true, [12] = true, [13] = true,
                      [14] = true, [16] = true, [17] = true, [18] = true }
local SC_HOLD     = 1500  -- a closer weapon skills anyway at this much TP (was 2000)
local SC_HOLD_ONE = 1500  -- a lone melee mate (holding for yours)
local SC_ROLE     = { opener = 1, closer = 2, alone = 3 }
local wsNames     = nil

local function wsName(id)
    if wsNames == nil then
        wsNames = {}
        for key, value in pairs(xi.weaponskill or {}) do
            wsNames[value] = (key:lower():gsub('_', ' '):gsub('(%a)([%w]*)', function(a, b) return a:upper() .. b end))
        end
    end

    return wsNames[id] or 'a weapon skill'
end

-- who opens and who closes (every few seconds while fighting): the first melee mate opens (a Red Mage only if no one
-- else can), the rest close
local function skillchainRoles(player)
    local melee = {}
    local customClosers = 0
    for _, trust in ipairs(squadTrusts(player)) do
        local ownTp = trust:getLocalVar('SQUAD_WSTP') -- set with !squad ws <slot> <tp>: this mate keeps its own timing
        if trust:isAlive() and trust:getLocalVar('SQUAD_WSC') > 0 then
            -- (Gambits weapon skill settings, squad_ws.lua) a Custom mate keeps its own setting; one that closes still lets a
            -- lone melee mate open for it
            if trust:getLocalVar('SQUAD_WSC_CLOSE_TP') > 0 then
                customClosers = customClosers + 1
            end
        elseif trust:isAlive() and ownTp > 0 then
            local role = 100 + math.floor(ownTp / 100)
            if trust:getLocalVar('SQUAD_SC_ROLE') ~= role then
                trust:setLocalVar('SQUAD_SC_ROLE', role)
                pcall(function()
                    if ownTp >= 1500 then
                        trust:setTrustTPSkillSettings(ai.tp.CLOSER_UNTIL_TP, ai.s.HIGHEST, ownTp)
                    else
                        trust:setTrustTPSkillSettings(ai.tp.ASAP, ai.s.HIGHEST, 0) -- (the game's lowest is 1000 TP)
                    end
                end)
            end
        elseif trust:isAlive() and SC_MELEE[trust:getMainJob()] then
            melee[#melee + 1] = trust
        end
    end

    table.sort(melee, function(a, b)
        local ar, br = a:getMainJob() == 5 and 1 or 0, b:getMainJob() == 5 and 1 or 0
        if ar ~= br then
            return ar < br
        end

        return a:getLocalVar('SQUAD_ID') < b:getLocalVar('SQUAD_ID')
    end)

    for i, trust in ipairs(melee) do
        local role = (#melee == 1 and customClosers == 0 and SC_ROLE.alone) or (i == 1 and SC_ROLE.opener) or SC_ROLE.closer
        if trust:getLocalVar('SQUAD_SC_ROLE') ~= role then
            trust:setLocalVar('SQUAD_SC_ROLE', role)
            pcall(function()
                if role == SC_ROLE.opener then
                    trust:setTrustTPSkillSettings(ai.tp.OPENER, ai.s.HIGHEST, 1000)
                elseif role == SC_ROLE.closer then
                    trust:setTrustTPSkillSettings(ai.tp.CLOSER_UNTIL_TP, ai.s.HIGHEST, SC_HOLD)
                else
                    trust:setTrustTPSkillSettings(ai.tp.CLOSER_UNTIL_TP, ai.s.HIGHEST, SC_HOLD_ONE)
                end
            end)
        end
    end
end

local function skillchainTick(mob)
    local player = mob:getMaster()
    if player == nil or player:getObjType() ~= xi.objType.PC then
        return
    end

    local now = os.time()
    if now < mob:getLocalVar('SQUAD_SC_AT') then
        return
    end

    mob:setLocalVar('SQUAD_SC_AT', now + 4)
    skillchainRoles(player)
end

-- a mate's weapon skill landed: it opened a chain (tell the party, so you can close it) or closed one
local function skillchainCall(mob, target, skill)
    local player = mob:getMaster()
    if player == nil or target == nil then
        return
    end

    local ok, tier = pcall(function()
        local effect = target:getStatusEffect(xi.effect.SKILLCHAIN)
        return effect and effect:getTier() or -1
    end)
    if not ok or tier ~= 0 then
        return -- (it closed one: the game itself says "Skillchain: ...")
    end

    local now = os.time()
    if now < mob:getLocalVar('SQUAD_SC_SAID') then
        return
    end

    mob:setLocalVar('SQUAD_SC_SAID', now + 8)
    local name = wsName(skill and skill.getID and skill:getID() or 0)
    campSay(player, mob, ({ 'Opening with %s, close it!', '%s, go!', 'Opener: %s' })[math.random(1, 3)]:format(name))
end

local function campStop(puller)
    puller:setLocalVar('SQUAD_PULL_PHASE', 0)
    puller:setLocalVar('SQUAD_PULL_TARGET', 0)
end

-- A monster that casts or shoots stops short of the camp. far = how far from camp it may stand before the puller runs past the
-- camp to bring it in, past = how far beyond the camp that run goes, near = close enough to the camp, max = tries per pull,
-- timeout = seconds. (global: squad.lua is at the local limit)
SQUAD_HOLD = SQUAD_HOLD or {}
SQUAD_DRAG = SQUAD_DRAG or { on = true, far = 14, past = 16, near = 10, max = 2, timeout = 14 }

-- why the camp is not pulling (map log, at most every 10 s)
function squadCampWhy(c, text)
    local now = os.time()
    if now >= (c.whyAt or 0) then
        c.whyAt = now + 10
        print('[squad] camp: ' .. text)
    end
end

-- once a second (from the mates' ticks): the puller's next pull, when the camp is quiet and everyone is ready
local function campTick(mob)
    local player = mob:getMaster()
    if player == nil or player:getObjType() ~= xi.objType.PC then
        return
    end

    local c = camps[player:getID()]
    local now = os.time()
    if c == nil or now < (c.nextTick or 0) then
        return
    end

    c.nextTick = now + 1
    if player:getZoneID() ~= c.zone then
        camps[player:getID()] = nil
        campApplyAll(player)
        say(player, 'Camp lifted: you left the area. Your squad follows you again.')
        return
    end

    -- 2026-11-19: a zone with floors (Crawlers' Nest): when you stand on another floor than the camp for a few seconds (not mid pull or fight),
    -- the camp moves to where you are, and the menu's monster list and the pulls follow that floor. Same settings, same Start / Pause state.
    local okF = pcall(function()
        local py = player:getYPos()
        if c.state ~= 'pulling' and not player:isEngaged() and math.abs(py - c.y) > CAMP_MAX_DY then
            c.floorAt = c.floorAt or now
            if now - c.floorAt >= 6 then
                c.x, c.y, c.z = player:getXPos(), py, player:getZPos()
                c.floorAt = nil
                campApplyAll(player)
                say(player, 'Camp moved to the floor you are on. The monsters around you are the ones it pulls now.')
            end
        else
            c.floorAt = nil
        end
    end)

    if c.puller == 0 then
        squadCampWhy(c, 'puller is set to you (!squad camp puller <slot> to give it to a mate)')
        return -- (you pull: the mates hold and fight what you bring)
    end

    local trusts = squadTrusts(player)
    local puller
    for _, trust in ipairs(trusts) do
        if trust:getLocalVar('SQUAD_ID') == c.puller then
            puller = trust
        end
    end

    if puller == nil or not puller:isAlive() then
        c.state = 'idle'
        squadCampWhy(c, string.format('the puller (mate id %s) is not out or is down; mates out: %d', tostring(c.puller), #trusts))
        return
    end

    if c.state == 'pulling' then
        -- (diagnostics for the map log, every 3 seconds: where the puller is and how fast it moves)
        if now >= (c.logAt or 0) then
            pcall(function()
                local pp, t = puller:getPos(), c.targetEnt
                local tp = t and t:getPos()
                local moved = c.lastPos and math.sqrt((pp.x - c.lastPos.x) ^ 2 + (pp.z - c.lastPos.z) ^ 2) or 0
                print(string.format('[squad] pull: %s phase %d, %.0f yalms to %s (engaged %s), %.0f from camp, moved %.1f yalms in %ds, engaged %s',
                    puller:getPacketName(), puller:getLocalVar('SQUAD_PULL_PHASE'), tp and math.sqrt((pp.x - tp.x) ^ 2 + (pp.z - tp.z) ^ 2) or -1,
                    t and t:getName() or '?', t and tostring(t:isEngaged()) or '?', campDistance(c, pp), moved, now - (c.lastLogAt or now),
                    tostring(puller:isEngaged())))
                c.lastPos, c.lastLogAt = pp, now
            end)
            c.logAt = now + 3
        end

        -- 2026-11-19 leash: a puller that has strayed this far past the pull range is taking a long way round (a ledge, a wall, a
        -- drop); that is where mates fell off. Give the pull up, run for camp, and leave that monster alone for two minutes.
        do
            local okL, farL = pcall(function() return campDistance(c, puller:getPos()) end)
            if okL and farL ~= nil and farL > campRange(player) + 25 and puller:getLocalVar('SQUAD_PULL_PHASE') == 1 then
                if c.targetEnt ~= nil then
                    c.skip = c.skip or {}
                    c.skip[c.targetEnt:getID()] = now + 120
                end

                campStop(puller)
                c.state, c.nextPull = 'idle', now + 10
                campSay(player, puller, 'too far round, coming back')
                print(string.format('[squad] pull: %s is %.0f yalms from camp, past the leash; giving this one up', puller:getPacketName(), farL))
                return
            end
        end

        -- Being chewed on while dragging a monster home is what killed the
        -- puller: give the pull up and run for camp instead.
        local hpPct = percentOf(puller, 'getHP', 'getMaxHP')
        if hpPct < CAMP_PULL_FLEE_HP then
            campStop(puller)
            c.state, c.nextPull = 'idle', now + 20
            campSay(player, puller, 'too hurt, dropping it - help')
            print(string.format('[squad] pull: %s at %d%% HP, dropped the pull and headed back', puller:getPacketName(), hpPct))
            return
        end

        local phase = puller:getLocalVar('SQUAD_PULL_PHASE')
        local D = SQUAD_DRAG
        -- The mates at camp stand their ground until the monster is at camp: nobody runs out to catch it.
        do
            local foe, far = c.targetEnt, true
            pcall(function()
                far = foe ~= nil and foe:isAlive() and campDistance(c, foe:getPos()) > D.near
            end)
            if far then
                SQUAD_HOLD[player:getID()] = { puller = c.puller, untilT = now + 2 }
                for _, trust in ipairs(trusts) do
                    if trust:getLocalVar('SQUAD_ID') ~= c.puller and trust:isEngaged() then
                        pcall(function() trust:disengage() end)
                    end
                end
            else
                SQUAD_HOLD[player:getID()] = nil
            end
        end
        if c.dragging then
            -- Running past the camp so a monster that stopped short (a ranged or magic one) follows to the party.
            local foe, near = c.targetEnt, false
            pcall(function()
                near = foe == nil or not foe:isAlive() or campDistance(c, foe:getPos()) <= D.near
            end)
            if phase == 0 or near or now - (c.dragSince or now) > D.timeout then
                c.dragging = nil
                campApply(player, puller) -- the real camp again
                puller:setLocalVar('SQUAD_PULL_PHASE', 2) -- and back to it with the monster, then he engages it like after any pull
                print(string.format('[squad] pull: %s finished the drag after %ds (monster near camp: %s), heading back to camp', puller:getPacketName(),
                    now - (c.dragSince or now), tostring(near)))
            end

            return
        end

        if phase == 0 then
            -- back at camp. A monster that stopped short of it (it casts or shoots from a distance) is not brought home
            -- yet: the puller runs past the camp, on the far side from the monster, and it follows to the party.
            local foe, drag = c.targetEnt, false
            pcall(function()
                if D.on and foe ~= nil and foe:isAlive() and foe:isEngaged() and (c.drags or 0) < D.max and now - (c.pullStart or now) < 120 then
                    local fp = foe:getPos()
                    local dx, dz = c.x - fp.x, c.z - fp.z
                    local len = math.sqrt(dx * dx + dz * dz)
                    if len > D.far then
                        local px, pz = c.x + dx / len * D.past, c.z + dz / len * D.past
                        puller:setLocalVar('SQUAD_CAMP_X', campEncode(px))
                        puller:setLocalVar('SQUAD_CAMP_Y', campEncode(c.y))
                        puller:setLocalVar('SQUAD_CAMP_Z', campEncode(pz))
                        puller:setLocalVar('SQUAD_PULL_PHASE', 2)
                        c.dragging, c.dragSince, c.drags, drag = true, now, (c.drags or 0) + 1, true
                        print(string.format('[squad] pull: %s is home but %s stopped %.0f yalms from camp, running past the camp to bring it in',
                            puller:getPacketName(), foe:getName(), len))
                    end
                end
            end)
            if drag then
                return
            end

            c.drags = nil
            c.state, c.since = 'fighting', now -- back at camp with it (or it is gone)
            print(string.format('[squad] pull: %s is back (or the target is gone) after %ds', puller:getPacketName(), now - (c.pullStart or now)))
        elseif now - c.since > CAMP_PULL_TIMEOUT then
            campStop(puller)
            c.state, c.nextPull = 'idle', now + 10
            campSay(player, puller, 'cant get to it, coming back')
            print(string.format('[squad] pull: %s gave up after %ds', puller:getPacketName(), now - (c.pullStart or now)))
        end

        return
    end

    local busy, busyWho = player:isEngaged(), player:isEngaged() and 'you' or nil
    for _, trust in ipairs(trusts) do
        if trust:isEngaged() then
            busy = true
            busyWho = busyWho or trust:getPacketName()
        end
    end

    if busy then
        c.state = 'fighting'
        squadCampWhy(c, string.format('not pulling: %s is still engaged', tostring(busyWho)))
        return
    end

    if c.state == 'fighting' then
        c.state, c.nextPull = 'idle', now + math.random(CAMP_PULL_GAP[1], CAMP_PULL_GAP[2])
    end

    if now < (c.nextPull or 0) or c.paused then
        if c.paused then
            squadCampWhy(c, 'not pulling: the camp is paused')
        end

        return
    end

    -- everyone ready? (not while anyone rests, nobody hurt, everyone with MP has some: you, a second character, the mates)
    local everyone = {}
    for _, member in pairs(player:getPartyWithTrusts() or {}) do
        everyone[#everyone + 1] = member
    end

    if #everyone == 0 then
        everyone = { player }
    end

    -- (2026-11-21, levi) MP holds a pull only for the healer: a mate set to the healer role (or on auto as a WHM), or a
    -- character on WHM. HP and resting still count for everyone. With no healer out, everyone's MP counts as before.
    local function isHealer(member)
        if member:getObjType() == xi.objType.PC then
            return member:getMainJob() == xi.job.WHM
        end

        local role = decodeBehavior(player:getCharVar('SQUAD_AI_' .. member:getLocalVar('SQUAD_ID')))
        return role == 'healer' or (role == 'auto' and member:getMainJob() == xi.job.WHM)
    end

    local anyHealer = false
    for _, member in ipairs(everyone) do
        if member:getObjType() == xi.objType.PC and isHealer(member) then anyHealer = true end
    end

    for _, trust in ipairs(trusts) do
        if isHealer(trust) then anyHealer = true end
    end

    local function mpLow(member)
        return (not anyHealer or isHealer(member)) and member:getMaxMP() > 0 and percentOf(member, 'getMP', 'getMaxMP') < CAMP_READY_MP
    end

    for _, member in ipairs(everyone) do
        if member:getObjType() == xi.objType.PC and (member:getAnimation() == xi.animation.HEALING or percentOf(member, 'getHP', 'getMaxHP') < CAMP_READY_HP or
            mpLow(member)) then
            -- (2026-11-21) the line names who is short and of what: it was read as the healer's MP when it was yours
            local hpLow = percentOf(member, 'getHP', 'getMaxHP') < CAMP_READY_HP
            local short = member:getAnimation() == xi.animation.HEALING and 'is resting' or (hpLow and 'needs HP' or 'needs MP')
            if not c.waitSaid then
                c.waitSaid = true
                campSay(player, puller, string.format('waiting a bit, %s %s', member:getName(), short))
            end

            squadCampWhy(c, string.format('waiting: %s %s (HP %d%% MP %d%%; needs %d%% HP, %d%% MP)', member:getName(), short,
                percentOf(member, 'getHP', 'getMaxHP'), percentOf(member, 'getMP', 'getMaxMP'), CAMP_READY_HP, CAMP_READY_MP))
            c.nextPull = now + 5
            return
        end
    end

    for _, trust in ipairs(trusts) do
        if not trust:isAlive() or percentOf(trust, 'getHP', 'getMaxHP') < CAMP_READY_HP or mpLow(trust) then
            if not c.waitSaid then
                c.waitSaid = true
                campSay(player, puller, string.format('waiting a bit, %s needs %s', trust:getPacketName(),
                    percentOf(trust, 'getHP', 'getMaxHP') < CAMP_READY_HP and 'HP' or 'MP'))
            end

            squadCampWhy(c, string.format('waiting: %s HP %d%% MP %d%% (needs %d%% HP, %d%% MP)', trust:getPacketName(), percentOf(trust, 'getHP', 'getMaxHP'),
                percentOf(trust, 'getMP', 'getMaxMP'), CAMP_READY_HP, CAMP_READY_MP))
            c.nextPull = now + 5
            return
        end
    end

    c.waitSaid = nil
    local target = campPick(player, c)
    if target == nil then
        c.nextPull = now + 10
        squadCampWhy(c, 'no target found within range and level window')
        if not c.noneSaid then
            c.noneSaid = true
            local wantLabel = campWantLabel(c)
            campSay(player, nil, wantLabel and ('no ' .. wantLabel .. ' around right now, waiting for pops') or 'nothing to pull nearby, waiting for pops')
        end

        return
    end

    c.noneSaid = nil

    -- 2026-11-19: a puller with Ninjutsu (sub job Ninja) puts up Utsusemi: Ichi before the run out. One try per 20 seconds, so a failed cast never stalls the pull.
    local okU, castU = pcall(function()
        if puller:getSubJob() == 13 and puller:getSubLvl() >= 12 and not puller:hasStatusEffect(xi.effect.COPY_IMAGE)
            and puller:getMP() >= 24 and now >= puller:getLocalVar('SQUAD_UTSU_AT')
        then
            puller:setLocalVar('SQUAD_UTSU_AT', now + 20)
            puller:castSpell(338, puller)
            return true
        end

        return false
    end)
    if okU and castU then
        c.nextPull = now + 4
        return
    end

    -- ... and Monomi: Ichi (Sneak) from sub level 25, so the run out is quiet
    local okM, castM = pcall(function()
        if puller:getSubJob() == 13 and puller:getSubLvl() >= 25 and not puller:hasStatusEffect(xi.effect.SNEAK)
            and puller:getMP() >= 20 and now >= puller:getLocalVar('SQUAD_MONOMI_AT')
        then
            puller:setLocalVar('SQUAD_MONOMI_AT', now + 20)
            puller:castSpell(318, puller)
            return true
        end

        return false
    end)
    if okM and castM then
        c.nextPull = now + 4
        return
    end

    puller:setLocalVar('SQUAD_PULL_TARGET', target:getTargID())
    puller:setLocalVar('SQUAD_PULL_PHASE', 1)
    c.state, c.since = 'pulling', now
    c.pullStart, c.targetEnt, c.lastPos, c.lastLogAt, c.logAt = now, target, nil, nil, now
    c.pulls = (c.pulls or 0) + 1
    pcall(function()
        print(string.format('[squad] pull: %s (job %d, MP %d) goes for %s (level %d), %.0f yalms from camp', puller:getPacketName(), puller:getMainJob(),
            puller:getMP(), target:getName(), target:getMainLvl(), campDistance(c, target:getPos())))
    end)
    campSay(player, puller, string.format('Pulling >> %s <<', target:getName()))
end

local function campStatus(player)
    local c = camps[player:getID()]
    if c == nil then
        return 'No camp: your squad follows you. Set one here with !squad camp.'
    end

    local who = 'you'
    if c.pullerBot then
        local b = GetPlayerByID(c.pullerBot)
        who = b and (b:getName() .. ' (bot)') or 'a bot who left'
    elseif c.puller ~= 0 then
        for _, trust in ipairs(squadTrusts(player)) do
            if trust:getLocalVar('SQUAD_ID') == c.puller then
                who = trust:getPacketName()
            end
        end
        if who == 'you' then
            who = 'a mate who is not out'
        end
    end

    return string.format('Camp: %d yalms from you, %s pulling%s (%d pulls so far, pull range %d yalms).', math.floor(campDistance(c, player:getPos())), who,
        c.paused and ' (paused)' or '', c.pulls or 0, campRange(player)) .. (campWantLabel(c) and (' Pulling only: ' .. campWantLabel(c)) or '')
end

-- The first time a squad mate comes out as a job, they get basic level 1 gear for it. A marker row (slot 255) in
-- the saved gear remembers that this happened, so taking gear off later does not bring the starter set back.
local STARTER_MARK = 255

-- How long to wait between squad mates when they are all called at once (milliseconds)
local CALL_GAP_MS = 1500
RECALL_WAIT_MS = 4000 -- (global: 200-local limit) after sending mates off, wait this long before calling them again: a mate
                      -- called back at once can show up in plain clothes (the game still has the old one on screen)
ZONE_WAIT_MS = 7000   -- after zoning: the game is still loading the area for a few seconds
NEW_MATE_MAX_LEVEL = 12   -- (global: this file is near Lua's 200-local limit) the highest level a new mate may start at

-- The basic level 1 sets come from squad_starter_gear.lua (build_starter_gear.py writes it from your database): the game's own
-- weapon for each job plus plain level 1 armor, never rare/ex or event items. If the file is missing the old picker is used.
local starterLoaded, starterSets = pcall(require, 'modules/custom/lua/squad_starter_gear')
if not starterLoaded or type(starterSets) ~= 'table' then
    print('[squad] squad_starter_gear.lua not found - using the old starter gear picker. Run build_starter_gear.py to create it.')
    starterSets = nil
end

-- The starter weapon (and the Monk's White Belt) is fixed; each armor slot is drawn at random from the plain pieces the job can
-- wear at that level (pools from build_starter_gear.py, levels 1-10), so no two mates start out alike.
local STARTER_POOL_MAX_LEVEL = 10

local function starterGearFor(job, level)
    local fixed = (starterSets ~= nil and starterSets[job]) or BuildStarterGear(job)
    local pools = starterSets ~= nil and type(starterSets.pools) == 'table' and starterSets.pools[job] or nil
    if pools == nil then
        return fixed
    end

    local cap  = math.max(1, math.min(level or 1, STARTER_POOL_MAX_LEVEL))
    local gear = {}
    for slot, itemId in pairs(fixed) do
        gear[slot] = itemId
    end

    for slot, list in pairs(pools) do
        local choices = {}
        for _, entry in ipairs(list) do
            if entry[2] <= cap then
                choices[#choices + 1] = entry[1]
            end
        end

        if #choices > 0 then
            gear[slot] = choices[math.random(#choices)]
        end
    end

    return gear
end

local function ensureStarterGear(player, mate)
    local worn = mate.equip[mate.mjob] or {}
    mate.equip[mate.mjob] = worn

    if worn[STARTER_MARK] ~= nil then
        return
    end

    for slot, itemId in pairs(starterGearFor(mate.mjob, jobLevel(mate, mate.mjob))) do
        if worn[slot] == nil then
            SetSquadEquip(mate.id, mate.mjob, slot, itemId)
            UnlockSquadItem(player:getID(), itemId) -- basic gear is free for the whole squad
            worn[slot] = itemId
        end
    end

    SetSquadEquip(mate.id, mate.mjob, STARTER_MARK, 1)
    worn[STARTER_MARK] = 1
end

-----------------------------------
-- Level sync (v1.7): a mate never comes out above YOUR current level. getMainLvl() already follows the game's own Level Sync,
-- so syncing your party in the game syncs the squad too. A mate whose own level is lower keeps it. Like the game's Level Sync,
-- gear above the synced level is left off while synced. Their own levels and exp are kept; a synced mate still earns exp.
-- When your level changes (level up, job change, Level Sync on or off), the squad is called again at the new level as soon as
-- nobody is fighting.
-----------------------------------
local SYNC_TO_PLAYER   = true
local RESYNC_EVERY_SEC = 5

local itemLevels = {}
local function itemLevel(itemId)
    if itemLevels[itemId] == nil then
        local info = GetSquadItemInfo(itemId)
        itemLevels[itemId] = (info and info.valid and info.level) or 0
    end

    return itemLevels[itemId]
end

local function syncCap(player)
    if not SYNC_TO_PLAYER then
        return nil
    end

    return player:getMainLvl()
end

local resyncSquad -- defined after callMate
local zoneOut = {} -- [player id] = { [squad id] = last seen out (os.time()), mh = true while in your Mog House }: called again after zoning
local restTick    -- defined after callMate

-- The squad in "call all" order (!squad order; char var SQUAD_ORDER holds the slots as digits, e.g. 312)
local function orderedSquad(player, list)
    local code = player:getCharVar('SQUAD_ORDER')
    local out = {}
    for k, mate in ipairs(list) do
        out[k] = mate
    end

    if code <= 0 then
        return out
    end

    local rank, i = {}, 0
    for d in tostring(code):gmatch('%d') do
        i = i + 1
        rank[tonumber(d)] = rank[tonumber(d)] or i
    end

    table.sort(out, function(a, b)
        return (rank[a.slot] or (100 + a.slot)) < (rank[b.slot] or (100 + b.slot))
    end)
    return out
end

-----------------------------------
-- Squad chat (Ollama sidecar): in-character party chat and generated backstories.
-- The Python sidecar in <kit>/squad-chat owns the character sheets, memory and the model. The kit folder comes from
-- kit_paths.lua, which the launcher writes every launch (C:/FFXISOLO if it is missing).
-- This file only passes chat out and plays the replies in party chat.
-----------------------------------
local CHAT_DIR = (function()   -- no new file-level locals: this file is close to Lua's limit of 200
    local ok, paths = pcall(require, 'modules/custom/lua/kit_paths')
    if ok and type(paths) == 'table' and type(paths.kit) == 'string' and paths.kit ~= '' then return paths.kit .. 'squad-chat/' end
    return 'C:/FFXISOLO/squad-chat/'
end)()
local CHAT_IN = CHAT_DIR .. 'in.txt'
local CHAT_OUT = CHAT_DIR .. 'out.txt'
local CHAT_POLL_SEC = 1

-- The stand-in tests load this file without a real server: keep them away from the real bridge files.
local CHAT_ACTIVE = rawget(_G, '__SQUAD_TEST') == nil

xi = xi or {}
xi.squad = xi.squad or {}

-- Co-op (modules/custom/late/coop.lua): a friend's character visiting this world brings its own squad. With a visitor
-- in the party each player's squad is its own (camp, pulls, exp), and a visitor's squad never talks to this world's
-- squad-chat sidecar, which knows one leader: the owner. In a world without visitors both answers below are always
-- "mine" and "not a visitor", so nothing changes there. (Kept on xi.squad: no room for more file-level locals.)
xi.squad.mine = function(player, mate)
    local coop = rawget(xi, 'coop')
    if type(coop) ~= 'table' or type(coop.ownMate) ~= 'function' then
        return true
    end

    return coop.ownMate(player, mate)
end

xi.squad.visitor = function(player)
    local coop = rawget(xi, 'coop')
    if type(coop) ~= 'table' or type(coop.isGuest) ~= 'function' then
        return false
    end

    return coop.isGuest(player) == true
end

-- Exp: is this the player a mate earns through? A mate is paid once per kill (and once per finished page), on its own
-- player's share, the way a player in the party is. Before 2026-11-17 every player-type member near the kill paid
-- every mate again: double with a second character in the party, more with bot players.
xi.squad.pays = function(player, mate)
    local ownerId = 0
    local master = mate:getMaster()
    if type(master) == 'userdata' or type(master) == 'table' then -- (an entity; the stand-in tests use tables)
        ownerId = master:getID()
    end

    if ownerId == 0 then
        ownerId = mate:getLocalVar('MASTER_ID')
    end

    return ownerId ~= 0 and ownerId == player:getID()
end

local function chatClean(text)
    text = tostring(text or '')
    text = string.gsub(text, '[\r\n\t]', ' ')
    text = string.gsub(text, '%z', ' ')
    return text
end

local function chatSend(kind, ...)
    if xi.squad.chatMuted == true then -- (a visitor's !squad command is running: see the end of the command)
        return false
    end

    local parts = { kind }
    for i = 1, select('#', ...) do
        parts[#parts + 1] = chatClean(select(i, ...))
    end

    if not CHAT_ACTIVE then
        local test = rawget(_G, '__SQUAD_TEST')
        if test and test.chatSink then
            test.chatSink(table.concat(parts, '\t')) -- (the stand-in tests read what would go to the sidecar)
        end

        return false
    end

    local handle = io.open(CHAT_IN, 'a')
    if handle == nil then
        return false
    end

    handle:write(table.concat(parts, '\t'), '\n')
    handle:close()
    return true
end

local function chatEnabled(player)
    return player:getCharVar('SQUAD_CHAT_OFF') ~= 1
end

local function chatActiveNames(player)
    local names = {}
    for _, member in pairs(player:getPartyWithTrusts()) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') > 0 and member:isAlive() and xi.squad.mine(player, member) then
            names[#names + 1] = member:getPacketName()
        end
    end

    return table.concat(names, ',')
end

local function chatHasActive(player)
    for _, member in pairs(player:getPartyWithTrusts()) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') > 0 and member:isAlive() and xi.squad.mine(player, member) then
            return true
        end
    end

    return false
end

-- What is happening right now (fight awareness) and the bot players in your party (bots.lua).
local chatFightState = { engaged = false, nextFight = 0, calls = {} }
local chatBotsInParty = {} -- [bot name] = { fights = n }

-- A few real adventure beats go into the sidecar's journal, not just zones and levels.
-- The hook is per player and weak-keyed, so a relog or a new character gets its own listeners.
local chatHookedPlayers = setmetatable({}, { __mode = 'k' })
local function chatHookPlayer(player)
    if chatHookedPlayers[player] then
        return
    end

    chatHookedPlayers[player] = true
    player:addListener('DEFEATED_MOB', 'SQUAD_CHAT_KILL', function(mob)
        if mob == nil then
            return
        end

        local ok, notorious = pcall(function() return mob:isNM() end)
        if ok and notorious then
            chatSend('BATTLE', mob:getName(), 1)
        end
    end)

    player:addListener('DEATH', 'SQUAD_CHAT_DEATH', function()
        chatSend('DEATH', player:getZoneName())
        if type(xi.squad.pack) == 'table' then
            pcall(xi.squad.pack.onPlayerDeath, player)
        end
    end)

    -- Your weapon skills: a mate may cheer (or needle) you. At most one every 20 seconds.
    player:addListener('WEAPONSKILL_USE', 'SQUAD_CHAT_WS', function(entity, target, skill, tp, action, damage)
        local now = os.time()
        if now < (chatFightState.wsAt or 0) then
            return
        end

        chatFightState.wsAt = now + 20
        chatSend('ACT', 'ws', player:getName(), target and target:getName() or '', tonumber(damage) or 0)
    end)

    -- Every kill counts towards the fights a bot player shared with you (for the journal when it leaves).
    player:addListener('DEFEATED_MOB', 'SQUAD_CHAT_SHARED', function(mob)
        for name in pairs(chatBotsInParty) do
            chatBotsInParty[name].fights = chatBotsInParty[name].fights + 1
        end

        if mob ~= nil then
            chatFightState.wonName = mob:getName()
        end
    end)
end

local chatLastZone = nil
local chatLastLevel = nil
local chatLastContext = 0

local function chatPushContext(player)
    chatHookPlayer(player)
    local now = os.time()
    local zone = player:getZoneName()
    local level = player:getMainLvl()
    if zone == chatLastZone and level == chatLastLevel and now - chatLastContext < 15 then
        return
    end

    chatSend('CTX', zone, level, player:isEngaged() and 1 or 0, chatActiveNames(player), player:getName(), player:getRace()) -- name and race: who the mates follow
    chatSend('CHAT_STATE', chatEnabled(player) and 1 or 0)
    chatLastContext = now

    -- The first poll only records where you are; the sidecar should not announce the zone you logged in at.
    if chatLastZone ~= nil and zone ~= chatLastZone then
        chatSend('ZONE', zone)
    end

    if chatLastLevel ~= nil and level ~= chatLastLevel then
        chatSend('LEVEL', level)
    end

    chatLastZone = zone
    chatLastLevel = level
end

local function chatPercent(entity, now, max)
    local ok, value = pcall(function()
        local top = entity[max](entity)
        if top == nil or top <= 0 then
            return -1
        end

        return math.floor(entity[now](entity) * 100 / top)
    end)
    return ok and value or -1
end

-- a callout at most every `every` seconds for the same thing ('lowmp:Kasumi')
local function chatCall(key, every, ...)
    local now = os.time()
    if (chatFightState.calls[key] or 0) > now then
        return
    end

    chatFightState.calls[key] = now + every
    chatSend('ACT', ...)
end

-- Once a second from chatTick: the fight as it goes (FIGHT every 5 s), and the moments worth a line.
local function chatFight(player)
    local now = os.time()
    local engaged = player:isEngaged()
    local target = engaged and player:getTarget() or nil
    if engaged and not chatFightState.engaged then
        chatFightState.wonName = nil
        if target ~= nil then
            chatSend('ACT', 'pull', player:getName(), target:getName())
        end
    elseif not engaged and chatFightState.engaged then
        if chatFightState.wonName ~= nil then
            chatSend('ACT', 'won', player:getName(), chatFightState.wonName)
        end

        chatSend('FIGHT', '', -1, -1, -1, '')
        chatFightState.wonName = nil
    end

    chatFightState.engaged = engaged
    if not engaged then
        return
    end

    local mates = {}
    for _, member in pairs(player:getPartyWithTrusts()) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') > 0 and member:isAlive() and xi.squad.mine(player, member) then
            local name = member:getPacketName()
            local hp, mp = chatPercent(member, 'getHP', 'getMaxHP'), chatPercent(member, 'getMP', 'getMaxMP')
            mates[#mates + 1] = string.format('%s:%d:%d', name, hp, mp)
            if mp >= 0 and mp < 25 then
                chatCall('lowmp:' .. name, 180, 'lowmp', name, target and target:getName() or '')
            end

            if hp >= 0 and hp < 30 then
                chatCall('hurt:' .. name, 60, 'hurt', name, target and target:getName() or '')
            end
        end
    end

    local hp = chatPercent(player, 'getHP', 'getMaxHP')
    if hp >= 0 and hp < 35 then
        chatCall('hurt:' .. player:getName(), 45, 'hurt', player:getName(), target and target:getName() or '')
    end

    if now >= chatFightState.nextFight then
        chatFightState.nextFight = now + 5
        chatSend('FIGHT', target and target:getName() or '', target and chatPercent(target, 'getHP', 'getMaxHP') or -1,
            hp, chatPercent(player, 'getMP', 'getMaxMP'), table.concat(mates, ','))
    end
end

-- Every 30 s from chatTick: the bot players around you (bots.lua, when it is installed), and who joined or left
-- your party, so the mates know them and remember them.
local chatNextWorld = 0
local function chatWorld(player)
    local now = os.time()
    if now < chatNextWorld then
        return
    end

    chatNextWorld = now + 10
    local bots = xi.bots
    if bots == nil or bots.worldFor == nil then
        return
    end

    local ok, world = pcall(bots.worldFor, player)
    if not ok or type(world) ~= 'table' then
        return
    end

    local inParty = {}
    for _, b in ipairs(world.party or {}) do
        inParty[b.name] = true
        if chatBotsInParty[b.name] == nil then
            chatBotsInParty[b.name] = { fights = 0 }
            chatSend('BOTJOIN', b.name, b.job or '', b.level or 0, player:getZoneName())
        end
    end

    for name, info in pairs(chatBotsInParty) do
        if not inParty[name] then
            chatBotsInParty[name] = nil
            chatSend('BOTLEAVE', name, info.fights, player:getZoneName())
        end
    end

    if now >= (chatFightState.worldAt or 0) then
        chatFightState.worldAt = now + 30
        local function list(t)
            local out = {}
            for _, b in ipairs(t or {}) do
                out[#out + 1] = b.job and string.format('%s (%s %d)', b.name, b.job, b.level or 0) or b.name
            end

            return table.concat(out, ',')
        end

        chatSend('WORLD', list(world.near), list(world.friends), world.ls or '', list(world.party))
    end
end

-- a bot player said something in your party (bots.lua): the mates hear it
xi.squad.onBotSay = function(player, botName, text)
    if player == nil or xi.squad.visitor(player) or not chatEnabled(player) or not chatHasActive(player) then
        return
    end

    text = chatClean(text)
    if text ~= '' then
        chatSend('BOTSAY', botName, text)
    end
end

local function chatCountLines()
    if not CHAT_ACTIVE then
        return 0
    end

    local handle = io.open(CHAT_OUT, 'r')
    if handle == nil then
        return 0
    end

    local count = 0
    for _ in handle:lines() do
        count = count + 1
    end

    handle:close()
    return count
end

local chatOutCount = chatCountLines()

local function chatRead(player)
    if not CHAT_ACTIVE then
        return
    end

    local handle = io.open(CHAT_OUT, 'r')
    if handle == nil then
        return
    end

    local lines = {}
    for line in handle:lines() do
        lines[#lines + 1] = line
    end

    handle:close()

    -- The sidecar clears the file when it starts; start over if that happened.
    if chatOutCount > #lines then
        chatOutCount = 0
    end

    for index = chatOutCount + 1, #lines do
        local kind, mate, text = string.match(lines[index], '^(%u+)\t([^\t]*)\t(.*)$')
        if text ~= nil then
            -- Windows text-mode writers can leave a carriage return at the end. The client treats control
            -- characters literally, so strip them before the line goes into party chat.
            text = chatClean(text):gsub('^%s+', ''):gsub('%s+$', '')
        end
        if kind == 'SAY' and mate ~= '' and text ~= '' then
            xi.squad.aiSaidAt = os.time() -- (the pack's fight and idle lines stay quiet while the AI talks)
            player:printToPlayer(text, 4, mate)
            print(string.format('[squad] chat %s: %s', mate, text))
        elseif kind == 'NOTE' and text ~= '' then
            player:printToPlayer('[Squad] ' .. text)
        end
    end

    chatOutCount = #lines
end

local chatNextPoll = 0

local function chatTick(mob)
    if not CHAT_ACTIVE then
        return
    end

    local now = os.time()
    if now < chatNextPoll then
        return
    end

    -- co-op: a visitor's mates leave the chat bridge to the owner's (before the poll is counted as done)
    local coop = rawget(xi, 'coop')
    if type(coop) == 'table' and type(coop.isGuestMate) == 'function' and coop.isGuestMate(mob) then
        return
    end

    chatNextPoll = now + CHAT_POLL_SEC

    local master = mob:getMaster()
    if master == nil then
        master = GetPlayerByID(mob:getLocalVar('MASTER_ID'))
    end

    if master == nil or master:getObjType() ~= xi.objType.PC then
        return
    end

    chatPushContext(master)
    pcall(chatFight, master)
    pcall(chatWorld, master)
    chatRead(master)
end

-- Called by squad.cpp for every party-chat line (after auto-translate is decoded).
xi.squad.onPartyChat = function(player, text)
    if xi.squad.visitor(player) or not chatEnabled(player) or not chatHasActive(player) then
        return
    end

    text = chatClean(text)
    if text == '' then
        return
    end

    chatSend('CHAT', player:getName(), text)
end

local nationNames = { [0] = "San d'Oria", [1] = 'Bastok', [2] = 'Windurst' }

local function chatNewMate(name, race, job, level, nation)
    chatSend('NEWMATE', name, race or 1, job or 'WAR', level or 1, nation or "San d'Oria")
end

-- A mate made in the launcher's Squad tab is written straight to the database, so it never goes through
-- !squad new. Send the current roster when you list or call the squad; the sidecar generates a sheet for
-- anyone it has not seen, using the job and level the mate has now.
local function chatRoster(player, squad)
    for _, mate in ipairs(squad) do
        chatSend('ROSTER', mate.name, mate.race > 0 and mate.race or 1, jobNames[mate.mjob] or 'WAR',
            jobLevel(mate, mate.mjob), nationNames[mate.nation] or "San d'Oria")
    end
end

-- Auto-equip (SnkSyndicate's suggestion; the user's design, 2026-11-17): one squad-wide switch, !squad autoequip on.
-- On: each mate wears the best gear you have given the squad that its job and level can use (highest item level
-- first), picked again every time it is called (so after a level up or a job change too). Off: back to choosing by
-- hand, and the gear stays as it was. Choosing a piece by hand turns it off. A global (squad.lua is near Lua's
-- 200-local limit). Two-handed weapons get a grip or nothing in the sub slot, hand-to-hand nothing, one-handed a
-- shield (a ninja: a second weapon); arrows and bolts only with a bow or crossbow of the same kind.
-- (2026-11-18, Bob's idea) Lockstyle: how a mate LOOKS, apart from what it wears. Per mate (every job), the visible slots
-- only (main, sub, ranged, head, body, hands, legs, feet). Char vars SQUAD_LS_<mate id>_<slot> = item id (0 = shows the real
-- gear). Any piece given to the squad that fits the slot can be shown, whatever its level or job, like a player's lockstyle.
-- Globals: squad.lua is at Lua's local limit.
SQUAD_LS_SLOTS = { [0] = true, [1] = true, [2] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true }
function squadLockstyleGet(player, mateId)
    local out, any = {}, false
    for slot in pairs(SQUAD_LS_SLOTS) do
        local item = player:getCharVar(string.format('SQUAD_LS_%d_%d', mateId, slot))
        if item > 0 then
            out[slot], any = item, true
        end
    end
    return out, any
end
function squadLockstyleSet(player, mateId, slot, item)
    player:setCharVar(string.format('SQUAD_LS_%d_%d', mateId, slot), item or 0)
end
function squadLockstyleClear(player, mateId)
    for slot in pairs(SQUAD_LS_SLOTS) do
        squadLockstyleSet(player, mateId, slot, 0)
    end
end

SQUAD_TWO_HANDED = { [4] = true, [6] = true, [7] = true, [8] = true, [10] = true, [12] = true }

function squadAutoEquip(player, mate)
    local job, lvl = mate.mjob, levelsFor(mate)
    local cand = {}
    for itemId in pairs(GetSquadUnlocks(player:getID()) or {}) do
        local info = GetSquadItemInfo(itemId)
        if info and info.valid and info.level <= lvl and hasBit(info.jobs, job - 1) then
            cand[#cand + 1] = { id = itemId, info = info }
        end
    end

    if #cand == 0 then
        return 0
    end

    table.sort(cand, function(a, b)
        return a.info.level > b.info.level or (a.info.level == b.info.level and a.id < b.id)
    end)

    local used, pick = {}, {}
    local function best(slot, ok)
        for _, c in ipairs(cand) do
            if hasBit(c.info.slot, slot) and not used[c.id] and (ok == nil or ok(c.info)) then
                used[c.id] = true
                return c.id, c.info
            end
        end

        return nil
    end

    local mainId, mainInfo = best(0)
    if mainId then
        pick[0] = mainId
        local skill = mainInfo.skill or 0
        if SQUAD_TWO_HANDED[skill] then
            pick[1] = best(1, function(i) return (i.shield or 0) == 0 and (i.skill or 0) == 0 end) or 0 -- (a grip)
        elseif skill == 1 then
            pick[1] = 0 -- (hand-to-hand: both hands)
        elseif job == 13 and lvl >= 10 then
            pick[1] = best(1, function(i) return (i.skill or 0) > 1 and not SQUAD_TWO_HANDED[i.skill] and i.skill < 25 end)
                or best(1, function(i) return (i.shield or 0) > 0 end) or 0
        else
            pick[1] = best(1, function(i) return (i.shield or 0) > 0 end) or 0
        end
    end

    local rangeId, rangeInfo = best(2)
    if rangeId then
        pick[2] = rangeId
        local rs = rangeInfo.skill or 0
        if rs == 25 or rs == 26 then
            pick[3] = best(3, function(i) return (i.skill or 0) == rs end) or 0
        end
    end

    for _, slot in ipairs({ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }) do
        pick[slot] = best(slot)
    end

    mate.equip[job] = mate.equip[job] or {}
    local worn, changed = mate.equip[job], 0
    for slot = 0, 15 do
        local want = pick[slot]
        if want ~= nil and want ~= (worn[slot] or 0) then
            SetSquadEquip(mate.id, job, slot, want)
            worn[slot] = want ~= 0 and want or nil
            changed = changed + 1
        end
    end

    return changed
end

-- (2026-11-19, from Jon Tanta's Squad Update) once a second per mate: its range from the foe (squad_space.lua) and the
-- skillchain wait (squad_chain.lua). A module that is missing is skipped; an error is printed at most every 20 seconds.
SQUAD_TEAM_ERR = SQUAD_TEAM_ERR or 0
function squadTeamTick(mob)
    local now = os.time()
    if mob:getLocalVar('SQUAD_TEAM_T') == now or not mob:isAlive() then
        return
    end

    mob:setLocalVar('SQUAD_TEAM_T', now)
    local boss = mob:getMaster()
    if boss == nil or boss:getObjType() ~= xi.objType.PC then
        return
    end

    local foe = nil
    if mob:isEngaged() then
        foe = mob:getTarget()
    end

    if type(foe) ~= 'userdata' and type(foe) ~= 'table' then
        foe = nil
    end

    local fighting = foe ~= nil and foe:isAlive() and foe:getObjType() == xi.objType.MOB
    for _, mod in ipairs({ SQUAD_SPACE, SQUAD_CHAIN }) do
        if type(mod) == 'table' and mod.tick ~= nil then
            local ok, err = pcall(mod.tick, mob, boss, foe, fighting, now, mob:getMainLvl(), mob:getMainJob())
            if not ok and now - SQUAD_TEAM_ERR >= 20 then
                SQUAD_TEAM_ERR = now
                print('[squad] team tick error: ' .. tostring(err))
            end
        end
    end
end

local function callMate(player, mate)
    if isSummoned(player, mate.id) then
        say(player, string.format('%s is already with you.', mate.name))
        return
    end

    if #player:getPartyWithTrusts() >= MAX_ACTIVE + 1 then
        say(player, 'Your party is full.')
        return
    end

    local cap = syncCap(player)
    local main, sub, subLevel = levelsFor(mate, cap, player)
    local synced = main < jobLevel(mate, mate.mjob)

    ensureStarterGear(player, mate)
    if player:getCharVar('SQUAD_AUTOEQUIP') == 1 then
        pcall(squadAutoEquip, player, mate)
    end

    -- (2026-11-19, Meli, lilibun: synced mates came out naked and unarmed) under a Level Sync a piece above the synced
    -- level used to be left off entirely. Now: weapons and ammo (slots 0-3) stay on, so the mate can fight and use
    -- weapon skills; armour above the level gives no stats but still shows (as a look), unless a lockstyle is set there.
    local outfit = {}
    local looks = squadLockstyleGet(player, mate.id)
    for slot, itemId in pairs(mate.equip[mate.mjob]) do
        if slot ~= STARTER_MARK then
            if not synced or itemLevel(itemId) <= main or (type(slot) == 'number' and slot <= 3) then
                outfit[slot] = itemId
            elseif SQUAD_LS_SLOTS[slot] and looks[slot] == nil then
                looks[slot] = itemId
            end
        end
    end

    -- (Gambits weapon skill settings) per mate and main job; without a Gambits setting the !squad ws vars, as before
    local okWs, wsSettings = pcall(require, 'modules/custom/lua/squad_ws')
    wsSettings = okWs and type(wsSettings) == 'table' and wsSettings or nil
    local trust = SpawnSquadMate(player,
    {
        id       = mate.id,
        mjob     = mate.mjob,
        sjob     = sub,
        mlevel   = main,
        slevel   = subLevel,
        template = mate.template,
        race     = mate.race > 0 and mate.race or 1,
        face     = mate.face,
        size     = player:getCharVar('SQUAD_SIZE_' .. mate.id), -- 0 = not chosen, 1-3 = small / medium / large
        ws       = wsSettings and wsSettings.spawnWs(player, mate)  -- 0 = every weapon skill it can use, else only this one
                   or player:getCharVar('SQUAD_WS_' .. mate.id),
        scrolls  = squadScrollsOn(),                              -- spells 18+ only when the squad learned them
        blueSet    = squadBlueSetGet(player, mate.id),            -- (a Blue Mage) your chosen set; empty = automatic
        bluePrefer = squadBluePrefer(),
        equip    = outfit,
        lockstyle = looks,  -- (the look shown over the real gear, if any)
    })

    if trust == nil then
        say(player, string.format('Could not call %s (see the map server log).', mate.name))
        return
    end

    trust:renameEntity(mate.name, true)
    trust:setLocalVar('SQUAD_ID', mate.id) -- make sure the tag is there after spawning
    trust:setLocalVar('SQUAD_WSTP', player:getCharVar('SQUAD_WSTP_' .. mate.id)) -- its own weapon skill timing (!squad ws)
    if wsSettings then
        -- Gambits weapon skill settings for this job (Custom / Squad default), else the !squad ws timing just set
        local okApply, applyErr = pcall(wsSettings.onSpawn, player, trust, mate)
        if not okApply then
            print('[squad] weapon skill settings: ' .. tostring(applyErr))
        end
    end
    -- The party list was sent while the mate still had its template's name (the last one called kept showing "Shantotto"):
    -- send the party list again now, and once more a moment later, so it shows the new name.
    player:reloadParty()
    player:timer(1500, function(entity)
        entity:reloadParty()
    end)
    trust:setLocalVar('SQUAD_CAP', cap or 0)  -- the level it was synced to, to notice when yours changes
    trust:setLocalVar('SQUAD_OWN', jobLevel(mate, mate.mjob))

    if dialogue.speakOnSpawn then
        local okPack, saidPack = false, false
        if type(xi.squad.pack) == 'table' then
            okPack, saidPack = pcall(xi.squad.pack.onCall, player, trust, mate.name, mate.race, mate.mjob, jobLevel(mate, mate.mjob))
        end

        if not (okPack and saidPack) then
            speak(player, mate.name, 'spawn', { job = jobTitles[mate.mjob] or '' })
        end
    end

    campApply(player, trust)
    -- (2026-11-22, levi) the mate uses its gear's enchantments (Vision Ring and the like): squad_enchant.lua
    local okEnchant, enchantErr = pcall(function() require('modules/custom/lua/squad_enchant').onSpawn(trust, outfit) end)
    if not okEnchant then
        print('[squad] enchantments: ' .. tostring(enchantErr))
    end

    trust:addListener('WEAPONSKILL_USE', 'SQUAD_SC', function(mobArg, target, skill)
        pcall(skillchainCall, mobArg, target, skill)
    end)

    trust:addListener('COMBAT_TICK', 'SQUAD_FOOD', function(mobArg)
        campTick(mobArg)
        pcall(skillchainTick, mobArg)
        eatIfNeeded(mobArg)
        petTick(mobArg)
        -- Also poll the chat bridge here: a trust in combat still gets COMBAT_TICK,
        -- and this makes sure replies are not held back if the idle tick is late.
        chatTick(mobArg)
    end)

    -- Every AI tick, fighting or not (COMBAT_TICK only fires while you fight): resting with you, and following your level
    trust:addListener('TICK', 'SQUAD_IDLE', function(mobArg)
        local owner = mobArg:getMaster()
        if owner ~= nil and mobArg:isAlive() then -- (who is out, for the call back after zoning)
            local seen = zoneOut[owner:getID()] or {}
            zoneOut[owner:getID()] = seen
            seen[mobArg:getLocalVar('SQUAD_ID')] = os.time()
        end

        pcall(squadCutsceneTick, mobArg, owner)
        campTick(mobArg)
        if restTick ~= nil then
            restTick(mobArg)
        end
        if resyncSquad ~= nil then
            resyncSquad(mobArg)
        end
        -- (Jon Tanta, 2026-11-21) SQUAD_IDLE (trust_controller.cpp): a mate the player has stopped gets no built-in Thief positioning
        if squadThiefTick ~= nil and mobArg:getLocalVar('SQUAD_IDLE') == 0 and mobArg:isAlive() and mobArg:getMaster() ~= nil then
            pcall(squadThiefTick, mobArg)
        end
        squadTeamTick(mobArg) -- (spacing and the skillchain wait, once a second)
        chatTick(mobArg)
        if type(xi.squad.pack) == 'table' then
            pcall(xi.squad.pack.tick, mobArg) -- (pack lines: fights and quiet moments while the AI is quiet)
        end
    end)

    trust:addListener('WEAPONSKILL_USE', 'SQUAD_WS_SHOUT', function(mobArg, target, skill, tp, action)
        -- 2026-11-19: every mate weapon skill goes in the log with the chain state of the foe, so the chains can be read back
        pcall(function()
            local fx = target and target:getStatusEffect(xi.effect.SKILLCHAIN)
            print(string.format('[ws] %s used %s at %d TP; chain on foe: %s', mobArg:getPacketName(), wsName(skill and skill.getID and skill:getID() or 0),
                tp or 0, fx and ('tier ' .. tostring(fx:getTier())) or 'none'))
        end)
        if (dialogue.wsShoutChance or 0) > 0 and math.random(100) <= dialogue.wsShoutChance then
            speakFromMob(mobArg, 'weaponskill')
        end
    end)

    return trust
end

-- (2026-11-21, lilibun: mates standing in the middle of cutscenes) while you are in a cutscene or talking to an NPC for
-- more than a moment, your squad mates are hidden; they show again the moment it ends. (The short wait keeps them from
-- blinking out for a one-line chat.) A global: squad.lua is near Lua's 200-local limit.
SQUAD_CS_HIDE_AFTER = 2 -- seconds in an event before the mates are hidden
function squadCutsceneTick(mob, owner)
    local hidden = mob:getLocalVar('SQUAD_CS_HIDDEN') == 1
    local inEvent = owner ~= nil and owner:isInEvent() and mob:isAlive()
    if inEvent then
        local since = mob:getLocalVar('SQUAD_CS_SINCE')
        if since == 0 then
            mob:setLocalVar('SQUAD_CS_SINCE', os.time())
        elseif not hidden and os.time() - since >= SQUAD_CS_HIDE_AFTER and mob:getStatus() == xi.status.NORMAL then
            mob:setLocalVar('SQUAD_CS_HIDDEN', 1)
            mob:setStatus(xi.status.INVISIBLE)
        end
    else
        mob:setLocalVar('SQUAD_CS_SINCE', 0)
        if hidden then
            mob:setLocalVar('SQUAD_CS_HIDDEN', 0)
            if mob:getStatus() == xi.status.INVISIBLE then
                mob:setStatus(xi.status.NORMAL)
            end
        end
    end
end

-- Summon cooldown: after a squad mate is called with !squad call, that mate cannot be called again for
-- the call timer (each mate has their own timer, kept across logouts): the launcher's "Squad call timer" (squad_config.lua,
-- minutes, 0-30, default 5). Following your level, a mate's level up, zoning and the Squad menu's "Apply now"
-- (!squad reapply) re-call mates without the cooldown.
local function callCooldownSec()
    local ok, c = pcall(function()
        package.loaded['modules/custom/lua/squad_config'] = nil
        return require('modules/custom/lua/squad_config')
    end)
    local minutes = ok and type(c) == 'table' and tonumber(c.call_cooldown_min) or 5
    return math.max(0, math.min(30, minutes)) * 60
end

-- (2026-11-17) the launcher's "Squad mates learn spells from scrolls (18+)" switch (squad_config.lua spell_scrolls,
-- off by default). On: spells a mate's jobs learn at level 18 or above need their scroll given to the squad once
-- (trade it to a mate or !squad give); blue magic from 18 is learned from monsters instead (a squad Blue Mage out with
-- you may learn a spell when the party defeats a monster that knows it). Below 18 everything stays automatic.
-- Learned spells are squad_unlock rows 60000 + spell id. (Globals: squad.lua is near Lua's 200-local limit.)
SQUAD_SPELL_KEY = 60000
SQUAD_BLUE_LEARN_CHANCE = 15 -- percent per spell, per defeated monster

-- (2026-11-17) A squad Blue Mage's set blue magic (trustutils.cpp sets it with a player's slots and points and gives
-- its traits). Automatic until you pick spells yourself (!squad blu, or the Squad window): your set is kept in char
-- vars SQUAD_BLUN_<mate id> (how many, 0 = automatic) and SQUAD_BLU_<mate id>_<n> (the spell ids).
SQUAD_BLUE_PREFER = { 'MAGIC_FRUIT', 'WILD_CARROT', 'HEALING_BREEZE', 'POLLEN', 'COCOON', 'METALLIC_BODY', 'JET_STREAM',
    'UPPERCUT', 'SCREWDRIVER', 'BLUDGEON', 'HEAD_BUTT', 'BATTLE_DANCE', 'POWER_ATTACK', 'SPROUT_SMACK', 'WILD_OATS' }

function squadBluePrefer()
    local out = {}
    local spells = xi.magic and type(xi.magic.spell) == 'table' and xi.magic.spell or {}
    for _, name in ipairs(SQUAD_BLUE_PREFER) do
        local id = spells[name]
        if id then
            out[#out + 1] = id
        end
    end

    return out
end

function squadBlueSetGet(player, mateId)
    local out = {}
    for n = 1, math.min(20, player:getCharVar('SQUAD_BLUN_' .. mateId)) do
        local id = player:getCharVar('SQUAD_BLU_' .. mateId .. '_' .. n)
        if id > 0 then
            out[#out + 1] = id
        end
    end

    return out
end

function squadBlueSetPut(player, mateId, list)
    local old = player:getCharVar('SQUAD_BLUN_' .. mateId)
    for n = 1, 20 do
        local id = list and list[n] or 0
        if id > 0 or n <= old then
            player:setCharVar('SQUAD_BLU_' .. mateId .. '_' .. n, id)
        end
    end

    player:setCharVar('SQUAD_BLUN_' .. mateId, list and math.min(#list, 20) or 0)
end

-- the mate's blue magic now: { slots, points, used, auto, known = SquadKnownBlue list, set = { ids } } (nil if not out)
function squadBlueState(player, mate)
    if not SquadKnownBlue then
        return nil
    end

    for _, member in pairs(player:getPartyWithTrusts()) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') == mate.id then
            local st = {
                slots = member:getLocalVar('SQUAD_BLU_SLOTS'), points = member:getLocalVar('SQUAD_BLU_POINTS'),
                used = member:getLocalVar('SQUAD_BLU_USED'), auto = member:getLocalVar('SQUAD_BLU_AUTO') == 1,
                known = SquadKnownBlue(member, squadScrollsOn()) or {}, set = {},
            }
            for n = 1, member:getLocalVar('SQUAD_BLU_COUNT') do
                st.set[#st.set + 1] = member:getLocalVar('SQUAD_BLU_' .. n)
            end

            return st
        end
    end

    return nil
end

function squadScrollsOn()
    local ok, c = pcall(function()
        package.loaded['modules/custom/lua/squad_config'] = nil
        return require('modules/custom/lua/squad_config')
    end)
    return ok and type(c) == 'table' and c.spell_scrolls == true
end

-- a spell scroll given to the squad: true when it was dealt with here (learned, or why not)
function squadLearnScroll(owner, tell, itemId, takeOne)
    local sc = SquadScrollSpell and SquadScrollSpell(itemId)
    if sc == nil then
        return false
    end

    local name = prettySpellName and prettySpellName(sc.name) or sc.name
    if not squadScrollsOn() then
        tell(string.format('Your squad learns %s by itself (spells come automatically on this world).', name))
        return true
    elseif sc.level < 18 then
        tell(string.format('%s comes by itself (spells below level 18 are automatic).', name))
        return true
    elseif GetSquadUnlocks(owner:getID())[SQUAD_SPELL_KEY + sc.spell] then
        tell(string.format('Your squad already knows %s.', name))
        return true
    elseif not takeOne() then
        tell('Could not take the scroll.')
        return true
    end

    UnlockSquadItem(owner:getID(), SQUAD_SPELL_KEY + sc.spell)
    tell(string.format('Your squad learns %s. Every mate whose job and level fit can cast it from their next call.', name))
    return true
end

local function cooldownLeft(player, mate)
    local calledAt = player:getCharVar('SQUAD_CALLED_' .. mate.id)
    if calledAt <= 0 then
        return 0
    end

    return math.max(0, calledAt + callCooldownSec() - os.time())
end

local function callWithCooldown(player, mate)
    if not isSummoned(player, mate.id) then
        local left = cooldownLeft(player, mate)
        if left > 0 then
            say(player, string.format('%s is not ready to come out yet: %d min %02d s left.', mate.name, math.floor(left / 60), left % 60))
            return nil
        end
    end

    local trust = callMate(player, mate)
    if trust ~= nil then
        player:setCharVar('SQUAD_CALLED_' .. mate.id, os.time())
    end

    return trust
end

-----------------------------------
-- Resting with you (v1.8): while you rest (/heal), mates who are not fighting sit down too and recover HP and MP:
-- the first time after REST_FIRST_SEC, then every REST_EVERY_SEC. They stand up when you do.
-----------------------------------
local REST_FIRST_SEC = 10   -- the game makes you wait 20 seconds; mates are a little quicker
local REST_EVERY_SEC = 10
local REST_HP_PERCENT = 10  -- of their max HP per tick
local REST_MP_PERCENT = 10  -- of their max MP per tick

restTick = function(mob)
    local master = mob:getMaster()
    if master == nil or master:getObjType() ~= xi.objType.PC or not mob:isAlive() then
        return
    end

    local sitting = mob:getAnimation() == xi.animation.HEALING
    local resting = master:getAnimation() == xi.animation.HEALING and not mob:isEngaged() and not master:isEngaged()

    -- At camp (unless !squad camp rest off): rest between fights while the pull is out, until full again
    local c = camps[master:getID()]
    if not resting and c and c.zone == master:getZoneID() and master:getCharVar('SQUAD_CAMP_NOREST') == 0 and not mob:isEngaged() and
        mob:getLocalVar('SQUAD_PULL_PHASE') == 0
    then
        local p = mob:getPos()
        local hurt = mob:getHP() < mob:getMaxHP() or (mob:getMaxMP() > 0 and mob:getMP() < mob:getMaxMP())
        resting = hurt and math.sqrt((p.x - c.x) ^ 2 + (p.z - c.z) ^ 2) <= 8
    end

    if not resting then
        if sitting then
            mob:setAnimation(xi.animation.NONE)
        end

        return
    end

    local now = os.time()
    if not sitting then
        mob:setAnimation(xi.animation.HEALING)
        mob:setLocalVar('SQUAD_REST_AT', now + REST_FIRST_SEC)
        return
    end

    if now < mob:getLocalVar('SQUAD_REST_AT') then
        return
    end

    mob:setLocalVar('SQUAD_REST_AT', now + REST_EVERY_SEC)
    -- 10% of the max, but never less than a resting player of that level gets (a low-level mate has little MP,
    -- and 10% of 20 MP was 2 a tick)
    local lvl = mob:getMainLvl()
    if mob:getHP() < mob:getMaxHP() then
        mob:addHP(math.max(10 + lvl, math.floor(mob:getMaxHP() * REST_HP_PERCENT / 100)))
    end

    if mob:getMaxMP() > 0 and mob:getMP() < mob:getMaxMP() then
        mob:addMP(math.max(12 + math.floor(lvl / 2), math.floor(mob:getMaxMP() * REST_MP_PERCENT / 100)))
    end
end

-- Called from each mate's tick: when your level no longer matches the level the squad came out at, or a mate who is out
-- levelled up (SQUAD_RELEVEL = their new level, set by grantSquadExp), call everyone again once the fight is over
resyncSquad = function(mob)
    local master = mob:getMaster()
    if master == nil or master:getObjType() ~= xi.objType.PC then
        return
    end

    local cap = master:getMainLvl()
    local relevel = mob:getLocalVar('SQUAD_RELEVEL')
    if relevel > 0 and (SYNC_TO_PLAYER and math.min(relevel, cap) or relevel) == mob:getMainLvl() then
        mob:setLocalVar('SQUAD_RELEVEL', 0) -- (synced below their new level: nothing would change)
        relevel = 0
    end

    if relevel == 0 then
        if not SYNC_TO_PLAYER or mob:getLocalVar('SQUAD_CAP') == cap then
            return
        end

        -- your level changed, but would this mate's? (a mate below both levels stays as it is)
        local own = mob:getLocalVar('SQUAD_OWN')
        if own > 0 and math.min(own, cap) == mob:getMainLvl() then
            mob:setLocalVar('SQUAD_CAP', cap)
            return
        end
    end

    local now = os.time()
    if now - master:getLocalVar('SQUAD_RESYNC_AT') < RESYNC_EVERY_SEC or master:isEngaged() then
        return
    end

    master:setLocalVar('SQUAD_RESYNC_AT', now)

    local out = {}
    for _, member in pairs(master:getPartyWithTrusts()) do
        if member:getObjType() == xi.objType.TRUST then
            if member:isEngaged() then
                return -- someone is still fighting: try again in a moment
            end

            local squadId = member:getLocalVar('SQUAD_ID')
            if squadId > 0 then
                out[squadId] = true
            end
        end
    end

    local squad = GetSquad(master:getID())
    local again = {}
    for _, mate in ipairs(squad) do
        if out[mate.id] then
            again[#again + 1] = mate
        end
    end

    if #again == 0 then
        return
    end

    master:clearTrusts()
    if relevel > 0 then
        say(master, string.format('%s comes back at level %d.', mob:getPacketName(), relevel))
    else
        say(master, string.format('Your squad matches your level (%d).', cap))
    end
    for index, mate in ipairs(again) do
        master:timer(RECALL_WAIT_MS + (index - 1) * CALL_GAP_MS, function(entity)
            callMate(entity, mate)
        end)
    end
end

-- Trading gear to a squad mate: every new piece of equipment is kept by the squad for good and every mate can
-- wear it (the same collection !squad give fills). Called from squad.cpp when you trade with one of your mates.
xi = xi or {}
xi.squad = xi.squad or {}

local function prettyItem(name)
    return (string.gsub(string.gsub(name, '_', ' '), '(%a)([%w]*)', function(first, rest)
        return string.upper(first) .. rest
    end))
end

-- Spell commands typed in party chat (see squad.cpp). result: cast, unknown, notready, notarget or busy
xi.squad.onSpellCommand = function(player, trust, spellName, result)
    local events = { cast = 'spellcast', unknown = 'spellunknown', notready = 'spellnotready', notarget = 'spellnotarget', busy = 'spellbusy' }
    local event = events[result]
    if event ~= nil then
        speak(player, trust:getPacketName(), event, { spell = prettySpellName(spellName) })
    end
end

-- Job abilities typed in party chat (see squad.cpp). result: cast, unknown, notready, notarget or busy.
-- Busy (mid-swing or mid-cast) is tried again every second for a few seconds, so the ability still goes off.
local ABILITY_RETRIES = 6

xi.squad.onAbilityCommand = function(player, trust, abilityName, result, abilityId)
    local who  = trust:getPacketName()
    local vars = { ability = prettySpellName(abilityName), job = xi.job and tostring(trust:getMainJob()) or '' }
    for jobName, id in pairs(xi.job or {}) do
        if id == trust:getMainJob() then
            vars.job = jobName
        end
    end

    if result ~= 'busy' then
        speak(player, who, 'ability' .. result, vars)
        return
    end

    local tries = 0
    local function again(mate)
        tries = tries + 1
        local now = SquadUseAbility(player, mate, abilityId)
        if now == 'busy' and tries < ABILITY_RETRIES then
            mate:timer(1000, again)
        else
            speak(player, who, 'ability' .. now, vars)
        end
    end

    trust:timer(1000, again)
end

-- One-of-a-kind gear (squad_copy_items.lua: quest, mission and artifact pieces you can only get once): the squad gets
-- its own copy and you keep yours. Anything you can buy or get again is taken as before.
squadCopyItems = nil -- (globals: 200-local limit)
isRareItem = function(itemId)
    if squadCopyItems == nil then
        local ok, list = pcall(require, 'modules/custom/lua/squad_copy_items')
        squadCopyItems = (ok and type(list) == 'table') and list or {}
    end

    return squadCopyItems[itemId] ~= nil
end

-- (2026-11-20) the launcher's "Squad gear: you keep the item" switch (squad_config.lua keep_gear, off by default):
-- giving gear to the squad unlocks it for every mate and you keep the piece, the way one-of-a-kind gear always works.
-- (2026-11-21, Yache) the launcher's "Squad gets all gear" switch (squad_config.lua all_gear, off by default): every
-- piece of gear counts as given to the squad, so mates can wear anything their job and level allow without a trade.
function squadAllGear()
    local ok, c = pcall(function()
        package.loaded['modules/custom/lua/squad_config'] = nil
        return require('modules/custom/lua/squad_config')
    end)
    return ok and type(c) == 'table' and c.all_gear == true
end

function squadKeepGear()
    local ok, c = pcall(function()
        package.loaded['modules/custom/lua/squad_config'] = nil
        return require('modules/custom/lua/squad_config')
    end)
    return ok and type(c) == 'table' and c.keep_gear == true
end

xi.squad.onTrade = function(player, trust, items)
    local who = trust:getPacketName()
    -- the squad belongs to the trust's master; the items come from whoever traded (maybe the dualbox character)
    local owner = trust:getMaster()
    if owner == nil or owner:getObjType() ~= xi.objType.PC then
        owner = player
    end

    if player:checkDistance(trust) > 6 then
        speak(player, who, 'closer')
        return
    end

    local unlocked = GetSquadUnlocks(owner:getID())
    local took = 0

    for _, offer in ipairs(items) do
        local info = GetSquadItemInfo(offer.itemId)

        if squadLearnScroll(owner, function(text) player:printToPlayer(text, xi.msg.channel.SYSTEM_3) end, offer.itemId,
            function() return player:delItemAt(offer.itemId, 1, xi.inv.INVENTORY, offer.slot) end) then
            -- (a spell scroll: learned or told why not)
        elseif not info.valid then
            speak(player, who, 'cannotuse')
        elseif unlocked[offer.itemId] then
            speak(player, who, 'alreadyhave', { item = prettyItem(info.name) })
        elseif isRareItem(offer.itemId) then
            UnlockSquadItem(owner:getID(), offer.itemId) -- (you keep it: Rare)
            unlocked[offer.itemId] = true
            took = took + 1
            speak(player, who, 'thanks', { item = prettyItem(info.name) })
            player:printToPlayer(string.format('%s is one of a kind: the squad gets its own and you keep yours.', prettyItem(info.name)))
        elseif squadKeepGear() then
            UnlockSquadItem(owner:getID(), offer.itemId) -- (you keep it: the launcher switch)
            unlocked[offer.itemId] = true
            took = took + 1
            speak(player, who, 'thanks', { item = prettyItem(info.name) })
            player:printToPlayer(string.format('The squad gets its own %s and you keep yours.', prettyItem(info.name)))
        elseif player:delItemAt(offer.itemId, 1, xi.inv.INVENTORY, offer.slot) then
            UnlockSquadItem(owner:getID(), offer.itemId)
            unlocked[offer.itemId] = true
            took = took + 1
            speak(player, who, 'thanks', { item = prettyItem(info.name) })
        else
            speak(player, who, 'failed')
        end
    end

    if took > 0 then
        owner:printToPlayer('Use the Squad tab in the launcher, or !squad equip, to dress your squad.')
        if owner:getID() ~= player:getID() then
            player:printToPlayer(string.format('Added to %s\'s squad collection.', owner:getName()))
        end
    end
end

local function save(player, mate)
    SaveSquadMate(player:getID(), mate.slot, mate)
    say(player, 'Saved: ' .. describe(mate, player) .. '  (dismiss and call them again to apply)')
end

commandObj.onTrigger = function(player, action, arg1, arg2, arg3, arg4)
    local charId = player:getID()
    if action ~= 'panel' and action ~= 'sheet' then
        print(string.format('[squad] %s: !squad %s %s %s', player:getName(), tostring(action or ''), tostring(arg1 or ''), tostring(arg2 or '')))
    end
    local squad = GetSquad(charId)
    action = action and string.lower(action) or nil

    if action == nil or action == 'list' or action == 'call' then
        chatRoster(player, squad)
    end

    if action == nil or action == 'list' then
        if #squad == 0 then
            say(player, 'You have no squad mates yet. Try: !squad new Bob WAR')
            return
        end

        for _, mate in ipairs(squad) do
            say(player, describe(mate, player))
        end

        return
    end

    -- (Gambits v2, milestone 1) !squad ruleset [slot] [number|off]: a Rule Set per mate and main job (squad_rulesets.lua)
    if action == 'ruleset' or action == 'rulesets' then
        local okRs, rulesets = pcall(require, 'modules/custom/lua/squad_rulesets')
        if okRs and type(rulesets) == 'table' then
            rulesets.command(player, squad, arg1, arg2, { say = say, findMate = findMate, jobNames = jobNames })
        else
            say(player, 'Rule Sets are not available: ' .. tostring(rulesets))
        end

        return
    end

    -- (job expansion) !squad partyrole [slot|me] [tank|melee|mage|ranged|auto]: who the Rule Sets' Tank/Melee/Mage/Ranged
    -- targets (and a squad Bard's role songs) mean
    if action == 'partyrole' then
        local okJ, J = pcall(require, 'modules/custom/lua/squad_jobs')
        if okJ and type(J) == 'table' then
            J.partyRoleCommand(player, squad, arg1, arg2, { say = say, findMate = findMate })
        else
            say(player, 'Party roles are not available: ' .. tostring(J))
        end

        return
    end

    -- what each mate out with you has eaten, and how long it lasts
    if action == 'food' then
        if not food.enabled then
            say(player, 'Squad food is switched off (squad_food.lua).')
            return
        end

        local any = false
        for _, trust in ipairs(squadTrusts(player)) do
            any = true
            local mealId, left = trust:getLocalVar('SQUAD_FOOD_ID'), trust:getLocalVar('SQUAD_FOOD_UNTIL') - GetSystemTime()
            local name
            for _, meal in pairs(food.foods) do
                if meal.id == mealId then
                    name = meal.name
                end
            end

            if mealId ~= 0 and name and left > 0 then
                say(player, string.format('%s: %s, %d min left', trust:getPacketName(), name, math.floor(left / 60)))
            elseif trust:getMainLvl() < (food.minLevel or 10) then
                say(player, string.format('%s: no food yet (mates eat from level %d)', trust:getPacketName(), food.minLevel or 10))
            else
                local meal = chooseFood(trust:getMainJob(), trust:getMainLvl())
                say(player, string.format('%s: nothing right now, eats %s when the next fight starts', trust:getPacketName(), meal and meal.name or '(no food for this job)'))
            end
        end

        if not any then
            say(player, 'None of your squad mates are out.')
        end

        return
    end

    if action == 'ai' then
        if #squad == 0 then
            say(player, 'You have no squad mates yet. Try: !squad new Bob WAR')
            return
        end

        for _, mate in ipairs(squad) do
            local role, mode = decodeBehavior(player:getCharVar('SQUAD_AI_' .. mate.id))
            say(player, string.format('%d: %s - role %s, mode %s', mate.slot, mate.name, role, mode))
            say(player, string.format('     %s', switchSummary(switchesOf(player, mate.id))))
        end

        say(player, 'Change with: !squad role <slot> <auto|tank|damage|healer|support>   |   !squad mode <slot> <balanced|aggressive|conserve>')
        say(player, 'Switches: !squad sw <slot> <melee|ranged|ja|magic|all> <on|off>')
        return
    end

    if action == 'chat' then
        local mode = arg1 and string.lower(arg1) or nil
        if mode == 'off' then
            player:setCharVar('SQUAD_CHAT_OFF', 1)
            chatSend('CHAT_STATE', 0)
            say(player, 'Squad chat off. Your mates will still fight; they just will not talk in party chat.')
        elseif mode == 'on' then
            player:setCharVar('SQUAD_CHAT_OFF', 0)
            chatSend('CHAT_STATE', 1)
            say(player, 'Squad chat on. Talk in party chat and they will answer.')
        elseif mode == 'test' then
            local handle = io.open(CHAT_OUT, 'r')
            local count, last = 0, nil
            if handle ~= nil then
                for line in handle:lines() do
                    count = count + 1
                    last = line
                end
                handle:close()
            end
            say(player, string.format('Chat is %s. The sidecar has written %d line(s)%s.', chatEnabled(player) and 'on' or 'off', count,
                last and ('; last: ' .. last) or ''))
            local tester = (chatActiveNames(player):match('^([^,]+)')) or 'Squad'   -- the first mate who is out
            say(player, 'Here is a direct test; it should appear in party chat as ' .. tester .. '.')
            player:printToPlayer('This is a test line from your squad chat.', 4, tester)
        else
            say(player, 'Squad chat is ' .. (chatEnabled(player) and 'on' or 'off') .. '. Use !squad chat on or !squad chat off.')
        end

        return
    end

    if action == 'lore' then
        if #squad == 0 then
            say(player, 'You have no squad mates yet. Try: !squad new Bob WAR')
            return
        end

        local mate = arg1 ~= nil and findMate(squad, tonumber(arg1) or 0) or nil
        if mate == nil then
            say(player, '!squad lore <slot> - write (or rewrite) that mate\'s backstory.')
            for _, member in ipairs(squad) do
                say(player, string.format('  [%d] %s', member.slot, member.name))
            end

            return
        end

        chatSend('LORE', mate.name)
        say(player, string.format('Writing %s\'s backstory. This takes a moment; you will get a note when it is ready.', mate.name))
        return
    end

    if action == 'panel' then
        -- For the in-game Squad panel addon, which reads these lines and hides them from the chat log:
        --   squadpanel:<slot>|<name>|<main job>|<main level>|<sub job or ->|<sub level>|<role>|<mode>|<1 if the mate is out now>|<switch mask>
        for _, mate in ipairs(squad) do
            local main, sub, subLevel = levelsFor(mate, nil, player)
            local role, mode = decodeBehavior(player:getCharVar('SQUAD_AI_' .. mate.id))
            say(player, string.format('squadpanel:%d|%s|%s|%d|%s|%d|%s|%s|%d|%d', mate.slot, mate.name, jobNames[mate.mjob] or '???', main,
                sub ~= 0 and jobNames[sub] or '-', subLevel, role, mode, isSummoned(player, mate.id) and 1 or 0,
                switchesOf(player, mate.id)))
        end

        -- the menu's Camp row (servermenu 1.6): camp|<on>|<puller slot, 0 = you>|<paused>|<pulls>
        local c = camps[charId]
        local pullerSlot = 0
        if c and c.puller ~= 0 then
            for _, mate in ipairs(squad) do
                if mate.id == c.puller then
                    pullerSlot = mate.slot
                end
            end
        end

        say(player, string.format('squadpanel:camp|%d|%d|%d|%d', c and 1 or 0, pullerSlot, c and c.paused and 1 or 0, c and c.pulls or 0))

        -- (servermenu 1.17) the bot players in your party, for the Puller list: campbots|<names, comma list or ->|<pulling bot or ->
        if BotIsBot then
            local botNames, pullerName = {}, '-'
            for _, member in pairs(player:getParty() or {}) do
                if BotIsBot(member:getID()) and member:getZoneID() == player:getZoneID() then
                    botNames[#botNames + 1] = member:getName()
                    if c and c.pullerBot == member:getID() then
                        pullerName = member:getName()
                    end
                end
            end

            say(player, string.format('squadpanel:campbots|%s|%s', #botNames > 0 and table.concat(botNames, ',') or '-', pullerName))
        end

        -- (servermenu 1.10) engage timing, and per mate: opt|<slot>|<size 0-3>|<ws TP, 0 = chain>|<chosen WS or ->|<range 0-3>|<usable WS, comma list or ->
        say(player, string.format('squadpanel:engage|%d', player:getCharVar('TrustEngageType') == 1 and 1 or 0))
        say(player, string.format('squadpanel:auto|%d', player:getCharVar('SQUAD_AUTOEQUIP') == 1 and 1 or 0))
        -- (servermenu 1.11) adv|<follow 0 normal, 1 close, 2 far>|<camp rest 1 on>|<call order, slots, or ->  and  delay|<slot>|<seconds>
        local orderCode = player:getCharVar('SQUAD_ORDER')
        say(player, string.format('squadpanel:adv|%d|%d|%s', player:getCharVar('SQUAD_FOLLOW'), player:getCharVar('SQUAD_CAMP_NOREST') == 1 and 0 or 1,
            orderCode > 0 and tostring(orderCode) or '-'))
        local pullLow, pullHigh, pullOwn = squadCampLevels(player)
        say(player, string.format('squadpanel:plvl|%d|%d|%d', pullLow, pullHigh, pullOwn and 1 or 0))
        for _, mate in ipairs(squad) do
            say(player, string.format('squadpanel:delay|%d|%d', mate.slot, player:getCharVar('SQUAD_DELAY_' .. mate.id)))
        end
        -- (servermenu 1.12) cd|<slot>|<seconds before this mate can be called again>: a mate who is away waits that long; for a
        -- mate who is out (1.13) it is how long before a dismiss and call works straight away
        for _, mate in ipairs(squad) do
            local left = cooldownLeft(player, mate)
            if left > 0 then
                say(player, string.format('squadpanel:cd|%d|%d', mate.slot, left))
            end
        end
        for _, mate in ipairs(squad) do
            local wsList = '-'
            for _, trust in ipairs(squadTrusts(player)) do
                if trust:getLocalVar('SQUAD_ID') == mate.id and GetSquadWeaponSkills then
                    local ok, names = pcall(GetSquadWeaponSkills, trust)
                    if ok and type(names) == 'table' and #names > 0 then
                        -- the strongest last; a chat line holds about 200 characters, so the weakest are left out if needed
                        local kept = {}
                        for i = #names, 1, -1 do
                            if #table.concat(kept, ',') + #names[i] > 150 then
                                break
                            end
                            table.insert(kept, 1, names[i])
                        end
                        wsList = table.concat(kept, ',')
                    end
                end
            end

            local chosen = player:getCharVar('SQUAD_WS_' .. mate.id)
            say(player, string.format('squadpanel:opt|%d|%d|%d|%s|%d|%s', mate.slot, player:getCharVar('SQUAD_SIZE_' .. mate.id),
                player:getCharVar('SQUAD_WSTP_' .. mate.id), chosen > 0 and wsName(chosen):gsub(' ', '_') or '-',
                player:getCharVar('SQUAD_RANGE_' .. mate.id), wsList))
        end
        -- (servermenu 1.8) what the puller goes for, and the kinds of monster around the camp
        if c then
            say(player, 'squadpanel:campwant|' .. (c.want or '-'))
            for _, k in ipairs(campKinds(player, c)) do
                say(player, string.format('squadpanel:campmob|%s|%d|%d|%d|%d', k.name, k.lo, k.hi, k.count, k.fits and 1 or 0))
            end
        end

        say(player, 'squadpanel:end')
        return
    end

    if action == 'sheet' then
        -- The stat sheet behind the panel's Sheet window (the idea is borrowed from TitanXI's trust profiles).
        -- Same channel as 'panel': lines the addon reads and hides from your chat log.
        --   squadsheet:hdr|<name>|<main job>|<main level>|<sub job or ->|<sub level>|<role>|<mode>|<race>|<switch mask>
        --   squadsheet:job|<job>|<level>                               every job the mate has
--   squadsheet:exp|<job>|<own level>|<exp>|<needed>          main job exp (needed 0 = level cap)
        --   squadsheet:vital|<HP|MP|TP>|<current>|<max>                only while the mate is called
        --   squadsheet:stat|<STR..CHR>|<value>
        --   squadsheet:combat|<Attack|Accuracy|Defense|Evasion|Ranged attack|Ranged accuracy>|<value>
        --   squadsheet:haste|<gear|magic|ability>|<hundredths of a percent>
        --   squadsheet:eq|<slot index>|<slot name>|<item name>|<item id>
        --   squadsheet:note|<text>
        --   squadsheet:end
        local mate = arg1 ~= nil and findMate(squad, tonumber(arg1) or 0) or nil
        if mate == nil then
            say(player, '!squad sheet <slot> - the stat sheet of one squad mate, for the squad panel.')
            return
        end

        local main, sub, subLevel = levelsFor(mate, nil, player)
        local role, mode         = decodeBehavior(player:getCharVar('SQUAD_AI_' .. mate.id))
        local live               = summonedMate(player, mate.id)
        local clean              = function(text) return tostring(text or '?'):gsub('|', '/') end

        say(player, string.format('squadsheet:hdr|%s|%s|%d|%s|%d|%s|%s|%s|%d', clean(mate.name), jobNames[mate.mjob] or '???', main,
            sub ~= 0 and jobNames[sub] or ((mate.sjob ~= 0 and mate.sjob ~= mate.mjob) and jobNames[mate.sjob] or '-'), subLevel, role, mode, raceNames[mate.race] or '?', switchesOf(player, mate.id))) -- (a support job set but not active yet: level 0)

        local jobs = {}
        for job = 1, 18 do
            if mate.jobs[job] ~= nil then
                jobs[#jobs + 1] = { job, mate.jobs[job].level }
            end
        end

        table.sort(jobs, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
        for _, entry in ipairs(jobs) do
            say(player, string.format('squadsheet:job|%s|%d', jobNames[entry[1]] or '???', entry[2]))
        end

        -- 1.15: exp toward the next level of the main job. This is the mate's own level, not the synced one.
        --   squadsheet:exp|<job>|<own level>|<exp>|<exp needed, 0 at the level cap>
        local mainInfo = mate.jobs[mate.mjob]
        if mainInfo ~= nil then
            local ownLevel = tonumber(mainInfo.level) or 0
            local needed   = 0
            if ownLevel < MAX_LEVEL then
                local ok, value = pcall(GetSquadExpNeeded, ownLevel)
                needed = ok and (tonumber(value) or 0) or 0
            end
            say(player, string.format('squadsheet:exp|%s|%d|%d|%d', jobNames[mate.mjob] or '???', ownLevel, tonumber(mainInfo.exp) or 0, needed))
        end

        if live ~= nil then
            -- Every reading is wrapped: a missing binding must not stop the rest of the sheet.
            local function read(method, arg)
                local fn = live[method]
                if type(fn) ~= 'function' then
                    return 0
                end

                local ok, value
                if arg == nil then
                    ok, value = pcall(fn, live)
                else
                    ok, value = pcall(fn, live, arg)
                end

                return ok and (tonumber(value) or 0) or 0
            end

            say(player, string.format('squadsheet:vital|HP|%d|%d', read('getHP'), read('getMaxHP')))
            say(player, string.format('squadsheet:vital|MP|%d|%d', read('getMP'), read('getMaxMP')))
            say(player, string.format('squadsheet:vital|TP|%d|%d', read('getTP'), 3000))

            local stats = { { 'STR', xi.mod.STR }, { 'DEX', xi.mod.DEX }, { 'VIT', xi.mod.VIT }, { 'AGI', xi.mod.AGI },
                            { 'INT', xi.mod.INT }, { 'MND', xi.mod.MND }, { 'CHR', xi.mod.CHR } }
            for _, entry in ipairs(stats) do
                say(player, string.format('squadsheet:stat|%s|%d', entry[1], read('getStat', entry[2])))
            end

            -- Accuracy, evasion and the ranged pair are the numbers the game works its hit rates out from;
            -- attack and defense are only stored as modifiers.
            local combat = { { 'Attack', 'getMod', xi.mod.ATT }, { 'Accuracy', 'getACC' }, { 'Defense', 'getMod', xi.mod.DEF },
                             { 'Evasion', 'getEVA' }, { 'Ranged attack', 'getRATT' }, { 'Ranged accuracy', 'getRACC' } }
            for _, entry in ipairs(combat) do
                say(player, string.format('squadsheet:combat|%s|%d', entry[1], read(entry[2], entry[3])))
            end

            local haste = { { 'gear', xi.mod.HASTE_GEAR }, { 'magic', xi.mod.HASTE_MAGIC }, { 'ability', xi.mod.HASTE_ABILITY } }
            for _, entry in ipairs(haste) do
                say(player, string.format('squadsheet:haste|%s|%d', entry[1], read('getMod', entry[2])))
            end
        else
            say(player, 'squadsheet:note|Not called right now, so there are no live stats. The gear below is what they wear as ' ..
                (jobNames[mate.mjob] or '???') .. '.')
        end

        local worn = mate.equip[mate.mjob] or {}
        for slot = 0, 15 do
            local itemId = worn[slot]
            if itemId ~= nil and itemId ~= 0 then
                local info = GetSquadItemInfo(itemId)
                say(player, string.format('squadsheet:eq|%d|%s|%s|%d', slot, equipSlotNames[slot], clean(info.valid and info.name or itemId), itemId))
            end
        end

        for slot, itemId in pairs((squadLockstyleGet(player, mate.id))) do
            local info = GetSquadItemInfo(itemId)
            say(player, string.format('squadsheet:ls|%d|%s|%s|%d', slot, equipSlotNames[slot], clean(info.valid and info.name or itemId), itemId))
        end

        say(player, 'squadsheet:end')
        return
    end

    if action == 'new' then
        local name = arg1
        local job = parseJob(arg2)
        -- A new mate may start at a level up to 12 (and never above your own main level), so a mate made later
        -- can catch up a little; after that they level up by fighting with you. A GM may give any level, for testing.
        local wanted = math.floor(tonumber(arg3) or 1)
        local level = wanted
        if player:getGMLevel() == 0 then
            level = math.max(1, math.min(wanted, NEW_MATE_MAX_LEVEL, player:getMainLvl()))
            if wanted > level then
                say(player, string.format('New mates start at level %d at most (up to %d, and not above your own level).', level, NEW_MATE_MAX_LEVEL))
            end
        end

        if not validName(name) then
            say(player, 'Name must be 3-15 letters. Example: !squad new Bob WAR')
            return
        elseif job == nil then
            say(player, 'Unknown job. Jobs: ' .. jobList)
            return
        elseif not jobUnlocked(player, job) then
            say(player, lockedMessage(player, job))
            return
        end

        local slot = nil
        for s = 1, MAX_SLOTS do
            if findMate(squad, s) == nil then
                slot = s
                break
            end
        end

        if slot == nil then
            say(player, string.format('Your squad is full (%d). Use !squad delete <slot> first.', MAX_SLOTS))
            return
        end

        local id = SaveSquadMate(charId, slot, { name = name, race = 1, face = 0, nation = 0, mjob = job, sjob = 0, template = 0 })
        SetSquadJob(id, job, clampLevel(level), 0)
        chatNewMate(name, 1, jobNames[job], clampLevel(level), "San d'Oria")
        say(player, string.format('Created %s in slot %d. Use !squad call %d to bring them out.', name, slot, slot))
        return
    end

    if action == 'debug' then
        say(player, 'Party members that are trusts (name shown / internal / squad id / job / level):')
        for _, member in pairs(player:getPartyWithTrusts()) do
            if member:getObjType() == xi.objType.TRUST then
                say(player, string.format('  %s / %s / SQUAD_ID %d / job %d / level %d', member:getPacketName(), member:getName(), member:getLocalVar('SQUAD_ID'), member:getMainJob(), member:getMainLvl()))
            end
        end

        return
    end

    if action == 'camp' then
        local what = arg1 and string.lower(arg1) or nil
        if what == 'off' then
            camps[charId] = nil
            campApplyAll(player)
            say(player, 'Camp lifted. Your squad follows you again.')
            if type(xi.squad.pack) == 'table' then
                pcall(xi.squad.pack.onCommand, player, 'follow')
            end
        elseif what == 'status' then
            say(player, campStatus(player))
        elseif what == 'want' then
            local c = camps[charId]
            local raw = arg2 and arg2 ~= '' and arg2 or 'any'
            if c == nil then
                say(player, 'Set a camp first (!squad camp), then pick what to pull.')
                return
            end

            raw = raw:match('^%s*(.-)%s*$')
            local marker, name = raw:sub(1, 1), raw
            if marker ~= '+' and marker ~= '-' then
                marker = ''
            else
                name = raw:sub(2):match('^%s*(.-)%s*$')
            end

            if marker == '' and string.lower(name) == 'any' then
                c.want = nil
                say(player, 'Your puller goes for anything of a good level again.')
                return
            end

            local list = campWants(c)
            local at = nil
            for i, existing in ipairs(list) do
                if campNameMatches(existing, name) then
                    at = i
                end
            end

            -- A menu pick toggles: picking a kind that is already on the list takes it off.
            if marker == '-' or (marker == '' and at ~= nil) then
                if at ~= nil then
                    table.remove(list, at)
                end
            elseif not at then
                list[#list + 1] = name
            end

            if #list == 0 then
                c.want = nil
                say(player, 'Nothing picked: your puller is back to anything of a good level.')
            else
                c.want = table.concat(list, ',')
                say(player, string.format('Your puller goes for %s now (up to level %d).', campWantLabel(c), player:getMainLvl() + CAMP_WANT_ABOVE))
            end
        elseif what == 'range' then
            local n = tonumber(arg2 or '')
            if n and n >= CAMP_RANGE_LIMITS[1] and n <= CAMP_RANGE_LIMITS[2] then
                player:setCharVar('SQUAD_PULL_RANGE', math.floor(n))
                say(player, string.format('Your puller now goes for monsters up to %d yalms from camp.', math.floor(n)))
            else
                say(player, string.format('Pull range is %d yalms. Change it with !squad camp range <%d-%d>.', campRange(player), CAMP_RANGE_LIMITS[1], CAMP_RANGE_LIMITS[2]))
            end
        elseif what == 'links' then
            -- 2026-11-19: how many other monsters may come along with the one the puller goes for (0 = none: a monster with a same-kind
            -- neighbour close by is skipped). Hornflies, Crawlers and the like stand in swarms: 1 or 2 lets the puller take them.
            local n = tonumber(arg2 or '')
            if n and n >= 0 and n <= 5 then
                SQUAD_LINK.max = math.floor(n)
            end

            say(player, string.format('The puller may bring up to %d extra monster(s) along with its target (!squad camp links 0-5; 0 skips any monster with a neighbour close by).', SQUAD_LINK.max or 0))
        elseif what == 'levels' then
            local low, high = tonumber(arg2 or ''), tonumber(arg3 or '')
            if string.lower(arg2 or '') == 'reset' then
                player:setCharVar('SQUAD_PULL_LOW', 0)
                player:setCharVar('SQUAD_PULL_HIGH', 0)
                say(player, string.format('Your puller is back to monsters from %d below to %d above your level.', -CAMP_LEVELS[1], CAMP_LEVELS[2]))
            elseif low and high and low >= -30 and high <= 30 and low <= high then
                player:setCharVar('SQUAD_PULL_LOW', math.floor(low) + 100)
                player:setCharVar('SQUAD_PULL_HIGH', math.floor(high) + 100)
                say(player, string.format('Your puller now goes for monsters from level %+d to %+d against yours (now %d-%d).',
                    math.floor(low), math.floor(high), math.max(1, player:getMainLvl() + math.floor(low)), player:getMainLvl() + math.floor(high)))
            else
                local l, h = squadCampLevels(player)
                say(player, string.format('Pull levels: %+d to %+d against yours. Change: !squad camp levels <low> <high> (e.g. -10 0, from -30 to +10), or reset.', l, h))
            end
        elseif what == 'rest' then
            -- mates sit and rest at camp while the pull is out (char var SQUAD_CAMP_NOREST: 0 = on, the default; 1 = off)
            local on = string.lower(arg2 or '')
            if on == 'on' or on == 'off' then
                player:setCharVar('SQUAD_CAMP_NOREST', on == 'off' and 1 or 0)
            end

            say(player, player:getCharVar('SQUAD_CAMP_NOREST') == 1 and 'At camp your mates stay standing between fights (!squad camp rest on to change).'
                or 'At camp your mates sit and rest between fights while the pull is out (!squad camp rest off to change).')
        elseif what == 'pause' or what == 'resume' or what == 'start' then
            local c = camps[charId]
            if c then
                c.paused = what == 'pause'
                say(player, what == 'pause' and 'Pulls paused (the squad still holds camp).' or (what == 'start' and 'Pulling starts.' or 'Pulls resume.'))
            else
                say(player, campStatus(player))
            end
        else
            local pos = player:getPos()
            local old = camps[charId]
            camps[charId] = { zone = player:getZoneID(), x = pos.x, y = pos.y, z = pos.z, puller = old and old.puller or 0, state = 'idle', pulls = old and old.pulls or 0,
                              want = old and old.zone == player:getZoneID() and old.want or nil,
                              paused = true } -- (waits for Start: !squad camp start, or the Start button)
            campApplyAll(player)
            say(player, 'Camp set here. Your squad holds this spot and fights whatever comes within 20 yalms of it. Nothing is pulled until you press Start (!squad camp start).')
            if type(xi.squad.pack) == 'table' then
                pcall(xi.squad.pack.onCommand, player, 'hold')
            end
            say(player, 'Who pulls: !squad pull <slot>  (a mate)  or  !squad pull <bot name>  or  !squad pull me  |  !squad camp off  |  !squad camp pause|resume|status|range <yalms>|want <Monster_Name or any>')
        end

        return
    end

    if action == 'pull' then
        local who = arg1 and string.lower(arg1) or 'me'
        local mate = nil
        -- a bot player in your party can pull too (bots.lua runs it)
        local pullBot = nil
        if who ~= 'me' and who ~= 'off' and BotIsBot then
            for _, member in pairs(player:getParty() or {}) do
                if BotIsBot(member:getID()) and string.lower(member:getName()) == who then
                    pullBot = member
                end
            end
        end

        if pullBot then
            local c = camps[charId]
            if c == nil then
                local pos = player:getPos()
                c = { zone = player:getZoneID(), x = pos.x, y = pos.y, z = pos.z, puller = 0, state = 'idle', pulls = 0 }
                camps[charId] = c
                campApplyAll(player)
                say(player, 'Camp set here (where you stand).')
            end

            for _, trust in ipairs(squadTrusts(player)) do
                if trust:getLocalVar('SQUAD_ID') == c.puller then
                    campStop(trust)
                end
            end

            c.puller, c.pullerBot, c.state, c.nextPull = 0, pullBot:getID(), 'idle', os.time() + 2
            say(player, string.format('%s pulls. Monsters level %d-%d within %d yalms of camp, one at a time.',
                pullBot:getName(), math.max(1, player:getMainLvl() + CAMP_LEVELS[1]), player:getMainLvl() + CAMP_LEVELS[2], campRange(player)))
            return
        elseif who ~= 'me' and who ~= 'off' then
            mate = findMate(squad, tonumber(who) or -1)
            for _, m in ipairs(squad) do
                if mate == nil and string.lower(m.name) == who then
                    mate = m
                end
            end

            if mate == nil or not isSummoned(player, mate.id) then
                say(player, 'Call that mate first (!squad call <slot>), then: !squad pull <slot>')
                return
            end
        end

        local c = camps[charId]
        if c == nil then
            local pos = player:getPos()
            c = { zone = player:getZoneID(), x = pos.x, y = pos.y, z = pos.z, puller = 0, state = 'idle', pulls = 0 }
            camps[charId] = c
            campApplyAll(player)
            say(player, 'Camp set here (where you stand).')
        end

        for _, trust in ipairs(squadTrusts(player)) do
            if trust:getLocalVar('SQUAD_ID') == c.puller then
                campStop(trust)
            end
        end

        c.state = 'idle'
        c.pullerBot = nil
        if mate == nil then
            c.puller = 0
            say(player, 'You pull. Bring them back within 20 yalms of camp and the squad joins in.')
            return
        end

        c.puller, c.nextPull = mate.id, os.time() + 2
        say(player, string.format('%s pulls. Monsters level %d-%d within %d yalms of camp, one at a time when everyone is ready.',
            mate.name, math.max(1, player:getMainLvl() + CAMP_LEVELS[1]), player:getMainLvl() + CAMP_LEVELS[2], campRange(player)))
        return
    end

    if action == 'dismiss' and arg1 ~= nil and string.lower(arg1) ~= 'all' then
        -- one mate leaves, the others stay (needs the squad.cpp of v0.1.27: SquadDismissMate)
        local mate = findMate(squad, tonumber(arg1) or 0)
        local trust = mate and summonedMate(player, mate.id)
        if mate == nil then
            say(player, 'No squad mate in that slot. Use !squad to list them.')
        elseif trust == nil then
            say(player, string.format('%s is not out.', mate.name))
        elseif SquadDismissMate == nil then
            say(player, 'Dismissing one mate needs the newer server: press UPDATE in the launcher. (!squad dismiss sends everyone off.)')
        elseif SquadDismissMate(trust) then
            if type(xi.squad.pack) == 'table' then
                pcall(xi.squad.pack.onBench, player, mate.name)
            end

            if zoneOut[player:getID()] then
                zoneOut[player:getID()][mate.id] = nil
            end
            say(player, string.format('%s has been dismissed.', mate.name))
        end

        return
    end

    if action == 'dismiss' then
        zoneOut[player:getID()] = nil
        -- (2026-11-18) a party of you and your mates no longer breaks up (and so stays synced) while they are away for a
        -- moment; dismissing them all for good ends a Level Sync that only they were part of
        if player:hasStatusEffect(xi.effect.LEVEL_SYNC) and type(SquadLevelSync) == 'function' then
            local others = 0
            for _, member in pairs(player:getParty() or {}) do
                if member:getID() ~= player:getID() then
                    others = others + 1
                end
            end
            if others == 0 then
                pcall(SquadLevelSync, player, '')
            end
        end
        player:clearTrusts()
        chatSend('CTX', player:getZoneName(), player:getMainLvl(), 0, '', player:getName(), player:getRace())
        say(player, 'Your trusts and squad mates have been dismissed.')
        return
    end

    if action == 'call' then
        if #squad == 0 then
            say(player, 'You have no squad mates yet.')
            return
        end

        if arg1 == nil or string.lower(arg1) == 'all' then
            -- One at a time, a moment apart. Several characters appearing in the very same instant can leave the last ones undressed.
            for index, mate in ipairs(orderedSquad(player, squad)) do
                if index == 1 then
                    callWithCooldown(player, mate)
                else
                    player:timer((index - 1) * CALL_GAP_MS, function(entity)
                        callWithCooldown(entity, mate)
                    end)
                end
            end

            return
        end

        local mate = findMate(squad, tonumber(arg1) or 0)
        if mate == nil then
            say(player, 'No squad mate in that slot. Use !squad to list them.')
            return
        end

        callWithCooldown(player, mate)
        return
    end

    -- The Squad menu's "Apply now": the mates who are out come back with their new settings (no cooldown)
    if action == 'reapply' then
        local out = {}
        for _, mate in ipairs(orderedSquad(player, squad)) do
            if isSummoned(player, mate.id) then
                out[#out + 1] = mate
            end
        end

        player:clearTrusts()
        for index, mate in ipairs(out) do
            player:timer(RECALL_WAIT_MS + (index - 1) * CALL_GAP_MS, function(entity)
                callMate(entity, mate)
            end)
        end

        if #out == 0 then
            say(player, 'None of your squad mates are out.')
        end

        return
    end

    if action == 'give' then
        local itemId = FindSquadItem(arg1 or '')
        if itemId == 0 then
            say(player, 'Item not found. Use the item name (like bronze_harness) or its id.')
            return
        end

        if squadLearnScroll(player, function(text) say(player, text) end, itemId, function()
            return player:hasItem(itemId) and player:delItem(itemId, 1)
        end) then
            return
        end

        local info = GetSquadItemInfo(itemId)
        if not info.valid then
            say(player, 'Your squad can only be given equipment (and spell scrolls).')
            return
        end

        if GetSquadUnlocks(charId)[itemId] then
            say(player, string.format('Your squad already has %s. Every mate can wear it.', info.name))
            return
        end

        if not player:hasItem(itemId) then
            say(player, string.format('You do not have %s with you.', info.name))
            return
        end

        if isRareItem(itemId) then
            UnlockSquadItem(charId, itemId) -- (you keep it: Rare)
            say(player, string.format('%s is one of a kind: your squad gets its own and you keep yours. Every squad mate can wear it now.', info.name))
            return
        end

        if squadKeepGear() then
            UnlockSquadItem(charId, itemId) -- (you keep it: the launcher switch)
            say(player, string.format('Your squad gets its own %s and you keep yours. Every squad mate can wear it now.', info.name))
            return
        end

        player:delItem(itemId, 1)
        UnlockSquadItem(charId, itemId)
        say(player, string.format('You give %s to your squad. Every squad mate can wear it now.', info.name))
        return
    elseif action == 'unlocked' then
        local count = 0
        local names = {}
        for itemId in pairs(GetSquadUnlocks(charId)) do
            if itemId < SQUAD_SPELL_KEY then -- (learned spells are listed by !squad spells)
                count = count + 1
                if #names < 15 then
                    local info = GetSquadItemInfo(itemId)
                    names[#names + 1] = info.valid and info.name or tostring(itemId)
                end
            end
        end

        say(player, string.format('Your squad has been given %d item(s).', count))
        if count > 0 then
            say(player, table.concat(names, ', ') .. (count > #names and ', ...' or ''))

        end

        return
    end

    -- Everything below works on one slot: !squad <action> <slot> ...
    if action == 'diag' then
        -- what each mate out is doing right now (for bug reports): engaged, AI state, target, effects
        for _, trust in ipairs(squadTrusts(player)) do
            local ok, line = pcall(function()
                local t = trust:getTarget()
                local effects = {}
                for _, e in ipairs(trust:getStatusEffects() or {}) do
                    effects[#effects + 1] = tostring(e:getEffectType())
                end
                local walking = trust:isFollowingPath()
                if arg1 == 'clear' then
                    trust:clearPath() -- (test: does a mate swing again once its path is dropped?)
                end
                return string.format('%s lv%d: engaged %s, action %d, target %s %.1f yalms, walking %s, distance mod %d, TP %d, effects [%s]%s',
                    trust:getPacketName(), trust:getMainLvl(), tostring(trust:isEngaged()), trust:getCurrentAction(),
                    t and t:getName() or 'none', t and trust:checkDistance(t) or -1, tostring(walking),
                    trust:getMobMod(xi.mobMod.TRUST_DISTANCE), trust:getTP(), table.concat(effects, ' '), arg1 == 'clear' and ' (path cleared)' or '')
            end)
            say(player, ok and line or ('diag failed: ' .. tostring(line)))
            print('[squad] diag ' .. (ok and line or tostring(line)))
        end
        return
    end

    if action == 'follow' then
        -- How closely mates follow you out of combat (trust_controller.cpp reads SQUAD_FOLLOW: 0 normal, 1 close, 2 far)
        local styles = { normal = 0, close = 1, near = 1, far = 2, loose = 2 }
        local style = styles[string.lower(arg1 or '')]
        if style == nil then
            local now = ({ [0] = 'normal', 'close', 'far' })[player:getCharVar('SQUAD_FOLLOW')] or 'normal'
            say(player, '!squad follow close | normal | far   - how closely your mates follow you. Now: ' .. now)
            return
        end

        player:setCharVar('SQUAD_FOLLOW', style)
        say(player, 'Your mates now follow you ' .. ({ [0] = 'at the normal distance.', 'close behind.', 'from further back.' })[style])
        return
    end

    if action == 'order' then
        -- Who "call all" brings out first: !squad order 3 1 2  (slots not listed come after, in slot order)
        local words = {}
        local given = { arg1, arg2, arg3, arg4 }
        for i = 1, 4 do
            for w in tostring(given[i] or ''):gmatch('[^%s,]+') do
                words[#words + 1] = w
            end
        end

        if words[1] and string.lower(words[1]) == 'reset' then
            player:setCharVar('SQUAD_ORDER', 0)
            say(player, '"Call all" brings your mates out in slot order again.')
            return
        end

        local code, seen = '', {}
        for _, w in ipairs(words) do
            local slot = tonumber(w)
            if slot and slot >= 1 and slot <= 9 and findMate(squad, slot) and not seen[slot] then
                seen[slot] = true
                code = code .. slot
            end
        end

        if code == '' then
            local names = {}
            for _, mate in ipairs(orderedSquad(player, squad)) do
                names[#names + 1] = mate.slot .. ' ' .. mate.name
            end

            say(player, '!squad order <slots, e.g. 3 1 2> | reset   - who "call all" brings out first. Now: ' .. table.concat(names, ', '))
            return
        end

        player:setCharVar('SQUAD_ORDER', tonumber(code))
        local names = {}
        for _, mate in ipairs(orderedSquad(player, squad)) do
            names[#names + 1] = mate.name
        end

        say(player, '"Call all" order: ' .. table.concat(names, ', ') .. '. Dismiss and call everyone to use it now.')
        return
    end

    if action == 'spells' and arg1 ~= nil and tonumber(arg1) ~= nil then
        -- (2026-11-22, levi) !squad spells <slot>: the spells one mate has now, by the rules a call uses (Gambits'
        -- mateSpells in gambits_squad.lua: main/sub job and level, scroll items, learned scrolls when that option is on)
        local mate = findMate(squad, tonumber(arg1))
        local mateSpells = xi.squad.mateSpells
        if mate == nil then
            say(player, '!squad spells <slot> - the spells one squad mate has. !squad list shows the slots.')
            return
        end

        if type(mateSpells) ~= 'function' then
            say(player, 'The spell list needs gambits_squad.lua, which did not load.')
            return
        end

        local main, sub, subLevel = levelsFor(mate, nil, player)
        local ok, has, maybe = pcall(mateSpells, player, mate.mjob, main, sub, subLevel)
        if not ok then
            say(player, 'Could not build the spell list: ' .. tostring(has))
            return
        end

        local function lines(list)
            local rows = {}
            for _, entry in ipairs(list or {}) do
                local name, lv, s = string.match(entry, '^(.-):(%d+)(s?)$')
                if name then
                    rows[#rows + 1] = { name = prettySpellName(string.lower(name)), lv = tonumber(lv), sub = s == 's' }
                end
            end

            table.sort(rows, function(a, b)
                if a.lv ~= b.lv then
                    return a.lv < b.lv
                end

                return a.name < b.name
            end)
            local out, cur = {}, ''
            for _, r in ipairs(rows) do
                local item = string.format('%s %d%s', r.name, r.lv, r.sub and '*' or '')
                if cur ~= '' and #cur + #item + 2 > 120 then
                    out[#out + 1] = cur
                    cur = ''
                end

                cur = cur == '' and item or (cur .. ', ' .. item)
            end

            if cur ~= '' then
                out[#out + 1] = cur
            end

            return out, #rows
        end

        local subText = sub ~= 0 and string.format('/%s%d', jobNames[sub] or '?', subLevel) or ''
        local hasLines, hasCount = lines(has)
        say(player, string.format('%s (%s%d%s) has %d spell(s)%s', mate.name, jobNames[mate.mjob] or '???', main, subText, hasCount,
            hasCount > 0 and ' (level learned, * = from the support job):' or '.'))
        for _, text in ipairs(hasLines) do
            say(player, text)
        end

        local maybeLines, maybeCount = lines(maybe)
        if maybeCount > 0 then
            say(player, string.format('Allowed by job and level but not confirmed (%d): scroll not given yet, or blue magic set when called:', maybeCount))
            for _, text in ipairs(maybeLines) do
                say(player, text)
            end
        end

        return
    end

    if action == 'spells' then
        if not squadScrollsOn() then
            say(player, 'Squad mates know every spell their jobs learn at their level (the launcher option "learn spells from scrolls" is off).')
            return
        end

        local byId = {}
        for name, id in pairs(xi.magic.spell or {}) do
            byId[id] = name
        end

        local names = {}
        for key in pairs(GetSquadUnlocks(charId) or {}) do
            if key >= SQUAD_SPELL_KEY then
                local raw = byId[key - SQUAD_SPELL_KEY]
                names[#names + 1] = raw and prettySpellName(string.lower(raw)) or tostring(key - SQUAD_SPELL_KEY)
            end
        end

        table.sort(names)
        say(player, string.format('Your squad has learned %d spell(s) of level 18 or above%s', #names, #names > 0 and ':' or '. Give them scrolls (trade to a mate or !squad give scroll_of_<spell>).'))
        for i = 1, #names, 12 do
            say(player, table.concat(names, ', ', i, math.min(i + 11, #names)))
        end

        return
    end

    if action == 'autoequip' or action == 'auto' then
        local wanted = string.lower(arg1 or '')
        if wanted == 'on' or wanted == '1' then
            player:setCharVar('SQUAD_AUTOEQUIP', 1)
            local total = 0
            for _, m in ipairs(GetSquad(player:getID()) or {}) do
                local ok, n = pcall(squadAutoEquip, player, m)
                total = total + ((ok and n) or 0)
            end

            say(player, string.format('Auto-equip is on: your squad wears the best gear you have given them (%d piece(s) changed), and picks again each time they are called. Apply now (or dismiss and call) to see it. !squad autoequip off to choose by hand.', total))
        elseif wanted == 'off' or wanted == '0' then
            player:setCharVar('SQUAD_AUTOEQUIP', 0)
            say(player, 'Auto-equip is off: your squad keeps what it wears now, and you choose gear by hand.')
        else
            say(player, '!squad autoequip on | off   - mates wear the best given gear for their job and level. Now: ' .. (player:getCharVar('SQUAD_AUTOEQUIP') == 1 and 'on' or 'off'))
        end

        return
    end

    if action == 'sync' then
        -- Level Sync to anyone in your party: a player, a bot or a squad mate (the party menu's Level Sync does the same;
        -- needs the server of 2026-11-17 or later)
        local who = arg1 or ''
        if who == '' then
            say(player, '!squad sync <name> | off   - Level Sync your party to a player, bot or squad mate in it (or use the party menu)')
            return
        end

        if not SquadLevelSync then
            say(player, 'Level Sync to squad mates needs the latest update (UPDATE in the launcher).')
            return
        end

        local off = string.lower(who) == 'off'
        local r = SquadLevelSync(player, off and '' or who)
        if r == 0 then
            say(player, 'You are not in a party (call a squad mate or invite someone first).')
        elseif r < 0 then
            say(player, 'Only the party leader can set Level Sync.')
        end

        return
    end

    if action == 'engage' then
        -- When mates join a fight. The game reads the char var TrustEngageType (trust_controller.cpp): 0 = retail (you
        -- engage AND swing), 1 = as soon as you engage. Set here directly; the core !trustengage command is GM-only.
        local wanted = string.lower(arg1 or '')
        if wanted == 'first' or wanted == 'on' or wanted == '1' then
            player:setCharVar('TrustEngageType', 1)
            say(player, 'Your squad now joins the fight as soon as you engage (draw your weapon), without waiting for your first swing.')
        elseif wanted == 'normal' or wanted == 'off' or wanted == '0' then
            player:setCharVar('TrustEngageType', 0)
            say(player, 'Your squad now joins the fight after your first swing, like retail trusts.')
        else
            local now = player:getCharVar('TrustEngageType') == 1 and 'first (as soon as you engage)' or 'normal (after your first swing)'
            say(player, '!squad engage first | normal   - when your mates join a fight. Now: ' .. now)
        end

        return
    end

    if action == 'pose' and player:getGMLevel() > 0 then
        -- (GM test: which animation id shows a sitting mate in the game client, e.g. 33 healing, 47 sit)
        local id = tonumber(arg1) or 0
        for _, trust in ipairs(squadTrusts(player)) do
            trust:setAnimation(id)
        end
        say(player, 'Squad mates set to animation ' .. id .. ' (0 stands them up).')
        return
    end

    local mate = findMate(squad, tonumber(arg1) or 0)
    if mate == nil then
        usage(player)
        return
    end

    if action == 'role' or action == 'mode' then
        local list = action == 'role' and ROLES or MODES
        local wanted = string.lower(arg2 or '')
        local synonyms = { dps = 'damage', attacker = 'damage', heal = 'healer', buffer = 'support', normal = 'balanced', aggro = 'aggressive', careful = 'conserve' }
        wanted = synonyms[wanted] or wanted
        local index = nil
        for i, word in ipairs(list) do
            if word == wanted then
                index = i
            end
        end

        if index == nil then
            say(player, string.format('Use: !squad %s <slot> <%s>', action, table.concat(list, '|')))
            return
        end

        local currentRole, currentMode = decodeBehavior(player:getCharVar('SQUAD_AI_' .. mate.id))
        local roleIndex, modeIndex = 1, 1
        for i, word in ipairs(ROLES) do
            if word == currentRole then
                roleIndex = i
            end
        end

        for i, word in ipairs(MODES) do
            if word == currentMode then
                modeIndex = i
            end
        end

        if action == 'role' then
            roleIndex = index
        else
            modeIndex = index
        end

        player:setCharVar('SQUAD_AI_' .. mate.id, (roleIndex - 1) * 10 + (modeIndex - 1))
        say(player, string.format('%s: role %s, mode %s  (dismiss and call them again to apply)', mate.name, ROLES[roleIndex], MODES[modeIndex]))
        return
    end

    if action == 'sw' or action == 'switch' or action == 'switches' then
        local wanted = string.lower(arg2 or '')
        local state  = string.lower(arg3 or '')

        if wanted == '' then
            say(player, string.format('%s: %s', mate.name, switchSummary(switchesOf(player, mate.id))))
            say(player, 'Use: !squad sw <slot> <melee|ranged|ja|magic|all> <on|off>')
            return
        end

        local targets = nil
        if wanted == 'all' then
            targets = SWITCHES
        elseif SW_BIT[wanted] ~= nil then
            targets = { wanted }
        end

        local on = (state == 'on' or state == 'yes' or state == '1')
        if targets == nil or (not on and state ~= 'off' and state ~= 'no' and state ~= '0') then
            say(player, 'Use: !squad sw <slot> <melee|ranged|ja|magic|all> <on|off>')
            return
        end

        local mask = switchesOf(player, mate.id)
        for _, name in ipairs(targets) do
            mask = withBit(mask, SW_BIT[name], on)
        end

        player:setCharVar('SQUAD_SW_' .. mate.id, mask + 1)

        -- Melee off takes effect right away on a mate who is already out; everything else is built when they are called.
        local live = summonedMate(player, mate.id)
        if live ~= nil and not hasBit(mask, SW_BIT.melee) then
            live:setAutoAttackEnabled(false)
            if live:getMobMod(xi.mobMod.TRUST_DISTANCE) == 0 then
                live:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.MID_RANGE)
            end
        end

        say(player, string.format('%s: %s', mate.name, switchSummary(mask)))
        say(player, 'Dismiss and call them again to apply everything else.')
        return
    end

    if action == 'gearlist' then
        -- (servermenu 1.14's gear picker) the given gear this mate can wear in one slot, as panel lines:
        -- squadpanel:gl|<mate slot>|<equip slot>|<item id>|<level>|<name>, then squadpanel:gle|<mate slot>|<equip slot>|<count>
        local eq = tonumber(arg2 or '')
        if eq == nil or eq < 0 or eq > 15 then
            say(player, 'squadpanel:gle|' .. mate.slot .. '|-1|0')
            return
        end

        local mainLevel = levelsFor(mate)
        local found = {}
        for itemId in pairs(GetSquadUnlocks(charId) or {}) do
            local info = GetSquadItemInfo(itemId)
            if info and info.valid and hasBit(info.slot, eq) and info.level <= mainLevel and hasBit(info.jobs, mate.mjob - 1) then
                found[#found + 1] = { id = itemId, level = info.level, name = info.name }
            end
        end

        table.sort(found, function(x, y)
            return x.level > y.level or (x.level == y.level and x.name < y.name)
        end)

        -- (2026-11-21, Tasou/Yache) with "Squad gets all gear" on, the rest of the list is every piece this mate can
        -- wear in the slot, best first, after the pieces you gave (needs the xi_map with GetSquadGearChoices)
        if squadAllGear() and type(GetSquadGearChoices) == 'function' then
            local listed = {}
            for _, f in ipairs(found) do
                listed[f.id] = true
            end

            local ok, choices = pcall(GetSquadGearChoices, eq, mate.mjob, mainLevel, 80)
            if ok and type(choices) == 'table' then
                for _, c in ipairs(choices) do
                    if #found >= 40 then
                        break
                    end

                    if not listed[c.id] then
                        listed[c.id] = true
                        found[#found + 1] = { id = c.id, level = c.level, name = c.name }
                    end
                end
            end
        end

        for k = 1, math.min(#found, 40) do
            say(player, string.format('squadpanel:gl|%d|%d|%d|%d|%s', mate.slot, eq, found[k].id, found[k].level, found[k].name))
        end

        say(player, string.format('squadpanel:gle|%d|%d|%d', mate.slot, eq, #found))
        return
    elseif action == 'equip' then
        local itemId = FindSquadItem(arg2 or '')
        if itemId == 0 then
            say(player, 'Item not found. Use the item name (like bronze_harness) or its id.')
            return
        end

        local info = GetSquadItemInfo(itemId)
        if not info.valid then
            say(player, 'That is not an equippable item.')
            return
        end

        if REQUIRE_UNLOCK and not squadAllGear() and not GetSquadUnlocks(charId)[itemId] then
            say(player, string.format('%s has not been given to your squad yet. Use !squad give %s first.', info.name, arg2))
            return
        end

        local mainLevel = levelsFor(mate)
        if info.level > mainLevel then
            say(player, string.format('%s needs level %d, but %s is level %d as %s.', info.name, info.level, mate.name, mainLevel, jobNames[mate.mjob]))
            return
        elseif not hasBit(info.jobs, mate.mjob - 1) then
            say(player, string.format('%s cannot be worn by %s.', info.name, jobNames[mate.mjob]))
            return
        end

        local slotIndex = nil
        if arg3 ~= nil then
            slotIndex = equipSlots[string.lower(arg3)]
            if slotIndex == nil or not hasBit(info.slot, slotIndex) then
                say(player, string.format('%s does not fit that slot.', info.name))
                return
            end
        else
            local worn = mate.equip[mate.mjob] or {}
            for s = 0, 15 do
                if hasBit(info.slot, s) then
                    if slotIndex == nil then
                        slotIndex = s
                    end

                    if worn[s] == nil then
                        slotIndex = s
                        break
                    end
                end
            end
        end

        if slotIndex == nil then
            say(player, 'Could not find a slot for that item.')
            return
        end

        SetSquadEquip(mate.id, mate.mjob, slotIndex, itemId)
        say(player, string.format('%s now wears %s (%s) as %s. Dismiss and call them again to apply.', mate.name, info.name, equipSlotNames[slotIndex], jobNames[mate.mjob]))
        if player:getCharVar('SQUAD_AUTOEQUIP') == 1 then
            player:setCharVar('SQUAD_AUTOEQUIP', 0)
            say(player, 'Auto-equip is now off (you chose gear by hand).')
        end
        return
    elseif action == 'lockstyle' or action == 'ls' then
        -- !squad lockstyle <slot> <item> [equip slot] | set | off [equip slot]
        local what = string.lower(arg2 or '')
        if what == '' then
            local locked, any = squadLockstyleGet(player, mate.id)
            say(player, string.format('%s - lockstyle:%s', mate.name, any and '' or ' off (shows the gear it wears)'))
            for slot, itemId in pairs(locked) do
                local info = GetSquadItemInfo(itemId)
                say(player, string.format('  %s: %s', equipSlotNames[slot], info.valid and info.name or tostring(itemId)))
            end
            say(player, 'Use: !squad lockstyle <slot> <item> [slot] | set | off [slot]')
            return
        elseif what == 'off' or what == 'clear' then
            local slotIndex = arg3 and equipSlots[string.lower(arg3)]
            if slotIndex ~= nil then
                squadLockstyleSet(player, mate.id, slotIndex, 0)
                say(player, string.format('%s shows its own %s gear again. Dismiss and call them again to apply.', mate.name, equipSlotNames[slotIndex]))
            else
                squadLockstyleClear(player, mate.id)
                say(player, string.format('Lockstyle off: %s shows the gear it wears. Dismiss and call them again to apply.', mate.name))
            end
            return
        elseif what == 'set' then
            -- lock the look it has right now (its current job's gear)
            squadLockstyleClear(player, mate.id)
            local n = 0
            for slot, itemId in pairs(mate.equip[mate.mjob] or {}) do
                if SQUAD_LS_SLOTS[slot] and itemId ~= 0 then -- (the starter mark is slot 255, not a lockstyle slot)
                    squadLockstyleSet(player, mate.id, slot, itemId)
                    n = n + 1
                end
            end
            say(player, string.format('%s keeps this look (%d pieces) whatever it wears from now on. Dismiss and call them again to apply.', mate.name, n))
            return
        end

        local itemId = FindSquadItem(arg2 or '')
        local info = itemId ~= 0 and GetSquadItemInfo(itemId) or { valid = false }
        if not info.valid then
            say(player, 'Item not found, or not something you can wear. Use the item name (like leather_vest) or its id.')
            return
        end

        if REQUIRE_UNLOCK and not squadAllGear() and not GetSquadUnlocks(charId)[itemId] then
            say(player, string.format('%s has not been given to your squad yet. Use !squad give %s first.', info.name, arg2))
            return
        end

        local slotIndex = arg3 and equipSlots[string.lower(arg3)] or nil
        if slotIndex == nil then
            for s2 = 0, 8 do
                if SQUAD_LS_SLOTS[s2] and hasBit(info.slot, s2) then
                    slotIndex = s2
                    break
                end
            end
        end

        if slotIndex == nil or not SQUAD_LS_SLOTS[slotIndex] or not hasBit(info.slot, slotIndex) then
            say(player, string.format('%s does not show in that slot (lockstyle covers main, sub, range, head, body, hands, legs, feet).', info.name))
            return
        end

        squadLockstyleSet(player, mate.id, slotIndex, itemId)
        say(player, string.format('%s now looks like it wears %s (%s). Dismiss and call them again to apply.', mate.name, info.name, equipSlotNames[slotIndex]))
        return
    elseif action == 'unequip' then
        if player:getCharVar('SQUAD_AUTOEQUIP') == 1 then
            player:setCharVar('SQUAD_AUTOEQUIP', 0)
            say(player, 'Auto-equip is now off (you chose gear by hand).')
        end

        local which = string.lower(arg2 or '')
        if which == 'all' then
            for s = 0, 15 do
                SetSquadEquip(mate.id, mate.mjob, s, 0)
            end

            say(player, string.format('%s took off everything (%s gear).', mate.name, jobNames[mate.mjob]))
            return
        end

        local slotIndex = equipSlots[which]
        if slotIndex == nil then
            say(player, 'Which slot? head body hands legs feet main sub range ammo neck waist ear1 ear2 ring1 ring2 back, or all')
            return
        end

        SetSquadEquip(mate.id, mate.mjob, slotIndex, 0)
        say(player, string.format('%s took off the %s item. Dismiss and call them again to apply.', mate.name, equipSlotNames[slotIndex]))
        return
    elseif action == 'gear' then
        local worn = mate.equip[mate.mjob] or {}
        say(player, string.format('%s - %s gear:', mate.name, jobNames[mate.mjob]))

        local any = false
        for s = 0, 15 do
            if worn[s] ~= nil then
                local info = GetSquadItemInfo(worn[s])
                say(player, string.format('  %s: %s', equipSlotNames[s], info.valid and info.name or tostring(worn[s])))
                any = true
            end
        end

        if not any then
            say(player, '  (nothing equipped)')
        end

        return
    elseif action == 'delete' then
        player:setCharVar('SQUAD_LOOK_' .. mate.id, 0)
        squadLockstyleClear(player, mate.id)
        player:setCharVar('SQUAD_SIZE_' .. mate.id, 0)
        player:setCharVar('SQUAD_WSTP_' .. mate.id, 0)
        player:setCharVar('SQUAD_WS_' .. mate.id, 0)
        player:setCharVar('SQUAD_RANGE_' .. mate.id, 0)
        player:setCharVar('SQUAD_DELAY_' .. mate.id, 0)
        squadBlueSetPut(player, mate.id, nil)
        chatSend('DELETE', mate.name)
        DeleteSquadMate(charId, mate.slot)
        say(player, string.format('Deleted %s.', mate.name))
        return
    elseif action == 'levels' then
        say(player, string.format('%s - job levels (unlisted jobs are level 1):', mate.name))
        for id = 1, 18 do
            local info = mate.jobs[id]
            if info ~= nil then
                say(player, string.format('  %s %d  (%d exp)', jobNames[id], info.level, info.exp))
            end
        end

        return
    elseif action == 'setlevel' then
        if player:getGMLevel() == 0 then
            say(player, 'Squad mates level up by fighting with you, like any character.')
            return
        end

        local job = parseJob(arg2)
        local level = tonumber(arg3)
        if job == nil or level == nil then
            say(player, '!squad setlevel <slot> <job> <level>')
            return
        elseif not jobUnlocked(player, job) then
            say(player, lockedMessage(player, job))
            return
        end

        SetSquadJob(mate.id, job, clampLevel(level), 0)
        chatSend('UPDATE', mate.name, 'level', clampLevel(level))
        say(player, string.format('%s: %s is now level %d.', mate.name, jobNames[job], clampLevel(level)))
        return
    elseif action == 'job' then
        local job = parseJob(arg2)
        if job == nil then
            say(player, 'Unknown job. Jobs: ' .. jobList)
            return
        elseif not jobUnlocked(player, job) and job ~= mate.mjob and job ~= mate.sjob then
            say(player, lockedMessage(player, job))
            return
        end

        mate.mjob = job
        if mate.sjob == job then
            mate.sjob = 0
        end
        chatSend('UPDATE', mate.name, 'job', jobNames[job])
    elseif action == 'sub' then
        if arg2 ~= nil and string.lower(arg2) == 'none' then
            mate.sjob = 0
        else
            local job = parseJob(arg2)
            if job == nil or job == mate.mjob then
                say(player, 'Pick a different job than the main job, or "none".')
                return
            elseif not jobUnlocked(player, job) and job ~= mate.sjob then
                say(player, lockedMessage(player, job))
                return
            end

            mate.sjob = job
        end
    elseif action == 'look' then
        local race = raceIds[string.lower(arg2 or '')]
        local face = tonumber(arg3)
        if race == nil or face == nil or face < 1 or face > 16 then
            say(player, '!squad look <slot> <race> <face 1-16>   races: humem humef elvm elvf tarum taruf mithra galka')
            return
        end

        -- A look is picked once (in game or in the launcher, which sets the same var); a GM may still change it
        local lookVar = 'SQUAD_LOOK_' .. mate.id
        if player:getCharVar(lookVar) == 1 and player:getGMLevel() == 0 then
            say(player, string.format('%s\'s look is already set for good.', mate.name))
            return
        end

        mate.race = race
        mate.face = math.floor(face) - 1
        player:setCharVar(lookVar, 1)
        say(player, string.format('%s\'s look is now set for good.', mate.name))
        chatSend('UPDATE', mate.name, 'race', race)
    elseif action == 'blu' then
        -- A Blue Mage's set blue magic: !squad blu <slot> [set | unset <spell>] | auto (the Squad window does the same)
        local sub, what = string.lower(arg2 or ''), string.lower(table.concat({ arg3 or '', arg4 or '' }, ' '))
        local st = squadBlueState(player, mate)
        if st == nil or st.slots == 0 then
            say(player, string.format('%s needs to be out, on Blue Mage (main or sub job), to set blue magic.', mate.name))
            return
        end

        local function find(text)
            local key = text:gsub('[%s_\'%-]', '')
            for _, k in ipairs(st.known) do
                if tostring(k.spell) == key or string.lower(k.name):gsub('[%s_\'%-]', '') == key then
                    return k
                end
            end

            return nil
        end

        if sub == 'auto' then
            squadBlueSetPut(player, mate.id, nil)
            say(player, string.format('%s picks their own blue magic again. Dismiss and call them again to apply it.', mate.name))
        elseif sub == 'set' or sub == 'unset' then
            local k = find(what)
            if k == nil then
                say(player, string.format('%s doesn\'t know "%s" (or isn\'t high enough for it). !squad blu %d lists what they know.', mate.name, what, mate.slot))
                return
            end

            local list = st.auto and st.set or squadBlueSetGet(player, mate.id) -- (from automatic: start from what is set now)
            local copy, has = {}, false
            for _, id in ipairs(list) do
                if id == k.spell then
                    has = true
                    if sub == 'set' then
                        copy[#copy + 1] = id
                    end
                else
                    copy[#copy + 1] = id
                end
            end

            if sub == 'set' and not has then
                local used = 0
                for _, kk in ipairs(st.known) do
                    for _, id in ipairs(copy) do
                        if kk.spell == id then
                            used = used + kk.points
                        end
                    end
                end

                if #copy >= st.slots or used + k.points > st.points then
                    say(player, string.format('No room for %s: %d/%d slots, %d/%d points. Unset something first.', k.name, #copy, st.slots, used, st.points))
                    return
                end

                copy[#copy + 1] = k.spell
            end

            squadBlueSetPut(player, mate.id, copy)
            say(player, string.format('%s %s %s (your own set now; !squad blu %d auto to let them choose). Dismiss and call them again to apply it.',
                mate.name, sub == 'set' and 'sets' or 'unsets', k.name, mate.slot))
        else
            -- the list, also for the Squad window: blu|slot|slots|points|used|auto, blus|slot|id|name|level|points|set, blue|slot
            say(player, string.format('squadpanel:blu|%d|%d|%d|%d|%d', mate.slot, st.slots, st.points, st.used, st.auto and 1 or 0))
            for _, k in ipairs(st.known) do
                say(player, string.format('squadpanel:blus|%d|%d|%s|%d|%d|%d', mate.slot, k.spell, string.gsub(k.name, ' ', '_'), k.level, k.points, k.set and 1 or 0))
            end

            say(player, 'squadpanel:blue|' .. mate.slot)
            local names = {}
            for _, k in ipairs(st.known) do
                if k.set then
                    names[#names + 1] = k.name
                end
            end

            say(player, string.format('%s (%s): %d/%d slots, %d/%d points. Set: %s', mate.name, st.auto and 'automatic' or 'your set',
                #st.set, st.slots, st.used, st.points, #names > 0 and table.concat(names, ', ') or 'nothing'))
            say(player, string.format('!squad blu %d set <spell> | unset <spell> | auto', mate.slot))
        end

        return
    elseif action == 'delay' then
        -- Seconds this mate waits after you engage before joining (trust_controller.cpp reads local var SQUAD_ENGAGE_DELAY, ms)
        local secs = tonumber(arg2 or '')
        if secs == nil or secs < 0 or secs > 10 then
            say(player, string.format('!squad delay <slot> <0-10>   - seconds %s waits before joining a fight. Now: %d', mate.name,
                player:getCharVar('SQUAD_DELAY_' .. mate.id)))
            return
        end

        secs = math.floor(secs)
        player:setCharVar('SQUAD_DELAY_' .. mate.id, secs)
        say(player, string.format('%s %s. Dismiss and call them again to apply it.', mate.name,
            secs == 0 and 'joins fights right away' or ('waits ' .. secs .. (secs == 1 and ' second' or ' seconds') .. ' before joining a fight')))
        return
    elseif action == 'range' then
        -- How far this mate stands from the monster: !squad range <slot> melee | mid | far | auto (auto = its job's own)
        local choices = { auto = 0, melee = 1, mid = 2, far = 3 }
        local choice = choices[string.lower(arg2 or '')]
        if choice == nil then
            say(player, '!squad range <slot> melee | mid | far | auto   - how far this mate stands from the monster')
            return
        end

        player:setCharVar('SQUAD_RANGE_' .. mate.id, choice)
        say(player, string.format('%s now fights %s. Dismiss and call them again to apply it.', mate.name,
            ({ [0] = 'at its job\'s usual distance', 'up close', 'from mid range (6 yalms)', 'from long range (12 yalms)' })[choice]))
        return
    elseif action == 'ws' then
        -- When this mate weapon skills, and which one: !squad ws <slot> chain | <TP 1000-3000> [weapon_skill | best]
        local when = string.lower(arg2 or '')
        local tp = tonumber(when)
        if when ~= 'chain' and (tp == nil or tp < 1000 or tp > 3000) then
            local nowTp, nowWs = player:getCharVar('SQUAD_WSTP_' .. mate.id), player:getCharVar('SQUAD_WS_' .. mate.id)
            say(player, '!squad ws <slot> chain | <TP 1000-3000> [weapon_skill | best]   e.g. !squad ws 1 1000 raging_axe')
            say(player, string.format('%s now: %s, %s.', mate.name, nowTp > 0 and ('at ' .. nowTp .. ' TP') or 'skillchains with the party',
                nowWs > 0 and wsName(nowWs) or 'its best weapon skill'))
            return
        end

        local wsId = 0
        local wanted = string.lower(arg3 or 'best')
        if wanted ~= 'best' then
            -- "Tachi:_Enpi", "ascetic's_fury" -> TACHI_ENPI, ASCETICS_FURY (the enum's spelling)
            local key = string.upper(wanted):gsub("'", ''):gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
            wsId = xi.weaponskill and xi.weaponskill[key] or nil
            if wsId == nil then
                say(player, string.format('No weapon skill called "%s" (use underscores for spaces, e.g. raging_axe).', arg3))
                return
            end
        end

        tp = when == 'chain' and 0 or math.floor(tp)
        player:setCharVar('SQUAD_WSTP_' .. mate.id, tp)
        player:setCharVar('SQUAD_WS_' .. mate.id, wsId)
        say(player, string.format('%s will use %s %s. Dismiss and call them again to apply it.', mate.name,
            wsId > 0 and wsName(wsId) or 'its best weapon skill',
            tp > 0 and ('at ' .. tp .. ' TP' .. (tp < 1500 and ' (as soon as it has 1000)' or '')) or 'to skillchain with the party'))
        -- (Gambits weapon skill settings) a Gambits setting for the mate's current job comes first: say so
        local okWs, wsSettings = pcall(require, 'modules/custom/lua/squad_ws')
        if okWs and type(wsSettings) == 'table' then
            local okNote, noteText = pcall(wsSettings.legacyNote, player,
                { id = mate.id, mjob = mate.mjob, name = mate.name, jobName = jobNames[mate.mjob] })
            if okNote and noteText then
                say(player, noteText)
            end
        end
        return
    elseif action == 'size' then
        -- Body size, like a player's at character creation. Picked once (part of the look); a GM may still change it.
        local sizes = { small = 1, s = 1, medium = 2, m = 2, large = 3, l = 3 }
        local size = sizes[string.lower(arg2 or '')]
        if size == nil then
            say(player, '!squad size <slot> small | medium | large   (once: the size is for good)')
            return
        end

        local sizeVar = 'SQUAD_SIZE_' .. mate.id
        if player:getCharVar(sizeVar) > 0 and player:getGMLevel() == 0 then
            say(player, string.format('%s\'s size is already set for good.', mate.name))
            return
        end

        player:setCharVar(sizeVar, size)
        say(player, string.format('%s is now %s, for good. Dismiss and call them again to see it.', mate.name, ({ 'small', 'medium', 'large' })[size]))
        return
    elseif action == 'rename' then
        if not validName(arg2) then
            say(player, 'Name must be 3-15 letters.')
            return
        end

        local oldName = mate.name
        mate.name = arg2
        chatSend('RENAME', oldName, arg2)
    else
        usage(player)
        return
    end

    save(player, mate)
end

-- Co-op: a visitor from a friend's world uses !squad for its own squad like anyone else, except that nothing it does
-- goes to this world's squad-chat sidecar (chatSend is silent while its command runs), and the two actions that are
-- about the sidecar are refused with a line (modules/custom/late/coop.lua: xi.coop.blockGuest).
do
    local run = commandObj.onTrigger
    commandObj.onTrigger = function(player, action, ...)
        if not xi.squad.visitor(player) then
            return run(player, action, ...)
        end

        if type(xi.coop.blockGuest) == 'function' and xi.coop.blockGuest(player, 'squad', action) then
            return
        end

        xi.squad.chatMuted = true
        local ok, err = pcall(run, player, action, ...)
        xi.squad.chatMuted = nil
        if not ok then
            error(err, 0)
        end
    end
end

xi.module.registerCommand('squad', commandObj)

-----------------------------------
-- !startergear: the basic level 1 gear for a job (the starter weapon and plain armor)
--   !startergear           you (for the job you are on now) and every one of your squad mates
--   !startergear me        only you
--   !startergear squad     only your squad
-- You get the items in your inventory. Squad mates have their gear saved for their job; it shows up the next time
-- you call them (dismiss and call them again if they are out already). Gear a mate already wears is never replaced.
-----------------------------------
local gearCommand = {}

gearCommand.cmdprops =
{
    permission = 0,
    parameters = 's',
}

local STARTER_SLOT_ORDER = { 0, 4, 5, 6, 7, 8, 10 } -- weapon, head, body, hands, legs, feet, waist (the Monk's White Belt)

local function itemLabel(itemId)
    local info = GetSquadItemInfo(itemId)
    return info.valid and prettyItem(info.name) or ('item ' .. tostring(itemId))
end

local function starterGearForPlayer(player)
    local gear = starterGearFor(player:getMainJob(), player:getMainLvl())
    local added, already = {}, 0

    for _, slot in ipairs(STARTER_SLOT_ORDER) do
        local itemId = gear[slot]
        if itemId ~= nil then
            if player:hasItem(itemId) then
                already = already + 1
            elseif player:getFreeSlotsCount() == 0 then
                say(player, 'Your inventory is full - make some room and use !startergear me again.')
                break
            elseif player:addItem(itemId, 1) then
                added[#added + 1] = itemLabel(itemId)
            end
        end
    end

    if #added == 0 and already == 0 then
        say(player, 'There is no basic level 1 gear for your current job in this game.')
    elseif #added == 0 then
        say(player, string.format('You: you already have all of your starter gear (%d pieces).', already))
    else
        say(player, 'You: added ' .. table.concat(added, ', ') .. (already > 0 and string.format(' (you already had %d more).', already) or '.'))
    end
end

local function starterGearForSquad(player)
    local squad = GetSquad(player:getID())
    if #squad == 0 then
        say(player, 'You have no squad mates yet. Try: !squad new Bob WAR')
        return
    end

    for _, mate in ipairs(squad) do
        mate.equip = mate.equip or {}
        local worn = mate.equip[mate.mjob] or {}
        mate.equip[mate.mjob] = worn

        local added = 0
        for slot, itemId in pairs(starterGearFor(mate.mjob, jobLevel(mate, mate.mjob))) do
            if worn[slot] == nil then
                SetSquadEquip(mate.id, mate.mjob, slot, itemId)
                UnlockSquadItem(player:getID(), itemId) -- basic gear is free for the whole squad
                worn[slot] = itemId
                added = added + 1
            end
        end

        SetSquadEquip(mate.id, mate.mjob, STARTER_MARK, 1)
        worn[STARTER_MARK] = 1

        if added > 0 then
            say(player, string.format('%s: %d starter piece(s) added.', mate.name, added))
        else
            say(player, string.format('%s: already has gear in every starter slot.', mate.name))
        end
    end

    if next(squad) ~= nil then
        say(player, 'Squad gear is saved. Dismiss and call your squad again to see it on them.')
    end
end

gearCommand.onTrigger = function(player, who)
    who = who and string.lower(who) or 'all'

    if who == 'me' then
        starterGearForPlayer(player)
    elseif who == 'squad' then
        starterGearForSquad(player)
    elseif who == 'all' then
        starterGearForPlayer(player)
        starterGearForSquad(player)
    else
        say(player, 'Use: !startergear   or   !startergear me   or   !startergear squad')
    end
end

xi.module.registerCommand('startergear', gearCommand)

-----------------------------------
-- Job behavior for squad mates
--
-- Squad mates spawn using a "template" trust, but the template scripts hand out abilities without checking level
-- (a normal Trust always matches your level). So for every squad mate we replace the template's spawn script with
-- level-aware behavior for the mate's main job, plus the sub job's abilities and spells at the sub level.
-- Spells are limited by level through the spell lists; job abilities are limited here, using the levels below.
-- Names are looked up when the server starts. Any ability or spell this server does not know is skipped and logged
-- as "[squad] unknown ...", so a wrong name never breaks a spawn.
-----------------------------------

-- The level job abilities are checked against: the main level for the main job, the sub level for the sub job
local profileLevel = 1

-- A gambit condition from a condition type and an optional argument (an effect name like 'HASTE', or a number)
local function cond(condition, arg)
    local value = 0
    if type(arg) == 'string' then
        value = xi.effect[arg]
        if value == nil then
            print(string.format('[squad] unknown effect %s - skipped', arg))
            return nil
        end
    elseif arg ~= nil then
        value = arg
    end

    return { condition, value }
end

-- Two conditions that must both be true
local function both(first, second)
    if first == nil or second == nil then
        return nil
    end

    return { first, second }
end

local function spell(name)
    local id = xi.magic.spell[name]
    if id == nil then
        print(string.format('[squad] unknown spell %s - skipped', name))
        return nil
    end

    return { ai.r.MA, ai.s.SPECIFIC, id }
end

local function family(name)
    local id = xi.magic.spellFamily[name]
    if id == nil then
        print(string.format('[squad] unknown spell family %s - skipped', name))
        return nil
    end

    return { ai.r.MA, ai.s.HIGHEST, id }
end

-----------------------------------
-- Roles and modes (v1.5)
--
-- Every gambit of a squad mate goes through addGambit below. The mate's ROLE decides which kinds of gambit it keeps, and its MODE
-- decides how early it heals and how much mana it holds back. "auto" and "balanced" change nothing at all.
--   tank     keeps Provoke, Sentinel, Holy Circle, Third Eye, Yonin, Flash and its own buffs. Heals only when someone is in real trouble.
--            Never uses Berserk, Last Resort or Aggressor (they trade defense or evasion for damage), not even from a Rule Set.
--   damage   keeps attacks, nukes, ranged attacks and its own buffs. Heals only when someone is in real trouble.
--   healer   keeps cures, status removal and buffs for the party. Does not nuke, shoot or weaken the enemy.
--   support  keeps buffs, weakening spells, status removal and normal cures. Does not nuke.
--   aggressive heals earlier (+15% HP) and holds nothing back.   conserve heals later (-15% HP) and keeps 40% mana in reserve.
-- A role and a mode are stored on your character (SQUAD_AI_<mate id>), set with !squad role / !squad mode, and read when the mate is called.
-----------------------------------
local EMERGENCY_HP    = { tank = 40, damage = 30 }
local CONSERVE_MP     = 40
local MODE_HEAL_SHIFT = { aggressive = 15, conserve = -15 }

-- Which kind each spell, spell family and job ability is. Anything not listed counts as 'other' (spells) or 'meleeja' (abilities).
local CATEGORY_NAMES =
{
    family =
    {
        heal   = { 'CURE' },
        buff   = { 'HASTE', 'PHALANX', 'PROTECT', 'PROTECTRA', 'SHELL', 'SHELLRA', 'MARCH', 'VALOR_MINUET', 'UTSUSEMI' },
        debuff = { 'DIA', 'DISTRACT', 'HOJO', 'KURAYAMI', 'PARALYZE', 'SLOW' },
        nuke   = { 'BANISH' },
    },
    spell =
    {
        heal    = { 'CURE' },
        cleanse = { 'BLINDNA', 'CURSNA', 'ERASE', 'PARALYNA', 'POISONA', 'SILENA', 'STONA', 'VIRUNA' },
        buff    = { 'ENFIRE', 'REFRESH' },
        debuff  = { 'FLASH' },
        nuke    = { 'ASPIR', 'DRAIN', 'STONE' },
    },
    ja =
    {
        tankja  = { 'PROVOKE', 'SENTINEL', 'HOLY_CIRCLE', 'THIRD_EYE', 'YONIN' },
        dpsja   = { 'BERSERK', 'LAST_RESORT', 'AGGRESSOR' }, -- (2026-11-22, levi) lower defense/evasion: not for a tank
        utility = { 'CONVERT', 'CHAKRA' },
    },
}

-- What each role does with each kind: true keeps it, false drops it, 'emergency' keeps it but only for a badly hurt target, 'self' keeps it only on the mate itself
local ROLE_KEEPS =
{
    heal    = { tank = 'emergency', damage = 'emergency', healer = true,  support = true },
    cleanse = { tank = false,       damage = false,       healer = true,  support = true },
    buff    = { tank = 'self',      damage = 'self',      healer = true,  support = true },
    debuff  = { tank = true,        damage = true,        healer = false, support = true },
    nuke    = { tank = false,       damage = true,        healer = false, support = false },
    ranged  = { tank = false,       damage = true,        healer = false, support = true },
    tankja  = { tank = true,        damage = false,       healer = false, support = false },
    meleeja = { tank = true,        damage = true,        healer = false, support = false },
    dpsja   = { tank = false,       damage = true,        healer = false, support = false },
}

local categoryIds = nil

local function buildCategoryIds()
    categoryIds = { family = {}, spell = {}, ja = {} }
    local sources = { family = xi.magic.spellFamily, spell = xi.magic.spell, ja = xi.ja }
    for kind, byCategory in pairs(CATEGORY_NAMES) do
        for category, names in pairs(byCategory) do
            for _, name in ipairs(names) do
                local id = sources[kind][name]
                if id ~= nil then
                    categoryIds[kind][id] = category
                end
            end
        end
    end
end

-- The kind of a gambit, from its action
local function classify(action)
    if categoryIds == nil then
        buildCategoryIds()
    end

    local reaction, selector, id = action[1], action[2], action[3]
    if reaction == ai.r.JA then
        return categoryIds.ja[id] or 'meleeja'
    end

    if reaction == ai.r.RATTACK then
        return 'ranged'
    end

    if reaction == ai.r.MA then
        if selector == ai.s.MB_ELEMENT or (ai.s.BEST_AGAINST_TARGET ~= nil and selector == ai.s.BEST_AGAINST_TARGET) then
            return 'nuke'
        end

        if selector == ai.s.HIGHEST then
            if id == xi.magic.spellFamily.NONE then
                return 'nuke'
            end

            return categoryIds.family[id] or 'other'
        end

        return categoryIds.spell[id] or 'other'
    end

    return 'other'
end

-- A condition is { condition, value }, or a pair of those (see both). Changes the "HP below" threshold, wherever it is.
local function mapHeal(condition, change)
    if type(condition[1]) == 'table' then
        return { mapHeal(condition[1], change), mapHeal(condition[2], change) }
    end

    if condition[1] == ai.c.HPP_LT then
        return { ai.c.HPP_LT, change(condition[2]) }
    end

    return condition
end

-- Adds "mana at least floor%" to a condition, or raises the one it already has. A pair of other conditions is left alone.
local function withMpFloor(condition, floor)
    if type(condition[1]) == 'table' then
        local first, second = condition[1], condition[2]
        if first[1] == ai.c.MPP_GTE then
            return { { ai.c.MPP_GTE, math.max(first[2], floor) }, second }
        end

        if second[1] == ai.c.MPP_GTE then
            return { first, { ai.c.MPP_GTE, math.max(second[2], floor) } }
        end

        return condition
    end

    if condition[1] == ai.c.MPP_GTE then
        return { ai.c.MPP_GTE, math.max(condition[2], floor) }
    end

    return { condition, { ai.c.MPP_GTE, floor } }
end

-- One gambit under a role and a mode. Returns keep (true/false) and the possibly changed condition.
local function behaviorFilter(role, mode, target, condition, action)
    local category = classify(action)
    local keeps = ROLE_KEEPS[category] and ROLE_KEEPS[category][role]
    if keeps == false then
        return false, condition
    end

    if keeps == 'self' and target ~= ai.t.SELF then
        return false, condition
    end

    if keeps == 'emergency' then
        local cap = EMERGENCY_HP[role]
        condition = mapHeal(condition, function(value)
            return math.min(value, cap)
        end)
    end

    if category == 'heal' then
        local shift = MODE_HEAL_SHIFT[mode]
        if shift ~= nil then
            condition = mapHeal(condition, function(value)
                return math.max(15, math.min(90, value + shift))
            end)
        end
    elseif mode == 'conserve' and (category == 'buff' or category == 'debuff' or category == 'nuke' or category == 'cleanse') then
        condition = withMpFloor(condition, CONSERVE_MP)
    end

    return true, condition
end

-- Set while a mate's behavior is being built (see squadSpawn). Nil, or "auto" and "balanced", mean no change.
local activeBehavior = nil

-- Ditto for the on/off switches: nil means every kind of action is allowed.
local activeSwitches = nil

-- The switch that guards an action, or nil for actions no switch covers (weapon skills belong to the trust template, not to us).
local function switchForAction(action)
    local reaction = action[1]
    if reaction == ai.r.MA then
        return 'magic'
    elseif reaction == ai.r.JA then
        return 'ja'
    elseif reaction == ai.r.RATTACK then
        return 'ranged'
    end

    return nil
end

local function addGambit(mob, target, condition, action, retry)
    if condition == nil or action == nil then
        return
    end

    -- (Gambits v2 U13) a player's squad mate uses a job ability only as a player could: its main or sub job at the
    -- level, never a two-hour or main-job-only ability from the sub job, and a merit ability only with the merit unlocked
    -- by its owner. One rule for the built-in, launcher-edited and Rule Set rules (squad_ability_rules.lua). A bot's
    -- profile (xi.squad.profileFor: no player owner) is not checked here. Without the rules file: fail closed.
    if action[1] == ai.r.JA and action[2] == ai.s.SPECIFIC then
        local okAr, abilityRules = pcall(require, 'modules/custom/lua/squad_ability_rules')
        if okAr and type(abilityRules) == 'table' then
            if not abilityRules.allowGambit(mob, action[3]) then
                return
            end
        elseif type(mob:getMaster()) == 'userdata' or type(mob:getMaster()) == 'table' then
            return
        end
    end

    if activeSwitches ~= nil then
        local needed = switchForAction(action)
        if needed ~= nil and not hasBit(activeSwitches, SW_BIT[needed]) then
            return
        end
    end

    -- (2026-11-22, levi) a tank's Rule Set is otherwise untouched by its role, but still never Berserks (see squadSpawn)
    if activeBehavior ~= nil and activeBehavior.ruleSet then
        if classify(action) == 'dpsja' then
            return
        end
    elseif activeBehavior ~= nil and (activeBehavior.role ~= 'auto' or activeBehavior.mode ~= 'balanced') then
        local keep, adjusted = behaviorFilter(activeBehavior.role, activeBehavior.mode, target, condition, action)
        if not keep then
            return
        end

        condition = adjusted
    end

    if retry ~= nil then
        mob:addGambit(target, condition, action, retry)
    else
        mob:addGambit(target, condition, action)
    end
end

-- Adds a job ability gambit if the mate's level for that job allows it
local function addJA(mob, minLevel, jaName, target, condition, arg)
    if profileLevel < minLevel then
        return
    end

    local jaId = xi.ja[jaName]
    if jaId == nil then
        print(string.format('[squad] unknown job ability %s - skipped', jaName))
        return
    end

    addGambit(mob, target, cond(condition, arg), { ai.r.JA, ai.s.SPECIFIC, jaId })
end

-- Each job has three parts: ja (job abilities), magic (spells), stance (stat tweaks and where it stands).
-- As a sub job only ja and magic are used, at the sub level.
local jobs = {}

-- Warrior: Provoke 5, Berserk 15, Warcry 35, Aggressor 45
jobs[jobIds.WAR] =
{
    ja = function(mob)
        addJA(mob, 5, 'PROVOKE', ai.t.SELF, ai.c.NOT_HAS_TOP_ENMITY, 0)
        addJA(mob, 15, 'BERSERK', ai.t.SELF, ai.c.NOT_STATUS, 'BERSERK')
        addJA(mob, 35, 'WARCRY', ai.t.SELF, ai.c.NOT_STATUS, 'WARCRY')
        addJA(mob, 45, 'AGGRESSOR', ai.t.SELF, ai.c.NOT_STATUS, 'AGGRESSOR')
    end,
}

-- Monk: Boost 5, Dodge 15, Focus 25, Chakra 35, Counterstance 45
jobs[jobIds.MNK] =
{
    ja = function(mob)
        addJA(mob, 5, 'BOOST', ai.t.SELF, ai.c.NOT_STATUS, 'BOOST')
        addJA(mob, 15, 'DODGE', ai.t.SELF, ai.c.ALWAYS, 0)
        addJA(mob, 25, 'FOCUS', ai.t.SELF, ai.c.ALWAYS, 0)
        addJA(mob, 35, 'CHAKRA', ai.t.SELF, ai.c.HPP_LT, 50)
        addJA(mob, 45, 'COUNTERSTANCE', ai.t.SELF, ai.c.HAS_TOP_ENMITY, 0)
    end,
}

-- White Mage: cures, status removal and buffs
jobs[jobIds.WHM] =
{
    magic = function(mob)
        addGambit(mob, ai.t.PARTY, cond(ai.c.HPP_LT, 25), family('CURE'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'SLEEP_I'), spell('CURE'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'SLEEP_II'), spell('CURE'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.HPP_LT, 75), family('CURE'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.NOT_STATUS, 'PROTECT'), family('PROTECTRA'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.NOT_STATUS, 'SHELL'), family('SHELLRA'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'POISON'), spell('POISONA'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'PARALYSIS'), spell('PARALYNA'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'BLINDNESS'), spell('BLINDNA'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'SILENCE'), spell('SILENA'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'PETRIFICATION'), spell('STONA'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'DISEASE'), spell('VIRUNA'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS, 'CURSE_I'), spell('CURSNA'))
        addGambit(mob, ai.t.SELF, cond(ai.c.STATUS_FLAG, xi.effectFlag.ERASABLE), spell('ERASE'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS_FLAG, xi.effectFlag.ERASABLE), spell('ERASE'))
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'PARALYSIS'), family('PARALYZE'), 60)
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'SLOW'), family('SLOW'), 60)
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'FLASH'), spell('FLASH'), 60)
        -- Now and then, after everything above: Dia (never when the mob already has it) and Banish, keeping MP for cures
        addGambit(mob, ai.t.TARGET, both(cond(ai.c.MPP_GTE, 40), cond(ai.c.NOT_STATUS, 'DIA')), family('DIA'), 60)
        addGambit(mob, ai.t.TARGET, cond(ai.c.MPP_GTE, 50), family('BANISH'), 30)
    end,
    stance = function(mob)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.NO_MOVE)
    end,
}

-- Black Mage: magic bursts and the strongest nuke available. As a sub job it only nukes with plenty of MP left.
jobs[jobIds.BLM] =
{
    -- Elemental Seal 15: on a magic burst (the burst itself is the first magic rule)
    ja = function(mob)
        addJA(mob, 15, 'ELEMENTAL_SEAL', ai.t.SELF, ai.c.MB_AVAILABLE, 0)
    end,
    magic = function(mob, isSub)
        addGambit(mob, ai.t.TARGET, both(cond(ai.c.MPP_GTE, isSub and 60 or 0), cond(ai.c.MB_AVAILABLE, 0)), { ai.r.MA, ai.s.MB_ELEMENT, xi.magic.spellFamily.NONE })
        -- (2026-11-20, Altair: a level 12 BLM cast once a fight or not at all) the last number is the wait before this rule
        -- may fire again, and 60 seconds is longer than most fights. A Black Mage nukes every 12 seconds now, MP allowing;
        -- as a sub job it stays at 60.
        addGambit(mob, ai.t.TARGET, both(cond(ai.c.MPP_GTE, isSub and 60 or 0), cond(ai.c.NOT_SC_AVAILABLE, 0)), { ai.r.MA, ai.s.BEST_AGAINST_TARGET, 0 }, isSub and 60 or 12)
    end,
    stance = function(mob)
        local power = mob:getMainLvl() / 10
        mob:addMod(xi.mod.MATT, power)
        mob:addMod(xi.mod.MACC, power)
        mob:addMod(xi.mod.HASTE_MAGIC, 1000) -- 10% haste (magic)

        mob:setAutoAttackEnabled(false)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.NO_MOVE)
    end,
}

-- Red Mage: heals, buffs itself and you, and slows or weakens the enemy. Convert at 40.
jobs[jobIds.RDM] =
{
    ja = function(mob)
        addJA(mob, 40, 'CONVERT', ai.t.SELF, ai.c.MPP_LT, 25)
    end,
    magic = function(mob)
        addGambit(mob, ai.t.PARTY, cond(ai.c.HPP_LT, 50), family('CURE'))
        -- 15s, not 60s: the retry timer is global across targets, so a full minute made him skip
        -- every new mob after the first Dia. The NOT_STATUS check still stops him recasting on one mob.
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'DIA'), family('DIA'), 15) -- Dia from level 1 (Dia II at 31)
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'HASTE'), family('HASTE'))
        addGambit(mob, ai.t.MASTER, cond(ai.c.NOT_STATUS, 'HASTE'), family('HASTE'))
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'REFRESH'), spell('REFRESH'))
        addGambit(mob, ai.t.MASTER, cond(ai.c.NOT_STATUS, 'REFRESH'), spell('REFRESH'))
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'PHALANX'), family('PHALANX'))
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'ENFIRE'), spell('ENFIRE'))
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'EVASION_DOWN'), family('DISTRACT'), 60)
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'SLOW'), family('SLOW'), 60)
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'PARALYSIS'), family('PARALYZE'), 60)
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'PROTECT'), family('PROTECT'))
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'SHELL'), family('SHELL'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.NOT_STATUS, 'PROTECT'), family('PROTECT'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.NOT_STATUS, 'SHELL'), family('SHELL'))
        -- A skillchain just landed: magic burst it (with MP to spare for cures)
        addGambit(mob, ai.t.TARGET, both(cond(ai.c.MPP_GTE, 30), cond(ai.c.MB_AVAILABLE, 0)), { ai.r.MA, ai.s.MB_ELEMENT, xi.magic.spellFamily.NONE })
        -- Now and then, after everything above: the best elemental spell the mob is weakest to, keeping MP for the rest
        addGambit(mob, ai.t.TARGET, cond(ai.c.MPP_GTE, 50), { ai.r.MA, ai.s.BEST_AGAINST_TARGET, 0 }, 30)
    end,
    stance = function(mob)
        -- Red Mages fight up close and cast between swings. With the melee switch off (!squad sw / the panel),
        -- the melee-off rule below still sends him to casting range.
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.MELEE)
    end,
}

-- Thief: Sneak Attack and Trick Attack are handled by squadThiefTick below (main THF or /THF), the rest is melee
jobs[jobIds.THF] = {}

-- Squad thieves (main or sub THF), every tick: Sneak Attack from behind the target, Trick Attack from behind
-- whoever the target is fighting. SQUAD_FLANK tells the trust controller where to stand (1 behind the target,
-- 2 behind the tank); it is cleared once the hit lands or the fight ends. (global: squad.lua is at the local limit)
function squadThiefTick(mob)
    local lvl = 0
    if mob:getMainJob() == jobIds.THF then
        lvl = mob:getMainLvl()
    elseif mob:getSubJob() == jobIds.THF then
        lvl = mob:getSubLvl()
    end

    local flank  = 0
    local target = mob:isEngaged() and mob:getTarget() or nil
    -- (job expansion) the mate's Rule Set uses Sneak/Trick Attack: it decides when; here only the position is kept
    if mob:getLocalVar('SQUAD_SATA_MANAGED') ~= 0 then
        local okJ, J = pcall(require, 'modules/custom/lua/squad_jobs')
        if okJ and type(J) == 'table' then
            flank = J.thiefManaged(mob, lvl, target, os.time())
            if mob:getLocalVar('SQUAD_FLANK') ~= flank then
                mob:setLocalVar('SQUAD_FLANK', flank)
            end

            return
        end
    end

    if lvl >= 15 and target ~= nil and target:isAlive() then
        local tank     = target:getTarget()
        local tanking  = tank ~= nil and tank:getID() == mob:getID() -- (the target faces us: no getting behind it)
        local otherTank = tank ~= nil and not tanking and tank:isAlive()
        local now      = os.time()
        local tryJA    = now - mob:getLocalVar('SQUAD_THF_T') >= 3

        if mob:hasStatusEffect(xi.effect.SNEAK_ATTACK) then
            flank = tanking and 0 or 1
        elseif mob:hasStatusEffect(xi.effect.TRICK_ATTACK) then
            flank = (otherTank and mob:checkDistance(target) <= 4) and 2 or 0 -- (too far to swing from there: go in)
        elseif not tanking and not mob:hasRecast(xi.recast.ABILITY, xi.jobAbility.SNEAK_ATTACK) then -- Sneak Attack ready (trust recasts are kept by ability id)
            flank = 1
            if tryJA and mob:isBehind(target) and mob:checkDistance(target) < 4 then
                mob:setLocalVar('SQUAD_THF_T', now)
                SquadUseAbility(mob:getMaster(), mob, xi.jobAbility.SNEAK_ATTACK)
            end
        elseif lvl >= 30 and otherTank and not mob:hasRecast(xi.recast.ABILITY, xi.jobAbility.TRICK_ATTACK) then -- Trick Attack ready (trust recasts are kept by ability id)
            flank = 2
            if tryJA and mob:checkDistance(tank) < 2 and mob:checkDistance(target) <= 4 and target:checkDistance(tank) < target:checkDistance(mob) then
                mob:setLocalVar('SQUAD_THF_T', now)
                SquadUseAbility(mob:getMaster(), mob, xi.jobAbility.TRICK_ATTACK)
            end
        end
    end

    if mob:getLocalVar('SQUAD_FLANK') ~= flank then
        mob:setLocalVar('SQUAD_FLANK', flank)
    end
end

-- Paladin: Holy Circle 5, Sentinel 30; Flash and Cure come from the spell list
jobs[jobIds.PLD] =
{
    ja = function(mob)
        addJA(mob, 5, 'HOLY_CIRCLE', ai.t.SELF, ai.c.NOT_STATUS, 'HOLY_CIRCLE')
        addJA(mob, 30, 'SENTINEL', ai.t.SELF, ai.c.NOT_STATUS, 'SENTINEL')
    end,
    magic = function(mob)
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'FLASH'), spell('FLASH'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.HPP_LT, 75), family('CURE'))
    end,
}

-- Dark Knight: Arcane Circle 5, Last Resort 15, Souleater 30; Drain heals when hurt, Aspir restores MP
jobs[jobIds.DRK] =
{
    ja = function(mob)
        addJA(mob, 5, 'ARCANE_CIRCLE', ai.t.SELF, ai.c.NOT_STATUS, 'ARCANE_CIRCLE')
        addJA(mob, 15, 'LAST_RESORT', ai.t.SELF, ai.c.NOT_STATUS, 'LAST_RESORT')
        addJA(mob, 30, 'SOULEATER', ai.t.SELF, ai.c.NOT_STATUS, 'SOULEATER')
    end,
    magic = function(mob)
        addGambit(mob, ai.t.TRIGGER_SELF_ACTION_TARGET, cond(ai.c.HPP_LT, 75), spell('DRAIN'), 30)
        addGambit(mob, ai.t.TRIGGER_SELF_ACTION_TARGET, cond(ai.c.MPP_LT, 50), spell('ASPIR'), 60)
    end,
}

-- Beastmaster: Courier Carrie is called by the pet loop; charm and jug items are not supported yet.
-- Aamr is the BST trust template: its axe TP settings are reused, while the pet's own Jug_Crab skills are
-- enabled on the C++ side (see petutils::SpawnPet).
jobs[jobIds.BST] =
{
    ja = function(mob)
        mob:setTrustTPSkillSettings(ai.tp.ASAP, ai.s.HIGHEST, 1000)
    end,
}

-- Bard: Minuet and March for you and the party, ranged attacks from a distance
-- (2026-11-19, user) A bard picks its two songs for the party it plays in (looked at when it is called):
--   mostly casters: Mage's Ballad + Minuet; no healer: Knight's Minne + Army's Paeon; otherwise Minuet + March.
--   A song it doesn't know yet is skipped for the next one in the list (Minne 1, Minuet 3, Paeon 5, Ballad 25,
--   March 29). Era bards hold two songs. On the monster: Battlefield Elegy (39) then Foe Requiem (7).
--   Bots build their list without a party, so they get the Minuet + March list.
SQUAD_BRD_SONGS =
{
    caster   = { 'BALLAD', 'MINUET', 'PAEON', 'MINNE' },
    nohealer = { 'MINNE', 'PAEON', 'MINUET' },
    melee    = { 'MINUET', 'MARCH', 'PAEON', 'MINNE' },
}
SQUAD_BRD_SONG_INFO =
{
    MINNE  = { level = 1,  effect = 'MINNE',  family = 'KNIGHTS_MINNE' },
    MINUET = { level = 3,  effect = 'MINUET', family = 'VALOR_MINUET' },
    PAEON  = { level = 5,  effect = 'PAEON',  family = 'ARMYS_PAEON' },
    BALLAD = { level = 25, effect = 'BALLAD', family = 'MAGES_BALLAD' },
    MARCH  = { level = 29, effect = 'MARCH',  family = 'MARCH' },
}

function squadBardParty(mob)
    local ok, kind = pcall(function()
        local master = mob:getMaster()
        if type(master) ~= 'userdata' then
            return 'melee'
        end

        local casters, melee, healer, tank = 0, 0, false, false
        local members = master:getPartyWithTrusts() or {}
        for _, m in pairs(members) do
            if m:getID() ~= mob:getID() then
                local j = m:getMainJob()
                if j == 3 or j == 4 or j == 5 or j == 15 or j == 20 or j == 21 then
                    casters = casters + 1
                else
                    melee = melee + 1
                end
                healer = healer or j == 3 or j == 5 or j == 20
                tank = tank or j == 1 or j == 7 or j == 13
            end
        end

        if casters > 0 and casters >= melee then
            return 'caster'
        elseif not healer and tank then
            return 'nohealer'
        end

        return 'melee'
    end)
    return ok and kind or 'melee'
end

jobs[jobIds.BRD] =
{
    magic = function(mob)
        local picked = 0
        for _, name in ipairs(SQUAD_BRD_SONGS[squadBardParty(mob)]) do
            local song = SQUAD_BRD_SONG_INFO[name]
            if picked < 2 and profileLevel >= song.level then
                addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, song.effect), family(song.family))
                picked = picked + 1
            end
        end

        if profileLevel >= 39 then
            addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'ELEGY'), family('ELEGY'), 30)
        end
        if profileLevel >= 7 then
            addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'REQUIEM'), family('FOE_REQUIEM'), 30)
        end
        -- (2026-11-19, Yache, ticket kupo-4: with a bard out, monsters went unclaimed and stood still) the bard's
        -- "ranged attack every minute" is gone: its ranged slot holds an instrument, not a weapon. It was harmless
        -- until 0.1.46 made squad mates' ranged weapons real; from then on the bard really fired its flute.
    end,
    stance = function(mob)
        mob:setAutoAttackEnabled(false)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.MID_RANGE)
    end,
}

-- Ranger: Sharpshot 20, fires often from a distance
jobs[jobIds.RNG] =
{
    ja = function(mob)
        addJA(mob, 20, 'SHARPSHOT', ai.t.SELF, ai.c.NOT_STATUS, 'SHARPSHOT')
        addGambit(mob, ai.t.TARGET, cond(ai.c.ALWAYS, 0), { ai.r.RATTACK, 0, 0 }, 10)
    end,
    stance = function(mob)
        mob:setAutoAttackEnabled(false)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.LONG_RANGE)
    end,
}

-- Samurai: Third Eye 15, Hasso 25, Meditate 30
jobs[jobIds.SAM] =
{
    ja = function(mob)
        addJA(mob, 15, 'THIRD_EYE', ai.t.SELF, ai.c.HAS_TOP_ENMITY, 0)
        addJA(mob, 25, 'HASSO', ai.t.SELF, ai.c.NOT_STATUS, 'HASSO')
        addJA(mob, 30, 'MEDITATE', ai.t.SELF, ai.c.TP_LT, 1000)
    end,
}

-- Ninja: Yonin 40 when holding the enemy's attention; shadows, blind and slow from the spell list
jobs[jobIds.NIN] =
{
    ja = function(mob)
        addJA(mob, 40, 'YONIN', ai.t.SELF, ai.c.HAS_TOP_ENMITY, 0)
    end,
    magic = function(mob)
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'COPY_IMAGE'), family('UTSUSEMI'))
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'BLINDNESS'), family('KURAYAMI'), 30)
        addGambit(mob, ai.t.TARGET, cond(ai.c.NOT_STATUS, 'SLOW'), family('HOJO'), 30)
    end,
}

-- Dragoon: Jump 1, Ancient Circle 5 (against dragons), High Jump 35, Super Jump 50; the pet loop calls the wyvern.
-- Shikaree Z is the DRG trust template: its polearm TP settings and WHM-sub support spells are reused here.
jobs[jobIds.DRG] =
{
    ja = function(mob)
        addJA(mob, 5, 'ANCIENT_CIRCLE', ai.t.TARGET, ai.c.IS_ECOSYSTEM, xi.ecosystem.DRAGON)
        addJA(mob, 1, 'JUMP', ai.t.TARGET, ai.c.ALWAYS, 0)
        addJA(mob, 35, 'HIGH_JUMP', ai.t.TARGET, ai.c.ALWAYS, 0)
        addJA(mob, 50, 'SUPER_JUMP', ai.t.SELF, ai.c.HAS_TOP_ENMITY, 0)
        mob:setTrustTPSkillSettings(ai.tp.CLOSER_UNTIL_TP, ai.s.HIGHEST, 2000)
    end,
    magic = function(mob)
        -- Only a DRG/WHM has these spells; a DRG/WAR simply skips the block.
        if mob:getSubJob() ~= jobIds.WHM then
            return
        end

        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'HASTE'), family('HASTE'))
        addGambit(mob, ai.t.SELF, cond(ai.c.STATUS_FLAG, xi.effectFlag.ERASABLE), spell('ERASE'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.STATUS_FLAG, xi.effectFlag.ERASABLE), spell('ERASE'))
        addGambit(mob, ai.t.PARTY, cond(ai.c.HPP_LT, 50), family('CURE'))
    end,
}

-- Summoner: Carbuncle is called by the pet loop; Blood Pacts and the other avatars are not supported yet
jobs[jobIds.SMN] = {}

-- Blue Mage (v1.17): fights with a sword and casts blue magic between swings - its cures and defences first, then
-- the two strongest physical spells its level has. A squad Blue Mage knows every blue spell of its level (no
-- hunting for them, no set points). There is no Blue Mage trust to borrow, so it uses the plain body template.
jobs[jobIds.BLU] =
{
    magic = function(mob)
        addGambit(mob, ai.t.PARTY, cond(ai.c.HPP_LT, 50), spell('MAGIC_FRUIT'))              -- 58
        addGambit(mob, ai.t.PARTY, cond(ai.c.HPP_LT, 50), spell('WILD_CARROT'))              -- 30
        addGambit(mob, ai.t.SELF, cond(ai.c.HPP_LT, 50), spell('HEALING_BREEZE'))            -- 16
        addGambit(mob, ai.t.SELF, cond(ai.c.HPP_LT, 50), spell('POLLEN'))                    -- 1
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'DEFENSE_BOOST'), spell('COCOON'))   -- 8
        addGambit(mob, ai.t.SELF, cond(ai.c.NOT_STATUS, 'STONESKIN'), spell('METALLIC_BODY')) -- 8

        -- (only two attack spells, each on its own timer: with all of them listed it would cast without a pause)
        local attacks = { { 38, 'JET_STREAM' }, { 38, 'UPPERCUT' }, { 26, 'SCREWDRIVER' }, { 18, 'BLUDGEON' }, { 12, 'HEAD_BUTT' },
                          { 12, 'BATTLE_DANCE' }, { 4, 'POWER_ATTACK' }, { 4, 'SPROUT_SMACK' }, { 4, 'WILD_OATS' } }
        local used = 0
        for _, a in ipairs(attacks) do
            if used < 2 and profileLevel >= a[1] then
                used = used + 1
                addGambit(mob, ai.t.TARGET, cond(ai.c.MPP_GTE, 30), spell(a[2]), used == 1 and 20 or 35)
            end
        end
    end,
    stance = function(mob)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.MELEE)
    end,
}

-- Corsair (v1.17): Corsair's Roll (more experience for the party) from 5, and one fighting roll - Hunter's Roll
-- (accuracy) from 11, Chaos Roll (attack) from 14. Only two: a third roll would push the first one off, for ever.
-- It fights up close and fires when it has something to fire.
jobs[jobIds.COR] =
{
    ja = function(mob)
        addJA(mob, 5, 'CORSAIRS_ROLL', ai.t.SELF, ai.c.NOT_STATUS, 'CORSAIRS_ROLL')
        if profileLevel >= 14 then
            addJA(mob, 14, 'CHAOS_ROLL', ai.t.SELF, ai.c.NOT_STATUS, 'CHAOS_ROLL')
        else
            addJA(mob, 11, 'HUNTERS_ROLL', ai.t.SELF, ai.c.NOT_STATUS, 'HUNTERS_ROLL')
        end

        addGambit(mob, ai.t.TARGET, cond(ai.c.ALWAYS, 0), { ai.r.RATTACK, 0, 0 }, 15)
    end,
    stance = function(mob)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.MELEE)
    end,
}

-- Puppetmaster (v1.17): hand-to-hand, weapon skills as soon as it has the TP. It has NO automaton: the game's
-- automaton belongs to a player character (its frame, head, attachments and skills are read from the character),
-- so a squad mate cannot own one without a change to the pet code itself.
jobs[jobIds.PUP] =
{
    -- (the weapon skill timing sits in stance: an edited PUP rule list from the launcher replaces "ja", 2026-11-17)
    stance = function(mob)
        mob:setTrustTPSkillSettings(ai.tp.ASAP, ai.s.HIGHEST, 1000)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.MELEE)
    end,
}

-----------------------------------
-- Editable job rules (v1.5)
--
-- modules/custom/lua/squad_rules_data.lua (written by the launcher) can replace the rules of a job. For a job it lists, its "ja" (job abilities)
-- and/or "magic" (spells) list is used instead of the built-in one; anything it does not list stays as it is built in. A rule is a table:
--   { on = true, target = 'PARTY', cond = { 'HPP_LT', 25 }, cond2 = { 'MPP_GTE', 10 }, action = { 'family', 'CURE' }, retry = 60, level = 5 }
--   target   SELF, PARTY, MASTER or TARGET                    cond2, retry and level are optional
--   cond     { condition name, argument }: the argument is a number, an effect name (like 'HASTE'), { flag = 'ERASABLE' },
--            { ecosystem = 'DRAGON' }, or { main = 0, sub = 60 } for a different number as a sub job
--   action   { 'spell', NAME } | { 'family', NAME } | { 'ja', NAME } | { 'ranged' } | { 'nuke' } | { 'burst' }
--   level    the least level a job ability needs (spells are limited by the mate's learned spells instead)
-- A rule with anything wrong in it is skipped and logged as "[squad] ...", it never stops the mate from spawning.
-----------------------------------
local rulesOk, rulesData = pcall(require, 'modules/custom/lua/squad_rules_data')
if not rulesOk then
    if not string.find(tostring(rulesData), 'not found', 1, true) then
        print('[squad] squad_rules_data.lua could not be read: ' .. tostring(rulesData))
    end

    rulesData = {}
elseif type(rulesData) ~= 'table' then
    rulesData = {}
end

local function ruleArg(arg, isSub)
    if type(arg) == 'table' then
        if arg.flag ~= nil then
            return xi.effectFlag[arg.flag]
        end

        if arg.ecosystem ~= nil then
            return xi.ecosystem[arg.ecosystem]
        end

        if arg.main ~= nil or arg.sub ~= nil then
            if isSub then
                return arg.sub or 0
            end

            return arg.main or 0
        end
    end

    return arg
end

local function ruleCondition(spec, isSub)
    if type(spec) ~= 'table' then
        return nil
    end

    local id = ai.c[spec[1]]
    if id == nil then
        print(string.format('[squad] unknown condition %s - rule skipped', tostring(spec[1])))
        return nil
    end

    -- (Gambits WAR/PLD/RDM batch) JA_ON_COOLDOWN names a job ability: the engine wants its id (cond would read a name as
    -- a status effect)
    if spec[1] == 'JA_ON_COOLDOWN' then
        local jaId = type(spec[2]) == 'string' and xi.ja[spec[2]] or nil
        if jaId == nil then
            print(string.format('[squad] unknown job ability %s for JA_ON_COOLDOWN - rule skipped', tostring(spec[2])))
            return nil
        end

        return { id, jaId }
    end

    -- (job expansion) MOD_LT: { mod = 'UTSUSEMI', below = 2 } -> the engine's packed argument (squad_rulesets.lua R.modArg)
    if spec[1] == 'MOD_LT' then
        local okR, R = pcall(require, 'modules/custom/lua/squad_rulesets')
        local packed = okR and type(R) == 'table' and R.modArg and R.modArg(spec[2]) or nil
        if packed == nil then
            print(string.format('[squad] MOD_LT needs { mod = UTSUSEMI|BLINK, below = n } - rule skipped'))
            return nil
        end

        return { id, packed }
    end

    return cond(id, ruleArg(spec[2], isSub))
end

local function ruleAction(spec)
    if type(spec) ~= 'table' then
        return nil
    end

    local kind = spec[1]
    if kind == 'spell' then
        return spell(spec[2])
    elseif kind == 'family' then
        return family(spec[2])
    elseif kind == 'ja' then
        local id = xi.ja[spec[2]]
        if id == nil then
            print(string.format('[squad] unknown job ability %s - rule skipped', tostring(spec[2])))
            return nil
        end

        return { ai.r.JA, ai.s.SPECIFIC, id }
    elseif kind == 'ranged' then
        return { ai.r.RATTACK, 0, 0 }
    elseif kind == 'nuke' then
        -- (2026-11-18) the best nuke of the element the monster is weakest to. HIGHEST with no family picked from
        -- every spell without a family, i.e. Shock and Drown (Kennyj2007: a BLM that only cast those). The spell id 0
        -- makes the game always choose by the weakness, at the best tier it knows.
        return { ai.r.MA, ai.s.BEST_AGAINST_TARGET, 0 }
    elseif kind == 'burst' then
        return { ai.r.MA, ai.s.MB_ELEMENT, xi.magic.spellFamily.NONE }
    end

    print(string.format('[squad] unknown action %s - rule skipped', tostring(kind)))
    return nil
end

-- the 2-hour abilities: main job only, so a support job's rules never use them (sparkiie, 2026-11-17). Global:
-- squad.lua is at the local limit.
SQUAD_TWO_HOURS = { MIGHTY_STRIKES = true, HUNDRED_FISTS = true, BENEDICTION = true, MANAFONT = true, CHAINSPELL = true,
    PERFECT_DODGE = true, INVINCIBLE = true, BLOOD_WEAPON = true, FAMILIAR = true, SOUL_VOICE = true, EAGLE_EYE_SHOT = true,
    MEIKYO_SHISUI = true, MIJIN_GAKURE = true, CALL_WYVERN = true, ASTRAL_FLOW = true, AZURE_LORE = true, WILD_CARD = true,
    OVERDRIVE = true }

local function applyRules(mob, rules, isSub)
    for _, rule in ipairs(rules) do
        local subTwoHour = isSub and type(rule) == 'table' and type(rule.action) == 'table' and rule.action[1] == 'ja'
            and SQUAD_TWO_HOURS[tostring(rule.action[2])]
        if type(rule) == 'table' and rule.on ~= false and profileLevel >= (rule.level or 0) and not subTwoHour then
            local target = ai.t[rule.target]
            if target == nil then
                print(string.format('[squad] unknown target %s - rule skipped', tostring(rule.target)))
            else
                local condition = ruleCondition(rule.cond, isSub)
                if condition ~= nil and rule.cond2 ~= nil then
                    condition = both(condition, ruleCondition(rule.cond2, isSub))
                end

                addGambit(mob, target, condition, ruleAction(rule.action), rule.retry)
            end
        end
    end
end

-- Runs one part ('ja' or 'magic') of a job: the edited list if there is one, otherwise the built-in code
local function runPart(mob, jobId, part, isSub)
    local custom = type(rulesData.jobs) == 'table' and rulesData.jobs[jobNames[jobId]]
    if type(custom) == 'table' and custom.enabled ~= false and type(custom[part]) == 'table' then
        applyRules(mob, custom[part], isSub)
        return
    end

    local definition = jobs[jobId]
    if definition ~= nil and definition[part] ~= nil then
        definition[part](mob, isSub)
    end
end

-- A mate's on/off switches, from the number stored on its master
local function switchesForMob(mob)
    local master = mob:getMaster()
    local squadId = mob:getLocalVar('SQUAD_ID')
    if master == nil or squadId == 0 then
        return SW_ALL
    end

    return switchesOf(master, squadId)
end

-- A mate's role and mode, from the number stored on its master
local function behaviorOf(mob)
    local master = mob:getMaster()
    local squadId = mob:getLocalVar('SQUAD_ID')
    if master == nil or squadId == 0 then
        return 'auto', 'balanced'
    end

    return decodeBehavior(master:getCharVar('SQUAD_AI_' .. squadId))
end

-- Runs when a squad mate spawns: the main job at the main level, then the sub job (if any) at the sub level.
-- Returns true if we handled it, false to let the template script run.
local function squadSpawn(mob)
    local main = jobs[mob:getMainJob()]
    if main == nil then
        return false
    end

    local role, mode = behaviorOf(mob)
    local switches = switchesForMob(mob)
    activeBehavior = { role = role, mode = mode }
    activeSwitches = switches

    -- (Gambits v2, milestone 1) a Rule Set chosen for this mate and main job (squad_rulesets.lua) replaces the job
    -- rules of the main AND the sub job, in its own order, untouched by role/mode (the on/off switches still apply).
    -- No set chosen, or the module missing: everything below runs exactly as before.
    local okRs, rulesets = pcall(require, 'modules/custom/lua/squad_rulesets')
    local customSet = okRs and type(rulesets) == 'table' and rulesets.forMob(mob) or nil
    if customSet ~= nil then
        activeBehavior = (role == 'tank') and { role = role, mode = mode, ruleSet = true } or nil
        profileLevel = mob:getMainLvl()
        applyRules(mob, customSet.rules, false)
        if main.stance then
            main.stance(mob)
        end
        -- (job expansion) what the set asks of the squad: managed Sneak/Trick Attack, songs for party roles (squad_jobs.lua)
        pcall(function() require('modules/custom/lua/squad_jobs').analyse(mob, customSet.rules) end)
    else
        pcall(function() require('modules/custom/lua/squad_jobs').analyse(mob, nil) end)
        profileLevel = mob:getMainLvl()
        runPart(mob, mob:getMainJob(), 'ja', false)
        runPart(mob, mob:getMainJob(), 'magic', false)

        if main.stance then
            main.stance(mob)
        end

        local sub = jobs[mob:getSubJob()]
        if sub ~= nil then
            profileLevel = mob:getSubLvl()
            runPart(mob, mob:getSubJob(), 'ja', true)
            runPart(mob, mob:getSubJob(), 'magic', true)
        end
    end

    -- Melee off: the mate swings at nothing and, if its job does not already keep it at a distance, stands at casting range.
    -- Turning melee back on is only done by calling the mate again, so a job that never melees (BLM, WHM) stays that way.
    if not hasBit(switches, SW_BIT.melee) then
        mob:setAutoAttackEnabled(false)
        if mob:getMobMod(xi.mobMod.TRUST_DISTANCE) == 0 then
            mob:setMobMod(xi.mobMod.TRUST_DISTANCE, xi.trust.movementType.MID_RANGE)
        end
    end

    -- (job expansion) the party roles chosen with !squad partyrole, for the engine's Tank/Melee/Mage/Ranged targets
    pcall(function() require('modules/custom/lua/squad_jobs').applyRoles(mob) end)

    -- Engage delay the player chose for this mate (!squad delay), in ms for trust_controller.cpp
    local delayMaster = mob:getMaster()
    if delayMaster then
        mob:setLocalVar('SQUAD_ENGAGE_DELAY', delayMaster:getCharVar('SQUAD_DELAY_' .. mob:getLocalVar('SQUAD_ID')) * 1000)
    end

    -- Combat distance the player chose for this mate (!squad range): 1 melee, 2 mid range, 3 long range; 0 = its job's own
    local rangeMaster = mob:getMaster()
    local rangeChoice = rangeMaster and rangeMaster:getCharVar('SQUAD_RANGE_' .. mob:getLocalVar('SQUAD_ID')) or 0
    if rangeChoice >= 1 and rangeChoice <= 3 then
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, ({ xi.trust.movementType.MELEE, xi.trust.movementType.MID_RANGE,
            xi.trust.movementType.LONG_RANGE })[rangeChoice])
    end

    -- (2026-11-20, Badtouch) a mate you set to mid or long range with a bow, gun or throwing weapon shoots with it.
    -- Only Ranger and Corsair had a ranged-attack rule, so a Thief with a bow at range just stood there. The weapon
    -- is put on after this runs (squad.cpp applyEquipment), so this looks a moment later. Not for a chosen Rule Set
    -- (it has its own rules) or with the Ranged switch off; instruments never count.
    local ownJob = mob:getMainJob()
    if (rangeChoice == 2 or rangeChoice == 3) and customSet == nil and ownJob ~= xi.job.RNG and ownJob ~= xi.job.COR
        and hasBit(switches, SW_BIT.ranged)
        and (role == 'auto' or ROLE_KEEPS.ranged[role] ~= false) then
        local shootCond = cond(ai.c.ALWAYS, 0)
        mob:timer(1500, function(m)
            if m == nil or not m:isAlive() then
                return
            end
            local okSk, skill = pcall(function() return m:getWeaponSkillType(xi.slot.RANGED) end)
            if okSk and (skill == xi.skill.ARCHERY or skill == xi.skill.MARKSMANSHIP or skill == xi.skill.THROWING) then
                m:addGambit(ai.t.TARGET, shootCond, { ai.r.RATTACK, 0, 0 }, 10)
            end
        end)
    end

    activeBehavior = nil
    activeSwitches = nil
    return true
end

local m = Module:new('squad')

-- Every trust script, because a squad mate can spawn from any of them. Normal trusts (no SQUAD_ID) are left exactly as they were.
local templates =
{
   'aaev', 'aagk', 'aahm', 'aamr', 'aatt', 'abenzio', 'abquhbah', 'adelheid', 'ajido-marujido', 'aldo', 'aldo_uc',
   'amchuchu', 'apururu_uc', 'arciela', 'arciela_ii', 'areuhat', 'august', 'ayame', 'ayame_uc', 'babban', 'balamor',
   'brygid', 'chacharoon', 'cherukiki', 'cid', 'cornelia', 'curilla', 'd_shantotto', 'darrcuiln', 'elivira',
   'excenmille', 'excenmille_s', 'fablinix', 'ferreous_coffin', 'flaviria_uc', 'gadalar', 'gessho', 'gilgamesh',
   'halver', 'i_shield_uc', 'ingrid', 'ingrid_ii', 'iroha', 'iroha_ii', 'iron_eater', 'jakoh_uc', 'joachim',
   'karaha-baruha', 'kayeel-payeel', 'king_of_hearts', 'klara', 'koru-moru', 'kukki-chebukki', 'kupipi', 'kupofried',
   'kuyin_hathdenna', 'lehko_habhoka', 'leonoyne', 'lhe_lhangavo', 'lhu_mhakaracca', 'lilisette', 'lilisette_ii',
   'lion', 'lion_ii', 'luzaf', 'maat', 'maat_uc', 'makki-chebukki', 'margret', 'matsui-p', 'maximilian', 'mayakov',
   'mihli_aliapoh', 'mildaurion', 'mnejing', 'monberaux', 'moogle', 'morimar', 'mumor', 'mumor_ii', 'naja_salaheem',
   'naja_uc', 'najelith', 'naji', 'nanaa_mihgo', 'nashmeira', 'nashmeira_ii', 'noillurie', 'ovjang', 'pieuje_uc',
   'prishe', 'prishe_ii', 'qultada', 'rahal', 'rainemard', 'robel-akbel', 'romaa_mihgo', 'rongelouts', 'rosulatia',
   'rughadjeen', 'sakura', 'selh_teus', 'semih_lafihna', 'shantotto', 'shantotto_ii', 'shikaree_z', 'star_sibyl',
   'sylvie_uc', 'tenzen', 'tenzen_ii', 'teodor', 'trion', 'uka_totlihn', 'ullegore', 'ulmia', 'valaineral', 'volker',
   'ygnas', 'yoran-oran_uc', 'zazarg', 'zeid', 'zeid_ii',
}

for _, name in ipairs(templates) do
    local base = 'xi.actions.spells.trust.' .. name

    m:addOverride(base .. '.onMobSpawn', function(mob)
        if mob:getLocalVar('SQUAD_ID') > 0 then
            local master = mob:getMaster()
            if master ~= nil then
                mob:setLocalVar('MASTER_ID', master:getID())
            end

            if squadSpawn(mob) then
                return
            end
        end

        super(mob)
    end)

    -- Squad mates use their own lines instead of the template trust's speeches
    m:addOverride(base .. '.onMobDespawn', function(mob)
        if mob:getLocalVar('SQUAD_ID') == 0 then
            super(mob)
        elseif dialogue.speakOnDespawn then
            speakFromMob(mob, 'despawn')
        end
    end)

    m:addOverride(base .. '.onMobDeath', function(mob)
        if mob:getLocalVar('SQUAD_ID') == 0 then
            super(mob)
        elseif dialogue.speakOnDeath then
            local okPack, saidPack = false, false
            if type(xi.squad.pack) == 'table' then
                okPack, saidPack = pcall(xi.squad.pack.onDown, mob)
            end

            if not (okPack and saidPack) then
                speakFromMob(mob, 'death')
            end
        end
    end)
end

-- Template trust speeches (like Naji's battle cries) are skipped for squad mates, whatever their job
-- (2026-11-21, sparkiie: a Ninja mate's Mijin Gakure did its damage but the mate lived) the ability ends with
-- player:die(), which only works on a player character; for anyone else it only logged a warning. A squad mate (a trust)
-- falls the way a player does: its HP goes to 0 after the blow.
m:addOverride('xi.job_utils.ninja.useMijinGakure', function(player, target, ability, action)
    local dmg = super(player, target, ability, action)
    if player:getObjType() ~= xi.objType.PC and player:isAlive() then
        player:setHP(0)
    end

    return dmg
end)

m:addOverride('xi.trust.message', function(mob, messageOffset)
    if mob:getLocalVar('SQUAD_ID') > 0 then
        return
    end

    return super(mob, messageOffset)
end)

m:addOverride('xi.trust.teamworkMessage', function(mob, teamworkMessages)
    if mob:getLocalVar('SQUAD_ID') > 0 then
        return
    end

    return super(mob, teamworkMessages)
end)

-----------------------------------
-- Experience (v0.3)
--
-- When you gain experience from a kill, each squad mate that is in your party, alive and near the
-- monster earns experience for their own main job, worked out with their own level.
-- Levels gained are saved right away; they apply the next time the mate is called.
-----------------------------------
-- Squad mates earn exp like real party members (user's rule, 2026-11-16):
--   - they count in the party split, for you and for them (2 people = 60% each, 3 = 45%... the era table), and the highest
--     level in the party sets the share, the same as any party;
--   - they get your bonuses too (exp ring / Dedication, Signet, Rhapsodies, gear and food), since their exp is worked out
--     through your character. The ring's bonus is added for them without using up your ring: they see a copy of it.
-- Raise the Rates tab's exp rate for faster leveling; the default stays the Treasures of Aht Urhgan era values.
local warnedProxy = false

-- Your character as the exp calculation sees it for a mate: everything is yours, except that the Dedication (ring) effect is
-- a copy whose cap never runs out and which is never removed.
local function memberForMate(master, ringPower)
    local fakeDedication = nil
    if ringPower ~= nil then
        local power = ringPower
        fakeDedication =
        {
            getPower    = function() return power end,
            getSubPower = function() return 1000000000 end,
            setSubPower = function() end,
        }
    end

    return setmetatable({}, {
        __index = function(_, key)
            if key == 'getStatusEffect' then
                return function(_, effect, ...)
                    if effect == xi.effect.DEDICATION then
                        return fakeDedication
                    end

                    return master:getStatusEffect(effect, ...)
                end
            elseif key == 'delStatusEffect' then
                return function(_, effect, ...)
                    if effect == xi.effect.DEDICATION then
                        return false
                    end

                    return master:delStatusEffect(effect, ...)
                end
            end

            local value = master[key]
            if type(value) == 'function' then
                return function(_, ...)
                    return value(master, ...)
                end
            end

            return value
        end,
    })
end

local function calcForMate(calc, master, mob, mateData)
    local ok, result = pcall(calc, memberForMate(master, mateData.ringPower), mob, mateData)
    if ok then
        return result
    end

    if not warnedProxy then
        warnedProxy = true
        print('[squad] mate exp through the player copy failed (' .. tostring(result) .. '); using the plain calculation')
    end

    -- fallback: your own character; with a ring on, the mate gets no ring bonus and your ring's cap is put back afterwards
    local dedication = master:getStatusEffect(xi.effect.DEDICATION)
    local subPower   = dedication and dedication:getSubPower()
    local ok2, result2 = pcall(calc, master, mob, mateData)
    local current = master:getStatusEffect(xi.effect.DEDICATION)
    if dedication ~= nil and current ~= nil then
        current:setSubPower(subPower)
    end

    if not ok2 then
        print('[squad] exp calculation failed for a mate: ' .. tostring(result2))
        return nil
    end

    return result2
end

local grantSquadExp

local function awardSquadExp(calc, master, mate, mob, data, squadId)
    local level = mate:getMainLvl()

    local mateData = {}
    for key, value in pairs(data) do
        mateData[key] = value
    end

    mateData.memberLevel = level
    mateData.memberTNL = GetSquadExpNeeded(level)

    local result = calcForMate(calc, master, mob, mateData)
    if result == nil or result.exp <= 0 then
        return
    end

    -- The exp rate from the Rates tab (map.EXP_RATE) is applied by the game's core when a player gains exp, so apply it here too
    local expRate = tonumber(xi.settings.map.EXP_RATE) or 1
    local gain    = math.max(math.floor(result.exp * expRate), 0)
    grantSquadExp(master, mate, squadId, gain)
end

-- Gives a mate a set amount of exp for their main job, with the level-up lines and new spells. Also used by Fields/Grounds pages.
grantSquadExp = function(master, mate, squadId, gain)
    if gain <= 0 then
        return
    end

    local outcome = AddSquadExp(squadId, mate:getMainJob(), gain, MAX_LEVEL)
    if outcome.gained > 0 then
        local name = mate:getPacketName()
        master:printToPlayer(string.format('%s reaches level %d!', name, outcome.level))
        if mate:getObjType() == xi.objType.TRUST then
            mate:setLocalVar('SQUAD_RELEVEL', outcome.level) -- (resyncSquad calls them back at it once the fight is over)
            mate:setLocalVar('SQUAD_OWN', outcome.level)
        end
        if type(SquadSyncLevelled) == 'function' then
            SquadSyncLevelled(master, name, outcome.level) -- a Level Sync to this mate follows its new level
        end
        if not xi.squad.visitor(master) then
            chatSend('UPDATE', name, 'level', outcome.level)
        end

        if dialogue.speakOnLevelUp then
            speak(master, name, 'levelup', { level = outcome.level, job = jobTitles[mate:getMainJob()] or '' })
        end

        -- Squad mates learn their job's new spells automatically when they level, no scrolls needed
        local learned = SquadNewSpells(mate:getMainJob(), outcome.level - outcome.gained, outcome.level)
        if #learned > 0 then
            local shown = {}
            for i = 1, math.min(#learned, 8) do
                shown[i] = prettySpellName(learned[i])
            end

            master:printToPlayer(string.format('%s learns: %s%s', name, table.concat(shown, ', '), #learned > 8 and ', ...' or ''), 4, name)
        end
    end
end

-- Zoning takes the Trusts away (the game's rule): the mates who were out come back by themselves in the new area, a
-- moment after you arrive, without the call timer. Through your Mog House (no Trusts inside) they wait for the next area.
m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)

    -- (spells from scrolls) a squad Blue Mage out with you may learn blue magic from what the party defeats
    if not (BotIsBot and BotIsBot(player:getID())) then
        player:addListener('DEFEATED_MOB', 'SQUAD_BLU_LEARN', function(mob)
            if mob == nil or not squadScrollsOn() or not SquadBlueSpellsOf then
                return
            end

            local blus = {}
            for _, trust in ipairs(squadTrusts(player)) do
                if trust:isAlive() and trust:getMainJob() == xi.job.BLU then
                    blus[#blus + 1] = trust
                end
            end

            if #blus == 0 then
                return
            end

            local learned = GetSquadUnlocks(player:getID()) or {}
            for _, sp in ipairs(SquadBlueSpellsOf(mob) or {}) do
                local key = SQUAD_SPELL_KEY + sp.spell
                if sp.level >= 18 and not learned[key] then
                    for _, trust in ipairs(blus) do
                        if trust:getMainLvl() >= sp.level and math.random(100) <= SQUAD_BLUE_LEARN_CHANCE and not learned[key] then
                            UnlockSquadItem(player:getID(), key)
                            learned[key] = true
                            local name = prettySpellName and prettySpellName(sp.name) or sp.name
                            player:printToPlayer(string.format('%s learned the blue magic %s! (from their next call)', trust:getPacketName(), name), xi.msg.channel.SYSTEM_3)
                        end
                    end
                end
            end
        end)
    end

    -- 2026-11-19: the game takes the Trusts away when you are knocked out. When you are back on your feet (a Raise, or the home point) the mates who
    -- were out come back by themselves a few seconds later, without the call timer.
    player:addListener('DEATH', 'SQUAD_DEATH_RETURN', function(dead)
        local diedAt = os.time()
        dead:setLocalVar('SQUAD_DEATH_TOKEN', diedAt)
        local function poll(entity)
            if entity:getLocalVar('SQUAD_DEATH_TOKEN') ~= diedAt or os.time() - diedAt > 1800 then
                return
            end

            if entity:getHP() > 0 then
                entity:setLocalVar('SQUAD_DEATH_TOKEN', 0)
                local seenNow = zoneOut[entity:getID()]
                if seenNow == nil then
                    return
                end

                local back = {}
                for _, mate in ipairs(orderedSquad(entity, GetSquad(entity:getID()))) do
                    local at = seenNow[mate.id]
                    if at ~= nil and at >= diedAt - 90 then
                        back[#back + 1] = mate
                    end
                end

                for index, mate in ipairs(back) do
                    entity:timer(3000 + (index - 1) * CALL_GAP_MS, function(e)
                        if not e:inMogHouse() and not isSummoned(e, mate.id) then
                            callMate(e, mate)
                        end
                    end)
                end

                print(string.format('[squad] %s is back on his feet: %d mate(s) coming back', entity:getName(), #back))
                return
            end

            entity:timer(2000, poll)
        end

        dead:timer(4000, poll)
    end)

    local seen = zoneOut[player:getID()]
    if not zoning or firstLogin or seen == nil then
        return result
    end

    if player:inMogHouse() then
        seen.mh = true
        return result
    end

    zoneOut[player:getID()] = nil
    local now = os.time()
    local back = {}
    for _, mate in ipairs(orderedSquad(player, GetSquad(player:getID()))) do
        local at = seen[mate.id]
        if at ~= nil and (seen.mh or now - at <= 60) then
            back[#back + 1] = mate
        end
    end

    for index, mate in ipairs(back) do
        player:timer(ZONE_WAIT_MS + (index - 1) * CALL_GAP_MS, function(entity)
            if not entity:inMogHouse() and not isSummoned(entity, mate.id) then
                callMate(entity, mate)
            end
        end)
    end

    return result
end)

m:addOverride('xi.experiencePoints.calculate', function(member, mob, data)
    -- (2026-11-21, delukard; Hurami: "the same as squad mates") below level 12 bot players in your party don't split
    -- your exp either: the share is worked out as if only the real players were there (party size and highest level).
    if member:getObjType() == xi.objType.PC and member:getMainLvl() < 12 and BotIsBot and not BotIsBot(member:getID()) then
        local real, highest, hasBot = 0, member:getMainLvl(), false
        for _, p in pairs(member:getParty()) do
            if p:getObjType() == xi.objType.PC and p:getZoneID() == mob:getZoneID() then
                if BotIsBot(p:getID()) then
                    hasBot = true
                else
                    real = real + 1
                    highest = math.max(highest, p:getMainLvl())
                end
            end
        end

        if hasBot then
            local solo = {}
            for key, value in pairs(data) do
                solo[key] = value
            end

            solo.partySize = math.max(1, math.min(tonumber(data.partySize) or 1, real))
            if highest < (tonumber(data.highestMemberLevel) or highest) then
                solo.highestMemberLevel = highest
                solo.highestMemberTNL   = GetSquadExpNeeded(highest)
            end

            data = solo
        end
    end

    -- the squad mates who share this kill: in your party, alive, in the zone and within 100 yalms of the monster
    local sharing = {}
    if member:getObjType() == xi.objType.PC then
        for _, mate in pairs(member:getPartyWithTrusts()) do
            if mate:getObjType() == xi.objType.TRUST then
                local squadId = mate:getLocalVar('SQUAD_ID')
                if
                    squadId > 0 and
                    mate:isAlive() and
                    mate:getZoneID() == mob:getZoneID() and
                    mate:checkDistance(mob) < 100
                then
                    table.insert(sharing, { mate = mate, squadId = squadId })
                end
            end
        end
    end

    if #sharing == 0 then
        return super(member, mob, data)
    end

    -- the party as the game would see it with the mates in it: more people share, and the highest level sets the share
    local shared = {}
    for key, value in pairs(data) do
        shared[key] = value
    end

    -- (user's rule) below level 12 the mates don't split the exp: you get your solo share and so does each mate
    local splitFromLevel = 12
    local splitting = member:getMainLvl() >= splitFromLevel
    if splitting then
        shared.partySize = (tonumber(data.partySize) or 1) + #sharing
    end

    -- read before your own share uses the ring up, so the mates still get it on the kill that ends it
    local ring = member:getStatusEffect(xi.effect.DEDICATION)
    shared.ringPower = ring and ring:getPower() or nil
    for _, entry in ipairs(sharing) do
        local level = entry.mate:getMainLvl()
        if splitting and level > (shared.highestMemberLevel or 0) then
            shared.highestMemberLevel = level
            shared.highestMemberTNL   = GetSquadExpNeeded(level)
        end
    end

    local result = super(member, mob, shared)
    if result == nil then
        return result
    end

    for _, entry in ipairs(sharing) do
        -- once per kill: on its own player's share (this runs for every player in the party near the kill)
        if xi.squad.pays(member, entry.mate) then
            awardSquadExp(super, member, entry.mate, mob, shared, entry.squadId)
        end
    end

    return result
end)

-- This player's own squad mates who are out, alive and in the same zone: { { mate = entity, squadId = n }, ... }
-- (page exp: a second character finishing its page does not pay your mates a second time)
local function activeMates(master)
    local out = {}
    for _, mate in pairs(master:getPartyWithTrusts()) do
        if mate:getObjType() == xi.objType.TRUST then
            local squadId = mate:getLocalVar('SQUAD_ID')
            if squadId > 0 and mate:isAlive() and mate:getZoneID() == master:getZoneID() and xi.squad.pays(master, mate) then
                table.insert(out, { mate = mate, squadId = squadId })
            end
        end
    end

    return out
end

-- For other modules (fov_no_buffs.lua: page exp for squad mates)
xi.squad = xi.squad or {}
xi.squad.activeMates = activeMates

-- Camps for the bot players in your party (bots.lua, 2026-11-17): they hold the same camp as your squad, fight what
-- comes within 20 yalms of it, and one of them can be the puller (!squad pull <bot name>, or the menu's Puller list).
xi.squad.campInfo = function(player)
    local c = camps[player:getID()]
    if c == nil or c.zone ~= player:getZoneID() then
        return nil
    end

    return c
end

xi.squad.campPickFor = function(player)
    local c = camps[player:getID()]
    if c == nil then
        return nil
    end

    local ok, mob = pcall(campPick, player, c)
    return ok and mob or nil
end

xi.squad.campRestOn = function(player)
    return player:getCharVar('SQUAD_CAMP_NOREST') == 0
end

xi.squad.campCountPull = function(player)
    local c = camps[player:getID()]
    if c then
        c.pulls = (c.pulls or 0) + 1
    end
end
xi.squad.grantExp    = function(master, mate, squadId, gain)
    grantSquadExp(master, mate, squadId, math.floor(tonumber(gain) or 0))
end

-- For the bot players (bots_party.lua): the same job profiles the squad mates use, as a list of gambits
-- { target, condition, action } for a main job / level and sub job / level. Nothing is spawned or changed.
xi.squad = xi.squad or {}
xi.squad.profileFor = function(mainJob, mainLvl, subJob, subLvl)
    local recorder = { list = {} }
    function recorder:addGambit(target, condition, action)
        self.list[#self.list + 1] = { target = target, condition = condition, action = action }
    end
    -- the job profiles also tune the mate itself (setTrustTPSkillSettings and the like): nothing to record for a bot,
    -- so any other method is a quiet no-op instead of an error that cut the bot's list short
    setmetatable(recorder, { __index = function()
        return function() return 0 end
    end })

    local savedBehavior, savedSwitches, savedLevel = activeBehavior, activeSwitches, profileLevel
    activeBehavior, activeSwitches = nil, nil
    local ok, err = pcall(function()
        if jobs[mainJob] ~= nil then
            profileLevel = mainLvl
            runPart(recorder, mainJob, 'ja', false)
            runPart(recorder, mainJob, 'magic', false)
        end

        if subJob and subJob ~= 0 and jobs[subJob] ~= nil and (subLvl or 0) > 0 then
            profileLevel = subLvl
            runPart(recorder, subJob, 'ja', true)
            runPart(recorder, subJob, 'magic', true)
        end
    end)
    activeBehavior, activeSwitches, profileLevel = savedBehavior, savedSwitches, savedLevel
    if not ok then
        print('[squad] profile for a bot failed: ' .. tostring(err))
    end

    return recorder.list
end

-- For the automatic tests only: does nothing on a real server, where __SQUAD_TEST does not exist
if rawget(_G, '__SQUAD_TEST') ~= nil then
    __SQUAD_TEST.hooks =
    {
        jobs = jobs, jobIds = jobIds, jobNames = jobNames, squadSpawn = squadSpawn, runPart = runPart, classify = classify,
        behaviorFilter = behaviorFilter, applyRules = applyRules, decodeBehavior = decodeBehavior, commandObj = commandObj,
        setLevel = function(level) profileLevel = level end, setRules = function(data) rulesData = data end,
        ROLES = ROLES, MODES = MODES, SWITCHES = SWITCHES, SW_BIT = SW_BIT, SW_ALL = SW_ALL,
        switchesOf = switchesOf, withBit = withBit, switchSummary = switchSummary, switchForAction = switchForAction,
        chatFight = chatFight, chatWorld = chatWorld, chatHookPlayer = chatHookPlayer,
        skillchainRoles = skillchainRoles, ruleCondition = ruleCondition, -- (Gambits WAR/PLD/RDM/WS batch tests)
    }
end

-- 2026-11-19: any error inside a !squad command is written to the log with its traceback (the client only shows "A command error occurred")
if commandObj ~= nil and commandObj.onTrigger ~= nil then
    local innerTrigger = commandObj.onTrigger
    commandObj.onTrigger = function(...)
        local n, args = select('#', ...), { ... }
        local okC, errC = xpcall(function() return innerTrigger(unpack(args, 1, n)) end, debug.traceback)
        if not okC then
            print('[squad] COMMAND ERROR: ' .. tostring(errC):gsub('[{}]', ''):gsub('\n', ' | '))
            error(errC, 0)
        end
    end
end

return m
