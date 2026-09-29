#!/usr/bin/env python3
"""Checks of the Silero neural voice through the dev app's control socket: the engine setting, that Python and the
model are found, that the real helper turns text (with digits and Latin letters) into speech of the right length, and
that the app falls back to the system voice when Silero is missing. Nothing is played: the automation build is muted and
phrases are only made, never played.

Needs the dev app running (scripts/run_app.sh) and, for the live part, a Python with torch and the model (the
environment of ~/Projects/another project is found by itself, or run scripts/install_silero.sh); without them the live part is
skipped.

    scripts/e2e/silero.py
"""
import http.client
import json
import os
import re
import socket
import sys
from urllib.parse import quote

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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


DEFAULT_SPEECH = {
    "engine": "system", "sileroSpeaker": "eugene", "sileroPython": None, "voiceIdentifier": None, "rate": 0.5,
    "speakAnswers": True, "speakConfirmations": False, "confirmationSound": True,
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
    call("POST", "/settings", {"speech": DEFAULT_SPEECH})
    try:
        run()
    finally:
        call("POST", "/settings", {"speech": DEFAULT_SPEECH})
        call("POST", "/window/close?name=settings")
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def run():
    print("the setting")
    after = call("POST", "/settings", {"speech": {"engine": "silero", "sileroSpeaker": "xenia"}})
    check("the engine and speaker are applied and saved", after["live"]["speech"]["engine"] == "silero" and after["stored"]["speech"]["sileroSpeaker"] == "xenia",
          json.dumps(after["stored"]["speech"]))
    check("the voice state names the engine", call("GET", "/voice")["speech"]["engine"] == "silero")
    odd = call("POST", "/settings", {"speech": {"engine": "warp-drive", "sileroSpeaker": "  "}})
    check("nonsense falls back to the defaults", odd["live"]["speech"]["engine"] == "system" and odd["live"]["speech"]["sileroSpeaker"] == "eugene", json.dumps(odd["live"]["speech"]))

    print("finding Silero")
    state = call("GET", "/speech/silero")
    check("the state is reported", state["status"] in ("ready", "unavailable", "missingHelper"), json.dumps(state, ensure_ascii=False))
    if state["status"] != "ready":
        print(f"  note: Silero is not available here ({state.get('problem') or state['status']}): the live part is skipped")
        fallback()
        return
    check("Python and the model are named", state["python"].endswith("/bin/python") and state["model"].endswith("v4_ru.pt"), json.dumps(state))

    print("the real voice")
    call("POST", "/settings", {"speech": {"engine": "silero", "sileroSpeaker": "eugene"}})
    plain = call("POST", "/speech/silero/say", {"text": "Сегодня у вас три дела: планёрка, созвон и статистика."})
    check("a Russian sentence becomes speech", plain.get("ok") is True and 2.5 < plain["seconds"] < 12, json.dumps(plain, ensure_ascii=False))
    check("…quickly once the model is loaded", plain["synthesisMs"] < 3000, str(plain["synthesisMs"]))
    hard = call("POST", "/speech/silero/say", {"text": "Встреча с Notion в 15:00, оплатить 340 долларов."})
    check("digits and Latin letters are spelled out first", re.fullmatch(r"[А-Яа-яЁё ,.]+", hard.get("spoken", "?")) is not None, hard.get("spoken"))
    check("…so they are pronounced (the phrase is not cut short)", hard["seconds"] > 3.0, json.dumps(hard, ensure_ascii=False))
    slow = call("POST", "/settings", {"speech": {"rate": 0.35}})
    slower = call("POST", "/speech/silero/say", {"text": "Сегодня у вас три дела: планёрка, созвон и статистика."})
    check("a slower rate lengthens the speech", slower["seconds"] > plain["seconds"] * 1.15, f"{slower['seconds']} vs {plain['seconds']}")
    call("POST", "/settings", {"speech": {"rate": 0.5}})
    status, _ = call("POST", "/speech/silero/say", {"text": ""}, raw=True)
    check("an empty phrase is refused", status == 400, str(status))

    print("the answer path")
    wav = os.path.join(ROOT, "spikes", "stt", "out", "synth", "03.wav")  # «Скажи что на сегодня»
    if os.path.exists(wav):
        r = call("POST", "/record/inject-audio", {"path": wav})
        check("an answer goes through the same voice (muted here, so it is only logged)", r.get("answeredLocally") is True and len(r.get("spoken", [])) == 1
              and call("GET", "/speech/log")["muted"] is True, json.dumps(r, ensure_ascii=False)[:300])
    else:
        print("  skip the answer path (run spikes/stt/make_synth.sh for the fixtures)")
    fallback()


def fallback():
    print("a missing Silero")
    call("POST", "/settings", {"speech": {"engine": "silero", "sileroPython": "/nonexistent/python"}})
    state = call("GET", "/speech/silero")
    check("an unusable interpreter is named", state["status"] == "unavailable" and "/nonexistent/python" in state["problem"], json.dumps(state, ensure_ascii=False))
    status, data = call("POST", "/speech/silero/say", {"text": "проверка"}, raw=True)
    check("making a phrase then fails with a clear message", status == 502 and "nonexistent" in json.loads(data).get("error", ""), f"{status} {data[:120]!r}")
    call("POST", "/settings", {"speech": {"sileroPython": None}})
    print("the tab")
    call("POST", "/window/open?name=settings")
    call("POST", "/ui", {"settingsTab": "speech"})
    status, png = call("GET", "/render?view=settingsTab&tab=speech&height=900", raw=True)
    check("the Speech tab renders with the engine choice", status == 200 and png[:4] == b"\x89PNG" and len(png) > 60_000, f"{status} {len(png)}")


if __name__ == "__main__":
    main()
