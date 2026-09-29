#!/usr/bin/env python3
"""Checks of the settings window and the preferences through the dev app's control socket: values change, are saved to
the database, are clamped when nonsensical; the real window opens behind the person's work and shows every tab.

Needs the dev app running (scripts/run_app.sh). Changes the dev bundle's preferences and puts them back.

    scripts/e2e/settings.py
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
    conn.request(method, quote(path, safe="/?&="), body=json.dumps(body) if body is not None else None)
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


def main():
    if not os.path.exists(SOCK):
        sys.exit("control socket not found: is the dev app running? (scripts/run_app.sh)")
    call("POST", "/settings", DEFAULT_SETTINGS)
    try:
        run()
    finally:
        call("POST", "/settings", DEFAULT_SETTINGS)  # never leave odd values behind for the next run
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run():
    print("preferences")
    before = call("GET", "/settings")
    check("they are loaded at launch", before["loaded"] is True)
    check("the defaults are sensible", before["live"]["speech"]["speakAnswers"] is True and before["live"]["recognition"]["language"] == "ru"
          and before["live"]["recording"]["handsFreeSilence"] == 2.5, json.dumps(before["live"]))

    after = call("POST", "/settings", {"speech": {"rate": 0.4, "speakConfirmations": True}, "recording": {"maxSeconds": 90}})
    check("a change is applied at once", after["live"]["speech"]["rate"] == 0.4 and after["live"]["recording"]["maxSeconds"] == 90)
    check("…and saved in the database", after["stored"]["speech"]["rate"] == 0.4 and after["stored"]["speech"]["speakConfirmations"] is True
          and after["stored"]["recording"]["maxSeconds"] == 90, json.dumps(after["stored"]))

    wild = call("POST", "/settings", {"speech": {"rate": 5}, "recording": {"handsFreeSilence": 0, "holdThreshold": 9}})
    check("nonsense is clamped", wild["live"]["speech"]["rate"] == 0.7 and wild["live"]["recording"]["handsFreeSilence"] == 1
          and wild["live"]["recording"]["holdThreshold"] == 0.8, json.dumps(wild["live"]))

    auto = call("POST", "/settings", {"recognition": {"language": None, "idleUnloadMinutes": 0}})
    stored = auto["stored"]["recognition"]
    check("automatic language detection survives a save", stored.get("language") is None and stored.get("languageAuto") is True
          and stored["idleUnloadMinutes"] == 0, json.dumps(stored))

    call("POST", "/settings", DEFAULT_SETTINGS)
    restored = call("GET", "/settings")
    check("they can be put back", restored["stored"]["speech"]["rate"] == 0.5 and restored["stored"]["recognition"]["language"] == "ru"
          and restored["stored"]["recording"]["maxSeconds"] == 120)

    print("the window")
    opened = call("POST", "/window/open?name=settings")
    check("it opens without taking the screen", opened.get("open") is True and opened.get("active") is False and opened.get("key") is False, str(opened))
    for tab in ("general", "recording", "recognition", "speech", "glossary"):
        call("POST", "/ui", {"settingsTab": tab})
        time.sleep(0.3)
        status, data = call("GET", f"/render?view=settings&tab={tab}", raw=True)
        check(f"the {tab} tab renders", status == 200 and data[:4] == b"\x89PNG" and len(data) > 30_000, f"{status} {len(data)}")
        status, live = call("GET", "/render?view=live&name=settings", raw=True)
        check(f"…and is drawn in the real window ({tab})", status == 200 and len(live) > 30_000, f"{status} {len(live)}")
    call("POST", "/window/close?name=settings")
    time.sleep(0.3)
    check("it closes", call("GET", "/window?name=settings").get("open") is False)
    check("an unknown tab is rejected", "error" in call("POST", "/ui", {"settingsTab": "nope"}))


main()
