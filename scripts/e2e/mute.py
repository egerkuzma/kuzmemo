#!/usr/bin/env python3
"""Checks that the sound of the Mac goes off while a recording lasts and comes back on every way a recording can end: a
hold, a tap that is then stopped with Esc, and a recording made with the setting switched off. The automation build never
touches the real sound: a stand-in output records what would have been done, and /voice shows it. It also checks that a key
press with no scripted input armed is refused (the automation build never opens the real microphone).

Needs the dev app running (scripts/run_app.sh) and the fixtures from scripts/fixtures/make_synth.sh.

    scripts/e2e/mute.py
"""
import http.client
import json
import os
import socket
import sys
import time
from urllib.parse import quote

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOCK = os.environ.get("KUZMEMO_SOCK") or os.path.expanduser("~/Library/Application Support/Kuzmemo-Dev/run/control.sock")
SYNTH = os.path.join(ROOT, "scripts", "fixtures", "out", "synth")


class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCK)


def call(method, path, body=None):
    conn = Unix("localhost", timeout=120)
    conn.request(method, quote(path, safe="/?&="), body=json.dumps(body) if body is not None else None)
    data = conn.getresponse().read()
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


def output():
    return call("GET", "/voice")["output"]


def wait_idle(timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        state = call("GET", "/voice")
        if state["phase"] == "idle" and state["pendingJobs"] == 0:
            return state
        time.sleep(0.3)
    return call("GET", "/voice")


def main():
    if not os.path.exists(SOCK):
        sys.exit("control socket not found: is the dev app running? (scripts/run_app.sh)")
    wav = os.path.join(SYNTH, "03.wav")  # "Скажи что на сегодня": a phrase the local router answers
    if not os.path.exists(wav):
        sys.exit("fixtures are missing: run scripts/fixtures/make_synth.sh")
    call("POST", "/settings", {"recording": {"muteWhileRecording": True}})
    call("POST", "/settings", {"speech": {"engine": "system"}})
    call("POST", "/settings", {"interface": {"language": "russian"}})
    wait_idle()
    try:
        run(wav)
    finally:
        call("POST", "/settings", {"recording": {"muteWhileRecording": True}})
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run(wav):
    print("the setting")
    live = call("GET", "/settings")["live"]["recording"]
    check("the sound is turned off during a recording by default", live.get("muteWhileRecording") is True, json.dumps(live))
    start = output()
    check("nothing is silenced between recordings", start["silenced"] is False, json.dumps(start))
    base = len(start["events"])

    print("a hold")
    call("POST", "/voice/input", {"path": wav})
    call("POST", "/hotkey/down")
    time.sleep(0.6)
    during = output()
    check("the sound is off while the key is held", during["silenced"] is True and during["events"][base:] == ["silence"], json.dumps(during))
    call("POST", "/hotkey/up")
    time.sleep(0.15)
    after = output()
    check("…and back the moment the key is let go, before the answer", after["silenced"] is False and after["events"][base:] == ["silence", "restore"], json.dumps(after))
    wait_idle()

    print("a tap, then Esc")
    base = len(output()["events"])
    call("POST", "/voice/input", {"path": wav})
    call("POST", "/hotkey/down"); time.sleep(0.1); call("POST", "/hotkey/up")
    time.sleep(0.5)
    check("a hands-free recording keeps the sound off", output()["silenced"] is True, json.dumps(output()))
    call("POST", "/hotkey/escape")
    time.sleep(0.3)
    cancelled = output()
    check("cancelling with Esc brings it back", cancelled["silenced"] is False and cancelled["events"][base:] == ["silence", "restore"], json.dumps(cancelled))
    wait_idle()

    print("the setting switched off")
    call("POST", "/settings", {"recording": {"muteWhileRecording": False}})
    base = len(output()["events"])
    call("POST", "/voice/input", {"path": wav})
    call("POST", "/hotkey/down"); time.sleep(0.6)
    check("with the setting off the sound is left alone", output()["silenced"] is False and len(output()["events"]) == base, json.dumps(output()))
    call("POST", "/hotkey/up")
    wait_idle()
    check("…also afterwards", len(output()["events"]) == base and output()["silenced"] is False)

    print("two recordings in a row")
    call("POST", "/settings", {"recording": {"muteWhileRecording": True}})
    base = len(output()["events"])
    for _ in range(2):
        call("POST", "/voice/input", {"path": wav})
        call("POST", "/hotkey/down"); time.sleep(0.5); call("POST", "/hotkey/up")
        wait_idle()
    events = output()["events"][base:]
    check("each is silenced and restored once", events == ["silence", "restore", "silence", "restore"] and output()["silenced"] is False, str(events))

    print("no scripted input")
    # The automation build must never open the real microphone (nor ask for the permission) when a key is pressed: a script
    # has to arm an input first. Nothing is armed here, so the press is refused before anything is touched.
    base = len(output()["events"])
    permission = call("GET", "/voice")["permissions"]["microphone"]
    call("POST", "/hotkey/down")
    time.sleep(0.4)
    state = call("GET", "/voice")
    check("a key press without an armed input starts no recording", state["phase"] == "idle", json.dumps(state["phase"]))
    check("…says that the microphone is off in this build", "выключен" in state["hud"]["state"], str(state["hud"]))
    check("…and leaves the sound alone", output()["silenced"] is False and len(output()["events"]) == base, json.dumps(output()))
    call("POST", "/hotkey/up")
    state = call("GET", "/voice")
    check("the release changes nothing", state["phase"] == "idle" and state["policy"] == "idle", json.dumps(state))
    check("the microphone permission is left as it was", state["permissions"]["microphone"] == permission, json.dumps(state["permissions"]))


if __name__ == "__main__":
    main()
