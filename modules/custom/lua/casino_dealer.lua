-----------------------------------
-- Casino Dealer (XI: Forever Offline, 2026-11-21, idea by The-Yache)
-- A dealer in Southern San d'Oria, Bastok Markets, Windurst Woods and Lower Jeuno. Trade gil, pick "Roll", and you and
-- the dealer each roll 0-999 (the same range as /random). Roll higher and you get double your bet back; a tie gives the
-- bet back; roll lower and the bet is gone.
--
-- Why the NPC rolls for the player: the server's /random is answered inside the map server and never reaches a script,
-- and /random is blocked while an NPC event is open, so a script cannot read the player's own /random.
--
-- Safety: the trade is completed like any NPC trade, so the bet is taken when it is handed over and the window closes
-- cleanly. The bet is also written to a char var until it is played, so a bet that is walked away from, cancelled or
-- cut off by a disconnect is paid back at the next visit.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('casino_dealer')

local MAX_ROLL = 1000 -- rolls are 0-999

local dealers =
{
    { zone = 'Southern_San_dOria', x = 47.5,   y = 2,   z = -34.5, rot = 170 },
    { zone = 'Bastok_Markets',     x = -325.0, y = -12, z = -33.0, rot = 128 },
    { zone = 'Windurst_Woods',     x = 12.0,   y = -2,  z = 0.0,   rot = 128 },
    { zone = 'Lower_Jeuno',        x = 21.0,   y = -1,  z = 54.0,  rot = 128 },
}

local DEALER_NAME = 'Lucky Dealer'
local LOOK        = '0x0100020500101120003000400050006000700000' -- a Hume (m), same format as the examples in test_npcs_in_gm_home.lua

local function say(player, npc, text)
    player:printToPlayer(text, 0, npc:getPacketName())
end

local function gilText(n)
    local s = tostring(n)
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

-- The bet is taken for good when the trade is completed (tradeComplete), like any NPC trade: an unfinished trade left the
-- game window waiting, so the winnings only showed after zoning. While the bet is on the table it is also written to a
-- char var, so a player who disconnects, zones or walks away from the menu gets it back (paid at their next visit).
local PENDING = '[Casino]Pending'

-- Give gil back to the player in one step and check the balance moved; sets it directly if add did not take.
local function payOut(player, amount)
    if amount <= 0 then
        return true
    end

    local before = player:getGil()
    player:addGil(amount)

    if player:getGil() == before + amount then
        return true
    end

    player:setGil(before + amount)

    if player:getGil() == before + amount then
        print(string.format('[casino_dealer] addGil did not change gil for %s; set it directly instead', player:getName()))
        return true
    end

    print(string.format('[casino_dealer] could not pay %d gil to %s (had %d, has %d)', amount, player:getName(), before, player:getGil()))
    return false
end

-- pays back a bet that was never played; the marker is cleared first so it can never be paid twice
local function refundPending(player, npc)
    local bet = player:getCharVar(PENDING)
    if bet <= 0 then
        return
    end

    player:setCharVar(PENDING, 0)

    if payOut(player, bet) then
        say(player, npc, string.format('Your bet of %s gil was not played. It is returned.', gilText(bet)))
    else
        player:setCharVar(PENDING, bet)
        say(player, npc, 'I could not return your bet just now. Talk to me again in a moment.')
    end
end

local function play(player, npc, bet)
    player:setFreezeFlag(false)

    if player:getCharVar(PENDING) ~= bet then
        return -- the bet is no longer on the table (already played or refunded)
    end

    local mine   = math.random(0, MAX_ROLL - 1)
    local theirs = math.random(0, MAX_ROLL - 1)

    player:setCharVar(PENDING, 0)

    say(player, npc, string.format('Dice Roll! %s rolls %d.', player:getName(), mine))
    say(player, npc, string.format('Dice Roll! %s rolls %d.', DEALER_NAME, theirs))

    if mine > theirs then
        if payOut(player, bet * 2) then
            say(player, npc, string.format('You win! Your %s gil is doubled: %s gil paid out.', gilText(bet), gilText(bet * 2)))
        else
            player:setCharVar(PENDING, bet * 2) -- it will be paid at the next visit
            say(player, npc, 'You win, but I could not pay just now. Talk to me again in a moment.')
        end
    elseif mine == theirs then
        if payOut(player, bet) then
            say(player, npc, 'A tie! Your bet is returned.')
        else
            player:setCharVar(PENDING, bet)
            say(player, npc, 'A tie, but I could not return your bet just now. Talk to me again in a moment.')
        end
    else
        say(player, npc, string.format('The house wins. You lose %s gil.', gilText(bet)))
    end
end

local function offerBet(player, npc, bet)
    player:setFreezeFlag(true)
    player:customMenu({
        title = string.format('Bet %s gil?', gilText(bet)),
        options =
        {
            {
                'Roll the dice!',
                function(playerArg)
                    -- run after the menu closes
                    playerArg:timer(50, function(entity)
                        play(entity, npc, bet)
                    end)
                end,
            },
            {
                'Never mind.',
                function(playerArg)
                    playerArg:setFreezeFlag(false)
                    playerArg:timer(50, function(entity)
                        refundPending(entity, npc)
                    end)
                end,
            },
        },
        onCancelled = function(playerArg)
            playerArg:setFreezeFlag(false)
            playerArg:timer(50, function(entity)
                refundPending(entity, npc)
            end)
        end,
        onEnd = function(playerArg)
            playerArg:setFreezeFlag(false)
        end,
    })
end

local function onTrade(player, npc, trade)
    local bet = trade:getGil()

    -- gil in a trade takes one slot, so a gil-only trade has an item count of 1 (like other gil trades in the scripts)
    if bet > 0 and trade:getItemCount() == 1 then
        refundPending(player, npc) -- an older bet that was never played comes back first

        if player:getCharVar(PENDING) ~= 0 then
            return
        end

        player:setCharVar(PENDING, bet)

        if player:tradeComplete() then
            offerBet(player, npc, bet)
        else
            player:setCharVar(PENDING, 0)
            say(player, npc, 'Something went wrong with the trade. Nothing was taken.')
        end
    else
        say(player, npc, 'Gil only, please. Trade me the amount you want to bet.')
    end
end

local function onTrigger(player, npc)
    refundPending(player, npc)
    say(player, npc, 'Feeling lucky? Trade me the gil you want to bet. We each roll 0 to 999. Roll higher and I double your gil; a tie gives it back.')
end

local spawned = {}

local function spawnDealer(zone, d)
    local npc = zone:insertDynamicEntity({
        objtype    = xi.objType.NPC,
        name       = 'CasinoDealer_' .. d.zone,
        packetName = DEALER_NAME,
        look       = LOOK,
        x          = d.x,
        y          = d.y,
        z          = d.z,
        rotation   = d.rot,
        widescan   = 1,
        onTrade    = onTrade,
        onTrigger  = onTrigger,
    })

    if npc then
        spawned[d.zone] = npc:getID()
    end
end

for _, d in ipairs(dealers) do
    local dealer = d

    m:addOverride('xi.zones.' .. dealer.zone .. '.Zone.onInitialize', function(zone)
        super(zone)

        local ok, err = pcall(spawnDealer, zone, dealer)
        if not ok then
            print('[casino_dealer] ' .. dealer.zone .. ': ' .. tostring(err))
        end
    end)
end

return m
