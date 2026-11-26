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

// XI: Forever Offline: where a squad mate stands for the position the player chose (map/ai/helpers/squad_position.h).

#include "map/ai/helpers/squad_position.h"

#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <vector>

namespace sp = squad::position;

namespace
{
    auto approx(float a, float b, float eps = 0.01f) -> bool
    {
        return std::fabs(a - b) < eps;
    }

    // the engine's own "behind": the angle between the enemy's facing and the direction to the spot is more than 90
    // degrees (behind(…, 64) in 256ths of a circle), so each arc spot must be on the enemy's back half
    auto onBackHalf(sp::Point enemy, float facing, sp::Point spot) -> bool
    {
        const sp::Point ahead = sp::BehindSpot(enemy, facing + sp::Pi, 1.0f, 0.0f); // (behind turned by pi = in front)
        const float     fx    = ahead.x - enemy.x;
        const float     fz    = ahead.z - enemy.z;
        const float     sx    = spot.x - enemy.x;
        const float     sz    = spot.z - enemy.z;
        return fx * sx + fz * sz < 0.0f; // (negative dot product: more than 90 degrees from the facing)
    }

    auto peer(int mode, bool melee = true, bool usable = true, bool self = false) -> sp::Peer
    {
        return { .self = self, .mode = mode, .melee = melee, .usable = usable, .fighting = usable };
    }
} // namespace

TEST_CASE("ArcOffset: straight behind first, then alternating sides, never past 75 degrees")
{
    CHECK(approx(sp::ArcOffset(0), 0.0f));
    CHECK(approx(sp::ArcOffset(1), sp::ArcStep));
    CHECK(approx(sp::ArcOffset(2), -sp::ArcStep));
    CHECK(approx(sp::ArcOffset(3), 2.0f * sp::ArcStep));
    CHECK(approx(sp::ArcOffset(4), -2.0f * sp::ArcStep));
    CHECK(approx(sp::ArcOffset(5), sp::ArcMax));
    CHECK(approx(sp::ArcOffset(6), -sp::ArcMax));
    CHECK(approx(sp::ArcOffset(9), sp::ArcMax)); // (more mates than spots: they share the outermost)
    CHECK(approx(sp::ArcOffset(-1), 0.0f));
}

TEST_CASE("BehindSpot: at the radius, every arc spot on the enemy's back half; five melee mates over a yalm apart")
{
    const sp::Point enemy{ 100.0f, -50.0f };
    for (float facing : { 0.0f, 1.0f, 2.5f, 4.0f, 5.9f })
    {
        std::vector<sp::Point> spots;
        for (int i = 0; i < 7; ++i) // (more than a party's five mates: the outer spots are shared, still on the back half)
        {
            const auto s = sp::BehindSpot(enemy, facing, sp::MeleeArcRadius, sp::ArcOffset(i));
            CHECK(approx(sp::Distance(s, enemy), sp::MeleeArcRadius));
            CHECK(onBackHalf(enemy, facing, s));
            spots.push_back(s);
        }
        for (size_t a = 0; a < 5; ++a) // (a party holds at most five mates: spots 0, +-30, +-60 degrees)
        {
            for (size_t b = a + 1; b < 5; ++b)
            {
                CHECK(sp::Distance(spots[a], spots[b]) > 1.0f); // (mates do not stand in one another)
            }
        }
    }
}

TEST_CASE("MeleeRadius: two yalms, closer for a small enemy, never inside the thief's own spot")
{
    CHECK(approx(sp::MeleeRadius(4.0f), sp::MeleeArcRadius)); // (a big enemy: the arc radius)
    CHECK(approx(sp::MeleeRadius(2.3f), 1.7f));               // (reach 2.3: 0.6 inside it)
    CHECK(approx(sp::MeleeRadius(1.0f), sp::MeleeArcMin));    // (very small reach: the minimum)
}

TEST_CASE("BehindSpot: offset 0 is the engine's nearPosition(enemy, r, pi)")
{
    // nearPosition: total = facing + pi; x = A.x + cos(2pi - total) * r; z = A.z + sin(2pi - total) * r
    const float     facing = 1.3f;
    const sp::Point enemy{ 10.0f, 20.0f };
    const float     total  = facing + sp::Pi;
    const auto      s      = sp::BehindSpot(enemy, facing, 3.0f, 0.0f);
    CHECK(approx(s.x, 10.0f + std::cos(2.0f * sp::Pi - total) * 3.0f));
    CHECK(approx(s.z, 20.0f + std::sin(2.0f * sp::Pi - total) * 3.0f));
}

TEST_CASE("PartnerSpot (r3): always behind the enemy, turned towards the player within 60 degrees")
{
    const sp::Point enemy{ 5.0f, 5.0f };
    for (float facing : { 0.0f, 1.1f, 2.6f, 4.2f })
    {
        // the player somewhere behind the enemy (within 60 degrees): the partner on the player's line, nearer the enemy
        for (float playerOff : { 0.0f, 0.4f, -0.4f, 0.9f, -1.0f })
        {
            const sp::Point player = sp::BehindSpot(enemy, facing, 4.0f, playerOff);
            const sp::Point s      = sp::PartnerSpot(enemy, facing, player, sp::PartnerDistance);
            CHECK(approx(sp::Distance(s, enemy), sp::PartnerDistance));
            CHECK(approx(sp::OffsetOf(enemy, facing, s), playerOff, 0.001f)); // (in line with the player: the TA check)
            CHECK(sp::Distance(s, enemy) < sp::Distance(player, enemy));      // (and nearer the enemy than the player)
        }
        // the player at the side or in front: the partner stays on the back side, at the edge of the arc or behind
        for (float playerOff : { 1.5f, -1.6f, 2.5f, -2.9f, sp::Pi })
        {
            const sp::Point player = sp::BehindSpot(enemy, facing, 4.0f, playerOff);
            const sp::Point s      = sp::PartnerSpot(enemy, facing, player, sp::PartnerDistance);
            CHECK(std::fabs(sp::OffsetOf(enemy, facing, s)) <= sp::PartnerMaxAngle + 0.001f);
            CHECK(onBackHalf(enemy, facing, s));
        }
        // the player on the enemy, or far away: still behind (straight behind / towards the player within 60 degrees)
        CHECK(approx(sp::OffsetOf(enemy, facing, sp::PartnerSpot(enemy, facing, { 5.1f, 5.1f }, sp::PartnerDistance)), 0.0f, 0.001f));
        CHECK(onBackHalf(enemy, facing, sp::PartnerSpot(enemy, facing, sp::BehindSpot(enemy, facing, 40.0f, 0.3f), sp::PartnerDistance)));
    }
}

TEST_CASE("ShouldMove: only clearly away from the spot, and not again within 2 seconds")
{
    CHECK(sp::ShouldMove(1.5f, sp::MeleeSlack, 5.0f));
    CHECK_FALSE(sp::ShouldMove(0.8f, sp::MeleeSlack, 5.0f));   // (close enough: no shuffling)
    CHECK_FALSE(sp::ShouldMove(1.5f, sp::MeleeSlack, 1.0f));   // (moved a second ago)
    CHECK(sp::ShouldMove(1.5f, sp::MeleeSlack, sp::MoveEverySeconds));
    CHECK_FALSE(sp::ShouldMove(1.5f, sp::RangedSlack, 5.0f));  // (a caster at 15 yalms may be 2 off)
    CHECK(sp::ShouldMove(2.5f, sp::RangedSlack, 5.0f));
}

TEST_CASE("Place: Normal mates and unusable ones keep their usual place")
{
    std::vector<sp::Peer> peers = { peer(sp::Normal, true, true, true) };
    CHECK_FALSE(sp::Place(peers, true).positioned);
    peers = { peer(sp::Behind, true, false, true) }; // (the enemy is on it, or dead, or another enemy)
    CHECK_FALSE(sp::Place(peers, true).positioned);
    peers = { peer(7, true, true, true) }; // (an unknown value: as Normal)
    CHECK_FALSE(sp::Place(peers, true).positioned);
}

TEST_CASE("Place: each mate behind gets its own arc index, melee and casters counted apart")
{
    // order: melee Behind, caster Behind, melee Behind (self), Normal, caster Behind
    std::vector<sp::Peer> peers = { peer(sp::Behind), peer(sp::Behind, false), peer(sp::Behind, true, true, true), peer(sp::Normal),
                                    peer(sp::Behind, false) };
    auto p = sp::Place(peers, true);
    CHECK(p.positioned);
    CHECK_FALSE(p.partner);
    CHECK(p.arcIndex == 1); // (the second melee)

    peers = { peer(sp::Behind), peer(sp::Behind, false), peer(sp::Behind, true), peer(sp::Normal), peer(sp::Behind, false, true, true) };
    p = sp::Place(peers, true);
    CHECK(p.arcIndex == 1); // (the second caster)

    // a mate that cannot be placed does not take an arc spot from the others
    peers = { peer(sp::Behind, true, false), peer(sp::Behind, true, true, true) };
    CHECK(sp::Place(peers, true).arcIndex == 0);
}

TEST_CASE("Place: one TA partner; the others with TA stand in the arc")
{
    std::vector<sp::Peer> peers = { peer(sp::TaPartner, true, true, true), peer(sp::TaPartner) };
    auto p = sp::Place(peers, true);
    CHECK((p.positioned && p.partner));

    peers = { peer(sp::TaPartner), peer(sp::TaPartner, true, true, true) };
    p = sp::Place(peers, true);
    CHECK((p.positioned && !p.partner && p.arcIndex == 0)); // (the first took the partner spot: not an arc spot)

    peers = { peer(sp::Behind), peer(sp::TaPartner), peer(sp::Behind, true, true, true) };
    CHECK(sp::Place(peers, true).arcIndex == 1); // (the partner does not count in the arc)
}

TEST_CASE("Place: no partner spot (player not near the enemy) -> TA partners stand behind")
{
    std::vector<sp::Peer> peers = { peer(sp::TaPartner), peer(sp::TaPartner, true, true, true) };
    auto p = sp::Place(peers, false);
    CHECK((p.positioned && !p.partner && p.arcIndex == 1));
}

TEST_CASE("OffsetOf: the inverse of BehindSpot")
{
    const sp::Point enemy{ 30.0f, -12.0f };
    for (float facing : { 0.0f, 0.7f, 2.0f, 3.5f, 5.5f })
    {
        for (float o : { 0.0f, 0.5f, -0.5f, 1.2f, -1.3f, 3.0f, -3.0f })
        {
            CHECK(approx(sp::OffsetOf(enemy, facing, sp::BehindSpot(enemy, facing, 2.0f, o)), o, 0.001f));
        }
    }
}

TEST_CASE("ArcOffsetAvoiding: no Behind spot within 25 degrees of the TA line; without a line, the plain arc")
{
    for (int i = 0; i < 6; ++i)
    {
        CHECK(approx(sp::ArcOffsetAvoiding(i, std::nullopt), sp::ArcOffset(i)));
    }
    // the player straight behind the enemy: the TA line is offset 0, so the first Behind mate goes to +30, then -30, ...
    CHECK(approx(sp::ArcOffsetAvoiding(0, 0.0f), sp::ArcStep));
    CHECK(approx(sp::ArcOffsetAvoiding(1, 0.0f), -sp::ArcStep));
    CHECK(approx(sp::ArcOffsetAvoiding(2, 0.0f), 2.0f * sp::ArcStep));
    // the player a little to one side (+35 degrees): +30 is too near the line, 0 and -30 are fine
    const float line = sp::Pi * 35.0f / 180.0f;
    CHECK(approx(sp::ArcOffsetAvoiding(0, line), 0.0f));
    CHECK(approx(sp::ArcOffsetAvoiding(1, line), -sp::ArcStep));
    for (float l : { 0.0f, 0.3f, -0.6f, 1.0f, -1.2f })
    {
        for (int i = 0; i < 5; ++i)
        {
            CHECK(std::fabs(sp::ArcOffsetAvoiding(i, l) - l) >= sp::PartnerClear - 0.0001f);
        }
    }
}

TEST_CASE("The reported case: player behind the enemy, Behind mate first, TA partner second -> the Behind mate is not in line")
{
    // the engine's in-line test: the angle from the enemy to the player against the angle from the enemy to the mate,
    // within 8/256 of a circle (about 11 degrees), and the mate nearer the enemy than the player
    const float     facing = 0.4f;
    const sp::Point enemy{ 0.0f, 0.0f };
    std::vector<sp::Peer> peers = { { .self = true, .mode = sp::Behind, .melee = true, .usable = true, .fighting = true },
                                    { .self = false, .mode = sp::TaPartner, .melee = true, .usable = true, .fighting = true } };
    const auto mira = sp::Place(peers, true);
    REQUIRE((mira.positioned && !mira.partner && mira.lineReserved));
    const float inLine = sp::Pi * 2.0f * 8.0f / 256.0f;
    // the player straight behind, and anywhere else behind within the partner's 60 degrees
    for (float playerOff : { 0.05f, 0.5f, -0.7f, 1.0f })
    {
        const sp::Point player   = sp::BehindSpot(enemy, facing, 3.5f, playerOff); // (the THF player)
        const sp::Point spot     = sp::PartnerSpot(enemy, facing, player, sp::PartnerDistance);
        const auto      miraSpot = sp::BehindSpot(enemy, facing, sp::MeleeArcRadius, sp::ArcOffsetAvoiding(mira.arcIndex, sp::OffsetOf(enemy, facing, spot)));
        const float     dev      = std::fabs(sp::OffsetOf(enemy, facing, miraSpot) - sp::OffsetOf(enemy, facing, player));
        CHECK(dev > inLine); // (Mira is out of the line: the player's TA cannot land on her)
        const float devPartner = std::fabs(sp::OffsetOf(enemy, facing, spot) - sp::OffsetOf(enemy, facing, player));
        CHECK(devPartner < inLine); // (the partner is in it)
    }

    // the partner has the enemy's attention (it keeps its usual place): the line stays reserved, Mira stays off it
    peers[1].usable = false;
    const auto mira2 = sp::Place(peers, true);
    CHECK((mira2.positioned && mira2.lineReserved));
    // no TA partner fighting: the arc is the plain one again (Mira straight behind)
    peers[1].fighting = false;
    CHECK_FALSE(sp::Place(peers, true).lineReserved);
}

TEST_CASE("Place: a caster with TA partner never takes the partner spot (it stands at its distance)")
{
    std::vector<sp::Peer> peers = { peer(sp::TaPartner, false, true, true), peer(sp::TaPartner) };
    auto p = sp::Place(peers, true);
    CHECK((p.positioned && !p.partner && p.arcIndex == 0));
    peers = { peer(sp::TaPartner, false), peer(sp::TaPartner, true, true, true) };
    CHECK(sp::Place(peers, true).partner); // (the melee one is still the partner)
}
