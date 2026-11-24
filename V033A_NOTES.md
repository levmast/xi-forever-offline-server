# v0.3.3a detailed notes

<details>
<summary><b>EN-01</b> Buff range setting (`TRUST_AOE_RANGE`): <i>proof carried</i></summary>

**What:** the setting explained above. Four engine files change (the party area target search, the trust spell range test, the setting declaration, and the Run ability loops).

**Why:** Add-on movement and placement lines, Bard song positioning, COR roll stacking, healer and GEO placement, and Squads Revamped spacing. All of them only mean something on Retail.

**Behaviour change:** **yes.** Default Retail changes what stock does; Extended is stock.
Test steps (to be written against a v0.3.3 build; outline):
1. Call a squad with a WHM mate and four mates; stand them at 5, 12, 20 and 35 yalms from her. Have her cast Protectra. Expected on Retail: only the mate at 5 gets it; where to see it: the status icons or `!squad` status line.
2. Set Extended, restart, repeat. Expected: all four get it.
3. Stand a real player at 35 yalms in both modes. Expected: never buffed (unchanged).

**Commits:** `3b5896cab7`

**Files:** `scripts/globals/job_utils/rune_fencer.lua`, `settings/default/map.lua`, `src/map/ai/helpers/targetfind.cpp`, `src/map/ai/states/magic_state.cpp`

**Test steps:**
1. Setting Retail. Place the four other mates 5, 12, 20, 35 yalms from the WHM mate (stand them with `!squad` camp or move the player so they follow, then measure with the target distance readout). Have the WHM cast Protectra. Expected: Protectra icon on the mate at 5 only. See it in: the status icons in the party list, or `!squad` status.
2. Same layout, Curaga on the mate at 12 (the cure circle is around that mate). Expected: mates 7 and 8 yalms from it healed, the one at 35 not.
3. Setting Extended (launcher Rules page, restart the server). Repeat 1. Expected: all four have Protectra.
4. A real player at 35 yalms, either mode. Expected: never buffed by a mate's Protectra.
5. Setting back to Retail. Expected: same as step 1.

**Revert:** set Extended, or drop the branch.

**Proof mark:** **proof carried.** Upstream changed only squad.cpp and squad.lua; the four engine files and the Rune Fencer script of this fix are untouched.

</details>

<details>
<summary><b>EN-02</b> Squad mates are party members: <i>proof carried</i></summary>

**What:** a squad mate that borrows a passive template body (Brygid, Cornelia) is targetable and can cast, so a Geomancer or Blue Mage mate casts for the first time (Indi, Geo and Cure spells; Blue spells with her set kept across the spawn). A mate can call a pet exactly as a player does (Call Wyvern, summons, Call Beast, Geo spells put a Luopan on the target) and a Luopan works for a trust master. A Puppetmaster mate fights with her own automaton, built from her own record through the Lua hook `SquadMateAutomaton` (frame, head, attachments, name; the player's own automaton is never read or written). The engine tests `IsSquadMate()` everywhere, so a retail trust is not touched.

**Why:** Squads Revamped and add-on job rows for GEO, BLU, SMN, DRG, BST and PUP mates. Without it those mates stand and cannot act (a passive trust cannot cast).

**Behaviour change:** none for retail trusts. Squad mates of those jobs start acting; that is the point.

**Commits:** `42125ad96b`

**Files:** `scripts/globals/job_utils/geomancer.lua`, `src/map/ai/controllers/automaton_controller.cpp`, `src/map/entities/trust_entity.cpp`, `src/map/entities/trust_entity.h`, `src/map/lua/lua_base_entity.cpp`, `src/map/lua/luautils.cpp`, `src/map/utils/petutils.cpp`, `src/map/utils/puppetutils.cpp`, `src/map/utils/puppetutils.h`, `src/map/utils/trustutils.cpp`

**Test steps:**
1. Call a GEO mate and fight a monster.   Expected: she casts Indi and Geo spells, a Luopan stands at the Geo spell's target.   See it in: the game, MP drop.
  2. Call a BLU mate, zone, look at her set.   Expected: the blue set is unchanged.   See it in: the Squad window Blue Mage view.
  3. Call DRG and BST mates.   Expected: wyvern or jug pet fights.   See it in: party list pet row.
  4. Call a PUP mate.   Expected: her own automaton fights; your own automaton data is unchanged.   See it in: the game.
  5. Call a retail trust.   Expected: exactly as before.

**Revert:** revert the commit; nothing else reads it. Without it those mates idle, as in v0.3.2.

**Proof mark:** **proof carried.** Entity, pet and spell files only; upstream did not touch them.

</details>

<details>
<summary><b>EN-10</b> Trust hold hook (`TRUST_HOLD`): <i>proof carried</i></summary>

**What:** a neutral hook in the trust AI. A Lua script that owns a trust can hold the stock engage and / or the stock weapon skills of that one trust, and lets go again. Three local vars: `TRUST_HOLD` (1 engage, 2 weapon skills), `TRUST_HOLD_SEQ` (a counter the script raises about once a second), `TRUST_HOLD_ENGINE` (set to 1 on every trust: this build has the hook). The hold runs out three seconds after the last renewal, so a script that stops or crashes never leaves a trust frozen.

**Why:** add-on and Squads Revamped lines that say "not yet" to the stock engage or weapon skill until the tank holds the monster. Without it those lines are advisory, because the stock AI acts before any Lua row runs.

**Behaviour change:** none. The stock server never writes `TRUST_HOLD`; the only thing written on every trust is the marker var.

**Commits:** `bb5ab829c0`

**Files:** `src/map/ai/controllers/trust_controller.cpp`, `src/map/ai/controllers/trust_controller.h`, `src/map/ai/controllers/trust_hold.h`, `src/map/ai/helpers/gambits_container.cpp`, `src/test/CMakeLists.txt`, `src/test/tests/trust_hold_tests.cpp`

**Test steps:**
1. With nothing set, call a trust (Kupipi) and engage a monster. Expected: the trust engages at once, as on v0.3.2. See it in: the trust draws her weapon; party list.
2. On the trust set local var `TRUST_HOLD` = 1 and raise `TRUST_HOLD_SEQ` by 1 once a second (an add-on that holds the stock decisions does this; by hand: a repeating timer on the trust). Engage a monster. Expected: the trust does not engage while the counter keeps moving. See it in: she stays out of the fight.
3. Stop raising the counter, keep `TRUST_HOLD` = 1. Expected: within about 3 seconds she engages by herself. See it in: she draws her weapon; the monster turns on her or the fight shows her attacks.
4. Set `TRUST_HOLD` = 2 and keep the counter moving; build 1000 TP on a melee trust. Expected: no stock weapon skill fires at 1000 TP while held; one fires within about 3 seconds after you stop the counter (or clear the mask). See it in: the combat log line of the weapon skill.
5. Read `TRUST_HOLD_ENGINE` on a trust after her first tick. Expected: 1 on every trust. See it in: a Lua console read of the local var, or the add-on's own version command, once it reads the neutral names.

**Revert:** revert the commit; nothing else reads the vars.

**Proof mark:** **proof carried.** trust_controller and gambits_container are untouched upstream.

</details>

<details>
<summary><b>SQ-02</b> Gear loader: callMate's outfit loop is a function: <i>RE-TEST</i></summary>

**What:** the loop in `callMate` that decides which saved pieces a squad mate wears and which become looks (a Level Sync piece above the level still shows) moves into a pure function, `squad_equipment.projectSpawnGear`, loaded lazily with `require` (like `squad_ws`). Same inputs, same outfit and looks.

**Why:** Squads Revamped and other add-ons changing the gear rule through one function, without patching `squad.lua`.

**Behaviour change:** none intended (a refactor).

**Commits:** `bd9baa32cc`

**Files:** `modules/custom/lua/squad.lua`, `modules/custom/lua/squad_equipment.lua`

**Test steps:**
1. Call a squad at full level.   Expected: the same pieces as before the change.   See it in: Squad window gear view, `!squad gear`.
  2. Level Sync below a mate's gear.   Expected: weapons and ammo stay on, armour above the level shows as a look, a lockstyle slot is not overwritten.
  3. Remove `modules/custom/lua/squad_equipment.lua` and call a mate.   Expected: a Lua error naming the file (it must ship with the change).   See it in: the map log.

**Revert:** revert the commit (the inline loop is restored byte for byte).

**Proof mark:** **RE-TEST.** Upstream's new auto-equip (Squad gets all gear) now feeds the same mate.equip that callMate's outfit loop reads; callMate itself is not changed upstream, but the two meet here.

</details>

<details>
<summary><b>SC-01</b> Party chat commands move into Lua (thin squad.cpp, step 1): <i>RE-TEST</i></summary>

**What:** The decisions of a party chat line (`cure me`, `all haste`, `poppelle cure momo`, `2hr`, `sneak attack`) were 274 lines of C++ in squad.cpp. squad.cpp now only decodes the packet and calls `xi.squad.onChatCommand`; the rules are `squad_logic.lua`. A player sees nothing different.

**Why:** Every later item here, and Squads Revamped: a chat rule becomes a Lua edit that needs no restart (SC-03). The party request router of an add-on plugs into this file.

**Behaviour change:** none (this is the same behaviour moved; the parity test is the proof). Switch: none; it is the reason the map server must be rebuilt (needs the map server rebuilt from this branch's squad.cpp).

**Commits:** `1b3f601115`

**Files:** `modules/custom/cpp/squad.cpp`, `modules/custom/lua/squad_logic.lua`, `modules/init.txt`

**Test steps:**
1. Setting `!sqreq off` first, so only this item is under test. Type `cure me` in party chat. Expected: One mate casts Cure on you and says one line. See it in: party chat log.
2. Type `all haste`. Expected: Every mate that has Haste casts it on you, each with a line (the v0.3.2 behaviour; SC-07 changes it). See it in: party chat log.
3. Type `poppelle cure pipo`, then `cure on pipo`. Expected: Poppelle casts Cure on Pipo; then the first mate able does. See it in: party chat log.
4. Type `2hr`, `sneak attack`, `hide`. Expected: The first mate that can uses its two-hour, Sneak Attack, Hide; a mate that cannot answers `not ready` or `not mine`. See it in: party chat log.
5. Type `we should really cure everybody now ok` (seven words). Expected: Nothing happens: it is conversation. See it in: party chat log.
6. Type `{Cure IV}` with auto-translate. Expected: Read as Cure IV: the mate casts it or says it does not know it. See it in: party chat log, server log `[SQUAD] auto-translate`.

**Revert:** Revert the commit and rebuild: the old C++ handles the chat again. (Without the rebuild `squad_logic.lua` is simply never called and the old C++ keeps working.)

**Proof mark:** **RE-TEST.** Same file as upstream's new getSquadGearPool (squad.cpp); the merge was clean and the changes are in other functions, one build and a chat smoke test confirms it.

</details>

<details>
<summary><b>SC-02</b> Job ability rules for party chat live in Lua (thin squad.cpp, step 2): <i>RE-TEST</i></summary>

**What:** Who may use which job ability (`squadMateMayUse` and two rule blocks of `trySquadAbility`) was a second copy of the rules `squad_ability_rules.lua` already holds. One table now (`sq_logic.lua`). No change for a player.

**Why:** Rule Sets and chat see the same rules; Squads Revamped edits them live.

**Behaviour change:** none. Switch: none (needs the map server rebuilt from this branch's squad.cpp).

**Commits:** `309b2dc14f`

**Files:** `modules/custom/cpp/squad.cpp`, `modules/custom/lua/sq_logic.lua`, `modules/init.txt`

**Test steps:**
1. Setting `!sqreq off` first, so only this item is under test. Type `sneak attack` with a THF mate main, then with a WHM mate main. Expected: The THF uses it; the WHM answers that it is not one of its abilities. See it in: party chat log.
2. Type `hundred fists` (or `2hr`) with a WAR/MNK mate (MNK as sub). Expected: No Hundred Fists from the sub job. See it in: party chat log.

**Revert:** Revert the commit and rebuild.

**Proof mark:** **RE-TEST.** Same file as upstream's new getSquadGearPool (squad.cpp), other functions; needs the same rebuild and smoke test.

</details>

<details>
<summary><b>SC-03</b> Hot reload for the Squads Lua files (dev only): <i>proof carried</i></summary>

**What:** `squad_reload.lua`: edit a Squads Lua file while the server runs, then `!squad reload` (GM) or save it and the engine's file watcher reloads it in order, keeping state (camps, timers). A syntax error changes nothing. The file list is the v0.3.x one (`sq_logic`, `squad_requests`, `late/squad_gear_score`; `squad_meals`, `squad_shell`, the request words as data), the order is init.txt's.

**Why:** Squads Revamped and the dev team: Squads changes without a restart.

**Behaviour change:** none: it does nothing unless a Squads file is saved or the command is used. Switch: remove the last line of init.txt.

**Commits:** `b890919754`

**Files:** `modules/custom/lua/squad_reload.lua`, `modules/init.txt`

**Test steps:**
1. As a GM: `!squad reload status`. Expected: Lists the active files in init.txt order, ending with `late/squad_gear_score`. See it in: chat log.
2. Edit `squad_logic.lua`: `L.MAX_WORDS = 6` to `1`. `!squad reload squad_logic`. Expected: Says it reloaded; `cure me` is now just chat (no answer). No restart. See it in: chat log, server log `[squad_reload]`.
3. Put `6` back. Save the file. Expected: The file watcher reloads it by itself; `cure me` answers again. See it in: server log.
4. Break the file (type `this is not lua` at the end), `!squad reload`. Expected: `reload refused ... does not compile, nothing changed`; chat still answers. See it in: chat log.

**Revert:** Remove the init.txt line and the file.

**Proof mark:** **proof carried.** squad_reload.lua is a new file; the init.txt line stays last.

</details>

<details>
<summary><b>SC-04</b> SquadSpellKind binding (what a spell can be cast on): <i>RE-TEST</i></summary>

**What:** One small read-only C++ binding: `enemy`, `dead`, `party` or `self` for a spell id, from the spell table with the flags `trySquadCast` already reads. Not visible by itself.

**Why:** SC-06 to SC-09, SC-14, SC-15 need it to tell a buff on a person from an attack, a Raise, a spell that only works on its caster.

**Behaviour change:** none. Switch: none (needs the map server rebuilt from this branch's squad.cpp).

**Commits:** `40ce54ddf3`

**Files:** `modules/custom/cpp/squad.cpp`

**Test steps:**
1. Not visible alone. See SC-07 (`all protect` is one cast) and SC-08 (`warp` is refused), which do not work without it. Expected: Without the rebuilt binding the request fixes leave the line to the old chat (nothing breaks). See it in: SC-07, SC-08.

**Revert:** Revert the commit and rebuild.

**Proof mark:** **RE-TEST.** Same file as upstream's new getSquadGearPool and its binding line (squad.cpp); the new binding sits next to it. Rebuild confirms.

</details>

<details>
<summary><b>SC-17</b> Looser words for a request (G4): <i>proof carried</i></summary>

**What:** With `!sqreq more on`: `sneak please`, `i need invis`, `can you cure me?`, `poppelle sneak please`, `{Sneak}`, `cure ii please` are requests. Before they were silent no-ops. A line with any other word (`we should sneak past the undead`, `sneak attack`) is conversation, passed on unchanged. The words are data (`squad_requests_data.lua`).

**Why:** An add-on asks the same words (`!ask`).

**Behaviour change:** yes, behind a switch. Default off. Switch: `!sqreq more on` / `!sqreq more off`.

**Commits:** `a42dc82a21`

**Files:** `modules/custom/lua/squad_logic.lua`, `modules/custom/lua/squad_requests.lua`, `modules/custom/lua/squad_requests_data.lua`

**Test steps:**
1. `!sqreq more off`. Type `sneak please`. Expected: Nothing happens (v0.3.2). See it in: party chat log.
2. `!sqreq more on`. Type `sneak please`, `i need invis`, `can you cure me?` (hurt). Expected: A mate casts each, with its line. See it in: party chat log.
3. Type `we should sneak past the undead` and `sneak attack`. Expected: No request is made (the Thief ability path handles `sneak attack`). See it in: party chat log.

**Revert:** `!sqreq more off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new; upstream did not touch it.

</details>

<details>
<summary><b>SC-18</b> "us", "everyone", "party" are a target (G3): <i>proof carried</i></summary>

**What:** With the extras on: `sneak us`, `protect everyone`, `invis party`, `haste all` ask for every living member who can take the spell (people; squad mates too for spells good for them). One acknowledgement; the casts are spread over free mates; a casting mate is waited for (up to 12 s); nobody can: one line.

**Why:** One request for a whole party.

**Behaviour change:** yes, behind a switch. Default off. Switch: `!sqreq more on`.

**Commits:** `5d8b4c1d32`

**Files:** `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. `!sqreq more on`, a second player in the party. Type `sneak us`. Expected: Both of you get Sneak, from different mates when two are free; one line. See it in: status icons, party chat log.
2. Type `protect everyone`. Expected: Players and mates get Protect. See it in: status icons.

**Revert:** `!sqreq more off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-19</b> The best spell she can cast (G7): <i>proof carried</i></summary>

**What:** With the extras on `cure`, `protect`, `haste` ask for the best tier she has learned and can pay for (every tier is asked best first). A tier word (`cure ii`) is that tier only. Before it was the first tier even at level 75.

**Why:** Useful chat requests at high level.

**Behaviour change:** yes, behind a switch. Default off. Switch: `!sqreq more on`.

**Commits:** `fdcc5592df`

**Files:** `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. `!sqreq more on`. Hurt yourself, type `cure please`. Expected: The mate casts her highest Cure she can afford (watch the cast name). See it in: battle/chat log.
2. Type `cure ii please`. Expected: Exactly Cure II. See it in: chat log.

**Revert:** `!sqreq more off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-20</b> Needed or not, and the best one to do it (G8, G13): <i>proof carried</i></summary>

**What:** With the extras on: Cure at full health, a -na with nothing to cure, a buff already on are not cast; one mate says why, once. Raise needs somebody down, Escape and Reraise are refused with the reason, the words `poisoned`, `blind`, `i died` act only when there is something to do. The caster is chosen: the job that fits first (White Mage for Cure, Red Mage for stealth), then most MP, then nearest, then squad order. A mate you name is always the one asked.

**Why:** The router behaviour an add-on has, on the dev team's Squads.

**Behaviour change:** yes, behind a switch. Default off. Switch: `!sqreq more on`.

**Commits:** `dcffaf30e9`

**Files:** `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. `!sqreq more on`, full health. Type `cure please`. Expected: No cast; one line that nothing is needed. See it in: party chat log.
2. Get poisoned, type `poisoned`. Expected: A mate casts Poisona. See it in: party chat log.
3. Type `sneak` with a WHM and a RDM mate out. Expected: The RDM casts it. See it in: party chat log.

**Revert:** `!sqreq more off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-21</b> "sneak and invis" is one caster, one after the other (G12): <i>proof carried</i></summary>

**What:** With the extras on, a request for several spells on one person (`sneak and invis`, `stealth`) goes to one mate: the first spell to the best caster, the next ones wait for her unless she cannot cast it at all. One acknowledgement.

**Why:** Sneak and Invisible together, the way a player asks.

**Behaviour change:** yes, behind a switch. Default off. Switch: `!sqreq more on`.

**Commits:** `b250afe830`

**Files:** `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. `!sqreq more on`. Type `sneak and invis please`. Expected: One mate casts Sneak, then Invisible when she is free; both are on you; one line. See it in: status icons, party chat log.

**Revert:** `!sqreq more off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-22</b> One Teleport price (G11): <i>proof carried</i></summary>

**What:** A bot white mage you shout for asks 500 to 2,000 gil; the same Teleport asked in party chat was free. With the extras on, a Teleport asked in party chat costs what the shout would have, paid when the bot casts; without the gil it says so and does not cast.

**Why:** Bots as a service with one price list.

**Behaviour change:** yes, behind a switch. Default off: a price is a change a player should choose. Switch: `!sqreq more on`.

**Commits:** `e9c94797d1`

**Files:** `modules/custom/lua/bots.lua`, `modules/custom/lua/bots_tele.lua`, `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. `!sqreq more on`, a bot WHM with Teleport-Holla in the party, 5,000 gil. Type `teleport holla`. Expected: The bot says its price and casts; the gil is paid (500 to 1,200). See it in: party chat log, gil.
2. With 10 gil. Expected: The bot says it needs the gil first; no cast. See it in: party chat log.

**Revert:** `!sqreq more off`, or revert the commit.

**Proof mark:** **proof carried.** bots.lua and bots_tele.lua are untouched upstream.

</details>

<details>
<summary><b>SC-23</b> "feed us" has a path (G14): <i>proof carried</i></summary>

**What:** With the extras on: `food`, `eat`, `feed us`, `poppelle eat` make the mates eat now, by the same rules as every combat tick (`xi.squad.eatNow`, exported from squad.lua): a stopped mate does not, a mate under level 11 does not, one eating already does not. When nobody could, one mate says so.

**Why:** Squads Revamped's 'Only when asked' buffs profile.

**Behaviour change:** yes, behind a switch. Default off. Switch: `!sqreq more on`.

**Commits:** `3b4a0738ba`

**Files:** `modules/custom/lua/squad.lua`, `modules/custom/lua/squad_requests.lua`, `modules/custom/lua/squad_requests_data.lua`

**Test steps:**
1. `!sqreq more on`, mates level 11 or higher, not eating. Type `feed us`. Expected: Each mate eats and says its eat line; the food icon shows. See it in: party list, chat log.
2. Type `feed us` again. Expected: One mate says everyone has eaten. See it in: chat log.

**Revert:** `!sqreq more off`, or revert the commit.

**Proof mark:** **proof carried.** One export line in squad.lua, in a function upstream did not change.

</details>

<details>
<summary><b>SQ-D1</b> Squads Bard casters group (mageSwitch) on by default: <i>new in v0.3.3a</i></summary>

**What:** `SQUAD_BARD_WALK.cfg.mageSwitch` now starts as `true`. A squad Bard with casters (WHM, BLM, RDM, SMN, SCH, GEO) in the party switches to the caster spot, and back to the fighters when the casters are fine (the group switch that was already in the file).

**Why:** The casters group is the retail way: a Bard stands where the people who need the songs most can hear them.

**Commits:** `94874bec26`

**Files:** `modules/custom/lua/squad_bard_walk.lua`

**Test steps:**
1. Call a squad with a Bard and a White Mage, fight a monster. Expected: the Bard walks to the casters' side (`!bard debug` prints the group). See it in: the game, the map log.
2. In the server console set `SQUAD_BARD_WALK.cfg.mageSwitch = false`. Expected: the Bard stays beside the fighters again.
3. `!bard go fighters` / `!bard go mages` still force a side.

**Revert:** Set `SQUAD_BARD_WALK.cfg.mageSwitch = false`, or revert the commit.

**Proof mark:** **new in v0.3.3a.** A default change, one line; steps in the test plan.

</details>

<details>
<summary><b>CF-01</b> The addon channel (a packet that carries a command without any chat line): <i>RE-TEST</i></summary>

**What:** a new packet, `0x1F0`, that an add-on can send to the map server. The server runs its text as a command, exactly as it runs a `!` chat line (same command handler, same permission checks, a jailed character runs nothing). It is not a chat packet, so it is not echoed, nothing shows in the chat window and no other player sees it. The server says it handles the packet (`xi.addonChannel` for Lua, and the line `squadpanel:chan|1` in the answer to `!squad panel`), so a window sends it only to a server that has it. The stock Squads window (the kit's `servermenu`) uses it when the server says so and keeps typing otherwise.

**Why:** any add-on that has to talk to the server without chat lines (the Squads window now, our packages next), and the quiet chat clean-up that is today a filter on lines the add-on typed itself.

**Behaviour change:** none for a player who runs no add-on that sends the packet. The server still answers with the same data lines as before.

**Commits:** `8d12e562a4`, `0cfeeced57`

**Files:** `modules/custom/lua/squad.lua`, `modules/custom/tests/test_core_channel_advert.lua`, `src/map/enums/packet_c2s.h`, `src/map/packet_system.cpp`, `src/map/packet_system.h`, `src/map/packets/c2s/0x1f0_addon_channel.cpp`, `src/map/packets/c2s/0x1f0_addon_channel.h`, `src/map/packets/c2s/CMakeLists.txt`, `src/map/packets/c2s/rate_limiter.cpp`, `tools/core_files/run_checks.py`

**Test steps:**
1. As a GM, type `!exec print(tostring(xi.addonChannel and xi.addonChannel.packet))`. Expected: `496` (that is 0x1F0). On the stock v0.3.2 engine it prints `nil`. See it in: the server log.
2. Open the Squads window (`/sq`). Press Refresh. Expected: the window fills as before. See it in: the window; the chat log shows no `>> /say !squad panel` line.
3. Press Call all. Expected: the mates are called, and there is no `>> /say !squad call all` line and no `Name : !squad call all` line in the chat window. See it in: the chat window (nothing), the world (the mates appear).
4. Press a mate's Dismiss, then Set camp here. Expected: they work; still no typed line in chat.
5. Type `!squad call all` by hand. Expected: it still works and still shows as a normal chat command (the typed way is unchanged).
6. Go to the stock v0.3.2 engine (or stop using the branch's engine) with the same window. Expected: the window works exactly as before and types its lines again (the server never says the channel line).
7. In the server folder run `python tools/core_files/run_checks.py`. Expected: `all core file checks pass`.

**Revert:** revert the commit and rebuild the engine; the window keeps typing by itself, because an older server never says `chan|1`. The pace limit can be changed or removed with `GP_CLI_COMMAND_ADDON_CHANNEL` in `network.PACKET_RATE_LIMITS` (default 200 ms, the same as chat; 0 = none).

**Proof mark:** **RE-TEST.** The Squad command's panel answer and the camp lines sit in commandObj.onTrigger, the same function where upstream changed the auto-equip branch; separate branches, merged clean. One smoke test: !squad panel and !squad autoequip now.

</details>

<details>
<summary><b>CF-02</b> Spell and ability tables from the server's own data: <i>proof carried</i></summary>

**What:** `modules/custom/lua/core_spell_data.lua`, a table of every spell and job ability with its id, level for each job, tier (Cure II is 2, Katon: Ni is 2), range, target type (self, party, enemy, ...), and for spells MP, cast and recast time. It is written by `tools/core_files/gen_spell_tables.py` from `sql/spell_list.sql`, `sql/abilities.sql` and the target list in `battle_entity.h`; nobody types a number. `gen_spell_tables.py --check` says whether it is up to date.

**Why:** any script that has to know whether a character has learned a spell or ability, how far it reaches, or what it can target, without querying the database or hard coding levels.

**Behaviour change:** none. Nothing loads the file; a script reads it with `require('modules/custom/lua/core_spell_data')`.

**Commits:** `12a4aa8202`

**Files:** `modules/custom/lua/core_spell_data.lua`, `modules/custom/tests/test_core_spell_data.lua`, `tools/core_files/gen_spell_tables.py`

**Test steps:**
1. Run `python tools/core_files/gen_spell_tables.py --check`. Expected: `core_spell_data.lua is up to date`. See it in: the terminal.
2. Run `python tools/core_files/run_checks.py`. Expected: `ok test_core_spell_data.lua` and `all core file checks pass`.
3. Open `modules/custom/lua/core_spell_data.lua` and find `['CURE_II']`. Expected: `tier = 2`, `range = 20`, `lv = { [3] = 11, ...}` (White Mage 11).
4. Start the server. Expected: no new error line in the log (nothing loads the file).

**Revert:** delete the three files or revert commit `12a4aa8202`.

**Proof mark:** **proof carried.** New files only.

</details>

<details>
<summary><b>CF-03</b> Skillchain property table (each weapon skill's properties and the closing rules): <i>proof carried</i></summary>

**What:** `modules/custom/lua/core_skillchain_data.lua`: the skillchain properties of each of the 215 weapon skills that have any (primary first), the rule table that says which pair of properties makes which skillchain, the level of each skillchain, and the server's timing (3 seconds before a link, a 10 second window, each link shortens it by 1). `core_skillchain.lua` answers the common questions over it (the properties of a weapon skill, what two skills in a row form, the window after n links). It is written by `tools/core_files/gen_skillchain_table.py` from `data/weapon_skills.yaml`, `data/enums/skillchain_type.yaml` and `battleutils.cpp` (the server's own rule table), nothing is guessed from names.

**Why:** any script that plans or recognises skillchains (who opens, who closes, what it makes) without copying the rules.

**Behaviour change:** none. Nothing loads the files unless a script asks.

**Commits:** `183594afb3`

**Files:** `modules/custom/lua/core_skillchain.lua`, `modules/custom/lua/core_skillchain_data.lua`, `modules/custom/tests/test_core_skillchain.lua`, `tools/core_files/gen_skillchain_table.py`

**Test steps:**
1. Run `python tools/core_files/gen_skillchain_table.py --check`. Expected: `core_skillchain_data.lua is up to date`.
2. Run `python tools/core_files/run_checks.py`. Expected: `ok test_core_skillchain.lua`.
3. Open `modules/custom/lua/core_skillchain_data.lua`. Expected: `D.TIMING = { delay = 3, window = 10, shrink = 1, max_links = 5 }`, and `D.WS[1]` is `combo` with property 8 (impaction).
4. Start the server. Expected: no new error line.

**Revert:** delete the four files or revert commit `183594afb3`.

**Proof mark:** **proof carried.** New files only.

</details>

<details>
<summary><b>CF-04</b> A crash guard any server script can use: <i>proof carried</i></summary>

**What:** `modules/custom/lua/core_guard.lua`. A script runs a risky function through `guard.call(tag, fn, ...)` (or `guard.wrap`); a Lua error is caught, one short line goes to the server log, and the script carries on. The same error repeating cannot flood the log: each tag gets 3 lines per 60 seconds, the rest are counted, and the next line says how many were held back.

**Why:** server scripts of any kind that run inside the engine's callbacks, where an error must never travel up.

**Behaviour change:** none. Loading it does nothing; it logs only when a guarded call fails.

**Commits:** `d16e6a44c1`, `5a5baa6cec`

**Files:** `modules/custom/lua/core_guard.lua`, `modules/custom/tests/test_core_guard.lua`, `tools/core_files/run_checks.py`

**Test steps:**
1. Run `python tools/core_files/run_checks.py`. Expected: `ok test_core_guard.lua`.
2. (optional, as a GM) `!exec local g = require('modules/custom/lua/core_guard'); for i = 1, 10 do g.call('demo', function() error('boom') end) end`. Expected: exactly 3 lines `[guard] demo: ... boom` in the server log, not 10.
3. Start the server. Expected: no new error line.

**Revert:** delete the two files or revert commits `d16e6a44c1` and `5a5baa6cec`.

**Proof mark:** **proof carried.** New files only.

</details>

<details>
<summary><b>SH-01</b> Revamped hook points (server): <i>RE-TEST</i></summary>

**What:** Placeholder Lua files (`xk_*`, `sq_*`, `addon_owner.lua`) listed in `modules/init.txt`, a few guarded hook calls in `squad.lua` and `squad_bard_walk.lua`; none of them does anything until a Revamped package replaces the placeholders. See `docs/REVAMPED-HOOKS.md`.

**Why:** Lets add-ons and Squads Revamped install without patching these files.

**Commits:** `0b192d9ca7`

**Files:** `docs/REVAMPED-HOOKS.md`, `modules/custom/lua/addon_owner.lua`, `modules/custom/lua/sq_act.lua`, `modules/custom/lua/sq_automaton.lua`, `modules/custom/lua/sq_backend_dev.lua`, `modules/custom/lua/sq_export.lua`, `modules/custom/lua/sq_gate.lua`, `modules/custom/lua/sq_gearview.lua`, `modules/custom/lua/sq_guard.lua`, `modules/custom/lua/sq_owner.lua`, `modules/custom/lua/sq_plan.lua`, `modules/custom/lua/sq_profile.lua`, `modules/custom/lua/sq_rows_bard.lua`, `modules/custom/lua/sq_rows_boost.lua` and 26 more

**Test steps:**
1. `python tools/revamped/test_revamped_hooks.py`. Expected: 11 tests OK.
2. In game: `!squad autoequip now` and `!squad` work as before.

**Revert:** Revert the commit and remove the init.txt lines.

**Proof mark:** **RE-TEST.** Its squad.lua hooks sit in commandObj.onTrigger, callMate and squadSpawn; upstream changed onTrigger (auto-equip branch) and squadOutfitFix. The hook test passes on the merged tree; one in-game check of auto-equip confirms.

</details>

<details>
<summary><b>SQ-10</b> Bard walk stands where every fighter hears the song: <i>proof carried</i></summary>

**What:** the squad Bard stood at the centroid of the fighters, so fighters on the far side of the monster were outside her song reach. She now takes the spot nearest to the old one from which every fighter is within 9 yalms and not nearer the foe than 5; the old spot when it already reaches everyone.

**Why:** EN-01 (Retail range), where a song reaches only members inside 10 yalms.

**Behaviour change:** **yes, Retail range only.** Switch: Extended range, or `SQUAD_BARD_WALK.cfg.songReach = false`. The casters group (Ballad) is not touched.

**Commits:** `4864cdd770`

**Files:** `modules/custom/lua/squad_bard_walk.lua`

**Test steps:**
1. Engage a monster with the three melee mates standing on opposite sides of it. Expected: the Bard walks to a spot within 9 yalms of each of them (the `[bard walk]` line in `xi_map.log` lists every member and `!bard debug` prints her spot) and sings March and Minuet; all three melee mates get both. See it in: status icons; `!bard debug`.
2. `!bard debug` with the fighters bunched together. Expected: the spot is the old one (the middle of them).
3. Set `SQUAD_BARD_WALK.cfg.songReach = false` (console). Expected: the old spot, step 1 shows the far mate without the song.

**Revert:** the switch, or revert the commit.

**Proof mark:** **proof carried.** squad_bard_walk.lua is untouched upstream.

</details>

<details>
<summary><b>SQ-11</b> Corsair and Geomancer stand where their area effect reaches: <i>proof carried</i></summary>

**What:** a Corsair rolls 8 yalms around herself and was held 10 yalms from the foe; a Geomancer's aura is 6 yalms plus the hitbox and she was held 14 yalms from the foe. COR now stands 6 (lowest 4), GEO 5 (lowest 4). Other jobs keep their range.

**Why:** EN-01 (Corsair); the aura always obeyed its radius (Geomancer).

**Behaviour change:** **yes.** COR on Retail range only, GEO always. Switch: `SQUAD_SPACE.reach = false`.

**Commits:** `a8e6f71011`

**Files:** `modules/custom/lua/squad_space.lua`

**Test steps:**
1. Engage a monster. Expected: the COR mate stands about 6 yalms from it (`SQUAD_SPACE.debug = true` prints "holds 6 yalms from <foe>" in the map log); the fighters at the monster get her roll. See it in: the fighters' status icons (the roll).
2. GEO. Expected: she stands about 5 yalms from the foe and the Indi aura covers the fighters. See it in: status icons of the fighters; the map log line.
3. `SQUAD_SPACE.reach = false`, new fight. Expected: COR 10, GEO 14 as before.

**Revert:** the switch, or revert the commit.

**Proof mark:** **proof carried.** squad_space.lua is untouched upstream.

</details>

<details>
<summary><b>EN-11</b> Songs in squad party rules reach only their radius: <i>proof carried</i></summary>

**What:** a squad rule such as "a melee member lacks Minuet > Minuet" no longer picks a member 10 to 15 yalms away, where the song (radius 10) cannot reach. A song's valid target value (129) was not recognised, so the rule's reach was a flat 15 yalms.

**Why:** EN-01 (Retail range). Where a song stops at its radius, a rule that keeps choosing a member just outside it would recast the song for the same member for ever.

**Behaviour change:** **yes, with Retail range only** (the default). Extended keeps the old 15 yalms. Switch: `TRUST_AOE_RANGE`.

**Commits:** `e16f62883d`

**Files:** `src/map/ai/helpers/gambits_container.cpp`, `src/map/ai/helpers/gambits_reach.h`, `src/test/tests/gambits_reach_tests.cpp`

**Test steps:**
1. Put the melee mate 12 yalms from the Bard (hold the player so the mate stands off; measure with the target distance readout). Engage a monster. Expected: the Bard does not sing Minuet for that mate. She sings once the mate is within 10 yalms. See it in: the Bard's casting bar, the mate's status icons.
2. Set `TRUST_AOE_RANGE` to `'extended'`, restart the map server, repeat step 1. Expected: as v0.3.2: the Bard sings, the mate gets Minuet at 12 yalms. See it in: status icons.
3. Back to Retail. Mate at 8 yalms. Expected: she sings once and the mate gets Minuet; no second cast for the same mate while it lasts.

**Revert:** choose Extended, or revert the commit.

**Proof mark:** **proof carried.** gambits_reach and gambits_container are untouched upstream.

</details>

<details>
<summary><b>EN-12</b> Ordinary trusts and area abilities reach only their radius: <i>proof carried</i></summary>

**What:** Kupipi's Protectra and Shellra, Qultada's rolls and other stock trust rules that spread an area effect from the caster stop at the radius (Protectra 10, rolls 8, Warcry 14) instead of the flat 15 yalms. Cures, Haste and single target abilities are untouched.

**Why:** EN-01. With Retail range the stock trusts would otherwise waste MP and recasts on a member just outside the circle.

**Behaviour change:** **yes, with Retail range only.** Extended is v0.3.2.

**Commits:** `a0285977f9`

**Files:** `src/map/ai/helpers/gambits_container.cpp`, `src/map/ai/helpers/gambits_reach.h`, `src/test/tests/gambits_reach_tests.cpp`

**Test steps:**
1. A trust 12 yalms from Kupipi without Protect, another 5 yalms away without Protect. Engage a monster. Expected: Kupipi casts Protectra for the one at 5; the one at 12 is left until it is within 10; no repeated Protectra casts for the one at 12. See it in: Kupipi's MP, the party list status icons, the combat log.
2. Qultada, a trust at 12 yalms. Expected: no roll is started for that trust alone; with the trust at 6 yalms the roll is used. See it in: the combat log (Corsair's Roll line).
3. Set Extended, restart. Expected: Kupipi casts for the trust at 12 as in v0.3.2. See it in: the party list status icons.

**Revert:** choose Extended, or revert the commit.

**Proof mark:** **proof carried.** gambits_reach and gambits_container are untouched upstream.

</details>

<details>
<summary><b>EN-13</b> An area rule that does not converge rests for that member: <i>proof carried</i></summary>

**What:** a rule that spreads an area effect from the caster and has cast three times in 30 seconds on a member who still matches it skips that member for 45 seconds, then tries again. A safety net behind EN-11 and EN-12 for cases they cannot know about.

**Why:** EN-11, EN-12.

**Behaviour change:** **yes, Retail range only, area rules only.** Other rules are not counted.

**Commits:** `bb7a0996db`

**Files:** `src/map/ai/helpers/gambits_backoff.h`, `src/map/ai/helpers/gambits_container.cpp`, `src/map/ai/helpers/gambits_container.h`, `src/test/CMakeLists.txt`, `src/test/tests/gambits_backoff_tests.cpp`

**Test steps:**
1. Use a member the 10 yalm check accepts but the area effect still misses (the harness can place a member so; a member the effect cannot take, such as one at full Protect that is not refreshed, is not this case). Engage. Expected: Kupipi casts Protectra at most 3 times on that member in the first 30 seconds, then goes on with other rules and other members for 45 seconds, then tries once more. See it in: Kupipi's MP drops three times, then holds.
2. A member who takes the buff normally. Expected: one cast, no rest.

**Revert:** choose Extended, or revert the commit.

**Proof mark:** **proof carried.** New file and gambits_container, untouched upstream.

</details>

<details>
<summary><b>EN-14</b> NO_MOVE comment: <i>proof carried</i></summary>

**What:** the comment on `NO_MOVE` said the trust repositions "within 9.0 of both" the master and the target; the code paths to the target only. Comment only.

**Behaviour change:** none. Files touched: server `src/map/ai/controllers/trust_controller.cpp`. Revert: revert the commit.

**Commits:** `792151c978`

**Files:** `src/map/ai/controllers/trust_controller.cpp`

**Test steps:**
none (a comment). Check the diff: only the comment line changes. Expected: no code line differs. See it in: `git show` of the commit.

**Revert:** revert the commit. Check: the comment reads as before.

**Proof mark:** **proof carried.** A comment in trust_controller.cpp.

</details>

<details>
<summary><b>EN-06</b> Null spell guard in the trust cast (crash fix): <i>proof carried</i></summary>

**What:** `CTrustController::Cast` looked up the spell and used it without checking. A script that casts a spell id that is not in `spell_list` (for example `castSpell(60000)` on a trust) crashed the map server about two seconds later (access violation). It now stops and returns. A known spell is untouched. The same code is in upstream HEAD.

**Why:** any add-on that passes a spell id from its own tables; one bad id must not take the server down.

**Behaviour change:** none for valid ids.

**Commits:** `6792634cf1`

**Files:** `src/map/ai/controllers/trust_controller.cpp`

**Test steps:**
1. `!exec for _, m in pairs(player:getPartyWithTrusts()) do if m:isTrust() then m:castSpell(60000, player) end end`.   Expected: nothing happens, the map server stays up; the log may show `Spell ID (60000) exceeds MAX_SPELL_ID`. Before the fix the map server crashed about 2 s later.   See it in: the map log, the server window.
  2. A mate casts Cure on you.   Expected: as before.

**Revert:** revert the commit.

**Proof mark:** **proof carried.** trust_controller.cpp is untouched upstream.

</details>

<details>
<summary><b>SC-05</b> Stopped mates do not answer chat orders (G15): <i>proof carried</i></summary>

**What:** A mate that is stopped (`!idle on`, Actions OFF, `SQUAD_IDLE`) or owned by another system (`ADDON_OWNED`) is not asked by `cure`, `sneak`, `2hr`. Before, stopped did not mean nothing for chat.

**Why:** an add-on (an add-on owned mate acts through its own lines) and the rule 'stopped means nothing'.

**Behaviour change:** yes: a stopped mate stays silent. Bug fix. Switch: `!sqreq off`.

**Commits:** `38c8497ca8`

**Files:** `modules/custom/lua/squad_logic.lua`, `modules/custom/lua/squad_requests.lua`, `modules/init.txt`

**Test steps:**
1. `!idle on`. Type `cure me` (hurt first if you like). Expected: No mate answers (all are stopped). See it in: party chat log.
2. `!idle off`, then stop one mate only with `!squad sw <slot> all off` (Actions OFF). Expected: `cure me` is answered by another mate, never by the stopped one. See it in: party chat log.
3. `!sqreq off` and repeat step 1. Expected: The stopped mate answers (the v0.3.2 behaviour). See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new; init.txt only gained lines.

</details>

<details>
<summary><b>SC-06</b> Typing the same line again does not cast again (G16): <i>proof carried</i></summary>

**What:** An accepted cast keeps (spell, person) taken for its cast time plus 2 s. A repeat is ignored. Before, the mate that was mid-cast said busy and the next mate cast the same spell on the same person. Attack spells are not claimed.

**Why:** One cast per request; the bots use the same claim (SC-11).

**Behaviour change:** yes: the repeat is ignored. Bug fix. Switch: `!sqreq off`.

**Commits:** `a08da4cb2b`

**Files:** `modules/custom/lua/squad_logic.lua`, `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. Type `sneak` and one second later `sneak` again (two mates can Sneak). Expected: One Sneak, from one mate. The second line does nothing. See it in: party chat log, status icons.
2. Wait 12 seconds, type `sneak` again. Expected: A new Sneak is cast. See it in: party chat log.
3. `!sqreq off`, repeat step 1. Expected: A second mate casts Sneak too (the v0.3.2 behaviour). See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-07</b> "all <spell>" casts once (G2): <i>proof carried</i></summary>

**What:** `all protect` made every able mate cast Protect on you (three casts, three lines). For a spell that goes on a person it is now one cast and one line. For attack spells `all stone` still means every mate that can.

**Why:** Group targets (SC-18) are the extra that gives `all` the meaning 'everyone gets it'.

**Behaviour change:** yes. Bug fix. Switch: `!sqreq off`.

**Commits:** `0cfbc12aaa`

**Files:** `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. Type `all protect` with three mates able to. Expected: You get Protect once, from one mate, with one line. See it in: status icons, party chat log.
2. Type `all stone` at an enemy. Expected: Every mate that has Stone casts it. See it in: battle log.
3. `!sqreq off`, repeat step 1. Expected: Three Protects and three lines (v0.3.2). See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-08</b> A spell that only works on its caster is refused honestly (G6): <i>proof carried</i></summary>

**What:** Warp, Escape, Reraise, Utsusemi and Tonko cannot be put on you. `warp` got a false 'On it' or 'nothing to cast on'. One mate now says the spell only takes its caster; nothing is cast.

**Why:** Honest answers; An add-on asks the right spell (Warp II) itself.

**Behaviour change:** yes: one true line instead of a false one. Bug fix. The audit could not verify in the engine what the old unnamed request did, so this item has no engine before/after. Switch: `!sqreq off`.

**Commits:** `09d62a7ef1`

**Files:** `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. Type `warp`, `escape`, `reraise`, `utsusemi ichi`. Expected: One line from one mate that it only works on the caster. No cast. You are not warped. See it in: party chat log.
2. Type `sneak`. Expected: Still casts (a spell that can go on you). See it in: party chat log.
3. `!sqreq off`, type `warp`. Expected: The old answer (a line, maybe a cast): v0.3.2 behaviour. See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-09</b> Raise goes on the fallen and "raise" finds them (G9): <i>proof carried</i></summary>

**What:** `raise` while you stood and a friend lay dead was 'nothing to cast on'. With nobody named, Raise goes on you if you are down, else on the first fallen member of the party; with nobody down one mate says so. A named target works as before.

**Why:** A usable Raise by chat.

**Behaviour change:** yes. Bug fix. Switch: `!sqreq off`.

**Commits:** `a5534c771d`

**Files:** `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. A friend in your party is knocked out, you stand. Type `raise`. Expected: A mate with Raise casts it on the friend, one line. See it in: party chat log.
2. Nobody down, type `raise`. Expected: One mate says nobody needs a Raise. No cast. See it in: party chat log.
3. You are knocked out, type `raise`. Expected: A mate raises you. See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-10</b> The acknowledgement comes when the cast landed (G5): <i>proof carried</i></summary>

**What:** 'On it: Sneak!' came when the engine accepted the cast, even if it was interrupted. For spells that leave an effect (Sneak, Invisible, Deodorize, Haste, Protect, Shell, Blink, Stoneskin, Phalanx, Regen, Refresh, Aquaveil) the line comes once the effect is on; if it is not on after three looks, one line says it did not land and asking again works. Cure, Raise and attacks are answered at accept as before.

**Why:** Honest failures.

**Behaviour change:** yes: the line comes a few seconds later, and failure is said. Bug fix. Switch: `!sqreq off`.

**Commits:** `52bf79b0a1`

**Files:** `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. Type `sneak`. Expected: No line at once; after the cast (about 8 s) the mate says its line and Sneak is on you. See it in: party chat log, status icons.
2. Type `sneak` and interrupt the caster (hit it, or move it away). Expected: One line that it did not land; typing `sneak` again casts. See it in: party chat log.
3. Type `cure me`. Expected: The line comes at once. See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua is new.

</details>

<details>
<summary><b>SC-11</b> One answerer between squad mates and bots (G1): <i>proof carried</i></summary>

**What:** A mate and a bot that both could Sneak you got two Sneaks and two lines. A request a mate took is marked; the bots' own request code asks before it acts (a spell request whose (spell, person) a mate has is skipped, chatter is not added to a line a mate took). A bot that casts claims the same way. If no mate can, the bots keep the line.

**Why:** One voice per request.

**Behaviour change:** yes. Bug fix. Switch: `!sqreq off`.

**Commits:** `2a0f392839`

**Files:** `modules/custom/lua/bots.lua`, `modules/custom/lua/squad_logic.lua`, `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. Have a squad and a bot player in your party. Type `sneak`. Expected: One Sneak, one voice (the mate's). See it in: party chat log.
2. Dismiss the squad, type `sneak`. Expected: The bot answers (it keeps the line when no mate can). See it in: party chat log.
3. `!sqreq off`, call the squad back, type `sneak`. Expected: A mate and a bot both answer (v0.3.2). See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** squad_requests.lua and bots.lua are untouched upstream.

</details>

<details>
<summary><b>SC-12</b> The chat helper does not answer a request as conversation (G19): <i>RE-TEST</i></summary>

**What:** 'sneak me' was also a conversation line for the squad chat helper, so a mate could answer it in character with a line unrelated to who casts. squad.cpp now reads the line for requests first and `xi.squad.onPartyChat` leaves a taken line alone. Conversation is passed on as before.

**Why:** One voice per request.

**Behaviour change:** yes. Bug fix. Switch: `!sqreq off` (the C++ order change stays; it is harmless without the Lua side).

**Commits:** `0596d9225c`

**Files:** `modules/custom/cpp/squad.cpp`, `modules/custom/lua/squad.lua`

**Test steps:**
1. With the chat helper running (`!squad chat on`), type `sneak me`. Expected: The mate that casts speaks; no other mate replies with chat about it. See it in: party chat log.
2. Type `how is everyone doing`. Expected: The helper answers as before. See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit and rebuild.

**Proof mark:** **RE-TEST.** Touches squad.cpp (the same file as upstream's new gear pool function) and squad.lua onPartyChat; different functions, merged clean. Rebuild plus 'sneak me' confirms.

</details>

<details>
<summary><b>SC-13</b> Bots read apostrophes like the squad mates (G10): <i>proof carried</i></summary>

**What:** Auto-translate already reaches the bots as plain words in v0.3.2 (`bots.cpp` `plainChat`). What was left: the bots kept the apostrophe, so `Mage's Ballad` was the key MAGE'S_BALLAD (no such spell) and the bot answered with chatter. Apostrophes are dropped.

**Why:** Songs and spells with apostrophes asked of bots.

**Behaviour change:** yes. Bug fix. Switch: `!sqreq off`.

**Commits:** `0eb82019fb`

**Files:** `modules/custom/lua/bots.lua`, `modules/custom/lua/squad_requests.lua`

**Test steps:**
1. With a bot BRD in the party type `mage's ballad`. Expected: The bot casts Mage's Ballad. See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** bots.lua is untouched upstream.

</details>

<details>
<summary><b>SC-14</b> Bots cast Raise only on the fallen (G9, bots): <i>proof carried</i></summary>

**What:** A bot said 'sure, raise coming' and cast Raise at you while you stood. Now Raise goes on the first fallen member (or you if you are down); nobody down: no cast, and a bot you named says so.

**Why:** Honest bots.

**Behaviour change:** yes. Bug fix. Switch: `!sqreq off`.

**Commits:** `3767547f92`

**Files:** `modules/custom/lua/bots.lua`

**Test steps:**
1. Bot WHM in the party, nobody down. Type `raise`. Expected: No cast, no 'sure'. `belan raise` (the bot's name): the bot says you are standing. See it in: party chat log.
2. A friend is down, type `raise`. Expected: The bot raises the friend. See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** bots.lua is untouched upstream.

</details>

<details>
<summary><b>SC-15</b> Bots do not promise a self-only spell (G6, bots): <i>proof carried</i></summary>

**What:** A bot said 'sure, warp coming' and cast Warp at you, which the server refuses. It no longer promises it; a bot you named says the spell only works on itself.

**Why:** Honest bots.

**Behaviour change:** yes. Bug fix. Switch: `!sqreq off`.

**Commits:** `63b07c9c38`

**Files:** `modules/custom/lua/bots.lua`

**Test steps:**
1. Bot in the party, type `warp`. Expected: No 'sure', no cast. `belan reraise`: 'reraise only works on myself'. See it in: party chat log.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** bots.lua is untouched upstream.

</details>

<details>
<summary><b>SC-16</b> Bot orders: every bot obeys, one answers (G18): <i>proof carried</i></summary>

**What:** `follow`, `stay`, `attack`, `stop` were obeyed by every bot in the party and each said its own line. Every bot still obeys; one says its line.

**Why:** Less spam with a full party of bots.

**Behaviour change:** yes. Bug fix. Switch: `!sqreq off`.

**Commits:** `aabb52a947`

**Files:** `modules/custom/lua/bots.lua`

**Test steps:**
1. Two or more bots in the party. Type `follow`. Expected: All follow you; one says 'k, following'. See it in: party chat log, bot movement.

**Revert:** `!sqreq off`, or revert the commit.

**Proof mark:** **proof carried.** bots.lua is untouched upstream.

</details>

<details>
<summary><b>SC-D2</b> Squad request extras on by default: <i>new in v0.3.3a</i></summary>

**What:** The request extras (SC-17 to SC-23: looser words, group targets, best tier, needed or not, one caster for 'sneak and invis', one Teleport price, food) are on until a player turns them off. The choice is the character variable `SQREQ_MORE_OFF` (1 = off); a player who typed `!sqreq more on` before stays on.

**Why:** Players asked for the extras by default; the switch is still one command.

**Commits:** `eb4280ce0d`

**Files:** `modules/custom/lua/squad_requests.lua`, `modules/custom/lua/squad_requests_data.lua`

**Test steps:**
1. `!sqreq`. Expected: 'fixes ON, extras ON (!sqreq more off turns them off)'.
2. `sneak please`. Expected: a mate sneaks you (one answer).
3. `!sqreq more off`, then `sneak please`. Expected: nothing (the stock chat). `!sqreq more on` brings it back.
4. Note: with the extras on, a Teleport asked of a bot in party chat costs the shout's gil price (SC-22).

**Revert:** `!sqreq more off` per player, or revert the commit.

**Proof mark:** **new in v0.3.3a.** A default change, one line; steps in the test plan.

</details>
