#!/usr/bin/env python3
"""Writes the notice of the third-party software that is built into Kuzmemo. Passing a program on (a disk image does)
is allowed on condition that the licences of what it contains travel with it.

    scripts/make_notices.py OUT [--scratch-path DIR]

The list comes from SwiftPM itself (`swift package show-dependencies`), so it follows Package.swift and Package.resolved,
and the texts are the ones in the checkouts the build used (`--scratch-path` is the build folder of a `--scratch-path`
build, as scripts/run_app.sh --dist uses). It stops with an error when a package has no licence file: an app must not go
out without its notice. scripts/run_app.sh puts the result into the bundle and scripts/make_dmg.sh into the disk image.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LICENCE_FILES = ("license", "license.txt", "license.md", "licence", "copying")
NOTICE_FILES = ("notices", "notice", "notice.txt")

HEADER = """Third-party software in Kuzmemo
===============================

Kuzmemo itself is released under the MIT License (see the file LICENSE). It is built with the packages below, whose
licences follow in full.
"""

FOOTER = """
Not part of this download
=========================

The speech models and the optional voices are fetched on the person's request, from their own sources, and are not
distributed with Kuzmemo:

  - the Whisper speech-recognition models (OpenAI, MIT License) are downloaded from Hugging Face in Settings > Recognition;
  - the Silero voice model (CC BY-NC-SA 4.0, non-commercial use) is downloaded by scripts/install_silero.sh together with
    PyTorch (BSD-style licence) and NumPy (BSD licence) into a Python environment of its own;
  - omnivoice.cpp (MIT License) and the OmniVoice weights in GGUF form (CC-BY-NC 4.0, non-commercial use) are fetched and
    built by scripts/install_omnivoice.sh.
"""


def dependencies(scratch):
    command = ["swift", "package"] + (["--scratch-path", scratch] if scratch else []) + ["show-dependencies", "--format", "json"]
    result = subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
    found = {}

    def walk(node):
        for child in node.get("dependencies", []):
            found.setdefault(child["identity"], child)
            walk(child)

    walk(json.loads(result.stdout))
    return sorted(found.values(), key=lambda package: package["identity"])


def texts(folder):
    """The licence files of a package first, then its notice files, each with its own name."""
    names = os.listdir(folder)
    licences = sorted(n for n in names if n.lower() in LICENCE_FILES)
    notices = sorted(n for n in names if n.lower() in NOTICE_FILES)
    return [(n, (pathlib.Path(folder) / n).read_text(encoding="utf-8", errors="replace").strip()) for n in licences + notices]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("out")
    parser.add_argument("--scratch-path")
    args = parser.parse_args()

    parts = [HEADER]
    problems = 0
    for package in dependencies(args.scratch_path):
        found = texts(package["path"])
        if not any(name.lower() in LICENCE_FILES for name, _ in found):
            print(f"no licence file in {package['path']}", file=sys.stderr)
            problems += 1
            continue
        title = f"{package['identity']} {package.get('version', '')}".strip()
        rule = "-" * 78
        parts.append(f"\n{rule}\n{title}  ({package['url']})\n{rule}\n")
        for name, text in found:
            parts.append(f"\n[{name}]\n\n{text}\n")
    if problems:
        sys.exit(1)
    parts.append(FOOTER)
    pathlib.Path(args.out).write_text("".join(parts), encoding="utf-8")
    print(f"notices: {args.out}")


if __name__ == "__main__":
    main()
