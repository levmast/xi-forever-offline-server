-- stand-ins for the server pieces hardcore.lua uses
xi = { msg = { channel = { SYSTEM_3 = 29 }, area = { SYSTEM = 1 } }, objType = { PC = 1 }, settings = { main = { GIL_RATE = 1, HOMEPOINT_TELEPORT = 1, ENABLE_SURVIVAL_GUIDE = 1, TABS_RATE = 1 } } }
xi.module = { registry = {}, commands = {} }
xi.module.registerCommand = function(name, c) xi.module.commands[name] = c end
local function getpath(s) local t = _G; for part in s:gmatch('[^.]+') do t = t and t[part] end; return t end
local function setpath(s, v) local t = _G; local parts = {}; for p in s:gmatch('[^.]+') do parts[#parts+1]=p end
  for i=1,#parts-1 do t[parts[i]] = t[parts[i]] or {}; t = t[parts[i]] end; t[parts[#parts]] = v end
Module = {}; Module.__index = Module
function Module:new(name) local o = setmetatable({ name = name, overrides = {} }, self); table.insert(xi.module.registry, o); return o end
function Module:addOverride(path, fn) table.insert(self.overrides, { path, fn }) end
function applyAll() for _, mod in ipairs(xi.module.registry) do for _, o in ipairs(mod.overrides) do
  local old = getpath(o[1]); assert(type(old) == 'function', 'missing target ' .. o[1])
  local env = setmetatable({ super = old }, { __index = _G }); setfenv(o[2], env); setpath(o[1], o[2]) end end end
package.preload['modules/module_utils'] = function() return true end
-- base functions to be overridden
npcUtil = { giveReward = function(p) return xi.settings.main.GIL_RATE end, completeQuest = function(p) return xi.settings.main.GIL_RATE end,
  completeMission = function(p) return xi.settings.main.GIL_RATE end }
xi.regime = { checkRegime = function(p) return xi.settings.main.TABS_RATE end }
xi.caskets = { spawnCasket = function(p) return 0 end, onTrigger = function(p, npc) return 'casket' end }
xi.homepoint = { onTrigger = function(p) return xi.settings.main.HOMEPOINT_TELEPORT end, onEventUpdate = function() end, onEventFinish = function() end }
xi.survivalGuide = { onTrigger = function(p) return xi.settings.main.ENABLE_SURVIVAL_GUIDE end, onEventUpdate = function() end, onEventFinish = function() end }
xi.player = { onGameIn = function() return 'base' end, onPlayerDeath = function() end, onPlayerLevelUp = function() end }
xi.server = { onServerStart = function() end, onTimeServerTick = function() end }
-- C++ stand-ins
sent = {}; resets = {}; kicked = {}; area = {}; timers = {}
SendItemToDeliveryBox = function(name, id, q, from) table.insert(sent, { name, id, from }); return 0 end
GetItemByID = function(id) return {} end
players = {}
GetPlayerByID = function(id) return players[id] end
GetPlayerByName = function(n) for _, p in pairs(players) do if p:getName() == n then return p end end end
HardcoreResetJob = function(id) local p = players[id]; if p.dead then return false end; p.jobs[p.mjob] = 1; table.insert(resets, id); return true end
function newPlayer(id, name)
  local p = { id = id, name = name, vars = {}, jobs = {}, mjob = 1, dead = false, msgs = {}, items = {} }
  for j = 1, 22 do p.jobs[j] = 1 end
  function p:getObjType() return 1 end
  function p:getID() return self.id end
  function p:getName() return self.name end
  function p:getCharVar(k) return self.vars[k] or 0 end
  function p:setCharVar(k, v) self.vars[k] = v end
  function p:getJobLevel(j) return self.jobs[j] end
  function p:getMainJob() return self.mjob end
  function p:isDead() return self.dead end
  function p:printToPlayer(t) table.insert(self.msgs, t) end
  function p:printToArea(t) table.insert(area, t) end
  function p:timer(ms, fn) table.insert(timers, { self, fn }) end
  function p:leaveGame() kicked[self.id] = true end
  function p:hasItem(i) return self.items[i] end
  function p:getGMLevel() return self.gm or 0 end
  function p:getTitle() return self.title or 0 end
  function p:setTitle(t) self.title = t end
  function p:getZoneID() return self.zone or 100 end
  function p:getBattlefield() return self.battlefield end
  players[id] = p
  return p
end
function runTimers() local list = timers; timers = {}; for _, t in ipairs(list) do t[2](t[1]) end end
