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

// XI: Forever Offline: how a squad mate catches up with the one it follows, or with the monster it chases (CTrustController::CatchUp).
//
// (B5, 2026-11-25: squad mates stood in a line at the top of a ledge) A trust used a navmesh path only while it was within three
// times its follow distance (4.5 yalms for most mates). Further away it took a straight step every tick, and since the Wall Safe
// Update (2026-11-20) that step slides along the navmesh and stops at the edge of a ledge: a mate whose target was below the ledge
// stayed at the top until it was 30 yalms away and warped. Each mate follows the mate in front, so the whole line stayed with it.
//
// For squad mates now:
//  - far away, the navmesh path is used too (a ramp, a winding way down), asked for at most once a second, and a path that still
//    ends close to where the target is now is kept instead of being asked for again;
//  - with no path at all, the wall-safe straight step is taken, as before;
//  - a mate whose leader is further from the player than the mate itself is, or cannot get any closer to the one it follows (no
//    progress for a few seconds), is no longer followed: the mate behind it follows the player.
// No warp is added: the 30 yalm warp is the one there was. Ordinary trusts move as before.
//
// Free of engine types so it can be unit tested on its own (src/test/tests/squad_follow_tests.cpp). Times are milliseconds.
namespace squad::follow
{

constexpr int64_t RepathEveryMs   = 1000; // a far path is asked for at most this often
constexpr int64_t StuckAfterMs    = 3000; // this long without getting ProgressYalms closer is "stuck"
constexpr float   ProgressYalms   = 0.5f;
constexpr float   NearFactor      = 3.0f; // within want * NearFactor: a path every tick, as before
constexpr float   LeadLostMarginY = 3.0f; // a leader this much further from the player than oneself is not followed

// within the old "near" band: the behaviour there is unchanged (a fresh path every tick)
constexpr auto Near(const float dist, const float want) -> bool
{
    return dist < want * NearFactor;
}

// the path being walked still ends close enough to where the goal is now
constexpr auto KeepPath(const bool following, const float destinationToGoal, const float want) -> bool
{
    const float slack = want + 1.0f > 2.0f ? want + 1.0f : 2.0f;
    return following && destinationToGoal < slack;
}

// a far path may be asked for now
constexpr auto MayRepath(const int64_t sinceLastMs) -> bool
{
    return sinceLastMs >= RepathEveryMs;
}

// follow the player instead of the mate in front
constexpr auto LeadLost(const float leadToMaster, const float selfToMaster, const bool leadStuck) -> bool
{
    return leadStuck || leadToMaster > selfToMaster + LeadLostMarginY;
}

// The catch-up step itself, for any path finder with the CPathFind calls used here (the engine's CPathFind in
// CTrustController::CatchUp; a stand-in in the tests): PathAround(goal, want, flags) -> bool, IsFollowingPath(), GetDestination(),
// FollowPath(tick), StepToOnMesh(goal, run). dist(a, b): the engine's distance. Closer than nearBand, or not a squad mate:
// exactly as before (a fresh path every tick, else the wall-safe straight step). Further: keep a path that still ends near the
// goal, ask for a new one at most every RepathEveryMs, and take the straight step only when no path exists. step = walk the path
// now (false when the caller's own FollowPath right after does it). lastRepathMs: the mate's own record of its last far query.
template <typename PathFinder, typename Position, typename Tick, typename Distance>
void CatchUp(PathFinder& pf, const Position& self, const Position& goal, const float want, const float nearBand, const bool squadMate,
             const bool step, const bool canMove, const Tick tick, const int64_t nowMs, int64_t& lastRepathMs, const uint8_t pathFlags,
             Distance dist)
{
    const float d = dist(self, goal);
    if (d < nearBand || !squadMate)
    {
        if (d < nearBand && pf.PathAround(goal, want, pathFlags))
        {
            pf.FollowPath(tick);
        }
        else if (canMove)
        {
            pf.StepToOnMesh(goal, true);
        }

        return;
    }

    const bool following = pf.IsFollowingPath();
    if (!KeepPath(following, following ? dist(pf.GetDestination(), goal) : 0.0f, want) && MayRepath(nowMs - lastRepathMs))
    {
        lastRepathMs = nowMs;
        pf.PathAround(goal, want, pathFlags); // (no path: the path finder clears it, and the step below is taken)
    }

    if (pf.IsFollowingPath())
    {
        if (step)
        {
            pf.FollowPath(tick);
        }
    }
    else if (canMove)
    {
        pf.StepToOnMesh(goal, true);
    }
}

// no progress toward the goal for StuckAfterMs while further than `closeEnough` (casting and standing still on purpose do not count)
class Progress
{
public:
    void Update(const int64_t nowMs, const float dist, const float closeEnough, const bool paused)
    {
        if (paused || dist <= closeEnough + ProgressYalms)
        {
            Reset();
            m_Best = dist;
            return;
        }

        if (!m_Running || dist < m_Best - ProgressYalms)
        {
            m_Running = true;
            m_Since   = nowMs;
            m_Best    = dist;
            m_Stuck   = false;
            return;
        }

        m_Stuck = nowMs - m_Since >= StuckAfterMs;
    }

    void Reset()
    {
        m_Running = false;
        m_Stuck   = false;
    }

    auto Stuck() const -> bool
    {
        return m_Stuck;
    }

private:
    bool    m_Running = false;
    bool    m_Stuck   = false;
    int64_t m_Since   = 0;
    float   m_Best    = 0.0f;
};

} // namespace squad::follow
