-----------------------------------
-- Squad mate food
--
-- Squad mates eat free, modest food once they reach minLevel (10). They eat when a fight starts and again whenever
-- their food has worn off. The foods below come from your own server's food scripts, so the stats are exactly what the
-- real items give. Edit freely: change a food in a tier, move the level ranges, or add more foods to the list.
--
-- To add a food, copy its mods from scripts/items/<food>.lua (the effect:addMod lines).
--
-- (2026-11-22, Altair) You can also tell a mate what to eat: !squad food <slot>. Each food is unlocked once for its
-- average auction house price; after that any of your mates may eat it, free as before (squad_meals.lua).
-----------------------------------
local food = {}

food.enabled  = true
food.minLevel = 10
food.speakOnEat = true -- the squad mate announces what they are eating

-- Which kind of food each job eats (job ids: 1 WAR, 2 MNK, 3 WHM, 4 BLM, 5 RDM, 6 THF, 7 PLD, 8 DRK, 9 BST, 10 BRD, 11 RNG, 12 SAM, 13 NIN, 14 DRG, 15 SMN)
food.roleByJob =
{
    [1] = 'attack', [2] = 'attack', [3] = 'healer', [4] = 'mage', [5] = 'mage', [6] = 'attack', [7] = 'tank', [8] = 'attack',
    [9] = 'attack', [10] = 'mage', [11] = 'ranged', [12] = 'attack', [13] = 'attack', [14] = 'attack', [15] = 'mage',
    [16] = 'attack', [17] = 'ranged', [18] = 'attack', -- BLU, COR, PUP
    [19] = 'attack', [20] = 'mage',                    -- DNC, SCH (2026-11-22)
}

-- Level ranges, and the food each kind of job eats in each range
food.tiers =
{
    { from = 10, to = 25, foods = { attack = 'slice_of_grilled_hare', tank = 'boiled_crayfish', ranged = 'roast_pipira', mage = 'serving_of_bavarois', healer = 'piece_of_cascade_candy' } },
    { from = 26, to = 45, foods = { attack = 'slice_of_roast_mutton', tank = 'boiled_crab', ranged = 'roast_pipira', mage = 'serving_of_black_pudding', healer = 'mushroom_crepe' } },
    { from = 46, to = 65, foods = { attack = 'meat_mithkabob', tank = 'bowl_of_seafood_stew', ranged = 'nopales_salad', mage = 'serving_of_crimson_jelly', healer = 'serving_of_mushroom_saute' } },
    { from = 66, to = 75, foods = { attack = 'coeurl_sub', tank = 'tavnazian_taco', ranged = 'pot-au-feu', mage = 'serving_of_vermillion_jelly', healer = 'serving_of_mushroom_saute' } },
}

-- The foods: duration in seconds, display name, and the stats they give (from the real items).
-- kind = which jobs it is listed for when you choose a mate's food (!squad food <slot>); price = what one costs on
-- the auction house on average (the launcher's price file), which is what unlocking that choice costs, once per
-- character. Foods marked "no auction price" are not on that list and carry a round figure.
food.foods =
{
    ['apple_pie'] = { name = "Apple Pie", id = 4413, duration = 1800, kind = 'mage', price = 300, mods = { { 'FOOD_MP', 25 }, { 'AGI', -1 }, { 'INT', 3 } } },
    ['boiled_crab'] = { name = "Boiled Crab", id = 4456, duration = 1800, kind = 'tank', price = 2000, mods = { { 'VIT', 2 }, { 'FOOD_DEFP', 27 }, { 'FOOD_DEF_CAP', 50 } } },
    ['boiled_crayfish'] = { name = "Boiled Crayfish", id = 4535, duration = 1800, kind = 'tank', price = 800, mods = { { 'FOOD_DEFP', 30 }, { 'FOOD_DEF_CAP', 25 } } },
    ['bowl_of_seafood_stew'] = { name = "Bowl of Seafood Stew", id = 4561, duration = 10800, kind = 'tank', price = 5900, mods = { { 'FOOD_HP', 20 }, { 'DEX', 1 }, { 'VIT', 5 }, { 'FOOD_DEFP', 25 }, { 'FOOD_DEF_CAP', 120 } } },
    ['coeurl_sub'] = { name = "Coeurl Sub", id = 5166, duration = 1800, kind = 'attack', price = 2000, mods = { { 'FOOD_MP', 10 }, { 'STR', 5 }, { 'AGI', 1 }, { 'INT', -2 }, { 'HPHEAL', 1 }, { 'FOOD_ATTP', 20 }, { 'FOOD_ATT_CAP', 75 }, { 'FOOD_RATTP', 20 }, { 'FOOD_RATT_CAP', 75 }, { 'STUNRES', 4 } } },
    ['cream_puff'] = { name = "Cream Puff", id = 5718, duration = 1800, kind = 'mage', price = 2000, mods = { { 'INT', 7 }, { 'FOOD_HP', -10 } } }, -- no auction price
    ['dhalmel_steak'] = { name = "Dhalmel Steak", id = 4438, duration = 10800, kind = 'attack', price = 2000, mods = { { 'STR', 4 }, { 'INT', -2 }, { 'FOOD_ATTP', 25 }, { 'FOOD_ATT_CAP', 45 } } },
    ['dragon_steak'] = { name = "Dragon Steak", id = 4350, duration = 10800, kind = 'attack', price = 9000, mods = { { 'FOOD_HP', 25 }, { 'STR', 7 }, { 'INT', -3 }, { 'HPHEAL', 2 }, { 'MPHEAL', 2 }, { 'FOOD_ATTP', 20 }, { 'FOOD_ATT_CAP', 150 }, { 'FOOD_RATTP', 20 }, { 'FOOD_RATT_CAP', 150 }, { 'DEMON_KILLER', 5 } } }, -- no auction price
    ['fish_chiefkabob'] = { name = "Fish Chiefkabob", id = 4575, duration = 3600, kind = 'tank', price = 1500, mods = { { 'DEX', 1 }, { 'VIT', 2 }, { 'MND', -1 }, { 'FOOD_DEFP', 25 }, { 'FOOD_DEF_CAP', 95 } } },
    ['fish_mithkabob'] = { name = "Fish Mithkabob", id = 4398, duration = 1800, kind = 'tank', price = 1000, mods = { { 'DEX', 1 }, { 'VIT', 2 }, { 'MND', -1 }, { 'FOOD_DEFP', 25 }, { 'FOOD_DEF_CAP', 90 } } },
    ['hedgehog_pie'] = { name = "Hedgehog Pie", id = 5146, duration = 10800, kind = 'attack', price = 10500, mods = { { 'FOOD_HP', 55 }, { 'STR', 6 }, { 'VIT', 2 }, { 'INT', -3 }, { 'MND', 3 }, { 'HPHEAL', 2 }, { 'MPHEAL', 2 }, { 'FOOD_ATTP', 18 }, { 'FOOD_ATT_CAP', 90 }, { 'ACC', 5 }, { 'FOOD_RATTP', 18 }, { 'FOOD_RATT_CAP', 90 } } },
    ['jack-o-lantern'] = { name = "Jack-o'-Lantern", id = 4488, duration = 10800, kind = 'attack', price = 3000, mods = { { 'CHR', -10 }, { 'ACC', 10 }, { 'RACC', 10 }, { 'EVA', 10 }, { 'ARCANA_KILLER', 4 }, { 'DARK_MEVA', 25 } } },
    ['meat_chiefkabob'] = { name = "Meat Chiefkabob", id = 4574, duration = 3600, kind = 'attack', price = 1800, mods = { { 'STR', 5 }, { 'AGI', 1 }, { 'INT', -2 }, { 'FOOD_ATTP', 22 }, { 'FOOD_ATT_CAP', 65 } } },
    ['meat_mithkabob'] = { name = "Meat Mithkabob", id = 4381, duration = 1800, kind = 'attack', price = 740, mods = { { 'STR', 5 }, { 'AGI', 1 }, { 'INT', -2 }, { 'FOOD_ATTP', 22 }, { 'FOOD_ATT_CAP', 60 } } },
    ['melon_pie'] = { name = "Melon Pie", id = 4421, duration = 1800, kind = 'mage', price = 500, mods = { { 'FOOD_MP', 25 }, { 'AGI', -1 }, { 'INT', 4 } } },
    ['mushroom_crepe'] = { name = "Mushroom Crepe", id = 5773, duration = 1800, kind = 'healer', price = 2000, mods = { { 'MND', 2 }, { 'FOOD_MPP', 10 }, { 'FOOD_MP_CAP', 30 }, { 'MACC', 10 }, { 'MDEF', 5 } } }, -- no auction price
    ['nopales_salad'] = { name = "Nopales Salad", id = 5701, duration = 10800, kind = 'ranged', price = 3000, mods = { { 'STR', 1 }, { 'AGI', 6 }, { 'RACC', 20 }, { 'RATT', 10 } } }, -- no auction price
    ['pear_crepe'] = { name = "Pear Crepe", id = 5777, duration = 1800, kind = 'healer', price = 2000, mods = { { 'INT', 2 }, { 'FOOD_MACCP', 20 }, { 'FOOD_MACC_CAP', 45 }, { 'MDEF', 1 }, { 'MPHEAL', 2 } } }, -- no auction price
    ['piece_of_cascade_candy'] = { name = "Piece of Cascade Candy", id = 5942, duration = 1800, kind = 'healer', price = 1000, mods = { { 'MND', 4 }, { 'CHR', 4 } } }, -- no auction price
    ['plate_of_bream_sushi'] = { name = "Bream Sushi", id = 5176, duration = 1800, kind = 'attack', price = 1200, mods = { { 'DEX', 6 }, { 'VIT', 5 }, { 'FOOD_ACCP', 16 }, { 'FOOD_ACC_CAP', 76 }, { 'FOOD_RACCP', 16 }, { 'FOOD_RACC_CAP', 76 }, { 'SLEEPRES', 1 } } },
    ['plate_of_crab_sushi'] = { name = "Crab Sushi", id = 5721, duration = 1800, kind = 'tank', price = 2000, mods = { { 'VIT', 1 }, { 'DEF', 10 }, { 'FOOD_ACCP', 13 }, { 'FOOD_ACC_CAP', 64 }, { 'SLEEPRES', 1 } } }, -- no auction price
    ['plate_of_sole_sushi'] = { name = "Sole Sushi", id = 5149, duration = 1800, kind = 'attack', price = 2500, mods = { { 'FOOD_HP', 20 }, { 'STR', 5 }, { 'DEX', 6 }, { 'FOOD_ACCP', 15 }, { 'FOOD_ACC_CAP', 72 }, { 'FOOD_RACCP', 15 }, { 'FOOD_RACC_CAP', 72 }, { 'SLEEPRES', 1 } } },
    ['plate_of_squid_sushi'] = { name = "Squid Sushi", id = 5148, duration = 1800, kind = 'ranged', price = 1200, mods = { { 'FOOD_HP', 30 }, { 'DEX', 6 }, { 'AGI', 5 }, { 'MND', -1 }, { 'FOOD_ACCP', 15 }, { 'FOOD_ACC_CAP', 72 }, { 'FOOD_RACCP', 15 }, { 'FOOD_RACC_CAP', 72 }, { 'SLEEPRES', 1 } } },
    ['pot-au-feu'] = { name = "Pot-au-feu", id = 5752, duration = 1800, kind = 'ranged', price = 3000, mods = { { 'STR', 3 }, { 'AGI', 3 }, { 'INT', -3 }, { 'FOOD_RATTP', 15 }, { 'FOOD_RATT_CAP', 60 }, { 'FOOD_RACCP', 10 }, { 'FOOD_RACC_CAP', 50 }, { 'ENMITY', -3 } } }, -- no auction price
    ['pumpkin_pie'] = { name = "Pumpkin Pie", id = 4446, duration = 1800, kind = 'mage', price = 800, mods = { { 'FOOD_MP', 40 }, { 'AGI', -1 }, { 'INT', 3 }, { 'CHR', -2 } } },
    ['rice_dumpling'] = { name = "Rice Dumpling", id = 4271, duration = 1800, kind = 'attack', price = 690, mods = { { 'FOOD_HP', 17 }, { 'STR', 3 }, { 'VIT', 2 }, { 'AGI', 1 }, { 'FOOD_ATTP', 20 }, { 'FOOD_ATT_CAP', 45 }, { 'FOOD_RATTP', 30 }, { 'FOOD_RATT_CAP', 45 }, { 'HPHEAL', 2 }, { 'MPHEAL', 2 }, { 'ACC', 5 }, { 'PARALYZERES', 4 } } },
    ['roast_pipira'] = { name = "Roast Pipira", id = 4538, duration = 1800, kind = 'ranged', price = 300, mods = { { 'DEX', 3 }, { 'MND', -1 }, { 'FOOD_ATTP', 14 }, { 'FOOD_ATT_CAP', 75 }, { 'FOOD_RATTP', 14 }, { 'FOOD_RATT_CAP', 75 } } },
    ['rolanberry_pie'] = { name = "Rolanberry Pie", id = 4414, duration = 1800, kind = 'mage', price = 1000, mods = { { 'FOOD_MP', 50 }, { 'AGI', -1 }, { 'INT', 2 } } },
    ['serving_of_bavarois'] = { name = "Serving of Bavarois", id = 5729, duration = 10800, kind = 'mage', price = 2000, mods = { { 'FOOD_HP', 20 }, { 'INT', 3 }, { 'HPHEAL', 3 } } }, -- no auction price
    ['serving_of_bison_steak'] = { name = "Bison Steak", id = 5142, duration = 10800, kind = 'attack', price = 7000, mods = { { 'STR', 6 }, { 'AGI', 1 }, { 'INT', -3 }, { 'FOOD_ATTP', 18 }, { 'FOOD_ATT_CAP', 90 }, { 'FOOD_RATTP', 18 }, { 'FOOD_RATT_CAP', 90 }, { 'LIZARD_KILLER', 5 } } },
    ['serving_of_black_pudding'] = { name = "Serving of Black Pudding", id = 5552, duration = 10800, kind = 'mage', price = 2000, mods = { { 'FOOD_MPP', 5 }, { 'FOOD_MP_CAP', 25 }, { 'FOOD_HP', 8 }, { 'INT', 4 }, { 'HPHEAL', 1 }, { 'MPHEAL', 1 } } },
    ['serving_of_crimson_jelly'] = { name = "Serving of Crimson Jelly", id = 5144, duration = 10800, kind = 'mage', price = 11000, mods = { { 'FOOD_MPP', 12 }, { 'FOOD_MP_CAP', 85 }, { 'INT', 6 }, { 'MPHEAL', 2 } } },
    ['serving_of_mushroom_saute'] = { name = "Serving of Mushroom Sautee", id = 5676, duration = 10800, kind = 'healer', price = 3000, mods = { { 'FOOD_MP', 60 }, { 'MND', 6 }, { 'MPHEAL', 6 } } }, -- no auction price
    ['serving_of_vermillion_jelly'] = { name = "Vermillion Jelly", id = 5158, duration = 14400, kind = 'mage', price = 30000, mods = { { 'FOOD_MPP', 12 }, { 'FOOD_MP_CAP', 90 }, { 'INT', 6 }, { 'MPHEAL', 2 } } },
    ['slice_of_grilled_hare'] = { name = "Slice of Grilled Hare", id = 4371, duration = 10800, kind = 'attack', price = 800, mods = { { 'STR', 2 }, { 'INT', -1 }, { 'FOOD_ATTP', 30 }, { 'FOOD_ATT_CAP', 15 } } },
    ['slice_of_roast_mutton'] = { name = "Slice of Roast Mutton", id = 4437, duration = 10800, kind = 'attack', price = 1000, mods = { { 'STR', 3 }, { 'INT', -1 }, { 'FOOD_ATTP', 27 }, { 'FOOD_ATT_CAP', 30 } } },
    ['tavnazian_salad'] = { name = "Tavnazian Salad", id = 4279, duration = 10800, kind = 'ranged', price = 6000, mods = { { 'FOOD_HP', 20 }, { 'FOOD_MP', 20 }, { 'DEX', 4 }, { 'AGI', 4 }, { 'VIT', 6 }, { 'CHR', 4 }, { 'FOOD_DEFP', 25 }, { 'FOOD_DEF_CAP', 150 } } },
    ['tavnazian_taco'] = { name = "Tavnazian Taco", id = 5174, duration = 1800, kind = 'tank', price = 2000, mods = { { 'FOOD_HP', 20 }, { 'FOOD_MP', 20 }, { 'DEX', 4 }, { 'AGI', 4 }, { 'VIT', 6 }, { 'CHR', 4 }, { 'FOOD_DEFP', 25 }, { 'FOOD_DEF_CAP', 150 }, { 'HPHEAL', 1 }, { 'MPHEAL', 1 } } },
}

-- The kinds, in the order the food menu lists them
food.kinds = { 'attack', 'tank', 'ranged', 'mage', 'healer' }
food.kindNames = { attack = 'Fighter food', tank = 'Tank food', ranged = 'Ranged food', mage = 'Mage food', healer = 'Healer food' }

return food
