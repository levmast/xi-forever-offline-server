-----------------------------------
-- Fast travel for the solo server: Home Point crystals and Survival Guides.
--
-- Touch a crystal or guide: the first time it is registered, after that you can teleport to any you have registered,
-- and it costs gil like the real game.
--   Home Points:     free between Home Points of the same city; 500 gil (x2 for far places) otherwise.
--                    1/5 of that with the key item "Rhapsody in White".
--   Survival Guides: 1000 gil (1/5 with "Rhapsody in White").
-- Both flags are false: the retail windows are used (Home Point event 8700, Survival Guide event 8500).
-- The era DAT pack had cut the teleport out of the Home Point window; restore_retail_homepoints.py in the kit puts
-- the retail Home Point events back (run it again after reinstalling the era DAT pack).
-- Set a flag to true to go back to the text menus.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/teleports')
require('scripts/globals/homepoint')
require('scripts/globals/teleports/survival_guide')
local survival = require('scripts/globals/teleports/survival_guide_map')
-----------------------------------
local m = Module:new('fast_travel')

local OVERRIDE_SURVIVAL_GUIDES  = false -- false = leave the Survival Guides to the game's own menu
local USE_CUSTOM_HOMEPOINT_MENU = false -- false = use the game's own Home Point window (event 8700)
local HOMEPOINT_BASE_FEE        = 500
local GUIDE_FEE                = 1000

-- The menu box shows a title and three choices; anything else is only found by scrolling it, which is easy to miss.
-- Two entries per page keeps "More..." or "Back." on screen at every step of every list.
local PER_PAGE_HOMEPOINT = 2
local PER_PAGE_GUIDE     = 2
local PER_PAGE_REGION    = 2

-- index = the Home Point number used by the game; group = the city it belongs to (0 = on its own)
local homepoints =
{
    [  0] = { name = "Southern San d'Oria #1", group = 1, fee = 1, zone = xi.zone.SOUTHERN_SAN_DORIA, pos = { -85.554, 1, -64.554, 45 } },
    [  1] = { name = "Southern San d'Oria #2", group = 1, fee = 1, zone = xi.zone.SOUTHERN_SAN_DORIA, pos = { 44.1, 2, -34.5, 170 } },
    [  2] = { name = "Southern San d'Oria #3", group = 1, fee = 1, zone = xi.zone.SOUTHERN_SAN_DORIA, pos = { 140.5, -2, 121, 0 } },
    [  3] = { name = "Northern San d'Oria #1", group = 1, fee = 1, zone = xi.zone.NORTHERN_SAN_DORIA, pos = { -178, 4, 71, 0 } },
    [  4] = { name = "Northern San d'Oria #2", group = 1, fee = 1, zone = xi.zone.NORTHERN_SAN_DORIA, pos = { 10, -0.2, 95, 0 } },
    [  5] = { name = "Northern San d'Oria #3", group = 1, fee = 1, zone = xi.zone.NORTHERN_SAN_DORIA, pos = { 70, -0.2, 10, 0 } },
    [  6] = { name = "Port San d'Oria #1", group = 1, fee = 1, zone = xi.zone.PORT_SAN_DORIA, pos = { -38, -4, -63, 0 } },
    [  7] = { name = "Port San d'Oria #2", group = 1, fee = 1, zone = xi.zone.PORT_SAN_DORIA, pos = { 48, -12, -105, 0 } },
    [  8] = { name = "Port San d'Oria #3", group = 1, fee = 1, zone = xi.zone.PORT_SAN_DORIA, pos = { -6, -13, -150, 0 } },
    [  9] = { name = "Bastok Mines #1", group = 2, fee = 1, zone = xi.zone.BASTOK_MINES, pos = { 39, 0, -43, 0 } },
    [ 10] = { name = "Bastok Mines #2", group = 2, fee = 1, zone = xi.zone.BASTOK_MINES, pos = { 118, 1, -58, 0 } },
    [ 11] = { name = "Bastok Markets #1", group = 2, fee = 1, zone = xi.zone.BASTOK_MARKETS, pos = { -342, -10, -154, 0 } },
    [ 12] = { name = "Bastok Markets #2", group = 2, fee = 1, zone = xi.zone.BASTOK_MARKETS, pos = { -328, -12, -33, 0 } },
    [ 13] = { name = "Bastok Markets #3", group = 2, fee = 1, zone = xi.zone.BASTOK_MARKETS, pos = { -189, -8, 26, 0 } },
    [ 14] = { name = "Port Bastok #1", group = 2, fee = 1, zone = xi.zone.PORT_BASTOK, pos = { 124, 8, 7, 0 } },
    [ 15] = { name = "Port Bastok #2", group = 2, fee = 1, zone = xi.zone.PORT_BASTOK, pos = { 42, 8.5, -244, 0 } },
    [ 16] = { name = "Metalworks #1", group = 2, fee = 1, zone = xi.zone.METALWORKS, pos = { 46, -14, -19, 0 } },
    [ 17] = { name = "Windurst Waters #1", group = 3, fee = 1, zone = xi.zone.WINDURST_WATERS, pos = { -32, -5, 132, 0 } },
    [ 18] = { name = "Windurst Waters #2", group = 3, fee = 1, zone = xi.zone.WINDURST_WATERS, pos = { 138.5, 0, -14, 0 } },
    [ 19] = { name = "Windurst Walls #1", group = 3, fee = 1, zone = xi.zone.WINDURST_WALLS, pos = { -72, -5, 125, 0 } },
    [ 20] = { name = "Windurst Walls #2", group = 3, fee = 1, zone = xi.zone.WINDURST_WALLS, pos = { -212, 0, -99, 0 } },
    [ 21] = { name = "Windurst Walls #3", group = 3, fee = 1, zone = xi.zone.WINDURST_WALLS, pos = { 31, -6.5, -40, 0 } },
    [ 22] = { name = "Port Windurst #1", group = 3, fee = 1, zone = xi.zone.PORT_WINDURST, pos = { -188, -4, 101, 0 } },
    [ 23] = { name = "Port Windurst #2", group = 3, fee = 1, zone = xi.zone.PORT_WINDURST, pos = { -207, -8, 210, 0 } },
    [ 24] = { name = "Port Windurst #3", group = 3, fee = 1, zone = xi.zone.PORT_WINDURST, pos = { 180, -12, 226, 0 } },
    [ 25] = { name = "Windurst Woods #1", group = 3, fee = 1, zone = xi.zone.WINDURST_WOODS, pos = { 9, -2, 0, 0 } },
    [ 26] = { name = "Windurst Woods #2", group = 3, fee = 1, zone = xi.zone.WINDURST_WOODS, pos = { 107, -5, -56, 0 } },
    [ 27] = { name = "Windurst Woods #3", group = 3, fee = 1, zone = xi.zone.WINDURST_WOODS, pos = { -92, -5, 62, 0 } },
    [ 28] = { name = "Windurst Woods #4", group = 3, fee = 1, zone = xi.zone.WINDURST_WOODS, pos = { 74, -7, -139, 0 } },
    [ 29] = { name = "Ru'Lude Gardens #1", group = 4, fee = 1, zone = xi.zone.RULUDE_GARDENS, pos = { -6, 3, 0, 0 } },
    [ 30] = { name = "Ru'Lude Gardens #2", group = 4, fee = 1, zone = xi.zone.RULUDE_GARDENS, pos = { 53, 9, -57, 0 } },
    [ 31] = { name = "Ru'Lude Gardens #3", group = 4, fee = 1, zone = xi.zone.RULUDE_GARDENS, pos = { -67, 6, -25, 1 } },
    [ 32] = { name = "Upper Jeuno #1", group = 4, fee = 1, zone = xi.zone.UPPER_JEUNO, pos = { -99, 0, 167, 0 } },
    [ 33] = { name = "Upper Jeuno #2", group = 4, fee = 1, zone = xi.zone.UPPER_JEUNO, pos = { 32, -1, -44, 0 } },
    [ 34] = { name = "Upper Jeuno #3", group = 4, fee = 1, zone = xi.zone.UPPER_JEUNO, pos = { -52, 1, 16, 0 } },
    [ 35] = { name = "Lower Jeuno #1", group = 4, fee = 1, zone = xi.zone.LOWER_JEUNO, pos = { -99, 0, -183, 0 } },
    [ 36] = { name = "Lower Jeuno #2", group = 4, fee = 1, zone = xi.zone.LOWER_JEUNO, pos = { 18, -1, 54, 0 } },
    [ 37] = { name = "Port Jeuno #1", group = 4, fee = 1, zone = xi.zone.PORT_JEUNO, pos = { 37, 0, 9, 0 } },
    [ 38] = { name = "Port Jeuno #2", group = 4, fee = 1, zone = xi.zone.PORT_JEUNO, pos = { -155, -1, -4, 0 } },
    [ 39] = { name = "Kazham #1", group = 0, fee = 1, zone = xi.zone.KAZHAM, pos = { 78, -13, -94, 0 } },
    [ 40] = { name = "Mhaura #1", group = 0, fee = 1, zone = xi.zone.MHAURA, pos = { -13, -15, 87, 0 } },
    [ 41] = { name = "Norg #1", group = 8, fee = 1, zone = xi.zone.NORG, pos = { -27, 0, -47, 0 } },
    [ 42] = { name = "Rabao #1", group = 9, fee = 1, zone = xi.zone.RABAO, pos = { -29, 0, -76, 0 } },
    [ 43] = { name = "Selbina #1", group = 0, fee = 1, zone = xi.zone.SELBINA, pos = { 36, -11, 35, 0 } },
    [ 44] = { name = "Western Adoulin #1", group = 5, fee = 1, zone = xi.zone.WESTERN_ADOULIN, pos = { -84, 4, -32, 128 } },
    [ 45] = { name = "Eastern Adoulin #1", group = 5, fee = 1, zone = xi.zone.EASTERN_ADOULIN, pos = { -51, 0, 59, 128 } },
    [ 46] = { name = "Ceizak Battlegrounds #1", group = 0, fee = 2, zone = xi.zone.CEIZAK_BATTLEGROUNDS, pos = { -107, 3, 295, 128 } },
    [ 47] = { name = "Foret de Hennetiel #1", group = 0, fee = 2, zone = xi.zone.FORET_DE_HENNETIEL, pos = { -193, -0.5, -252, 128 } },
    [ 48] = { name = "Morimar Basalt Fields #1", group = 0, fee = 2, zone = xi.zone.MORIMAR_BASALT_FIELDS, pos = { -415, -63.2, 409, 106 } },
    [ 49] = { name = "Yorcia Weald #1", group = 0, fee = 2, zone = xi.zone.YORCIA_WEALD, pos = { -420, 0, -62, 64 } },
    [ 50] = { name = "Marjami Ravine #1", group = 0, fee = 2, zone = xi.zone.MARJAMI_RAVINE, pos = { -23, 0, 174, 0 } },
    [ 51] = { name = "Kamihr Drifts #1", group = 0, fee = 2, zone = xi.zone.KAMIHR_DRIFTS, pos = { 210, 20.299, 315, 192 } },
    [ 52] = { name = "Yughott Grotto #1", group = 0, fee = 2, zone = xi.zone.YUGHOTT_GROTTO, pos = { 434, -40, 171, 0 } },
    [ 53] = { name = "Palborough Mines #1", group = 0, fee = 2, zone = xi.zone.PALBOROUGH_MINES, pos = { 109, -38, -147, 0 } },
    [ 54] = { name = "Giddeus #1", group = 0, fee = 2, zone = xi.zone.GIDDEUS, pos = { -132, -3, -303, 0 } },
    [ 55] = { name = "Fei'Yin #1", group = 0, fee = 2, zone = xi.zone.FEIYIN, pos = { 243, -24, 62, 0 } },
    [ 56] = { name = "Quicksand Caves #1", group = 0, fee = 2, zone = xi.zone.QUICKSAND_CAVES, pos = { -984, 17, -289, 0 } },
    [ 57] = { name = "Den of Rancor #1", group = 0, fee = 2, zone = xi.zone.DEN_OF_RANCOR, pos = { -80, 46, 62, 0 } },
    [ 58] = { name = "Castle Zvahl Keep #1", group = 0, fee = 2, zone = xi.zone.CASTLE_ZVAHL_KEEP, pos = { -554, -70, 66, 0 } },
    [ 59] = { name = "Ru'Aun Gardens #1", group = 0, fee = 2, zone = xi.zone.RUAUN_GARDENS, pos = { 5, -42, 526, 0 } },
    [ 60] = { name = "Ru'Aun Gardens #3", group = 0, fee = 2, zone = xi.zone.RUAUN_GARDENS, pos = { -312, -42, -422, 0 } },
    [ 61] = { name = "Ru'Aun Gardens #2", group = 0, fee = 2, zone = xi.zone.RUAUN_GARDENS, pos = { -499, -42, 167, 0 } },
    [ 62] = { name = "Ru'Aun Gardens #4", group = 0, fee = 2, zone = xi.zone.RUAUN_GARDENS, pos = { 500, -42, 158, 0 } },
    [ 63] = { name = "Ru'Aun Gardens #5", group = 0, fee = 2, zone = xi.zone.RUAUN_GARDENS, pos = { 305, -42, -427, 0 } },
    [ 64] = { name = "Tavnazian Safehold #1", group = 6, fee = 1, zone = xi.zone.TAVNAZIAN_SAFEHOLD, pos = { -1, -28, 107, 0 } },
    [ 65] = { name = "Aht Urhgan Whitegate #1", group = 7, fee = 1, zone = xi.zone.AHT_URHGAN_WHITEGATE, pos = { -21, 0, -21, 0 } },
    [ 66] = { name = "Nashmau #1", group = 0, fee = 1, zone = xi.zone.NASHMAU, pos = { -20, 0, -25, 0 } },
    [ 67] = { name = "Al Zahbi #1 (DOESN'T CURRENTLY EXIST)", group = 0, fee = 1, zone = xi.zone.AL_ZAHBI, pos = { 0, 0, 0, 0 } },
    [ 68] = { name = "Southern San d'Oria [ S] #1", group = 0, fee = 1, zone = xi.zone.SOUTHERN_SAN_DORIA_S, pos = { -85, 1, -66, 0 } },
    [ 69] = { name = "Bastok Markets [S] #1", group = 0, fee = 1, zone = xi.zone.BASTOK_MARKETS_S, pos = { -293, -10, -102, 0 } },
    [ 70] = { name = "Windurst Waters [S] #1", group = 0, fee = 1, zone = xi.zone.WINDURST_WATERS_S, pos = { -32, -5, 131, 0 } },
    [ 71] = { name = "Upper Delkfutt's Tower #1", group = 0, fee = 2, zone = xi.zone.UPPER_DELKFUTTS_TOWER, pos = { -365, -176.5, -36, 0 } },
    [ 72] = { name = "The Shrine of Ru'Avitau #1", group = 0, fee = 2, zone = xi.zone.THE_SHRINE_OF_RUAVITAU, pos = { -13, 48, 61, 0 } },
    [ 73] = { name = "Riverne - Site #B01 #1", group = 0, fee = 2, zone = xi.zone.RIVERNE_SITE_B01, pos = { -520, -18, 505, 127 } },
    [ 74] = { name = "Bhaflau Thickets #1", group = 0, fee = 2, zone = xi.zone.BHAFLAU_THICKETS, pos = { -98, -10, -493, 192 } },
    [ 75] = { name = "Caedarva Mire #1", group = 0, fee = 2, zone = xi.zone.CAEDARVA_MIRE, pos = { -449, 13, -497, 0 } },
    [ 76] = { name = "Uleguerand Range #1", group = 0, fee = 2, zone = xi.zone.ULEGUERAND_RANGE, pos = { 64, -196, 181, 0 } },
    [ 77] = { name = "Uleguerand Range #2", group = 0, fee = 2, zone = xi.zone.ULEGUERAND_RANGE, pos = { 380, 23, -62, 0 } },
    [ 78] = { name = "Uleguerand Range #3", group = 0, fee = 2, zone = xi.zone.ULEGUERAND_RANGE, pos = { 424, -32, 221, 0 } },
    [ 79] = { name = "Uleguerand Range #4", group = 0, fee = 2, zone = xi.zone.ULEGUERAND_RANGE, pos = { 64, -96, 461, 0 } },
    [ 80] = { name = "Uleguerand Range #5", group = 0, fee = 2, zone = xi.zone.ULEGUERAND_RANGE, pos = { -220, -1, -62, 0 } },
    [ 81] = { name = "Attohwa Chasm #1", group = 0, fee = 2, zone = xi.zone.ATTOHWA_CHASM, pos = { -200, -10, 342, 0 } },
    [ 82] = { name = "Pso'Xja #1", group = 0, fee = 2, zone = xi.zone.PSOXJA, pos = { -58, 40, 14, 64 } },
    [ 83] = { name = "Newton Movalpolos #1", group = 0, fee = 2, zone = xi.zone.NEWTON_MOVALPOLOS, pos = { 445, 27, -22, 0 } },
    [ 84] = { name = "Riveren - Site #A01 #1", group = 0, fee = 2, zone = xi.zone.RIVERNE_SITE_A01, pos = { 189, 0, 362, 0 } },
    [ 85] = { name = "Al'Taieu #1", group = 0, fee = 2, zone = xi.zone.ALTAIEU, pos = { 7, 0, 709, 192 } },
    [ 86] = { name = "Al'Taieu #2", group = 0, fee = 2, zone = xi.zone.ALTAIEU, pos = { -532, 0, 447, 128 } },
    [ 87] = { name = "Al'Taieu #3", group = 0, fee = 2, zone = xi.zone.ALTAIEU, pos = { 569, 0, 410, 192 } },
    [ 88] = { name = "Grand Palace of Hu'Xzoi #1", group = 0, fee = 2, zone = xi.zone.GRAND_PALACE_OF_HUXZOI, pos = { -12, 0, -288, 192 } },
    [ 89] = { name = "The Garden of Ru'Hmet #1", group = 0, fee = 2, zone = xi.zone.THE_GARDEN_OF_RUHMET, pos = { -426, 0, 368, 224 } },
    [ 90] = { name = "Mount Zhayolm #1", group = 0, fee = 2, zone = xi.zone.MOUNT_ZHAYOLM, pos = { -540.844, -4.000, 70.809, 74 } },
    [ 91] = { name = "Cape Teriggan #1", group = 0, fee = 2, zone = xi.zone.CAPE_TERIGGAN, pos = { -303, -8, 526, 0 } },
    [ 92] = { name = "The Boyahda Tree #1", group = 0, fee = 2, zone = xi.zone.THE_BOYAHDA_TREE, pos = { 88, -15, -217, 0 } },
    [ 93] = { name = "Den of Rancor #2", group = 0, fee = 2, zone = xi.zone.DEN_OF_RANCOR, pos = { 182, 34, -62, 223 } },
    [ 94] = { name = "Fei'Yin #2", group = 0, fee = 2, zone = xi.zone.FEIYIN, pos = { 102, 0, 269, 191 } },
    [ 95] = { name = "Ifrit's Cauldron #1", group = 0, fee = 2, zone = xi.zone.IFRITS_CAULDRON, pos = { -63, 50, 81, 192 } },
    [ 96] = { name = "Quicksand Caves #2", group = 0, fee = 2, zone = xi.zone.QUICKSAND_CAVES, pos = { 573, 9, -500, 0 } },
    [ 97] = { name = "Southern San d'Oria #4", group = 1, fee = 1, zone = xi.zone.SOUTHERN_SAN_DORIA, pos = { -165, -1, 12, 65 } },
    [ 98] = { name = "Northern San d'Oria #4", group = 1, fee = 1, zone = xi.zone.NORTHERN_SAN_DORIA, pos = { -132, 12, 194, 170 } },
    [ 99] = { name = "Bastok Mines #3", group = 2, fee = 1, zone = xi.zone.BASTOK_MINES, pos = { 87, 7, 1, 0 } },
    [100] = { name = "Bastok Markets #4", group = 2, fee = 1, zone = xi.zone.BASTOK_MARKETS, pos = { -192, -6, -69, 0 } },
    [101] = { name = "Port Bastok #3", group = 2, fee = 1, zone = xi.zone.PORT_BASTOK, pos = { -127, -6, 8, 206 } },
    [102] = { name = "Metalworks #2", group = 2, fee = 1, zone = xi.zone.METALWORKS, pos = { -76, 2, 3, 124 } },
    [103] = { name = "Windurst Waters #3", group = 3, fee = 1, zone = xi.zone.WINDURST_WATERS, pos = { 5, -4, -175, 130 } },
    [104] = { name = "Norg #2", group = 8, fee = 1, zone = xi.zone.NORG, pos = { -65, -5, 54, 127 } },
    [105] = { name = "Rabao #2", group = 9, fee = 1, zone = xi.zone.RABAO, pos = { -21, 8, 110, 64 } },
    [106] = { name = "Aht Urhgan Whitegate #2", group = 7, fee = 1, zone = xi.zone.AHT_URHGAN_WHITEGATE, pos = { 130, 0, -16, 0 } },
    [107] = { name = "Aht Urhgan Whitegate #3", group = 7, fee = 1, zone = xi.zone.AHT_URHGAN_WHITEGATE, pos = { -108, -6, 108, 192 } },
    [108] = { name = "Aht Urhgan Whitegate #4", group = 7, fee = 1, zone = xi.zone.AHT_URHGAN_WHITEGATE, pos = { -99, 0, -68, 0 } },
    [109] = { name = "Western Adoulin #2", group = 5, fee = 1, zone = xi.zone.WESTERN_ADOULIN, pos = { 32, 0, -164, 32 } },
    [110] = { name = "Eastern Adoulin #2", group = 5, fee = 1, zone = xi.zone.EASTERN_ADOULIN, pos = { -51, 0, -96, 96 } },
    [111] = { name = "Xarcabard [S] #1", group = 0, fee = 2, zone = xi.zone.XARCABARD_S, pos = { 223, -13, -254, 0 } },
    [112] = { name = "Leafallia #1", group = 0, fee = 2, zone = xi.zone.LEAFALLIA, pos = { 5.539, -0.434, 8.133, 73 } },
    [113] = { name = "Castle Zvahl Keep [S] #1", group = 0, fee = 2, zone = xi.zone.CASTLE_ZVAHL_KEEP_S, pos = { -554, -70, 66, 128 } },
    [114] = { name = "Qufim Island #1", group = 0, fee = 1, zone = xi.zone.QUFIM_ISLAND, pos = { -212, -21, 93, 64 } },
    [115] = { name = "Toraimorai Canal #1", group = 0, fee = 1, zone = xi.zone.TORAIMARAI_CANAL, pos = { -257.5, 24, 82, 192 } },
    [116] = { name = "Ra'Kaznar Inner Court #1", group = 0, fee = 2, zone = xi.zone.RAKAZNAR_INNER_COURT, pos = { 757, 120, 17.5, 128 } },
    [117] = { name = "Misareaux Coast #1", group = 0, fee = 2, zone = xi.zone.MISAREAUX_COAST, pos = { -65, -17.5, 563, 224 } },
    [118] = { name = "Windurst Waters #4", group = 3, fee = 1, zone = xi.zone.WINDURST_WATERS, pos = { -92, -2, 54, 155 } },
    [119] = { name = "Windurst Woods #5", group = 3, fee = 1, zone = xi.zone.WINDURST_WOODS, pos = { -43.5, 0, -145, 0 } },
    [120] = { name = "Tavnazian Safehold #2", group = 6, fee = 1, zone = xi.zone.TAVNAZIAN_SAFEHOLD, pos = { 14, -9.96, -5, 0 } },
    [121] = { name = "Tavnazian Safehold #3", group = 6, fee = 1, zone = xi.zone.TAVNAZIAN_SAFEHOLD, pos = { 73.59, -36.149, 38.87, 0 } },
}

local homepointRegions =
{
    { group = 1, name = "San d'Oria" },
    { group = 2, name = 'Bastok' },
    { group = 3, name = 'Windurst' },
    { group = 4, name = 'Jeuno' },
    { group = 7, name = 'Aht Urhgan' },
    { group = 6, name = 'Tavnazia' },
    { group = 8, name = 'Norg' },
    { group = 9, name = 'Rabao' },
    { group = 5, name = 'Adoulin' },
    { group = 0, name = 'Other places' },
}

local guideRegions =
{
    { group = 1, name = 'Zones - list 1' },
    { group = 2, name = 'Zones - list 2' },
    { group = 3, name = '[S] zones, cities' },
    { group = 4, name = 'Adoulin, Zeruhn' },
}

-----------------------------------
-- Helpers
-----------------------------------
local function tell(player, text)
    local channel = (xi.msg and xi.msg.channel and xi.msg.channel.SYSTEM_3) or 0
    player:printToPlayer(text, channel)
end

-- Opens the next menu a moment later: a menu cannot reliably be opened from inside another menu's choice.
local function later(player, func)
    player:timer(250, function(entity)
        func(entity)
    end)
end

local function costText(cost)
    if cost == 0 then
        return 'free'
    end

    return string.format('%dg', cost)
end

-- The zone constants have no punctuation in them, so the guide list reads "San Doria" and "Feiyin" without these.
local zoneNameFixes =
{
    { 'San Doria',      "San d'Oria" },
    { 'Rulude',         "Ru'Lude" },
    { 'Ruaun',          "Ru'Aun" },
    { 'Ruavitau',       "Ru'Avitau" },
    { 'Altaieu',        "Al'Taieu" },
    { 'Huxzoi',         "Hu'Xzoi" },
    { 'Ruhmet',         "Ru'Hmet" },
    { 'Psoxja',         "Pso'Xja" },
    { 'Feiyin',         "Fei'Yin" },
    { 'Ifrits',         "Ifrit's" },
    { 'Carpenters',     "Carpenter's" },
    { 'Ordelles',       "Ordelle's" },
    { 'Crawlers',       "Crawlers'" },
    { 'Ranperres',      "Ranperre's" },
    { 'Delkfutts',      "Delkfutt's" },
    { 'Karugo Narugo',  'Karugo-Narugo' },
    { 'Riverne Site A01', 'Riverne - Site #A01' },
    { 'Riverne Site B01', 'Riverne - Site #B01' },
}

local zoneNameCache = nil
local function zoneName(zoneId)
    if zoneNameCache == nil then
        zoneNameCache = {}
        local small = { OF = true, THE = true, IN = true }
        for name, id in pairs(xi.zone) do
            if type(id) == 'number' and zoneNameCache[id] == nil then
                local words = {}
                local first = true
                for word in string.gmatch(name, '[^_]+') do
                    if small[word] and not first then
                        words[#words + 1] = string.lower(word)
                    elseif word == 'S' then
                        words[#words + 1] = '[S]'
                    else
                        words[#words + 1] = string.upper(string.sub(word, 1, 1)) .. string.lower(string.sub(word, 2))
                    end

                    first = false
                end

                local text = table.concat(words, ' ')
                for _, fix in ipairs(zoneNameFixes) do
                    text = string.gsub(text, fix[1], fix[2])
                end

                zoneNameCache[id] = text
            end
        end
    end

    return zoneNameCache[zoneId] or ('Zone ' .. tostring(zoneId))
end

local function hasRhapsody(player)
    return xi.keyItem.RHAPSODY_IN_WHITE ~= nil and player:hasKeyItem(xi.keyItem.RHAPSODY_IN_WHITE)
end

-- A page of choices: entries = { { label = '...', run = function(player) end }, ... }
local function pagedMenu(player, title, entries, page, backFunc, perPage)
    perPage = perPage or PER_PAGE_HOMEPOINT
    local pages = math.max(1, math.ceil(#entries / perPage))
    page = math.max(1, math.min(page, pages))

    local options = {}
    for i = (page - 1) * perPage + 1, math.min(#entries, page * perPage) do
        options[#options + 1] = { entries[i].label, entries[i].run }
    end

    -- "More..." replaces "Back." on every page but the last, so the box never needs to scroll to reach it.
    if page < pages then
        options[#options + 1] =
        {
            'More...',
            function(playerArg)
                later(playerArg, function(entity)
                    pagedMenu(entity, title, entries, page + 1, backFunc, perPage)
                end)
            end,
        }
    elseif backFunc then
        options[#options + 1] =
        {
            'Back.',
            function(playerArg)
                later(playerArg, backFunc)
            end,
        }
    end

    player:setFreezeFlag(true)
    player:customMenu({
        title = pages > 1 and string.format('%s %d/%d', title, page, pages) or title,
        options = options,
        onCancelled = function(playerArg)
            -- cancel goes back a step instead of dropping out of the whole menu
            if backFunc then
                later(playerArg, backFunc)
            else
                playerArg:setFreezeFlag(false)
            end
        end,
        onEnd = function(playerArg)
            playerArg:setFreezeFlag(false)
        end,
    })
end

-----------------------------------
-- Home Points
-----------------------------------
local function hasHomePoint(player, index)
    return player:hasTeleport(xi.teleport.type.HOMEPOINT, index % 32, math.floor(index / 32))
end

local function homepointCost(player, from, to)
    local origin, target = homepoints[from], homepoints[to]
    if origin == nil or target == nil then
        return 0
    end

    if origin.group == target.group and target.group ~= 0 then
        return 0
    end

    local cost = HOMEPOINT_BASE_FEE * target.fee
    if hasRhapsody(player) then
        cost = math.floor(cost / 5)
    end

    return cost
end

local function homepointTeleport(player, from, to)
    local target = homepoints[to]
    if target == nil or not hasHomePoint(player, to) then
        return
    end

    local cost = homepointCost(player, from, to)
    if player:getGil() < cost then
        tell(player, string.format('You need %d gil to teleport to %s.', cost, target.name))
        return
    end

    if cost > 0 then
        player:delGil(cost)
    end

    -- (2026-11-18, Yumainai) the game's own window plays a warp effect before the jump; the text menu teleported
    -- instantly. Play the Warp spell's animation (261) on the player, then move after it.
    player:setFreezeFlag(true)
    player:injectActionPacket(player:getID(), 4, 261, 0, 0, 0, 0, 0)
    player:timer(2500, function(entity)
        entity:setFreezeFlag(false)
        entity:setPos(target.pos[1], target.pos[2], target.pos[3], target.pos[4], target.zone)
    end)
end

local function homepointDestinations(player, origin, group)
    local found  = {}
    local common = nil
    local mixed  = false

    for index = 0, 255 do
        local hp = homepoints[index]
        if hp ~= nil and index ~= origin and hp.group == group and hasHomePoint(player, index) then
            local cost = homepointCost(player, origin, index)
            if common == nil then
                common = cost
            elseif cost ~= common then
                mixed = true
            end

            found[#found + 1] = { index = index, name = hp.name, cost = cost }
        end
    end

    -- When every destination costs the same the price goes in the title, so the names are not shortened.
    local entries = {}
    for _, hp in ipairs(found) do
        local index = hp.index
        local label = hp.name
        if mixed then
            label = label .. ' ' .. costText(hp.cost)
        end

        entries[#entries + 1] =
        {
            label = label,
            -- Run after the menu closes: a zone change sent from inside the custom menu is dropped.
            run = function(playerArg)
                later(playerArg, function(entity)
                    homepointTeleport(entity, origin, index)
                end)
            end,
        }
    end

    return entries, (not mixed) and common or nil
end

local function homepointRegionMenu(player, origin)
    local regions = {}
    for _, region in ipairs(homepointRegions) do
        local count = #homepointDestinations(player, origin, region.group)
        if count > 0 then
            regions[#regions + 1] = { group = region.group, name = region.name, count = count }
        end
    end

    if #regions == 0 then
        player:setFreezeFlag(false)
        tell(player, 'You have not registered any other Home Points yet. Touch a Home Point crystal to register it.')
        return
    end

    local function showRegion(entity, region)
        local entries, cost = homepointDestinations(entity, origin, region.group)
        local title = 'Home Point: ' .. region.name
        if cost ~= nil then
            title = title .. ' (' .. costText(cost) .. ')'
        end

        local back = (#regions > 1) and function(e) homepointRegionMenu(e, origin) end or nil
        pagedMenu(entity, title, entries, 1, back, PER_PAGE_HOMEPOINT)
    end

    if #regions == 1 then
        showRegion(player, regions[1])
        return
    end

    local entries = {}
    for _, region in ipairs(regions) do
        local target = region
        entries[#entries + 1] =
        {
            label = string.format('%s (%d)', target.name, target.count),
            run = function(playerArg)
                later(playerArg, function(entity)
                    showRegion(entity, target)
                end)
            end,
        }
    end

    pagedMenu(player, 'Where to?', entries, 1, nil, PER_PAGE_REGION)
end

local function homepointMenu(player, npc, index)
    player:setFreezeFlag(true)
    local options = {}
    if xi.settings.main.HOMEPOINT_TELEPORT == 1 then -- (classic travel: only "set home point")
        options[#options + 1] =
        {
            'Teleport.',
            function(playerArg)
                later(playerArg, function(entity)
                    homepointRegionMenu(entity, index)
                end)
            end,
        }
    end

    options[#options + 1] =
            {
                'Set as your home point.',
                function(playerArg)
                    if npc and playerArg:checkDistance(npc) <= 6 then
                        npc:entityAnimationPacket(xi.animationString.EFFECT_HOME_POINT, playerArg)
                        playerArg:setHomePoint()
                    end

                    local text = zones[playerArg:getZoneID()].text
                    if text.HOMEPOINT_SET then
                        playerArg:messageSpecial(text.HOMEPOINT_SET)
                    end
                end,
            }
    options[#options + 1] = { 'Never mind.', function(playerArg) end }

    player:customMenu({
        title = 'What will you do?',
        options = options,
        onCancelled = function(playerArg)
            playerArg:setFreezeFlag(false)
        end,
        onEnd = function(playerArg)
            playerArg:setFreezeFlag(false)
        end,
    })
end

-- Off by default: the base handler sends event 8700, which is the retail menu.
if USE_CUSTOM_HOMEPOINT_MENU then
    m:addOverride('xi.homepoint.onTrigger', function(player, csid, index)
        -- homepoint_heal is replaced by this override; keep its full heal.
        player:addHP(player:getMaxHP())
        player:addMP(player:getMaxMP())

        local npc = player:getCursorTarget()
        local hpBit, hpSet = index % 32, math.floor(index / 32)

        -- touching a crystal registers it
        if not player:hasTeleport(xi.teleport.type.HOMEPOINT, hpBit, hpSet) then
            player:addTeleport(xi.teleport.type.HOMEPOINT, hpBit, hpSet)
            tell(player, 'You have registered this Home Point.')
        end

        homepointMenu(player, npc, index)
    end)
end

-- Retail window: keep the full heal on touch, then the game's own Home Point menu.
-- Zones whose era files keep the retail Home Point entries but the era text (Yumainai, 2026-11-17: the Metalworks
-- crystals showed chocobo text, one did nothing; Qufim Island is the same) can't show the game's window, so their
-- crystals use the text menu above.
-- (2026-11-18) Back to the game's own window everywhere (the user: retail-like menus). A re-check found the era text
-- and Home Point events in Metalworks and Qufim match each other (same event program and the same Home Point text
-- lines as Bastok Mines), so the text menu is off; add a zone here again only if a crystal is shown to break.
local TEXT_MENU_ZONES =
{
    -- [xi.zone.METALWORKS]   = true,
    -- [xi.zone.QUFIM_ISLAND] = true,
}

if not USE_CUSTOM_HOMEPOINT_MENU then
    m:addOverride('xi.homepoint.onTrigger', function(player, csid, index)
        player:addHP(player:getMaxHP())
        player:addMP(player:getMaxMP())
        if TEXT_MENU_ZONES[player:getZoneID()] then
            local hpBit, hpSet = index % 32, math.floor(index / 32)
            if not player:hasTeleport(xi.teleport.type.HOMEPOINT, hpBit, hpSet) then
                player:addTeleport(xi.teleport.type.HOMEPOINT, hpBit, hpSet)
                tell(player, 'You have registered this Home Point.')
            end

            homepointMenu(player, player:getCursorTarget(), index)
            return
        end

        super(player, csid, index)
    end)
end

-- (2026-11-22, Yumainai, kupo-8) Home Point #1 of Port San d'Oria, Bastok Markets, Port Bastok and Port Windurst stands
-- at its pre-2015 spot (Phoenix). A teleport from another zone lands there (homepoint.lua), but a teleport inside the
-- same zone is done by the game itself, with today's spot from its own files: you landed where the crystal no longer
-- is. After such a jump the server puts you next to the crystal.
local MOVED_HOMEPOINTS =
{
    [ 6] = { -66.077,  -4, -104.948, 192, xi.zone.PORT_SAN_DORIA },
    [11] = { -293.791, -10, -102.539, 160, xi.zone.BASTOK_MARKETS },
    [14] = { 53.645,   7.5,  -28.682, 224, xi.zone.PORT_BASTOK },
    [22] = { -67.980,  -4,   110.675, 192, xi.zone.PORT_WINDURST },
}

m:addOverride('xi.homepoint.onEventFinish', function(player, csid, option, event)
    super(player, csid, option, event)
    if csid ~= event or bit.band(option, 0xFF) ~= 3 or xi.settings.main.HOMEPOINT_TELEPORT ~= 1 then
        return
    end

    local dest = MOVED_HOMEPOINTS[bit.rshift(option, 16)]
    if dest and dest[5] == player:getZoneID() then
        player:timer(1500, function(entity)
            if entity:getZoneID() == dest[5] then
                entity:setPos(dest[1], dest[2], dest[3], dest[4])
            end
        end)
    end
end)

-----------------------------------
-- Survival Guides
-----------------------------------
local function hasGuide(player, guide)
    return player:hasTeleport(xi.teleport.type.SURVIVAL, guide.groupIndex - 1, guide.group - 1)
end

local function guideCost(player)
    return hasRhapsody(player) and math.floor(GUIDE_FEE / 5) or GUIDE_FEE
end

local function guideTeleport(player, guideId)
    local guide = survival.survivalGuides[guideId]
    if guide == nil or not hasGuide(player, guide) then
        return
    end

    local cost = guideCost(player)
    if player:getGil() < cost then
        tell(player, string.format('You need %d gil to travel there.', cost))
        return
    end

    player:delGil(cost)
    player:setFreezeFlag(false)
    player:setPos(guide.posX, guide.posY, guide.posZ, guide.posRot, guide.zoneId)
end

local function guideDestinations(player, currentZone, group)
    local ids = {}
    for guideId, guide in pairs(survival.survivalGuides) do
        if guide.group == group and guide.zoneId ~= currentZone and hasGuide(player, guide) then
            ids[#ids + 1] = guideId
        end
    end

    table.sort(ids)

    local entries = {}
    for _, guideId in ipairs(ids) do
        local id = guideId
        entries[#entries + 1] =
        {
            label = zoneName(survival.survivalGuides[id].zoneId),
            -- Run after the menu closes, for the same reason as the Home Point entries.
            run = function(playerArg)
                later(playerArg, function(entity)
                    guideTeleport(entity, id)
                end)
            end,
        }
    end

    return entries
end

local function guideRegionMenu(player, currentZone)
    local regions = {}
    for _, region in ipairs(guideRegions) do
        local count = #guideDestinations(player, currentZone, region.group)
        if count > 0 then
            regions[#regions + 1] = { group = region.group, name = region.name, count = count }
        end
    end

    if #regions == 0 then
        player:setFreezeFlag(false)
        tell(player, 'You have not registered any other Survival Guides yet. Touch a Survival Guide to register it.')
        return
    end

    local fee = costText(guideCost(player))

    local function showRegion(entity, region)
        local back = (#regions > 1) and function(e) guideRegionMenu(e, currentZone) end or nil
        local title = string.format('Survival Guide: %s (%s)', region.name, fee)
        pagedMenu(entity, title, guideDestinations(entity, currentZone, region.group), 1, back, PER_PAGE_GUIDE)
    end

    if #regions == 1 then
        showRegion(player, regions[1])
        return
    end

    local entries = {}
    for _, region in ipairs(regions) do
        local target = region
        entries[#entries + 1] =
        {
            label = string.format('%s (%d)', target.name, target.count),
            run = function(playerArg)
                later(playerArg, function(entity)
                    showRegion(entity, target)
                end)
            end,
        }
    end

    pagedMenu(player, string.format('Where to? (%s)', fee), entries, 1, nil, PER_PAGE_REGION)
end

-- (2026-11-20, Yumainai: the Ru'Lude Gardens guide showed another NPC's lines and a menu with a blank choice) The era
-- game files replace an area's event file but not its text file. They were made for the October 2026 game version; the
-- November update added lines to some areas' text, so there the retail Survival Guide window (event 8500) points at
-- the wrong lines. In the areas listed here the guide opens our own menu instead, which needs nothing from the game
-- files. Take an area out again once the era files have caught up with the game version (Phoenix's Era-DATs).
local SURVIVAL_TEXT_ZONES =
{
    [xi.zone.RULUDE_GARDENS] = true,
}

local function guideTextMenu(player, zoneId, guide, ownLines)
    -- touching a guide registers it
    if not hasGuide(player, guide) then
        local text = zones[guide.zoneId].text
        if not ownLines and text.COMMON_SENSE_SURVIVAL then
            player:messageSpecial(text.COMMON_SENSE_SURVIVAL)
        else
            -- (in a listed area the game's own line for this would be a wrong one too)
            tell(player, 'You have registered this Survival Guide.')
        end

        player:addTeleport(xi.teleport.type.SURVIVAL, guide.groupIndex - 1, guide.group - 1)
    end

    player:setFreezeFlag(true)
    guideRegionMenu(player, zoneId)
end

-- Classic switch (launcher CONFIG > Rates "Survival Guide teleports", main.ENABLE_SURVIVAL_GUIDE = 0): the guides do
-- nothing, like before they existed. (Home Point teleports have their own setting, main.HOMEPOINT_TELEPORT, which the
-- game's Home Point script already reads.)
m:addOverride('xi.survivalGuide.onTrigger', function(player)
    if xi.settings.main.ENABLE_SURVIVAL_GUIDE == 0 then
        tell(player, 'Survival Guide teleports are switched off on this world (classic travel).')
        return
    end

    local zoneId   = player:getZoneID()
    local ownLines = SURVIVAL_TEXT_ZONES[zoneId] == true
    if OVERRIDE_SURVIVAL_GUIDES or ownLines then
        local guide = survival.survivalGuides[survival.zoneIdToGuideIdMap[zoneId]]
        if guide ~= nil then
            guideTextMenu(player, zoneId, guide, ownLines)
            return
        end
    end

    return super(player)
end)

return m
