#!/usr/bin/env python3
"""Checks of the Data page through the dev app's control socket: the integrity check, the daily copy and its rhythm (one
per date, the last 14 kept), copies made by hand, the erase (a copy first, settings and the glossary stay), and the page
itself drawn in both languages. The copies are real files; they are opened here with Python's own sqlite3 to be sure that
they are ordinary databases holding what the app says.

Needs the dev app running (scripts/run_app.sh). Erases the dev bundle's data and its backups folder (never the daily
app's: it refuses to run against a bundle that is not the dev one).

    scripts/e2e/data.py
"""
import glob
import http.client
import json
import os
import socket
import sqlite3
import sys
import time
from urllib.parse import quote

SOCK = os.environ.get("KUZMEMO_SOCK") or os.path.expanduser("~/Library/Application Support/Kuzmemo-Dev/run/control.sock")


class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCK)


def call(method, path, body=None, raw=False):
    conn = Unix("localhost", timeout=120)
    conn.request(method, quote(path, safe="/?&="), body=json.dumps(body) if body is not None else None)
    response = conn.getresponse()
    data = response.read()
    conn.close()
    if raw:
        return response.status, data
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


def open_copy(path):
    """A copy opened on its own, read-only: what a person (or a script) would do to look inside it."""
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def scalar(connection, sql):
    return connection.execute(sql).fetchone()[0]


def main():
    if not os.path.exists(SOCK):
        sys.exit("control socket not found: is the dev app running? (scripts/run_app.sh)")
    state = call("GET", "/state")
    if not state.get("app", {}).get("dev"):
        sys.exit("refusing to run against a bundle that is not the dev one")
    call("POST", "/settings", {"interface": {"language": "english"}})
    try:
        run()
    finally:
        call("POST", "/clock", {"local": None})
        call("POST", "/db/reset")
        for path in glob.glob(os.path.join(call("GET", "/data")["backupsFolder"], "kuzmemo-*")):
            os.remove(path)  # leave the dev bundle's folder as it was found
        call("POST", "/glossary", {"terms": []})
        call("POST", "/settings", {"interface": {"language": "russian"}})
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run():
    folder = call("GET", "/data")["backupsFolder"]
    for path in glob.glob(os.path.join(folder, "kuzmemo-*")):
        os.remove(path)  # the dev bundle's own folder: start from nothing
    call("POST", "/clock", {"local": "2026-09-28 14:30"})
    call("POST", "/db/reset")
    call("POST", "/dev/seed")

    print("the page's facts")
    info = call("GET", "/data")
    entries = info["overview"]["entries"]
    check("the demo week is in the database", entries > 5, str(info.get("overview")))
    check("nothing is wrong at the start", info["hasProblem"] is False and info["recovery"] == "opened", str(info))
    check("no copies yet, so a daily one is due", info["copies"] == [] and info["dailyDue"] is True)
    check("the database file has a size", info["bytes"] > 0)

    print("the integrity check")
    report = call("POST", "/data/check")["integrity"]
    check("a fresh database is sound", report["healthy"] is True and report["problems"] == [], str(report))
    check("the search index needed no repair", report["searchIndexRebuilt"] is False)

    print("the daily copy")
    made = call("POST", "/data/daily")["made"]
    check("the first call makes a copy", made is not None and made["reason"] == "daily" and made["day"] == "2026-09-28", str(made))
    check("the file name carries the wall clock", made and made["name"] == "kuzmemo-2026-09-28-143000.sqlite", str(made))
    check("a second call the same day does nothing", call("POST", "/data/daily")["made"] is None)
    check("and the page says none is due", call("GET", "/data")["dailyDue"] is False)
    connection = open_copy(made["path"])
    check("the copy is an ordinary, sound SQLite file", scalar(connection, "PRAGMA integrity_check") == "ok")
    check("it holds the same entries", scalar(connection, "SELECT count(*) FROM items") == entries)
    check("and is not in the write-ahead mode", scalar(connection, "PRAGMA journal_mode") == "delete")
    connection.close()
    check("no half-written file is left behind", not glob.glob(os.path.join(folder, "*.partial")))

    print("the rhythm of days and the limit of 14")
    call("POST", "/clock", {"local": "2026-09-29 09:00"})
    check("the next date makes it due again", call("GET", "/data")["dailyDue"] is True)
    check("and a new copy is made", call("POST", "/data/daily")["made"] is not None)
    days = ["2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07",
            "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15"]
    for day in days:
        call("POST", "/clock", {"local": f"{day} 09:00"})
        call("POST", "/data/daily")
    copies = call("GET", "/data")["copies"]
    daily = [c for c in copies if c["reason"] == "daily"]
    check("only the last 14 daily copies are kept", len(daily) == 14, f"{len(daily)}: {[c['day'] for c in daily]}")
    check("the newest is the latest day, listed first", daily and daily[0]["day"] == "2026-10-15", str(daily[:1]))
    check("the oldest kept is 2026-10-02", daily and daily[-1]["day"] == "2026-10-02", str(daily[-1:]))
    check("the files match the list", len(glob.glob(os.path.join(folder, "kuzmemo-*.sqlite"))) == len(copies))

    print("a copy by hand")
    manual = call("POST", "/data/backup", {"reason": "manual"})["made"]
    check("it is marked as made by hand", manual["reason"] == "manual" and manual["name"].endswith("-manual.sqlite"), str(manual))
    check("a copy of the erase kind cannot be asked for", call("POST", "/data/backup", {"reason": "beforeErase"}, raw=True)[0] == 400)
    check("the daily ones stayed at 14", len([c for c in call("GET", "/data")["copies"] if c["reason"] == "daily"]) == 14)

    print("the erase")
    call("POST", "/glossary", {"terms": [{"canonical": "Notion", "kind": "product", "aliases": ["нотион"], "spoken": "Ношн"}]})
    settings_before = call("GET", "/settings")["stored"]
    check("a glossary word is there", call("GET", "/data")["overview"]["glossaryTerms"] == 1)
    check("the erase needs a confirmation", call("POST", "/data/erase", {}, raw=True)[0] == 400)
    check("and nothing was erased without it", call("GET", "/data")["overview"]["entries"] == entries)
    erased = call("POST", "/data/erase", {"confirm": True})["erased"]
    check("it reports what it removed", erased["entries"] == entries and erased["undoSteps"] >= 1, str(erased))
    after = call("GET", "/data")
    check("no entries, phrases or undo steps remain", after["overview"]["entries"] == 0 and after["overview"]["memos"] == 0 and after["overview"]["undoSteps"] == 0, str(after["overview"]))
    check("the glossary stayed", after["overview"]["glossaryTerms"] == 1)
    check("the settings stayed", call("GET", "/settings")["stored"] == settings_before)
    check("the calendar is empty too", call("GET", "/state")["counts"]["items"] == 0)
    before_erase = [c for c in after["copies"] if c["reason"] == "beforeErase"]
    check("a copy was made just before", len(before_erase) == 1, str(after["copies"][:3]))
    if before_erase:
        connection = open_copy(before_erase[0]["path"])
        check("and it still holds the entries that were erased", scalar(connection, "SELECT count(*) FROM items") == entries)
        connection.close()
    check("the notice says what happened", "Erased" in (after.get("notice") or {}).get("text", ""), str(after.get("notice")))
    check("the database is sound afterwards", call("POST", "/data/check")["integrity"]["healthy"] is True)

    print("the page itself")
    for language, marker in (("english", "en"), ("russian", "ru")):
        call("POST", "/settings", {"interface": {"language": language}})
        status, png = call("GET", "/render?view=settingsTab&tab=data&height=900", raw=True)
        check(f"the page draws in {language}", status == 200 and png[:8] == b"\x89PNG\r\n\x1a\n" and len(png) > 20000, f"{status} {len(png)} bytes")
    call("POST", "/settings", {"interface": {"language": "english"}})
    call("POST", "/window/open?name=settings")
    time.sleep(0.5)
    call("POST", "/ui", {"settingsTab": "data"})
    time.sleep(0.4)
    check("the real settings window is open", call("GET", "/window?name=settings").get("open") is True)
    status, live = call("GET", "/render?view=live&name=settings", raw=True)
    check("and the Data tab is drawn in it", status == 200 and live[:4] == b"\x89PNG" and len(live) > 30_000, f"{status} {len(live)}")
    call("POST", "/window/close?name=settings")


main()
