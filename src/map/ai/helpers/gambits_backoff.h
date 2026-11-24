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

#pragma once

#include <cstdint>
#include <iterator>
#include <string>
#include <unordered_map>

// XI: Forever Offline: a safety net for party rules that never converge. A rule such as "a member lacks Protect > Protectra"
// stays true for a member the area effect cannot reach (out of its radius, out of its line, dead zone, a status the member
// cannot take), so it fires again at the next retry for the same member, for ever: MP and time spent for nothing, and the
// members the cast could have helped wait behind it. This guard counts the casts of a rule on one member and, after Attempts
// of them inside Window with the member still matching, leaves that member alone for Rest. The members the rule can help
// are not touched, and the rule is tried on that member again once the rest is over.
// Free of engine types (milliseconds from any steady clock) so it can be unit tested on its own
// (src/test/tests/gambits_backoff_tests.cpp).
namespace gambits::backoff
{

constexpr int     Attempts = 3;         // casts on the same member that left the rule true
constexpr int64_t WindowMs = 30'000;    // ...inside this long
constexpr int64_t RestMs   = 45'000;    // then the rule skips that member for this long

class Guard
{
public:
    // Is the rule resting for this member?
    auto Blocked(const std::string& rule, const uint32_t member, const int64_t nowMs) const -> bool
    {
        const auto it = m_entries.find(Key(rule, member));
        return it != m_entries.end() && nowMs < it->second.restUntil;
    }

    // The rule just acted on this member and the member still matched it
    void Record(const std::string& rule, const uint32_t member, const int64_t nowMs)
    {
        if (m_entries.size() > MaxEntries)
        {
            Prune(nowMs);
        }

        auto& entry = m_entries[Key(rule, member)];
        if (nowMs < entry.restUntil)
        {
            return; // (already resting)
        }

        if (entry.count == 0 || nowMs - entry.first > WindowMs)
        {
            entry.count = 0;
            entry.first = nowMs;
        }

        if (++entry.count >= Attempts)
        {
            entry.restUntil = nowMs + RestMs;
            entry.count     = 0;
        }
    }

    // The member no longer matches the rule (it got the effect): forget its count
    void Converged(const std::string& rule, const uint32_t member)
    {
        m_entries.erase(Key(rule, member));
    }

    void Clear()
    {
        m_entries.clear();
    }

    auto Size() const -> std::size_t
    {
        return m_entries.size();
    }

private:
    struct Entry
    {
        int     count     = 0;
        int64_t first     = 0;
        int64_t restUntil = 0;
    };

    static constexpr std::size_t MaxEntries = 256;

    static auto Key(const std::string& rule, const uint32_t member) -> std::string
    {
        return rule + ":" + std::to_string(member);
    }

    void Prune(const int64_t nowMs)
    {
        for (auto it = m_entries.begin(); it != m_entries.end();)
        {
            const bool stale = nowMs >= it->second.restUntil && nowMs - it->second.first > WindowMs;
            it               = stale ? m_entries.erase(it) : std::next(it);
        }
    }

    std::unordered_map<std::string, Entry> m_entries;
};

} // namespace gambits::backoff
