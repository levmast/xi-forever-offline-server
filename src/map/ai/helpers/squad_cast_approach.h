/*
===========================================================================

  XI: Forever Offline (B9 / B11, 2026-11-27): a spell asked for in party chat that the mate cannot cast from where it
  stands. Pure rules (no game types), shared by trust_controller.cpp (the approach), squad.cpp (the answer) and the tests.

  - B9: a single-target spell on a party member (Raise on a body) out of the spell's range. Out of a fight, and when the
    mate is not holding a camp, the mate walks toward the target (at most MaxApproach yalms beyond the reach, at most
    TimeoutSeconds) and casts once it is in range. In a fight, at a camp, or farther than that, the answer is "far".
  - Both B9 and B11 (an area spell that waits for its caster to step in) end with a result the Lua side reads from the
    mate's local vars, so "on my way" (the request was received) is told apart from "cast" and "did not cast".

===========================================================================
*/

#pragma once

#include <cstdint>

namespace squad::castapproach
{

// the mate's local vars the result is written to (squad_requests.lua reads them)
inline constexpr const char* VarSpell = "SQUAD_DEFER_SPELL"; // the spell id the result is for
inline constexpr const char* VarState = "SQUAD_DEFER_STATE"; // State below
inline constexpr const char* VarWhy   = "SQUAD_DEFER_WHY";   // Why below (0 when cast)

enum class State : uint8_t
{
    None    = 0,
    Waiting = 1, // walking in (B9) or stepping in (B11)
    Cast    = 2, // the cast started
    Failed  = 3, // given up: see Why
};

enum class Why : uint8_t
{
    None     = 0,
    Far      = 1, // too far, or the way there did not get it in range
    Timeout  = 2, // not in range in time
    Combat   = 3, // a fight started (you or the mate engaged)
    Target   = 4, // the target is gone, in another zone, or no longer fits the spell (a Raise target got up)
    NotReady = 5, // MP or the spell's recast
    Busy     = 6, // the cast itself was refused (another action, silence, the cast gate)
};

inline constexpr float MaxApproach    = 20.0f; // yalms beyond the spell's reach the mate will walk
inline constexpr int   TimeoutSeconds = 10;
inline constexpr float InsideMargin   = 0.5f; // stop this far inside the reach

// the reach of a spell from one entity to another: the player rule (the spell's range plus both hitboxes)
constexpr auto Reach(float spellRange, float hitboxA, float hitboxB) -> float
{
    return spellRange + hitboxA + hitboxB;
}

enum class Start : uint8_t
{
    CastNow,  // in reach: cast as before
    Approach, // out of reach: walk in, then cast
    Far,      // out of reach and no walking now: answer "far"
};

// what to do with a party chat request for a single-target spell on someone else
constexpr auto Decide(float dist, float reach, bool fighting, bool holdsCamp) -> Start
{
    if (dist <= reach)
    {
        return Start::CastNow;
    }

    if (fighting || holdsCamp || dist > reach + MaxApproach)
    {
        return Start::Far;
    }

    return Start::Approach;
}

enum class Step : uint8_t
{
    Walk,   // keep walking toward it
    Cast,   // in reach: cast now
    Cancel, // give up: see the Why
};

struct StepFacts
{
    float dist        = 0.0f;
    float reach       = 0.0f;
    int   elapsedSec  = 0;
    bool  targetOk    = true;  // alive/dead as the spell needs, same zone
    bool  fighting    = false; // you or the mate engaged
    bool  spellReady  = true;  // MP and recast
    bool  canMove     = true;  // speed above 0 and not held in place
};

struct StepResult
{
    Step step;
    Why  why;
};

// one tick of the walk: checked again every tick before anything is cast
constexpr auto Next(const StepFacts& f) -> StepResult
{
    if (!f.targetOk)
    {
        return { Step::Cancel, Why::Target };
    }

    if (f.fighting)
    {
        return { Step::Cancel, Why::Combat };
    }

    if (!f.spellReady)
    {
        return { Step::Cancel, Why::NotReady };
    }

    if (f.dist <= f.reach - InsideMargin || (f.dist <= f.reach && !f.canMove))
    {
        return { Step::Cast, Why::None };
    }

    if (f.elapsedSec >= TimeoutSeconds)
    {
        return { Step::Cancel, Why::Timeout };
    }

    if (!f.canMove || f.dist > f.reach + MaxApproach + 5.0f)
    {
        return { Step::Cancel, Why::Far };
    }

    return { Step::Walk, Why::None };
}

} // namespace squad::castapproach
