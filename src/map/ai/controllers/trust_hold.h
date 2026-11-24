/*
===========================================================================

  Copyright (c) 2026 LandSandBoat Dev Teams

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see http://www.gnu.org/licenses/

===========================================================================
*/

#pragma once

#include <cstdint>

// XI: Forever Offline: a script (Lua) can hold the stock trust AI's own decisions for one trust, one decision at a time.
//
// The stock AI acts before any gambit does: it engages as soon as the master engages, and it fires a weapon skill the moment TP
// reaches 1000. A script that owns a trust's behaviour (a Squads or other add-on) wants to say "not yet" to those, for example
// until its tank holds the monster, and to let go when its own test passes. The hook is two local vars on the trust:
//
//   TRUST_HOLD      bit mask: HoldEngage = hold the stock engage, HoldWeaponSkill = hold the stock weapon skills
//   TRUST_HOLD_SEQ  a counter the script raises each time it renews the hold (about once a second)
//
// A hold is honoured only while the counter keeps moving: three seconds after the last renewal (the script stopped, was
// reloaded or crashed) the trust is back on the stock AI by itself, so a hold can never leave a trust frozen. A trust whose
// script never writes TRUST_HOLD behaves exactly as before; the stock server never writes it.
// The state is free of engine types (milliseconds from any steady clock) so it can be unit tested on its own
// (src/test/tests/trust_hold_tests.cpp).
namespace trust_hold
{

constexpr uint32_t HoldEngage      = 1; // hold the stock engage (CTrustController::EngageDelayPassed)
constexpr uint32_t HoldWeaponSkill = 2; // hold the stock weapon skills, TP skills included (CGambitsContainer::Tick)
constexpr int64_t  TtlMs           = 3000;

class State
{
public:
    // mask / seq: the trust's TRUST_HOLD and TRUST_HOLD_SEQ; bit: the decision being asked about
    auto Active(const uint32_t mask, const uint32_t seq, const uint32_t bit, const int64_t nowMs) -> bool
    {
        if ((mask & bit) == 0 || seq == 0) // (a counter still at 0 has never been renewed: not a hold)
        {
            return false;
        }

        if (seq != m_seq)
        {
            m_seq   = seq;
            m_since = nowMs;
            return true;
        }

        return nowMs - m_since < TtlMs;
    }

private:
    uint32_t m_seq   = 0;
    int64_t  m_since = 0;
};

} // namespace trust_hold
