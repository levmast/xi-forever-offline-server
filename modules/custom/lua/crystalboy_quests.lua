-----------------------------------
-- FFXI Offline: the Gobbiebag quests give Crystal Boy items instead of bag space.
--
-- Every character starts with 80-slot bags here, so the original quests (which need the bag to be exactly
-- 30, 35, ... 75) could never start. This module rebuilds them around the same NPC (Bluffnix, Lower Jeuno),
-- the 75-era fame (Jeuno 3, 4, 5, 5, 6, 6, 7, 7, 8, 9, as Phoenix's era module sets) and the same trade (four materials, or a Bowl of Goblin Stew):
--   * a part can start once the previous part is complete (Part I: no requirement) and Jeuno fame is high enough,
--   * Bluffnix tells his own story in the chat log instead of the bag cutscenes: crystals remember old adventures,
--     the Crystal Boy is a goblin-found mechanism that plays them, and each cartridge is a Recollection of one adventure,
--   * the reward is a Crystal Boy item instead of 5 more slots.
-- Parts without a reward yet stay closed, as they were.
--   Part I  -> Crystal Boy (8100)
--   Part II -> Jueno Recollection I   (8101, plays Legend of Jueno)
--   Part III -> Jueno Recollection II  (8102, Legend of Jueno 2)
--   Part IV  -> Jueno Recollection III (8103, Legend of Jueno 3)
--   Part V   -> Jueno Recollection IV  (8104, Legend of Jueno 4)
-- After each: finish the game in the Crystal Boy (play time, see the addon's rewards.lua), then bring the Recollection
-- back to Bluffnix: a Memory key item (+1% monster exp under Signet, they add up), Page from the Dragon Chronicles,
-- Anniversary Ring, and 10,000 / 15,000 / 20,000 / 25,000 gil. Once per character.
--
-- GM test helper: !cbfame <1-9> sets San d'Oria, Bastok and Windurst fame (Jeuno fame follows them).
-- It needs GM level 1 or more, so normal characters cannot use it.
-----------------------------------
require('modules/module_utils')
require('scripts/globals/npc_util')
-----------------------------------
local m = Module:new('crystalboy_quests')

-- Bags (the launcher's "Full bags from the start", storage_config.lua; missing = on). On: every bag opens at 80 at log
-- in. Off: the classic way, 30 slots and +5 for each Gobbiebag part (the Crystal Boy parts still give their items).
-- (one table, not more file-level locals: kept small on purpose)
local bags =
{
    full = function()
        local ok, cfg = pcall(require, 'modules/custom/lua/storage_config')
        return not (ok and type(cfg) == 'table' and cfg.full_bags == false)
    end,

    all = { 'INVENTORY', 'MOGSAFE', 'MOGSATCHEL', 'MOGSACK', 'MOGCASE', 'WARDROBE', 'WARDROBE2', 'WARDROBE3', 'WARDROBE4',
            'WARDROBE5', 'WARDROBE6', 'WARDROBE7', 'WARDROBE8' },
}

local CRYSTAL_BOY = 8100

-- Rewards for finishing a Recollection (a Game Boy game) in the Crystal Boy, handed over by Bluffnix once per character.
-- titles = the ROM's internal title(s), as the addon records them in its claims file (DX and original versions)
-- memory = key item: +1% exp from monsters while Signet is active (one per finished Recollection, they add up)
local RECOLLECTIONS =
{
    [8101] =
    {
        titles  = { 'SEIKEN DENSETSU', 'FINAL FANTASY ADV', 'FF ADVENTURE', 'MYSTIC QUEST', 'JUENO LEG 1JUNO' },
        game    = 'Legend of Jueno',
        memory  = 1634, -- "Memory of Jueno I" (key item text written by install_crystalboy_items.py)
        items   = { 4198, 15793 }, -- Page from the Dragon Chronicles, Anniversary Ring (no longer Rare: they stack)
        gil     = 10000,
        var     = '[CB]Done8101',
        story   = 'You saw how it ends? Tell Bluffnix everything! ...The road, the city, the people... hmm, hmm... Bluffnix has goosebumps.',
    },
    [8102] =
    {
        titles  = { 'SAGA', 'JUENO LEG 2JUNO' },
        game    = 'Legend of Jueno 2',
        memory  = 2605, -- "Memory of Jueno II"
        items   = { 4198, 15793 },
        gil     = 15000,
        var     = '[CB]Done8102',
        story   = 'The second part, all the way to the end? Hmm! Bluffnix will think about that one for a long time.',
    },
    [8103] =
    {
        titles  = { 'SAGA2 DX', 'SAGA2', 'JUENO LEG 3JUNO' },
        game    = 'Legend of Jueno 3',
        memory  = 2841, -- "Memory of Jueno III"
        items   = { 4198, 15793 },
        gil     = 20000,
        var     = '[CB]Done8103',
        story   = 'So that is how the whole legend ends! Bluffnix knew it! ...Bluffnix hoped it, anyway.',
    },
    [8104] =
    {
        titles  = { 'SAGA3 DX', 'SAGA3', 'JUENO LEG 4JUNO' },
        game    = 'Legend of Jueno 4',
        memory  = 2716, -- "Memory of Jueno IV"
        items   = { 4198, 15793 },
        gil     = 25000,
        var     = '[CB]Done8104',
        story   = 'All four parts, right to the very end? Bluffnix has to sit down. What a story!',
    },
}

local MEMORY_KEY_ITEMS = {}
for _, r in pairs(RECOLLECTIONS) do table.insert(MEMORY_KEY_ITEMS, r.memory) end

-- reward = item id, or nil while that part has no reward yet (the part then stays closed)
local parts =
{
    { file = 'The_Gobbiebag_Part_I',    quest = 'THE_GOBBIEBAG_PART_I',    prev = nil,                       size = 30, fame = 3, reward = CRYSTAL_BOY,
      items = { 'SQUARE_OF_DHALMEL_LEATHER', 'STEEL_INGOT', 'SQUARE_OF_LINEN_CLOTH', 'PERIDOT' } },
    { file = 'The_Gobbiebag_Part_II',   quest = 'THE_GOBBIEBAG_PART_II',   prev = 'THE_GOBBIEBAG_PART_I',    size = 35, fame = 4, reward = 8101,
      items = { 'SQUARE_OF_RAM_LEATHER', 'MYTHRIL_INGOT', 'SQUARE_OF_WOOL_CLOTH', 'TURQUOISE' }, recollection = 8101 },
    { file = 'The_Gobbiebag_Part_III',  quest = 'THE_GOBBIEBAG_PART_III',  prev = 'THE_GOBBIEBAG_PART_II',   size = 40, fame = 5, reward = 8102,
      items = { 'SQUARE_OF_BLACK_TIGER_LEATHER', 'GOLD_INGOT', 'SQUARE_OF_VELVET_CLOTH', 'PAINITE' }, recollection = 8102 },
    { file = 'The_Gobbiebag_Part_IV',   quest = 'THE_GOBBIEBAG_PART_IV',   prev = 'THE_GOBBIEBAG_PART_III',  size = 45, fame = 5, reward = 8103,
      items = { 'CERMET_CHUNK', 'DARKSTEEL_INGOT', 'SQUARE_OF_SILK_CLOTH', 'GOSHENITE' }, recollection = 8103 },
    { file = 'The_Gobbiebag_Part_V',    quest = 'THE_GOBBIEBAG_PART_V',    prev = 'THE_GOBBIEBAG_PART_IV',   size = 50, fame = 6, reward = 8104,
      items = { 'RHODONITE', 'PAKTONG_INGOT', 'SQUARE_OF_MOBLINWEAVE', 'SQUARE_OF_BUGARD_LEATHER' }, recollection = 8104 },
    { file = 'The_Gobbiebag_Part_VI',   quest = 'THE_GOBBIEBAG_PART_VI',   prev = 'THE_GOBBIEBAG_PART_V',    size = 55, fame = 6, reward = nil,
      items = { 'SHAKUDO_INGOT', 'SQUARE_OF_BALLON_CLOTH', 'IOLITE', 'HIGH_QUALITY_EFT_SKIN' } },
    { file = 'The_Gobbiebag_Part_VII',  quest = 'THE_GOBBIEBAG_PART_VII',  prev = 'THE_GOBBIEBAG_PART_VI',   size = 60, fame = 7, reward = nil,
      items = { 'SQUARE_OF_LYNX_LEATHER', 'ADAMAN_INGOT', 'SQUARE_OF_RAINBOW_CLOTH', 'DEATHSTONE' } },
    { file = 'The_Gobbiebag_Part_VIII', quest = 'THE_GOBBIEBAG_PART_VIII', prev = 'THE_GOBBIEBAG_PART_VII',  size = 65, fame = 7, reward = nil,
      items = { 'SQUARE_OF_SMILODON_LEATHER', 'ELECTRUM_INGOT', 'SQUARE_OF_CILICE', 'ANGELSTONE' } },
    { file = 'The_Gobbiebag_Part_IX',   quest = 'THE_GOBBIEBAG_PART_IX',   prev = 'THE_GOBBIEBAG_PART_VIII', size = 70, fame = 8, reward = nil,
      items = { 'ORICHALCUM_INGOT', 'SQUARE_OF_PEISTE_LEATHER', 'SQUARE_OF_OIL_SOAKED_CLOTH', 'OXBLOOD_ORB' } },
    { file = 'The_Gobbiebag_Part_X',    quest = 'THE_GOBBIEBAG_PART_X',    prev = 'THE_GOBBIEBAG_PART_IX',   size = 75, fame = 9, reward = nil,
      items = { 'MOLYBDENUM_INGOT', 'SQUARE_OF_GRIFFON_LEATHER', 'SQUARE_OF_FOULARD', 'ANGEL_SKIN_ORB' } },
}

-- Bluffnix's own words for the Crystal Boy parts (the game's cutscenes only talk about bags).
-- Lines are spoken in the chat log, about two seconds apart.
local talk =
{
    lowFame =
    {
        'Hmph. Bluffnix does not know you.',
        'Bluffnix only shows his treasures to adventurers the people of Jeuno talk about. Come back when they say your name.',
    },
    recollection =
    {
        noTablet =
        {
            'Where is the Recollection? Bluffnix wants to hold it while you tell the story. Bring it in your bag!',
        },
        notYet =
        {
            'How far did you get? ...Not to the end yet? The tablet still hums with the unfinished part.',
            'Keep playing! When you have seen how the story ends, come and tell Bluffnix.',
        },
        finish =
        {
            'The crystal heard it too. Look, it left a little memory behind in you. Monsters will teach you a bit more, as long as Signet watches over you.',
            'And this is for you: a page of an old chronicle, a ring for quick learning, and some gil. A good story is worth paying for, hehe.',
        },
        noRoom =
        {
            'Your bag is too full! Make room for two things, then come back.',
        },
        thanks =
        {
            'Bluffnix still thinks about that story. The crystals remember so many more... Bluffnix keeps digging!',
        },
    },
    [1] =
    {
        start =
        {
            'Psst! You! You look like somebody who likes old things.',
            'Bluffnix digs in the old tunnels under Jeuno and finds... this! A little mechanism. Gears, glass, and a crystal heart that hums when you hold it.',
            'Crystals remember, you know. Old crystals remember the adventures of people long gone. Bluffnix thinks this box was made to show those memories!',
            'But the gears are rusty and the glass is cloudy. Bring Bluffnix a square of dhalmel leather, a steel ingot, a square of linen cloth and a peridot, and Bluffnix fixes it for you.',
            '...Or a bowl of Goblin Stew. Bluffnix works much better on a full belly.',
        },
        remind =
        {
            'The memory box waits! Dhalmel leather, a steel ingot, linen cloth and a peridot. Or a bowl of Goblin Stew, hehe.',
        },
        finish =
        {
            'Leather for the strap, steel for the gears, linen to polish the glass... and the peridot wakes up the crystal heart. Listen! It hums!',
            'Bluffnix calls it the Crystal Boy. Put a Recollection inside and it plays the memory, like you are there yourself.',
            'Recollections? Little crystal tablets that remember one great adventure each. Bluffnix has none yet... but Bluffnix keeps digging. Come back later!',
        },
    },
    [2] =
    {
        start =
        {
            'Crystal Boy friend! Bluffnix found something in a cracked crate from an old Mithra caravan.',
            'A Recollection! A crystal tablet with a memory inside: a city of stone and lanterns, a young traveler, and a long road that starts at its gates.',
            'But the crystal is cloudy and the frame is broken. Bluffnix needs a square of ram leather, a mythril ingot, a square of wool cloth and a turquoise to make it clear again.',
            '...A bowl of Goblin Stew also helps. Thinking is hungry work.',
        },
        remind =
        {
            'The Recollection is still cloudy! Ram leather, a mythril ingot, wool cloth and a turquoise. Or Goblin Stew, hehe.',
        },
        finish =
        {
            'Look! Clear as morning water. Bluffnix can almost hear the street cries of that city.',
            'This is the Recollection of Jueno I. Use it with your Crystal Boy and walk the road yourself.',
            'People say whoever sees the whole story to its end keeps a little of that city\'s wisdom. Bluffnix wonders what you will find there...',
        },
    },
}

-- A chat line holds at most 150 characters: longer lines are split between words.
local function chunks(line, max)
    local out, cur = {}, ''
    for word in line:gmatch('%S+') do
        if cur ~= '' and #cur + 1 + #word > max then
            table.insert(out, cur)
            cur = word
        else
            cur = (cur == '' and word) or (cur .. ' ' .. word)
        end
    end
    if cur ~= '' then table.insert(out, cur) end
    return out
end

talk[3] =
{
    start =
    {
        'Psst! Bluffnix found another Recollection. Do not ask where. ...Fine: at the bottom of a well, under a very angry crab.',
        'This one is the second part of the legend. Same city behind you, a longer road ahead, and more people who want something from you.',
        'The tablet is chipped. Bluffnix needs a square of black tiger leather, a gold ingot, a square of velvet cloth and a painite to mend it.',
        '...Goblin Stew also works. Bluffnix always says so.',
    },
    remind = { 'The second tablet waits! Black tiger leather, a gold ingot, velvet cloth and a painite. Or Goblin Stew, hehe.' },
    finish =
    {
        'Leather to hold it, gold to seal the chip, velvet to polish... and the painite makes it shine again. Look!',
        'The Recollection of Jueno II. Carry on with your Crystal Boy, and tell Bluffnix where the road goes.',
    },
}

talk[4] =
{
    start =
    {
        'Crystal Boy friend! This one Bluffnix traded from a Galka who traded it from a Mithra who found it in a Quadav nest. Very old.',
        'Inside: the last part of the legend. Everything the first two parts promised, and a few things nobody promised at all.',
        'The tablet is cracked in three places. Bring a cermet chunk, a darksteel ingot, a square of silk cloth and a goshenite.',
        '...Or Goblin Stew. Bluffnix is very consistent about stew.',
    },
    remind = { 'The last tablet is still cracked! A cermet chunk, a darksteel ingot, silk cloth and a goshenite. Or Goblin Stew.' },
    finish =
    {
        'Cermet for the frame, darksteel for the corners, silk to wipe it, goshenite to wake it. Listen to it hum!',
        'The Recollection of Jueno III. See the legend to its end, and tell Bluffnix how it finishes!',
    },
}

talk[5] =
{
    start =
    {
        'Bluffnix found one more Recollection. Do not ask how. ...Fine: a Galka owed Bluffnix a favour.',
        'The fourth and last part of the legend. Everything the first three parts set up, and one long road to finish it.',
        'It flickers too much to play. Bluffnix needs a rhodonite, a paktong ingot, a square of moblinweave and a square of bugard leather.',
        '...Goblin Stew helps Bluffnix think. Everything is easier with stew.',
    },
    remind = { 'The last tablet still flickers! Rhodonite, a paktong ingot, moblinweave and bugard leather. Or Goblin Stew, hehe.' },
    finish =
    {
        'There! It stopped flickering. Now the memory holds still... mostly. Four parts of a legend are tricky.',
        'The Recollection of Jueno IV. Walk the last road with your Crystal Boy, and come back and tell Bluffnix how it ends.',
    },
}

local function speak(player, lines)
    local channel = xi.msg.channel.NS_SAY or xi.msg.channel.SAY or 0
    for i, line in ipairs(lines or {}) do
        local delay = (i - 1) * 2200
        local say = function(p)
            for _, part in ipairs(chunks(line, 140)) do
                p:printToPlayer(part, channel, 'Bluffnix')
            end
        end
        if delay == 0 or type(player.timer) ~= 'function' then
            say(player)
        else
            player:timer(delay, say)
        end
    end
end

-- The Crystal Boy addon writes what each character finished to
--   <Ashita>\config\addons\crystalboy\claims\<Character>\claims.lua
-- (the server and the game run on the same PC). The Ashita folder comes from kit_paths.lua (written by the launcher
-- every launch), else from the kit's config.json, else C:\Ashita-v4beta-main.
local function ashitaDir()
    local okp, paths = pcall(require, 'modules/custom/lua/kit_paths')
    if okp and type(paths) == 'table' and type(paths.ashita) == 'string' and paths.ashita ~= '' then
        return (paths.ashita:gsub('[/\\]+$', ''))
    end
    local kit = (okp and type(paths) == 'table' and type(paths.kit) == 'string' and paths.kit ~= '') and paths.kit or 'C:\\FFXISOLO\\'
    local dir = 'C:\\Ashita-v4beta-main'
    local f = io.open(kit .. 'config.json', 'r')
    if f then
        local text = f:read('*a')
        f:close()
        local found = text and text:match('"ashita_dir"%s*:%s*"(.-)"')
        if found and found ~= '' then dir = found:gsub('\\\\', '\\') end
    end
    return dir
end

local function cleanName(s)
    s = tostring(s or ''):gsub('[^%w%-_ %.%(%)%[%]]', '_')
    if s == '' then s = 'default' end
    return s
end

local function readClaims(player)
    local path = ashitaDir() .. '\\config\\addons\\crystalboy\\claims\\' .. cleanName(player:getName()) .. '\\claims.lua'
    local f = io.open(path, 'r')
    if not f then return {} end
    local src = f:read('*a')
    f:close()
    local fn
    if setfenv then
        fn = loadstring(src)
        if fn then setfenv(fn, {}) end
    else
        fn = load(src, 'claims', 't', {})
    end
    if not fn then return {} end
    local ok, t = pcall(fn)
    return (ok and type(t) == 'table') and t or {}
end

local function finished(player, r)
    if player:getCharVar(r.var .. 'GM') == 1 then return true end -- set by the GM test command !cbfinish
    local claims = readClaims(player)
    for _, title in ipairs(r.titles) do
        if type(claims[title]) == 'table' then return true end
    end

    return false
end

local function rewardRecollection(player, r)
    if not npcUtil.giveItem(player, r.items) then -- nothing is given unless every item fits
        speak(player, talk.recollection.noRoom)
        return
    end

    player:setCharVar(r.var, 1)
    player:addGil(r.gil)
    local ID = zones[player:getZoneID()]
    if ID and ID.text and ID.text.GIL_OBTAINED then player:messageSpecial(ID.text.GIL_OBTAINED, r.gil) end
    npcUtil.giveKeyItem(player, r.memory)
    local lines = { r.story }
    for _, l in ipairs(talk.recollection.finish) do table.insert(lines, l) end
    speak(player, lines)
end

-- Bluffnix talks about one thing at a time. Every Gobbiebag part asks this plan what he should do now, and only the
-- matching part answers (the game runs every matching handler, so the parts must never overlap).
-- Order: a part in progress > a Recollection ready to hand in > the next part to start > a Recollection still being
-- played > a thank-you.
local function questId(name) return name and xi.quest.id.jeuno[name] or nil end

local function statusOf(player, p)
    return player:getQuestStatus(xi.questLog.JEUNO, questId(p.quest))
end

local function bluffnixPlan(player)
    for k, p in ipairs(parts) do
        if p.reward and statusOf(player, p) == xi.questStatus.QUEST_ACCEPTED then return k, 'accepted' end
    end

    for k, p in ipairs(parts) do
        local r = p.recollection and RECOLLECTIONS[p.recollection]
        if r and statusOf(player, p) == xi.questStatus.QUEST_COMPLETED and player:getCharVar(r.var) == 0 and
            player:hasItem(p.recollection, xi.inv.INVENTORY) and finished(player, r)
        then
            return k, 'claim'
        end
    end

    for k, p in ipairs(parts) do
        local prevDone = p.prev == nil or player:hasCompletedQuest(xi.questLog.JEUNO, questId(p.prev))
        if p.reward and statusOf(player, p) == xi.questStatus.QUEST_AVAILABLE and prevDone then
            return k, (player:getFameLevel(xi.fameArea.JEUNO) >= p.fame) and 'start' or 'lowFame'
        end
    end

    if not bags.full() then
        for _, p in ipairs(parts) do
            if not p.reward then
                local st = statusOf(player, p)
                if st == xi.questStatus.QUEST_ACCEPTED or (st == xi.questStatus.QUEST_AVAILABLE and
                    player:hasCompletedQuest(xi.questLog.JEUNO, questId(p.prev)) and
                    player:getContainerSize(xi.inv.INVENTORY) == p.size)
                then
                    return nil -- (the game's own part answers)
                end
            end
        end
    end

    local pending, done
    for k, p in ipairs(parts) do
        local r = p.recollection and RECOLLECTIONS[p.recollection]
        if r and statusOf(player, p) == xi.questStatus.QUEST_COMPLETED then
            if player:getCharVar(r.var) == 0 then pending = pending or k else done = k end
        end
    end

    if pending then
        return pending, player:hasItem(parts[pending].recollection, xi.inv.INVENTORY) and 'notYet' or 'noTablet'
    end

    if done then return done, 'thanks' end
    return nil
end

local function planIs(player, partNo, kinds)
    local ok, k, kind = pcall(bluffnixPlan, player)
    if not ok or k ~= partNo then return false end
    for _, want in ipairs(kinds) do
        if kind == want then return true end
    end

    return false
end

local function buildSections(quest, p, partNo)
    local trade = {}
    for _, name in ipairs(p.items) do
        table.insert(trade, xi.item[name])
    end

    local stew  = xi.item.BOWL_OF_GOBLIN_STEW_880
    local words = talk[partNo] or {}
    local rTalk = talk.recollection

    local function onSection(kinds, handlers)
        return
        {
            check = function(player, status, vars)
                return planIs(player, partNo, kinds)
            end,

            [xi.zone.LOWER_JEUNO] = { ['Bluffnix'] = handlers },
        }
    end

    return
    {
        onSection({ 'start' }, {
            onTrigger = function(player, npc)
                quest:begin(player)
                speak(player, words.start)
                return quest:noAction()
            end,
        }),

        onSection({ 'lowFame' }, {
            onTrigger = function(player, npc)
                speak(player, talk.lowFame)
                return quest:noAction()
            end,
        }),

        onSection({ 'accepted' }, {
            onTrade = function(player, npc, trade_)
                if npcUtil.tradeHasExactly(trade_, trade) or npcUtil.tradeHasExactly(trade_, stew) then
                    -- the item first: with a full bag nothing is taken and the quest stays open
                    if npcUtil.giveItem(player, p.reward) then
                        player:confirmTrade()
                        quest:complete(player)
                        speak(player, words.finish)
                        bags.grow(player) -- (classic bags: the part's +5 as well)
                    end
                else
                    speak(player, words.remind)
                end

                return quest:noAction()
            end,

            onTrigger = function(player, npc)
                speak(player, words.remind)
                return quest:noAction()
            end,
        }),

        onSection({ 'claim' }, {
            onTrigger = function(player, npc)
                rewardRecollection(player, RECOLLECTIONS[p.recollection])
                return quest:noAction()
            end,
        }),

        onSection({ 'notYet', 'noTablet' }, {
            onTrigger = function(player, npc)
                local _, kind = bluffnixPlan(player)
                speak(player, kind == 'noTablet' and rTalk.noTablet or rTalk.notYet)
                return quest:noAction()
            end,
        }),

        onSection({ 'thanks' }, {
            onTrigger = function(player, npc)
                speak(player, rTalk.thanks)
                return quest:noAction()
            end,
        }),
    }
end

-- Bags at log in. Full bags (the default): every bag is opened at 80 (inventory, Mog Safe, Satchel, Sack, Case and the
-- eight Mog Wardrobes; the Mog Locker keeps its rental). Classic: the inventory (and Satchel) get the +5 for every
-- Gobbiebag part already done, so a character that finished parts while bags were full, or before this, isn't short.
-- Bags never shrink. (2026-11-17, the user's rule; 2026-11-16: a new world had 30-slot bags and no way to grow them.)
bags.grow = function(player)
    local size = player:getContainerSize(xi.inv.INVENTORY)
    if size <= 0 or size >= 80 then
        return
    end

    player:changeContainerSize(xi.inv.INVENTORY, 5)
    if player:getContainerSize(xi.inv.MOGSATCHEL) > 0 then
        player:changeContainerSize(xi.inv.MOGSATCHEL, 5)
    end

    player:printToPlayer(string.format('Your inventory now holds %d items.', player:getContainerSize(xi.inv.INVENTORY)), xi.msg.channel.SYSTEM_3)
end

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)
    if zoning or (BotIsBot and BotIsBot(player:getID())) then
        return result
    end

    -- (2026-11-25, delukard) The hub never touches bags: a visitor keeps the bags they brought from home. Before this
    -- the hub's full bags opened a Hardcore or classic character's every bag, and that went home with them.
    if xi.hardcore and xi.hardcore.isHub then
        return result
    end

    if bags.full() then
        local opened = false
        for _, name in ipairs(bags.all) do
            local loc  = xi.inv[name]
            local size = loc and player:getContainerSize(loc) or 80
            if size < 80 then
                player:changeContainerSize(loc, 80 - size)
                opened = true
            end
        end

        if opened then
            player:printToPlayer('Your bags are all open at 80 slots: inventory, Mog Safe, Satchel, Sack, Case and Wardrobes.', xi.msg.channel.SYSTEM_3)
        end
    else
        local done = 0
        for _, p in ipairs(parts) do
            if player:hasCompletedQuest(xi.questLog.JEUNO, questId(p.quest)) then
                done = done + 1
            end
        end

        local want = math.min(80, 30 + 5 * done)
        local size = player:getContainerSize(xi.inv.INVENTORY)
        if size > 0 and size < want then
            player:changeContainerSize(xi.inv.INVENTORY, want - size)
            local satchel = player:getContainerSize(xi.inv.MOGSATCHEL)
            if satchel > 0 and satchel < want then
                player:changeContainerSize(xi.inv.MOGSATCHEL, want - satchel)
            end

            player:printToPlayer(string.format('Your inventory now holds %d items (your Gobbiebag quests).', want), xi.msg.channel.SYSTEM_3)
        end

        -- (2026-11-20, Trinity: "Mog Satchel at the start, like new players get on Phoenix") Classic bags: the Mog
        -- Satchel is open from the start at the inventory's size (Phoenix gives it to an account with a security
        -- token; nobody has one here, so it stayed closed). The Gobbiebag quests grow an open Satchel with the inventory.
        do
            local inventory = player:getContainerSize(xi.inv.INVENTORY)
            local satchel   = player:getContainerSize(xi.inv.MOGSATCHEL)
            if inventory > 0 and satchel < inventory then
                player:changeContainerSize(xi.inv.MOGSATCHEL, inventory - satchel)
                if satchel == 0 then
                    player:printToPlayer(string.format('Your Mog Satchel is open: %d slots.', inventory), xi.msg.channel.SYSTEM_3)
                end
            end
        end

        -- Classic: a brand-new character's Mog Wardrobes 1-8 and Mog Case start closed, as on Phoenix
        -- (disable_optional_storage.sql); Phoenix's mission and quest rewards open them 5 at a time. The database
        -- default is 80, so without this they were all open. Only empty bags on a first log in: bags never shrink.
        if firstLogin then
            for _, name in ipairs({ 'MOGCASE', 'WARDROBE', 'WARDROBE2', 'WARDROBE3', 'WARDROBE4', 'WARDROBE5', 'WARDROBE6', 'WARDROBE7', 'WARDROBE8' }) do
                local loc  = xi.inv[name]
                local size = loc and player:getContainerSize(loc) or 0
                if size > 0 and player:getFreeSlotsCount(loc) >= size then
                    player:changeContainerSize(loc, -size)
                end
            end
        end
    end

    return result
end)

m:addOverride('xi.server.onServerStart', function()
    super()

    local full = bags.full()
    for partNo, p in ipairs(parts) do
        if full or p.reward then -- (classic bags: parts VI-X stay the game's own bag quests)
            xi.module.modifyInteractionEntry('scripts/quests/jeuno/' .. p.file, function(quest)
                quest.sections = buildSections(quest, p, partNo)
            end)
        end
    end
end)

-- The event's games (Horro's Visit, cartridges 8105-8109 in crystalboy-games). The client key-item file has no free
-- ids left, so a finished game is recorded on the character from the addon's claims file instead of with a Memory key
-- item: parts I-II add 1% experience each, parts III-V add 1% to the combat and magic skill-up rates each, all while
-- Signet is active. The claims file is only read while something is still missing, at most once every five minutes.
local DRAGONLAND =
{
    { title = 'DRAGONLAND 1', var = '[CB]DL1', kind = 'exp',   name = 'Dragonland I'   },
    { title = 'DRAGONLAND 2', var = '[CB]DL2', kind = 'exp',   name = 'Dragonland II'  },
    { title = 'DRAGONLAND 3', var = '[CB]DL3', kind = 'skill', name = 'Dragonland III' },
    { title = 'DRAGONLAND 4', var = '[CB]DL4', kind = 'skill', name = 'Dragonland IV'  },
    { title = 'DRAGONLAND 5', var = '[CB]DL5', kind = 'skill', name = 'Dragonland V'   },
}

local DL_CHECK = {}   -- [player id] = os.time() of the last claims read
local DL_MODS  = {}   -- [player id] = { combat, magic }: the percentage we have added

local function dragonlandCount(player, kind)
    local n = 0
    for _, g in ipairs(DRAGONLAND) do
        if g.kind == kind and player:getCharVar(g.var) == 1 then n = n + 1 end
    end

    return n
end

-- +1% skill-up chance per finished part III-V, while Signet is active. Only our own share is ever taken back out, so
-- a Moghancement or a piece of gear that also raises the rate keeps its bonus.
local function applySkillGain(player)
    local have = player:hasStatusEffect(xi.effect.SIGNET) and dragonlandCount(player, 'skill') or 0
    local was  = DL_MODS[player:getID()] or { combat = 0, magic = 0 }
    if was.combat ~= have then
        player:setMod(xi.mod.COMBAT_SKILLUP_RATE, player:getMod(xi.mod.COMBAT_SKILLUP_RATE) - was.combat + have)
        was.combat = have
    end

    if was.magic ~= have then
        player:setMod(xi.mod.MAGIC_SKILLUP_RATE, player:getMod(xi.mod.MAGIC_SKILLUP_RATE) - was.magic + have)
        was.magic = have
    end

    DL_MODS[player:getID()] = was
end

local function refreshDragonland(player, force)
    if not player then return end
    local open = false
    for _, g in ipairs(DRAGONLAND) do
        if player:getCharVar(g.var) == 0 then open = true; break end
    end

    local now  = os.time()
    local last = DL_CHECK[player:getID()] or 0
    if not force and (not open or now - last < 300) then
        applySkillGain(player)
        return
    end

    DL_CHECK[player:getID()] = now
    local claims = readClaims(player)
    for _, g in ipairs(DRAGONLAND) do
        if player:getCharVar(g.var) == 0 and type(claims[g.title]) == 'table' then
            player:setCharVar(g.var, 1)
            player:printToPlayer(string.format('%s finished! %s while Signet is active from now on.', g.name,
                g.kind == 'exp' and '+1% experience' or '+1% combat and magic skill gain'), xi.msg.channel.SYSTEM_3)
        end
    end

    applySkillGain(player)
end

-- Memories of finished Recollections: +1% exp from monsters each while Signet is active.
-- Added once to the final number (after Dedication, chains and the era tables), only for the player, not squad mates.
m:addOverride('xi.experiencePoints.calculate', function(member, mob, data)
    local result = super(member, mob, data)
    if
        result == nil or
        type(result.exp) ~= 'number' or
        member:getObjType() ~= xi.objType.PC or
        not member:hasStatusEffect(xi.effect.SIGNET)
    then
        return result
    end

    refreshDragonland(member)

    local percent = 0
    for _, ki in ipairs(MEMORY_KEY_ITEMS) do
        if member:hasKeyItem(ki) then percent = percent + 1 end
    end

    for _, g in ipairs(DRAGONLAND) do
        if g.kind == 'exp' and member:getCharVar(g.var) == 1 then percent = percent + 1 end
    end

    if percent > 0 then
        result.exp = result.exp + math.floor(result.exp * percent / 100)
    end

    return result
end)

-- GM helper for testing the quests: Jeuno fame comes from the three nations' fame.
local fameCommand = {}

fameCommand.cmdprops =
{
    permission = 1,
    parameters = 'i',
}

fameCommand.onTrigger = function(player, level)
    level = tonumber(level)
    if level == nil or level < 1 or level > 9 then
        player:printToPlayer(string.format('!cbfame <1-9>   (now: Jeuno fame %d)', player:getFameLevel(xi.fameArea.JEUNO)))
        return
    end

    local points = xi.data.fame.rankPoints[level]
    for _, area in ipairs({ xi.fameArea.SANDORIA, xi.fameArea.BASTOK, xi.fameArea.WINDURST }) do
        player:setFame(area, points)
    end

    player:printToPlayer(string.format('San d\'Oria, Bastok and Windurst fame set to level %d. Jeuno fame is now %d.',
        level, player:getFameLevel(xi.fameArea.JEUNO)))
end

xi.module.registerCommand('cbfame', fameCommand)

-- GM helper: count a Recollection as finished without playing it (to test Bluffnix's rewards).
-- !cbfinish [8101-8104] counts that Recollection as finished;  !cbfinish [id] reset undoes it and allows the rewards again
local finishCommand = {}

finishCommand.cmdprops =
{
    permission = 1,
    parameters = 's',
}

finishCommand.onTrigger = function(player, arg)
    local id, mode = 8101, nil
    for word in tostring(arg or ''):gmatch('%S+') do
        if word == 'reset' then mode = 'reset' elseif tonumber(word) then id = tonumber(word) end
    end

    local r = RECOLLECTIONS[id]
    if not r then
        player:printToPlayer('!cbfinish [8101-8104] [reset]')
        return
    end

    if mode == 'reset' then
        player:setCharVar(r.var .. 'GM', 0)
        player:setCharVar(r.var, 0)
        player:delKeyItem(r.memory)
        player:printToPlayer(r.game .. ': test finish and reward record cleared (key item removed).')
    else
        player:setCharVar(r.var .. 'GM', 1)
        player:printToPlayer(r.game .. ' counts as finished for this character. Talk to Bluffnix with its Recollection in your bag.')
    end
end

xi.module.registerCommand('cbfinish', finishCommand)

-- GM helper: re-read the Crystal Boy claims now and show the Dragonland parts this character has finished.
-- !cbdl
local dlCommand = {}

dlCommand.cmdprops =
{
    permission = 1,
    parameters = 's',
}

dlCommand.onTrigger = function(player, arg)
    refreshDragonland(player, true)
    local out = {}
    for _, g in ipairs(DRAGONLAND) do
        table.insert(out, g.name .. (player:getCharVar(g.var) == 1 and ' done' or ' -'))
    end

    player:printToPlayer(table.concat(out, ' | '), xi.msg.channel.SYSTEM_3)
end

xi.module.registerCommand('cbdl', dlCommand)

return m
