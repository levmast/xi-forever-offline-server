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

#pragma once

#include "base.h"

// Not a retail packet: the retail client never sends it. An addon builds it and hands it to the client's packet manager (Ashita:
// AddOutgoingPacket), so the line it carries never passes the chat input: it is not echoed, it is not a chat line, and no other player
// ever sees it. The server runs the text exactly as it runs a "!" chat line (the same command handler, the same permission checks).
//
// Layout (all little endian, the header is the usual 4 bytes: id 0x1F0, size in dwords, sync):
//   [header 4][Version 1][reserved 3][Str ... NUL][pad to 4]
// Version is 1. The text is at most 120 characters (a longer line is cut by the addon, and anything past the buffer is ignored here).
// A server that handles this packet says so to Lua: xi.addonChannel = { packet = 0x1F0, version = 1 } (a build without it has no such table).
GP_CLI_PACKET_VLA(GP_CLI_COMMAND_ADDON_CHANNEL, Str,
                  uint8_t Version;     // Channel protocol version, 1
                  uint8_t reserved[3]; // Zero
                  uint8_t Str[124];    // Command text, NUL terminated (with or without the leading '!')
);
