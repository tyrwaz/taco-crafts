#!/usr/bin/env python3
"""One-time: resolve Wowhead iconName for each distinct itemId in data.json and
save icon_map.json ({itemId: "inv_..."}). Uses the <link rel=image_src> on the
classic item page. Call convert.py normally afterward; it reads icon_map.json.
"""
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data.json"
OUT = ROOT / "icon_map.json"
UA = "Mozilla/5.0"


def fetch_icon(id_):
    url = f"https://www.wowhead.com/classic/item={id_}"
    try:
        html = subprocess.run(
            ["curl", "-sL", "-H", f"User-Agent: {UA}", "--max-time", "20", url],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        ).stdout
        m = re.search(r'rel="image_src"[^>]*href="https://wow\.zamimg\.com/images/wow/icons/large/([^"]+)\.jpg"', html)
        if m:
            return m.group(1)
        ic = re.findall(r"inv_[a-z0-9_]+", html)
        if ic:
            return max(set(ic), key=ic.count)
    except Exception as e:
        print(f"  ! id {id_} failed: {e}", file=sys.stderr)
    return None


def main():
    d = json.load(open(DATA, encoding="utf-8"))
    ids = set()
    for p in d.get("professions", []):
        for r in p.get("recipes", []):
            for g in r.get("reagents", []):
                ids.add(g.get("itemId"))
    for m in d.get("materials", []):
        ids.add(m.get("itemId"))
    ids.discard(None)
    ids = sorted(ids)

    # load existing map so re-runs are incremental
    out = {}
    if OUT.exists():
        out = json.load(open(OUT, encoding="utf-8"))

    todo = [i for i in ids if str(i) not in out]
    print(f"distinct ids: {len(ids)}, to resolve: {len(todo)}")
    for i, id_ in enumerate(todo):
        icon = fetch_icon(id_)
        if icon:
            out[str(id_)] = icon
            print(f"  [{i+1}/{len(todo)}] {id_} -> {icon}")
        else:
            print(f"  [{i+1}/{len(todo)}] {id_} -> (none)")
        time.sleep(0.4)  # be polite to wowhead

    OUT.write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(f"wrote {OUT}: {len(out)} icons")
    missing = [i for i in ids if str(i) not in out]
    print(f"still missing: {len(missing)} {missing[:10]}")


if __name__ == "__main__":
    main()
