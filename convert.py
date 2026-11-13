#!/usr/bin/env python3
"""TacoCrafts converter: read the addon's SavedVariables Lua -> web JSON.

Locates *Account/TIFFANY1121/SavedVariables/TacoCrafts.lua, parses the
TacoCraftsDB global (a focused Lua literal parser -- our addon only emits
tables, strings, numbers, booleans, nil), and writes data.json for the page.
"""
import json
import re
import sys
from pathlib import Path

GAME_ROOT = Path(r"C:\Program Files (x86)\World of Warcraft\_forever_")
WTF_ACCOUNT = GAME_ROOT / "WTF" / "Account"
OUTPUT = Path(__file__).resolve().parent / "data.json"


# ---------------------------------------------------------------------------
# Focused Lua literal parser (handles exactly what TacoCraftsDB will contain)
# ---------------------------------------------------------------------------
class LuaParseError(ValueError):
    pass


def parse_lua_literal(text: str):
    text = text.strip()
    pos = [0]

    def err(msg):
        raise LuaParseError(f"{msg} at offset {pos[0]}: ...{text[pos[0]:pos[0]+30]}")

    def skip_ws():
        while pos[0] < len(text):
            ch = text[pos[0]]
            if ch.isspace():
                pos[0] += 1
            elif ch == "--":  # comment
                nl = text.find("\n", pos[0])
                pos[0] = len(text) if nl == -1 else nl + 1
            else:
                break

    def parse_string():
        # quoted string; handles escapes \" \\ \n \r \t \z
        quote = text[pos[0]]
        pos[0] += 1
        out = []
        while True:
            if pos[0] >= len(text):
                err("unterminated string")
            ch = text[pos[0]]
            if ch == quote:
                pos[0] += 1
                return "".join(out)
            if ch == "\\" and pos[0] + 1 < len(text):
                nxt = text[pos[0] + 1]
                esc = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"', "'": "'"}
                if nxt in esc:
                    out.append(esc[nxt]); pos[0] += 2
                elif nxt == "z":
                    pos[0] += 2
                    while pos[0] < len(text) and text[pos[0]].isspace():
                        pos[0] += 1
                else:
                    out.append(nxt); pos[0] += 2
                continue
            out.append(ch); pos[0] += 1

    def parse_number():
        m = re.match(r"-?[\d.eE+]+", text[pos[0]:])
        if not m:
            err("expected number")
        s = m.group(0)
        pos[0] += len(s)
        return float(s) if ("." in s or "e" in s.lower()) else int(s)

    def parse_table():
        pos[0] += 1  # {
        result = {}
        order = []
        array_len = 0
        next_index = 1  # implicit array index for bare positional entries
        while True:
            skip_ws()
            if pos[0] >= len(text):
                err("unterminated table")
            if text[pos[0]] == "}":
                pos[0] += 1
                break
            skip_ws()
            key = None
            if text[pos[0]] == "[":
                # [expr] = value  (usually ["string"] or [number])
                pos[0] += 1
                skip_ws()
                if text[pos[0]] in ('"', "'"):
                    key = parse_string()
                else:
                    key = parse_number()
                skip_ws()
                if pos[0] >= len(text) or text[pos[0]] != "]":
                    err("expected ] after key")
                pos[0] += 1
                skip_ws()
                if pos[0] >= len(text) or text[pos[0]] != "=":
                    err("expected = after key")
                pos[0] += 1
                skip_ws()
                val = parse_value()
            else:
                # bare positional entry: { ... }, 123, "str"  -> implicit next_index
                key = next_index
                val = parse_value()
            result[key] = val
            next_index += 1
            if isinstance(key, int) and key == array_len + 1:
                array_len = key
            skip_ws()
            if pos[0] < len(text) and text[pos[0]] == ",":
                pos[0] += 1
            elif pos[0] < len(text) and text[pos[0]] == "}":
                continue
        # if it's dense 1..n array, return as list
        if array_len == len(result):
            return [result[i + 1] for i in range(array_len)]
        return result

    def parse_value():
        skip_ws()
        if pos[0] >= len(text):
            err("unexpected end")
        ch = text[pos[0]]
        if ch == "{":
            return parse_table()
        if ch in ('"', "'"):
            return parse_string()
        if ch.isdigit() or ch == "-":
            return parse_number()
        # bare words: nil / true / false
        m = re.match(r"[A-Za-z_]+", text[pos[0]:])
        if m:
            w = m.group(0)
            pos[0] += len(w)
            if w == "nil":
                return None
            if w == "true":
                return True
            if w == "false":
                return False
            err(f"unsupported bare word {w!r}")
        err("unexpected char")

    return parse_value()


def find_and_parse_savedvar():
    # Forever stores per-character SavedVariables under Account/<acct>/<realm>/<char>/SavedVariables/
    # (e.g. <acct>/91/Kinato-Tyrnth/), plus account-wide at Account/<acct>/SavedVariables/.
    # Search recursively and take the newest TacoCrafts.lua we find.
    candidates = []
    if WTF_ACCOUNT.exists():
        for f in WTF_ACCOUNT.rglob("TacoCrafts.lua"):
            candidates.append(f)
    if not candidates:
        print(f"ERROR: no TacoCrafts.lua found under {WTF_ACCOUNT}", file=sys.stderr)
        print("  Load the addon in game, open the profession window, run /tacocrafts scan, then /reload or log out.", file=sys.stderr)
        sys.exit(2)
    path = max(candidates, key=lambda p: p.stat().st_mtime)
    raw = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"TacoCraftsDB\s*=\s*", raw)
    if not m:
        print(f"ERROR: TacoCraftsDB not found in {path}", file=sys.stderr)
        sys.exit(2)
    body = raw[m.end():]
    # stop at trailing ` }` plus whatever follows (comments) -- parse_lua stops at first top-level }
    return parse_lua_literal(body), path


def primitive(v):
    # JSON-safe copy (drop nil/None that would break render)
    if v is None:
        return None
    if isinstance(v, dict):
        return {str(k): primitive(x) for k, x in v.items() if x is not None}
    if isinstance(v, list):
        return [primitive(x) for x in v]
    return v


def build_export(db, src_path):
    if db is None:
        db = {}  # file parsed to nil (saved-var bug or never persisted) -> empty export
    meta = db.get("meta") or {}
    prof = db.get("profession") or {}
    mats = db.get("materialsList") or []
    profSkill = db.get("professionSkill") or {}
    # if the addon didn't attach rank to the open profession, look it up by name
    prof_level = prof.get("level")
    prof_max = prof.get("maxLevel")
    if (prof_level is None or prof_max is None) and prof.get("name") and profSkill.get(prof["name"]):
        prof_level = profSkill[prof["name"]].get("level") or prof_level
        prof_max = profSkill[prof["name"]].get("maxLevel") or prof_max
    return {
        "schema": 1,
        "character": meta.get("character"),
        "realm": meta.get("realm"),
        "faction": meta.get("faction"),
        "classKey": meta.get("classKey"),
        "updated": meta.get("updated"),
        "professions": [
            {
                "name": prof.get("name"),
                "skillId": prof.get("skillId"),
                "level": prof_level,
                "maxLevel": prof_max,
                "secondary": bool(prof.get("isSecondary")),
                "recipes": [primitive(r) for r in (prof.get("recipes") or [])],
            }
        ] if prof.get("recipes") else [],
        "materials": [primitive(m) for m in mats if m and m.get("count")],
        "professionSkill": primitive(profSkill),
        "_source": str(src_path),
    }


# itemId -> iconName sources: (1) the offline WoW Classic caches repo's Forever Cache.json
# (official client, ~10k gear/drop items), and (2) icon_map.json -- manually-resolved from
# Wowhead via resolve_icons.py for items the cache lacks (herbs, reagents, etc.).
ICON_CACHE_PATH = Path(__file__).resolve().parent / "forever_cache.json"
ICON_MAP_PATH = Path(__file__).resolve().parent / "icon_map.json"
_ICON_MAP = None


def _icon_map():
    global _ICON_MAP
    if _ICON_MAP is None:
        _ICON_MAP = {}
        try:
            if ICON_CACHE_PATH.exists():
                for item in json.load(open(ICON_CACHE_PATH, encoding="utf-8")):
                    if item.get("iconName") and item.get("itemId"):
                        _ICON_MAP[item["itemId"]] = item["iconName"]
        except Exception:
            pass  # never fail the export over a missing cache
        try:
            if ICON_MAP_PATH.exists():
                for k, v in json.load(open(ICON_MAP_PATH, encoding="utf-8")).items():
                    _ICON_MAP[int(k)] = v
        except Exception:
            pass
    return _ICON_MAP


def enrich_icons(export):
    """Fill `icon` (bare filename, e.g. inv_potion_17) on every item with an itemId."""
    imap = _icon_map()
    if not imap:
        return export
    for p in export.get("professions", []):
        for r in p.get("recipes", []):
            for g in r.get("reagents", []):
                if not g.get("icon") and g.get("itemId") in imap:
                    g["icon"] = imap[g["itemId"]]
    for m in export.get("materials", []):
        if not m.get("icon") and m.get("itemId") in imap:
            m["icon"] = imap[m["itemId"]]
    return export


def main():
    db, path = find_and_parse_savedvar()
    export = build_export(db, path)
    enrich_icons(export)
    OUTPUT.write_text(json.dumps(export, indent=2), encoding="utf-8")
    n_rec = sum(len(p["recipes"]) for p in export["professions"])
    print(f"Read {path}")
    print(f"Written {OUTPUT}")
    print(f"  char={export['character']} realm={export['realm']} class={export['classKey']}")
    for p in export["professions"]:
        print(f"  {p['name']}: {p['level']}/{p['maxLevel']} recipes={len(p['recipes'])}")
    print(f"  materials={len(export['materials'])}")
    imap = _icon_map()
    n_icons = sum(1 for p in export["professions"] for r in p["recipes"] for g in r.get("reagents", []) if g.get("icon")) + \
              sum(1 for m in export["materials"] if m.get("icon"))
    print(f"  icons assigned from cache: {n_icons} ({len(imap)} in cache)")


if __name__ == "__main__":
    main()
