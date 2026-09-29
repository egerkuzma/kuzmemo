#!/usr/bin/env python3
"""Checks of the "My voice" engine through the dev app's control socket: the setting, that the installed program is found,
that a recording and its words become a voice (a system-voice recording stands in for the person's, so nothing personal is
involved), that answers are made sentence by sentence with the timing the settings page shows, that the cache plays a
repeated sentence at once, that a queue of sentences is played through a player that renders into memory (no sound device),
that a wrong recording is refused, and that the voice can be forgotten. Nothing is played: the automation build is muted and
phrases are only made, never played.

Needs the dev app running (scripts/run_app.sh) and, for the live part, the program from scripts/install_omnivoice.sh;
without it the live part is skipped.

    scripts/e2e/clone.py
"""
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from urllib.parse import quote

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOCK = os.environ.get("KUZMEMO_SOCK") or os.path.expanduser("~/Library/Application Support/Kuzmemo-Dev/run/control.sock")
DAILY_VOICE = os.path.expanduser("~/Library/Application Support/Kuzmemo/voice")


class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCK)


def call(method, path, body=None, raw=False, timeout=180):
    conn = Unix("localhost", timeout=timeout)
    conn.request(method, quote(path, safe="/?&="), body=json.dumps(body) if body is not None else None)
    response = conn.getresponse()
    data = response.read()
    conn.close()
    if raw:
        return response.status, data
    return json.loads(data) if data else {}


DEFAULT_SPEECH = {
    "engine": "system", "sileroSpeaker": "eugene", "sileroPython": None, "voiceIdentifier": None, "rate": 0.5,
    "cloneSteps": 8, "speakAnswers": True, "speakConfirmations": False, "confirmationSound": True,
}

SAMPLE_TEXT = ("Сегодня хорошая погода, и я записываю образец голоса для проверки. "
               "Это обычный спокойный текст без чисел и латинских слов, чтобы всё прочиталось верно.")
DIGEST = "На сегодня у тебя три дела: в десять часов, Планёрка. в тринадцать часов, Обед с Анной. в восемнадцать часов, Тренировка."

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
    daily_before = os.path.exists(DAILY_VOICE) and sorted(os.listdir(DAILY_VOICE))
    call("POST", "/speech/clone/forget")
    call("POST", "/settings", {"speech": DEFAULT_SPEECH})
    call("POST", "/settings", {"interface": {"language": "russian"}})  # the checks read Russian texts and the fixtures speak Russian
    work = tempfile.mkdtemp(prefix="kuzmemo-clone-e2e-")
    try:
        run(work)
    finally:
        call("POST", "/speech/clone/forget")
        call("POST", "/settings", {"speech": DEFAULT_SPEECH})
        call("POST", "/window/close?name=settings")
        shutil.rmtree(work, ignore_errors=True)
    daily_after = os.path.exists(DAILY_VOICE) and sorted(os.listdir(DAILY_VOICE))
    check("the daily app's voice folder was never touched", daily_before == daily_after, f"{daily_before} -> {daily_after}")
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


def recording(work, name, text):
    """A recording made with the system voice (rendered to a file, nothing is played)."""
    aiff = os.path.join(work, name + ".aiff")
    subprocess.run(["say", "-v", "Milena", "-o", aiff, text], check=True)
    return aiff


def run(work):
    print("the setting")
    after = call("POST", "/settings", {"speech": {"engine": "clone", "cloneSteps": 12}})
    check("the engine and the steps are applied and saved", after["live"]["speech"]["engine"] == "clone" and after["stored"]["speech"]["cloneSteps"] == 12,
          json.dumps(after["stored"]["speech"]))
    check("the voice state names the engine", call("GET", "/voice")["speech"]["engine"] == "clone")
    odd = call("POST", "/settings", {"speech": {"cloneSteps": 500}})
    check("steps out of range are brought back into it", odd["live"]["speech"]["cloneSteps"] == 32, json.dumps(odd["live"]["speech"]))
    call("POST", "/settings", {"speech": {"cloneSteps": 8}})
    reset = call("POST", "/settings", {"speech": {"cloneSteps": None}})  # a missing value falls back to the default
    check("the default is 8 steps", reset["live"]["speech"]["cloneSteps"] == 8, json.dumps(reset["live"]["speech"]))

    print("finding the engine")
    state = call("GET", "/speech/clone")
    check("the state is reported", state["status"] in ("notInstalled", "noVoice", "ready"), json.dumps(state, ensure_ascii=False))
    check("the voice folder belongs to this bundle, not to the daily app", "/Kuzmemo-Dev/" in state["voiceFolder"], state["voiceFolder"])
    check("the program is shared", state["engineFolder"].endswith("/Kuzmemo/omnivoice"), state["engineFolder"])
    if state["status"] == "notInstalled":
        print("  note: the program is not installed here (scripts/install_omnivoice.sh): the live part is skipped")
        tab()
        return
    check("no voice yet in a clean bundle", state["status"] == "noVoice" and "sample" not in state, json.dumps(state, ensure_ascii=False))

    print("a voice from a recording")
    sample = recording(work, "sample", SAMPLE_TEXT)
    short = recording(work, "short", "Раз два.")
    status, data = call("POST", "/speech/clone/enroll", {"path": short, "words": "раз два"}, raw=True)
    check("a recording that is too short is refused, in words", status == 422 and "секунд" in json.loads(data).get("error", ""), f"{status} {data[:160]!r}")
    status, data = call("POST", "/speech/clone/enroll", {"path": sample, "words": "слово"}, raw=True)
    check("a recording without its words is refused", status == 422 and "слова" in json.loads(data).get("error", ""), f"{status} {data[:160]!r}")
    status, data = call("POST", "/speech/clone/enroll", {"path": os.path.join(work, "missing.wav"), "words": "два слова"}, raw=True)
    check("a missing file is refused", status == 422, f"{status} {data[:160]!r}")
    check("…and none of that made a voice", call("GET", "/speech/clone")["status"] == "noVoice")
    print("the steps of the settings page")
    reviewing = call("POST", "/speech/clone/choose", {"path": sample})
    check("a chosen recording waits for its words to be checked", reviewing["enrollment"] == "review" and 3 < reviewing["draft"]["seconds"] < 15
          and reviewing["draft"]["suggested"] is False, json.dumps(reviewing, ensure_ascii=False)[:300])
    check("…and nothing is saved before they are", reviewing["status"] == "noVoice")
    call("POST", "/window/open?name=settings")
    call("POST", "/ui", {"settingsTab": "speech"})
    status, png = call("GET", "/render?view=settingsTab&tab=speech&height=1000", raw=True)
    check("the review step renders", status == 200 and png[:4] == b"\x89PNG", str(status))
    if os.environ.get("KUZMEMO_SHOTS"):
        open(os.path.join(os.environ["KUZMEMO_SHOTS"], "clone-review.png"), "wb").write(png)
    cancelled = call("POST", "/speech/clone/cancel")
    check("giving up leaves things as they were", cancelled["enrollment"] == "idle" and cancelled["status"] == "noVoice")
    call("POST", "/speech/clone/choose", {"path": short})
    afterShort = call("GET", "/speech/clone")
    check("a recording that is too short never reaches the review", afterShort["enrollment"] == "idle" and "секунд" in (afterShort["enrollmentProblem"] or ""), json.dumps(afterShort, ensure_ascii=False)[:300])
    call("POST", "/speech/clone/choose", {"path": sample})
    tooFew = call("POST", "/speech/clone/save", {"words": "слово"})
    check("one word is not enough, and the review stays open with the reason", tooFew["enrollment"] == "review" and "слова" in (tooFew["enrollmentProblem"] or ""), json.dumps(tooFew, ensure_ascii=False)[:300])
    saved = call("POST", "/speech/clone/save", {"words": SAMPLE_TEXT})
    check("with the words checked the voice is saved", saved["status"] == "ready" and saved["enrollment"] == "idle", json.dumps(saved, ensure_ascii=False)[:300])
    if os.environ.get("KUZMEMO_SHOTS"):
        status, png = call("GET", "/render?view=settingsTab&tab=speech&height=1000", raw=True)
        open(os.path.join(os.environ["KUZMEMO_SHOTS"], "clone-ready.png"), "wb").write(png)
    made = call("POST", "/speech/clone/enroll", {"path": sample, "words": SAMPLE_TEXT})
    check("a recording and its words become a voice (the shortcut for scripts)", made.get("status") == "ready", json.dumps(made, ensure_ascii=False)[:300])
    check("…of the right length", 3 < made.get("sample", {}).get("seconds", 0) < 15, json.dumps(made.get("sample")))
    files = sorted(os.listdir(made["voiceFolder"]))
    check("…kept as the recording, its codes and its words", files == ["ref.rvq", "ref.txt", "ref.wav"], str(files))
    check("…with the words as given", open(os.path.join(made["voiceFolder"], "ref.txt"), encoding="utf-8").read() == SAMPLE_TEXT)

    print("answers")
    call("POST", "/settings", {"speech": {"engine": "clone", "cloneSteps": 12}})
    word = call("POST", "/speech/clone/say", {"text": "Готово."})
    check("one word is one sentence", word.get("ok") is True and word["lineCount"] == 1 and 0.2 < word["audioSeconds"] < 4, json.dumps(word, ensure_ascii=False)[:300])
    check("…the first sound comes in a few seconds", 0 < word["firstSoundSeconds"] < 20, str(word.get("firstSoundSeconds")))
    digest = call("POST", "/speech/clone/say", {"text": DIGEST, "cache": True})
    check("an answer of three items is made sentence by sentence", digest.get("ok") is True and digest["lineCount"] >= 2 and len(digest["readyAt"]) == digest["lineCount"], json.dumps(digest, ensure_ascii=False)[:400])
    check("…in order, each ready after the one before", digest["readyAt"] == sorted(digest["readyAt"]), str(digest["readyAt"]))
    check("…of a sensible length", 5 < digest["audioSeconds"] < 20, str(digest["audioSeconds"]))
    check("…with the steps that were set", digest["steps"] == 12, str(digest["steps"]))
    check("…nothing came from the cache the first time", digest["cachedLines"] == 0, str(digest["cachedLines"]))
    again = call("POST", "/speech/clone/say", {"text": DIGEST, "cache": True})
    check("the same answer again comes from the cache", again["cachedLines"] == again["lineCount"], json.dumps(again, ensure_ascii=False)[:300])
    check("…and is ready at once", again["madeInSeconds"] < 0.5, str(again["madeInSeconds"]))
    check("…with the same sound", abs(again["audioSeconds"] - digest["audioSeconds"]) < 0.01, f"{again['audioSeconds']} vs {digest['audioSeconds']}")
    other = call("POST", "/speech/clone/say", {"text": DIGEST, "cache": True, "steps": 8})
    check("another number of steps is not served from what was made with 12", other["cachedLines"] == 0 and other["steps"] == 8, json.dumps(other, ensure_ascii=False)[:300])
    kept = os.path.join(work, "lines")
    saved = call("POST", "/speech/clone/say", {"text": DIGEST, "save": kept})
    written = sorted(os.listdir(kept)) if os.path.isdir(kept) else []
    check("sentences can be kept as files", len(written) == saved["lineCount"] and all(open(os.path.join(kept, f), "rb").read(4) == b"RIFF" for f in written), str(written))
    offline = call("POST", "/speech/clone/say", {"text": DIGEST, "cache": True, "play": "offline"})
    check("a queue of sentences is played through a player with no sound device", offline.get("ok") is True and offline["silenceSeconds"] is not None, json.dumps(offline, ensure_ascii=False)[:300])
    check("…and all of it was rendered", offline["rendered"] >= offline["audioSeconds"] * 0.9, f"{offline['rendered']} of {offline['audioSeconds']}")
    check("…in a moment, not in real time", offline["totalMs"] < offline["audioSeconds"] * 1000 * 0.9, f"{offline['totalMs']} ms for {offline['audioSeconds']} s")
    status, data = call("POST", "/speech/clone/say", {"text": ""}, raw=True)
    check("an empty phrase is refused", status == 400, str(status))
    state = call("GET", "/speech/clone")
    check("the last answer is reported", state["lastReport"]["lineCount"] == offline["lineCount"], json.dumps(state.get("lastReport"))[:200])

    print("starting ahead")
    def programs():
        return int(subprocess.run("pgrep -f 'omnivoice-tts' | wc -l", shell=True, capture_output=True, text=True).stdout.strip() or 0)
    check("no program is running between answers", programs() == 0, str(programs()))
    call("POST", "/speech/clone/prewarm", {"wait": 2.5})
    check("started ahead, the program waits for the text", programs() == 1, str(programs()))
    ahead = call("POST", "/speech/clone/say", {"text": "Готово.", "cache": False})
    plain = call("POST", "/speech/clone/say", {"text": "Готово.", "cache": False})
    check("the answer uses it", ahead.get("startedAhead") is True and plain.get("startedAhead") is False, f"{ahead.get('startedAhead')} {plain.get('startedAhead')}")
    check("…and is sooner for it", ahead["firstSoundSeconds"] < plain["firstSoundSeconds"] + 0.3, f"{ahead['firstSoundSeconds']:.2f} s against {plain['firstSoundSeconds']:.2f} s")
    check("nothing is left running after the answer", programs() == 0, str(programs()))
    call("POST", "/speech/clone/prewarm", {})
    check("a program started and never used is there…", programs() == 1, str(programs()))
    call("POST", "/settings", {"speech": {"cloneSteps": 20}})
    for _ in range(30):
        if programs() == 0: break
        import time; time.sleep(0.1)
    check("…and goes when the quality is changed (it was started with the old steps)", programs() == 0, str(programs()))
    call("POST", "/settings", {"speech": {"cloneSteps": 12}})

    print("the answer path")
    wav = os.path.join(ROOT, "scripts", "fixtures", "out", "synth", "03.wav")  # "Скажи что на сегодня" ("tell me what is on today")
    if os.path.exists(wav):
        call("POST", "/dev/seed")
        r = call("POST", "/record/inject-audio", {"path": wav})
        spoken = " ".join(r.get("spoken", []))
        check("an answer goes through the same path (muted here, so it is only logged)", r.get("answeredLocally") is True and len(r.get("spoken", [])) == 1
              and call("GET", "/speech/log")["muted"] is True, json.dumps(r, ensure_ascii=False)[:300])
        check("…and it talks to the person as «ты»", "у тебя" in spoken and "у вас" not in spoken, spoken[:200])
    else:
        print("  skip the answer path (run scripts/fixtures/make_synth.sh for the fixtures)")

    print("the tab")
    tab()

    print("forgetting the voice")
    gone = call("POST", "/speech/clone/forget")
    check("the voice is forgotten", gone["status"] == "noVoice" and not os.path.exists(gone["voiceFolder"]), json.dumps(gone, ensure_ascii=False)[:200])
    status, data = call("POST", "/speech/clone/say", {"text": "Готово."}, raw=True)
    check("without a voice an answer cannot be made, and it says why", status == 502 and "голос" in json.loads(data).get("error", "").lower(), f"{status} {data[:160]!r}")


def tab():
    call("POST", "/window/open?name=settings")
    call("POST", "/ui", {"settingsTab": "speech"})
    status, png = call("GET", "/render?view=settingsTab&tab=speech&height=1000", raw=True)
    check("the Speech tab renders with My voice chosen", status == 200 and png[:4] == b"\x89PNG" and len(png) > 60_000, f"{status} {len(png)}")


if __name__ == "__main__":
    main()
