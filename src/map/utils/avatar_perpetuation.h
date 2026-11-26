/*
===========================================================================

  XI: Forever Offline (F13, 2026-11-25): the avatar perpetuation cost of one regen tick, as a pure function.

  Moved out of CStatusEffectContainer::TickRegen unchanged, so a player and a squad Summoner pay by exactly the same
  rule (status_effect_container.cpp fills the inputs from the summoner's own mods, day, weather and effects):

    Final perpetuation = (Base / Half_Factor +- Reductions Or Penalties) * Avatar_Favor_Factor
    -> minimum 1, except 0 under Astral Flow. Refresh is applied by the caller (net = refresh - cost).

===========================================================================
*/

#pragma once

#include <cstdint>

namespace avatarperp
{

struct Inputs
{
    int16_t base{};             // Mod::AVATAR_PERPETUATION (job_utils/summoner.lua applyPerpetuationCost)
    bool    hasPet{};           // an avatar is out (the reductions below need it)
    bool    halved{};           // HALF_PERPETUATION_CARBUNCLE / _DAY / _WEATHER applies (floored)
    int16_t reduction{};        // Mod::PERPETUATION_REDUCTION
    int16_t affinity{};         // the avatar element's *_AFFINITY_PERP mod (0 when the element is not valid)
    bool    dayMatch{};         // today's element is the avatar's
    int16_t dayReduction{};     // Mod::DAY_REDUCTION
    bool    weatherMatch{};     // the weather is the avatar's element
    int16_t weatherReduction{}; // Mod::WEATHER_REDUCTION
    bool    avatarsFavor{};     // Avatar's Favor is on and the pet is Carbuncle .. Cait Sith or Siren (x1.2, floored)
    bool    astralFlow{};       // Astral Flow: no perpetuation
};

inline auto Cost(const Inputs& in) -> int16_t
{
    int16_t cost = in.base;
    if (in.hasPet)
    {
        if (in.halved)
        {
            cost = static_cast<int16_t>(cost / 2); // Confirmed it's floored.
        }

        cost = static_cast<int16_t>(cost - in.reduction);
        cost = static_cast<int16_t>(cost - in.affinity);

        if (in.dayMatch)
        {
            cost = static_cast<int16_t>(cost - in.dayReduction);
        }

        if (in.weatherMatch)
        {
            cost = static_cast<int16_t>(cost - in.weatherReduction);
        }

        if (in.avatarsFavor)
        {
            cost = static_cast<int16_t>(cost * 1.2); // Confirmed it's floored.
        }
    }

    if (in.astralFlow)
    {
        return 0;
    }

    return cost < 1 ? static_cast<int16_t>(1) : cost;
}

} // namespace avatarperp
