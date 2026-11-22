-----------------------------------
-- Seeing Blood-red (Scholar AF3)
-----------------------------------
-- !addquest 7 34
-- Erlene              : !pos 376.936 -39.999 17.914 175
-- Indescript Markings : !pos -457.366 24.532 -364.607 90 (Pashhow Marshlands [S], E-11 by the north wall)
-----------------------------------
-- XI: Forever Offline (2026-11-22, levi): this quest was missing. The retail steps up to the letter are kept: Erlene in
-- the Eldieme Necropolis [S] sends you back to where Schultz was found, the Indescript Markings at E-11 in Pashhow
-- Marshlands [S] hold the Unaddressed Sealed Letter, and Erlene reads it. Retail then sends you to Grauberg [S] to fight
-- Ulbrecht in Ruhotz Silvermines; that battle (an instance with its own cutscenes) is not on this server, so Erlene
-- gives the Scholar's Mortarboard when you bring the letter back (as CatsEyeXI did). Erlene speaks in plain text: the
-- retail cutscene numbers for this quest are not known here.
-----------------------------------
local eldiemeID = zones[xi.zone.THE_ELDIEME_NECROPOLIS_S]
local pashhowID = zones[xi.zone.PASHHOW_MARSHLANDS_S]
-----------------------------------

local quest = Quest:new(xi.questLog.CRYSTAL_WAR, xi.quest.id.crystalWar.SEEING_BLOOD_RED)

quest.reward =
{
    item  = xi.item.SCHOLARS_MORTARBOARD,
    title = xi.title.SUMMA_CUM_LAUDE,
}

local function say(player, text)
    local channel = xi.msg.channel.NS_SAY or xi.msg.channel.SAY or 0
    player:printToPlayer(text, channel, 'Erlene')
end

-- an action of the quest's own, ranked like a progress cutscene so a click always reaches it
local function act(fn)
    local action = LambdaAction:new(fn)
    action.priority = Action.Priority.Progress
    return action
end

quest.sections =
{
    {
        check = function(player, status, vars)
            return status == xi.questStatus.QUEST_AVAILABLE and
                player:hasCompletedQuest(xi.questLog.CRYSTAL_WAR, xi.quest.id.crystalWar.DOWNWARD_HELIX) and
                xi.quest.getVar(player, xi.questLog.CRYSTAL_WAR, xi.quest.id.crystalWar.DOWNWARD_HELIX, 'Timer') <= VanadielUniqueDay() and
                not xi.quest.getMustZone(player, xi.questLog.CRYSTAL_WAR, xi.quest.id.crystalWar.DOWNWARD_HELIX) and
                player:getMainJob() == xi.job.SCH and
                player:getMainLvl() >= xi.settings.main.AF3_QUEST_LEVEL
        end,

        [xi.zone.THE_ELDIEME_NECROPOLIS_S] =
        {
            ['Erlene'] =
            {
                onTrigger = function(player, npc)
                    return act(function(playerArg)
                        say(playerArg, 'Professor Schultz is still missing... and that mortarboard you brought back has me worried.')
                        say(playerArg, 'Would you go back to where he was last seen? Pashhow Marshlands, the southern reaches, by the wall. Look for markings.')
                        quest:begin(playerArg)
                        return 0
                    end)
                end,
            },
        },
    },

    {
        check = function(player, status, vars)
            return status == xi.questStatus.QUEST_ACCEPTED
        end,

        [xi.zone.PASHHOW_MARSHLANDS_S] =
        {
            ['Indescript_Markings'] =
            {
                onTrigger = function(player, npc)
                    if
                        npc:getID() == pashhowID.npc.INDESCRIPT_MARKINGS_OFFSET and
                        not player:hasKeyItem(xi.keyItem.UNADDRESSED_SEALED_LETTER)
                    then
                        return act(function(playerArg)
                            npcUtil.giveKeyItem(playerArg, xi.keyItem.UNADDRESSED_SEALED_LETTER)
                            quest:setVar(playerArg, 'Prog', 1)
                            return 0
                        end)
                    end
                end,
            },
        },

        [xi.zone.THE_ELDIEME_NECROPOLIS_S] =
        {
            ['Erlene'] =
            {
                onTrigger = function(player, npc)
                    if not player:hasKeyItem(xi.keyItem.UNADDRESSED_SEALED_LETTER) then
                        return act(function(playerArg)
                            say(playerArg, 'Pashhow Marshlands, the southern edge by the north wall of E-11. Please, look for anything he may have left.')
                            return 0
                        end)
                    end

                    return act(function(playerArg)
                        say(playerArg, 'A letter... in the professor\'s hand. "Ulbrecht" ...so it was him.')
                        say(playerArg, 'You have done more than any student could ask. The professor would want you to have this.')
                        if quest:complete(playerArg) then
                            playerArg:delKeyItem(xi.keyItem.UNADDRESSED_SEALED_LETTER)
                        end

                        return 0
                    end)
                end,
            },
        },
    },
}

return quest
