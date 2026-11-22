-----------------------------------
-- Squad extras: personality (2026-11-22, levi). See squad_plus.lua.
--
-- What was already there: each mate's voice (squad_dialogue.lua and the launcher's Squad tab) speaks its own call,
-- level up, knock out and weapon skill lines, and the dialogue pack (squad_pack.lua) adds race and role lines on calls,
-- knock outs, fights and quiet moments. This adds the party around those moments, flavored by the speaker's race (and
-- job, for milestones):
--  - you level up: a mate or two cheer ("Grats on 31, Levi!", a Galka's "Hmph. Well earned.");
--  - a mate levels up: another mate cheers it, and the mate says what the level means for its job now and then
--    ("Cure IV! Nobody falls on my watch now.", "Seventy-five. The top.");
--  - a mate is knocked out: another mate calls it ("Tig is down! Hold together!"); you are knocked out: a mate reacts;
--  - a rare item drops into the treasure pool: a mate notices ("A Peacock Charm! Lot it, Levi!").
-- The cheers and knock out calls stay quiet while the squad chat AI is talking (as the pack's lines do); milestones
-- and drops always play. Each kind has its own pause. Switch: !squad persona on|off.
-----------------------------------
require('modules/module_utils')
local P = require('modules/custom/lua/squad_plus')
-----------------------------------
local m = Module:new('squad_persona')

local PS = {}
SQUAD_PERSONA = PS

PS.AI_QUIET = 300 -- seconds without a squad chat AI line before the cheers and calls play

PS.players = PS.players or {} -- [player id] = { job, lvl, voice, pool = { [key] = true } }

-- race codes as squad.lua keeps them (mate.race): 1/2 Hume, 3/4 Elvaan, 5/6 Tarutaru, 7 Mithra, 8 Galka
local RACE = { 'hume', 'hume', 'elvaan', 'elvaan', 'taru', 'taru', 'mithra', 'galka' }

PS.LINES = {
    youLevel = {
        hume   = { 'Grats on {level}, {master}!', 'Level {level}! Nice going, {master}.', 'Grats! {level} already.' },
        elvaan = { 'Level {level}. Well fought, {master}.', 'Congratulations on {level}. You honor this party.' },
        taru   = { 'Yay! Level {level}, {master}! Grats grats!', 'Level {level}! Hee hee, you\'re getting so strong!' },
        mithra = { 'Ooh, level {level}! Grats, {master}!', 'Level {level}! Now we hunt bigger prey, meow!' },
        galka  = { 'Hmph. Level {level}. Well earned.', 'Level {level}. Good. Keep it up, {master}.' },
    },
    mateLevel = {
        hume   = { 'Grats, {mate}!', 'Nice, {mate}! Level {level}.' },
        elvaan = { 'Well done, {mate}.', 'Level {level}, {mate}. Most fitting.' },
        taru   = { 'Grats {mate}! Level {level}!', 'Woohoo, go {mate}!' },
        mithra = { 'Grats, {mate}! Look at you go!', 'Level {level}, {mate}? Not bad, not bad!' },
        galka  = { 'Grats, {mate}.', 'Level {level}. Good work, {mate}.' },
    },
    mateDown = {
        hume   = { '{mate} is down! Hold together!', '{mate}! Hang in there, we\'ll finish this.' },
        elvaan = { '{mate} has fallen! Stand fast!', 'They will pay for {mate}!' },
        taru   = { 'Eek! {mate} is down!', 'Oh no, {mate}! Hurry, hurry!' },
        mithra = { '{mate} is down! Careful, everyone!', 'Hey! Get up, {mate}!' },
        galka  = { '{mate} is down. Keep fighting.', 'Hmph. {mate} fell. Finish it.' },
    },
    youDown = {
        hume   = { '{master}! No!', '{master} is down! Pull back!' },
        elvaan = { '{master}! Curse them!', 'We have lost {master}... regroup!' },
        taru   = { 'Waaah! {master}!', '{master}! Get up, get up!' },
        mithra = { '{master}! Oh no, not you!', '{master}! Who\'s going to lead us now?' },
        galka  = { '{master}! ...Get back up.', 'Hmph. {master} is down. We hold.' },
    },
    rare = {
        hume   = { 'Whoa, a {item}! Lot it, {master}!', 'Is that a {item}? Nice drop!' },
        elvaan = { 'A {item}. A fine prize, {master}.', 'Remarkable. A {item}!' },
        taru   = { 'Ooh ooh! A {item}! Shiny!', 'A {item}! Lucky lucky!' },
        mithra = { 'A {item}! Mine! ...Kidding. Lot it, {master}!', 'Ooh, a {item}! Treasure!' },
        galka  = { 'A {item}. Good drop.', 'Hmph. A {item}. Worth the trouble.' },
    },
}

-- what a level means for the mate's job (the levels match squad.lua's job rules), and the big ones for everyone
PS.MILESTONES = {
    WAR = { [15] = 'Berserk! Now things get loud.', [35] = 'Warcry. Everybody hit harder!', [45] = 'Aggressor. Watch them fall now.' },
    MNK = { [35] = 'Chakra. I can patch myself up now.', [45] = 'Counterstance. Let them come.' },
    WHM = { [25] = 'Raise. Don\'t make me use it.', [41] = 'Cure IV! Nobody falls on my watch now.', [40] = 'Haste! I\'ll keep you quick.' },
    RDM = { [40] = 'Convert. My MP won\'t run dry so easily now.' },
    THF = { [15] = 'Sneak Attack. Turn your back and see.', [30] = 'Trick Attack! Stand in front, tank.' },
    PLD = { [30] = 'Sentinel. Hit me all you like.' },
    DRK = { [15] = 'Last Resort. Defense is overrated.', [30] = 'Souleater. This is going to hurt... them.' },
    BST = { [12] = 'Reward. My pets will love me for it.', [25] = 'Sic. Go get them!' },
    RNG = { [20] = 'Sharpshot. Every arrow counts now.' },
    SAM = { [15] = 'Third Eye. I can see it coming.', [30] = 'Meditate. My blade won\'t wait for TP.' },
    NIN = { [40] = 'Yonin. Come at me.' },
    DRG = { [35] = 'High Jump! Up and away.', [50] = 'Super Jump. Gone before they know it.' },
}
PS.EVERYONE = {
    [18] = 'Eighteen. Time to think about a support job.',
    [50] = 'Fifty! Past the first limit.',
    [75] = 'Seventy-five. The top. We made it.',
}

local function raceOf(trust)
    return RACE[trust:getLocalVar('SQX_RACE')] or 'hume'
end

local function fill(text, vars)
    return (string.gsub(text, '{(%w+)}', function(key)
        return vars[key] ~= nil and tostring(vars[key]) or ('{' .. key .. '}')
    end))
end

local function line(kind, trust, vars)
    local pool = PS.LINES[kind][raceOf(trust)] or PS.LINES[kind].hume
    return fill(pool[math.random(#pool)], vars)
end

local function aiQuiet(player)
    local ok, off = pcall(function() return player:getCharVar('SQUAD_CHAT_OFF') == 1 end)
    local saidAt = xi.squad and tonumber(xi.squad.aiSaidAt) or 0
    return (ok and off) or os.time() - saidAt >= PS.AI_QUIET
end

local function ps(player)
    local s = PS.players[player:getID()]
    if s == nil then
        s = { pool = {} }
        PS.players[player:getID()] = s
    end

    return s
end

-- a living mate to speak (not `except`), at random
local function anyMate(player, except)
    local list = {}
    for _, trust in ipairs(P.trusts(player)) do
        if trust:isAlive() and (except == nil or trust:getID() ~= except:getID()) then
            list[#list + 1] = trust
        end
    end

    return list[1] and list[math.random(#list)] or nil
end

local function jobKey(jobId)
    for name, id in pairs(xi.job) do
        if id == jobId then
            return name
        end
    end

    return nil
end

-- ---------------------------------------------------------------- the events
function PS.youLevel(player, level)
    if not aiQuiet(player) then
        return
    end

    local first = anyMate(player)
    if first == nil then
        return
    end

    local vars = { master = player:getName(), level = level }
    P.say(player, first, line('youLevel', first, vars))
    local second = anyMate(player, first)
    if second ~= nil and math.random() < 0.5 then
        P.say(player, second, line('youLevel', second, vars))
    end
end

function PS.mateLevel(player, trust, level)
    local vars = { master = player:getName(), level = level, mate = trust:getPacketName() }
    local other = anyMate(player, trust)
    if other ~= nil and aiQuiet(player) then
        P.say(player, other, line('mateLevel', other, vars))
    end

    local job = PS.MILESTONES[jobKey(trust:getMainJob()) or ''] or {}
    local text = PS.EVERYONE[level] or job[level]
    if text ~= nil then
        P.say(player, trust, text)
    end
end

function PS.mateDown(player, trust)
    local other = anyMate(player, trust)
    if other ~= nil and aiQuiet(player) and P.every(player, 'PERSONA_DOWN', 20) then
        P.say(player, other, line('mateDown', other, { master = player:getName(), mate = trust:getPacketName() }))
    end
end

function PS.youDown(player)
    if not P.on(player, 'persona') or not aiQuiet(player) then
        return
    end

    local other = anyMate(player)
    if other ~= nil then
        P.say(player, other, line('youDown', other, { master = player:getName() }))
    end
end

-- the treasure pool after a kill: a rare item not seen before gets a line (one per kill)
local RARE_FLAG = 0x8000
function PS.checkPool(player)
    if not P.on(player, 'persona') then
        return
    end

    local okP, items = pcall(function() return player:getTreasurePool():getItems() end)
    if not okP or type(items) ~= 'table' then
        return
    end

    local s = ps(player)
    for _, row in pairs(items) do
        local key = string.format('%s:%s:%s', tostring(row.slotId), tostring(row.id), tostring(row.timestamp))
        if not s.pool[key] then
            s.pool[key] = true
            local okI, rare, name = pcall(function()
                local item = GetItemByID(row.id)
                return math.floor(item:getFlag() / RARE_FLAG) % 2 == 1, item:getName()
            end)
            local mate = anyMate(player)
            if okI and rare and mate ~= nil then
                P.say(player, mate, line('rare', mate, { master = player:getName(), item = P.pretty(name) }))
                break
            end
        end
    end

    local count = 0
    for _ in pairs(s.pool) do
        count = count + 1
    end
    if count > 200 then
        s.pool = {}
    end
end

-- ---------------------------------------------------------------- the tick
function PS.tick(player, trust)
    local s = ps(player)

    -- this mate's own level (SQUAD_OWN: set by squad.lua when it is called and on a level up)
    local own = trust:getLocalVar('SQUAD_OWN')
    local seen = trust:getLocalVar('SQX_OWN_SEEN')
    if seen == 0 then
        trust:setLocalVar('SQX_OWN_SEEN', own)
    elseif own > seen then
        trust:setLocalVar('SQX_OWN_SEEN', own)
        PS.mateLevel(player, trust, own)
    end

    -- one mate a second looks after the party events
    local now = os.time()
    if s.voiceAt == now and s.voice ~= trust:getID() then
        return
    end

    s.voice, s.voiceAt = trust:getID(), now

    -- your level (the same job, one higher: a level up, not a job change or a sync)
    local job, lvl = player:getMainJob(), player:getMainLvl()
    if s.job == job and s.lvl ~= nil and lvl == s.lvl + 1 then
        PS.youLevel(player, lvl)
    end
    s.job, s.lvl = job, lvl
end

P.register('persona', {
    title = 'race and job flavored lines: level ups, knock outs, rare drops',
    words = { 'persona', 'lines', 'personality' },
    tick = PS.tick,
    onSpawn = function(player, trust, mate)
        trust:setLocalVar('SQX_RACE', tonumber(mate and mate.race) or 0)
        trust:setLocalVar('SQX_OWN_SEEN', trust:getLocalVar('SQUAD_OWN'))

        trust:addListener('DEATH', 'SQX_PERSONA_KO', function(mob)
            local master = P.master(mob)
            if master ~= nil and P.on(master, 'persona') then
                P.try('persona ko', PS.mateDown, master, mob)
            end
        end)

        player:addListener('DEFEATED_MOB', 'SQX_PERSONA_DROP', function(entity)
            P.try('persona drop', function()
                entity:timer(2000, function(who)
                    P.try('persona pool', PS.checkPool, who)
                end)
            end)
        end)

        player:addListener('DEATH', 'SQX_PERSONA_DEATH', function(entity)
            P.try('persona death', PS.youDown, entity)
        end)
    end,
})

return m
