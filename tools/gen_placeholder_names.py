#!/usr/bin/env python3
"""Build modules/custom/lua/placeholder_names_data.lua from the zone mob YAML.

A placeholder (PH) is a member of a spawn slot (mobs.yaml `slots:`) that has no
`chance`, in a slot where at least one other member has a chance > 0 (the
lottery NM). Module data is merged over data/zones/<Zone>/mobs.yaml in
modules/init.txt order, the same way the map server does it (RFC 7396 merge
patch: maps merge, lists replace, null deletes).

Run from the server folder after updating:  python tools/gen_placeholder_names.py
Needs PyYAML.
"""
import os
import sys

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
OUT = os.path.join(ROOT, 'modules', 'custom', 'lua', 'placeholder_names_data.lua')


def module_data_roots():
    roots, seen = [], set()
    with open(os.path.join(ROOT, 'modules', 'init.txt'), encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = [p for p in line.replace('\\', '/').split('/') if p]
            if 'data' in parts:
                root = os.path.join(ROOT, 'modules', *parts)
            else:
                root = os.path.join(ROOT, 'modules', parts[0], 'data')
            key = os.path.normcase(os.path.normpath(root))
            if key not in seen and os.path.isdir(root):
                seen.add(key)
                roots.append(root)
    return roots


def find_ci(directory, name):
    """Case-insensitive child lookup (module folders use lower-case zone names)."""
    if not os.path.isdir(directory):
        return None
    want = name.lower()
    for entry in os.listdir(directory):
        if entry.lower() == want:
            return os.path.join(directory, entry)
    return None


def merge_patch(target, patch):
    if not isinstance(patch, dict):
        return patch
    if not isinstance(target, dict):
        target = {}
    for key, value in patch.items():
        if value is None:
            target.pop(key, None)
        else:
            target[key] = merge_patch(target.get(key), value)
    return target


def load(path):
    with open(path, encoding='utf-8') as f:
        return yaml.safe_load(f) or {}


def look_type(doc, mob_id):
    spawn = (doc.get('spawns') or {}).get(mob_id) or {}
    tmpl = (doc.get('templates') or {}).get(spawn.get('template')) or {}
    look = ((tmpl.get('attributes') or {}).get('render') or {}).get('look') or {}
    return spawn.get('template'), look.get('type', 'standard')


def main():
    roots = module_data_roots()
    zones_dir = os.path.join(ROOT, 'data', 'zones')
    rows, skipped = [], []
    for zone in sorted(os.listdir(zones_dir)):
        core = os.path.join(zones_dir, zone, 'mobs.yaml')
        if not os.path.isfile(core):
            continue
        doc = load(core)
        for root in roots:
            zdir = find_ci(os.path.join(root, 'zones'), zone)
            patch = zdir and find_ci(zdir, 'mobs.yaml')
            if patch:
                doc = merge_patch(doc, load(patch))
        for slot in doc.get('slots') or []:
            members = (slot or {}).get('members') or {}
            nms = [m for m, v in members.items() if (v or {}).get('chance', 0) > 0]
            if not nms:
                continue
            nm_names = sorted({look_type(doc, m)[0] or str(m) for m in nms})
            for mob_id, v in members.items():
                if (v or {}).get('chance', 0) > 0:
                    continue
                name, ltype = look_type(doc, mob_id)
                row = (int(mob_id), zone, name or '?', ', '.join(nm_names))
                # A renamed mob with an equipped (humanoid) look gets its gear overwritten by the name in the
                # update packet (see entity_update.cpp), so those are left alone.
                (rows if ltype == 'standard' else skipped).append(row)

    rows.sort()
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('-----------------------------------\n')
        f.write('-- Placeholder names: data (generated, do not edit by hand)\n')
        f.write('-- Made by tools/gen_placeholder_names.py from data/zones/*/mobs.yaml spawn slots plus module overrides.\n')
        f.write('-- [mob id] = true, -- zone: placeholder mob -> NM\n')
        f.write('-----------------------------------\n')
        f.write('return\n{\n')
        for mob_id, zone, name, nm in rows:
            f.write('    [%d] = true, -- %s: %s -> %s\n' % (mob_id, zone, name, nm))
        f.write('}\n')
    print('%d placeholders in %d zones written to %s' % (len(rows), len({r[1] for r in rows}), OUT))
    for mob_id, zone, name, nm in skipped:
        print('skipped (equipped look): %d %s %s -> %s' % (mob_id, zone, name, nm))


if __name__ == '__main__':
    sys.exit(main())
