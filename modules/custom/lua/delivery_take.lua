-----------------------------------
-- XI: Forever Offline (2026-11-26, Quaiton; the user said yes): !deliverybox takes everything waiting in your
-- delivery box (ventures, phone fishing, gifts...) into your inventory at once, until the inventory is full.
-- The moving is done in C++ (modules/custom/cpp/delivery_take.cpp: DeliveryTakeAll).
-----------------------------------
require('modules/module_utils')

local m = Module:new('delivery_take')

local function say(player, text)
    player:printToPlayer(text, xi.msg.channel.SYSTEM_3)
end

local command = {}
command.cmdprops = { permission = 0, parameters = '' } -- every player may use it on their own character

command.onTrigger = function(player)
    if type(DeliveryTakeAll) ~= 'function' then
        say(player, 'The delivery box command needs the newer map server (update first).')
        return
    end

    local taken, left, why = DeliveryTakeAll(player:getID())
    taken, left, why = taken or 0, left or 0, why or ''

    if why == 'open' then
        say(player, 'Close the delivery box window first, then use !deliverybox again.')
        return
    end

    if taken == 0 and left == 0 then
        say(player, 'Your delivery box is empty.')
        return
    end

    local text = string.format('Took %d item%s from your delivery box.', taken, taken == 1 and '' or 's')
    if left > 0 then
        if why == 'full' then
            text = text .. string.format(' Your inventory is full: %d still waiting.', left)
        else
            text = text .. string.format(' %d left (Rare items you already have stay in the box).', left)
        end
    end

    say(player, text)
end

xi.module.registerCommand('deliverybox', command)

return m
