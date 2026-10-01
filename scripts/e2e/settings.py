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
        self.sock.settimeout(self.timeout)  # the default connect() would set it; this one makes its own socket
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
    "speech": {
        "engine": "system", "sileroSpeaker": "eugene", "sileroPython": None, "voiceIdentifier": None, "rate": 0.5,
        "speakAnswers": True, "speakConfirmations": False, "confirmationSound": True,
    },
    "recognition": {"language": "ru", "languageAuto": False, "idleUnloadMinutes": 15, "modelVariant": "openai_whisper-large-v3-v20240930_turbo"},
    "recording": {"holdThreshold": 0.3, "handsFreeSilence": 2.5, "maxSeconds": 120, "microphone": None},
    "notifications": {
        "enabled": True, "eventLeads": [5, 0], "reminderLeads": [0], "allDayTimes": ["09:00"],
        "headsUpSound": {"kind": "system", "name": "Tink"}, "atTimeSound": {"kind": "system", "name": "Hero"},
        "allDaySound": {"kind": "system", "name": "Glass"}, "speakTitle": False,
        "quietHours": {"enabled": False, "from": "23:00", "to": "08:00"}, "snoozeMinutes": [10, 60], "horizonDays": 7,
    },
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
    try:
        is_dev = call("GET", "/state").get("app", {}).get("dev")
    except OSError as error:
        sys.exit(f"the control socket does not answer ({error}): is the dev app running and listening? (scripts/run_app.sh)")
    if not is_dev:
        sys.exit("refusing to run: this is not the dev build, and these checks erase data (scripts/run_app.sh builds the right one)")
    call("POST", "/settings", DEFAULT_SETTINGS)
    call("POST", "/settings", {"interface": {"language": "russian"}})
    try:
        run()
    finally:
        call("POST", "/settings", DEFAULT_SETTINGS)  # never leave odd values behind for the next run
        call("POST", "/settings", {"interface": {"language": "russian"}})
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

    print("the interface language")
    check("the preference and the language in use are reported", set(before["interface"]) == {"preference", "language"}, json.dumps(before["interface"]))
    english = call("POST", "/settings", {"interface": {"language": "english"}})["interface"]
    check("English can be chosen", english == {"preference": "english", "language": "en"}, str(english))
    check("an unknown language is rejected", "error" in call("POST", "/settings", {"interface": {"language": "klingon"}}))
    russian = call("POST", "/settings", {"interface": {"language": "russian"}})["interface"]
    check("and Russian again", russian == {"preference": "russian", "language": "ru"}, str(russian))

    print("the microphone")
    audio = call("GET", "/audio")  # lists the inputs and the choice; nothing is opened
    devices = audio["devices"]
    check("input devices are listed", len(devices) >= 1 and all({"uid", "name", "transport", "default"} <= set(d) for d in devices), json.dumps(devices)[:300])
    check("at most one is the system default", sum(1 for d in devices if d["default"]) <= 1)
    check("the choice starts as automatic", audio["preference"] == "automatic", str(audio["preference"]))
    bluetooth_default = any(d["default"] and d["transport"] == "bluetooth" for d in devices)
    has_built_in = any(d["transport"] == "builtIn" for d in devices)
    if bluetooth_default and has_built_in:
        check("a Bluetooth headset is not used for recording (it needs seconds to start)",
              audio["pickedTransport"] == "builtIn" and str(audio["reason"]).startswith("bluetoothAvoided"), json.dumps(audio)[:300])
    else:
        check("the system input is left alone", audio["picked"] is None, json.dumps(audio)[:300])
    call("POST", "/settings", {"recording": {"microphone": "system"}})
    audio = call("GET", "/audio")
    check("the system input can be chosen", audio["preference"] == "system" and audio["picked"] is None, json.dumps(audio)[:300])
    call("POST", "/settings", {"recording": {"microphone": devices[0]["uid"]}})
    audio = call("GET", "/audio")
    check("one device can be chosen", audio["picked"] == devices[0]["uid"], json.dumps(audio)[:300])
    call("POST", "/settings", {"recording": {"microphone": "unplugged-device"}})
    audio = call("GET", "/audio")
    check("a device that is gone falls back to the automatic choice", audio["reason"] is not None or audio["picked"] is None, json.dumps(audio)[:300])
    call("POST", "/settings", {"recording": {"microphone": None}})
    check("and automatic can be put back", call("GET", "/audio")["preference"] == "automatic")

    print("the window")
    opened = call("POST", "/window/open?name=settings")
    check("it opens without taking the screen", opened.get("open") is True and opened.get("active") is False and opened.get("key") is False, str(opened))
    for language, title in (("russian", "Настройки"), ("english", "Settings")):
        call("POST", "/settings", {"interface": {"language": language}})
        time.sleep(0.4)
        check(f"the window title follows the language ({language})", call("GET", "/window?name=settings").get("title") == title, str(call("GET", "/window?name=settings")))
        for tab in ("general", "recording", "recognition", "speech", "notifications", "glossary", "data"):
            call("POST", "/ui", {"settingsTab": tab})
            time.sleep(0.3)
            status, data = call("GET", f"/render?view=settings&tab={tab}", raw=True)
            check(f"the {tab} tab renders ({language})", status == 200 and data[:4] == b"\x89PNG" and len(data) > 30_000, f"{status} {len(data)}")
            status, live = call("GET", "/render?view=live&name=settings", raw=True)
            check(f"…and is drawn in the real window ({tab}, {language})", status == 200 and len(live) > 30_000, f"{status} {len(live)}")
    call("POST", "/settings", {"interface": {"language": "russian"}})
    call("POST", "/window/close?name=settings")

    time.sleep(0.3)
    check("it closes", call("GET", "/window?name=settings").get("open") is False)
    check("an unknown tab is rejected", "error" in call("POST", "/ui", {"settingsTab": "nope"}))

    print("the menu-bar popover")
    wiring = call("POST", "/popover/wiring")
    check("a window that hosts the popover is found by the app", wiring.get("registered") is True and wiring.get("visibleBefore") is True, json.dumps(wiring))
    check("…and “Open” / “Settings…” can close it", wiring.get("visibleAfterClose") is False, json.dumps(wiring))


if __name__ == "__main__":
    main()
