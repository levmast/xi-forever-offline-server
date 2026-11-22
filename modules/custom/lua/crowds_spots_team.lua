-- Spots the team marked in game with !crowd mark and sent in. Shipped with the game and read by crowds.lua
-- (zoneSpots), next to each player's own crowds_spots_user.lua. !crowd mark never writes this file.
-- kind = 'fish': where bot players stand to fish (bots_craft.lua). A port with none marked has no bots fishing.
-- 2026-11-22: fishing spots by Tasou (2 to 4 per port).
return {
    [249] = { -- Mhaura
        { kind = 'fish', x = -28.313, y = -4.000, z = 13.902, rot = 63 },
        { kind = 'fish', x = -42.648, y = -3.948, z = 16.666, rot = 73 },
        { kind = 'fish', x = -5.709, y = -1.148, z = 23.338, rot = 63 },
    },
    [232] = { -- Port San d'Oria
        { kind = 'fish', x = 26.799, y = -1.000, z = -50.192, rot = 161 },
        { kind = 'fish', x = 46.135, y = -1.000, z = -44.700, rot = 191 },
    },
    [240] = { -- Port Windurst
        { kind = 'fish', x = -194.301, y = -2.000, z = 71.430, rot = 130 },
        { kind = 'fish', x = -1.699, y = -3.000, z = 75.806, rot = 2 },
        { kind = 'fish', x = 21.297, y = -2.000, z = 57.755, rot = 252 },
        { kind = 'fish', x = -6.360, y = -3.000, z = 19.186, rot = 135 },
    },
    [248] = { -- Selbina
        { kind = 'fish', x = -2.109, y = -0.740, z = -29.955, rot = 45 },
        { kind = 'fish', x = -24.769, y = -0.966, z = -30.925, rot = 66 },
        { kind = 'fish', x = 7.833, y = -2.338, z = -22.268, rot = 74 },
    },
    [236] = { -- Port Bastok
        { kind = 'fish', x = 86.272, y = 8.500, z = -83.400, rot = 72 },
        { kind = 'fish', x = 107.067, y = 9.100, z = -87.300, rot = 69 },
        { kind = 'fish', x = 132.503, y = 9.100, z = -86.518, rot = 36 },
    },
}
