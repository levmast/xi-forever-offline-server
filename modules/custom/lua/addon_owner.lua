-- REVAMPED_STUB v1 addon_owner: an empty placeholder (an add-on that runs squad mates replaces this file).
-- ADDON_OWNER is the answer to "does an add-on own this mate?" that the hooks in squad.lua ask. Here the answer is always no.
-- Nothing sets the ADDON_OWN_<slot> character variables, so every hook in squad.lua falls through to the dev team's code.
ADDON_OWNER = ADDON_OWNER or {}
ADDON_OWNER.stub = true
if ADDON_OWNER.owns == nil then
    ADDON_OWNER.owns = function(_player, _trust)
        return false
    end
end
return ADDON_OWNER
