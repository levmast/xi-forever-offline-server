-- Forever Beta Shirt (item 25725): its own item, made from the Maat Unity Shirt (25738), which is unchanged.
-- Look: body model 399 (the game files are made by FFXISOLO\forever_beta_shirt.py). Listed in modules/init.txt so
-- dbtool puts it back after a server update. Use: modules/custom/lua/forever_beta_shirt.lua.
-- Flags as the Chariot Band: NoAuction, CanTradeNPC, CanEquip, NoSale, NoDelivery, Ex, Rare (64576).
-- 5 charges, 15 seconds to use, 15 hours between uses (54000 s). The server counts the charges itself; nothing recharges it.

REPLACE INTO `item_basic` (`itemid`,`subid`,`name`,`sortname`,`name_jp`,`type`,`stackSize`,`flags`,`aH`,`BaseSell`) VALUES (25725,0,'forever_beta_shirt','forever_beta_shirt','Forever Beta Shirt',6,1,64576,0,0);
REPLACE INTO `item_equipment` (`itemId`,`name`,`level`,`ilevel`,`jobs`,`MId`,`shieldSize`,`scriptType`,`slot`,`rslot`,`rslotlook`,`su_level`) VALUES (25725,'forever_beta_shirt',1,0,4194303,399,0,0,32,0,0,0);
REPLACE INTO `item_usable` (`itemid`,`name`,`validTargets`,`activation`,`animation`,`animationTime`,`maxCharges`,`useDelay`,`reuseDelay`,`aoe`) VALUES (25725,'forever_beta_shirt',1,1,76,0,5,15,54000,0);
REPLACE INTO `item_mods` (`itemId`,`modId`,`value`) VALUES (25725,1,1);
