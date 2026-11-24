#!/usr/bin/env python3
"""Run every check of the core files: the generated tables are current (each tools/core_files/gen_*.py --check) and every
modules/custom/tests/test_core_*.lua passes. No server, no database, nothing is written.

  python tools/core_files/run_checks.py              (needs the `lupa` package for the Lua tests: pip install lupa)
  python tools/core_files/run_checks.py --root <server tree>

The Lua tests run on LuaJIT 2.1 through lupa, the same Lua flavour the server uses; they also run with any plain luajit or lua:
  luajit modules/custom/tests/test_core_guard.lua modules/custom/lua
"""

import argparse
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(os.path.dirname(HERE))


def run_lua(path, root):
    lua_dir = os.path.join(root, "modules", "custom", "lua")
    extra = [os.path.join(root, "scripts", "globals", "gambits.lua"), os.path.join(root, "scripts", "enum", "job_ability.lua")]
    if not all(os.path.isfile(x) for x in extra):
        extra = []   # a test that needs them (test_core_channel_advert.lua) asserts its own usage line
    try:
        from lupa.luajit21 import LuaRuntime
    except ImportError:
        try:
            from lupa import LuaRuntime
        except ImportError:
            print("SKIP %s: the lupa package is not installed" % os.path.basename(path))
            return None
    rt = LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.CORE_TEST_HARNESS = True
    g.arg = rt.table_from({i + 1: v.replace("\\", "/") for i, v in enumerate([lua_dir, *extra])})
    with open(path, encoding="utf-8") as f:
        failed = rt.execute(f.read())
    return int(failed or 0)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=DEFAULT_ROOT)
    a = ap.parse_args(argv)
    bad = 0
    for gen in sorted(glob.glob(os.path.join(HERE, "gen_*.py"))):
        r = subprocess.run([sys.executable, gen, "--check", "--root", a.root], capture_output=True, text=True)
        print(("ok   " if r.returncode == 0 else "FAIL ") + os.path.basename(gen) + " --check: " + (r.stdout + r.stderr).strip().splitlines()[-1])
        bad += r.returncode != 0
    for test in sorted(glob.glob(os.path.join(a.root, "modules", "custom", "tests", "test_core_*.lua"))):
        failed = run_lua(test, a.root)
        if failed is None:
            continue
        print(("ok   " if failed == 0 else "FAIL ") + os.path.basename(test))
        bad += failed != 0
    print("all core file checks pass" if not bad else "%d core file check(s) failed" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
