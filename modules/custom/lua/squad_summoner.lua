-----------------------------------
-- Squad Summoners, the full job (2026-11-24, Hurami: "yes go ahead"); F13 player-like Summoner (2026-11-25)
--
-- Used by squad.lua (petTick in a fight, the idle tick, restTick), squad_logic.lua (party chat) and gambits_squad.lua
-- (the Gambits Summoner section). Everything is pcall'd by the callers: a fault here never stops a mate.
--
-- What a squad Summoner pays, like a player Summoner on this server (F13):
--   * summoning: the summon spell's MP (Carbuncle 5, the elementals 7, Fenrir 15), charged when the summon succeeds;
--     eligibility (level, pact, a zone that allows pets, not resting) and the cost are checked BEFORE an avatar is
--     released for a switch. Still instant (no 5 s cast, cannot be interrupted): the one difference left.
--   * keeping it out: perpetuation, charged by the map server every regen tick by the player's own rule
--     (status_effect_container.cpp + utils/avatar_perpetuation.h; xi_map marker SquadSmnEngine), with the mate's own
--     gear and Refresh; at 0 MP the avatar leaves, as a player's does.
--   * Blood Pacts: the player's check (xi.job_utils.summoner.canUseBloodPact: the avatar not asleep or stunned, MP >= the
--     pact's base cost) and the player's deduction (onUseBloodPact, Blood Boon included). The recast (the ability's 60 s
--     minus BP Delay / BP Delay II gear, at most 30 s) starts only when the pact really went off (S.onPactDone, from an
--     override of onUseBloodPact). A pact that did not go (not queued, out of range, the avatar busy) costs no MP and is
--     tried again after 5, 10, 15 s. Left out: merits (a mate has none) and Avatar's Favor's recast cut.
--   * resting: the avatar is released before the mate sits down, and none is called while it rests.
--   * the avatar's own monster TP moves are off (petutils.cpp; also setMobAbilityEnabled(false) here for an older
--     xi_map): only the mate's Blood Pacts, as with a player's avatar. Its melee is unchanged.
--
-- What you decide per mate (Gambits, Summoner section; char vars on you):
--   SQUAD_AVATAR_<mate>   avatar: 0 Auto (weakness), 1-8 that avatar, 9 Keep the current one (never switches by itself)
--   SQUAD_SMN_<mate>      settings (S.packSettings): normal attacks, Rage and Ward mode, between pulls, support out of
--                         combat, whether pact rules may switch the avatar
--   SQUAD_SMNR_<mate>_<n> pact rules 1-8 in order (S.encodeRule): "use PACT on TARGET when COND, in combat / out of
--                         combat / both", optionally protected (its MP is kept for it)
-- One intent per mate at a time (switch to the avatar a pact needs -> wait for the Blood Pact timer -> use it), with
-- clear cancellation (its condition is gone, 30 s, the avatar cannot be called or paid for, you order something, it
-- rests). Rules choose in order; the job's built-in wards / Rage only run for a kind of pact the mate has NO rules for,
-- so default and custom logic never decide the same thing at once. A mate without settings or rules behaves as before,
-- with the costs above.
-- Manual orders (party chat "Ayame Garuda" / "release" / "auto", !squad avatar) stay: an order wins for
-- S.MANUAL_SECONDS (rules that need another avatar wait, Auto does not switch); "release" keeps the avatar away for
-- S.RELEASE_SECONDS; "auto" goes back to Auto with a hold, so the order is not undone at once.
-- Several SMN mates: a Ward buff is reserved on you (the group) by the one mate on its way to it.
-----------------------------------
local S = {}

S.AVATARS = { 'CARBUNCLE', 'IFRIT', 'TITAN', 'LEVIATHAN', 'GARUDA', 'SHIVA', 'RAMUH', 'FENRIR' }
S.KEEP    = 9 -- SQUAD_AVATAR value: keep the current avatar
S.LEVEL   = { CARBUNCLE = 1, IFRIT = 10, TITAN = 10, LEVIATHAN = 10, GARUDA = 10, SHIVA = 10, RAMUH = 10, FENRIR = 60 }
S.ELEMENT = { CARBUNCLE = 'LIGHT', IFRIT = 'FIRE', TITAN = 'EARTH', LEVIATHAN = 'WATER', GARUDA = 'WIND', SHIVA = 'ICE',
              RAMUH = 'THUNDER', FENRIR = 'DARK' }
S.ASTRAL  = { CARBUNCLE = 'SEARING_LIGHT', IFRIT = 'INFERNO', TITAN = 'EARTHEN_FURY', LEVIATHAN = 'TIDAL_WAVE',
              GARUDA = 'AERIAL_BLAST', SHIVA = 'DIAMOND_DUST', RAMUH = 'JUDGMENT_BOLT', FENRIR = 'HOWLING_MOON' }
-- the summon spell's MP (spell_list.sql) when GetSpell cannot be read
S.SUMMON_MP = { CARBUNCLE = 5, IFRIT = 7, TITAN = 7, LEVIATHAN = 7, GARUDA = 7, SHIVA = 7, RAMUH = 7, FENRIR = 15 }

S.WARD_SECONDS    = 60  -- the base Blood Pact recast when the ability cannot be read
S.SWAP_SECONDS    = 45  -- no automatic switch within this long of the last one (Auto, rules)
S.RELEASE_SECONDS = 60
S.MANUAL_SECONDS  = 300
S.AF_SECONDS      = 7200
S.PENDING_SECONDS = 6   -- a dispatched pact that has not gone off in this long did not go
S.RETRY_STEP      = 5   -- retry after 5, 10, 15 s
S.RETRY_MAX       = 15
S.INTENT_SECONDS  = 30
S.IDLE_RELEASE    = 8   -- seconds out of combat before "release between pulls"
S.TICK_SECONDS    = 3   -- the regen tick (upkeep planning)
S.MAX_RULES       = 8

-- Every pact the mate can be told to use, in a FIXED order (rules store the position: append only, never reorder).
-- { avatar, kind (rage | ward | astral), level, aim (enemy | single | party), effect = the status it gives or takes }
S.PACT_LIST =
{
    'POISON_NAILS', 'METEORITE', 'HEALING_RUBY', 'HEALING_RUBY_II', 'SHINING_RUBY', 'GLITTERING_RUBY', 'SEARING_LIGHT',
    'PUNCH', 'BURNING_STRIKE', 'DOUBLE_PUNCH', 'FLAMING_CRUSH', 'CRIMSON_HOWL', 'INFERNO',
    'ROCK_THROW', 'ROCK_BUSTER', 'MEGALITH_THROW', 'MOUNTAIN_BUSTER', 'EARTHEN_WARD', 'EARTHEN_FURY',
    'BARRACUDA_DIVE', 'TAIL_WHIP', 'SPINNING_DIVE', 'SPRING_WATER', 'SLOWGA', 'TIDAL_WAVE',
    'CLAW', 'PREDATOR_CLAWS', 'WHISPERING_WIND', 'HASTEGA', 'AERIAL_ARMOR', 'AERIAL_BLAST',
    'AXE_KICK', 'DOUBLE_SLAP', 'RUSH', 'FROST_ARMOR', 'DIAMOND_DUST',
    'SHOCK_STRIKE', 'THUNDERSPARK', 'CHAOTIC_STRIKE', 'ROLLING_THUNDER', 'LIGHTNING_ARMOR', 'JUDGMENT_BOLT',
    'MOONLIT_CHARGE', 'CRESCENT_FANG', 'ECLIPSE_BITE', 'LUNAR_CRY', 'ECLIPTIC_HOWL', 'ECLIPTIC_GROWL', 'HOWLING_MOON',
}

S.PACTS =
{
    POISON_NAILS    = { 'CARBUNCLE', 'rage', 5, 'enemy' },
    METEORITE       = { 'CARBUNCLE', 'rage', 55, 'enemy' },
    HEALING_RUBY    = { 'CARBUNCLE', 'ward', 1, 'single' },
    HEALING_RUBY_II = { 'CARBUNCLE', 'ward', 65, 'party' },
    SHINING_RUBY    = { 'CARBUNCLE', 'ward', 24, 'party', effect = 'SHINING_RUBY' },
    GLITTERING_RUBY = { 'CARBUNCLE', 'ward', 44, 'party' },
    SEARING_LIGHT   = { 'CARBUNCLE', 'astral', 1, 'enemy' },
    PUNCH           = { 'IFRIT', 'rage', 1, 'enemy' },
    BURNING_STRIKE  = { 'IFRIT', 'rage', 23, 'enemy' },
    DOUBLE_PUNCH    = { 'IFRIT', 'rage', 30, 'enemy' },
    FLAMING_CRUSH   = { 'IFRIT', 'rage', 70, 'enemy' },
    CRIMSON_HOWL    = { 'IFRIT', 'ward', 38, 'party', effect = 'WARCRY' },
    INFERNO         = { 'IFRIT', 'astral', 1, 'enemy' },
    ROCK_THROW      = { 'TITAN', 'rage', 1, 'enemy' },
    ROCK_BUSTER     = { 'TITAN', 'rage', 21, 'enemy' },
    MEGALITH_THROW  = { 'TITAN', 'rage', 35, 'enemy' },
    MOUNTAIN_BUSTER = { 'TITAN', 'rage', 70, 'enemy' },
    EARTHEN_WARD    = { 'TITAN', 'ward', 46, 'party', effect = 'STONESKIN' },
    EARTHEN_FURY    = { 'TITAN', 'astral', 1, 'enemy' },
    BARRACUDA_DIVE  = { 'LEVIATHAN', 'rage', 1, 'enemy' },
    TAIL_WHIP       = { 'LEVIATHAN', 'rage', 26, 'enemy' },
    SPINNING_DIVE   = { 'LEVIATHAN', 'rage', 70, 'enemy' },
    SPRING_WATER    = { 'LEVIATHAN', 'ward', 47, 'party' },
    SLOWGA          = { 'LEVIATHAN', 'ward', 33, 'enemy', effect = 'SLOW' },
    TIDAL_WAVE      = { 'LEVIATHAN', 'astral', 1, 'enemy' },
    CLAW            = { 'GARUDA', 'rage', 1, 'enemy' },
    PREDATOR_CLAWS  = { 'GARUDA', 'rage', 70, 'enemy' },
    WHISPERING_WIND = { 'GARUDA', 'ward', 36, 'party' },
    HASTEGA         = { 'GARUDA', 'ward', 48, 'party', effect = 'HASTE' },
    AERIAL_ARMOR    = { 'GARUDA', 'ward', 25, 'party', effect = 'BLINK' },
    AERIAL_BLAST    = { 'GARUDA', 'astral', 1, 'enemy' },
    AXE_KICK        = { 'SHIVA', 'rage', 1, 'enemy' },
    DOUBLE_SLAP     = { 'SHIVA', 'rage', 50, 'enemy' },
    RUSH            = { 'SHIVA', 'rage', 70, 'enemy' },
    FROST_ARMOR     = { 'SHIVA', 'ward', 28, 'party', effect = 'ICE_SPIKES' },
    DIAMOND_DUST    = { 'SHIVA', 'astral', 1, 'enemy' },
    SHOCK_STRIKE    = { 'RAMUH', 'rage', 1, 'enemy' },
    THUNDERSPARK    = { 'RAMUH', 'rage', 19, 'enemy' },
    CHAOTIC_STRIKE  = { 'RAMUH', 'rage', 70, 'enemy' },
    ROLLING_THUNDER = { 'RAMUH', 'ward', 31, 'party', effect = 'ENTHUNDER' },
    LIGHTNING_ARMOR = { 'RAMUH', 'ward', 42, 'party', effect = 'SHOCK_SPIKES' },
    JUDGMENT_BOLT   = { 'RAMUH', 'astral', 1, 'enemy' },
    MOONLIT_CHARGE  = { 'FENRIR', 'rage', 5, 'enemy' },
    CRESCENT_FANG   = { 'FENRIR', 'rage', 10, 'enemy' },
    ECLIPSE_BITE    = { 'FENRIR', 'rage', 65, 'enemy' },
    LUNAR_CRY       = { 'FENRIR', 'ward', 21, 'enemy', effect = 'ACCURACY_DOWN' },
    ECLIPTIC_HOWL   = { 'FENRIR', 'ward', 54, 'party', effect = 'ACCURACY_BOOST' },
    ECLIPTIC_GROWL  = { 'FENRIR', 'ward', 43, 'party' },
    HOWLING_MOON    = { 'FENRIR', 'astral', 1, 'enemy' },
}

-- (r4) how far from its target the avatar may be when a pact goes off: pet_skills.sql pet_skill_distance (the server
-- adds both hitboxes). Not listed: 3 for a pact on the enemy, 20 for a ward on the party.
S.REACH =
{
    METEORITE = 5, ROCK_THROW = 12, MEGALITH_THROW = 12, SLOWGA = 5, THUNDERSPARK = 5, LUNAR_CRY = 12,
    SEARING_LIGHT = 5, INFERNO = 5, EARTHEN_FURY = 5, TIDAL_WAVE = 5, AERIAL_BLAST = 5, DIAMOND_DUST = 5,
    JUDGMENT_BOLT = 5, HOWLING_MOON = 5,
}

function S.pactReach(name)
    local entry = S.PACTS[name]
    return S.REACH[name] or ((entry and entry[4] == 'enemy') and 3 or 20)
end

-- (r4) the avatar's states a pact can start from (lua getCurrentAction): 16 = nothing (idle or just summoned),
-- 1 = attacking, 0 = none. Anything else (another pact on its way 13 / 4 / 11, a spell...) = busy.
S.READY_ACTIONS = { [0] = true, [1] = true, [16] = true }
S.REACH_MARGIN  = 1 -- yalms on top of the reach: the server's range also counts both hitboxes

-- (r4) can the avatar take this pact now? false + why while it must wait (busy, or too far from the target): the pact
-- is then not sent, so it neither counts as an attempt nor as "did not go off"
function S.avatarReady(pet, name, aim)
    local okA, action = pcall(function() return pet:getCurrentAction() end)
    if okA and not S.READY_ACTIONS[action] then
        return false, 'busy'
    end

    if aim ~= nil and aim:getID() ~= pet:getID() then
        local okD, dist = pcall(function() return pet:checkDistance(aim) end)
        if okD and dist ~= nil and dist > S.pactReach(name) + S.REACH_MARGIN then
            return false, string.format('too far (%.1f yalms)', dist)
        end
    end

    return true
end

-- the job's built-in wards (used when the mate has NO Ward rules), in their old order and kinds: healall (2+ under 60%
-- or one under 40%), heal1 (one member under 50%), debuff (the target lacks it), buff (you lack it), timed (every
-- `every` seconds in a fight). idle = also out of combat (with "support out of combat" on).
S.WARDS =
{
    CARBUNCLE = { { 'HEALING_RUBY_II', 'healall' }, { 'HEALING_RUBY', 'heal1' }, { 'SHINING_RUBY', 'buff', idle = true },
                  { 'GLITTERING_RUBY', 'timed', every = 300 } },
    IFRIT     = { { 'CRIMSON_HOWL', 'buff' } },
    TITAN     = { { 'EARTHEN_WARD', 'buff' } },
    LEVIATHAN = { { 'SPRING_WATER', 'healall' }, { 'SLOWGA', 'debuff' } },
    GARUDA    = { { 'WHISPERING_WIND', 'healall' }, { 'HASTEGA', 'buff', idle = true }, { 'AERIAL_ARMOR', 'buff' } },
    SHIVA     = { { 'FROST_ARMOR', 'buff' } },
    RAMUH     = { { 'ROLLING_THUNDER', 'buff' }, { 'LIGHTNING_ARMOR', 'buff' } },
    FENRIR    = { { 'LUNAR_CRY', 'debuff' }, { 'ECLIPTIC_HOWL', 'buff' }, { 'ECLIPTIC_GROWL', 'timed', every = 300 } },
}

-- rule fields: wire names, stored as their position - 1
S.TARGETS = { 'SELF', 'MASTER', 'PARTY', 'ENEMY' }
S.CONDS   = { 'ALWAYS', 'NOT_STATUS', 'STATUS', 'HPP_LT', 'HPP_GTE', 'MY_MPP_GTE', 'MY_MPP_LT' }
S.WHENS   = { 'COMBAT', 'IDLE', 'ANY' }
S.MODES   = { 'AUTO', 'OFF', 'RULES' }            -- Rage / Ward mode 0..2
S.BETWEEN = { 'KEEP', 'RELEASE', 'RELEASE_LOW_MP' } -- 0..2

S.state = S.state or {} -- per mate entity id: { intent, sent, attempts } (lost on a reload: harmless)

-- ---------------------------------------------------------------- small helpers
local function petIdOf(name)
    return name and xi.petId and xi.petId[name] or nil
end

local function abilityId(name)
    return name and xi.jobAbility and xi.jobAbility[name] or nil
end

local function effectId(name)
    return name and xi.effect and xi.effect[name] or nil
end

local function pretty(name)
    local text = tostring(name or '?')
    text = text:sub(1, 1) .. text:sub(2):lower()
    return (text:gsub('_(%a)', function(c) return ' ' .. c:upper() end))
end
S.pretty = pretty

local function nowSecs()
    return GetSystemTime and GetSystemTime() or os.time()
end

local function stateOf(mob)
    local id = mob:getID()
    local st = S.state[id]
    if st == nil then
        st = {}
        S.state[id] = st
    end

    return st
end

function S.nameOfPet(petId)
    for _, name in ipairs(S.AVATARS) do
        if petIdOf(name) == petId then
            return name
        end
    end

    return nil
end

function S.indexOf(word)
    word = string.upper(tostring(word or ''))
    for i, name in ipairs(S.AVATARS) do
        if name == word then
            return i
        end
    end

    return nil
end

function S.pactIndex(name)
    for i, n in ipairs(S.PACT_LIST) do
        if n == name then
            return i
        end
    end

    return nil
end

local function bits(v, shift, count)
    local n = math.floor(v / 2 ^ shift) % 2 ^ count
    return math.tointeger and math.tointeger(n) or n -- (a whole number on Lua 5.4 too: "70", not "70.0", on the wire)
end

local function positionOf(list, value)
    for i, v in ipairs(list) do
        if v == value then
            return i
        end
    end

    return nil
end

-- ---------------------------------------------------------------- settings (SQUAD_SMN_<mate>)
-- bit 0 stored; bit 1 normal attacks OFF; bits 2-3 Rage mode; bits 4-5 Ward mode; bits 6-7 between pulls; bit 8 support
-- out of combat; bit 9 rules may NOT switch the avatar. 0 (no var) = the defaults, the behaviour before F13.
function S.settingsVar(mateId)
    return 'SQUAD_SMN_' .. tostring(mateId)
end

function S.choiceVar(mateId)
    return 'SQUAD_AVATAR_' .. tostring(mateId)
end

function S.ruleVar(mateId, n)
    return string.format('SQUAD_SMNR_%d_%d', tonumber(mateId) or 0, n)
end

function S.packSettings(t)
    local rage, ward, between = tonumber(t.rage) or 0, tonumber(t.ward) or 0, tonumber(t.between) or 0
    for _, v in ipairs({ rage, ward, between }) do
        if v ~= math.floor(v) or v < 0 or v > 2 then
            return nil, 'Rage, Ward and between pulls take 0-2'
        end
    end

    return 1 + (t.engage == false and 2 or 0) + rage * 4 + ward * 16 + between * 64 + (t.idle and 256 or 0)
        + (t.ruleSwitch == false and 512 or 0)
end

function S.unpackSettings(v)
    v = tonumber(v) or 0
    if v <= 0 or v % 2 == 0 then
        return { engage = true, rage = 0, ward = 0, between = 0, idle = false, ruleSwitch = true, stored = false }
    end

    return { engage = bits(v, 1, 1) == 0, rage = math.min(2, bits(v, 2, 2)), ward = math.min(2, bits(v, 4, 2)),
             between = math.min(2, bits(v, 6, 2)), idle = bits(v, 8, 1) == 1, ruleSwitch = bits(v, 9, 1) == 0, stored = true }
end

function S.getSettings(master, mateId)
    return S.unpackSettings(master and master:getCharVar(S.settingsVar(mateId)) or 0)
end

function S.setSettings(master, mateId, t)
    local v, why = S.packSettings(t)
    if v == nil then
        return false, why
    end

    master:setCharVar(S.settingsVar(mateId), v)
    return true
end

-- ---------------------------------------------------------------- pact rules (SQUAD_SMNR_<mate>_<n>)
-- bit 0 on; bits 1-7 the pact (its position in S.PACT_LIST); bits 8-9 target; bits 10-13 condition; bits 14-24 the
-- argument (an effect id, or a percentage); bits 25-26 when; bit 27 protect. 0 = no rule.
function S.encodeRule(r)
    if type(r) ~= 'table' then
        return nil, 'not a rule'
    end

    local pact = S.pactIndex(r.pact or '')
    local target = positionOf(S.TARGETS, r.target)
    local cond = positionOf(S.CONDS, r.cond)
    local when = positionOf(S.WHENS, r.when or 'COMBAT')
    if pact == nil then
        return nil, 'unknown pact ' .. tostring(r.pact)
    elseif target == nil then
        return nil, 'unknown target ' .. tostring(r.target)
    elseif cond == nil then
        return nil, 'unknown condition ' .. tostring(r.cond)
    elseif when == nil then
        return nil, 'unknown time ' .. tostring(r.when)
    end

    local entry = S.PACTS[r.pact]
    if (entry[2] == 'rage' or entry[2] == 'astral' or entry[4] == 'enemy') and r.target ~= 'ENEMY' then
        return nil, 'that pact goes on the enemy: use the target Enemy (a condition on the mate\'s own MP is fine)'
    elseif entry[4] ~= 'enemy' and r.target == 'ENEMY' then
        return nil, 'that pact helps the party: use Itself, You or A party member'
    end

    if entry[2] == 'rage' and r.when ~= nil and r.when ~= 'COMBAT' then
        return nil, 'a Rage pact is for a fight: use In combat'
    end

    local arg = 0
    if r.cond == 'NOT_STATUS' or r.cond == 'STATUS' then
        arg = type(r.arg) == 'number' and r.arg or effectId(r.arg)
        if arg == nil then
            return nil, 'unknown status effect ' .. tostring(r.arg)
        end
    elseif r.cond ~= 'ALWAYS' then
        arg = tonumber(r.arg)
        if arg == nil or arg ~= math.floor(arg) or arg < 0 or arg > 100 then
            return nil, r.cond .. ' needs a percentage 0-100'
        end
    end

    if arg < 0 or arg > 2047 or arg ~= math.floor(arg) then
        return nil, 'the value is out of range'
    end

    return (r.on == false and 0 or 1) + pact * 2 + (target - 1) * 256 + (cond - 1) * 1024 + arg * 16384
        + (when - 1) * 33554432 + (r.protect and 134217728 or 0)
end

local function effectName(id)
    for name, v in pairs(xi.effect or {}) do
        if v == id then
            return name
        end
    end

    return id
end

function S.decodeRule(v)
    v = tonumber(v) or 0
    local pact = v > 0 and S.PACT_LIST[bits(v, 1, 7)] or nil
    if pact == nil then
        return nil
    end

    local cond = S.CONDS[bits(v, 10, 4) + 1] or 'ALWAYS'
    local arg = bits(v, 14, 11)
    return { on = bits(v, 0, 1) == 1, pact = pact, target = S.TARGETS[bits(v, 8, 2) + 1] or 'SELF', cond = cond,
             arg = (cond == 'NOT_STATUS' or cond == 'STATUS') and effectName(arg) or arg, argId = arg,
             when = S.WHENS[bits(v, 25, 2) + 1] or 'COMBAT', protect = bits(v, 27, 1) == 1 }
end

function S.getRules(master, mateId)
    local out = {}
    for n = 1, S.MAX_RULES do
        local r = S.decodeRule(master:getCharVar(S.ruleVar(mateId, n)))
        if r == nil then
            break
        end

        out[#out + 1] = r
    end

    return out
end

local function writeRules(master, mateId, list)
    for n = 1, S.MAX_RULES do
        master:setCharVar(S.ruleVar(mateId, n), list[n] and (S.encodeRule(list[n]) or 0) or 0)
    end
end

-- set rule n (1 .. count + 1). true, or false + why
function S.setRule(master, mateId, n, rule)
    local list = S.getRules(master, mateId)
    if type(n) ~= 'number' or n < 1 or n > #list + 1 or n > S.MAX_RULES then
        return false, string.format('rule number 1-%d', math.min(#list + 1, S.MAX_RULES))
    end

    local v, why = S.encodeRule(rule)
    if v == nil then
        return false, why
    end

    list[n] = S.decodeRule(v)
    writeRules(master, mateId, list)
    return true
end

function S.deleteRule(master, mateId, n)
    local list = S.getRules(master, mateId)
    if list[n] == nil then
        return false, 'no rule ' .. tostring(n)
    end

    table.remove(list, n)
    writeRules(master, mateId, list)
    return true
end

-- settings and the whole rule list at once (a starter): everything is checked first, and only when ALL of it is valid
-- is anything written. true, or false + why (then nothing changed)
function S.replaceAll(master, mateId, settings, rules)
    local sv, why = S.packSettings(settings or {})
    if sv == nil then
        return false, 'settings: ' .. tostring(why)
    end

    if type(rules) ~= 'table' or #rules > S.MAX_RULES then
        return false, string.format('at most %d pact rules', S.MAX_RULES)
    end

    local values = {}
    for i, r in ipairs(rules) do
        local v, whyR = S.encodeRule(r)
        if v == nil then
            return false, string.format('rule %d: %s', i, tostring(whyR))
        end

        values[i] = v
    end

    master:setCharVar(S.settingsVar(mateId), sv)
    for n = 1, S.MAX_RULES do
        master:setCharVar(S.ruleVar(mateId, n), values[n] or 0)
    end

    return true
end

-- move rule n one place up (dir -1) or down (dir 1)
function S.moveRule(master, mateId, n, dir)
    local list = S.getRules(master, mateId)
    local m = n + dir
    if list[n] == nil or list[m] == nil then
        return false, 'cannot move that rule'
    end

    list[n], list[m] = list[m], list[n]
    writeRules(master, mateId, list)
    return true
end

-- ---------------------------------------------------------------- eligibility and costs
-- can this summoner call `name`? has(name) = you have the pact (nil = every avatar its level allows)
function S.allowed(name, level, has)
    if not S.LEVEL[name] or level < S.LEVEL[name] or not petIdOf(name) then
        return false, string.format('%s needs level %d', pretty(name), S.LEVEL[name] or 99)
    end

    if has ~= nil and name ~= 'CARBUNCLE' and not has(name) then
        return false, string.format('you have no pact with %s yet (win its trial fight)', pretty(name))
    end

    return true
end

-- the summon spell's MP (a player's cost: spell_list.sql, through GetSpell)
function S.summonCost(name)
    local sid = xi.magic and xi.magic.spell and xi.magic.spell[name]
    if sid and type(GetSpell) == 'function' then
        local ok, cost = pcall(function() return GetSpell(sid):getMPCost() end)
        if ok and type(cost) == 'number' then
            return cost
        end
    end

    return S.SUMMON_MP[name] or 7
end

-- the pact's base MP: the same number canUseBloodPact checks (job_utils/summoner.lua getBaseMPCost)
function S.pactCost(mob, name)
    local id = abilityId(name)
    local f = xi.job_utils and xi.job_utils.summoner and xi.job_utils.summoner.getBaseMPCost
    if id and type(f) == 'function' and type(GetAbility) == 'function' then
        local ok, cost = pcall(function() return f(mob, GetAbility(id)) end)
        if ok and type(cost) == 'number' then
            return cost
        end
    end

    return 9999
end

-- the MP one regen tick costs with `name` out (perpetuation - the mate's reduction - Refresh), for planning only: the
-- map server charges the real amount
function S.netUpkeep(mob, name)
    local f = xi.job_utils and xi.job_utils.summoner and xi.job_utils.summoner.getPerpetuationCost
    local perp = 0
    if type(f) == 'function' and petIdOf(name) then
        local lvl = mob:getMainLvl()
        local ok, v = pcall(f, { getPetID = function() return petIdOf(name) end, getMainLvl = function() return lvl end })
        perp = ok and tonumber(v) or 0
        perp = math.max(1, perp - (mob:getMod(xi.mod.PERPETUATION_REDUCTION) or 0))
    end

    return perp - math.max(0, mob:getMod(xi.mod.REFRESH) or 0)
end

-- the recast of a pact that went off: the ability's recast minus BP Delay (at most 15) and BP Delay II (at most 15),
-- 30 at most in all (char_entity.cpp's rule; a mate has no merits and no Avatar's Favor)
function S.recastOf(mob, id)
    local recast = S.WARD_SECONDS
    if type(GetAbility) == 'function' then
        local ok, v = pcall(function() return GetAbility(id):getRecast() end)
        if ok and type(v) == 'number' and v > 0 then
            recast = v
        end
    end

    local d1 = math.min(15, math.max(0, xi.mod.BP_DELAY and mob:getMod(xi.mod.BP_DELAY) or 0))
    local d2 = math.min(15, math.max(0, xi.mod.BP_DELAY_II and mob:getMod(xi.mod.BP_DELAY_II) or 0))
    return math.max(0, recast - math.min(30, d1 + d2))
end

local function timerVar(kind)
    return kind == 'rage' and 'SQUAD_BP_NEXT' or 'SQUAD_WARD_NEXT'
end

local function resting(mob)
    return xi.animation ~= nil and mob:getAnimation() == xi.animation.HEALING
end

local function petsAllowed(mob)
    local ok, yes = pcall(function() return mob:canUseMisc(xi.zoneMisc.PET) end)
    return not ok or yes ~= false
end

local function currentAvatar(mob)
    local ok, pet = pcall(function() return mob:getPet() end)
    if ok and pet ~= nil and pet:isAlive() then
        return S.nameOfPet(pet:getPetID()), pet
    end

    return nil, nil
end

local function log(mob, text)
    print(string.format('[smn] %s (MP %d/%d): %s', mob:getPacketName(), mob:getMP(), mob:getMaxMP(), text))
end

local function sharedTimer()
    return xi.settings and xi.settings.map and xi.settings.map.BLOOD_PACT_SHARED_TIMER == true
end

-- ---------------------------------------------------------------- summon, release, switch
-- a paid summon of `name` (no avatar out). true, or false + why. The MP is charged only when it worked.
function S.summon(mob, name, now, has, reserve)
    if SquadHasPet(mob) then
        return false, 'an avatar is out'
    end

    local ok, why = S.allowed(name, mob:getMainLvl(), has)
    if not ok then
        return false, why
    elseif resting(mob) then
        return false, 'resting'
    elseif not petsAllowed(mob) then
        return false, 'pets cannot be called here'
    end

    local cost = S.summonCost(name)
    if mob:getMP() < cost + (reserve or 0) then
        return false, string.format('not enough MP to call %s (%d)', pretty(name), cost)
    end

    if not SquadSpawnPet(mob, petIdOf(name)) then
        return false, 'the summon did not work'
    end

    mob:delMP(cost)
    mob:setLocalVar('SMN_LAST_PET', petIdOf(name))
    mob:setLocalVar('SQUAD_PET_PICK', petIdOf(name))
    local _, pet = currentAvatar(mob)
    if pet then
        pcall(function() pet:setMobAbilityEnabled(false) end) -- (no monster TP moves; the map server turns them off too)
        -- (r2 diagnostics, DEV 2026-11-26: pacts did not go off) which step a pact reaches: the avatar's PetSkill call,
        -- then its skill state. Log lines only; nothing else depends on them.
        local who = mob:getPacketName()
        pcall(function()
            pet:addListener('WEAPONSKILL_BEFORE_USE', 'SMN_DIAG_USE', function(p, skillId)
                print(string.format('[smn] %s: the avatar starts skill %s', who, tostring(skillId)))
            end)
            pet:addListener('WEAPONSKILL_STATE_ENTER', 'SMN_DIAG_STATE', function(p, skillId)
                print(string.format('[smn] %s: the avatar is in skill %s', who, tostring(skillId)))
            end)
        end)
    end

    log(mob, string.format('summoned %s for %d MP', pretty(name), cost))
    return true
end

-- release the avatar (no cost, no refund)
function S.release(mob, why)
    local name = currentAvatar(mob)
    if name then
        pcall(function() mob:despawnPet() end)
        log(mob, 'released ' .. pretty(name) .. (why and (' (' .. why .. ')') or ''))
    end

    return name ~= nil
end

-- switch to `name`: nothing when it is already out; eligibility and the cost (+ extra) are checked BEFORE the current
-- one leaves
function S.switchTo(mob, name, now, has, why, extra)
    local current = currentAvatar(mob)
    if current == name then
        return true, 'already out'
    end

    local ok, reason = S.allowed(name, mob:getMainLvl(), has)
    if not ok then
        return false, reason
    elseif resting(mob) then
        return false, 'resting'
    elseif not petsAllowed(mob) then
        return false, 'pets cannot be called here'
    end

    local cost = S.summonCost(name)
    if mob:getMP() < cost + (extra or 0) then
        return false, string.format('not enough MP to call %s and use it', pretty(name))
    end

    if current then
        S.release(mob, why or ('for ' .. pretty(name)))
    end

    mob:setLocalVar('SQUAD_PET_NEXT', 0)
    mob:setLocalVar('SMN_SWAP_NEXT', now + S.SWAP_SECONDS)
    return S.summon(mob, name, now, has, 0)
end

-- ---------------------------------------------------------------- the group's ward reservations (on you)
local function reserveKey(entry, id)
    return effectId(entry.effect) or (1000 + (id or 0))
end

function S.reserved(master, key, mateId, now)
    local by = master:getLocalVar('SMN_RSV_' .. key)
    return by ~= 0 and by ~= mateId and master:getLocalVar('SMN_RSVT_' .. key) > now
end

function S.reserve(master, key, mateId, now, secs)
    if S.reserved(master, key, mateId, now) then
        return false
    end

    master:setLocalVar('SMN_RSV_' .. key, mateId)
    master:setLocalVar('SMN_RSVT_' .. key, now + (secs or S.INTENT_SECONDS))
    return true
end

function S.unreserve(master, key, mateId)
    if master and key and master:getLocalVar('SMN_RSV_' .. key) == mateId then
        master:setLocalVar('SMN_RSV_' .. key, 0)
        master:setLocalVar('SMN_RSVT_' .. key, 0)
    end
end

-- ---------------------------------------------------------------- targets and conditions
local function members(master)
    local out = {}
    local ok, list = pcall(function() return master:getPartyWithTrusts() end)
    for _, m in pairs(ok and list or {}) do
        if m ~= nil and m:isAlive() then
            out[#out + 1] = m
        end
    end

    return out
end

local function hasEffectId(entity, id)
    return id ~= nil and id ~= 0 and entity:hasStatusEffect(id)
end

-- does `who` meet the rule's condition? (MY_MPP_* read the mate itself)
function S.condTrue(rule, who, mob)
    local c, a = rule.cond, tonumber(rule.argId) or 0
    if c == 'ALWAYS' then
        return true
    elseif c == 'NOT_STATUS' then
        return not hasEffectId(who, a)
    elseif c == 'STATUS' then
        return hasEffectId(who, a)
    elseif c == 'HPP_LT' then
        return who:getHPP() < a
    elseif c == 'HPP_GTE' then
        return who:getHPP() >= a
    elseif c == 'MY_MPP_GTE' then
        return mob:getMaxMP() > 0 and mob:getMP() * 100 >= a * mob:getMaxMP()
    elseif c == 'MY_MPP_LT' then
        return mob:getMaxMP() > 0 and mob:getMP() * 100 < a * mob:getMaxMP()
    end

    return false
end

-- the entity a rule acts on now (nil = its condition is not met)
function S.ruleAim(rule, mob, master, target)
    if rule.target == 'ENEMY' then
        if target ~= nil and target:isAlive() and target:isMob() and S.condTrue(rule, target, mob) then
            return target
        end

        return nil
    elseif rule.target == 'SELF' then
        return S.condTrue(rule, mob, mob) and mob or nil
    elseif rule.target == 'MASTER' then
        return master:isAlive() and S.condTrue(rule, master, mob) and master or nil
    end

    -- PARTY: a member near the mate that meets it (the lowest HP one for an HP condition)
    local best = nil
    for _, m in ipairs(members(master)) do
        if mob:checkDistance(m) <= 20 and S.condTrue(rule, m, mob) then
            if best == nil or (rule.cond == 'HPP_LT' and m:getHPP() < best:getHPP()) then
                best = m
            end
        end
    end

    return best
end

-- ---------------------------------------------------------------- dispatch and confirmation
-- ask the avatar for the pact (the player's check first). The recast starts only when it went off (S.onPactDone).
local function dispatch(mob, pet, name, aim, now, key)
    local id = abilityId(name)
    local entry = S.PACTS[name]
    if id == nil or entry == nil or type(GetAbility) ~= 'function' or aim == nil then
        return false, 'unknown pact'
    end

    local check = xi.job_utils and xi.job_utils.summoner and xi.job_utils.summoner.canUseBloodPact
    local okC, code = pcall(function() return type(check) == 'function' and check(mob, pet, aim, GetAbility(id)) or 0 end)
    if not okC or code ~= 0 then
        return false, 'cannot use it now'
    end

    -- (r4) wait for the avatar: not while it is busy, and a pact on the enemy only once the avatar is in its reach (an
    -- avatar too far away makes the pact go off on nobody). A Rage pact sends the avatar in, as a player's does.
    local st0 = stateOf(mob)
    local ready, why = S.avatarReady(pet, name, aim)
    if not ready then
        if entry[4] == 'enemy' and why ~= 'busy' and aim:isMob() and type(SquadPetAttack) == 'function' then
            SquadPetAttack(mob, aim)
        end

        if st0.waitNote ~= name .. why:sub(1, 4) then
            st0.waitNote = name .. why:sub(1, 4)
            log(mob, string.format('%s waits: the avatar is %s', pretty(name), why))
        end

        return false, 'waiting'
    end

    st0.waitNote = nil
    local okA, action = pcall(function() return pet:getCurrentAction() end)
    pet:usePetAbility(id, aim)
    local st = stateOf(mob)
    st.sent = { id = id, name = name, kind = entry[2], at = now, key = key, action = okA and action or '?' }
    if entry[2] ~= 'astral' then
        -- nothing else of this kind while it is on its way; the real recast is set when it went off
        mob:setLocalVar(timerVar(entry[2]), now + S.PENDING_SECONDS)
        if sharedTimer() then
            mob:setLocalVar(timerVar(entry[2] == 'rage' and 'ward' or 'rage'), now + S.PENDING_SECONDS)
        end
    end

    local okN, aimName = pcall(function() return aim:getName() end)
    log(mob, string.format('%s -> %s (avatar action %s)', pretty(name), okN and aimName or '?', tostring(st.sent.action)))
    return true
end

-- from the onUseBloodPact override (the primary target; the MP is charged): the pact went off
function S.onPactDone(summoner, petskillId, now)
    local name = nil
    for n in pairs(S.PACTS) do
        if abilityId(n) == petskillId then
            name = n
        end
    end

    local entry = name and S.PACTS[name]
    if entry == nil then
        return
    end

    now = now or nowSecs()
    if entry[2] ~= 'astral' then
        local recast = S.recastOf(summoner, petskillId)
        summoner:setLocalVar(timerVar(entry[2]), now + recast)
        if sharedTimer() then
            summoner:setLocalVar(timerVar(entry[2] == 'rage' and 'ward' or 'rage'), now + recast)
        end
    end

    local st = S.state[summoner:getID()]
    if st then
        if st.sent and st.sent.id == petskillId then
            S.unreserve(summoner:getMaster(), st.sent.key, summoner:getLocalVar('SQUAD_ID'))
            st.sent = nil
        end

        if st.intent and st.intent.name == name then
            st.intent = nil
        end

        st.attempts = 0
    end

    summoner:setLocalVar('SMN_PACTS', summoner:getLocalVar('SMN_PACTS') + 1)
    log(summoner, pretty(name) .. ' went off')
end

-- a dispatched pact that never went off: free its timer for a retry after 5, 10, 15 s (no MP was spent)
local function checkSent(mob, now, master)
    local st = stateOf(mob)
    if st.sent == nil or now < st.sent.at + S.PENDING_SECONDS then
        return
    end

    st.attempts = (st.attempts or 0) + 1
    local wait = math.min(S.RETRY_MAX, S.RETRY_STEP * st.attempts)
    if st.sent.kind ~= 'astral' then
        mob:setLocalVar(timerVar(st.sent.kind), now + wait)
        if sharedTimer() then
            mob:setLocalVar(timerVar(st.sent.kind == 'rage' and 'ward' or 'rage'), now + wait)
        end
    end

    S.unreserve(master, st.sent.key, mob:getLocalVar('SQUAD_ID'))
    log(mob, string.format('%s did not go off; again in %d s', pretty(st.sent.name), wait))
    st.sent = nil
    if st.attempts >= 3 then
        if st.intent then
            S.unreserve(master, st.intent.key, mob:getLocalVar('SQUAD_ID'))
        end

        st.intent = nil
        st.attempts = 0
    end
end

local function cancelIntent(mob, master, why)
    local st = stateOf(mob)
    if st.intent then
        S.unreserve(master, st.intent.key, mob:getLocalVar('SQUAD_ID'))
        log(mob, 'gave up ' .. pretty(st.intent.name) .. (why and (': ' .. why) or ''))
        st.intent = nil
    end
end

-- ---------------------------------------------------------------- built-in wards and Rage (no rules of that kind)
-- the built-in ward to use now, or nil: name, aim, entry
function S.chooseWard(mob, pet, master, target, level, name, now, idle)
    local list = S.WARDS[name or '']
    if not list then
        return nil
    end

    local lowest, low60, low40 = nil, 0, false
    for _, m in ipairs(members(master)) do
        local hpp = m:getHPP()
        if lowest == nil or hpp < lowest:getHPP() then
            lowest = m
        end
        if hpp < 60 then low60 = low60 + 1 end
        if hpp < 40 then low40 = true end
    end

    local fighting = target ~= nil and target:isAlive()
    local mateId = mob:getLocalVar('SQUAD_ID')
    for _, kind in ipairs({ 'healall', 'heal1', 'debuff', 'buff', 'timed' }) do
        for _, w in ipairs(list) do
            local pact = S.PACTS[w[1]]
            if w[2] == kind and pact and level >= pact[3] and abilityId(w[1]) and (not idle or w.idle)
                and mob:getMP() >= S.pactCost(mob, w[1]) then
                if kind == 'healall' and (low60 >= 2 or low40) then
                    return w[1], master, pact
                elseif kind == 'heal1' and lowest ~= nil and lowest:getHPP() < 50 then
                    return w[1], lowest, pact
                elseif kind == 'debuff' and fighting and target:isMob() and not hasEffectId(target, effectId(pact.effect)) then
                    return w[1], target, pact
                elseif kind == 'buff' and (fighting or w.idle) and master:isAlive() and not hasEffectId(master, effectId(pact.effect))
                    and not S.reserved(master, reserveKey(pact, abilityId(w[1])), mateId, now) then
                    return w[1], master, pact
                elseif kind == 'timed' and fighting and now >= mob:getLocalVar('SMN_T_' .. w[1]) then
                    mob:setLocalVar('SMN_T_' .. w[1], now + (w.every or 300))
                    return w[1], master, pact
                end
            end
        end
    end

    return nil
end

-- the strongest Rage this avatar has at this level
function S.bestRage(name, level)
    local best, bestLevel = nil, -1
    for _, n in ipairs(S.PACT_LIST) do
        local p = S.PACTS[n]
        if p[1] == name and p[2] == 'rage' and level >= p[3] and p[3] > bestLevel and abilityId(n) then
            best, bestLevel = n, p[3]
        end
    end

    return best
end

-- the MP kept for the protected rules (the dearest enabled protected pact the mate can use)
function S.protectedReserve(mob, rules)
    local keep, level = 0, mob:getMainLvl()
    for _, r in ipairs(rules) do
        local e = S.PACTS[r.pact]
        if r.on and r.protect and e and level >= e[3] then
            keep = math.max(keep, S.pactCost(mob, r.pact))
        end
    end

    return keep
end

-- ---------------------------------------------------------------- the planner
local function damageWeakness(target, element)
    if target == nil or not (xi.combat and xi.combat.damage and xi.combat.damage.magicalElementSDT and xi.element and xi.element[element or '']) then
        return nil
    end

    local ok, v = pcall(xi.combat.damage.magicalElementSDT, target, xi.element[element])
    return ok and tonumber(v) or nil
end

-- the best allowed avatar against the target (nil = nothing stands out)
function S.bestFor(target, level, has)
    local best, bestV = nil, 1.05
    for _, name in ipairs(S.AVATARS) do
        if S.allowed(name, level, has) then
            local v = damageWeakness(target, S.ELEMENT[name])
            if v and v > bestV then
                best, bestV = name, v
            end
        end
    end

    return best, bestV
end

local function manualHold(mob, now)
    return now < mob:getLocalVar('SMN_MANUAL_UNTIL')
end

-- the pet id squadPetId summons for "your choice" (kept for squad.lua; nil = its own pick)
function S.pickId(mob, master, level, has)
    if master == nil then
        return nil
    end

    local name = S.AVATARS[master:getCharVar(S.choiceVar(mob:getLocalVar('SQUAD_ID')))]
    if name and S.allowed(name, level, has) then
        return petIdOf(name)
    end

    return nil
end

-- the avatar this mate should have when nothing special is going on: your choice, Keep (the last one), or the default
local function wantedAvatar(mob, master, level, has, defaultPick)
    local choice = master:getCharVar(S.choiceVar(mob:getLocalVar('SQUAD_ID')))
    local name = S.AVATARS[choice]
    if name and S.allowed(name, level, has) then
        return name
    end

    if choice == S.KEEP then
        local last = S.nameOfPet(mob:getLocalVar('SMN_LAST_PET'))
        if last and S.allowed(last, level, has) then
            return last
        end

        -- nothing out yet: the avatar of the first enabled pact rule the mate can use now (its level, the pact's level,
        -- and the avatar's own level and pact: S.allowed), so "Keep current" starts with the rules' avatar
        local mateId = mob:getLocalVar('SQUAD_ID')
        for _, r in ipairs(S.getRules(master, mateId)) do
            local e = S.PACTS[r.pact]
            if r.on and e and level >= e[3] and abilityId(r.pact) and S.allowed(e[1], level, has) then
                return e[1]
            end
        end
    end

    local okP, picked = pcall(function() return defaultPick and defaultPick(mob) end)
    return (okP and picked and S.nameOfPet(picked)) or 'CARBUNCLE'
end

-- an intent from the rules (in order), or nil
local function chooseRule(mob, master, target, rules, settings, level, has, now, fighting)
    local mateId = mob:getLocalVar('SQUAD_ID')
    local current = currentAvatar(mob)
    for i, r in ipairs(rules) do
        local entry = S.PACTS[r.pact]
        local whenOk = (fighting and (r.when == 'COMBAT' or r.when == 'ANY'))
            or (not fighting and settings.idle and (r.when == 'IDLE' or r.when == 'ANY'))
        local kindOff = entry and ((entry[2] == 'rage' and settings.rage == 1) or (entry[2] == 'ward' and settings.ward == 1))
        if r.on and entry and whenOk and not kindOff and level >= entry[3] and abilityId(r.pact)
            and (entry[2] ~= 'astral' or mob:hasStatusEffect(xi.effect.ASTRAL_FLOW))
            and (entry[2] ~= 'rage' or fighting) and S.allowed(entry[1], level, has) then
            local needSwitch = current ~= entry[1]
            local switchOk = not needSwitch or (settings.ruleSwitch and not manualHold(mob, now)
                and now >= mob:getLocalVar('SMN_SWAP_NEXT') and petsAllowed(mob))
            local aim = switchOk and S.ruleAim(r, mob, master, target) or nil
            local key = entry[4] ~= 'enemy' and reserveKey(entry, abilityId(r.pact)) or nil
            if aim and (key == nil or S.reserve(master, key, mateId, now, S.INTENT_SECONDS)) then
                return { rule = i, name = r.pact, avatar = entry[1], kind = entry[2], key = key, expires = now + S.INTENT_SECONDS }
            end
        end
    end

    return nil
end

-- move the intent on: switch if needed (only when it can pay summon + pact + the upkeep while it waits), then the pact
local function progressIntent(mob, master, target, rules, has, now)
    local st = stateOf(mob)
    local intent = st.intent
    if intent == nil then
        return false
    end

    if now > intent.expires then
        cancelIntent(mob, master, 'took too long')
        return false
    end

    local r = rules[intent.rule]
    local aim = (r and r.pact == intent.name) and S.ruleAim(r, mob, master, target) or nil
    if aim == nil then
        cancelIntent(mob, master, 'no longer needed')
        return false
    end

    local current, pet = currentAvatar(mob)
    local cost = S.pactCost(mob, intent.name)
    local readyAt = intent.kind == 'astral' and now or mob:getLocalVar(timerVar(intent.kind))
    if current ~= intent.avatar then
        local wait = math.max(0, readyAt - now)
        local upkeep = math.max(0, S.netUpkeep(mob, intent.avatar)) * math.ceil(wait / S.TICK_SECONDS)
        local ok, why = S.switchTo(mob, intent.avatar, now, has, 'for ' .. pretty(intent.name), cost + upkeep)
        if not ok then
            cancelIntent(mob, master, why)
            return false
        end

        current, pet = currentAvatar(mob)
    end

    if pet == nil or st.sent ~= nil or now < readyAt or mob:getMP() < cost then
        return true -- (waiting: the timer, the MP, or the pact on its way; the intent expires if it never comes)
    end

    dispatch(mob, pet, intent.name, aim, now, intent.key)
    return true
end

-- one planning step; fighting = a combat tick with a living target
local function plan(mob, master, target, now, has, defaultPick, fighting)
    local st = stateOf(mob)
    local level = mob:getMainLvl()
    local mateId = mob:getLocalVar('SQUAD_ID')
    local settings = S.getSettings(master, mateId)
    local rules = S.getRules(master, mateId)

    if resting(mob) then
        S.onRest(mob)
        return
    end

    checkSent(mob, now, master)

    if mob:getLocalVar('SMN_RELEASED_UNTIL') > now then
        return -- (you released it: no avatar until the time is up)
    end

    if st.intent == nil and st.sent == nil then
        st.intent = chooseRule(mob, master, target, rules, settings, level, has, now, fighting)
        if st.intent then
            log(mob, string.format('rule %d: %s', st.intent.rule, pretty(st.intent.name)))
        end
    end

    local busy = progressIntent(mob, master, target, rules, has, now)
    local current, pet = currentAvatar(mob)

    -- an avatar for the fight when it has none: a paid summon that keeps 2 ticks of upkeep in hand
    if fighting and pet == nil and st.intent == nil and now >= mob:getLocalVar('SQUAD_PET_NEXT') then
        local name = wantedAvatar(mob, master, level, has, defaultPick)
        local ok = S.summon(mob, name, now, has, 2 * math.max(0, S.netUpkeep(mob, name)))
        mob:setLocalVar('SQUAD_PET_NEXT', now + (ok and 120 or 10))
        current, pet = currentAvatar(mob)
    end

    if pet == nil then
        return
    end

    -- normal attacks: on unless you turned them off; never stopped by Rage, its timer, MP or a reserve
    if fighting and settings.engage then
        SquadPetAttack(mob, target)
    end

    if busy or st.intent ~= nil or st.sent ~= nil then
        return
    end

    local choice = master:getCharVar(S.choiceVar(mateId))

    -- Auto: a new fight against something weak to another element brings that avatar, if it can pay for it
    if fighting and choice == 0 and not manualHold(mob, now) and mob:getLocalVar('SMN_LAST_TGT') ~= target:getID() then
        mob:setLocalVar('SMN_LAST_TGT', target:getID())
        local best, v = S.bestFor(target, level, has)
        local mine = damageWeakness(target, S.ELEMENT[current or '']) or 1
        if best and best ~= current and v >= mine + 0.15 and now >= mob:getLocalVar('SMN_SWAP_NEXT') then
            if S.switchTo(mob, best, now, has, 'weakness', 2 * math.max(0, S.netUpkeep(mob, best))) then
                return
            end
        end
    end

    -- Astral Flow: asked for ("2hr") or by itself on a notorious monster under 70%; the avatar's own Astral Flow pact
    -- (the player's check: Astral Flow on, MP >= level x 2)
    local afId = xi.effect and xi.effect.ASTRAL_FLOW
    if afId and fighting then
        local flowing = mob:hasStatusEffect(afId)
        if not flowing and target:isMob() and target:isNM() and target:getHPP() <= 70
            and os.time() >= master:getCharVar('SQUAD_AF_' .. mateId) then
            master:setCharVar('SQUAD_AF_' .. mateId, os.time() + S.AF_SECONDS)
            mob:addStatusEffect(afId, { power = 1, duration = 180, origin = mob })
            flowing = true
        end

        if flowing and mob:getLocalVar('SMN_AF_USED') == 0 and current and S.ASTRAL[current] then
            if dispatch(mob, pet, S.ASTRAL[current], target, now, nil) then
                mob:setLocalVar('SMN_AF_USED', 1)
                return
            end
        end
    elseif afId and not mob:hasStatusEffect(afId) then
        mob:setLocalVar('SMN_AF_USED', 0)
    end

    local hasWardRules, hasRageRules = false, false
    for _, r in ipairs(rules) do
        local e = S.PACTS[r.pact]
        hasWardRules = hasWardRules or (r.on and e ~= nil and e[2] == 'ward')
        hasRageRules = hasRageRules or (r.on and e ~= nil and e[2] == 'rage')
    end

    -- built-in wards (Ward mode Auto and no Ward rules)
    if settings.ward == 0 and not hasWardRules and now >= mob:getLocalVar('SQUAD_WARD_NEXT') and (fighting or settings.idle) then
        local name, aim, entry = S.chooseWard(mob, pet, master, fighting and target or nil, level, current, now, not fighting)
        if name then
            local key = entry[4] ~= 'enemy' and reserveKey(entry, abilityId(name)) or nil
            if key == nil or S.reserve(master, key, mateId, now, S.PENDING_SECONDS + 2) then
                if dispatch(mob, pet, name, aim, now, key) then
                    return
                end

                S.unreserve(master, key, mateId)
            end
        end
    end

    -- built-in Rage (Rage mode Auto and no Rage rules): only with the MP left over after the protected rules
    if fighting and settings.rage == 0 and not hasRageRules and now >= mob:getLocalVar('SQUAD_BP_NEXT') then
        local rage = current and S.bestRage(current, level)
        if rage then
            if mob:getMP() - S.pactCost(mob, rage) < S.protectedReserve(mob, rules) then
                mob:setLocalVar('SQUAD_BP_NEXT', now + S.RETRY_STEP)
            else
                local sent, why = dispatch(mob, pet, rage, target, now, nil)
                if not sent then
                    -- (r4) waiting for the avatar: look again at the next tick
                    mob:setLocalVar('SQUAD_BP_NEXT', now + (why == 'waiting' and 1 or S.RETRY_STEP))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- entry points (squad.lua)
-- every combat tick of a SMN mate (petTick)
function S.combatTick(mob, master, target, now, has, defaultPick)
    if master == nil then
        return
    end

    local fighting = target ~= nil and target:isAlive()
    if fighting then
        mob:setLocalVar('SMN_FIGHT_AT', now)
    end

    plan(mob, master, fighting and target or nil, now, has, defaultPick, fighting)
end

-- the idle tick (you are not fighting): resting, release between pulls, support out of combat. At most once a second.
function S.idleTick(mob, master, now, has, defaultPick)
    if master == nil or mob:getLocalVar('SMN_IDLE_AT') == now then
        return
    end

    mob:setLocalVar('SMN_IDLE_AT', now)
    if mob:isEngaged() or master:isEngaged() then
        return -- (the combat tick has it)
    end

    if resting(mob) then
        S.onRest(mob)
        return
    end

    local settings = S.getSettings(master, mob:getLocalVar('SQUAD_ID'))
    local st = stateOf(mob)
    -- (r2, DEV 2026-11-26: "after a fight no release, it says Claw is on its way") the fight is over: a pact of the fight
    -- that is still pending, and an intent for a fight-only rule, end here (they were kept alive only by combat ticks),
    -- so the release between pulls is not blocked by them
    checkSent(mob, now, master)
    if st.intent then
        local r = S.getRules(master, mob:getLocalVar('SQUAD_ID'))[st.intent.rule]
        if r == nil or r.when == 'COMBAT' or st.intent.kind == 'rage' or not settings.idle then
            cancelIntent(mob, master, 'the fight is over')
        end
    end

    if currentAvatar(mob) and st.intent == nil and st.sent == nil and now - mob:getLocalVar('SMN_FIGHT_AT') >= S.IDLE_RELEASE then
        local low = mob:getMaxMP() > 0 and mob:getMP() * 2 < mob:getMaxMP()
        if settings.between == 1 or (settings.between == 2 and low) then
            S.release(mob, 'between pulls')
            return
        end
    end

    -- support out of combat only where the avatar's upkeep is charged (an older xi_map would make it a free buff bot)
    if settings.idle and S.engineReady() then
        plan(mob, master, nil, now, has, defaultPick, false)
    end
end

-- the mate sits down to rest: a player releases the avatar first; so does the mate (and calls none while it rests)
function S.onRest(mob)
    cancelIntent(mob, mob:getMaster(), 'resting')
    if currentAvatar(mob) then
        S.release(mob, 'resting')
    end
end

-- ---------------------------------------------------------------- your orders and the Gambits avatar setting
-- set a mate's avatar (idx nil = Auto, S.KEEP = keep the current one). manual = a chat or command order (it wins for
-- S.MANUAL_SECONDS); the Gambits setting is not an order. Naming the avatar that is out changes nothing.
function S.setChoice(player, mateId, mateName, idx, outMate, has, manual)
    player:setCharVar(S.choiceVar(mateId), idx or 0)
    local now = nowSecs()
    if idx == nil then
        if outMate then
            outMate:setLocalVar('SMN_MANUAL_UNTIL', 0)
            outMate:setLocalVar('SMN_SWAP_NEXT', now + S.SWAP_SECONDS) -- (Auto again, but not this very moment)
        end

        return string.format('%s picks the avatar by itself (Auto).', mateName)
    elseif idx == S.KEEP then
        return string.format('%s keeps the avatar it has.', mateName)
    end

    local name = S.AVATARS[idx]
    if outMate ~= nil then
        if manual then
            outMate:setLocalVar('SMN_MANUAL_UNTIL', now + S.MANUAL_SECONDS)
            outMate:setLocalVar('SMN_RELEASED_UNTIL', 0)
            cancelIntent(outMate, player, 'your order')
        end

        if currentAvatar(outMate) == name then
            return string.format('%s already has %s out.', mateName, pretty(name))
        end

        local ok, why = S.switchTo(outMate, name, now, has, 'your order', 0)
        if not ok then
            return string.format('%s will bring %s when it can (%s).', mateName, pretty(name), why)
        end
    end

    return string.format('%s will bring %s.', mateName, pretty(name))
end

-- "release": the avatar leaves for S.RELEASE_SECONDS (no summon, no intent in that time)
function S.orderRelease(player, mate)
    local now = nowSecs()
    cancelIntent(mate, player, 'your order')
    mate:setLocalVar('SMN_RELEASED_UNTIL', now + S.RELEASE_SECONDS)
    mate:setLocalVar('SQUAD_PET_NEXT', now + S.RELEASE_SECONDS)
    mate:setLocalVar('SMN_MANUAL_UNTIL', now + S.RELEASE_SECONDS)
    S.release(mate, 'your order')
end

-- party chat: "Ayame Ifrit", "Ifrit" (the first Summoner out), "all Shiva", "release", "Ayame auto", "avatar auto".
-- words = the line after the mate's name was taken off. true = handled.
function S.chat(player, askedMates, everyone, named, words, has)
    local smns = {}
    for _, m in ipairs(askedMates) do
        if m:getMainJob() == xi.job.SMN then
            smns[#smns + 1] = m
        end
    end

    if #smns == 0 or #words == 0 or #words > 2 then
        return false
    end

    local line = table.concat(words, ' ')
    local idx, auto, release = S.indexOf(words[#words]), false, false
    if line == 'avatar auto' or (named and line == 'auto') then
        auto = true
    elseif line == 'release' or line == 'release avatar' then
        release = true
    elseif idx == nil or (#words == 2 and words[1] ~= 'avatar' and words[1] ~= 'summon' and words[1] ~= 'call') then
        return false
    end

    local targets = everyone and smns or { smns[1] }
    for _, m in ipairs(targets) do
        local mateName = m:getPacketName()
        if release then
            S.orderRelease(player, m)
            player:printToPlayer(string.format('%s releases the avatar for a minute.', mateName))
        else
            player:printToPlayer(S.setChoice(player, m:getLocalVar('SQUAD_ID'), mateName, (not auto) and idx or nil, m, has, true))
        end
    end

    return true
end

-- !squad avatar [mate] [avatar|auto|keep]
function S.command(player, squad, mateWord, avatarWord, outMates, has)
    local function list()
        local parts = {}
        for _, mate in ipairs(squad or {}) do
            if mate.mjob == xi.job.SMN then
                local idx = player:getCharVar(S.choiceVar(mate.id))
                parts[#parts + 1] = string.format('%s: %s', mate.name,
                    idx == S.KEEP and 'Keep' or (S.AVATARS[idx] and pretty(S.AVATARS[idx]) or 'Auto'))
            end
        end
        return #parts > 0 and table.concat(parts, ', ') or 'No Summoner in your squad.'
    end

    if mateWord == nil or mateWord == '' then
        player:printToPlayer('Avatars: ' .. list() .. '. Use !squad avatar <mate> <carbuncle|ifrit|titan|leviathan|garuda|shiva|ramuh|fenrir|auto|keep>.')
        return
    end

    local mate = nil
    for _, m in ipairs(squad or {}) do
        if string.lower(m.name) == string.lower(mateWord) then
            mate = m
        end
    end

    if mate == nil then
        player:printToPlayer('No squad mate called ' .. mateWord .. '.')
        return
    end

    local word = string.lower(avatarWord or '')
    local idx = S.indexOf(word)
    if word == 'keep' then
        idx = S.KEEP
    elseif word ~= 'auto' and idx == nil then
        player:printToPlayer('Pick one of: carbuncle, ifrit, titan, leviathan, garuda, shiva, ramuh, fenrir, auto, keep.')
        return
    end

    local out = outMates and outMates[mate.id] or nil
    player:printToPlayer(S.setChoice(player, mate.id, mate.name, idx, out, has, true))
end

-- ---------------------------------------------------------------- Gambits (gambits_squad.lua)
-- the pacts a mate could be told to use: { name, avatar, level, kind, aim, effect, usable (level and pact) }
function S.catalog(level, has)
    local out = {}
    for _, n in ipairs(S.PACT_LIST) do
        local p = S.PACTS[n]
        if abilityId(n) then
            out[#out + 1] = { name = n, avatar = p[1], level = p[3], kind = p[2], aim = p[4], effect = p.effect,
                              usable = S.allowed(p[1], level, has) == true and level >= p[3] }
        end
    end

    return out
end

-- what a called mate is doing now (the Gambits status line)
function S.live(mob)
    if mob == nil then
        return nil
    end

    local st = S.state[mob:getID()] or {}
    return { avatar = currentAvatar(mob), intent = st.intent and st.intent.name or nil, sent = st.sent and st.sent.name or nil,
             mp = mob:getMP(), maxmp = mob:getMaxMP(), pacts = mob:getLocalVar('SMN_PACTS') }
end

-- true when the map server charges perpetuation and has no avatar TP moves (squad.cpp marker)
function S.engineReady()
    return type(rawget(_G, 'SquadSmnEngine')) == 'function'
end

return S
