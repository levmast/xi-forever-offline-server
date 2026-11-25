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

// XI: Forever Offline: what a spell asked for in party chat can be cast on (map/ai/helpers/squad_spell_kind.h).
// The rows are the spells' own values in sql/spell_list.sql (validTargets, AOE, radius / 10); the group "song" is group 1.

#include "map/ai/helpers/squad_spell_kind.h"

#include <catch2/catch_test_macros.hpp>

#include <string>

using squad::spellkind::Classify;
using squad::spellkind::Facts;
using squad::spellkind::Kind;
using squad::spellkind::Name;
using squad::spellkind::ReachesPartyAroundCaster;

namespace
{

// validTargets, AOE, radius in yalms
constexpr auto spell(const uint16_t validTargets, const uint8_t aoe, const float radius) -> Facts
{
    return Facts{ .canTargetEnemy = false, .validTargets = validTargets, .aoe = aoe, .radius = radius, .song = false };
}

constexpr auto song(const uint16_t validTargets, const uint8_t aoe, const float radius) -> Facts
{
    return Facts{ .canTargetEnemy = false, .validTargets = validTargets, .aoe = aoe, .radius = radius, .song = true };
}

constexpr auto enemy(const uint16_t validTargets, const uint8_t aoe, const float radius, const bool isSong = false) -> Facts
{
    return Facts{ .canTargetEnemy = true, .validTargets = validTargets, .aoe = aoe, .radius = radius, .song = isSong };
}

// The classification before 2026-11-24 (squad.cpp at v0.3.5 / v0.3.6): the valid target alone.
constexpr auto before(const Facts& s) -> Kind
{
    if (s.canTargetEnemy)
    {
        return Kind::Enemy;
    }

    if ((s.validTargets & 0x0020) != 0)
    {
        return Kind::Dead;
    }

    if ((s.validTargets & (0x0002 | 0x0008)) != 0)
    {
        return Kind::Party;
    }

    return Kind::Self;
}

} // namespace

TEST_CASE("squad spell kind: an area spell cast on the caster is a party request", "[squad][spellkind]")
{
    // Protectra, Protectra II .. V, Shellra .. V: validTargets 1, AOE 1 (radial), radius 100
    const Facts ra = spell(1, 1, 10.0f);
    CHECK(Classify(ra) == Kind::Party);
    CHECK(ReachesPartyAroundCaster(ra));
    CHECK(before(ra) == Kind::Self); // (the defect: "it only takes the caster")

    // Barfira and the other Bar-ra spells, Esuna, Auspice, the Boost spells, Cura: the same shape
    CHECK(Classify(spell(1, 1, 10.0f)) == Kind::Party);

    // Teleport-Holla .. Vahzl, Recall, Escape: validTargets 1, AOE 1, radius 100
    CHECK(Classify(spell(1, 1, 10.0f)) == Kind::Party);

    // blue magic that heals or shields around the caster (Healing Breeze, Diamondhide)
    CHECK(Classify(spell(1, 1, 10.0f)) == Kind::Party);
}

TEST_CASE("squad spell kind: a song sung on the singer is a party request", "[squad][spellkind]")
{
    // Mage's Ballad, Valor Minuet: validTargets 129 (self + the Pianissimo flag), AOE 5, radius 100
    const Facts ballad = song(0x0081, 5, 10.0f);
    CHECK(Classify(ballad) == Kind::Party);
    CHECK(before(ballad) == Kind::Self);

    // the song shape without the group is not one (only CTrustController::Cast's song branch aims it at the caster)
    CHECK(Classify(spell(0x0081, 5, 10.0f)) == Kind::Self);

    // a song with no area, or one that cannot go on its singer, stays out
    CHECK(Classify(song(0x0081, 5, 0.0f)) == Kind::Self);
    CHECK(Classify(song(0x0080, 5, 10.0f)) == Kind::Self);
}

TEST_CASE("squad spell kind: a spell that only works on its caster stays self", "[squad][spellkind]")
{
    CHECK(Classify(spell(1, 0, 0.0f)) == Kind::Self); // Warp, Reraise, Utsusemi: Ichi, Tonko: Ichi
    CHECK(Classify(spell(1, 4, 0.0f)) == Kind::Self); // Blink, Stoneskin, Aquaveil, Barfire: an area only under Accession
    CHECK(Classify(spell(1, 3, 0.0f)) == Kind::Self); // Blaze Spikes, Klimaform: an area only under Manifestation
    CHECK(Classify(spell(1, 6, 0.0f)) == Kind::Self); // Cocoon, Metallic Body: an area only under Diffusion
    CHECK(Classify(spell(0, 4, 0.0f)) == Kind::Self); // Animus Augeo, Adloquium (no valid target given)

    // unchanged by the fix
    for (const Facts& s : { spell(1, 0, 0.0f), spell(1, 4, 0.0f), spell(1, 3, 0.0f), spell(1, 6, 0.0f), spell(0, 4, 0.0f) })
    {
        CHECK(Classify(s) == before(s));
        CHECK_FALSE(ReachesPartyAroundCaster(s));
    }

    // a radial area needs a radius, and "self" has to be the only valid target (what Cast aims at the caster)
    CHECK(Classify(spell(1, 1, 0.0f)) == Kind::Self);
    CHECK(Classify(spell(0x0101, 1, 10.0f)) == Kind::Self); // (self + pet)
    CHECK(Classify(spell(0x0201, 0, 0.0f)) == Kind::Self);  // Indi-Regen: self + the Entrust flag, no area
}

TEST_CASE("squad spell kind: spells that go on a party member are unchanged", "[squad][spellkind]")
{
    const Facts rows[] = {
        spell(95, 4, 0.0f),  // Cure
        spell(91, 4, 0.0f),  // Protect II
        spell(91, 0, 0.0f),  // Haste
        spell(3, 4, 0.0f),   // Sneak, Regen, Erase
        spell(3, 1, 10.0f),  // Curaga
        spell(3, 0, 0.0f),   // Warp II, Retrace, Geo-Regen
    };

    for (const Facts& s : rows)
    {
        CHECK(Classify(s) == Kind::Party);
        CHECK(Classify(s) == before(s));
        CHECK_FALSE(ReachesPartyAroundCaster(s)); // (party by their valid target, not by their area)
    }
}

TEST_CASE("squad spell kind: Raise goes on the fallen", "[squad][spellkind]")
{
    const Facts raise = spell(32, 0, 0.0f);
    CHECK(Classify(raise) == Kind::Dead);
    CHECK(Classify(raise) == before(raise));

    // dead wins over an area around the caster
    CHECK(Classify(spell(0x0021, 1, 10.0f)) == Kind::Dead);
}

TEST_CASE("squad spell kind: spells on an enemy are unchanged, with or without an area", "[squad][spellkind]")
{
    const Facts rows[] = {
        enemy(4, 1, 10.0f),       // Stonega, Sleepga
        enemy(4, 0, 0.0f),        // Stone
        enemy(4, 1, 4.0f, true),  // Horde Lullaby
        enemy(4, 0, 0.0f, true),  // Foe Lullaby
        enemy(1, 1, 10.0f),       // (whatever the table says, an enemy spell is never an area around the caster)
        enemy(0x0081, 5, 10.0f, true),
    };

    for (const Facts& s : rows)
    {
        CHECK(Classify(s) == Kind::Enemy);
        CHECK(Classify(s) == before(s));
        CHECK_FALSE(ReachesPartyAroundCaster(s));
    }
}

TEST_CASE("squad spell kind: the only change is self to party", "[squad][spellkind]")
{
    // every combination of the inputs the table uses: the fix never touches an enemy, dead or party spell, and never makes a
    // spell "self" that was not
    int changed = 0;
    for (const bool canTargetEnemy : { false, true })
    {
        for (const bool isSong : { false, true })
        {
            for (uint16_t validTargets = 0; validTargets < 0x1000; ++validTargets)
            {
                for (uint8_t aoe = 0; aoe <= 6; ++aoe)
                {
                    for (const float radius : { 0.0f, 4.0f, 10.0f })
                    {
                        const Facts s{ .canTargetEnemy = canTargetEnemy, .validTargets = validTargets, .aoe = aoe, .radius = radius, .song = isSong };
                        const Kind  now = Classify(s);
                        const Kind  was = before(s);
                        if (now != was)
                        {
                            ++changed;
                            REQUIRE(was == Kind::Self);
                            REQUIRE(now == Kind::Party);
                            REQUIRE(ReachesPartyAroundCaster(s));
                            REQUIRE_FALSE(canTargetEnemy);
                            REQUIRE((validTargets & 0x0001) != 0);
                            REQUIRE(radius > 0.0f);
                        }
                    }
                }
            }
        }
    }

    CHECK(changed > 0);
}

TEST_CASE("squad spell kind: the names Lua reads", "[squad][spellkind]")
{
    CHECK(std::string(Name(Kind::Enemy)) == "enemy");
    CHECK(std::string(Name(Kind::Dead)) == "dead");
    CHECK(std::string(Name(Kind::Party)) == "party");
    CHECK(std::string(Name(Kind::Self)) == "self");
}
