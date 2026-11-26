/*
===========================================================================

  XI: Forever Offline: where a squad mate stands in a fight, as the player chose (!squad position, the Squads menu).

    Normal     - as before: the job's usual spot (melee next to the enemy, casters and ranged at their distance).
    Behind     - on the enemy's back side. Melee next to it, casters and ranged at their usual distance. Several mates with
                 this choice share an arc behind the enemy, each on its own spot, so they do not stand in one another.
    TA partner - a melee mate stands right behind the enemy, turned towards the player within 60 degrees of straight
                 behind (r3; PartnerSpot): a player Thief anywhere behind the enemy has it in line for Trick Attack while
                 also being behind the enemy for Sneak Attack. It never goes to the enemy's front. Only one mate takes
                 that spot; others with this choice stand in the arc like Behind, and the arc keeps off its line.

  A mate the enemy is attacking keeps its usual place (the enemy turns to face it whatever it does). The spots move with
  the enemy, and a mate moves to its spot at most every few seconds and only when it is clearly away from it, so the
  squad does not keep running while the enemy turns.

  This header holds the pure geometry (no engine types), tested in src/test/tests/squad_position_tests.cpp; the trust
  controller feeds it.

===========================================================================
*/

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>

namespace squad::position
{

enum Mode : int32_t
{
    Normal    = 0,
    Behind    = 1,
    TaPartner = 2,
};

inline constexpr float Pi = 3.14159265f;

// The arc behind the enemy: the first mate straight behind, then 30 degrees to either side, then 60, at most 75 (all
// inside the back half, where "behind" counts).
inline constexpr float ArcStep = Pi / 6.0f;          // 30 degrees
inline constexpr float ArcMax  = Pi * 75.0f / 180.0f; // 75 degrees

// How far from its spot a mate may be before it moves (yalms), and how often it may move (seconds).
inline constexpr float MeleeSlack       = 1.0f;
inline constexpr float RangedSlack      = 2.0f;
inline constexpr float MoveEverySeconds = 2.0f;

// A caster or ranged mate behind the enemy keeps the enemy's target (the tank) within this many yalms; otherwise it
// keeps its usual place, so a heal can still reach.
inline constexpr float TankReach = 18.0f;

// The TA partner stands this far from the enemy (behind it, towards the player: PartnerSpot).
inline constexpr float PartnerDistance = 1.2f;

// Melee mates in the arc stand this far from the enemy: far enough apart that up to five of them (0, +-30, +-60 degrees)
// are over a yalm from one another, but always inside the reach of their swing (MeleeArcRadius).
inline constexpr float MeleeArcRadius   = 2.0f;
inline constexpr float MeleeArcMin      = 1.2f; // (the thief logic's own spot behind the target)
inline constexpr float MeleeReachMargin = 0.6f;

// The melee arc's radius for a mate whose swing reaches `meleeRange` yalms (the engine's GetMeleeRange, hit boxes
// included): MeleeArcRadius, closer for a small enemy, never closer than MeleeArcMin.
inline auto MeleeRadius(float meleeRange) -> float
{
    return std::clamp(meleeRange - MeleeReachMargin, MeleeArcMin, MeleeArcRadius);
}

struct Point
{
    float x{};
    float z{};
};

// Offset from straight behind (radians) for the index-th mate in the arc (0-based): 0, +30, -30, +60, -60, +75, -75, ...
inline auto ArcOffset(int index) -> float
{
    if (index <= 0)
    {
        return 0.0f;
    }
    const int   ring   = (index + 1) / 2;                 // 1, 1, 2, 2, 3, 3, ...
    const float side   = (index % 2 == 1) ? 1.0f : -1.0f; // +, -, +, -, ...
    const float amount = std::min(ArcStep * static_cast<float>(ring), ArcMax);
    return side * amount;
}

// The spot `radius` yalms from the enemy on its back side, turned by `offset` radians. `facing` is the enemy's facing in
// radians as the engine has it (rotationToRadian of its rotation); the formula is the engine's nearPosition with
// facing + pi, so offset 0 is exactly where the engine's own "behind the target" spot is.
inline auto BehindSpot(Point enemy, float facing, float radius, float offset) -> Point
{
    const float total = facing + Pi + offset;
    return { enemy.x + std::cos(2.0f * Pi - total) * radius, enemy.z + std::sin(2.0f * Pi - total) * radius };
}

inline auto Distance(Point a, Point b) -> float
{
    const float dx = a.x - b.x;
    const float dz = a.z - b.z;
    return std::sqrt(dx * dx + dz * dz);
}

// Should a mate head for its spot now? Only when it is clearly away from it and has not just moved.
inline auto ShouldMove(float distanceToSpot, float slack, float secondsSinceLastMove) -> bool
{
    return distanceToSpot > slack && secondsSinceLastMove >= MoveEverySeconds;
}

// The offset (radians, from straight behind, the convention of BehindSpot) of the direction from the enemy to `point`,
// in [-pi, pi]. OffsetOf(enemy, facing, BehindSpot(enemy, facing, r, o)) == o.
inline auto OffsetOf(Point enemy, float facing, Point point) -> float
{
    const float theta = std::atan2(point.z - enemy.z, point.x - enemy.x); // (BehindSpot: theta = 2 pi - (facing + pi + o))
    float       o     = Pi - theta - facing;
    while (o > Pi)
    {
        o -= 2.0f * Pi;
    }
    while (o < -Pi)
    {
        o += 2.0f * Pi;
    }
    return o;
}

// (r3, the user: "the TA partner always stands behind") The TA partner never leaves the enemy's back: it turns towards the
// player within PartnerMaxAngle of straight behind. A player Thief anywhere behind the enemy then has it in line for Trick
// Attack (and is behind the enemy for Sneak Attack); a player at the side or in front leaves it at the edge of the back
// arc or straight behind, never in front of the enemy.
inline constexpr float PartnerMaxAngle = Pi / 3.0f; // 60 degrees

// The offset (from straight behind) the TA partner stands at: towards the player, at most PartnerMaxAngle; straight
// behind when the player stands (nearly) on the enemy.
inline auto PartnerOffset(Point enemy, float facing, Point player) -> float
{
    if (Distance(enemy, player) < 0.5f)
    {
        return 0.0f;
    }
    return std::clamp(OffsetOf(enemy, facing, player), -PartnerMaxAngle, PartnerMaxAngle);
}

// The TA partner's spot: `dist` yalms from the enemy, on its back side, towards the player (PartnerOffset).
inline auto PartnerSpot(Point enemy, float facing, Point player, float dist) -> Point
{
    return BehindSpot(enemy, facing, dist, PartnerOffset(enemy, facing, player));
}

// The player's Trick Attack takes a party member within about 11 degrees of the line from the enemy to the player
// (battleutils areInLine, worldAngleMaxDeviance 8/256). While a TA partner is fighting the enemy, the Behind arc keeps
// this far from that line, so only the partner is in line.
inline constexpr float PartnerClear = Pi * 25.0f / 180.0f;

// The arc offset for the index-th mate (0-based), skipping the spots within PartnerClear of `avoid` (the TA line's
// offset) when there is one. Without one: ArcOffset(index).
inline auto ArcOffsetAvoiding(int index, std::optional<float> avoid) -> float
{
    if (!avoid.has_value())
    {
        return ArcOffset(index);
    }
    int seen = 0;
    for (int k = 0; k < 32; ++k)
    {
        const float o = ArcOffset(k);
        if (std::fabs(o - *avoid) < PartnerClear)
        {
            continue;
        }
        if (seen == std::max(index, 0))
        {
            return o;
        }
        ++seen;
    }
    return ArcOffset(index); // (not reached: the outermost spots repeat)
}

// One mate's place among those of its master that use a position on the same enemy, counted in the master's order.
struct Peer
{
    bool self{};     // this is the mate asking
    int  mode{};     // Mode
    bool melee{};    // a melee mate (else caster / ranged)
    bool usable{};   // alive, fighting the same enemy, not the enemy's target
    bool fighting{}; // alive and fighting the same enemy (the enemy may be on it)
};

struct Placement
{
    bool positioned{};   // false: keep the usual place
    bool partner{};      // the TA partner spot
    int  arcIndex{};     // else the index in the arc of its kind (melee or not)
    bool lineReserved{}; // a TA partner fights this enemy: the melee arc keeps off the line to the player
};

// Is the line to the player kept for a TA partner? Whenever a melee mate set to TA partner fights the enemy, also while
// the enemy is on it (it then keeps its usual place, but nobody else takes the line meanwhile).
template <typename Range>
inline auto LineReserved(const Range& peers, bool partnerSpotExists) -> bool
{
    if (!partnerSpotExists)
    {
        return false;
    }
    for (const Peer& p : peers)
    {
        if (p.fighting && p.melee && p.mode == TaPartner)
        {
            return true;
        }
    }
    return false;
}

// Where the asking mate (the Peer with self = true) stands. Melee and casters have separate arcs (they stand at
// different distances). The first usable melee mate with TA partner takes the partner spot when `partnerSpotExists`;
// the other TA partners join the melee arc.
template <typename Range>
inline auto Place(const Range& peers, bool partnerSpotExists) -> Placement
{
    const bool reserved     = LineReserved(peers, partnerSpotExists);
    bool       partnerTaken = false;
    int        meleeArc     = 0;
    int        otherArc     = 0;
    for (const Peer& p : peers)
    {
        if (!p.usable || (p.mode != Behind && p.mode != TaPartner))
        {
            if (p.self)
            {
                return {};
            }
            continue;
        }
        const bool takesPartner = p.melee && p.mode == TaPartner && partnerSpotExists && !partnerTaken;
        if (p.self)
        {
            if (takesPartner)
            {
                return { .positioned = true, .partner = true, .arcIndex = 0, .lineReserved = reserved };
            }
            return { .positioned = true, .partner = false, .arcIndex = p.melee ? meleeArc : otherArc, .lineReserved = reserved };
        }
        if (takesPartner)
        {
            partnerTaken = true;
        }
        else if (p.melee)
        {
            ++meleeArc;
        }
        else
        {
            ++otherArc;
        }
    }
    return {};
}

// What a mate with a chosen position is doing, for "!squad position <slot>" (local var SQUAD_POS_STATE).
enum State : int32_t
{
    StateNone       = 0, // not in a fight (or Normal)
    StateArc        = 1, // in the arc behind the enemy (SQUAD_POS_ARC = its index + 1)
    StatePartner    = 2, // on the TA partner spot
    StateEnemyOnIt  = 3, // its usual place: the enemy is attacking it
    StateOtherFoe   = 4, // its usual place: it is not fighting the enemy its master's party fights here
    StateTankTooFar = 5, // its usual place: from the spot behind, the tank would be out of a heal's reach
    StateThief      = 6, // the thief logic places it for Sneak / Trick Attack right now
};

} // namespace squad::position
