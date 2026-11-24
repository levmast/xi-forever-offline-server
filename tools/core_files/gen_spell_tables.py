#!/usr/bin/env python3
"""Generate modules/custom/lua/core_spell_data.lua: every spell and job ability of this server with its level, tier, range and target type,
read from the server's own data files (nothing is typed in by hand, nothing is guessed).

Sources (all inside this repository, read only):
  sql/spell_list.sql             spell id, name, level per job (the 22 byte `jobs` column), family, skill, target mask, mp, cast, recast, range
  sql/abilities.sql              ability id, name, job, level, target mask, recast, recast group, range, area flag and radius
  src/map/entities/battle_entity.h  enum TARGETTYPE: the names of the bits of a target mask (self, player_party, enemy, ...)

Output table layout (see the header the file carries for the exact field list):
  D.SPELL[NAME]   = { id, tier, range (yalms), target (bit mask), mp, cast (ms), recast (ms), skill, family, lv = { [jobId] = level } }
  D.ABILITY[NAME] = { id, tier, job, level, range (yalms, 0 = self), target (bit mask), recast (s), recast_id, aoe, radius }
  D.TARGET        = { self = 1, player_party = 2, enemy = 4, ... }   the bit names, from the enum above
  D.spell_by_id[id] = NAME, D.ability_by_id[id] = NAME

A tier is the number a name ends with: roman numerals (Cure II = 2, Fire VI = 6), the ninjutsu forms (Ichi / Ni / San = 1 / 2 / 3); a name with
neither is tier 1. It is derived from the server's own spell and ability names, the server data has no tier column of its own.
Job ids are the server's (1 = WAR ... 22 = RUN; an ability with job 0 or 23 belongs to a group of the data that is not one of the 22 jobs). A level is the one in the data: a main job at that level or above has the spell.

Run:  python tools/core_files/gen_spell_tables.py            write modules/custom/lua/core_spell_data.lua
      python tools/core_files/gen_spell_tables.py --check    exit 1 when the file on disk differs from what the data would give
      python tools/core_files/gen_spell_tables.py --root <server tree>   (default: this repository)
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(os.path.dirname(HERE))
OUT_REL = os.path.join("modules", "custom", "lua", "core_spell_data.lua")

ROMAN = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8}
NINJUTSU = {"ichi": 1, "ni": 2, "san": 3}
SPELL_ROW = re.compile(r"^INSERT INTO `spell_list` VALUES \((\d+),'([a-z0-9_'-]+)',0x([0-9A-Fa-f]{44}),(.*)\);\s*(?:--.*)?$")
ABILITY_ROW = re.compile(r"^INSERT INTO `abilities` VALUES \((.*)\);\s*(?:--.*)?$")


def key_of(name):
    return name.upper().replace("-", "_").replace("'", "")


def tier_of(name):
    last = name.lower().replace("-", "_").split("_")[-1]
    if "_" in name.replace("-", "_") and last in ROMAN:
        return ROMAN[last]
    if "_" in name.replace("-", "_") and last in NINJUTSU:
        return NINJUTSU[last]
    return 1


def read_targets(root):
    path = os.path.join(root, "src", "map", "entities", "battle_entity.h")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"enum TARGETTYPE\s*:\s*uint16\s*\{(.*?)\};", text, flags=re.S)
    if not m:
        raise SystemExit("battle_entity.h: enum TARGETTYPE not found")
    out = {}
    for name, value in re.findall(r"^\s*TARGET_([A-Z_]+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)", m.group(1), flags=re.M):
        out[name.lower()] = int(value, 0)
    if out.get("self") != 1 or out.get("enemy") != 4 or out.get("none") != 0:
        raise SystemExit("battle_entity.h: TARGETTYPE does not start the way this generator expects: " + repr(out))
    return out


def read_spells(root):
    out = []
    with open(os.path.join(root, "sql", "spell_list.sql"), encoding="utf-8", errors="replace") as f:
        for line in f:
            m = SPELL_ROW.match(line)
            if not m:
                continue
            sid, name, jobs, rest = int(m.group(1)), m.group(2), bytes.fromhex(m.group(3)), m.group(4).split(",")
            # rest: group, family, element, zonemisc, validTargets, skill, mpCost, castTime, recastTime, message, magicBurstMessage, animation,
            #       animationTime, AOE, base, multiplier, CE, VE, requirements, spell_range, radius, content_tag, status_effect, status_effect_tier
            if len(rest) < 20:
                raise SystemExit("spell_list.sql: a row of spell %d has %d columns after the jobs, expected 24" % (sid, len(rest)))
            skill = rest[5].strip()
            mp = int(rest[6])
            if skill == "@SKILL_NINJUTSU":
                mp = 0   # a ninjutsu's mpCost column holds the tool item id, not MP
            lv = {job: jobs[job - 1] for job in range(1, 23) if jobs[job - 1] > 0}
            out.append({
                "key": key_of(name), "id": sid, "tier": tier_of(name), "range": int(rest[19]) / 10.0, "target": int(rest[4]),
                "mp": mp, "cast": int(rest[7]), "recast": int(rest[8]), "skill": skill, "family": int(rest[1]), "lv": lv,
            })
    if len(out) < 800:
        raise SystemExit("spell_list.sql: only %d spells found, the file changed shape" % len(out))
    return out


def read_abilities(root):
    out = []
    with open(os.path.join(root, "sql", "abilities.sql"), encoding="utf-8", errors="replace") as f:
        for line in f:
            m = ABILITY_ROW.match(line)
            if not m:
                continue
            f_ = m.group(1).split(",")
            if len(f_) < 16:
                raise SystemExit("abilities.sql: a row has %d columns, expected 21" % len(f_))
            # abilityId, name, job, level, validTarget, recastTime, recastId, message1, message2, animation, animationTime, castTime,
            # actionType, range, isAOE, radius, CE, VE, meritModID, addType, content_tag
            name = f_[1].strip("'")
            out.append({
                "key": key_of(name), "id": int(f_[0]), "tier": tier_of(name), "job": int(f_[2]), "level": int(f_[3]),
                "target": int(f_[4]), "recast": int(f_[5]), "recast_id": int(f_[6]), "range": float(f_[13]),
                "aoe": int(f_[14]), "radius": int(f_[15]),
            })
    if len(out) < 500:
        raise SystemExit("abilities.sql: only %d abilities found, the file changed shape" % len(out))
    return out


def skill_lua(raw):
    name = raw.removeprefix("@SKILL_").lower()
    return name if name.isdigit() else "'" + name + "'"


def num(x):
    return ("%g" % x) if isinstance(x, float) else str(x)


def render(spells, abilities, targets):
    L = [
        "-----------------------------------",
        "-- GENERATED by tools/core_files/gen_spell_tables.py from sql/spell_list.sql, sql/abilities.sql and src/map/entities/battle_entity.h (enum TARGETTYPE).",
        "-- Do not edit by hand: run the script again. `python tools/core_files/gen_spell_tables.py --check` says whether this file is current.",
        "--",
        "--   D.SPELL[NAME]   = { id, tier, range, target, mp, cast, recast, skill, family, lv = { [jobId] = level } }",
        "--       range in yalms, target a bit mask of D.TARGET, cast and recast in milliseconds, skill the server's skill id",
        "--       (ninjutsu mp is 0: the data keeps the tool item there)",
        "--   D.ABILITY[NAME] = { id, tier, job, level, range, target, recast, recast_id, aoe, radius }",
        "--       range in yalms (0 = self), recast in seconds, aoe 0 or 1 and radius in yalms; level 0 with a recast of 3600 is the job's two hour ability",
        "--   tier = the number the name ends with (II = 2, Ichi = 1, Ni = 2, San = 3), 1 when it has none. Job ids: 1 = WAR ... 22 = RUN; an ability with job 0 or 23 belongs to a group of the data that is not one of the 22 jobs.",
        "--   D.spell_by_id / D.ability_by_id give the NAME of an id.",
        "-- Nothing loads this file by itself: a script reads it with require('modules/custom/lua/core_spell_data').",
        "-----------------------------------",
        "local D = {}",
        "D.TARGET = { " + ", ".join("%s = %d" % (k, v) for k, v in sorted(targets.items(), key=lambda kv: kv[1])) + " }",
        "D.SPELL = {",
    ]
    for s in sorted(spells, key=lambda s: s["id"]):
        lv = ", ".join("[%d] = %d" % (j, l) for j, l in sorted(s["lv"].items()))
        L.append("    ['%s'] = { id = %d, tier = %d, range = %s, target = %d, mp = %d, cast = %d, recast = %d, skill = %s, family = %d, lv = { %s } }," % (
            s["key"], s["id"], s["tier"], num(s["range"]), s["target"], s["mp"], s["cast"], s["recast"],
            skill_lua(s["skill"]), s["family"], lv))
    L.append("}")
    L.append("D.ABILITY = {")
    for a in sorted(abilities, key=lambda a: a["id"]):
        L.append("    ['%s'] = { id = %d, tier = %d, job = %d, level = %d, range = %s, target = %d, recast = %d, recast_id = %d, aoe = %d, radius = %d }," % (
            a["key"], a["id"], a["tier"], a["job"], a["level"], num(a["range"]), a["target"], a["recast"], a["recast_id"], a["aoe"], a["radius"]))
    L.append("}")
    L.append("D.spell_by_id, D.ability_by_id = {}, {}")
    L.append("for name, s in pairs(D.SPELL) do D.spell_by_id[s.id] = name end")
    L.append("for name, a in pairs(D.ABILITY) do D.ability_by_id[a.id] = name end")
    L.append("return D")
    return "\n".join(L) + "\n"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--root", default=DEFAULT_ROOT)
    a = ap.parse_args(argv)
    text = render(read_spells(a.root), read_abilities(a.root), read_targets(a.root))
    dst = os.path.join(a.root, OUT_REL)
    if a.check:
        have = ""
        if os.path.exists(dst):
            with open(dst, encoding="utf-8", newline="") as f:
                have = f.read().replace("\r\n", "\n")
        if have != text:
            print("core_spell_data.lua is out of date: run python tools/core_files/gen_spell_tables.py")
            return 1
        print("core_spell_data.lua is up to date")
        return 0
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote", dst)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
