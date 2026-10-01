#!/usr/bin/env python3
"""Checks of the notification plan through the dev app's control socket: which alerts the calendar produces, how the
settings change them (lead times, times of day for all-day entries, sounds, quiet hours, horizon), what would be handed
to the system, and that the settings tab renders.

The dev app is the automation build: it only *plans* (nothing reaches the real notification center and nothing is
played). Needs the dev app running (scripts/run_app.sh). Erases the dev database and pins the clock, then unpins it.

    scripts/e2e/notifications.py
"""
import http.client
import json
import os
import socket
import sys
import time
from urllib.parse import quote

SOCK = os.environ.get("KUZMEMO_SOCK") or os.path.expanduser("~/Library/Application Support/Kuzmemo-Dev/run/control.sock")
BUNDLE = os.path.expanduser("~/Applications/Kuzmemo Dev.app/Contents/Resources")


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
    "recording": {"holdThreshold": 0.3, "handsFreeSilence": 2.5, "maxSeconds": 120},
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


def plan(**notifications):
    """Applies notification settings (after putting the defaults back), plans again and returns the plan."""
    merged = json.loads(json.dumps(DEFAULT_SETTINGS["notifications"]))
    merged.update(notifications)
    call("POST", "/settings", {"notifications": merged})
    return call("POST", "/notifications/sync?limit=60")


def of(state, title):
    """The alerts of the entry whose title contains `title`, as (fireAt, kind, lead) tuples."""
    return [(a["fireAt"], a["kind"], a["lead"]) for a in state["alerts"] if title in a["title"]]


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
    call("POST", "/settings", {"interface": {"language": "russian"}})  # the checks read Russian texts and the fixtures speak Russian
    try:
        run()
    finally:
        call("POST", "/settings", DEFAULT_SETTINGS)
        call("POST", "/clock", {"local": None})
        call("POST", "/window/close?name=settings")
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run():
    call("POST", "/db/reset")
    call("POST", "/clock", {"local": "2026-09-29 12:00"})  # Tuesday noon
    call("POST", "/dev/seed")

    print("the plan with the defaults")
    state = plan()
    check("the automation build only plans", state["isLive"] is False and state["access"] == "unknown", json.dumps({k: state[k] for k in ("isLive", "access")}))
    check("something is planned", state["count"] > 10, str(state["count"]))
    check("an event is announced 5 minutes ahead and at its start",
          of(state, "Встреча с Дмитрием") == [("2026-09-30 14:55", "headsUp", 5), ("2026-09-30 15:00", "atTime", 0)], str(of(state, "Встреча с Дмитрием")))
    check("a timed task alerts once, at its time", of(state, "Ответить клиенту") == [("2026-09-29 16:00", "atTime", 0)], str(of(state, "Ответить клиенту")))
    check("an entry with a day but no time is announced at 09:00", of(state, "Сказать Дмитрию") == [("2026-10-01 09:00", "allDay", 0)], str(of(state, "Сказать Дмитрию")))
    check("a finished entry is not announced", of(state, "Проверить подписку") == [])
    check("an overdue entry is not announced", of(state, "Отправить счёт") == [])
    check("a repeating entry is announced on each day", len(of(state, "Проверить статистику")) >= 7, str(of(state, "Проверить статистику")))
    times = [a["fireAt"] for a in state["alerts"]]
    check("the plan is in time order", times == sorted(times))
    first = state["alerts"][0]
    check("a request is built for each alert", first["trigger"] == first["fireAt"] + ":00" and first["category"] == "kuzmemo.entry"
          and first["soundFile"] == "System-Hero.aiff", json.dumps(first, ensure_ascii=False))
    check("its text reads well", first["kindText"] == "В назначенное время" and first["when"] == "Сегодня, 16:00", json.dumps(first, ensure_ascii=False))
    call("POST", "/settings", {"interface": {"language": "english"}})
    english = call("POST", "/notifications/sync?limit=60")["alerts"][0]
    check("…and in English", english["kindText"] == "At the scheduled time" and english["when"] == "Today, 16:00", json.dumps(english, ensure_ascii=False))
    call("POST", "/settings", {"interface": {"language": "russian"}})

    print("how early")
    state = plan(eventLeads=[15, 5, 0])
    check("an event can have three alerts", [t for t, _, _ in of(state, "Встреча с Дмитрием")] == ["2026-09-30 14:45", "2026-09-30 14:55", "2026-09-30 15:00"],
          str(of(state, "Встреча с Дмитрием")))
    state = plan(eventLeads=[], reminderLeads=[5, 0])
    check("an event can have none", of(state, "Встреча с Дмитрием") == [])
    check("reminders and tasks have their own leads", [t for t, _, _ in of(state, "Ответить клиенту")] == ["2026-09-29 15:55", "2026-09-29 16:00"],
          str(of(state, "Ответить клиенту")))
    state = plan(eventLeads=[1440, 60, 0])
    check("a day ahead and an hour ahead work too", [t for t, _, _ in of(state, "Встреча с Дмитрием")] == ["2026-09-29 15:00", "2026-09-30 14:00", "2026-09-30 15:00"],
          str(of(state, "Встреча с Дмитрием")))

    print("entries without a time")
    state = plan(allDayTimes=["09:00", "13:00", "18:00"])
    check("each chosen time announces them", [t for t, _, _ in of(state, "Сказать Дмитрию")] == ["2026-10-01 09:00", "2026-10-01 13:00", "2026-10-01 18:00"],
          str(of(state, "Сказать Дмитрию")))
    state = plan(allDayTimes=[])
    check("no times, no announcements", of(state, "Сказать Дмитрию") == [])
    check("timed entries are not affected", of(state, "Ответить клиенту") == [("2026-09-29 16:00", "atTime", 0)])
    state = plan(allDayTimes=["20:00", "08:00", "20:00", "08:00"])
    check("times are sorted and repeats dropped", [t for t, _, _ in of(state, "Сказать Дмитрию")] == ["2026-10-01 08:00", "2026-10-01 20:00"],
          str(of(state, "Сказать Дмитрию")))

    print("sounds")
    state = plan(headsUpSound={"kind": "chime", "name": "bell"}, atTimeSound={"kind": "none", "name": ""}, allDaySound={"kind": "system", "name": "Ping"})
    meeting = [a for a in state["alerts"] if "Встреча с Дмитрием" in a["title"]]
    check("an own chime goes to the system by its bundled file name", meeting[0]["soundFile"] == "Kuzmemo-bell.wav", json.dumps(meeting[0], ensure_ascii=False))
    check("no sound means no sound", meeting[1]["soundFile"] is None and meeting[1]["silent"] is False, json.dumps(meeting[1], ensure_ascii=False))
    allday = [a for a in state["alerts"] if "Сказать Дмитрию" in a["title"]]
    check("a system sound goes by its bundled copy", allday[0]["soundFile"] == "System-Ping.aiff", json.dumps(allday[0], ensure_ascii=False))
    if os.path.isdir(BUNDLE):
        check("the chime file is in the app", os.path.exists(f"{BUNDLE}/Kuzmemo-bell.wav"))
        check("the system sound copy is in the app", os.path.exists(f"{BUNDLE}/System-Ping.aiff") and os.path.exists(f"{BUNDLE}/System-Hero.aiff"))
    else:
        print("  skip the bundled sound files (the dev app is not installed in ~/Applications)")

    print("quiet hours")
    state = plan(quietHours={"enabled": True, "from": "23:00", "to": "08:00"}, allDayTimes=["07:30", "12:00"])
    early, noon = [a for a in state["alerts"] if "Сказать Дмитрию" in a["title"]]
    check("an alert inside them stays but loses its sound", early["fireAt"].endswith("07:30") and early["silent"] is True and early["soundFile"] is None, json.dumps(early, ensure_ascii=False))
    check("an alert outside them keeps its sound", noon["silent"] is False and noon["soundFile"] == "System-Glass.aiff", json.dumps(noon, ensure_ascii=False))
    state = plan(quietHours={"enabled": True, "from": "23:00", "to": "08:00"}, allDayTimes=["09:00"])
    check("after the quiet stretch (09:00) it is loud again", [a["silent"] for a in state["alerts"] if "Сказать Дмитрию" in a["title"]] == [False])

    print("switched off, and how far ahead")
    state = plan(enabled=False)
    check("switched off means nothing is planned", state["count"] == 0 and state["enabled"] is False)
    state = plan(horizonDays=1)
    check("the horizon limits the plan", state["count"] > 0 and max(a["fireAt"] for a in state["alerts"]) < "2026-10-01", str(state["count"]))
    state = plan(horizonDays=30)
    check("…and can be long", state["count"] > 20 and state["count"] <= 60, str(state["count"]))

    print("the preferences themselves")
    after = call("POST", "/settings", {"notifications": {"eventLeads": [0, 10, 10, 5, -3, 99999], "allDayTimes": ["18:00", "09:00", "09:00"], "horizonDays": 500, "snoozeMinutes": [60, 0, 10, 10]}})
    live, stored = after["live"]["notifications"], after["stored"]["notifications"]
    check("they are read forgivingly", live["eventLeads"] == [10, 5, 0] and live["allDayTimes"] == ["09:00", "18:00"] and live["horizonDays"] == 30
          and live["snoozeMinutes"] == [10, 60], json.dumps(live))
    check("…and saved as they are used", stored == live, json.dumps(stored))
    call("POST", "/settings", DEFAULT_SETTINGS)
    restored = call("GET", "/settings")["stored"]["notifications"]
    check("they can be put back", restored["eventLeads"] == [5, 0] and restored["allDayTimes"] == ["09:00"] and restored["headsUpSound"]["name"] == "Tink", json.dumps(restored))

    print("the tab")
    opened = call("POST", "/window/open?name=settings")
    check("the window opens without taking the screen", opened.get("open") is True and opened.get("active") is False, str(opened))
    call("POST", "/ui", {"settingsTab": "notifications"})
    time.sleep(0.3)
    status, data = call("GET", "/render?view=settingsTab&tab=notifications&height=1500", raw=True)
    check("the whole tab renders", status == 200 and data[:4] == b"\x89PNG" and len(data) > 100_000, f"{status} {len(data)}")
    status, live = call("GET", "/render?view=live&name=settings", raw=True)
    check("…and is drawn in the real window", status == 200 and len(live) > 30_000, f"{status} {len(live)}")


if __name__ == "__main__":
    main()
