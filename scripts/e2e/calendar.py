#!/usr/bin/env python3
"""Checks of the calendar window through the dev app's control socket: demo data, window states, renders, and the
real window (opened behind other windows without activating the app, then closed).

Needs the dev app running (scripts/run_app.sh). It erases the dev database and pins the clock to
2026-09-28 14:30. It never brings the window in front of the person's work.

    scripts/e2e/calendar.py
"""
import http.client
import json
import os
import socket
import sys
import time
from urllib.parse import quote

SOCK = os.environ.get("KUZMEMO_SOCK") or os.path.expanduser("~/Library/Application Support/Kuzmemo-Dev/run/control.sock")


class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCK)


def call(method, path, body=None, raw=False):
    conn = Unix("localhost", timeout=60)
    conn.request(method, path, body=json.dumps(body) if body is not None else None)
    response = conn.getresponse()
    data = response.read()
    conn.close()
    if raw:
        return response.status, data
    return json.loads(data) if data else {}


DEFAULT_SETTINGS = {
    "speech": {"voiceIdentifier": None, "rate": 0.5, "speakAnswers": True, "speakConfirmations": False, "confirmationSound": True},
    "recognition": {"language": "ru", "languageAuto": False, "idleUnloadMinutes": 15, "modelVariant": "openai_whisper-large-v3-v20240930_turbo"},
    "recording": {"holdThreshold": 0.3, "handsFreeSilence": 2.5, "maxSeconds": 120},
}

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        print(f"  FAIL {name} {detail}")


def png(path):
    status, data = call("GET", quote(path, safe="/?&="), raw=True)
    return status == 200 and data[:8] == b"\x89PNG\r\n\x1a\n", len(data)


def main():
    if not os.path.exists(SOCK):
        sys.exit("control socket not found: is the dev app running? (scripts/run_app.sh)")

    print("demo data")
    call("POST", "/db/reset")
    call("POST", "/settings", DEFAULT_SETTINGS)
    call("POST", "/clock", {"local": "2026-09-28 14:30"})
    check("seeding works in the dev bundle", call("POST", "/dev/seed").get("seeded") is True)

    state = call("POST", "/ui", {"mode": "day", "date": "2026-09-28"})
    check("today shows six entries and two overdue", state["dayEntries"] == 6 and state["overdue"] == 2, str(state))
    check("the Inbox counts two undated entries and two failed phrases", state["inbox"] == 4, str(state))
    tomorrow = call("POST", "/ui", {"date": "2026-09-29"})
    check("another day shows its own entries and no overdue", tomorrow["dayEntries"] == 3 and tomorrow["overdue"] == 0, str(tomorrow))
    check("the repeating list has the three series", call("POST", "/ui", {"mode": "recurring"})["recurring"] == 3)
    check("search understands word forms", call("POST", "/ui", {"search": "Дмитрий"})["search"] == 2)
    check("clearing the search clears the results", call("POST", "/ui", {"search": "", "mode": "day", "date": "2026-09-28"})["search"] == 0)
    check("an unknown mode is rejected", "error" in call("POST", "/ui", {"mode": "nonsense"}))

    print("renders")
    for name, query in [
        ("the month and day, light", "view=main&width=1000&height=660"),
        ("the month and day, dark", "view=main&width=1000&height=660&scheme=dark"),
        ("the editor for a series", "view=editor&title=Планёрка"),
        ("the editor for a new entry", "view=editor&title=new"),
        ("the HUD asking a question", "view=hud&state=listening"),
    ]:
        ok, size = png(f"/render?{query}")
        check(f"{name} renders a picture", ok and size > 20_000, f"{size} bytes")

    print("the real window")
    call("POST", "/ui", {"mode": "day", "date": "2026-09-29"})
    opened = call("POST", "/window/open")
    check("it opens", opened.get("open") is True and opened.get("visible") is True, str(opened))
    check("without taking over the screen", opened.get("active") is False and opened.get("key") is False, str(opened))
    call("POST", "/ui", {"editor": "Встреча с Дмитрием"})
    time.sleep(0.8)
    check("the editor sheet appears for an entry", call("GET", "/window").get("sheetAttached") is True)
    call("POST", "/ui", {"editor": None})
    time.sleep(0.8)
    check("and goes away again", call("GET", "/window").get("sheetAttached") is False)
    call("POST", "/ui", {"editor": "new"})
    time.sleep(0.8)
    check("a new entry opens the sheet too", call("GET", "/window").get("sheetAttached") is True)
    call("POST", "/ui", {"editor": None})
    time.sleep(0.5)
    closed = call("POST", "/window/close")
    time.sleep(0.3)
    check("it closes", call("GET", "/window").get("open") is False, str(closed))

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


main()
