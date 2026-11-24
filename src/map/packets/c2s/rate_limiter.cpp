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

#include "rate_limiter.h"

#include "common/logging.h"
#include "common/lua.h"

#include "entities/char_entity.h"
#include "enums/packet_c2s.h"

#include <optional>

namespace
{

// magic_enum only names the packets up to the end of its range (see enums/packet_c2s.h). A packet above it is named here by hand.
auto packetIdFromName(const std::string& packetName) -> std::optional<PacketC2S>
{
    if (const auto fromEnum = magic_enum::enum_cast<PacketC2S>(packetName); fromEnum.has_value())
    {
        return fromEnum;
    }

    if (packetName == "GP_CLI_COMMAND_ADDON_CHANNEL")
    {
        return PacketC2S::GP_CLI_COMMAND_ADDON_CHANNEL;
    }

    return std::nullopt;
}

} // namespace

PacketRateLimiter::PacketRateLimiter()
{
    // The addon channel runs commands the way chat does, so it keeps the chat pace unless PACKET_RATE_LIMITS says otherwise (0 = no limit).
    rateLimits_[static_cast<uint16>(PacketC2S::GP_CLI_COMMAND_ADDON_CHANNEL)] = std::chrono::milliseconds(200);

    const auto limits = lua["xi"]["settings"]["network"]["PACKET_RATE_LIMITS"].get_or_create<sol::table>();
    if (limits.empty())
    {
        ShowWarning("network.PACKET_RATE_LIMITS is missing or empty, no packets will be rate limited");
        return;
    }

    for (const auto& [keyObj, valueObj] : limits)
    {
        if (keyObj.get_type() != sol::type::string || valueObj.get_type() != sol::type::number)
        {
            ShowWarning("PACKET_RATE_LIMITS: expected entries of the form <packet name> = <milliseconds>, ignoring entry");
            continue;
        }

        const auto packetName    = keyObj.as<std::string>();
        const auto maybePacketId = packetIdFromName(packetName);
        if (!maybePacketId.has_value())
        {
            ShowWarningFmt("PACKET_RATE_LIMITS: unknown packet name {}, ignoring entry", packetName);
            continue;
        }

        const auto milliseconds = valueObj.as<double>();
        if (milliseconds < 0.0)
        {
            ShowWarningFmt("PACKET_RATE_LIMITS: negative duration for {}, ignoring entry", packetName);
            continue;
        }

        if (milliseconds == 0.0)
        {
            rateLimits_.erase(static_cast<uint16>(*maybePacketId));
            continue;
        }

        rateLimits_[static_cast<uint16>(*maybePacketId)] = std::chrono::milliseconds(static_cast<int64>(milliseconds));
    }
}

auto PacketRateLimiter::isLimited(CCharEntity* PChar, uint16 packetId) -> bool
{
    const auto rateLimitIt = rateLimits_.find(packetId);
    if (rateLimitIt == rateLimits_.end())
    {
        return false;
    }

    const auto timeNow           = timer::now();
    const auto [it, wasInserted] = PChar->m_PacketRateLimits.emplace(packetId, PacketRateLimitState{ .lastHandled = timeNow });
    if (wasInserted)
    {
        return false;
    }

    auto& state = it->second;
    if (timeNow >= state.lastHandled + rateLimitIt->second)
    {
        state.lastHandled = timeNow;
        state.warned      = false;
        return false;
    }

    // Warn once per burst, so a client flooding a packet doesn't flood the log too.
    if (!state.warned)
    {
        state.warned = true;
        ShowWarningFmt("Rate-limiting packet {} ({:#05x}) from {}",
                       magic_enum::enum_name(static_cast<PacketC2S>(packetId)),
                       packetId,
                       PChar->getName());
    }

    return true;
}
