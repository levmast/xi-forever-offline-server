-----------------------------------
-- XI: Forever Offline: the look of a squad mate is sent again a few seconds after it comes out (squad.lua callMate ->
-- SquadRefreshLook in modules/custom/cpp/squad.cpp). That entity update (0x00E) announces position, claim, general data and
-- the look (send flags 0x57), so all of them have to be in it.
--
-- (2026-11-24, Ricc: "they disappear entirely when you set camp here") with the look alone in the server's mask, a mate that
-- stood still went out with the position 0, 0, 0 and 0% HP.
--
-- The test client keeps every packet in its queue and the server folds an update into a queued one for the same entity, so
-- the queue is emptied before each update that is read here.
-----------------------------------
local ffi = require('ffi')

local squadSlot = 0

-- send flags of 0x00E (entity_update.cpp sendflags_t)
local FLAG_POSITION = 0x01
local FLAG_GENERAL  = 0x04
local FLAG_MODEL    = 0x10
local LOOK_REFRESH  = 0x57 -- position + claim + general + model + the long name

local function squadApi(name)
    local fn = rawget(_G, name)
    assert(type(fn) == 'function', 'the squad module function ' .. name .. ' is missing')
    return fn
end

local function squadCommand()
    for _, entry in ipairs(xi.module.commandRegistry or {}) do
        if entry.name == 'squad' then
            return entry.command
        end
    end

    return xi.commands and xi.commands.squad
end

local function spawnPlayer(job)
    local player = xi.test.world:spawnPlayer({ zone = xi.zone.WEST_RONFAURE, job = job or xi.job.WAR, level = 75, race = xi.race.HUME_M })
    player:setUnkillable(true)
    return player
end

local function saveMate(player, job)
    squadSlot = squadSlot + 1
    local id = squadApi('SaveSquadMate')(player:getID(), squadSlot, { name = 'Look' .. squadSlot, race = xi.race.HUME_M, face = 0, nation = 0, mjob = job, sjob = 0, template = 0 })
    assert(id ~= nil and id > 0, 'no squad record')
    return id, squadSlot
end

-- a mate spawned directly (no callMate, so no timers of its own)
local function spawnMate(player, job)
    local id   = saveMate(player, job)
    local mate = squadApi('SpawnSquadMate')(player, { id = id, mjob = job, sjob = 0, mlevel = 75, slevel = 0, template = 0, race = xi.race.HUME_M, face = 0, equip = { [xi.slot.MAIN] = xi.item.HEAVY_AXE } })
    assert(mate ~= nil, 'the squad mate was not spawned')
    mate:renameEntity('Look' .. squadSlot, true) -- (as callMate does: every squad mate in play carries its own name)
    mate:setLocalVar('SQUAD_ID', id)
    xi.test.world:tickEntity(player)
    xi.test.world:skipTime(2)

    return mate
end

local function squadMates(player)
    local out = {}
    for _, member in ipairs(player:getPartyWithTrusts()) do
        if member:isTrust() and member:getLocalVar('SQUAD_ID') > 0 then
            out[#out + 1] = member
        end
    end

    return out
end

local function u16(data, at)
    return data[at] + data[at + 1] * 0x100
end

local function u32(data, at)
    return u16(data, at) + u16(data, at + 2) * 0x10000
end

local function f32(data, at)
    local bytes = ffi.new('uint8_t[4]', data[at], data[at + 1], data[at + 2], data[at + 3])
    return ffi.cast('float*', bytes)[0]
end

local function bytes(data, from, count)
    local out = {}
    for i = 0, count - 1 do
        out[#out + 1] = string.format('%02X', data[from + i] or 0)
    end

    return table.concat(out)
end

local function text(data, from, max)
    local s = ''
    for i = 0, max - 1 do
        local byte = data[from + i]
        if byte == nil or byte == 0 then
            break
        end

        s = s .. string.char(byte)
    end

    return s
end

-- the entity updates (0x00E) for this entity in the client's queue
local function updatesFor(player, entity)
    local out = {}
    for _, pkt in ipairs(player.packets:getIncoming()) do
        if pkt.type == 0x00E and u32(pkt.data, 0x04) == entity:getID() then
            out[#out + 1] =
            {
                size   = pkt.size,
                flags  = pkt.data[0x0A],
                x      = f32(pkt.data, 0x0C),
                y      = f32(pkt.data, 0x10),
                z      = f32(pkt.data, 0x14),
                speed  = pkt.data[0x1C],
                hpp    = pkt.data[0x1E],
                status = pkt.data[0x20],
                side   = pkt.data[0x29],
                look   = bytes(pkt.data, 0x30, 20),
                name   = text(pkt.data, 0x44, 16),
            }
        end
    end

    return out
end

local function withLook(updates)
    local out = {}
    for _, update in ipairs(updates) do
        if bit.band(update.flags, FLAG_MODEL) ~= 0 then
            out[#out + 1] = update
        end
    end

    return out
end

local function near(a, b)
    return math.abs(a - b) < 0.01
end

local function describeUpdate(update)
    return string.format('flags 0x%02X pos %.2f %.2f %.2f hp %d%% status %d side %d size %d name "%s"',
        update.flags, update.x, update.y, update.z, update.hpp, update.status, update.side, update.size, update.name)
end

-- what the flags announce is in the packet: where the entity is, and its HP
local function assertWhole(update, entity, what)
    local line = describeUpdate(update)
    assert(update.flags == LOOK_REFRESH, what .. ': the look update does not have the send flags 0x57 (' .. line .. ')')
    assert(bit.band(update.flags, FLAG_POSITION) ~= 0 and bit.band(update.flags, FLAG_GENERAL) ~= 0, what .. ': flags (' .. line .. ')')
    assert(near(update.x, entity:getXPos()) and near(update.y, entity:getYPos()) and near(update.z, entity:getZPos()),
        string.format('%s: the packet announces a position but carries %.2f %.2f %.2f, the mate is at %.2f %.2f %.2f',
            what, update.x, update.y, update.z, entity:getXPos(), entity:getYPos(), entity:getZPos()))
    assert(not (update.x == 0 and update.y == 0 and update.z == 0), what .. ': the position is 0, 0, 0')
    assert(update.hpp == entity:getHPP() and update.hpp > 0, string.format('%s: the packet announces general data but carries %d%% HP, the mate has %d%%', what, update.hpp, entity:getHPP()))
end

-- the part that keeps a mate dressed is intact: the long layout with the whole equipped look (20 bytes at 0x30: model type 1,
-- face, race, then head, body, hands, legs, feet, main, sub, ranged) and the mate's name after it, not inside it
local function assertLookWhole(update, mate, what)
    local name    = mate:getPacketName()
    local nameHex = ''
    for i = 1, #name do
        nameHex = nameHex .. string.format('%02X', name:byte(i))
    end

    assert(update.size == 0x58, string.format('%s: the look update is not the long layout (size %d)', what, update.size))
    assert(update.look:sub(1, 4) == '0100', what .. ': the look is not an equipped model (' .. update.look .. ')')
    assert(update.look:sub(29, 32) ~= '0000', what .. ': the main weapon is missing from the look (' .. update.look .. ')')
    assert(update.name == name, string.format('%s: the name after the look is "%s", the mate is "%s"', what, update.name, name))
    assert(not string.find(update.look, nameHex, 1, true), what .. ': the name was written into the look (' .. update.look .. ')')
    assert(update.status == xi.status.NORMAL, what .. ': status ' .. update.status)
    assert(update.side == xi.allegiance.PLAYER, what .. ': allegiance ' .. update.side)
end

describe('Squad look refresh', function()
    local refresh

    before_each(function()
        refresh = squadApi('SquadRefreshLook')
    end)

    it('a mate standing still: the update carries its position and HP', function()
        local player = spawnPlayer()
        local mate   = spawnMate(player, xi.job.WAR)

        assert(#updatesFor(player, mate) > 0, 'the client was not sent the mate')

        -- nothing else pending: the mate has stood still for a while
        xi.test.world:skipTime(3)
        player.packets:clear()
        xi.test.world:skipTime(1)
        assert(#withLook(updatesFor(player, mate)) == 0, 'a look update went out without a refresh')

        player.packets:clear()
        assert(refresh(mate) == true, 'SquadRefreshLook refused a squad mate')
        xi.test.world:skipTime(1)

        local looks = withLook(updatesFor(player, mate))
        assert(#looks == 1, string.format('expected one look update, got %d', #looks))
        assertWhole(looks[1], mate, 'standing still')

        assertLookWhole(looks[1], mate, 'standing still')

        -- and again: the same packet every time
        player.packets:clear()
        assert(refresh(mate) == true)
        xi.test.world:skipTime(1)
        local again = withLook(updatesFor(player, mate))
        assert(#again == 1 and again[1].look == looks[1].look and again[1].name == looks[1].name, 'a second refresh is not the same look and name')
    end)

    it('a mate that moved in the same tick: the update carries the new position', function()
        local player = spawnPlayer()
        local mate   = spawnMate(player, xi.job.WAR)
        xi.test.world:skipTime(3)

        player.packets:clear()
        mate:setPos(mate:getXPos() + 3, mate:getYPos(), mate:getZPos() + 2)
        assert(refresh(mate) == true, 'SquadRefreshLook refused a squad mate')
        xi.test.world:skipTime(1)

        local looks = withLook(updatesFor(player, mate))
        assert(#looks >= 1, 'no look update for the mate that moved')
        assertWhole(looks[#looks], mate, 'moving')
    end)

    it('a hurt mate: the update carries its real HP', function()
        local player = spawnPlayer()
        local mate   = spawnMate(player, xi.job.WAR)
        mate:setHP(math.floor(mate:getMaxHP() / 2))
        xi.test.world:skipTime(3)

        player.packets:clear()
        assert(refresh(mate) == true)
        xi.test.world:skipTime(1)

        local looks = withLook(updatesFor(player, mate))
        assert(#looks == 1, string.format('expected one look update, got %d', #looks))
        assertWhole(looks[1], mate, 'hurt')
        assert(looks[1].hpp < 100, 'the HP in the packet is not the mate\'s')
    end)

    it('a called mate gets the refresh about 4 and 10 seconds after it comes out, each one whole', function()
        local player   = spawnPlayer()
        local _, slot  = saveMate(player, xi.job.WAR)
        local command  = squadCommand()
        assert(command and type(command.onTrigger) == 'function', 'the !squad command is not registered')

        command.onTrigger(player, 'call', tostring(slot))
        xi.test.world:tickEntity(player)

        local mates = squadMates(player)
        assert(#mates == 1, string.format('!squad call %d brought %d mates', slot, #mates))
        local mate = mates[1]

        -- one second at a time, by the server's own clock; the queue is emptied each second so every update is its own packet
        local calledAt = xi.test.world:getSteadyTime()
        local seen     = {}
        local looks    = {}
        for _ = 1, 16 do
            player.packets:clear()
            xi.test.world:skipTime(1)
            local elapsed = xi.test.world:getSteadyTime() - calledAt
            for _, update in ipairs(withLook(updatesFor(player, mate))) do
                if elapsed > 2 then -- (before that: the spawn itself)
                    seen[#seen + 1]   = string.format('%.1f', elapsed)
                    looks[#looks + 1] = update
                    assertWhole(update, mate, 'refresh at ' .. seen[#seen] .. ' s')
                end
            end
        end

        local list = table.concat(seen, ', ')
        assert(#seen == 2, string.format('expected the two refreshes (4 s and 10 s), saw %d at [%s] s', #seen, list))
        assert(tonumber(seen[1]) >= 4 and tonumber(seen[1]) <= 6, 'the first refresh is not at about 4 s: ' .. list)
        assert(tonumber(seen[2]) >= 10 and tonumber(seen[2]) <= 12, 'the second refresh is not at about 10 s: ' .. list)
        assert(looks[1].look == looks[2].look and looks[1].name == mate:getPacketName() and looks[2].name == mate:getPacketName(), 'the two refreshes differ')
        assert(looks[1].size == 0x58 and looks[1].look:sub(1, 4) == '0100', 'the refresh is not the long equipped layout')
    end)

    it('a called mate at a camp keeps its place through both refreshes', function()
        local player   = spawnPlayer()
        local _, slot  = saveMate(player, xi.job.WAR)
        local command  = squadCommand()

        command.onTrigger(player, 'camp') -- camp here
        command.onTrigger(player, 'call', tostring(slot))
        xi.test.world:tickEntity(player)

        local mate = squadMates(player)[1]
        assert(mate ~= nil, 'the mate did not come')
        assert(mate:getLocalVar('SQUAD_CAMP') == 1, 'the mate does not hold the camp')

        local refreshes = 0
        for second = 1, 14 do
            player.packets:clear()
            xi.test.world:skipTime(1)
            for _, update in ipairs(updatesFor(player, mate)) do
                -- no update of any kind may put the mate at the zone origin
                assert(bit.band(update.flags, FLAG_POSITION) == 0 or not (update.x == 0 and update.y == 0 and update.z == 0),
                    string.format('second %d: an update put the mate at 0, 0, 0 (%s)', second, describeUpdate(update)))
                if second > 1 and bit.band(update.flags, FLAG_MODEL) ~= 0 then
                    refreshes = refreshes + 1
                    assertWhole(update, mate, 'camp refresh at second ' .. second)
                end
            end
        end

        assert(refreshes == 2, string.format('expected two refreshes at the camp, saw %d', refreshes))
    end)

    it('an ordinary trust is not refreshed and its updates are unchanged', function()
        local player = spawnPlayer(xi.job.SMN)
        player:addSpell(xi.magic.spell.NAJI)
        player.actions:useSpell(player, xi.magic.spell.NAJI)
        xi.test.world:tickEntity(player)
        xi.test.world:skipTime(10)

        local naji = nil
        for _, member in ipairs(player:getPartyWithTrusts()) do
            if member:isTrust() then
                naji = member
            end
        end

        assert(naji ~= nil, 'Naji did not come')
        assert(naji:getLocalVar('SQUAD_ID') == 0)

        xi.test.world:skipTime(3)
        player.packets:clear()
        assert(refresh(naji) == false, 'SquadRefreshLook acted on an ordinary trust')
        xi.test.world:skipTime(1)
        assert(#updatesFor(player, naji) == 0, 'an ordinary trust standing still was sent an update')

        -- its own updates say what they carry, nothing more
        player.packets:clear()
        naji:setPos(naji:getXPos() + 3, naji:getYPos(), naji:getZPos())
        xi.test.world:skipTime(1)
        local updates = updatesFor(player, naji)
        assert(#updates >= 1, 'no update for the trust that moved')
        for _, update in ipairs(updates) do
            assert(bit.band(update.flags, FLAG_MODEL) == 0, 'an ordinary trust update carries the look flag (' .. describeUpdate(update) .. ')')
            assert(update.flags ~= LOOK_REFRESH)
            if bit.band(update.flags, FLAG_POSITION) ~= 0 then
                assert(near(update.x, naji:getXPos()) and near(update.z, naji:getZPos()), 'the trust position in the packet is wrong')
            end
        end
    end)
end)
