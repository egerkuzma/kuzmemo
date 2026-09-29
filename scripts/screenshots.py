#!/usr/bin/env python3
"""Captures the app's screens in English and Russian through the dev app's control socket, to look at them (and to
make README pictures). Needs the dev app running (scripts/run_app.sh). It erases the dev database, pins the clock to
2026-09-28 14:30, seeds the demo week and the glossary, and leaves the interface in Russian.

    scripts/screenshots.py [output-folder] [--live]

The default folder is scripts/out/screenshots (git-ignored). Renders are drawn offscreen and never show a window;
--live also opens the real settings window (behind other windows, without activating the app) and captures it with
its title bar.
"""
import http.client
import json
import os
import socket
import sys
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
SERIES_TITLE = {"english": "Team standup", "russian": "Планёрка"}


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


def main():
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
