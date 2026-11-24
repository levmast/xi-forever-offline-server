-----------------------------------
-- Squads Revamped: thin C++ step 2, the job ability rules for party chat and the retry of a busy mate (audit step S3, blocks B37 and B38).
--
-- Before: squad.cpp decided in C (squadMateMayUse + a two hour check) whether a mate may use a job ability, in trySquadAbility. Now the rules
-- are the Lua rules that already existed for the Rule Sets (squad_ability_rules.lua: main job at its level; sub job at the sub level but never a
-- two hour or main-only ability; never a pet ability; a merit ability only when the owner has the merit). One rule table, one place, hot reloadable.
--
-- C++ keeps what needs the game: the recast test and the call into the trust controller. It registers them as
--   SquadTryAbilityRaw(player, mate, abilityId)   and   SquadUseAbilityRaw(player, mate, abilityId)    -> 'cast' | 'unknown' | 'notready' | 'notarget' | 'busy'
-- and this file defines the names the other Lua already calls (SquadTryAbility from squad_logic.lua, SquadUseAbility from squad.lua) in front of them,
-- so no caller changes. On a map server that was NOT rebuilt (the original C++ registers SquadTryAbility and SquadUseAbility itself, after the Lua files
-- loaded, and replaces these two), this file changes nothing; and a reload on such a server leaves the C++ functions alone.
--
-- Not a binding call at load time: the bindings are registered after the Lua files loaded.
-----------------------------------
SQ_LOGIC = SQ_LOGIC or {}
local L = SQ_LOGIC

L.version = 1

local function rules()
    local ok, mod = pcall(require, 'modules/custom/lua/squad_ability_rules')
    if ok and type(mod) == 'table' then
        return mod
    end

    return nil
end

-- true, or false and the reason (fails closed: no rule table, no ability)
function L.mayUse(mate, abilityId)
    local A = rules()
    if A == nil or abilityId == nil or mate == nil then
        return false, 'the job ability rules are not available'
    end

    local owner = A.ownerOf(mate)
    local m = { job = mate:getMainJob(), level = mate:getMainLvl(), subJob = mate:getSubJob() or 0, subLevel = mate:getSubLvl() or 0, owner = owner }
    local why = A.reason(m, abilityId)
    return why == nil, why
end

-- the result names the callers expect
local function gate(raw, player, mate, abilityId)
    if type(raw) ~= 'function' then
        return 'busy'
    end

    if mate ~= nil and mate:isAlive() then
        local ok = L.mayUse(mate, abilityId)
        if not ok then
            return 'unknown'
        end
    end

    return raw(player, mate, abilityId)
end

function L.tryAbility(player, mate, abilityId)
    return gate(rawget(_G, 'SquadTryAbilityRaw'), player, mate, abilityId)
end

function L.useAbility(player, mate, abilityId)
    return gate(rawget(_G, 'SquadUseAbilityRaw'), player, mate, abilityId)
end

-- Define the two names in front of the raw bindings: at load (both nil, the bindings come later) and on a reload of a rebuilt server (the raw
-- bindings exist). Never over the C++ functions of a server that was not rebuilt.
local function install(name, fn, rawName)
    local current = rawget(_G, name)
    if current == nil or rawget(_G, rawName) ~= nil then
        _G[name] = fn
    end
end

install('SquadTryAbility', function(player, mate, abilityId) return L.tryAbility(player, mate, abilityId) end, 'SquadTryAbilityRaw')
install('SquadUseAbility', function(player, mate, abilityId) return L.useAbility(player, mate, abilityId) end, 'SquadUseAbilityRaw')

return L
