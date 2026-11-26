/*
===========================================================================

  XI: Forever Offline (F12, 2026-11-25): a squad mate's temporary weapon skill gear set.

  One optional WS set per mate and main job (armor and accessories only: slots 4-15, head .. back). The set is put on
  right before the mate starts a weapon skill and taken off again as soon as the weapon skill is over, so the weapon
  skill's damage is calculated with the set, and melee, defence and everything else use the ordinary outfit.

  This header is pure: no entity, no item table. The caller hands it the outfit, the set and a few predicates, and the
  functions that add and remove an item's modifiers. CTrustEntity (trust_entity.cpp) owns one Ledger per mate.

  Rules (the same as the Lua side, squad_wsset.lua, checks when the set is saved and when the mate is called):
    * only armor slots 4-15; weapons, ammo and the look are never touched
    * a piece the mate cannot wear NOW (level after Level Sync, job) is skipped: that slot keeps the outfit piece
    * a Rare piece that the effective outfit already wears in another slot is skipped (a Rare item once)
    * a piece equal to the outfit piece in that slot is no swap at all
    * Apply is refused while a swap is active (never stacked); Restore is safe to call any number of times
===========================================================================
*/

#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace squad::wsset
{

constexpr int    SlotCount = 16;
constexpr int    FirstSlot = 4;  // head
constexpr int    LastSlot  = 15; // back
using Gear                 = std::array<uint16_t, SlotCount>;

inline auto IsSetSlot(const int slot) -> bool
{
    return slot >= FirstSlot && slot <= LastSlot;
}

struct Swap
{
    uint8_t  slot{};
    uint16_t from{}; // the outfit piece taken off (0 = nothing was there)
    uint16_t to{};   // the set piece put on
};

struct Plan
{
    std::vector<Swap> swaps;
    int               skipped{}; // set pieces left out (cannot be worn now, Rare clash)
};

// The swaps for this set over this outfit. wearable(itemId) -> bool: the mate may wear it now (level, job).
// isRare(itemId) -> bool: the item's Rare flag.
template <typename Wearable, typename IsRare>
auto MakePlan(const Gear& set, const Gear& outfit, Wearable&& wearable, IsRare&& isRare) -> Plan
{
    Plan plan{};
    Gear effective = outfit;
    for (int slot = FirstSlot; slot <= LastSlot; ++slot)
    {
        const uint16_t want = set[slot];
        if (want == 0 || want == outfit[slot])
        {
            continue;
        }

        if (!wearable(want))
        {
            ++plan.skipped;
            continue;
        }

        if (isRare(want))
        {
            bool clash = false;
            for (int other = 0; other < SlotCount; ++other)
            {
                if (other != slot && effective[other] == want)
                {
                    clash = true;
                    break;
                }
            }

            if (clash)
            {
                ++plan.skipped;
                continue;
            }
        }

        plan.swaps.push_back(Swap{ static_cast<uint8_t>(slot), outfit[slot], want });
        effective[slot] = want;
    }

    return plan;
}

// One mate's swap state. remove(itemId) / add(itemId) take an item's modifiers off / put them on.
class Ledger
{
public:
    auto active() const -> bool
    {
        return active_;
    }

    auto current() const -> const Plan&
    {
        return plan_;
    }

    // Puts the plan on. false (nothing done) when a swap is already active or the plan is empty.
    template <typename Remove, typename Add>
    auto Apply(const Plan& plan, Remove&& remove, Add&& add) -> bool
    {
        if (active_ || plan.swaps.empty())
        {
            return false;
        }

        for (const auto& s : plan.swaps)
        {
            if (s.from != 0)
            {
                remove(s.from);
            }

            add(s.to);
        }

        plan_   = plan;
        active_ = true;
        return true;
    }

    // Takes the active plan off again (in reverse order). false when nothing was active: calling it twice is harmless.
    template <typename Remove, typename Add>
    auto Restore(Remove&& remove, Add&& add) -> bool
    {
        if (!active_)
        {
            return false;
        }

        for (auto it = plan_.swaps.rbegin(); it != plan_.swaps.rend(); ++it)
        {
            remove(it->to);
            if (it->from != 0)
            {
                add(it->from);
            }
        }

        plan_   = Plan{};
        active_ = false;
        return true;
    }

private:
    bool active_{};
    Plan plan_{};
};

} // namespace squad::wsset
