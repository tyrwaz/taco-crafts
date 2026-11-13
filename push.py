#!/usr/bin/env python3
"""TacoCrafts publisher: regenerate data.json from the game save and push to GitHub Pages.

Usage:
  python push.py            one shot: convert.py then git add/commit/push (only if data changed)
  python push.py --watch    loop: watch the addon's SavedVariables and deploy whenever it changes

IMPORTANT: only data.json is ever committed/pushed. index.html (the live design / facelift)
lives on GitHub and is reset from origin each deploy so this tool can NEVER overwrite it.
Needs: gh authenticated as the repo owner (tyrwaz), git repo with origin set.
"""
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
GAME_SAVE = Path(r"C:\Program Files (x86)\World of Warcraft\_forever_\WTF\Account\TIFFANY1121\91\Kinato-Tyrnth\SavedVariables\TacoCrafts.lua")
REMOTE = "origin"
BRANCH = "main"


def run(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


def deploy():
    if not GAME_SAVE.exists():
        print("no game save found; nothing to do")
        return False
    # 0. Always start from the current remote state so we never diverge or clobber the
    #    live design: reset tracked files to origin/main -> index.html (the facelift)
    #    exactly matches GitHub and any stale local design is dropped.
    run(["git", "fetch", REMOTE], cwd=ROOT)
    run(["git", "reset", "--hard", f"{REMOTE}/{BRANCH}"], cwd=ROOT)

    # 1. regenerate data.json from the save
    r = run([sys.executable, str(ROOT / "convert.py")])
    if r.returncode != 0:
        print("convert.py failed:", r.stdout, r.stderr)
        return False

    # 2. only data.json is ever committed; does it differ from HEAD?
    r = run(["git", "add", "data.json"], cwd=ROOT)
    r = run(["git", "diff", "--cached", "--quiet", "data.json"], cwd=ROOT)
    if r.returncode == 0:
        print("no material change in data.json; nothing to push")
        run(["git", "reset", "-q", "HEAD", "data.json"], cwd=ROOT)
        return False

    # 3. commit just data.json
    run(["git", "-c", "user.name=tyrwaz", "-c", "user.email=tyrwaz@users.noreply.github.com",
         "commit", "-m", "Update TacoCrafts data (game snapshot)", "data.json"], cwd=ROOT)

    # 4. rebase onto remote first so a concurrent push can never reject us again
    r = run(["git", "-c", "user.name=tyrwaz", "-c", "user.email=tyrwaz@users.noreply.github.com",
             "pull", "--rebase", REMOTE, BRANCH], cwd=ROOT)
    if r.returncode != 0:
        print("pull/rebase failed:", r.stdout, r.stderr)
        return False

    # 5. push
    r = run(["git", "push", REMOTE, BRANCH], cwd=ROOT)
    if r.returncode != 0:
        print("push failed:", r.stdout, r.stderr)
        return False
    print("deployed: pushed updated data.json to", REMOTE + "/" + BRANCH)
    return True


def watch(interval=20):
    last = GAME_SAVE.stat().st_mtime if GAME_SAVE.exists() else 0
    print(f"watching {GAME_SAVE} every {interval}s (Ctrl+C to stop)")
    while True:
        if GAME_SAVE.exists():
            m = GAME_SAVE.stat().st_mtime
            if m != last:
                last = m
                print("[detected save change] running convert + deploy")
                deploy()
        time.sleep(interval)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--watch":
        watch()
    else:
        deploy()
