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

// XI: Forever Offline: which monster a trust's "top enmity" question is asked about (map/ai/helpers/trust_enmity_target.h).
//
// TopEnmityTarget is the real function CTrustController::GetTopEnmity calls. The rest of this file is a small model of
// its callers, written out here because they need a running zone: the dead-target filter of GetTopEnmity, and the two
// gambit conditions as gambits_container.cpp CheckTrigger evaluates them (HAS_TOP_ENMITY / NOT_HAS_TOP_ENMITY: false
// when there is no top enmity at all).

#include "map/ai/helpers/trust_enmity_target.h"

#include <catch2/catch_test_macros.hpp>

#include <initializer_list>

namespace
{

using trustenmity::TopEnmityTarget;

struct Mob
{
    int  top;          // targid at the top of this monster's enmity list, 0 = empty list
    bool dead = false;
};

constexpr int Master = 1;
constexpr int Tank   = 2;
constexpr int Mage   = 3;

// CTrustController::GetTopEnmity: targid of the top enmity entity, 0 = none
auto topEnmity(const bool squadMate, const Mob* POwn, const Mob* PMasters) -> int
{
    if (!squadMate || (POwn != nullptr && POwn->dead))
    {
        POwn = nullptr;
    }

    const auto* PMob = TopEnmityTarget(squadMate, POwn, PMasters);
    return PMob != nullptr ? PMob->top : 0;
}

// gambits_container.cpp CheckTrigger
auto hasTopEnmity(const int top, const int self) -> bool
{
    return top != 0 ? top == self : false;
}

auto notHasTopEnmity(const int top, const int self) -> bool
{
    return top != 0 ? top != self : false;
}

} // namespace

TEST_CASE("trust enmity target: the selection itself", "[trust][enmity]")
{
    Mob a{ Tank };
    Mob b{ Mage };

    SECTION("a squad mate with its own target reads that one")
    {
        CHECK(TopEnmityTarget(true, &a, &b) == &a);
        CHECK(TopEnmityTarget(true, &a, static_cast<Mob*>(nullptr)) == &a);
        CHECK(TopEnmityTarget(true, &a, &a) == &a);
    }

    SECTION("a squad mate without one falls back to the master's")
    {
        CHECK(TopEnmityTarget(true, static_cast<Mob*>(nullptr), &b) == &b);
    }

    SECTION("no target anywhere: nothing to read")
    {
        CHECK(TopEnmityTarget(true, static_cast<Mob*>(nullptr), static_cast<Mob*>(nullptr)) == nullptr);
        CHECK(TopEnmityTarget(false, static_cast<Mob*>(nullptr), static_cast<Mob*>(nullptr)) == nullptr);
    }

    SECTION("every other trust keeps the master's target, whatever it is fighting itself")
    {
        CHECK(TopEnmityTarget(false, &a, &b) == &b);
        CHECK(TopEnmityTarget(false, &a, static_cast<Mob*>(nullptr)) == nullptr);
        CHECK(TopEnmityTarget(false, static_cast<Mob*>(nullptr), &b) == &b);
    }

    SECTION("usable in constant expressions")
    {
        static constexpr int x = 0;
        static constexpr int y = 0;
        static_assert(TopEnmityTarget(true, &x, &y) == &x);
        static_assert(TopEnmityTarget(false, &x, &y) == &y);
        SUCCEED();
    }
}

TEST_CASE("trust enmity target: master and squad mate on the same monster", "[trust][enmity]")
{
    SECTION("the tank holds it: the mage may nuke, the tank need not provoke")
    {
        Mob mob{ Tank };
        CHECK(notHasTopEnmity(topEnmity(true, &mob, &mob), Mage));
        CHECK_FALSE(hasTopEnmity(topEnmity(true, &mob, &mob), Mage));
        CHECK(hasTopEnmity(topEnmity(true, &mob, &mob), Tank));
        CHECK_FALSE(notHasTopEnmity(topEnmity(true, &mob, &mob), Tank));
    }

    SECTION("the mage pulled it: the nuke rule stops, the tank provokes")
    {
        Mob mob{ Mage };
        CHECK_FALSE(notHasTopEnmity(topEnmity(true, &mob, &mob), Mage));
        CHECK(hasTopEnmity(topEnmity(true, &mob, &mob), Mage));
        CHECK(notHasTopEnmity(topEnmity(true, &mob, &mob), Tank));
    }

    SECTION("same answers as before the change (the inherited rule read the master's target)")
    {
        for (const int top : { 0, Master, Tank, Mage })
        {
            Mob mob{ top };
            CHECK(topEnmity(true, &mob, &mob) == topEnmity(false, &mob, &mob));
        }
    }
}

TEST_CASE("trust enmity target: master and squad mate on different monsters", "[trust][enmity]")
{
    Mob mastersMob{ Master }; // the master has this one
    Mob matesMob{ Mage };     // the mage has pulled the other

    SECTION("the mage is asked about its own monster: it has it, so no nuke")
    {
        const int top = topEnmity(true, &matesMob, &mastersMob);
        CHECK(top == Mage);
        CHECK(hasTopEnmity(top, Mage));
        CHECK_FALSE(notHasTopEnmity(top, Mage));
    }

    SECTION("before the change the master's monster answered: 'not top', and the mage kept nuking")
    {
        const int inherited = topEnmity(false, &matesMob, &mastersMob);
        CHECK(inherited == Master);
        CHECK(notHasTopEnmity(inherited, Mage));
    }

    SECTION("a tank on the mage's monster provokes it; a tank that already holds its own does not")
    {
        CHECK(notHasTopEnmity(topEnmity(true, &matesMob, &mastersMob), Tank));

        Mob tanksMob{ Tank };
        CHECK_FALSE(notHasTopEnmity(topEnmity(true, &tanksMob, &mastersMob), Tank));
        CHECK(hasTopEnmity(topEnmity(true, &tanksMob, &mastersMob), Tank)); // (Third Eye, Yonin, Counterstance, Super Jump)
    }
}

TEST_CASE("trust enmity target: master not fighting, squad has a target", "[trust][enmity]")
{
    const Mob* none = nullptr;

    SECTION("the tank does not hold it: Provoke fires (before: no monster to ask, never)")
    {
        Mob mob{ Mage };
        CHECK(notHasTopEnmity(topEnmity(true, &mob, none), Tank));
        CHECK_FALSE(notHasTopEnmity(topEnmity(false, &mob, none), Tank));
    }

    SECTION("the tank holds it: its defensive abilities fire (before: never)")
    {
        Mob mob{ Tank };
        CHECK(hasTopEnmity(topEnmity(true, &mob, none), Tank));
        CHECK_FALSE(hasTopEnmity(topEnmity(false, &mob, none), Tank));
    }

    SECTION("the mage: nukes while the tank holds it, stops when it has it itself")
    {
        Mob held{ Tank };
        Mob pulled{ Mage };
        CHECK(notHasTopEnmity(topEnmity(true, &held, none), Mage));
        CHECK_FALSE(notHasTopEnmity(topEnmity(true, &pulled, none), Mage));
    }
}

TEST_CASE("trust enmity target: squad mate without a valid target", "[trust][enmity]")
{
    const Mob* none = nullptr;

    SECTION("no target and the master has none: both conditions are false")
    {
        const int top = topEnmity(true, none, none);
        CHECK(top == 0);
        CHECK_FALSE(hasTopEnmity(top, Tank));
        CHECK_FALSE(notHasTopEnmity(top, Tank));
    }

    SECTION("no target of its own: the master's monster is asked, as before")
    {
        Mob mastersMob{ Master };
        CHECK(topEnmity(true, none, &mastersMob) == Master);
        CHECK(topEnmity(true, none, &mastersMob) == topEnmity(false, none, &mastersMob));
    }

    SECTION("its target has died: not read; the master's monster, if any")
    {
        Mob dead{ Mage, true };
        Mob mastersMob{ Tank };
        CHECK(topEnmity(true, &dead, &mastersMob) == Tank);
        CHECK(topEnmity(true, &dead, none) == 0);
    }

    SECTION("an empty enmity list: both conditions are false")
    {
        Mob fresh{ 0 };
        CHECK_FALSE(hasTopEnmity(topEnmity(true, &fresh, none), Mage));
        CHECK_FALSE(notHasTopEnmity(topEnmity(true, &fresh, none), Mage));
    }
}

TEST_CASE("trust enmity target: ordinary trusts are unchanged", "[trust][enmity]")
{
    // every combination: a trust that is not a squad mate gets exactly the master's monster
    Mob        a{ Tank };
    Mob        b{ Mage };
    Mob        dead{ Master, true };
    const Mob* candidates[] = { nullptr, &a, &b, &dead };

    for (const Mob* own : candidates)
    {
        for (const Mob* masters : candidates)
        {
            CHECK(TopEnmityTarget(false, own, masters) == masters);
            CHECK(topEnmity(false, own, masters) == (masters != nullptr ? masters->top : 0));
        }
    }
}
