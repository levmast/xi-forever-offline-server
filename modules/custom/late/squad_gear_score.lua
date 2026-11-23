-----------------------------------
-- XI: Forever Offline: what a piece of gear is worth to a job (lilibun, 2026-11-22)
--
-- Auto-equip (squad.lua squadAutoEquip) used to take the highest-level piece a mate could wear in each slot, so a
-- level 20 Warrior put on a Silver Hairpin (MP+15, HP-6) because it is level 20 and a cap is level 7.
-- SQUAD_GEAR_SCORE.rate(info, job, level) gives a number for a piece: what it adds (item_mods) times what that is
-- worth to the job, and for a weapon its damage per second times how well the job handles that kind of weapon.
-- info comes from GetSquadItemInfo (squad.cpp), which has to be the build that sends mods, dmg and delay; with an
-- older xi_map rate() answers nil and auto-equip goes by level as before.
--
-- The numbers are a judgement, not a formula from the game: change them here (or live, they are plain tables).
--   SQUAD_GEAR_SCORE.kinds   what one point is worth to a kind of fighter
--   SQUAD_GEAR_SCORE.jobs    which kinds a job is made of, and its own corrections
--   SQUAD_GEAR_SCORE.ranks   how well a job handles a weapon skill (1 = its best)
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('xifo_squad_gear_score')

SQUAD_GEAR_SCORE = SQUAD_GEAR_SCORE or {}
local G = SQUAD_GEAR_SCORE

-- weapon = main and sub hand damage per second, ranged = the ranged slot's, ammo = an arrow's or bullet's damage
G.kinds =
{
    -- everyone: staying alive counts a little
    -- (the DMG lines are "damage taken", in hundredths of a percent: -500 = 5% less, so less is better)
    all    = { DEF = 0.12, HP = 0.04, VIT = 0.10, EVA = 0.10, MDEF = 0.5, MEVA = 0.03, REGEN = 3, DMG = -0.005, DMGPHYS = -0.003,
               DMGMAGIC = -0.003, DMGBREATH = -0.001, DMGRANGE = -0.001, HPHEAL = 0.3, weapon = 2, ranged = 0.5, ammo = 0.05 },
    melee  = { STR = 1.0, DEX = 0.75, AGI = 0.2, ATT = 0.5, ACC = 0.8, HASTE_GEAR = 0.03, DOUBLE_ATTACK = 3, TRIPLE_ATTACK = 5,
               CRITHITRATE = 2, STORETP = 1, SUBTLE_BLOW = 0.2, ENMITY = -0.2, weapon = 12 },
    tank   = { DEF = 0.5, HP = 0.15, VIT = 1.0, STR = 0.5, DEX = 0.4, ATT = 0.25, ACC = 0.6, ENMITY = 1.5, EVA = 0.3, SHIELD = 0.4,
               PARRY = 0.2, DMG = -0.012, DMGPHYS = -0.008, DMGMAGIC = -0.006, HASTE_GEAR = 0.02, SPELLINTERRUPT = 0.2, weapon = 8 },
    healer = { MND = 1.0, MP = 0.15, INT = 0.15, CHR = 0.1, HEALING = 0.5, ENHANCE = 0.3, DIVINE = 0.2, ENFEEBLE = 0.2,
               CURE_POTENCY = 3, FASTCAST = 2, CONSERVE_MP = 0.5, REFRESH = 12, MPHEAL = 0.5, MACC = 0.3, ENMITY = -0.8,
               SPELLINTERRUPT = 0.2 },
    nuker  = { INT = 1.0, MP = 0.15, MND = 0.2, MATT = 2.5, MACC = 1.5, ELEM = 0.6, DARK = 0.3, ENFEEBLE = 0.2, FASTCAST = 2,
               CONSERVE_MP = 0.5, REFRESH = 12, MPHEAL = 0.5, ENMITY = -0.5, SPELLINTERRUPT = 0.2 },
    ranged = { AGI = 1.0, STR = 0.6, DEX = 0.2, RACC = 0.8, RATT = 0.5, ACC = 0.2, ATT = 0.1, STORETP = 1, ENMITY = -0.3,
               RAPID_SHOT = 1, weapon = 4, ranged = 12, ammo = 0.6 },
    singer = { CHR = 1.0, SINGING = 0.8, STRING = 0.8, WIND = 0.8, MACC = 0.8, ALL_SONGS_EFFECT = 8, MP = 0.02, DEX = 0.2,
               AGI = 0.2, ACC = 0.2, FASTCAST = 1, weapon = 3, ranged = 0 },
    caller = { MP = 0.25, SUMMONING = 0.8, MND = 0.3, INT = 0.3, REFRESH = 12, MPHEAL = 0.5, AVATAR_PERPETUATION = -8,
               PERPETUATION_REDUCTION = 8, BP_DELAY = 1.5, ENMITY = -0.3 },
}

-- job id -> the kinds it is made of (added together, each with a share) and its own corrections on top
G.jobs =
{
    [1]  = { { melee = 1 } },                                                               -- WAR
    [2]  = { { melee = 1 }, { COUNTER = 2, KICK_ATTACK_RATE = 2, MARTIAL_ARTS = 0.3, GUARD = 0.2, HP = 0.08, VIT = 0.3 } }, -- MNK
    [3]  = { { healer = 1 } },                                                              -- WHM
    [4]  = { { nuker = 1 } },                                                               -- BLM
    [5]  = { { nuker = 0.6, healer = 0.5, melee = 0.15 }, { ENFEEBLE = 0.3, ENHANCE = 0.15, MACC = 0.5, FASTCAST = 1 } }, -- RDM
    [6]  = { { melee = 1 }, { DEX = 0.25, AGI = 0.4, EVA = 0.3, TREASURE_HUNTER = 10, RACC = 0.1 } }, -- THF
    [7]  = { { tank = 1, healer = 0.15 }, { MND = 0.3, MP = 0.05, CURE_POTENCY = 1, DIVINE = 0.2, ENMITY = 0.5 } }, -- PLD
    [8]  = { { melee = 1 }, { INT = 0.3, DARK = 0.3, MP = 0.03, MACC = 0.3 } },             -- DRK
    [9]  = { { melee = 1 }, { CHR = 0.6, CHARM_TIME = 1 } },                                -- BST
    [10] = { { singer = 1 } },                                                              -- BRD
    [11] = { { ranged = 1 } },                                                              -- RNG
    [12] = { { melee = 1 }, { STORETP = 2, ZANSHIN = 1, RACC = 0.1 } },                     -- SAM
    [13] = { { melee = 0.7, tank = 0.4 }, { EVA = 0.4, AGI = 0.5, NINJUTSU = 0.4, DUAL_WIELD = 2, INT = 0.15, ENMITY = 0.3,
             HASTE_GEAR = 0.01, RACC = 0.1 } },                                             -- NIN
    [14] = { { melee = 1 } },                                                               -- DRG
    [15] = { { caller = 1 } },                                                              -- SMN
    [16] = { { melee = 0.8, nuker = 0.3 }, { MND = 0.3, MP = 0.08, BLUE = 0.5, MACC = 0.4, MATT = 0.5 } }, -- BLU
    [17] = { { ranged = 0.8, melee = 0.3 }, { MACC = 0.2 } },                               -- COR
    [18] = { { melee = 1 }, { MARTIAL_ARTS = 0.3, GUARD = 0.2 } },                          -- PUP
    [19] = { { melee = 1 }, { DEX = 0.2, AGI = 0.3, EVA = 0.3, CHR = 0.3, MND = 0.1 } },    -- DNC
    [20] = { { nuker = 0.7, healer = 0.6 } },                                               -- SCH
    [21] = { { nuker = 0.8, healer = 0.2 }, { GEOMANCY_SKILL = 0.8, HANDBELL_SKILL = 0.8 } }, -- GEO
    [22] = { { tank = 0.8, melee = 0.5 }, { MDEF = 1, MEVA = 0.1 } },                       -- RUN
}

-- weapon skill ids: 1 hand-to-hand, 2 dagger, 3 sword, 4 great sword, 5 axe, 6 great axe, 7 scythe, 8 polearm, 9 katana,
-- 10 great katana, 11 club, 12 staff, 25 archery, 26 marksmanship, 27 throwing. 1 = the job's best, by its skill ranks.
local A, B, C, D, E = 1.0, 0.88, 0.76, 0.64, 0.52
G.ranks =
{
    [1]  = { [6] = A, [5] = A, [4] = B, [7] = B, [3] = B, [12] = B, [8] = B, [2] = B, [11] = B, [1] = D, [25] = D, [26] = D, [27] = D },
    [2]  = { [1] = A, [12] = D, [11] = E, [27] = E }, -- (a Monk's fists come first, whatever the staff's numbers say)
    [3]  = { [11] = A, [12] = B },
    [4]  = { [12] = A, [11] = B, [7] = E, [2] = D },
    [5]  = { [3] = A, [2] = A, [11] = D, [25] = D, [27] = E },
    [6]  = { [2] = A, [3] = D, [11] = E, [1] = E, [26] = C, [25] = C, [27] = D },
    [7]  = { [3] = A, [11] = A, [12] = C, [4] = B, [2] = C, [8] = E }, -- (a staff takes the shield away)
    [8]  = { [7] = A, [4] = A, [5] = B, [6] = B, [3] = B, [2] = C, [11] = C, [26] = E },
    [9]  = { [5] = A, [7] = B, [2] = C, [11] = D, [3] = E },
    [10] = { [2] = A, [12] = B, [3] = C, [11] = D, [27] = E },
    [11] = { [26] = A, [25] = A, [5] = B, [2] = B, [3] = D, [11] = E, [27] = C },
    [12] = { [10] = A, [8] = B, [3] = C, [25] = C, [27] = C, [11] = E, [2] = E },
    [13] = { [9] = A, [27] = A, [2] = C, [3] = C, [26] = C, [10] = C, [1] = E, [11] = E, [25] = E },
    [14] = { [8] = A, [12] = B, [3] = C, [11] = E, [2] = E },
    [15] = { [12] = A, [11] = B, [2] = E },
    [16] = { [3] = A, [11] = B },
    [17] = { [26] = A, [2] = A, [3] = B, [27] = C },
    [18] = { [1] = A, [2] = D, [11] = E, [27] = C },
    [19] = { [2] = A, [1] = D, [3] = D, [27] = C },
    [20] = { [12] = A, [11] = A, [2] = D },
    [21] = { [11] = A, [12] = B, [2] = D },
    [22] = { [4] = A, [3] = A, [6] = B, [5] = B, [11] = C },
}

local cache = {}

-- what one point of each mod (by name) is worth to a job: the "all" kind plus the job's kinds and corrections
G.weights = function(job)
    if cache[job] then
        return cache[job]
    end

    local out = {}
    for name, value in pairs(G.kinds.all) do
        out[name] = value
    end

    local def = G.jobs[job] or { { melee = 1 } }
    for kind, share in pairs(def[1] or {}) do
        for name, value in pairs(G.kinds[kind] or {}) do
            if name == 'weapon' or name == 'ranged' or name == 'ammo' then
                -- how much the weapon counts is the most any of the job's kinds gives it, not a sum
                out[name] = math.max(out[name] or 0, value * share)
            else
                out[name] = (out[name] or 0) + value * share
            end
        end
    end

    for name, value in pairs(def[2] or {}) do
        out[name] = (out[name] or 0) + value
    end

    cache[job] = out
    return out
end

local names = nil -- mod id -> name, for the mods some job cares about (xi.mod is ready by the time gear is rated)
local function modNames()
    if names == nil then
        names = {}
        local wanted = {}
        for _, kind in pairs(G.kinds) do
            for name in pairs(kind) do
                wanted[name] = true
            end
        end

        for _, def in pairs(G.jobs) do
            for name in pairs(def[2] or {}) do
                wanted[name] = true
            end
        end

        for name in pairs(wanted) do
            local id = xi and xi.mod and xi.mod[name]
            if type(id) == 'number' then
                names[id] = name
            end
        end
    end

    return names
end

local function has(mask, bitIndex)
    return math.floor((mask or 0) / 2 ^ bitIndex) % 2 == 1
end

-- The worth of a piece for a job at a level. nil = cannot tell (no stats from the server): go by level.
G.rate = function(info, job, lvl)
    if type(info) ~= 'table' or type(info.mods) ~= 'table' then
        return nil
    end

    lvl = lvl or 1
    local w = G.weights(job)
    local byId = modNames()
    local sum = {}
    for id, value in pairs(info.mods) do
        local name = byId[id]
        if name then
            sum[name] = (sum[name] or 0) + value
        end
    end

    -- "Converts HP to MP" and the other way round, and the percent lines, as plain HP and MP
    local convHP = info.mods[xi.mod.CONVMPTOHP] or 0
    local convMP = info.mods[xi.mod.CONVHPTOMP] or 0
    local hpp    = info.mods[xi.mod.HPP] or 0
    local mpp    = info.mods[xi.mod.MPP] or 0
    sum.HP = (sum.HP or 0) + convHP - convMP + hpp / 100 * (40 + lvl * 14)
    sum.MP = (sum.MP or 0) + convMP - convHP + mpp / 100 * (20 + lvl * 8)

    local score = 0
    for name, value in pairs(sum) do
        score = score + value * (w[name] or 0)
    end

    -- a weapon: damage per second, by the slot it goes in
    local dmg, delay, skill = info.dmg or 0, info.delay or 0, info.skill or 0
    if dmg > 0 then
        if has(info.slot, 3) then
            if skill >= 25 and skill <= 27 then -- (arrows, bolts, bullets, things to throw: pet food has a number here too)
                score = score + dmg * (w.ammo or 0)
            end
        elseif has(info.slot, 2) then
            score = score + dmg / math.max(delay, 60) * 60 * (w.ranged or 0) * ((G.ranks[job] or {})[skill] or E)
        elseif has(info.slot, 0) or has(info.slot, 1) then
            if skill == 1 then
                -- hand-to-hand: the weapon adds to the fists' own damage and delay, and both fists hit. Monks and
                -- Puppetmasters swing faster as they level (Martial Arts: 80 off at 16, 20 more every 15 levels).
                local arts = 0
                if (job == 2 or job == 18) and lvl >= 16 then
                    arts = math.min(160, 80 + 20 * math.floor((lvl - 16) / 15))
                end

                dmg, delay = (dmg + 3 + lvl * 0.33) * 2, delay - arts -- (the delay in the data already has the fists' 480)
            end

            score = score + dmg / math.max(delay, 60) * 60 * (w.weapon or 0) * ((G.ranks[job] or {})[skill] or E)
        end
    end

    return score + (info.level or 0) * 0.005 -- (between near equals the newer piece)
end

return m
