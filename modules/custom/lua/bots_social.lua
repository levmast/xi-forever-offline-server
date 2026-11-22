-----------------------------------
-- XI: Forever Offline: bot players - small human touches (2026-11-21). Used by bots_extras.lua.
-- The idea is from MimicXI's world bots (hotactionsock/MimicXI, GPL-3.0); written here for our own bot players.
--
-- Emotes at the right moments, through the same packet a game client sends (BotEmote), so everyone near sees them:
--   * it levels up: a /joy (or /hurray), and the bots in its party cheer it
--   * you level up with bots in your party: some of them cheer or clap for you
--   * it joins your party: a /bow (or /wave, /salute); your party ends: a /wave goodbye if you are still near
--   * badly hurt in a fight (under 20% HP): one /panic
--   * back on its feet after dying: a /sigh
--   * out of town, you walk past a bot that is not busy: now and then a /wave (each of you once in half an hour)
--   * in town, two bots standing near each other trade a couple of emotes, turned to each other
-- Every bot waits GAP seconds between two emotes, so nobody spams. Nothing here moves a bot, changes its target or
-- its party, or touches how it fights. Switch: !extras bot_social off.
-----------------------------------
local S = {}

local GAP          = 20   -- seconds between two emotes of the same bot
local RANGE        = 20   -- yalms: who it reacts to
local PASS_RANGE   = 8    -- yalms: "you walk past"
local PASS_AGAIN   = 1800 -- seconds before the same bot waves at the same player again
local PASS_CHANCE  = 0.35
local PANIC_HPP    = 20
local PANIC_AGAIN  = 120
local TALK_EVERY   = { 40, 120 } -- seconds between two "does it say something to its neighbour?" thoughts in town
local TALK_CHANCE  = 0.5
local TALK_RANGE   = 6

local OPENERS = { 'LAUGH', 'YES', 'THINK', 'SMILE', 'GRIN', 'POINT', 'CLAP', 'HUH', 'DOUBT', 'JOY' }
local ANSWERS =
{
    LAUGH = { 'LAUGH', 'GRIN', 'SMILE' },
    YES   = { 'YES', 'SMILE', 'CLAP' },
    THINK = { 'THINK', 'YES', 'NO', 'HUH' },
    SMILE = { 'SMILE', 'LAUGH', 'BOW' },
    GRIN  = { 'LAUGH', 'GRIN', 'NO' },
    POINT = { 'HUH', 'YES', 'LAUGH' },
    CLAP  = { 'BOW', 'JOY', 'SMILE' },
    HUH   = { 'NO', 'YES', 'LAUGH', 'THINK' },
    DOUBT = { 'YES', 'NO', 'LAUGH' },
    JOY   = { 'CLAP', 'CHEER', 'JOY' },
}

local state = nil -- bots.lua's own table: [bot id] = st

local function rnd(a, b)
    return math.random(a, b)
end

local function now()
    return os.time()
end

local function pick(list)
    return list[rnd(1, #list)]
end

local function d2(a, b)
    return (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2
end

local function isBot(e)
    return BotIsBot ~= nil and BotIsBot(e:getID()) == true
end

local function soc(st)
    st.soc = st.soc or {}
    return st.soc
end

-- the real players of an area, looked up at most every 2 seconds per area (hundreds of bots ask)
local realCache = {} -- [zone id] = { t, list }
local function realPlayers(bot)
    local zoneId = bot:getZoneID()
    local c = realCache[zoneId]
    local t = now()
    if not c or t - c.t >= 2 then
        c = { t = t, list = {} }
        realCache[zoneId] = c
        local zone = bot:getZone()
        for _, p in ipairs(zone and zone:getPlayers() or {}) do
            if not isBot(p) then
                c.list[#c.list + 1] = p:getName()
            end
        end
    end

    return c.list
end

-- one emote now, if this bot may (alive, not too soon after its last one); target: an entity or nil
local function emote(bot, st, target, name)
    local which = xi.emote and xi.emote[name]
    if not which or not BotEmote then
        return false
    end

    local s = soc(st)
    local t = now()
    if t <= (s.nextEmote or 0) or bot:isDead() then
        return false
    end

    s.nextEmote = t + GAP
    BotEmote(bot:getID(), target, which, (xi.emoteMode and xi.emoteMode.MOTION) or 2)
    return true
end

-- the same a moment later. The bot and its target are looked up again by name when the moment comes: either may
-- have changed area meanwhile, and an old handle must not be used (see the note in bots.lua's think).
local function emoteLater(bot, st, targetName, name, ms)
    local botName = bot:getName()
    bot:timer(ms, function()
        local b = GetPlayerByName and GetPlayerByName(botName) or nil
        if not b or not isBot(b) then
            return
        end

        local target = nil
        if targetName then
            target = GetPlayerByName(targetName)
            if not target or target:getZoneID() ~= b:getZoneID() or d2(b:getPos(), target:getPos()) > RANGE * RANGE then
                return -- gone, or too far by now: no emote into the air
            end
        end

        emote(b, st, target, name)
    end)
end

local function realMemberNear(bot)
    local pos = bot:getPos()
    for _, m in pairs(bot:getParty() or {}) do
        if m:getObjType() == xi.objType.PC and not isBot(m) and m:getZoneID() == bot:getZoneID() then
            if d2(pos, m:getPos()) <= RANGE * RANGE then
                return m
            end
        end
    end

    return nil
end

local function realMember(bot)
    for _, m in pairs(bot:getParty() or {}) do
        if m:getObjType() == xi.objType.PC and not isBot(m) then
            return m
        end
    end

    return nil
end

function S.setup(brainState)
    state = brainState
end

-- a real level up (bots.lua noticeChanges: one level more on the same job)
function S.onLevel(bot, st)
    emoteLater(bot, st, nil, math.random() < 0.3 and 'HURRAY' or 'JOY', rnd(800, 1600))
    local pos = bot:getPos()
    for _, m in pairs(bot:getParty() or {}) do
        if m:getID() ~= bot:getID() and m:getObjType() == xi.objType.PC and isBot(m) and m:getZoneID() == bot:getZoneID() then
            local mst = state and state[m:getID()]
            if mst and d2(pos, m:getPos()) <= RANGE * RANGE and math.random() < 0.7 then
                emoteLater(m, mst, bot:getName(), pick({ 'CHEER', 'CLAP', 'PRAISE' }), rnd(1500, 4000))
            end
        end
    end
end

-- once a second per bot (bots.lua think). Cheap on purpose: a few numbers, and anything that looks around the
-- area runs every few seconds only.
function S.tick(bot, st)
    local s = soc(st)
    local t = now()

    -- died: remember it; back on its feet: a sigh
    if bot:isDead() then
        s.died = true
        return
    elseif s.died then
        s.died = nil
        emoteLater(bot, st, nil, 'SIGH', rnd(3000, 6000))
    end

    -- badly hurt in a fight: one /panic (never while it is casting: bots.lua leaves a casting bot alone, so do we)
    if bot:isEngaged() then
        if bot:getHPP() < PANIC_HPP and t >= (s.panicAt or 0) and not (xi.bots.isCasting and xi.bots.isCasting(bot)) then
            s.panicAt = t + PANIC_AGAIN
            emote(bot, st, nil, 'PANIC')
        end

        return
    end

    -- your party: a bow when it joins, a wave when it is over, a cheer when you level up
    if t >= (s.partyAt or 0) then
        s.partyAt = t + 2
        local you = realMember(bot)
        local name = you and you:getName() or nil
        if name then
            s.withSeen, s.outSince = t, nil
        elseif s.with then
            -- not in its party list right now. That is a goodbye only when you are in the world and still not in
            -- its party a few seconds on; while you are between two areas (nobody of your name in the world) it
            -- waits, so changing area does not make everyone wave and bow again.
            local old = GetPlayerByName and GetPlayerByName(s.with) or nil
            if not old then
                s.outSince = nil
                if t - (s.withSeen or 0) < 90 then
                    name = s.with
                end
            else
                s.outSince = s.outSince or t
                if t - s.outSince < 5 then
                    name = s.with
                end
            end
        end

        if name ~= s.with then
            if name then
                if you:getZoneID() == bot:getZoneID() and d2(bot:getPos(), you:getPos()) <= RANGE * RANGE then
                    emoteLater(bot, st, name, pick({ 'BOW', 'BOW', 'WAVE', 'SALUTE' }), rnd(1500, 3000))
                end

                s.youLvl, s.youJob = you:getMainLvl(), you:getMainJob()
            elseif s.with then
                emoteLater(bot, st, s.with, pick({ 'WAVE', 'WAVE', 'GOODBYE', 'BOW' }), rnd(1000, 2500))
            end

            s.with = name
        elseif you then
            local lvl, job = you:getMainLvl(), you:getMainJob()
            if s.youLvl and job == s.youJob and lvl == s.youLvl + 1 and math.random() < 0.6 then
                emoteLater(bot, st, name, pick({ 'CHEER', 'CLAP', 'PRAISE', 'JOY' }), rnd(1200, 3500))
            end

            s.youLvl, s.youJob = lvl, job
        end
    end

    -- out of town and not busy with you: a wave at a player walking past
    if t >= (s.passAt or 0) then
        s.passAt = t + 3
        if not s.with and not (st.life and st.life.phase) then
            local pos = bot:getPos()
            for _, who in ipairs(realPlayers(bot)) do
                local p = GetPlayerByName and GetPlayerByName(who) or nil
                if p and p:getZoneID() == bot:getZoneID() and d2(pos, p:getPos()) <= PASS_RANGE * PASS_RANGE then
                    s.waved = s.waved or {}
                    if t >= (s.waved[who] or 0) then
                        s.waved[who] = t + PASS_AGAIN
                        if math.random() < PASS_CHANCE then
                            emoteLater(bot, st, who, math.random() < 0.8 and 'WAVE' or 'BOW', rnd(500, 1500))
                        end
                    end

                    break
                end
            end
        end
    end

    -- in town, standing at its spot (not resting): a word with whoever stands next to it
    local life = st.life
    if life and life.phase == 'there' and life.kind ~= 'rest' then
        s.talkAt = s.talkAt or (t + rnd(TALK_EVERY[1], TALK_EVERY[2]))
        if t >= s.talkAt then
            s.talkAt = t + rnd(TALK_EVERY[1], TALK_EVERY[2])
            if math.random() < TALK_CHANCE and t >= (s.nextEmote or 0) then
                local zone = bot:getZone()
                local pos = bot:getPos()
                for _, p in ipairs(zone and zone:getPlayers() or {}) do
                    if p:getID() ~= bot:getID() and isBot(p) and d2(pos, p:getPos()) <= TALK_RANGE * TALK_RANGE then
                        local pst = state and state[p:getID()]
                        local pl = pst and pst.life
                        if pl and pl.phase == 'there' and pl.kind ~= 'rest' and not p:isEngaged() and now() >= (soc(pst).nextEmote or 0) then
                            local opener = pick(OPENERS)
                            if emote(bot, st, p, opener) then
                                emoteLater(p, pst, bot:getName(), pick(ANSWERS[opener] or { 'YES' }), rnd(1500, 3000))
                            end

                            break
                        end
                    end
                end
            end
        end
    else
        s.talkAt = nil
    end
end

return S
