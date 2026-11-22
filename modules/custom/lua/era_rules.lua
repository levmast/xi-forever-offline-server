-----------------------------------
-- Era rules: keep an expansion's era balance while its content is on
-----------------------------------
-- The era modules (modules/era/lua) revert an expansion's changes only while that expansion's content
-- is switched off: they ask xi.pre(expansion). With ERA_RULES_<TAG> = 1 in the settings, xi.pre also
-- answers true for that expansion when its content is on, so you get its zones, jobs, spells and
-- quests with the earlier era's balance (weapon skills, pdif caps, job and pet numbers, exp tables).
--
-- Era files that only hide the expansion's things (shop stock, gathering items, a quest's trade list,
-- an NM that only exists with the content) are left alone: those follow ENABLE_<TAG> as before.
--
-- Example: ENABLE_WOTG = 1 and ERA_RULES_WOTG = 1 = Wings of the Goddess content with the
-- Treasures of Aht Urhgan era rules.
--
-- Must load before modules/era/lua (init.txt lists it above that line; folder entries load last anyway).
-----------------------------------
local tagOf = {}
for name, value in pairs(xi.expansion) do
    tagOf[value] = name
end

-- era/lua files that gate content, not balance (matched against the calling file's path)
local contentFiles =
{
    '/era/lua/zones/',                    -- vendor stock
    'valeriano_shop_adjust',              -- vendor stock
    'helm_adjustments',                   -- gathering items
    'inside_the_belly',                   -- Zaldon's fish list
    'old_nm_respawn_timers',              -- Atkorkamuy exists only with WotG content
}

local function calledFromContentFile()
    for level = 3, 8 do
        local info = debug.getinfo(level, 'S')
        if info == nil then
            return false
        end

        local src = string.gsub(info.source or '', '\\', '/')
        if string.find(src, '/era/lua/', 1, true) then
            for _, pattern in ipairs(contentFiles) do
                if string.find(src, pattern, 1, true) then
                    return true
                end
            end

            return false
        end
    end

    return false
end

local basePre = xi.pre

xi.pre = function(expansion)
    if basePre(expansion) then
        return true
    end

    local main = xi.settings and xi.settings.main
    if main == nil then
        return false
    end

    local keep = main['ERA_RULES_' .. tostring(tagOf[expansion])]
    if not (keep == 1 or keep == true) then
        return false
    end

    return not calledFromContentFile()
end
