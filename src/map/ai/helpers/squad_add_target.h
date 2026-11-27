/*
===========================================================================

  XI: Forever Offline (F21, 2026-11-27): the Gambits target ENEMY_ADD, "the nearest awake add" (Sleep, Sleep II, Foe
  Lullaby, Foe Lullaby II on a monster that joined the fight). Pure rules, shared by gambits_container.cpp and the tests.

  - Candidates: the monsters fighting the party (CTrustController::PartyFoes, squad_threat.h), nearest to the caster first.
  - Never the party's combat target: the player's battle target while the player is engaged, else the monster most squad
    mates are fighting (a camp the player is not fighting at). The caster's own target is an add like any other when it
    is not that one.
  - Not asleep (Sleep, Sleep II, Lullaby: either family), within the rule's spell reach, not reserved by another mate.
  - One caster at a time: a cast on an add reserves it (local vars on the monster) for ReserveSeconds; a refused cast
    releases it at once, an expired reservation is free again.
  - Repeated resists: after MaxTries casts within TriesWindow seconds that did not leave it asleep, the add is skipped for
    BackoffSeconds (per caster). Asleep again = the count starts over.

===========================================================================
*/

#pragma once

#include <cstdint>

namespace squad::addtarget
{

inline constexpr const char* VarBy    = "SQUAD_ADD_BY";    // on the monster: the squad mate's entity id that reserved it
inline constexpr const char* VarUntil = "SQUAD_ADD_UNTIL"; // ...until this time (seconds, epoch)

inline constexpr int64_t ReserveSeconds = 8;
inline constexpr int     MaxTries       = 3;
inline constexpr int64_t TriesWindow    = 60;
inline constexpr int64_t BackoffSeconds = 30;

struct Candidate
{
    bool  asleep        = false;
    bool  isMainTarget  = false; // the party's combat target
    bool  inReach       = true;
    bool  reservedOther = false; // another mate holds it and the hold has not run out
    bool  backedOff     = false; // this caster's resist backoff
};

constexpr auto Eligible(const Candidate& c) -> bool
{
    return !c.asleep && !c.isMainTarget && c.inReach && !c.reservedOther && !c.backedOff;
}

// a reservation on a monster: by (0 = none) until (seconds)
constexpr auto ReservedByOther(uint32_t by, int64_t until, uint32_t me, int64_t now) -> bool
{
    return by != 0 && by != me && now < until;
}

// this caster's tries on one add
struct Tries
{
    int     count    = 0;
    int64_t firstAt  = 0;
    int64_t offUntil = 0;
};

constexpr auto BackedOff(const Tries& t, int64_t now) -> bool
{
    return now < t.offUntil;
}

// a cast went out on the add: counted; the MaxTries-th one within the window starts the backoff
constexpr auto RecordTry(Tries t, int64_t now) -> Tries
{
    if (t.count == 0 || now - t.firstAt > TriesWindow)
    {
        t.count   = 0;
        t.firstAt = now;
    }

    t.count += 1;
    if (t.count >= MaxTries)
    {
        t.offUntil = now + BackoffSeconds;
        t.count    = 0;
    }

    return t;
}

} // namespace squad::addtarget
