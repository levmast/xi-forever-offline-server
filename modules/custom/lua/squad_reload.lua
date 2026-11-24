-----------------------------------
-- Squads hot reload v1 (SQUAD_RELOAD)
--
-- Edit a Squads Lua file while the server runs and the change takes effect without a restart. Delivered as a patch
-- bundle (tools/squads/hot_reload/): this one new file plus one line in modules/init.txt. squad.lua and the other
-- Squads files are NOT edited, so a Squads update cannot conflict with it. Remove the init.txt line and the file and
-- everything is as before.
--
-- What it does
--   * !squad reload            (GM) ordered reload of every active Squads file
--   * !squad reload <file>     (GM) one file plus the files that wrap it (squad_space also reloads squad_range, ...)
--   * !squad reload status     (GM) what is active, the state kept, what the last reload did
--   * !squadreload             (GM) the same as !squad reload, a separate command that works even if !squad is broken
--   * automatic: when the engine's file watcher re-runs a saved Squads file, that bare re-run (which would build a second,
--     empty copy of every local and leave the old listeners on old code) is replaced by the ordered reload of that file.
--     The watcher's own run is cancelled with one error line "[squad_reload] ... replaced by an ordered reload".
--
-- How state survives (no change to squad.lua)
--   A Squads file keeps its working state in chunk-level locals (camps, zoneOut, the chat timers, ...). Running the file
--   again creates fresh copies, while listeners, timers and overrides created earlier keep the old ones. After a file ran
--   again this module walks the old and the new closures and matches their upvalues by name, for names that are
--   chunk-level locals of the file (a line starting with "local" in column 0):
--     * state locals (assigned or mutated inside a function, or listed in R.keep): the new code is handed the OLD value, so
--       the camp table, timers and counters are the same object before and after
--     * everything else (local functions, constants, rule tables): the old closures are handed the NEW value, so the
--       listeners, timers and overrides that are already running call the new code
--   Not refreshed (known limits): the few lines of "glue" inside a listener or override body (those closures keep their old
--   bytecode until the mate is called again, "Apply now" = !squad reapply), and locals declared inside a "do" block.
--
-- Safety
--   Every file is compiled first; one syntax error and nothing is run ("nothing changed"). A runtime error stops the
--   reload at that file and says which. Lua runs on the one game thread, so the whole reload is one server tick.
--
-- Put this file LAST in modules/init.txt (after the Squads files it manages).
-----------------------------------
require('modules/module_utils')

SQUAD_RELOAD = SQUAD_RELOAD or {}
local R = SQUAD_RELOAD

R.version = 2 -- 2: XI Forever v0.3.x file set (sq_logic, squad_requests, custom/late files); the run order follows init.txt
R.dir     = './modules/custom/lua/'

-- Run order (a file may only assume the ones above it). Files that are not on disk or not in init.txt are skipped.
-- A name with a folder ('late/squad_gear_score') is modules/custom/<name>.lua; a plain name is modules/custom/lua/<name>.lua.
-- This is the order of a stock install; the order that runs is the order of the lines in init.txt (orderNow below).
R.order =
{
    'squad_bridge', 'squad', 'squad_logic', 'sq_logic', 'squad_requests',
    'squad_space', 'squad_chain',
    'squad_hate', 'squad_ai_extra', 'squad_ext',
    'gambits_squad', 'squad_tiers',
    'squad_range',
    'squad_moves', 'squad_bard', 'squad_talk',
    'squad_sandbox', 'squad_idle', 'squad_actions', 'squad_bard_walk',
    'late/squad_gear_score',
}

-- Files that wrap another file's function: reloading one reloads the whole group, in this order, so a wrapper is never
-- applied twice or lost.
R.groups =
{
    { 'squad_space', 'squad_range' },
    { 'squad_chain', 'squad_ext' },
    { 'squad_ext', 'squad_moves', 'squad_bard', 'squad_talk' },
}

-- require()d data and rule modules: dropped from package.loaded on a reload so the next require reads the file again.
-- squad_pack and squad_rulesets_store hold live state and are not on this list.
R.data =
{
    'squad_config', 'squad_equipment', 'squad_dialogue', 'squad_food', 'squad_rules_data', 'squad_starter_gear',
    'squad_ws', 'squad_ja_jobs_data', 'squad_spell_jobs_data', 'squad_ability_rules', 'squad_copy_items',
    'squad_rulesets', 'squad_rulesets_data', 'squad_talk_data', 'squad_moves_data', 'squad_moves_user', 'pets_data',
    'squad_jobs', 'squad_item_names',
    -- v0.3.x: required by squad.lua (squad_meals when it loads, squad_shell when a linkshell line comes) and the request words
    'squad_meals', 'squad_shell', 'squad_requests_data',
}

-- Extra state names per file (always handed from the old to the new code), added to what the scan finds.
R.keep =
{
    squad = { 'camps', 'zoneOut', 'chatFightState', 'chatBotsInParty', 'chatHookedPlayers', 'itemLevels', 'jobs' },
}

-- Names that are never state even if the scan thinks so.
R.refresh = {}

R.last   = R.last or nil
R.seen   = R.seen or {}
R.log    = R.log or {}

local function say(player, msg)
    print('[squad_reload] ' .. msg)
    if player ~= nil and player.printToPlayer ~= nil then
        pcall(function() player:printToPlayer(msg) end)
    end
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if fh == nil then
        return nil
    end

    local text = fh:read('*a')
    fh:close()
    return text
end

local function fileOf(name)
    if name:find('/', 1, true) then
        return './modules/custom/' .. name .. '.lua'
    end

    return R.dir .. name .. '.lua'
end

-- the path of a name relative to modules/, the way a line of init.txt writes it
local function relOf(name)
    if name:find('/', 1, true) then
        return 'custom/' .. name .. '.lua'
    end

    return 'custom/lua/' .. name .. '.lua'
end

-- 'custom/lua/squad.lua' out of a chunk source ('@./modules/custom/lua/squad.lua'); nil for any other file
local function sourceKey(source)
    if type(source) ~= 'string' then
        return nil
    end

    local s = source:gsub('\\', '/')
    local late = s:match('custom/(late/[%w_]+)%.lua$')
    if late ~= nil then
        return late
    end

    return s:match('custom/lua/([%w_]+)%.lua$')
end
R.sourceKey = sourceKey

-----------------------------------
-- Which active files exist: init.txt lines, expanded to the files of R.order
-----------------------------------
local function initLines()
    local text = readFile('./modules/init.txt') or ''
    local out = {}
    for line in text:gmatch('[^\r\n]+') do
        line = line:gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' and line:sub(1, 1) ~= '#' then
            out[#out + 1] = line:gsub('\\', '/')
        end
    end

    return out
end

-- a line of init.txt covers a file when it names it, or names a folder above it ("custom/late", "custom/late/")
local function covers(line, rel)
    if line == rel then
        return true
    end

    local dir = line:sub(-1) == '/' and line or (line .. '/')
    return rel:sub(1, #dir) == dir and not line:match('%.[%w]+$')
end

local function activeSet()
    local active = {}
    local lines = initLines()
    for _, name in ipairs(R.order) do
        for n, line in ipairs(lines) do
            if covers(line, relOf(name)) then
                active[name] = n
            end
        end
    end

    return active
end

-- The managed names in the order the engine loaded them: the line number in init.txt, a folder line ("custom/late") after the plain
-- lines of its own number in the order of R.order. Names that are not active keep their place at the end.
local function orderNow()
    local active = activeSet()
    local index = {}
    for i, name in ipairs(R.order) do
        index[name] = i
    end

    local list = {}
    for _, name in ipairs(R.order) do
        list[#list + 1] = name
    end

    table.sort(list, function(a, b)
        local la, lb = active[a] or 1e9, active[b] or 1e9
        if la ~= lb then
            return la < lb
        end

        return index[a] < index[b]
    end)

    return list
end
R.orderNow = orderNow

local function isManaged(name)
    for _, n in ipairs(R.order) do
        if n == name then
            return true
        end
    end

    return false
end

-----------------------------------
-- Scan a file's text: chunk-level locals and whether they are state
-----------------------------------
local function splitLines(text)
    local lines = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = (line:gsub('\r$', ''))
    end

    return lines
end

-- True when "NAME <accessors> =" (an assignment to NAME or to something inside it) is on the line
local function assignsTo(line, name)
    local code = line:gsub('%-%-.*$', '')
    local from = 1
    while true do
        local s, e = code:find(name, from, true)
        if s == nil then
            return false
        end

        local before = s > 1 and code:sub(s - 1, s - 1) or ''
        local after  = code:sub(e + 1, e + 1)
        if not before:match('[%w_%.:]') and not after:match('[%w_]') then
            local i = e + 1
            while true do
                local c = code:sub(i, i)
                if c == '.' and code:sub(i + 1, i + 1):match('[%a_]') then
                    local _, e2 = code:find('^%.[%w_]+', i)
                    i = e2 + 1
                elseif c == '[' then
                    local depth, j = 0, i
                    while j <= #code do
                        local ch = code:sub(j, j)
                        if ch == '[' then depth = depth + 1 elseif ch == ']' then depth = depth - 1 end
                        if depth == 0 then break end
                        j = j + 1
                    end
                    if depth ~= 0 then
                        break
                    end
                    i = j + 1
                else
                    break
                end
            end

            local rest = code:sub(i):match('^%s*(.*)$')
            if rest:sub(1, 1) == '=' and rest:sub(2, 2) ~= '=' then
                local lead = code:sub(1, s - 1):match('^%s*local%s+$') or code:sub(1, s - 1):match('local%s+[%w_,%s]*$')
                if lead == nil then
                    return true
                end
            end
        end

        from = e + 1
    end
end

-- tables the standard library changes in place
local function mutatedByLib(line, name)
    local code = line:gsub('%-%-.*$', '')
    return code:find('table%.[%a]+%(%s*' .. name .. '[%s,%)]') ~= nil
end

-- Returns { names = { NAME = 'func' | 'state' | 'value' }, count = n } for the chunk-level locals of a file
function R.analyze(text, extraKeep)
    local lines = splitLines(text)
    local decl, order = {}, {}
    local inFunction = false
    local runtime = {} -- line numbers of indented lines inside a top-level function
    for n, line in ipairs(lines) do
        if line:match('^end[%s%)%-]*') and (line:match('^end$') or line:match('^end%s') or line:match('^end%)') or line:match('^end,')) then
            inFunction = false
        elseif line:sub(1, 1):match('%S') and line:find('function', 1, true) and not line:match('^%-%-')
            and not line:match('[%s%)]end[%)%s,;]*$') then
            -- a column-0 line that opens a function (local function f / function g / x.y = function / addListener(..., function))
            -- and does not close it on the same line
            inFunction = true
        end

        if inFunction and line:match('^%s+%S') then
            runtime[#runtime + 1] = n
        end

        local fname = line:match('^local%s+function%s+([%w_]+)')
        if fname then
            decl[fname] = decl[fname] or 'func'
            order[#order + 1] = fname
        else
            local names, init = line:match('^local%s+([%w_,%s]-)%s*=%s*(.*)$')
            if names == nil then
                names = line:match('^local%s+([%w_,%s]+)$')
                init = ''
            end

            if names then
                for nm in names:gmatch('[%a_][%w_]*') do
                    if nm ~= 'function' then
                        if decl[nm] == nil then
                            order[#order + 1] = nm
                        end

                        decl[nm] = init:match('^function%s*%(') and 'func' or 'value'
                    end
                end
            end
        end
    end

    local keep = {}
    for _, nm in ipairs(extraKeep or {}) do
        keep[nm] = true
    end

    -- a name that is also declared inside a function (local, parameter, for variable) cannot be told apart from the
    -- chunk-level one by name: it is left alone (unless it is in the curated keep list)
    local ambiguous = {}
    local function mark(list)
        for nm in list:gmatch('[%a_][%w_]*') do
            if decl[nm] ~= nil then
                ambiguous[nm] = true
            end
        end
    end

    for _, line in ipairs(lines) do
        local code = line:gsub('%-%-.*$', '')
        if line:match('^%s') then
            local loc = code:match('local%s+([%w_,%s]-)%s*=') or code:match('local%s+([%w_,%s]+)$')
            if loc then mark(loc) end
            local lf = code:match('local%s+function%s+([%w_]+)')
            if lf then mark(lf) end
        end

        for params in code:gmatch('function%s*[%w_%.:]*%(([^)]*)%)') do
            mark(params)
        end

        for vars in code:gmatch('for%s+([%w_,%s]-)%s+in%s') do
            mark(vars)
        end

        for var in code:gmatch('for%s+([%a_][%w_]*)%s*=') do
            mark(var)
        end
    end

    for nm in pairs(ambiguous) do
        if not keep[nm] then
            decl[nm] = nil
        end
    end

    for nm, kind in pairs(decl) do
        if kind == 'value' then
            if keep[nm] then
                decl[nm] = 'state'
            else
                for _, n in ipairs(runtime) do
                    local line = lines[n]
                    if assignsTo(line, nm) or mutatedByLib(line, nm) then
                        decl[nm] = 'state'
                        break
                    end
                end
            end
        end
    end

    for nm in pairs(R.refresh) do
        if decl[nm] == 'state' then
            decl[nm] = 'value'
        end
    end

    local count = 0
    for _ in pairs(decl) do
        count = count + 1
    end

    return { names = decl, count = count }
end

-----------------------------------
-- Closure collection and the upvalue fix-up
-----------------------------------

-- Every Lua closure whose chunk is one of the files in `keys` ({ squad = true }), reached from the globals, the registry
-- (where the engine keeps the listeners and timers), package.loaded and the upvalues and environments of what it finds.
local function collectClosures(keys)
    local found, seen, stack = {}, {}, {}
    local function push(v)
        local t = type(v)
        if (t == 'table' or t == 'function') and not seen[v] then
            seen[v] = true
            stack[#stack + 1] = v
        end
    end

    push(_G)
    push(package.loaded)
    local okReg, registry = pcall(debug.getregistry)
    if okReg then
        push(registry)
    end

    while #stack > 0 do
        local v = stack[#stack]
        stack[#stack] = nil
        if type(v) == 'table' then
            for k, x in next, v do
                push(k)
                push(x)
            end

            local mt = getmetatable(v)
            if type(mt) == 'table' then
                push(mt)
            end
        else
            local info = debug.getinfo(v, 'S')
            if info ~= nil and info.what == 'Lua' then
                local key = sourceKey(info.source)
                if key ~= nil and keys[key] then
                    found[#found + 1] = { fn = v, file = key }
                end

                local i = 1
                while true do
                    local name, val = debug.getupvalue(v, i)
                    if name == nil then
                        break
                    end

                    push(val)
                    i = i + 1
                end

                local okEnv, env = pcall(getfenv, v)
                if okEnv then
                    push(env)
                end
            end
        end
    end

    return found
end

local function upvaluesOf(closures)
    local byName = {}
    for _, c in ipairs(closures) do
        local i = 1
        while true do
            local name, val = debug.getupvalue(c.fn, i)
            if name == nil then
                break
            end

            if name ~= '_ENV' then
                local list = byName[name]
                if list == nil then
                    list = {}
                    byName[name] = list
                end

                list[#list + 1] = { fn = c.fn, index = i, value = val, file = c.file }
            end

            i = i + 1
        end
    end

    return byName
end

-- Among the upvalues of one name, the cell that most closures share: the chunk-level local (a local of an inner function
-- that happens to have the same name is a different cell, captured by fewer closures). Returns that cell's holders.
local function dominant(list)
    local groups, best, bestN = {}, nil, 0
    for _, u in ipairs(list) do
        local id = debug.upvalueid(u.fn, u.index)
        local g = groups[id]
        if g == nil then
            g = {}
            groups[id] = g
        end

        g[#g + 1] = u
        if #g > bestN then
            best, bestN = g, #g
        end
    end

    return best
end

-- One upvalue cell of an old file, and the cell of the same name in the new copy. kinds: { name = 'func'|'state'|'value' }
local function fixup(oldClosures, newClosures, kinds, stats)
    local oldBy = upvaluesOf(oldClosures)
    local newBy = upvaluesOf(newClosures)
    for name, kind in pairs(kinds) do
        local olds = oldBy[name] and dominant(oldBy[name])
        local news = newBy[name] and dominant(newBy[name])
        if olds ~= nil and news ~= nil then
            local oldValue, newValue = olds[1].value, news[1].value
            if kind == 'state' then
                -- the new code gets the old value
                if oldValue ~= nil and newValue ~= oldValue then
                    debug.setupvalue(news[1].fn, news[1].index, oldValue)
                    stats.kept = stats.kept + 1
                end
            elseif newValue ~= nil and oldValue ~= newValue and type(newValue) == type(oldValue) then
                -- the old closures get the new value
                debug.setupvalue(olds[1].fn, olds[1].index, newValue)
                if kind == 'func' then
                    stats.rebound = stats.rebound + 1
                else
                    stats.values = stats.values + 1
                end
            end
        end
    end
end

-----------------------------------
-- The reload
-----------------------------------
local function expand(selected)
    -- selected: set of names; returns the ordered list including the wrapper groups
    local want = {}
    for name in pairs(selected) do
        want[name] = true
    end

    local changed = true
    while changed do
        changed = false
        for _, group in ipairs(R.groups) do
            local hit = false
            for _, n in ipairs(group) do
                if want[n] then
                    hit = true
                end
            end

            if hit then
                for _, n in ipairs(group) do
                    if not want[n] then
                        want[n] = true
                        changed = true
                    end
                end
            end
        end
    end

    local list = {}
    for _, name in ipairs(orderNow()) do
        if want[name] then
            list[#list + 1] = name
        end
    end

    return list
end

local function dropData()
    local dropped = 0
    for _, name in ipairs(R.data) do
        local key = 'modules/custom/lua/' .. name
        if package.loaded[key] ~= nil then
            package.loaded[key] = nil
            dropped = dropped + 1
        end
    end

    return dropped
end

-- the commands a re-run staged: put them into the published command table in place (the engine holds that table)
local function publishCommands(fromIndex)
    local reg = xi.module.commandRegistry
    for i = #reg, fromIndex + 1, -1 do
        local entry = reg[i]
        xi.commands = xi.commands or {}
        local old = xi.commands[entry.name]
        if old ~= nil and old ~= entry.command then
            for k, v in pairs(entry.command) do
                old[k] = v
            end
        else
            xi.commands[entry.name] = entry.command
        end

        reg[i] = nil
    end
end

function R.hookCommand()
    local cmd = xi.commands and xi.commands.squad
    if cmd == nil or type(cmd.onTrigger) ~= 'function' or cmd.onTrigger == R.wrapped then
        return
    end

    local base = cmd.onTrigger
    R.wrapped = function(player, action, ...)
        if action == 'reload' then
            return R.command(player, ...)
        end

        return base(player, action, ...)
    end

    cmd.onTrigger = R.wrapped
end

-- opts: files = { 'squad_space' } (default every active file), data = true to drop the data modules (default when no
-- file is named), player = who to tell
function R.run(opts)
    opts = opts or {}
    local report = { ok = true, files = {}, started = os.clock() }
    if R.running then
        report.ok, report.err = false, 'a reload is already running'
        return report
    end

    R.last = report

    local active = activeSet()
    local selected = {}
    if opts.files ~= nil then
        for _, n in ipairs(opts.files) do
            if not isManaged(n) then
                report.ok, report.err = false, 'not a Squads file this reload manages: ' .. tostring(n)
                return report
            end

            selected[n] = true
        end
    else
        for n in pairs(active) do
            selected[n] = true
        end
    end

    local list = {}
    for _, n in ipairs(expand(selected)) do
        if active[n] and readFile(fileOf(n)) ~= nil then
            list[#list + 1] = n
        end
    end

    if #list == 0 then
        report.ok, report.err = false, 'no active Squads file to reload'
        return report
    end

    -- 1. compile everything first: a syntax error means nothing runs
    local chunks, texts = {}, {}
    for _, n in ipairs(list) do
        texts[n] = readFile(fileOf(n))
        local fn, err = loadfile(fileOf(n))
        if fn == nil then
            report.ok, report.err = false, string.format('%s.lua does not compile, nothing changed: %s', n, tostring(err))
            return report
        end

        chunks[n] = fn
    end

    -- 2. run them in order
    R.running = true
    local keys = {}
    for _, n in ipairs(list) do
        keys[n] = true
    end

    local data = opts.data
    if data == nil then
        data = opts.files == nil
    end

    report.dropped = data and dropData() or 0

    local okAll = true
    for _, n in ipairs(list) do
        local entry = { name = n, ok = true }
        local t0 = os.clock()
        local oldClosures = collectClosures({ [n] = true })
        local regLen, cmdLen = #xi.module.registry, #xi.module.commandRegistry
        local kinds = R.analyze(texts[n], R.keep[n]).names

        local ok, err = pcall(chunks[n])
        -- the loader would drain these and apply the overrides; a re-run must not (the old overrides stay in place)
        for i = #xi.module.registry, regLen + 1, -1 do
            xi.module.registry[i] = nil
        end

        publishCommands(cmdLen)
        if not ok then
            entry.ok, entry.err = false, tostring(err)
            report.ok = false
            report.files[#report.files + 1] = entry
            okAll = false
            break
        end

        local newClosures = collectClosures({ [n] = true })
        -- the new closures are the ones that are not in the old set
        local isOld = {}
        for _, c in ipairs(oldClosures) do
            isOld[c.fn] = true
        end

        local fresh = {}
        for _, c in ipairs(newClosures) do
            if not isOld[c.fn] then
                fresh[#fresh + 1] = c
            end
        end

        local stats = { kept = 0, rebound = 0, values = 0 }
        fixup(oldClosures, fresh, kinds, stats)
        entry.old, entry.new, entry.stats = #oldClosures, #fresh, stats
        entry.ms = math.floor((os.clock() - t0) * 1000)
        R.seen[n] = true
        report.files[#report.files + 1] = entry
    end

    R.running = false
    R.hookCommand()
    report.ms = math.floor((os.clock() - report.started) * 1000)
    R.last = report
    return report
end

local function describe(report)
    if not report.ok and #report.files == 0 then
        return 'reload refused: ' .. tostring(report.err)
    end

    local parts = {}
    for _, f in ipairs(report.files) do
        if f.ok then
            parts[#parts + 1] = string.format('%s (%d old closures, %d state kept, %d rebound, %d values)', f.name, f.old or 0, f.stats.kept, f.stats.rebound, f.stats.values)
        else
            parts[#parts + 1] = string.format('%s FAILED: %s', f.name, f.err or '?')
        end
    end

    return string.format('%s in %d ms: %s', report.ok and 'reloaded' or 'reload stopped', report.ms or 0, table.concat(parts, '; '))
end

R.describe = describe

-----------------------------------
-- Commands
-----------------------------------
local function allowed(player)
    return player == nil or player.getGMLevel == nil or player:getGMLevel() > 0
end

function R.command(player, arg1, arg2)
    if not allowed(player) then
        say(player, 'Squads reload is for game masters.')
        return
    end

    if arg1 == 'status' then
        local act, names = activeSet(), {}
        for _, n in ipairs(orderNow()) do
            if act[n] then
                names[#names + 1] = n
            end
        end

        say(player, 'Squads hot reload v' .. R.version .. ', active files: ' .. (#names > 0 and table.concat(names, ', ') or 'none'))
        say(player, R.last and describe(R.last) or 'no reload yet')
        return
    end

    local opts = { player = player }
    if arg1 ~= nil and arg1 ~= '' and arg1 ~= 'all' then
        local name = arg1:gsub('%.lua$', '')
        if not isManaged(name) and isManaged('late/' .. name) then
            name = 'late/' .. name -- "!squad reload squad_gear_score" names a file of modules/custom/late
        end

        opts.files = { name }
    end

    local report = R.run(opts)
    say(player, describe(report))
end

if xi.module.commandRegistry ~= nil then
    xi.module.registerCommand('squadreload',
    {
        cmdprops = { permission = 1, parameters = 's' },
        onTrigger = function(player, arg1)
            R.command(player, arg1)
        end,
    })
end

-----------------------------------
-- Automatic: the engine's file watcher re-runs a saved Squads file with a bare safe_script_file; that is turned into the
-- ordered reload of the same file. Every Squads file starts with require('modules/module_utils').
-----------------------------------
if R.origRequire == nil then
    R.origRequire = require
end

-- hand the first run of a file to the engine; a second run of a file we manage is a watcher re-run.
-- Only files that init.txt names itself are known to be loaded already (this file is last). A file that is only covered by a
-- folder line (custom/late) is loaded by the engine AFTER this file, so its first run must not count as a re-run: it is marked
-- seen by the require hook below when that first run happens.
local function seedSeen()
    local named = {}
    for _, line in ipairs(initLines()) do
        named[line] = true
    end

    for name in pairs(activeSet()) do
        if named[relOf(name)] then
            R.seen[name] = true
        end
    end
end
R.seedSeen = seedSeen
seedSeen()

R.auto = R.auto ~= false

_G.require = function(name, ...)
    if R.auto and not R.running and name == 'modules/module_utils' then
        local info = debug.getinfo(2, 'S')
        local key = info and sourceKey(info.source)
        if key ~= nil and isManaged(key) and R.seen[key] then
            local report = R.run({ files = { key } })
            print('[squad_reload] ' .. describe(report))
            error('[squad_reload] ' .. key .. '.lua: the bare re-run was replaced by an ordered reload', 0)
        end

        if key ~= nil and isManaged(key) then
            R.seen[key] = true
        end
    end

    return R.origRequire(name, ...)
end

R.hookCommand()
print('[squad_reload] Squads hot reload v' .. R.version .. ' ready (!squad reload, !squadreload, file watcher)')

return R
