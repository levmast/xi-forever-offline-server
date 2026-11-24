-----------------------------------
-- FFXI Offline: Fields of Valor / Grounds of Valor without the prowess buffs.
--
-- Pages, tabs, gil and the experience reward work as normal, and so do the book's teleports
-- (Repatriation, Homing Instinct), Cancel regime and the Field Support buffs bought with tabs: Circumspection
-- (sneak/invisible), Reraise I-III, Regen, Refresh, Protect, Shell, Haste and the food options (levi, 2026-11-24).
-- Turned off:
--   * Trust cipher purchases (Koru-Moru, Sakura): Trusts are not part of this server.
--   * The random Grounds of Valor prowess buffs (casket rate, skill-up rate, crystal yield, treasure hunter,
--     attack speed, HP/MP, accuracy, attack, magic, cure potency, weapon skill damage, killer) and their lines.
--     The repeat-clear counter that raises the page reward (up to double) stays.
-- Page exp: multiplied by "Experience from Fields/Grounds pages" on the launcher's Rates tab (0.125 = 1/8),
-- then capped like one era kill (200 up to level 50, 250 at 51-60, 300 at 61-75).
-- Squad mates out with you get the page's exp too (capped for their level); needs squad.lua 1.7+ (xi.squad.grantExp).
-- Picking a turned-off option in the book costs nothing and says so.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/regimes')
-----------------------------------
local m = Module:new('fov_no_buffs')

-- book menu option numbers (from scripts/globals/regimes.lua) that are turned off
local blocked =
{
    [xi.regime.type.FIELDS] =
    {
        [181] = true, [197] = true,                                           -- trust ciphers
    },
    [xi.regime.type.GROUNDS] =
    {
        [292] = true, [308] = true,                                           -- trust ciphers
    },
}

local prowessEffects =
{
    'PROWESS_CASKET_RATE', 'PROWESS_SKILL_RATE', 'PROWESS_CRYSTAL_YIELD', 'PROWESS_TH', 'PROWESS_ATTACK_SPEED',
    'PROWESS_HP_MP', 'PROWESS_ACC_RACC', 'PROWESS_ATT_RATT', 'PROWESS_MACC_MATK', 'PROWESS_CURE_POTENCY',
    'PROWESS_WS_DMG', 'PROWESS_KILLER',
}

m:addOverride('xi.regime.bookOnEventFinish', function(player, option, regimeType)
    local opt  = bit.band(option, 0x7FFFFFFF)
    local list = blocked[regimeType]
    if list and list[opt] then
        player:printToPlayer('That option is turned off on this server. No tabs were spent.', xi.msg.channel.SYSTEM_3)
        return
    end

    return super(player, option, regimeType)
end)

-- Era cap for one page's exp: the same as the era cap for one monster (era_exp.lua): 200 / 250 / 300.
-- (2026-11-20, Ricc: "pages only give 200 with the page rate at x3") a monster's exp is capped first and multiplied by its
-- rate afterwards; a page was multiplied first and capped afterwards, so a page rate above 1 did nothing once the cap
-- was reached. The cap now rises with the page rate when that is above 1 (x3: 600 / 750 / 900); at 1 or below it is
-- the same as before.
local function eraCap(level)
    local rate = math.max(1, tonumber(xi.settings.main.BOOK_EXP_RATE) or 1)
    local cap  = 300
    if level <= 50 then
        cap = 200
    elseif level <= 60 then
        cap = 250
    end

    return math.floor(cap * rate)
end

local prowessBuff, prowessMessage = {}, {}
for _, name in ipairs(prowessEffects) do
    local effect = xi.effect[name]
    if effect then
        prowessBuff[effect]          = true
        prowessMessage[effect - 168] = true -- the game's "prowess" line for that buff (see regimes.lua)
    end
end

-- The page code is run with a stand-in for the player that forwards everything to the real one, except:
--   addExp:          held back, then capped and given to you and your squad mates below
--   addStatusEffect: the random Grounds prowess buffs are not given (the repeat-clear counter is)
--   messageBasic:    their "prowess" lines are not shown
-- The stand-in must never reach the engine itself: arguments that are the stand-in (or a table whose origin is the
-- stand-in, e.g. the Grounds repeat-clear counter's { power = n, origin = player }) are swapped for the real player.
-- Before this the counter's addStatusEffect failed and the page stopped right after "completed": no reward, and the
-- page stayed full and never finished.
local function realArgs(proxy, player, ...)
    -- LuaJIT (the map server): no table.pack / table.unpack, so select('#') and the global unpack
    local args = { n = select('#', ...), ... }
    for i = 1, args.n do
        local a = args[i]
        if rawequal(a, proxy) then
            args[i] = player
        elseif type(a) == 'table' and getmetatable(a) == nil and rawequal(a.origin, proxy) then
            local copy = {}
            for k, v in pairs(a) do
                copy[k] = v
            end

            copy.origin = player
            args[i] = copy
        end
    end

    return (unpack or table.unpack)(args, 1, args.n)
end

local function standIn(player, held)
    local proxy = {}
    return setmetatable(proxy, {
        __index = function(_, key)
            if key == 'addExp' then
                return function(_, amount)
                    held.exp = (held.exp or 0) + (tonumber(amount) or 0)
                end
            elseif key == 'addStatusEffect' then
                return function(_, effect, ...)
                    if prowessBuff[effect] then
                        return false
                    end

                    return player:addStatusEffect(effect, realArgs(proxy, player, ...))
                end
            elseif key == 'messageBasic' then
                return function(_, msg, ...)
                    if prowessMessage[msg] then
                        return
                    end

                    return player:messageBasic(msg, realArgs(proxy, player, ...))
                end
            end

            local value = player[key]
            if type(value) == 'function' then
                return function(_, ...)
                    return value(player, realArgs(proxy, player, ...))
                end
            end

            return value
        end,
    })
end

m:addOverride('xi.regime.checkRegime', function(player, mob, regimeId, index, regimeType)
    if not player then
        return super(player, mob, regimeId, index, regimeType)
    end

    local held = {}
    super(standIn(player, held), mob, regimeId, index, regimeType)

    -- belt and braces: no random prowess buff stays on
    if regimeType == xi.regime.type.GROUNDS then
        for effect in pairs(prowessBuff) do
            if player:hasStatusEffect(effect) then
                player:delStatusEffectSilent(effect)
            end
        end
    end

    -- the page's exp (already x "Experience from Fields/Grounds pages" and the Grounds repeat bonus), capped like one era kill
    local pageExp = math.floor(held.exp or 0)
    if pageExp <= 0 then
        return
    end

    local mine = math.min(pageExp, eraCap(player:getMainLvl()))
    if mine > 0 then
        player:addExp(mine)
    end

    -- squad mates out with you get the page's exp too, capped for their own level
    if xi.squad and xi.squad.activeMates and xi.squad.grantExp then
        local ok, mates = pcall(xi.squad.activeMates, player)
        if ok and type(mates) == 'table' then
            local names = {}
            for _, entry in ipairs(mates) do
                local gain = math.min(pageExp, eraCap(entry.mate:getMainLvl()))
                local done = pcall(xi.squad.grantExp, player, entry.mate, entry.squadId, gain)
                if done then
                    table.insert(names, string.format('%s %d', entry.mate:getPacketName(), gain))
                end
            end

            if #names > 0 then
                player:printToPlayer('Page exp for your squad: ' .. table.concat(names, ', ') .. '.', xi.msg.channel.SYSTEM_3)
            end
        end
    end
end)

return m
