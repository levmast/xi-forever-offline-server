-- Forever Beta Shirt (item 25725): its own item, made from the Maat Unity Shirt (25738), which is unchanged.
-- Look: body model 399 (the game files are made by FFXISOLO\forever_beta_shirt.py). Listed in modules/init.txt so
-- dbtool puts it back after a server update. Use: modules/custom/lua/forever_beta_shirt.lua.
-- Flags as the Chariot Band: NoAuction, CanTradeNPC, CanEquip, NoSale, NoDelivery, Ex, Rare (64576).
-- 5 charges, 15 seconds to use, 15 hours between uses (54000 s). The server counts the charges itself; nothing recharges it.

REPLACE INTO `item_basic` (`itemid`,`subid`,`name`,`sortname`,`name_jp`,`type`,`stackSize`,`flags`,`aH`,`BaseSell`) VALUES (25725,0,'forever_beta_shirt','forever_beta_shirt','Forever Beta Shirt',6,1,64576,0,0);
REPLACE INTO `item_equipment` (`itemId`,`name`,`level`,`ilevel`,`jobs`,`MId`,`shieldSize`,`scriptType`,`slot`,`rslot`,`rslotlook`,`su_level`) VALUES (25725,'forever_beta_shirt',1,0,4194303,399,0,0,32,0,0,0);
REPLACE INTO `item_usable` (`itemid`,`name`,`validTargets`,`activation`,`animation`,`animationTime`,`maxCharges`,`useDelay`,`reuseDelay`,`aoe`) VALUES (25725,'forever_beta_shirt',1,1,76,0,5,15,54000,0);
REPLACE INTO `item_mods` (`itemId`,`modId`,`value`) VALUES (25725,1,1);

-- One more shirt for anyone who threw the first one away (2026-11-22). Until v0.1.59 the shirt showed on player installs
-- as a nameless Lv127 item ("."), and people dropped it. Once per character: a character that was given the shirt
-- ([FBShirt]Given) and has none left, in any bag or in the delivery box, gets another one in the delivery box.
-- Marker char var [FBShirt]Reissue: 1 = to send (only while this file runs), 2 = sent, the game tells the player at the
-- next login (forever_beta_shirt.lua), 3 = done or nothing needed. This file is imported again at every server update:
-- a character that has a marker is never looked at again, so nobody gets a third shirt. The launcher imports each file
-- as one transaction, so a stop half way leaves nothing behind.
INSERT IGNORE INTO `char_vars` (`charid`,`varname`,`value`)
SELECT v.`charid`, '[FBShirt]Reissue', 1 FROM `char_vars` v
WHERE v.`varname` = '[FBShirt]Given' AND v.`value` <> 0
  AND NOT EXISTS (SELECT 1 FROM `char_inventory` i WHERE i.`charid` = v.`charid` AND i.`itemId` = 25725)
  AND NOT EXISTS (SELECT 1 FROM `delivery_box` d WHERE d.`charid` = v.`charid` AND d.`itemid` = 25725);
INSERT IGNORE INTO `char_vars` (`charid`,`varname`,`value`)
SELECT v.`charid`, '[FBShirt]Reissue', 3 FROM `char_vars` v
WHERE v.`varname` = '[FBShirt]Given' AND v.`value` <> 0;
INSERT INTO `delivery_box` (`charid`,`box`,`itemid`,`quantity`,`senderid`,`sender`)
SELECT r.`charid`, 1, 25725, 1, r.`charid`, 'Forever Offline' FROM `char_vars` r
WHERE r.`varname` = '[FBShirt]Reissue' AND r.`value` = 1;
UPDATE `char_vars` SET `value` = 2 WHERE `varname` = '[FBShirt]Reissue' AND `value` = 1;
