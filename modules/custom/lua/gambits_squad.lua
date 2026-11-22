-----------------------------------
-- Gambits v2, M2: !gsq, the in-game squad Rule Set editor's server side (XI: Forever Offline).
--
-- The Gambits addon (SQUAD tab) edits a Rule Set locally and talks to this command only to load, save, check and
-- delete. The server stays the authority: it checks every set with squad_rulesets.lua (M1.1), decides who may change
-- what (squad_rulesets_store.lua) and writes squad_rulesets_data.lua. Choosing a set for a mate and applying it use the
-- existing commands (!squad ruleset <slot> <num>, !squad reapply), unchanged.
--
-- Every reply is one chat line "GSQ|<request id>|<kind>|..." that the addon hides. The game's chat message carries at
-- most 150 bytes (GP_SERV_COMMAND_CHAT_STD Mes[150]) and silently cuts the rest, so every reply line is at most
-- REPLY_MAX (140) bytes, framing included; a reply that would be longer is never cut - it becomes an error for that
-- request. Requests (one chat line, at most 128 bytes from the game client; the addon keeps them at 120):
--   ping  <n> [t]                    -> GSQ|n|pong|t|<server time>
--   hello <n>                        -> GSQ|n|hello|4|<max rules>|<max line>|<max x chunks>
--   mates <n>                        -> GSQ|n|mate|slot|mateId|name|JOB|level|SUB or -|chosen set num|out 0/1|sub level or -
--                                       ... GSQ|n|end|count  (version 4: the levels a call uses without Level Sync,
--                                       squad.lua's levelsFor; SUB only once the mate's sub job is unlocked)
--   catm  <n> <slot>                 -> (version 4) the catalog for ONE squad mate, as cat, kinds t c f j s u: j = only the
--                                       job abilities the U13 rules allow it (squad_ability_rules.lua A.reason: level, two-
--                                       hour, main-only, the owner's merits); s = the spells it has by trustutils.cpp's rules
--                                       (group, scroll item, main/sub level, learned when spells come from scrolls); u =
--                                       spells its jobs and levels allow but that are not confirmed (not learned yet, or blue
--                                       magic, which is set when it is called). Normal levels: Level Sync is not applied.
--   list  <n> <JOB>                  -> GSQ|n|set|num|JOB|rules|flags|rev|id|name ... GSQ|n|end|count
--                                       flags: o = yours (editable), m = written by hand (copy only), r = read-only
--   get   <n> <num>                  -> GSQ|n|hdr|num|JOB|flags|rev|id|name, GSQ|n|rule|i|<seg>/<segs>|<part of rule i>
--                                       ..., GSQ|n|end|count  (version 3: a long rule comes in several segments)
--   cat   <n> <JOB> [SUB]            -> GSQ|n|cat|<seq>|<kind>|e1,e2,... (seq 1, 2, ...; kinds t c f j s in this order;
--                                       an entry is never split), GSQ|n|end|<lines>|<t.c.f.j.s entry counts>|<check>
--                                       (check = G.check over every "kind:entry" in order: the addon rejects a catalog
--                                       with a missing, repeated, reordered, cut or changed line)
--   chk   <n> <slot> <num>           -> GSQ|n|chk|i|why ... GSQ|n|end|count   (the mate must be out)
--   w     <token> <seq> <total> <data>  a save in 1..total parts (see below) -> GSQ|token|ack|seq|total, at the end
--                                       GSQ|token|ok|num|rev|id  or  GSQ|token|err|code|text
--   x     <token> <seq> <total> <chunk>  (version 2) the same save as one text stream cut into 1..total chunks at any
--                                       byte: the server joins the chunks in order without a separator. One long rule may
--                                       span chunks, so 32 rules of any valid form fit (at most 64 chunks, 6144 bytes).
--                                       Answers, tokens, retries and expiry are exactly those of w.
--   del   <token> <num> <rev>        -> GSQ|token|ok|num|-|-  or  GSQ|token|err|code|text
--   abort <token>                    -> GSQ|token|aborted
-- (version 5, Gambits WAR/PLD/RDM/WS batch; squad_ws.lua) weapon skill settings per mate and main job:
--   catm  <n> <slot> j               -> as above; the extra word "j" says the addon reads conditions with a job ability
--                                       argument (JA_ON_COOLDOWN:j). Without it they are left out (older addons reject them).
--   wsg   <n> <slot>                 -> GSQ|n|ws|slot|JOB|src|ctl|mode|tp|ws|ltp|lws|out|usable|applied|eng, GSQ|n|end|1
--                                       src c = Custom, d = Squad default (chosen in Gambits), l = no Gambits setting
--                                       (the !squad ws values ltp/lws apply); ctl/mode/tp/ws = the stored setting (kept
--                                       while Squad default is chosen); out 0/1; usable 1/0 = the chosen weapon skill is in
--                                       the called mate's list now, - = not known or Best; applied 1/0 = the called mate
--                                       runs the stored setting, - = not called; eng 1/0 = this map server has the triggers
--   wsl   <n> <slot>                 -> GSQ|n|wsl|id:Name,id:Name,... (as many lines as needed), GSQ|n|end|<lines>|<count>:
--                                       every weapon skill the called mate can use now (err notout when it is not called)
--   wss   <n> <slot> <ctl> <mode> <tp> <ws>  stores the setting for the mate's main job -> the wsg answer
--                                       (ctl 0 = Squad default, 1 = Custom; mode 1-4; tp 1000/1500/2000/3000; ws 0 = Best)
--   wsa   <n> <slot>                 -> puts the stored setting on the called mate now (no new call) -> the wsg answer
-- (version 7, party roles; squad_jobs.lua) who the Rule Sets' Tank/Melee/Mage/Ranged targets mean (!squad partyrole):
--   prl   <n>                        -> GSQ|n|pr|who|name|JOB|level|set|auto|out|live for you (who 0) and each of your squad
--                                       mates (who = slot), then GSQ|n|pm|name|JOB|kind|targets for every OTHER member of
--                                       your party now (kind p = a player character, t = a trust; read-only), GSQ|n|end|count
--                                       set = the stored role (0 auto, 1 tank, 2 melee, 3 mage, 4 ranged); auto = the targets
--                                       the main job alone gives (letters T tank, M melee, C mage, R ranged: PLD "TM"); out
--                                       0/1; live = the role the engine reads now, - when the mate is not out; targets = what
--                                       that member counts as now (its role, else its main job)
--   prs   <n> <who> <role>           -> stores the role of you (who 0) or the mate in that slot of YOUR squad and sets it at
--                                       once (on you, or on the mate when it is out) -> that one pr line, read back; GSQ|n|end|1
-- Errors of a request: GSQ|<id>|err|code|text.
-- Save data: part 1 starts with "num,rev,JOB,rules,name;" (num 0 = a new set, rev - for a new set), then rules
-- separated by ';', each "on,TARGET,COND,ARG,COND2,ARG2,kind,NAME,RETRY[,LEVEL[,ID]]" (on 1/0; kind f = best of a spell
-- family, s = a specific spell, j = job ability, r = ranged attack, n = best nuke, b = magic burst - r/n/b without a NAME;
-- LEVEL = the rule's own minimum level, ID = the rule's id when it is not "r<position>"; empty fields allowed). Version 3
-- carries every M1.1 rule form except table arguments ({ main, sub }, flags, ecosystems): such a rule is sent as "?" and
-- the addon keeps it read-only. A part can be sent again (same seq, same data: answered again); the set is checked and
-- written only when all parts are there, once (the same last part again gets the same answer); a save not finished
-- within 120 s is dropped; nothing is written before that.
-- This file only registers the command; it defines no globals.
-----------------------------------
local VERSION      = 7     -- 2: x; 3: spells, ranged/nuke/burst, level and id, 140-byte replies; 4: mates sub level, catm;
                           -- 5: weapon skill settings (wsg, wsl, wss, wsa), catm "j", PARTY_LOWEST_HPP, HAS_MP*
                           -- 6 (job expansion): MOD_LT ("m", argument MODIFIER.number), TRIGGER_SELF_ACTION_TARGET, more
                           --   families, abilities and spells of content this server has not enabled are left out
                           -- 7 (party roles): prl, prs
local MAX_LINE     = 120
local MAX_PARTS    = 16    -- w: parts that end on a rule boundary
local MAX_CHUNKS   = 64    -- x: 32 rules of the most complex valid form (~140 bytes each) need about 49 chunks of 93 bytes
local MAX_STREAM   = 6144  -- x: bytes of one save (32 of the most complex valid rules are about 4.5 kB)
local MAX_CHUNK    = 110   -- x: bytes of one chunk
local MAX_DRAFTS   = 64    -- unfinished saves kept in memory at once (all characters; at most 6 kB each)
local DRAFT_SECS   = 120
local REPLY_MAX    = 140   -- bytes of one reply line; the game cuts a chat message after 150
local SPELL_MAX_LV = 75    -- spells offered in the catalog: learnable at this level or below
local ACTIONS      = { f = 'family', j = 'ja', s = 'spell', r = 'ranged', n = 'nuke', b = 'burst' }
local ACTION_CODE  = { family = 'f', ja = 'j', spell = 's', ranged = 'r', nuke = 'n', burst = 'b' }
local NAMED        = { family = true, ja = true, spell = true }  -- the kinds with a NAME (squad_rulesets.lua ACTION_KINDS)
-- the targets the editor offers (ai.t names; the engine's job groups: TANK = PLD/RUN, CASTER = WHM BLM RDM BRD SMN BLU
-- SCH GEO RUN, MELEE = the melee jobs, RANGED = RNG/COR; PARTY takes the first member in party order that matches;
-- PARTY_LOWEST_HPP the member with the lowest HP% that matches - only with the batch's map server)
-- (version 6) TRIGGER_SELF_ACTION_TARGET: the conditions are checked on the mate itself, the action goes to the enemy
-- ("my HP below 60% -> Drain"); the engine's own target, offered as "Self, act on enemy"
local TARGETS      = { 'SELF', 'PARTY', 'PARTY_LOWEST_HPP', 'TANK', 'CASTER', 'MELEE', 'RANGED', 'TOP_ENMITY', 'TARGET', 'MASTER',
                       'TRIGGER_SELF_ACTION_TARGET' }
-- spell families offered for "Best of family" (only names xi.magic.spellFamily has are sent; the rest of this list stays for
-- older servers' names). (version 6) nukes, dark magic, ninjutsu and songs for the job expansion's jobs.
local FAMILIES     = { 'CURE', 'CURAGA', 'CURA', 'REGEN', 'PROTECT', 'SHELL', 'PROTECTRA', 'SHELLRA', 'HASTE', 'BLINK',
                       'STONESKIN', 'AQUAVEIL', 'REFRESH', 'RAISE', 'RERAISE', 'POISONA', 'PARALYNA', 'BLINDNA', 'SILENA',
                       'STONA', 'VIRUNA', 'CURSNA', 'ERASE', 'ESUNA', 'SACRIFICE', 'AUSPICE', 'DIA', 'BANISH',
                       'BANISHGA', 'HOLY', 'FLASH', 'REPOSE', 'SLOW', 'PARALYZE', 'SILENCE',
                       'PHALANX', 'ENFIRE', 'ENBLIZZARD', 'ENAERO', 'ENSTONE', 'ENTHUNDER', 'ENWATER', 'DISTRACT', 'FRAZZLE',
                       'FIRE', 'BLIZZARD', 'AERO', 'STONE', 'THUNDER', 'WATER', 'FIRAGA', 'BLIZZAGA', 'AEROGA', 'STONEGA',
                       'THUNDAGA', 'WATERGA', 'POISON', 'POISONGA', 'BIO', 'DRAIN', 'ASPIR', 'ABSORB', 'SLEEP', 'SLEEPGA',
                       'BLIND',
                       'UTSUSEMI', 'KATON', 'HYOTON', 'HUTON', 'DOTON', 'RAITON', 'SUITON', 'JUBAKU', 'HOJO', 'KURAYAMI',
                       'DOKUMORI', 'TONKO',
                       'VALOR_MINUET', 'MARCH', 'KNIGHTS_MINNE', 'ARMYS_PAEON', 'MAGES_BALLAD', 'MADRIGAL', 'PRELUDE',
                       'ELEGY', 'FOE_REQUIEM', 'FOE_LULLABY', 'HORDE_LULLABY' }
-- (version 6) families whose every spell belongs to an expansion (sql/spell_list.sql content_tag): left out when that
-- content is off (Cura, Sacrifice, Esuna, Auspice and Repose are Wings of the Goddess spells)
local FAMILY_CONTENT = { CURA = 'WOTG', SACRIFICE = 'WOTG', ESUNA = 'WOTG', AUSPICE = 'WOTG', REPOSE = 'WOTG' }

-- (version 6) luautils::IsContentEnabled in Lua: an empty tag is always on; otherwise ENABLE_<TAG>, unless the server
-- does not restrict content at all
local function contentEnabled(tag)
    if tag == nil or tag == '' then
        return true
    end

    local main = xi and xi.settings and xi.settings.main
    if type(main) ~= 'table' then
        return true -- (no settings to read: as before)
    end

    local function on(v)
        return v == true or (type(v) == 'number' and v ~= 0)
    end

    return on(main['ENABLE_' .. tag]) or not on(main.RESTRICT_CONTENT)
end

-- (version 6) a job ability this server has loaded (abilities of disabled content are not loaded at all, ability.cpp)
local function abilityLoaded(id)
    local get = rawget(_G, 'GetAbility')
    if type(get) ~= 'function' then
        return true -- (no way to tell: as before)
    end

    local ok, a = pcall(get, id)
    return ok and a ~= nil
end

local G = {}  -- exported for the tests only (returned below)
G.contentEnabled, G.abilityLoaded = contentEnabled, abilityLoaded
local unpackList = unpack or table.unpack -- (LuaJIT / Lua 5.4)

local function rulesets()
    local ok, R = pcall(require, 'modules/custom/lua/squad_rulesets')
    return ok and type(R) == 'table' and R or nil
end

local function store()
    local ok, St = pcall(require, 'modules/custom/lua/squad_rulesets_store')
    return ok and type(St) == 'table' and St or nil
end

local function channel()
    return (xi and xi.msg and xi.msg.channel and xi.msg.channel.SYSTEM_3) or 0
end

G.REPLY_MAX = REPLY_MAX

-- one reply line. Never cut: a line over REPLY_MAX becomes an error for that request (the addon then fails it cleanly
-- instead of reading part of an answer).
function G.reply(player, ...)
    local parts = { 'GSQ' }
    for _, v in ipairs({ ... }) do
        parts[#parts + 1] = (string.gsub(tostring(v), '[|\r\n]', ' '))
    end

    local line = table.concat(parts, '|')
    if #line > REPLY_MAX and parts[3] == 'err' and #parts >= 5 then
        -- an error's last field is text for the player: shortened (data lines are never shortened)
        local keep = #parts[#parts] - (#line - REPLY_MAX) - 3
        parts[#parts] = string.sub(parts[#parts], 1, math.max(0, keep)) .. '...'
        line = table.concat(parts, '|')
    end

    if #line > REPLY_MAX then
        print(string.format('[squad] Rule Sets editor: an answer of %d bytes was not sent (at most %d): %s', #line, REPLY_MAX,
            string.sub(line, 1, 60)))
        line = 'GSQ|' .. (parts[2] or '-') .. '|err|toolong|an answer did not fit one chat line'
    end

    player:printToPlayer(line, channel())
    return #line
end

-- The catalog check: the same number on both sides, over every "kind:entry" in order (Lua 5.1 and 5.4 give the same)
function G.check(text, h)
    h = h or 7
    for i = 1, #text do
        h = (h * 31 + string.byte(text, i)) % 1000000007
    end

    return h
end

-- The catalog: kinds in order, each as few lines as fit, entries whole: GSQ|id|cat|seq|kind|a,b,c ; then the end line
local CAT_KINDS  = { 't', 'c', 'f', 'j', 's' }
local CATM_KINDS = { 't', 'c', 'f', 'j', 's', 'u' }
local function replyCatalog(player, id, lists, kinds)
    local seq, counts, check = 0, {}, 7
    for _, kind in ipairs(kinds or CAT_KINDS) do
        local items = lists[kind] or {}
        counts[#counts + 1] = #items
        local line = {}
        local budget = REPLY_MAX - #string.format('GSQ|%s|cat|%d|%s|', id, 999, kind)
        local size = 0
        local function flush()
            if #line > 0 then
                seq = seq + 1
                G.reply(player, id, 'cat', seq, kind, table.concat(line, ','))
                line, size = {}, 0
            end
        end

        for _, item in ipairs(items) do
            check = G.check(kind .. ':' .. item .. '\n', check)
            local add = #item + (#line > 0 and 1 or 0)
            if #line > 0 and size + add > budget then
                flush()
                add = #item
            end

            line[#line + 1] = item
            size = size + add
        end

        flush()
    end

    G.reply(player, id, 'end', seq, table.concat(counts, '.'), check)
end

local JOBS = { WAR = 1, MNK = 2, WHM = 3, BLM = 4, RDM = 5, THF = 6, PLD = 7, DRK = 8, BST = 9, BRD = 10, RNG = 11, SAM = 12,
               NIN = 13, DRG = 14, SMN = 15, BLU = 16, COR = 17, PUP = 18, DNC = 19, SCH = 20 }
local function jobName(id)
    for name, value in pairs(JOBS) do
        if value == id then
            return name
        end
    end

    return '-'
end

G.JOBS = JOBS

-- ---------------------------------------------------------------- the rule codec (shared with the addon by design)
local function splitPlain(text, sep)
    local out, start = {}, 1
    while true do
        local at = string.find(text, sep, start, true)
        if not at then
            out[#out + 1] = string.sub(text, start)
            return out
        end

        out[#out + 1] = string.sub(text, start, at - 1)
        start = at + #sep
    end
end

G.splitPlain = splitPlain

local function argValue(text)
    if text == nil or text == '' then
        return nil
    end

    local n = tonumber(text)
    if n ~= nil then
        return n
    end

    return text
end

-- "1,PARTY,HPP_LT,50,,,f,CURE,[,LEVEL[,ID]]" -> a M1.1 rule table, or nil + why
function G.decodeRule(text, index)
    local f = splitPlain(text, ',')
    if #f < 8 or #f > 11 then
        return nil, 'rule ' .. index .. ' has ' .. #f .. ' fields (8 to 11 expected)'
    end

    for _, field in ipairs(f) do
        if not string.match(field, '^[%w_%-%.]*$') then
            return nil, 'rule ' .. index .. ' has a character that is not allowed'
        end
    end

    local kind = ACTIONS[f[7]]
    if kind == nil then
        return nil, 'rule ' .. index .. ': the action must be f, s, j, r, n or b'
    end

    if f[1] ~= '1' and f[1] ~= '0' then
        return nil, 'rule ' .. index .. ': on must be 1 or 0'
    end

    if f[3] == '' then
        return nil, 'rule ' .. index .. ' needs a condition'
    end

    if NAMED[kind] and f[8] == '' then
        return nil, 'rule ' .. index .. ' needs an action name'
    elseif not NAMED[kind] and f[8] ~= '' then
        return nil, 'rule ' .. index .. ': ' .. kind .. ' takes no name'
    end

    local rule = { id = 'r' .. index, on = f[1] == '1', target = f[2], cond = { f[3], argValue(f[4]) },
                   action = NAMED[kind] and { kind, f[8] } or { kind } }
    if f[10] ~= nil and f[10] ~= '' then
        rule.level = tonumber(f[10])
        if rule.level == nil then
            return nil, 'rule ' .. index .. ': level must be a number'
        end
    end

    if f[11] ~= nil and f[11] ~= '' then
        rule.id = f[11]
    end
    if rule.cond[2] == nil then
        rule.cond = { f[3] }
    end

    if f[5] ~= '' then
        rule.cond2 = { f[5], argValue(f[6]) }
        if rule.cond2[2] == nil then
            rule.cond2 = { f[5] }
        end
    end

    -- (version 6, job expansion) MOD_LT carries "MODIFIER.number" ({ mod = 'UTSUSEMI', below = 2 })
    for _, c in ipairs({ rule.cond, rule.cond2 }) do
        if c and c[1] == 'MOD_LT' and type(c[2]) == 'string' then
            local mod, below = string.match(c[2], '^([A-Z][A-Z0-9_]*)%.(%d+)$')
            c[2] = mod and { mod = mod, below = tonumber(below) } or c[2]
        end
    end

    if f[9] ~= nil and f[9] ~= '' then
        rule.retry = tonumber(f[9])
        if rule.retry == nil then
            return nil, 'rule ' .. index .. ': retry must be a number'
        end
    end

    return rule
end

-- a M1.1 rule table -> "1,PARTY,HPP_LT,50,,,f,CURE,[,LEVEL[,ID]]", or nil when it has anything the wire cannot carry
-- exactly (a table argument, a field this version does not know, a fraction, an odd value): the addon then shows the
-- rule as "?" and keeps it read-only, so nothing is ever lost by an edit.
local RULE_KEYS = { id = true, on = true, target = true, cond = true, cond2 = true, action = true, retry = true, level = true }
function G.encodeRule(rule, index)
    if type(rule) ~= 'table' or type(rule.action) ~= 'table' or type(rule.cond) ~= 'table' then
        return nil
    end

    for key in pairs(rule) do
        if not RULE_KEYS[key] then
            return nil
        end
    end

    local kind = ACTION_CODE[rule.action[1] or '']
    if kind == nil or #rule.action ~= (NAMED[rule.action[1]] and 2 or 1) then
        return nil
    end

    local function word(v)
        return type(v) == 'string' and string.match(v, '^[%w_]+$') ~= nil
    end

    local function whole(v)
        return type(v) == 'number' and v == math.floor(v) and v >= 0 and v < 100000
    end

    local function value(v)
        if v == nil then
            return ''
        elseif whole(v) then
            return string.format('%d', v)
        elseif word(v) then
            return v
        elseif type(v) == 'table' and word(v.mod) and whole(v.below) then
            -- (version 6) { mod = 'UTSUSEMI', below = 2 } -> "UTSUSEMI.2" (MOD_LT); any other key: not carried
            for key in pairs(v) do
                if key ~= 'mod' and key ~= 'below' then
                    return nil
                end
            end

            return string.format('%s.%d', v.mod, v.below)
        end

        return nil
    end

    local c1, c2 = rule.cond, rule.cond2
    if not word(c1[1]) or #c1 > 2 or (c2 ~= nil and (type(c2) ~= 'table' or not word(c2[1]) or #c2 > 2)) then
        return nil
    end

    local a1, a2 = value(c1[2]), c2 and value(c2[2]) or ''
    local name = NAMED[rule.action[1]] and rule.action[2] or nil
    local retry, level = value(rule.retry), value(rule.level)
    if a1 == nil or a2 == nil or retry == nil or level == nil or not word(rule.target)
        or (name ~= nil and not word(name)) or (rule.on ~= nil and type(rule.on) ~= 'boolean')
        or (rule.retry ~= nil and not whole(rule.retry)) or (rule.level ~= nil and not whole(rule.level)) then
        return nil
    end

    local id = ''
    if rule.id ~= nil and rule.id ~= 'r' .. tostring(index or '') then
        if type(rule.id) ~= 'string' or #rule.id > 24 or not string.match(rule.id, '^[%w_%-%.]+$') then
            return nil
        end

        id = rule.id
    end

    local fields = { rule.on == false and '0' or '1', rule.target, c1[1], a1, c2 and c2[1] or '', a2, kind, name or '', retry }
    if level ~= '' or id ~= '' then
        fields[#fields + 1] = level
    end

    if id ~= '' then
        fields[#fields + 1] = id
    end

    return table.concat(fields, ',')
end
-- part 1 header "num,rev,JOB,rules,name" -> table or nil + why
function G.decodeHeader(text)
    local f = splitPlain(text, ',')
    if #f ~= 5 then
        return nil, 'the header needs 5 fields'
    end

    local num, count = tonumber(f[1]), tonumber(f[4])
    if num == nil or num < 0 or num ~= math.floor(num) or count == nil or count < 1 or count ~= math.floor(count) then
        return nil, 'the header has a bad number'
    end

    if JOBS[f[3]] == nil then
        return nil, 'unknown job ' .. f[3]
    end

    if not string.match(f[5], '^[%w_%-]+$') or #f[5] > 24 then
        return nil, 'the name must be 1-24 letters, digits, - or _'
    end

    return { num = num, rev = f[2] ~= '-' and f[2] or nil, job = f[3], count = count, name = (string.gsub(f[5], '_', ' ')) }
end

-- ---------------------------------------------------------------- saves in parts (one draft per player)
local drafts  = {}  -- [character id] = { token, total, parts = { [seq] = data }, at }
local results = {}  -- [character id] = { token, reply = { ... }, at }
G._drafts, G._results = drafts, results
G.now = os.time

local function expire(charId)
    local t = G.now()
    local d = drafts[charId]
    if d and t - d.at > DRAFT_SECS then
        drafts[charId] = nil
    end

    local r = results[charId]
    if r and t - r.at > DRAFT_SECS then
        results[charId] = nil
    end
end

-- Memory bound: drops every expired draft and result (all characters); returns how many unfinished saves remain
local function sweep()
    local t, count = G.now(), 0
    for id, d in pairs(drafts) do
        if t - d.at > DRAFT_SECS then
            drafts[id] = nil
        else
            count = count + 1
        end
    end

    for id, r in pairs(results) do
        if t - r.at > DRAFT_SECS then
            results[id] = nil
        end
    end

    return count
end

G.sweep = sweep

-- Builds the edit from all parts: edit | nil, code, why (stream: the chunks of x, joined without a separator)
function G.assemble(parts, total, stream)
    for seq = 1, total do
        if parts[seq] == nil then
            return nil, 'incomplete', 'part ' .. seq .. ' of ' .. total .. ' is missing'
        end
    end

    local text = table.concat(parts, stream and '' or ';', 1, total)
    local items = splitPlain(text, ';')
    local header, why = G.decodeHeader(items[1])
    if header == nil then
        return nil, 'badreq', why
    end

    local rules = {}
    for i = 2, #items do
        if items[i] ~= '' then
            local rule, rwhy = G.decodeRule(items[i], #rules + 1)
            if rule == nil then
                return nil, 'badreq', rwhy
            end

            rules[#rules + 1] = rule
        end
    end

    if #rules ~= header.count then
        return nil, 'incomplete', string.format('%d rules arrived, %d were announced', #rules, header.count)
    end

    return { op = 'save', num = header.num, rev = header.rev, job = header.job, name = header.name, rules = rules }
end

local function finish(player, token, kind, ...)
    local charId = player:getID()
    local reply = { token, kind, ... }
    results[charId] = { token = token, reply = reply, at = G.now() }
    drafts[charId] = nil
    G.reply(player, unpackList(reply))
end

-- Writes through squad_rulesets_store.lua; G.save can be replaced by the tests
function G.save(edit, charId)
    local St, R = store(), rulesets()
    if St == nil or R == nil then
        return nil, 'server', 'the Rule Set files are missing on the server'
    end

    local result, how, why = St.save(edit, charId, R)
    if result == nil then
        return nil, how, why
    end

    if edit.op == 'delete' then
        print(string.format('[squad] Rule Sets editor: character %d deleted set %d (%s)', charId, edit.num, how))
        return { num = edit.num }
    end

    print(string.format('[squad] Rule Sets editor: character %d saved set %d [%s] %s, %d rules (%s)', charId, result.num,
        result.id, result.job, #result.rules, how))
    return result
end

local function part(player, token, seqText, totalText, data, stream)
    local charId = player:getID()
    expire(charId)
    local seq, total = tonumber(seqText), tonumber(totalText)
    if token == nil or not string.match(token, '^%d+$') or seq == nil or total == nil or seq < 1 or seq > total
        or seq ~= math.floor(seq) or total ~= math.floor(total)
        or total > (stream and MAX_CHUNKS or MAX_PARTS) or data == nil
        or (stream and (#data > MAX_CHUNK or not string.match(data, '^[%w_%-%.,;]+$'))) then
        G.reply(player, token or '-', 'err', 'badreq', 'bad save part')
        return
    end

    -- this save was finished already: the same answer again (a lost reply, a retried last part)
    local done = results[charId]
    if done and done.token == token then
        G.reply(player, unpackList(done.reply))
        return
    end

    local d = drafts[charId]
    if d == nil or d.token ~= token then
        if d == nil and sweep() >= MAX_DRAFTS then
            G.reply(player, token, 'err', 'busy', 'too many unfinished saves on the server; try again in two minutes')
            return
        end

        d = { token = token, total = total, parts = {}, at = G.now(), stream = stream == true, bytes = 0 }  -- a new save replaces an unfinished one
        drafts[charId] = d
    end

    if d.total ~= total or d.stream ~= (stream == true) then
        drafts[charId] = nil
        G.reply(player, token, 'err', 'badreq', d.total ~= total and 'the number of parts changed' or 'w and x parts mixed in one save')
        return
    end

    if stream then
        local old = d.parts[seq]
        if old ~= nil and old ~= data then
            drafts[charId] = nil
            G.reply(player, token, 'err', 'badreq', 'chunk ' .. seq .. ' arrived twice with different data')
            return
        end

        if old == nil then
            d.bytes = d.bytes + #data
            if d.bytes > MAX_STREAM then
                drafts[charId] = nil
                G.reply(player, token, 'err', 'toolong', 'the Rule Set is larger than ' .. MAX_STREAM .. ' bytes')
                return
            end
        end
    end

    d.parts[seq] = data
    d.at = G.now()

    for s = 1, total do
        if d.parts[s] == nil then
            G.reply(player, token, 'ack', seq, total)
            return
        end
    end

    local edit, code, why = G.assemble(d.parts, total, d.stream)
    if edit == nil then
        finish(player, token, 'err', code, why)
        return
    end

    local set, scode, swhy = G.save(edit, charId)
    if set == nil then
        finish(player, token, 'err', scode, swhy)
        return
    end

    local St = store()
    finish(player, token, 'ok', set.num, St and St.rev(set) or '-', set.id)
end

-- ---------------------------------------------------------------- read-only requests
local function mateOut(player, mateId)
    for _, member in pairs(player:getPartyWithTrusts() or {}) do
        if member:getObjType() == xi.objType.TRUST and member:getLocalVar('SQUAD_ID') == mateId then
            return member
        end
    end

    return nil
end

local function visible(set, charId)
    return set.owner == nil or set.owner == charId
end

local function flags(set, charId)
    local f = set.owner == nil and 'm' or (set.owner == charId and 'o' or 'x')
    if set.readonly == true then
        f = f .. 'r'
    end

    return f
end

local function squadOf(player)
    return (GetSquad and GetSquad(player:getID())) or {}
end

local requests = {}

requests.ping = function(player, w)
    G.reply(player, w[2], 'pong', w[3] or '-', G.now())
end

requests.hello = function(player, w)
    local R = rulesets()
    G.reply(player, w[2], 'hello', VERSION, R and R.MAX_RULES or 32, MAX_LINE, MAX_CHUNKS)
end

requests.mates = function(player, w)
    local R = rulesets()
    local count = 0
    for _, mate in ipairs(squadOf(player)) do
        local level = mate.jobs and mate.jobs[mate.mjob] and mate.jobs[mate.mjob].level or 1
        local subName, subLevel = mate.sjob ~= 0 and jobName(mate.sjob) or '-', '-'
        local okL, main, sub, sl = G.levels(mate, player)
        if okL then
            level, subName, subLevel = main, sub ~= 0 and jobName(sub) or '-', sub ~= 0 and sl or '-'
        end

        local chosen = R and R.selectedNum(player, mate.id, mate.mjob) or 0
        G.reply(player, w[2], 'mate', mate.slot, mate.id, mate.name, jobName(mate.mjob), level,
            subName, chosen, mateOut(player, mate.id) and 1 or 0, subLevel)
        count = count + 1
    end

    G.reply(player, w[2], 'end', count)
end

requests.list = function(player, w)
    local R, St = rulesets(), store()
    if R == nil or St == nil then
        G.reply(player, w[2], 'err', 'server', 'the Rule Set files are missing on the server')
        return
    end

    local charId = player:getID()
    local loaded = R.load()
    local count = 0
    for _, set in ipairs(loaded.list) do
        if (w[3] == nil or set.job == w[3]) and visible(set, charId) then
            G.reply(player, w[2], 'set', set.num, set.job, #set.rules, flags(set, charId), St.rev(set), set.id,
                (string.gsub(set.name, '|', ' ')))
            count = count + 1
        end
    end

    for _, problem in ipairs(loaded.problems) do
        G.reply(player, w[2], 'prob', problem)
    end

    G.reply(player, w[2], 'end', count)
end

requests.get = function(player, w)
    local R, St = rulesets(), store()
    local num = tonumber(w[3] or '')
    if R == nil or St == nil or num == nil then
        G.reply(player, w[2], 'err', 'badreq', 'get needs a Rule Set number')
        return
    end

    local charId = player:getID()
    local set = R.load().byNum[num]
    if set == nil or not visible(set, charId) then
        G.reply(player, w[2], 'err', 'missing', 'no usable Rule Set with that number')
        return
    end

    G.reply(player, w[2], 'hdr', set.num, set.job, flags(set, charId), St.rev(set), set.id, set.name)
    local count = 0
    for i, rule in ipairs(set.rules) do
        -- a rule longer than one line comes in segments: GSQ|n|rule|i|seg/segs|part
        local text = G.encodeRule(rule, i) or '?'
        local room = REPLY_MAX - #string.format('GSQ|%s|rule|%d|9/9|', w[2], i)
        local segs = math.max(1, math.ceil(#text / room))
        for seg = 1, segs do
            G.reply(player, w[2], 'rule', i, seg .. '/' .. segs, string.sub(text, (seg - 1) * room + 1, seg * room))
        end

        count = count + 1
    end

    G.reply(player, w[2], 'end', count)
end

-- the targets, conditions and families of a catalog (cat and catm alike). withJa: the addon reads job ability arguments
-- (catm "j", version 5). Names that need the batch's map server (R.ENGINE_NAMES) only when it is there.
-- (version 6) withMod: the addon reads modifier arguments (catm "jm"); an older addon's check refuses a whole catalog
-- with an entry kind it does not know, so MOD_LT is only sent when asked for
local function baseLists(R, withJa, withMod)
    local engineOk = R.engineReady == nil or R.engineReady()
    local engine2Ok = R.engine2Ready == nil or R.engine2Ready()
    local function offered(name)
        return (engineOk or not (R.ENGINE_NAMES and R.ENGINE_NAMES[name]))
            and (engine2Ok or not (R.ENGINE2_NAMES and R.ENGINE2_NAMES[name]))
    end

    local lists = {}
    lists.t = {}
    for _, t in ipairs(TARGETS) do
        if (ai == nil or ai.t == nil or ai.t[t] ~= nil) and offered(t) then
            lists.t[#lists.t + 1] = t
        end
    end

    -- every condition a Rule Set may hold: no argument (n), a whole number range (r:low:high), a status effect (e) or
    -- (version 5, withJa) a job ability (j); the addon offers the agreed subset for new rules and shows the others in
    -- existing rules
    lists.c = {}
    for name, spec in pairs(R.CONDITIONS) do
        if not offered(name) or (ai ~= nil and ai.c ~= nil and ai.c[name] == nil) then
            -- (not on this server)
        elseif spec == 'ja' then
            if withJa then
                lists.c[#lists.c + 1] = name .. ':j'
            end
        elseif spec == 'none' then
            lists.c[#lists.c + 1] = name .. ':n'
        elseif spec == 'effect' then
            lists.c[#lists.c + 1] = name .. ':e'
        elseif spec == 'mod' then
            if withMod then
                lists.c[#lists.c + 1] = name .. ':m' -- (version 6: the addon knows the modifiers and their ranges, R.MODS)
            end
        elseif type(spec) == 'table' then
            lists.c[#lists.c + 1] = string.format('%s:r:%d:%d', name, spec[1], spec[2])
        end
    end

    table.sort(lists.c)
    lists.f = {}
    local known = xi and xi.magic and xi.magic.spellFamily
    for _, name in ipairs(FAMILIES) do
        if (known == nil or known[name] ~= nil) and contentEnabled(FAMILY_CONTENT[name]) then
            lists.f[#lists.f + 1] = name
        end
    end

    return lists
end

requests.cat = function(player, w)
    local R = rulesets()
    local job, sub = JOBS[w[3] or ''], JOBS[w[4] or '']
    if R == nil or job == nil then
        G.reply(player, w[2], 'err', 'badreq', 'cat needs a job like WHM')
        return
    end

    local lists = baseLists(R)

    -- job abilities of the job (and the given sub job): name:level (s = sub job), from the U13 table; the server still
    -- checks each one when the mate is called (level, sub job, merits)
    lists.j = {}
    local okData, data = pcall(require, 'modules/custom/lua/squad_ja_jobs_data')
    local ids = xi and rawget(xi, 'ja')
    if okData and type(data) == 'table' and type(data.abilities) == 'table' and type(ids) == 'table' then
        local names = {}
        for name, id in pairs(ids) do
            names[id] = names[id] or name
        end

        local rows = {}
        for id, row in pairs(data.abilities) do
            if type(row) == 'table' and (row[1] == job or (sub ~= nil and row[1] == sub)) and id < 512 and id ~= 55
                and names[id] and abilityLoaded(id) then
                rows[#rows + 1] = { name = names[id], level = row[2] or 0, main = row[1] == job }
            end
        end

        table.sort(rows, function(a, b)
            if a.main ~= b.main then
                return a.main
            end

            if a.level ~= b.level then
                return a.level < b.level
            end

            return a.name < b.name
        end)
        for _, row in ipairs(rows) do
            lists.j[#lists.j + 1] = string.format('%s:%d%s', row.name, row.level, row.main and '' or 's')
        end
    end

    -- specific spells the job (and sub job) learn by SPELL_MAX_LV: name:level (s = sub job), from squad_spell_jobs_data.lua
    -- (made from sql/spell_list.sql); only names the server knows (xi.magic.spell). A spell both jobs learn is listed once,
    -- for the main job.
    lists.s = {}
    local okSp, spells = pcall(require, 'modules/custom/lua/squad_spell_jobs_data')
    local spellIds = xi and xi.magic and xi.magic.spell
    if okSp and type(spells) == 'table' and type(spells.spells) == 'table' then
        local rows = {}
        for _, row in pairs(spells.spells) do
            local name, levels = row[1], row[2]
            if type(name) == 'string' and type(levels) == 'table' and (type(spellIds) ~= 'table' or spellIds[name] ~= nil)
                and contentEnabled(row.ct) then
                local mainLv, subLv = levels[job], sub and levels[sub] or nil
                if mainLv and mainLv <= SPELL_MAX_LV then
                    rows[#rows + 1] = { name = name, level = mainLv, main = true }
                elseif subLv and subLv <= SPELL_MAX_LV then
                    rows[#rows + 1] = { name = name, level = subLv, main = false }
                end
            end
        end

        table.sort(rows, function(a, b)
            if a.main ~= b.main then
                return a.main
            end

            if a.level ~= b.level then
                return a.level < b.level
            end

            return a.name < b.name
        end)
        for _, row in ipairs(rows) do
            lists.s[#lists.s + 1] = string.format('%s:%d%s', row.name, row.level, row.main and '' or 's')
        end
    end

    replyCatalog(player, w[2], lists)
end
-- ---------------------------------------------------------------- (version 4) one squad mate's own catalog
-- The levels a call uses, without Level Sync: squad.lua's levelsFor (exported as xi.squad.levelsFor). ok, main, sub, subLevel
function G.levels(mate, player)
    local levelsFor = xi and xi.squad and xi.squad.levelsFor
    if type(levelsFor) ~= 'function' then
        return false
    end

    local ok, main, sub, subLevel = pcall(levelsFor, mate, nil, player)
    if not ok or type(main) ~= 'number' then
        return false
    end

    return true, main, sub or 0, subLevel or 0
end

-- trustutils.cpp's spell groups (spell.h SPELLGROUP_*)
local GROUP_BLUE, GROUP_SUMMONING, GROUP_GEOMANCY, GROUP_TRUST = 3, 5, 7, 8
local SCROLL_LEVEL = 18 -- with spells from scrolls: from this level only learned spells (trustutils.cpp)
G.SQUAD_SPELL_KEY = 60000 -- squad_unlock rows of learned spells (squad.lua SQUAD_SPELL_KEY)

-- The spells a mate has, by the rules trustutils.cpp uses when it builds a squad mate's spell list, and the spells its
-- jobs and levels allow that cannot be confirmed here. Returns s, u (lists of "NAME:level" / "NAME:levels")
function G.mateSpells(player, mjob, main, sub, subLevel)
    local s, u = {}, {}
    local okSp, data = pcall(require, 'modules/custom/lua/squad_spell_jobs_data')
    if not okSp or type(data) ~= 'table' or type(data.spells) ~= 'table' then
        return s, u
    end

    local flags = (tonumber(data.version) or 1) >= 2 -- (version 1 has no group or scroll flags: nothing can be confirmed)
    local scrollsKnown, scrolls = type(rawget(_G, 'squadScrollsOn')) == 'function', false
    if scrollsKnown then
        local okS, on = pcall(squadScrollsOn)
        scrollsKnown, scrolls = okS, okS and on == true
    end

    local learned = {}
    if scrolls then
        local okU, unlocks = pcall(function() return GetSquadUnlocks(player:getID()) end)
        if okU and type(unlocks) == 'table' then
            for key in pairs(unlocks) do
                if type(key) == 'number' and key > G.SQUAD_SPELL_KEY then
                    learned[key - G.SQUAD_SPELL_KEY] = true
                end
            end
        else
            scrollsKnown = false
        end
    end

    local spellIds = xi and xi.magic and xi.magic.spell
    local rows = {}
    for id, row in pairs(data.spells) do
        local name, levels, group = row[1], row[2], row.g
        if type(name) == 'string' and type(levels) == 'table' and (type(spellIds) ~= 'table' or spellIds[name] ~= nil)
            and contentEnabled(row.ct) then
            local byMain = levels[mjob] ~= nil and levels[mjob] <= main
            local bySub = sub ~= 0 and levels[sub] ~= nil and levels[sub] <= subLevel
            if byMain or bySub then
                local at = math.min(byMain and levels[mjob] or 255, bySub and levels[sub] or 255)
                local kind
                if not flags then
                    kind = 'u'
                elseif group == GROUP_TRUST or group == GROUP_SUMMONING or group == GROUP_GEOMANCY then
                    kind = nil -- never in a squad mate's spell list
                elseif group == GROUP_BLUE then
                    -- blue magic only for a Blue Mage, and which of it is SET is decided when it is called (slots, points)
                    kind = (mjob == 16 or sub == 16) and 'u' or nil
                elseif row.sc ~= true then
                    kind = nil -- no scroll: a monster's version that only shares the job levels
                elseif at < SCROLL_LEVEL or (scrollsKnown and not scrolls) then
                    kind = 's'
                elseif scrollsKnown and learned[id] then
                    kind = 's'
                else
                    kind = 'u' -- needs its scroll (or the scroll option could not be read)
                end

                if kind then
                    rows[#rows + 1] = { kind = kind, name = name, level = at, main = byMain }
                end
            end
        end
    end

    table.sort(rows, function(a, b) return a.name < b.name end)
    for _, row in ipairs(rows) do
        local list = row.kind == 's' and s or u
        list[#list + 1] = string.format('%s:%d%s', row.name, row.level, row.main and '' or 's')
    end

    return s, u
end

-- The job abilities a mate may use by the U13 rules (the same A.reason squad.lua's addGambit applies when it is called)
function G.mateAbilities(player, mjob, main, sub, subLevel)
    local out = {}
    local okA, A = pcall(require, 'modules/custom/lua/squad_ability_rules')
    local okData, data = pcall(require, 'modules/custom/lua/squad_ja_jobs_data')
    local ids = xi and rawget(xi, 'ja')
    if not okA or type(A) ~= 'table' or type(A.reason) ~= 'function' or not okData or type(data) ~= 'table'
        or type(data.abilities) ~= 'table' or type(ids) ~= 'table' then
        return out -- fail closed: nothing offered without the rules
    end

    local names = {}
    for name, id in pairs(ids) do
        names[id] = names[id] or name
    end

    local m = { job = mjob, level = main, subJob = sub, subLevel = subLevel, owner = player }
    local rows = {}
    for id, row in pairs(data.abilities) do
        if type(row) == 'table' and (row[1] == mjob or (sub ~= 0 and row[1] == sub)) and id < 512 and id ~= 55 and names[id]
            and abilityLoaded(id) then
            local okR, why = pcall(A.reason, m, id, names[id])
            if okR and why == nil then
                rows[#rows + 1] = { name = names[id], level = row[2] or 0, main = row[1] == mjob }
            end
        end
    end

    table.sort(rows, function(a, b) return a.name < b.name end)
    for _, row in ipairs(rows) do
        out[#out + 1] = string.format('%s:%d%s', row.name, row.level, row.main and '' or 's')
    end

    return out
end

requests.catm = function(player, w)
    local R = rulesets()
    local slot = tonumber(w[3] or '')
    if R == nil or slot == nil then
        G.reply(player, w[2], 'err', 'badreq', 'catm needs a squad slot')
        return
    end

    local mate
    for _, m in ipairs(squadOf(player)) do
        if m.slot == slot then
            mate = m
        end
    end

    if mate == nil then
        G.reply(player, w[2], 'err', 'missing', 'no squad mate in that slot')
        return
    end

    local ok, main, sub, subLevel = G.levels(mate, player)
    if not ok then
        G.reply(player, w[2], 'err', 'server', 'this server cannot tell the mate\'s levels (squad.lua without xi.squad.levelsFor)')
        return
    end

    -- "j" (version 5) / "jm" (version 6): which argument kinds the addon reads
    local flags = w[4] or ''
    local lists = baseLists(R, flags == 'j' or flags == 'jm', flags == 'jm')
    lists.j = G.mateAbilities(player, mate.mjob, main, sub, subLevel)
    lists.s, lists.u = G.mateSpells(player, mate.mjob, main, sub, subLevel)
    replyCatalog(player, w[2], lists, CATM_KINDS)
end
requests.chk = function(player, w)
    local R = rulesets()
    local slot, num = tonumber(w[3] or ''), tonumber(w[4] or '')
    if R == nil or slot == nil or num == nil then
        G.reply(player, w[2], 'err', 'badreq', 'chk needs a slot and a Rule Set number')
        return
    end

    local mate
    for _, m in ipairs(squadOf(player)) do
        if m.slot == slot then
            mate = m
        end
    end

    local set = R.load().byNum[num]
    if mate == nil or set == nil then
        G.reply(player, w[2], 'err', 'missing', 'no such squad mate or Rule Set')
        return
    end

    local mob = mateOut(player, mate.id)
    if mob == nil then
        G.reply(player, w[2], 'err', 'notout', 'call the squad mate first; the check uses its levels now')
        return
    end

    local m = { job = mob:getMainJob(), level = mob:getMainLvl(), subJob = mob:getSubJob() or 0, subLevel = mob:getSubLvl() or 0,
                owner = player }
    local _, dropped = R.usableRules(set, m)
    for _, d in ipairs(dropped) do
        -- the reason is text for the player: shortened to fit one line (data is never shortened)
        local room = REPLY_MAX - #string.format('GSQ|%s|chk|%s|', w[2], tostring(d[1]))
        local why = (string.gsub(tostring(d[2]), '[|\r\n]', ' '))
        if #why > room then
            why = string.sub(why, 1, room - 3) .. '...'
        end

        G.reply(player, w[2], 'chk', d[1], why)
    end

    -- (version 4) the levels it was checked at: the summoned mate's current ones, Level Sync included
    G.reply(player, w[2], 'end', #dropped, m.level, m.subJob ~= 0 and jobName(m.subJob) or '-', m.subLevel)
end

-- ---------------------------------------------------------------- (version 5) weapon skill settings (squad_ws.lua)
local function wsSettings()
    local ok, W = pcall(require, 'modules/custom/lua/squad_ws')
    return ok and type(W) == 'table' and W or nil
end

local function mateInSlot(player, slotText)
    local slot = tonumber(slotText or '')
    for _, m in ipairs(squadOf(player)) do
        if slot ~= nil and m.slot == slot then
            return m
        end
    end

    return nil
end

-- the wsg answer for one mate: GSQ|n|ws|slot|JOB|src|ctl|mode|tp|ws|ltp|lws|out|usable|applied|eng, GSQ|n|end|1
local function replyWs(player, id, W, mate)
    local trust = mateOut(player, mate.id)
    local job = trust and trust:getMainJob() or mate.mjob
    local s = W.resolve(player, mate.id, job)
    local wsId = W.effectiveWs(s)
    local usable = '-'
    if trust and wsId > 0 then
        local u = W.isUsable(trust, wsId)
        usable = u == true and 1 or (u == false and 0 or '-')
    end

    local applied = W.applied(player, mate, trust)
    G.reply(player, id, 'ws', mate.slot, jobName(job), ({ custom = 'c', default = 'd', legacy = 'l' })[s.source],
        s.noEngine and 1 or s.control, s.mode, s.tp, s.ws, s.legacyTp, s.legacyWs, trust and 1 or 0, usable,
        applied == nil and '-' or (applied and 1 or 0), W.engineReady() and 1 or 0)
    G.reply(player, id, 'end', 1)
end

requests.wsg = function(player, w)
    local W, mate = wsSettings(), mateInSlot(player, w[3])
    if W == nil then
        G.reply(player, w[2], 'err', 'server', 'the weapon skill settings file is missing on the server')
    elseif mate == nil then
        G.reply(player, w[2], 'err', 'missing', 'no squad mate in that slot')
    else
        replyWs(player, w[2], W, mate)
    end
end

-- the weapon skill names a reply carries: letters, digits and _ only ("Tachi: Enpi" -> Tachi_Enpi)
function G.wsWireName(name)
    return (string.gsub(string.gsub(tostring(name or ''), ' ', '_'), '[^%w_]', ''))
end

requests.wsl = function(player, w)
    local W, mate = wsSettings(), mateInSlot(player, w[3])
    if W == nil or mate == nil then
        G.reply(player, w[2], 'err', W == nil and 'server' or 'missing', W == nil and 'the weapon skill settings file is missing on the server'
            or 'no squad mate in that slot')
        return
    end

    local trust = mateOut(player, mate.id)
    local list = trust and W.usableIds(trust)
    if trust == nil then
        G.reply(player, w[2], 'err', 'notout', 'call the squad mate first; its weapon skills depend on what it holds now')
        return
    elseif list == nil then
        G.reply(player, w[2], 'err', 'server', 'this map server cannot list a mate\'s weapon skills')
        return
    end

    local lines, line, size = 0, {}, 0
    local budget = REPLY_MAX - #string.format('GSQ|%s|wsl|', w[2])
    local function flush()
        if #line > 0 then
            G.reply(player, w[2], 'wsl', table.concat(line, ','))
            lines, line, size = lines + 1, {}, 0
        end
    end

    for _, e in ipairs(list) do
        local entry = string.format('%d:%s', tonumber(e.id) or 0, G.wsWireName(e.name))
        local add = #entry + (#line > 0 and 1 or 0)
        if #line > 0 and size + add > budget then
            flush()
            add = #entry
        end

        line[#line + 1] = entry
        size = size + add
    end

    flush()
    G.reply(player, w[2], 'end', lines, #list)
end

requests.wss = function(player, w)
    local W, mate = wsSettings(), mateInSlot(player, w[3])
    if W == nil or mate == nil then
        G.reply(player, w[2], 'err', W == nil and 'server' or 'missing', W == nil and 'the weapon skill settings file is missing on the server'
            or 'no squad mate in that slot')
        return
    end

    local s = { control = tonumber(w[4] or ''), mode = tonumber(w[5] or ''), tp = tonumber(w[6] or ''), ws = tonumber(w[7] or '') }
    local value, why = W.encode(s)
    if value == nil then
        G.reply(player, w[2], 'err', 'badreq', why)
        return
    end

    if s.control == 1 and not W.engineReady() then
        G.reply(player, w[2], 'err', 'engine', 'Custom weapon skills need the updated map server (xi_map)')
        return
    end

    if s.ws > 0 then
        local known = xi and rawget(xi, 'weaponskill')
        local found = type(known) ~= 'table'
        for _, v in pairs(type(known) == 'table' and known or {}) do
            found = found or v == s.ws
        end

        if not found then
            G.reply(player, w[2], 'err', 'badreq', 'unknown weapon skill ' .. s.ws)
            return
        end

        -- a called mate: the new choice must be one it can use now (a saved choice that stops being usable is kept)
        local trust = mateOut(player, mate.id)
        local current = W.resolve(player, mate.id, trust and trust:getMainJob() or mate.mjob)
        if trust and s.ws ~= current.ws and W.isUsable(trust, s.ws) == false then
            G.reply(player, w[2], 'err', 'notusable', mate.name .. ' cannot use that weapon skill now')
            return
        end
    end

    local trust = mateOut(player, mate.id)
    player:setCharVar(W.varName(mate.id, trust and trust:getMainJob() or mate.mjob), value)
    replyWs(player, w[2], W, mate)
end

requests.wsa = function(player, w)
    local W, mate = wsSettings(), mateInSlot(player, w[3])
    if W == nil or mate == nil then
        G.reply(player, w[2], 'err', W == nil and 'server' or 'missing', W == nil and 'the weapon skill settings file is missing on the server'
            or 'no squad mate in that slot')
        return
    end

    local trust = mateOut(player, mate.id)
    if trust == nil then
        G.reply(player, w[2], 'err', 'notout', 'not called: the saved setting applies when the mate is called')
        return
    end

    W.liveApply(player, mate, trust)
    replyWs(player, w[2], W, mate)
end

-- ---------------------------------------------------------------- (version 7) party roles (squad_jobs.lua)
local function partyRoles()
    local ok, J = pcall(require, 'modules/custom/lua/squad_jobs')
    return ok and type(J) == 'table' and type(J.setRole) == 'function' and J or nil
end

-- names on the wire: letters, digits, _ and - only
local function wireName(name)
    local s = string.gsub(tostring(name or ''), '[^%w_%-]', '')
    return s ~= '' and s or '?'
end

-- entity:method(...) that cannot fail the request: its result, or the fallback when it errors or gives nil
local function call(entity, method, fallback, ...)
    local args = { ... }
    local ok, v = pcall(function()
        return entity[method](entity, (table.unpack or unpack)(args))
    end)

    return ok and v ~= nil and v or fallback
end

-- the member is a trust (false when that cannot be told)
local function isTrustEntity(member)
    local ok, yes = pcall(function()
        return member:getObjType() == xi.objType.TRUST
    end)

    return ok and yes == true
end

-- the pr line of you (mate nil) or one of your squad mates, read from where the role is kept
local function replyRole(player, id, J, mate)
    local state = J.roleState(player, mate)
    if mate == nil then
        local job = call(player, 'getMainJob', 0)
        G.reply(player, id, 'pr', 0, wireName(call(player, 'getName', 'you')), jobName(job),
            call(player, 'getMainLvl', 0), state.set, J.autoTargets(job), 1, state.live or 0)
        return
    end

    local okL, main = G.levels(mate, player)
    local level = okL and main or (mate.jobs and mate.jobs[mate.mjob] and mate.jobs[mate.mjob].level) or 0
    G.reply(player, id, 'pr', mate.slot, wireName(mate.name), jobName(mate.mjob), level, state.set, J.autoTargets(mate.mjob),
        state.out and 1 or 0, state.live ~= nil and state.live or '-')
end

requests.prl = function(player, w)
    local J = partyRoles()
    if J == nil then
        G.reply(player, w[2], 'err', 'server', 'party roles are not available on this server (squad_jobs.lua)')
        return
    end

    local squad, count = squadOf(player), 0
    replyRole(player, w[2], J, nil)
    count = count + 1
    for _, mate in ipairs(squad) do
        replyRole(player, w[2], J, mate)
        count = count + 1
    end

    -- everyone else in the party now (a dualbox character, another player, their trusts, a trust that is not a squad
    -- mate): read-only, as the engine sees them, so a summary of "who counts as tank" is never missing them
    local own = {}
    for _, mate in ipairs(squad) do
        own[mate.id] = true
    end

    local me = call(player, 'getID', -1)
    for _, member in pairs(call(player, 'getPartyWithTrusts', {})) do
        local memberId = call(member, 'getID', -2)
        local isTrust = isTrustEntity(member)
        local mine = false
        if isTrust then
            local master = call(member, 'getMaster', nil)
            local masterId = master and type(master) ~= 'number' and call(master, 'getID', -3) or -3
            mine = masterId == me and own[call(member, 'getLocalVar', 0, 'SQUAD_ID')] == true
        end

        if memberId ~= me and not mine then
            local job = call(member, 'getMainJob', 0)
            local name = isTrust and call(member, 'getPacketName', nil) or nil
            name = name or call(member, 'getName', '?')
            G.reply(player, w[2], 'pm', wireName(name), jobName(job), isTrust and 't' or 'p',
                J.effectiveTargets(call(member, 'getLocalVar', 0, 'SQUAD_ROLE'), job))
            count = count + 1
        end
    end

    G.reply(player, w[2], 'end', count)
end

requests.prs = function(player, w)
    local J = partyRoles()
    if J == nil then
        G.reply(player, w[2], 'err', 'server', 'party roles are not available on this server (squad_jobs.lua)')
        return
    end

    local whoText, roleText = w[3] or '', w[4] or ''
    if
        not string.match(whoText, '^%d+$') or
        not string.match(roleText, '^%d+$') or
        w[5] ~= nil
    then
        G.reply(player, w[2], 'err', 'badreq', 'prs needs who (0 = you, or a squad slot) and a role 0-4')
        return
    end

    local role = tonumber(roleText)
    if J.ROLE_NAME[role] == nil then
        G.reply(player, w[2], 'err', 'badreq', 'the role must be 0 auto, 1 tank, 2 melee, 3 mage or 4 ranged')
        return
    end

    -- only you, or a mate of YOUR squad (the slot is looked up in the sender's own squad)
    local mate = nil
    if tonumber(whoText) ~= 0 then
        mate = mateInSlot(player, whoText)
        if mate == nil then
            G.reply(player, w[2], 'err', 'missing', 'no squad mate in that slot')
            return
        end
    end

    local state, why = J.setRole(player, mate, role)
    if state == nil then
        G.reply(player, w[2], 'err', 'badreq', why or 'the role was not set')
        return
    end

    replyRole(player, w[2], J, mate)
    G.reply(player, w[2], 'end', 1)
end

requests.w = function(player, w, rest)
    if w[6] ~= nil then
        G.reply(player, w[2], 'err', 'badreq', 'save data must not contain spaces')
        return
    end

    part(player, w[2], w[3], w[4], rest)
end

requests.x = function(player, w, rest)
    if w[6] ~= nil then
        G.reply(player, w[2], 'err', 'badreq', 'save data must not contain spaces')
        return
    end

    part(player, w[2], w[3], w[4], rest, true)
end

requests.del = function(player, w)
    local token, num = w[2], tonumber(w[3] or '')
    local charId = player:getID()
    expire(charId)
    local done = results[charId]
    if done and done.token == token then
        G.reply(player, unpackList(done.reply))
        return
    end

    if token == nil or not string.match(token, '^%d+$') or num == nil then
        G.reply(player, token or '-', 'err', 'badreq', 'del needs a token, a number and a revision')
        return
    end

    local set, code, why = G.save({ op = 'delete', num = num, rev = w[4] }, charId)
    if set == nil then
        finish(player, token, 'err', code, why)
        return
    end

    finish(player, token, 'ok', num, '-', '-')
end

requests.abort = function(player, w)
    local charId = player:getID()
    if drafts[charId] and drafts[charId].token == w[2] then
        drafts[charId] = nil
    end

    G.reply(player, w[2] or '-', 'aborted')
end

-- the whole text after "!gsq "
function G.handle(player, line)
    line = tostring(line or '')
    if #line > 160 then
        G.reply(player, '-', 'err', 'toolong', 'request too long')
        return
    end

    local w = {}
    for word in string.gmatch(line, '%S+') do
        w[#w + 1] = word
    end

    local fn = requests[w[1] or '']
    if fn == nil or w[2] == nil or not string.match(w[2], '^%d+$') then
        G.reply(player, w[2] or '-', 'err', 'badreq', 'unknown request')
        return
    end

    -- the save data is the 5th word of "w <token> <seq> <total> <data>" (it has no spaces)
    local ok, err = pcall(fn, player, w, w[5])
    if not ok then
        print('[squad] Rule Sets editor: request failed: ' .. tostring(err))
        G.reply(player, w[2], 'err', 'server', 'the server could not do that (see its log)')
    end
end

-- repair a save that a crash interrupted, once at start-up
do
    local St = store()
    if St then
        local okRec, done = pcall(St.recover)
        if okRec then
            for _, what in ipairs(done) do
                print('[squad] Rule Sets editor: ' .. what)
            end
        end
    end
end

local command = {}
command.cmdprops = { permission = 0, parameters = 's' }
command.onTrigger = function(player, line)
    G.handle(player, line)
end

if xi and xi.module and xi.module.registerCommand then
    xi.module.registerCommand('gsq', command)
end

-- (2026-11-22) for squad.lua's !squad spells <slot>
if xi then
    xi.squad = xi.squad or {}
    xi.squad.mateSpells = G.mateSpells
end

G._requests = requests
return G
