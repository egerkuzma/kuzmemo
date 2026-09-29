#!/usr/bin/env python3
"""The launch of the real dev app with a database too damaged to open. It used to fail on every launch; now the damaged file is
set aside (never deleted) and the newest usable copy is put in its place, or the app starts empty when there is none. The script
quits the dev app, damages its database file, launches it again and looks at what the app says and did; it also checks that a
clean quit folds the write-ahead log into the database file.

Needs the dev bundle installed (scripts/run_app.sh) and running. Works only on the dev bundle's own data folder.

    scripts/e2e/recovery.py
"""
import glob
import http.client
import json
import os
import socket
import subprocess
import sys
import time
from urllib.parse import quote

SUPPORT = os.path.expanduser("~/Library/Application Support/Kuzmemo-Dev")
SOCK = os.environ.get("KUZMEMO_SOCK") or os.path.join(SUPPORT, "run", "control.sock")
APP = os.path.expanduser("~/Applications/Kuzmemo Dev.app")
DB = os.path.join(SUPPORT, "kuzmemo.sqlite")
BACKUPS = os.path.join(SUPPORT, "backups")
BUNDLE_ID = "app.kuzmemo.dev"


class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCK)


def call(method, path, body=None):
    conn = Unix("localhost", timeout=60)
    conn.request(method, quote(path, safe="/?&="), body=json.dumps(body) if body is not None else None)
    response = conn.getresponse()
    data = response.read()
    conn.close()
    return json.loads(data) if data else {}


passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        print(f"  FAIL {name} {detail}")


def running():
    return subprocess.run(["pgrep", "-f", f"{APP}/Contents/MacOS/Kuzmemo"], capture_output=True).returncode == 0


def wait_until(condition, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(step)
    return False


def quit_app():
    subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'], capture_output=True)
    if not wait_until(lambda: not running(), 25):
        sys.exit("the dev app did not quit")
    time.sleep(0.3)


def launch_app():
    subprocess.run(["open", APP], check=True)

    def up():
        try:
            return "app" in call("GET", "/state")
        except (OSError, ValueError):
            return False

    if not wait_until(up, 40):
        sys.exit("the dev app did not come up")


def damage_with_pages():
    """Three pages of 0xFF: SQLite reports a malformed image."""
    with open(DB, "wb") as handle:
        handle.write(b"\xff" * 4096 * 3)
    for suffix in ("-wal", "-shm"):
        if os.path.exists(DB + suffix):
            os.remove(DB + suffix)


def damaged_files():
    return sorted(glob.glob(os.path.join(SUPPORT, "kuzmemo-damaged-*.sqlite")))


def main():
    if not os.path.exists(APP):
        sys.exit(f"the dev bundle is not installed at {APP} (scripts/run_app.sh)")
    if not os.path.exists(SOCK):
        sys.exit("control socket not found: is the dev app running? (scripts/run_app.sh)")
    if not call("GET", "/state").get("app", {}).get("dev"):
        sys.exit("refusing to run against a bundle that is not the dev one")
    try:
        run()
    finally:
        if not running():
            launch_app()
        call("POST", "/db/reset")
        call("POST", "/settings", {"interface": {"language": "russian"}})
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run():
    call("POST", "/settings", {"interface": {"language": "english"}})
    call("POST", "/db/reset")
    for path in glob.glob(os.path.join(BACKUPS, "kuzmemo-*")) + damaged_files():
        os.remove(path)
    call("POST", "/dev/seed")
    kept = call("GET", "/state")["counts"]["items"]
    made = call("POST", "/data/backup", {"reason": "manual"})["made"]
    call("POST", "/dev/seed")  # entries made after the copy: the price of going back to it
    check("setup: the copy has the first entries, the database has more", call("GET", "/state")["counts"]["items"] == kept * 2 and kept > 5)

    print("a damaged file, with a copy available")
    quit_app()
    wal = DB + "-wal"
    check("a clean quit folds the log into the database file", not os.path.exists(wal) or os.path.getsize(wal) == 0,
          f"{os.path.getsize(wal) if os.path.exists(wal) else '-'} bytes")
    damage_with_pages()
    launch_app()
    info = call("GET", "/data")
    check("the app started and says the file was recovered", info["recovery"] == "restored", str(info.get("recovery")))
    check("it puts the copy's entries in place, not the later ones", call("GET", "/state")["counts"]["items"] == kept, str(call("GET", "/state")["counts"]))
    aside = damaged_files()
    check("the damaged file is kept next to the database", len(aside) == 1, str(aside))
    if aside:
        check("…and is the damaged one, not a copy of the good one", open(aside[0], "rb").read(8) == b"\xff" * 8)
    check("the copy itself is still in the backups folder", os.path.exists(made["path"]))
    check("the page explains it", "copy from" in (info.get("attention") or ""), str(info.get("attention")))
    state = call("GET", "/state")
    check("the menu-bar icon warns", state["status"] == "error", state["status"])
    check("and a toast says so", state.get("toast", {}).get("style") == "error" and "Settings" in " ".join(state["toast"]["lines"]), str(state.get("toast")))
    check("the recovered database is sound", call("POST", "/data/check")["integrity"]["healthy"] is True)

    call("POST", "/window/open?name=settings")
    time.sleep(0.5)
    call("POST", "/ui", {"settingsTab": "data"})
    time.sleep(0.6)
    check("opening the Data page quiets the icon", call("GET", "/state")["status"] == "idle", call("GET", "/state")["status"])
    check("…but the explanation stays on the page", bool(call("GET", "/data").get("attention")))
    call("POST", "/window/close?name=settings")

    print("a damaged file, with no copy")
    quit_app()
    for path in glob.glob(os.path.join(BACKUPS, "kuzmemo-*")):
        os.remove(path)
    with open(DB, "wb") as handle:
        handle.write(b"this is not a database at all")
    for suffix in ("-wal", "-shm"):
        if os.path.exists(DB + suffix):
            os.remove(DB + suffix)
    launch_app()
    info = call("GET", "/data")
    check("the app starts empty and says so", info["recovery"] == "startedEmpty" and "no copy" in (info.get("attention") or ""), str(info))
    check("the calendar is empty but works", call("GET", "/state")["counts"]["items"] == 0)
    aside = damaged_files()
    check("both damaged files are kept", len(aside) == 2, str(aside))
    check("the second holds what was there", any(open(p, "rb").read() == b"this is not a database at all" for p in aside))
    call("POST", "/dev/seed")
    check("the new database takes entries", call("GET", "/state")["counts"]["items"] == kept)

    print("a healthy launch afterwards")
    quit_app()
    launch_app()
    info = call("GET", "/data")
    check("nothing is recovered, nothing warns", info["recovery"] == "opened" and info["hasProblem"] is False and not info.get("attention"), str(info))
    check("the entries are still there", call("GET", "/state")["counts"]["items"] == kept)
    check("the icon is calm", call("GET", "/state")["status"] == "idle")

    for path in damaged_files() + glob.glob(os.path.join(BACKUPS, "kuzmemo-*")):
        os.remove(path)


main()
