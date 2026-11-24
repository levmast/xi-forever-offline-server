-----------------------------------
-- core_guard.lua: a crash guard any server Lua can use.
--
-- A Lua error inside a server callback must never travel up into the engine. This helper runs a function, catches an error, writes one short
-- line to the server log and carries on. The same error repeating (a bad row hit every tick) cannot flood the log: each tag gets a few lines
-- per time window, the rest are counted, and the next line after the window says how many were held back.
--
--   local guard = require('modules/custom/lua/core_guard')
--   local ok, a, b = guard.call('mything.tick', fn, arg1, arg2)   -- true, <fn's results>   or   false, <error text>
--   local safe = guard.wrap('mything.tick', fn)                   -- the same, as a function: safe(arg1, arg2)
--   guard.stats()                                                 -- { [tag] = { errors, logged, held, held_total, last } }
--   guard.configure({ burst = 3, window = 60, sink = print, clock = os.time, max_tags = 200, max_text = 300 })
--   guard.reset()                                                 -- forget the counters (tests, or after a reload)
--
-- Nothing here is specific to one script. Loading the file changes nothing: it registers nothing, hooks nothing, and logs nothing until a
-- guarded call actually fails.
-----------------------------------
local unpack = table.unpack or unpack
local function pack(...) return { n = select('#', ...), ... } end

local G = { VERSION = 1 }

local cfg = { burst = 3, window = 60, sink = print, clock = os.time, max_tags = 200, max_text = 300 }
local stats, tag_count = {}, 0

function G.configure(opts)
    for k, v in pairs(opts or {}) do
        if cfg[k] ~= nil then cfg[k] = v end
    end
end

function G.reset()
    stats, tag_count = {}, 0
end

function G.stats()
    return stats
end

local function text_of(err)
    local t = type(err)
    if t == 'string' then return err end
    if t == 'table' or t == 'userdata' then
        local ok, s = pcall(tostring, err)
        if ok and type(s) == 'string' then return s end
        return '<' .. t .. ' error>'
    end
    return tostring(err)
end

local function short(s)
    s = tostring(s):gsub('[%c]+', ' ')
    if #s > cfg.max_text then s = s:sub(1, cfg.max_text) .. '...' end
    return s
end

-- the entry of a tag; a server that keeps inventing tags cannot grow the table past max_tags (the extras share one entry)
local function entry_of(tag)
    local e = stats[tag]
    if e then return e end
    if tag_count >= cfg.max_tags then
        tag = '(other)'
        e = stats[tag]
        if e then return e end
    end
    e = { errors = 0, logged = 0, held = 0, last = nil, started = nil, held_total = 0 }
    stats[tag] = e
    tag_count = tag_count + 1
    return e
end

local function note(tag, err)
    local e = entry_of(tag)
    local now = cfg.clock()
    e.errors = e.errors + 1
    e.last = short(text_of(err))
    if e.started == nil or now - e.started >= cfg.window then
        local held = e.held
        e.started, e.logged, e.held = now, 0, 0
        e.pending_held = held
    end
    if e.logged < cfg.burst then
        e.logged = e.logged + 1
        local extra = ''
        if e.pending_held and e.pending_held > 0 then
            extra = string.format(' (%d more held back)', e.pending_held)
            e.pending_held = 0
        end
        pcall(cfg.sink, string.format('[guard] %s: %s%s', short(tag), e.last, extra))
    else
        e.held = e.held + 1
        e.held_total = e.held_total + 1
    end
end

local function handler(err)
    -- keep the message and a short stack for the log; the stack is cut so one line stays one line
    local msg = text_of(err)
    if type(err) == 'string' and debug and debug.traceback then
        local tb = debug.traceback('', 2):gsub('^%s*stack traceback:%s*', '')
        tb = tb:gsub('%s*\n%s*', ' < ')
        msg = msg .. ' @ ' .. tb:sub(1, 160)
    end
    return msg
end

function G.call(tag, fn, ...)
    if type(fn) ~= 'function' then
        note(tag or '(nil)', 'guard.call: not a function: ' .. type(fn))
        return false, 'not a function'
    end
    local n, args = select('#', ...), { ... }
    local r = pack(xpcall(function() return fn(unpack(args, 1, n)) end, handler))
    if r[1] then return unpack(r, 1, r.n) end
    note(tostring(tag or '(nil)'), r[2])
    return false, r[2]
end

function G.wrap(tag, fn)
    return function(...) return G.call(tag, fn, ...) end
end

return G
