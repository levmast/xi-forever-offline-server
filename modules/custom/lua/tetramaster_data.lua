-----------------------------------
-- Tetra Master (XI: Forever Offline): card tiers, the tavern card shops and where cards drop.
-- Every number here can be changed; the server reads this file when it starts. A library: registers nothing.
--
-- Tiers come from a card's printed numbers: attack + physical defence + magical defence, plus 2 for class X and 4
-- for class A ("strength", 0-39):  Common 0-5 (42 cards), Uncommon 6-10 (90), Rare 11-16 (62), Epic 17-22 (24),
-- Legendary 23+ (32).
--
-- NOT FROM RETAIL: none of this existed in FFXI. Drop chances and prices are ours, to be tuned by playing.
-----------------------------------
local Cards = require('modules/custom/lua/tetramaster_cards')

local D = {}

D.TIERS = { 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary' }

function D.strength(id)
    local c = Cards.get(id)
    if c == nil then
        return 0
    end

    return c.attack + c.pdef + c.mdef + (({ X = 2, A = 4 })[c.type] or 0)
end

-- 1 Common .. 5 Legendary
function D.tier(id)
    local s = D.strength(id)
    if s <= 5 then
        return 1
    elseif s <= 10 then
        return 2
    elseif s <= 16 then
        return 3
    elseif s <= 22 then
        return 4
    end

    return 5
end

D.MAX_CARDS = 200                                           -- the most cards one character can keep

-- Selling a card back to any card trader (gil, by tier)
D.SELL = { 30, 80, 300, 1000, 3000 }

-----------------------------------
-- Monster drops
-----------------------------------
-- A monster family's own cards (xi.mobFamily names). Ordinary monsters drop the Common, Uncommon and Rare ones;
-- Epic and Legendary cards of a family only come from its notorious monsters.
D.FAMILY_CARDS =
{
    GOBLIN     = { 'Goblin' },
    SKELETON   = { 'Skeleton' },
    BOMB       = { 'Bomb' },
    SAHAGIN    = { 'Sahagin' },
    MIMIC      = { 'Mimic' },
    MANDRAGORA = { 'Mandragora' },
    SCORPION   = { 'Sand Scorpion' },
    CRAWLER    = { 'Crawler' },
    WORM       = { 'Carrion Worm' },
    ANTLION    = { 'Antlion' },
    TROLL      = { 'Troll' },
    TONBERRY   = { 'Tonberry', 'Master Tonberry', 'Don Tonberry' },
    AHRIMAN    = { 'Ahriman' },
    MORBOL     = { 'Malboro', 'Great Malboro', 'Malboro Menace' },
    BEHEMOTH   = { 'Behemoth', 'Behemoth King' },
    IRON_GIANT = { 'Iron Giant' },
    CERBERUS   = { 'Cerberus' },
    COEURL     = { 'Coeurl' },
    FROG       = { 'Frog' },
    FLAN       = { 'Flan', 'Dark Flan' },
    HECTEYES   = { 'Hecteyes' },
    BEETLE     = { 'Blazer Beetle' },
    GOLEM      = { 'Sand Golem' },
    GHOST      = { 'Wraith' },
    DRAGON     = { 'Red Dragon', 'Silver Dragon', 'Grand Dragon' },
}

-- Chance per kill for an ordinary monster of the family, by the card's tier (Common, Uncommon, Rare)
D.FAMILY_CHANCE = { 0.02, 0.02, 0.005 }
D.RARE_MIN_LEVEL = 30           -- ordinary monsters below this level never drop Rare cards

-- Any notorious monster of a family: this chance of one of the family's cards (any tier, the strongest first
-- when there are several above Rare)
D.NM_FAMILY_CHANCE = 0.15

-- Named notorious monsters and fights (mob names as the server knows them): { card, chance }
D.NAMED =
{
    King_Behemoth    = { 'Behemoth King', 0.08 },
    Behemoth         = { 'Behemoth', 0.20 },
    Fafnir           = { 'Grand Dragon', 0.20 },
    Nidhogg          = { 'Nova Dragon', 0.08 },
    Tonberry_Kinq    = { 'Master Tonberry', 0.15 },
    Tonberry_Pontifex = { 'Don Tonberry', 0.08 },
    Morbolger        = { 'Malboro Menace', 0.08 },
    Khimaira         = { 'Chimera', 0.20 },
    Cerberus         = { 'Cerberus', 0.25 },
    Ifrit_Prime      = { 'Ifrit', 0.25 },
    Shiva_Prime      = { 'Shiva', 0.25 },
    Titan_Prime      = { 'Titan', 0.25 },
    Garuda_Prime     = { 'Garuda', 0.25 },
    Ramuh_Prime      = { 'Ramuh', 0.25 },
    Leviathan_Prime  = { 'Leviathan', 0.25 },
    Fenrir_Prime     = { 'Fenrir', 0.25 },
    Carbuncle_Prime  = { 'Carbuncle', 0.25 },
    Odin             = { 'Odin', 0.08 },
    Bahamut          = { 'Bahamut', 0.08 },
}

-----------------------------------
-- Treasure caskets
-----------------------------------
D.CASKET_CHANCE = 0.15                          -- opening a casket: this chance of a card
D.CASKET_TIER_WEIGHTS = { 50, 35, 12, 3, 0 }    -- Common .. Legendary
D.CASKET_EPIC_MIN_LEVEL = 50                    -- below this level an Epic roll becomes Rare

-----------------------------------
-- The tavern card shops
-----------------------------------
-- 40 starter cards. Each shop sells 30 of them (the same 30 every time for one shop; shops differ a little).
-- All of them Common or weak Uncommon (strength 8 or less). None is a monster card from D.FAMILY_CARDS or an avatar
-- card: those are found, never bought.
D.SHOP_CARDS =
{
    'Fang', 'Zaghnol', 'Lizard Man', 'Zombie', 'Ironite', 'Yeti', 'Wyerd', 'Nymph', 'Zu', 'Dragonfly',
    'Chocobo', 'Fat Chocobo', 'Mog', 'Oglop', 'Gargant', 'Shoopuf', 'Monkey', 'Spira Gull', 'Ladybug', 'Mist Spawn',
    'Gimme Cat', 'Ragtime Mouse', 'Hedgehog Pie', 'Ochu', 'Ralvuimago', 'Stroper', 'Tantarian', 'Feather Circle', 'Grendel', 'Dingo',
    'Tiger Racket', 'Mythril Sword', 'Onion Knight', 'Masamune', 'Kain\'s Lance', 'Ultima Sword', 'Cargo Ship', 'Zidane', 'Kimahri', 'Mika',
}
D.SHOP_SIZE = 30

-- Price: 150 gil + 15 x strength squared (strength 0: 150 gil, 4: 390, 8: 1,110)
function D.price(id)
    local s = D.strength(id)
    return 150 + 15 * s * s
end

-- Card trader looks: '0x0100' .. face .. race .. 32 hex digits of gear (head body hands legs feet main sub ranged)
local GEAR = '00000320013003400150000000000000'
D.TRADER_LOOKS =
{
    '0x01000404' .. GEAR, -- Elvaan (f)
    '0x01000201' .. GEAR, -- Hume (m)
    '0x01000106' .. GEAR, -- Tarutaru (f)
    '0x01000307' .. GEAR, -- Mithra
    '0x01000508' .. GEAR, -- Galka
    '0x01000602' .. GEAR, -- Hume (f)
}

-- Luto Mewrilah (Upper Jeuno, G-8), who hands out the Signal Pearl on retail (Adventuring Fellows, not in this era's
-- content), is Jeuno's card trader instead. She keeps her own spot; if she is not in the zone data, she is made here.
-- fallback: where to make her (by her spot in the crowds data), and a Mithra look.
D.JEUNO =
{
    shop     = 100,                     -- her shop number (its own 30 of the 40)
    zone     = 'Upper_Jeuno',
    npc      = 'Luto_Mewrilah',
    name     = 'Luto Mewrilah',
    fallback = { x = -53.6, y = -0.1, z = 47.0, rot = 88 },
    look     = '0x01000307' .. GEAR,
    greeting = 'Luto Mewrilah: Signal pearrrls? Those days are over! Now I deal in Tetrrra Masterrr cards. Have a look!',
    -- the first time you talk to her: a free starter deck (once per character) and how to play
    starterMaxStrength = 5,             -- the five cards are different Common cards from the starter list
    welcome =
    {
        'Luto Mewrilah: A new face! Everrryone starts somewhere. Here, take this starrrter deck. On the house!',
        'Luto Mewrilah: Put a card next to your opponent\'s. If your arrrow points at it and theirs doesn\'t point back, it\'s yours!',
        'Luto Mewrilah: If both arrrows point at each other, the cards battle. Winning a battle can flip more cards in a combo!',
        'Luto Mewrilah: Open the board with /tm and play the computer for gil. Monsters and treasure caskets hide more cards. Good luck!',
    },
}

D.SHOP_RANGE = 6                                -- you must be this close to a card trader to buy or sell
D.SHOPS_FILE = 'modules/custom/lua/tetramaster_shops.lua'

-----------------------------------
-- Name lookups (built once)
-----------------------------------
local byName = {}
for id = 1, Cards.COUNT do
    local c = Cards.get(id)
    byName[c.name] = byName[c.name] or {}
    table.insert(byName[c.name], id)
end

-- All card ids with this name (a few names appear twice in the PlayOnline set: Crawler, Garuda, Iron Giant, ...)
function D.idsByName(name)
    return byName[name] or {}
end

-- The 30 cards of shop number <k> (1, 2, 3, ...): the 40 shuffled with k as the seed, first 30, in list order.
function D.shopStock(k)
    local ids = {}
    for _, name in ipairs(D.SHOP_CARDS) do
        -- a name in the set twice: the shop sells the weaker one
        local best = nil
        for _, id in ipairs(D.idsByName(name)) do
            if best == nil or D.strength(id) < D.strength(best) then
                best = id
            end
        end
        if best then
            ids[#ids + 1] = best
        end
    end

    local order = {}
    for i = 1, #ids do
        order[i] = i
    end

    local s = (k * 7919 + 17) % 2147483647
    for i = #order, 2, -1 do
        s = (s * 48271) % 2147483647
        local j = (s % i) + 1
        order[i], order[j] = order[j], order[i]
    end

    local keep = {}
    for n = 1, math.min(D.SHOP_SIZE, #order) do
        keep[order[n]] = true
    end

    local stock = {}
    for i, id in ipairs(ids) do
        if keep[i] then
            stock[#stock + 1] = id
        end
    end

    return stock
end

return D
