-----------------------------------
-- Extra caskets: Treasure Caskets in the areas that have none on retail (Ghelsba, Giddeus, Palborough, Davoi,
-- Beadeaux, Castle Oztroja, the Chains of Promathia and Aht Urhgan areas, ...). The areas that already have
-- caskets keep the game's own ones (and casket_tweaks.lua); this file never touches them.
--
-- These areas have no casket in the game files, so the chest is made by the server, at the monster's body:
--   - same chance as the normal caskets (CASKET_DROP_RATE in the launcher), same loot, gil and golden super casket
--   - only you and your party can open it, and it disappears after 3 minutes
--   - no number-guessing lock (there is no lock window in these areas): touching it opens it, the items go to
--     the treasure pool and the gil to whoever opened it.
-- GM test: !extracasket   spawns one at your feet (in any area).
-----------------------------------
require('modules/module_utils')
local loot = require('modules/custom/lua/casket_loot_custom')
-----------------------------------
local m = Module:new('extra_caskets')

-- Settings you can change ---------------------------------------------------
local BROWN_CHANCE = 0.15                          -- brown casket (weapons and armor) instead of blue
local SUPER_CHANCE = 0.05                          -- golden super casket (one cosmetic piece)
local LIFETIME     = 3 * 60                        -- seconds before an unopened casket disappears
local MAX_PER_ZONE = 6                             -- at most this many extra caskets in one area at a time

local BLUE_COUNTS  = { 1, 1, 2, 1, 2, 1, 3, 1, 2, 1 }
local BROWN_COUNTS = { 1, 1, 2, 1, 1, 2, 1, 3, 1, 1 }
local BASE_GIL     = 100
local BLUE_GIL     = { 10, 20 }
local BROWN_GIL    = { 15, 30 }
local SUPER_GIL    = { 30, 60 }
local GIL_SCALE    = 1.0

-- The areas (lower-case zone names) that have no caskets of their own
local ZONES = {}
for name in ([[
altaieu alzadaal_undersea_ruins arrapago_reef attohwa_chasm aydeewa_subterrane batallia_downs_s beadeaux
beadeaux_s beaucedine_glacier_s bhaflau_thickets bibiki_bay caedarva_mire carpenters_landing castle_oztroja
castle_oztroja_s castle_zvahl_baileys castle_zvahl_baileys_s castle_zvahl_keep castle_zvahl_keep_s
ceizak_battlegrounds cirdas_caverns crawlers_nest_s davoi dho_gates east_ronfaure_s foret_de_hennetiel
fort_ghelsba fort_karugo_narugo_s garlaige_citadel_s ghelsba_outpost giddeus grand_palace_of_huxzoi grauberg_s
halvung jugner_forest_s kamihr_drifts la_vaule_s lufaise_meadows mamook marjami_ravine meriphataud_mountains_s
misareaux_coast moh_gates monastic_cavern morimar_basalt_fields mount_zhayolm newton_movalpolos
north_gustaberg_s oldton_movalpolos palborough_mines pashhow_marshlands_s phomiuna_aqueducts promyvion_dem
promyvion_holla promyvion_mea promyvion_vahzl psoxja qulun_dome rala_waterways riverne_site_a01
riverne_site_b01 rolanberry_fields_s sacrarium sauromugue_champaign_s sih_gates the_eldieme_necropolis_s
the_garden_of_ruhmet uleguerand_range vunkerl_inlet_s wajaom_woodlands west_sarutabaruta_s woh_gates
xarcabard_s yahse_hunting_grounds yorcia_weald yughott_grotto
]]):gmatch('%S+') do
    ZONES[name] = true
end
-----------------------------------------------------------------------------

local MODEL_BLUE, MODEL_BROWN, MODEL_SUPER = 965, 966, 969
local open = {}                                    -- [zone id] = number of extra caskets standing there

local function channel()
    return (xi.msg and xi.msg.channel and xi.msg.channel.SYSTEM_3) or 0
end

local function say(player, text)
    for _, member in pairs(player:getAlliance()) do
        if member:getZoneID() == player:getZoneID() then
            member:printToPlayer(text, channel())
        end
    end
end

local function pickWeighted(pool)
    local total = 0
    for _, entry in ipairs(pool) do
        total = total + entry[2]
    end

    local roll = math.randomFloat(0, total)
    for _, entry in ipairs(pool) do
        roll = roll - entry[2]
        if roll <= 0 then
            return entry[1]
        end
    end

    return pool[#pool][1]
end

local function poolFor(tbl, level)
    return tbl[math.min(75, math.max(5, math.ceil(level / 5) * 5))]
end

local function rollItems(pool, counts)
    local items, seen = {}, {}
    if pool == nil or #pool == 0 then
        return items
    end

    for _ = 1, utils.randomEntry(counts) do
        for _ = 1, 6 do
            local itemId = pickWeighted(pool)
            if not seen[itemId] then
                seen[itemId] = true
                items[#items + 1] = itemId
                break
            end
        end
    end

    return items
end

local function rollGil(level, range)
    return math.max(1, math.floor((BASE_GIL + level * math.randomInt(range[1], range[2])) * GIL_SCALE))
end

local function dropChance(player)
    local rate = xi.settings.main.CASKET_DROP_RATE or 0.1
    if xi.effect.PROWESS_CASKET_RATE and player:hasStatusEffect(xi.effect.PROWESS_CASKET_RATE) then
        rate = rate + player:getStatusEffect(xi.effect.PROWESS_CASKET_RATE):getPower() / 100
    end

    return math.randomFloat(0, 1) < utils.clamp(rate, 0, 1)
end

local function removeCasket(npc)
    if npc:getLocalVar('GONE') == 1 then
        return
    end

    npc:setLocalVar('GONE', 1)
    local zoneId = npc:getZoneID()
    open[zoneId] = math.max(0, (open[zoneId] or 1) - 1)
    npc:setUntargetable(true)
    npc:entityAnimationPacket(xi.animationString.STATUS_DISAPPEAR)
    npc:timer(2000, function(n)
        n:setStatus(xi.status.DISAPPEAR)
        -- (2026-11-21, Bhaflau Thickets: a gone casket left a ghost you could not walk through) setStatus only tells the
        -- players near the NPC, and the engine forgets a disappearing dynamic NPC at once, so a game that still had the
        -- casket drawn kept it, invisible but solid, until you zoned. Tell everyone in the area it is gone (the same
        -- fix as the town crowds in crowds.lua).
        pcall(function()
            n:updateToEntireZone(xi.status.DISAPPEAR, 0)
        end)
    end)
end

local function onCasketTrigger(player, npc)
    if npc:getLocalVar('GONE') == 1 or npc:getLocalVar('OPENED') == 1 then
        return
    end

    if player:getLeaderID() ~= npc:getLocalVar('PARTYID') then
        player:printToPlayer('This casket belongs to another party.', channel())
        return
    end

    player:delStatusEffect(xi.effect.INVISIBLE)
    npc:setLocalVar('OPENED', 1)
    npc:setAnimationSub(1)

    for slot = 1, 4 do
        local itemId = npc:getLocalVar('ITEM' .. slot)
        if itemId > 0 then
            player:addTreasure(itemId, npc)
        end
    end

    local gil = npc:getLocalVar('GIL')
    if gil > 0 then
        player:addGil(gil)
        player:printToPlayer(string.format('You find %d gil inside.', gil), channel())
    end

    npc:timer(4000, function(n)
        removeCasket(n)
    end)
end

local function spawnCasket(player, x, y, z, rot, level)
    local zone = player:getZone()
    local zoneId = player:getZoneID()
    if zone == nil or (open[zoneId] or 0) >= MAX_PER_ZONE then
        return nil
    end

    local model, items, gil
    if #loot.cosmetics > 0 and math.randomFloat(0, 1) < SUPER_CHANCE then
        model, items, gil = MODEL_SUPER, { utils.randomEntry(loot.cosmetics) }, rollGil(level, SUPER_GIL)
    elseif math.randomFloat(0, 1) < BROWN_CHANCE then
        model, items, gil = MODEL_BROWN, rollItems(poolFor(loot.brown, level), BROWN_COUNTS), rollGil(level, BROWN_GIL)
    else
        model, items, gil = MODEL_BLUE, rollItems(poolFor(loot.blue, level), BLUE_COUNTS), rollGil(level, BLUE_GIL)
    end

    local npc = zone:insertDynamicEntity({
        objtype    = xi.objType.NPC,
        name       = 'Extra_Casket',
        packetName = 'Treasure Casket',
        look       = model,
        x          = x,
        y          = y,
        z          = z,
        rotation   = rot or 0,
        onTrigger  = onCasketTrigger,
        releaseIdOnDisappear = true,
    })

    if npc == nil then
        return nil
    end

    open[zoneId] = (open[zoneId] or 0) + 1
    npc:setLocalVar('PARTYID', player:getLeaderID())
    npc:setLocalVar('GIL', gil)
    for slot = 1, 4 do
        npc:setLocalVar('ITEM' .. slot, items[slot] or 0)
    end

    npc:setAnimationSub(4)
    npc:setStatus(xi.status.NORMAL)
    npc:entityAnimationPacket(xi.animationString.STATUS_VISIBLE)

    if model == MODEL_SUPER then
        say(player, 'The monster was concealing a golden super casket!')
    else
        say(player, 'The monster was concealing a treasure chest!')
    end

    npc:timer(LIFETIME * 1000, function(n)
        if n:getLocalVar('OPENED') == 0 then
            removeCasket(n)
        end
    end)

    return npc
end

m:addOverride('xi.mob.onMobDeathEx', function(mob, player, isKiller, isWeaponSkillKill)
    super(mob, player, isKiller, isWeaponSkillKill)

    if
        not isKiller or
        player == nil or
        not player:isPC() or
        player:getMainJob() == xi.job.MON or
        mob:getMaster() ~= nil
    then
        return
    end

    local zone = mob:getZone()
    if zone == nil or not ZONES[string.lower(zone:getName())] then
        return
    end

    if dropChance(player) then
        local pos = mob:getPos()
        spawnCasket(player, pos.x, pos.y, pos.z, pos.rot, mob:getMainLvl())
    end
end)

-- GM test: a casket at your feet, in any area
local testCommand = {}
testCommand.cmdprops = { permission = 1, parameters = '' }
testCommand.onTrigger = function(player)
    local pos = player:getPos()
    if spawnCasket(player, pos.x, pos.y, pos.z, pos.rot, player:getMainLvl()) then
        player:printToPlayer('Extra casket spawned.', channel())
    else
        player:printToPlayer('No casket: this area already has the maximum.', channel())
    end
end

xi.module.registerCommand('extracasket', testCommand)

return m
