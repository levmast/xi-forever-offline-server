-----------------------------------
-- Squads thin C++, step 1: party chat commands ("cure", "all haste", "Kasumi cure Momo", "2hr", "provoke", ...)
--
-- Before this step squad.cpp parsed the chat line itself (handleSpellChat 222 lines + handleAbilityChat 52 lines), asked
-- the mates, ranked the failures and called xi.squad.onSpellCommand / onAbilityCommand. Now squad.cpp only decodes the
-- packet (text, auto-translate bytes) and calls xi.squad.onChatCommand(player, text, hadAutoTranslate); everything else is
-- here, so a rule change (the word limit, who is asked first, how failures rank, which words mean "two hour") is a Lua edit
-- that the hot reload (tools/squads/hot_reload) picks up with no restart.
--
-- The C++ side keeps what needs the engine: six small bindings (squad.cpp, registered with the others)
--   SquadSpellIdByName(name)            -> spell id | nil          (the server's spell name table)
--   SquadAbilityIdByName(name)          -> ability id | nil        (job abilities only, never pet abilities)
--   SquadAbilityName(abilityId)         -> name | nil
--   SquadTwoHourAbilityId(mate)         -> ability id | nil        (the mate's main job two-hour ability)
--   SquadCastSpell(player, mate, spellId, targetOrNil) -> 'cast' | 'unknown' | 'notready' | 'notarget' | 'busy'
--   SquadTryAbility(player, mate, abilityId) -> the same result names
--
-- Load order: after squad.lua (it calls xi.squad.onSpellCommand / onAbilityCommand by name, at call time).
-----------------------------------
require('modules/module_utils')

xi = xi or {}
xi.squad = xi.squad or {}

SQUAD_LOGIC = SQUAD_LOGIC or {}
local L = SQUAD_LOGIC

L.version = 1
L.MAX_WORDS = 6 -- a chat line of more words than this is just chat

-- the words that mean "use your two-hour ability"
L.TWO_HOUR_WORDS =
{
    ['2hr'] = true, ['2_hr'] = true, ['2hour'] = true, ['2_hour'] = true, ['two_hour'] = true, ['twohour'] = true,
    ['1hr'] = true, ['1_hr'] = true, ['sp'] = true, ['sp1'] = true, ['sp_ability'] = true,
}

-- Brackets, colons and quotes are not part of a spell name ("{Utsusemi: Ichi}" -> "utsusemi ichi"); apostrophes disappear
local SYMBOLS = { ['{'] = true, ['}'] = true, ['['] = true, [']'] = true, ['('] = true, [')'] = true, ['<'] = true, ['>'] = true, [':'] = true, [';'] = true, [','] = true, ['"'] = true }

function L.clean(text)
    local out = {}
    for i = 1, #text do
        local c = text:sub(i, i)
        if c ~= "'" then
            out[#out + 1] = SYMBOLS[c] and ' ' or c
        end
    end

    text = table.concat(out):lower()
    while #text > 0 do
        local last = text:sub(-1)
        if last == '.' or last == '!' or last == '?' or last == ' ' then
            text = text:sub(1, -2)
        else
            break
        end
    end

    return text
end

function L.words(text)
    local words = {}
    for word in text:gmatch('%S+') do
        words[#words + 1] = word
    end

    return words
end

local function join(list, from, to)
    return table.concat(list, '_', from or 1, to or #list)
end

-- the failure that explains most: not ready beats no target beats busy beats "I do not know that"
local RANK = { notready = 4, notarget = 3, busy = 2 }

local function rank(result)
    return RANK[result] or 1
end

local function nameOf(entity)
    local name = entity:getPacketName()
    if name == nil or name == '' then
        name = entity:getName()
    end

    return (name or ''):lower()
end

-- the squad mates that are out and alive
function L.mates(player)
    local out = {}
    local req = rawget(_G, 'SQUAD_REQ') -- squad_requests.lua (v0.3.3 fixes); absent or off: every mate that is out and alive is asked
    for _, member in pairs(player:getPartyWithTrusts()) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') > 0 and member:isAlive()
            and (xi.squad.mine == nil or xi.squad.mine(player, member))
            and (req == nil or req.mayAnswer == nil or req.mayAnswer(player, member)) then
            out[#out + 1] = member
        end
    end

    return out
end

local function report(fn, ...)
    local handler = xi.squad[fn]
    if type(handler) == 'function' then
        local ok, err = pcall(handler, ...)
        if not ok then
            print('[squad_logic] ' .. fn .. ' failed: ' .. tostring(err))
        end
    end
end

-- Party chat named a job ability (or "2hr"): the first mate who can uses it ("all" = everyone who can)
function L.abilityChat(player, askedMates, everyone, name)
    local twoHour = L.TWO_HOUR_WORDS[name] == true
    local namedId = nil
    if not twoHour then
        namedId = SquadAbilityIdByName(name)
        if namedId == nil then
            return -- just chat
        end
    end

    local anyUsed        = false
    local worstFailure   = 'unknown'
    local failureSpeaker = askedMates[1]
    local failureId      = namedId

    for _, mate in ipairs(askedMates) do
        local abilityId = twoHour and SquadTwoHourAbilityId(mate) or namedId
        if abilityId ~= nil then
            local result = SquadTryAbility(player, mate, abilityId)
            if result == 'cast' or result == 'busy' then
                -- busy: onAbilityCommand tries again for a few seconds, so this mate has taken the request
                anyUsed = true
                report('onAbilityCommand', player, mate, SquadAbilityName(abilityId) or name, result, abilityId)
                if not everyone then
                    return
                end
            elseif rank(result) > rank(worstFailure) or failureId == nil then
                worstFailure, failureSpeaker, failureId = result, mate, abilityId
            end
        end
    end

    if not anyUsed and failureId ~= nil then
        report('onAbilityCommand', player, failureSpeaker, SquadAbilityName(failureId) or name, worstFailure, failureId)
    end
end

-- Typing a spell name in party chat (optionally "all" or a squad mate's name first) makes squad mates cast it.
-- text is already decoded (auto-translate bytes turned into words); the chat message itself is never blocked.
function L.onChat(player, text, hadAutoTranslate)
    -- (v0.3.3) squad_requests.lua reads the line first when its extras are on (!sqreq more on): looser words, groups, the best spell; true = done
    local req = rawget(_G, 'SQUAD_REQ')
    if req ~= nil and req.pre ~= nil then
        local ok, handled = pcall(req.pre, player, text, hadAutoTranslate)
        if ok and handled then
            return
        elseif not ok then
            print('[squad_logic] squad_requests failed: ' .. tostring(handled))
        end
    end

    local words = L.words(L.clean(text))
    if #words == 0 or #words > L.MAX_WORDS then
        return
    end

    local mates = L.mates(player)
    if #mates == 0 then
        return
    end

    -- Optional first word: "all" (everyone who can) or one squad mate's name
    local everyone, askedMates = false, mates
    if #words > 1 then
        if words[1] == 'all' then
            everyone = true
            table.remove(words, 1)
        else
            for _, mate in ipairs(mates) do
                if mate:getPacketName():lower() == words[1] then
                    askedMates = { mate }
                    table.remove(words, 1)
                    break
                end
            end
        end
    end

    local spellName = join(words)
    local spellId   = SquadSpellIdByName(spellName)

    -- Optional target at the end: "cure momo", "cure on momo", "protect me": a party member (you, a squad mate, another
    -- player or bot in your party). Only used when the words before it are a spell and the whole text is not one.
    local named = nil
    if spellId == nil and #words > 1 then
        local last, found = words[#words], nil
        if last == 'me' or last == 'myself' then
            found = player
        else
            for _, member in pairs(player:getPartyWithTrusts()) do
                if found == nil and member ~= nil and nameOf(member) == last then
                    found = member
                end
            end
        end

        if found ~= nil then
            local restEnd = #words - 1
            if restEnd > 1 and words[restEnd] == 'on' then
                restEnd = restEnd - 1
            end

            local restName = join(words, 1, restEnd)
            local namedSpell = SquadSpellIdByName(restName)
            if namedSpell ~= nil then
                spellName, spellId, named = restName, namedSpell, found
            end
        end
    end

    if hadAutoTranslate then
        print(string.format("[SQUAD] auto-translate in party chat read as '%s' -> %s", spellName, spellId ~= nil and 'spell found' or 'no spell with that name'))
    end

    if spellId == nil then
        L.abilityChat(player, askedMates, everyone, spellName)
        return
    end

    -- (v0.3.3) squad_requests.lua asks, claims and answers a spell request when it is loaded and its fixes are on; true = done
    local req = rawget(_G, 'SQUAD_REQ')
    if req ~= nil and req.cast ~= nil then
        local ok, handled = pcall(req.cast, player, askedMates, everyone, spellId, spellName, named, text)
        if ok and handled then
            return
        elseif not ok then
            print('[squad_logic] squad_requests failed: ' .. tostring(handled))
        end
    end

    -- Ask in order. One cast is enough unless "all" was said. If nobody can, report the most useful reason
    local anyCast, worstFailure, failureSpeaker = false, 'unknown', askedMates[1]
    for _, mate in ipairs(askedMates) do
        local result = SquadCastSpell(player, mate, spellId, named)
        if result == 'cast' then
            anyCast = true
            report('onSpellCommand', player, mate, spellName, result)
            if not everyone then
                return
            end
        elseif rank(result) > rank(worstFailure) then
            worstFailure, failureSpeaker = result, mate
        end
    end

    if not anyCast then
        report('onSpellCommand', player, failureSpeaker, spellName, worstFailure)
    end
end

-- what squad.cpp calls (resolved by name at call time, so an edit and a reload take effect at once)
xi.squad.onChatCommand = function(player, text, hadAutoTranslate)
    local ok, err = pcall(L.onChat, player, text, hadAutoTranslate)
    if not ok then
        print('[squad_logic] chat command failed: ' .. tostring(err))
    end
end

return L
