-----------------------------------
-- Stock Squad outfit projection only. No persistence, trading, spawning, or combat behavior.
-----------------------------------
local Equipment = {}

-- Input tables are stock saved gear for the current main job and its separate lockstyle.
-- Return two new transient tables; don't mutate saved equip, unlocks, or lockstyle.
function Equipment.projectSpawnGear(worn, lockstyle, main, synced, itemLevel, visibleSlots, starterMark)
    local outfit, looks = {}, {}
    for slot, itemId in pairs(lockstyle) do
        looks[slot] = itemId
    end

    for slot, itemId in pairs(worn) do
        if slot ~= starterMark then
            if not synced or itemLevel(itemId) <= main or (type(slot) == 'number' and slot <= 3) then
                outfit[slot] = itemId
            elseif visibleSlots[slot] and looks[slot] == nil then
                looks[slot] = itemId
            end
        end
    end
    return outfit, looks
end

return Equipment
