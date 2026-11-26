-----------------------------------
-- Gambits v2, milestone 1: Rule Sets for individual squad mates (XI: Forever Offline).
--
-- A Rule Set is an ordered list of rules for one main job, in the same rule shape the launcher's job-rule editor
-- already uses (squad.lua "Editable job rules"):
--   { id = 'r1', on = true, target = 'PARTY', cond = { 'HPP_LT', 40 }, cond2 = nil, action = { 'family', 'CURE' },
--     retry = nil, level = nil }
-- A player chooses one set per squad mate and main job with   !squad ruleset <slot> <number|off>
-- (stored on the player as the char vars SQUAD_RS_<mate id>_<job id> = the set's number, 0 = none, the default, and
-- SQUAD_RSH_<mate id>_<job id> = a check number made from the set's id, so a number later reused by another set is noticed).
-- When a mate is called with a set chosen for its main job, squad.lua applies that set's rules INSTEAD of the job's
-- built-in or launcher-edited rules (main and sub job), without the role/mode filter. The on/off switches still apply.
-- Without a chosen set nothing changes. Built-in job rules are never modified. Bots (xi.squad.profileFor) do not use sets.
--
-- The sets live in modules/custom/lua/squad_rulesets_data.lua (no file = no sets), re-read every time a mate is called,
-- so a changed file applies with "Apply now" (!squad reapply), without restarting the server:
--   return { format = 'xifo-ruleset-store', version = 1, sets = { { format = 'xifo-ruleset', version = 1, num = 1,
--            id = 'custom.whm.cure-basics', name = 'WHM - Cure basics', job = 'WHM', rules = { ... } } } }
-- A set with anything wrong in it is left out (and logged). When the mate is called, a rule it cannot use (a spell or
-- ability the server does not know, above its level, or a job ability of neither its main nor its sub job) is left out
-- for that call; if that leaves no rule at all, the mate uses its normal job rules and the player is told.
-- This file defines no globals; squad.lua loads it with require (squad.lua is at Lua's 200-local limit).
--
-- M1.1 (2026-11-19): condition arguments are checked per condition (types and ranges from gambits_container.cpp
-- CheckTrigger), conditions the engine handles unsafely are refused, the choice is protected by the id check number,
-- unusable sets fall back to the job rules with a message, and job abilities are checked against the main AND sub job
-- and their levels (squad_ja_jobs_data.lua, made from sql/abilities.sql). That check fails closed: without the table a
-- Rule Set's job abilities are left out (its other rules still apply).
-- U13 (2026-11-19): the job ability rules moved to squad_ability_rules.lua, shared with the built-in and launcher-edited
-- job rules (squad.lua addGambit), and now include merit abilities (the owner's merit must be unlocked).
-----------------------------------
local R = {}

R.STORE_FORMAT  = 'xifo-ruleset-store'
R.SET_FORMAT    = 'xifo-ruleset'
R.VERSION       = 1
R.DATA_MODULE   = 'modules/custom/lua/squad_rulesets_data'
R.MAX_RULES     = 32
R.MAX_NUM       = 9999
R.VAR_PREFIX    = 'SQUAD_RS_'
R.HASH_PREFIX   = 'SQUAD_RSH_'

-- FFXI job ids (the same numbers squad.lua's jobIds use)
R.JOB_IDS =
{
    WAR = 1, MNK = 2, WHM = 3, BLM = 4, RDM = 5, THF = 6, PLD = 7, DRK = 8, BST = 9, BRD = 10, RNG = 11, SAM = 12,
    NIN = 13, DRG = 14, SMN = 15, BLU = 16, COR = 17, PUP = 18, DNC = 19, SCH = 20,
}

-- What squad.lua's ruleAction understands, and whether the action needs a name
-- (WotG, 2026-11-22) waltz = the best Curing Waltz, samba = the best samba, storm = the storm of the day, helix = the
-- helix of the day (the engine's HIGHEST_WALTZ, BEST_SAMBA, STORM_DAY and HELIX_DAY choices; DNC and SCH)
local ACTION_KINDS = { spell = true, family = true, ja = true, ranged = false, nuke = false, burst = false,
                       waltz = false, samba = false, storm = false, helix = false }
-- the job ability the waltz and samba actions need (main or sub job at its level), checked like a named job ability
local ACTION_JA = { waltz = 'CURING_WALTZ', samba = 'DRAIN_SAMBA' }

-- The argument each condition takes, as gambits_container.cpp CheckTrigger reads it (condition_arg is a uint32, so a
-- negative number would wrap around; the TP and HP checks cast it to int16):
--   'none'                 the engine ignores the argument (it must be left out)
--   { low, high }          a whole number in that range ({ main = n, sub = n } also allowed, as squad.lua's ruleArg reads it)
--   'effect'               a status effect name (xi.effect)           STATUS / NOT_STATUS
--                          (Bard song tiers) or { effect = NAME, tier = n } for one song of a song type, e.g.
--                          { effect = 'MARCH', tier = 2 } = Victory March: only song effects, tier 1-R.MAX_SONG_TIER,
--                          only with the map server that reads tiers (R.tierReady)
--   'flag'                 { flag = NAME } (xi.effectFlag)            STATUS_FLAG
--   'ecosystem'            { ecosystem = NAME } (xi.ecosystem)        IS_ECOSYSTEM
--   'ja'                   a job ability name (xi.ja)                 JA_ON_COOLDOWN (the mate cannot use it yet: its recast is running)
-- A condition not listed here is not offered for Rule Sets (yet), so it fails clearly instead of being guessed at.
-- (2026-11-20, Gambits WAR/PLD/RDM batch) HAS_MP, HAS_MP_MPP_LT/GTE (false for a target without MP), JA_ON_COOLDOWN (fixed
-- in gambits_container.cpp) and the target PARTY_LOWEST_HPP need the map server built with that batch: R.ENGINE_NAMES are
-- refused on an older xi_map (R.engineReady()), where JA_ON_COOLDOWN would test the wrong thing or crash.
R.CONDITIONS =
{
    ALWAYS = 'none',
    HPP_LT = { 0, 100 }, HPP_GTE = { 0, 100 }, MPP_LT = { 0, 100 }, MPP_GTE = { 0, 100 },  -- percent of max HP/MP
    TP_LT = { 0, 3000 }, TP_GTE = { 0, 3000 },                                              -- TP
    LVL_LT = { 1, 99 }, LVL_GTE = { 1, 99 },                                                -- the target's main level
    HP_MISSING = { 1, 9999 },                                                               -- max HP minus HP, in HP
    RANDOM = { 1, 100 },                                                                    -- percent chance (100 = always)
    TIMER = { 0, 3600 },                                                                    -- seconds between hits (0 = always)
    STATUS = 'effect', NOT_STATUS = 'effect',
    STATUS_FLAG = 'flag',
    IS_ECOSYSTEM = 'ecosystem',
    HAS_TOP_ENMITY = 'none', NOT_HAS_TOP_ENMITY = 'none', PT_HAS_TANK = 'none', NOT_PT_HAS_TANK = 'none',
    SC_AVAILABLE = 'none', NOT_SC_AVAILABLE = 'none', MB_AVAILABLE = 'none', LUNGE_MB_AVAILABLE = 'none',
    READYING_WS = 'none', READYING_MS = 'none', READYING_JA = 'none',
    CASTING_MA = 'none', CASTING_DEBUFF = 'none', CASTING_ELEMENT_MA = 'none', CAST_ELE_MA_SELF = 'none',
    CASTING_ELE_MA_AOE = 'none', NEED_ELE_BAREFFECT = 'none',
    NO_SAMBA = 'none', NO_STORM = 'none', NO_MAX_RUNE = 'none', HAS_RUNES = 'none',
    HAS_MP = 'none', HAS_MP_MPP_LT = { 0, 100 }, HAS_MP_MPP_GTE = { 0, 100 },               -- false without an MP pool
    JA_ON_COOLDOWN = 'ja',
    -- (job expansion) a modifier of the target below a number: { mod = NAME, below = n }, NAME one of R.MODS
    MOD_LT = 'mod',
    -- (F1, 2026-11-25) the enemy is of a monster family: { family = NAME } (xi.mobFamily: GOBLIN, ORC, QUADAV ...). The enemy is
    -- the rule's target when that is a monster, else the mate's own enemy, so SELF / PARTY rules can ask: "Goblin -> Barfira".
    ENEMY_FAMILY = 'family',
    -- (F2, 2026-11-25) counts, { cmp = AT_LEAST | EXACTLY | AT_MOST | MORE_THAN | FEWER_THAN, count = n, ... }:
    --   PARTY_COUNT { status = NAME or 'ASLEEP' (Sleep, Sleep II, Lullaby) or nil (everyone) }: living party members within
    --               20 yalms of the mate, the mate included, e.g. { status = 'ASLEEP', cmp = 'AT_LEAST', count = 2 } -> Curaga
    --   ENEMY_COUNT { hp_above = 0-99 (default 0), radius = 1-30 yalms around the mate's enemy (default 10) }: the monsters
    --               fighting the party there (not the ones only standing near), e.g. { hp_above = 30, cmp = 'AT_LEAST', count = 3 }
    PARTY_COUNT = 'pcount',
    ENEMY_COUNT = 'ecount',
}

-- (F2) the comparisons of a count, as the engine numbers them (squad_threat.h CountMatches)
R.COUNT_CMP = { AT_LEAST = 0, EXACTLY = 1, AT_MOST = 2, MORE_THAN = 3, FEWER_THAN = 4 }
R.PARTY_COUNT_MAX = 18
R.ENEMY_COUNT_MAX = 30
R.ASLEEP_FILTER = 0xFFFE

local function isWholeNumber(value, low, high)
    return type(value) == 'number' and value == math.floor(value) and value >= low and value <= high
end

-- (F1/F2) true when xi_map has the community feedback milestone's engine (squad.cpp registers SquadFeedbackEngine)
function R.engine3Ready()
    return type(rawget(_G, 'SquadFeedbackEngine')) == 'function'
end

-- (F1) { family = 'GOBLIN' } -> the family id, or nil
function R.familyArg(arg)
    local families = type(xi) == 'table' and rawget(xi, 'mobFamily') or nil
    if type(arg) ~= 'table' or type(families) ~= 'table' or type(arg.family) ~= 'string' then
        return nil
    end

    local id = families[arg.family]
    return type(id) == 'number' and id or nil
end

-- (F2) { status = 'ASLEEP', cmp = 'AT_LEAST', count = 2 } -> filter | count << 16 | cmp << 24, or nil
function R.partyCountArg(arg)
    if type(arg) ~= 'table' or R.COUNT_CMP[arg.cmp or 'AT_LEAST'] == nil or not isWholeNumber(arg.count, 0, R.PARTY_COUNT_MAX) then
        return nil
    end

    local filter = 0
    if arg.status == 'ASLEEP' then
        filter = R.ASLEEP_FILTER
    elseif arg.status ~= nil then
        local effects = type(xi) == 'table' and rawget(xi, 'effect') or nil
        filter = type(effects) == 'table' and effects[arg.status] or nil
        if type(filter) ~= 'number' or filter <= 0 or filter >= R.ASLEEP_FILTER then
            return nil
        end
    end

    return filter + arg.count * 65536 + R.COUNT_CMP[arg.cmp or 'AT_LEAST'] * 16777216
end

-- (F2) { hp_above = 30, radius = 10, cmp = 'AT_LEAST', count = 3 } -> hp | radius << 8 | count << 16 | cmp << 24, or nil
function R.enemyCountArg(arg)
    if type(arg) ~= 'table' or R.COUNT_CMP[arg.cmp or 'AT_LEAST'] == nil or not isWholeNumber(arg.count, 0, R.ENEMY_COUNT_MAX) then
        return nil
    end

    local hp, radius = arg.hp_above or 0, arg.radius or 10
    if not isWholeNumber(hp, 0, 99) or not isWholeNumber(radius, 1, 30) then
        return nil
    end

    return hp + radius * 256 + arg.count * 65536 + R.COUNT_CMP[arg.cmp or 'AT_LEAST'] * 16777216
end

-- (job expansion) the modifiers MOD_LT may name, with the numbers that make sense for "below": Utsusemi shadows and
-- Blink images (battleutils.cpp IsAbsorbByShadow counts them down in these mods; the Copy Image effect's power does not
-- change). Stoneskin is not a mod: its HP left is the effect's power, so it is not offered.
R.MODS = {
    UTSUSEMI  = { 1, 7 },
    BLINK     = { 1, 3 },
}

-- The names that need the map server of the Gambits WAR/PLD/RDM batch (see above)
R.ENGINE_NAMES = { HAS_MP = true, HAS_MP_MPP_LT = true, HAS_MP_MPP_GTE = true, JA_ON_COOLDOWN = true, PARTY_LOWEST_HPP = true }
-- ... and the ones that need the job expansion's map server
R.ENGINE2_NAMES = { MOD_LT = true }
-- ... and the ones that need the community feedback milestone's map server (F1, F2)
R.ENGINE3_NAMES = { ENEMY_FAMILY = true, PARTY_COUNT = true, ENEMY_COUNT = true }

-- true when xi_map has that batch: its squad.cpp registers SquadApplyWeaponSkills (built from the same source)
function R.engineReady()
    return type(rawget(_G, 'SquadApplyWeaponSkills')) == 'function'
end

-- (job expansion) true when xi_map has the job expansion's engine (squad.cpp registers SquadJobExpansionEngine)
function R.engine2Ready()
    return type(rawget(_G, 'SquadJobExpansionEngine')) == 'function'
end

-- (job expansion) { mod = 'UTSUSEMI', below = 2 } -> the engine's argument (mod id + below * 65536), or nil
function R.modArg(arg)
    local mods = type(xi) == 'table' and rawget(xi, 'mod') or nil
    if type(arg) ~= 'table' or type(mods) ~= 'table' or R.MODS[arg.mod or ''] == nil or type(arg.below) ~= 'number' then
        return nil
    end

    local id = mods[arg.mod]
    if type(id) ~= 'number' then
        return nil
    end

    return id + math.floor(arg.below) * 65536
end

-- (Bard song tiers) the song effects (status_effect_container.cpp ApplyBardEffect: REQUIEM..NOCTURNE) and their tiers
-- (enhancing_song.lua songPTable: Advancing March 1, Victory March 2, Valor Minuet V 5, Army's Paeon VI 6 ...)
R.SONG_EFFECT_FIRST, R.SONG_EFFECT_LAST = 192, 223 -- (xi.effect.REQUIEM, xi.effect.NOCTURNE when the enum is there)
R.MAX_SONG_TIER = 7

-- true when xi_map's STATUS / NOT_STATUS read a tier (squad.cpp registers SquadStatusTierEngine)
function R.tierReady()
    return type(rawget(_G, 'SquadStatusTierEngine')) == 'function'
end

function R.isSongEffect(name)
    local effects = type(xi) == 'table' and rawget(xi, 'effect') or nil
    local id = type(effects) == 'table' and effects[name] or nil
    if type(id) ~= 'number' then
        return false
    end

    local first = type(effects) == 'table' and effects.REQUIEM or R.SONG_EFFECT_FIRST
    local last = type(effects) == 'table' and effects.NOCTURNE or R.SONG_EFFECT_LAST
    return id >= first and id <= last
end

-- (Bard song tiers) { effect = 'MARCH', tier = 2 } -> the engine's argument (effect id + tier * 65536), or nil
function R.effectArg(arg)
    local effects = type(xi) == 'table' and rawget(xi, 'effect') or nil
    local tier = type(arg) == 'table' and arg.tier or nil
    if type(arg) ~= 'table' or type(effects) ~= 'table' or type(arg.effect) ~= 'string' or type(tier) ~= 'number'
        or tier ~= math.floor(tier) or tier < 1 or tier > R.MAX_SONG_TIER or not R.isSongEffect(arg.effect) then
        return nil
    end

    return effects[arg.effect] + arg.tier * 65536
end

-- Conditions the engine has but that a Rule Set must not use, and why (gambits_container.cpp CheckTrigger)
R.REFUSED_CONDITIONS =
{
    SUB_ANIMATION   = 'it compares an internal animation number, which has no meaning in a rule',
    VAL_URIEL_CHECK = 'it is a special check for one trust and assumes its master is in battle',
}

local lastProblems = nil -- the problem text printed last, so an unchanged broken file is not logged on every call

local function isName(text)
    return type(text) == 'string' and string.match(text, '^[A-Z][A-Z0-9_]*$') ~= nil
end

local function isWhole(value, low, high)
    return type(value) == 'number' and value == math.floor(value) and value >= low and value <= high
end

-- Looks a name up in one of the server's enum tables (xi.effect, ...). nil = the table is not there (no check possible).
local function known(tableName, name)
    local t = type(xi) == 'table' and rawget(xi, tableName) or nil
    if type(t) ~= 'table' then
        return nil
    end

    return t[name] ~= nil
end

local function rangeProblem(name, value, spec)
    if not isWhole(value, spec[1], spec[2]) then
        return string.format('%s needs a whole number %d-%d', name, spec[1], spec[2])
    end
end

-- A condition: { NAME, argument }. Returns a problem text or nil.
local function conditionProblem(cond)
    if type(cond) ~= 'table' or not isName(cond[1]) then
        return 'the condition must be { NAME, argument }'
    end

    local name, arg = cond[1], cond[2]
    if R.REFUSED_CONDITIONS[name] then
        return name .. ' cannot be used in a Rule Set: ' .. R.REFUSED_CONDITIONS[name]
    end

    if R.ENGINE_NAMES[name] and not R.engineReady() then
        return name .. ' needs the updated map server (xi_map)'
    end

    if R.ENGINE2_NAMES[name] and not R.engine2Ready() then
        return name .. ' needs the updated map server (xi_map, job expansion)'
    end

    if R.ENGINE3_NAMES[name] and not R.engine3Ready() then
        return name .. ' needs the updated map server (xi_map, enemy family and count conditions)'
    end

    if ai ~= nil and ai.c ~= nil and ai.c[name] == nil then
        return 'unknown condition ' .. name
    end

    local spec = R.CONDITIONS[name]
    if spec == nil then
        return name .. ' is not supported in Rule Sets yet'
    end

    if spec == 'none' then
        if arg ~= nil and arg ~= 0 then
            return name .. ' takes no value'
        end

        return nil
    end

    if type(spec) == 'table' then
        if type(arg) == 'table' and (arg.main ~= nil or arg.sub ~= nil) and arg.flag == nil and arg.ecosystem == nil then
            return (arg.main ~= nil and rangeProblem(name .. ' main', arg.main, spec))
                or (arg.sub ~= nil and rangeProblem(name .. ' sub', arg.sub, spec)) or nil
        end

        return rangeProblem(name, arg, spec)
    end

    if spec == 'effect' and type(arg) == 'table' then
        -- (Bard song tiers) { effect = NAME, tier = n }: nothing else in the table
        for key in pairs(arg) do
            if key ~= 'effect' and key ~= 'tier' then
                return name .. ' takes { effect = NAME, tier = n } (unknown field ' .. tostring(key) .. ')'
            end
        end

        if not isName(arg.effect) then
            return name .. ' needs { effect = NAME, tier = n } with a song effect name like MARCH'
        end

        if known('effect', arg.effect) == false then
            return 'unknown status effect ' .. arg.effect
        end

        if known('effect', arg.effect) and not R.isSongEffect(arg.effect) then
            return name .. ': only song effects (MARCH, MINUET ...) take a tier, not ' .. arg.effect
        end

        if not R.tierReady() then
            return name .. ' with a song tier needs the updated map server (xi_map, Bard song tiers)'
        end

        return rangeProblem(name .. ' tier', arg.tier, { 1, R.MAX_SONG_TIER })
    elseif spec == 'effect' then
        if not isName(arg) then
            return name .. ' needs a status effect name like HASTE'
        end

        if known('effect', arg) == false then
            return 'unknown status effect ' .. arg
        end
    elseif spec == 'flag' then
        if type(arg) ~= 'table' or not isName(arg.flag) then
            return name .. ' needs { flag = NAME }'
        end

        if known('effectFlag', arg.flag) == false then
            return 'unknown effect flag ' .. arg.flag
        end
    elseif spec == 'ecosystem' then
        if type(arg) ~= 'table' or not isName(arg.ecosystem) then
            return name .. ' needs { ecosystem = NAME }'
        end

        if known('ecosystem', arg.ecosystem) == false then
            return 'unknown ecosystem ' .. arg.ecosystem
        end
    elseif spec == 'ja' then
        if not isName(arg) then
            return name .. ' needs a job ability name like PROVOKE'
        end

        if known('ja', arg) == false then
            return 'unknown job ability ' .. arg
        end
    elseif spec == 'mod' then
        local range = type(arg) == 'table' and R.MODS[arg.mod or ''] or nil
        if type(arg) ~= 'table' or not isName(arg.mod) then
            return name .. ' needs { mod = NAME, below = n }'
        end

        if range == nil then
            return name .. ' cannot use the modifier ' .. arg.mod .. ' (only UTSUSEMI, BLINK)'
        end

        if known('mod', arg.mod) == false then
            return 'unknown modifier ' .. arg.mod
        end

        return rangeProblem(name .. ' below', arg.below, range)
    elseif spec == 'family' then
        if type(arg) ~= 'table' or not isName(arg.family) then
            return name .. ' needs { family = NAME } like GOBLIN'
        end

        if known('mobFamily', arg.family) == false then
            return 'unknown monster family ' .. arg.family
        end
    elseif spec == 'pcount' or spec == 'ecount' then
        local fields = spec == 'pcount' and { status = true, cmp = true, count = true } or { hp_above = true, radius = true, cmp = true, count = true }
        if type(arg) ~= 'table' then
            return name .. ' needs { cmp = AT_LEAST|EXACTLY|AT_MOST|MORE_THAN|FEWER_THAN, count = n, ... }'
        end

        for key in pairs(arg) do
            if not fields[key] then
                return name .. ': unknown field ' .. tostring(key)
            end
        end

        if arg.cmp ~= nil and R.COUNT_CMP[arg.cmp] == nil then
            return name .. ': cmp must be AT_LEAST, EXACTLY, AT_MOST, MORE_THAN or FEWER_THAN'
        end

        if spec == 'pcount' then
            if arg.status ~= nil and arg.status ~= 'ASLEEP' then
                if not isName(arg.status) then
                    return name .. ': status must be a status effect name like PETRIFICATION, or ASLEEP'
                end

                if known('effect', arg.status) == false then
                    return 'unknown status effect ' .. arg.status
                end
            end

            return rangeProblem(name .. ' count', arg.count, { 0, R.PARTY_COUNT_MAX })
        end

        return rangeProblem(name .. ' count', arg.count, { 0, R.ENEMY_COUNT_MAX })
            or (arg.hp_above ~= nil and rangeProblem(name .. ' hp_above', arg.hp_above, { 0, 99 }))
            or (arg.radius ~= nil and rangeProblem(name .. ' radius', arg.radius, { 1, 30 })) or nil
    end

    return nil
end

-- ---------------------------------------------------------------- job abilities: shared rules (Gambits v2 U13)
-- Which job abilities a squad mate may use is decided in ONE place, squad_ability_rules.lua, for the built-in, the
-- launcher-edited and the Rule Set rules alike: main/sub job and level, two-hours and main-job-only abilities never
-- from the sub job, no pet abilities, and merit abilities only with the merit unlocked by the owner. It fails closed.
-- Here it is used to leave unusable rules out when the mate is called (so the fallback to the job rules still works),
-- and to refuse, at load, abilities no squad mate could ever use (no job, pet abilities).
local function abilityRules()
    local ok, rules = pcall(require, 'modules/custom/lua/squad_ability_rules')
    if ok and type(rules) == 'table' then
        return rules
    end

    return nil
end

-- Forgets the job ability table so the next check reads it again (after it was regenerated; also used by the tests)
function R.reloadJaTable()
    local rules = abilityRules()
    if rules then
        rules.reload()
    end
end

-- Returns info, id:  info = { job, level, sp, mainOnly, merit, pet } | false (no valid row for it) | nil (no table, or
-- the shared rules are missing)   id = the ability id from xi.ja, or nil for a name the server does not know
function R.jaInfo(name)
    local rules = abilityRules()
    local jaIds = type(xi) == 'table' and rawget(xi, 'ja') or nil
    local id = type(jaIds) == 'table' and jaIds[name] or nil
    if rules == nil or id == nil then
        return nil, id
    end

    return rules.info(id), id
end

-- Problems with a job ability action that do not depend on the mate (an empty list = fine)
local function jaProblem(name)
    local info, id = R.jaInfo(name)
    if id == nil then
        return nil -- unknown name: left out when the mate is called, as squad.lua always did (and logged then)
    end

    -- no table, or no valid row (an incomplete table): the set stays usable, and this rule is left out when the mate is
    -- called (R.unusableReason), so the set's other rules still apply
    if info and info.job == 0 then
        return 'job ability ' .. name .. ' belongs to no job'
    elseif info and info.pet then
        return name .. ' is a pet ability or the pet command menu, which a squad mate does not use itself'
    end

    return nil
end

-- (Gambits 0.3.3, Bard role targeting) a role target (TANK, MELEE, CASTER, RANGED) may name more roles that also qualify
-- (include, OR) and roles that never do (exclude, any of them; exclusion wins):
--   { target = 'MELEE', exclude = { 'TANK' } }          melee members that are not tanks (a PLD on Auto is both)
--   { target = 'TANK', include = { 'CASTER' } }         tanks or mages
-- The engine reads them from the target argument (gambits_container.cpp AddGambit; R.roleMasks). Bits as the engine's.
R.ROLE_BITS = { TANK = 1, MELEE = 2, CASTER = 4, RANGED = 8 }
R.ROLE_ORDER = { 'TANK', 'MELEE', 'CASTER', 'RANGED' }

-- true when xi_map reads role filters (squad.cpp registers SquadRoleFilterEngine)
function R.roleFilterReady()
    return type(rawget(_G, 'SquadRoleFilterEngine')) == 'function'
end

-- why a rule's include / exclude is wrong, or nil (a rule without them: nil)
function R.roleFilterProblem(rule)
    if rule.include == nil and rule.exclude == nil then
        return nil
    end

    if R.ROLE_BITS[rule.target or ''] == nil then
        return 'include / exclude roles only work with the targets TANK, MELEE, CASTER or RANGED'
    end

    local seen = { [rule.target] = 'target' }
    for _, key in ipairs({ 'include', 'exclude' }) do
        local list = rule[key]
        if list ~= nil then
            if type(list) ~= 'table' or #list == 0 or #list > 3 then
                return key .. ' must be a list of 1-3 roles (TANK, MELEE, CASTER, RANGED)'
            end

            for k in pairs(list) do
                if type(k) ~= 'number' or k < 1 or k > #list or k ~= math.floor(k) then
                    return key .. ' must be a plain list of roles'
                end
            end

            for _, role in ipairs(list) do
                if R.ROLE_BITS[role] == nil then
                    return key .. ': unknown role ' .. tostring(role) .. ' (TANK, MELEE, CASTER or RANGED)'
                end

                if seen[role] then
                    return string.format('the role %s is named twice (%s and %s): a role is either included or excluded',
                        role, seen[role], key)
                end

                seen[role] = key
            end
        end
    end

    if not R.roleFilterReady() then
        return 'include / exclude roles need the updated map server (xi_map, role filters)'
    end

    return nil
end

-- { target, include, exclude } -> the engine's target argument (target id | include bits << 8 | exclude bits << 12), or
-- the plain target id when the rule has no role filter
function R.roleMasks(rule, targetId)
    local inc, exc = 0, 0
    for _, role in ipairs(type(rule.include) == 'table' and rule.include or {}) do
        inc = inc + (R.ROLE_BITS[role] or 0)
    end

    for _, role in ipairs(type(rule.exclude) == 'table' and rule.exclude or {}) do
        exc = exc + (R.ROLE_BITS[role] or 0)
    end

    return targetId + inc * 256 + exc * 4096, inc, exc
end

-- Problems with one rule (an empty list = fine)
function R.ruleProblems(rule)
    local out = {}
    if type(rule) ~= 'table' then
        return { 'not a rule' }
    end

    if rule.id ~= nil and (type(rule.id) ~= 'string' or not string.match(rule.id, '^[%w%._%-]+$')) then
        out[#out + 1] = 'id must be letters, digits, dots, dashes or underscores'
    end

    if rule.on ~= nil and type(rule.on) ~= 'boolean' then
        out[#out + 1] = 'on must be true or false'
    end

    if not isName(rule.target) then
        out[#out + 1] = 'target must be a name like PARTY'
    elseif ai ~= nil and ai.t ~= nil and ai.t[rule.target] == nil then
        out[#out + 1] = 'unknown target ' .. rule.target
    elseif R.ENGINE_NAMES[rule.target] and not R.engineReady() then
        out[#out + 1] = 'the target ' .. rule.target .. ' needs the updated map server (xi_map)'
    end

    local roleWhy = R.roleFilterProblem(rule)
    if roleWhy then
        out[#out + 1] = roleWhy
    end

    local problem = conditionProblem(rule.cond)
    if problem then
        out[#out + 1] = 'cond: ' .. problem
    end

    if rule.cond2 ~= nil then
        problem = conditionProblem(rule.cond2)
        if problem then
            out[#out + 1] = 'cond2: ' .. problem
        end
    end

    local action = rule.action
    local named = type(action) == 'table' and ACTION_KINDS[action[1]]
    if named == nil then
        out[#out + 1] = 'action must be { spell|family|ja, NAME } or { ranged|nuke|burst|waltz|samba|storm|helix }'
    elseif named and not isName(action[2]) then
        out[#out + 1] = 'action ' .. action[1] .. ' needs a NAME'
    elseif action[1] == 'ja' then
        problem = jaProblem(action[2])
        if problem then
            out[#out + 1] = problem
        end
    end

    if rule.retry ~= nil and not isWhole(rule.retry, 0, 3600) then
        out[#out + 1] = 'retry must be a whole number of seconds, 0-3600'
    end

    if rule.level ~= nil and not isWhole(rule.level, 0, 75) then
        out[#out + 1] = 'level must be a whole number, 0-75'
    end

    return out
end

-- Problems with one set (an empty list = fine)
function R.setProblems(set)
    if type(set) ~= 'table' then
        return { 'not a table' }
    end

    local out = {}
    if set.format ~= R.SET_FORMAT or set.version ~= R.VERSION then
        out[#out + 1] = string.format("format must be '%s' version %d", R.SET_FORMAT, R.VERSION)
    end

    if not isWhole(set.num, 1, R.MAX_NUM) then
        out[#out + 1] = 'num must be a whole number, 1-' .. R.MAX_NUM
    end

    if type(set.id) ~= 'string' or not string.match(set.id, '^[%w%._%-]+$') then
        out[#out + 1] = 'id must be letters, digits, dots, dashes or underscores'
    end

    if type(set.name) ~= 'string' or set.name == '' then
        out[#out + 1] = 'name is missing'
    end

    if R.JOB_IDS[set.job] == nil then
        out[#out + 1] = 'job must be a main job like WHM'
    end

    if set.readonly ~= nil and type(set.readonly) ~= 'boolean' then
        out[#out + 1] = 'readonly must be true or false'
    end

    if type(set.rules) ~= 'table' or #set.rules == 0 then
        out[#out + 1] = 'rules must list at least one rule'
    elseif #set.rules > R.MAX_RULES then
        out[#out + 1] = 'at most ' .. R.MAX_RULES .. ' rules'
    else
        local seen, enabled = {}, 0
        for i, rule in ipairs(set.rules) do
            for _, problem in ipairs(R.ruleProblems(rule)) do
                out[#out + 1] = string.format('rule %d: %s', i, problem)
            end

            if type(rule) == 'table' then
                if rule.id ~= nil then
                    if seen[rule.id] then
                        out[#out + 1] = string.format('rule %d: id %s is used twice', i, tostring(rule.id))
                    end

                    seen[rule.id] = true
                end

                if rule.on ~= false then
                    enabled = enabled + 1
                end
            end
        end

        if enabled == 0 then
            out[#out + 1] = 'no rule is switched on'
        end
    end

    return out
end

-- Reads the store again (the file may have changed). Returns { byNum = {}, byId = {}, list = {}, problems = {} }.
function R.load()
    local store = { byNum = {}, byId = {}, list = {}, problems = {} }
    package.loaded[R.DATA_MODULE] = nil
    local ok, data = pcall(require, R.DATA_MODULE)
    package.loaded[R.DATA_MODULE] = nil

    if not ok then
        if not string.find(tostring(data), 'not found', 1, true) then
            store.problems[#store.problems + 1] = 'squad_rulesets_data.lua could not be read: ' .. tostring(data)
        end
    elseif type(data) ~= 'table' or data.format ~= R.STORE_FORMAT or data.version ~= R.VERSION or type(data.sets) ~= 'table' then
        store.problems[#store.problems + 1] = string.format("squad_rulesets_data.lua must return { format = '%s', version = %d, sets = { ... } }",
            R.STORE_FORMAT, R.VERSION)
    else
        for index, set in ipairs(data.sets) do
            local problems = R.setProblems(set)
            if #problems == 0 and store.byNum[set.num] ~= nil then
                problems[#problems + 1] = 'num ' .. set.num .. ' is used by another set'
            end

            if #problems == 0 and store.byId[set.id] ~= nil then
                problems[#problems + 1] = 'id ' .. set.id .. ' is used by another set'
            end

            if #problems == 0 then
                store.byNum[set.num], store.byId[set.id] = set, set
                store.list[#store.list + 1] = set
            else
                store.problems[#store.problems + 1] = string.format('set %d (%s): %s', index,
                    type(set) == 'table' and tostring(set.id) or '?', table.concat(problems, '; '))
            end
        end
    end

    local text = table.concat(store.problems, '\n')
    if text ~= '' and text ~= lastProblems then
        print('[squad] Rule Sets: ' .. string.gsub(text, '\n', '\n[squad] Rule Sets: '))
    end

    lastProblems = text
    return store
end

-- ---------------------------------------------------------------- selection (per squad mate and main job)
function R.varName(mateId, jobId)
    return string.format('%s%d_%d', R.VAR_PREFIX, mateId, jobId)
end

function R.hashVarName(mateId, jobId)
    return string.format('%s%d_%d', R.HASH_PREFIX, mateId, jobId)
end

-- The check number of a set id: 1 .. 2^31-2, the same in LuaJIT and Lua 5.4 (fits a char var, which is int(11))
function R.idHash(id)
    local h = 7
    for i = 1, #id do
        h = (h * 31 + string.byte(id, i)) % 2147483647
    end

    return h == 0 and 1 or h
end

function R.selectedNum(player, mateId, jobId)
    return tonumber(player:getCharVar(R.varName(mateId, jobId))) or 0
end

-- Stores the choice; a set (table) also stores its id check number, nil/0 clears both
function R.select(player, mateId, jobId, set)
    local num = type(set) == 'table' and set.num or set or 0
    player:setCharVar(R.varName(mateId, jobId), num)
    player:setCharVar(R.hashVarName(mateId, jobId), type(set) == 'table' and R.idHash(set.id) or 0)
end

-- The set chosen for this mate and job: returns set, nil  or  nil, reason  (reason nil = nothing chosen).
-- The number finds the set; the id check number (when stored) must match, so a reused number is never followed. A set
-- that only got a new number is still found by its id. A choice without a check number (made before M1.1) uses the number.
-- quiet: say nothing in the server log (the Squads menu asks this every 15 s; see R.liveStatus)
function R.resolve(player, mateId, jobId, store, quiet)
    if player == nil or mateId == nil or mateId == 0 or jobId == nil then
        return nil, nil
    end

    local num = R.selectedNum(player, mateId, jobId)
    if num <= 0 then
        return nil, nil
    end

    store = store or R.load()
    local hash = tonumber(player:getCharVar(R.hashVarName(mateId, jobId))) or 0
    local set = store.byNum[num]
    if set ~= nil and R.JOB_IDS[set.job] == jobId and (hash == 0 or R.idHash(set.id) == hash) then
        return set, nil
    end

    if hash ~= 0 then
        local found = {}
        for _, other in ipairs(store.list) do
            if R.JOB_IDS[other.job] == jobId and R.idHash(other.id) == hash then
                found[#found + 1] = other
            end
        end

        if #found == 1 then
            if not quiet then
                print(string.format('[squad] Rule Sets: mate %d: set %s now has number %d (was %d); following it by its id',
                    mateId, found[1].id, found[1].num, num))
            end
            return found[1], nil
        end
    end

    local reason = (set ~= nil and R.JOB_IDS[set.job] == jobId) and 'replaced' or 'gone'
    if not quiet then
        print(string.format('[squad] Rule Sets: mate %d has set %d chosen for job %d, but that set is %s; its job rules are used',
            mateId, num, jobId, reason == 'replaced' and 'now a different set' or 'not there or not valid'))
    end
    return nil, reason
end

-- Kept for M1 callers: the chosen set or nil
function R.selectedSet(player, mateId, jobId, store)
    local set = R.resolve(player, mateId, jobId, store)
    return set
end

-- ---------------------------------------------------------------- what a mate can use when it is called
-- Why one rule cannot be used by this mate now, or nil. Mirrors what squad.lua's applyRules/ruleAction would drop
-- (off, above the level, unknown names), plus the job ability check. On/off SWITCHES are deliberately not looked at:
-- turning magic off is the player's choice and must not bring the job rules back.
function R.unusableReason(rule, m)
    if rule.on == false then
        return 'off'
    end

    if (rule.level or 0) > m.level then
        return string.format('needs level %d', rule.level)
    end

    local action = rule.action
    local kind, name = action[1], action[2]
    -- Spells: only the NAME is checked here. A known spell is not guaranteed to be castable by this mate at its level
    -- (or from its sub job); that is left to the engine (spell::CanUseSpell in gambits_container.cpp), as for job rules.
    local magic = type(xi) == 'table' and rawget(xi, 'magic') or nil
    if kind == 'spell' and magic and type(magic.spell) == 'table' and magic.spell[name] == nil then
        return 'unknown spell ' .. name
    elseif kind == 'family' and magic and type(magic.spellFamily) == 'table' and magic.spellFamily[name] == nil then
        return 'unknown spell family ' .. name
    elseif kind == 'ja' or ACTION_JA[kind] then
        name = ACTION_JA[kind] or name
        -- the shared rules (squad_ability_rules.lua), the same squad.lua addGambit applies; fail closed without them
        local rules = abilityRules()
        local id = rules and rules.idOf(name) or nil
        if rules == nil then
            return name .. ': the job ability rules (squad_ability_rules.lua) are not available'
        elseif id == nil then
            return 'unknown job ability ' .. name
        end

        return rules.reason(m, id, name)
    end

    return nil
end

-- The rules of a set this mate can use now: usable, dropped ({ index, reason })
function R.usableRules(set, m)
    local usable, dropped = {}, {}
    for i, rule in ipairs(set.rules) do
        local reason = R.unusableReason(rule, m)
        if reason == nil then
            usable[#usable + 1] = rule
        elseif reason ~= 'off' then
            dropped[#dropped + 1] = { i, reason }
        end
    end

    return usable, dropped
end

local function tell(master, text)
    if master ~= nil and master.printToPlayer ~= nil then
        master:printToPlayer(text)
    end
end

-- ---------------------------------------------------------------- what a called mate actually runs (live status)
-- (2026-11-24) The Squads menu shows, per mate, what was really installed when the mate was called, next to what is
-- chosen now. It is written at the call (R.forMob, and squad.lua for a job Squads has no rules for) as LOCAL vars on the
-- mate itself: no char var, nothing saved, and it goes away with the mate (dismiss, zoning, Apply now). Nothing in
-- combat reads it.
--   SQUAD_RS_MARK  1 once written at this call (0: an older call path, an add-on's mate: "unknown", never "active")
--   SQUAD_RS_LIVE  the number of the set installed, 0 = job rules
--   SQUAD_RS_LIVEH / SQUAD_RS_LIVEF  that set's id check number / its rules' check number (an edit after the call)
--   SQUAD_RS_FB    why job rules: R.LIVE_FB
--   SQUAD_RS_DROP  rules of the set left out at this call (level, unknown names, abilities of neither job)
--   SQUAD_RS_SELN / SQUAD_RS_SELH  the choice (SQUAD_RS_ / SQUAD_RSH_ char vars) in force at the call
--   SQUAD_RS_JOB   the main job at the call;  SQUAD_RS_BEH  the Role and Mode (SQUAD_AI_) at the call
R.LIVE_FB = { NONE = 0, GONE = 1, REPLACED = 2, UNUSABLE = 3, NOJOB = 4 }

-- A check number of a set's rules (the same in LuaJIT and Lua 5.4): an edited set is noticed as not applied yet
local function serial(v)
    if type(v) ~= 'table' then
        return type(v) == 'string' and string.format('%q', v) or tostring(v)
    end

    local parts, keys = {}, {}
    for i = 1, #v do
        parts[#parts + 1] = serial(v[i])
    end

    for k in pairs(v) do
        if not (type(k) == 'number' and k >= 1 and k <= #v and k % 1 == 0) then
            keys[#keys + 1] = tostring(k)
        end
    end

    table.sort(keys)
    for _, k in ipairs(keys) do
        local value = v[k]
        if value == nil then
            value = v[tonumber(k)]
        end

        parts[#parts + 1] = k .. '=' .. serial(value)
    end

    return '{' .. table.concat(parts, ',') .. '}'
end

function R.fingerprint(set)
    return R.idHash(serial(type(set) == 'table' and set.rules or {}))
end

-- Written when a mate is called: set = the set installed (nil = job rules), fb = R.LIVE_FB, dropped = rules left out
function R.markLive(mob, master, mateId, jobId, set, fb, dropped)
    if mob == nil or master == nil then
        return
    end

    mob:setLocalVar('SQUAD_RS_MARK', 1)
    mob:setLocalVar('SQUAD_RS_LIVE', set and set.num or 0)
    mob:setLocalVar('SQUAD_RS_LIVEH', set and R.idHash(set.id) or 0)
    mob:setLocalVar('SQUAD_RS_LIVEF', set and R.fingerprint(set) or 0)
    mob:setLocalVar('SQUAD_RS_FB', fb or R.LIVE_FB.NONE)
    mob:setLocalVar('SQUAD_RS_DROP', dropped or 0)
    mob:setLocalVar('SQUAD_RS_SELN', tonumber(master:getCharVar(R.varName(mateId, jobId))) or 0)
    mob:setLocalVar('SQUAD_RS_SELH', tonumber(master:getCharVar(R.hashVarName(mateId, jobId))) or 0)
    mob:setLocalVar('SQUAD_RS_JOB', jobId or 0)
    mob:setLocalVar('SQUAD_RS_BEH', tonumber(master:getCharVar('SQUAD_AI_' .. mateId)) or 0)
end

local function findByHash(store, hash)
    if hash == 0 then
        return nil
    end

    for _, set in ipairs(store.list) do
        if R.idHash(set.id) == hash then
            return set
        end
    end

    return nil
end

-- What one squad mate runs now and what is chosen for its next call. mate = squad.lua's mate ({ id, mjob, ... }),
-- trust = the called mate or nil. Returns a table:
--   state  'off' (not called) | 'unknown' (called, nothing recorded) | 'addon' (an add-on owns it) |
--          'set' (the chosen set is running) | 'job' (job rules, none chosen) | 'fallback' (job rules: the chosen set
--          could not be used) | 'pending' (what runs differs from what is chosen: Apply now)
--   why    for 'pending': 'job' (main job changed), 'choice' (another set or none chosen), 'edited' (the set was
--          changed since), 'gone' (the running set is no longer saved), 'role' (Role/Mode changed; job rules only)
--   live / liveName, sel / selName, fb, dropped, liveJob
function R.liveStatus(player, mate, trust, store)
    store = store or R.load()
    local s = { state = 'off', why = '-', live = 0, liveName = '-', sel = 0, selName = '-', fb = 0, dropped = 0, liveJob = 0 }
    local selSet, selReason = R.resolve(player, mate.id, mate.mjob, store, true)
    s.sel = R.selectedNum(player, mate.id, mate.mjob)
    if selSet then
        s.sel, s.selName = selSet.num, selSet.name
    elseif selReason ~= nil then
        s.selName = '?' -- chosen, but no longer usable: the next call uses the job rules
    end

    if trust == nil then
        return s
    end

    if trust:getLocalVar('ADDON_OWNED') == 1 then
        s.state = 'addon'
        return s
    end

    if trust:getLocalVar('SQUAD_RS_MARK') ~= 1 then
        s.state = 'unknown'
        return s
    end

    s.live, s.fb, s.dropped, s.liveJob = trust:getLocalVar('SQUAD_RS_LIVE'), trust:getLocalVar('SQUAD_RS_FB'),
        trust:getLocalVar('SQUAD_RS_DROP'), trust:getLocalVar('SQUAD_RS_JOB')
    local liveSet = nil
    if s.live > 0 then
        liveSet = findByHash(store, trust:getLocalVar('SQUAD_RS_LIVEH'))
        s.liveName = liveSet and liveSet.name or '?'
    end

    local pending = nil
    if s.liveJob ~= mate.mjob then
        pending = 'job'
    elseif R.selectedNum(player, mate.id, mate.mjob) ~= trust:getLocalVar('SQUAD_RS_SELN')
        or (tonumber(player:getCharVar(R.hashVarName(mate.id, mate.mjob))) or 0) ~= trust:getLocalVar('SQUAD_RS_SELH') then
        pending = 'choice'
    elseif s.live > 0 and liveSet == nil then
        pending = 'gone'
    elseif s.live > 0 and R.fingerprint(liveSet) ~= trust:getLocalVar('SQUAD_RS_LIVEF') then
        pending = 'edited'
    elseif s.live > 0 and selSet ~= nil and R.idHash(selSet.id) ~= trust:getLocalVar('SQUAD_RS_LIVEH') then
        pending = 'choice' -- (the same number now names another set: followed by its id at the next call)
    elseif s.live == 0 and (s.fb == R.LIVE_FB.GONE or s.fb == R.LIVE_FB.REPLACED) and selSet ~= nil then
        pending = 'choice' -- (the chosen set could not be found at the call, and now it can)
    elseif s.live == 0 and s.fb == R.LIVE_FB.NONE and selSet == nil
        and (tonumber(player:getCharVar('SQUAD_AI_' .. mate.id)) or 0) ~= trust:getLocalVar('SQUAD_RS_BEH') then
        pending = 'role'
    end

    if pending then
        s.state, s.why = 'pending', pending
    elseif s.live > 0 then
        s.state = 'set'
    elseif s.fb ~= R.LIVE_FB.NONE then
        s.state = 'fallback'
    else
        s.state = 'job'
    end

    return s
end

-- The Squads menu line (servermenu 1.26n): rs|<slot>|<state>|<why>|<live num>|<live name>|<chosen num>|<chosen name>|
-- <fallback reason>|<rules left out>|<job at the call>. Names lose | { } % and are cut to 40 characters. An older menu
-- ignores the line.
function R.panelLine(player, mate, trust, store, jobName)
    local s = R.liveStatus(player, mate, trust, store)
    local function clean(text)
        local out = string.gsub(tostring(text or '-'), '[|{}%%\r\n]', '/')
        out = string.sub(out, 1, 40)
        return out ~= '' and out or '-'
    end

    return string.format('rs|%d|%s|%s|%d|%s|%d|%s|%d|%d|%s', mate.slot, s.state, s.why, s.live, clean(s.liveName), s.sel,
        clean(s.selName), s.fb, s.dropped, s.liveJob ~= 0 and clean(jobName and jobName(s.liveJob) or R.jobName(s.liveJob)) or '-'), s
end

-- squad.lua calls this while a mate spawns. Returns the set to apply (with only the usable rules) or nil for the
-- mate's normal job rules.
function R.forMob(mob)
    local master = mob:getMaster()
    local mateId = mob:getLocalVar('SQUAD_ID')
    if master == nil or mateId == 0 then
        return nil
    end

    local jobId = mob:getMainJob()
    local set, reason = R.resolve(master, mateId, jobId)
    if set == nil then
        if reason ~= nil then
            tell(master, string.format('Squad: the Rule Set chosen for your %s squad mate is %s, so it uses its job rules. See !squad ruleset.',
                R.jobName(jobId), reason == 'replaced' and 'now a different set' or 'no longer usable'))
        end

        R.markLive(mob, master, mateId, jobId, nil, reason == 'replaced' and R.LIVE_FB.REPLACED
            or (reason ~= nil and R.LIVE_FB.GONE or R.LIVE_FB.NONE), 0)
        return nil
    end

    -- owner = the player whose merits count for merit abilities (U13)
    local m = { job = jobId, level = mob:getMainLvl(), subJob = mob:getSubJob() or 0, subLevel = mob:getSubLvl() or 0,
                owner = master }
    local usable, dropped = R.usableRules(set, m)
    for _, d in ipairs(dropped) do
        print(string.format('[squad] Rule Sets: mate %d, set %s rule %d left out this call: %s', mateId, set.id, d[1], d[2]))
    end

    if #usable == 0 then
        print(string.format('[squad] Rule Sets: mate %d, set %s has no rule it can use; its job rules are used', mateId, set.id))
        tell(master, string.format('Squad: Rule Set %d (%s) has no rule your %s squad mate can use at level %d, so it uses its job rules.',
            set.num, set.name, R.jobName(jobId), m.level))
        R.markLive(mob, master, mateId, jobId, nil, R.LIVE_FB.UNUSABLE, #dropped)
        return nil
    end

    R.markLive(mob, master, mateId, jobId, set, R.LIVE_FB.NONE, #dropped)
    if #dropped == 0 then
        return set
    end

    local copy = {}
    for k, v in pairs(set) do
        copy[k] = v
    end

    copy.rules = usable
    return copy
end

function R.jobName(jobId)
    for name, id in pairs(R.JOB_IDS) do
        if id == jobId then
            return name
        end
    end

    return tostring(jobId)
end

-- ---------------------------------------------------------------- !squad ruleset [slot] [number|off]
-- deps: { say = fn(player, text), findMate = fn(squad, slot), jobNames = { [id] = 'WHM' } } from squad.lua
function R.command(player, squad, slotArg, choiceArg, deps)
    local say = deps.say
    local store = R.load()

    if slotArg == nil or slotArg == '' then
        if #store.list == 0 then
            say(player, 'No Rule Sets yet (modules/custom/lua/squad_rulesets_data.lua).')
        end

        for _, set in ipairs(store.list) do
            say(player, string.format('Rule Set %d: %s (%s, %d rules) [%s]', set.num, set.name, set.job, #set.rules, set.id))
        end

        for _, problem in ipairs(store.problems) do
            say(player, 'Not usable: ' .. problem)
        end

        say(player, 'Use: !squad ruleset <slot> <number|off>   (applies when the mate is called again: Apply now)')
        return
    end

    local mate = deps.findMate(squad, tonumber(slotArg) or 0)
    if mate == nil then
        say(player, 'No squad mate in that slot. Use !squad to list them.')
        return
    end

    local jobName = deps.jobNames[mate.mjob] or tostring(mate.mjob)
    local choice = string.lower(tostring(choiceArg or ''))

    if choice == '' then
        local set, reason = R.resolve(player, mate.id, mate.mjob, store)
        local text = 'its job rules (no Rule Set)'
        if set then
            text = string.format('Rule Set %d, %s [%s]', set.num, set.name, set.id)
        elseif reason == 'replaced' then
            text = 'its job rules: the Rule Set chosen earlier was replaced by a different set with the same number. Choose again'
        elseif reason == 'gone' then
            text = 'its job rules: the Rule Set chosen earlier is no longer usable. Choose again'
        end

        say(player, string.format('%s (%s): %s', mate.name, jobName, text))
        return
    end

    if choice == 'off' or choice == 'none' or choice == '0' then
        R.select(player, mate.id, mate.mjob, nil)
        say(player, string.format('%s uses its %s job rules again. Call it again to apply (Apply now).', mate.name, jobName))
        return
    end

    local set = store.byNum[tonumber(choice) or -1]
    if set == nil then
        say(player, 'There is no usable Rule Set with that number. Use !squad ruleset to list them.')
        return
    end

    if R.JOB_IDS[set.job] ~= mate.mjob then
        say(player, string.format('Rule Set %d is for %s, but %s is a %s. Change its job first, or pick a %s set.',
            set.num, set.job, mate.name, jobName, jobName))
        return
    end

    R.select(player, mate.id, mate.mjob, set)
    say(player, string.format('%s (%s) now follows Rule Set %d, %s [%s]. Call it again to apply (Apply now).',
        mate.name, jobName, set.num, set.name, set.id))
end

return R
