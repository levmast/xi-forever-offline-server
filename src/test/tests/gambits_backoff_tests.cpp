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

// XI: Forever Offline: the rest an area rule takes from a member it keeps acting on (map/ai/helpers/gambits_backoff.h)

#include "map/ai/helpers/gambits_backoff.h"

#include <catch2/catch_test_macros.hpp>

using gambits::backoff::Guard;

namespace
{
constexpr int64_t Second    = 1000;
const std::string Protectra = "kupipi:protectra";
} // namespace

TEST_CASE("gambits backoff: a rule is never blocked before it has acted", "[gambits][backoff]")
{
    Guard guard;
    CHECK_FALSE(guard.Blocked(Protectra, 7, 0));
    CHECK(guard.Size() == 0);
}

TEST_CASE("gambits backoff: two casts on the same member are still allowed", "[gambits][backoff]")
{
    Guard guard;
    guard.Record(Protectra, 7, 0);
    guard.Record(Protectra, 7, 15 * Second);
    CHECK_FALSE(guard.Blocked(Protectra, 7, 16 * Second));
}

TEST_CASE("gambits backoff: the third cast inside the window rests the rule for that member", "[gambits][backoff]")
{
    Guard guard;
    guard.Record(Protectra, 7, 0);
    guard.Record(Protectra, 7, 15 * Second);
    guard.Record(Protectra, 7, 30 * Second); // Protectra's own 15 s recast: three real casts in 30 s that did not take
    CHECK(guard.Blocked(Protectra, 7, 31 * Second));
    CHECK(guard.Blocked(Protectra, 7, 74 * Second));
    CHECK_FALSE(guard.Blocked(Protectra, 7, 75 * Second)); // 45 s of rest, then the rule may try again
}

TEST_CASE("gambits backoff: other members and other rules are not touched", "[gambits][backoff]")
{
    Guard guard;
    for (int i = 0; i < 3; ++i)
    {
        guard.Record(Protectra, 7, i * 10 * Second);
    }

    CHECK(guard.Blocked(Protectra, 7, 25 * Second));
    CHECK_FALSE(guard.Blocked(Protectra, 8, 25 * Second));        // another member the rule can help
    CHECK_FALSE(guard.Blocked("kupipi:shellra", 7, 25 * Second)); // another rule
}

TEST_CASE("gambits backoff: casts spread over more than the window do not add up", "[gambits][backoff]")
{
    Guard guard;
    guard.Record(Protectra, 7, 0);
    guard.Record(Protectra, 7, 40 * Second); // (the member lost Protect and got it again in between: a normal use)
    guard.Record(Protectra, 7, 80 * Second);
    guard.Record(Protectra, 7, 120 * Second);
    CHECK_FALSE(guard.Blocked(Protectra, 7, 121 * Second));
}

TEST_CASE("gambits backoff: a member that converged starts again from zero", "[gambits][backoff]")
{
    Guard guard;
    guard.Record(Protectra, 7, 0);
    guard.Record(Protectra, 7, 15 * Second);
    guard.Converged(Protectra, 7);
    guard.Record(Protectra, 7, 20 * Second);
    CHECK_FALSE(guard.Blocked(Protectra, 7, 21 * Second));
}

TEST_CASE("gambits backoff: after a rest the count starts over and Clear forgets everything", "[gambits][backoff]")
{
    Guard guard;
    for (int i = 0; i < 3; ++i)
    {
        guard.Record(Protectra, 7, i * 10 * Second);
    }

    CHECK(guard.Blocked(Protectra, 7, 21 * Second));
    guard.Record(Protectra, 7, 22 * Second); // (still resting: ignored)
    CHECK_FALSE(guard.Blocked(Protectra, 7, 200 * Second));
    guard.Record(Protectra, 7, 200 * Second);
    guard.Record(Protectra, 7, 210 * Second);
    CHECK_FALSE(guard.Blocked(Protectra, 7, 211 * Second)); // two casts after the rest: not blocked

    guard.Clear();
    CHECK(guard.Size() == 0);
}

TEST_CASE("gambits backoff: the table stays small", "[gambits][backoff]")
{
    Guard guard;
    for (uint32_t member = 0; member < 2000; ++member)
    {
        guard.Record(Protectra, member, static_cast<int64_t>(member) * 100 * Second);
    }

    CHECK(guard.Size() < 600);
}
