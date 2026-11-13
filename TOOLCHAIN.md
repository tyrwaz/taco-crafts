# TacoCrafts — toolchain & backup

GitHub Pages site for Kinato's WoW (Forever) Alchemy: shows learned recipes,
materials on hand, and craftable status. The addon exports game data to a JSON
that the site renders.

## Layout
- `index.html` — the live site (design owned here on GitHub; the watcher never
  touches it)
- `data.json` — the exported data the site renders (generated + pushed by the
  watcher)
- `addon/TacoCrafts.lua` + `.toc` — the in-game addon (backup: reinstall guide below)
- `convert.py` — reads the addon's SavedVariables -> `data.json`, enriches item
  icons from `icon_map.json` / `forever_cache.json`
- `resolve_icons.py` — one-time Wowhead scrape: fill `icon_map.json` with
  itemId -> iconName
- `push.py` — the auto-publisher: on save change, runs convert, commits ONLY
  `data.json`, rebases + pushes. Also works as `--watch`.
- `serve.py` — local preview server (`python serve.py` -> http://localhost:8000)
- `icon_map.json` — itemId -> icon filename map (tracked)
- `forever_cache.json` — 18MB offline icon dataset (NOT tracked; re-download below)
- `.cf_token` — your Cloudflare API token (never committed)

## Fresh-clone setup (new machine / migration)
1. `git clone https://github.com/tyrwaz/taco-crafts.git`
2. Re-download the big icon cache (18MB):
   `curl -L -o forever_cache.json https://raw.githubusercontent.com/Napalmsteak/WoW-Classic-Item-Caches/main/Forever%20Cache.json`
   (optional — convert.py works without it, just fewer icon overrides)
3. Install the addon into the game:
   `Interface/AddOns/TacoCrafts/TacoCrafts.lua` + `.toc` from `addon/`
4. Authentication for pushes:
   - GitHub: `gh auth login` as the repo owner (tyrwaz) and `gh auth setup-git`
   - Cloudflare: recreate `~/.cf_token` (secret; not in the repo) so the
     domain's DNS records can be managed
5. Start the auto-publisher: `python push.py --watch` (or use the Windows
   logon autostart wrapper)

## In-game usage
`/reload` -> open Alchemy (pause ~1s) -> `/tacocrafts scan` -> log out.
The watcher then converts + pushes, and the live site updates automatically.

## Restore addon after a WoW reinstall
```
addon="<your game>/Interface/AddOns/TacoCrafts"
curl -L -o "$addon/TacoCrafts.toc" \
  https://raw.githubusercontent.com/tyrwaz/taco-crafts/main/addon/TacoCrafts.toc
curl -L -o "$addon/TacoCrafts.lua" \
  https://raw.githubusercontent.com/tyrwaz/taco-crafts/main/addon/TacoCrafts.lua
```

## Notes
- Only `data.json` is ever committed by automation; `index.html` stays
  GitHub-owned (the watcher resets it from origin each run so it never clobbers
  the live design).
- `git fsck` will show `refs/remotes/origin/main: badRefContent` if a push
  crashes mid-write — fix by deleting the corrupt ref and re-fetching.
