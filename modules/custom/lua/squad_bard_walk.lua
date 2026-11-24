-----------------------------------
-- Squad BARD WALK (Jon + Deed, 2026-11-21): fresh start, movement only. Songs stay Hurami's / Gambits'.
-- While you fight, a squad bard walks to her song spot and stands there (the same rules as the Bard write-up). First stop: next to the DDs and the tank.
--   party has casters   behind the casters, on their far side from the foe, at least `safe` yalms from the foe, pulled in until
--                       every caster is within `range` yalms (songs reach about 9 to 10)
--   no casters          the party middle, at least `mid` yalms from the foe
--                       (retail area range: and where every fighter is within `range` of her, so each one hears the song)
-- Out of a fight she is released to the stock AI.
-- Check it: !bard debug prints where she goes and how far; (debug on) if she does not close in for 5 passes it says NOT MOVING and what holds her.
--   Automatic: it starts by itself when a bard mate is switched on (Actions ON in the Squads window, or the actions pass).
--   !bard on | off | debug | (nothing = status)      `!bard off` keeps it off until `!bard on`.
--   Tune live: SQUAD_BARD_WALK.cfg.safe = 14, .behind = 3, .range = 9
-- One owner: this file only walks. It does not engage, cast, or touch auto attack. TRUST_DISTANCE = NO_MOVE is held while she
-- walks/stands so the stock controller does not pull her back; the old value is restored the moment the fight ends.
-- One init.txt line: custom/lua/squad_bard_walk.lua
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('squad_bard_walk')

SQUAD_BARD_WALK = SQUAD_BARD_WALK or {}
local W = SQUAD_BARD_WALK
W.cfg = W.cfg or {}
-- (v0.3.3a) mageSwitch is ON by default: a party with casters gets the caster spot (the group switch below). SQUAD_BARD_WALK.cfg.mageSwitch = false puts a bard back beside the fighters only.
for k, v in pairs({ safe = 14, behind = 3, range = 9, mid = 5, arrive = 1.5, every = 1000, stuck = 5, mageSwitch = true, retarget = 5, castGate = true }) do
    if W.cfg[k] == nil then W.cfg[k] = v end
end
local C = W.cfg
local BRD = 10
local MAGE_JOBS = { [3] = true, [4] = true, [5] = true, [15] = true, [20] = true, [21] = true } -- WHM BLM RDM SMN SCH GEO

local function flat(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function hold(mob, on)
    local held = mob:getLocalVar('SQUAD_BW_HELD') == 1
    if on and not held then
        local noMove = xi.trust and xi.trust.movementType and xi.trust.movementType.NO_MOVE
        if noMove == nil then return end
        mob:setLocalVar('SQUAD_BW_PREV', mob:getMobMod(xi.mobMod.TRUST_DISTANCE))
        mob:setLocalVar('SQUAD_BW_HELD', 1)
        pcall(function() mob:setMobMod(xi.mobMod.TRUST_DISTANCE, noMove) end)
    elseif not on and held then
        mob:setLocalVar('SQUAD_BW_HELD', 0)
        pcall(function() mob:setMobMod(xi.mobMod.TRUST_DISTANCE, mob:getLocalVar('SQUAD_BW_PREV')) end)
    end
end

-- casting stops a walking mate, so she does not cast until she has arrived: walk first, then songs.
local function castGate(mob, canCast)
    if C.castGate == false then return end
    local blocked = mob:getLocalVar('SQUAD_BW_NOCAST') == 1
    if canCast and blocked then
        mob:setLocalVar('SQUAD_BW_NOCAST', 0)
        if mob:getLocalVar('SQUAD_ACT_OFF') ~= 1 then       -- Actions OFF keeps casting off by itself
            pcall(function() mob:setMagicCastingEnabled(true) end)
        end
    elseif not canCast and not blocked then
        mob:setLocalVar('SQUAD_BW_NOCAST', 1)
        pcall(function() mob:setMagicCastingEnabled(false) end)
    end
end

-- XI: Forever Offline: is the song reach checked? Songs reach only the members inside their radius when the area range is retail
-- (map.TRUST_AOE_RANGE, the default); on 'extended' (the stock server) every mate hears every song, so the walk stays as it was.
-- Tune live: SQUAD_BARD_WALK.cfg.songReach = false (never check)
function W.reachOn()
    if C.songReach == false then return false end
    local ok, v = pcall(function() return xi.settings.map.TRUST_AOE_RANGE end)
    return not (ok and v == 'extended')
end

-- Where to stand so that every fighter in `pool` is within `range` of her, as close as possible to `s0` (the spot she would
-- take anyway) and not nearer the foe than `mid`. nil = `s0` already reaches everyone, nothing to change. When no spot reaches
-- everyone (the fighters are spread wider than two songs), the spot that keeps the farthest one nearest (still outside `mid`
-- when she can) is taken: she sings to as many as she can, never worse than the centroid.
function W.reachSpot(pool, fp, s0)
    local pts = {}
    for _, p in ipairs(pool) do pts[#pts + 1] = p:getPos() end
    if #pts == 0 then return nil end

    local function worst(s)
        local w = 0
        for _, q in ipairs(pts) do
            local dd = flat(s, q)
            if dd > w then w = dd end
        end

        return w
    end

    local R = C.range
    if worst(s0) <= R then return nil end

    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(pts) do
        x0, x1 = math.min(x0, q.x), math.max(x1, q.x)
        z0, z1 = math.min(z0, q.z), math.max(z1, q.z)
    end

    local bestIn, bestInD = nil, math.huge   -- reaches everyone, outside `mid`: the one nearest to s0
    local bestAny, bestAnyW = nil, math.huge -- the smallest farthest distance, outside `mid`
    local bestFree, bestFreeW = nil, math.huge -- the same without the `mid` limit
    local step = 1
    local x = x0 - R
    while x <= x1 + R do
        local z = z0 - R
        while z <= z1 + R do
            local s = { x = x, z = z }
            local w = worst(s)
            if flat(s, fp) >= C.mid then
                if w <= R then
                    local dd = flat(s, s0)
                    if dd < bestInD then bestIn, bestInD = s, dd end
                end

                if w < bestAnyW then bestAny, bestAnyW = s, w end
            elseif w < bestFreeW then
                bestFree, bestFreeW = s, w
            end

            z = z + step
        end

        x = x + step
    end

    return bestIn or bestAny or bestFree
end

-- the spot: group 0 = next to the fighters (the DDs and the tank): where she goes first and sings March and Minuet.
--            group 1 = behind the casters: only while a caster is low on MP (Ballad), then she returns to the fighters.
function W.spot(bard, others, foe, group)
    if #others == 0 then return nil end
    local mages, fighters = {}, {}
    for _, p in ipairs(others) do
        if MAGE_JOBS[p:getMainJob()] then mages[#mages + 1] = p else fighters[#fighters + 1] = p end
    end

    local pool = (group == 1 and #mages > 0) and mages or (#fighters > 0 and fighters or others)
    local sx, sz = 0, 0
    for _, p in ipairs(pool) do
        local q = p:getPos()
        sx, sz = sx + q.x, sz + q.z
    end

    local c = { x = sx / #pool, z = sz / #pool }
    local fp = foe:getPos()
    local d = flat(c, fp)
    if d < 0.1 then return nil end

    local ux, uz = (c.x - fp.x) / d, (c.z - fp.z) / d
    if group ~= 1 or #mages == 0 then
        -- beside the fighters, never closer to the foe than `mid`; and, under the retail area range, where every fighter is
        -- inside the song's reach when the party allows it (a song lands only on members within `range` of her)
        local s0 = d >= C.mid and c or { x = fp.x + ux * C.mid, z = fp.z + uz * C.mid }
        if W.reachOn() then
            local s = W.reachSpot(pool, fp, s0)
            if s ~= nil then return s end
        end

        return s0
    end

    local function ok(s)
        for _, p in ipairs(pool) do
            if flat(s, p:getPos()) > C.range then return false end
        end
        return true
    end

    local want = math.max(C.safe, d + C.behind)
    local s = { x = fp.x + ux * want, z = fp.z + uz * want }
    while not ok(s) and want > d do
        want = want - 1
        s = { x = fp.x + ux * want, z = fp.z + uz * want }
    end

    return s
end

-- which group she sings to now: casters low on MP (under 35 percent) call for Ballad; she goes back to the fighters when all are over 60
local function pickGroup(bard, others)
    local force = bard:getLocalVar('SQUAD_BW_FORCE')   -- set by `!bard go mages|fighters|auto`
    if force == 1 or force == 2 then
        local g = force == 1 and 1 or 0
        bard:setLocalVar('SQUAD_BW_GRP', g)
        return g
    end

    if not C.mageSwitch then
        bard:setLocalVar('SQUAD_BW_GRP', 0)
        return 0          -- Squads: movement only, always beside the fighters. The mage/Ballad switch is built in Gambits.
    end

    local grp = bard:getLocalVar('SQUAD_BW_GRP')
    local low, allOk = false, true
    for _, p in ipairs(others) do
        if MAGE_JOBS[p:getMainJob()] then
            local mp = p:getMPP()
            if mp < 35 then low = true end
            if mp < 60 then allOk = false end
        end
    end

    if grp == 0 and low then grp = 1 elseif grp == 1 and allOk then grp = 0 end
    bard:setLocalVar('SQUAD_BW_GRP', grp)
    return grp
end

local function step(player)
    local foe = player:isEngaged() and player:getTarget() or nil
    local party = {}
    local ok, all = pcall(function() return player:getPartyWithTrusts() end)
    for _, e in pairs(ok and all or {}) do party[#party + 1] = e end

    for _, bard in ipairs(party) do
        if bard:getObjType() == xi.objType.TRUST and bard:getLocalVar('SQUAD_ID') ~= 0 and bard:getMainJob() == BRD then
            if foe == nil or not bard:isAlive() or bard:getZoneID() ~= player:getZoneID() or bard:getLocalVar('SQUAD_ACT_OFF') == 1 or (tonumber(player:getCharVar('ADDON_OWN_' .. bard:getLocalVar('SQUAD_ID'))) or 0) > 0 then -- SQUAD_GUARD v1 bard_walk_gate
                hold(bard, false)
                castGate(bard, true)
                bard:setLocalVar('SQUAD_BW_HAS', 0)
                bard:setLocalVar('SQUAD_BW_LAST', 0)
                bard:setLocalVar('SQUAD_BW_STUCK', 0)
            else
                local others = {}
                for _, e in ipairs(party) do
                    if e ~= bard and e:isAlive() then others[#others + 1] = e end
                end

                local grp = pickGroup(bard, others)
                local s = W.spot(bard, others, foe, grp)
                if s ~= nil then
                    -- sticky: keep the spot she already has unless the new one is far from it (C.retarget yalms)
                    -- or the foe changed. Stops her chasing a point that drifts as the party shuffles.
                    local kx, kz = bard:getLocalVar('SQUAD_BW_SX') / 10, bard:getLocalVar('SQUAD_BW_SZ') / 10
                    local kf = bard:getLocalVar('SQUAD_BW_FOE')
                    if bard:getLocalVar('SQUAD_BW_HAS') == 1 and kf == foe:getID() and flat({ x = kx, z = kz }, s) < C.retarget then
                        s = { x = kx, z = kz }
                    else
                        bard:setLocalVar('SQUAD_BW_HAS', 1)
                        bard:setLocalVar('SQUAD_BW_SX', math.floor(s.x * 10))
                        bard:setLocalVar('SQUAD_BW_SZ', math.floor(s.z * 10))
                        bard:setLocalVar('SQUAD_BW_FOE', foe:getID())
                    end

                    hold(bard, true)
                    local me = bard:getPos()
                    local togo = flat(me, s)
                    if togo > C.arrive + 2 then castGate(bard, false) elseif togo <= C.arrive then castGate(bard, true) end
                    if togo > C.arrive then
                        pcall(function()
                            if xi.navguard then xi.navguard.pathTo(bard, s.x, me.y, s.z) else bard:pathTo(s.x, me.y, s.z) end
                        end)
                    end

                    -- one log line every 5 s (xi_map.log): where everyone is, so a wrong spot can be read afterwards
                    if os.time() - bard:getLocalVar('SQUAD_BW_LOG') >= 5 then
                        bard:setLocalVar('SQUAD_BW_LOG', os.time())
                        local fp = foe:getPos()
                        local parts = {}
                        for _, e in ipairs(others) do
                            local q = e:getPos()
                            parts[#parts + 1] = string.format('%s(job %d) %.0f,%.0f d_foe %.0f', e:getPacketName(), e:getMainJob(), q.x, q.z, flat(q, fp))
                        end

                        print(string.format('[bard walk] %s group %d at %.0f,%.0f  spot %.0f,%.0f (%.1f to go)  foe %.0f,%.0f  party: %s',
                            bard:getPacketName(), grp, me.x, me.z, s.x, s.z, togo, fp.x, fp.z, table.concat(parts, '; ')))
                    end

                    -- is something else moving her? she should close in on the spot; if not for `stuck` passes, say so
                    local last = bard:getLocalVar('SQUAD_BW_LAST')
                    local now = togo * 10
                    if togo > C.arrive and last ~= 0 and now >= last - 3 then
                        bard:setLocalVar('SQUAD_BW_STUCK', bard:getLocalVar('SQUAD_BW_STUCK') + 1)
                    else
                        bard:setLocalVar('SQUAD_BW_STUCK', 0)
                    end

                    bard:setLocalVar('SQUAD_BW_LAST', math.floor(now))
                    if W.debug then -- (2026-11-22, Meli, PTgamerguy: the NOT MOVING line showed without !bard debug)
                        player:printToPlayer(string.format('[bard] %s -> %.0f,%.0f  %.1f yalms to go%s', bard:getPacketName(), s.x, s.z, togo,
                            bard:getLocalVar('SQUAD_BW_STUCK') >= C.stuck
                                and string.format('  NOT MOVING (TRUST_DISTANCE=%s, idle=%s): wall, or something else is moving her',
                                    tostring(bard:getMobMod(xi.mobMod.TRUST_DISTANCE)), tostring(bard:getLocalVar('SQUAD_IDLE'))) or ''))
                    end
                end
            end
        end
    end
end

-- start the walking loop for this player (once). `!bard off` sets the var to 2: stays off until `!bard on`.
function W.ensure(player)
    if player == nil or player:getCharVar('SQUAD_BARD_WALK') == 2 then
        return
    end

    player:setCharVar('SQUAD_BARD_WALK', 1)
    if os.time() - player:getLocalVar('SQUAD_BW_RUN') > 3 then
        player:timer(C.every, W.loop)
    end
end

local function loop(player)
    if player == nil or player:getCharVar('SQUAD_BARD_WALK') ~= 1 then
        return
    end

    player:setLocalVar('SQUAD_BW_RUN', os.time())
    pcall(step, player)
    player:timer(C.every, loop)
end

W.loop = loop

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    super(player, firstLogin, zoning)
    player:timer(5000, function(playerArg)
        W.ensure(playerArg)
    end)
end)

if xi ~= nil and xi.module ~= nil and xi.module.registerCommand ~= nil then
    pcall(function()
        local command = { cmdprops = { permission = 0, parameters = 's' } }
        command.onTrigger = function(player, arg)
            local word = string.lower(string.match(tostring(arg or ''), '^%s*(%S*)') or '')
            if word == 'on' then
                player:setCharVar('SQUAD_BARD_WALK', 0)
                W.ensure(player)
                player:printToPlayer('[bard] walking ON')
            elseif word == 'off' then
                player:setCharVar('SQUAD_BARD_WALK', 2)
                pcall(function()
                    for _, e in pairs(player:getPartyWithTrusts()) do
                        if e:getObjType() == xi.objType.TRUST then hold(e, false); castGate(e, true) end
                    end
                end)
                player:printToPlayer('[bard] walking off, released')
            elseif word == 'go' then
                local where = string.lower(string.match(tostring(arg or ''), '^%s*%S+%s+(%S+)') or '')
                local v = (where == 'mages' and 1) or (where == 'fighters' and 2) or 0
                pcall(function()
                    for _, e in pairs(player:getPartyWithTrusts()) do
                        if e:getObjType() == xi.objType.TRUST and e:getMainJob() == BRD then
                            e:setLocalVar('SQUAD_BW_FORCE', v)
                            e:setLocalVar('SQUAD_BW_HAS', 0)
                        end
                    end
                end)
                player:printToPlayer('[bard] go ' .. (v == 1 and 'mages' or v == 2 and 'fighters' or 'auto (by caster MP)'))
            elseif word == 'debug' then
                W.debug = not W.debug
                player:printToPlayer('[bard] debug ' .. tostring(W.debug))
            else
                player:printToPlayer('[bard] ' .. (player:getCharVar('SQUAD_BARD_WALK') == 1 and 'ON' or 'off') .. '   (!bard on | off | debug)')
            end
        end

        xi.module.registerCommand('bard', command)
    end)
end

return m
