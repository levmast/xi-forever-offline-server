-----------------------------------
-- Squad mates on your linkshell (2026-11-22; Truth's suggestion, the user's design). Used by squad.lua and bots.lua.
--
-- A mate you put on your linkshell talks on linkshell chat, whether it is out with you or not:
--   * now and then a member that is NOT out says what it is up to (a line that fits its job);
--   * when you say something on the linkshell, a member answers. A member that is out with you answers through the
--     squad chat AI when that is on (its answer goes to the linkshell instead of party chat); otherwise, and for
--     members that are not out, the answer is a written line;
--   * one member says hello when you log in.
-- You need a linkshell of your own equipped: the lines appear on it (the first one you wear), to you only.
--   !squad ls                      who is on it
--   !squad ls <slot | all> on      that mate joins        !squad ls <slot | all> off      it leaves
-- Kept on your character: SQUAD_SHELL_<mate id> = 1 for a member. (SQUAD_LS_... is taken: that is a mate's lockstyle.)
-----------------------------------
local S = {}

S.IDLE_MIN, S.IDLE_MAX = 8 * 60, 16 * 60 -- seconds between two "what I am up to" lines
S.ANSWER_MIN, S.ANSWER_MAX = 2, 5        -- seconds before a written answer
S.AI_WAIT = 40                           -- seconds an AI answer to a linkshell line may take and still go to the linkshell
S.QUIET_AFTER_YOU = 20                   -- no "up to" line right after you spoke or got an answer

local CH_LS1, CH_LS2 = 5, 27 -- xi.msg.channel.LINKSHELL, LINKSHELL2
local SLOT_LINK1, SLOT_LINK2 = 16, 17

-- which kind of line a job gets (job ids as squad.lua: 1 WAR ... 18 PUP)
local kindByJob =
{
    [1] = 'fighter', [2] = 'fighter', [3] = 'healer', [4] = 'mage', [5] = 'mage', [6] = 'rogue', [7] = 'fighter', [8] = 'fighter',
    [9] = 'ranger', [10] = 'bard', [11] = 'ranger', [12] = 'fighter', [13] = 'rogue', [14] = 'fighter', [15] = 'mage',
    [16] = 'mage', [17] = 'rogue', [18] = 'ranger',
}

-- {town} = where it says it is, {master} = you. Edit freely.
S.lines =
{
    upTo =
    {
        fighter = { 'Sparring behind the guard post in {town}. Losing, for now.', 'Having my blade looked at in {town}. The smith says it has seen better days.',
                    'Carrying crates for a merchant in {town}. It pays for supper.', 'Watching the gate at {town}. Quiet day.',
                    'Trading stories with the guards in {town}. Mine are better.' },
        mage    = { 'Reading in {town}. Three scrolls in and none of them useful yet.', 'Copying spell notes in {town}. My hand is cramping.',
                    'Arguing with a scholar in {town} about ice magic. I am right.', 'Looking through the scroll stalls in {town}. Too dear, all of them.',
                    'Meditating by the fountain in {town}. Mostly napping.' },
        healer  = { 'Helping at the infirmary in {town}. Scraped knees, mostly.', 'Gathering herbs outside {town}. Found more nettles than herbs.',
                    'Brewing tea in {town}. Come by if you pass.', 'Patching up a guard in {town} who "walked into a door".',
                    'Saying my prayers in {town}. You are in them, {master}.' },
        rogue   = { 'Playing dice in {town}. Winning. Do not ask how.', 'Keeping an eye on the market in {town}. Purely out of interest.',
                    'Found a rooftop in {town} with a good view. Staying a while.', 'Picking the lock on my own chest in {town}. Lost the key again.',
                    'Listening to gossip at the tavern in {town}. Nothing worth a gil yet.' },
        ranger  = { 'Fletching arrows in {town}. Half of them fly straight.', 'Out past the walls of {town}, following tracks. Rabbit, I think.',
                    'Shooting at a straw target in {town}. The straw is winning.', 'Mending my gear in {town}. Rain got into everything.',
                    'Scouting the road out of {town}. All clear.' },
        bard    = { 'Playing for coins in {town}. Two gil and a button so far.', 'Writing a song about our last fight. In {town}. It needs a better ending.',
                    'Tuning up in {town}. The innkeeper has asked me to stop.', 'Learning a new tune from a traveler in {town}.',
                    'Singing at the tavern in {town} tonight. Wish me luck.' },
    },
    hello  = { 'Welcome back, {master}.', 'There you are, {master}.', '{master}! Good to hear you.', 'Evening, {master}. All quiet here.', 'Hey, {master}. Call if you need me.' },
    greet  = { 'Hello, {master}.', 'Hey!', 'Good to hear you, {master}.', 'Hi there.', 'Hello! All well here.' },
    where  = { 'In {town}, keeping busy.', 'Still in {town}. Call and I will come.', '{town}. Nothing much going on.', 'Around {town}. Why, do you need me?' },
    thanks = { 'Any time.', 'Of course, {master}.', 'Think nothing of it.', 'Glad to help.' },
    bye    = { 'Take care, {master}.', 'See you soon.', 'Safe travels.', 'Until next time.' },
    other  = { 'Heard you, {master}.', 'Mm. Call me when it is time to fight.', 'Ha. Noted.', 'If you say so, {master}.', 'Understood.', 'Sounds like you.' },
}

local towns = { [0] = "San d'Oria", [1] = 'Bastok', [2] = 'Windurst' }

local function rnd(a, b)
    return math.random(a, b)
end

S.memberVar = function(mateId)
    return 'SQUAD_SHELL_' .. tostring(mateId)
end

S.isMember = function(player, mate)
    return player:getCharVar(S.memberVar(mate.id)) == 1
end

-- the linkshell chat the lines go to: the first linkshell you wear, nil when you wear none
S.channel = function(player)
    local ok, first = pcall(function()
        return player:getEquippedItem(SLOT_LINK1)
    end)
    if ok and first ~= nil then
        return CH_LS1
    end

    local ok2, second = pcall(function()
        return player:getEquippedItem(SLOT_LINK2)
    end)
    if ok2 and second ~= nil then
        return CH_LS2
    end

    return nil
end

local function squadOf(player)
    local list = GetSquad and GetSquad(player:getID()) or {}
    return list or {}
end

S.members = function(player)
    local out = {}
    for _, mate in ipairs(squadOf(player)) do
        if S.isMember(player, mate) then
            out[#out + 1] = mate
        end
    end

    return out
end

-- { [mate id] = true } for the mates out with you now (squad.lua fills this in: xi.squad.outIds)
local function outNow(player)
    local f = xi and xi.squad and xi.squad.outIds
    if type(f) == 'function' then
        local ok, t = pcall(f, player)
        if ok and type(t) == 'table' then
            return t
        end
    end

    return {}
end

local function fill(text, player, mate)
    local town = towns[tonumber(mate.nation) or -1] or 'town'
    return (text:gsub('{town}', town):gsub('{master}', player:getName()))
end

local function pick(list, last)
    if #list == 0 then
        return nil
    end

    local i = rnd(1, #list)
    if #list > 1 and list[i] == last then
        i = i % #list + 1
    end

    return list[i]
end

S.say = function(player, mate, text)
    local channel = S.channel(player)
    if channel == nil or text == nil then
        return false
    end

    player:printToPlayer(text, channel, mate.name)
    player:setLocalVar('SQUAD_SHELL_LAST', os.time())
    return true
end

-- what you said, sorted into the kind of answer it gets
S.kindOf = function(text)
    local t = ' ' .. string.lower(text or '') .. ' '
    t = t:gsub('[%p]', ' ')
    local function has(...)
        for _, word in ipairs({ ... }) do
            if t:find(' ' .. word .. ' ', 1, true) then
                return true
            end
        end

        return false
    end

    if has('thanks', 'thank', 'ty', 'thx') then
        return 'thanks'
    elseif has('bye', 'goodbye', 'night', 'later', 'cya', 'logging') then
        return 'bye'
    elseif t:find('where', 1, true) or t:find('up to', 1, true) or t:find('what are you doing', 1, true) or t:find('whats up', 1, true)
        or t:find('what s up', 1, true) or t:find('how are', 1, true) then
        return 'where'
    elseif has('hi', 'hello', 'hey', 'yo', 'morning', 'evening', 'hiya', 'greetings', 'o/') or t:find('nice to meet', 1, true) then
        return 'greet'
    end

    return 'other'
end

local lastLine = {}

local function written(player, mate, kind)
    local list = S.lines[kind]
    if kind == 'upTo' then
        list = S.lines.upTo[kindByJob[mate.mjob] or 'fighter'] or S.lines.upTo.fighter
    end

    local text = pick(list or {}, lastLine[kind])
    if text == nil then
        return nil
    end

    lastLine[kind] = text
    return fill(text, player, mate)
end

S.written = written

-- You said something on linkshell chat (bots.lua hands every linkshell line here).
S.onPlayerChat = function(player, text)
    local members = S.members(player)
    if #members == 0 or S.channel(player) == nil then
        return
    end

    player:setLocalVar('SQUAD_SHELL_LAST', os.time())
    local out = outNow(player)
    local outMembers, awayMembers = {}, {}
    for _, mate in ipairs(members) do
        if out[mate.id] then
            outMembers[#outMembers + 1] = mate
        else
            awayMembers[#awayMembers + 1] = mate
        end
    end

    -- members out with you answer through the squad chat AI when it is on: the line goes to the chat helper like party
    -- chat, and for a short while their answers are shown on the linkshell (squad.lua's chatRead asks channelForReply)
    local aiTook = false
    if #outMembers > 0 and xi.squad and type(xi.squad.shellToAI) == 'function' then
        local ok, sent = pcall(xi.squad.shellToAI, player, text)
        if ok and sent == true then
            aiTook = true
            player:setLocalVar('SQUAD_SHELL_AI_UNTIL', os.time() + S.AI_WAIT)
        end
    end

    -- a written answer: from a member that is not out when the AI took the line (so both kinds are heard, as on a real
    -- linkshell), else from any member
    local pool = aiTook and awayMembers or members
    if #pool == 0 or (aiTook and rnd(1, 100) > 50) then
        return
    end

    local mate = pool[rnd(1, #pool)]
    local kind = S.kindOf(text)
    player:timer(rnd(S.ANSWER_MIN, S.ANSWER_MAX) * 1000, function(entity)
        if S.isMember(entity, mate) then
            S.say(entity, mate, written(entity, mate, kind))
        end
    end)
end

-- squad.lua's chatRead: where an AI line of this mate goes. The linkshell, while an answer to your linkshell line is
-- awaited and the mate is a member; nil = party chat as always.
S.channelForReply = function(player, mateName)
    if os.time() > player:getLocalVar('SQUAD_SHELL_AI_UNTIL') then
        return nil
    end

    for _, mate in ipairs(S.members(player)) do
        if mate.name == mateName then
            return S.channel(player)
        end
    end

    return nil
end

-- once in a while a member that is not out says what it is up to
local function idleLook(player, stamp)
    if player:getLocalVar('SQUAD_SHELL_RUN') ~= stamp then
        return -- (a newer round is running: after zoning, or after a member joined)
    end

    local wait = rnd(S.IDLE_MIN, S.IDLE_MAX)
    local away = {}
    if S.channel(player) ~= nil and os.time() - player:getLocalVar('SQUAD_SHELL_LAST') >= S.QUIET_AFTER_YOU then
        local out = outNow(player)
        for _, mate in ipairs(S.members(player)) do
            if not out[mate.id] then
                away[#away + 1] = mate
            end
        end
    end

    if #away > 0 then
        local mate = away[rnd(1, #away)]
        S.say(player, mate, written(player, mate, 'upTo'))
    end

    player:timer(wait * 1000, function(entity)
        idleLook(entity, stamp)
    end)
end

S.start = function(player, first)
    S.rounds = (S.rounds or 0) + 1 -- (a number no other round has: the round before this one stops when it sees it)
    local stamp = S.rounds
    player:setLocalVar('SQUAD_SHELL_RUN', stamp)
    player:timer(rnd(S.IDLE_MIN, S.IDLE_MAX) * 1000, function(entity)
        idleLook(entity, stamp)
    end)

    -- hello when you log in (not at every zone line)
    if first then
        player:timer(rnd(8, 15) * 1000, function(entity)
            local members = S.members(entity)
            if #members > 0 then
                local mate = members[rnd(1, #members)]
                S.say(entity, mate, written(entity, mate, 'hello'))
            end
        end)
    end
end

-- squad.lua's xi.player.onGameIn: zoning = you crossed a zone line (timers do not come along), else you logged in
S.onGameIn = function(player, zoning)
    if #S.members(player) > 0 then
        S.start(player, not zoning)
    end
end

-- !squad ls [<slot | all> on | off]
S.command = function(player, say, arg1, arg2)
    local squad = squadOf(player)
    local who, word = string.lower(tostring(arg1 or '')), string.lower(tostring(arg2 or ''))
    if who == '' then
        local names = {}
        for _, mate in ipairs(S.members(player)) do
            names[#names + 1] = mate.name
        end

        if #names == 0 then
            say(player, 'None of your squad mates are on your linkshell. !squad ls <slot | all> on   - a mate joins   |   off - it leaves')
        else
            say(player, 'On your linkshell: ' .. table.concat(names, ', ') .. '.   !squad ls <slot | all> on | off')
        end

        if S.channel(player) == nil then
            say(player, 'You are not wearing a linkshell: equip one of yours and their lines appear on it.')
        end

        return
    end

    if word ~= 'on' and word ~= 'off' then
        say(player, '!squad ls <slot | all> on | off   - put a squad mate on your linkshell, or take it off')
        return
    end

    local slot = tonumber(who)
    local changed = {}
    for _, mate in ipairs(squad) do
        if who == 'all' or mate.slot == slot then
            player:setCharVar(S.memberVar(mate.id), word == 'on' and 1 or 0)
            changed[#changed + 1] = mate.name
        end
    end

    if #changed == 0 then
        say(player, string.format('You have no squad mate in slot %s.', tostring(arg1)))
        return
    end

    if word == 'on' then
        say(player, table.concat(changed, ', ') .. (#changed == 1 and ' is' or ' are') .. ' on your linkshell now.')
        if S.channel(player) == nil then
            say(player, 'You are not wearing a linkshell: equip one of yours and their lines appear on it.')
        end

        S.start(player, false)
    else
        say(player, table.concat(changed, ', ') .. (#changed == 1 and ' has' or ' have') .. ' left your linkshell.')
    end
end

return S
