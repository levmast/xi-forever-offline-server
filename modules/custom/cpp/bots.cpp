/*
===========================================================================
  FFXI Offline: bot players (step 4.1, proof of concept)

  Real characters with no game window, played from inside the map server, the way LandSandBoat's own test
  framework plays its test characters (src/test/lua/lua_simulation.cpp + lua_client_entity_pair_packets.cpp):
  a session with no network address, the character loaded with charutils::LoadChar, and the same client
  packets a game client sends (log in, zone in, walk, act, chat, answer an invite) handed straight to the
  server's own packet handlers (validate + process). Everything the server sends back to a bot is read and
  dropped here, except the few messages a bot must react to (zoning, a party invite, an event).

  The bot sessions belong to this module (they are not in the network's session list), so the network never
  sends to them and never times them out. A bot only exists while a real player is on the server (its
  sessions borrow that player's scheduler pointer, which some packet handlers need).

  Lua API (global functions, used by modules/custom/lua/bots.lua):
    BotCreate(name, race, face, job, nation, zone, x, y, z) -> charId or 0, message
    BotLogin(charId) -> true/false, message          BotLogout(charId)
    BotIsBot(charId) -> bool                          BotList() -> { charId = { name, online, zone } }
    BotMoveTo(charId, x, y, z) -> bool                BotFollow(charId, entity, distance)   BotStop(charId)
    BotIsMoving(charId) -> bool
    BotAttack(charId, target) / BotAttackOff(charId)  BotCast(charId, spellId, target)
    BotWeaponSkill(charId, wsId, target)              BotAbility(charId, abilityId, target)
    BotShoot(charId, target) (a ranged attack, /shoot)
    BotChat(charId, kind, text)  kind: 0 say, 1 shout, 4 party
    BotAnswerInvite(charId, accept)                   BotLeaveParty(charId)
    BotInvite(charId, playerEntity) (the bot invites you)  BotMakeLeader(charId, name)
  Lua callbacks (optional): xi.bots.onInvite(botEntity, inviterName), xi.bots.onLogin(botEntity), xi.bots.onZoneIn(botEntity)
===========================================================================
*/

#include "common/database.h"
#include "common/lua.h"
#include "common/utils.h"

#include "map/ability.h"
#include "map/ai/ai_container.h"
#include "map/autotranslate.h"
#include "map/ai/states/magic_state.h"
#include "map/entities/char_entity.h"
#include "map/lua/lua_base_entity.h"
#include "map/map_session.h"
#include "map/map_constants.h"
#include "map/navmesh/navmesh.h"
#include "map/packets/basic.h"
#include "map/packets/c2s/0x00a_login.h"
#include "map/packets/c2s/0x011_zone_transition.h"
#include "map/packets/c2s/0x015_pos.h"
#include "map/packets/c2s/0x01a_action.h"
#include "map/packets/c2s/0x032_trade_req.h"
#include "map/packets/c2s/0x033_trade_res.h"
#include "map/packets/c2s/0x036_item_transfer.h"
#include "map/packets/s2c/0x022_item_trade_res.h"
#include "map/items/transactions/player_trade.h"
#include "map/treasure_pool.h"
#include "map/packets/c2s/0x04e_auc.h"
#include "map/packets/c2s/0x05b_eventend.h"
#include "map/packets/c2s/0x05d_motion.h"
#include "map/packets/c2s/0x06e_group_solicit_req.h"
#include "map/packets/c2s/0x06f_group_leave.h"
#include "map/packets/c2s/0x074_group_solicit_res.h"
#include "map/packets/c2s/0x077_group_change2.h"
#include "map/packets/c2s/0x0b5_chat_std.h"
#include "map/packets/c2s/0x104_bazaar_exit.h"
#include "map/packets/c2s/0x105_bazaar_list.h"
#include "map/packets/c2s/0x106_bazaar_buy.h"
#include "map/packets/c2s/0x109_bazaar_open.h"
#include "map/packets/c2s/0x10a_bazaar_itemset.h"
#include "map/packets/c2s/0x10b_bazaar_close.h"
#include "map/packets/c2s/0x0b6_chat_name.h"
#include "map/packets/c2s/0x0c4_group_comlink_active.h"
#include "map/items/item_linkshell.h"
#include "map/items/transactions/item_claim.h"
#include "map/packets/c2s/0x096_combine_ask.h"
#include "map/packets/c2s/0x0e8_camp.h"
#include "map/item_container.h"
#include "map/linkshell.h"
#include "map/items/item.h"
#include "map/packets/c2s/validation.h"
#include "map/party.h"
#include "map/status_effect_container.h"
#include "map/persist_batch.h"
#include "map/enums/party_kind.h"
#include "map/utils/charutils.h"
#include "map/utils/blueutils.h"
#include "map/utils/puppetutils.h"
#include "map/utils/itemutils.h"
#include "map/blue_spell.h"
#include "map/spell.h"
#include "map/utils/moduleutils.h"
#include "map/utils/zoneutils.h"
#include "map/zone.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstring>
#include <ctime>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace
{

// Bot ACCOUNTS start at 21000000 (that is what marks a bot). Bot CHARACTERS use 16000000-16777215: the game client
// treats any id from 0x01000000 (16777216) up as an NPC or monster and will not invite it, so a character id must stay below.
constexpr uint32 BotAccBase     = 21000000;
constexpr uint32 BotCharBase    = 16000000;
constexpr uint32 BotCharEnd     = 0x01000000;
float            g_runYalmsPerSec = 4.0f;  // a player running at normal speed (BotSetRunSpeed; measured against yours by bots.lua)
constexpr auto   StepInterval   = std::chrono::milliseconds(200);
// How often a walking bot sends its position. The zone's own logic tick is 400 ms, far too coarse for a player
// character (a real client sends about ten position packets a second): at that rate a bot jumps 1.6 yalms at a time.
constexpr auto   MoveInterval   = std::chrono::milliseconds(100);

struct Bot
{
    uint32                      charId    = 0;
    uint32                      accId     = 0;
    std::string                 name;          // kept here so Lua can list bots without asking the database
    uint16                      lastZone  = 0;
    std::unique_ptr<MapSession> session;
    bool                        online    = false;
    bool                        zoning    = false; // the server sent "zone out": log in again when it has left the old zone
    timer::time_point           lastStep  = {};
    timer::time_point           zoneSince = {};
    // walking
    std::vector<position_t>     path;
    size_t                      pathIdx   = 0;
    // following an entity
    uint32                      followId  = 0;
    uint16                      followTarg = 0;
    float                       followDist = 3.0f;
    timer::time_point           followRepath = {};
    // a party invite that arrived (answered on the next tick, never from inside the server's own handler)
    bool                        invitePending = false;
    std::string                 inviterName;
    timer::time_point           inviteAt = {};
    float                       moveCounter = 0.0f;
    timer::time_point           retryAt = {};
};

// Never freed on purpose: at server exit the zones are gone before static objects are destroyed, and a bot
// character destroyed that late could touch them. The operating system frees it all anyway.
auto& g_bots = *new std::map<uint32, std::unique_ptr<Bot>>();

// A player's invite to a bot that is in a bot-run party. The standard handler refuses invites to
// anyone already grouped, so the bot leaves first and the invite is delivered again afterwards.
struct PendingPlayerInvite
{
    uint32            playerId = 0;
    PartyKind         kind     = PartyKind::Party;
    timer::time_point at       = {};
    bool              left     = false;
};
auto& g_pendingPlayerInvites = *new std::map<uint32, PendingPlayerInvite>(); // [bot charId]

timer::time_point g_lastGlobalTick = {};
timer::time_point g_lastPlayerSeen = {};
timer::time_point g_lastLuaTick    = {};
timer::time_point g_lastFriendSweep = {};
// the fast position tick for bots that are walking (never cancelled: it lives as long as the map server)
Scheduler::Token* g_moveTimer = nullptr;

// (2026-11-21) gifts: a real player can trade items to a bot player. The bot has no game client to open the trade
// window or press OK, so the module does both: it opens the trade a moment after the request, and accepts when the
// player presses OK. A bot never puts anything in, so it only ever receives.
struct GiftTrade
{
    uint32            bot;
    uint32            player;
    timer::time_point at;
    bool              done; // false: open the window at `at`; true: the player pressed OK, thank them once it closed
};
auto& g_gifts = *new std::vector<GiftTrade>();

auto botOf(uint32 charId) -> Bot*
{
    auto it = g_bots.find(charId);
    return it == g_bots.end() ? nullptr : it->second.get();
}

auto charOf(Bot* b) -> CCharEntity*
{
    return (b && b->session) ? b->session->PChar.get() : nullptr;
}

// Any real player's scheduler (some packet handlers need PSession->scheduler)
auto findScheduler() -> Scheduler*
{
    Scheduler* found = nullptr;
    zoneutils::ForEachZone(
        [&](CZone* PZone)
        {
            if (found)
            {
                return;
            }

            PZone->ForEachChar(
                [&](CCharEntity* PChar)
                {
                    if (!found && PChar->PSession && PChar->PSession->scheduler && !botOf(PChar->id))
                    {
                        found = PChar->PSession->scheduler;
                    }
                });
        });
    return found;
}

// Hands one client packet to the server's own handler, as if the bot's game client had sent it.
template <typename T>
auto inject(Bot* b, T& pkt) -> bool
{
    CCharEntity* PChar = charOf(b);
    if (!PChar)
    {
        return false;
    }

    pkt.header.id   = static_cast<uint16>(T::packetId) & 0x1FF;
    pkt.header.size = static_cast<uint16>(((sizeof(T) + 3) / 4) & 0x7F);

    const auto result = pkt.validate(b->session.get(), PChar);
    if (!result.valid())
    {
        ShowDebugFmt("[bots] {} {} not accepted: {}", PChar->getName(), T::name, result.errorString());
        return false;
    }

    pkt.process(b->session.get(), PChar);
    return true;
}

void drainPackets(Bot* b)
{
    CCharEntity* PChar = charOf(b);
    if (!PChar)
    {
        return;
    }

    // popPacket (not clearPacketList) keeps the server's own bookkeeping right (pending position updates etc.)
    while (!PChar->isPacketListEmpty())
    {
        std::ignore = PChar->popPacket();
    }
}

auto rotationTowards(const position_t& from, const position_t& to) -> uint8
{
    const float angle = std::atan2(-(to.z - from.z), to.x - from.x);
    float       turn  = angle / (2.0f * 3.14159265f);
    if (turn < 0)
    {
        turn += 1.0f;
    }

    return static_cast<uint8>(static_cast<int>(turn * 256.0f) & 0xFF);
}

void sendPosition(Bot* b, const position_t& p, uint8 rotation, bool moving, float dt)
{
    GP_CLI_COMMAND_POS pkt{};
    pkt.x         = p.x;
    pkt.z         = p.y; // the client sends height in the middle (see 0x015_pos.cpp: "Not a typo")
    pkt.y         = p.z;
    pkt.dir       = static_cast<int8_t>(rotation);
    pkt.RunMode   = 1;
    if (CCharEntity* PChar = charOf(b))
    {
        if (moving)
        {
            // Match CPathFind's animation clock (0x35, or 0x28 with a speed
            // change, per logic tick). Keep fractional units at our faster rate.
            const float unitsPerTick = PChar->GetSpeed() != PChar->UpdateSpeed() ? 40.0f : 53.0f;
            const float tickSeconds  = std::chrono::duration<float>(kLogicUpdateInterval).count();
            b->moveCounter = std::fmod(b->moveCounter + unitsPerTick * dt / tickSeconds, 8192.0f);
        }
        pkt.MoveFlame  = moving ? static_cast<uint16>(b->moveCounter) : 0;
        pkt.facetarget = PChar->m_TargID;
    }

    if (inject(b, pkt))
    {
        CCharEntity* PChar = charOf(b);
        if (PChar && PChar->loc.zone && (PChar->updatemask & UPDATE_POS))
        {
            // The normal PostTick broadcast is limited to the zone tick and a
            // 250 ms throttle. Publish each accepted bot step on its 100 ms timer.
            // Use the normal zone broadcaster to preserve visibility/spawn rules.
            PChar->loc.zone->UpdateEntityPacket(PChar, ENTITY_UPDATE, UPDATE_POS);
            // Only position was sent; leave HP, equipment and other updates pending.
            PChar->updatemask &= ~UPDATE_POS;
        }
    }
}

auto planPath(CCharEntity* PChar, const position_t& goal) -> std::vector<position_t>
{
    std::vector<position_t> out;
    CZone*                  PZone = PChar->loc.zone;
    if (!PZone || !PZone->navMesh())
    {
        out.push_back(goal); // no walking map here: straight line
        return out;
    }

    // Both ends are put on walkable ground first: a spot a little off the walking map made the search fail, and
    // the old fallback was a straight line to the goal - through walls, off ledges, across water.
    auto*      nav   = PZone->navMesh();
    position_t start = PChar->loc.p;
    position_t end   = goal;
    if (!nav->validPosition(start))
    {
        if (auto p = nav->findClosestValidPoint(start))
        {
            start = *p;
        }
    }

    if (!nav->validPosition(end))
    {
        if (auto p = nav->findClosestValidPoint(end))
        {
            end = *p;
        }
    }

    bool found = false;
    if (auto result = nav->findPath(start, end, 0.5f, AvoidLinks::No))
    {
        found = true;
        for (const auto& point : result->points)
        {
            // the first points are where it already stands: walking "to" them made it twitch at every new plan
            if (out.empty() && distance(PChar->loc.p, point.position) < 0.4f)
            {
                continue;
            }

            out.push_back(point.position);
        }
    }

    if (!found)
    {
        // no route: as far as the ground allows towards the goal, never through a wall (an empty plan = it stays put)
        if (auto p = nav->findFurthestValidPoint(start, end))
        {
            if (distance(PChar->loc.p, *p) > 0.75f)
            {
                out.push_back(*p);
            }
        }
    }

    return out;
}

void stepMovement(Bot* b, float dt)
{
    CCharEntity* PChar = charOf(b);
    if (!PChar || !PChar->loc.zone || PChar->isDead())
    {
        return;
    }

    // moving cancels a spell: a bot that is casting (a cure on you, say) stands still until the spell is out
    if (PChar->PAI && PChar->PAI->IsCurrentState<CMagicState>())
    {
        return;
    }

    // following: re-plan towards the entity every 1.5 s, stop when close enough
    if (b->followId != 0)
    {
        CBaseEntity* PTarget = PChar->loc.zone->GetEntity(b->followTarg);
        if (!PTarget || PTarget->id != b->followId || PTarget->getZone() != PChar->getZone())
        {
            b->followId = 0;
            b->path.clear();
        }
        else
        {
            const float d = distance(PChar->loc.p, PTarget->loc.p);
            if (d <= b->followDist)
            {
                b->path.clear();
            }
            else if (b->path.empty() && d <= b->followDist + 0.8f)
            {
                // standing, and the one it follows only shifted a little: it does not shuffle after every step
            }
            else if (timer::now() >= b->followRepath)
            {
                // (only on the timer: "or when it has no path" re-planned ten times a second for a bot with no route)
                b->path         = planPath(PChar, PTarget->loc.p);
                b->pathIdx      = 0;
                b->followRepath = timer::now() + std::chrono::milliseconds(1000);
            }
        }
    }

    if (b->path.empty() || b->pathIdx >= b->path.size())
    {
        b->path.clear();
        return;
    }

    float      budget = g_runYalmsPerSec * (PChar->GetSpeed() / 50.0f) * dt;
    position_t pos    = PChar->loc.p;
    uint8      rot    = pos.rotation;
    while (budget > 0 && b->pathIdx < b->path.size())
    {
        const position_t& next = b->path[b->pathIdx];
        const float       d    = distance(pos, next);
        rot                    = rotationTowards(pos, next);
        if (d <= budget)
        {
            pos.x = next.x;
            pos.y = next.y;
            pos.z = next.z;
            budget -= d;
            b->pathIdx++;
        }
        else
        {
            const float f = budget / d;
            pos.x += (next.x - pos.x) * f;
            pos.y += (next.y - pos.y) * f;
            pos.z += (next.z - pos.z) * f;
            budget = 0;
        }

        // following: stop at the follow distance
        if (b->followId != 0)
        {
            if (CBaseEntity* PTarget = PChar->loc.zone->GetEntity(b->followTarg))
            {
                if (distance(pos, PTarget->loc.p) <= b->followDist)
                {
                    b->path.clear();
                    break;
                }
            }
        }
    }

    sendPosition(b, pos, rot, true, dt);
    if (b->pathIdx >= b->path.size())
    {
        b->path.clear();
    }
}

// Walking bots are stepped on their own timer, ten times a second, instead of from the zone logic tick (400 ms).
// The client draws exactly the positions it is sent, so small steps at a client's rate are what makes a bot run.
void stepWalkingBots()
{
    static timer::time_point last = timer::now();
    const auto               now  = timer::now();
    const float              dt   = std::min(0.5f, std::chrono::duration<float>(now - last).count());
    last                          = now;

    for (auto& [id, b] : g_bots)
    {
        if (b->online && !b->zoning && (!b->path.empty() || b->followId != 0))
        {
            stepMovement(b.get(), dt);
        }
    }
}

void upsertSessionRow(Bot* b, CZone* PZone)
{
    // Never delete-then-insert here. accounts_parties has a foreign key on accounts_sessions(charid) with
    // ON DELETE CASCADE, so deleting the session row on every zone change also deleted the bot's party row:
    // after any area change the server no longer found its party and dropped it (bot parties fell apart, a bot
    // that joined you left your party as soon as it zoned, Level Sync was refused). A real client keeps its row.
    //
    // The row also says which map server the character is on (address + port). The world server delivers tells,
    // party and linkshell messages by that. A bot's row had port 0, an address nothing listens on: every /tell to
    // a bot came back "not received", and messages for a party of bots only went nowhere.
    uint8        key[20]{};
    const uint32 ip   = PZone ? PZone->GetIP() : 0;
    const uint16 port = PZone ? PZone->GetPort() : 0;
    db::preparedStmt("INSERT INTO accounts_sessions(accid,charid,session_key,server_addr,server_port,client_addr,version_mismatch) "
                     "VALUES(?,?,?,?,?,?,?) "
                     "ON DUPLICATE KEY UPDATE server_addr = VALUES(server_addr), server_port = VALUES(server_port), version_mismatch = 0",
                     b->accId, b->charId, key, ip, port, 0, 0);
}

// Log in / zone in: the same packets the test framework (and a real client) send.
auto zoneIn(Bot* b) -> bool
{
    auto* scheduler = findScheduler();
    if (!scheduler)
    {
        return false;
    }

    if (!b->session)
    {
        b->session = std::make_unique<MapSession>();
    }

    MapSession* s = b->session.get();
    s->scheduler   = scheduler;
    s->charID      = b->charId;
    s->accountID   = b->accId;
    s->blowfish.status = BLOWFISH_PENDING_ZONE;
    s->PChar.reset();
    s->PChar = charutils::LoadChar(b->charId);
    if (!s->PChar)
    {
        return false;
    }

    CCharEntity* PChar = s->PChar.get();
    PChar->PSession    = s;
    if (zoneutils::GetZone(PChar->loc.destination) == nullptr)
    {
        ShowWarningFmt("[bots] {}: zone {} is not loaded on this map server", PChar->getName(), PChar->loc.destination);
        s->PChar.reset();
        return false;
    }

    upsertSessionRow(b, zoneutils::GetZone(PChar->loc.destination));

    GP_CLI_COMMAND_LOGIN login{};
    login.UniqueNo = b->charId;
    if (!inject(b, login))
    {
        return false;
    }

    GP_CLI_COMMAND_ZONE_TRANSITION transition{};
    transition.unknown00 = 2;
    transition.unknown01 = 0;
    inject(b, transition);

    b->online   = PChar->loc.zone != nullptr;
    b->zoning   = false;
    b->lastStep = timer::now();
    b->path.clear();
    drainPackets(b);
    return b->online;
}

void logout(Bot* b)
{
    CCharEntity* PChar = charOf(b);
    if (PChar && PChar->loc.zone)
    {
        persist::flush(PChar, IsLogout::Yes);
        charutils::SaveCharPosition(PChar);
        PChar->status = xi::Status::Shutdown;
        charutils::removeCharFromZone(PChar); // also drops it from its party
    }

    drainPackets(b);
    db::preparedStmt("DELETE FROM accounts_sessions WHERE charid = ?", b->charId);
    if (b->session)
    {
        b->session->PChar.reset();
    }

    b->online = false;
    b->zoning = false;
    b->path.clear();
    b->followId = 0;
}

void callLua(const char* fn, CCharEntity* PChar, const sol::object& arg)
{
    const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
    if (!xiTable)
    {
        return;
    }

    const sol::optional<sol::table> botsTable = (*xiTable)["bots"].get<sol::optional<sol::table>>();
    if (!botsTable)
    {
        return;
    }

    sol::protected_function f = (*botsTable)[fn];
    if (f.valid())
    {
        auto result = f(CLuaBaseEntity(PChar), arg);
        if (!result.valid())
        {
            sol::error err = result;
            ShowErrorFmt("[bots] xi.bots.{}: {}", fn, err.what());
        }
    }
}

void callLuaPlain(const char* fn)
{
    const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
    if (!xiTable)
    {
        return;
    }

    const sol::optional<sol::table> botsTable = (*xiTable)["bots"].get<sol::optional<sol::table>>();
    if (!botsTable)
    {
        return;
    }

    sol::protected_function f = (*botsTable)[fn];
    if (f.valid())
    {
        auto result = f();
        if (!result.valid())
        {
            sol::error err = result;
            ShowErrorFmt("[bots] xi.bots.{}: {}", fn, err.what());
        }
    }
}

// ---- the friend list's mail: messages in xi_profile's mailboxes (accounts_messages), in PlayOnline's own format ----
// Worked out from four messages two real game clients sent each other on this server (2026-11-18: a friend request
// both ways, the "accepted" answer and a plain message). A row's name is the 72-byte message header in polcore's
// base64; its data is "<title>\x07<text>\0". The game reads a new message when xi_profile sends it the message notice
// (PresenceManager::pollBots does that for mail from bots) or when it logs in. Only the parts the clients filled in
// are set; everything else stays 0, as in theirs.
namespace polmail
{
constexpr uint64 PolIdMask = 0x1C273E4567891133ull; // XORed into both account ids of a header (xi_profile notices.cpp)
constexpr char   Alphabet[] = "TSG8IncW3HFKokOg79qzeCmZs2yBYEQVAUxR5rbwi4P@jMDLtpvad0f_J1hlN6uX";
constexpr uint8  Plain = 0, FriendRequest = 1, FriendAccepted = 9, FriendDeclined = 10;
// the titles the game writes (16 bytes at most: "Friend registration" is cut short in the client's own answer too)
constexpr const char* TitleRequest  = "Let's be friends";
constexpr const char* TitleAccepted = "Friend registrat";
constexpr const char* TitlePlain    = "FINAL FANTASY XI";

// polcore's base64: its own digits, and a short last group padded with its zero digit instead of '='
auto base64(const std::vector<uint8>& in) -> std::string
{
    std::string out;
    for (size_t i = 0; i < in.size(); i += 3)
    {
        const uint32 n = (static_cast<uint32>(in[i]) << 16) | (i + 1 < in.size() ? static_cast<uint32>(in[i + 1]) << 8 : 0u) |
                         (i + 2 < in.size() ? static_cast<uint32>(in[i + 2]) : 0u);
        for (int shift = 18; shift >= 0; shift -= 6)
        {
            out += Alphabet[(n >> shift) & 0x3F];
        }
    }

    return out;
}

void put(std::vector<uint8>& b, size_t at, uint64 value, size_t bytes)
{
    for (size_t i = 0; i < bytes; ++i)
    {
        b[at + i] = static_cast<uint8>(value >> (8 * i));
    }
}

// one stored message: { row name, row data }. summaryOf: the title whose first 15 letters go in the header (a
// client's "accepted" answer keeps the request's title there).
auto make(uint32 fromAcc, const std::string& fromName, uint32 toAcc, uint8 type, const std::string& title, const std::string& text,
          const std::string& summaryOf, uint32 seq, uint32 date) -> std::pair<std::string, std::string>
{
    std::string data = title.substr(0, 16);
    data += '\x07';
    data += text;
    data += '\0';

    std::vector<uint8> h(72, 0);
    put(h, 0, fromAcc ^ PolIdMask, 8);
    put(h, 8, toAcc ^ PolIdMask, 8);
    std::memcpy(h.data() + 16, fromName.data(), std::min<size_t>(fromName.size(), 15));
    std::memcpy(h.data() + 32, summaryOf.data(), std::min<size_t>(summaryOf.size(), 15));
    put(h, 48, seq, 4);
    put(h, 52, date, 4);
    put(h, 56, data.size(), 4);
    put(h, 62, (static_cast<uint64>(type & 0x1F) << 7) | 0x8000, 2);       // DataType 0, Type, Code 0, not online, valid
    put(h, 64, 1, 2);                                                        // ContentsId: FINAL FANTASY XI
    put(h, 66, 0x0002 | (summaryOf.size() > 15 ? 0x1000 : 0), 2);           // Language 1, title longer than its summary
    return { base64(h), data };
}

// (2026-11-22, Sunie: "bots don't recognize auto-translate text") Chat a player types to the bots (tells, party,
// linkshell, shouts) with auto-translate phrases in it arrives as raw bytes (FD 02 02 xx xx FD), which the bots and
// their chat AI read as garbage. The game's own table (autotranslate.cpp, the one squad.cpp uses for party chat) turns
// each phrase into "{ words }"; the braces are taken off, so what reaches Lua is the line as plain text.
auto plainChat(const std::string& raw) -> std::string
{
    if (raw.find('\xFD') == std::string::npos)
    {
        return raw;
    }

    const std::string text = autotranslate::replaceBytes(raw);
    std::string       out;
    out.reserve(text.size());
    for (std::size_t i = 0; i < text.size(); ++i)
    {
        if (text.compare(i, 2, "{ ") == 0)
        {
            // a phrase right after a word or another phrase: keep them apart
            if (!out.empty() && out.back() != ' ')
            {
                out += ' ';
            }

            ++i;
            continue;
        }

        if (text.compare(i, 2, " }") == 0)
        {
            ++i;
            continue;
        }

        out += text[i];
    }

    return out;
}

// the text of a stored message (after the title), printable letters only; auto-translate phrases are left out
auto textOf(const std::string& data) -> std::string
{
    const auto start = data.find('\x07');
    std::string out;
    bool translated = false;
    for (size_t i = start == std::string::npos ? 0 : start + 1; i < data.size() && data[i] != '\0'; ++i)
    {
        const auto c = static_cast<uint8>(data[i]);
        if (c == 0xFD)
        {
            translated = !translated;
        }
        else if (!translated && c >= 0x20 && c < 0x7F)
        {
            out += static_cast<char>(c);
        }
    }

    return out;
}
} // namespace polmail

auto& g_mailSeq = *new std::map<uint32, uint32>(); // [bot account] = its next message number (a client counts per session too)

// a bot's message into a player's mailbox (with the limits a game client meets in xi_profile)
auto postMail(Bot* b, uint32 toAcc, uint8 type, const std::string& title, const std::string& text, const std::string& summaryOf) -> bool
{
    if (auto rset = db::preparedStmt("SELECT COUNT(*) AS messages, COALESCE(SUM(sender_accid = ?), 0) AS mine FROM accounts_messages WHERE accid = ?", b->accId, toAcc);
        !rset || !rset->next() || rset->get<uint32>("messages") >= 100 || rset->get<uint32>("mine") >= 10)
    {
        return false;
    }

    const auto date        = static_cast<uint32>(std::time(nullptr));
    const auto [name, data] = polmail::make(b->accId, b->name, toAcc, type, title, text, summaryOf, g_mailSeq[b->accId]++, date);
    auto rset              = db::preparedStmt("INSERT IGNORE INTO accounts_messages(accid, name, sender_accid, type, data) VALUES(?, ?, ?, ?, ?)",
                                              toAcc, name, b->accId, type, data);
    return rset && rset->rowsAffected() == 1;
}

// a real player's account by character name (0: none)
auto playerAccount(const std::string& name) -> uint32
{
    if (auto rset = db::preparedStmt("SELECT accid FROM chars WHERE charname = ? AND accid < ? LIMIT 1", name, BotAccBase); rset && rset->next())
    {
        return rset->get<uint32>("accid");
    }

    return 0;
}

// the name an account goes by: its character that is on, else its first
auto playerNameOf(uint32 accId) -> std::string
{
    if (auto rset = db::preparedStmt("SELECT c.charname FROM chars c LEFT JOIN accounts_sessions s ON s.charid = c.charid "
                                     "WHERE c.accid = ? ORDER BY s.charid IS NULL, c.charid LIMIT 1",
                                     accId);
        rset && rset->next())
    {
        return rset->get<std::string>("charname");
    }

    return {};
}

// xi.bots.<fn>(bot, info) for the friend list's events
void callBotLua(const char* fn, CCharEntity* PBot, const sol::table& info)
{
    const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
    if (!xiTable)
    {
        return;
    }

    const sol::optional<sol::table> botsTable = (*xiTable)["bots"].get<sol::optional<sol::table>>();
    if (!botsTable)
    {
        return;
    }

    sol::protected_function f = (*botsTable)[fn];
    if (f.valid())
    {
        auto result = f(CLuaBaseEntity(PBot), info);
        if (!result.valid())
        {
            sol::error err = result;
            ShowErrorFmt("[bots] xi.bots.{}: {}", fn, err.what());
        }
    }
}

// a bot's mailbox: what real players sent it (a message, or the answer to its friend request). Read while it is on
// (Lua answers), then deleted, as a game client does. Friend requests are left to sweepFriendRequests.
void sweepBotMail()
{
    struct Mail
    {
        uint32      botAcc;
        std::string name;
        uint32      from;
        uint8       type;
        std::string data;
        uint32      botChar;
    };

    std::vector<Mail> mail;
    if (auto rset = db::preparedStmt("SELECT m.accid, m.name, m.sender_accid, m.type, m.data, c.charid FROM accounts_messages m "
                                     "JOIN chars c ON c.accid = m.accid "
                                     "WHERE m.accid >= ? AND m.sender_accid < ? AND m.type <> 1 LIMIT 50",
                                     BotAccBase, BotAccBase))
    {
        while (rset->next())
        {
            mail.push_back({ rset->get<uint32>("accid"), rset->get<std::string>("name"), rset->get<uint32>("sender_accid"),
                             rset->get<uint8>("type"), rset->getBlobBytes("data"), rset->get<uint32>("charid") });
        }
    }

    for (const auto& m : mail)
    {
        Bot*         b    = botOf(m.botChar);
        CCharEntity* PBot = (b && b->online && !b->zoning) ? charOf(b) : nullptr;
        if (PBot == nullptr)
        {
            continue; // (it reads its mail when it is on)
        }

        const auto from = playerNameOf(m.from);
        auto       info = ::lua.create_table();
        info["from"]    = from;
        if (m.type == polmail::Plain)
        {
            info["text"] = polmail::textOf(m.data);
            ShowInfoFmt("[bots] {} reads a message from {}", b->name, from);
            callBotLua("onMessage", PBot, info);
        }
        else if (m.type == polmail::FriendAccepted || m.type == polmail::FriendDeclined)
        {
            info["accepted"] = m.type == polmail::FriendAccepted;
            ShowInfoFmt("[bots] {} {} {}'s friend request", from, m.type == polmail::FriendAccepted ? "accepted" : "turned down", b->name);
            callBotLua("onFriendReply", PBot, info);
        }

        db::preparedStmt("DELETE FROM accounts_messages WHERE accid = ? AND name = ?", m.botAcc, m.name);
    }
}

// the friend list (served by xi_profile): a real player asked a bot to be friends. The bot answers while it is on
// (xi.bots.onFriendRequest decides: true = accept, false = turn down, nil = not yet, it asks again on a later sweep):
// the player's entry stops being pending and the bot lists the player too, the way xi_profile does it when a client
// accepts. xi_profile shows it to the player within a few seconds (PresenceManager::pollBots).
constexpr uint8 FriendListSize = 200;

void sweepFriendRequests()
{
    // a player took a bot off their friend list: the bot drops them too (as a real player would notice and do).
    // (Only accepted entries: a request the bot sent waits with no entry on the player's side yet.)
    db::preparedStmt("DELETE b FROM accounts_friends b "
                     "LEFT JOIN accounts_friends p ON p.accid = b.friend_accid AND p.blacklist = 0 AND p.friend_accid = b.accid "
                     "WHERE b.accid >= ? AND b.friend_accid < ? AND b.blacklist = 0 AND b.pending = 0 AND p.accid IS NULL",
                     BotAccBase, BotAccBase);

    // messages and answers real players sent to bots
    sweepBotMail();

    struct Request
    {
        uint32 accId;
        uint32 botAcc;
        uint32 botChar;
    };

    std::vector<Request> requests;
    if (auto rset = db::preparedStmt("SELECT f.accid, f.friend_accid, c.charid FROM accounts_friends f JOIN chars c ON c.accid = f.friend_accid "
                                     "WHERE f.blacklist = 0 AND f.pending = 1 AND f.accid < ? AND f.friend_accid >= ? LIMIT 100",
                                     BotAccBase, BotAccBase))
    {
        while (rset->next())
        {
            requests.push_back({ rset->get<uint32>("accid"), rset->get<uint32>("friend_accid"), rset->get<uint32>("charid") });
        }
    }

    for (const auto& r : requests)
    {
        Bot*         b    = botOf(r.botChar);
        CCharEntity* PBot = (b && b->online && !b->zoning) ? charOf(b) : nullptr;
        if (PBot == nullptr)
        {
            continue; // (it answers when it logs in)
        }

        std::string playerName;
        if (auto rset = db::preparedStmt("SELECT c.charname FROM chars c LEFT JOIN accounts_sessions s ON s.charid = c.charid "
                                         "WHERE c.accid = ? ORDER BY s.charid IS NULL, c.charid LIMIT 1",
                                         r.accId);
            rset && rset->next())
        {
            playerName = rset->get<std::string>("charname");
        }

        bool accept = true;
        bool later  = false;
        const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
        if (xiTable)
        {
            const sol::optional<sol::table> botsTable = (*xiTable)["bots"].get<sol::optional<sol::table>>();
            if (botsTable)
            {
                sol::protected_function f = (*botsTable)["onFriendRequest"];
                if (f.valid())
                {
                    auto info    = ::lua.create_table();
                    info["from"] = playerName;
                    auto result  = f(CLuaBaseEntity(PBot), info);
                    if (!result.valid())
                    {
                        sol::error err = result;
                        ShowErrorFmt("[bots] xi.bots.onFriendRequest: {}", err.what());
                    }
                    else if (result.get_type() == sol::type::boolean)
                    {
                        accept = result.get<bool>();
                    }
                    else
                    {
                        later = true; // (nil: it has not made up its mind; the request stays as it is)
                    }
                }
            }
        }

        // the request message the client left in the bot's mailbox is read now (also when it waits: unread
        // messages count against the sender's limit in xi_profile, and only the friend entry needs to wait)
        db::preparedStmt("DELETE FROM accounts_messages WHERE accid = ? AND sender_accid = ? AND type = ?", r.botAcc, r.accId, polmail::FriendRequest);
        if (later)
        {
            continue;
        }

        if (!accept)
        {
            db::preparedStmt("DELETE FROM accounts_friends WHERE accid = ? AND blacklist = 0 AND friend_accid = ? AND pending = 1", r.accId, r.botAcc);
            ShowInfoFmt("[bots] {} turned down a friend request from {}", b->name, playerName);
            continue;
        }

        db::preparedStmt("UPDATE accounts_friends SET pending = 0 WHERE accid = ? AND blacklist = 0 AND friend_accid = ?", r.accId, r.botAcc);

        // its own list: the player (kept if already there, else at its first free place)
        bool listed = false;
        std::vector<bool> used(FriendListSize, false);
        if (auto rset = db::preparedStmt("SELECT list_index, friend_accid FROM accounts_friends WHERE accid = ? AND blacklist = 0", r.botAcc))
        {
            while (rset->next())
            {
                const auto index = rset->get<uint32>("list_index");
                if (index < FriendListSize)
                {
                    used[index] = true;
                }

                listed = listed || rset->get<uint32>("friend_accid") == r.accId;
            }
        }

        if (listed)
        {
            db::preparedStmt("UPDATE accounts_friends SET pending = 0 WHERE accid = ? AND blacklist = 0 AND friend_accid = ?", r.botAcc, r.accId);
        }
        else
        {
            const auto it = std::find(used.begin(), used.end(), false);
            if (it == used.end())
            {
                continue;
            }

            const auto index = static_cast<uint32>(std::distance(used.begin(), it));
            db::preparedStmt("INSERT INTO accounts_friends(accid, blacklist, list_index, friend_accid, display_order, name, pending) VALUES(?, 0, ?, ?, ?, ?, 0)",
                             r.botAcc, index, r.accId, index, playerName.substr(0, 15));
        }

        // and answers the way a game client does: an "accepted" message (the player's list updates at once)
        postMail(b, r.accId, polmail::FriendAccepted, polmail::TitleAccepted, "", polmail::TitleRequest);
        ShowInfoFmt("[bots] {} and {} are now friends", b->name, playerName);
    }
}

void tickBot(Bot* b)
{
    CCharEntity* PChar = charOf(b);

    // zoning: the old zone is done with it -> log in to the new one
    if (b->zoning)
    {
        if (!PChar || PChar->loc.zone == nullptr)
        {
            if (timer::now() - b->zoneSince > std::chrono::milliseconds(500) && timer::now() >= b->retryAt)
            {
                if (!zoneIn(b))
                {
                    b->retryAt = timer::now() + std::chrono::seconds(2); // e.g. you are zoning too: try again
                    if (timer::now() - b->zoneSince > std::chrono::seconds(30))
                    {
                        ShowWarningFmt("[bots] {} could not finish zoning", b->charId);
                        logout(b);
                    }
                }
                else
                {
                    // a new character object in the new zone: its Lua brain (timers) must start again
                    callLua("onZoneIn", charOf(b), sol::lua_nil);
                }
            }
        }

        return;
    }

    if (!PChar || !b->online)
    {
        return;
    }

    // never stay inside an event (a bot has no window to watch a cutscene or pick a menu option)
    if (PChar->isInEvent() && PChar->currentEvent)
    {
        GP_CLI_COMMAND_EVENTEND end{};
        end.UniqueNo  = PChar->currentEvent->targetEntity ? PChar->currentEvent->targetEntity->id : PChar->id;
        end.ActIndex  = PChar->currentEvent->targetEntity ? PChar->currentEvent->targetEntity->targid : PChar->targid;
        end.EventPara = static_cast<uint16>(PChar->currentEvent->eventId);
        end.Mode      = static_cast<uint16>(GP_CLI_COMMAND_EVENTEND_MODE::End);
        end.EndPara   = 0;
        inject(b, end);
    }

    // a player invite held while the bot was in a bot party: leave, then let the normal handler deliver it
    if (const auto held = g_pendingPlayerInvites.find(b->charId); held != g_pendingPlayerInvites.end() && timer::now() >= held->second.at)
    {
        CCharEntity* PPlayer = zoneutils::GetChar(held->second.playerId);
        if (!PPlayer)
        {
            g_pendingPlayerInvites.erase(held);
        }
        else if (!PChar->PParty)
        {
            // Level Sync lingers 30 s after leaving a synced party, and the server refuses to invite anyone who has it
            PChar->StatusEffectContainer->DelStatusEffectSilent(xi::StatusEffect::LevelSync);
            GP_CLI_COMMAND_GROUP_SOLICIT_REQ req{};
            req.UniqueNo = b->charId;
            req.ActIndex = PChar->loc.zone == PPlayer->loc.zone ? PChar->targid : 0;
            req.Kind     = held->second.kind;
            req.process(PPlayer->PSession, PPlayer);
            g_pendingPlayerInvites.erase(held);
        }
        else if (!held->second.left)
        {
            GP_CLI_COMMAND_GROUP_LEAVE leave{};
            leave.Kind = PartyKind::Party;
            if (!inject(b, leave))
            {
                ShowInfoFmt("[bots] {} could not leave its party for {}'s invite", PChar->getName(), PPlayer->getName());
                g_pendingPlayerInvites.erase(held);
            }
            else
            {
                held->second.left = true;
                held->second.at   = timer::now() + std::chrono::milliseconds(1200);
            }
        }
        else
        {
            ShowInfoFmt("[bots] {} is still in a party; {}'s invite was dropped", PChar->getName(), PPlayer->getName());
            g_pendingPlayerInvites.erase(held);
        }
    }

    // a party invite: ask Lua (xi.bots.onInvite), or accept after a short pause
    if (b->invitePending && timer::now() >= b->inviteAt)
    {
        b->invitePending = false;
        const sol::optional<sol::table> xiTable = ::lua["xi"].get<sol::optional<sol::table>>();
        bool handled = false;
        if (xiTable)
        {
            const sol::optional<sol::table> botsTable = (*xiTable)["bots"].get<sol::optional<sol::table>>();
            if (botsTable)
            {
                sol::protected_function f = (*botsTable)["onInvite"];
                handled                   = f.valid();
            }
        }

        if (handled)
        {
            callLua("onInvite", PChar, sol::make_object(::lua, b->inviterName));
        }
        else if (PChar->InvitePending.entity.UniqueNo != 0)
        {
            GP_CLI_COMMAND_GROUP_SOLICIT_RES res{};
            res.Res = static_cast<uint8_t>(GP_CLI_COMMAND_GROUP_SOLICIT_RES_RES::Accept);
            inject(b, res);
        }
    }

    // movement is not stepped here: stepWalkingBots() runs it on its own, faster timer
    drainPackets(b);
}

auto targetOf(const sol::object& o) -> CBaseEntity*
{
    if (o.is<CLuaBaseEntity*>())
    {
        if (auto* e = o.as<CLuaBaseEntity*>())
        {
            return e->GetBaseEntity();
        }
    }

    return nullptr;
}

auto action(uint32 charId, GP_CLI_COMMAND_ACTION_ACTIONID id, CBaseEntity* PTarget, uint32 param) -> bool
{
    Bot*         b     = botOf(charId);
    CCharEntity* PChar = charOf(b);
    if (!PChar || !b->online)
    {
        return false;
    }

    // a resting bot stands up first: the server refuses every action from someone who is /healing
    // ("Invalid state: Healing"), which left bots sitting next to a monster they believed they were fighting
    if (PChar->animation == xi::Animation::Healing && id != GP_CLI_COMMAND_ACTION_ACTIONID::HomepointMenu)
    {
        GP_CLI_COMMAND_CAMP camp{};
        camp.Mode = static_cast<uint32_t>(GP_CLI_COMMAND_CAMP_MODE::Off);
        inject(b, camp);
    }

    GP_CLI_COMMAND_ACTION pkt{};
    pkt.UniqueNo = PTarget ? PTarget->id : PChar->id;
    pkt.ActIndex = PTarget ? PTarget->targid : PChar->targid;
    pkt.ActionID = id;
    switch (id)
    {
        case GP_CLI_COMMAND_ACTION_ACTIONID::CastMagic:
            pkt.CastMagic.SpellId = param;
            break;
        case GP_CLI_COMMAND_ACTION_ACTIONID::Weaponskill:
            pkt.Weaponskill.SkillId = param;
            break;
        case GP_CLI_COMMAND_ACTION_ACTIONID::JobAbility:
            pkt.JobAbility.SkillId = param;
            break;
        default:
            break;
    }

    return inject(b, pkt);
}

auto validName(const std::string& name) -> bool
{
    if (name.size() < 3 || name.size() > 15 || !std::isupper(static_cast<unsigned char>(name[0])))
    {
        return false;
    }

    for (char c : name)
    {
        if (!std::isalpha(static_cast<unsigned char>(c)))
        {
            return false;
        }
    }

    return true;
}

enum class IdSpace
{
    Account,
    Character,
};

// The database layer only accepts queries written out at compile time now, so the id space is chosen here
// instead of building the query from a table name.
auto nextId(const IdSpace space, uint32 base, uint32 end) -> uint32
{
    uint32 id   = base;
    auto   rset = space == IdSpace::Account
                    ? db::preparedStmt("SELECT MAX(id) AS m FROM accounts WHERE id >= ? AND id < ?", base, end)
                    : db::preparedStmt("SELECT MAX(charid) AS m FROM chars WHERE charid >= ? AND charid < ?", base, end);
    if (rset && rset->rowsCount() > 0 && rset->next() && !rset->isNull("m"))
    {
        id = std::max(base, rset->get<uint32>("m") + 1);
    }

    return id;
}

} // namespace

class BotsModule : public CPPModule
{
    void OnInit() override
    {
        // Sessions of an earlier server run are gone: clear their rows so /sea does not list ghosts
        db::preparedStmt("DELETE FROM accounts_sessions WHERE accid >= ?", BotAccBase);
        // The one-off migration of first-version bot ids is retired: it rewrote every table holding a charid,
        // which needs a query built at runtime, and the database layer now only accepts compile-time queries.
        // Every bot made since already lives in the new id range.

        // (2026-11-18, Reika) a PLAYER account made after the bots (a dual box account, from the setup script or the
        // game's own "create account") got the next id after the last bot, so it was loaded below as a bot and played
        // while its owner was away. Bot accounts are named bot_<id>; anything else in the bot range moves below it.
        if (auto rset = db::preparedStmt("SELECT id, login FROM accounts WHERE id >= ? AND login NOT LIKE 'bot\\_%' AND password <> '!bot-account-no-login!'", BotAccBase))
        {
            std::vector<uint32> misplaced;
            while (rset->next())
            {
                misplaced.push_back(rset->get<uint32>("id"));
            }

            for (const uint32 oldId : misplaced)
            {
                uint32 newId = 1000;
                if (auto top = db::preparedStmt("SELECT COALESCE(MAX(id), 999) AS m FROM accounts WHERE id < ?", BotAccBase); top && top->next())
                {
                    newId = std::max<uint32>(1000, top->get<uint32>("m") + 1);
                }

                // a copy of the account under the new id first (other tables point at accounts.id with foreign keys), then
                // the rows that belong to it, then the old row (whatever still points at it goes with it: login tokens)
                db::preparedStmt("DELETE FROM accounts_sessions WHERE accid = ?", oldId);
                if (!db::preparedStmt("INSERT INTO accounts (id, login, password, current_email, registration_email, timecreate, timelastmodify, "
                                      "content_ids, expansions, features, status, priv) SELECT ?, login, password, current_email, registration_email, "
                                      "timecreate, timelastmodify, content_ids, expansions, features, status, priv FROM accounts WHERE id = ?",
                                      newId, oldId))
                {
                    ShowWarningFmt("[bots] player account {} is in the bot id range and could not be moved", oldId);
                    continue;
                }
                db::preparedStmt("UPDATE chars SET accid = ? WHERE accid = ?", newId, oldId);
                db::preparedStmt("UPDATE accounts_friends SET accid = ? WHERE accid = ?", newId, oldId);
                db::preparedStmt("UPDATE accounts_friends SET friend_accid = ? WHERE friend_accid = ?", newId, oldId);
                db::preparedStmt("UPDATE accounts_messages SET accid = ? WHERE accid = ?", newId, oldId);
                db::preparedStmt("UPDATE accounts_messages SET sender_accid = ? WHERE sender_accid = ?", newId, oldId);
                db::preparedStmt("UPDATE accounts_banned SET accid = ? WHERE accid = ?", newId, oldId);
                db::preparedStmt("DELETE FROM accounts WHERE id = ?", oldId);
                ShowWarningFmt("[bots] player account {} was in the bot id range; moved to id {} (it is no longer played as a bot)", oldId, newId);
            }
        }

        // Every bot account/character this module ever made
        if (auto rset = db::preparedStmt("SELECT c.charid, c.accid, c.charname, c.pos_zone FROM chars c WHERE c.accid >= ?", BotAccBase))
        {
            while (rset->next())
            {
                auto b      = std::make_unique<Bot>();
                b->charId   = rset->get<uint32>("charid");
                b->accId    = rset->get<uint32>("accid");
                b->name     = rset->get<std::string>("charname");
                b->lastZone = rset->get<uint16>("pos_zone");
                g_bots[b->charId] = std::move(b);
            }
        }

        ShowInfoFmt("[bots] {} bot character(s) known", g_bots.size());

        ::lua.set_function("BotCreate",
                           [](const std::string& name, uint8 race, uint8 face, uint8 job, uint8 nation, uint16 zone, float x, float y, float z) -> std::tuple<uint32, std::string>
                           {
                               if (!validName(name))
                               {
                                   return { 0, "name must be 3-15 letters, starting with a capital" };
                               }

                               auto taken = db::preparedStmt("SELECT charid, accid FROM chars WHERE charname = ? LIMIT 1", name);
                               if (taken && taken->rowsCount() > 0 && taken->next())
                               {
                                   const uint32 oldChar = taken->get<uint32>("charid");
                                   const uint32 oldAcc  = taken->get<uint32>("accid");
                                   if (oldAcc < BotAccBase || (botOf(oldChar) && botOf(oldChar)->online))
                                   {
                                       return { 0, "that name is taken" };
                                   }

                                   // a bot of ours with that name (e.g. left half-made by an earlier attempt): remove it and make it again.
                                   // Deleting the account removes the character and all its rows (database triggers account_delete/char_delete).
                                   db::preparedStmt("DELETE FROM accounts_sessions WHERE charid = ?", oldChar);
                                   db::preparedStmt("DELETE FROM accounts WHERE id = ?", oldAcc);
                                   db::preparedStmt("DELETE FROM chars WHERE charid = ?", oldChar);
                                   g_bots.erase(oldChar);
                               }

                               const uint32 accId  = nextId(IdSpace::Account, BotAccBase, 0xFFFFFFFF);
                               const uint32 charId = nextId(IdSpace::Character, BotCharBase, BotCharEnd);
                               if (!db::preparedStmt("INSERT INTO accounts (id, login, password) VALUES (?, ?, ?)", accId, fmt::format("bot_{}", accId), "!bot-account-no-login!"))
                               {
                                   return { 0, "could not create the account" };
                               }

                               // the same rows the login server writes for a new character (login_helpers.cpp saveCharacter)
                               bool ok = db::preparedStmt("INSERT INTO chars(charid,accid,charname,pos_zone,nation,pos_x,pos_y,pos_z,playtime) VALUES(?,?,?,?,?,?,?,?,60)",
                                                          charId, accId, name, zone, nation, x, y, z) != nullptr;
                               ok = ok && db::preparedStmt("INSERT INTO char_look(charid,face,race,size) VALUES(?,?,?,?)", charId, face, race, 0) != nullptr;
                               ok = ok && db::preparedStmt("INSERT INTO char_stats(charid,mjob) VALUES(?,?)", charId, job) != nullptr;
                               // (database triggers may already have made some of these rows: same "ON DUPLICATE KEY" as the login server)
                               ok = ok && db::preparedStmt("INSERT INTO char_exp(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charId) != nullptr;
                               ok = ok && db::preparedStmt("INSERT INTO char_jobs(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charId) != nullptr;
                               ok = ok && db::preparedStmt("INSERT INTO char_points(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charId) != nullptr;
                               ok = ok && db::preparedStmt("INSERT INTO char_unlocks(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charId) != nullptr;
                               ok = ok && db::preparedStmt("INSERT INTO char_profile(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charId) != nullptr;
                               ok = ok && db::preparedStmt("INSERT INTO char_storage(charid) VALUES(?) ON DUPLICATE KEY UPDATE charid = charid", charId) != nullptr;

                               ok = ok && db::preparedStmt("INSERT INTO char_flags(charid) VALUES(?) ON DUPLICATE KEY UPDATE disconnecting = disconnecting", charId) != nullptr;
                               ok = ok && db::preparedStmt("DELETE FROM char_inventory WHERE charid = ?", charId) != nullptr;
                               ok = ok && db::preparedStmt("INSERT INTO char_inventory(charid) VALUES(?)", charId) != nullptr;

                               // NEW_ADVENTURER title: not a "first login", so no opening cutscene (as the test framework does)
                               uint8 titles[sizeof(CCharEntity::m_TitleList)]{};
                               addBit(206, titles, sizeof(titles));
                               ok = ok && db::preparedStmt("UPDATE chars SET titles = ? WHERE charid = ?", titles, charId) != nullptr;
                               if (!ok)
                               {
                                   // take the half-made bot away again (the triggers remove its rows)
                                   db::preparedStmt("DELETE FROM accounts WHERE id = ?", accId);
                                   db::preparedStmt("DELETE FROM chars WHERE charid = ?", charId);
                                   return { 0, "could not create the character (see the map server log)" };
                               }

                               auto b      = std::make_unique<Bot>();
                               b->charId   = charId;
                               b->accId    = accId;
                               b->name     = name;
                               b->lastZone = zone;
                               g_bots[charId] = std::move(b);
                               return { charId, "created" };
                           });

        ::lua.set_function("BotLogin",
                           [](uint32 charId) -> std::tuple<bool, std::string>
                           {
                               Bot* b = botOf(charId);
                               if (!b)
                               {
                                   return { false, "not a bot" };
                               }

                               if (b->online)
                               {
                                   return { true, "already online" };
                               }

                               if (!findScheduler())
                               {
                                   return { false, "a real player must be online" };
                               }

                               if (!zoneIn(b))
                               {
                                   logout(b);
                                   return { false, "log in failed (see the map server log)" };
                               }

                               callLua("onLogin", charOf(b), sol::lua_nil);
                               return { true, "logged in" };
                           });

        ::lua.set_function("BotLogout", [](uint32 charId)
                           {
                               if (Bot* b = botOf(charId); b && (b->online || b->zoning))
                               {
                                   logout(b);
                               }
                           });

        ::lua.set_function("BotIsBot", [](uint32 charId) -> bool
                           { return botOf(charId) != nullptr; });

        ::lua.set_function("BotList", []() -> sol::table
                           {
                               auto t = ::lua.create_table();
                               for (auto& [id, b] : g_bots)
                               {
                                   auto row      = ::lua.create_table();
                                   row["online"] = b->online || b->zoning;
                                   row["name"]   = b->name;
                                   if (CCharEntity* PChar = charOf(b.get()); PChar && b->online && PChar->loc.zone)
                                   {
                                       b->lastZone = static_cast<uint16>(PChar->getZone());
                                   }

                                   row["zone"] = b->lastZone;
                                   t[id]       = row;
                               }

                               return t;
                           });

        // cheap checks for the brains (called every second per bot)
        ::lua.set_function("BotIsOnline", [](uint32 charId) -> bool
                           {
                               Bot* b = botOf(charId);
                               return b && b->online && !b->zoning;
                           });

        ::lua.set_function("BotPlayerOnline", []() -> bool
                           { return findScheduler() != nullptr; });

        // /heal on or off (resting at a Home Point)
        ::lua.set_function("BotHeal", [](uint32 charId, bool on) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online || PChar->isDead() || PChar->PAI->IsEngaged())
                               {
                                   return false;
                               }

                               const bool healing = PChar->animation == xi::Animation::Healing;
                               if (healing == on)
                               {
                                   return true;
                               }

                               if (on)
                               {
                                   b->path.clear();
                                   b->followId = 0;
                               }

                               GP_CLI_COMMAND_CAMP pkt{};
                               pkt.Mode = static_cast<uint32_t>(on ? GP_CLI_COMMAND_CAMP_MODE::On : GP_CLI_COMMAND_CAMP_MODE::Off);
                               return inject(b, pkt);
                           });

        // an emote (/wave, /bow ...): number = xi.emote.X, mode = xi.emoteMode.X
        ::lua.set_function("BotEmote", [](uint32 charId, const sol::object& target, uint8 number, uint8 mode) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online)
                               {
                                   return false;
                               }

                               CBaseEntity* PTarget = targetOf(target);
                               if (!PTarget || PTarget->loc.zone != PChar->loc.zone)
                               {
                                   PTarget = PChar;
                               }

                               GP_CLI_COMMAND_MOTION pkt{};
                               pkt.UniqueNo = PTarget->id;
                               pkt.ActIndex = PTarget->targid;
                               pkt.Number   = number;
                               pkt.Mode     = mode;
                               return inject(b, pkt);
                           });

        // where an OFFLINE bot will be at its next log in
        ::lua.set_function("BotPlace", [](uint32 charId, uint16 zone, float x, float y, float z, uint8 rot) -> bool
                           {
                               Bot* b = botOf(charId);
                               if (!b || b->online || b->zoning)
                               {
                                   return false;
                               }

                               b->lastZone = zone;
                               return db::preparedStmt("UPDATE chars SET pos_zone = ?, pos_prevzone = ?, pos_x = ?, pos_y = ?, pos_z = ?, pos_rot = ? WHERE charid = ?",
                                                       zone, zone, x, y, z, rot, charId) != nullptr;
                           });

        ::lua.set_function("BotMoveTo", [](uint32 charId, float x, float y, float z) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online)
                               {
                                   return false;
                               }

                               b->followId = 0;
                               b->path     = planPath(PChar, position_t(x, y, z, 0, 0));
                               b->pathIdx  = 0;
                               return !b->path.empty(); // (false: no way there, or it already stands there)
                           });

        ::lua.set_function("BotFollow", [](uint32 charId, const sol::object& target, sol::optional<float> dist) -> bool
                           {
                               Bot*         b       = botOf(charId);
                               CCharEntity* PChar   = charOf(b);
                               CBaseEntity* PTarget = targetOf(target);
                               if (!PChar || !PTarget)
                               {
                                   return false;
                               }

                               // Already following this one: only the distance may change. The brains call this every
                               // second, and planning a new path each time restarted the walk each second (the jerky
                               // running); the movement tick re-plans on its own timer.
                               if (b->followId == PTarget->id && b->followTarg == PTarget->targid && PTarget->loc.zone == PChar->loc.zone)
                               {
                                   b->followDist = dist.value_or(3.0f);
                                   return true;
                               }

                               b->followId   = PTarget->id;
                               b->followTarg = PTarget->targid;
                               b->followDist = dist.value_or(3.0f);
                               b->followRepath = {};
                               // plan the first leg now: the movement tick only visits bots that have a path
                               if (PTarget->loc.zone == PChar->loc.zone)
                               {
                                   b->path         = planPath(PChar, PTarget->loc.p);
                                   b->pathIdx      = 0;
                                   b->followRepath = timer::now() + std::chrono::milliseconds(1500);
                               }
                               else
                               {
                                   b->path.clear();
                               }
                               return true;
                           });

        ::lua.set_function("BotStop", [](uint32 charId)
                           {
                               if (Bot* b = botOf(charId))
                               {
                                   b->followId = 0;
                                   b->path.clear();
                               }
                           });

        ::lua.set_function("BotIsMoving", [](uint32 charId) -> bool
                           {
                               Bot* b = botOf(charId);
                               return b && !b->path.empty();
                           });

        ::lua.set_function("BotAttack", [](uint32 charId, const sol::object& target) -> bool
                           { return action(charId, GP_CLI_COMMAND_ACTION_ACTIONID::Attack, targetOf(target), 0); });

        ::lua.set_function("BotAttackOff", [](uint32 charId) -> bool
                           { return action(charId, GP_CLI_COMMAND_ACTION_ACTIONID::AttackOff, nullptr, 0); });

        // A spell is interrupted when the caster "started moving" (CMagicState reads m_lastMoveDistance, which only a
        // position packet updates). A bot sends position packets only while it walks, so after it stopped the last
        // step's distance stayed there and every spell it began was interrupted at once, even standing still
        // (ChazDingle, delukard). It is standing (stepMovement stops it while it casts), so that distance is 0 now.
        ::lua.set_function("BotCast", [](uint32 charId, uint32 spellId, const sol::object& target) -> bool
                           {
                               if (CCharEntity* PChar = charOf(botOf(charId)))
                               {
                                   PChar->m_lastMoveDistance = 0.0f;
                               }

                               return action(charId, GP_CLI_COMMAND_ACTION_ACTIONID::CastMagic, targetOf(target), spellId);
                           });

        // a ranged attack (bow, gun, crossbow, throwing), the same packet as /shoot (bots_party.lua: RNG / COR / pullers)
        ::lua.set_function("BotShoot", [](uint32 charId, const sol::object& target) -> bool
                           { return action(charId, GP_CLI_COMMAND_ACTION_ACTIONID::Shoot, targetOf(target), 0); });

        ::lua.set_function("BotWeaponSkill", [](uint32 charId, uint32 wsId, const sol::object& target) -> bool
                           { return action(charId, GP_CLI_COMMAND_ACTION_ACTIONID::Weaponskill, targetOf(target), wsId); });

        ::lua.set_function("BotAbility", [](uint32 charId, uint32 abilityId, const sol::object& target) -> bool
                           {
                               // job profile lines say "target: self" for Provoke and the like (the squad's trust AI aims those
                               // at its battle target by itself); a bot sent them at itself and the server refused, so WAR bots
                               // never provoked (2026-11-18). An enemy-only ability goes to the monster it is fighting.
                               CBaseEntity* PTarget = targetOf(target);
                               if (CAbility* PAbility = ability::GetAbility(static_cast<uint16>(abilityId)))
                               {
                                   const uint16 valid = PAbility->getValidTarget();
                                   if ((valid & TARGET_ENEMY) && !(valid & TARGET_SELF) && (!PTarget || PTarget->objtype != TYPE_MOB))
                                   {
                                       CCharEntity* PChar = charOf(botOf(charId));
                                       PTarget = PChar ? PChar->GetBattleTarget() : nullptr;
                                       if (!PTarget)
                                       {
                                           return false;
                                       }
                                   }
                               }
                               return action(charId, GP_CLI_COMMAND_ACTION_ACTIONID::JobAbility, PTarget, abilityId);
                           });

        // A Blue Mage bot sets its blue magic (what the client's "Set Spells" menu does: 0x102): every set spell is
        // taken off, then the spells in `wanted` (blue spell ids, the bot's preference first) go into the free slots
        // while it has the slots and set points for them, and only ones it knows and is high enough for.
        // Returns how many are set. (2026-11-17)
        // A Puppetmaster bot fits its automaton (what the client's attachment menu does: 0x102): every attachment is
        // taken off, then the item ids in `wanted` (preference first) are unlocked and fitted while there are free
        // slots, up to `count`. The game's own check refuses one that the head and frame have no element capacity
        // left for, so those are just skipped. Returns how many are fitted. (2026-11-17)
        ::lua.set_function("BotSetAttachments", [](uint32 charId, const sol::table& wanted, uint8 count) -> int
                           {
                               CCharEntity* PChar = charOf(botOf(charId));
                               if (!PChar || (PChar->GetMJob() != xi::Job::PUP && PChar->GetSJob() != xi::Job::PUP))
                               {
                                   return 0;
                               }

                               for (uint8 i = 0; i < 12; ++i)
                               {
                                   if (PChar->getAutomatonAttachment(i) != 0)
                                   {
                                       puppetutils::setAttachment(PChar, i, 0);
                                   }
                               }

                               uint8 slot = 0;
                               for (const auto& kv : wanted)
                               {
                                   if (slot >= 12 || slot >= count)
                                   {
                                       break;
                                   }

                                   const auto itemId = kv.second.as<uint32>();
                                   if (itemId <= 0x2100 || itemId > 0x21FF)
                                   {
                                       continue;
                                   }

                                   const CItem* PItem = xi::items::lookup(static_cast<uint16>(itemId));
                                   if (!PItem)
                                   {
                                       continue;
                                   }

                                   if (!puppetutils::HasAttachment(PChar, PItem))
                                   {
                                       puppetutils::UnlockAttachment(PChar, PItem);
                                   }

                                   puppetutils::setAttachment(PChar, slot, static_cast<uint8>(itemId - 0x2100));
                                   if (PChar->getAutomatonAttachment(slot) == static_cast<uint8>(itemId - 0x2100))
                                   {
                                       ++slot;
                                   }
                               }

                               puppetutils::SaveAutomaton(PChar);
                               return slot;
                           });

        ::lua.set_function("BotSetBlueSpells", [](uint32 charId, const sol::table& wanted) -> int
                           {
                               CCharEntity* PChar = charOf(botOf(charId));
                               if (!PChar || (PChar->GetMJob() != xi::Job::BLU && PChar->GetSJob() != xi::Job::BLU))
                               {
                                   return 0;
                               }

                               for (uint8 i = 0; i < 20; ++i)
                               {
                                   if (PChar->m_SetBlueSpells[i] != 0)
                                   {
                                       auto* POld = static_cast<CBlueSpell*>(spell::GetSpell(static_cast<SpellID>(PChar->m_SetBlueSpells[i] + 0x200)));
                                       if (POld)
                                       {
                                           blueutils::SetBlueSpell(PChar, POld, i, false);
                                       }
                                   }
                               }

                               const uint8 slots  = blueutils::GetTotalSlots(PChar);
                               const uint8 mLevel = PChar->m_LevelRestriction != 0 && PChar->m_LevelRestriction < PChar->GetMLevel() ? PChar->m_LevelRestriction : PChar->GetMLevel();
                               const uint8 sLevel = PChar->GetSLevel();
                               uint8       slot   = 0;
                               int         set    = 0;
                               for (const auto& kv : wanted)
                               {
                                   if (slot >= slots)
                                   {
                                       break;
                                   }

                                   const auto id = kv.second.as<uint32>();
                                   if (id < 0x200 || id >= 0x300 || !charutils::hasSpell(PChar, static_cast<uint16>(id)))
                                   {
                                       continue;
                                   }

                                   auto* PSpell = dynamic_cast<CBlueSpell*>(spell::GetSpell(static_cast<SpellID>(id)));
                                   if (!PSpell)
                                   {
                                       continue;
                                   }

                                   const bool mainOk = PChar->GetMJob() == xi::Job::BLU && mLevel >= PSpell->getJob(xi::Job::BLU);
                                   const bool subOk  = PChar->GetSJob() == xi::Job::BLU && sLevel >= PSpell->getJob(xi::Job::BLU);
                                   if (!mainOk && !subOk)
                                   {
                                       continue;
                                   }

                                   blueutils::SetBlueSpell(PChar, PSpell, slot, true);
                                   if (PChar->m_SetBlueSpells[slot] != 0)
                                   {
                                       ++slot;
                                       ++set;
                                   }
                               }

                               charutils::BuildingCharTraitsTable(PChar);
                               PChar->UpdateHealth();
                               return set;
                           });

        // its inventory: { { slot, id, qty, stack, ah }, ... } (ah = may go on the auction house)
        ::lua.set_function("BotInventory", [](uint32 charId) -> sol::table
                           {
                               auto         t     = ::lua.create_table();
                               CCharEntity* PChar = charOf(botOf(charId));
                               if (!PChar)
                               {
                                   return t;
                               }

                               CItemContainer* inv = PChar->getStorage(LOC_INVENTORY);
                               for (uint8 slot = 1; slot <= inv->GetSize(); ++slot)
                               {
                                   CItem* PItem = inv->GetItem(slot);
                                   if (!PItem || PItem->getID() == 0 || PItem->getID() == 0xFFFF)
                                   {
                                       continue;
                                   }

                                   auto row     = ::lua.create_table();
                                   row["slot"]  = slot;
                                   row["id"]    = PItem->getID();
                                   row["qty"]   = PItem->getQuantity();
                                   row["stack"] = PItem->getStackSize();
                                   row["ah"]    = !PItem->hasFlag(xi::ItemFlag::NoAuction) && !PItem->isBusy();
                                   t.add(row);
                               }

                               return t;
                           });

        // a synthesis: crystal + up to 8 ingredient item ids (from its inventory), the same packet the client sends
        ::lua.set_function("BotSynth", [](uint32 charId, uint16 crystal, const sol::table& ingredients) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online)
                               {
                                   return false;
                               }

                               CItemContainer* inv = PChar->getStorage(LOC_INVENTORY);
                               std::map<uint8, uint32> used;
                               auto findSlot = [&](uint16 itemId) -> int
                               {
                                   for (uint8 slot = 1; slot <= inv->GetSize(); ++slot)
                                   {
                                       CItem* PItem = inv->GetItem(slot);
                                       if (PItem && PItem->getID() == itemId && !PItem->isBusy() && used[slot] < PItem->getQuantity())
                                       {
                                           used[slot]++;
                                           return slot;
                                       }
                                   }

                                   return -1;
                               };

                               GP_CLI_COMMAND_COMBINE_ASK pkt{};
                               const int crystalSlot = findSlot(crystal);
                               if (crystalSlot < 0)
                               {
                                   return false;
                               }

                               pkt.Crystal    = crystal;
                               pkt.CrystalIdx = static_cast<uint8_t>(crystalSlot);
                               uint8 n        = 0;
                               for (const auto& kv : ingredients)
                               {
                                   const sol::object& value = kv.second;
                                   if (n >= 8 || !value.is<uint16>())
                                   {
                                       break;
                                   }

                                   const uint16 itemId = value.as<uint16>();
                                   const int    slot   = findSlot(itemId);
                                   if (slot < 0)
                                   {
                                       return false;
                                   }

                                   pkt.ItemNo[n]  = itemId;
                                   pkt.TableNo[n] = static_cast<uint8_t>(slot);
                                   n++;
                               }

                               if (n == 0)
                               {
                                   return false;
                               }

                               pkt.Items = n;
                               return inject(b, pkt);
                           });

        // trade one item to an NPC (a HELM point: the tool), the same packet the client sends
        ::lua.set_function("BotTrade", [](uint32 charId, const sol::object& npc, uint16 itemId, uint32 qty) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               CBaseEntity* PNpc  = targetOf(npc);
                               if (!PChar || !b->online || !PNpc)
                               {
                                   return false;
                               }

                               CItemContainer* inv = PChar->getStorage(LOC_INVENTORY);
                               for (uint8 slot = 1; slot <= inv->GetSize(); ++slot)
                               {
                                   CItem* PItem = inv->GetItem(slot);
                                   if (PItem && PItem->getID() == itemId && !PItem->isBusy() && PItem->getQuantity() >= qty)
                                   {
                                       GP_CLI_COMMAND_ITEM_TRANSFER pkt{};
                                       pkt.UniqueNo                = PNpc->id;
                                       pkt.ActIndex                = PNpc->targid;
                                       pkt.ItemNum                 = 1;
                                       pkt.ItemNumTbl[0]           = qty;
                                       pkt.PropertyItemIndexTbl[0] = slot;
                                       return inject(b, pkt);
                                   }
                               }

                               return false;
                           });

        // auction house: put an item up (single, or a full stack), the same packet the client sends (towns only)
        ::lua.set_function("BotAucSell", [](uint32 charId, uint16 itemId, uint32 price, bool stack) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online || price == 0)
                               {
                                   return false;
                               }

                               uint32 listed = 0;
                               if (auto rset = db::preparedStmt("SELECT COUNT(*) AS n FROM auction_house WHERE seller = ? AND sale = 0", PChar->id); rset && rset->next())
                               {
                                   listed = rset->get<uint32>("n");
                               }

                               CItemContainer* inv = PChar->getStorage(LOC_INVENTORY);
                               for (uint8 slot = 1; slot <= inv->GetSize(); ++slot)
                               {
                                   CItem* PItem = inv->GetItem(slot);
                                   if (!PItem || PItem->getID() != itemId || PItem->isBusy())
                                   {
                                       continue;
                                   }

                                   if (stack && (PItem->getStackSize() <= 1 || PItem->getQuantity() != PItem->getStackSize()))
                                   {
                                       continue;
                                   }

                                   GP_CLI_COMMAND_AUC pkt{};
                                   pkt.Command                   = GP_CLI_COMMAND_AUC_COMMAND::LotIn;
                                   pkt.AucWorkIndex              = static_cast<int8_t>(std::min<uint32>(listed, 6));
                                   pkt.Param.LotIn.LimitPrice    = price;
                                   pkt.Param.LotIn.ItemWorkIndex = slot;
                                   pkt.Param.LotIn.ItemStacks    = stack ? 0 : 1;
                                   return inject(b, pkt);
                               }

                               return false;
                           });

        // auction house: buy the cheapest listing of an item at or below a price (single or stack)
        ::lua.set_function("BotAucBuy", [](uint32 charId, uint16 itemId, uint32 price, bool stack) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online || price == 0)
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_AUC pkt{};
                               pkt.Command              = GP_CLI_COMMAND_AUC_COMMAND::Bid;
                               pkt.AucWorkIndex         = 0;
                               pkt.Param.Bid.BidPrice   = price;
                               pkt.Param.Bid.ItemNo     = itemId;
                               pkt.Param.Bid.ItemStacks = stack ? 0 : 1;
                               return inject(b, pkt);
                           });

        // auction house: what is for sale right now (not its own), newest first: { { id, stack, price, seller }, ... }
        ::lua.set_function("BotAucListings", [](uint32 charId, uint32 limit) -> sol::table
                           {
                               auto t = ::lua.create_table();
                               if (auto rset = db::preparedStmt("SELECT itemid, stack, price, seller FROM auction_house WHERE sale = 0 AND seller != ? ORDER BY date DESC LIMIT ?",
                                                                charId, std::min<uint32>(limit, 500)))
                               {
                                   while (rset->next())
                                   {
                                       auto row      = ::lua.create_table();
                                       row["id"]     = rset->get<uint16>("itemid");
                                       row["stack"]  = rset->get<uint8>("stack") != 0;
                                       row["price"]  = rset->get<uint32>("price");
                                       row["seller"] = rset->get<uint32>("seller");
                                       t.add(row);
                                   }
                               }

                               return t;
                           });

        // auction house: the gil from its sales (the auction_house_buy trigger puts it in the delivery box, which a bot
        // never opens): takes it out and returns the total, for Lua to add to its gil
        ::lua.set_function("BotCollectSales", [](uint32 charId) -> uint32
                           {
                               uint32 total = 0;
                               if (auto rset = db::preparedStmt("SELECT CAST(COALESCE(SUM(quantity), 0) AS UNSIGNED) AS g FROM delivery_box WHERE charid = ? AND box = 1 AND itemid = 65535", charId);
                                   rset && rset->next())
                               {
                                   total = rset->get<uint32>("g");
                               }

                               if (total > 0)
                               {
                                   db::preparedStmt("DELETE FROM delivery_box WHERE charid = ? AND box = 1 AND itemid = 65535", charId);
                               }

                               return total;
                           });

        // auction house: how many of its own items are up for sale
        ::lua.set_function("BotAucCount", [](uint32 charId) -> uint32
                           {
                               if (auto rset = db::preparedStmt("SELECT COUNT(*) AS n FROM auction_house WHERE seller = ? AND sale = 0", charId); rset && rset->next())
                               {
                                   return rset->get<uint32>("n");
                               }

                               return 0;
                           });

        // bazaar (bots_trade.lua): the same packets a player's client sends - close (price mode), set prices, open.
        // An item at price 0 leaves the bazaar. Returns true when the item is priced (or cleared) as asked.
        ::lua.set_function("BotBazaarSet", [](uint32 charId, uint16 itemId, uint32 price) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online)
                               {
                                   return false;
                               }

                               CItemContainer* inv = PChar->getStorage(LOC_INVENTORY);
                               int             found = -1;
                               for (uint8 slot = 1; slot <= inv->GetSize(); ++slot)
                               {
                                   CItem* PItem = inv->GetItem(slot);
                                   if (!PItem || PItem->getID() != itemId || PItem->hasFlag(xi::ItemFlag::Exclusive))
                                   {
                                       continue;
                                   }

                                   const bool listed = PItem->state() == xi::ItemState::Bazaar;
                                   if (price == 0 ? listed : (!PItem->isBusy() || listed))
                                   {
                                       found = slot;
                                       break;
                                   }
                               }

                               if (found < 0)
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_BAZAAR_CLOSE close{};
                               std::ignore = inject(b, close);

                               GP_CLI_COMMAND_BAZAAR_ITEMSET set{};
                               set.ItemIndex = static_cast<uint8_t>(found);
                               set.Price     = std::min<uint32>(price, 99999999);
                               const bool ok = inject(b, set);

                               GP_CLI_COMMAND_BAZAAR_OPEN open{};
                               std::ignore = inject(b, open);
                               return ok && inv->GetItem(found) != nullptr && inv->GetItem(found)->getCharPrice() == set.Price;
                           });

        // what a character (a bot, or you) has in its bazaar right now: { { id, price, qty, slot }, ... } (empty when none)
        ::lua.set_function("BotBazaarItems", [](uint32 charId) -> sol::table
                           {
                               auto         t     = ::lua.create_table();
                               CCharEntity* PChar = zoneutils::GetChar(charId);
                               if (!PChar)
                               {
                                   if (Bot* b = botOf(charId))
                                   {
                                       PChar = charOf(b);
                                   }
                               }

                               if (!PChar || !PChar->hasBazaar())
                               {
                                   return t;
                               }

                               CItemContainer* inv = PChar->getStorage(LOC_INVENTORY);
                               for (uint8 slot = 1; slot <= inv->GetSize(); ++slot)
                               {
                                   CItem* PItem = inv->GetItem(slot);
                                   if (PItem && PItem->getCharPrice() != 0)
                                   {
                                       auto row     = ::lua.create_table();
                                       row["id"]    = PItem->getID();
                                       row["price"] = PItem->getCharPrice();
                                       row["qty"]   = PItem->getQuantity();
                                       row["slot"]  = slot;
                                       t.add(row);
                                   }
                               }

                               return t;
                           });

        // a bot buys from someone's bazaar (same zone, standing close): views it, buys qty of the cheapest listing of
        // itemId at or below maxPrice (each), leaves. Returns the gil it paid (0 = nothing bought).
        ::lua.set_function("BotBazaarBuy", [](uint32 charId, uint32 sellerId, uint16 itemId, uint32 maxPrice, uint32 qty) -> uint32
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online || !PChar->loc.zone || maxPrice == 0)
                               {
                                   return 0;
                               }

                               CCharEntity* PSeller = PChar->loc.zone->GetCharByID(sellerId);
                               if (!PSeller || PSeller == PChar || !PSeller->hasBazaar() || distance(PChar->loc.p, PSeller->loc.p) > 12.0f)
                               {
                                   return 0;
                               }

                               CItemContainer* sInv = PSeller->getStorage(LOC_INVENTORY);
                               int             best = -1;
                               uint32          bestPrice = 0;
                               for (uint8 slot = 1; slot <= sInv->GetSize(); ++slot)
                               {
                                   CItem* PItem = sInv->GetItem(slot);
                                   if (PItem && PItem->getID() == itemId && PItem->getCharPrice() != 0 && PItem->getCharPrice() <= maxPrice &&
                                       (best < 0 || PItem->getCharPrice() < bestPrice))
                                   {
                                       best      = slot;
                                       bestPrice = PItem->getCharPrice();
                                   }
                               }

                               if (best < 0)
                               {
                                   return 0;
                               }

                               const uint32 num = std::max<uint32>(1, std::min<uint32>(qty, sInv->GetItem(best)->getQuantity()));
                               const uint32 gilBefore = PChar->getStorage(LOC_INVENTORY)->GetItem(0) ? PChar->getStorage(LOC_INVENTORY)->GetItem(0)->getQuantity() : 0;

                               PChar->BazaarID.clean();
                               GP_CLI_COMMAND_BAZAAR_LIST list{};
                               list.UniqueNo = PSeller->id;
                               list.ActIndex = PSeller->targid;
                               if (!inject(b, list))
                               {
                                   return 0;
                               }

                               GP_CLI_COMMAND_BAZAAR_BUY buy{};
                               buy.BazaarItemIndex = static_cast<uint8_t>(best);
                               buy.BuyNum          = num;
                               std::ignore         = inject(b, buy);

                               GP_CLI_COMMAND_BAZAAR_EXIT leave{};
                               std::ignore = inject(b, leave);
                               PChar->BazaarID.clean();

                               const uint32 gilAfter = PChar->getStorage(LOC_INVENTORY)->GetItem(0) ? PChar->getStorage(LOC_INVENTORY)->GetItem(0)->getQuantity() : 0;
                               return gilBefore > gilAfter ? gilBefore - gilAfter : 0;
                           });

        // dead: "return to your Home Point" (the same answer a player gives the death menu)
        ::lua.set_function("BotHomepoint", [](uint32 charId) -> bool
                           {
                               CCharEntity* PChar = charOf(botOf(charId));
                               if (!PChar || !PChar->isDead())
                               {
                                   return false;
                               }

                               // (2026-11-20) not counted for conquest: see charutils::HomePoint
                               PChar->SetLocalVar("BotNoConquest", 1);

                               return action(charId, GP_CLI_COMMAND_ACTION_ACTIONID::HomepointMenu, nullptr, 0);
                           });

        // a new linkshell (as using a Linkshell item does): its id, 0 when the name is taken
        ::lua.set_function("BotMakeLinkshell", [](const std::string& name, uint16 color) -> uint32
                           { return linkshell::RegisterNewLinkshell(name, color); });

        // its linkpearl of this linkshell, in its bag: the slot, or -1
        auto pearlSlot = [](CCharEntity* PChar, uint32 lsId) -> int
        {
            CItemContainer* inv = PChar->getStorage(LOC_INVENTORY);
            for (uint8 slot = 1; slot <= inv->GetSize(); ++slot)
            {
                auto* PItem = dynamic_cast<CItemLinkshell*>(inv->GetItem(slot));
                if (PItem && PItem->GetLSID() == lsId && PItem->GetLSType() != LSTYPE_BROKEN)
                {
                    return slot;
                }
            }

            return -1;
        };

        ::lua.set_function("BotHasPearl", [pearlSlot](uint32 charId, uint32 lsId) -> bool
                           {
                               CCharEntity* PChar = charOf(botOf(charId));
                               return PChar && lsId != 0 && pearlSlot(PChar, lsId) >= 0;
                           });

        // puts on its pearl of this linkshell (linkshell 2), the same packet the client sends from the Linkshell menu.
        // (addLinkpearl(name, true) is not used: it reloads the whole inventory, and what the bot wears then points at
        // freed items - saved as garbage, it crashed the next login.)
        ::lua.set_function("BotEquipPearl", [pearlSlot](uint32 charId, uint32 lsId) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online || lsId == 0)
                               {
                                   return false;
                               }

                               for (const auto slot : { SLOT_LINK1, SLOT_LINK2 })
                               {
                                   if (auto* worn = PChar->getLinkshell(slot); worn && worn->GetLSID() == lsId)
                                   {
                                       return true; // (already on)
                                   }
                               }

                               const int slot = pearlSlot(PChar, lsId);
                               if (slot < 0)
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_GROUP_COMLINK_ACTIVE pkt{};
                               pkt.a           = 15;
                               pkt.ItemIndex   = static_cast<uint8_t>(slot);
                               pkt.Category    = LOC_INVENTORY;
                               pkt.ActiveFlg   = static_cast<uint8_t>(GP_CLI_COMMAND_GROUP_COMLINK_ACTIVE_ACTIVEFLG::EquipOrCreate);
                               pkt.LinkshellId = static_cast<uint8_t>(GP_CLI_COMMAND_GROUP_COMLINK_ACTIVE_LINKSHELLID::Linkshell2);
                               if (!inject(b, pkt))
                               {
                                   return false;
                               }

                               auto* worn = PChar->getLinkshell(SLOT_LINK2);
                               return worn && worn->GetLSID() == lsId;
                           });

        // it left its linkshell: pearls off (the client's unequip packet), then the linkpearls thrown away (a shell
        // item, 513, is kept)
        ::lua.set_function("BotDropPearls", [](uint32 charId) -> uint32
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online)
                               {
                                   return 0;
                               }

                               for (const auto slot : { SLOT_LINK1, SLOT_LINK2 })
                               {
                                   auto* worn = PChar->getLinkshell(slot);
                                   if (!worn || worn->getLocationID() != LOC_INVENTORY)
                                   {
                                       continue;
                                   }

                                   GP_CLI_COMMAND_GROUP_COMLINK_ACTIVE pkt{};
                                   pkt.a           = 15;
                                   pkt.ItemIndex   = worn->getSlotID();
                                   pkt.Category    = LOC_INVENTORY;
                                   pkt.ActiveFlg   = static_cast<uint8_t>(GP_CLI_COMMAND_GROUP_COMLINK_ACTIVE_ACTIVEFLG::Unequip);
                                   pkt.LinkshellId = static_cast<uint8_t>(slot == SLOT_LINK1 ? GP_CLI_COMMAND_GROUP_COMLINK_ACTIVE_LINKSHELLID::Linkshell1
                                                                                             : GP_CLI_COMMAND_GROUP_COMLINK_ACTIVE_LINKSHELLID::Linkshell2);
                                   inject(b, pkt);
                               }

                               uint32          dropped = 0;
                               CItemContainer* inv     = PChar->getStorage(LOC_INVENTORY);
                               for (uint8 slot = 1; slot <= inv->GetSize(); ++slot)
                               {
                                   auto* PItem = dynamic_cast<CItemLinkshell*>(inv->GetItem(slot));
                                   if (!PItem || PItem->getID() == 513 || PItem->isBusy())
                                   {
                                       continue;
                                   }

                                   auto transaction = ItemClaimTransaction::start(PChar);
                                   if (transaction && transaction->take(LOC_INVENTORY, slot, 1) && transaction->commit())
                                   {
                                       dropped++;
                                   }
                               }

                               return dropped;
                           });

        // a /tell from the bot to someone (the same packet the client sends)
        ::lua.set_function("BotTell", [](uint32 charId, const std::string& to, const std::string& text) -> bool
                           {
                               Bot* b = botOf(charId);
                               if (!charOf(b) || !b->online || text.empty() || to.empty())
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_CHAT_NAME pkt{};
                               pkt.unknown04 = 3; // (the server checks these two the way the client sends them)
                               pkt.unknown05 = 0;
                               std::strncpy(reinterpret_cast<char*>(pkt.sName), to.c_str(), sizeof(pkt.sName) - 1);
                               std::strncpy(reinterpret_cast<char*>(pkt.Mes), text.c_str(), sizeof(pkt.Mes) - 1);
                               return inject(b, pkt);
                           });

        // the friend list as the bots see it (bots_friends.lua): every entry a real player has for a bot.
        // { { bot = bot charid, acc = player account, name = the player's character (the one on, if any),
        //     mutual = both listed and accepted, asked = the player's request still waits, listed = the bot lists them } }
        ::lua.set_function("BotFriendList", []() -> sol::table
                           {
                               auto out = ::lua.create_table();
                               auto rset = db::preparedStmt("SELECT p.accid AS acc, bc.charid AS bot, p.pending AS ppending, "
                                                            "COALESCE(b.pending, 1) AS bpending, (b.accid IS NOT NULL) AS listed, "
                                                            "COALESCE((SELECT c.charname FROM chars c LEFT JOIN accounts_sessions s ON s.charid = c.charid "
                                                            "WHERE c.accid = p.accid ORDER BY s.charid IS NULL, c.charid LIMIT 1), '') AS pname "
                                                            "FROM accounts_friends p "
                                                            "JOIN chars bc ON bc.accid = p.friend_accid "
                                                            "LEFT JOIN accounts_friends b ON b.accid = p.friend_accid AND b.blacklist = 0 AND b.friend_accid = p.accid "
                                                            "WHERE p.accid < ? AND p.friend_accid >= ? AND p.blacklist = 0",
                                                            BotAccBase, BotAccBase);
                               if (!rset)
                               {
                                   return out;
                               }

                               int i = 1;
                               while (rset->next())
                               {
                                   const bool playerPending = rset->get<uint32>("ppending") != 0;
                                   const bool listed        = rset->get<uint32>("listed") != 0;
                                   const bool botPending    = rset->get<uint32>("bpending") != 0;

                                   auto row      = ::lua.create_table();
                                   row["bot"]    = rset->get<uint32>("bot");
                                   row["acc"]    = rset->get<uint32>("acc");
                                   row["name"]   = rset->get<std::string>("pname");
                                   row["mutual"] = !playerPending && listed && !botPending;
                                   row["asked"]  = playerPending;
                                   row["listed"] = listed;
                                   out[i++]      = row;
                               }

                               return out;
                           });

        // a bot sends a real player a friend request (the game shows it like any other): ok, why
        // ("sent", or why not: "not on", "no such player", "blocked", "listed" = it already lists them or asked before,
        // "asked" = the player asked it first, "full", "mailbox")
        ::lua.set_function("BotFriendRequest", [](uint32 charId, const std::string& playerName) -> std::tuple<bool, std::string>
                           {
                               Bot* b = botOf(charId);
                               if (!charOf(b) || !b->online)
                               {
                                   return { false, "not on" };
                               }

                               const uint32 acc = playerAccount(playerName);
                               if (acc == 0)
                               {
                                   return { false, "no such player" };
                               }

                               bool blocked = false, listed = false, asked = false;
                               if (auto rset = db::preparedStmt("SELECT accid, blacklist FROM accounts_friends "
                                                                "WHERE (accid = ? AND friend_accid = ?) OR (accid = ? AND friend_accid = ?)",
                                                                b->accId, acc, acc, b->accId))
                               {
                                   while (rset->next())
                                   {
                                       const bool mine = rset->get<uint32>("accid") == b->accId;
                                       const bool black = rset->get<uint32>("blacklist") != 0;
                                       blocked = blocked || (!mine && black);
                                       listed  = listed || mine;
                                       asked   = asked || (!mine && !black);
                                   }
                               }

                               if (blocked || listed || asked)
                               {
                                   return { false, blocked ? "blocked" : (listed ? "listed" : "asked") };
                               }

                               std::vector<bool> used(FriendListSize, false);
                               if (auto rset = db::preparedStmt("SELECT list_index FROM accounts_friends WHERE accid = ? AND blacklist = 0", b->accId))
                               {
                                   while (rset->next())
                                   {
                                       const auto index = rset->get<uint32>("list_index");
                                       if (index < FriendListSize)
                                       {
                                           used[index] = true;
                                       }
                                   }
                               }

                               const auto it = std::find(used.begin(), used.end(), false);
                               if (it == used.end())
                               {
                                   return { false, "full" };
                               }

                               const auto index = static_cast<uint32>(std::distance(used.begin(), it));
                               db::preparedStmt("INSERT INTO accounts_friends(accid, blacklist, list_index, friend_accid, display_order, name, pending) VALUES(?, 0, ?, ?, ?, ?, 1)",
                                                b->accId, index, acc, index, playerName.substr(0, 15));
                               if (!postMail(b, acc, polmail::FriendRequest, polmail::TitleRequest, playerName, polmail::TitleRequest))
                               {
                                   db::preparedStmt("DELETE FROM accounts_friends WHERE accid = ? AND blacklist = 0 AND friend_accid = ? AND pending = 1", b->accId, acc);
                                   return { false, "mailbox" };
                               }

                               ShowInfoFmt("[bots] {} sent {} a friend request", b->name, playerName);
                               return { true, "sent" };
                           });

        // a bot leaves a friend a message (the game's own: the icon lights up, it waits when they are off). Mail needs
        // no log in, so a bot that is off can write too (bots_friends.lua: the mail you find after days away).
        // As in the era, only to a friend: both listed, both accepted.
        ::lua.set_function("BotSendMessage", [](uint32 charId, const std::string& playerName, const std::string& text) -> bool
                           {
                               Bot* b = botOf(charId);
                               const uint32 acc = playerAccount(playerName);
                               if (b == nullptr || acc == 0)
                               {
                                   return false;
                               }

                               auto rset = db::preparedStmt("SELECT COUNT(*) AS n FROM accounts_friends "
                                                            "WHERE blacklist = 0 AND pending = 0 AND ((accid = ? AND friend_accid = ?) OR (accid = ? AND friend_accid = ?))",
                                                            b->accId, acc, acc, b->accId);
                               if (!rset || !rset->next() || rset->get<uint32>("n") != 2)
                               {
                                   return false;
                               }

                               std::string clean;
                               for (const char c : text)
                               {
                                   if (static_cast<uint8>(c) >= 0x20 && static_cast<uint8>(c) < 0x7F && clean.size() < 120)
                                   {
                                       clean += c;
                                   }
                               }

                               if (clean.empty() || !postMail(b, acc, polmail::Plain, polmail::TitlePlain, clean, polmail::TitlePlain))
                               {
                                   return false;
                               }

                               ShowInfoFmt("[bots] {} left {} a message", b->name, playerName);
                               return true;
                           });

        ::lua.set_function("BotChat", [](uint32 charId, uint8 kind, const std::string& text) -> bool
                           {
                               Bot* b = botOf(charId);
                               if (!charOf(b) || !b->online || text.empty())
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_CHAT_STD pkt{};
                               pkt.Kind = kind;
                               std::strncpy(reinterpret_cast<char*>(pkt.Str), text.c_str(), sizeof(pkt.Str) - 1);
                               return inject(b, pkt);
                           });

        ::lua.set_function("BotAnswerInvite", [](uint32 charId, bool accept) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || PChar->InvitePending.entity.UniqueNo == 0)
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_GROUP_SOLICIT_RES res{};
                               res.Res = static_cast<uint8_t>(accept ? GP_CLI_COMMAND_GROUP_SOLICIT_RES_RES::Accept : GP_CLI_COMMAND_GROUP_SOLICIT_RES_RES::Decline);
                               return inject(b, res);
                           });

        // the bot invites a player (the player answers with /join, as with any invite)
        ::lua.set_function("BotInvite", [](uint32 charId, const sol::object& who) -> bool
                           {
                               Bot*         b       = botOf(charId);
                               CCharEntity* PChar   = charOf(b);
                               CBaseEntity* PTarget = targetOf(who);
                               if (!PChar || !PTarget || PTarget->objtype != TYPE_PC)
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_GROUP_SOLICIT_REQ pkt{};
                               pkt.UniqueNo = PTarget->id;
                               pkt.ActIndex = PTarget->loc.zone == PChar->loc.zone ? PTarget->targid : 0;
                               pkt.Kind     = PartyKind::Party;
                               ShowInfoFmt("[bots] {} invites {} to a party", PChar->getName(), PTarget->getName());
                               return inject(b, pkt);
                           });

        // Join a player's party the way accepting an invite would, but without an invite packet: a normal
        // invite is refused for anyone already in a party, and the client cannot target someone in another
        // area at all. This is what a "want a party?" tell uses, so it works from anywhere and when the
        // player is already grouped. The bot then follows and zones over on its own.
        ::lua.set_function("BotJoinParty", [](uint32 charId, uint32 playerId) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               CCharEntity* PHead = zoneutils::GetChar(playerId);
                               if (!b || !b->online || !PChar || !PHead)
                               {
                                   return false;
                               }

                               if (PChar->PParty)
                               {
                                   return PChar->PParty == PHead->PParty;
                               }

                               if (!PHead->PParty)
                               {
                                   PHead->PParty = new CParty(PHead);
                               }

                               // (trusts / squad mates may be out: IsFull() counts them)
                               if (PHead->PParty->GetLeader() != PHead || PHead->PParty->IsFull())
                               {
                                   return false;
                               }

                               PHead->PParty->AddMember(PChar);

                               if (PChar->PParty != PHead->PParty)
                               {
                                   ShowErrorFmt("[bots] {} could not be added to {}'s party", PChar->getName(), PHead->getName());
                                   return false;
                               }

                               // send the full member list now (the normal AddMember reload is asynchronous)
                               PHead->PParty->ReloadPartyMembers(PHead);
                               ShowInfoFmt("[bots] {} joins {}'s party", PChar->getName(), PHead->getName());
                               return true;
                           });

        // the bot (party leader) hands the leader role to someone in the party
        ::lua.set_function("BotMakeLeader", [](uint32 charId, const std::string& name) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !PChar->PParty || PChar->PParty->GetLeader() != PChar)
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_GROUP_CHANGE2 pkt{};
                               std::strncpy(reinterpret_cast<char*>(pkt.sName), name.c_str(), sizeof(pkt.sName) - 1);
                               pkt.Kind       = static_cast<uint8_t>(GP_CLI_COMMAND_GROUP_CHANGE2_KIND::Party);
                               pkt.ChangeKind = static_cast<uint8_t>(GP_CLI_COMMAND_GROUP_CHANGE2_CHANGEKIND::SetPartyLeader);
                               return inject(b, pkt);
                           });

        // Level Sync on a party member (the leader's /levelsync, the same packet the client sends); an empty name turns it off.
        // The server's own rules apply: the target must be level 10+ and in the same area.
        ::lua.set_function("BotLevelSync", [](uint32 charId, const std::string& name) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !b->online || !PChar->PParty || PChar->PParty->GetLeader() != PChar)
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_GROUP_CHANGE2 pkt{};
                               std::strncpy(reinterpret_cast<char*>(pkt.sName), name.c_str(), sizeof(pkt.sName) - 1);
                               pkt.Kind       = static_cast<uint8_t>(GP_CLI_COMMAND_GROUP_CHANGE2_KIND::Party);
                               pkt.ChangeKind = static_cast<uint8_t>(name.empty() ? GP_CLI_COMMAND_GROUP_CHANGE2_CHANGEKIND::DisableLevelSync
                                                                                  : GP_CLI_COMMAND_GROUP_CHANGE2_CHANGEKIND::SetLevelSync);

                               // a bot can keep a Level Sync effect from a party it left: that blocks every new sync, so it goes
                               CParty* PParty = PChar->PParty;
                               if (!name.empty() && PParty->GetSyncTarget() == nullptr)
                               {
                                   for (auto* member : PParty->members)
                                   {
                                       if (member && botOf(member->id) && member->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::LevelSync))
                                       {
                                           member->StatusEffectContainer->DelStatusEffectSilent(xi::StatusEffect::LevelSync);
                                           ShowInfoFmt("[bots] {}: an old Level Sync effect removed", member->getName());
                                       }
                                   }
                               }

                               const bool sent = inject(b, pkt);
                               if (sent && !name.empty() && PParty == PChar->PParty && PParty->GetSyncTarget() == nullptr)
                               {
                                   // why the server said no (the leader's message is not visible for a bot)
                                   std::string why = "unknown";
                                   for (auto* member : PParty->members)
                                   {
                                       if (!member)
                                       {
                                           continue;
                                       }

                                       if (member->getName() == name && member->GetMLevel() < 10)
                                       {
                                           why = fmt::format("{} is below level 10", name);
                                       }
                                       else if (member->getName() == name && member->getZone() != PChar->getZone())
                                       {
                                           why = fmt::format("{} is in another area", name);
                                       }
                                       else if (member->StatusEffectContainer->HasStatusEffect({ xi::StatusEffect::LevelRestriction, xi::StatusEffect::LevelSync,
                                                                                                xi::StatusEffect::SjRestriction, xi::StatusEffect::Confrontation,
                                                                                                xi::StatusEffect::Battlefield }))
                                       {
                                           why = fmt::format("{} has a level restriction / sync / battlefield effect", member->getName());
                                       }
                                   }

                                   ShowWarningFmt("[bots] {}: Level Sync on {} refused ({})", PChar->getName(), name, why);
                               }

                               return sent;
                           });

        // whose level its party is synced to ("" = none)
        ::lua.set_function("BotSyncTarget", [](uint32 charId) -> std::string
                           {
                               CCharEntity* PChar = charOf(botOf(charId));
                               if (!PChar || !PChar->PParty || !PChar->PParty->GetSyncTarget())
                               {
                                   return "";
                               }

                               return PChar->PParty->GetSyncTarget()->getName();
                           });

        // how fast the bots run at normal speed (yalms per second), set from bots.lua
        ::lua.set_function("BotSetRunSpeed", [](float yalmsPerSec) -> float
                           {
                               g_runYalmsPerSec = std::clamp(yalmsPerSec, 1.0f, 10.0f);
                               return g_runYalmsPerSec;
                           });

        ::lua.set_function("BotLeaveParty", [](uint32 charId) -> bool
                           {
                               Bot*         b     = botOf(charId);
                               CCharEntity* PChar = charOf(b);
                               if (!PChar || !PChar->PParty)
                               {
                                   return false;
                               }

                               GP_CLI_COMMAND_GROUP_LEAVE pkt{};
                               pkt.Kind = PartyKind::Party;
                               return inject(b, pkt);
                           });
    }

    // Your own party chat: orders for bots in your party ("follow", "stay", "attack", "stop") -> xi.bots.partyOrder
    auto OnIncomingPacket(MapSession* session, CCharEntity* PChar, CBasicPacket& packet) -> bool override
    {
        if (botOf(PChar->id))
        {
            return false;
        }

        // (2026-11-21) a real player offers a bot a trade: the stock handler sends the request as usual and the bot
        // "accepts" it shortly after (OnZoneTick); when the player presses OK, the bot presses OK too
        if (packet.getType() == 0x032)
        {
            const auto* req = packet.as<GP_CLI_COMMAND_TRADE_REQ>();
            if (Bot* b = botOf(req->UniqueNo); b && b->online && !b->zoning)
            {
                g_gifts.push_back({ req->UniqueNo, PChar->id, timer::now() + std::chrono::milliseconds(1500), false });
            }
        }
        else if (packet.getType() == 0x033)
        {
            const auto* res = packet.as<GP_CLI_COMMAND_TRADE_RES>();
            if (static_cast<GP_CLI_COMMAND_TRADE_RES_KIND>(res->Kind) == GP_CLI_COMMAND_TRADE_RES_KIND::Make)
            {
                CCharEntity* PBot = PChar->tradePartner();
                if (PBot != nullptr && botOf(PBot->id) != nullptr)
                {
                    if (auto* transaction = PChar->activePlayerTradeTransaction())
                    {
                        transaction->accept(PBot); // (the stock handler then accepts for the player and completes it)
                        g_gifts.push_back({ PBot->id, PChar->id, timer::now() + std::chrono::milliseconds(1000), true });
                    }
                }
            }
        }

        // a real player's party invite to a bot: write it in the log (to see why an invite did not arrive)
        // a real player's /tell to a bot: the bot hears it (xi.bots.onTell); the tell itself goes on as normal
        if (packet.getType() == 0x0B6)
        {
            const auto* tell = packet.as<GP_CLI_COMMAND_CHAT_NAME>();
            std::string to(reinterpret_cast<const char*>(tell->sName), strnlen(reinterpret_cast<const char*>(tell->sName), sizeof(tell->sName)));
            const auto  length = std::min<std::size_t>((tell->header.size * 4u) > 0x15u ? (tell->header.size * 4u) - 0x15u : 0u, sizeof(tell->Mes));
            std::string text(reinterpret_cast<const char*>(tell->Mes), strnlen(reinterpret_cast<const char*>(tell->Mes), length));
            for (auto& [id, b] : g_bots)
            {
                if (b->online && !b->zoning && b->name.size() == to.size() &&
                    std::equal(to.begin(), to.end(), b->name.begin(), [](char x, char y) { return std::tolower(static_cast<unsigned char>(x)) == std::tolower(static_cast<unsigned char>(y)); }))
                {
                    if (CCharEntity* PBot = charOf(b.get()))
                    {
                        auto info    = ::lua.create_table();
                        info["from"] = std::string(PChar->getName());
                        info["text"] = polmail::plainChat(text);
                        callLua("onTell", PBot, info);
                    }

                    break;
                }
            }

            return false;
        }

        if (packet.getType() == 0x06E)
        {
            const auto* inv = packet.as<GP_CLI_COMMAND_GROUP_SOLICIT_REQ>();
            ShowInfoFmt("[bots] player {} sent 0x06E for char {} (index {}, kind {})", PChar->getName(), inv->UniqueNo, inv->ActIndex, static_cast<int>(inv->Kind));
            // The /sea list only carries the low 20 bits of a character id, and bot ids (16000000+) do not fit:
            // an invite picked from the search list arrives with a cut-off id that names nobody, and was lost.
            uint32 botId    = inv->UniqueNo;
            bool   remapped = false;
            if (!botOf(botId) && botId < 0x100000 && zoneutils::GetChar(botId) == nullptr)
            {
                for (auto& [id, b] : g_bots)
                {
                    if ((id & 0xFFFFF) == botId && b->online)
                    {
                        botId    = id;
                        remapped = true;
                        break;
                    }
                }
            }

            if (Bot* target = botOf(botId))
            {
                CCharEntity* PBot       = charOf(target);
                const bool   botGrouped = PBot && PBot->PParty != nullptr;

                ShowInfoFmt("[bots] {} invites bot {} (index {}, kind {}); bot is {} in a party{}", PChar->getName(), inv->UniqueNo, inv->ActIndex,
                            static_cast<int>(inv->Kind), botGrouped ? "already" : "not",
                            PChar->PTrusts.empty() ? "" : "; inviter has squad mates out");

                // a bot that just left a synced party still carries Level Sync for 30 s: the standard handler
                // answers "cannot invite" for that, so it goes before the invite is processed
                if (PBot && !botGrouped && PBot->StatusEffectContainer->HasStatusEffect(xi::StatusEffect::LevelSync))
                {
                    PBot->StatusEffectContainer->DelStatusEffectSilent(xi::StatusEffect::LevelSync);
                }

                // A bot in a bot-run party leaves it and takes the invite: the standard handler refuses
                // anyone who is already grouped, which is why /pcmd invite did nothing for those bots.
                if (botGrouped)
                {
                    const bool     leaderIsBot = botOf(PBot->PParty->GetPartyID()) != nullptr;
                    const bool     canInvite   = !PChar->PParty ||
                                             (PChar->PParty->GetLeader() == PChar && !PChar->PParty->IsFull());

                    if (leaderIsBot && canInvite)
                    {
                        g_pendingPlayerInvites[botId] = PendingPlayerInvite{
                            .playerId = PChar->id,
                            .kind     = inv->Kind,
                            .at       = timer::now() + std::chrono::milliseconds(1200),
                        };
                        ShowInfoFmt("[bots] {} leaves its bot party to take {}'s invite", PBot->getName(), PChar->getName());
                        return true; // consumed here: the standard handler would answer "cannot invite"
                    }
                }

                // an invite from the search list: handed to the standard handler with the bot's real id
                if (remapped)
                {
                    GP_CLI_COMMAND_GROUP_SOLICIT_REQ req{};
                    req.UniqueNo = botId;
                    req.ActIndex = 0;
                    req.Kind     = inv->Kind;
                    req.process(session, PChar);
                    ShowInfoFmt("[bots] {}'s invite from the search list goes to {}", PChar->getName(), target->name);
                    return true;
                }
            }

            return false;
        }

        if (packet.getType() != 0x0B5)
        {
            return false;
        }

        const auto* chat = packet.as<GP_CLI_COMMAND_CHAT_STD>();
        const bool  party = chat->Kind == static_cast<uint8_t>(GP_CLI_COMMAND_CHAT_STD_KIND::Party) && PChar->PParty;
        const bool  ls    = chat->Kind == static_cast<uint8_t>(GP_CLI_COMMAND_CHAT_STD_KIND::Linkshell1) ||
                         chat->Kind == static_cast<uint8_t>(GP_CLI_COMMAND_CHAT_STD_KIND::Linkshell2);
        // your shouts and yells too: a bot may answer (bots_tele.lua: "need tele holla" - a bot WHM offers)
        const bool shout = chat->Kind == static_cast<uint8_t>(GP_CLI_COMMAND_CHAT_STD_KIND::Shout) ||
                           chat->Kind == static_cast<uint8_t>(GP_CLI_COMMAND_CHAT_STD_KIND::Yell);
        if (!party && !ls && !shout)
        {
            return false;
        }

        const auto length = std::min<std::size_t>((chat->header.size * 4u) > 6u ? (chat->header.size * 4u) - 6u : 0u, sizeof(chat->Str));
        std::string text(reinterpret_cast<const char*>(chat->Str), strnlen(reinterpret_cast<const char*>(chat->Str), length));
        callLua(shout ? "playerShout" : (party ? "partyOrder" : "lsChat"), PChar, sol::make_object(::lua, polmail::plainChat(text)));
        return false; // the message still goes to party / linkshell chat as normal
    }

    void OnPushPacket(CCharEntity* PChar, const std::unique_ptr<CBasicPacket>& packet) override
    {
        Bot* b = botOf(PChar->id);
        if (!b || charOf(b) != PChar)
        {
            return;
        }

        switch (packet->getType())
        {
            case 0x00B: // zone out (logout packet with "zone change"): log in again once it has left
                b->zoning    = true;
                b->zoneSince = timer::now();
                b->path.clear();
                b->followId = 0;
                break;
            case 0x0DC: // party invite
                b->invitePending = true;
                b->inviteAt      = timer::now() + std::chrono::milliseconds(1500);
                b->inviterName.clear();
                if (CCharEntity* PInviter = zoneutils::GetChar(PChar->InvitePending.entity.UniqueNo))
                {
                    b->inviterName = PInviter->getName();
                }
                break;
            default:
                break;
        }
    }

    void OnZoneTick(CZone* PZone) override
    {
        // all bots, every 200 ms, after a zone has finished its own tick
        const auto now = timer::now();

        // (2026-11-21) gift trades (see g_gifts)
        for (auto it = g_gifts.begin(); it != g_gifts.end();)
        {
            if (now < it->at)
            {
                ++it;
                continue;
            }

            CCharEntity* PBot  = charOf(botOf(it->bot));
            CCharEntity* PChar = zoneutils::GetChar(it->player);
            if (PBot != nullptr && PChar != nullptr)
            {
                if (!it->done)
                {
                    // still asked, nobody else's trade open: open the window on both sides, as the stock 0x033 Start does
                    if (PBot->TradePending.entity.UniqueNo == PChar->id && !PBot->TradePending.initiator &&
                        PBot->activePlayerTradeTransaction() == nullptr)
                    {
                        if (PlayerTradeTransaction::start(PBot, PChar) != nullptr)
                        {
                            PChar->pushPacket<GP_SERV_COMMAND_ITEM_TRADE_RES>(PBot, GP_ITEM_TRADE_RES_KIND::Start);
                            PBot->pushPacket<GP_SERV_COMMAND_ITEM_TRADE_RES>(PChar, GP_ITEM_TRADE_RES_KIND::Start);
                        }
                        else
                        {
                            PBot->TradePending.clean();
                            PChar->TradePending.clean();
                            PChar->pushPacket<GP_SERV_COMMAND_ITEM_TRADE_RES>(PBot, GP_ITEM_TRADE_RES_KIND::ErrYouTrade);
                        }
                    }
                }
                else if (PBot->activePlayerTradeTransaction() == nullptr)
                {
                    auto info    = ::lua.create_table();
                    info["from"] = std::string(PChar->getName());
                    callLua("onGift", PBot, info);
                }
                // (still open: the player changed the items after OK; their next OK queues a new entry)
            }

            it = g_gifts.erase(it);
        }

        // the bots' own position tick, started once there is a scheduler to hang it on
        if (g_moveTimer == nullptr)
        {
            if (Scheduler* scheduler = findScheduler())
            {
                g_moveTimer = new Scheduler::Token(scheduler->intervalOnMainThread(MoveInterval, []() { stepWalkingBots(); }));
            }
        }

        if (now - g_lastGlobalTick < StepInterval)
        {
            return;
        }

        g_lastGlobalTick = now;

        if (findScheduler() != nullptr)
        {
            g_lastPlayerSeen = now;
        }

        // a real player gone for a minute (not just zoning): the bots log out too
        const bool nobody = now - g_lastPlayerSeen > std::chrono::seconds(60);
        for (auto& [id, b] : g_bots)
        {
            if (!b->online && !b->zoning)
            {
                continue;
            }

            if (nobody)
            {
                logout(b.get());
                continue;
            }

            tickBot(b.get());
        }

        // (2026-11-21, delukard) bot players in a party with a real player pass every drop at once, so your loot comes
        // to you without waiting out the lot timer. The launcher's "Bots pass all loot" (bots_config.lua pass_loot, on by
        // default; bots_life.lua sets BOTS_PASS_LOOT).
        if (!nobody && ::lua["BOTS_PASS_LOOT"].get_or(true))
        {
            for (auto& [id, b] : g_bots)
            {
                CCharEntity* PBot = b->online && !b->zoning ? charOf(b.get()) : nullptr;
                CTreasurePool* pool = PBot ? PBot->PTreasurePool : nullptr;
                if (pool == nullptr || pool->itemCount() == 0)
                {
                    continue;
                }

                bool withPlayer = false;
                for (CCharEntity* member : pool->getMembers())
                {
                    withPlayer = withPlayer || (member != nullptr && botOf(member->id) == nullptr);
                }

                if (!withPlayer)
                {
                    continue;
                }

                for (const auto& item : pool->getItems())
                {
                    if (item.ID != 0 && !pool->hasPassedItem(PBot, item.SlotID) && !pool->hasLottedItem(PBot, item.SlotID))
                    {
                        pool->passItem(PBot, item.SlotID);
                    }
                }
            }
        }

        // once a second: the Lua side (roster, log in / log out schedule), only while a real player is on
        if (!nobody && now - g_lastLuaTick >= std::chrono::seconds(1) && findScheduler() != nullptr)
        {
            g_lastLuaTick = now;
            callLuaPlain("onTick");
        }

        // every 10 seconds: friend requests to bots
        if (!nobody && now - g_lastFriendSweep >= std::chrono::seconds(10))
        {
            g_lastFriendSweep = now;
            sweepFriendRequests();
        }
    }
};

REGISTER_CPP_MODULE(BotsModule);
