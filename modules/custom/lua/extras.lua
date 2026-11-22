-----------------------------------
-- XI: Forever Offline: the switches for the additions of 2026-11-21. Loaded by crowds.lua and bots.lua
-- (pcall(require, 'modules/custom/lua/extras'); it is not in init.txt).
--
--   crowd_gates   crowd members walk in from the zone lines and Mog House doors, and leave through them
--   crowd_meet    two crowd members passing each other may stop for a moment
--   bot_social    bot players: emotes at the right moments (bots_social.lua)
--   bot_memory    bot players remember where they died and stay away for a while (bots_memory.lua)
--   bot_story     bot players keep a life story across restarts (bots_story.lua)
--   bot_gates     bot players leave town through its gates and come home through them (bots_gates.lua)
--
-- Everything is ON unless switched off.
--   * The launcher: World page (Town crowds, Bot players), or the classic Rates list. It writes extras_config.lua
--     (next to this file) on every launch, like the other *_config.lua files.
--   * In game: !extras (the list), !extras <name> on|off, !extras all on|off. That holds until the next PLAY, when
--     the launcher's setting decides again (with no launcher, e.g. a hand-started server, it is kept).
-- Switched off, the game behaves exactly as it did before these additions.
-----------------------------------
local E = {}

local PATH = 'modules/custom/lua/extras_config.lua'
local ORDER = { 'crowd_gates', 'crowd_meet', 'bot_social', 'bot_memory', 'bot_story', 'bot_gates' }
local ABOUT =
{
    crowd_gates = 'crowd members come and go through zone lines and Mog House doors',
    crowd_meet  = 'crowd members stop for each other on the road',
    bot_social  = 'bot players emote at the right moments',
    bot_memory  = 'bot players remember where they died',
    bot_story   = 'bot players keep a life story',
    bot_gates   = 'bot players leave and come home through the town gates',
}
local KNOWN = {}
for _, key in ipairs(ORDER) do
    KNOWN[key] = true
end

local values = nil -- [key] = false for what was switched off (nil = on)

local function load()
    values = {}
    local chunk = loadfile(PATH)
    if not chunk then
        return
    end

    local ok, t = pcall(chunk)
    if ok and type(t) == 'table' then
        for key in pairs(KNOWN) do
            if t[key] == false then
                values[key] = false
            end
        end
    end
end

local function save()
    local f = io.open(PATH, 'w')
    if not f then
        return false
    end

    f:write('-- Written by !extras (extras.lua). The launcher writes this file again on every launch.\n')
    f:write('return {\n')
    for _, key in ipairs(ORDER) do
        f:write(string.format('    %s = %s,\n', key, values[key] == false and 'false' or 'true'))
    end
    f:write('}\n')
    f:close()
    return true
end

function E.on(key)
    if values == nil then
        load()
    end

    return KNOWN[key] == true and values[key] ~= false
end

function E.set(key, on)
    if values == nil then
        load()
    end

    if not KNOWN[key] then
        return false
    end

    if on == false then
        values[key] = false
    else
        values[key] = nil
    end

    return save()
end

function E.reload()
    load()
end

function E.keys()
    return ORDER
end

function E.about(key)
    return ABOUT[key] or ''
end

if xi then
    xi.extras = E

    -- the in-game command (your own characters; a co-op visitor cannot use it)
    local cmd = {}
    cmd.cmdprops = { permission = 0, parameters = 'ss' }
    cmd.onTrigger = function(player, name, state)
        if xi.coop and xi.coop.blockGuest and xi.coop.blockGuest(player, 'extras', name) then
            return
        end

        local channel = (xi.msg and xi.msg.channel and xi.msg.channel.SYSTEM_3) or 0
        local function say(text)
            player:printToPlayer('[Extras] ' .. text, channel)
        end

        name = string.lower(name or '')
        state = string.lower(state or '')
        if name == '' or name == 'list' then
            for _, key in ipairs(ORDER) do
                say(string.format('%s: %s (%s)', key, E.on(key) and 'ON' or 'off', ABOUT[key]))
            end

            say('!extras <name> on|off     !extras all on|off')
            return
        end

        if state ~= 'on' and state ~= 'off' then
            say('Usage: !extras <name> on|off     (!extras lists the names)')
            return
        end

        local keys = name == 'all' and ORDER or (KNOWN[name] and { name } or nil)
        if not keys then
            say('No such switch: ' .. name .. '. !extras lists them.')
            return
        end

        for _, key in ipairs(keys) do
            E.set(key, state == 'on')
        end

        say(string.format('%s: %s%s', name, state == 'on' and 'ON' or 'off',
            ' (until the next PLAY: the launcher\'s World / Rates page decides then)'))
    end

    if xi.module and xi.module.registerCommand then
        pcall(xi.module.registerCommand, 'extras', cmd)
    end
end

return E
