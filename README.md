<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Kuzmemo icon">
</p>

<h1 align="center">Kuzmemo</h1>

<p align="center">
  <b>Talk to your calendar.</b><br>
  A macOS menu-bar app: press a key, say what you need, and it lands in a calendar of its own — or is read back to you.
</p>

<p align="center">
  <a href="README.ru.md">Русская версия</a> · <a href="LICENSE">MIT License</a>
</p>

<p align="center">
  <img src="docs/images/calendar.png" alt="The Kuzmemo calendar window" width="860">
</p>

*"Remind me the day after tomorrow to send the report."* · *"Team sync tomorrow at 11."* · *"Every weekday at 6 pm, check the stats."* · *"What's on today?"*

Speech recognition runs on your Mac. Understanding the phrase is done by Claude through the `claude` command-line tool you already use with your Claude subscription; the app itself only trusts a strict, validated JSON answer and does all the date arithmetic on its own.

The interface and the spoken answers are available in **English and Russian**; recognition of Russian speech is what the app was designed around first.

## What it looks like

Hold **Fn** and speak. A small card follows you through the steps — recording, the result with a short chance to **Undo**, or a question when the phrase is ambiguous:

<p align="center">
  <img src="docs/images/hud-recording.png" width="420" alt="Recording"><br>
  <img src="docs/images/hud-result.png" width="420" alt="The result with Undo"><br>
  <img src="docs/images/hud-question.png" width="420" alt="A clarifying question with two answers">
</p>

The menu-bar popover shows today and takes typed phrases through the same pipeline:

<p align="center">
  <img src="docs/images/popover.png" width="380" alt="The menu-bar popover">
</p>

## Features

- **One key.** Tap **Fn** to record hands-free (it stops when you stop talking) or hold it to talk while pressed. **⌃⌥M** works without any extra permission. **Esc** cancels.
- **The right microphone.** When macOS has selected a Bluetooth headset as the input, Kuzmemo records with the built-in microphone instead: a headset needs a few seconds to switch to call mode, which eats the first words. Settings → Recording lets you pick any input.
- **Understands ordinary phrases.** Reminders, events, tasks and notes; "tomorrow", "next Monday", "in two hours", "every weekday at 6 pm", "on the 25th". Ambiguous phrases ("next Friday") are answered with a short spoken question and buttons instead of a guess; you can reply by voice, by tapping an option or by typing.
- **Answers questions aloud.** "What's on today?", "what do I have tomorrow", "what's overdue", "find everything about the budget". Simple questions are answered locally in about half a second, and what has already passed today is not read out.
- **A calendar of its own** (SQLite, nothing is synced anywhere): month grid, day list, an Inbox for undated notes and for phrases that could not be processed yet, recurring entries, full-text search that understands word forms, an editor with a live description of the repeat rule.
- **Nothing is lost.** The recording is stored before recognition and the text before it is sent; if `claude` is unavailable, the phrase waits in the Inbox and is retried. Every change made by voice can be undone (card, menu, an undo journal that survives restarts).
- **Notifications you control.** System notifications with your own lead times (for example 10 and 5 minutes before a meeting and at the start), several reminders per day for entries without a time, your own sounds or macOS sounds, snooze buttons, quiet hours.
- **Voices.** The system voice, or the optional neural [Silero](https://github.com/snakers4/silero-models) voice (Russian) that runs locally in a small Python helper.
- **Glossary.** Teach it names and jargon: how they are misheard, how they are written, how a voice should say them. It starts empty; the terms live in your database and can be exported and imported as JSON.
- **Private by design.** Audio never leaves the Mac and is deleted after transcription. Only the recognized text, your glossary terms and the titles of a few nearby calendar entries are sent to Claude.

## Requirements

- macOS 26 or later; Apple silicon recommended (speech recognition uses the Neural Engine).
- Xcode 26 or later (Swift 6.2+) to build.
- [Claude Code](https://claude.com/claude-code) installed and signed in (`claude auth login`). Kuzmemo calls `claude -p`, so it uses your Claude subscription; there is no API-key mode.
- About 2 GB of disk for the speech model (and about 800 MB more for the optional neural voice).

## Build and run

```bash
git clone <this repository> && cd kuzmemo

# 1. A code-signing certificate, once. macOS ties the microphone and Input Monitoring permissions to the app's signature;
#    an ad-hoc build would lose them on every rebuild. Keychain Access > Certificate Assistant > Create a Certificate
#    (Identity Type: Self Signed Root, Certificate Type: Code Signing). Then tell the script which one to use:
export KUZMEMO_SIGN_IDENTITY="<certificate name or SHA-1 hash>"   # or put it in the git-ignored file signing/identity

# 2. Build, sign, install to ~/Applications and launch
scripts/run_app.sh --prod
```

On first launch grant **Microphone**, **Input Monitoring** (needed for the Fn key; the ⌃⌥M chord works without it) and **Notifications**. In **Settings → Recognition** download the speech model. If Fn opens the emoji picker or dictation, set *System Settings → Keyboard → Press 🌐 key to* **Do Nothing**.

The optional neural voice: `scripts/install_silero.sh` (needs Python 3.10+; it creates its own environment and downloads the model into `~/Library/Application Support/Kuzmemo/silero`), then choose it in *Settings → Speech*.

`scripts/run_app.sh` without `--prod` builds the *automation build* used by the end-to-end scripts (see below). The app icon is drawn by `scripts/make_icon.swift` during the build.

## Using it

| Say | What happens |
|---|---|
| "Remind me the day after tomorrow to call the bank" | An all-day reminder, announced at the times you chose |
| "Team sync tomorrow at eleven" | An event at 11:00, with an early warning if you enabled it |
| "Every Monday at ten stand-up" | A repeating event |
| "What's on today?" | Read aloud from your calendar, no network involved |
| "Move the meeting with Anna to Thursday" | The matching entry is changed (with Undo) |
| "Next Friday, sync at three" | "Which Friday?" with two buttons; answer aloud or tap |

The card that follows a command offers **Undo** for a couple of seconds; the menu-bar popover shows today, the result of the last command and a text box that goes through the same pipeline as speech. **⌘,** opens the settings; the **Calendar** window is the full month view.

## How it works

```
key → microphone → on-device Whisper (WhisperKit) → transcript
    → local fast path for simple questions, or `claude -p` (no tools, strict JSON schema)
    → validation (allow-listed actions, dates computed by the app, clarification rules)
    → SQLite + undo journal → card / spoken answer / notifications
```

The ideas the code is built around:

- **Claude describes, the app computes.** The model returns structure ("a weekday, next week, at 11"); date arithmetic, validation and every write are deterministic app code. A second, independent reading of simple date phrases cross-checks the model.
- **Untrusted input.** Transcripts and calendar text are data, never instructions: the model gets no tools, answers under a strict schema, may only ask for allow-listed actions, and deletes are soft with Undo.
- **Nothing is lost.** Every phrase is persisted before each stage; a failure leaves an Inbox card with a retry, and interrupted work is finished at the next launch.
- **Testable without a person.** A UI-free core, recorded model answers (a golden set of about sixty phrases, also runnable against the real `claude -p`), and a control socket in the development build that drives the real app.

Three SwiftPM targets: `KuzmemoCore` (UI-free logic and storage on GRDB, fully unit-tested), `KuzmemoSTT` (WhisperKit behind a protocol) and `Kuzmemo` (the app). The interface is localized with English source keys and Russian translation tables; `scripts/check_localization.py` keeps them in step with the code.

## Tests

```bash
swift test                                   # unit tests; the golden set replays recorded model answers offline
KUZMEMO_LIVE_CLAUDE=1 swift test --filter liveAgainstClaude   # the golden set against the real `claude -p`
python3 scripts/check_localization.py        # translation tables against the code
```

The development build exposes a control socket, so scripts can drive the real app without a person: `scripts/e2e/voice.py`, `calendar.py`, `settings.py`, `notifications.py`, `silero.py` (run `scripts/run_app.sh` first; speech fixtures come from `scripts/fixtures/make_synth.sh`). That build is muted, ignores the keyboard trigger and never opens the microphone. The pictures in this README come from `scripts/screenshots.py --readme` (macOS in dark mode).

## Data and privacy

Everything lives in `~/Library/Application Support/Kuzmemo` (database, models). Audio is a temporary file, removed as soon as the text is stored. The text of a phrase, the glossary and the titles of nearby entries go to Anthropic through Claude Code; nothing else does.

## Status

Personal project, work in progress: the voice path, the calendar window, settings, notifications and the bilingual interface are built; the long-run soak and a first release are next.

## License

MIT, see [LICENSE](LICENSE). Kuzmemo builds on GRDB, WhisperKit and KeyboardShortcuts (all MIT). The speech models are downloaded when you install them and are not part of this repository: Whisper (MIT); the optional Silero voice model is licensed CC BY-NC-SA 4.0, for non-commercial use.

## Contributing

Issues and pull requests are welcome. Code, comments, docs and commit messages are in English (Conventional Commits); user-visible text goes through the translation tables (English keys, Russian translations). Please keep personal data out of examples and tests.
