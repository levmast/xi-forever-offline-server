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

// XI: Forever Offline (squad Sneak/Trick Attack before a weapon skill): the decisions in map/ai/helpers/gambits_sata.h.
// The engine side (who is paired, whether the weapon skill would go, the ticks) is in gambits_container.cpp; the
// sequences below model its ticks with these decisions only.

#include "map/ai/helpers/gambits_sata.h"

#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <vector>

namespace
{

using gambits::sata::FollowUp;
using gambits::sata::FollowUpWindowMs;
using gambits::sata::MayPrepare;
using gambits::sata::NextFollowUp;

constexpr uint32_t TickMs      = 400;  // a map server tick
constexpr uint32_t AnimationMs = 2000; // Sneak Attack / Trick Attack animationTime (sql/abilities.sql)

// One paired Sneak Attack used at t = 0. Each tick: busy during the animation; the effect is on until consumedAt; the
// weapon skill can go from wsReadyAt. Returns the tick the weapon skill went (-1: never) and the tick the follow-up ended.
struct Outcome
{
    int  wsAt;
    int  endedAt;
    int  tries;
    bool pendingAtEnd;
};

auto RunFollowUp(const uint32_t consumedAt, const uint32_t wsReadyAt, const uint16_t tp = 1200, const uint32_t lockedUntil = AnimationMs) -> Outcome
{
    Outcome out{ -1, -1, 0, true };
    for (uint32_t t = TickMs; t <= 8000 && out.pendingAtEnd; t += TickMs)
    {
        const bool busy      = t < lockedUntil;
        const bool hasEffect = t < consumedAt;
        switch (NextFollowUp(true, t > FollowUpWindowMs, busy, hasEffect, tp))
        {
            case FollowUp::TryWeaponSkill:
                ++out.tries;
                if (t >= wsReadyAt)
                {
                    out.wsAt         = static_cast<int>(t);
                    out.pendingAtEnd = false;
                }
                break;
            case FollowUp::Expire:
                out.endedAt      = static_cast<int>(t);
                out.pendingAtEnd = false;
                break;
            case FollowUp::None:
            case FollowUp::Wait:
                break;
        }
    }

    return out;
}

} // namespace

TEST_CASE("Stand-alone Sneak/Trick Attack is never held back", "[gambits][sata]")
{
    // no TP condition on the rule: not paired with a weapon skill, used as before whatever the weapon skill does
    CHECK(MayPrepare(false, false));
    CHECK(MayPrepare(false, true));
}

TEST_CASE("Paired Sneak/Trick Attack only when its weapon skill would go", "[gambits][sata]")
{
    CHECK(MayPrepare(true, true));
    CHECK_FALSE(MayPrepare(true, false)); // closer waiting for a window, opener for a partner, TP threshold, range
}

TEST_CASE("Follow-up: nothing pending changes nothing", "[gambits][sata]")
{
    CHECK(NextFollowUp(false, false, false, true, 1500) == FollowUp::None);
    CHECK(NextFollowUp(false, true, true, false, 0) == FollowUp::None);
}

TEST_CASE("Follow-up: waits through the ability, then tries the weapon skill", "[gambits][sata]")
{
    CHECK(NextFollowUp(true, false, true, true, 1500) == FollowUp::Wait);  // the ability's animation
    CHECK(NextFollowUp(true, false, true, false, 1500) == FollowUp::Wait); // still busy: not judged yet
    CHECK(NextFollowUp(true, false, false, true, 1500) == FollowUp::TryWeaponSkill);
}

TEST_CASE("Follow-up: ends when the effect is gone, TP is gone or the window passed", "[gambits][sata]")
{
    CHECK(NextFollowUp(true, false, false, false, 1500) == FollowUp::Expire); // a swing used it, or the ability was paralyzed
    CHECK(NextFollowUp(true, false, false, true, 999) == FollowUp::Expire);   // TP lost
    CHECK(NextFollowUp(true, true, false, true, 1500) == FollowUp::Expire);   // window passed
    CHECK(NextFollowUp(true, true, true, true, 1500) == FollowUp::Expire);    // window passed while still busy
}

TEST_CASE("Sequence: the weapon skill goes on the first free tick after the ability", "[gambits][sata]")
{
    const auto out = RunFollowUp(/* consumedAt */ 99999, /* wsReadyAt */ 0);
    CHECK(out.wsAt == static_cast<int>(AnimationMs)); // the first tick that is not busy
    CHECK(out.tries == 1);
}

TEST_CASE("Sequence: out of range - tried every tick, never past the window", "[gambits][sata]")
{
    const auto out = RunFollowUp(99999, /* never ready */ 99999);
    CHECK(out.wsAt == -1);
    CHECK_FALSE(out.pendingAtEnd);
    CHECK(out.endedAt > static_cast<int>(FollowUpWindowMs));
    CHECK(out.endedAt <= static_cast<int>(FollowUpWindowMs + TickMs));
    CHECK(out.tries == static_cast<int>((FollowUpWindowMs - AnimationMs) / TickMs) + 1);
}

TEST_CASE("Sequence: a swing that takes the effect ends the follow-up at once", "[gambits][sata]")
{
    // consumed right when the ability ends (the attack state resumes in the same tick), weapon skill not tried
    const auto out = RunFollowUp(/* consumedAt */ AnimationMs, /* wsReadyAt */ 0);
    CHECK(out.wsAt == -1);
    CHECK(out.endedAt == static_cast<int>(AnimationMs));
    CHECK(out.tries == 0);
}

TEST_CASE("Sequence: paralyzed ability (no effect) ends after the animation", "[gambits][sata]")
{
    const auto out = RunFollowUp(/* never on */ 0, 0);
    CHECK(out.wsAt == -1);
    CHECK(out.endedAt == static_cast<int>(AnimationMs));
}

TEST_CASE("Sequence: stunned after the ability - waits, then the weapon skill inside the window", "[gambits][sata]")
{
    // locked (ability, then a 1.2 s stun) until 3200 ms: no attempt while locked, the weapon skill on the first free tick
    const auto out = RunFollowUp(99999, 0, 1200, /* lockedUntil */ 3200);
    CHECK(out.tries == 1);
    CHECK(out.wsAt == 3200);
}

TEST_CASE("Sequence: locked past the window - ends without an attempt", "[gambits][sata]")
{
    const auto out = RunFollowUp(99999, 0, 1200, /* lockedUntil */ 6000);
    CHECK(out.tries == 0);
    CHECK(out.wsAt == -1);
    CHECK(out.endedAt > static_cast<int>(FollowUpWindowMs));
    CHECK(out.endedAt <= static_cast<int>(FollowUpWindowMs + TickMs));
}

// ---------------------------------------------------------------- (option B + final batch) Sneak Attack before a skillchain close
namespace
{

using gambits::sata::AbilityEndsThisTick;
using gambits::sata::CloserSaStep;
using gambits::sata::CloseSa;
using gambits::sata::MayHoldOpenWindow;
using gambits::sata::UseWhenReady;
using gambits::sata::WithdrawAfterWeaponSkill;

constexpr int64_t EffectMs = 10000; // battleutils GetSkillChainEffect: the opening lasts 10 s
constexpr int64_t WindowMs = 3000;  // a close counts once the opening is older than 3 s
constexpr int64_t AnimSa   = 2000;  // Sneak Attack / Trick Attack animationTime
constexpr int64_t Tick     = 400;   // a map server tick
constexpr int64_t Delay    = 3200;  // a dagger's swing delay (only for the swing timer after a resumed attack)

// MODEL OF THE ENGINE ORDER (not the engine): one opening landed at t = 0, ticks at tickPhase + k * 400. Every tick, in the
// order of CAIContainer::Tick:
//   1. the TICK listener (squad_jobs.lua J.thiefManaged): READY once the request is readyDelay old; the request is cleared
//      once the effect is on;
//   2. the controller (CGambitsContainer::Tick): the follow-up (NextFollowUp, with I-C's AbilityEndsThisTick), then I-B
//      (UseWhenReady), then - on a rules pass when not busy - the weapon skill first (MayHoldOpenWindow) and the rule
//      (CloserSaStep);
//   3. the state loop: the ability acts one tick after its use (ability_state.cpp "tick > entry") and ends on the first tick
//      after its animation; the attack state resumes in that same tick and swings if its frozen timer has run out.
// The decisions are the production functions of gambits_sata.h; the loop around them is this model.
struct Scenario
{
    std::vector<int64_t> passes;             // rules passes (ms since the opening); a pass that falls while busy waits
    int64_t              tickPhase  = 0;     // ticks at tickPhase + k * 400
    int64_t              readyDelay = 800;   // from the request's tick until the squad's READY (-1: never in position)
    int64_t              swingLeft  = 99999; // ms left on the attack timer when the ability is used (frozen during it)
    bool                 paralyzed  = false; // the ability acts without effect
    bool                 unclean    = false; // an earlier rule acted on the pass of the request (I-B must not complete it)
    bool                 ib = true, ic = true, r = true; // the final batch's parts (false, false, false = option B as logged)
};

struct Result
{
    int64_t closeAt    = -1;    // the closing weapon skill's tick (-1: no close)
    bool    withSa     = false; // the effect was on when it started
    int64_t saAt       = -1;    // when the ability was used (-1: never)
    bool    eaten      = false; // a swing used the effect before the weapon skill
    bool    reqPending = false; // the request was still pending after the close (the squad would time it out into its backoff)
    bool    withdrawn  = false; // R withdrew it
};

auto Simulate(const Scenario& s) -> Result
{
    Result  out;
    bool    req = false, ready = false, reqClean = false, held = false;
    int64_t reqTick = 0;
    bool    inAbility = false, effect = false, followUp = false, recast = false, attackRunning = true;
    int64_t useAt = 0, actsAt = 0, endsAt = 0, followUntil = 0, attackLeft = 0;
    size_t  nextPass    = 0;
    bool    passWaiting = false;

    auto use = [&](const int64_t t)
    {
        inAbility   = true;
        useAt       = t;
        actsAt      = t + Tick;          // the first update after the entry
        endsAt      = t + AnimSa + Tick; // the first tick strictly after entry + animation (entry is a little after t)
        followUp    = true;
        followUntil = t + gambits::sata::FollowUpWindowMs;
        attackLeft  = s.swingLeft;
        out.saAt    = t;
        recast      = true;
    };
    auto close = [&](const int64_t t, const bool fromPass)
    {
        out.closeAt = t;
        out.withSa  = effect;
        if (fromPass && s.r && WithdrawAfterWeaponSkill(true, req ? 44 : 0, req ? 44 : 0, true, ready ? 44 : 0, effect))
        {
            req           = false;
            out.withdrawn = true;
        }
        out.reqPending = req;
    };

    for (int64_t t = s.tickPhase; t <= EffectMs; t += Tick)
    {
        if (t <= 0)
        {
            continue; // (the opening is seen from the first tick after it landed)
        }

        // 1. the squad (TICK listener): the effect on, or the ability on recast, clears the request (no backoff)
        if (effect || recast)
        {
            req = false;
        }
        ready = req && s.readyDelay >= 0 && t >= reqTick + s.readyDelay;

        // 2. the controller
        bool acted = false;
        if (followUp)
        {
            const bool finishing = s.ic && inAbility && AbilityEndsThisTick(true, t >= actsAt, effect, t - useAt - 1, 0, AnimSa);
            const bool locked    = inAbility && !finishing;
            switch (gambits::sata::NextFollowUp(true, t > followUntil, locked, effect, 1100))
            {
                case gambits::sata::FollowUp::TryWeaponSkill:
                    if (t > WindowMs)
                    {
                        close(t, false);
                        return out;
                    }
                    break;
                case gambits::sata::FollowUp::Expire:
                    followUp = false;
                    // (I-C fallback: closer openings - every scenario here is one)
                    if (s.ic && gambits::sata::CloseAfterLostEffect(t > followUntil, locked, effect, 1100) && t > WindowMs)
                    {
                        close(t, false);
                        return out;
                    }
                    break;
                default:
                    break;
            }
        }
        if (s.ib && !acted && UseWhenReady(req && reqClean, ready, true, effect, recast, inAbility, followUp, CloserSaStep(t, EffectMs, AnimSa)))
        {
            use(t);
            acted = true;
        }
        if (!acted)
        {
            const bool due = passWaiting || (nextPass < s.passes.size() && t >= s.passes[nextPass]);
            if (due && nextPass < s.passes.size() && t >= s.passes[nextPass])
            {
                ++nextPass;
            }
            if (due && inAbility)
            {
                passWaiting = true; // (busy: the pass waits for the first free tick)
            }
            else if (due)
            {
                passWaiting = false;
                bool closedNow = false;
                if (t > WindowMs && !effect)
                {
                    if (ready && !held && MayHoldOpenWindow(t, EffectMs, AnimSa))
                    {
                        held = true;
                    }
                    else
                    {
                        close(t, true);
                        closedNow = true;
                    }
                }
                else if (t > WindowMs && effect)
                {
                    close(t, true); // (the effect is on: no hold, the weapon skill goes with it)
                    closedNow = true;
                }
                if (closedNow)
                {
                    return out;
                }
                // the rule: TP >= 1000 AND NOT_STATUS SNEAK_ATTACK -> Sneak Attack
                if (!effect && !recast)
                {
                    const auto step = CloserSaStep(t, EffectMs, AnimSa);
                    if (ready ? step != CloseSa::Use : step == CloseSa::TooLate)
                    {
                        req   = false; // (withdrawn, no backoff)
                        ready = false;
                    }
                    else if (!ready)
                    {
                        if (!req)
                        {
                            req     = true;
                            reqTick = t;
                        }
                        reqClean = !s.unclean;
                    }
                    else
                    {
                        use(t); // (the rule path)
                    }
                }
            }
        }

        // 3. the state loop
        if (inAbility && t == actsAt)
        {
            effect = !s.paralyzed;
        }
        if (inAbility && t >= endsAt)
        {
            inAbility = false; // (the attack state resumes and updates in this same tick)
        }
        if (!inAbility && attackRunning && out.saAt >= 0 && t >= endsAt)
        {
            attackLeft -= Tick;
            if (attackLeft <= 0)
            {
                if (effect)
                {
                    effect    = false;
                    out.eaten = true;
                }
                attackLeft += Delay;
            }
        }
    }

    return out;
}

// The eleven openings of the DEV diagnostics log (2026-11-23, sata-diag.log), on the tick grid: the rules passes, the
// squad's READY delay and, for #1, a swing due on the animation-end tick. #1-#10 = the user's ten attempts, #11 = 19:06.
struct Logged
{
    const char*          name;
    std::vector<int64_t> passes;
    int64_t              tickPhase;
    int64_t              readyDelay;
    int64_t              swingLeft;
    bool                 optionBWithSa; // what option B did (the log)
    bool                 optionBEaten;
    bool                 batchWithSa;   // what the batch is expected to do
};

auto LoggedAttempts() -> std::vector<Logged>
{
    return {
        { "#1 18:47 SA eaten", { 398, 3598, 6398 }, -2, 800, 200, false, true, true },
        { "#2 18:49 two-pass", { 2396, 4796 }, -4, 800, 99999, false, false, true },
        { "#3 18:51 first pass in window", { 3196 }, -4, 800, 99999, false, false, false },
        { "#4 18:53 SA+WS", { 797, 3597 }, -3, 800, 99999, true, false, true },
        { "#5 18:54 SA+WS", { 802, 4002 }, 2, 800, 99999, true, false, true },
        { "#6 18:56 SA+WS", { 398, 3198 }, -2, 400, 99999, true, false, true },
        { "#7 18:58 SA+WS", { 412, 3612 }, 12, 800, 99999, true, false, true },
        { "#8 19:00 two-pass", { 2809, 6009 }, 9, 800, 99999, false, false, true },
        { "#9 19:03 two-pass", { 2802, 5602 }, 2, 800, 99999, false, false, true },
        { "#10 19:05 two-pass", { 2799, 5599 }, -1, 800, 99999, false, false, true },
        { "#11 19:06 first pass in window (extra)", { 3206 }, 6, 800, 99999, false, false, false },
    };
}

} // namespace

TEST_CASE("M: the use window with the measured latency keeps the 2 s margin", "[gambits][sata]")
{
    // earliest use: the ability (2 s) ends after the window opens (3000 - 2000 - 0 = 1000)
    CHECK(CloserSaStep(0, EffectMs, AnimSa) == CloseSa::Prepare);
    CHECK(CloserSaStep(999, EffectMs, AnimSa) == CloseSa::Prepare);
    CHECK(CloserSaStep(1000, EffectMs, AnimSa) == CloseSa::Use);
    // latest use: 10000 - 2000 margin - 800 (two ticks) - 2000 animation = 5200: the close starts by 8000 = end - 2 s
    CHECK(gambits::sata::WsLatencyMs == 800);
    CHECK(CloserSaStep(5200, EffectMs, AnimSa) == CloseSa::Use);
    CHECK(CloserSaStep(5201, EffectMs, AnimSa) == CloseSa::TooLate);
    CHECK(5200 + AnimSa + gambits::sata::WsLatencyMs == EffectMs - gambits::sata::CloseSafetyMarginMs);
    CHECK(CloserSaStep(EffectMs, EffectMs, AnimSa) == CloseSa::TooLate);
    CHECK(CloserSaStep(-1, EffectMs, AnimSa) == CloseSa::TooLate);
    // a longer animation or a shorter opening shrinks the budget
    CHECK(CloserSaStep(5000, EffectMs, 3000) == CloseSa::TooLate);
    CHECK(CloserSaStep(4000, 8000, AnimSa) == CloseSa::TooLate);
}

TEST_CASE("Closer: an open window waits one pass only while a whole late pass still fits (unchanged)", "[gambits][sata]")
{
    CHECK_FALSE(MayHoldOpenWindow(2999, EffectMs, AnimSa)); // no window yet: nothing to hold
    CHECK(MayHoldOpenWindow(3000, EffectMs, AnimSa));
    CHECK(MayHoldOpenWindow(4400, EffectMs, AnimSa)); // 5600 left = 3600 (a late pass) + 2000 margin
    CHECK_FALSE(MayHoldOpenWindow(4401, EffectMs, AnimSa));
    CHECK_FALSE(MayHoldOpenWindow(EffectMs, EffectMs, AnimSa));
}

TEST_CASE("I-B: a request is completed only when everything still holds", "[gambits][sata]")
{
    CHECK(UseWhenReady(true, true, true, false, false, false, false, CloseSa::Use));
    CHECK_FALSE(UseWhenReady(false, true, true, false, false, false, false, CloseSa::Use)); // not the rule's request for this opening
    CHECK_FALSE(UseWhenReady(true, false, true, false, false, false, false, CloseSa::Use)); // not in position
    CHECK_FALSE(UseWhenReady(true, true, false, false, false, false, false, CloseSa::Use)); // not eligible (TP, target, not paired)
    CHECK_FALSE(UseWhenReady(true, true, true, true, false, false, false, CloseSa::Use));  // effect already on
    CHECK_FALSE(UseWhenReady(true, true, true, false, true, false, false, CloseSa::Use));  // on recast
    CHECK_FALSE(UseWhenReady(true, true, true, false, false, true, false, CloseSa::Use));  // busy / stunned
    CHECK_FALSE(UseWhenReady(true, true, true, false, false, false, true, CloseSa::Use));  // already used: no second activation
    CHECK_FALSE(UseWhenReady(true, true, true, false, false, false, false, CloseSa::Prepare)); // too early (ends before the window)
    CHECK_FALSE(UseWhenReady(true, true, true, false, false, false, false, CloseSa::TooLate)); // the close goes alone
}

TEST_CASE("I-C: the weapon skill may start on the ability's last tick only", "[gambits][sata]")
{
    CHECK(AbilityEndsThisTick(true, true, true, 2001, 0, AnimSa));
    CHECK(AbilityEndsThisTick(true, true, true, 2400, 0, AnimSa));
    CHECK_FALSE(AbilityEndsThisTick(true, true, true, 2000, 0, AnimSa)); // the animation is never cut short
    CHECK_FALSE(AbilityEndsThisTick(true, true, true, 400, 0, AnimSa));
    CHECK_FALSE(AbilityEndsThisTick(true, false, true, 2400, 0, AnimSa)); // not acted yet
    CHECK_FALSE(AbilityEndsThisTick(true, true, false, 2400, 0, AnimSa)); // paralyzed / effect gone: nothing to protect
    CHECK_FALSE(AbilityEndsThisTick(false, true, true, 2400, 0, AnimSa)); // another ability (or none)
    CHECK_FALSE(AbilityEndsThisTick(true, true, true, 2400, 500, AnimSa)); // a cast time counts too
}

TEST_CASE("I-C fallback: an ability without effect lets the close go at once", "[gambits][sata]")
{
    CHECK(gambits::sata::CloseAfterLostEffect(false, false, false, 1000));
    CHECK_FALSE(gambits::sata::CloseAfterLostEffect(true, false, false, 1000)); // the follow-up's window passed: rules pass
    CHECK_FALSE(gambits::sata::CloseAfterLostEffect(false, true, false, 1000)); // busy / stunned
    CHECK_FALSE(gambits::sata::CloseAfterLostEffect(false, false, true, 1000)); // the effect is there: the normal follow-up
    CHECK_FALSE(gambits::sata::CloseAfterLostEffect(false, false, false, 999)); // no weapon skill TP
}

TEST_CASE("R: only the obsolete request of this opening, only when the position worked", "[gambits][sata]")
{
    CHECK(WithdrawAfterWeaponSkill(true, 44, 44, true, 44, false));
    CHECK_FALSE(WithdrawAfterWeaponSkill(false, 44, 44, true, 44, false)); // not a managed thief
    CHECK_FALSE(WithdrawAfterWeaponSkill(true, 0, 44, true, 44, false));   // nothing pending
    CHECK_FALSE(WithdrawAfterWeaponSkill(true, 76, 44, true, 76, false));  // another (newer) request
    CHECK_FALSE(WithdrawAfterWeaponSkill(true, 44, 44, false, 44, false)); // another opening
    CHECK_FALSE(WithdrawAfterWeaponSkill(true, 44, 44, true, 0, false));   // never in position: the squad's backoff stays
    CHECK_FALSE(WithdrawAfterWeaponSkill(true, 44, 44, true, 44, true));   // the effect is on: the squad clears it itself
}

TEST_CASE("Model check: option B replays the logged outcomes", "[gambits][sata]")
{
    for (const auto& a : LoggedAttempts())
    {
        Scenario s{ a.passes, a.tickPhase, a.readyDelay, a.swingLeft };
        s.ib = s.ic = s.r = false;
        const auto res = Simulate(s);
        INFO(a.name);
        CHECK(res.closeAt > WindowMs);
        CHECK(res.withSa == a.optionBWithSa);
        CHECK(res.eaten == a.optionBEaten);
    }
    // the logged two-pass closes left the request pending (the squad then set its 10 s backoff, DEV log x4)
    Scenario two{ { 2396, 4796 }, -4, 800 };
    two.ib = two.ic = two.r = false;
    CHECK(Simulate(two).reqPending);
}

TEST_CASE("Final batch on the eleven logged openings", "[gambits][sata]")
{
    int withSa = 0;
    for (const auto& a : LoggedAttempts())
    {
        const auto res = Simulate({ a.passes, a.tickPhase, a.readyDelay, a.swingLeft });
        INFO(a.name);
        CHECK(res.closeAt > WindowMs);
        CHECK(res.closeAt <= EffectMs - gambits::sata::CloseSafetyMarginMs);
        CHECK(res.withSa == a.batchWithSa);
        CHECK_FALSE(res.eaten);
        withSa += res.withSa ? 1 : 0;
    }
    CHECK(withSa == 9); // the user's ten: 9; the extra 19:06 opening (first pass already in the window): no request, no SA

    // the late first pass is not "fixed" by holding the close: it still goes on that pass, at once
    const auto late = Simulate({ { 3196 }, -4, 800 });
    CHECK(late.closeAt == 3196);
    CHECK_FALSE(late.withSa);
}

TEST_CASE("Batch: early and late READY, too late, never, paralysis, unclean request", "[gambits][sata]")
{
    // READY early (before 1000 ms): waits for the earliest use, the ability then ends inside the window, the close follows
    const auto early = Simulate({ { 400, 3600 }, 0, 400 });
    CHECK(early.withSa);
    CHECK(early.saAt == 1200);
    CHECK(early.closeAt == 3600);

    // READY late but within the budget (4.8 s): the ability at once, the close on its last tick (4.8 + 2.4 = 7.2 s)
    const auto late = Simulate({ { 2800, 6000 }, 0, 2000 });
    CHECK(late.withSa);
    CHECK(late.saAt == 4800);
    CHECK(late.closeAt == 7200);

    // READY too late (after 5.2 s): no ability, the close on the next pass without it; R withdraws the request (no backoff)
    const auto tooLate = Simulate({ { 2800, 5600 }, 0, 2800 });
    CHECK_FALSE(tooLate.withSa);
    CHECK(tooLate.saAt == -1);
    CHECK(tooLate.closeAt == 5600);
    CHECK(tooLate.withdrawn);
    CHECK_FALSE(tooLate.reqPending);

    // never in position: the close on the first window pass; the request is left to the squad's timeout + backoff (real failure)
    const auto never = Simulate({ { 800, 3600 }, 0, -1 });
    CHECK_FALSE(never.withSa);
    CHECK(never.closeAt == 3600);
    CHECK_FALSE(never.withdrawn);
    CHECK(never.reqPending);

    // paralyzed: no effect, the follow-up ends, the next pass closes in time
    Scenario para{ { 400, 3600, 6400 }, 0, 400 };
    para.paralyzed = true;
    const auto p   = Simulate(para);
    CHECK_FALSE(p.withSa);
    CHECK(p.closeAt > WindowMs);
    CHECK(p.closeAt <= EffectMs - gambits::sata::CloseSafetyMarginMs);

    // an earlier rule acted on the request's pass: I-B does not complete it between passes (the rule pass still can)
    Scenario unclean{ { 400, 3600 }, 0, 400 };
    unclean.unclean = true;
    const auto u    = Simulate(unclean);
    CHECK(u.saAt == 3600); // the held window pass, as option B
}

TEST_CASE("I-C: the animation-end swing never takes the effect while the window is open", "[gambits][sata]")
{
    for (const int64_t swing : { 1, 200, 400, 401, 800, 3200 })
    {
        Scenario with{ { 400, 3600 }, 0, 400, swing };
        const auto a = Simulate(with);
        CHECK(a.withSa);
        CHECK_FALSE(a.eaten);

        Scenario without{ { 400, 3600 }, 0, 400, swing };
        without.ic   = false;
        const auto b = Simulate(without);
        CHECK(b.eaten == (swing <= Tick)); // the logged #1 failure mode, without I-C
    }
}

TEST_CASE("Batch sweep: every close inside the window and by 8.0 s; no effect lost while the window is open", "[gambits][sata]")
{
    int runs = 0, sa = 0;
    for (const int64_t gap : { 2000, 2400, 2800, 3200, 3600 })
    {
        for (int64_t first = 0; first < gap; first += 100)
        {
            for (const int64_t tickPhase : { 0, 200 })
            {
                std::vector<int64_t> passes;
                for (int64_t p = first; p <= EffectMs; p += gap)
                {
                    passes.push_back(p);
                }
                for (const int64_t ready : { 400, 800, 1600, 2400, 3200, 4800, -1 })
                {
                    for (const int64_t swing : { 100, 400, 1200, 3200 })
                    {
                        for (const bool para : { false, true })
                        {
                            for (const bool unclean : { false, true })
                            {
                                Scenario s{ passes, tickPhase, ready, swing };
                                s.paralyzed = para;
                                s.unclean   = unclean;
                                const auto r = Simulate(s);
                                ++runs;
                                sa += r.withSa ? 1 : 0;
                                REQUIRE(r.closeAt > WindowMs);
                                REQUIRE(r.closeAt <= EffectMs - gambits::sata::CloseSafetyMarginMs);
                                REQUIRE((r.saAt < 0 || r.saAt <= 5200));
                                REQUIRE_FALSE(r.eaten);
                                if (r.saAt >= 0 && !para)
                                {
                                    REQUIRE(r.withSa); // used and not paralyzed: the weapon skill takes it
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    CHECK(runs > 0);
    CHECK(sa > 0);
}

TEST_CASE("Sequence: TP lost meanwhile ends the follow-up", "[gambits][sata]")
{
    const auto out = RunFollowUp(99999, 0, /* tp */ 800);
    CHECK(out.wsAt == -1);
    CHECK(out.endedAt == static_cast<int>(AnimationMs));
}
