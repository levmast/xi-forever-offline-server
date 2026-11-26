dofile('hardcore_harness.lua')
bit = bit or require('bit')
xi.job = { WAR = 1, SMN = 15, PUP = 18 }
xi.magic = { spell = { CARBUNCLE = 296 } }; xi.petType = { AUTOMATON = 2 }; xi.item = { HARLEQUIN_FRAME = 8224, HARLEQUIN_HEAD = 8193 }
local masks = {}
HardcoreSetJobs = function(id, mask) masks[id] = mask; players[id].unlocked = mask; return true end
HardcoreCanSwap = function(id) return id >= 1000 and id < 2000 end
HardcoreLootPool = function(zone) return { 1001, 1002, 1003 } end
HardcoreNMPool = function() return { 1900, 1901 } end
HardcoreStarterPool = function(job, race)
    local t = { twoHanded = { [16001] = true }, shields = { [12001] = true } }
    for slot = 0, 15 do t[slot] = {} end
    t[0] = { 16001 }; t[1] = { 12001 }; t[4] = { 12400 }; t[5] = { 12500 }; t[13] = { 13500, 13501 }; t[14] = { 13500, 13501 }
    return t
end
dofile('hardcore.lua')
applyAll()
local H = xi.hardcore
local function check(c, msg) if not c then error('FAIL: ' .. msg, 2) end; print('ok  ' .. msg) end
local f = io.open('modules/custom/lua/hardcore_pending.lua', 'w'); f:write("return { { name = 'Randall', mode = 4 } }"); f:close()
local r = newPlayer(9, 'Randall')
r.unlocked = 0x7E
function r:hasJob(j) return bit.band(self.unlocked, bit.lshift(1, j)) ~= 0 end
function r:unlockJob(j) self.unlocked = bit.bor(self.unlocked, bit.lshift(1, j)); if self.jobs[j] == 0 then self.jobs[j] = 1 end end
function r:changeJob(j) self.mjob = j; self.unlocked = bit.bor(self.unlocked, bit.lshift(1, j)) end
function r:raceChange(a, b, c) self.race = { a, b, c }; return true end
function r:addSpell() self.carb = true end
function r:setPetName() end
function r:unlockAttachment() end
r.bag, r.worn, r.gil = {}, {}, 0
function r:getRace() return 3 end
function r:getMainLvl() return 1 end
function r:addItem(id) r.bag[#r.bag + 1] = id; return true end
function r:equipItem(id, c, slot) r.worn[slot] = id end
function r:addGil(g) r.gil = r.gil + g end
xi.player.onGameIn(r, true, false)
check(H.mode(r) == 4, 'pending Randomized applied')
runTimers(); runTimers()
check(r.gil == 0 and #r.bag == 0, 'no kit before Fate has changed the looks')
xi.player.onGameIn(r, false, true); runTimers()
check(r.gil == 10000, 'the starting 10,000 gil')
check(r.worn[0] == 16001 and r.worn[1] == nil, 'a two-handed weapon: no shield')
check(r.worn[4] == 12400 and r.worn[5] == 12500, 'head and body filled')
check(r.worn[13] and r.worn[14] and r.worn[13] ~= r.worn[14], 'two different rings')
check(H.RANGED_KIT[r.mjob] ~= nil or (r.worn[2] == nil and r.worn[3] == nil), 'ranged and ammo left empty (but for RNG / COR)')
xi.player.onGameIn(r, false, true); runTimers()
check(r.gil == 10000 and #r.bag == 5, 'the kit comes once')
local rolled = r:getCharVar('[HC]Jobs')
check(rolled ~= 0 and r.mjob >= 1 and r.mjob <= 18 and bit.band(rolled, bit.lshift(1, r.mjob)) ~= 0, 'one era job rolled and set as main: ' .. r.mjob)
check(r.unlocked == rolled, 'only the rolled job is open to the character (mask ' .. r.unlocked .. ')')
check(r.race ~= nil and r.race[1] >= 1 and r.race[1] <= 8, 'random race/face/size')
-- a job quest unlock goes to the squad
r:unlockJob(7); r.msgs = {}
npcUtil.completeQuest(r)
check(bit.band(r:getCharVar('[HC]SquadJobs'), bit.lshift(1, 7)) ~= 0, 'PLD from a quest goes to the squad')
check(bit.band(r.unlocked, bit.lshift(1, 7)) == 0 or bit.band(rolled, bit.lshift(1, 7)) ~= 0, 'and not to the character')
check(H.squadJob(r, 7) and not H.squadJob(iron or newPlayer(50, 'Nobody'), 7), 'squad.lua sees it')
-- grants at 18/33/65
r.jobs[r.mjob] = 18; xi.player.onPlayerLevelUp(r)
local count = 0; for j = 1, 18 do if bit.band(r:getCharVar('[HC]Jobs'), bit.lshift(1, j)) ~= 0 then count = count + 1 end end
check(count == 2 and r:getCharVar('[HC]Grants') == 1, 'second job at 18')
r.jobs[r.mjob] = 70; xi.player.onPlayerLevelUp(r)
count = 0; for j = 1, 18 do if bit.band(r:getCharVar('[HC]Jobs'), bit.lshift(1, j)) ~= 0 then count = count + 1 end end
check(count == 4 and r:getCharVar('[HC]Grants') == 3, 'four jobs in all after 33 and 65')
xi.player.onPlayerLevelUp(r); check(r:getCharVar('[HC]Grants') == 3, 'no fifth job')
check(#sent == 21 and sent[1][3] == 'Fate', 'Randomized milestones: 3 cosmetics each, from Fate (round 4): ' .. #sent)
-- loot
local mob = { isNM = function() return false end, getZoneID = function() return 100 end, getMainLvl = function() return 10 end }
local nm = { isNM = function() return true end, getZoneID = function() return 100 end, getMainLvl = function() return 10 end }
local got = H.randomLoot(r, mob, 1001)
check(got == 1002 or got == 1003, 'a drop becomes another item from the area pool')
check(H.randomLoot(r, mob, 4096) == 4096, 'a crystal stays a crystal')
local n = H.randomLoot(r, nm, 1500); check(n == 1900 or n == 1901, 'an NM drop comes from the NM pool')
-- death is normal
r.dead = true; xi.player.onPlayerDeath(r); r.dead = false
check(r:getCharVar('[HC]Dead') == 0 and r:getCharVar('[HC]Reset') == 0, 'a Randomized death is a normal death')
check(H.noFastTravel(r) == false, 'Randomized keeps teleports')
-- titles: the mode's own, on from the start; a character without a mode loses one
check(r:getTitle() == 1081, "Randomized wears Altana's Wild Card (1081)")
local plain = newPlayer(60, 'Plainjane'); plain.title = 1079; xi.player.onGameIn(plain, false, false)
check(plain:getTitle() == 0, 'a character that stepped down loses the mode title')
-- chests and battlefield crates
xi.item.GIL = 65535
xi.battlefield = { contents = {
    [10] = { levelCap = 20, loot = { { { itemId = 1101 }, { itemId = 1102 }, { itemId = xi.item.GIL }, quantity = 2 }, { { itemId = 4096 } } } },
    [11] = { levelCap = 20, loot = { { { itemId = 1103 } } } },
    [12] = { levelCap = 50, loot = { { { itemId = 1500 }, { itemId = 1501 } } } } } }
local pool20 = H.battlefieldPool(10)
check(#pool20 == 3, 'battlefield pool: the level 20 fights\' items, no gil or crystals (' .. #pool20 .. ')')
r.battlefield = { getID = function() return 11 end }
local bc = H.randomTreasure(r, nil, 1101)
check(bc == 1102 or bc == 1103, 'a level 20 crate gives another level 20 crate item: ' .. bc)
check(H.randomTreasure(r, nil, 4096) == 4096, 'a crystal in a crate stays')
r.battlefield = nil
local chest = H.randomTreasure(r, nil, 1001)
check(chest == 1002 or chest == 1003, 'a chest gives an item of the area pool')
-- caskets (casket_tweaks.lua asks)
local items = H.randomCasket(r, { 1001, 1002, 0, 0 })
check(items[1] ~= 0 and items[2] ~= 0 and items[1] ~= items[2] and items[3] == 0, 'casket: two different area items, empty slots stay empty')
local same = H.randomCasket(plain, { 1001, 0, 0, 0 })
check(same[1] == 1001, 'a regular casket is left alone')
print('RANDOM PASSED')
