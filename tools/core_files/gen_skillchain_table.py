#!/usr/bin/env python3
"""Generate modules/custom/lua/core_skillchain_data.lua: the skillchain properties of every weapon skill and the rules that close a skillchain,
read from the server's own data and source (nothing is guessed from names).

Sources (all inside this repository, read only):
  data/weapon_skills.yaml          `skillchain: [a, b, c]` of each weapon skill: its properties, primary first, as the server fires them
  data/enums/skillchain_type.yaml  the property names and their numbers (the server's xi.skillchainType)
  src/map/utils/battleutils.cpp    skillchain_map (which pair of properties makes which skillchain), GetSkillchainTier (the level of each
                                   skillchain) and GetSkillChainEffect (the timing: the wait before a link may be made, the window, how much
                                   each link shortens it, the most links counted)

Output (the file carries the same field list in its header):
  D.PROPERTY[name] = id, D.property_name[id] = name        the server's skillchain property numbers
  D.TIER[id]       = level of that property (1 .. 4)
  D.CHAIN[resonance][skill] = result                        resonance = the property the target is resonating, skill = a property of the
                                                            weapon skill that is used on it, result = the skillchain that is formed
  D.WS[id] = { name, skill, props = { primary, secondary, tertiary } }   every weapon skill that has properties
  D.TIMING = { delay, window, shrink, max_links }           seconds; links counted up to max_links

Run:  python tools/core_files/gen_skillchain_table.py            write modules/custom/lua/core_skillchain_data.lua
      python tools/core_files/gen_skillchain_table.py --check    exit 1 when the file on disk differs from what the data would give
      python tools/core_files/gen_skillchain_table.py --root <server tree>   (default: this repository)
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(os.path.dirname(HERE))
OUT_REL = os.path.join("modules", "custom", "lua", "core_skillchain_data.lua")


def camel_to_snake(s):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", s).lower()


def read_properties(root):
    out = {}
    in_values = False
    with open(os.path.join(root, "data", "enums", "skillchain_type.yaml"), encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].rstrip()
            if line.strip() == "values:":
                in_values = True
                continue
            m = re.match(r"^\s+([a-z_]+):\s*(\d+)\s*$", line)
            if in_values and m:
                out[m.group(1)] = int(m.group(2))
    if out.get("none") != 0 or out.get("light") != 13 or len(out) != 17:
        raise SystemExit("data/enums/skillchain_type.yaml: the property list is not the 17 entries this generator expects: " + repr(out))
    return out


def read_source(root):
    path = os.path.join(root, "src", "map", "utils", "battleutils.cpp")
    with open(path, encoding="utf-8") as f:
        return f.read()


def read_tiers(text, props):
    m = re.search(r"GetSkillchainTier.*?tiers\[\]\s*=\s*\{(.*?)\};", text, flags=re.S)
    if not m:
        raise SystemExit("battleutils.cpp: GetSkillchainTier table not found")
    nums = [int(x) for x in re.findall(r"^\s*(\d+),", m.group(1), flags=re.M)]
    if len(nums) != len(props):
        raise SystemExit("battleutils.cpp: GetSkillchainTier has %d entries, there are %d properties" % (len(nums), len(props)))
    return nums


def read_chain_map(text, props):
    m = re.search(r"skillchain_map\s*=\s*\{(.*?)\n\};", text, flags=re.S)
    if not m:
        raise SystemExit("battleutils.cpp: skillchain_map not found")
    out = []
    pat = r"\{\s*\{\s*xi::SkillchainType::(\w+),\s*xi::SkillchainType::(\w+)\s*\},\s*xi::SkillchainType::(\w+)\s*\}"
    for skill, resonance, result in re.findall(pat, m.group(1)):
        out.append(tuple(props[camel_to_snake(x)] for x in (skill, resonance, result)))
    if len(out) < 25:
        raise SystemExit("battleutils.cpp: skillchain_map looks wrong (%d entries)" % len(out))
    if len(set((s, r) for s, r, _ in out)) != len(out):
        raise SystemExit("battleutils.cpp: skillchain_map has a pair twice")
    return out   # (skill property, resonance property, result)


def read_timing(text):
    # the three clock values and the link cap of GetSkillChainEffect; each is looked up by its own sentence so a change of shape stops the run
    body = text[text.index("auto GetSkillChainEffect"):]
    body = body[:body.index("\n}\n")]
    delay = re.search(r"PSCEffect->GetStartTime\(\)\s*\+\s*(\d+)s\s*<\s*timer::now\(\)\)\s*\n\s*\{\s*\n\s*if \(PSCEffect->GetTier\(\) == 0\)", body)
    window = re.search(r"SetDuration\((\d+)s\);\s*\n\s*PSCEffect->SetTier\(0\)", body)
    shrink = re.search(r"SetDuration\(PSCEffect->GetDuration\(\)\s*-\s*(\d+)s\)", body)
    cap = re.search(r"std::min\(PSCEffect->GetSubPower\(\)\s*\+\s*1,\s*(\d+)\)", body)
    if not (delay and window and shrink and cap):
        raise SystemExit("battleutils.cpp: GetSkillChainEffect no longer has the timing lines this generator reads")
    return int(delay.group(1)), int(window.group(1)), int(shrink.group(1)), int(cap.group(1))


def parse_ws(path, props):
    out, cur, in_section = [], None, False
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            if not line.startswith(" "):
                in_section = line.strip() == "weapon_skills:"
                cur = None
                continue
            if not in_section:
                continue
            m = re.match(r"^  ([a-z0-9_]+):\s*$", line)
            if m:
                cur = {"name": m.group(1), "id": None, "skill": None, "props": []}
                out.append(cur)
                continue
            if cur is None:
                continue
            m = re.match(r"^    ([a-z_]+):\s*(.*)$", line)
            if not m:
                continue
            k, v = m.group(1), m.group(2).strip()
            if k == "id":
                cur["id"] = int(v)
            elif k == "skill":
                cur["skill"] = v
            elif k == "skillchain":
                names = [x.strip() for x in v.strip("[]").split(",") if x.strip()]
                for n in names:
                    if n not in props:
                        raise SystemExit("unknown skillchain property %r in %s" % (n, cur["name"]))
                cur["props"] = [props[n] for n in names]
    ws = [e for e in out if e["id"] is not None and e["skill"] is not None and e["props"]]
    if len(ws) < 150:
        raise SystemExit("weapon_skills.yaml: only %d weapon skills with properties, the file changed shape" % len(ws))
    if len(set(e["id"] for e in ws)) != len(ws):
        raise SystemExit("weapon_skills.yaml: a weapon skill id is used twice")
    return ws


def render(props, tiers, chain, timing, ws):
    names = sorted(props, key=lambda n: props[n])
    L = [
        "-----------------------------------",
        "-- GENERATED by tools/core_files/gen_skillchain_table.py from data/weapon_skills.yaml, data/enums/skillchain_type.yaml and",
        "-- src/map/utils/battleutils.cpp. Do not edit by hand: run the script again.",
        "-- `python tools/core_files/gen_skillchain_table.py --check` says whether this file is current.",
        "--",
        "--   D.PROPERTY[name] = id, D.property_name[id] = name     the server's skillchain property numbers (xi.skillchainType)",
        "--   D.TIER[id]       = level of the property, 1 .. 4",
        "--   D.CHAIN[resonance][skill] = result     resonance: the property the target is resonating; skill: a property of the weapon skill",
        "--       used on it; result: the skillchain that is formed (a missing entry means no skillchain). The server tries every resonance",
        "--       property, in order, against every property of the skill, in order, and takes the first pair that is in the table.",
        "--   D.WS[weapon skill id] = { name, skill, props = { primary, secondary, tertiary } }   only weapon skills that have properties",
        "--   D.TIMING = { delay, window, shrink, max_links }   seconds: a link may be made after `delay`, the window is `window` and each link",
        "--       shortens it by `shrink`; links are counted up to `max_links`",
        "-- Nothing loads this file by itself: a script reads it with require('modules/custom/lua/core_skillchain_data'),",
        "-- or through modules/custom/lua/core_skillchain.lua, which answers the common questions.",
        "-----------------------------------",
        "local D = {}",
        "D.PROPERTY = { " + ", ".join("%s = %d" % (n, props[n]) for n in names) + " }",
        "D.property_name = {}",
        "for name, id in pairs(D.PROPERTY) do D.property_name[id] = name end",
        "D.TIER = { " + ", ".join("[%d] = %d" % (props[n], tiers[props[n]]) for n in names if props[n] > 0) + " }",
        "D.TIMING = { delay = %d, window = %d, shrink = %d, max_links = %d }" % timing,
    ]
    by = {}
    for skill, res, result in chain:
        by.setdefault(res, {})[skill] = result
    L.append("D.CHAIN = {")
    for res in sorted(by):
        L.append("    [%d] = { %s }," % (res, ", ".join("[%d] = %d" % (s, by[res][s]) for s in sorted(by[res]))))
    L.append("}")
    L.append("D.WS = {")
    for e in sorted(ws, key=lambda e: e["id"]):
        L.append("    [%d] = { name = '%s', skill = '%s', props = { %s } }," % (e["id"], e["name"], e["skill"], ", ".join(str(p) for p in e["props"])))
    L.append("}")
    L.append("return D")
    return "\n".join(L) + "\n"


def build(root):
    props = read_properties(root)
    text = read_source(root)
    tiers = read_tiers(text, props)
    return render(props, tiers, read_chain_map(text, props), read_timing(text), parse_ws(os.path.join(root, "data", "weapon_skills.yaml"), props))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--root", default=DEFAULT_ROOT)
    a = ap.parse_args(argv)
    text = build(a.root)
    dst = os.path.join(a.root, OUT_REL)
    if a.check:
        have = ""
        if os.path.exists(dst):
            with open(dst, encoding="utf-8", newline="") as f:
                have = f.read().replace("\r\n", "\n")
        if have != text:
            print("core_skillchain_data.lua is out of date: run python tools/core_files/gen_skillchain_table.py")
            return 1
        print("core_skillchain_data.lua is up to date")
        return 0
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote", dst)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
