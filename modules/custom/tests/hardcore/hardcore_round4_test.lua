-- Randomized round 4 (2026-11-24): weighted / levelled drops, NM window, RNG / COR kit, milestones, Fated monsters,
-- random squad. Run from a folder holding hardcore.lua and the harness (see hardcore_test.lua).
dofile('hardcore_harness.lua')
bit = bit or require('bit')
xi.job = { WAR = 1, SMN = 15, PUP = 18 }
xi.magic = { spell = { CARBUNCLE = 296 } }; xi.petType = { AUTOMATON = 2 }; xi.item = { HARLEQUIN_FRAME = 8224, HARLEQUIN_HEAD = 8193 }
xi.mod = { HPP = 2, ATTP = 23 }
HardcoreSetJobs = function(id, mask) players[id].unlocked = mask; return true end
HardcoreCanSwap = function(id) return id >= 1000 and id < 3000 end
HardcoreLootPool = function(zone) return { 1001, 1002 } end
HardcoreNMPool = function() return { 1900 } end
HardcoreLootTable = function(zone)
    return { { id = 1001, w = 500, lvl = 0 }, { id = 1002, w = 10, lvl = 0 }, { id = 1010, w = 300, lvl = 12 },
             { id = 1050, w = 300, lvl = 60 }, { id = 1003, w = 1, lvl = 8 } }
end
HardcoreNMTable = function()
    return { { id = 2010, w = 100, lvl = 10, nm = 12 }, { id = 2011, w = 100, lvl = 14, nm = 15 },
             { id = 2070, w = 100, lvl = 70, nm = 72 }, { id = 2071, w = 100, lvl = 70, nm = 74 } }
end
HardcoreStarterPool = function() local t = { twoHanded = {} }; for s = 0, 15 do t[s] = {} end; return t end
dofile('hardcore.lua')
applyAll()
local H = xi.hardcore
local function check(c, msg) if not c then error('FAIL: ' .. msg, 2) end; print('ok  ' .. msg) end

-- weighted drops keep how rare things are
math.randomseed(7)
local mob = { isNM = function() return false end, getZoneID = function() return 100 end, getMainLvl = function() return 10 end }
local counts = {}
for _ = 1, 4000 do local id = H.randomLoot(nil, mob, 1999); counts[id] = (counts[id] or 0) + 1 end
check(counts[1050] == nil, 'a level 60 item never drops from a level 10 monster')
check((counts[1001] or 0) > (counts[1002] or 0) * 10, 'a common item stays far more common than a rare one (' .. tostring(counts[1001]) .. ' vs ' .. tostring(counts[1002]) .. ')')
check((counts[1010] or 0) > 0 and (counts[1003] or 0) < 60, 'level 12 fits a level 10 monster; a 1-in-1000 item stays rare (' .. tostring(counts[1003]) .. ')')
local high = { isNM = function() return false end, getZoneID = function() return 100 end, getMainLvl = function() return 62 end }
local c60 = 0; for _ = 1, 200 do if H.randomLoot(nil, high, 1999) == 1050 then c60 = c60 + 1 end end
check(c60 > 0, 'a level 62 monster can drop the level 60 item')
-- NM window
local nm = { isNM = function() return true end, getZoneID = function() return 100 end, getMainLvl = function() return 13 end }
local bad = 0; for _ = 1, 500 do local id = H.randomLoot(nil, nm, 2999); if id == 2070 or id == 2071 then bad = bad + 1 end end
check(bad == 0, 'a level 13 NM never gives what level 72 NMs give')
local nm40 = { isNM = function() return true end, getZoneID = function() return 100 end, getMainLvl = function() return 40 end }
local any = H.randomLoot(nil, nm40, 2999); check(any ~= 2999, 'an NM with nobody near its level still gets something (wider window)')
check(H.randomLoot(nil, mob, 4096) == 4096, 'a crystal stays')
-- without the new tables (an older xi_map): the flat pools
local keepT, keepN = HardcoreLootTable, HardcoreNMTable
HardcoreLootTable, HardcoreNMTable = nil, nil
local mob2 = { isNM = function() return false end, getZoneID = function() return 200 end, getMainLvl = function() return 10 end }
local flat = H.randomLoot(nil, mob2, 1001); check(flat == 1002, 'an older xi_map: the flat area pool as before')
HardcoreLootTable, HardcoreNMTable = keepT, keepN

-- RNG / COR kit
local r = newPlayer(9, 'Randall'); r.bag, r.worn, r.gil = {}, {}, 0
function r:getRace() return 3 end
function r:getMainLvl() return self.jobs[self.mjob] end
function r:addItem(id, n) self.bag[#self.bag + 1] = { id, n or 1 }; return true end
function r:equipItem(id, c, slot) self.worn[slot] = id end
H.starterGear(r, 11)
check(r.worn[2] == 17152 and r.worn[3] == 17318 and r.bag[#r.bag][2] == 99, 'a Ranger gets a Shortbow and 99 Wooden Arrows, worn')
r.worn = {}; r.bag = {}
H.starterGear(r, 17)
check(r.worn[2] == nil and r.worn[3] == 17343 and r.bag[1][1] == 19221, 'a Corsair gets 99 Bronze Bullets worn and a Firefly in the bag (level 5)')

-- Fated monsters
local listeners = {}
local function newMob(name, isNM)
    local m = { name = name, vars = {}, mods = {}, size = 0, hp = 100, maxhp = 100, nm = isNM, listeners = {} }
    function m:isMob() return true end
    function m:isNM() return self.nm end
    function m:isAlive() return true end
    function m:getLocalVar(k) return self.vars[k] or 0 end
    function m:setLocalVar(k, v) self.vars[k] = v end
    function m:getPacketName() return self.name end
    function m:renameEntity(n) self.name = n end
    function m:addMod(k, v) self.mods[k] = (self.mods[k] or 0) + v end
    function m:delMod(k, v) self.mods[k] = (self.mods[k] or 0) - v end
    function m:updateHealth() self.maxhp = 100 * (100 + (self.mods[xi.mod.HPP] or 0)) / 100 end
    function m:getMaxHP() return self.maxhp end
    function m:setHP(v) self.hp = v end
    function m:setModelSize(s) self.size = s end
    function m:getMainLvl() return 10 end
    function m:getZoneID() return 100 end
    function m:addListener(ev, id, fn) self.listeners[id] = fn end
    function m:removeListener(id) self.listeners[id] = nil end
    return m
end
local treasure = {}
local p = newPlayer(10, 'Fatey'); p.vars['[HC]Mode'] = 4
function p:addListener(ev, id, fn) listeners[id] = fn end
function p:removeListener(id) listeners[id] = nil end
function p:addTreasure(id, from) treasure[#treasure + 1] = H.randomTreasure(self, from, id) end
function p:getMainLvl() return 10 end
H.watchFate(p)
check(listeners.HC_FATE_ENGAGE ~= nil, 'a Randomized character watches its fights')
H.FATED_CHANCE = 100
local rabbit = newMob('Wild Rabbit', false)
listeners.HC_FATE_ENGAGE(p, rabbit)
check(rabbit.name == 'Fated Wild Rabbit' and rabbit.size == 3 and rabbit.hp == 150, 'Fated: renamed, largest size, half again its HP')
check(rabbit.mods[xi.mod.ATTP] == 15, 'Fated: hits 15% harder')
area = {}
rabbit.listeners.HC_FATED_DEATH(rabbit, p)
check(#treasure == 1 and treasure[1] ~= nil, 'a Fated monster leaves a jackpot: ' .. tostring(treasure[1]))
local jp = treasure[1]
check(jp ~= 1050 and jp ~= 2070 and jp ~= 2071, 'the jackpot fits its level')
check(rabbit.name == 'Wild Rabbit' and rabbit.size == 0 and (rabbit.mods[xi.mod.HPP] or 0) == 0, 'a normal monster again afterwards')
check(#area == 1 and area[1]:find('Fate smiles on Fatey'), 'the jackpot is announced')
local king = newMob('Leaping Lizzy', true); listeners.HC_FATE_ENGAGE(p, king)
check(king.name == 'Leaping Lizzy', 'an NM is never Fated')
p.battlefield = {}; local bf = newMob('Bee', false); listeners.HC_FATE_ENGAGE(p, bf); p.battlefield = nil
check(bf.name == 'Bee', 'no Fated monsters in a battlefield')
local plain = newPlayer(11, 'Plain'); local seen = newMob('Crab', false)
H.maybeFated(plain, seen)  -- (a regular character's listener is never added; the mode check in the listener guards it too)
H.FATED_CHANCE = 0; local miss = newMob('Bat', false); listeners.HC_FATE_ENGAGE(p, miss)
check(miss.name == 'Bat', 'at 0% nothing is Fated')
local despawned = newMob('Hare', false); H.FATED_CHANCE = 100; listeners.HC_FATE_ENGAGE(p, despawned)
despawned.listeners.HC_FATED_DESPAWN(despawned)
check(despawned.name == 'Hare' and despawned.size == 0, 'a Fated monster that despawns is normal again')

-- random squad
local mates = { { id = 501, slot = 1, name = 'Bob', mjob = 1, sjob = 2, race = 1, face = 0, jobs = { [1] = { level = 30 } } },
                { id = 502, slot = 2, name = 'Ann', mjob = 3, sjob = 0, race = 2, face = 1, jobs = {} } }
local saved = {}
GetSquad = function() return mates end
SaveSquadMate = function(cid, slot, m) saved[#saved + 1] = { slot, m.mjob, m.sjob } end
check(H.randomSquadPrepare(p, mates[1]) == nil and mates[1].mjob == 1, 'off by default: the squad is normal')
check(H.randomSquadJobAllowed(p, mates[1], 9), 'off: any job is allowed')
H.randomSquadCommand(p, 'on')
check(p:getCharVar('[HC]RSquad') == 1, 'random squad on')
local mask1 = p:getCharVar('[HC]RSJobs501')
local look = H.randomSquadPrepare(p, mates[1])
check(look and look.race >= 1 and look.race <= 8 and look.face >= 0 and look.face <= 15 and look.size >= 1 and look.size <= 3, 'a mate gets its own rolled looks')
check(bit.band(mask1, bit.lshift(1, mates[1].mjob)) ~= 0, 'and is on its rolled job')
check(mates[1].sjob == 0 or bit.band(p:getCharVar('[HC]RSJobs501'), bit.lshift(1, mates[1].sjob)) ~= 0, 'a support job only from its rolled jobs')
local look2 = H.randomSquadPrepare(p, mates[1]); check(look2.race == look.race and look2.face == look.face, 'the looks stay the same each call')
local other
for j = 1, 18 do if bit.band(p:getCharVar('[HC]RSJobs501'), bit.lshift(1, j)) == 0 then other = j; break end end
check(not H.randomSquadJobAllowed(p, mates[1], other), 'a job fate did not give is refused')
H.randomSquadLevel(p, 501, 18, 'Bob')
local n2 = 0; for j = 1, 18 do if bit.band(p:getCharVar('[HC]RSJobs501'), bit.lshift(1, j)) ~= 0 then n2 = n2 + 1 end end
check(n2 == 2, 'a second rolled job at 18')
H.randomSquadLevel(p, 501, 70, 'Bob'); H.randomSquadLevel(p, 501, 75, 'Bob')
local n4 = 0; for j = 1, 18 do if bit.band(p:getCharVar('[HC]RSJobs501'), bit.lshift(1, j)) ~= 0 then n4 = n4 + 1 end end
check(n4 == 4, 'four rolled jobs in all, never more, never a repeat')
check(p:getCharVar('[HC]RSJobs502') ~= 0 and p:getCharVar('[HC]RSJobs502') ~= nil, 'every mate rolls for itself')
H.randomSquadCommand(p, 'off')
check(p:getCharVar('[HC]RSquad') == 0 and mates[1].mjob == 1 and mates[1].sjob == 2, 'off: the mate is itself again (WAR / MNK)')
check(H.randomSquadPrepare(p, mates[1]) == nil, 'off: its own looks')
local kept = p:getCharVar('[HC]RSJobs501'); H.randomSquadCommand(p, 'on')
check(p:getCharVar('[HC]RSJobs501') == kept, 'on again: the same rolls come back')
local iron = newPlayer(12, 'Irony'); iron.vars['[HC]Mode'] = 1
H.randomSquadCommand(iron, 'on'); check(iron:getCharVar('[HC]RSquad') == 0, 'only Randomized characters have a random squad')
-- (2026-11-24) the first roll: every mate a different race (then a different race and gender)
local RACE_OF = { 1, 1, 2, 2, 3, 3, 4, 5 }
for trial = 1, 20 do
    local rp = newPlayer(100 + trial, 'Racer' .. trial); rp.vars['[HC]Mode'] = 4
    local six = {}
    for i = 1, 6 do six[i] = { id = 600 + i, slot = i, name = 'M' .. i, mjob = 1, sjob = 0, race = 1, face = 0, jobs = {} } end
    GetSquad = function() return six end
    H.randomSquadCommand(rp, 'on')
    local races, models = {}, {}
    for i = 1, 6 do
        local m = math.floor(rp:getCharVar('[HC]RSLook' .. (600 + i)) / 1000)
        models[m] = (models[m] or 0) + 1
        if i <= 5 then races[RACE_OF[m]] = (races[RACE_OF[m]] or 0) + 1 end
    end
    for _, c in pairs(races) do assert(c == 1, 'two of the first five mates share a race') end
    for _, c in pairs(models) do assert(c == 1, 'two mates share a race and gender') end
end
check(true, 'first roll: the first five mates are five different races, a sixth a different race and gender (20 squads)')
print('ROUND4 PASSED')
