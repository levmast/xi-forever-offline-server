-----------------------------------
-- XI: Forever Offline: bot players - the additions of 2026-11-21 in one place. Loaded by bots.lua.
--   bots_social.lua  emotes at the right moments            (!extras bot_social)
--   bots_memory.lua  staying away from where it died        (!extras bot_memory)
--   bots_story.lua   a life story that survives restarts    (!extras bot_story)
--   bots_gates.lua   out and home through the town gates    (!extras bot_gates)
-- bots.lua, bots_hunt.lua and bots_life.lua call the functions below (each call in a pcall). A part that is
-- switched off, missing or broken does nothing, and the bots behave as they did before.
-----------------------------------
local X = {}

local function part(name)
    local ok, mod = pcall(require, 'modules/custom/lua/' .. name)
    if not ok or type(mod) ~= 'table' then
        print(string.format('[bots] %s is off: it could not be loaded: %s', name, tostring(mod)))
        return nil
    end

    return mod
end

local extrasOk, extras = pcall(require, 'modules/custom/lua/extras')
if not extrasOk or type(extras) ~= 'table' or type(extras.on) ~= 'function' then
    extras = nil
end

local social = part('bots_social')
local memory = part('bots_memory')
local story  = part('bots_story')
local gates  = part('bots_gates')

local function on(key)
    return extras ~= nil and extras.on(key)
end

function X.setup(brainState)
    if social then
        social.setup(brainState)
    end
end

-- a brain starts (log in, or after changing area)
function X.onBrain(bot, st)
    if story and on('bot_story') then
        story.remember(bot, st)
    end
end

-- once a second per bot
function X.tick(bot, st)
    if social and on('bot_social') then
        social.tick(bot, st)
    end
end

-- something for its diary
function X.onDiary(bot, text, public)
    if story and on('bot_story') then
        story.add(bot, text, public)
    end
end

-- a real level up: one level more on the same job
function X.onLevel(bot, st)
    if social and on('bot_social') then
        social.onLevel(bot, st)
    end
end

function X.onDeath(bot, st)
    if memory and on('bot_memory') then
        memory.onDeath(bot, st)
    end
end

-- bots_hunt.lua: the area it goes hunting in, and whether a camp will do
function X.chooseArea(bot, first, again)
    if memory and on('bot_memory') then
        return memory.chooseArea(bot, first, again)
    end

    return first
end

function X.campOk(bot, zoneId, camp)
    if memory and on('bot_memory') then
        return memory.campOk(bot, zoneId, camp)
    end

    return true
end

-- bots_hunt.lua: going out through the gate (true: it walks there first and go(bot) is called at the gate)
function X.leave(bot, st, destZone, go)
    if gates and on('bot_gates') then
        return gates.leave(bot, st, destZone, go)
    end

    return false
end

-- bots.lua: on its way to the gate (once a second while st.trip is set). Switched off meanwhile: it goes at once.
function X.tripThink(bot, st)
    if not gates then
        if st.trip and st.trip.hunt ~= nil and st.hunt == st.trip.hunt then
            st.hunt = nil
        end

        st.trip = nil
        return nil
    end

    if not on('bot_gates') and st.trip then
        st.trip.untilT = math.min(st.trip.untilT or 0, os.time())
    end

    return gates.think(bot, st)
end

function X.tripCancel(st)
    if gates then
        gates.cancel(st)
    else
        st.trip = nil
    end
end

-- bots_life.lua: coming home to this town: where it arrives (nil: on its spot, as before)
function X.homeArrival(bot, townZone)
    if gates and on('bot_gates') and bot:getZoneID() ~= townZone then
        return gates.arrivalFrom(bot:getZoneID(), townZone)
    end

    return nil
end

-- !bots story <Name>
function X.storyLines(name, count)
    if not story then
        return nil
    end

    return story.lines(name, count)
end

X.parts = { social = social, memory = memory, story = story, gates = gates }

return X
