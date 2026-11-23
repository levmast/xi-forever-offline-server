-----------------------------------
-- Squad mate food choice (2026-11-22; Altair's suggestion, the user's rule). Used by squad.lua.
--
-- !squad food <slot> opens a menu for that mate: "As it comes" (the mate picks by job and level, as before) or a food
-- of your choosing. A food has to be unlocked first, once per character, for what one costs on the auction house on
-- average (squad_food.lua's price x the launcher's "Auction house prices" rule). Unlocked foods are free from then on,
-- for every mate, like the food they always ate.
--   !squad food <slot> auto   back to the mate's own pick, without the menu
-- Kept on your character: SQUAD_FOOD_<mate id> = the item id it was told to eat (0 = its own pick),
-- SQUAD_FOODU_<item id> = 1 once that food is unlocked.
-----------------------------------
local M = {}

local PER_PAGE = 2 -- the menu box shows a title and three lines: two foods and "More..." / "Back."

M.pickVar = function(mateId)
    return 'SQUAD_FOOD_' .. tostring(mateId)
end

M.unlockVar = function(itemId)
    return 'SQUAD_FOODU_' .. tostring(itemId)
end

M.byId = function(food, itemId)
    for key, meal in pairs(food.foods or {}) do
        if meal.id == itemId then
            return meal, key
        end
    end

    return nil
end

-- what unlocking a food costs: its average auction house price, moved by the launcher's price rule
M.price = function(meal)
    local rate = tonumber(xi and xi.settings and xi.settings.main and xi.settings.main.AH_PRICE_RATE) or 1
    if rate <= 0 then
        rate = 1
    end

    return math.max(1, math.floor((meal.price or 1000) * rate + 0.5))
end

M.unlocked = function(player, meal)
    return player:getCharVar(M.unlockVar(meal.id)) == 1
end

-- the foods of one kind, cheapest first
M.ofKind = function(food, kind)
    local list = {}
    for _, meal in pairs(food.foods or {}) do
        if meal.kind == kind then
            list[#list + 1] = meal
        end
    end

    table.sort(list, function(a, b)
        if (a.price or 0) ~= (b.price or 0) then
            return (a.price or 0) < (b.price or 0)
        end

        return a.name < b.name
    end)

    return list
end

-- the food a mate that is out was told to eat (nil = its own pick)
M.chosen = function(mob, food)
    local id = mob:getLocalVar('SQUAD_FOOD_PICK')
    if id == nil or id == 0 then
        return nil
    end

    return (M.byId(food, id))
end

M.onSpawn = function(player, trust, mate)
    trust:setLocalVar('SQUAD_FOOD_PICK', player:getCharVar(M.pickVar(mate.id)))
end

local function commas(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

M.commas = commas

-- Tells the mate (and the one out with you, if it is) what to eat. itemId 0 = its own pick.
M.set = function(player, mate, itemId, deps)
    player:setCharVar(M.pickVar(mate.id), itemId)
    for _, trust in ipairs(deps.trusts or {}) do
        if trust:getLocalVar('SQUAD_ID') == mate.id then
            trust:setLocalVar('SQUAD_FOOD_PICK', itemId)
            -- the meal it has now ends, so the new one is eaten when the next fight starts
            if trust:getLocalVar('SQUAD_FOOD_ID') ~= 0 and trust:getLocalVar('SQUAD_FOOD_ID') ~= itemId then
                pcall(function()
                    if trust:getLocalVar('SQUAD_FOOD_FX') == 1 then
                        trust:delStatusEffect(xi.effect.FOOD)
                    end
                end)
                trust:setLocalVar('SQUAD_FOOD_UNTIL', 0)
            end
        end
    end
end

local function later(player, func)
    player:timer(250, function(entity)
        func(entity)
    end)
end

local function menu(player, title, options, back)
    player:setFreezeFlag(true)
    player:customMenu({
        title = title,
        options = options,
        onCancelled = function(playerArg)
            if back then
                later(playerArg, back)
            else
                playerArg:setFreezeFlag(false)
            end
        end,
        onEnd = function(playerArg)
            playerArg:setFreezeFlag(false)
        end,
    })
end

local function paged(player, title, entries, page, back)
    local pages = math.max(1, math.ceil(#entries / PER_PAGE))
    page = math.max(1, math.min(page, pages))
    local options = {}
    for i = (page - 1) * PER_PAGE + 1, math.min(#entries, page * PER_PAGE) do
        options[#options + 1] = { entries[i].label, entries[i].run }
    end

    if page < pages then
        options[#options + 1] = { 'More...', function(playerArg)
            later(playerArg, function(entity)
                paged(entity, title, entries, page + 1, back)
            end)
        end }
    elseif back then
        options[#options + 1] = { 'Back.', function(playerArg)
            later(playerArg, back)
        end }
    end

    menu(player, pages > 1 and string.format('%s %d/%d', title, page, pages) or title, options, back)
end

local function choose(player, mate, meal, deps)
    M.set(player, mate, meal.id, deps)
    deps.say(player, string.format('%s eats %s from now on (when the next fight starts).', mate.name, meal.name))
end

local function askUnlock(player, mate, meal, deps, back)
    local cost = M.price(meal)
    menu(player, string.format('Unlock %s for %s gil?', meal.name, commas(cost)),
    {
        { 'Yes, unlock it.', function(playerArg)
            if M.unlocked(playerArg, meal) then
                choose(playerArg, mate, meal, deps)
            elseif playerArg:getGil() < cost then
                deps.say(playerArg, string.format('%s costs %s gil to unlock and you have %s.', meal.name, commas(cost), commas(playerArg:getGil())))
            else
                playerArg:delGil(cost)
                playerArg:setCharVar(M.unlockVar(meal.id), 1)
                deps.say(playerArg, string.format('%s is unlocked for your squad (%s gil). It is free from now on.', meal.name, commas(cost)))
                choose(playerArg, mate, meal, deps)
            end
        end },
        { 'No.', function(playerArg)
            if back then
                later(playerArg, back)
            end
        end },
    }, back)
end

local function kindMenu(player, mate, kind, deps, back)
    local entries = {}
    for _, meal in ipairs(M.ofKind(deps.food, kind)) do
        local mine = M.unlocked(player, meal)
        entries[#entries + 1] =
        {
            label = mine and (meal.name .. ' (unlocked)') or string.format('%s - %s gil', meal.name, commas(M.price(meal))),
            run = function(playerArg)
                if M.unlocked(playerArg, meal) then
                    choose(playerArg, mate, meal, deps)
                else
                    later(playerArg, function(entity)
                        askUnlock(entity, mate, meal, deps, function(e)
                            kindMenu(e, mate, kind, deps, back)
                        end)
                    end)
                end
            end,
        }
    end

    paged(player, (deps.food.kindNames and deps.food.kindNames[kind]) or kind, entries, 1, back)
end

-- The first menu: the mate's own pick, then the kinds of food (the kind its job usually eats first).
M.open = function(player, mate, deps)
    local food = deps.food
    local now = M.byId(food, player:getCharVar(M.pickVar(mate.id)))
    local own = food.roleByJob and food.roleByJob[mate.mjob]
    local kinds = {}
    if own then
        kinds[#kinds + 1] = own
    end

    for _, kind in ipairs(food.kinds or {}) do
        if kind ~= own then
            kinds[#kinds + 1] = kind
        end
    end

    local function top(entity)
        M.open(entity, mate, deps)
    end

    local entries =
    {
        {
            label = 'As it comes (by job and level)',
            run = function(playerArg)
                M.set(playerArg, mate, 0, deps)
                deps.say(playerArg, string.format('%s picks its own food again.', mate.name))
            end,
        },
    }
    for _, kind in ipairs(kinds) do
        entries[#entries + 1] =
        {
            label = (food.kindNames and food.kindNames[kind]) or kind,
            run = function(playerArg)
                later(playerArg, function(entity)
                    kindMenu(entity, mate, kind, deps, top)
                end)
            end,
        }
    end

    paged(player, string.format('%s eats: %s', mate.name, now and now.name or 'as it comes'), entries, 1, nil)
end

-- !squad food <slot> [auto]. Returns true when it handled the command.
M.command = function(player, squad, arg1, arg2, deps)
    local slot = tonumber(arg1)
    if slot == nil then
        return false
    end

    local mate
    for _, m in ipairs(squad or {}) do
        if m.slot == slot then
            mate = m
        end
    end

    if mate == nil then
        deps.say(player, string.format('You have no squad mate in slot %d.', slot))
        return true
    end

    local word = string.lower(tostring(arg2 or ''))
    if word == 'auto' or word == 'off' or word == 'none' then
        M.set(player, mate, 0, deps)
        deps.say(player, string.format('%s picks its own food again.', mate.name))
        return true
    end

    M.open(player, mate, deps)
    return true
end

return M
