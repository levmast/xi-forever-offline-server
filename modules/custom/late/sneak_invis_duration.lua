-----------------------------------
-- Sneak, Invisible and Deodorize duration (XI: Forever Offline, 2026-11-21, Yache)
-- The launcher's Rules > Travel > "Sneak and Invisible duration" (main.SNEAK_INVIS_DURATION_MULTIPLIER, 1 = the
-- era's random 30 s - 5 min) multiplies how long the spells last. In the core the setting only reached Fields of
-- Valor buffs; the spells themselves ignored it. Loaded last (custom/late), so it wraps Phoenix's era duration.
-----------------------------------
require('modules/module_utils')
-----------------------------------
local m = Module:new('sneak_invis_duration')

local function multiplier()
    local value = tonumber(xi.settings and xi.settings.main and xi.settings.main.SNEAK_INVIS_DURATION_MULTIPLIER) or 1
    return math.max(0.1, math.min(10, value))
end

m:addOverride('xi.spells.enhancing.calculateEnhancingDuration', function(caster, target, spell, spellId, spellGroup, spellEffect)
    local duration = super(caster, target, spell, spellId, spellGroup, spellEffect)
    if
        spellEffect == xi.effect.SNEAK or
        spellEffect == xi.effect.INVISIBLE or
        spellEffect == xi.effect.DEODORIZE
    then
        local mult = multiplier()
        if mult ~= 1 then
            duration = math.floor(duration * mult)
        end
    end

    return duration
end)

return m
