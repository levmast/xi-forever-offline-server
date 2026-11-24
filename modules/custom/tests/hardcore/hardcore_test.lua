dofile('hardcore_harness.lua')
dofile('hardcore.lua')
applyAll()
local H = xi.hardcore
local function check(c, msg) if not c then error('FAIL: ' .. msg, 2) end; print('ok  ' .. msg) end

-- becoming hardcore
local iron = newPlayer(1, 'Ironhide'); xi.player.onGameIn(iron, true, false)
check(iron:getCharVar('[HC]Mode') == 1, 'pending Iron applied at first login')
local steel = newPlayer(2, 'Steely'); xi.player.onGameIn(steel, true, false)
check(H.mode(steel) == 2, 'Steel applied')
local silver = newPlayer(3, 'Silvia'); xi.player.onGameIn(silver, true, false)
check(H.mode(silver) == 3, 'Silver applied')
local lv = newPlayer(4, 'Leveled'); lv.jobs[3] = 5; xi.player.onGameIn(lv, true, false)
check(H.mode(lv) == 0, 'a character with a level gained is refused')
local normal = newPlayer(5, 'Normal'); xi.player.onGameIn(normal, true, false)
check(H.mode(normal) == 0, 'not in the list: stays normal')

-- rates swapped only for the call, and restored
check(npcUtil.completeQuest(steel) == 2.0, 'Steel quest gil rate 2.0 during the call')
check(xi.settings.main.GIL_RATE == 1, 'world GIL_RATE restored after')
check(npcUtil.completeQuest(normal) == 1, 'normal character keeps the world rate')
check(xi.homepoint.onTrigger(steel) == 0, 'Steel: no Home Point teleports')
check(xi.homepoint.onTrigger(iron) == 1, 'Iron keeps Home Point teleports')
check(xi.survivalGuide.onTrigger(silver) == 0, 'Silver: no Survival Guides')
check(H.noFastTravel(steel) and not H.noFastTravel(iron), 'noFastTravel')
check(xi.regime.checkRegime(silver) == 3.0, 'Silver tabs 3.0')
-- an error inside still restores
local okErr = pcall(H.withRates, steel, function() error('boom') end)
check(not okErr and xi.settings.main.GIL_RATE == 1, 'restored after an error')

-- milestones
steel.jobs[1] = 10; xi.player.onPlayerLevelUp(steel)
check(#sent == 2, 'Steel level 10: 2 cosmetics sent, got ' .. #sent)
check(sent[1][3] == 'Hardcore' and sent[1][2] ~= sent[2][2], 'sender Hardcore, two different items')
steel.jobs[1] = 11; xi.player.onPlayerLevelUp(steel)
check(#sent == 2, 'level 11 pays nothing')
silver.jobs[1] = 30; xi.player.onPlayerLevelUp(silver)
check(#sent == 2 + 9, 'Silver jump to 30 pays 10,20,30 x3 = 9, got ' .. (#sent - 2))
iron.jobs[1] = 75; xi.player.onPlayerLevelUp(iron)
check(#sent == 11 + 7, 'Iron to 75 pays up to 70 (7), got ' .. (#sent - 11))

-- Steel death: job back to 1 when up, milestone not paid again
sent = {}
steel.jobs[1] = 14; steel.dead = true; xi.player.onPlayerDeath(steel)
check(steel:getCharVar('[HC]Reset') == 101, 'reset waiting for WAR')
runTimers(); check(steel.jobs[1] == 14, 'not reset while still dead')
steel.dead = false; runTimers()
check(steel.jobs[1] == 1 and steel:getCharVar('[HC]Reset') == 0, 'reset to 1 once up')
check(steel:getCharVar('[HC]Resets') == 1, 'reset counted')
steel.jobs[1] = 10; xi.player.onPlayerLevelUp(steel)
check(#sent == 0, 'milestone 10 not paid twice after a delevel')
steel.jobs[1] = 20; xi.player.onPlayerLevelUp(steel)
check(#sent == 2, 'next milestone 20 pays')

-- Silver death: locked, kicked, login refused
silver.dead = true; xi.player.onPlayerDeath(silver)
check(silver:getCharVar('[HC]Dead') > 0, 'Silver death recorded')
runTimers(); check(kicked[3], 'Silver logged out after death')
kicked[3] = nil; silver.dead = false; timers = {}
xi.player.onGameIn(silver, false, false); runTimers()
check(kicked[3], 'locked Silver cannot log in')
local deaths = 0; for _, t in ipairs(area) do if t:find('has fallen') then deaths = deaths + 1 end end
check(deaths == 1, 'one fall announcement')

-- Iron death: nothing special
xi.player.onPlayerDeath(iron); check(iron:getCharVar('[HC]Deaths') == 1 and iron:getCharVar('[HC]Reset') == 0, 'Iron death counted only')

-- out file
local f = io.open('modules/custom/lua/hardcore_out.txt'); local text = f:read('*a'); f:close()
check(text:find('|milestone|Steely|Steel|WAR|10||Test World') ~= nil, 'out line written')
check(text:find('|death|Silvia|Silver|WAR|30|') ~= nil, 'death line written')

-- bot guard and squad gear
BotJoinParty = function(bot, playerId) return true end
squadAllGear = function() return true end
xi.server.onServerStart()
check(BotJoinParty(99, 2) == false, 'bots refused for Steel')
check(BotJoinParty(99, 1) == true, 'bots fine for Iron')
check(squadAllGear() == false, 'all gear off while hardcore online')

-- hub incoming
local f2 = io.open('modules/custom/lua/hardcore_in.txt', 'w'); f2:write('5|old line\n'); f2:close()
area = {}; xi.server.onTimeServerTick(); check(#area == 0, 'first look replays nothing')
local f3 = io.open('modules/custom/lua/hardcore_in.txt', 'a'); f3:write('6|Bob (Silver) has fallen.\n'); f3:close()
xi.hardcore = H; -- tick waits 10 s
local t0 = os.time; os.time = function() return t0() + 20 end
xi.server.onTimeServerTick(); check(#area == 1 and area[1]:find('Bob'), 'new hub line shown')
os.time = t0

-- command
xi.module.commands.hardcore.onTrigger(steel, '', nil)
check(steel.msgs[#steel.msgs]:find('Steel hardcore for'), '!hardcore status')
print('ALL PASSED')
-- icons
local zoneList = { iron, steel, normal }
for _, p in ipairs(zoneList) do p.lv = {}; function p:getZone() return { getPlayers = function() return zoneList end } end
  function p:getLocalVar(k) return self.lv[k] or 0 end; function p:setLocalVar(k, v) self.lv[k] = v end end
normal.msgs = {}
xi.module.commands.hcicons.onTrigger(normal)
local got = normal.msgs[#normal.msgs]
check(got:find('%[HC%-ICONS%] !') and got:find('Ironhide=1') and got:find('Steely=2') and not got:find('Normal'), 'icons list for the area: ' .. got)
iron.msgs = {}; H.tellIcons(steel)
check(#iron.msgs == 0, 'no icon line to a player without the add-on')
check(normal.msgs[#normal.msgs] == '[HC-ICONS] Steely=2', 'icon line to a player whose add-on asked')
print('ICONS PASSED')
