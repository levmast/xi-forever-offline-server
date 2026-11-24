-----------------------------------
-- Squad requests: the words (XI Forever v0.3.3). DATA ONLY, no behavior. Used by squad_requests.lua when the extras are on (on by default since v0.3.3a; !sqreq more off turns them off).
--
--   FILLER     words that carry no meaning ("please", "can you", "i need"); a line may hold them besides the request itself
--   ME, GROUP  who gets it: you, or everyone ("us", "party", "all")
--   TIER       a tier word after a family: "cure iv", "protect 3"
--   FAMILIES   what can be asked for. Per entry:
--                name    the name said back
--                words   the words that ask for it ("invis" is Invisible); phrases = words that only count as a request on their own
--                spells  the spell names in tier order (a name the server does not know is skipped)
--                kind    'target'  the spell goes ON a person
--                        'party'   the caster casts it on herself and it takes the party in reach (the Teleports)
--                        'caster'  it can only ever land on the caster: refused with a reason
--                scope   'pc' people only (Sneak is about being seen), 'all' people and squad mates
--                dead    the target must be down (Raise)
--                need    'hp' the target must be hurt (Cure), 'status' it must carry one of `cures`
--                effect  the effect that proves it landed (and that is "already on")
--                roles   job numbers in the order that fits best (WHM 3, RDM 5, SCH 20, PLD 7)
--   BUNDLES    one word for several families, cast by one mate one after the other ("stealth")
-----------------------------------
local D = { VERSION = 1 }

D.MAX_WORDS = 9 -- a line of more words than this is conversation

D.FILLER = {}
for _, w in ipairs({
    'please', 'pls', 'plz', 'plss', 'can', 'could', 'would', 'will', 'you', 'u', 'ya', 'your', 'someone', 'anyone', 'somebody', 'anybody',
    'cast', 'give', 'gimme', 'get', 'need', 'needs', 'needed', 'want', 'wanna', 'wants', 'i', 'im', 'ill', 'id', 'ive', 'my', 'the', 'a', 'an',
    'some', 'on', 'to', 'for', 'with', 'thanks', 'thx', 'ty', 'hey', 'ok', 'okay', 'just', 'now', 'and', 'then', 'also', 'plus', 'real', 'quick',
    'asap', 'again', 'more', 'up', 'us', 'guys', 'hi', 'yo',
}) do
    D.FILLER[w] = true
end

D.ME = { me = true, myself = true, mine = true }
D.GROUP = { all = true, everyone = true, everybody = true, us = true, party = true, team = true, squad = true, guys = true, group = true, both = true }
D.TIER = { i = 1, ['1'] = 1, ii = 2, ['2'] = 2, iii = 3, ['3'] = 3, iv = 4, ['4'] = 4, v = 5, ['5'] = 5, vi = 6, ['6'] = 6 }

D.NEED_HP = 90 -- Cure is only cast on someone below this many percent
-- the hit points a tier of Cure gives back, about (the smallest tier that covers what is missing is the one cast)
D.CURE_HEAL = { 30, 90, 190, 380, 700 }

local function tiers(base, n)
    local out = { base }
    local roman = { 'II', 'III', 'IV', 'V', 'VI' }
    for i = 2, n do
        out[#out + 1] = base .. '_' .. roman[i - 1]
    end

    return out
end

local STEALTH_ROLES = { 5, 3, 20 } -- RDM, WHM, SCH
local HEAL_ROLES = { 3, 20, 5, 7 } -- WHM, SCH, RDM, PLD
local BUFF_ROLES = { 5, 3 } -- RDM, WHM

D.ORDER = {
    'sneak', 'invisible', 'deodorize', 'raise', 'haste', 'refresh', 'protect', 'shell', 'blink', 'stoneskin', 'phalanx', 'regen', 'aquaveil', 'cure',
    'poisona', 'paralyna', 'blindna', 'silena', 'stona', 'viruna', 'cursna', 'erase', 'teleport_holla', 'teleport_dem', 'teleport_mea',
    'teleport_yhoat', 'teleport_altep', 'teleport_vahzl', 'warp', 'escape', 'reraise', 'food',
}

D.FAMILIES = {
    sneak = { name = 'Sneak', spells = { 'SNEAK' }, effect = 'SNEAK', kind = 'target', scope = 'pc', roles = STEALTH_ROLES, words = { 'sneak', 'sneaky', 'snk' } },
    invisible = {
        name = 'Invisible', spells = { 'INVISIBLE' }, effect = 'INVISIBLE', kind = 'target', scope = 'pc', roles = STEALTH_ROLES,
        words = { 'invisible', 'invis', 'invisi', 'invisable', 'inv', 'invisibility' },
    },
    deodorize = {
        name = 'Deodorize', spells = { 'DEODORIZE' }, effect = 'DEODORIZE', kind = 'target', scope = 'pc', roles = STEALTH_ROLES,
        words = { 'deodorize', 'deodorise', 'deodo', 'deod', 'deo' },
    },
    raise = {
        name = 'Raise', spells = tiers('RAISE', 3), kind = 'target', scope = 'pc', dead = true, roles = { 3, 20, 5 },
        words = { 'raise', 'rez', 'res', 'revive', 'ress', 'resurrect' }, phrases = { 'i died', 'im dead', 'i am dead', 'i got killed' },
    },
    haste = { name = 'Haste', spells = { 'HASTE' }, effect = 'HASTE', kind = 'target', scope = 'all', roles = BUFF_ROLES, words = { 'haste' } },
    refresh = { name = 'Refresh', spells = tiers('REFRESH', 2), effect = 'REFRESH', kind = 'target', scope = 'all', roles = { 5, 20 }, words = { 'refresh' } },
    protect = { name = 'Protect', spells = tiers('PROTECT', 5), effect = 'PROTECT', kind = 'target', scope = 'all', roles = BUFF_ROLES, words = { 'protect', 'prot' } },
    shell = { name = 'Shell', spells = tiers('SHELL', 5), effect = 'SHELL', kind = 'target', scope = 'all', roles = BUFF_ROLES, words = { 'shell' } },
    blink = { name = 'Blink', spells = { 'BLINK' }, effect = 'BLINK', kind = 'target', scope = 'all', roles = { 5, 3, 20 }, words = { 'blink' } },
    stoneskin = {
        name = 'Stoneskin', spells = { 'STONESKIN' }, effect = 'STONESKIN', kind = 'target', scope = 'all', roles = { 5, 3, 20 }, words = { 'stoneskin', 'stone skin', 'ss' },
    },
    phalanx = { name = 'Phalanx', spells = { 'PHALANX' }, effect = 'PHALANX', kind = 'target', scope = 'all', roles = { 5 }, words = { 'phalanx' } },
    regen = { name = 'Regen', spells = tiers('REGEN', 3), effect = 'REGEN', kind = 'target', scope = 'all', roles = { 3, 20, 5 }, words = { 'regen' } },
    aquaveil = { name = 'Aquaveil', spells = { 'AQUAVEIL' }, effect = 'AQUAVEIL', kind = 'target', scope = 'all', roles = { 5, 3, 20 }, words = { 'aquaveil', 'aqua veil' } },
    cure = {
        name = 'Cure', spells = tiers('CURE', 5), kind = 'target', scope = 'all', need = 'hp', roles = HEAL_ROLES, words = { 'cure', 'heal' },
        phrases = { 'low hp', 'hurt', 'im hurt' },
    },
    poisona = {
        name = 'Poisona', spells = { 'POISONA' }, kind = 'target', scope = 'all', need = 'status', cures = { 'POISON' }, roles = HEAL_ROLES,
        words = { 'poisona' }, phrases = { 'poisoned', 'poison' },
    },
    paralyna = {
        name = 'Paralyna', spells = { 'PARALYNA' }, kind = 'target', scope = 'all', need = 'status', cures = { 'PARALYSIS' }, roles = HEAL_ROLES,
        words = { 'paralyna' }, phrases = { 'paralyzed', 'paralysed', 'paralysis', 'para' },
    },
    blindna = {
        name = 'Blindna', spells = { 'BLINDNA' }, kind = 'target', scope = 'all', need = 'status', cures = { 'BLINDNESS' }, roles = HEAL_ROLES,
        words = { 'blindna' }, phrases = { 'blind', 'blinded', 'cant see' },
    },
    silena = {
        name = 'Silena', spells = { 'SILENA' }, kind = 'target', scope = 'all', need = 'status', cures = { 'SILENCE' }, roles = HEAL_ROLES,
        words = { 'silena' }, phrases = { 'silenced', 'silence', 'cant cast' },
    },
    stona = {
        name = 'Stona', spells = { 'STONA' }, kind = 'target', scope = 'all', need = 'status', cures = { 'PETRIFICATION' }, roles = HEAL_ROLES,
        words = { 'stona' }, phrases = { 'petrified', 'stoned' },
    },
    viruna = {
        name = 'Viruna', spells = { 'VIRUNA' }, kind = 'target', scope = 'all', need = 'status', cures = { 'DISEASE' }, roles = HEAL_ROLES,
        words = { 'viruna' }, phrases = { 'diseased', 'disease' },
    },
    cursna = {
        name = 'Cursna', spells = { 'CURSNA' }, kind = 'target', scope = 'all', need = 'status', cures = { 'CURSE_I', 'CURSE_II', 'DOOM', 'BANE' }, roles = HEAL_ROLES,
        words = { 'cursna' }, phrases = { 'cursed', 'curse', 'doomed' },
    },
    erase = {
        name = 'Erase', spells = { 'ERASE' }, kind = 'target', scope = 'all', need = 'status',
        cures = { 'POISON', 'PARALYSIS', 'BLINDNESS', 'SILENCE', 'SLOW', 'WEIGHT', 'BIND', 'ADDLE', 'BURN', 'FROST', 'CHOKE', 'RASP', 'SHOCK', 'DROWN', 'DIA', 'BIO' },
        roles = { 3, 20 }, words = { 'erase' },
    },
    teleport_holla = { name = 'Teleport-Holla', spells = { 'TELEPORT_HOLLA' }, kind = 'party', roles = { 3, 5, 20 }, words = { 'teleport holla', 'tele holla', 'teleport-holla', 'holla' } },
    teleport_dem = { name = 'Teleport-Dem', spells = { 'TELEPORT_DEM' }, kind = 'party', roles = { 3, 5, 20 }, words = { 'teleport dem', 'tele dem', 'teleport-dem', 'dem' } },
    teleport_mea = { name = 'Teleport-Mea', spells = { 'TELEPORT_MEA' }, kind = 'party', roles = { 3, 5, 20 }, words = { 'teleport mea', 'tele mea', 'teleport-mea', 'mea' } },
    teleport_yhoat = {
        name = 'Teleport-Yhoat', spells = { 'TELEPORT_YHOAT' }, kind = 'party', roles = { 3, 5, 20 }, words = { 'teleport yhoat', 'tele yhoat', 'teleport-yhoat', 'yhoat' },
    },
    teleport_altep = { name = 'Teleport-Altep', spells = { 'TELEPORT_ALTEP' }, kind = 'party', roles = { 3, 5, 20 }, words = { 'teleport altep', 'tele altep', 'teleport-altep', 'altep' } },
    teleport_vahzl = { name = 'Teleport-Vahzl', spells = { 'TELEPORT_VAHZL' }, kind = 'party', roles = { 3, 5, 20 }, words = { 'teleport vahzl', 'tele vahzl', 'teleport-vahzl', 'vahzl' } },
    -- Warp takes only the caster, so it is asked as Warp II (it takes the party member it is cast on)
    warp = { name = 'Warp', spells = { 'WARP_II' }, kind = 'target', scope = 'pc', roles = { 4, 5, 20 }, words = { 'warp', 'warp home', 'go home' } },
    escape = { name = 'Escape', kind = 'caster', spells = {}, roles = {}, words = { 'escape' }, refuse = 'Escape only takes the caster. Teleport or Warp II can move us.' },
    -- not a spell: the squad mates eat now (the food rules of squad.lua decide what and whether)
    food = { name = 'Food', kind = 'food', spells = {}, roles = {}, words = { 'food', 'eat', 'feed', 'snack', 'meal', 'lunch', 'dinner', 'chow' } },
    reraise = { name = 'Reraise', kind = 'caster', spells = {}, roles = {}, words = { 'reraise' }, refuse = 'Reraise only lands on the caster, I cannot put it on you.' },
}

-- one word, several requests, one caster, one after the other
D.BUNDLES = {
    stealth = { 'sneak', 'invisible' },
    ['sneak invis'] = { 'sneak', 'invisible' },
    ['sneak invisible'] = { 'sneak', 'invisible' },
    ['invis sneak'] = { 'sneak', 'invisible' },
    ['invisible sneak'] = { 'sneak', 'invisible' },
}

return D
