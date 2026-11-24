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

// XI: Forever Offline (2026-11-23): a squad thief whose Rule Set uses Sneak Attack / Trick Attack before its weapon skill.
//
// Reported: Sneak Attack went up, but an ordinary swing often used it before the weapon skill did. Two causes:
//   1. The ability was used while the weapon skill could not go (a closer waiting for a skillchain window, Open waiting
//      for a partner, a TP threshold above the rule's own), so the next swing took it.
//   2. After the ability, the weapon skill waited for the rules' next 2-3 s evaluation instead of the first tick on which
//      the mate could act again.
// This file holds the decisions, free of engine types so they can be unit tested on their own
// (src/test/tests/gambits_sata_tests.cpp). gambits_container.cpp applies them only to squad mates whose Rule Set asks for
// it (SQUAD_SATA_MANAGED / SQUAD_SATA_WSHOLD, set by squad_jobs.lua J.analyse); every other trust and every player is
// unchanged.
namespace gambits::sata
{

// How long after a paired Sneak/Trick Attack the weapon skill is tried on every tick instead of on the rules' cadence.
// The ability itself keeps the mate busy for its animation (2 s for both, sql/abilities.sql animationTime); the rest is
// room for a tick or two. Afterwards everything is as before.
constexpr uint32_t FollowUpWindowMs = 4000;

// May a managed Sneak/Trick Attack rule prepare (ask for the position) or use its ability now?
//   paired       the Rule Set pairs it with the weapon skill (a TP condition on the rule: SQUAD_SATA_WSHOLD) and the mate
//                has weapon skill TP (1000+); below that no weapon skill is possible and the ability is used on its own
//   wsWouldFire  the weapon skill would go now if it were not held for the ability: the same triggers, choice and range
//                (gambits_container.cpp asks the real path, TryTrustSkill, in dry-run mode)
// A rule without a TP condition is a stand-alone Sneak/Trick Attack and is never held back.
inline auto MayPrepare(const bool paired, const bool wsWouldFire) -> bool
{
    return !paired || wsWouldFire;
}

// After a paired Sneak/Trick Attack was used: what the next tick does about the weapon skill.
enum class FollowUp
{
    None,           // nothing pending: the rules' usual cadence
    Wait,           // still in the ability (or another action): try again next tick
    TryWeaponSkill, // the effect is on and the mate is free: try the weapon skill now
    Expire,         // over (window passed, the effect is gone, TP gone): back to the usual cadence
};

// pending: a paired ability was used and its window has not been cleared; expired: the window has passed;
// busy: the mate is in an ability, spell, ranged, weapon skill or mob skill state, or cannot act (stun, sleep: the
// inactive state); hasEffect: Sneak or Trick Attack is on
// the mate; tp: its TP now.
inline auto NextFollowUp(const bool pending, const bool expired, const bool busy, const bool hasEffect, const uint16_t tp) -> FollowUp
{
    if (!pending)
    {
        return FollowUp::None;
    }

    if (expired)
    {
        return FollowUp::Expire;
    }

    if (busy)
    {
        return FollowUp::Wait; // (the effect is applied when the ability starts; the mate stays busy for its animation)
    }

    if (!hasEffect || tp < 1000)
    {
        return FollowUp::Expire; // a swing or the weapon skill used it, it was paralyzed, or TP was lost
    }

    return FollowUp::TryWeaponSkill;
}

// ---------------------------------------------------------------- (option B) Sneak/Trick Attack before a skillchain close
// A mate whose weapon skill settings close (Close, Open + Close, the engine's closer triggers) can only use its weapon skill
// once another member's opening has made a window. The window opens 3 s after the opening lands and ends with the opening's
// effect (10 s: battleutils GetSkillChainEffect); the close is judged when the weapon skill starts (its state's first
// update). The close always comes first: Sneak/Trick Attack is only fitted in when the close still lands with a safety
// margin, and never by waiting for the thief to get into position. All times in milliseconds since the opening landed.
constexpr int64_t CloseWindowDelayMs = 3000; // battleutils: a close counts once the opening is older than 3 s
constexpr int64_t CloseSafetyMarginMs = 2000; // the close must be due at least this long before the window ends (the user)
// From the ability's use to the weapon skill starting, beyond the animation: two map ticks of 400 ms. The ability state acts
// on its first update after it was entered and ends on the first update after its animation (ability_state.cpp: both
// "tick >"), and the controller runs before the state loop (ai_container.cpp), so the follow-up's weapon skill starts one
// to two ticks after the animation. Measured on DEV (2026-11-23, diagnostics): 2.40-2.80 s from the use to the weapon skill.
// (Was 500 = one tick: a use at the old latest point could start the close at ~8.3 s.) Timing is not guaranteed under
// heavy server load: these are map-tick bounds, not wall-clock guarantees.
constexpr int64_t WsLatencyMs         = 800;
constexpr int64_t EarlyAnimEndMs      = 0;    // the ability ends after the window opens: no swings between its end and the window
constexpr int64_t MaxPassGapMs        = 3600; // the rules' cadence: 2-3 s plus up to 600 ms party-position offset (Tick)

enum class CloseSa
{
    Prepare, // too early to use it (it would wear off on swings before the window): ask for the position only
    Use,     // use it now: it ends about when the window opens or later, and the close still lands with the margin
    TooLate, // the close would no longer land with the margin after the ability: close without it
};

// sinceOpening: now minus the moment the opening landed; effectMs: the opening's duration; animMs: the ability's animation
// (sql/abilities.sql animationTime, 2000 for Sneak Attack and Trick Attack)
inline auto CloserSaStep(const int64_t sinceOpening, const int64_t effectMs, const int64_t animMs) -> CloseSa
{
    const int64_t latestUse   = effectMs - CloseSafetyMarginMs - WsLatencyMs - animMs;
    const int64_t earliestUse = CloseWindowDelayMs - animMs - EarlyAnimEndMs;
    if (sinceOpening < 0 || sinceOpening >= effectMs || sinceOpening > latestUse)
    {
        return CloseSa::TooLate;
    }

    return sinceOpening < earliestUse ? CloseSa::Prepare : CloseSa::Use;
}

// The window is open, the thief is in position for its ability, and the close is due now: may the weapon skill wait this
// one rules pass so the ability goes first? Only if, even when the ability does not go in that pass (another rule acted,
// it failed), the close on the next pass still lands with the margin. Asked once per opening (gambits_container.cpp).
inline auto MayHoldOpenWindow(const int64_t sinceOpening, const int64_t effectMs, const int64_t animMs) -> bool
{
    if (sinceOpening < CloseWindowDelayMs || sinceOpening >= effectMs)
    {
        return false; // (no window yet: nothing is held for it; window over: nothing to hold)
    }

    const int64_t remaining = effectMs - sinceOpening;
    const int64_t needed    = (MaxPassGapMs > animMs + WsLatencyMs ? MaxPassGapMs : animMs + WsLatencyMs) + CloseSafetyMarginMs;
    return remaining >= needed;
}

// ---------------------------------------------------------------- (2026-11-23, final batch, from the DEV diagnostics)
// I-B. A request the rule's own gate made for THIS opening (rules pass, CloserSaStep not TooLate, no earlier rule acted on
// that pass) is completed on the tick the squad reports the thief in position, instead of waiting 2-3 s for the next rules
// pass (DEV log: READY at 3.2-3.6 s, next pass at 4.8-6.0 s, past the 4.4 s hold: the close went without it). It is the
// rule's action being finished, not a new rule: everything the use needs is checked again here.
//   authorized   the request is the one the rule made for the opening now on the target (same opening, same ability)
//   ready        the squad says the position is right for that ability (SQUAD_SATA_READY)
//   eligible     still paired (managed + TP condition), 1000+ TP, the target alive and still the one fought
//   effectOn     Sneak/Trick Attack already on (nothing to do); onRecast the ability is on recast
//   locked       busy with another action, or unable to act (stun, sleep ...)
//   followUp     a paired ability was already used (its weapon skill is pending): never a second activation
//   step         CloserSaStep now: only Use (the close still lands with the margin after it); otherwise the close goes alone
inline auto UseWhenReady(const bool authorized, const bool ready, const bool eligible, const bool effectOn, const bool onRecast, const bool locked,
                         const bool followUp, const CloseSa step) -> bool
{
    return authorized && ready && eligible && !effectOn && !onRecast && !locked && !followUp && step == CloseSa::Use;
}

// I-C. The weapon skill after a paired Sneak/Trick Attack may start on the tick the ability's animation is over, before the
// attack state resumes: the state loop resumes it and lets it swing in that same tick, which used the effect before the
// weapon skill on DEV. Only that last tick (not earlier: the animation is never cut short) and only when the ability has
// acted and its effect is on. msSinceUse counts from a moment at or after the state was entered, so this is never earlier
// than the engine's own end (ability_state.cpp: tick > entry + cast + animation).
inline auto AbilityEndsThisTick(const bool pairedAbilityState, const bool completed, const bool effectOn, const int64_t msSinceUse, const int64_t castMs,
                                const int64_t animMs) -> bool
{
    return pairedAbilityState && completed && effectOn && msSinceUse > castMs + animMs;
}

// I-C fallback. The follow-up ends because the effect is not there (the ability was paralyzed, or a hit used it): the weapon
// skill is tried at once instead of on the next 2-3 s rules pass. Needed with I-B: a use near the latest point (5.2 s) that
// fails would otherwise leave the close to a pass up to 3.6 s later, past the 2 s margin. Only inside the follow-up's own
// window, when the mate is free and has the TP; if the weapon skill cannot go, the rules pass closes as before.
inline auto CloseAfterLostEffect(const bool expired, const bool locked, const bool hasEffect, const uint16_t tp) -> bool
{
    return !expired && !locked && !hasEffect && tp >= 1000;
}

// R. The closing weapon skill went without the requested ability: the request is withdrawn (no backoff), so the squad does not
// keep the thief flanking and then time the request out into its 10 s backoff (DEV log: 4 times). Only the request the rule
// made for this same opening, only when the thief was in position (the position worked; only the time ran out) and the effect
// is not on. A request that never got its position is left to the squad's timeout and backoff, as before (a real failure).
inline auto WithdrawAfterWeaponSkill(const bool managed, const uint32_t pending, const uint32_t requestedFor, const bool sameOpening, const uint32_t ready,
                                     const bool effectOn) -> bool
{
    return managed && pending != 0 && pending == requestedFor && sameOpening && ready == pending && !effectOn;
}

} // namespace gambits::sata
