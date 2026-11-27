-- Forever Track Pants (item 23868, internal name forever_jeans): beta testers' legs. The look is the Track Pants' (sneakers built in, so like them they
-- block the feet slot: rslot 256); the item record is made from the Denim Pants (25911). Neither is changed. (2026-11-25, the user)
-- Look: legs model 517 (the game files are made by FFXISOLO\forever_jeans.py). Listed in modules/init.txt so dbtool
-- puts it back after a server update. Use: modules/custom/lua/forever_jeans.lua.
-- Stats: DEF:1, Fishing skill +2 (mod 127; +2 because they take the feet slot too). Use: Warp to the home point, exactly like the Warp Ring (28540): must be
-- worn 8 seconds, one charge that never runs out (maxCharges 1), 10 minutes between uses.
-- Flags as the shirt: NoAuction, CanTradeNPC, CanEquip, NoSale, NoDelivery, Ex, Rare (64576).

REPLACE INTO `item_basic` (`itemid`,`subid`,`name`,`sortname`,`name_jp`,`type`,`stackSize`,`flags`,`aH`,`BaseSell`) VALUES (23868,0,'forever_jeans','forever_jeans','Forever Track Pants',6,1,64576,0,0);
REPLACE INTO `item_equipment` (`itemId`,`name`,`level`,`ilevel`,`jobs`,`MId`,`shieldSize`,`scriptType`,`slot`,`rslot`,`rslotlook`,`su_level`) VALUES (23868,'forever_jeans',1,0,4194303,517,0,0,128,256,0,0);
REPLACE INTO `item_usable` (`itemid`,`name`,`validTargets`,`activation`,`animation`,`animationTime`,`maxCharges`,`useDelay`,`reuseDelay`,`aoe`) VALUES (23868,'forever_jeans',1,8,80,3,1,8,600,0);
DELETE FROM `item_mods` WHERE `itemId` = 23868;
INSERT INTO `item_mods` (`itemId`,`modId`,`value`) VALUES (23868,1,1),(23868,127,2);
