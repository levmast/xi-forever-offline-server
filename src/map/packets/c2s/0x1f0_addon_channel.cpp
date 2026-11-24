/*
===========================================================================

  Copyright (c) 2025 LandSandBoat Dev Teams

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

#include "0x1f0_addon_channel.h"

#include "command_handler.h"
#include "common/logging.h"
#include "common/lua.h"
#include "entities/char_entity.h"
#include "map_session.h"
#include "packets/c2s/validation.h"
#include "utils/jailutils.h"

#include <algorithm>

auto GP_CLI_COMMAND_ADDON_CHANNEL::validate(MapSession* PSession, const CCharEntity* PChar) const -> PacketValidationResult
{
    return PacketValidator(PChar)
        .mustEqual(this->Version, 1, "Unknown addon channel version");
}

void GP_CLI_COMMAND_ADDON_CHANNEL::process(MapSession* PSession, CCharEntity* PChar) const
{
    // The text starts after the header (4), the version and the three reserved bytes (4). It may not be NUL terminated when the client
    // filled the whole buffer, so read at most what the packet says it carries.
    const auto messageLength = std::min<std::size_t>((header.size * 4) - 0x8, sizeof(this->Str));
    const auto rawMessage    = asStringFromUntrustedSource(this->Str, messageLength);
    if (rawMessage.empty())
    {
        return;
    }

    // Same rule as a "!" chat line: a jailed character runs no commands.
    if (jailutils::InPrison(PChar))
    {
        return;
    }

    // The line may carry its leading '!' (the chat form) or not; the command handler wants it without.
    const auto command = rawMessage[0] == '!' ? rawMessage.substr(1) : rawMessage;
    if (command.empty())
    {
        return;
    }

    // TODO: Don't pass around Scheduler& through PSession (same as the chat packet)
    auto& scheduler = *PSession->scheduler;

    // Unlike chat there is no fallthrough: a line that is not a command is dropped, never said to anyone.
    static_cast<void>(CCommandHandler::call(scheduler, lua, PChar, command));
}
