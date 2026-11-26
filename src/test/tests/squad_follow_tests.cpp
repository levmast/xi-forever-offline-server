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

// XI: Forever Offline: how a squad mate catches up (map/ai/helpers/squad_follow.h, B5 "mates stuck at ledges")

#include "map/ai/helpers/squad_follow.h"

#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <cstddef>
#include <vector>

using squad::follow::KeepPath;
using squad::follow::LeadLost;
using squad::follow::MayRepath;
using squad::follow::Near;
using squad::follow::Progress;

TEST_CASE("follow: the near band is the old 3x rule", "[squad][follow]")
{
    CHECK(Near(4.4f, 1.5f));
    CHECK_FALSE(Near(4.5f, 1.5f));
    CHECK_FALSE(Near(20.0f, 1.5f));
}

TEST_CASE("follow: a path that still ends near the goal is kept", "[squad][follow]")
{
    CHECK(KeepPath(true, 1.0f, 1.5f));
    CHECK(KeepPath(true, 2.4f, 1.5f));        // (slack = want + 1 = 2.5)
    CHECK_FALSE(KeepPath(true, 2.6f, 1.5f));  // the target moved on: ask again
    CHECK_FALSE(KeepPath(false, 0.0f, 1.5f)); // no path being walked
    CHECK(KeepPath(true, 1.9f, 0.5f));        // (at least 2 yalms of slack)
}

TEST_CASE("follow: a far path is asked for at most once a second", "[squad][follow]")
{
    CHECK_FALSE(MayRepath(0));
    CHECK_FALSE(MayRepath(999));
    CHECK(MayRepath(1000));
    CHECK(MayRepath(5000));
}

TEST_CASE("follow: a leader further from the player than oneself, or stuck, is not followed", "[squad][follow]")
{
    CHECK_FALSE(LeadLost(3.0f, 6.0f, false));  // the usual line: the leader is closer to the player
    CHECK_FALSE(LeadLost(8.0f, 6.0f, false));  // a little further: within the margin (no swapping back and forth)
    CHECK(LeadLost(9.5f, 6.0f, false));        // clearly further away (stuck at the top of a ledge, the line went round)
    CHECK(LeadLost(3.0f, 6.0f, true));         // stuck
}

TEST_CASE("follow: no progress for 3 s while far is stuck; progress or arriving clears it", "[squad][follow]")
{
    Progress p;
    p.Update(0, 12.0f, 3.5f, false);
    CHECK_FALSE(p.Stuck());
    p.Update(1000, 12.0f, 3.5f, false);
    p.Update(2999, 11.8f, 3.5f, false); // (0.2 yalms is not progress)
    CHECK_FALSE(p.Stuck());
    p.Update(3000, 11.9f, 3.5f, false);
    CHECK(p.Stuck());

    p.Update(3500, 11.0f, 3.5f, false); // got 1 yalm closer: moving again
    CHECK_FALSE(p.Stuck());

    p.Update(7000, 11.0f, 3.5f, false);
    CHECK(p.Stuck());
    p.Update(7100, 3.0f, 3.5f, false); // in formation
    CHECK_FALSE(p.Stuck());
}

// ---------------------------------------------------------------- CatchUp on a stand-in world with a ledge
// The ground is a plateau (z < 0) above the player (z = 10). Its edge, z = 0, can only be crossed on a ramp at x 20-24. A straight
// step behaves as the engine's StepToOnMesh does at a wall: it slides along the edge and stops there. The navmesh's path, when the
// world has the ramp, goes down the ramp. One step = 1 yalm, one tick = 400 ms (the AI tick). This tests CatchUp's choices
// (squad_follow.h) with the path finder's documented behaviour; the real CPathFind on a real navmesh is checked in game.
namespace
{
struct Pos
{
    float x = 0.0f;
    float z = 0.0f;
};

auto dist2d(const Pos& a, const Pos& b) -> float
{
    return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z));
}

struct World
{
    bool ledge = true; // the plateau's edge blocks straight steps
    bool ramp  = true; // ... except on the ramp, and the navmesh knows the way down it

    auto blocked(const Pos& from, const Pos& to) const -> bool
    {
        return ledge && from.z <= 0.0f && to.z > 0.0f && !(ramp && to.x >= 20.0f && to.x <= 24.0f);
    }
};

struct StubPathFinder
{
    World&           world;
    Pos&             pos;
    std::vector<Pos> path;
    int              queries = 0;
    int              steps   = 0;

    auto PathAround(const Pos& goal, float, uint8_t) -> bool
    {
        ++queries;
        path.clear();
        if (world.ledge && !world.ramp && pos.z <= 0.0f && goal.z > 0.0f)
        {
            return false; // no way down
        }

        if (world.ledge && pos.z <= 0.0f && goal.z > 0.0f)
        {
            path = { Pos{ 22.0f, -1.0f }, Pos{ 22.0f, 1.0f }, goal };
        }
        else
        {
            path = { goal };
        }

        return true;
    }

    auto IsFollowingPath() const -> bool
    {
        return !path.empty();
    }

    auto GetDestination() const -> const Pos&
    {
        return path.back();
    }

    void move(const Pos& to)
    {
        const float d = dist2d(pos, to);
        Pos         next{ to.x, to.z };
        if (d > 1.0f)
        {
            next = Pos{ pos.x + (to.x - pos.x) / d, pos.z + (to.z - pos.z) / d };
        }

        if (world.blocked(pos, next))
        {
            next.z = -0.01f; // (slides along the edge and stops there, as moveAlongSurface)
        }

        pos = next;
    }

    void FollowPath(int)
    {
        if (path.empty())
        {
            return;
        }

        move(path.front());
        if (dist2d(pos, path.front()) < 0.1f)
        {
            path.erase(path.begin());
        }
    }

    void StepToOnMesh(const Pos& goal, bool)
    {
        ++steps;
        move(goal);
    }
};

struct Run
{
    Pos   end;
    int   queries;
    int   steps;
    float distance;
};

// a mate at (0, -5) follows a player standing at (0, 10) for `ticks` AI ticks
auto follow(World world, const bool squadMate, const int ticks) -> Run
{
    Pos            pos{ 0.0f, -5.0f };
    const Pos      goal{ 0.0f, 10.0f };
    StubPathFinder pf{ world, pos };
    int64_t        lastRepath = 0;
    int64_t        now        = 1'000'000;
    for (int i = 0; i < ticks && dist2d(pos, goal) > 3.5f; ++i)
    {
        squad::follow::CatchUp(pf, pos, goal, 3.0f, 4.5f, squadMate, true, true, 0, now, lastRepath, uint8_t{ 1 }, dist2d);
        now += 400;
    }

    return Run{ pos, pf.queries, pf.steps, dist2d(pos, goal) };
}
} // namespace

TEST_CASE("catch-up: a squad mate above a ledge takes the ramp down to you (B5)", "[squad][follow][ledge]")
{
    const auto run = follow(World{}, true, 120);
    CHECK(run.distance <= 3.5f);
    CHECK(run.queries <= 2); // the path that still ends at you is kept: one query, not one per tick
}

TEST_CASE("catch-up: an ordinary trust keeps the old behaviour and stays at the edge", "[squad][follow][ledge]")
{
    const auto run = follow(World{}, false, 120);
    CHECK(run.distance > 9.0f);
    CHECK(run.end.z < 0.0f); // (wall-safe: never off the edge)
    CHECK(run.queries == 0);
}

TEST_CASE("catch-up: flat ground, a squad mate walks straight to you", "[squad][follow][ledge]")
{
    World flat;
    flat.ledge = false;
    const auto run = follow(flat, true, 120);
    CHECK(run.distance <= 3.5f);
    CHECK(run.queries <= 2);
}

TEST_CASE("catch-up: no way down, the mate stays wall-safe at the edge and asks at most once a second", "[squad][follow][ledge]")
{
    World noRoute;
    noRoute.ramp   = false;
    const auto run = follow(noRoute, true, 50); // 50 ticks = 20 s
    CHECK(run.end.z < 0.0f);                   // never off the edge
    CHECK(run.queries <= 21);                  // at most one query a second (not 50, one per tick)
    CHECK(run.queries >= 15);                  // and it does keep trying (a way may open: the player moves)
    CHECK(run.steps > 0);                      // the wall-safe straight step in between, as before
}

TEST_CASE("follow: casting (paused) never counts as stuck", "[squad][follow]")
{
    Progress p;
    p.Update(0, 12.0f, 3.5f, false);
    p.Update(5000, 12.0f, 3.5f, true);
    CHECK_FALSE(p.Stuck());
    p.Update(6000, 12.0f, 3.5f, false); // a new count starts after the pause
    CHECK_FALSE(p.Stuck());
    p.Update(9000, 12.0f, 3.5f, false);
    CHECK(p.Stuck());
}
