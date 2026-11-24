-----------------------------------
-- Squad requests (XI Forever v0.3.3): what happens after a party chat line like "sneak", "all haste" or "poppelle cure me" was read.
--
-- squad_logic.lua (the thin chat layer) reads the words and asks this file at two points:
--   SQUAD_REQ.mayAnswer(player, mate)   may this mate answer a chat order at all?
--   SQUAD_REQ.cast(...)                 the asking, claiming and answering of one spell request
-- Everything here is a fix of something the party chat did wrong (docs: PARTY_REQUESTS_AUDIT, items G1 to G20), each one in its own
-- section below, and each one is switched off by one setting, so a player who wants the exact v0.3.2 behavior has it:
--
--   !sqreq              what is on
--   !sqreq off | on     all of the fixes (character variable SQREQ_OFF, default: on)
--   !sqreq more on|off  the extras that change what a line means: looser words, groups, best spell, ... (default: on since v0.3.3a; `!sqreq more off` turns them off, character variable SQREQ_MORE_OFF)
--
-- With the fixes off, or with this file removed from init.txt, squad_logic.lua does exactly what it did before.
-- Hot reloadable (tools/squads/hot_reload). Load order: after squad_logic.lua.
-----------------------------------
require('modules/module_utils')

xi = xi or {}
xi.squad = xi.squad or {}

SQUAD_REQ = SQUAD_REQ or {}
local R = SQUAD_REQ

R.version = 1

-----------------------------------
-- settings
-----------------------------------
local function charVar(player, name)
    local ok, value = pcall(function()
        return player:getCharVar(name)
    end)

    if ok and type(value) == 'number' then
        return value
    end

    return 0
end

-- the fixes are on unless the player turned them off
function R.on(player)
    return charVar(player, 'SQREQ_OFF') ~= 1
end

-- the extras that change what a line means are on unless the player turned them off (!sqreq more off). v0.3.3a: on by default;
-- SQREQ_MORE_OFF = 1 is "turned off" (an unset character variable reads 0, so "off" has to be the stored value)
function R.more(player)
    return R.on(player) and charVar(player, 'SQREQ_MORE_OFF') ~= 1
end

-----------------------------------
-- G15: a mate that is stopped does not answer chat orders
-- "!idle on" (squad_idle.lua) and Actions OFF (squad_actions.lua) set SQUAD_IDLE: that mate does nothing until you let it. A mate that
-- another system owns (ADDON_OWNED, set by the hook in squad.lua) acts through that system's own lines, not through a chat order.
-----------------------------------
function R.mayAnswer(player, mate)
    if not R.on(player) then
        return true
    end

    local ok, idle, owned = pcall(function()
        return mate:getLocalVar('SQUAD_IDLE'), mate:getLocalVar('ADDON_OWNED')
    end)

    if ok and ((idle or 0) ~= 0 or (owned or 0) ~= 0) then
        return false
    end

    return true
end

-----------------------------------
-- the request: ask the mates, claim it, answer it
-----------------------------------
local function now()
    return os.time()
end

local function idOf(entity)
    local ok, id = pcall(function()
        return entity:getID()
    end)

    return ok and id or 0
end

-- the failure that explains most: not ready beats no target beats busy beats "I do not know that" (the same order as squad_logic.lua)
local RANK = { notready = 4, notarget = 3, busy = 2 }

local function rank(result)
    return RANK[result] or 1
end

local function report(player, mate, spellName, result)
    local handler = xi.squad.onSpellCommand
    if type(handler) == 'function' then
        local ok, err = pcall(handler, player, mate, spellName, result)
        if not ok then
            print('[squad_requests] onSpellCommand failed: ' .. tostring(err))
        end
    end
end

-- Lines of this file's own (squad.lua's voices have none for these events). Printed in party chat as the mate, like every Squads line.
R.LINES = R.LINES or {}
R.LINES.selfonly = {
    '{spell} only works on whoever casts it, I cannot put it on you.',
    'I cannot cast {spell} on you, it only takes the caster.',
}

R.LINES.noraise = {
    'Nobody is down, there is nobody to raise.',
    'You are standing and so is everyone else, no Raise needed.',
}

R.LINES.already = {
    '{who} already has {spell}.',
    '{spell} is already on {who}.',
}
R.LINES.noneed = {
    'There is nothing to cure on {who}.',
    '{who} does not need {spell} right now.',
}
R.LINES.standing = {
    '{who} is standing, no Raise needed.',
}
R.LINES.refuse = {
    '{why}',
}
R.LINES.fed = {
    'Nobody is hungry, everyone has eaten.',
    'We are fed, nothing more to eat right now.',
}
R.LINES.failed = {
    'That {spell} did not land.',
    '{spell} fizzled, it did not take. Ask again.',
}

-- 'cure_iv' -> 'Cure IV'
local function pretty(name)
    local text = tostring(name):gsub('_', ' ')
    text = text:gsub('(%a)([%w]*)', function(first, rest)
        local word = first .. rest
        if word:match('^[ivxIVX]+$') then
            return word:upper()
        end

        return first:upper() .. rest
    end)

    return text
end

local function say(player, mate, event, vars)
    local lines = R.LINES[event]
    if lines == nil or #lines == 0 then
        return
    end

    local text = lines[math.random(#lines)]
    text = text:gsub('{(%w+)}', function(key)
        return tostring((vars or {})[key] or '')
    end)

    pcall(function()
        player:printToPlayer(text, 4, mate:getPacketName())
    end)
end

-- what the spell can be cast on: 'enemy' | 'dead' | 'party' | 'self' | '' (the binding of the rebuilt squad.cpp is missing: leave the line to squad_logic.lua)
local function kindOf(spellId)
    local f = rawget(_G, 'SquadSpellKind')
    if type(f) ~= 'function' then
        return ''
    end

    local ok, kind = pcall(f, spellId)
    return ok and kind or ''
end

-----------------------------------
-- G16: typing the same line again does not cast again
-- A cast that was accepted keeps (spell, person) taken while it is being cast and a moment after. A repeat of the line
-- finds it taken and is ignored; before, a mate that was mid-cast answered "busy" and the NEXT mate cast the same spell on the same person. Attack spells are not claimed (casting "stone" again is a new nuke, and the recast already limits it).
-----------------------------------
R.CLAIM_PAD = 2 -- seconds after the cast time
R.claims = R.claims or {} -- [player id] = { ['spell:target'] = until }

-- the cast time of a spell in seconds (the server's spell table: milliseconds); 5 when it cannot be read
local function castSeconds(spellId)
    local ok, seconds = pcall(function()
        local ms = GetSpell(spellId):getCastTime()
        return ms > 100 and ms / 1000 or ms
    end)

    if ok and type(seconds) == 'number' and seconds > 0 then
        return math.min(seconds, 30)
    end

    return 5
end

local function claimKey(spellId, target)
    return tostring(spellId) .. ':' .. tostring(idOf(target))
end

function R.taken(player, spellId, target)
    local mine = R.claims[idOf(player)]
    local untilT = mine ~= nil and mine[claimKey(spellId, target)] or nil
    return untilT ~= nil and untilT > now()
end

function R.claim(player, spellId, target)
    local key = idOf(player)
    local mine = R.claims[key] or {}
    R.claims[key] = mine
    for k, untilT in pairs(mine) do
        if untilT <= now() then
            mine[k] = nil
        end
    end

    mine[claimKey(spellId, target)] = now() + castSeconds(spellId) + R.CLAIM_PAD
end

-----------------------------------
-- G5: the acknowledgement comes when the cast landed, and a cast that did not land is said so
-- Before, "On it: Sneak!" came the moment the engine accepted the cast; an interrupt, a mate that died or an out of range target ended in
-- silence after a cheerful line. For the spells that leave an effect on the target (Sneak, Invisible, Haste, Protect, ...) the mate now
-- answers when the effect is on, after the cast time. Not landed after that: one line saying so, and the claim of G16 is let go so asking again
-- works. Spells without a visible effect (Cure, Raise, attacks) are answered at accept, as before: nothing can be read to say more.
-----------------------------------
R.EFFECT = R.EFFECT or {
    sneak = 'SNEAK', invisible = 'INVISIBLE', deodorize = 'DEODORIZE', haste = 'HASTE', protect = 'PROTECT', shell = 'SHELL', blink = 'BLINK',
    stoneskin = 'STONESKIN', phalanx = 'PHALANX', regen = 'REGEN', refresh = 'REFRESH', aquaveil = 'AQUAVEIL',
}
R.LAND_TRIES = 3 -- looks at the target: one second after the cast time, then every two seconds

local function effectOf(spellName)
    local base = tostring(spellName):gsub('_[ivx]+$', '')
    local name = R.EFFECT[base]
    return name ~= nil and xi.effect ~= nil and xi.effect[name] or nil
end

function R.release(player, spellId, target)
    local mine = R.claims[idOf(player)]
    if mine ~= nil then
        mine[claimKey(spellId, target)] = nil
    end
end

function R.acknowledge(player, mate, spellName, spellId, target)
    local effect = effectOf(spellName)
    if effect == nil then
        report(player, mate, spellName, 'cast')
        return
    end

    local tries = 0
    local function look()
        tries = tries + 1
        local ok, landed = pcall(function()
            return target:hasStatusEffect(effect)
        end)

        if ok and landed then
            report(player, mate, spellName, 'cast')
        elseif tries < R.LAND_TRIES then
            mate:timer(2000, look)
        else
            R.release(player, spellId, target)
            say(player, mate, 'failed', { spell = pretty(spellName) })
        end
    end

    local ok = pcall(function()
        mate:timer(math.floor((castSeconds(spellId) + 1) * 1000), look)
    end)

    if not ok then
        report(player, mate, spellName, 'cast') -- no timer to wait with: answer now, as before
    end
end

-- G9: the first person of your party who is knocked out, in the same zone (a squad mate cannot be raised: it is called again)
local function firstFallen(player)
    local ok, party = pcall(function()
        return player:getPartyWithTrusts()
    end)

    for _, member in pairs(ok and party or {}) do
        local isPlayer = member:getObjType() == xi.objType.PC
        if isPlayer and member:isDead() and member:getZoneID() == player:getZoneID() then
            return member
        end
    end

    return nil
end

-----------------------------------
-- G1: one answerer between the squad mates and the bot players
-- The mates (squad.cpp, listed first in init.txt) and the bots (bots.cpp) read the same party chat line and used to know nothing of each
-- other: with a mate and a bot that both could Sneak you got two Sneaks and two "On it". A request a mate took is now marked here, and the
-- bots' own request code asks before it acts (bots.lua: xi.squad.requestTaken, xi.squad.lineTaken). If no mate can, the bots keep the line.
-----------------------------------
R.LINE_SECONDS = 6
R.lines = R.lines or {} -- [player id] = { text = 'normalised', untilT = time }

local function norm(text)
    return (tostring(text or ''):lower():gsub('[^%w]', ''))
end

function R.markLine(player, text)
    R.lines[idOf(player)] = { text = norm(text), untilT = now() + R.LINE_SECONDS }
end

function R.lineTaken(player, text)
    if not R.on(player) then
        return false
    end

    local line = R.lines[idOf(player)]
    return line ~= nil and line.untilT > now() and line.text == norm(text)
end

xi.squad.lineTaken = function(player, text)
    return R.lineTaken(player, text)
end

xi.squad.requestsOn = function(player)
    return R.on(player)
end

xi.squad.requestsMore = function(player)
    return R.more(player)
end

xi.squad.requestTaken = function(player, spellId, target)
    return R.on(player) and R.taken(player, spellId, target)
end

xi.squad.requestClaim = function(player, spellId, target)
    if R.on(player) then
        R.claim(player, spellId, target)
    end
end

-- the same request is on its way for this person when any tier of the family is claimed on them
function R.takenFamily(player, unit)
    for _, tier in ipairs(unit.tiers) do
        if R.taken(player, tier.id, unit.target) then
            return true
        end
    end

    return false
end

-- squad_logic.lua hands a spell request over: the mates it asks (in order), "all", the spell, the named target (or nil = you).
-- Returns true when the request was answered here, false to let squad_logic.lua run the old loop.
function R.cast(player, askedMates, everyone, spellId, spellName, named, text)
    if not R.on(player) then
        return false
    end

    local kind = kindOf(spellId)
    if kind == '' then
        return false
    end

    -- G9: Raise goes on someone who is knocked out and on nobody else. "raise" with nobody named means the person who is down: you, else the first
    -- fallen member of the party. Before, "raise" while you stood and a friend lay dead was "nothing to cast on", and nobody was told why.
    if kind == 'dead' and named == nil and not player:isDead() then
        named = firstFallen(player)
        if named == nil then
            say(player, askedMates[1], 'noraise', {})
            R.markLine(player, text)
            return true
        end
    end

    local target = named or player

    -- G2: "all <spell>" for a spell that goes on a person (Sneak, Protect, Haste, Cure, Raise) is ONE cast on that person. Before, every mate
    -- that could cast it did, so "all protect" gave you Protect three times and three acknowledgements. "all" keeps its meaning for attack
    -- spells: every mate that can casts at the enemy.
    if everyone and kind ~= 'enemy' then
        everyone = false
    end

    -- G6: a spell that only works on its caster (Warp, Escape, Reraise, Utsusemi, Tonko) cannot be put on you. Before, "warp" was accepted (a false
    -- "On it") or answered with the misleading "nothing to cast on". One mate says what is true, once.
    if kind == 'self' and not (named ~= nil and #askedMates == 1 and askedMates[1] == named) then
        say(player, askedMates[1], 'selfonly', { spell = pretty(spellName) })
        R.markLine(player, text)
        return true
    end

    if kind ~= 'enemy' and R.taken(player, spellId, target) then
        print(string.format('[squad_requests] %s on %s is taken (a cast is on its way): the repeated line is ignored', spellName, tostring(target:getName())))
        R.markLine(player, text)
        return true
    end

    -- ask in order; one cast is enough unless "all" was said; nobody can: the most useful reason
    local anyCast, worstFailure, failureSpeaker = false, 'unknown', askedMates[1]
    for _, mate in ipairs(askedMates) do
        local result = SquadCastSpell(player, mate, spellId, named)
        if result == 'cast' then
            anyCast = true
            if kind ~= 'enemy' then
                R.claim(player, spellId, target)
            end

            R.markLine(player, text)
            R.acknowledge(player, mate, spellName, spellId, target)
            if not everyone then
                return true
            end
        elseif rank(result) > rank(worstFailure) then
            worstFailure, failureSpeaker = result, mate
        end
    end

    if not anyCast then
        report(player, failureSpeaker, spellName, worstFailure)
    end

    return true
end

-----------------------------------
-- G4 (extra): looser words
-- "sneak please", "i need invis", "can you cure me?", "poppelle sneak", "invis" were not spells to the party chat (the whole line had to be a spell
-- name, plus "me" or a name), so they did nothing and said nothing, which looks like a broken mate. With the extras on, a line made of a request
-- word, filler words ("please", "can you", "i need"), and a target is a request. A line with any other word in it ("we should sneak past the
-- undead", "sneak attack") is conversation and goes to the old chat unchanged. The words are in squad_requests_data.lua.
-----------------------------------
local function data()
    local ok, mod = pcall(require, 'modules/custom/lua/squad_requests_data')
    if ok and type(mod) == 'table' then
        return mod
    end

    return nil
end

function R.tokens(text)
    if type(text) ~= 'string' then
        return {}
    end

    local lowered = text:lower():gsub("'", ''):gsub('[^%w]+', ' ')
    local out = {}
    for word in lowered:gmatch('%S+') do
        out[#out + 1] = word
    end

    return out
end

-- phrase -> { keys = {...}, implicit = bool }, built again when the data module is a new table (a hot reload)
local function index(d)
    if R.indexOf == d and R.index ~= nil then
        return R.index
    end

    local idx = {}
    local function add(phrase, entry)
        local key = table.concat(R.tokens(phrase), ' ')
        if key ~= '' and idx[key] == nil then
            idx[key] = entry
        end
    end

    for _, key in ipairs(d.ORDER) do
        local f = d.FAMILIES[key]
        for _, w in ipairs(f.words or {}) do
            add(w, { keys = { key } })
        end

        for _, w in ipairs(f.phrases or {}) do
            add(w, { keys = { key }, implicit = true })
        end
    end

    for word, keys in pairs(d.BUNDLES or {}) do
        add(word, { keys = keys })
    end

    R.index, R.indexOf = idx, d
    return idx
end

-- env.member(word) -> a party member whose name is that word; env.mate(word) -> a squad mate with that name (both optional)
-- Returns nil when the line is not a request, else { keys, tiers, me, group, members, asked, implicit }
function R.parse(d, text, env)
    env = env or {}
    local trimmed = tostring(text or ''):match('^%s*(.-)%s*$')
    local first = trimmed:sub(1, 1)
    if trimmed == '' or first == '!' or first == '/' then
        return nil
    end

    local toks = R.tokens(trimmed)
    if #toks == 0 or #toks > d.MAX_WORDS then
        return nil
    end

    local intent = { keys = {}, tiers = {}, me = false, group = false, members = {}, asked = nil, implicit = true }
    local used = {}
    if #toks > 1 and env.mate ~= nil then -- a mate's name first: only she is asked
        local mate = env.mate(toks[1])
        if mate ~= nil then
            intent.asked, used[1] = mate, true
        end
    end

    local idx = index(d)
    local i = 1
    while i <= #toks do
        local took = false
        if not used[i] then
            for len = math.min(3, #toks - i + 1), 1, -1 do
                local free = true
                for j = i, i + len - 1 do
                    if used[j] then
                        free = false
                    end
                end

                local entry = free and idx[table.concat(toks, ' ', i, i + len - 1)] or nil
                if entry ~= nil then
                    for j = i, i + len - 1 do
                        used[j] = true
                    end

                    i = i + len
                    for _, key in ipairs(entry.keys) do
                        local seen = false
                        for _, k in ipairs(intent.keys) do
                            seen = seen or k == key
                        end

                        if not seen then
                            intent.keys[#intent.keys + 1] = key
                        end
                    end

                    if not entry.implicit then
                        intent.implicit = false
                    end

                    -- a tier word right after a tiered family: "cure iv", "raise 2"
                    local fam = #entry.keys == 1 and d.FAMILIES[entry.keys[1]] or nil
                    if fam ~= nil and #fam.spells > 1 and toks[i] ~= nil and not used[i] and d.TIER[toks[i]] ~= nil and d.TIER[toks[i]] <= #fam.spells then
                        intent.tiers[entry.keys[1]], used[i] = d.TIER[toks[i]], true
                        i = i + 1
                    end

                    took = true
                    break
                end
            end
        end

        if not took then
            i = i + 1
        end
    end

    if #intent.keys == 0 then
        return nil
    end

    -- who gets it, and the fillers; any other word makes the line conversation
    for k, w in ipairs(toks) do
        if not used[k] then
            if d.ME[w] then
                intent.me = true
            elseif d.GROUP[w] then
                intent.group = true
            elseif env.member ~= nil and env.member(w) ~= nil then
                intent.members[#intent.members + 1] = env.member(w)
            elseif not d.FILLER[w] then
                return nil
            end
        end
    end

    if not intent.me and not intent.group and #intent.members == 0 then
        intent.me = true
    end

    return intent
end

local function nameTokens(entity)
    local ok, name = pcall(function()
        return entity:getPacketName()
    end)

    if not ok or name == nil or name == '' then
        ok, name = pcall(function()
            return entity:getName()
        end)
    end

    return table.concat(R.tokens(ok and name or ''), ' ')
end

local function party(player)
    local ok, list = pcall(function()
        return player:getPartyWithTrusts()
    end)

    local out = {}
    for _, member in pairs(ok and list or {}) do
        out[#out + 1] = member
    end

    return out
end

local function spellIdOf(name)
    local id = type(SquadSpellIdByName) == 'function' and SquadSpellIdByName(name:lower()) or nil
    if id == nil and xi.magic ~= nil and xi.magic.spell ~= nil then
        id = xi.magic.spell[name:upper()]
    end

    return id
end

-- squad_logic.lua asks first, when the extras are on: true = the line was a request and is done
function R.pre(player, text, hadAutoTranslate)
    if not R.more(player) then
        return false
    end

    local d = data()
    local logic = rawget(_G, 'SQUAD_LOGIC')
    if d == nil or logic == nil or logic.mates == nil then
        return false
    end

    local mates = logic.mates(player)
    if #mates == 0 then
        return false
    end

    local everyone = party(player)
    local intent = R.parse(d, text, {
        member = function(word)
            for _, member in ipairs(everyone) do
                if nameTokens(member) == word then
                    return member
                end
            end
        end,
        mate = function(word)
            for _, mate in ipairs(mates) do
                if nameTokens(mate) == word then
                    return mate
                end
            end
        end,
    })

    if intent == nil then
        return false
    end

    return R.run(player, mates, intent, text, d)
end

-----------------------------------
-- G3 (extra): a group is a target
-- "sneak us", "protect everyone", "invis party", "haste all" were silent no-ops (one target only: you, or one name). With the extras on, "us",
-- "everyone", "party", "team", "all" mean every living member of the party who can take the spell (people; squad mates too for the spells
-- that are good for them). One request, one acknowledgement: the casts are spread over the mates that are free, and a mate that is still
-- casting is waited for, a second at a time, up to R.BUSY_RETRIES seconds.
-----------------------------------
R.BUSY_RETRIES = 12
R.MAX_UNITS = 12 -- most casts of one request

local function isPlayer(entity)
    local ok, kind = pcall(function()
        return entity:getObjType()
    end)

    return ok and kind == xi.objType.PC
end

local function sameZone(a, b)
    local ok, same = pcall(function()
        return a:getZoneID() == b:getZoneID()
    end)

    return ok and same
end

local function isDown(entity)
    local ok, down = pcall(function()
        return entity:isDead()
    end)

    return ok and down == true
end

-- who a group request is about: you first, then the party in its order
local function groupTargets(player, fam)
    local out = {}
    for _, member in ipairs(party(player)) do
        local ok = sameZone(player, member) and (isPlayer(member) or fam.scope == 'all')
        if ok and fam.dead then
            ok = isPlayer(member) and isDown(member)
        elseif ok then
            ok = not isDown(member)
        end

        if ok then
            if idOf(member) == idOf(player) then
                table.insert(out, 1, member)
            else
                out[#out + 1] = member
            end
        end
    end

    return out
end

local function finish(req)
    if req.finished then
        return
    end

    req.finished = true
    -- every unit that nobody could do: one line, the likeliest reason, from the mate that fits the request best
    local worst, speaker, spell = 'unknown', nil, nil
    for _, unit in ipairs(req.units) do
        if unit.state == 'failed' and rank(unit.why) > rank(worst) then
            worst, speaker, spell = unit.why, unit.mate or req.asked[1], unit.spellName
        elseif unit.state == 'failed' and spell == nil then
            speaker, spell = unit.mate or req.asked[1], unit.spellName
        end
    end

    if spell ~= nil and not req.acked then
        report(req.player, speaker or req.asked[1], spell, worst)
    end

    -- nothing was cast and nothing failed: say why, once (everyone has it already, nobody needs it, nobody is down)
    if not req.acked and spell == nil and req.said ~= nil then
        local voice = req.asked[1]
        say(req.player, voice, req.said.kind, req.said.facts)
    end
end

-----------------------------------
-- G8 (extra): is it needed, and who is the best one to do it
-- Cure at full health, a -na with nothing to cure and a buff that is already on all cast before, and the first mate in call order cast even when a
-- better healer or a mate with more MP was out. With the extras on: a request nobody needs is answered once ("Sunie already has Sneak", "there is
-- nothing to cure on Jon") and not cast; and the mate who casts is chosen: the job that fits the request first (a White Mage for Cure, a Red Mage for
-- Sneak), then the most MP left, then the nearest, then the order of the squad. A named mate is always the one asked.
-----------------------------------
local function effectId(name)
    return name ~= nil and xi.effect ~= nil and xi.effect[name] or nil
end

local function hasEffect(entity, name)
    local id = effectId(name)
    if id == nil then
        return false
    end

    local ok, has = pcall(function()
        return entity:hasStatusEffect(id)
    end)

    return ok and has == true
end

-- why this person needs nothing from this family, or nil when they do
local function noNeed(d, fam, target)
    if fam.need == 'hp' then
        local ok, hpp = pcall(function()
            return target:getHPP()
        end)

        if ok and hpp ~= nil and hpp >= d.NEED_HP then
            return 'noneed'
        end
    elseif fam.need == 'status' then
        for _, name in ipairs(fam.cures or {}) do
            if hasEffect(target, name) then
                return nil
            end
        end

        return 'noneed'
    elseif fam.effect ~= nil and hasEffect(target, fam.effect) then
        return 'already'
    end

    return nil
end

local function roleOf(mate, fam)
    local ok, job = pcall(function()
        return mate:getMainJob()
    end)

    for n, role in ipairs(fam.roles or {}) do
        if ok and role == job then
            return n
        end
    end

    return 9
end

-- the mates in the order they are asked for this unit
local function ordered(req, unit)
    if #req.asked == 1 then
        return req.asked
    end

    local fam = req.d.FAMILIES[unit.fam]
    local list = {}
    for i, mate in ipairs(req.asked) do
        local okM, mp = pcall(function()
            return mate:getMP()
        end)

        local okD, dist = pcall(function()
            return mate:checkDistance(unit.target)
        end)

        list[#list + 1] = { mate = mate, role = roleOf(mate, fam), mp = okM and mp or 0, dist = okD and dist or 0, i = i }
    end

    table.sort(list, function(a, b)
        if a.role ~= b.role then
            return a.role < b.role
        elseif a.mp ~= b.mp then
            return a.mp > b.mp
        elseif a.dist ~= b.dist then
            return a.dist < b.dist
        end

        return a.i < b.i
    end)

    local out = {}
    for _, entry in ipairs(list) do
        out[#out + 1] = entry.mate
    end

    return out
end

-----------------------------------
-- G7 (extra): the best spell she can cast
-- "cure", "protect", "haste" were the first tier even at level 75 (Cure I, Protect I). Without a tier word, every tier is asked best first and
-- the first one she has learned and can pay for is cast: a mate that cannot afford Cure IV casts Cure III. A tier word ("cure ii") is that tier only.
-----------------------------------
-- the spells of a family to ask, best first: { { id = n, name = 'cure_iv' }, ... }
local function tierList(fam, tier)
    local out = {}
    local first, last = #fam.spells, 1
    if tier ~= nil then
        first, last = tier, tier
    end

    for n = first, last, -1 do
        local name = fam.spells[n]
        local id = name ~= nil and spellIdOf(name) or nil
        if id ~= nil then
            out[#out + 1] = { id = id, name = name:lower() }
        end
    end

    return out
end

-- the mates of `list` in order, every tier best first; 'cast' (and who, and which spell), 'busy', or 'failed' (and why, and who)
local function tryList(req, unit, list)
    local sawBusy, worst, worstMate = false, 'unknown', nil
    for _, mate in ipairs(list) do
        local mateWorst = 'unknown'
        for _, tier in ipairs(unit.tiers) do
            local result = SquadCastSpell(req.player, mate, tier.id, unit.named)
            if result == 'cast' then
                return 'cast', mate, tier
            elseif result == 'busy' then
                sawBusy = true
                break -- she is casting: no other tier changes that
            elseif result == 'notarget' then
                mateWorst = 'notarget'
                break
            elseif rank(result) > rank(mateWorst) then
                mateWorst = result -- not enough MP or recasting: the next tier down may still work
            end
        end

        if rank(mateWorst) > rank(worst) or worstMate == nil then
            worst, worstMate = mateWorst, mate
        end
    end

    if sawBusy then
        return 'busy'
    end

    return 'failed', worst, worstMate
end

-----------------------------------
-- G12 (extra): "sneak and invis" is one request for one caster, one after the other
-- Two lines, or one line with two words, were two separate casts that could land on two different mates, each with its own line. With the extras
-- on, a request for several spells on one person goes to ONE mate: the first spell is given to the best caster, and the next ones wait for her
-- (she is casting) instead of going to somebody else, unless she cannot cast it at all. One voice for the whole request.
-----------------------------------
local function tryUnit(req, unit)
    if req.sticky and req.speaker ~= nil then
        local result, a, b = tryList(req, unit, { req.speaker })
        if result == 'cast' or result == 'busy' then
            return result, a, b
        end

        local others = {}
        for _, mate in ipairs(ordered(req, unit)) do
            if mate ~= req.speaker then
                others[#others + 1] = mate
            end
        end

        return tryList(req, unit, others)
    end

    return tryList(req, unit, ordered(req, unit))
end

local function step(req)
    local waiting = false
    for _, unit in ipairs(req.units) do
        if unit.state == 'pending' then
            if R.takenFamily(req.player, unit) then
                unit.state = 'taken'
            else
                local result, a, b = tryUnit(req, unit)
                if result == 'cast' then
                    req.speaker = req.speaker or a
                    unit.state, unit.id, unit.spellName = 'casting', b.id, b.name
                    R.claim(req.player, unit.id, unit.target)
                    R.markLine(req.player, req.text)
                    if not req.acked then
                        req.acked = true
                        R.acknowledge(req.player, a, unit.spellName, unit.id, unit.target)
                    end
                elseif result == 'busy' then
                    waiting = true
                else
                    unit.state, unit.why, unit.mate = 'failed', a, b
                end
            end
        end
    end

    if waiting and req.retries < R.BUSY_RETRIES then
        req.retries = req.retries + 1
        local ok = pcall(function()
            req.player:timer(1000, function()
                step(req)
            end)
        end)

        if not ok then
            finish(req)
        end

        return
    end

    for _, unit in ipairs(req.units) do
        if unit.state == 'pending' then
            unit.state, unit.why, unit.mate = 'failed', 'busy', nil
        end
    end

    finish(req)
end

-----------------------------------
-- G14 (extra): "feed us" has a path
-- "food", "eat", "feed us" did nothing: the mates ate by themselves and by !squad food, but no chat line asked. With the extras on the mates eat now,
-- by the same rules as every combat tick (a stopped mate does not, a level under 11 does not, one that is eating already does not), each in its
-- own voice; when nobody could, one mate says so.
-----------------------------------
function R.feed(player, mates, intent, text)
    local eat = xi.squad.eatNow
    if type(eat) ~= 'function' then
        return false
    end

    local who = intent.asked ~= nil and { intent.asked } or mates
    local ate = 0
    for _, mate in ipairs(who) do
        local before = mate:getLocalVar('SQUAD_FOOD_ID')
        pcall(eat, mate)
        if before == 0 and mate:getLocalVar('SQUAD_FOOD_ID') ~= 0 then
            ate = ate + 1
        end
    end

    R.markLine(player, text)
    if ate == 0 then
        say(player, who[1], 'fed', {})
    end

    return true
end

-- the units of a request (one per family and person) are asked together; true when there was something to do
function R.run(player, mates, intent, text, d)
    local req = { player = player, asked = intent.asked ~= nil and { intent.asked } or mates, units = {}, text = text, retries = 0, acked = false, d = d }
    for _, key in ipairs(intent.keys) do
        local fam = d.FAMILIES[key]
        if fam.kind == 'food' then
            return R.feed(player, mates, intent, text)
        end

        local targets = {}
        local function add(entity)
            for _, t in ipairs(targets) do
                if idOf(t) == idOf(entity) then
                    return
                end
            end

            targets[#targets + 1] = entity
        end

        if intent.group then
            for _, member in ipairs(groupTargets(player, fam)) do
                add(member)
            end
        end

        if intent.me then
            add(player)
        end

        for _, member in ipairs(intent.members) do
            add(member)
        end

        local tiers = tierList(fam, intent.tiers[key])
        if fam.kind == 'caster' then
            req.said = req.said or { kind = 'refuse', facts = { why = fam.refuse or 'I cannot do that.' } }
        elseif #tiers > 0 then
            -- "raise" with nobody named is the person who is down: you, else the first fallen member of the party
            if fam.dead and #targets == 1 and idOf(targets[1]) == idOf(player) and not isDown(player) then
                local fallen = firstFallen(player)
                if fallen == nil then
                    req.said = req.said or { kind = 'noraise', facts = {} }
                    targets = {}
                else
                    targets = { fallen }
                end
            end

            for _, target in ipairs(targets) do
                local who = idOf(target) == idOf(player) and 'you' or tostring(target:getName())
                local facts = { who = who, spell = fam.name }
                local why = nil
                if (fam.dead == true) ~= isDown(target) then
                    why = 'skip'
                    if fam.dead then
                        req.said = req.said or { kind = 'standing', facts = facts }
                    end
                else
                    why = noNeed(d, fam, target)
                    if why ~= nil then
                        req.said = req.said or { kind = why, facts = facts }
                    end
                end

                if why == nil and #req.units < R.MAX_UNITS then
                    req.units[#req.units + 1] = {
                        fam = key, tiers = tiers, id = tiers[1].id, spellName = tiers[1].name, target = target,
                        named = idOf(target) ~= idOf(player) and target or nil, state = 'pending',
                    }
                end
            end
        end
    end

    -- several spells for one person: one caster does them one after the other
    local people = {}
    for _, unit in ipairs(req.units) do
        people[idOf(unit.target)] = true
    end

    local count = 0
    for _ in pairs(people) do
        count = count + 1
    end

    req.sticky = #req.units > 1 and count == 1

    if #req.units == 0 then
        if req.said ~= nil and not intent.implicit then
            R.markLine(player, text)
            finish(req)
            return true
        end

        return false
    end

    step(req)
    return true
end

-----------------------------------
-- !sqreq
-----------------------------------
local function tell(player, text)
    pcall(function()
        player:printToPlayer(text)
    end)
end

function R.status(player)
    tell(player, string.format('squad requests: fixes %s, extras %s', R.on(player) and 'ON' or 'OFF (!sqreq on)', R.more(player) and 'ON (!sqreq more off turns them off)' or 'off (!sqreq more on)'))
end

function R.command(player, a, b)
    a, b = tostring(a or ''):lower(), tostring(b or ''):lower()
    if a == 'off' or a == 'on' then
        player:setCharVar('SQREQ_OFF', a == 'off' and 1 or 0)
    elseif a == 'more' and (b == 'on' or b == 'off') then
        player:setCharVar('SQREQ_MORE_OFF', b == 'off' and 1 or 0)
    elseif a ~= '' and a ~= 'status' then
        tell(player, '!sqreq | !sqreq off | !sqreq on | !sqreq more on | !sqreq more off')
    end

    R.status(player)
end

if xi.module ~= nil and xi.module.registerCommand ~= nil then
    xi.module.registerCommand('sqreq', {
        cmdprops = { permission = 0, parameters = 'ss' },
        onTrigger = function(player, a, b)
            R.command(player, a, b)
        end,
    })
end

return R
