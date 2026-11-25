-----------------------------------
-- Hardcore modes (XI: Forever Offline, 2026-11-23): Iron, Steel and Silver
--
-- A character becomes hardcore from the launcher's HARDCORE menu, before it gains its first level. The mode is the
-- character variable [HC]Mode (1 = Iron, 2 = Steel, 3 = Silver) and goes wherever the character goes (co-op, the hub).
--
--   Iron    its own rates (the Iron profile); no auction house, no bazaars, no trades or delivery box with other
--           characters; parties with anyone.
--   Steel   the Steel profile; the same blocks, no Home Point / Survival Guide teleports; when it is knocked out, the
--           job it was on goes back to level 1 (everything completed stays; squad mates keep their levels);
--           only parties with hardcore characters, so no bot players.
--   Silver  the Silver profile; the same as Steel, but when it is knocked out the character is locked for good: it can't
--           log in, it is on the memorial, and the launcher deletes it after 7 days (a GM can restore it in that time).
--
-- "Knocked out" means HP 0, even if it is raised afterwards. A crash or a disconnect is not a death.
-- Every 10 levels on a job (10, 20, ... 70), once per job: random cosmetics in the delivery box, 1 for Iron, 2 for Steel,
-- 3 for Silver. Milestones, Steel delevels and Silver deaths are announced to the whole world, written to
-- hardcore_out.txt for the launcher (the hub and Stinkshell), and the hub shows other worlds' lines from hardcore_in.txt.
--
-- Where the rules are kept:
--   * the C++ side (src/map/utils/hardcoreutils.h, modules/custom/cpp/hardcore.cpp): kill experience, drops, mob gil,
--     skill-ups, crafting, fishing, blue magic; the auction house, bazaars, trades, the delivery box; party invites
--   * here: the rates the game's scripts read from xi.settings.main (quest gil, tabs, page experience, casket chance,
--     Home Point and Survival Guide teleports), the deaths, the milestones, the announcements
-- The rates of each mode are in hardcore_profiles.lua (written by the launcher from its hardcore profiles). A key a
-- profile leaves out uses the world's own setting.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('hardcore_modes')

xi = xi or {}
xi.hardcore = xi.hardcore or {}
local H = xi.hardcore

H.IRON, H.STEEL, H.SILVER, H.RANDOM = 1, 2, 3, 4
H.NAMES = { [1] = 'Iron', [2] = 'Steel', [3] = 'Silver', [4] = 'Randomized' }
H.GIFTS = { [1] = 1, [2] = 2, [3] = 3 } -- cosmetics per milestone
-- each mode's own title, always worn (the C++ side keeps it on: charutils::setTitle, hardcoreutils::modeTitle). The
-- client's title list has empty slots 1078 - 1115; the launcher writes these names into the game's title file.
H.TITLES = { [1] = 1078, [2] = 1079, [3] = 1080, [4] = 1081 }
H.TITLE_NAMES =
{
    [1] = 'Forged in Solitude',
    [2] = 'Tempered by Ruin',
    [3] = 'Bearer of a Single Flame',
    [4] = "Altana's Wild Card",
}
H.MILESTONE_STEP = 10
H.MILESTONE_TOP = 70
H.LOCK_DAYS = 7

local VAR_MODE    = '[HC]Mode'
local VAR_START   = '[HC]Start'    -- when it became hardcore (os.time)
local VAR_DEAD    = '[HC]Dead'     -- Silver: when it died (os.time); 0 = alive
local VAR_DEATHS  = '[HC]Deaths'   -- times knocked out (every mode)
local VAR_RESET   = '[HC]Reset'    -- Steel: a job waiting to go back to level 1 (job id + 100)
local VAR_RESETS  = '[HC]Resets'   -- Steel: how many times a job went back to 1
local VAR_GIFTS   = '[HC]GiftsDue' -- cosmetics earned but not sent yet (the delivery box refused)
local VAR_MS      = '[HC]MS'       -- .. job: the highest milestone paid on that job

local OUT_FILE    = 'modules/custom/lua/hardcore_out.txt'
local IN_FILE     = 'modules/custom/lua/hardcore_in.txt'
local PENDING     = 'modules/custom/lua/hardcore_pending.lua'
local PROFILES    = 'modules/custom/lua/hardcore_profiles.lua'
local WORLD_CFG   = 'modules/custom/lua/hardcore_world.lua'

-----------------------------------
-- the profiles (character rates of each mode)
-----------------------------------
-- The user's three profiles (2026-11-23). The launcher writes hardcore_profiles.lua from its own copy at every PLAY;
-- these are only used when that file is missing.
local DEFAULT_RATES =
{
    [1] =
    {
        ['map.EXP_RATE'] = 1.0, ['map.DROP_RATE_MULTIPLIER'] = 1.2, ['map.MOB_GIL_MULTIPLIER'] = 1.2,
        ['map.ALL_MOBS_GIL_BONUS'] = 0, ['map.SKILLUP_CHANCE_MULTIPLIER'] = 1.2, ['map.BLUE_LEARN_MULTIPLIER'] = 1.2,
        ['map.CRAFT_CHANCE_MULTIPLIER'] = 1.2, ['map.CRAFT_HQ_CHANCE_MULTIPLIER'] = 1.2, ['map.FISHING_SKILL_MULTIPLIER'] = 1.2,
        ['main.GIL_RATE'] = 1.2, ['main.TABS_RATE'] = 1.0, ['main.BOOK_EXP_RATE'] = 0.125, ['main.CASKET_DROP_RATE'] = 0.1,
        ['main.HOMEPOINT_TELEPORT'] = 1, ['main.ENABLE_SURVIVAL_GUIDE'] = 1,
    },
    [2] =
    {
        ['map.EXP_RATE'] = 2.0, ['map.DROP_RATE_MULTIPLIER'] = 2.0, ['map.MOB_GIL_MULTIPLIER'] = 2.0,
        ['map.ALL_MOBS_GIL_BONUS'] = 2, ['map.SKILLUP_CHANCE_MULTIPLIER'] = 2.0, ['map.BLUE_LEARN_MULTIPLIER'] = 2.0,
        ['map.CRAFT_CHANCE_MULTIPLIER'] = 2.0, ['map.CRAFT_HQ_CHANCE_MULTIPLIER'] = 2.0, ['map.FISHING_SKILL_MULTIPLIER'] = 2.0,
        ['main.GIL_RATE'] = 2.0, ['main.TABS_RATE'] = 2.0, ['main.BOOK_EXP_RATE'] = 2.0, ['main.CASKET_DROP_RATE'] = 0.2,
        ['main.HOMEPOINT_TELEPORT'] = 0, ['main.ENABLE_SURVIVAL_GUIDE'] = 0,
    },
    [3] =
    {
        ['map.EXP_RATE'] = 3.5, ['map.DROP_RATE_MULTIPLIER'] = 3.0, ['map.MOB_GIL_MULTIPLIER'] = 3.0,
        ['map.ALL_MOBS_GIL_BONUS'] = 3, ['map.SKILLUP_CHANCE_MULTIPLIER'] = 3.0, ['map.BLUE_LEARN_MULTIPLIER'] = 3.0,
        ['map.CRAFT_CHANCE_MULTIPLIER'] = 3.0, ['map.CRAFT_HQ_CHANCE_MULTIPLIER'] = 3.0, ['map.FISHING_SKILL_MULTIPLIER'] = 3.0,
        ['main.GIL_RATE'] = 3.0, ['main.TABS_RATE'] = 3.0, ['main.BOOK_EXP_RATE'] = 3.5, ['main.CASKET_DROP_RATE'] = 0.27,
        ['main.HOMEPOINT_TELEPORT'] = 0, ['main.ENABLE_SURVIVAL_GUIDE'] = 0,
    },
    [4] = -- Randomized (not hardcore): the user's "random mode" profile
    {
        ['map.EXP_RATE'] = 2.0, ['map.DROP_RATE_MULTIPLIER'] = 2.2, ['map.MOB_GIL_MULTIPLIER'] = 2.3,
        ['map.ALL_MOBS_GIL_BONUS'] = 1, ['map.SKILLUP_CHANCE_MULTIPLIER'] = 2.2, ['map.BLUE_LEARN_MULTIPLIER'] = 3.0,
        ['map.CRAFT_CHANCE_MULTIPLIER'] = 2.2, ['map.CRAFT_HQ_CHANCE_MULTIPLIER'] = 5.0, ['map.FISHING_SKILL_MULTIPLIER'] = 2.0,
        ['main.GIL_RATE'] = 3.3, ['main.TABS_RATE'] = 3.0, ['main.BOOK_EXP_RATE'] = 0.5, ['main.CASKET_DROP_RATE'] = 0.28,
        ['main.HOMEPOINT_TELEPORT'] = 1, ['main.ENABLE_SURVIVAL_GUIDE'] = 1,
    },
}

-- these always hold, whatever a profile file says (the user's rules, not rates)
local FIXED =
{
    [2] = { ['main.HOMEPOINT_TELEPORT'] = 0, ['main.ENABLE_SURVIVAL_GUIDE'] = 0 },
    [3] = { ['main.HOMEPOINT_TELEPORT'] = 0, ['main.ENABLE_SURVIVAL_GUIDE'] = 0 },
}

local function readLuaFile(path)
    local chunk = loadfile(path)
    if not chunk then
        return nil
    end

    local ok, value = pcall(chunk)
    if ok and type(value) == 'table' then
        return value
    end

    return nil
end

local function loadRates()
    local rates = {}
    local file = readLuaFile(PROFILES) or {}
    for mode = 1, 4 do
        local row = {}
        for key, value in pairs(DEFAULT_RATES[mode]) do
            row[key] = value
        end

        if type(file[mode]) == 'table' then
            for key, value in pairs(file[mode]) do
                if type(key) == 'string' and tonumber(value) ~= nil then
                    row[key] = tonumber(value)
                end
            end
        end

        for key, value in pairs(FIXED[mode] or {}) do
            row[key] = value
        end

        rates[mode] = row
    end

    return rates
end

H.rates = loadRates() -- read by the C++ side too (hardcoreutils::rate)

local world = readLuaFile(WORLD_CFG) or {}
H.hardcoreOnly = world.hardcore_only == true -- this world only lets hardcore visitors in
H.isHub = world.hub == true                   -- the hub shows other worlds' lines (hardcore_in.txt)
H.shareOnline = world.share ~= false          -- write lines for the launcher to send online (hub, Stinkshell)
H.worldName = type(world.world) == 'string' and world.world or ''

-----------------------------------
-- small helpers
-----------------------------------
local function tell(player, text)
    player:printToPlayer(text, xi.msg.channel.SYSTEM_3)
end

local function isBot(player)
    if player:getCharVar('[Bot]Started') ~= 0 then
        return true
    end

    return BotIsBot ~= nil and BotIsBot(player:getID()) and true or false
end

local function clean(text)
    return (tostring(text or ''):gsub('[|\r\n]', ' '))
end

H.mode = function(player)
    if player == nil or player:getObjType() ~= xi.objType.PC then
        return 0
    end

    local mode = player:getCharVar(VAR_MODE)
    if mode >= 1 and mode <= 4 then
        return mode
    end

    return 0
end

H.modeName = function(mode)
    return H.NAMES[mode] or 'normal'
end

local JOB_NAMES = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG',
                    'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN' }

local function jobName(job)
    return JOB_NAMES[job] or ('job ' .. tostring(job))
end

H.survivalText = function(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local days = math.floor(seconds / 86400)
    local hours = math.floor(seconds % 86400 / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    if days > 0 then
        return string.format('%dd %dh', days, hours)
    elseif hours > 0 then
        return string.format('%dh %02dm', hours, minutes)
    end

    return string.format('%dm', minutes)
end

-- seconds this character has been hardcore, counted in play time when the server knows it
local function survived(player)
    local start = player:getCharVar(VAR_START)
    if start > 0 then
        return os.time() - start
    end

    return 0
end

-----------------------------------
-- the rates the scripts read from xi.settings.main: swapped in while a hardcore player's own call runs
-----------------------------------
H.withRates = function(player, fn, ...)
    local mode = H.mode(player)
    local row = mode > 0 and H.rates[mode] or nil
    if row == nil or xi.settings == nil or xi.settings.main == nil then
        return fn(...)
    end

    local saved = {}
    for key, value in pairs(row) do
        local name = key:match('^main%.([%w_]+)$')
        if name then
            saved[name] = xi.settings.main[name]
            xi.settings.main[name] = value
        end
    end

    local results = { pcall(fn, ...) }
    for name, value in pairs(saved) do
        xi.settings.main[name] = value
    end

    if not results[1] then
        error(results[2], 0)
    end

    return unpack(results, 2, table.maxn(results))
end

-- no Home Point / Survival Guide teleports for this character? (used by fpxport.lua too)
H.noFastTravel = function(player)
    local mode = H.mode(player)
    return mode > 0 and H.rates[mode] ~= nil and H.rates[mode]['main.HOMEPOINT_TELEPORT'] == 0
end

local function wrap(path)
    m:addOverride(path, function(player, ...)
        if H.mode(player) == 0 then
            return super(player, ...)
        end

        return H.withRates(player, super, player, ...)
    end)
end

wrap('npcUtil.giveReward')
wrap('npcUtil.completeQuest')
wrap('npcUtil.completeMission')
wrap('xi.regime.checkRegime')
wrap('xi.caskets.spawnCasket')
wrap('xi.homepoint.onTrigger')
wrap('xi.homepoint.onEventUpdate')
wrap('xi.homepoint.onEventFinish')
wrap('xi.survivalGuide.onTrigger')
wrap('xi.survivalGuide.onEventUpdate')
wrap('xi.survivalGuide.onEventFinish')

-----------------------------------
-- announcements: the whole world now; the launcher sends hardcore_out.txt lines on to the hub and Stinkshell
-----------------------------------
local function writeOut(kind, player, mode, job, level, extra)
    if not H.shareOnline then
        return
    end

    local handle = io.open(OUT_FILE, 'a')
    if handle then
        handle:write(string.format('%d|%s|%s|%s|%s|%d|%s|%s\n', os.time(), kind, clean(player:getName()), H.modeName(mode),
                                   jobName(job), tonumber(level) or 0, clean(extra), clean(H.worldName)))
        handle:close()
    end
end

local function announce(player, text)
    local decorated = string.format('\129\154 %s \129\154', text)
    local ok = pcall(function()
        player:printToArea(decorated, xi.msg.channel.SYSTEM_3, xi.msg.area.SYSTEM, '', false)
    end)
    if not ok then
        tell(player, decorated)
    end
end

-----------------------------------
-- becoming hardcore (the launcher's pending list) and the login checks
-----------------------------------
local function eligible(player)
    for job = 1, #JOB_NAMES do
        local ok, level = pcall(function()
            return player:getJobLevel(job)
        end)
        if ok and (tonumber(level) or 0) > 1 then
            return false
        end
    end

    return true
end

local function pendingFor(player)
    local list = readLuaFile(PENDING)
    if type(list) ~= 'table' then
        return 0
    end

    local name = string.lower(player:getName())
    for _, entry in ipairs(list) do
        if type(entry) == 'table' and type(entry.name) == 'string' and string.lower(entry.name) == name then
            local mode = tonumber(entry.mode) or 0
            if mode >= 1 and mode <= 4 then
                return mode
            end
        end
    end

    return 0
end

local function becomeHardcore(player, mode)
    player:setCharVar(VAR_MODE, mode)
    player:setCharVar(VAR_START, os.time())
    player:setCharVar(VAR_DEAD, 0)
    player:setCharVar(VAR_DEATHS, 0)
    player:setCharVar(VAR_RESET, 0)
    player:setCharVar(VAR_RESETS, 0)
    for job = 1, #JOB_NAMES do
        player:setCharVar(VAR_MS .. job, 0)
    end

    local rules =
    {
        [1] = 'No auction house, bazaars, trades or deliveries from other characters. Everything you have, you earn.',
        [2] = 'No auction house, trades or teleports. When you are knocked out, the job you are on goes back to level 1.',
        [3] = 'No auction house, trades or teleports. When you are knocked out, this character is gone. For good.',
        [4] = 'Fate picks your looks and your jobs; every drop, chest and casket is a surprise. Your squad can still learn any job. Your auction house is your own: its stock changes every 6 hours and its prices swing up to 20% more.',
    }
    if mode == H.RANDOM then
        tell(player, 'You are now a Randomized character. ' .. rules[mode])
        announce(player, string.format('%s has begun a Randomized journey.', player:getName()))
    else
        tell(player, string.format('You are now a %s hardcore character. %s', H.modeName(mode), rules[mode]))
        announce(player, string.format('%s has begun a %s hardcore journey.', player:getName(), H.modeName(mode)))
    end
    if mode ~= H.RANDOM then                     -- (a Randomized start is told once its job is rolled)
        writeOut('start', player, mode, player:getMainJob(), 1, '')
    end
    pcall(H.wearTitle, player, mode)
    -- (2026-11-24, the user: a new Randomized character showed the new-player "?" instead of its shield) the "?" would
    -- cover the mode's mark, and the status sent at log in still had no mode: take the "?" off for good and send the
    -- character's status again now, so the shield shows at once (not only after the next zone)
    pcall(function()
        player:setNewPlayer(false)
    end)
    pcall(function()
        player:setCostume(player:getCostume())
    end)
    tell(player, string.format('Your title is now "%s". It stays on as long as you play this mode.', H.TITLE_NAMES[mode]))
    print(string.format('[hardcore] %s is now %s', player:getName(), H.modeName(mode)))
end

local online = {} -- [char id] = mode, the hardcore players seen this session
local seen = {}   -- [char id] = true, every real player seen this session (to show the hub's lines)

local function lockedOut(player)
    local dead = player:getCharVar(VAR_DEAD)
    if H.mode(player) ~= H.SILVER or dead == 0 then
        return false
    end

    local left = math.max(0, H.LOCK_DAYS * 86400 - (os.time() - dead))
    tell(player, string.format('%s fell as a Silver hardcore character and rests on the memorial. %s', player:getName(),
         left > 0 and string.format('The character is deleted in %s.', H.survivalText(left)) or 'The character is being deleted.'))
    player:timer(6000, function(entity)
        entity:leaveGame()
    end)
    return true
end

local function sendGifts(player, count)
    local pool = H.cosmeticPool()
    if #pool == 0 or count <= 0 then
        return 0
    end

    local fresh = {}
    for _, itemId in ipairs(pool) do
        if not player:hasItem(itemId) then
            fresh[#fresh + 1] = itemId
        end
    end

    local sent, names = 0, {}
    for _ = 1, count do
        local from = #fresh > 0 and fresh or pool
        local index = math.random(#from)
        local itemId = from[index]
        local code = tonumber(SendItemToDeliveryBox(player:getName(), itemId, 1, 'Hardcore'))
        if code ~= nil and code >= 2 then
            break
        end

        sent = sent + 1
        if from == fresh then
            table.remove(fresh, index)
        end
    end

    return sent
end

local function payDueGifts(player)
    local due = player:getCharVar(VAR_GIFTS)
    if due > 0 then
        local sent = sendGifts(player, due)
        player:setCharVar(VAR_GIFTS, due - sent)
        if sent > 0 then
            tell(player, string.format('%d hardcore reward%s waiting in your delivery box.', sent, sent == 1 and ' is' or 's are'))
        end
    end
end

local function applyReset(player)
    local waiting = player:getCharVar(VAR_RESET)
    if waiting < 100 or player:isDead() then
        return false
    end

    local job = waiting - 100
    if player:getMainJob() ~= job then
        -- (changed job at a Moogle before getting up: that job goes back to 1 the next time it is the main job)
        return false
    end

    if type(HardcoreResetJob) == 'function' and HardcoreResetJob(player:getID()) then
        player:setCharVar(VAR_RESET, 0)
        player:setCharVar(VAR_RESETS, player:getCharVar(VAR_RESETS) + 1)
        tell(player, string.format('Steel: your %s is back to level 1. Everything you completed stays with you.', jobName(job)))
        return true
    end

    print('[hardcore] HardcoreResetJob is missing: rebuild the map server (modules/custom/cpp/hardcore.cpp)')
    return false
end

local function watchReset(player, tries)
    player:timer(2000, function(entity)
        if entity:getCharVar(VAR_RESET) < 100 then
            return
        end

        if not applyReset(entity) and tries < 900 then
            watchReset(entity, tries + 1)
        end
    end)
end

-- the mode's title goes on (and comes off a character that stepped down to a regular one)
H.wearTitle = function(player, mode)
    local want = H.TITLES[mode]
    local now  = player:getTitle()
    if want ~= nil then
        if now ~= want then
            player:setTitle(want)
        end
    elseif now >= H.TITLES[1] and now <= H.TITLES[4] then
        player:setTitle(0)
    end
end

m:addOverride('xi.player.onGameIn', function(player, firstLogin, zoning)
    local result = super(player, firstLogin, zoning)
    if isBot(player) then
        return result
    end

    seen[player:getID()] = true
    local mode = H.mode(player)
    if mode == 0 and not zoning then
        local wanted = pendingFor(player)
        if wanted > 0 then
            if eligible(player) then
                becomeHardcore(player, wanted)
                mode = wanted
            else
                tell(player, 'This character has already gained a level, so it cannot become hardcore. Start a new character from the HARDCORE menu.')
            end
        end
    end

    pcall(H.wearTitle, player, mode)

    -- (2026-11-24) a mode character never keeps the new-player "?": the game shows your own "?" from your saved
    -- settings, not from the status, so it covered the shield on characters that became hardcore or Randomized
    -- before this fix (Nyurami, Kandra). Turned off for good at log in; it shows from the next zone or log in.
    if mode ~= 0 then
        pcall(function()
            if player:getNewPlayer() then
                player:setNewPlayer(false)
            end
        end)
    end

    -- a world that only takes hardcore visitors
    if mode == 0 and H.hardcoreOnly and xi.coop and xi.coop.isGuest and xi.coop.isGuest(player) then
        tell(player, 'This world only takes hardcore and Randomized visitors (Iron, Steel, Silver and Randomized characters). Taking you home...')
        player:timer(8000, function(entity)
            entity:leaveGame()
        end)
        return result
    end

    if mode == 0 then
        return result
    end

    online[player:getID()] = mode

    if lockedOut(player) then
        return result
    end

    if mode == H.RANDOM then
        player:timer(1500, function(entity)
            pcall(H.randomLogin, entity)
        end)
        player:timer(4000, function(entity)
            pcall(H.tellIcons, entity)
        end)
        return result
    end

    if not zoning then
        tell(player, string.format('%s hardcore. Deaths: %d. Hardcore for %s.', H.modeName(mode), player:getCharVar(VAR_DEATHS), H.survivalText(survived(player))))
        player:timer(5000, function(entity)
            payDueGifts(entity)
        end)
    end

    if player:getCharVar(VAR_RESET) >= 100 then
        watchReset(player, 0)
    end

    player:timer(4000, function(entity)
        pcall(H.tellIcons, entity)
    end)

    return result
end)

-----------------------------------
-- Randomized (mode 4, not hardcore): random looks, random jobs, random drops
--   * the first login: a random race (one of the 8 models), face and size (the Ancestry Moogle's own change, which
--     moves you to the area again so the model loads) and one random job of the 18 era jobs
--   * another random job when the highest of its jobs reaches 18, 33 and 65 ([HC]Grants counts them)
--   * only the rolled jobs can be played ([HC]Jobs, a bit per job). A job unlock quest done by a Randomized character
--     does not unlock it for the character: it goes to [HC]SquadJobs, for the squad mates (squad.lua asks
--     xi.hardcore.squadJob). The six starting jobs are always open to the squad, as for everyone.
--   * every drop of its claim is a random item that fits: the same area's drop pool, or the NM pool for an NM
--     (HardcoreLootPool / HardcoreNMPool); quest items, crystals, seals and Rare/Ex items stay what they are
-----------------------------------
local VAR_JOBS    = '[HC]Jobs'
local VAR_SQUAD   = '[HC]SquadJobs'
local VAR_GRANTS  = '[HC]Grants'
local VAR_LOOKS   = '[HC]Looks'
local GRANT_AT    = { 18, 33, 65 }
local ERA_JOBS    = 18                 -- WAR .. PUP (no DNC, SCH, GEO, RUN)
local SUPPORT_BIT = 1                  -- bit 0 of the unlocked jobs: the support (sub) job quest

local function hasBit(mask, job)
    return bit.band(mask, bit.lshift(1, job)) ~= 0
end

-- what a job needs to work from level 1 that its unlock quest would have given
local function jobKit(player, job)
    if job == xi.job.SMN then
        pcall(function()
            player:addSpell(xi.magic.spell.CARBUNCLE)
        end)
    elseif job == xi.job.PUP then
        pcall(function()
            player:setPetName(xi.petType.AUTOMATON, 118 + math.random(0, 7))
            player:unlockAttachment(xi.item.HARLEQUIN_FRAME)
            player:unlockAttachment(xi.item.HARLEQUIN_HEAD)
        end)
    end
end

local function rollJob(mask)
    local choices = {}
    for job = 1, ERA_JOBS do
        if not hasBit(mask, job) then
            choices[#choices + 1] = job
        end
    end

    return #choices > 0 and choices[math.random(#choices)] or nil
end

local function applyJobs(player)
    local rolled = player:getCharVar(VAR_JOBS)
    if rolled == 0 or type(HardcoreSetJobs) ~= 'function' then
        return
    end

    -- the unlocked jobs as the game has them now (a bit per job)
    local unlocked = 0
    for job = 0, 22 do
        local ok, has = pcall(function()
            return player:hasJob(job)
        end)
        if ok and has then
            unlocked = bit.bor(unlocked, bit.lshift(1, job))
        end
    end

    local allowed = bit.bor(bit.band(unlocked, SUPPORT_BIT), rolled)
    local extra = bit.band(unlocked, bit.bnot(allowed))
    local fromQuests = bit.band(extra, bit.bnot(0x7E)) -- (the six starting jobs every new character has don't count)
    if fromQuests ~= 0 then
        local before = player:getCharVar(VAR_SQUAD)
        player:setCharVar(VAR_SQUAD, bit.bor(before, fromQuests))
        local names = {}
        for job = 1, 22 do
            if hasBit(fromQuests, job) and not hasBit(before, job) then
                names[#names + 1] = jobName(job)
            end
        end

        if #names > 0 then
            tell(player, string.format('Your squad mates can now be %s. (A Randomized character only plays the jobs fate gave it.)', table.concat(names, ', ')))
        end
    end

    if extra ~= 0 then
        HardcoreSetJobs(player:getID(), allowed)
    end

    if not hasBit(rolled, player:getMainJob()) then
        for job = 1, ERA_JOBS do
            if hasBit(rolled, job) then
                player:changeJob(job)
                break
            end
        end
    end
end

local function giveJob(player, job, first)
    local rolled = bit.bor(player:getCharVar(VAR_JOBS), bit.lshift(1, job))
    player:setCharVar(VAR_JOBS, rolled)
    player:unlockJob(job)
    jobKit(player, job)
    if first then
        player:changeJob(job)
    end

    applyJobs(player)
end

-- The starting set (2026-11-23, the user): a new Randomized character arrives dressed in random level 1 gear its job
-- can wear (HardcoreStarterPool: auction house items only), one piece in each slot that has any, equipped, plus
-- 10,000 gil. Once ([HC]Kit), and only while the character is still level 1. Ranged and ammo stay empty (a bow
-- needs the right arrows). When the game's creation screen made it, the kit waits until Fate has changed its looks.
local VAR_KIT     = '[HC]Kit'
local KIT_GIL     = 10000
local KIT_SLOTS   = { 0, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } -- main, sub, head .. back (the game's slot numbers)

H.starterGear = function(player, job)
    if type(HardcoreStarterPool) ~= 'function' then
        return {}
    end

    local pool = HardcoreStarterPool(job, player:getRace())
    local used, given = {}, {}
    local main
    for _, slot in ipairs(KIT_SLOTS) do
        local skip = slot == 1 and main ~= nil and pool.twoHanded and pool.twoHanded[main]
        local list = pool[slot]
        if not skip and type(list) == 'table' then
            local choices = {}
            for _, id in ipairs(list) do
                if not used[id] then
                    choices[#choices + 1] = id
                end
            end

            if #choices > 0 then
                local id = choices[math.random(#choices)]
                used[id] = true
                if player:addItem(id) then
                    player:equipItem(id, nil, slot)
                    given[#given + 1] = id
                    if slot == 0 then
                        main = id
                    end
                end
            end
        end
    end

    return given
end

local function starterKit(player)
    if player:getCharVar(VAR_KIT) ~= 0 then
        return
    end

    local rolled = player:getCharVar(VAR_JOBS)
    for job = 1, ERA_JOBS do
        if hasBit(rolled, job) and player:getJobLevel(job) > 1 then
            player:setCharVar(VAR_KIT, 1)             -- an older Randomized character: no kit
            return
        end
    end

    player:setCharVar(VAR_KIT, 1)
    local ok, given = pcall(H.starterGear, player, player:getMainJob())
    player:addGil(KIT_GIL)
    local pieces = ok and #given or 0
    tell(player, string.format('Fate dressed you for the road: %d piece%s of gear, and %d gil in your pocket.',
        pieces, pieces == 1 and '' or 's', KIT_GIL))
end

H.randomLogin = function(player)
    if player:getCharVar(VAR_JOBS) == 0 then
        local job = rollJob(0)
        giveJob(player, job, true)
        tell(player, string.format('Fate has spoken: you are a %s.', jobName(job)))
        writeOut('start', player, H.RANDOM, job, 1, '')
    else
        applyJobs(player)
    end

    if player:getCharVar(VAR_LOOKS) == 0 then
        player:setCharVar(VAR_LOOKS, 1)
        local race = math.random(1, 8)
        local face = math.random(0, 15)
        local size = math.random(0, 2)
        tell(player, 'Fate is choosing how you look... (you move to the area again in a moment)')
        player:timer(2500, function(entity)
            if not entity:raceChange(race, face, size) then
                entity:setCharVar(VAR_LOOKS, 0)       -- try again next time
            end
        end)
        return                                        -- the starting set comes when it arrives with its new looks
    end

    starterKit(player)
end

H.randomGrants = function(player)
    local rolled = player:getCharVar(VAR_JOBS)
    local highest = 0
    for job = 1, ERA_JOBS do
        if hasBit(rolled, job) then
            highest = math.max(highest, player:getJobLevel(job))
        end
    end

    local grants = player:getCharVar(VAR_GRANTS)
    while grants < #GRANT_AT and highest >= GRANT_AT[grants + 1] do
        grants = grants + 1
        player:setCharVar(VAR_GRANTS, grants)
        local job = rollJob(player:getCharVar(VAR_JOBS))
        if job == nil then
            break
        end

        giveJob(player, job, false)
        tell(player, string.format('Fate has a new path for you: %s! Change jobs at a Moogle to try it.', jobName(job)))
        announce(player, string.format('%s (Randomized) was given %s at level %d.', player:getName(), jobName(job), GRANT_AT[grants]))
        writeOut('grant', player, H.RANDOM, job, GRANT_AT[grants], '')
    end
end

-- squad.lua asks: may a squad mate of this player be this job? (the starting six and the player's own jobs are asked
-- there first)
H.squadJob = function(player, job)
    return H.mode(player) == H.RANDOM and hasBit(player:getCharVar(VAR_SQUAD), job)
end

-- a job unlock quest done by a Randomized character goes to its squad, not to the character
m:addOverride('npcUtil.completeQuest', function(player, ...)
    local result = super(player, ...)
    if H.mode(player) == H.RANDOM then
        pcall(applyJobs, player)
    end

    return result
end)

local lootPools, nmPool = {}, nil

local function zonePool(zone)
    lootPools[zone] = lootPools[zone] or HardcoreLootPool(zone)
    return lootPools[zone]
end

H.randomLoot = function(player, mob, itemId)
    if type(HardcoreCanSwap) ~= 'function' or not HardcoreCanSwap(itemId) then
        return itemId
    end

    local pool
    if mob:isNM() then
        nmPool = nmPool or HardcoreNMPool()
        pool = nmPool
    else
        pool = zonePool(mob:getZoneID())
    end

    return H.pickFrom(pool, itemId)
end

-- something else from the pool than what it was, most of the time
H.pickFrom = function(pool, itemId)
    if pool == nil or #pool < 2 then
        return itemId
    end

    for _ = 1, 4 do
        local pick = pool[math.random(#pool)]
        if pick ~= itemId then
            return pick
        end
    end

    return itemId
end

-- A battlefield's pool: what every battlefield with the same level cap can give (their own loot tables), so a
-- level 20 fight gives level 20 fight things and an uncapped one gives uncapped ones.
local bcPools = {}

H.battlefieldPool = function(battlefieldId)
    local contents = xi.battlefield and xi.battlefield.contents or {}
    local content  = contents[battlefieldId]
    if content == nil then
        return nil
    end

    local cap = content.levelCap or 0
    if bcPools[cap] then
        return bcPools[cap]
    end

    local ids, have = {}, {}
    for _, other in pairs(contents) do
        if (other.levelCap or 0) == cap and type(other.loot) == 'table' then
            for _, group in ipairs(other.loot) do
                if type(group) == 'table' then
                    for _, entry in ipairs(group) do
                        local id = type(entry) == 'table' and entry.itemId or nil
                        if id and id ~= xi.item.GIL and not have[id] and HardcoreCanSwap(id) then
                            have[id] = true
                            ids[#ids + 1] = id
                        end
                    end
                end
            end
        end
    end

    bcPools[cap] = ids
    return ids
end

-- Randomized: what comes out of a treasure chest or coffer, or a battlefield's crate (the C++ addTreasure asks).
-- In a battlefield: the pool of battlefields with its level cap; elsewhere: the area's own drop pool.
H.randomTreasure = function(player, dropper, itemId)
    if type(HardcoreCanSwap) ~= 'function' or not HardcoreCanSwap(itemId) then
        return itemId
    end

    local pool
    local battlefield = player:getBattlefield()
    if battlefield then
        pool = H.battlefieldPool(battlefield:getID())
    end

    if pool == nil or #pool < 2 then
        pool = zonePool(player:getZoneID())
    end

    if pool == nil or #pool < 2 then
        nmPool = nmPool or HardcoreNMPool()
        pool = nmPool
    end

    return H.pickFrom(pool, itemId)
end

-- Randomized: the casket a Randomized character's kill leaves (casket_tweaks.lua fills it when it appears) holds
-- random items of the area's pool, each a different one
H.randomCasket = function(player, items)
    if H.mode(player) ~= H.RANDOM or type(HardcoreCanSwap) ~= 'function' then
        return items
    end

    local pool, out, used = zonePool(player:getZoneID()), {}, {}
    for slot = 1, 4 do
        local id = items[slot] or 0
        if id > 0 and HardcoreCanSwap(id) then
            for _ = 1, 6 do
                local pick = H.pickFrom(pool, id)
                if not used[pick] then
                    id = pick
                    break
                end
            end
        end

        used[id] = true
        out[slot] = id
    end

    return out
end

-- The same for the game's own caskets, when casket_tweaks.lua is not loaded. The casket rolls its items the
-- first time it is opened, with xi.itemUtils.pickItemRandom; for a Randomized opener each roll is swapped for an
-- item of the area's pool before the casket shows them, so what you see is what you get.
m:addOverride('xi.caskets.onTrigger', function(player, npc)
    if H.mode(player) ~= H.RANDOM or npc:getLocalVar('[caskets]ITEMS_SET') == 1 or
        type(xi.itemUtils) ~= 'table' or type(xi.itemUtils.pickItemRandom) ~= 'function'
    then
        return super(player, npc)
    end

    local original = xi.itemUtils.pickItemRandom
    local pool     = zonePool(player:getZoneID())
    xi.itemUtils.pickItemRandom = function(...)
        local id = original(...)
        if type(id) == 'number' and id > 0 and HardcoreCanSwap(id) then
            return H.pickFrom(pool, id)
        end

        return id
    end

    local ok, result = pcall(super, player, npc)
    xi.itemUtils.pickItemRandom = original
    if not ok then
        error(result)
    end

    return result
end)

-----------------------------------
-- deaths
-----------------------------------
m:addOverride('xi.player.onPlayerDeath', function(player)
    super(player)

    local mode = H.mode(player)
    if mode == 0 or isBot(player) then
        return
    end

    player:setCharVar(VAR_DEATHS, player:getCharVar(VAR_DEATHS) + 1)
    if mode == H.RANDOM then
        return                                  -- not hardcore: a normal death
    end

    local job = player:getMainJob()
    local level = player:getJobLevel(job)

    if mode == H.STEEL then
        if level > 1 then
            player:setCharVar(VAR_RESET, 100 + job)
            tell(player, string.format('Steel: you were knocked out. Your %s goes back to level 1 when you get up.', jobName(job)))
            announce(player, string.format('%s (Steel) fell on %s at level %d. Back to level 1.', player:getName(), jobName(job), level))
            writeOut('delevel', player, mode, job, level, '')
            watchReset(player, 0)
        end
    elseif mode == H.SILVER then
        if player:getCharVar(VAR_DEAD) == 0 then
            local lasted = H.survivalText(survived(player))
            player:setCharVar(VAR_DEAD, os.time())
            announce(player, string.format('%s (Silver) has fallen. %s %d, hardcore for %s. Rest well.', player:getName(), jobName(job), level, lasted))
            writeOut('death', player, mode, job, level, lasted)
            tell(player, 'Silver: your journey ends here. This character is locked and will be deleted in 7 days.')
            print(string.format('[hardcore] %s (Silver) died: %s %d, %s', player:getName(), jobName(job), level, lasted))
            player:timer(12000, function(entity)
                entity:leaveGame()
            end)
        end
    end
end)

-----------------------------------
-- milestones: every 10 levels on a job, once per job
-----------------------------------
m:addOverride('xi.player.onPlayerLevelUp', function(player)
    super(player)

    local mode = H.mode(player)
    if mode == 0 or isBot(player) then
        return
    end

    if mode == H.RANDOM then
        pcall(H.randomGrants, player)
        return
    end

    local job = player:getMainJob()
    local level = player:getJobLevel(job)
    local reached = math.min(H.MILESTONE_TOP, math.floor(level / H.MILESTONE_STEP) * H.MILESTONE_STEP)
    local paid = player:getCharVar(VAR_MS .. job)
    if reached < H.MILESTONE_STEP or reached <= paid then
        return
    end

    -- every milestone passed (a big jump pays each one it passed)
    local count = 0
    for at = paid + H.MILESTONE_STEP, reached, H.MILESTONE_STEP do
        if at >= H.MILESTONE_STEP then
            count = count + H.GIFTS[mode]
        end
    end

    player:setCharVar(VAR_MS .. job, reached)
    local sent = sendGifts(player, count)
    if sent < count then
        player:setCharVar(VAR_GIFTS, player:getCharVar(VAR_GIFTS) + count - sent)
    end

    tell(player, string.format('%s milestone: %s level %d! %d cosmetic reward%s sent to your delivery box.', H.modeName(mode), jobName(job), reached, count, count == 1 and '' or 's'))
    announce(player, string.format('%s (%s) reached level %d on %s.', player:getName(), H.modeName(mode), reached, jobName(job)))
    writeOut('milestone', player, mode, job, reached, '')
end)

-----------------------------------
-- the cosmetic pool: only the good ones (Claude's pick, 2026-11-23; every one is in the golden casket list, so its
-- model shows in game; see NOTE-casket-costume-models). Out of era is fine. Duplicates are avoided when possible.
-----------------------------------
local POOL =
{
    -- creature masques and suits
    10250, 10429,                 -- Moogle Suit, Moogle Masque
    23790, 23791,                 -- Adenium Masque, Adenium Suit
    23862, 23863,                 -- Boudox's Masque, Boudox's Suit
    23864, 23865,                 -- Magh Bihu's Masque, Magh Bihu's Suit
    25639, 25715,                 -- Korrigan Masque, Korrigan Suit
    25657, 25756,                 -- Wyrmking Masque, Wyrmking Suit
    26798, 26954,                 -- Behemoth Masque, Behemoth Suit
    26705, 27854,                 -- Mandragora Masque, Mandragora Suit
    27715, 27866,                 -- Goblin Masque, Goblin Suit
    27716, 27867,                 -- Green Moogle Masque, Green Moogle Suit
    27765, 27911,                 -- Chocobo Masque, Chocobo Suit
    25711,                        -- Botulus Suit
    -- famous heads
    23737, 24273, 26789,          -- Byakko Masque, Sobu Houou Kabuto, Shobuhouou Kabuto
    10384, 25645, 25672, 26707,   -- Cumulus Masque, Kupo Masque, Snoll Masque, Flan Masque
    26703, 25638, 26717, 26719,   -- Lycopodium Masque, Pachypodium Masque, Cait Sith Cap, Sheep Cap
    26738, 26788, 27717, 27726,   -- Leafkin Cap, Rabbit Cap, Worm Masque, She-Slime Hat
    27757, 25648, 25649, 25650,   -- Bomb Masque, Curmudgeon's Helmet, Gazer's Helmet, Retching Helmet
    25652, 25670, 25675, 25677,   -- Crab Cap, Rarab Cap, White Rarab Cap, Arthros Cap
    10447, 25586, 25604, 25632,   -- Pyracmon Cap, Kakai Cap, Buffalo Cap, Carbie Cap
    26693, 11500, 23731, 25585,   -- Morbol Cap, Chocobo Beret, Royal Chocobo Beret, Black Chocobo Cap
    23802, 23806, 15213, 13917,   -- Aucuba Crown, Vaquero Hat, Laurel Crown, Horror Head
    16075, 16076, 15178,          -- Witch Hat, Coven Hat, Dream Hat
    -- whole armour looks
    23812, 23813, 23814, 23815, 23816, -- Sapphire
    23817, 23818, 23819, 23820, 23821, -- Jadeite
    23822, 23823, 23824, 23825, 23826, -- Diamond
    23827, 23828, 23829, 23830, 23831, -- Emerald
    23832, 23833, 23834, 23835, 23836, -- Ruby
    23837, 23838, 23839, 23840, 23841, -- Apathy
    23842, 23843, 23844, 23845,        -- Rage
    23846, 23847, 23848, 23849, 23850, -- Cowardice
    23851, 23852, 23853, 23854, 23855, -- Envy
    23856, 23857, 23858, 23859, 23860, -- Arrogance
    23807, 23808, 23809,               -- Esthete's set
    25674, 26521, 25814, 25857, 25939, -- Ilm set
    27714, 27923, 28063,               -- Councilor's set (Mirth Masquette)
    26523, 25817,                      -- Delegate's set
    -- clothes worth showing off
    14519, 15752, 11355, 16378,        -- Dream Robe, Dream Boots, Dinner Jacket, Dinner Hose
    26517, 25755, 27872, 27873, 27902, -- Shadow Lord Shirt, Crustacean Shirt, the three Spriggan coats
}

local poolChecked = nil

H.cosmeticPool = function()
    if poolChecked then
        return poolChecked
    end

    -- keep only items this server knows (GetItemByID gives nil for an unknown id)
    poolChecked = {}
    for _, itemId in ipairs(POOL) do
        local known = true
        if type(GetItemByID) == 'function' then
            local ok, item = pcall(GetItemByID, itemId)
            known = ok and item ~= nil
        end

        if known then
            poolChecked[#poolChecked + 1] = itemId
        end
    end

    return poolChecked
end

-----------------------------------
-- squad gear: "Squad gets all gear" and "keep the item" never apply while a hardcore player is in this world
-- (a host's own switches; at home the hardcore profiles keep them off anyway)
-----------------------------------
local function hardcoreOnline()
    for id, mode in pairs(online) do
        if GetPlayerByID(id) ~= nil and mode <= 3 then
            return true
        end

        online[id] = nil
    end

    return false
end

m:addOverride('xi.server.onServerStart', function(...)
    local result = super(...)
    -- (assigned through _G: inside an override, a plain global assignment lands in the override's own environment)
    if type(_G.squadAllGear) == 'function' then
        local allGear = _G.squadAllGear
        _G.squadAllGear = function(...)
            if hardcoreOnline() then
                return false
            end

            return allGear(...)
        end
    end

    if type(_G.squadKeepGear) == 'function' then
        local keepGear = _G.squadKeepGear
        _G.squadKeepGear = function(...)
            if hardcoreOnline() then
                return false
            end

            return keepGear(...)
        end
    end

    -- bot players never join a Steel or Silver party (the core refuses it too; this saves the bots the try)
    local function guard(fnName, playerArg)
        local original = _G[fnName]
        if type(original) ~= 'function' then
            return
        end

        _G[fnName] = function(...)
            local args = { ... }
            local target = args[playerArg]
            if type(target) == 'number' then
                target = GetPlayerByID(target)
            end

            if target ~= nil and type(target) ~= 'number' and H.mode(target) >= H.STEEL then
                return false
            end

            return original(...)
        end
    end

    guard('BotJoinParty', 2)
    guard('BotInvite', 2)

    return result
end)

-----------------------------------
-- the hub: other worlds' lines (the launcher writes hardcore_in.txt: "<seq>|<text>")
-----------------------------------
local lastSeq = 0
local nextLook = 0

local function showIncoming()
    local handle = io.open(IN_FILE, 'r')
    if not handle then
        return
    end

    local lines = {}
    for line in handle:lines() do
        lines[#lines + 1] = line
    end

    handle:close()

    local newest = lastSeq
    for _, line in ipairs(lines) do
        local seq, text = line:match('^(%d+)|(.+)$')
        seq = tonumber(seq)
        if seq and seq > lastSeq and text then
            newest = math.max(newest, seq)
            if lastSeq > 0 then -- (the first look only notes where the file is: no replay of old lines)
                for id, _ in pairs(seen) do
                    local p = GetPlayerByID(id)
                    if p == nil then
                        seen[id] = nil
                    else
                        pcall(function()
                            p:printToArea(string.format('\129\154 %s \129\154', text), xi.msg.channel.SYSTEM_3, xi.msg.area.SYSTEM, '', false)
                        end)
                        break
                    end
                end
            end
        end
    end

    lastSeq = math.max(newest, lastSeq == 0 and 1 or lastSeq)
end

m:addOverride('xi.server.onTimeServerTick', function(...)
    local result = super(...)
    if H.isHub and os.time() >= nextLook then
        nextLook = os.time() + 10
        pcall(showIncoming)
    end

    return result
end)

-----------------------------------
-- the hcicons add-on (badges over hardcore characters' heads): it sends !hcicons when it arrives in an area, and gets
-- one hidden line back, "[HC-ICONS] !Name=1,Other=3" (the add-on hides every line with [HC-ICONS] in it). A hardcore
-- character arriving later is told to the players there whose add-on asked: "[HC-ICONS] Name=2".
-----------------------------------
local ICON_MARK = '[HC-ICONS]'

local function zonePlayers(player)
    local ok, list = pcall(function()
        return player:getZone():getPlayers()
    end)
    return ok and type(list) == 'table' and list or {}
end

local iconsCommand = {}
iconsCommand.cmdprops = { permission = 0, parameters = '' }
iconsCommand.onTrigger = function(player)
    player:setLocalVar('HC_ICONS', 1)
    local parts = {}
    for _, other in pairs(zonePlayers(player)) do
        local mode = H.mode(other)
        if mode > 0 and other:getCharVar(VAR_DEAD) == 0 then
            parts[#parts + 1] = other:getName() .. '=' .. mode
        end
    end

    player:printToPlayer(ICON_MARK .. ' !' .. table.concat(parts, ','), xi.msg.channel.SYSTEM_3)
end

xi.module.registerCommand('hcicons', iconsCommand)

H.tellIcons = function(player)
    local mode = H.mode(player)
    if mode == 0 then
        return
    end

    for _, other in pairs(zonePlayers(player)) do
        if other:getID() ~= player:getID() and other:getLocalVar('HC_ICONS') == 1 then
            other:printToPlayer(string.format('%s %s=%d', ICON_MARK, player:getName(), mode), xi.msg.channel.SYSTEM_3)
        end
    end
end

-----------------------------------
-- !hardcore: your mode, deaths, milestones. GM: !hardcore restore <name> (a Silver character that died to a bug)
-----------------------------------
local command = {}
command.cmdprops = { permission = 0, parameters = 'ss' }
command.onTrigger = function(player, action, name)
    action = string.lower(action or '')

    if action == 'restore' then
        if player:getGMLevel() < 1 then
            tell(player, 'Only a GM can restore a fallen Silver character (the launcher\'s HARDCORE menu on the dev PC can too).')
            return
        end

        local target = name and GetPlayerByName(name) or nil
        if target == nil then
            tell(player, 'The character must be logged in to restore it here. Use the HARDCORE menu (dev PC) for one that is offline.')
            return
        end

        target:setCharVar(VAR_DEAD, 0)
        tell(player, target:getName() .. ' is restored.')
        return
    end

    local mode = H.mode(player)
    if mode == 0 then
        tell(player, 'This is not a hardcore character. New hardcore characters start from the launcher\'s HARDCORE menu.')
        return
    end

    local parts = {}
    for job = 1, #JOB_NAMES do
        local ms = player:getCharVar(VAR_MS .. job)
        if ms > 0 then
            parts[#parts + 1] = jobName(job) .. ' ' .. ms
        end
    end

    tell(player, string.format('%s hardcore for %s. Deaths: %d.%s Milestones: %s.', H.modeName(mode), H.survivalText(survived(player)),
        player:getCharVar(VAR_DEATHS), mode == H.STEEL and string.format(' Jobs back to 1: %d.', player:getCharVar(VAR_RESETS)) or '',
        #parts > 0 and table.concat(parts, ', ') or 'none yet'))
end

xi.module.registerCommand('hardcore', command)

return m
