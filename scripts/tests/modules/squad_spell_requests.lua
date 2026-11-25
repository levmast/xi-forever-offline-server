-----------------------------------
-- XI: Forever Offline: a spell asked for in party chat (modules/custom/lua/squad_logic.lua -> squad_requests.lua ->
-- SquadSpellKind / SquadCastSpell in modules/custom/cpp/squad.cpp).
--
-- (2026-11-24, Ricc: "/p Protectra II" was answered "it only takes the caster") A spell cast on the caster that reaches the
-- party around it (Protectra, Shellra, the Bar-ra spells, a Teleport, a song) has the valid target "self" in the spell table,
-- like Warp or Utsusemi. It is a request a mate can answer; a spell that only works on its caster still is not.
--
-- The lines are given to xi.squad.onChatCommand, the function squad.cpp calls with the decoded party chat line.
-----------------------------------
local squadSlot = 0

local SELF_ONLY_LINES = { 'only works on whoever casts it', 'it only takes the caster' }

local function squadApi(name)
    local fn = rawget(_G, name)
    assert(type(fn) == 'function', 'the squad module function ' .. name .. ' is missing')
    return fn
end

local function kind(spellId)
    return squadApi('SquadSpellKind')(spellId)
end

local function spawnPlayer()
    local player = xi.test.world:spawnPlayer({ zone = xi.zone.WEST_RONFAURE, job = xi.job.WAR, level = 75, race = xi.race.HUME_M })
    player:setUnkillable(true)
    return player
end

local function spawnMate(player, job, level)
    squadSlot = squadSlot + 1
    local name = 'Req' .. squadSlot
    local id   = squadApi('SaveSquadMate')(player:getID(), squadSlot, { name = name, race = xi.race.HUME_M, face = 0, nation = 0, mjob = job, sjob = 0, template = 0 })
    assert(id ~= nil and id > 0, 'no squad record')

    local mate = squadApi('SpawnSquadMate')(player, { id = id, mjob = job, sjob = 0, mlevel = level or 75, slevel = 0, template = 0, race = xi.race.HUME_M, face = 0, equip = {} })
    assert(mate ~= nil, 'the squad mate was not spawned')
    mate:renameEntity(name, true)
    mate:setLocalVar('SQUAD_ID', id)
    mate:setPos(player:getXPos() + 1, player:getYPos(), player:getZPos() + 1)
    xi.test.world:tickEntity(player)
    xi.test.world:skipTime(2)

    return mate
end

-- the party chat lines the server sent the player (0x017), with who said them
local function replies(player)
    local out = {}
    for _, pkt in pairs(player.packets:getIncoming()) do
        if pkt.type == 0x017 then
            local s = ''
            for i = 0, pkt.size - 24 do
                local byte = pkt.data[23 + i]
                if byte == nil or byte == 0 then
                    break
                end

                s = s .. string.char(byte)
            end

            local who = ''
            for i = 0, 14 do
                local byte = pkt.data[8 + i]
                if byte == nil or byte == 0 then
                    break
                end

                who = who .. string.char(byte)
            end

            out[#out + 1] = { who = who, text = s }
        end
    end

    return out
end

local function selfOnlyReply(player)
    for _, reply in ipairs(replies(player)) do
        for _, line in ipairs(SELF_ONLY_LINES) do
            if string.find(reply.text, line, 1, true) then
                return reply
            end
        end
    end

    return nil
end

local function allReplies(player)
    local out = {}
    for _, reply in ipairs(replies(player)) do
        out[#out + 1] = string.format('(%s) %s', reply.who, reply.text)
    end

    return table.concat(out, ' / ')
end

-- says the line in party chat, as squad.cpp hands it over, and lets the squad act for a while
local function ask(player, line, seconds)
    player.packets:clear()
    xi.squad.onChatCommand(player, line, false)
    for _ = 1, seconds or 8 do
        xi.test.world:skipTime(1)
    end
end

local function spellCounter(mate)
    local counter = { n = 0, last = 0 }
    mate:addListener('MAGIC_START', 'SQREQ_TEST_CAST', function(_, _, spell)
        counter.n    = counter.n + 1
        counter.last = spell:getID()
    end)

    return counter
end

describe('Squad spell requests', function()
    describe('what a spell can be cast on (SquadSpellKind)', function()
        local s = xi.magic.spell

        it('Protectra, Shellra, the Bar-ra spells: party', function()
            for _, id in ipairs({ s.PROTECTRA, s.PROTECTRA_II, s.PROTECTRA_III, s.PROTECTRA_IV, s.PROTECTRA_V,
                s.SHELLRA, s.SHELLRA_II, s.SHELLRA_III, s.SHELLRA_IV, s.SHELLRA_V,
                s.BARFIRA, s.BARBLIZZARA, s.BARAERA, s.BARSTONRA, s.BARTHUNDRA, s.BARWATERA,
                s.BARSLEEPRA, s.BARPOISONRA, s.BARPARALYZRA, s.BARBLINDRA, s.BARSILENCERA, s.BARPETRA, s.BARVIRA }) do
                assert(kind(id) == 'party', string.format('spell %d is "%s"', id, tostring(kind(id))))
            end
        end)

        it('Teleport and Escape: party', function()
            for _, id in ipairs({ s.TELEPORT_HOLLA, s.TELEPORT_DEM, s.TELEPORT_MEA, s.TELEPORT_ALTEP, s.TELEPORT_YHOAT, s.TELEPORT_VAHZL, s.ESCAPE }) do
                assert(kind(id) == 'party', string.format('spell %d is "%s"', id, tostring(kind(id))))
            end
        end)

        it('songs for the party: party; songs on an enemy: enemy', function()
            for _, id in ipairs({ s.MAGES_BALLAD, s.VALOR_MINUET, s.ARMYS_PAEON, s.ADVANCING_MARCH, s.KNIGHTS_MINNE }) do
                assert(kind(id) == 'party', string.format('song %d is "%s"', id, tostring(kind(id))))
            end

            for _, id in ipairs({ s.FOE_LULLABY, s.HORDE_LULLABY, s.FOE_REQUIEM }) do
                assert(kind(id) == 'enemy', string.format('song %d is "%s"', id, tostring(kind(id))))
            end
        end)

        it('spells that only work on their caster: self', function()
            for _, id in ipairs({ s.WARP, s.RERAISE, s.UTSUSEMI_ICHI, s.UTSUSEMI_NI, s.TONKO_ICHI, s.BLINK, s.STONESKIN, s.AQUAVEIL, s.BARFIRE, s.BLAZE_SPIKES, s.COCOON }) do
                assert(kind(id) == 'self', string.format('spell %d is "%s"', id, tostring(kind(id))))
            end
        end)

        it('single target party spells: party; Raise: dead', function()
            for _, id in ipairs({ s.CURE, s.CURE_IV, s.PROTECT, s.PROTECT_II, s.SHELL, s.HASTE, s.SNEAK, s.INVISIBLE, s.REGEN, s.ERASE, s.WARP_II, s.CURAGA }) do
                assert(kind(id) == 'party', string.format('spell %d is "%s"', id, tostring(kind(id))))
            end

            for _, id in ipairs({ s.RAISE, s.RAISE_II }) do
                assert(kind(id) == 'dead', string.format('spell %d is "%s"', id, tostring(kind(id))))
            end
        end)

        it('enemy spells, with or without an area: enemy', function()
            for _, id in ipairs({ s.STONE, s.STONEGA, s.STONEGA_II, s.SLEEP, s.SLEEPGA, s.SLEEPGA_II, s.DIA, s.DIAGA, s.BANISHGA }) do
                assert(kind(id) == 'enemy', string.format('spell %d is "%s"', id, tostring(kind(id))))
            end
        end)

        it('a spell that does not exist: empty', function()
            assert(kind(60000) == '', 'an unknown spell has a kind')
        end)

        it('every spell of the table has one of the four kinds (written to SQKIND_OUT when set)', function()
            local valid = { enemy = true, dead = true, party = true, self = true }
            local lines = {}
            local count = 0
            for id = 1, 1100 do
                local k = kind(id)
                if k ~= '' then
                    count = count + 1
                    assert(valid[k], string.format('spell %d has the kind "%s"', id, tostring(k)))
                    lines[#lines + 1] = string.format('%d|%s', id, k)
                end
            end

            assert(count > 500, 'the spell table was not read (' .. count .. ' spells)')
            local path = os.getenv('SQKIND_OUT')
            if path ~= nil and path ~= '' then
                local file = assert(io.open(path, 'w'))
                file:write(table.concat(lines, '\n'), '\n')
                file:close()
            end
        end)
    end)

    describe('asked in party chat', function()
        it('"protectra ii": the White Mage casts it, the Warrior asked first is not the answer', function()
            local player = spawnPlayer()
            local war    = spawnMate(player, xi.job.WAR)
            local whm    = spawnMate(player, xi.job.WHM)
            local warCasts, whmCasts = spellCounter(war), spellCounter(whm)

            ask(player, 'protectra ii')

            local refused = selfOnlyReply(player)
            assert(refused == nil, 'answered as a caster-only spell: ' .. allReplies(player))
            assert(warCasts.n == 0, 'the Warrior cast something')
            assert(whmCasts.n == 1 and whmCasts.last == xi.magic.spell.PROTECTRA_II, string.format('the White Mage cast %d spells (last %d)', whmCasts.n, whmCasts.last))
            assert(player:hasStatusEffect(xi.effect.PROTECT), 'you did not get Protect: ' .. allReplies(player))
            assert(whm:hasStatusEffect(xi.effect.PROTECT), 'the caster did not get Protect')
        end)

        it('every Protectra tier and Shellra are cast', function()
            for _, case in ipairs({
                { line = 'protectra',     spell = xi.magic.spell.PROTECTRA,     effect = xi.effect.PROTECT },
                { line = 'protectra iii', spell = xi.magic.spell.PROTECTRA_III, effect = xi.effect.PROTECT },
                { line = 'protectra iv',  spell = xi.magic.spell.PROTECTRA_IV,  effect = xi.effect.PROTECT },
                { line = 'shellra',       spell = xi.magic.spell.SHELLRA,       effect = xi.effect.SHELL },
                { line = 'shellra iv',    spell = xi.magic.spell.SHELLRA_IV,    effect = xi.effect.SHELL },
                { line = 'barfira',       spell = xi.magic.spell.BARFIRA,       effect = xi.effect.BARFIRE },
                { line = 'barsleepra',    spell = xi.magic.spell.BARSLEEPRA,    effect = xi.effect.BARSLEEP },
            }) do
                local player = spawnPlayer()
                local whm    = spawnMate(player, xi.job.WHM)
                local casts  = spellCounter(whm)

                ask(player, case.line)

                assert(selfOnlyReply(player) == nil, case.line .. ' answered as a caster-only spell: ' .. allReplies(player))
                assert(casts.n == 1 and casts.last == case.spell, string.format('%s: %d casts (last %d): %s', case.line, casts.n, casts.last, allReplies(player)))
                assert(player:hasStatusEffect(case.effect), case.line .. ': you did not get the effect')
            end
        end)

        it('a mate asked by name who cannot cast it does not, and does not call it caster-only', function()
            local player = spawnPlayer()
            local war    = spawnMate(player, xi.job.WAR)
            local whm    = spawnMate(player, xi.job.WHM)
            local warCasts, whmCasts = spellCounter(war), spellCounter(whm)

            ask(player, war:getPacketName():lower() .. ' protectra ii')

            assert(selfOnlyReply(player) == nil, 'answered as a caster-only spell: ' .. allReplies(player))
            assert(warCasts.n == 0 and whmCasts.n == 0, 'somebody cast although the Warrior was asked by name')
            assert(not player:hasStatusEffect(xi.effect.PROTECT))
        end)

        it('nobody who can cast it: nothing is cast', function()
            local player = spawnPlayer()
            local war    = spawnMate(player, xi.job.WAR)
            local casts  = spellCounter(war)

            ask(player, 'protectra ii')

            assert(selfOnlyReply(player) == nil, 'answered as a caster-only spell: ' .. allReplies(player))
            assert(casts.n == 0)
            assert(not player:hasStatusEffect(xi.effect.PROTECT))
        end)

        it('a White Mage too low for the tier does not cast it', function()
            local player = spawnPlayer()
            local whm    = spawnMate(player, xi.job.WHM, 20) -- Protectra II is level 27
            local casts  = spellCounter(whm)

            ask(player, 'protectra ii')

            assert(selfOnlyReply(player) == nil, 'answered as a caster-only spell: ' .. allReplies(player))
            assert(casts.n == 0, 'a level 20 White Mage cast Protectra II')
        end)

        it('a caster without the MP does not cast it', function()
            local player = spawnPlayer()
            local whm    = spawnMate(player, xi.job.WHM)
            local casts  = spellCounter(whm)
            whm:setMP(0)

            ask(player, 'protectra ii', 4)

            assert(selfOnlyReply(player) == nil, 'answered as a caster-only spell: ' .. allReplies(player))
            assert(casts.n == 0, 'cast without MP')
        end)

        it('an area spell is still not put on somebody else by name', function()
            local player = spawnPlayer()
            local war    = spawnMate(player, xi.job.WAR)
            local whm    = spawnMate(player, xi.job.WHM)
            local casts  = spellCounter(whm)

            -- "protectra ii <the Warrior>": the spell goes on its caster only, so there is no target (as before v0.3.5)
            ask(player, 'protectra ii ' .. war:getPacketName():lower())

            assert(casts.n == 0, 'Protectra II was cast for a named member')
            assert(not war:hasStatusEffect(xi.effect.PROTECT))
        end)

        it('"all protectra ii" is one cast', function()
            local player = spawnPlayer()
            local whm1   = spawnMate(player, xi.job.WHM)
            local whm2   = spawnMate(player, xi.job.WHM)
            local casts1, casts2 = spellCounter(whm1), spellCounter(whm2)

            ask(player, 'all protectra ii')

            assert(casts1.n + casts2.n == 1, string.format('%d casts for one request', casts1.n + casts2.n))
            assert(player:hasStatusEffect(xi.effect.PROTECT))
        end)

        it('a spell that only works on its caster is still refused (Utsusemi, Blink, Warp)', function()
            local player = spawnPlayer()
            player:setCharVar('SQREQ_MORE_OFF', 1) -- (the looser words read "warp" as Warp II on you; the plain line is the spell)
            local nin    = spawnMate(player, xi.job.NIN)
            local whm    = spawnMate(player, xi.job.WHM)
            local blm    = spawnMate(player, xi.job.BLM)
            local ninCasts, whmCasts, blmCasts = spellCounter(nin), spellCounter(whm), spellCounter(blm)

            for _, line in ipairs({ 'utsusemi ichi', 'blink', 'warp' }) do
                ask(player, line, 3)
                assert(selfOnlyReply(player) ~= nil, line .. ' was not refused as a caster-only spell: ' .. allReplies(player))
            end

            assert(ninCasts.n == 0 and whmCasts.n == 0 and blmCasts.n == 0, 'a caster-only spell was cast on request')
        end)

        it('a single target spell goes on you, as before', function()
            local player = spawnPlayer()
            local whm    = spawnMate(player, xi.job.WHM)
            local casts  = spellCounter(whm)

            ask(player, 'protect ii')

            assert(selfOnlyReply(player) == nil)
            assert(casts.n == 1 and casts.last == xi.magic.spell.PROTECT_II, string.format('%d casts (last %d): %s', casts.n, casts.last, allReplies(player)))
            assert(player:hasStatusEffect(xi.effect.PROTECT))
            assert(not whm:hasStatusEffect(xi.effect.PROTECT), 'a single target spell landed on the caster too')
        end)

        it('an enemy area spell with no enemy is not cast and not called caster-only', function()
            local player = spawnPlayer()
            local blm    = spawnMate(player, xi.job.BLM)
            local casts  = spellCounter(blm)

            ask(player, 'stonega', 3)

            assert(selfOnlyReply(player) == nil, 'answered as a caster-only spell: ' .. allReplies(player))
            assert(casts.n == 0, 'an attack spell was cast with no enemy')
        end)

        it('a song asked by name is sung by the Bard', function()
            local player = spawnPlayer()
            local war    = spawnMate(player, xi.job.WAR)
            local brd    = spawnMate(player, xi.job.BRD)
            local warCasts, brdCasts = spellCounter(war), spellCounter(brd)

            ask(player, 'valor minuet', 14)

            assert(selfOnlyReply(player) == nil, 'answered as a caster-only spell: ' .. allReplies(player))
            assert(warCasts.n == 0)
            assert(brdCasts.n == 1 and brdCasts.last == xi.magic.spell.VALOR_MINUET, string.format('%d songs (last %d): %s', brdCasts.n, brdCasts.last, allReplies(player)))
            assert(player:hasStatusEffect(xi.effect.MINUET), 'you did not get Minuet')
        end)

        it('with the request fixes off (!sqreq off) the old path casts it too', function()
            local player = spawnPlayer()
            player:setCharVar('SQREQ_OFF', 1)
            local whm    = spawnMate(player, xi.job.WHM)
            local casts  = spellCounter(whm)

            ask(player, 'protectra ii')

            assert(casts.n == 1 and casts.last == xi.magic.spell.PROTECTRA_II)
            assert(player:hasStatusEffect(xi.effect.PROTECT))
        end)
    end)
end)
