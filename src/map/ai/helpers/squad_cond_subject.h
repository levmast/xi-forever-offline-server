/*
===========================================================================

  XI: Forever Offline (F22, 2026-11-27): who a Gambits condition is about.

  A rule's conditions used to be read on the rule's target only (the enemy for a nuke, the member for a cure). F22 lets
  each condition read another subject:
    Target - the rule's target, as before (the value 0, so every condition written before F22 keeps its meaning);
    Self   - the mate acting ("my MP at least 30%");
    Enemy  - the mate's current combat target ("the enemy's HP below 50%" in a rule for the party).
  The subject travels in the condition id's high bits (Lua: condition + subject * SubjectStep), so the engine's tables,
  the AddGambit call and the saved Rule Sets keep their shape. An older xi_map does not know such an id: its CheckTrigger
  default case makes the condition false, so a rule with one never runs there (it does not run without it).

===========================================================================
*/

#pragma once

#include <cstdint>

namespace squad::condsubject
{

enum class Subject : uint16_t
{
    Target = 0,
    Self   = 1,
    Enemy  = 2,
};

inline constexpr uint16_t SubjectStep = 0x1000; // condition id + subject * SubjectStep
inline constexpr uint16_t BaseMask    = 0x0FFF;

constexpr auto BaseOf(uint16_t raw) -> uint16_t
{
    return static_cast<uint16_t>(raw & BaseMask);
}

constexpr auto SubjectOf(uint16_t raw) -> Subject
{
    const auto s = static_cast<uint16_t>(raw / SubjectStep);
    return s == 1 ? Subject::Self : (s == 2 ? Subject::Enemy : Subject::Target);
}

// true for a subject bit pattern this engine does not know (3 and up): such a condition is false
constexpr auto UnknownSubject(uint16_t raw) -> bool
{
    return raw / SubjectStep > 2;
}

constexpr auto Encode(uint16_t base, Subject subject) -> uint16_t
{
    return static_cast<uint16_t>(BaseOf(base) + static_cast<uint16_t>(subject) * SubjectStep);
}

inline constexpr int MaxConditions = 4; // conditions per Rule Set rule (all AND)

} // namespace squad::condsubject
