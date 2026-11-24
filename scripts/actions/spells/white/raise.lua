-----------------------------------
-- Spell: Raise
-----------------------------------
---@type TSpell
local spellObject = {}

spellObject.onMagicCastingCheck = function(caster, target, spell)
    -- Can’t cast on living targets
    if target:isAlive() then
        return xi.msg.basic.MAGIC_CANNOT_BE_CAST
    end

    -- Only PCs should ever be blocked by the Raise/Tractor menu state
    if target:isPC() and target:hasRaiseTractorMenu() then
        return xi.msg.basic.MAGIC_CANNOT_BE_CAST
    end

    -- Non-PC targets must be explicitly raisable (behavior bit)
    if
        not target:isPC() and
        bit.band(target:getBehavior(), xi.behavior.RAISABLE) == 0
    then
        return xi.msg.basic.MAGIC_CANNOT_BE_CAST
    end

    return 0
end

spellObject.onSpellCast = function(caster, target, spell)
    if target:isPC() then
        target:sendRaise(1)
    elseif target:getLocalVar('SQUAD_ID') > 0 and xi.squad and xi.squad.onRaised then
        xi.squad.onRaised(caster, target, 1) -- (XI: Forever Offline) a fallen squad mate gets up (modules/custom/lua/squad.lua)
    end

    spell:setMsg(xi.msg.basic.MAGIC_CASTS_ON)
    return 1
end

return spellObject
