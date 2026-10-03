#!/usr/bin/env python3
"""End-to-end checks of the voice path through the dev app's control socket, without a person or a microphone.

Needs: the dev app running (scripts/run_app.sh), the speech model installed, and the synthetic phrases from
scripts/fixtures/make_synth.sh (scripts/fixtures/out/synth). Speech and sounds stay muted; the dev database is erased first.
It calls the real Claude, so a run costs a few requests and about a minute.

    scripts/e2e/voice.py
"""
import http.client
import json
import os
import socket
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SYNTH = os.path.join(ROOT, "scripts", "fixtures", "out", "synth")
SOCK = os.environ.get("KUZMEMO_SOCK") or os.path.expanduser("~/Library/Application Support/Kuzmemo-Dev/run/control.sock")


class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)  # the default connect() would set it; this one makes its own socket
        self.sock.connect(SOCK)


def call(method, path, body=None):
    conn = Unix("localhost", timeout=180)
    payload = json.dumps(body) if body is not None else None
    conn.request(method, path, body=payload)
    response = conn.getresponse()
    data = response.read()
    conn.close()
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

# A new install starts with an empty glossary, so the run brings the words it needs.
GLOSSARY = [
    {"canonical": "Notion", "kind": "product", "aliases": ["нотион", "ношн"], "spoken": "Ношн"},
    {"canonical": "GitHub", "kind": "product", "aliases": ["гит хаб", "гитхаб"], "spoken": "Гит хаб"},
    {"canonical": "Slack", "kind": "product", "aliases": ["слэк", "слак"], "spoken": "Слэк"},
    {"canonical": "Acme", "kind": "company", "aliases": ["акме"], "spoken": "Акме"},
]

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   {name}")
    else:
        failed += 1
        print(f"  FAIL {name} {detail}")


def wav(name):
    return os.path.join(SYNTH, f"{name}.wav")


def wait_idle(timeout=90):
    end = time.time() + timeout
    while time.time() < end:
        state = call("GET", "/voice")
        if state["phase"] == "idle" and state["pendingJobs"] == 0:
            return state
        time.sleep(0.25)
    raise SystemExit("timed out waiting for the voice pipeline to go idle")


def counts():
    return call("GET", "/state")["counts"]


def main():
    if not os.path.exists(SOCK):
        sys.exit("control socket not found: is the dev app running? (scripts/run_app.sh)")
    try:
        is_dev = call("GET", "/state").get("app", {}).get("dev")
    except OSError as error:
        sys.exit(f"the control socket does not answer ({error}): is the dev app running and listening? (scripts/run_app.sh)")
    if not is_dev:
        sys.exit("refusing to run: this is not the dev build, and these checks erase data (scripts/run_app.sh builds the right one)")
    if not os.path.isdir(SYNTH):
        sys.exit("synthetic phrases missing: run scripts/fixtures/make_synth.sh")

    print("setup")
    call("POST", "/db/reset")
    call("POST", "/settings", DEFAULT_SETTINGS)
    call("POST", "/settings", {"interface": {"language": "russian"}})  # the checks read Russian texts and the fixtures speak Russian
    call("POST", "/glossary", {"terms": GLOSSARY})
    call("POST", "/clock", {"local": "2026-09-28 14:30"})
    call("POST", "/speech/mute", {"muted": True})
    deadline = time.time() + 240
    while call("GET", "/voice")["model"] not in ("ready",) and time.time() < deadline:
        time.sleep(2)
    check("speech model is ready", call("GET", "/voice")["model"] == "ready")

    print("injected recordings")
    r = call("POST", "/record/inject-audio", {"path": wav("01")})
    o = r.get("outcome", {})
    check("flagship phrase becomes a reminder for the day after tomorrow",
          r["kind"] == "processed" and o.get("kind") == "applied"
          and o["changes"][0]["date"] == "2026-09-30" and o["changes"][0]["itemKind"] == "reminder", json.dumps(r, ensure_ascii=False)[:400])
    check("the change came from voice and carries the transcript", "Дмитрию" in o["changes"][0]["title"] and r["transcript"])
    check("recognition is not stuck (the first one after a launch may take a few seconds)", r["sttMs"] < 10000, f"sttMs={r['sttMs']}")

    r = call("POST", "/record/inject-audio", {"path": wav("03")})
    check("\"tell me what is on today\" is answered locally, without Claude", r["answeredLocally"] and r["outcome"]["kind"] == "answered" and "llm" not in r["outcome"])
    check("…and read aloud (muted, but logged)", len(r["spoken"]) == 1 and "сегодня" in r["spoken"][0], str(r["spoken"]))

    r = call("POST", "/record/inject-audio", {"path": wav("04")})
    check("an ambiguous Friday is asked about", r["outcome"]["kind"] == "clarify" and len(r["outcome"]["options"]) >= 2, json.dumps(r, ensure_ascii=False)[:300])
    check("…and the question is spoken", len(r["spoken"]) == 1)

    before = counts()
    for name in ("silence3", "noise5"):
        r = call("POST", "/record/inject-audio", {"path": wav(name)})
        check(f"{name} never reaches the model", r["kind"] == "noSpeech" and r["spoken"] == [])
    check("…and creates no items", counts()["items"] == before["items"])

    # two recordings in quick succession: the second is saved as a phrase the moment it ends, not when its turn in the queue
    # comes (a quit or a crash while the first was being worked on used to lose it without a trace)
    memos = counts()["memos"]
    results = {}
    def inject(name):
        results[name] = call("POST", "/record/inject-audio", {"path": wav(name)})
    first = threading.Thread(target=inject, args=("01",))
    second = threading.Thread(target=inject, args=("02",))
    first.start(); time.sleep(0.3); second.start(); time.sleep(0.5)
    queued = counts()["memos"]
    busy = call("GET", "/voice")["pendingJobs"]
    first.join(); second.join()
    check("a recording that waits behind another one is already a saved phrase", queued == memos + 2 and busy == 2,
          f"memos {memos} → {queued}, pending jobs {busy} while the first was being worked on")
    check("…and both are processed", results["01"]["kind"] == "processed" and results["02"]["kind"] == "processed",
          f"{results['01'].get('kind')} / {results['02'].get('kind')}")

    print("trigger key, with a scripted microphone")
    call("POST", "/voice/input", {"path": wav("02")})
    call("POST", "/hotkey/down"); time.sleep(0.12); call("POST", "/hotkey/up")
    state = call("GET", "/voice")
    check("a tap starts a hands-free recording", state["phase"].startswith("recording") and "true" in state["phase"], state["phase"])
    started = time.time()
    wait_idle()
    check("it stops by itself after the silence that follows the phrase", time.time() - started > 4.5, f"{time.time() - started:.1f}s")
    agenda = call("GET", "/agenda?from=2026-09-29&to=2026-09-29")["entries"]
    check("\"tomorrow at eleven, a call\" lands at 11:00", any(e["time"] == "11:00" and e["kind"] == "event" for e in agenda), str(agenda))

    call("POST", "/voice/input", {"path": wav("10")})
    call("POST", "/hotkey/down"); time.sleep(3.6)
    check("holding keeps recording", call("GET", "/voice")["phase"].startswith("recording"))
    released = time.time()
    call("POST", "/hotkey/up")
    wait_idle()
    check("push-to-talk stops on release and is processed", time.time() - released < 12, f"{time.time() - released:.1f}s")
    agenda = call("GET", "/agenda?from=2026-09-28&to=2026-09-28")["entries"]
    check("\"in half an hour\" becomes today at 15:00", any(e["time"] == "15:00" for e in agenda), str(agenda))

    n = counts()["memos"]
    call("POST", "/voice/input", {"path": wav("14")})
    call("POST", "/hotkey/down"); time.sleep(0.2); call("POST", "/hotkey/other"); call("POST", "/hotkey/up"); time.sleep(0.3)
    state = call("GET", "/voice")
    check("a chord cancels quietly", state["phase"] == "idle" and state["hud"]["state"] == "hidden" and counts()["memos"] == n, str(state["hud"]))

    call("POST", "/voice/input", {"path": wav("14")})
    call("POST", "/hotkey/down"); time.sleep(0.1); call("POST", "/hotkey/up"); time.sleep(1.0)
    call("POST", "/hotkey/escape")
    check("Esc cancels a hands-free recording", call("GET", "/voice")["phase"] == "idle" and counts()["memos"] == n)

    call("POST", "/voice/input", {"path": wav("14")})
    call("POST", "/hotkey/down"); time.sleep(0.4); call("POST", "/hotkey/up"); time.sleep(0.3)
    state = call("GET", "/voice")
    check("a press that is too short is dropped with a note", state["phase"] == "idle" and "Слишком" in state["hud"]["state"] and counts()["memos"] == n)

    print("clarifying questions")
    def ask():
        r = call("POST", "/record/inject-audio", {"path": wav("04")})
        q = call("GET", "/voice").get("question")
        check("an ambiguous phrase leaves a question open", r["outcome"]["kind"] == "clarify" and q is not None, json.dumps(r, ensure_ascii=False)[:200])
        return q

    # a spoken answer: the app listens by itself after asking (here the scripted microphone plays the answer)
    call("POST", "/voice/input", {"path": wav("a2")})
    ask()
    wait_idle()
    agenda = call("GET", "/agenda?from=2026-10-02&to=2026-10-02")["entries"]
    check("\"this Friday, the second of October\" completes the phrase (event at 15:00 on 2 Oct)",
          any(e["time"] == "15:00" and e["date"] == "2026-10-02" for e in agenda), str(agenda))
    check("…and the question is closed", "question" not in call("GET", "/voice"))

    # an option tapped in the HUD
    q = ask()
    r = call("POST", "/answer", {"option": q["options"][1]})
    check("choosing \"Friday of next week\" books 9 Oct", r["kind"] == "applied" and r["changes"][0]["date"] == "2026-10-09", json.dumps(r, ensure_ascii=False)[:300])

    # a typed answer
    ask()
    r = call("POST", "/answer", {"text": "Эту пятницу"})
    check("a typed answer is accepted", r["kind"] == "applied" and r["changes"][0]["date"] == "2026-10-02", json.dumps(r, ensure_ascii=False)[:300])

    # a refusal
    items = counts()["items"]
    call("POST", "/voice/input", {"path": wav("a3")})
    ask()
    wait_idle()
    check("\"no, never mind, cancel\" saves nothing", counts()["items"] == items and "question" not in call("GET", "/voice"))

    # a bulk deletion: the app asks about a complete plan, and a plain yes applies that very plan without asking the model again
    call("POST", "/dev/seed")  # six entries on the seed's today
    r = call("POST", "/memo/transcript", {"text": "удали все записи на сегодня"})
    q = call("GET", "/voice").get("question")
    check("deleting everything today is asked about first", r["kind"] == "clarify" and q is not None and q["text"].startswith("Удалить"),
          json.dumps(r, ensure_ascii=False)[:300])
    items = counts()["items"]
    r = call("POST", "/answer", {"option": q["options"][0]})  # "Да, удалить"
    check("the yes applies the asked plan itself, without the model", r["kind"] == "applied" and "llm" not in r and len(r["changes"]) >= 3
          and counts()["items"] == items - len(r["changes"]), json.dumps(r, ensure_ascii=False)[:300])
    check("…and the question is closed", "question" not in call("GET", "/voice"))

    # no answer at all: the words are kept as a note
    call("POST", "/voice/input", {"path": wav("silence3")})
    ask()
    started = time.time()
    wait_idle()
    inbox = call("GET", "/inbox")["items"]
    check("silence for the whole window keeps the phrase as a note", any(i["kind"] == "note" and "пятницу" in i["title"] for i in inbox), str(inbox))
    check("…after about seven seconds", 5 < time.time() - started < 15, f"{time.time() - started:.1f}s")

    # an answer that is only a burst of noise: the level detector takes it for speech, so the recording is made and the question
    # is taken as being answered; the recogniser then finds nothing in it. The phrase must still end up as a note, as it does
    # when nobody answers at all (it used to stay open, invisibly, until the next launch).
    inbox_before = len(call("GET", "/inbox")["items"])
    memos_before = counts()["memos"]
    call("POST", "/voice/input", {"path": wav("burst4")})
    ask()
    wait_idle()
    inbox = call("GET", "/inbox")["items"]
    check("a noise burst recorded as the answer still keeps the phrase as a note",
          len(inbox) == inbox_before + 1 and any(i["kind"] == "note" and "пятницу" in i["title"] for i in inbox) and "question" not in call("GET", "/voice"),
          str(inbox))
    # two new phrases: the question's and the recorded answer's (the recogniser, not the level detector, turned it down)
    check("…and the burst went through the recogniser", counts()["memos"] == memos_before + 2, f"memos {memos_before} → {counts()['memos']}")

    # Esc while listening
    inbox_before = len(call("GET", "/inbox")["items"])
    call("POST", "/voice/input", {"path": wav("silence3")})
    ask()
    time.sleep(1.0)
    call("POST", "/hotkey/escape")
    check("Esc closes the question and saves nothing", "question" not in call("GET", "/voice") and len(call("GET", "/inbox")["items"]) == inbox_before)

    print("undo")
    items = counts()["items"]
    undone = call("POST", "/undo")
    check("the last voice change can be undone", "undone" in undone and counts()["items"] == items - 1, str(undone))

    log = call("GET", "/speech/log")
    check("nothing was said aloud during automation", log["muted"] is True)

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
