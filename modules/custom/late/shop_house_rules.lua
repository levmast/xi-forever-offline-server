-----------------------------------
-- Shop house rules (XI: Forever Offline, 2026-11-16; suggested by delukard on our Discord)
--   * Nation shops: your OWN nation's shops always sell their "1st place" and "top 2" items, as if your nation led
--     the conquest standings. Other nations' shops follow the normal rules (xi.shop.nation in scripts/globals/shop.lua).
--   * Guild shops: every item they stock refills to its normal level (targetStock) at each new game day, instead of a
--     few a day. Prices still follow the stock (a full shelf is the cheapest), and selling more than that to a guild
--     still works as before (overstock is trimmed back the next day, as Phoenix does).
-- Loaded from custom/late (the last line of modules/init.txt), so it runs after Phoenix's era guild shop data.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/shop')
-----------------------------------
local m = Module:new('shop_house_rules')

-- Guild shops: a full refill every day (rollShopDay adds restockRate per day, up to targetStock)
-- (2026-11-22, Yumainai, Meli: the Goldsmiths' list with blank first and last pages) Only what a guild stocks itself
-- (it starts with some, or gets some each day). The other lines are things it only resells once a player has sold
-- them to it: they have a targetStock too, and refilling those put every one of them on the shelf from the second
-- game day (at once with "Guild shops never run out"): 124 lines at the Goldsmiths' Guild, more than the game's
-- guild window can show.
local refilled = 0
for _, shop in pairs(xi.data.guildShops or {}) do
    for _, cfg in ipairs(shop.stock or {}) do
        local stocksIt = (cfg.initial or 0) > 0 or (cfg.restockRate or 0) > 0
        if stocksIt and (cfg.targetStock or 0) > 0 and (cfg.restockRate or 0) < cfg.targetStock then
            cfg.restockRate = cfg.targetStock
            refilled = refilled + 1
        end
    end
end
print(string.format('[shop_house_rules] guild shops: %d items refill to full every day', refilled))

-- Nation shops: { itemId, price, place } where place 1 = only when 1st, 2 = top two, 3 = always
m:addOverride('xi.shop.nation', function(player, stock, nation)
    if player:getNation() ~= nation then
        return super(player, stock, nation)
    end

    local newStock = {}
    for _, stockItem in ipairs(stock) do
        table.insert(newStock, { stockItem[1], stockItem[2] })
    end

    xi.shop.general(player, newStock, nation)
end)

return m
