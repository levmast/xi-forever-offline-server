-----------------------------------
-- XI: Forever Offline: squad mates follow the player combat mechanics (squad audit N1 N2 N3 N5 N6 N8 N10 N11).
-- Every case builds a real player character and a real squad mate (modules/custom/cpp/squad.cpp SpawnSquadMate) with
-- the same race, job, level and gear, and compares the server's own calculations for both. Ordinary trusts are checked
-- to keep their own (unchanged) model. Lines starting "SQMECH|" carry the numbers (shown with a failing test).
-----------------------------------
local squadSlot = 0

-- (registered by the squad module, modules/custom/cpp/squad.cpp; looked up when used)
local function squadApi(name)
    local fn = rawget(_G, name)
    assert(type(fn) == 'function', 'the squad module function ' .. name .. ' is missing')
    return fn
end

local function SaveSquadMate(...)
    return squadApi('SaveSquadMate')(...)
end

local function SpawnSquadMate(...)
    return squadApi('SpawnSquadMate')(...)
end

local function GetSquadWeaponSkills(...)
    return squadApi('GetSquadWeaponSkills')(...)
end

local function report(case, values)
    local keys = {}
    for k in pairs(values) do
        table.insert(keys, k)
    end

    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, string.format('%s=%s', k, tostring(values[k])))
    end

    print(string.format('SQMECH|%s|%s', case, table.concat(parts, ' ')))
end

local function isSquadMate(entity)
    -- (the binding is new; a baseline build without it reports false)
    local ok, result = pcall(function()
        return entity:isSquadMate()
    end)

    return ok and result == true
end

-- A player of that race, job and level with capped skills (main job caps, as the squad mate's) and the gear on.
local function spawnPlayer(cfg)
    local player = xi.test.world:spawnPlayer({ zone = cfg.zone or xi.zone.WEST_RONFAURE, job = cfg.job, level = cfg.level, race = cfg.race or xi.race.HUME_M })
    player:setUnkillable(true)
    player:capAllSkills()

    for slot, itemId in pairs(cfg.equip or {}) do
        player:addItem(itemId)
        player:equipItem(itemId, nil, slot) -- (the slot itself: a dagger's slot type is main|sub)
        assert(player:getEquipID(slot) == itemId, string.format('the player could not equip item %d in slot %d', itemId, slot))
    end

    return player
end

-- The squad mate: a squad record for the player, then the same spawn the game uses (callMate -> SpawnSquadMate).
local function spawnMate(player, cfg)
    squadSlot = squadSlot + 1
    local id = SaveSquadMate(player:getID(), squadSlot, { name = 'Mate' .. squadSlot, race = cfg.race or xi.race.HUME_M, face = 0, nation = 0, mjob = cfg.job, sjob = cfg.sjob or 0, template = 0 })
    assert(id ~= nil and id > 0, 'no squad record')

    local mate = SpawnSquadMate(player, { id = id, mjob = cfg.job, sjob = cfg.sjob or 0, mlevel = cfg.level, slevel = cfg.slevel or 0, template = 0, race = cfg.race or xi.race.HUME_M, face = 0, equip = cfg.equip or {} })
    assert(mate ~= nil, 'the squad mate was not spawned')
    xi.test.world:tickEntity(player)

    return mate, squadSlot
end

-- The text of every CHAT_STD (0x017) message the server sent the player (printToPlayer), as in test_npcs_in_gm_home.lua.
local function chatTexts(player)
    local texts = {}
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

            table.insert(texts, s)
        end
    end

    return texts
end

-- The module's !squad command, as the loader published it (modules/custom/lua/squad.lua)
local function squadCommand()
    for _, entry in ipairs(xi.module.commandRegistry or {}) do
        if entry.name == 'squad' then
            return entry.command
        end
    end

    return xi.commands and xi.commands.squad
end

local function ratings(entity)
    return {
        att  = entity:getStat(xi.mod.ATT),
        acc  = entity:getACC(),
        def  = entity:getStat(xi.mod.DEF),
        eva  = entity:getEVA(),
        racc = entity:getRACC(),
        ratt = entity:getStat(xi.mod.RATT),
        str  = entity:getStat(xi.mod.STR),
        dex  = entity:getStat(xi.mod.DEX),
        vit  = entity:getStat(xi.mod.VIT),
        agi  = entity:getStat(xi.mod.AGI),
    }
end

-- skills a player has and the squad mate must have the same (combat, ranged/defensive 25-31, magic, singing, instruments)
local comparedSkills =
{
    xi.skill.HAND_TO_HAND, xi.skill.DAGGER, xi.skill.SWORD, xi.skill.GREAT_SWORD, xi.skill.AXE, xi.skill.GREAT_AXE,
    xi.skill.SCYTHE, xi.skill.POLEARM, xi.skill.KATANA, xi.skill.GREAT_KATANA, xi.skill.CLUB, xi.skill.STAFF,
    xi.skill.ARCHERY, xi.skill.MARKSMANSHIP, xi.skill.THROWING, xi.skill.GUARD, xi.skill.EVASION, xi.skill.SHIELD,
    xi.skill.PARRY, xi.skill.DIVINE_MAGIC, xi.skill.HEALING_MAGIC, xi.skill.ENHANCING_MAGIC, xi.skill.ENFEEBLING_MAGIC,
    xi.skill.ELEMENTAL_MAGIC, xi.skill.DARK_MAGIC, xi.skill.SUMMONING_MAGIC, xi.skill.NINJUTSU, xi.skill.SINGING,
    xi.skill.STRING_INSTRUMENT, xi.skill.WIND_INSTRUMENT, xi.skill.BLUE_MAGIC,
}

local ratingCases =
{
    { name = 'WAR75_greataxe',   job = xi.job.WAR, level = 75, equip = { [xi.slot.MAIN] = xi.item.HEAVY_AXE } },
    { name = 'WAR30_greataxe',   job = xi.job.WAR, level = 30, equip = { [xi.slot.MAIN] = xi.item.BUTTERFLY_AXE } },
    { name = 'THF75_dagger',     job = xi.job.THF, level = 75, race = xi.race.MITHRA, equip = { [xi.slot.MAIN] = xi.item.MYTHRIL_KNIFE } },
    { name = 'PLD60_sword_kite', job = xi.job.PLD, level = 60, race = xi.race.ELVAAN_M, equip = { [xi.slot.MAIN] = xi.item.IRON_SWORD, [xi.slot.SUB] = xi.item.KITE_SHIELD } },
    { name = 'BLM50_staff',      job = xi.job.BLM, level = 50, race = xi.race.TARU_M, equip = { [xi.slot.MAIN] = xi.item.ELM_STAFF } },
    { name = 'MNK10_unarmed',    job = xi.job.MNK, level = 10, race = xi.race.GALKA, equip = {} },
    { name = 'MNK10_knuckles',   job = xi.job.MNK, level = 10, race = xi.race.GALKA, equip = { [xi.slot.MAIN] = xi.item.LEGIONNAIRES_KNUCKLES } },
    { name = 'RNG75_bow',        job = xi.job.RNG, level = 75, equip = { [xi.slot.MAIN] = xi.item.MYTHRIL_KNIFE, [xi.slot.RANGED] = xi.item.POWER_BOW, [xi.slot.AMMO] = xi.item.IRON_ARROW } },
}

-- Known, deliberately unchanged difference (not part of this batch): a squad mate of a job without hand-to-hand skill
-- that has nothing in the main hand keeps its trust template's stand-in weapon (Ayame: great katana), where a player
-- fights with the unarmed item (no skill). Recorded so a change shows up here.
local unarmedNonH2HCase = { name = 'SAM75_nogear', job = xi.job.SAM, level = 75, equip = {} }

describe('Squad player mechanics', function()
    -----------------------------------
    -- N1: combat ratings and skills
    -----------------------------------
    describe('N1 ratings', function()
        for _, case in ipairs(ratingCases) do
            it('match a player: ' .. case.name, function()
                local player = spawnPlayer(case)
                local mate   = spawnMate(player, case)

                local p = ratings(player)
                local m = ratings(mate)
                report('N1|' .. case.name .. '|player', p)
                report('N1|' .. case.name .. '|squad', m)

                local skills = {}
                for _, skill in ipairs(comparedSkills) do
                    skills['s' .. skill] = string.format('%d/%d', player:getSkillLevel(skill), mate:getSkillLevel(skill))
                    if isSquadMate(mate) then
                        assert(player:getSkillLevel(skill) == mate:getSkillLevel(skill), string.format('%s skill %d: player %d, squad %d', case.name, skill, player:getSkillLevel(skill), mate:getSkillLevel(skill)))
                    end
                end

                report('N1|' .. case.name .. '|skills', skills)

                if isSquadMate(mate) then
                    for key, value in pairs(p) do
                        assert(value == m[key], string.format('%s %s: player %d, squad %d', case.name, key, value, m[key]))
                    end
                end
            end)
        end

        it('records the known unarmed non hand-to-hand difference (SAM, nothing in the main hand)', function()
            local player = spawnPlayer(unarmedNonH2HCase)
            local mate   = spawnMate(player, unarmedNonH2HCase)
            local p      = ratings(player)
            local m      = ratings(mate)
            report('N1|SAM75_nogear|player', p)
            report('N1|SAM75_nogear|squad', m)
            report('N1|SAM75_nogear|weapon', { playerSkill = player:getWeaponSkillType(xi.slot.MAIN), squadSkill = mate:getWeaponSkillType(xi.slot.MAIN) })

            -- everything that does not depend on the weapon matches
            for _, key in ipairs({ 'def', 'eva', 'str', 'dex', 'vit', 'agi' }) do
                assert(p[key] == m[key], string.format('SAM75_nogear %s: player %d, squad %d', key, p[key], m[key]))
            end
        end)

        it('uses the player rule for sub job skills (main job cap, else the sub job cap at the sub level)', function()
            local cfg    = { job = xi.job.WAR, level = 60, sjob = xi.job.WHM, slevel = 30 }
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)

            local healing = mate:getSkillLevel(xi.skill.HEALING_MAGIC)
            local expected = mate:getMaxSkillLevel(30, xi.job.WHM, xi.skill.HEALING_MAGIC)
            report('N1|WAR60_WHM30|skills', { healing = healing, expected = expected, gaxe = mate:getSkillLevel(xi.skill.GREAT_AXE), gaxeCap = mate:getMaxSkillLevel(60, xi.job.WAR, xi.skill.GREAT_AXE) })
            if isSquadMate(mate) then
                assert(healing == expected, string.format('healing %d, expected %d (sub job cap at the sub level)', healing, expected))
                assert(mate:getSkillLevel(xi.skill.GREAT_AXE) == mate:getMaxSkillLevel(60, xi.job.WAR, xi.skill.GREAT_AXE), 'great axe is the main job cap')
            end
        end)

        it('is a Humanoid (N10) and recognised as a squad mate', function()
            local cfg    = { job = xi.job.NIN, level = 40 }
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)

            report('N10|NIN40', { ecosystem = mate:getEcosystem(), squad = tostring(isSquadMate(mate)) })
            assert(isSquadMate(mate), 'the squad mate is not recognised (isSquadMate)')
            assert(mate:getEcosystem() == xi.ecosystem.HUMANOID, 'a squad NIN is not Humanoid')
            assert(not isSquadMate(player), 'a player is not a squad mate')
        end)

        it('gives a squad Ranger its bow weapon skills', function()
            local cfg    = ratingCases[8]
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)
            local names  = GetSquadWeaponSkills(mate) or {}

            local hasArchery = false
            for _, name in pairs(names) do
                local lower = string.lower(name)
                if lower == 'flaming_arrow' or lower == 'piercing_arrow' or lower == 'dulling_arrow' or lower == 'sidewinder' then
                    hasArchery = true
                end
            end

            report('N1|RNG75_ws', { list = table.concat(names, ','), archery = tostring(hasArchery) })
            assert(hasArchery, 'a squad Ranger with a bow has no archery weapon skill')
        end)
    end)

    -----------------------------------
    -- The !squad sheet shows the player-equivalent totals
    -----------------------------------
    describe('Squad sheet', function()
        it('shows the Attack and Defense totals combat uses (WAR75, Heavy Axe)', function()
            local cfg         = ratingCases[1]
            local player      = spawnPlayer(cfg)
            local mate, slot  = spawnMate(player, cfg)
            local command     = squadCommand()
            assert(command and type(command.onTrigger) == 'function', 'the !squad command is not registered')

            player.packets:clear()
            command.onTrigger(player, 'sheet', tostring(slot))

            local shown = {}
            local kinds = {}
            for _, text in ipairs(chatTexts(player)) do
                local kind, name, value = text:match('^squadsheet:(%a+)|([^|]+)|?(%-?%d*)')
                if kind then
                    kinds[kind] = (kinds[kind] or 0) + 1
                    if kind == 'combat' then
                        shown[name] = tonumber(value)
                    end
                end
            end

            local values =
            {
                shownAttack = shown['Attack'], shownDefense = shown['Defense'], shownAccuracy = shown['Accuracy'], shownEvasion = shown['Evasion'],
                mateAttack = mate:getStat(xi.mod.ATT), mateDefense = mate:getStat(xi.mod.DEF), mateAccuracy = mate:getACC(), mateEvasion = mate:getEVA(),
                playerAttack = player:getStat(xi.mod.ATT), playerDefense = player:getStat(xi.mod.DEF),
                attackMod = mate:getMod(xi.mod.ATT), defenseMod = mate:getMod(xi.mod.DEF),
                hdr = kinds.hdr or 0, stat = kinds.stat or 0, combat = kinds.combat or 0, vital = kinds.vital or 0, haste = kinds.haste or 0,
            }
            report('SHEET|WAR75', values)

            -- the rest of the sheet is still there
            assert(values.hdr == 1 and values.vital == 3 and values.stat == 7 and values.combat == 6 and values.haste == 3, 'sheet lines are missing')
            -- the totals, not the stored modifiers
            assert(values.shownAttack == values.mateAttack, 'the sheet Attack is not the attack total')
            assert(values.shownDefense == values.mateDefense, 'the sheet Defense is not the defense total')
            assert(values.shownAccuracy == values.mateAccuracy and values.shownEvasion == values.mateEvasion, 'Accuracy/Evasion changed')
            if isSquadMate(mate) then
                assert(values.shownAttack == values.playerAttack and values.shownDefense == values.playerDefense, 'the sheet does not show the player-equivalent values')
            end
        end)
    end)

    -----------------------------------
    -- N11: unarmed hand-to-hand delay
    -----------------------------------
    describe('N11 unarmed delay', function()
        for _, level in ipairs({ 7, 10, 75 }) do
            it('is a player unarmed delay at level ' .. level, function()
                local cfg    = { job = xi.job.MNK, level = level }
                local player = spawnPlayer(cfg)
                local mate   = spawnMate(player, cfg)

                local values =
                {
                    playerBase = player:getBaseDelay(),
                    squadBase  = mate:getBaseDelay(),
                    playerMA   = player:getMod(xi.mod.MARTIAL_ARTS),
                    squadMA    = mate:getMod(xi.mod.MARTIAL_ARTS),
                    squadH2H   = tostring(mate:isUsingH2H()),
                }
                report('N11|MNK' .. level, values)

                assert(mate:isUsingH2H(), 'an unarmed squad Monk does not fight hand-to-hand')
                assert(values.squadMA == values.playerMA, 'Martial Arts differs')
                if isSquadMate(mate) then
                    assert(values.squadBase == values.playerBase, string.format('base delay: player %d, squad %d', values.playerBase, values.squadBase))
                end
            end)
        end

        it('keeps an equipped weapon delay (Legionnaire\'s Knuckles)', function()
            local cfg    = ratingCases[7]
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)

            report('N11|MNK10_knuckles', { playerBase = player:getBaseDelay(), squadBase = mate:getBaseDelay() })
            assert(mate:getBaseDelay() == player:getBaseDelay(), 'the knuckles delay differs')
            assert(mate:getBaseDelay() == 576, 'Legionnaire\'s Knuckles base delay is not 576')
        end)
    end)

    -----------------------------------
    -- N3: level correction, hit rate caps and pDIF
    -----------------------------------
    describe('N3 level correction', function()
        local function pdifStats(actor, target, samples)
            local low, high, sum = 99, 0, 0
            for _ = 1, samples do
                local value = xi.combat.physical.calculateMeleePDIF(actor, target, xi.skill.GREAT_AXE, 1, false, true, false, 0, false, xi.slot.MAIN, false)
                low  = math.min(low, value)
                high = math.max(high, value)
                sum  = sum + value
            end

            return low, high, sum / samples
        end

        for _, diff in ipairs({ 0, 5, -5 }) do
            it('treats a squad mate as a player at target level +' .. diff, function()
                local cfg    = ratingCases[1]
                local player = spawnPlayer(cfg)
                local mate   = spawnMate(player, cfg)
                local mob    = player.entities:moveTo('Forest_Hare')
                mob:spawn()
                mob:setMobLevel(75 + diff)
                mate:setPos(player:getPos())

                local pHit = xi.combat.physicalHitRate.getPhysicalHitRate(player, mob, 0, 0, false)
                local mHit = xi.combat.physicalHitRate.getPhysicalHitRate(mate, mob, 0, 0, false)
                local pCap = xi.combat.physicalHitRate.getPhysicalHitRateCap(player, 0)
                local mCap = xi.combat.physicalHitRate.getPhysicalHitRateCap(mate, 0)
                local pLow, pHigh, pAvg = pdifStats(player, mob, 3000)
                local mLow, mHigh, mAvg = pdifStats(mate, mob, 3000)

                report('N3|WAR75_vs+' .. diff,
                {
                    playerHit = string.format('%.4f', pHit), squadHit = string.format('%.4f', mHit),
                    playerCap = pCap, squadCap = mCap,
                    playerPdif = string.format('%.3f-%.3f avg %.3f', pLow, pHigh, pAvg),
                    squadPdif  = string.format('%.3f-%.3f avg %.3f', mLow, mHigh, mAvg),
                    mobDef = mob:getStat(xi.mod.DEF), mobEva = mob:getEVA(),
                })

                if isSquadMate(mate) then
                    assert(math.abs(pHit - mHit) < 0.0001, string.format('hit rate: player %.4f, squad %.4f', pHit, mHit))
                    assert(pCap == mCap, 'hit rate cap differs')
                    assert(math.abs(pAvg - mAvg) < 0.05, string.format('average pDIF: player %.3f, squad %.3f', pAvg, mAvg))
                    assert(math.abs(pHigh - mHigh) < 0.15, string.format('highest pDIF: player %.3f, squad %.3f', pHigh, mHigh))
                end
            end)
        end
    end)

    -----------------------------------
    -- N2: shield block, parry, guard
    -----------------------------------
    describe('N2 defence', function()
        it('blocks with a shield as a player (PLD60, Kite Shield)', function()
            local cfg    = ratingCases[4]
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)
            local mob    = player.entities:moveTo('Forest_Hare')
            mob:spawn()
            mob:setMobLevel(60)

            local values =
            {
                playerRank   = player:getSkillRank(xi.skill.SHIELD),
                squadRank    = mate:getSkillRank(xi.skill.SHIELD),
                playerShield = player:getSkillLevel(xi.skill.SHIELD),
                squadShield  = mate:getSkillLevel(xi.skill.SHIELD),
                playerBlock  = string.format('%.2f', xi.combat.physical.calculateBlockRate(player, mob)),
                squadBlock   = string.format('%.2f', xi.combat.physical.calculateBlockRate(mate, mob)),
                squadItem    = tostring(mate:getEquippedItem(xi.slot.SUB) and mate:getEquippedItem(xi.slot.SUB):getID()),
                playerParry  = xi.combat.physical.calculateParryRate(player, mob),
                squadParry   = xi.combat.physical.calculateParryRate(mate, mob),
                playerAbsorb = xi.combat.physical.getDamageReductionForBlock(player, mob, 100),
                squadAbsorb  = xi.combat.physical.getDamageReductionForBlock(mate, mob, 100),
            }
            report('N2|PLD60', values)

            assert(values.squadRank > 0, 'a squad Paladin has no Shield rank')
            assert(values.squadBlock == values.playerBlock, 'block rate differs')
            assert(values.squadParry == values.playerParry, 'parry rate differs')
            assert(values.squadAbsorb == values.playerAbsorb, 'shield absorption differs')
        end)

        it('cannot block without a shield or without a Shield rank', function()
            local blmCfg = ratingCases[5]
            local player = spawnPlayer(blmCfg)
            local blm    = spawnMate(player, blmCfg)
            local mob    = player.entities:moveTo('Forest_Hare')
            mob:spawn()
            blm:lookAt(mob:getPos())

            local pldCfg = { job = xi.job.PLD, level = 60, equip = { [xi.slot.MAIN] = xi.item.IRON_SWORD } }
            local pld    = spawnMate(player, pldCfg)
            pld:lookAt(mob:getPos())

            report('N2|noshield', { blm = tostring(xi.combat.physical.canBlock(blm, mob)), pldNoShield = tostring(xi.combat.physical.canBlock(pld, mob)) })
            assert(not xi.combat.physical.canBlock(blm, mob), 'a Black Mage blocked')
            assert(not xi.combat.physical.canBlock(pld, mob), 'a Paladin without a shield blocked')
        end)

        it('parries with a weapon and not barehanded; guards barehanded (MNK)', function()
            local thfCfg = ratingCases[3]
            local player = spawnPlayer(thfCfg)
            local thf    = spawnMate(player, thfCfg)
            local mob    = player.entities:moveTo('Forest_Hare')
            mob:spawn()

            local mnk = spawnMate(player, { job = xi.job.MNK, level = 75, race = xi.race.GALKA })

            report('N2|parry_guard', { thfParryRank = thf:getSkillRank(xi.skill.PARRY), thfParryRate = xi.combat.physical.calculateParryRate(thf, mob), mnkGuardRank = mnk:getSkillRank(xi.skill.GUARD), mnkGuardRate = xi.combat.physical.calculateGuardRate(mnk, mob) })
            assert(thf:getSkillRank(xi.skill.PARRY) > 0, 'a squad Thief has no Parry rank')
            assert(mnk:getSkillRank(xi.skill.GUARD) > 0, 'a squad Monk has no Guard rank')
        end)
    end)

    -----------------------------------
    -- N5: ability recasts
    -----------------------------------
    describe('N5 recasts', function()
        it('shares the Phantom Roll recast (squad Corsair)', function()
            local cfg    = { job = xi.job.COR, level = 75 }
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)

            mate:useJobAbility(xi.ja.FIGHTERS_ROLL, mate)
            xi.test.world:tickEntity(mate)
            xi.test.world:skipTime(3)
            local fighters = mate:hasStatusEffect(xi.effect.FIGHTERS_ROLL)

            mate:useJobAbility(xi.ja.CHAOS_ROLL, mate)
            xi.test.world:tickEntity(mate)
            xi.test.world:skipTime(3)
            local chaos = mate:hasStatusEffect(xi.effect.CHAOS_ROLL)

            report('N5|COR_rolls', { fighters = tostring(fighters), chaosAfter = tostring(chaos), group = tostring(mate:hasRecast(xi.recast.ABILITY, 0x8000 + 193)) })
            assert(fighters, 'Fighter\'s Roll did not land')
            if isSquadMate(mate) then
                assert(not chaos, 'Chaos Roll was used while the shared Phantom Roll recast was running')
            end
        end)

        it('keeps the per-ability recast of an ordinary trust (Qultada)', function()
            local player = spawnPlayer({ job = xi.job.SMN, level = 75 })
            player:addSpell(xi.magic.spell.QULTADA)
            player.actions:useSpell(player, xi.magic.spell.QULTADA)
            xi.test.world:tickEntity(player)
            xi.test.world:skipTime(10)

            local qultada = nil
            for _, member in ipairs(player:getPartyWithTrusts()) do
                if member:getName() == 'qultada' then
                    qultada = member
                end
            end

            assert(qultada, 'Qultada was not summoned')
            assert(not isSquadMate(qultada), 'an ordinary trust is reported as a squad mate')

            qultada:useJobAbility(xi.ja.FIGHTERS_ROLL, qultada)
            xi.test.world:tickEntity(qultada)
            xi.test.world:skipTime(3)
            qultada:useJobAbility(xi.ja.CHAOS_ROLL, qultada)
            xi.test.world:tickEntity(qultada)
            xi.test.world:skipTime(3)

            report('N5|Qultada', { fighters = tostring(qultada:hasStatusEffect(xi.effect.FIGHTERS_ROLL)), chaos = tostring(qultada:hasStatusEffect(xi.effect.CHAOS_ROLL)), group = tostring(qultada:hasRecast(xi.recast.ABILITY, 0x8000 + 193)) })
            assert(not qultada:hasRecast(xi.recast.ABILITY, 0x8000 + 193), 'an ordinary trust got a squad recast group')
        end)
    end)

    -----------------------------------
    -- N8: magic
    -----------------------------------
    describe('N8 magic', function()
        it('uses the player Magic Burst and multi-target rules for a squad mate', function()
            local cfg    = ratingCases[5]
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)
            local mob    = player.entities:moveTo('Forest_Hare')
            mob:spawn()

            local pMB = xi.spells.damage.calculateIfMagicBurst(player, mob, xi.element.FIRE, 2)
            local mMB = xi.spells.damage.calculateIfMagicBurst(mate, mob, xi.element.FIRE, 2)
            local pBase = xi.spells.damage.calculateBaseDamage(player, mob, xi.magic.spell.FIRE_III, xi.magic.spellGroup.BLACK, xi.skill.ELEMENTAL_MAGIC, xi.mod.INT)
            local mBase = xi.spells.damage.calculateBaseDamage(mate, mob, xi.magic.spell.FIRE_III, xi.magic.spellGroup.BLACK, xi.skill.ELEMENTAL_MAGIC, xi.mod.INT)

            report('N8|BLM50', { playerMB = pMB, squadMB = mMB, playerFireIII = pBase, squadFireIII = mBase, playerINT = player:getStat(xi.mod.INT), squadINT = mate:getStat(xi.mod.INT), playerElem = player:getSkillLevel(xi.skill.ELEMENTAL_MAGIC), squadElem = mate:getSkillLevel(xi.skill.ELEMENTAL_MAGIC) })

            if isSquadMate(mate) then
                assert(pMB == mMB, 'Magic Burst multiplier differs')
                assert(pBase == mBase, 'Fire III base damage differs')
            end
        end)

        it('reads a squad Bard\'s instrument for song potency and Singing accuracy', function()
            local cfg    = { job = xi.job.BRD, level = 60, equip = { [xi.slot.RANGED] = xi.item.CORNETTE } }
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)

            report('N8|BRD60', { playerSinging = player:getSkillLevel(xi.skill.SINGING), squadSinging = mate:getSkillLevel(xi.skill.SINGING), playerWind = player:getSkillLevel(xi.skill.WIND_INSTRUMENT), squadWind = mate:getSkillLevel(xi.skill.WIND_INSTRUMENT), squadRanged = tostring(mate:getEquippedItem(xi.slot.RANGED) and mate:getEquippedItem(xi.slot.RANGED):getSkillType()) })
            if isSquadMate(mate) then
                assert(mate:getSkillLevel(xi.skill.WIND_INSTRUMENT) == player:getSkillLevel(xi.skill.WIND_INSTRUMENT), 'wind instrument skill differs')
                assert(mate:getEquippedItem(xi.slot.RANGED) ~= nil and mate:getEquippedItem(xi.slot.RANGED):getSkillType() == xi.skill.WIND_INSTRUMENT, 'the Bard\'s instrument is not read')
                assert(mate:getWeaponSkillType(xi.slot.RANGED) ~= xi.skill.WIND_INSTRUMENT, 'the instrument became a shooting weapon')
            end
        end)
    end)

    -----------------------------------
    -- Final verification additions: charges, paralysis, damage multipliers, multi-target, resist tiers, BLM bonus
    -----------------------------------
    describe('Verification', function()
        local function countAbilityUses(entity)
            local counter = { n = 0 }
            entity:addListener('ABILITY_STATE_EXIT', 'SQMECH_ABILITY_COUNT', function()
                counter.n = counter.n + 1
            end)

            return counter
        end

        local function useAbility(entity, abilityId, target)
            entity:useJobAbility(abilityId, target)
            xi.test.world:tickEntity(entity)
            xi.test.world:skipTime(4)
        end

        it('N5: Quick Draw uses the player charges (2) for a squad Corsair', function()
            local cfg    = { job = xi.job.COR, level = 75 }
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)
            local mob    = player.entities:moveTo('Forest_Hare')
            mob:spawn()
            mob:setUnkillable(true)
            mate:setPos(mob:getXPos() + 2, mob:getYPos(), mob:getZPos())
            mate:lookAt(mob:getPos())

            local uses  = countAbilityUses(mate)
            local after = {}
            for shot = 1, 3 do
                useAbility(mate, xi.jobAbility.FIRE_SHOT, mob)
                after[shot] = uses.n
            end

            report('N5|COR_quickdraw', { uses1 = after[1], uses2 = after[2], uses3 = after[3], groupBlocked = tostring(mate:hasRecast(xi.recast.ABILITY, 0x8000 + 195, 1)) })
            assert(after[1] == 1 and after[2] == 2, string.format('the two charges were not both usable (%d, %d)', after[1], after[2]))
            if isSquadMate(mate) then
                assert(after[3] == 2, 'a third Quick Draw went off with both charges used')
                assert(mate:hasRecast(xi.recast.ABILITY, 0x8000 + 195, 1), 'no charge recast after two shots')
            end
        end)

        it('N5: a paralyzed ability still uses its recast (squad), not for an ordinary trust', function()
            local cfg    = { job = xi.job.WAR, level = 75 }
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)
            mate:addMod(xi.mod.PARALYZE, 100) -- always paralyzed

            useAbility(mate, xi.jobAbility.BERSERK, mate)
            local squadRecast = mate:hasRecast(xi.recast.ABILITY, xi.jobAbility.BERSERK)
            local squadEffect = mate:hasStatusEffect(xi.effect.BERSERK)

            local owner = spawnPlayer({ job = xi.job.SMN, level = 75 })
            owner:addSpell(xi.magic.spell.NAJI)
            owner.actions:useSpell(owner, xi.magic.spell.NAJI)
            xi.test.world:tickEntity(owner)
            xi.test.world:skipTime(10)
            local naji = nil
            for _, member in ipairs(owner:getPartyWithTrusts()) do
                if member:isTrust() then
                    naji = member
                end
            end

            assert(naji, 'Naji did not come')
            naji:addMod(xi.mod.PARALYZE, 100)
            useAbility(naji, xi.jobAbility.BERSERK, naji)
            local trustRecast = naji:hasRecast(xi.recast.ABILITY, xi.jobAbility.BERSERK)

            report('N5|paralysis', { squadRecast = tostring(squadRecast), squadBerserk = tostring(squadEffect), trustRecast = tostring(trustRecast) })
            assert(not squadEffect, 'Berserk went off although the mate is always paralyzed')
            assert(not trustRecast, 'an ordinary trust lost its recast to paralysis (unchanged trust rule)')
            if isSquadMate(mate) then
                assert(squadRecast, 'a paralyzed squad mate did not use the recast (player rule)')
            end
        end)

        it('N5: Double-Up 11 resets the shared Phantom Roll recast (resetRecast)', function()
            local cfg    = { job = xi.job.COR, level = 75 }
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)

            useAbility(mate, xi.jobAbility.FIGHTERS_ROLL, mate)
            local before = mate:hasRecast(xi.recast.ABILITY, 0x8000 + 193)
            mate:resetRecast(xi.recast.ABILITY, xi.recastID.PHANTOM_ROLL)
            local groupAfter   = mate:hasRecast(xi.recast.ABILITY, 0x8000 + 193)
            local fighterAfter = mate:hasRecast(xi.recast.ABILITY, xi.jobAbility.FIGHTERS_ROLL)

            report('N5|resetRecast', { groupBefore = tostring(before), groupAfter = tostring(groupAfter), fightersAfter = tostring(fighterAfter) })
            if isSquadMate(mate) then
                assert(before, 'no shared roll recast after Fighter\'s Roll')
                assert(not groupAfter and not fighterAfter, 'resetRecast left a roll recast running')
            end
        end)

        it('N6: weapon procs and damage-rate mods as a player (Bravura, DA/Zanshin rates)', function()
            local cfg    = { job = xi.job.WAR, level = 75, equip = { [xi.slot.MAIN] = xi.item.BRAVURA_75 } }
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)

            local function procs(entity, samples)
                local count = 0
                for _ = 1, samples do
                    if entity:addDamageFromMultipliers(100, xi.physicalAttackType.NORMAL, xi.slot.MAIN, true) > 100 then
                        count = count + 1
                    end
                end

                return count
            end

            local pProcs = procs(player, 4000)
            local mProcs = procs(mate, 4000)

            for _, entity in ipairs({ player, mate }) do
                entity:addMod(xi.mod.DA_DOUBLE_DMG_RATE, 100)
                entity:addMod(xi.mod.ZANSHIN_DOUBLE_DAMAGE, 100)
            end

            local values =
            {
                playerProcs = pProcs, squadProcs = mProcs,
                playerDA = player:addDamageFromMultipliers(100, xi.physicalAttackType.DOUBLE, xi.slot.MAIN, false),
                squadDA  = mate:addDamageFromMultipliers(100, xi.physicalAttackType.DOUBLE, xi.slot.MAIN, false),
                playerZanshin = player:addDamageFromMultipliers(100, xi.physicalAttackType.ZANSHIN, xi.slot.MAIN, false),
                squadZanshin  = mate:addDamageFromMultipliers(100, xi.physicalAttackType.ZANSHIN, xi.slot.MAIN, false),
            }
            report('N6|WAR75_bravura', values)

            -- Bravura: "occasionally deals double damage", 5 % (EXTRA_DMG_CHANCE 50): about 200 of 4000
            assert(pProcs > 120 and pProcs < 290, 'the player proc count is off: ' .. pProcs)
            if isSquadMate(mate) then
                assert(mProcs > 120 and mProcs < 290, 'the squad proc count is off: ' .. mProcs)
                assert(values.squadDA == 200 and values.squadZanshin == 200, 'DA/Zanshin double damage rates do not apply to the squad mate')
            end
        end)

        it('N8: multi-target damage reduction and resist tiers as a player', function()
            local cfg    = ratingCases[5]
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)
            local mob    = player.entities:moveTo('Forest_Hare')
            mob:spawn()

            local function threeTargetCount()
                return 3
            end

            local threeTargets = { getTotalTargets = threeTargetCount }
            local mtdr =
            {
                player = xi.spells.damage.calculateMTDR(player, threeTargets),
                squad  = xi.spells.damage.calculateMTDR(mate, threeTargets),
            }

            -- a weak caster (level 1 hare) against the level 50 player and mate: many resists
            mob:setMobLevel(1)
            local function lowestFactor(target)
                local lowest = 1
                local half   = 0
                for _ = 1, 3000 do
                    local factor = xi.combat.magicHitRate.calculateResistRate(mob, target, { magicalElement = xi.element.FIRE, skillType = xi.skill.ELEMENTAL_MAGIC, actorStat = xi.mod.INT })
                    lowest = math.min(lowest, factor)
                    if factor <= 0.5 then
                        half = half + 1
                    end
                end

                return lowest, half
            end

            local pLow, pHalf = lowestFactor(player)
            local mLow, mHalf = lowestFactor(mate)
            report('N8|mtdr_resist', { playerMTDR = mtdr.player, squadMTDR = mtdr.squad, playerLowest = pLow, squadLowest = mLow, playerResisted = pHalf, squadResisted = mHalf })

            assert(mtdr.player == 0.75, 'player MTDR for three targets is not 0.75')
            if isSquadMate(mate) then
                assert(mtdr.squad == mtdr.player, 'squad MTDR differs')
                assert(mLow == pLow, string.format('lowest resist factor: player %s, squad %s', pLow, mLow))
            end
        end)

        for _, instrument in ipairs({ { name = 'Cornette', id = xi.item.CORNETTE }, { name = 'Maple_Harp', id = xi.item.MAPLE_HARP } }) do
            it('N8: Bard song potency and Singing accuracy as a player (' .. instrument.name .. ')', function()
                local cfg    = { job = xi.job.BRD, level = 60, equip = { [xi.slot.RANGED] = instrument.id } }
                local player = spawnPlayer(cfg)
                local mate   = spawnMate(player, cfg)
                local mob    = player.entities:moveTo('Forest_Hare')
                mob:spawn()
                mob:setMobLevel(60)

                local function potency(caster)
                    return xi.spells.enhancing.calculateSongPower(caster, caster, nil, xi.magic.spell.VALOR_MINUET_III, 3, xi.effect.MINUET, 0, nil)
                end

                local function landed(caster)
                    local count = 0
                    for _ = 1, 2000 do
                        if xi.combat.magicHitRate.calculateResistRate(caster, mob, { magicalElement = xi.element.LIGHT, skillType = xi.skill.SINGING, effectId = xi.effect.LULLABY, actorStat = xi.mod.CHR }) >= 1 then
                            count = count + 1
                        end
                    end

                    return count
                end

                local values = { playerPotency = potency(player), squadPotency = potency(mate), playerLanded = landed(player), squadLanded = landed(mate) }
                report('N8|BRD60_' .. instrument.name, values)
                if isSquadMate(mate) then
                    assert(values.playerPotency == values.squadPotency, 'Minuet III potency differs')
                    assert(math.abs(values.playerLanded - values.squadLanded) < 100, 'Singing accuracy differs (unresisted of 2000)')
                end
            end)
        end

        -- the Gambits engine condition JA_ON_COOLDOWN sees the same shared recast as execution
        it('Gambits JA_ON_COOLDOWN sees the shared Phantom Roll recast', function()
            local player = spawnPlayer({ job = xi.job.COR, level = 75 })
            local mate   = spawnMate(player, { job = xi.job.COR, level = 75, sjob = xi.job.WAR, slevel = 37 })
            -- (a mob no other test here uses; claimed for this player so nothing left over blocks the engage)
            local mob    = player.entities:moveTo('Carrion_Worm')
            mob:spawn()
            mob:setMobMod(xi.mobMod.NO_MOVE, 1)
            mob:setUnkillable(true)
            xi.test.world:skipTime(1)
            xi.test.world:tick()
            mob:updateClaim(player)
            player:setPos(mob:getXPos() + 1, mob:getYPos(), mob:getZPos())
            mate:setPos(mob:getXPos() - 1, mob:getYPos(), mob:getZPos())

            -- one rule only: Berserk (WAR sub job) while Chaos Roll is "on cooldown"
            mate:removeAllGambits()
            mate:addGambit(ai.t.SELF, { ai.c.JA_ON_COOLDOWN, xi.ja.CHAOS_ROLL }, { ai.r.JA, ai.s.SPECIFIC, xi.ja.BERSERK })

            player:setCharVar('TrustEngageType', 1)
            mob:updateEnmity(player)
            player:engage(mob:getTargID())
            mate:engage(mob:getTargID()) -- (squad mates otherwise wait out their own engage delay)
            for _ = 1, 6 do
                xi.test.world:skipTime(1)
                xi.test.world:tick()
            end

            local beforeRoll = mate:hasStatusEffect(xi.effect.BERSERK)

            useAbility(mate, xi.ja.FIGHTERS_ROLL, mate)
            for _ = 1, 8 do
                xi.test.world:skipTime(1)
                xi.test.world:tick()
            end

            local afterRoll = mate:hasStatusEffect(xi.effect.BERSERK)
            report('GAMBITS|JA_ON_COOLDOWN', { engaged = tostring(mate:isEngaged()), action = tostring(mate:getCurrentAction()), playerEngaged = tostring(player:isEngaged()), mobAlive = tostring(mob:isAlive()), dist = string.format('%.1f', mate:checkDistance(mob)), berserkBeforeRoll = tostring(beforeRoll), fightersRoll = tostring(mate:hasStatusEffect(xi.effect.FIGHTERS_ROLL)), berserkAfterRoll = tostring(afterRoll) })

            assert(mate:isEngaged(), 'precondition: the mate engaged')
            assert(not beforeRoll, 'JA_ON_COOLDOWN Chaos Roll was true before any roll')
            assert(mate:hasStatusEffect(xi.effect.FIGHTERS_ROLL), 'precondition: Fighter\'s Roll landed')
            assert(afterRoll, 'JA_ON_COOLDOWN Chaos Roll stayed false while the shared Phantom Roll recast ran')
        end)

        it('N8: the squad Black Mage bonuses stay (MATT, MACC, magic haste)', function()
            local cfg    = ratingCases[5]
            local player = spawnPlayer(cfg)
            local mate   = spawnMate(player, cfg)

            local values =
            {
                playerMATT = player:getMod(xi.mod.MATT), squadMATT = mate:getMod(xi.mod.MATT),
                playerMACC = player:getMod(xi.mod.MACC), squadMACC = mate:getMod(xi.mod.MACC),
                squadHaste = mate:getMod(xi.mod.HASTE_MAGIC),
            }
            report('N8|BLM50_bonus', values)
            assert(values.squadMATT - values.playerMATT >= 5, 'the squad BLM Magic Attack bonus is gone')
            assert(values.squadMACC - values.playerMACC >= 5, 'the squad BLM Magic Accuracy bonus is gone')
            assert(values.squadHaste >= 1000, 'the squad BLM magic haste is gone')
        end)
    end)

    -----------------------------------
    -- Ordinary trusts keep their model
    -----------------------------------
    describe('Ordinary trusts', function()
        for _, spell in ipairs({ xi.magic.spell.NAJI, xi.magic.spell.CURILLA, xi.magic.spell.NAJA_SALAHEEM, xi.magic.spell.AYAME, xi.magic.spell.KUPIPI }) do
            it('keep the trust ratings (trust spell ' .. spell .. ')', function()
                local player = spawnPlayer({ job = xi.job.SMN, level = 75 })
                player:addSpell(spell)
                player.actions:useSpell(player, spell)
                xi.test.world:tickEntity(player)
                xi.test.world:skipTime(10)

                local mob = player.entities:moveTo('Forest_Hare')
                mob:spawn()

                local seen = 0
                for _, member in ipairs(player:getPartyWithTrusts()) do
                    if member:isTrust() then
                        seen = seen + 1
                        local values = ratings(member)
                        values.squad    = tostring(isSquadMate(member))
                        values.eco      = member:getEcosystem()
                        values.delay    = member:getBaseDelay()
                        values.twoHand  = tostring(member:isWeaponTwoHanded())
                        values.canBlock = tostring(xi.combat.physical.canBlock(member, mob))
                        values.hitCap   = xi.combat.physicalHitRate.getPhysicalHitRateCap(member, 0)
                        values.mb       = xi.spells.damage.calculateIfMagicBurst(member, mob, xi.element.FIRE, 2)
                        values.parry    = xi.combat.physical.calculateParryRate(member, mob)
                        values.block    = string.format('%.2f', xi.combat.physical.calculateBlockRate(member, mob))
                        report('TRUST|' .. member:getName(), values)
                        assert(not isSquadMate(member), 'an ordinary trust is reported as a squad mate')
                    end
                end

                assert(seen == 1, 'the trust did not come (' .. spell .. ')')
            end)
        end
    end)
end)
