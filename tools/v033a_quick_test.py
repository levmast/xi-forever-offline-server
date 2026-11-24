#!/usr/bin/env python3
"""v0.3.3a quick test (server): every automated check of this repository's additions, one command, PASS/FAIL per check.

    python tools/v033a_quick_test.py            (from the repository root; needs Python 3 and the `lupa` package: pip install lupa)

No server, no database, no build; nothing is written. Runs:
  1. tools/core_files/run_checks.py        generated tables are current + the core Lua tests
  2. tools/revamped/test_revamped_hooks.py the Revamped hook points are harmless
  3. every other modules/custom/tests/test_*.lua (Squads item commands, item names, Squad Role clarity)
The C++ unit tests (src/test) are built and run by the normal server build (ctest); they are not part of this command.
"""
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA_DIR = os.path.join(ROOT, "modules", "custom", "lua")
GAMBITS = os.path.join(ROOT, "scripts", "globals", "gambits.lua")
JA_ENUM = os.path.join(ROOT, "scripts", "enum", "job_ability.lua")
SQL = os.path.join(ROOT, "sql")


def run_lua_file(path):
    """Child mode: python v033a_quick_test.py --lua <test.lua>  (the test's own failures exit non-zero)."""
    try:
        from lupa.luajit21 import LuaRuntime
    except ImportError:
        from lupa import LuaRuntime
    rt = LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    name = os.path.basename(path)
    extra = {"test_squad_item_commands.lua": [GAMBITS, JA_ENUM, SQL], "test_squad_item_names.lua": [SQL]}.get(name, [GAMBITS, JA_ENUM])
    args = [path, LUA_DIR] + extra
    g.arg = rt.table_from({i: v.replace("\\", "/") for i, v in enumerate(args)})
    with open(path, encoding="utf-8") as f:
        failed = rt.execute(f.read())
    return int(failed or 0) if isinstance(failed, (int, float)) else 0


def defaults_check():
    """Child mode: the v0.3.3a defaults are in the files (map.TRUST_AOE_RANGE retail, Bard casters group on, request extras on)."""
    def read(*parts):
        with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
            return f.read()
    checks = [("map.TRUST_AOE_RANGE default is retail", "TRUST_AOE_RANGE = 'retail'" in read("settings", "default", "map.lua")),
              ("Bard casters group (mageSwitch) is on", "mageSwitch = true" in read("modules", "custom", "lua", "squad_bard_walk.lua")),
              ("request extras are on unless turned off", "charVar(player, 'SQREQ_MORE_OFF') ~= 1" in read("modules", "custom", "lua", "squad_requests.lua"))]
    for label, good in checks:
        print(("ok   " if good else "FAIL ") + label)
    return 0 if all(good for _, good in checks) else 1


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--defaults":
        return defaults_check()
    if len(sys.argv) == 3 and sys.argv[1] == "--lua":
        return 1 if run_lua_file(sys.argv[2]) else 0
    jobs = [("core files: generated tables + core Lua tests", [sys.executable, os.path.join(ROOT, "tools", "core_files", "run_checks.py")]),
            ("Revamped hook points are harmless", [sys.executable, os.path.join(ROOT, "tools", "revamped", "test_revamped_hooks.py")])]
    jobs.append(("v0.3.3a defaults are in place", [sys.executable, os.path.abspath(__file__), "--defaults"]))
    for path in sorted(glob.glob(os.path.join(ROOT, "modules", "custom", "tests", "test_*.lua"))):
        name = os.path.basename(path)
        if name.startswith("test_core_"):
            continue                                   # run by run_checks.py above
        jobs.append((name, [sys.executable, os.path.abspath(__file__), "--lua", path]))
    bad = 0
    for label, cmd in jobs:
        result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        ok = result.returncode == 0
        print(("PASS  " if ok else "FAIL  ") + label)
        if not ok:
            bad += 1
            print("      " + "\n      ".join((result.stdout + result.stderr).strip().splitlines()[-12:]))
    print("\nALL %d CHECKS PASS" % len(jobs) if not bad else "\n%d of %d CHECKS FAILED" % (bad, len(jobs)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
