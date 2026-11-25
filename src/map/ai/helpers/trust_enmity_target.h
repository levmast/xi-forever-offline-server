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

// XI: Forever Offline (2026-11-23). Which monster's enmity list CTrustController::GetTopEnmity reads.
//
// Inherited rule: the master's battle target. A trust always fights what its master fights, so that was the trust's own
// target too. A squad mate can be on another monster (the master switched target, a camp, !squad attack) or fight while
// its master has no battle target at all (weapon sheathed). Then "do I have the enemy's attention" was answered for the
// wrong monster, or not at all: Provoke, Third Eye, Yonin, Counterstance and Super Jump never fired, and a Rule Set's
// "does not have the enemy's attention" let a mage keep nuking the monster that was on it.
//
// Squad mates: the monster the mate itself is fighting; without one, the master's, as before.
// Every other trust: the master's, unchanged.
// The function is free of engine types so it can be unit tested on its own (src/test/tests/trust_enmity_target_tests.cpp).
namespace trustenmity
{

// POwnTarget / PMasterTarget: the monster each is fighting, or nullptr when there is none that can be read
template <typename T>
constexpr auto TopEnmityTarget(const bool squadMate, T* POwnTarget, T* PMasterTarget) noexcept -> T*
{
    if (squadMate && POwnTarget != nullptr)
    {
        return POwnTarget;
    }

    return PMasterTarget;
}

} // namespace trustenmity
