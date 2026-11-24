# Revamped hook points (v0.3.3 baseline)

Branch `v033/revamped-hooks`, based on tag v0.3.2 of xi-forever-offline-server. Companion kit branch: `v033/revamped-shells` in xi-forever-offline.

## What this is, in plain words

Add-ons that run your own squad mates through their own rules, and Squads Revamped (a one-window Squads panel), are separate server packages. Until now, installing them meant editing `squad.lua`, three other Squads files and `init.txt` with a patch tool. This branch puts those edit points in the tree ahead of time, so a package is "copy files over the placeholders" and no installer has to edit anything.

On its own this branch changes nothing a player can see or feel. Every hook is a no-op until a Revamped package is installed, and the placeholders are empty files.

## What is in the tree

1. **`modules/custom/lua/squad.lua`: the hooks (seam version 1 and 2).** Marked blocks, each nil safe:
   - spawn hook and the early-return hook (jobs Squads has no rules for: SCH, DNC, RUN, GEO): if the master's character variable `ADDON_OWN_<slot>` is above 0, the mate is marked `ADDON_OWNED` and Squads builds nothing for her. Nothing writes that variable here, so it is never above 0.
   - thief gate and team gate: `ADDON_OWNED == 0` added to the thief tick and around `squadTeamTick`. Always true here, so Squads runs as before.
   - reapply gate: `!squad reapply` skips a mate `ADDON_OWNER.owns(player, trust)` says an add-on owns. The placeholder answers no for everyone.
   - `SQUAD_SEAM_V1 = { version = 1 }` and `SQUAD_SEAM = { version = 2 }` at the end of the file: a package checks them and refuses to act if they are missing.
   - five version 2 hooks (`sr_command`, `sr_panel`, `sr_spawn`, `sr_tick`, `sr_gambit`) that call the global `SQUAD_PROFILE` when it exists. No file here defines it, so they do nothing.
2. **`modules/custom/lua/squad_bard_walk.lua`: one guard.** The Bard walk skips a Bard whose `ADDON_OWN_<slot>` is above 0 (never, here).
3. **34 empty placeholder files plus `addon_owner.lua`** in `modules/custom/lua/` (`xk_*.lua` and `sq_*.lua` loaders, the same names and order the Squads Revamped installer uses), each starting with `-- REVAMPED_STUB v1`, listed in `modules/init.txt` as one commented group right after `custom/lua/squad.lua`, and `custom/lua/addon_owner.lua` at the end of the file (after `custom/lua/squad_bard_walk.lua`, where the Squads Revamped guard tool puts it), with the comment line that tool writes. The 34 loaders contain only `return {}`. `addon_owner.lua` defines `ADDON_OWNER` with `owns()` always false.
4. **`tools/revamped/test_revamped_hooks.py`**: the test.

Deliberately NOT in the tree, because they change what the old Squads does while no package is installed: the `actions_gate` guard (squad_actions.lua), the `ruleset_off` guard (squad_rulesets.lua), and switching `gambits_squad.lua` and `squad_actions.lua` off in `init.txt`. The package installer still does those three, as it does today. `squad_reload.lua` (the hot reload bundle) is also left out: it is a developer tool, not a hook.

## Files touched

`modules/init.txt` (one group of 35 lines and two more lines at the end), `modules/custom/lua/squad.lua`, `modules/custom/lua/squad_bard_walk.lua`, 35 new files in `modules/custom/lua/`, `docs/REVAMPED-HOOKS.md`, `tools/revamped/test_revamped_hooks.py`.

## Turn it off or revert

- Drop the placeholders: delete the group of lines under `# Revamped hook points` and the `custom/lua/addon_owner.lua` line (with its comment) from `modules/init.txt`. Nothing refers to them; the server starts exactly as before (the hooks in squad.lua stay inert).
- Take the hooks out of squad.lua: the blocks are marked `-- SQUAD_SEAM v2 begin <name>` / `end`; the Squads Revamped tool `seam_v2.py --undo` removes the version 2 blocks and `revert_seam.py` the version 1 ones. Or `git revert` the branch.

## Test steps

Automated: from the repository root, `python tools/revamped/test_revamped_hooks.py` expects `Ran 11 tests ... OK`.

In game (a throw-away server copy and the launcher; not a live install):
1. Build or take the v0.3.2 server with this branch's `modules` folder. Start it. Expected: it starts, and in the server log there is no Lua error that names `squad.lua`, `addon_owner.lua`, `xk_*` or `sq_*`.
2. Log in, open the Squads menu, call two mates, set a role, send them to fight a monster. Expected: identical to v0.3.2 (they follow, fight, heal, and Apply now works).
3. Type `!squad reapply`. Expected: the mates are dismissed and called again; no line says "An add-on owns".
4. With an add-on test build only: `addon_owner.lua` is replaced (or the add-on sets `ADDON_OWNER.owns` itself); GM `!exec print(ADDON_OWNER.stub)` prints `nil` (the placeholder says `true`).
5. In the server's `modules/custom/lua`, open any `sq_*.lua`: it is the empty placeholder (about 4 lines) until the package replaces it.

## Our proof

`python tools/revamped/test_revamped_hooks.py`: see the run in the branch report. The hooks come from Squads Revamped's own `apply_seam.py` (seam version 1), `seam_v2.py` and `apply_guards.py` (`bard_walk_gate` and the init step), dry-run clean on the v0.3.2 tree, then applied. Not run on a live server: steps 1 to 5 are for Jon's test, not marked passed.
