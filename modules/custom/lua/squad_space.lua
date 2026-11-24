-----------------------------------
-- Squad SPACE (from Jon Tanta's Squad Update, 2026-11-19; merged into XI: Forever Offline): every job knows how far from the foe it belongs.
--   * healers and casters stand back at a safe range (the engine's TRUST_DISTANCE takes a distance in yalms), so a foe that
--     swings, breathes or casts an area move at the front does not reach them
--   * melee stay on the foe (distance 0); archers and gunners at 12
--   * the bard has her own cycle in squad_adapt.lua (out to a song spot, sing, back to the foe)
--   * cramped places: if a mate cannot reach its range (a corridor, a small room), it notices that it is stuck and steps its range
--     down a few yalms at a time, down to a floor, instead of pushing at a wall; it tries the full range again every so often
--   * a healer also stays within cure reach of whoever the foe is on
--   * a range the player set with !squad range is always respected, and so is NON_COMBAT
-- squadTeamTick (squad.lua) calls SQUAD_SPACE.tick every second per mate. Lines are printed as "[space] ..."
-- Tune live: SQUAD_SPACE.base[3] = 12 (WHM range), SQUAD_SPACE.on = false (off)
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('squad_space')

SQUAD_SPACE = SQUAD_SPACE or {}
local S = SQUAD_SPACE
S.on     = true
S.debug  = false -- (true: a [space] line in the map log each time a mate's range changes)
S.stuck  = 4     -- seconds without progress before the range steps down
S.step   = 3     -- yalms per step down
S.retry  = 40    -- seconds before trying the full range again
S.cure   = 17    -- a healer stays within this many yalms of the foe's target (cure range is 20)

-- job id -> { preferred range, lowest range it will accept }
S.base = S.base or {
    [3]  = { 15, 8 },   -- WHM (same as BLM: they stand together)
    [4]  = { 15, 8 },   -- BLM (same as WHM)
    [5]  = { 9, 6 },    -- RDM
    [11] = { 12, 7 },   -- RNG
    [15] = { 15, 9 },   -- SMN
    [17] = { 10, 6 },   -- COR
    [20] = { 14, 8 },   -- SCH
    [21] = { 14, 8 },   -- GEO
}

-- XI: Forever Offline: jobs whose party effect has a short radius stand where it reaches the fighters. { range, lowest range, retail only }
-- A Corsair rolls 8 yalms around herself (standing 10 from the foe she reached nobody at the foe); a Geomancer's Indi / Geo aura is
-- 6 yalms plus the hitbox around her (14 from the foe it covered no one in the fight). The Corsair's reach only matters when party
-- effects obey their radius (map.TRUST_AOE_RANGE retail, the default), the aura always obeyed it. Off: SQUAD_SPACE.reach = false.
S.reach = S.reach ~= false
S.reachBase = S.reachBase or {
    [17] = { 6, 4, true },  -- COR
    [21] = { 5, 4, false }, -- GEO
}

local function areaRetail()
    local ok, v = pcall(function() return xi.settings.map.TRUST_AOE_RANGE end)
    return not (ok and v == 'extended')
end

-- the row of this job: the area reach row when it applies, else the usual one
S.rowFor = function(job)
    local r = S.reachBase[job]
    if S.reach and r ~= nil and (not r[3] or areaRetail()) then
        return r
    end

    return S.base[job]
end

local NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN' }

local function say(mob, text)
    if S.debug then
        print(string.format('[space] %s (%s): %s', mob:getPacketName(), NAMES[mob:getMainJob()] or '?', text))
    end
end

local function flat(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function playerChose(mob)
    local master = mob:getMaster()
    if master == nil then
        return false
    end

    local id = mob:getLocalVar('SQUAD_ID')
    local ok, v = pcall(function() return master:getCharVar('SQUAD_RANGE_' .. id) end)
    return ok and (v or 0) >= 1
end

S.tick = function(mob, boss, foe, fighting, now, level, job)
    local row = S.rowFor(job)
    if not S.on or row == nil then
        return
    end

    if not fighting or foe == nil then
        if mob:getLocalVar('SQUAD_SP_D') ~= 0 then
            mob:setLocalVar('SQUAD_SP_D', 0)
            mob:setLocalVar('SQUAD_SP_STUCK', 0)
        end

        return
    end

    if playerChose(mob) or mob:getMobMod(xi.mobMod.TRUST_DISTANCE) == xi.trust.movementType.NON_COMBAT then
        return
    end

    local want = mob:getLocalVar('SQUAD_SP_D')
    if want == 0 then
        want = row[1]
        mob:setLocalVar('SQUAD_SP_D', want)
        mob:setLocalVar('SQUAD_SP_AT', now)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, want)
        say(mob, string.format('holds %d yalms from %s', want, foe:getName()))
    end

    local me, fp = mob:getPos(), foe:getPos()
    local dist = flat(me, fp)

    -- a healer stays in cure reach of the one the foe is on
    if job == 3 then
        local tgt = foe:getTarget()
        if tgt ~= nil and tgt:isAlive() and tgt:getID() ~= mob:getID() and flat(me, tgt:getPos()) > S.cure and want > row[2] then
            want = math.max(row[2], want - 2)
            mob:setLocalVar('SQUAD_SP_D', want)
            mob:setMobMod(xi.mobMod.TRUST_DISTANCE, want)
            say(mob, string.format('moves in to %d yalms to stay in cure reach of %s', want, tgt:getName()))
        end
    end

    -- stuck test: well short of the range and not moving (a wall, a corridor, a crowd)
    local lx, lz = mob:getLocalVar('SQUAD_SP_X') / 10, mob:getLocalVar('SQUAD_SP_Z') / 10
    mob:setLocalVar('SQUAD_SP_X', math.floor(me.x * 10))
    mob:setLocalVar('SQUAD_SP_Z', math.floor(me.z * 10))
    local moved = math.sqrt((me.x - lx) ^ 2 + (me.z - lz) ^ 2)
    local stuck = mob:getLocalVar('SQUAD_SP_STUCK')
    if dist < want - 3 and moved < 0.5 then
        stuck = stuck + 1
    else
        stuck = 0
    end

    if stuck >= S.stuck and want > row[2] then
        want = math.max(row[2], want - S.step)
        mob:setLocalVar('SQUAD_SP_D', want)
        mob:setLocalVar('SQUAD_SP_AT', now)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, want)
        say(mob, string.format('cramped here: range down to %d yalms (floor %d)', want, row[2]))
        stuck = 0
    elseif want < row[1] and now - mob:getLocalVar('SQUAD_SP_AT') >= S.retry then
        want = math.min(row[1], want + S.step)
        mob:setLocalVar('SQUAD_SP_D', want)
        mob:setLocalVar('SQUAD_SP_AT', now)
        mob:setMobMod(xi.mobMod.TRUST_DISTANCE, want)
        say(mob, string.format('tries %d yalms again', want))
    end

    mob:setLocalVar('SQUAD_SP_STUCK', stuck)
end

return m
