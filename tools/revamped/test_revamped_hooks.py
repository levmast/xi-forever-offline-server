"""Revamped hook points in the server tree (branch v033/revamped-hooks). Run from the repository root:
    python tools/revamped/test_revamped_hooks.py        (needs lupa; reads the files only, starts no server)
Proves: every placeholder is a harmless empty file and is listed in init.txt in the right place; addon_owner.lua answers "no";
squad.lua carries each hook exactly once and still compiles; squad_bard_walk.lua carries its guard once; nothing the hooks read
can be true without a Revamped package (no ADDON_OWN_<slot> character variable is ever written by anything in the tree).
"""
import os
import re
import sys
import unittest

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MOD = os.path.join(ROOT, "modules")
LUA = os.path.join(MOD, "custom", "lua")
TAG = "-- REVAMPED_STUB v1"


def text(*parts):
    with open(os.path.join(*parts), encoding="utf-8", newline="") as f:
        return f.read()


def init_lines():
    return [ln.strip() for ln in text(MOD, "init.txt").replace("\r\n", "\n").split("\n")]


def stubs():
    return sorted(f for f in os.listdir(LUA) if f.endswith(".lua") and text(LUA, f).startswith(TAG))


class Hooks(unittest.TestCase):
    def test_there_are_35_placeholders(self):
        self.assertEqual(len(stubs()), 34 + 1)          # 34 loaders + addon_owner

    def test_every_placeholder_is_listed_once(self):
        lines = init_lines()
        for f in stubs():
            self.assertEqual(lines.count("custom/lua/" + f), 1, f)

    def test_loaders_follow_squad_lua_and_addon_owner_follows_bard_walk(self):
        lines = init_lines()
        # (v0.3.3a) the v0.3.3 Squads Lua parts (squad_logic, sq_logic, squad_requests) load right after squad.lua; the placeholders follow them
        sq = max(lines.index(x) for x in ("custom/lua/squad.lua", "custom/lua/squad_logic.lua", "custom/lua/sq_logic.lua", "custom/lua/squad_requests.lua") if x in lines)
        self.assertEqual(lines[sq + 1].startswith("# Revamped hook points"), True)
        self.assertEqual(lines[sq + 2], "custom/lua/xk_profiles.lua")
        bw = lines.index("custom/lua/squad_bard_walk.lua")
        own = lines.index("custom/lua/addon_owner.lua")
        self.assertGreater(own, bw)                                          # the engine loads after squad_bard_walk
        self.assertTrue(lines[own - 1].startswith("# An add-on that runs squad mates (guards v1)"))   # the line the guard tool writes, so it reports "applied"
        # the old Squads files stay on: nothing switched off by default
        for keep in ("custom/lua/gambits_squad.lua", "custom/lua/squad_actions.lua", "custom/lua/squad_idle.lua"):
            self.assertIn(keep, lines)

    def test_no_trailing_comment_on_a_path_line(self):
        for ln in init_lines():
            if ln.startswith("custom/lua/"):
                self.assertNotIn("#", ln)             # the loader reads everything after the first character as a path

    def test_placeholders_are_empty(self):
        for f in stubs():
            if f == "addon_owner.lua":
                continue
            code = [ln for ln in text(LUA, f).split("\n") if ln.strip() and not ln.startswith("--")]
            self.assertEqual(code, ["return {}"], f)

    def test_placeholders_define_no_global(self):
        for f in stubs():
            lua = lupa.LuaRuntime()
            before = set(lua.globals().keys())
            lua.execute(text(LUA, f))
            after = set(lua.globals().keys())
            self.assertEqual(after - before, {"ADDON_OWNER"} if f == "addon_owner.lua" else set(), f)

    def test_addon_owner_answers_no(self):
        lua = lupa.LuaRuntime()
        lua.execute(text(LUA, "addon_owner.lua"))
        self.assertFalse(lua.eval("ADDON_OWNER.owns({}, 'x')"))
        self.assertTrue(lua.eval("ADDON_OWNER.stub"))
        # a real add-on replaces the file: its own owns() is not overwritten if it came first
        lua.execute("ADDON_OWNER = { owns = function() return true end }")
        lua.execute(text(LUA, "addon_owner.lua"))
        self.assertTrue(lua.eval("ADDON_OWNER.owns({}, 'x')"))

    def test_squad_lua_hooks_once_and_compiles(self):
        s = text(LUA, "squad.lua")
        for name in ("sr_command", "sr_panel", "sr_spawn", "sr_tick", "sr_gambit", "sr_handshake"):
            self.assertEqual(s.count("-- SQUAD_SEAM v2 begin " + name), 1, name)
            self.assertEqual(s.count("-- SQUAD_SEAM v2 end " + name), 1, name)
        self.assertEqual(len(re.findall(r"^SQUAD_SEAM_V1 = \{ version = 1 \}", s, re.M)), 1)
        self.assertEqual(s.count("local addonSkipped = {}"), 1)                 # the reapply gate
        self.assertEqual(s.count("getLocalVar('ADDON_OWNED') == 0"), 2)         # thief gate and team gate
        from lupa import luajit21                       # the server's own Lua dialect (5.5 refuses upstream's loop-variable assignments)
        lua = luajit21.LuaRuntime()
        ok, err = lua.eval("function(src) local f, e = loadstring(src, 'squad.lua') return f ~= nil, e end")(s)
        self.assertTrue(ok, err)

    def test_bard_walk_guard_once(self):
        s = text(LUA, "squad_bard_walk.lua")
        self.assertEqual(s.count("SQUAD_GUARD v1 bard_walk_gate"), 1)

    def test_nothing_in_the_tree_switches_a_mate_over(self):
        # the hooks fire only for a character variable ADDON_OWN_<slot> above 0 (or a SQUAD_PROFILE global). No file of the tree writes either.
        bad = []
        for dirpath, _dirs, files in os.walk(MOD):
            for f in files:
                if f.endswith(".lua"):
                    s = text(dirpath, f)
                    if re.search(r"setCharVar\(\s*['\"]ADDON_OWN_", s) or re.search(r"^SQUAD_PROFILE\s*=", s, re.M):
                        bad.append(os.path.join(dirpath, f))
        self.assertEqual(bad, [])

    def test_guards_that_change_old_behavior_are_not_applied(self):
        self.assertNotIn("SQUAD_GUARD v1 actions_gate", text(LUA, "squad_actions.lua"))
        self.assertNotIn("SQUAD_GUARD v1 ruleset_off", text(LUA, "squad_rulesets.lua"))


if __name__ == "__main__":
    unittest.main()
