-----------------------------------
-- Gambits v2, M2: writing the squad Rule Set store (XI: Forever Offline).
--
-- The in-game editor (Gambits addon, SQUAD tab) saves Rule Sets through the !gsq command (gambits_squad.lua), and this
-- file does the writing. Reading, checking, choosing and running sets stays in squad_rulesets.lua (M1.1), unchanged:
-- it reads modules/custom/lua/squad_rulesets_data.lua again every time a mate is called, so a saved set applies at the
-- next call ("Apply now" = !squad reapply), without restarting the server.
--
-- Rules for writing (docs: Gambits v2 M2 design decisions):
--   * Only the editor writes, and only whole files: the raw file is read again, ONLY the edited set is replaced or added,
--     every other set is kept as it is (also sets that do not pass the checks, and fields this file does not know).
--   * A file that cannot be read is never overwritten (fix it by hand first).
--   * Write <file>.tmp, read it back, keep the old file as <file>.bak, then replace: MoveFileExA(REPLACE_EXISTING) through
--     LuaJIT ffi on Windows when it is there; otherwise rename the old file to <file>.old, rename .tmp into place and
--     remove .old (on Windows os.rename cannot replace a file; on Linux os.rename replaces in one step).
--   * recover() repairs what a crash between those steps could leave (no file but a .old or a good .tmp).
--   * Comments in a hand-written file are not kept once the editor saves (the .bak keeps the old text).
-- Ownership: a set the editor made has owner = <character id> and only that character may change or delete it; a set
-- without an owner (written by hand) is read-only for the editor. The extra field is ignored by squad_rulesets.lua.
-- This file defines no globals and registers nothing (the module loader treats it as a library).
-----------------------------------
local St = {}

St.PATH          = 'modules/custom/lua/squad_rulesets_data.lua'
St.STORE_FORMAT  = 'xifo-ruleset-store'
St.SET_FORMAT    = 'xifo-ruleset'
St.VERSION       = 1
St.MAX_NAME      = 24

-- ---------------------------------------------------------------- serialising (deterministic, so rev() is stable)
local SET_KEYS  = { 'format', 'version', 'num', 'id', 'name', 'job', 'owner', 'readonly', 'rules' }
local RULE_KEYS = { 'id', 'on', 'target', 'include', 'exclude', 'cond', 'cond2', 'action', 'retry', 'level' } -- (0.3.3: include / exclude roles)
local STORE_KEYS = { 'format', 'version', 'sets' }

local function isArray(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end

    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end

    return true, n
end

local function orderedKeys(t, first)
    local keys, seen = {}, {}
    for _, k in ipairs(first or {}) do
        if t[k] ~= nil then
            keys[#keys + 1] = k
            seen[k] = true
        end
    end

    local rest = {}
    for k in pairs(t) do
        if not seen[k] then
            if type(k) ~= 'string' and type(k) ~= 'number' then
                error('a table key that is not a string or number cannot be saved')
            end

            rest[#rest + 1] = k
        end
    end

    table.sort(rest, function(a, b)
        if type(a) == type(b) then
            return a < b
        end

        return type(a) == 'number'
    end)
    for _, k in ipairs(rest) do
        keys[#keys + 1] = k
    end

    return keys
end

local function keyText(k)
    if type(k) == 'string' and string.match(k, '^[%a_][%w_]*$') then
        return k
    end

    if type(k) == 'number' then
        return '[' .. St.numberText(k) .. ']'
    end

    return '[' .. string.format('%q', k) .. ']'
end

function St.numberText(v)
    if v ~= v or v == math.huge or v == -math.huge then
        error('a number that is not finite cannot be saved')
    end

    if v == math.floor(v) and v >= -2 ^ 53 and v <= 2 ^ 53 then
        return string.format('%d', v)
    end

    return string.format('%.17g', v)
end

-- One value as Lua text. depth: indentation level; keysFor(depth, value) chooses the key order.
local function valueText(v, depth, keysFor, seen)
    local kind = type(v)
    if kind == 'string' then
        return (string.gsub(string.format('%q', v), '\\\n', '\\n'))
    elseif kind == 'number' then
        return St.numberText(v)
    elseif kind == 'boolean' then
        return tostring(v)
    elseif kind ~= 'table' then
        error('a ' .. kind .. ' cannot be saved')
    end

    if seen[v] then
        error('a table that contains itself cannot be saved')
    end

    seen[v] = true
    local array, n = isArray(v)
    local out
    if array and n <= 4 then
        -- short lists (conditions, actions) on one line: { 'HPP_LT', 50 }
        local parts = {}
        for i = 1, n do
            parts[i] = valueText(v[i], depth + 1, keysFor, seen)
        end

        out = n == 0 and '{}' or ('{ ' .. table.concat(parts, ', ') .. ' }')
    elseif array then
        local pad = string.rep('    ', depth + 1)
        local parts = {}
        for i = 1, n do
            parts[i] = pad .. valueText(v[i], depth + 1, keysFor, seen) .. ','
        end

        out = '{\n' .. table.concat(parts, '\n') .. '\n' .. string.rep('    ', depth) .. '}'
    else
        local pad = string.rep('    ', depth + 1)
        local parts = {}
        for _, k in ipairs(orderedKeys(v, keysFor(depth, v))) do
            parts[#parts + 1] = pad .. keyText(k) .. ' = ' .. valueText(v[k], depth + 1, keysFor, seen) .. ','
        end

        out = '{\n' .. table.concat(parts, '\n') .. '\n' .. string.rep('    ', depth) .. '}'
    end

    seen[v] = nil
    return out
end

local function keysFor(_, t)
    if t.rules ~= nil or t.num ~= nil then
        return SET_KEYS
    elseif t.action ~= nil or t.cond ~= nil or t.target ~= nil then
        return RULE_KEYS
    elseif t.sets ~= nil then
        return STORE_KEYS
    end

    return nil
end

-- The canonical text of any plain value (also used for rev)
function St.valueText(v)
    return valueText(v, 0, keysFor, {})
end

St.HEADER = '-- Squad Rule Sets (Gambits v2). Written by the in-game editor (Gambits addon, SQUAD tab).\n' ..
            '-- squad_rulesets.lua reads this file every time a squad mate is called. Hand edits are fine while the\n' ..
            '-- server is stopped, but comments are not kept when the editor saves (the previous file is kept as .bak).\n'

function St.serialize(store)
    return St.HEADER .. 'return ' .. St.valueText(store) .. '\n'
end

-- A set's revision: a check number of its canonical text (changes whenever anything in the set changes, also by hand)
function St.rev(set)
    local text = St.valueText(set)
    local h = 7
    for i = 1, #text do
        h = (h * 31 + string.byte(text, i)) % 2147483647
    end

    return string.format('%d', h == 0 and 1 or h)
end

-- ---------------------------------------------------------------- file system (replaceable by the tests)
local function isWindows()
    return package.config:sub(1, 1) == '\\'
end

local ffiMove = nil -- function(from, to) -> true | false, why ; or false when not available
local function moveFileEx()
    if ffiMove ~= nil then
        return ffiMove
    end

    ffiMove = false
    if not isWindows() then
        return ffiMove
    end

    local ok, ffi = pcall(require, 'ffi')
    if not ok or type(ffi) ~= 'table' or ffi.os ~= 'Windows' then
        return ffiMove
    end

    pcall(ffi.cdef, 'int MoveFileExA(const char* existing, const char* new, unsigned long flags); unsigned long GetLastError(void);')
    local okC, fn = pcall(function() return ffi.C.MoveFileExA end)
    if not okC or fn == nil then
        return ffiMove
    end

    ffiMove = function(from, to)
        local done = ffi.C.MoveFileExA(from, to, 0x1 + 0x8) -- MOVEFILE_REPLACE_EXISTING + MOVEFILE_WRITE_THROUGH
        if done ~= 0 then
            return true
        end

        return false, 'MoveFileExA failed, Windows error ' .. tostring(tonumber(ffi.C.GetLastError()))
    end

    return ffiMove
end

St.fs =
{
    exists = function(path)
        local f = io.open(path, 'rb')
        if f then
            f:close()
            return true
        end

        return false
    end,
    read = function(path)
        local f, err = io.open(path, 'rb')
        if not f then
            return nil, err
        end

        local text = f:read('*a')
        f:close()
        return text
    end,
    write = function(path, text)
        local f, err = io.open(path, 'wb')
        if not f then
            return false, err
        end

        local ok, werr = f:write(text)
        local closed, cerr = f:close()
        if not ok then
            return false, werr
        end

        if not closed then
            return false, cerr
        end

        return true
    end,
    rename = function(from, to)
        local ok, err = os.rename(from, to)
        return ok and true or false, err
    end,
    remove = function(path)
        local ok, err = os.remove(path)
        return ok and true or false, err
    end,
    -- one-step replace when the platform has one: returns true, false+why, or nil (not available)
    replace = function(from, to)
        if not isWindows() then
            local ok, err = os.rename(from, to)
            return ok and true or false, err
        end

        local move = moveFileEx()
        if not move then
            return nil
        end

        return move(from, to)
    end,
    windows = isWindows,
}

-- ---------------------------------------------------------------- reading
local function emptyStore()
    return { format = St.STORE_FORMAT, version = St.VERSION, sets = {} }
end

-- Loads Lua text that returns a table, without running it in the server's globals
local function loadText(text, name)
    local chunk, err
    if setfenv then
        chunk, err = loadstring(text, name)
        if chunk then
            setfenv(chunk, {})
        end
    else
        chunk, err = load(text, name, 't', {})
    end

    if not chunk then
        return nil, err
    end

    local ok, value = pcall(chunk)
    if not ok then
        return nil, value
    end

    return value
end
St.loadText = loadText

-- The raw store: a table, or (when there is no file) an empty one. nil + why when the file is there but unusable.
function St.readRaw(path, fs)
    fs = fs or St.fs
    path = path or St.PATH
    if not fs.exists(path) then
        return emptyStore(), 'new'
    end

    local text, err = fs.read(path)
    if text == nil then
        return nil, 'cannot read ' .. path .. ': ' .. tostring(err)
    end

    local data, lerr = loadText(text, '=' .. path)
    if data == nil then
        return nil, path .. ' is not valid Lua: ' .. tostring(lerr)
    end

    if type(data) ~= 'table' or data.format ~= St.STORE_FORMAT or data.version ~= St.VERSION or type(data.sets) ~= 'table' then
        return nil, path .. ' is not a ' .. St.STORE_FORMAT .. ' version ' .. St.VERSION .. ' store'
    end

    return data
end

-- ---------------------------------------------------------------- recovery and writing
-- Repairs what a crash during a save could leave. Returns a list of what it did (for the server log).
function St.recover(path, fs)
    fs = fs or St.fs
    path = path or St.PATH
    local done = {}
    local tmp, old = path .. '.tmp', path .. '.old'

    local function good(p)
        local text = fs.read(p)
        if not text then
            return false
        end

        local data = loadText(text, '=' .. p)
        return type(data) == 'table' and data.format == St.STORE_FORMAT and type(data.sets) == 'table'
    end

    if not fs.exists(path) then
        if fs.exists(old) and good(old) then
            if fs.rename(old, path) then
                done[#done + 1] = 'restored the previous file from ' .. old
            end
        elseif fs.exists(tmp) and good(tmp) then
            if fs.rename(tmp, path) then
                done[#done + 1] = 'finished an interrupted save from ' .. tmp
            end
        end
    end

    if fs.exists(path) and good(path) then
        if fs.exists(tmp) and fs.remove(tmp) then
            done[#done + 1] = 'removed a left-over ' .. tmp
        end

        if fs.exists(old) and fs.remove(old) then
            done[#done + 1] = 'removed a left-over ' .. old
        end
    end

    return done
end

-- Writes the store safely. Returns true, how | false, why (the old file is then unchanged).
function St.write(store, path, fs)
    fs = fs or St.fs
    path = path or St.PATH
    local tmp, bak, old = path .. '.tmp', path .. '.bak', path .. '.old'

    local okText, text = pcall(St.serialize, store)
    if not okText then
        return false, 'cannot write the store: ' .. tostring(text)
    end

    St.recover(path, fs)

    local wrote, werr = fs.write(tmp, text)
    if not wrote then
        fs.remove(tmp)
        return false, 'cannot write ' .. tmp .. ': ' .. tostring(werr)
    end

    -- read it back: exactly what was meant, and a valid store
    local back = fs.read(tmp)
    local data = back and loadText(back, '=' .. tmp)
    if back ~= text or type(data) ~= 'table' or data.format ~= St.STORE_FORMAT or type(data.sets) ~= 'table'
        or #data.sets ~= #store.sets then
        fs.remove(tmp)
        return false, 'the written file did not read back correctly; nothing was changed'
    end

    local had = fs.exists(path)
    if had then
        local current = fs.read(path)
        if current == nil then
            fs.remove(tmp)
            return false, 'cannot read the current file to keep a backup; nothing was changed'
        end

        local okBak, berr = fs.write(bak, current)
        if not okBak then
            fs.remove(tmp)
            return false, 'cannot write the backup ' .. bak .. ': ' .. tostring(berr) .. '; nothing was changed'
        end
    end

    local how
    local replaced, rerr = fs.replace(tmp, path)
    if replaced == true then
        how = fs.windows() and 'MoveFileEx' or 'rename'
    elseif replaced == nil or not had then
        -- no one-step replace here (or nothing to replace): old file aside, new one in, old one away
        if had then
            local moved, merr = fs.rename(path, old)
            if not moved then
                fs.remove(tmp)
                return false, 'cannot move the current file aside: ' .. tostring(merr) .. '; nothing was changed'
            end
        end

        local placed, perr = fs.rename(tmp, path)
        if not placed then
            if had then
                fs.rename(old, path)
            end

            fs.remove(tmp)
            return false, 'cannot put the new file in place: ' .. tostring(perr) .. '; the previous file was kept'
        end

        if had then
            fs.remove(old)
        end

        how = had and 'rename via .old' or 'new file'
    else
        fs.remove(tmp)
        return false, 'cannot replace the file: ' .. tostring(rerr) .. '; nothing was changed'
    end

    local final = fs.read(path)
    if final ~= text then
        return false, 'the saved file does not match what was written (' .. how .. '); the previous version is in ' .. bak
    end

    return true, how
end

-- ---------------------------------------------------------------- editing (pure: no files, no server)
-- The set may be changed by this character: true, or false + a code and a reason
function St.mayEdit(set, charId)
    if type(set) ~= 'table' then
        return false, 'missing', 'that Rule Set is not there'
    end

    if set.owner == nil then
        return false, 'readonly', 'this Rule Set was written by hand; it can be copied, not changed, in the editor'
    end

    if set.owner ~= charId then
        return false, 'owner', 'this Rule Set belongs to another character'
    end

    if set.readonly == true then
        return false, 'readonly', 'this Rule Set is marked read-only'
    end

    return true
end

-- The set with this number in the raw store, and its index
function St.findByNum(raw, num)
    for i, set in ipairs(raw.sets) do
        if type(set) == 'table' and set.num == num then
            return set, i
        end
    end

    return nil, nil
end

-- The lowest number no set in the raw store uses (sets that do not pass the checks count too)
function St.freeNum(raw, maxNum)
    local used = {}
    for _, set in ipairs(raw.sets) do
        if type(set) == 'table' and type(set.num) == 'number' then
            used[set.num] = true
        end
    end

    for n = 1, maxNum or 9999 do
        if not used[n] then
            return n
        end
    end

    return nil
end

-- A new id for this character that no set uses: user.<character id>.<time>[.<n>]
function St.newId(raw, charId, now)
    local used = {}
    for _, set in ipairs(raw.sets) do
        if type(set) == 'table' and type(set.id) == 'string' then
            used[set.id] = true
        end
    end

    local base = string.format('user.%d.%d', charId, now or os.time())
    local id, n = base, 1
    while used[id] do
        n = n + 1
        id = base .. '.' .. n
    end

    return id
end

-- Applies one edit to a raw store (a copy is NOT made: the caller re-reads the file for every save).
-- edit = { op = 'save' | 'delete', num = 0 (new) or the set's number, rev = the revision the editor started from,
--          job = 'WHM', name = '...', rules = { ... } }
-- Returns the set (or true for delete) | nil, code, reason. Validation: squad_rulesets.lua R.setProblems + unique num/id.
function St.applyEdit(raw, edit, charId, R, now)
    if edit.op == 'delete' then
        local set, index = St.findByNum(raw, edit.num)
        local ok, code, why = St.mayEdit(set, charId)
        if not ok then
            return nil, code, why
        end

        if edit.rev ~= St.rev(set) then
            return nil, 'stale', 'the Rule Set changed since it was loaded; load it again'
        end

        table.remove(raw.sets, index)
        return true
    end

    local set
    if edit.num == 0 then
        local num = St.freeNum(raw, R and R.MAX_NUM or 9999)
        if num == nil then
            return nil, 'full', 'no free Rule Set number'
        end

        set = { format = St.SET_FORMAT, version = St.VERSION, num = num, id = St.newId(raw, charId, now), owner = charId,
                readonly = false }
        raw.sets[#raw.sets + 1] = set
    else
        local index
        set, index = St.findByNum(raw, edit.num)
        local ok, code, why = St.mayEdit(set, charId)
        if not ok then
            return nil, code, why
        end

        if edit.rev ~= St.rev(set) then
            return nil, 'stale', 'the Rule Set changed since it was loaded; load it again'
        end

        -- the same table stays in its place; only these fields change
        raw.sets[index] = set
    end

    set.name, set.job, set.rules = edit.name, edit.job, edit.rules

    local problems = {}
    if R and R.setProblems then
        problems = R.setProblems(set)
    end

    for _, other in ipairs(raw.sets) do
        if other ~= set and type(other) == 'table' then
            if other.num == set.num then
                problems[#problems + 1] = 'num ' .. tostring(set.num) .. ' is used by another set'
            end

            if other.id == set.id then
                problems[#problems + 1] = 'id ' .. tostring(set.id) .. ' is used by another set'
            end
        end
    end

    if #problems > 0 then
        return nil, 'invalid', table.concat(problems, '; ')
    end

    return set
end

-- Reads, edits, checks and writes in one go. Returns set|true, how | nil, code, reason
function St.save(edit, charId, R, path, fs, now)
    fs = fs or St.fs
    path = path or St.PATH
    St.recover(path, fs)
    local raw, err = St.readRaw(path, fs)
    if raw == nil then
        return nil, 'unreadable', err .. '; nothing was saved (fix the file by hand first)'
    end

    local result, code, why = St.applyEdit(raw, edit, charId, R, now)
    if result == nil then
        return nil, code, why
    end

    local ok, how = St.write(raw, path, fs)
    if not ok then
        return nil, 'write', how
    end

    return result, how
end

return St
