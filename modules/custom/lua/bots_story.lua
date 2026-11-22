-----------------------------------
-- XI: Forever Offline: bot players - a life story that survives restarts (2026-11-21). Used by bots_extras.lua.
-- The idea is from MimicXI's world bots (hotactionsock/MimicXI, GPL-3.0: its activity log); written here for ours.
--
-- bots.lua already keeps a bot's last five happenings (its "diary") for the chat, but only until the server stops.
-- This keeps the ones worth remembering in bots_story.txt (next to this file; one line each: time, name, text):
--   every 5th level, a new job, a nation rank, missions and quests done, battlefields, linkshells, a summoner's
--   pacts, and its deaths (one per half hour at most). Shopping and the levels in between are left out.
-- Up to KEEP lines per bot; the file is tidied when the server starts (old lines and the overflow go).
--   * When a bot's brain first starts after a restart, its last five are put back into its diary, so in a chat
--     it still knows what it did yesterday.
--   * !bots story <Name> shows a bot's story (the newest first).
-- Switch: !extras bot_story off (nothing is written or put back; what was written stays in the file).
-----------------------------------
local ST = {}

local FILE       = 'modules/custom/lua/bots_story.txt'
local KEEP       = 40
local MAX_AGE    = 180 * 86400
local DEATH_GAP  = 1800
local TIDY_ABOVE = 1.5 -- the file is rewritten at start when it holds this many times more lines than are kept

local stories = nil -- [name] = { { t, text }, ... } oldest first
local lastDeath = {}

local function now()
    return os.time()
end

local function clean(text)
    return (tostring(text):gsub('[\r\n\t]', ' '))
end

local function load()
    stories = {}
    local f = io.open(FILE, 'r')
    if not f then
        return
    end

    local lines, kept = 0, 0
    local cutoff = now() - MAX_AGE
    for line in f:lines() do
        lines = lines + 1
        local t, name, text = line:match('^(%d+)\t([^\t]+)\t(.+)$')
        t = tonumber(t)
        if t and t >= cutoff then
            local list = stories[name] or {}
            stories[name] = list
            list[#list + 1] = { t = t, text = text }
        end
    end
    f:close()

    for _, list in pairs(stories) do
        while #list > KEEP do
            table.remove(list, 1)
        end

        kept = kept + #list
    end

    -- tidy the file (start of the server only: one write)
    if lines > 200 and lines > kept * TIDY_ABOVE then
        local all = {}
        for name, list in pairs(stories) do
            for _, e in ipairs(list) do
                all[#all + 1] = { t = e.t, name = name, text = e.text }
            end
        end

        table.sort(all, function(a, b)
            return a.t < b.t
        end)
        local out = io.open(FILE, 'w')
        if out then
            for _, e in ipairs(all) do
                out:write(string.format('%d\t%s\t%s\n', e.t, e.name, e.text))
            end
            out:close()
        end
    end
end

local function worthKeeping(name, text, public)
    if text:find('^bought ') then
        return false
    end

    if text:find('^hit level ') then
        return public == true
    end

    if text:find('^got killed') then
        local t = now()
        if t - (lastDeath[name] or 0) < DEATH_GAP then
            return false
        end

        lastDeath[name] = t
    end

    return true
end

-- from bots.lua's diary: something happened to this bot
function ST.add(bot, text, public)
    if stories == nil then
        load()
    end

    local name = bot:getName()
    text = clean(text)
    if text == '' or not worthKeeping(name, text, public) then
        return false
    end

    local list = stories[name] or {}
    stories[name] = list
    local t = now()
    list[#list + 1] = { t = t, text = text }
    while #list > KEEP do
        table.remove(list, 1)
    end

    local f = io.open(FILE, 'a')
    if f then
        f:write(string.format('%d\t%s\t%s\n', t, name, text))
        f:close()
    end

    return true
end

function ST.of(name)
    if stories == nil then
        load()
    end

    return stories[name] or {}
end

-- a brain starting for the first time since the server started: its last five are its diary again
function ST.remember(bot, st)
    if st.storyBack then
        return 0
    end

    st.storyBack = true
    if st.events and #st.events > 0 then
        return 0
    end

    local list = ST.of(bot:getName())
    st.events = {}
    for i = math.max(1, #list - 4), #list do
        st.events[#st.events + 1] = { t = list[i].t, text = list[i].text }
    end

    return #st.events
end

local function ago(t)
    local s = math.max(0, now() - t)
    if s < 3600 then
        return math.max(1, math.floor(s / 60)) .. ' min ago'
    elseif s < 86400 then
        return math.floor(s / 3600) .. ' h ago'
    end

    local d = math.floor(s / 86400)
    return d .. (d == 1 and ' day ago' or ' days ago')
end

-- lines for !bots story <Name> (newest first, at most `count`)
function ST.lines(name, count)
    local list = ST.of(name)
    local out = {}
    for i = #list, math.max(1, #list - (count or 12) + 1), -1 do
        out[#out + 1] = string.format('%s: %s', ago(list[i].t), list[i].text)
    end

    return out
end

function ST.reload()
    stories = nil
end

return ST
