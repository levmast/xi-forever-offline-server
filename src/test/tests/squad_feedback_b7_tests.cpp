// XI: Forever Offline (2026-11-27, feedback batch B7-F24): the pure rules of B9 / B11 (squad_cast_approach.h), F22
// (squad_cond_subject.h) and F21 (squad_add_target.h). The engine code that uses them is checked in game.

#include "map/ai/helpers/squad_add_target.h"
#include "map/ai/helpers/squad_cast_approach.h"
#include "map/ai/helpers/squad_cond_subject.h"

#include <catch2/catch_test_macros.hpp>

namespace ca = squad::castapproach;
namespace cs = squad::condsubject;
namespace at = squad::addtarget;

TEST_CASE("B9 a chat spell on someone out of reach: cast, walk in, or far", "[squad][b9]")
{
    const float reach = ca::Reach(20.0f, 0.5f, 0.5f);
    CHECK(reach == 21.0f);
    CHECK(ca::Decide(15.0f, reach, false, false) == ca::Start::CastNow);
    CHECK(ca::Decide(21.0f, reach, false, false) == ca::Start::CastNow);               // (at the edge: in reach, as the cast check)
    CHECK(ca::Decide(25.0f, reach, false, false) == ca::Start::Approach);              // out of a fight, no camp: walk in
    CHECK(ca::Decide(25.0f, reach, true, false) == ca::Start::Far);                    // in a fight: the fight's movement stays as it is
    CHECK(ca::Decide(25.0f, reach, false, true) == ca::Start::Far);                    // holding a camp
    CHECK(ca::Decide(reach + ca::MaxApproach + 0.1f, reach, false, false) == ca::Start::Far); // too far to walk for it
}

TEST_CASE("B9 the walk in: every tick checked again before the cast", "[squad][b9]")
{
    ca::StepFacts f;
    f.reach = 21.0f;
    f.dist  = 30.0f;
    CHECK(ca::Next(f).step == ca::Step::Walk);

    f.dist = 20.0f; // inside reach - margin
    CHECK(ca::Next(f).step == ca::Step::Cast);

    f.dist = 20.8f; // in reach but not past the margin: keep walking while it can move
    CHECK(ca::Next(f).step == ca::Step::Walk);
    f.canMove = false;
    CHECK(ca::Next(f).step == ca::Step::Cast); // (cannot get closer, in reach: cast)
    f.canMove = true;

    f.dist     = 30.0f;
    f.targetOk = false;
    CHECK(ca::Next(f).step == ca::Step::Cancel);
    CHECK(ca::Next(f).why == ca::Why::Target);
    f.targetOk = true;

    f.fighting = true;
    CHECK(ca::Next(f).why == ca::Why::Combat);
    f.fighting = false;

    f.spellReady = false;
    CHECK(ca::Next(f).why == ca::Why::NotReady);
    f.spellReady = true;

    f.elapsedSec = ca::TimeoutSeconds;
    CHECK(ca::Next(f).why == ca::Why::Timeout);
    f.elapsedSec = 0;

    f.canMove = false;
    CHECK(ca::Next(f).why == ca::Why::Far);
    f.canMove = true;

    f.dist = f.reach + ca::MaxApproach + 6.0f; // the target moved far away
    CHECK(ca::Next(f).why == ca::Why::Far);
}

TEST_CASE("F22 a condition's subject rides in its id's high bits", "[squad][f22]")
{
    CHECK(cs::Encode(4, cs::Subject::Target) == 4); // (every condition written before F22: unchanged)
    CHECK(cs::Encode(4, cs::Subject::Self) == 4 + 0x1000);
    CHECK(cs::Encode(1, cs::Subject::Enemy) == 1 + 0x2000);
    CHECK(cs::BaseOf(cs::Encode(46, cs::Subject::Enemy)) == 46);
    CHECK(cs::SubjectOf(4) == cs::Subject::Target);
    CHECK(cs::SubjectOf(0x1004) == cs::Subject::Self);
    CHECK(cs::SubjectOf(0x2001) == cs::Subject::Enemy);
    CHECK_FALSE(cs::UnknownSubject(0x2001));
    CHECK(cs::UnknownSubject(0x3001)); // (a later subject this engine does not know: the condition is false)
    CHECK(cs::MaxConditions == 4);
}

TEST_CASE("F21 an add: eligible, reserved, backed off", "[squad][f21]")
{
    at::Candidate c;
    CHECK(at::Eligible(c));
    c.asleep = true;
    CHECK_FALSE(at::Eligible(c));
    c = {};
    c.isMainTarget = true;
    CHECK_FALSE(at::Eligible(c));
    c = {};
    c.inReach = false;
    CHECK_FALSE(at::Eligible(c));
    c = {};
    c.reservedOther = true;
    CHECK_FALSE(at::Eligible(c));
    c = {};
    c.backedOff = true;
    CHECK_FALSE(at::Eligible(c));

    // one caster at a time; a hold runs out; your own hold is not "another's"
    CHECK(at::ReservedByOther(7, 108, 9, 100));
    CHECK_FALSE(at::ReservedByOther(7, 108, 7, 100));
    CHECK_FALSE(at::ReservedByOther(7, 108, 9, 108));
    CHECK_FALSE(at::ReservedByOther(0, 108, 9, 100));

    // three tries within a minute: backed off for 30 s; a try after the window starts over
    at::Tries t{};
    t = at::RecordTry(t, 100);
    t = at::RecordTry(t, 110);
    CHECK_FALSE(at::BackedOff(t, 111));
    t = at::RecordTry(t, 120);
    CHECK(at::BackedOff(t, 121));
    CHECK(at::BackedOff(t, 149));
    CHECK_FALSE(at::BackedOff(t, 150));

    at::Tries slow{};
    slow = at::RecordTry(slow, 100);
    slow = at::RecordTry(slow, 150);
    slow = at::RecordTry(slow, 200); // (200 is more than a minute after the window's first try at 100: the count starts over)
    CHECK_FALSE(at::BackedOff(slow, 201));
    CHECK(slow.count == 1);
    CHECK(slow.firstAt == 200);
}
