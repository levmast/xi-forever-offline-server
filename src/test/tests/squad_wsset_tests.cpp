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

// XI: Forever Offline (F12): a squad mate's WS gear set (map/ai/helpers/squad_wsset.h). A fake modifier table stands in
// for the mate: every item adds its own "STR" points, so the stats during and after a swap can be checked exactly.

#include "map/ai/helpers/squad_wsset.h"

#include <catch2/catch_test_macros.hpp>

#include <map>

namespace
{

using squad::wsset::Gear;

struct FakeMate
{
    std::map<int, int> itemStr; // item id -> STR it gives
    int                     str{};   // the mate's STR from items
    int                     adds{};
    int                     removes{};

    void add(const uint16_t item)
    {
        str += itemStr[item];
        ++adds;
    }

    void remove(const uint16_t item)
    {
        str -= itemStr[item];
        ++removes;
    }
};

auto anyWearable = [](uint16_t)
{
    return true;
};

auto noRare = [](uint16_t)
{
    return false;
};

} // namespace

TEST_CASE("squad WS set: the plan only swaps armor slots that differ from the outfit", "[squad][wsset]")
{
    Gear outfit{};
    outfit[0]  = 100; // main (never touched)
    outfit[4]  = 200; // head
    outfit[13] = 300; // ring1

    Gear set{};
    set[0]  = 999; // a weapon in the set is ignored (slots 0-3 are never set slots)
    set[4]  = 201; // head swap
    set[13] = 300; // the same ring: no swap
    set[14] = 400; // ring2 into an empty slot

    const auto plan = squad::wsset::MakePlan(set, outfit, anyWearable, noRare);
    REQUIRE(plan.swaps.size() == 2);
    CHECK(plan.swaps[0].slot == 4);
    CHECK(plan.swaps[0].from == 200);
    CHECK(plan.swaps[0].to == 201);
    CHECK(plan.swaps[1].slot == 14);
    CHECK(plan.swaps[1].from == 0);
    CHECK(plan.swaps[1].to == 400);
    CHECK(plan.skipped == 0);
}

TEST_CASE("squad WS set: pieces the mate cannot wear now are skipped (Level Sync), the outfit piece stays", "[squad][wsset]")
{
    Gear outfit{};
    outfit[5] = 500;
    Gear set{};
    set[5] = 501; // a level 75 body
    set[6] = 601; // hands the mate can wear

    const auto plan = squad::wsset::MakePlan(
        set, outfit, [](const uint16_t id)
        { return id != 501; },
        noRare);
    REQUIRE(plan.swaps.size() == 1);
    CHECK(plan.swaps[0].slot == 6);
    CHECK(plan.skipped == 1);
}

TEST_CASE("squad WS set: a Rare piece the effective outfit already wears elsewhere is skipped", "[squad][wsset]")
{
    Gear outfit{};
    outfit[11] = 700; // a Rare earring in ear1
    Gear set{};
    set[12] = 700; // the same Rare earring into ear2
    set[13] = 701; // a Rare ring, worn nowhere else

    const auto plan = squad::wsset::MakePlan(set, outfit, anyWearable, [](const uint16_t id)
                                             { return id == 700 || id == 701; });
    REQUIRE(plan.swaps.size() == 1);
    CHECK(plan.swaps[0].slot == 13);
    CHECK(plan.skipped == 1);

    // two Rare pieces of the same item in the set itself: the second one is skipped
    Gear set2{};
    set2[13]    = 701;
    set2[14]    = 701;
    const auto p2 = squad::wsset::MakePlan(set2, Gear{}, anyWearable, [](const uint16_t id)
                                           { return id == 701; });
    REQUIRE(p2.swaps.size() == 1);
    CHECK(p2.skipped == 1);
}

TEST_CASE("squad WS set: the set's stats are on during the weapon skill and the outfit's after, exactly", "[squad][wsset]")
{
    FakeMate mate;
    mate.itemStr = { { 200, 5 }, { 201, 12 }, { 400, 8 } };

    Gear outfit{};
    outfit[4] = 200;
    mate.add(200); // the outfit as the call put it on: STR 5
    REQUIRE(mate.str == 5);

    Gear set{};
    set[4]  = 201;
    set[14] = 400;
    const auto plan = squad::wsset::MakePlan(set, outfit, anyWearable, noRare);

    squad::wsset::Ledger ledger;
    auto                 rm = [&](uint16_t id)
    { mate.remove(id); };
    auto ad = [&](uint16_t id)
    { mate.add(id); };

    REQUIRE(ledger.Apply(plan, rm, ad));
    CHECK(ledger.active());
    CHECK(mate.str == 12 + 8); // the head swapped, the ring added: what the WS damage reads

    CHECK_FALSE(ledger.Apply(plan, rm, ad)); // never stacked
    CHECK(mate.str == 20);

    REQUIRE(ledger.Restore(rm, ad));
    CHECK_FALSE(ledger.active());
    CHECK(mate.str == 5); // melee after the weapon skill: the outfit exactly

    // restore again (cleanup, death, despawn after the damage already restored it): nothing changes
    CHECK_FALSE(ledger.Restore(rm, ad));
    CHECK_FALSE(ledger.Restore(rm, ad));
    CHECK(mate.str == 5);
    CHECK(mate.adds == mate.removes + 1); // every add after the first was undone once
}

TEST_CASE("squad WS set: an empty plan does nothing and is not active", "[squad][wsset]")
{
    FakeMate             mate;
    squad::wsset::Ledger ledger;
    auto                 rm = [&](uint16_t id)
    { mate.remove(id); };
    auto ad = [&](uint16_t id)
    { mate.add(id); };

    CHECK_FALSE(ledger.Apply(squad::wsset::Plan{}, rm, ad));
    CHECK_FALSE(ledger.active());
    CHECK_FALSE(ledger.Restore(rm, ad));
    CHECK(mate.adds == 0);
    CHECK(mate.removes == 0);
}

TEST_CASE("squad WS set: a refused start (apply, then restore at once) leaves no trace", "[squad][wsset]")
{
    FakeMate mate;
    mate.itemStr = { { 10, 3 }, { 11, 9 } };
    Gear outfit{};
    outfit[9] = 10;
    mate.add(10);
    Gear set{};
    set[9] = 11;

    squad::wsset::Ledger ledger;
    auto                 rm = [&](uint16_t id)
    { mate.remove(id); };
    auto ad = [&](uint16_t id)
    { mate.add(id); };

    for (int i = 0; i < 5; ++i) // five refused starts in a row
    {
        REQUIRE(ledger.Apply(squad::wsset::MakePlan(set, outfit, anyWearable, noRare), rm, ad));
        REQUIRE(ledger.Restore(rm, ad));
    }

    CHECK(mate.str == 3);
    CHECK_FALSE(ledger.active());
}
