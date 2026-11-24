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

// XI: Forever Offline (Squad healer range): the party-target reach rule in map/ai/helpers/gambits_reach.h.
// Spell data below is copied from sql/spell_list.sql (validTargets, spell_range / 10, radius / 10).

#include "map/ai/helpers/gambits_reach.h"

#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <optional>

namespace
{

using gambits::reach::FromAbilityData;
using gambits::reach::FromSpellData;
using gambits::reach::PartyReach;
using gambits::reach::SpellReach;
using gambits::reach::TrustPartyReach;
using gambits::reach::WithinReach;

struct Pos
{
    float x;
    float y;
    float z;
};

// spell_list.sql rows: { validTargets, spell_range / 10, radius / 10 }
const auto Cure      = FromSpellData(95, 20.0f, 0.0f);  // 1
const auto CureIV    = FromSpellData(95, 20.0f, 0.0f);  // 4
const auto Curaga    = FromSpellData(3, 20.0f, 10.0f);  // 7
const auto Poisona   = FromSpellData(91, 20.0f, 0.0f);  // 14
const auto Haste     = FromSpellData(91, 20.0f, 0.0f);  // 57
const auto Erase     = FromSpellData(3, 20.0f, 0.0f);   // 143
const auto Protectra = FromSpellData(1, 0.0f, 10.0f);   // 125
const auto Shellra   = FromSpellData(1, 0.0f, 10.0f);   // 130
const auto Blink     = FromSpellData(1, 0.0f, 0.0f);    // 53
const auto Dia       = FromSpellData(4, 20.0f, 0.0f);   // 23 (enemy only)
const auto Raise     = FromSpellData(32, 20.0f, 0.0f);  // 12 (dead members only)

const auto ArmysPaeon     = FromSpellData(129, 20.0f, 10.0f); // 378 (a song: the singer, or a member under Pianissimo; range 20, radius 10)
const auto ValorMinuet    = FromSpellData(129, 20.0f, 10.0f); // 394
const auto AdvancingMarch = FromSpellData(129, 20.0f, 10.0f); // 419
const auto NoSelfSpell = FromSpellData(128, 20.0f, 0.0f);  // (Pianissimo bit without a self target: not a song on the singer)

// abilities.sql rows (v0.3.2): { validTarget, radius }
const auto FightersRoll = FromAbilityData(1, 8.0f);  // Corsair's rolls: used on oneself, radius 8
const auto Warcry       = FromAbilityData(1, 14.0f); // 32
const auto HasteSamba   = FromAbilityData(1, 0.0f);  // self only, no area
const auto CuringWaltz  = FromAbilityData(3, 0.0f);  // single target
const auto DivineWaltz  = FromAbilityData(27, 10.0f); // 195 (valid targets 27: usable on a party member too, the area is around that member)

const std::optional<SpellReach> NoSpell = std::nullopt; // a job ability, ranged attack or mixed rule

// Is a member at this spot a valid target for the rule (caster at the origin)?
auto Reaches(const bool squadMate, const std::optional<SpellReach>& spell, const Pos& member, const float casterHitbox = 0.0f, const float memberHitbox = 0.0f) -> bool
{
    return WithinReach(Pos{ 0.0f, 0.0f, 0.0f }, member, PartyReach(squadMate, spell, casterHitbox, memberHitbox));
}

} // namespace

TEST_CASE("gambits reach: spell data is classified like CTrustController::Cast", "[gambits][reach]")
{
    REQUIRE(Cure.has_value());
    CHECK_FALSE(Cure->selfOnly);
    REQUIRE(Curaga.has_value());
    CHECK_FALSE(Curaga->selfOnly); // (cast on the member, its area is around them)
    REQUIRE(Protectra.has_value());
    CHECK(Protectra->selfOnly);
    REQUIRE(Shellra.has_value());
    CHECK(Shellra->selfOnly);
    REQUIRE(Blink.has_value());
    CHECK(Blink->selfOnly);
    CHECK_FALSE(Dia.has_value());
    CHECK_FALSE(Raise.has_value());
}

TEST_CASE("gambits reach: ordinary trusts keep the inherited 15 yalms for every action", "[gambits][reach]")
{
    for (const auto& spell : { Cure, CureIV, Curaga, Protectra, Shellra, Blink, NoSpell })
    {
        CHECK(PartyReach(false, spell, 0.0f, 0.0f) == 15.0f);
        CHECK(PartyReach(false, spell, 1.0f, 2.0f) == 15.0f);
    }

    CHECK(Reaches(false, Cure, { 15.0f, 0.0f, 0.0f }));
    CHECK_FALSE(Reaches(false, Cure, { 15.1f, 0.0f, 0.0f }));
    CHECK(Reaches(false, Protectra, { 14.0f, 0.0f, 0.0f })); // (unchanged, including the old Protectra behaviour)
}

TEST_CASE("gambits reach: squad cures and single-target support reach the spell's range", "[gambits][reach]")
{
    for (const auto& spell : { Cure, CureIV, Curaga, Poisona, Haste, Erase })
    {
        CHECK(PartyReach(true, spell, 0.0f, 0.0f) == 20.0f);
        CHECK(Reaches(true, spell, { 16.0f, 0.0f, 0.0f })); // beyond the old 15
        CHECK(Reaches(true, spell, { 19.9f, 0.0f, 0.0f }));
        CHECK_FALSE(Reaches(true, spell, { 20.1f, 0.0f, 0.0f })); // beyond the spell
    }
}

TEST_CASE("gambits reach: hitboxes count like a player's cast", "[gambits][reach]")
{
    CHECK(std::abs(PartyReach(true, Cure, 0.5f, 0.7f) - 21.2f) < 1e-4f);
    CHECK(Reaches(true, Cure, { 21.0f, 0.0f, 0.0f }, 0.5f, 0.7f));
    CHECK_FALSE(Reaches(true, Cure, { 21.3f, 0.0f, 0.0f }, 0.5f, 0.7f));
    CHECK(PartyReach(true, Cure, -1.0f, -1.0f) == 20.0f); // (a bad hitbox never shrinks the spell)
}

TEST_CASE("gambits reach: never beyond the trust cast limit, never below the inherited radius", "[gambits][reach]")
{
    const auto longRange = FromSpellData(3, 40.0f, 0.0f); // (not "far": windows.h defines far and near)
    CHECK(PartyReach(true, longRange, 0.0f, 0.0f) == 27.0f); // 28.5 cast limit - 1.5 margin
    CHECK(PartyReach(true, Cure, 5.0f, 5.0f) == 27.0f);
    CHECK(PartyReach(true, Cure, 5.0f, 5.0f) < gambits::reach::TrustCastLimit);

    const auto shortRange = FromSpellData(3, 10.0f, 0.0f);
    CHECK(PartyReach(true, shortRange, 0.0f, 0.0f) == 15.0f); // (shorter actions keep what they had)

    const auto noRange = FromSpellData(3, 0.0f, 0.0f);
    CHECK(PartyReach(true, noRange, 0.0f, 0.0f) == 15.0f);
}

TEST_CASE("gambits reach: job abilities, ranged attacks and mixed rules keep 15 yalms", "[gambits][reach]")
{
    CHECK(PartyReach(true, NoSpell, 0.0f, 0.0f) == 15.0f);
    CHECK(PartyReach(true, NoSpell, 3.0f, 3.0f) == 15.0f);
    CHECK(Reaches(true, NoSpell, { 15.0f, 0.0f, 0.0f }));
    CHECK_FALSE(Reaches(true, NoSpell, { 15.1f, 0.0f, 0.0f }));
    CHECK(PartyReach(true, Dia, 0.0f, 0.0f) == 15.0f); // (an enemy spell in a party rule: unchanged)
}

TEST_CASE("gambits reach: Protectra and Shellra only for members inside their area", "[gambits][reach]")
{
    for (const auto& spell : { Protectra, Shellra })
    {
        CHECK(PartyReach(true, spell, 0.0f, 0.0f) == 10.0f);
        CHECK(PartyReach(true, spell, 2.0f, 2.0f) == 10.0f); // (CTargetFind::isWithinArea: centre to centre, no hitbox)
        CHECK(Reaches(true, spell, { 0.0f, 0.0f, 0.0f }));  // the caster itself
        CHECK(Reaches(true, spell, { 9.9f, 0.0f, 0.0f }));
        CHECK_FALSE(Reaches(true, spell, { 10.1f, 0.0f, 0.0f }));
        CHECK_FALSE(Reaches(true, spell, { 14.0f, 0.0f, 0.0f })); // (was a valid target at 15: a cast that missed them)
    }
}

TEST_CASE("gambits reach: a self-only spell without an area is for the caster alone", "[gambits][reach]")
{
    CHECK(PartyReach(true, Blink, 0.0f, 0.0f) == 0.0f);
    CHECK(Reaches(true, Blink, { 0.0f, 0.0f, 0.0f }));
    CHECK_FALSE(Reaches(true, Blink, { 0.5f, 0.0f, 0.0f }));
}

TEST_CASE("gambits reach: distance is 3D, vertical separation counts", "[gambits][reach]")
{
    CHECK(WithinReach(Pos{ 0, 0, 0 }, Pos{ 12, 0, 12 }, 20.0f));        // 16.97 flat
    CHECK_FALSE(WithinReach(Pos{ 0, 0, 0 }, Pos{ 12, 12, 12 }, 20.0f)); // 20.78 with the slope
    CHECK_FALSE(WithinReach(Pos{ 0, 0, 0 }, Pos{ 0, 16, 0 }, 15.0f));   // straight up
    CHECK(WithinReach(Pos{ 0, 0, 0 }, Pos{ 0, 16, 0 }, 20.0f));
    CHECK(WithinReach(Pos{ 5, 2, -3 }, Pos{ 5, 2, -3 }, 0.0f));
    CHECK_FALSE(WithinReach(Pos{ 0, 0, 0 }, Pos{ 0, 0, 0 }, -1.0f));

    // matches sqrt(dx^2 + dy^2 + dz^2) <= reach (distance() in common/utils.h) around the edge
    const Pos a{ 1.0f, 2.0f, 3.0f };
    const Pos b{ 13.0f, 7.0f, 15.0f };
    const float d = std::sqrt(144.0f + 25.0f + 144.0f);
    CHECK(WithinReach(a, b, d + 0.001f));
    CHECK_FALSE(WithinReach(a, b, d - 0.001f));
}

TEST_CASE("gambits reach: the reported Squad healer position (squad_space.lua) is now in cure reach", "[gambits][reach]")
{
    // Monster at the origin, tank 2 yalms east of it; squad_space holds a WHM 15 yalms from the monster at a random
    // angle and C++ accepts 12.5-17.5 (PathOutToDistance). Caster-relative positions of the tank:
    const Pos tank{ 2.0f, 0.0f, 0.0f };
    const auto tankSeenFrom = [&](const Pos& healer)
    {
        return Pos{ tank.x - healer.x, tank.y - healer.y, tank.z - healer.z };
    };

    const Pos opposite{ -15.0f, 0.0f, 0.0f };   // the far side: 17 yalms from the tank
    const Pos outerBand{ -17.5f, 0.0f, 0.0f };  // edge of the accepted band: 19.5 yalms
    const Pos onSlope{ -15.0f, 6.0f, 0.0f };    // far side and 6 yalms up a slope: 18.03 yalms

    for (const auto& healer : { opposite, outerBand, onSlope })
    {
        CHECK_FALSE(Reaches(false, Cure, tankSeenFrom(healer))); // inherited 15: no cure rule could pick the tank
        CHECK(Reaches(true, Cure, tankSeenFrom(healer)));        // squad mate: the cure range applies
    }

    CHECK_FALSE(Reaches(true, Protectra, tankSeenFrom(opposite))); // ...but Protectra still would not cover the tank
}

TEST_CASE("gambits reach: a song is sung on the singer and reaches only its radius", "[gambits][reach][songs]")
{
    // valid targets 129 = self + Pianissimo target; it used to be neither "self only" nor "a party member" and fell back to 15
    for (const auto& song : { ArmysPaeon, ValorMinuet, AdvancingMarch })
    {
        REQUIRE(song.has_value());
        CHECK(song->selfOnly);
        CHECK(song->radius == 10.0f);
        CHECK(PartyReach(true, song, 0.0f, 0.0f) == 10.0f);
        CHECK(Reaches(true, song, { 9.9f, 0.0f, 0.0f }));
        CHECK_FALSE(Reaches(true, song, { 10.1f, 0.0f, 0.0f })); // a melee member 12 yalms away is not a valid target any more
        CHECK_FALSE(Reaches(true, song, { 14.0f, 0.0f, 0.0f }));
    }

    CHECK_FALSE(NoSelfSpell.has_value());
}

TEST_CASE("gambits reach: job abilities with an area reach their radius, the rest keep 15", "[gambits][reach][abilities]")
{
    REQUIRE(FightersRoll.has_value());
    CHECK(FightersRoll->selfOnly);
    CHECK(PartyReach(true, FightersRoll, 0.0f, 0.0f) == 8.0f);
    CHECK(Reaches(true, FightersRoll, { 7.9f, 0.0f, 0.0f }));
    CHECK_FALSE(Reaches(true, FightersRoll, { 8.1f, 0.0f, 0.0f }));
    REQUIRE(Warcry.has_value());
    CHECK(PartyReach(true, Warcry, 0.0f, 0.0f) == 14.0f);
    CHECK_FALSE(DivineWaltz.has_value()); // (cast on a party member: not an area around oneself, keeps 15)

    CHECK_FALSE(HasteSamba.has_value());  // (no area: the inherited reach, as before)
    CHECK_FALSE(CuringWaltz.has_value()); // (single target: the inherited reach, as before)
    CHECK(PartyReach(true, HasteSamba, 0.0f, 0.0f) == 15.0f);
}

TEST_CASE("gambits reach: ordinary trusts keep 15 except for an area effect on oneself", "[gambits][reach][trusts]")
{
    // Kupipi Protectra / Shellra, Qultada's rolls, a bard's songs: the radius. Everything else (cures, single target abilities,
    // no spell known): the 15 yalms every party target always had.
    CHECK(TrustPartyReach(Protectra) == 10.0f);
    CHECK(TrustPartyReach(Shellra) == 10.0f);
    CHECK(TrustPartyReach(ArmysPaeon) == 10.0f);
    CHECK(TrustPartyReach(FightersRoll) == 8.0f);
    CHECK(TrustPartyReach(Warcry) == 14.0f);

    CHECK(TrustPartyReach(Cure) == 15.0f);
    CHECK(TrustPartyReach(Curaga) == 15.0f); // (cast on the member: the 15 stays, the area is around them)
    CHECK(TrustPartyReach(Haste) == 15.0f);
    CHECK(TrustPartyReach(Blink) == 15.0f); // (self only without an area: not an area rule)
    CHECK(TrustPartyReach(NoSpell) == 15.0f);
    CHECK(TrustPartyReach(HasteSamba) == 15.0f);
    CHECK(TrustPartyReach(CuringWaltz) == 15.0f);
    CHECK(TrustPartyReach(Dia) == 15.0f);
}

TEST_CASE("gambits reach: the predicted loop - a member 10 to 15 yalms away is no longer a target of an area rule", "[gambits][reach][loop]")
{
    // The rule "a party member lacks Protect > Protectra" (Kupipi) or "... Minuet > Minuet" (a squad bard) picked the first
    // member inside 15 yalms. Protectra and the songs reach 10, so under the retail area range the cast landed on nobody new
    // and the rule picked the same member again. Both kinds of caster now stop at the radius.
    const Pos farMember{ 12.0f, 0.0f, 0.0f };
    CHECK(WithinReach(Pos{ 0, 0, 0 }, farMember, 15.0f));                                // before
    CHECK_FALSE(WithinReach(Pos{ 0, 0, 0 }, farMember, TrustPartyReach(Protectra)));    // ordinary trust now
    CHECK_FALSE(Reaches(true, Protectra, farMember));                                   // squad mate (already)
    CHECK_FALSE(Reaches(true, ArmysPaeon, farMember));                                 // squad bard song (was reachable at 15)
    CHECK_FALSE(WithinReach(Pos{ 0, 0, 0 }, farMember, TrustPartyReach(FightersRoll))); // Qultada's roll (8)
    CHECK(WithinReach(Pos{ 0, 0, 0 }, Pos{ 7.0f, 0, 0 }, TrustPartyReach(FightersRoll))); // a member inside the roll still is
}
