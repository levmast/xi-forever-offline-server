-----------------------------------
-- XI: Forever Offline: squad support job levels (xi.squad.levelsFor, modules/custom/lua/squad.lua).
-- A main level 1 squad mate keeps a level 1 support job, as a player does: CBattleEntity::SetSLevel gives a main level 1
-- character a level 1 support job whatever map.SUBJOB_RATIO says (0 = no support jobs). The v0.1.57 ratio change
-- computed floor(1 / 2) = 0 there and the mate lost its support job.
-- The mates and the player are stand-in tables: levelsFor only reads mate.mjob/sjob/jobs, player:hasJob(0) and
-- player:getMainLvl().
-----------------------------------
local mnk, war, whm, nin = xi.job.MNK, xi.job.WAR, xi.job.WHM, xi.job.NIN

local function mate(mainLv, sjob, subLv, extra)
    sjob = sjob == nil and war or sjob
    local m = { mjob = mnk, sjob = sjob, jobs = { [mnk] = { level = mainLv } } }
    if sjob ~= 0 and subLv then
        m.jobs[sjob] = { level = subLv }
    end

    for job, entry in pairs(extra or {}) do
        m.jobs[job] = entry
    end

    return m
end

-- hasSupport: the player finished the support job quest (hasJob(0)); mainLv: the player's main level
local function player(hasSupport, mainLv)
    return
    {
        hasJob = function(_, job)
            return job == 0 and hasSupport
        end,

        getMainLvl = function()
            return mainLv or 1
        end,
    }
end

local unlocked = player(true, 75)

-- "main/sub job id/sub level"
local function says(m, cap, p)
    local main, sub, subLevel = xi.squad.levelsFor(m, cap, p == nil and unlocked or p)
    return string.format('%d/%d/%d', main, sub, subLevel)
end

-- The player rule (CBattleEntity::SetSLevel) for a sub job of its own level slvl
local function playerSub(ratio, mlvl, slvl)
    if ratio == 0 then
        return 0
    end

    local cap = ratio == 1 and math.floor(mlvl / 2) or ratio == 2 and math.floor(mlvl * 2 / 3) or mlvl
    if slvl > cap then
        return mlvl == 1 and 1 or cap
    end

    return slvl
end

describe('Squad support job levels', function()
    local savedRatio

    before_each(function()
        assert(type(xi.squad) == 'table' and type(xi.squad.levelsFor) == 'function', 'xi.squad.levelsFor is not loaded')
        savedRatio = xi.settings.map.SUBJOB_RATIO
    end)

    after_each(function()
        xi.settings.map.SUBJOB_RATIO = savedRatio
    end)

    it('gives a main level 1 mate a level 1 support job with every SUBJOB_RATIO but 0', function()
        for _, ratio in ipairs({ 0, 1, 2, 3 }) do
            xi.settings.map.SUBJOB_RATIO = ratio
            local want = ratio == 0 and string.format('1/0/0') or string.format('1/%d/1', war)
            assert(says(mate(1, war, 1)) == want, string.format('MNK1/WAR1, ratio %d: %s, got %s', ratio, want, says(mate(1, war, 1))))
            assert(says(mate(1, war, nil)) == want, string.format('MNK1 with WAR never levelled, ratio %d: %s, got %s', ratio, want, says(mate(1, war, nil))))
        end

        xi.settings.map.SUBJOB_RATIO = nil
        assert(says(mate(1, war, 1)) == string.format('1/%d/1', war), 'SUBJOB_RATIO not set (half): MNK1/WAR1, got ' .. says(mate(1, war, 1)))
    end)

    it('gives a level 1 support job under a Level Sync to 1', function()
        xi.settings.map.SUBJOB_RATIO = 1
        assert(says(mate(30, war, 30), 1) == string.format('1/%d/1', war), 'MNK30 synced to 1: MNK1/WAR1, got ' .. says(mate(30, war, 30), 1))
    end)

    it('keeps the normal progression and the support job\'s own level', function()
        local cases =
        {
            { 1, 2, '2/1/1' }, { 1, 3, '3/1/1' }, { 1, 4, '4/1/2' }, { 1, 75, '75/1/37' },
            { 2, 2, '2/1/1' }, { 2, 3, '3/1/2' }, { 2, 75, '75/1/50' },
            { 3, 2, '2/1/2' }, { 3, 3, '3/1/3' }, { 3, 75, '75/1/75' },
        }
        for _, c in ipairs(cases) do
            xi.settings.map.SUBJOB_RATIO = c[1]
            local want = c[3]:gsub('/1/', '/' .. war .. '/', 1)
            assert(says(mate(c[2], war, 75)) == want, string.format('ratio %d, MNK%d with WAR75: %s, got %s', c[1], c[2], want, says(mate(c[2], war, 75))))
        end

        xi.settings.map.SUBJOB_RATIO = 0
        assert(says(mate(75, war, 75)) == '75/0/0', 'ratio 0, MNK75: no support job, got ' .. says(mate(75, war, 75)))
        for _, ratio in ipairs({ 1, 2, 3 }) do
            xi.settings.map.SUBJOB_RATIO = ratio
            assert(says(mate(75, war, 20)) == string.format('75/%d/20', war), string.format('ratio %d, MNK75 with WAR20: the support job\'s own level, got %s', ratio, says(mate(75, war, 20))))
        end
    end)

    it('gives no support job while support jobs are locked or none is chosen', function()
        xi.settings.map.SUBJOB_RATIO = 1
        local locked = player(false, 10)
        assert(says(mate(1, war, 1), nil, locked) == '1/0/0', 'support jobs locked, everything below 18: none, got ' .. says(mate(1, war, 1), nil, locked))
        assert(says(mate(18, war, 1), nil, locked) == string.format('18/%d/1', war), 'the mate\'s main job at 18 unlocks it')
        assert(says(mate(1, war, 1, { [whm] = { level = 18 } }), nil, locked) == string.format('1/%d/1', war), 'any of the mate\'s jobs at 18 unlocks it')
        assert(says(mate(1, war, 1), nil, player(false, 18)) == string.format('1/%d/1', war), 'the player at main level 18 unlocks it')
        assert(says(mate(1, 0, nil)) == '1/0/0' and says(mate(40, 0, nil)) == '40/0/0', 'no support job chosen: none')
        assert(says(mate(1, mnk, 1)) == '1/0/0', 'support job = main job: none')
        assert(says(mate(1, nin, 1)) == string.format('1/%d/1', nin), 'an advanced job already saved as the support job: level 1')
    end)

    it('matches the player rule for every main level 1-75, support level 1-75 and ratio 0-3', function()
        local mismatch = {}
        for _, ratio in ipairs({ 0, 1, 2, 3 }) do
            xi.settings.map.SUBJOB_RATIO = ratio
            for m = 1, 75 do
                for s = 1, 75 do
                    local _, sub, subLevel = xi.squad.levelsFor(mate(m, war, s), nil, unlocked)
                    local want             = playerSub(ratio, m, s)
                    if
                        (want == 0 and sub ~= 0) or
                        (want > 0 and (sub ~= war or subLevel ~= want))
                    then
                        if #mismatch < 8 then
                            table.insert(mismatch, string.format('ratio %d MNK%d WAR%d: %d, player %d', ratio, m, s, subLevel, want))
                        end
                    end
                end
            end
        end

        assert(#mismatch == 0, 'differs from the player rule: ' .. table.concat(mismatch, '; '))
    end)
end)
