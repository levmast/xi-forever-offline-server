/*
===========================================================================

  XI: Forever Offline (2026-11-23): the Randomized characters' own auction house.

  Randomized characters (char var "[HC]Mode" = 4) see the same auction house as everyone, with two changes:
    * stock rotates: every 6 hours each item is either in stock for them or not (about 70 in 100 are), so what can be
      bought keeps changing. Crystals and clusters are always in stock, so synthesis never stops.
    * prices swing 20% more: each item gets its own price factor for the 6 hours, between 0.80 and 1.20. The search
      server shows them the price history times that factor, and the map server lets them buy a listing when their
      bid is at least the listing's price times the factor (they pay what they bid, as everyone does).

  Pure functions of (item, time), so the map server (buying) and the search server (what the lists show) always
  agree without talking to each other. Header only; nothing changes for anyone who is not Randomized.

===========================================================================
*/

#pragma once

#include "common/cbasetypes.h"

namespace hardcoremarket
{
    constexpr uint32 PeriodSeconds = 6 * 60 * 60; // a new stock and new prices every 6 hours
    constexpr uint32 InStockOf100  = 70;          // about 70 items in 100 are in stock in a period
    constexpr double Swing         = 0.20;        // prices move up to 20% either way

    inline auto mix(uint64 x) -> uint64 // splitmix64
    {
        x += 0x9E3779B97F4A7C15ULL;
        x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
        x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
        return x ^ (x >> 31);
    }

    inline auto period(uint32 now) -> uint32
    {
        return now / PeriodSeconds;
    }

    inline auto roll(uint16 itemId, uint32 now, uint64 salt) -> uint64
    {
        return mix((static_cast<uint64>(itemId) << 32) ^ (static_cast<uint64>(period(now)) * 0x2545F4914F6CDD1DULL) ^ salt);
    }

    // crystals and clusters (4096 - 4111) are always there
    inline auto inStock(uint16 itemId, uint32 now) -> bool
    {
        if (itemId >= 4096 && itemId <= 4111)
        {
            return true;
        }

        return roll(itemId, now, 0x51ULL) % 100 < InStockOf100;
    }

    // 0.80 .. 1.20 for this item in this period
    inline auto factor(uint16 itemId, uint32 now) -> double
    {
        const double unit = static_cast<double>(roll(itemId, now, 0xA7ULL) % 2001) / 1000.0 - 1.0; // -1 .. 1
        return 1.0 + Swing * unit;
    }

    // a price as a Randomized character sees it
    inline auto shown(uint32 price, uint16 itemId, uint32 now) -> uint32
    {
        const double value = static_cast<double>(price) * factor(itemId, now) + 0.5;
        return value < 1.0 ? 1 : static_cast<uint32>(value);
    }
} // namespace hardcoremarket
