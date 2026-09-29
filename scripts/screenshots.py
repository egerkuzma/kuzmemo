#!/usr/bin/env python3
"""Captures the app's screens in English and Russian through the dev app's control socket, to look at them (and to
make README pictures). Needs the dev app running (scripts/run_app.sh). It erases the dev database, pins the clock to
2026-09-28 14:30, seeds the demo week and the glossary, and leaves the interface in Russian.

    scripts/screenshots.py [output-folder] [--live]
    scripts/screenshots.py --readme            the pictures of the README, English only, into docs/images

The default folder is scripts/out/screenshots (git-ignored). Renders are drawn offscreen and never show a window;
--live also opens the real settings window (behind other windows, without activating the app) and captures it with
its title bar. --readme takes the curated set (the calendar and a few settings pages as real windows at 2x, the cards
drawn offscreen; all dark, and macOS has to be in dark mode while it runs), and
finishes them with scripts/frame_screenshots.swift (rounded corners and a shadow). The real windows come to the front
for a moment while they are captured.
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOCK = os.environ.get("KUZMEMO_SOCK") or os.path.expanduser("~/Library/Application Support/Kuzmemo-Dev/run/control.sock")
TABS = ("general", "recording", "recognition", "speech", "notifications", "glossary")
HUD_STATES = ("recording", "handsfree", "transcribing", "interpreting", "result", "question", "listening", "note")
GLOSSARY = [
    {"canonical": "Notion", "kind": "product", "aliases": ["нотион", "ношн", "notion"], "spoken": "Ношн"},
    {"canonical": "GitHub", "kind": "product", "aliases": ["гит хаб", "гитхаб", "git hub"], "spoken": "Гит хаб"},
    {"canonical": "Slack", "kind": "product", "aliases": ["слэк", "слак"], "spoken": "Слэк"},
    {"canonical": "Acme", "kind": "company", "aliases": ["акме"], "spoken": "Акме"},
]
# The words of the README's glossary picture: names that speech recognition tends to get wrong in English.
GLOSSARY_EN = [
    {"canonical": "GitHub", "kind": "product", "aliases": ["git hub", "get hub"], "spoken": "Git Hub"},
    {"canonical": "Kubernetes", "kind": "product", "aliases": ["cooper netties", "kuber netties"], "spoken": "Koo-ber-net-eez"},
    {"canonical": "Notion", "kind": "product", "aliases": ["notion", "no shun"]},
    {"canonical": "Slack", "kind": "product", "aliases": ["slak"]},
]
SERIES_TITLE ={"english": "Team standup", "russian": "Планёрка"}


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


saved = []


def capture(folder, name, path):
    status, data = call("GET", path, raw=True)
    if status != 200 or data[:8] != b"\x89PNG\r\n\x1a\n":
        print(f"  !! {name}: {status} {data[:120]!r}")
        return
    os.makedirs(folder, exist_ok=True)
    target = os.path.join(folder, f"{name}.png")
    with open(target, "wb") as handle:
        handle.write(data)
    saved.append(target)
    print(f"  {os.path.relpath(target, ROOT)}  ({len(data) // 1024} KB)")


def readme():
    """The README pictures: English interface, the demo week, framed like macOS shows windows."""
    out = os.path.join(ROOT, "docs", "images")
    raw = tempfile.mkdtemp(prefix="kuzmemo-shots-")
    jobs = []

    def grab(name, path, radius, margin=64):
        before = len(saved)
        capture(raw, name, path)
        if len(saved) > before:
            jobs.append({"input": os.path.join(raw, f"{name}.png"), "output": os.path.join(out, f"{name}.png"), "radius": radius, "margin": margin})

    call("POST", "/clock", {"local": "2026-09-28 14:30"})
    call("POST", "/settings", {"interface": {"language": "english"}})
    call("POST", "/glossary", {"terms": GLOSSARY_EN})
    call("POST", "/settings", {"recognition": {"language": "en"}})
    call("POST", "/db/reset")
    call("POST", "/dev/seed")
    try:
        # The real windows are captured as they are, in the appearance macOS is in now, which has to be dark (forcing
        # another appearance on a window draws a mixture of both). The cards are drawn offscreen, dark as well.
        call("POST", "/ui", {"mode": "day", "date": "2026-09-28"})
        call("POST", "/window/open?name=main")
        time.sleep(1.0)
        grab("calendar", "/render?view=live&name=main&chrome=1&front=1&scale=2", radius=48)
        call("POST", "/window/close?name=main")
        # a few settings pages (the General and Recording tabs show a file path and a device name: left out)
        call("POST", "/window/open?name=settings")
        time.sleep(1.0)
        for tab in ("notifications", "glossary"):
            call("POST", "/ui", {"settingsTab": tab})
            time.sleep(0.6)
            grab(f"settings-{tab}", "/render?view=live&name=settings&chrome=1&front=1&scale=2", radius=48)
        call("POST", "/window/close?name=settings")
        # the cards that appear while talking, the menu-bar popover and the entry editor (drawn offscreen)
        for state in ("recording", "result", "question"):
            grab(f"hud-{state}", f"/render?view=hud&state={state}&scheme=dark", radius=40, margin=48)
        grab("popover", "/render?view=popover&scheme=dark", radius=36)
        grab("editor", "/render?view=editor&title=Team standup&scheme=dark", radius=36)
    finally:
        call("POST", "/settings", {"interface": {"language": "russian"}, "recognition": {"language": "ru"}})
    spec =os.path.join(raw, "jobs.json")
    with open(spec, "w") as handle:
        json.dump(jobs, handle)
    subprocess.run(["swift", os.path.join(ROOT, "scripts", "frame_screenshots.swift"), spec], check=True, cwd=ROOT)
    print(f"\n{len(jobs)} pictures in {os.path.relpath(out, ROOT)}")


def main():
    if "--readme" in sys.argv:
        if not os.path.exists(SOCK):
            sys.exit("control socket not found: is the dev app running? (scripts/run_app.sh)")
        readme()
        return
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    live = "--live" in sys.argv
    out = os.path.abspath(args[0]) if args else os.path.join(ROOT, "scripts", "out", "screenshots")
    if not os.path.exists(SOCK):
        sys.exit("control socket not found: is the dev app running? (scripts/run_app.sh)")
    call("POST", "/clock", {"local": "2026-09-28 14:30"})
    call("POST", "/glossary", {"terms": GLOSSARY})
    try:
        for language, code in (("english", "en"), ("russian", "ru")):
            print(language)
            call("POST", "/settings", {"interface": {"language": language}})
            call("POST", "/db/reset")
            call("POST", "/dev/seed")
            call("POST", "/ui", {"mode": "day", "date": "2026-09-28"})
            folder = os.path.join(out, code)
            capture(folder, "main-light", "/render?view=main&width=1000&height=660")
            capture(folder, "main-dark", "/render?view=main&width=1000&height=660&scheme=dark")
            capture(folder, "editor-series", f"/render?view=editor&title={SERIES_TITLE[language]}")
            capture(folder, "editor-new", "/render?view=editor&title=new")
            capture(folder, "popover", "/render?view=popover")
            for state in HUD_STATES:
                capture(folder, f"hud-{state}", f"/render?view=hud&state={state}")
            for tab in TABS:
                capture(folder, f"settings-{tab}", f"/render?view=settingsTab&tab={tab}&height=760")
            if live:
                call("POST", "/window/open?name=settings")
                for tab in TABS:
                    call("POST", "/ui", {"settingsTab": tab})
                    time.sleep(0.4)
                    capture(folder, f"window-settings-{tab}", "/render?view=live&name=settings&chrome=1")
                call("POST", "/window/close?name=settings")
    finally:
        call("POST", "/settings", {"interface": {"language": "russian"}})
    print(f"\n{len(saved)} pictures in {os.path.relpath(out, ROOT)}")


main()
