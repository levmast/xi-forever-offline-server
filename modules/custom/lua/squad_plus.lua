-----------------------------------
-- Squad extras (2026-11-22, levi): party-play features for squad mates, one file each, every one switchable per
-- character. Required by the feature files (not listed in init.txt itself):
--   squad_callouts.lua   skillchain and magic burst calls in party chat; mages burst the chains        !squad callouts
--   squad_cc.lua         a Black Mage, Red Mage or Bard sleeps the extra monsters of a link           !squad sleep
--   squad_heal.lua       hate-aware healing: the right cure for the damage, no healer aggro           !squad heal
--   squad_pullcalls.lua  the puller calls the pull, links and adds; Provoke pulls                    !squad pullcalls
--   squad_persona.lua    race and job flavored lines: level ups, knock outs, rare drops              !squad persona
--   squad_buffs.lua      buffs recast before they wear off, wear warnings                            !squad buffs
--   squad_petjobs.lua    Beastmaster, Summoner and Puppetmaster mates look after their pets          !squad pets
--
-- squad.lua calls SQUAD_PLUS.onSpawn(player, trust, mate) once a mate is called, and SQUAD_PLUS.command(...) before its
-- own !squad commands. A feature registers itself with SQUAD_PLUS.register(key, def):
--   def = { title = 'one line', words = { 'callouts', ... }, onSpawn = function(player, trust, mate) end,
--           tick = function(player, trust) end (optional: once a second per mate while the switch is on),
--           command = function(player, word, arg1, arg2, arg3) return true end (optional, for more than on/off) }
-- A feature's switch is the char var SQUAD_X_<KEY>: 1 = off, anything else = on (so every feature starts on).
-- !squad extras lists them; !squad <word> on|off switches one.
-- LuaJIT 5.1: no table.unpack, no //, no goto.
-----------------------------------
local P = rawget(_G, 'SQUAD_PLUS') or {}
SQUAD_PLUS = P

P.features = P.features or {} -- [key] = def
P.order    = P.order or {}    -- keys, in the order they registered
P.errAt    = P.errAt or 0

local function log(text)
    print('[squad+] ' .. tostring(text))
end
P.log = log

-- an error is printed at most every 20 seconds, so a broken feature never floods the log
function P.try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local now = os.time()
        if now - P.errAt >= 20 then
            P.errAt = now
            log(what .. ': ' .. tostring(err))
        end
    end

    return ok, err
end

function P.register(key, def)
    if P.features[key] == nil then
        P.order[#P.order + 1] = key
    end

    def.key = key
    P.features[key] = def
end

-- ---------------------------------------------------------------- switches
function P.var(key)
    return 'SQUAD_X_' .. string.upper(key)
end

function P.on(player, key)
    if player == nil then
        return false
    end

    local ok, value = pcall(function() return player:getCharVar(P.var(key)) end)
    return ok and value ~= 1
end

function P.set(player, key, on)
    player:setCharVar(P.var(key), on and 0 or 1)
end

-- ---------------------------------------------------------------- who is who
function P.isPC(entity)
    return entity ~= nil and entity:getObjType() == xi.objType.PC
end

-- the squad mate's owner (a player character), or nil
function P.master(mob)
    local master = mob and mob:getMaster()
    if master ~= nil and master:getObjType() == xi.objType.PC then
        return master
    end

    return nil
end

-- the player's squad mates who are out (alive or not)
function P.trusts(player)
    local out = {}
    for _, member in pairs(player:getPartyWithTrusts() or {}) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') > 0 then
            out[#out + 1] = member
        end
    end

    return out
end

-- everyone in the party: you, the other characters, the mates (and you alone without a party)
function P.party(player)
    local out = {}
    for _, member in pairs(player:getPartyWithTrusts() or {}) do
        out[#out + 1] = member
    end

    if #out == 0 then
        out[1] = player
    end

    return out
end

-- a mate's role from !squad role (squad.lua: SQUAD_AI_<id> = role * 10 + mode)
P.ROLES = { 'auto', 'tank', 'damage', 'healer', 'support' }
function P.role(player, trust)
    local code = tonumber(player:getCharVar('SQUAD_AI_' .. trust:getLocalVar('SQUAD_ID'))) or 0
    return P.ROLES[math.floor(code / 10) + 1] or 'auto'
end

-- the mate's own switches (!squad sw): kind = 'melee' | 'ranged' | 'ja' | 'magic'
local SW_BIT = { melee = 0, ranged = 1, ja = 2, magic = 3 }
function P.allowed(player, trust, kind)
    local raw = tonumber(player:getCharVar('SQUAD_SW_' .. trust:getLocalVar('SQUAD_ID'))) or 0
    if raw <= 0 then
        return true
    end

    return math.floor((raw - 1) / (2 ^ SW_BIT[kind])) % 2 == 1
end

-- the party role a member plays: 'tank', 'healer' or 'other' (the explicit !squad role first, then the main job)
function P.partRole(player, member)
    if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') > 0 then
        local role = P.role(player, member)
        if role == 'tank' or role == 'healer' then
            return role
        end
        if role ~= 'auto' then
            return 'other'
        end
    end

    local job = member:getMainJob()
    if job == xi.job.PLD or job == xi.job.NIN then
        return 'tank'
    elseif job == xi.job.WHM then
        return 'healer'
    end

    return 'other'
end

-- ---------------------------------------------------------------- talk
-- a line in party chat, as if the mate said it (nil mate: a plain line)
function P.say(player, mate, text)
    local name
    if mate ~= nil then
        pcall(function() name = mate:getPacketName() end)
    end

    if name then
        player:printToPlayer(text, 4, name)
    else
        player:printToPlayer(text)
    end
end

-- a quiet line for you only (system color)
function P.note(player, text)
    player:printToPlayer(text)
end

-- at most one line per `every` seconds for this key on this entity
function P.every(entity, key, every)
    local now = os.time()
    local var = 'SQX_T_' .. key
    if now < entity:getLocalVar(var) then
        return false
    end

    entity:setLocalVar(var, now + every)
    return true
end

-- 'cure_iv' / 'CURE_IV' -> 'Cure IV'
function P.pretty(name)
    local text = string.gsub(string.lower(tostring(name)), '_', ' ')
    text = string.gsub(text, '(%a)([%w\']*)', function(first, rest)
        local word = first .. rest
        if string.match(word, '^[ivx]+$') then
            return string.upper(word)
        end

        return string.upper(first) .. rest
    end)

    return text
end

local spellNames
function P.spellName(id)
    if spellNames == nil then
        spellNames = {}
        for name, value in pairs(xi.magic and xi.magic.spell or {}) do
            spellNames[value] = P.pretty(name)
        end
    end

    return spellNames[id] or 'a spell'
end

-- ---------------------------------------------------------------- spells
-- The spells a mate knows now (squad.lua's spell rules, through gambits_squad.lua's xi.squad.mateSpells), as a set of
-- spell ids. Kept per mate and level; nil when the list cannot be built (then nothing here casts for that mate).
P.known = P.known or {} -- [entity id] = { key = 'job/lvl/sub/lvl', set = { [id] = true } }
function P.knownSpells(player, trust)
    local id = trust:getID()
    local key = string.format('%d/%d/%d/%d/%d', trust:getLocalVar('SQUAD_ID'), trust:getMainJob(), trust:getMainLvl(),
        trust:getSubJob(), trust:getSubLvl())
    local entry = P.known[id]
    if entry and entry.key == key then
        return entry.set
    end

    local mateSpells = xi.squad and xi.squad.mateSpells
    local spellIds = xi.magic and xi.magic.spell
    if type(mateSpells) ~= 'function' or type(spellIds) ~= 'table' then
        return nil
    end

    local ok, has = pcall(mateSpells, player, trust:getMainJob(), trust:getMainLvl(), trust:getSubJob(), trust:getSubLvl())
    if not ok or type(has) ~= 'table' then
        return nil
    end

    local set = {}
    for _, entry2 in ipairs(has) do
        local name = string.match(entry2, '^(.-):')
        if name and spellIds[name] then
            set[spellIds[name]] = true
        end
    end

    P.known[id] = { key = key, set = set }
    return set
end

-- the first spell of `names` (best first) the mate knows: id, name
function P.bestKnown(player, trust, names)
    local set = P.knownSpells(player, trust)
    if set == nil then
        return nil
    end

    for _, name in ipairs(names) do
        local id = xi.magic.spell[name]
        if id and set[id] then
            return id, name
        end
    end

    return nil
end

-- can this mate act right now: alive, not stopped, not casting or busy, able to cast
local BLOCKED = { 'SILENCE', 'MUTE', 'SLEEP_I', 'SLEEP_II', 'STUN', 'PETRIFICATION', 'TERROR', 'LULLABY', 'AMNESIA' }
function P.free(trust)
    if not trust:isAlive() or trust:getLocalVar('SQUAD_IDLE') ~= 0 or trust:getLocalVar('SQUAD_PULL_PHASE') ~= 0 then
        return false
    end

    local act = trust:getCurrentAction()
    if act ~= 1 and act ~= 16 and act ~= 0 then
        return false
    end

    for _, name in ipairs(BLOCKED) do
        local effect = xi.effect[name]
        if effect and trust:hasStatusEffect(effect) then
            return false
        end
    end

    return true
end

-- the spell's MP cost (nil when the spell is unknown to the server)
function P.mpCost(spellId)
    local get = rawget(_G, 'GetSpell')
    if type(get) ~= 'function' then
        return nil
    end

    local ok, cost = pcall(function() return get(spellId):getMPCost() end)
    return ok and cost or nil
end

-- casts a spell the mate knows, when it is off recast and the mate has the MP (plus `reserve` MP).
-- castSpell is the game's own casting (cast time, interruption, MP, recast); it only clears a mob's recast for the
-- spell first, so the recast is checked here. true when the cast was started.
function P.cast(trust, spellId, target, reserve)
    if spellId == nil or target == nil then
        return false
    end

    local cost = P.mpCost(spellId)
    if cost == nil or trust:getMP() < cost + (reserve or 0) then
        return false
    end

    if trust:hasRecast(xi.recast.MAGIC, spellId) then
        return false
    end

    local ok = pcall(function() trust:castSpell(spellId, target) end)
    return ok
end

-- ---------------------------------------------------------------- enemies
-- The monsters fighting the party: every monster with a party member (or a party member's pet) on its hate list, within
-- `range` yalms of the player. Kept for a second per player, since several mates ask in the same tick.
P.foeCache = P.foeCache or {} -- [player id] = { at, list }
function P.foes(player, range)
    local now = os.time()
    local cached = P.foeCache[player:getID()]
    if cached and cached.at == now then
        return cached.list
    end

    local seen, list = {}, {}
    local function add(entity)
        local okN, notoriety = pcall(function() return entity:getNotorietyList() end)
        if not okN or type(notoriety) ~= 'table' then
            return
        end

        for _, foe in pairs(notoriety) do
            local okF = pcall(function()
                if not seen[foe:getID()] and foe:getObjType() == xi.objType.MOB and foe:isAlive() and
                    player:checkDistance(foe) <= (range or 30) then
                    seen[foe:getID()] = true
                    list[#list + 1] = foe
                end
            end)
            if not okF then
                seen[0] = true
            end
        end
    end

    for _, member in ipairs(P.party(player)) do
        add(member)
        local okPet, pet = pcall(function() return member:getPet() end)
        if okPet and pet ~= nil then
            add(pet)
        end
    end

    P.foeCache[player:getID()] = { at = now, list = list }
    return list
end

-- the monster the party is fighting: the tank's target, else yours, else the first mate's
function P.mainTarget(player)
    local first
    for _, member in ipairs(P.party(player)) do
        local okT, target = pcall(function()
            return member:isEngaged() and member:getTarget() or nil
        end)
        if okT and target ~= nil and target:isAlive() then
            if P.partRole(player, member) == 'tank' then
                return target
            end

            if member:getID() == player:getID() then
                first = target
            end

            first = first or target
        end
    end

    return first
end

-- ---------------------------------------------------------------- the tick
-- A feature with def.tick(player, trust) gets it once a second per mate (while its switch is on), from one TICK
-- listener per mate (the AI tick: fighting or not).
function P.tickMate(trust)
    local now = os.time()
    if trust:getLocalVar('SQX_TICK_AT') == now then
        return
    end

    trust:setLocalVar('SQX_TICK_AT', now)
    local player = P.master(trust)
    if player == nil or not trust:isAlive() then
        return
    end

    for _, key in ipairs(P.order) do
        local def = P.features[key]
        if def and type(def.tick) == 'function' and P.on(player, key) then
            P.try(key .. ' tick', def.tick, player, trust)
        end
    end
end

-- ---------------------------------------------------------------- hooks from squad.lua
function P.onSpawn(player, trust, mate)
    for _, key in ipairs(P.order) do
        local def = P.features[key]
        if def and type(def.onSpawn) == 'function' then
            P.try(key .. ' onSpawn', def.onSpawn, player, trust, mate)
        end
    end

    trust:addListener('TICK', 'SQX_TICK', function(mob)
        P.try('tick', P.tickMate, mob)
    end)
end

local function list(player)
    P.note(player, 'Squad extras (each one: !squad <word> on|off):')
    for _, key in ipairs(P.order) do
        local def = P.features[key]
        P.note(player, string.format('  %s %s - %s', def.words[1], P.on(player, key) and 'ON ' or 'off', def.title))
    end
end

-- true when the command was handled here
function P.command(player, action, arg1, arg2, arg3, arg4)
    if action == nil then
        return false
    end

    action = string.lower(action)
    if action == 'extras' or action == 'extra' then
        list(player)
        return true
    end

    for _, key in ipairs(P.order) do
        local def = P.features[key]
        for _, word in ipairs(def.words or {}) do
            if action == word then
                local a1 = arg1 and string.lower(arg1) or nil
                if a1 == 'on' or a1 == 'off' then
                    P.set(player, key, a1 == 'on')
                    P.note(player, string.format('Squad %s: %s.', def.words[1], a1 == 'on' and 'on' or 'off'))
                    if def.onSwitch then
                        P.try(key .. ' switch', def.onSwitch, player, a1 == 'on')
                    end
                    return true
                end

                if def.command then
                    local ok, handled = P.try(key .. ' command', def.command, player, word, arg1, arg2, arg3, arg4)
                    if ok and handled then
                        return true
                    end
                end

                P.note(player, string.format('Squad %s is %s - %s', def.words[1], P.on(player, key) and 'on' or 'off', def.title))
                P.note(player, string.format('!squad %s on|off%s', def.words[1], def.usage and (' | ' .. def.usage) or ''))
                return true
            end
        end
    end

    return false
end

return P
