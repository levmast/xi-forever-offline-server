-----------------------------------
-- No battle music (levi, 2026-11-26)
--
-- Fights keep playing the zone's normal background music: at server start every zone's solo and party
-- battle music is set to its background track (every zone here uses one track for day and night).
-- Instances without their own music override follow their zone. Scripted events that pick their own
-- fight music (pirates, Besieged, Einherjar) are left alone.
--
-- Switch (GM, saved across restarts):  !battlemusic off   fights keep zone music (default)
--                                       !battlemusic on    normal battle music again
--                                       !battlemusic       shows the current setting
-- The change applies right away for players online. To remove the module entirely, comment out its
-- line in modules/init.txt and restart the server.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('no_battle_music')

local VAR         = '[NoBattleMusic]Restore' -- 1 = normal battle music, unset/0 = zone music in fights
local SLOT_SOLO   = xi.musicSlot and xi.musicSlot.COMBAT_SOLO or 2
local SLOT_PARTY  = xi.musicSlot and xi.musicSlot.COMBAT_PARTY or 3

local original = {} -- [zoneId] = { solo, party } as loaded from the zone data

local function forEachZone(fn)
    local seen = {}
    for _, id in pairs(xi.zone or {}) do
        if type(id) == 'number' and not seen[id] then
            seen[id] = true
            local zone = GetZone(id)
            if zone then
                fn(id, zone)
            end
        end
    end
end

local function apply(quiet)
    local restore = GetServerVariable(VAR) == 1
    local count   = 0

    forEachZone(function(id, zone)
        if original[id] == nil then
            original[id] = { zone:getSoloBattleMusic(), zone:getPartyBattleMusic() }
        end

        local solo, party
        if restore then
            solo, party = original[id][1], original[id][2]
        else
            local bgm = zone:getBackgroundMusicDay()
            solo, party = bgm, bgm
        end

        zone:setSoloBattleMusic(solo)
        zone:setPartyBattleMusic(party)
        count = count + 1

        -- players already in the zone get it now instead of on their next zone change
        for _, player in pairs(zone:getPlayers() or {}) do
            if not player:getInstance() then
                player:changeMusic(SLOT_SOLO, solo)
                player:changeMusic(SLOT_PARTY, party)
            end
        end
    end)

    if not quiet then
        print(string.format('[no_battle_music] %d zones: %s', count,
            restore and 'normal battle music' or 'zone music in fights'))
    end

    return restore
end

m:addOverride('xi.server.onServerStart', function()
    super()

    local ok, err = pcall(apply, false)
    if not ok then
        print('[no_battle_music] ' .. tostring(err))
    end
end)

xi.module.registerCommand('battlemusic',
{
    cmdprops =
    {
        permission = 1,
        parameters = 's',
    },

    onTrigger = function(player, arg)
        arg = arg and string.lower(arg) or ''

        if arg == 'on' then
            SetServerVariable(VAR, 1)
        elseif arg == 'off' then
            SetServerVariable(VAR, 0)
        elseif arg ~= '' then
            player:printToPlayer('!battlemusic off  (fights keep zone music)   !battlemusic on  (normal battle music)')
            return
        end

        local restore
        if arg == '' then
            restore = GetServerVariable(VAR) == 1
        else
            restore = apply(true)
        end

        player:printToPlayer(restore and
            'Battle music: ON (normal battle music). Use !battlemusic off to keep zone music in fights.' or
            'Battle music: OFF (fights keep zone music). Use !battlemusic on to bring it back.')
    end,
})

return m
