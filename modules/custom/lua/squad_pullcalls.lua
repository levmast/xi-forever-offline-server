-----------------------------------
-- Squad extras: pull calls (2026-11-22, levi). See squad_plus.lua.
--
-- What was already there (squad.lua camp, trust_controller.cpp DoCampPullTick): !squad camp and a puller who picks a
-- monster, says "Pulling >> Goblin_Smithy <<", opens from range with a pull spell (a song, Dia, Bio, a tier-one nuke,
-- Banish, Provoke or Flash from its rules) or a shot, else walks up and hits it, then runs back to camp. This adds the
-- party chat around it, the way a 2006 puller talked:
--  - the pull is numbered with the monsters on their way: "Pulling >> Goblin_Smithy << (1)";
--  - the tool is called when it lands: "Dia on it, coming back!", "Shot it, on my way!", "Got it, coming back!";
--  - a link on the way back: "Link! Goblin Mugger, (2) coming!";
--  - near camp, a mate at camp (the tank first): "Here it comes!";
--  - at any fight (with or without a camp), a new monster joining it: "Add! Goblin Leecher!" (left to the sleep line
--    when a mage is already sleeping it).
-- Nothing here moves the puller or picks a monster. Switch: !squad pullcalls on|off.
-----------------------------------
require('modules/module_utils')
local P = require('modules/custom/lua/squad_plus')
-----------------------------------
local m = Module:new('squad_pullcalls')

local PC = {}
SQUAD_PULLCALLS = PC

PC.NEAR = 18 -- yalms from camp for "Here it comes!"

PC.state = PC.state or {} -- [player id] = { pullNo, target, called, coming, links = { [id] = true }, near, fight = { [id] = time } }

local function st(player)
    local s = PC.state[player:getID()]
    if s == nil then
        s = { links = {}, fight = {} }
        PC.state[player:getID()] = s
    end

    return s
end

local function mobName(foe)
    local name = foe:getName()
    pcall(function() name = foe:getPacketName() end)
    return (string.gsub(tostring(name), '_', ' '))
end

local function camp(player)
    local get = xi.squad and xi.squad.campInfo
    if type(get) ~= 'function' then
        return nil
    end

    local ok, c = pcall(get, player)
    return ok and c or nil
end

local function isPuller(c, trust)
    return c ~= nil and c.puller ~= nil and trust:getLocalVar('SQUAD_ID') == c.puller
end

-- squad.lua's pull line asks for the count: " (1)" (empty when the switch is off)
function PC.suffix(player)
    if not P.on(player, 'pullcalls') then
        return ''
    end

    return ' (1)'
end

-- the pull's tool, from the puller's own spell or shot
local function toolCall(player, trust, target, line)
    local c = camp(player)
    if not isPuller(c, trust) or c.state ~= 'pulling' or c.targetEnt == nil or target == nil then
        return
    end

    if target:getID() ~= c.targetEnt:getID() then
        return
    end

    local s = st(player)
    if s.called == c.pulls then
        return
    end

    s.called = c.pulls
    P.say(player, trust, line)
end

function PC.onMagic(trust, target, spell)
    local player = P.master(trust)
    if player == nil or spell == nil or not P.on(player, 'pullcalls') then
        return
    end

    local name = P.spellName(spell:getID())
    local lines = { '%s on it, coming back!', '%s landed, on my way back!', '%s! It\'s coming.' }
    toolCall(player, trust, target, string.format(lines[math.random(#lines)], name))
end

function PC.onShot(trust, target)
    local player = P.master(trust)
    if player == nil or not P.on(player, 'pullcalls') then
        return
    end

    local lines = { 'Shot it, on my way!', 'Tagged it, coming back!' }
    toolCall(player, trust, target, lines[math.random(#lines)])
end

-- the monsters on the puller's hate list (alive)
local function following(puller)
    local out = {}
    local ok, list = pcall(function() return puller:getNotorietyList() end)
    if ok and type(list) == 'table' then
        for _, foe in pairs(list) do
            local okF, alive = pcall(function() return foe:getObjType() == xi.objType.MOB and foe:isAlive() end)
            if okF and alive then
                out[#out + 1] = foe
            end
        end
    end

    return out
end

-- a mate at camp to say "Here it comes!": the tank, else any mate who is not the puller
local function campVoice(player, c)
    local any
    for _, trust in ipairs(P.trusts(player)) do
        if trust:isAlive() and not isPuller(c, trust) then
            if P.partRole(player, trust) == 'tank' then
                return trust
            end

            any = any or trust
        end
    end

    return any
end

function PC.pullTick(player, trust, c)
    local s = st(player)
    local phase = trust:getLocalVar('SQUAD_PULL_PHASE')

    if s.pullNo ~= c.pulls then -- (a new pull)
        s.pullNo, s.coming, s.near, s.links = c.pulls, false, false, {}
        if c.targetEnt ~= nil then
            s.links[c.targetEnt:getID()] = true
        end
    end

    if phase == 2 and not s.coming then
        s.coming = true
        if s.called ~= c.pulls then -- (no spell or shot was called: it was hit or provoked)
            s.called = c.pulls
            local lines = { 'Got it, coming back!', 'Got its attention, heading back!', 'It\'s on me, coming in!' }
            P.say(player, trust, lines[math.random(#lines)])
        end
    end

    if phase ~= 2 then
        return
    end

    -- links on the way back
    local list = following(trust)
    for _, foe in ipairs(list) do
        if not s.links[foe:getID()] then
            s.links[foe:getID()] = true
            local count = 0
            for _ in pairs(s.links) do
                count = count + 1
            end

            P.say(player, trust, string.format('Link! %s, (%d) coming!', mobName(foe), count))
        end
    end

    -- near camp
    if not s.near and c.targetEnt ~= nil and c.x ~= nil then
        local ok, d = pcall(function()
            local pos = c.targetEnt:getPos()
            return math.sqrt((pos.x - c.x) ^ 2 + (pos.z - c.z) ^ 2)
        end)
        if ok and d and d <= PC.NEAR then
            s.near = true
            local voice = campVoice(player, c)
            if voice ~= nil then
                local lines = { 'Here it comes!', 'Incoming!', 'Here it comes, get ready!' }
                P.say(player, voice, lines[math.random(#lines)])
            end
        end
    end
end

-- a monster joining a fight already on: "Add!" (one mate per player calls these: the first one ticking)
function PC.addTick(player, trust)
    local s = st(player)
    local now = os.time()
    if s.addVoiceAt == now and s.addVoice ~= trust:getID() then
        return
    end

    s.addVoice, s.addVoiceAt = trust:getID(), now

    local foes = P.foes(player, 25)
    if #foes == 0 then
        s.fight = {}
        return
    end

    local c = camp(player)
    local fresh = {}
    for _, foe in ipairs(foes) do
        local id = foe:getID()
        if s.fight[id] == nil then
            s.fight[id] = now
            local pulled = c ~= nil and (s.links[id] or (c.targetEnt ~= nil and c.targetEnt:getID() == id))
            if next(s.fight) ~= nil and not pulled and s.started then
                fresh[#fresh + 1] = foe
            end
        end
    end

    if not s.started then
        s.started = true -- (the first monsters of a fight are the fight, not adds)
        return
    end

    for _, foe in ipairs(fresh) do
        local claims = SQUAD_CC and SQUAD_CC.claims
        if not (claims and claims[foe:getID()]) and P.every(trust, 'ADD_CALL', 3) then
            local lines = { 'Add! %s!', 'We\'ve got an add: %s!', 'Add incoming, %s!' }
            P.say(player, trust, string.format(lines[math.random(#lines)], mobName(foe)))
        end
    end
end

function PC.tick(player, trust)
    local c = camp(player)
    if isPuller(c, trust) and c.state == 'pulling' then
        PC.pullTick(player, trust, c)
    end

    local s = st(player)
    if #P.foes(player, 25) == 0 then
        s.started, s.fight = false, {}
        return
    end

    -- the adds caller: not the puller while it is out pulling
    if not (isPuller(c, trust) and c.state == 'pulling') then
        PC.addTick(player, trust)
    end
end

P.register('pullcalls', {
    title = 'the puller calls the pull, its tool and links; mates call adds',
    words = { 'pullcalls', 'pullcall', 'calls' },
    tick = PC.tick,
    onSpawn = function(player, trust, mate)
        trust:addListener('MAGIC_USE', 'SQX_PULL_MAGIC', function(mob, target, spell)
            P.try('pullcalls magic', PC.onMagic, mob, target, spell)
        end)

        trust:addListener('RANGE_STATE_EXIT', 'SQX_PULL_SHOT', function(mob, target)
            P.try('pullcalls shot', PC.onShot, mob, target)
        end)
    end,
})

return m
