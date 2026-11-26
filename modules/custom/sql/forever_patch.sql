-- Forever Patch (item 23867): its own item, made from the Eyepatch (11482), which is unchanged. (2026-11-25, the user)
-- Look: head model 517 (the game files are made by FFXISOLO\forever_patch.py). Listed in modules/init.txt so dbtool
-- puts it back after a server update. Use: modules/custom/lua/forever_patch.lua.
-- Stats: DEF:1, Fishing skill +1 (mod 127, as the fishermen's gear). Use: the Forever Beta Shirt's experience bonus
-- (Dedication +75%, 12 hours, up to 4000), 5 charges, 15 hours between uses. Using it never takes the fishing skill away.
-- Flags as the shirt: NoAuction, CanTradeNPC, CanEquip, NoSale, NoDelivery, Ex, Rare (64576).

REPLACE INTO `item_basic` (`itemid`,`subid`,`name`,`sortname`,`name_jp`,`type`,`stackSize`,`flags`,`aH`,`BaseSell`) VALUES (23867,0,'forever_patch','forever_patch','Forever Patch',6,1,64576,0,0);
REPLACE INTO `item_equipment` (`itemId`,`name`,`level`,`ilevel`,`jobs`,`MId`,`shieldSize`,`scriptType`,`slot`,`rslot`,`rslotlook`,`su_level`) VALUES (23867,'forever_patch',1,0,4194303,517,0,0,16,0,0,0);
REPLACE INTO `item_usable` (`itemid`,`name`,`validTargets`,`activation`,`animation`,`animationTime`,`maxCharges`,`useDelay`,`reuseDelay`,`aoe`) VALUES (23867,'forever_patch',1,1,76,0,5,15,54000,0);
DELETE FROM `item_mods` WHERE `itemId` = 23867;
INSERT INTO `item_mods` (`itemId`,`modId`,`value`) VALUES (23867,1,1),(23867,127,1);
