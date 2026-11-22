-----------------------------------
-- Squad mate food
--
-- Squad mates eat free, modest food once they reach minLevel (10). They eat when a fight starts and again whenever
-- their food has worn off. The foods below come from your own server's food scripts, so the stats are exactly what the
-- real items give. Edit freely: change a food in a tier, move the level ranges, or add more foods to the list.
--
-- To add a food, copy its mods from scripts/items/<food>.lua (the effect:addMod lines).
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

-- The foods: duration in seconds, display name, and the stats they give (from the real items)
food.foods =
{
    ['boiled_crab'] = { name = "Boiled Crab", id = 4456, duration = 1800, mods = { { 'VIT', 2 }, { 'FOOD_DEFP', 27 }, { 'FOOD_DEF_CAP', 50 } } },
    ['boiled_crayfish'] = { name = "Boiled Crayfish", id = 4535, duration = 1800, mods = { { 'FOOD_DEFP', 30 }, { 'FOOD_DEF_CAP', 25 } } },
    ['bowl_of_seafood_stew'] = { name = "Bowl of Seafood Stew", id = 4561, duration = 10800, mods = { { 'FOOD_HP', 20 }, { 'DEX', 1 }, { 'VIT', 5 }, { 'FOOD_DEFP', 25 }, { 'FOOD_DEF_CAP', 120 } } },
    ['coeurl_sub'] = { name = "Coeurl Sub", id = 5166, duration = 1800, mods = { { 'FOOD_MP', 10 }, { 'STR', 5 }, { 'AGI', 1 }, { 'INT', -2 }, { 'HPHEAL', 1 }, { 'FOOD_ATTP', 20 }, { 'FOOD_ATT_CAP', 75 }, { 'FOOD_RATTP', 20 }, { 'FOOD_RATT_CAP', 75 }, { 'STUNRES', 4 } } },
    ['meat_mithkabob'] = { name = "Meat Mithkabob", id = 4381, duration = 1800, mods = { { 'STR', 5 }, { 'AGI', 1 }, { 'INT', -2 }, { 'FOOD_ATTP', 22 }, { 'FOOD_ATT_CAP', 60 } } },
    ['mushroom_crepe'] = { name = "Mushroom Crepe", id = 5773, duration = 1800, mods = { { 'MND', 2 }, { 'FOOD_MPP', 10 }, { 'FOOD_MP_CAP', 30 }, { 'MACC', 10 }, { 'MDEF', 5 } } },
    ['nopales_salad'] = { name = "Nopales Salad", id = 5701, duration = 10800, mods = { { 'STR', 1 }, { 'AGI', 6 }, { 'RACC', 20 }, { 'RATT', 10 } } },
    ['piece_of_cascade_candy'] = { name = "Piece of Cascade Candy", id = 5942, duration = 1800, mods = { { 'MND', 4 }, { 'CHR', 4 } } },
    ['pot-au-feu'] = { name = "Pot-au-feu", id = 5752, duration = 1800, mods = { { 'STR', 3 }, { 'AGI', 3 }, { 'INT', -3 }, { 'FOOD_RATTP', 15 }, { 'FOOD_RATT_CAP', 60 }, { 'FOOD_RACCP', 10 }, { 'FOOD_RACC_CAP', 50 }, { 'ENMITY', -3 } } },
    ['roast_pipira'] = { name = "Roast Pipira", id = 4538, duration = 1800, mods = { { 'DEX', 3 }, { 'MND', -1 }, { 'FOOD_ATTP', 14 }, { 'FOOD_ATT_CAP', 75 }, { 'FOOD_RATTP', 14 }, { 'FOOD_RATT_CAP', 75 } } },
    ['serving_of_bavarois'] = { name = "Serving of Bavarois", id = 5729, duration = 10800, mods = { { 'FOOD_HP', 20 }, { 'INT', 3 }, { 'HPHEAL', 3 } } },
    ['serving_of_black_pudding'] = { name = "Serving of Black Pudding", id = 5552, duration = 10800, mods = { { 'FOOD_MPP', 5 }, { 'FOOD_MP_CAP', 25 }, { 'FOOD_HP', 8 }, { 'INT', 4 }, { 'HPHEAL', 1 }, { 'MPHEAL', 1 } } },
    ['serving_of_crimson_jelly'] = { name = "Serving of Crimson Jelly", id = 5144, duration = 10800, mods = { { 'FOOD_MPP', 12 }, { 'FOOD_MP_CAP', 85 }, { 'INT', 6 }, { 'MPHEAL', 2 } } },
    ['serving_of_mushroom_saute'] = { name = "Serving of Mushroom Sautee", id = 5676, duration = 10800, mods = { { 'FOOD_MP', 60 }, { 'MND', 6 }, { 'MPHEAL', 6 } } },
    ['serving_of_vermillion_jelly'] = { name = "Vermillion Jelly", id = 5158, duration = 14400, mods = { { 'FOOD_MPP', 12 }, { 'FOOD_MP_CAP', 90 }, { 'INT', 6 }, { 'MPHEAL', 2 } } },
    ['slice_of_grilled_hare'] = { name = "Slice of Grilled Hare", id = 4371, duration = 10800, mods = { { 'STR', 2 }, { 'INT', -1 }, { 'FOOD_ATTP', 30 }, { 'FOOD_ATT_CAP', 15 } } },
    ['slice_of_roast_mutton'] = { name = "Slice of Roast Mutton", id = 4437, duration = 10800, mods = { { 'STR', 3 }, { 'INT', -1 }, { 'FOOD_ATTP', 27 }, { 'FOOD_ATT_CAP', 30 } } },
    ['tavnazian_taco'] = { name = "Tavnazian Taco", id = 5174, duration = 1800, mods = { { 'FOOD_HP', 20 }, { 'FOOD_MP', 20 }, { 'DEX', 4 }, { 'AGI', 4 }, { 'VIT', 6 }, { 'CHR', 4 }, { 'FOOD_DEFP', 25 }, { 'FOOD_DEF_CAP', 150 }, { 'HPHEAL', 1 }, { 'MPHEAL', 1 } } },
}

return food
