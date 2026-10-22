#!/usr/bin/env python3
"""Demo of the tips window (prompter) without a call, a model or Claude.

Opens the real window with a fake recording status and plays a scripted call of about
2.5 minutes that shows the v36/v37 features:
  - your speech card and the agenda moving forward,
  - a ❓ "question heard" line that the next tip replaces,
  - 🆘 HELP NOW: press it and red 🆘 facts appear at once, then a short answer,
  - ⏸ / ▶ pause tips: while paused nothing new appears (it is held), ▶ shows what was held,
  - the 🗣 "Now speaking" line switching between two voices, and a "Who is speaking?" card
    after ~20 s (name them, type a name, or Skip; the 🗣 popover renames / fixes / merges),
  - a mic alert with "Use Mac mic", and at the end the "Claude is not listening" warning.
The interface language (⚙ Display: English / Українська) and "Hide from screen sharing" are window
settings: try them during the demo. Speaker names are full "First Last" names, like the team list.
Questions typed in the window get a canned answer; settings in ⚙ get a confirmation.

  python3 ~/work/Tools/live-transcriber/bin/demo_prompter.py
  python3 ~/work/Tools/live-transcriber/bin/demo_prompter.py --dry   # no window: fast run, prints a log
Close the window or press Ctrl+C to end it. No network, no model. Works with an older
bin/prompter too (only the HTML page changed).
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPTER = ROOT / "bin" / "prompter"
DRY = "--dry" in sys.argv
END_AT = 150          # seconds of script; the window stays open afterwards until you close it

tmp = Path(tempfile.mkdtemp(prefix="prompter-demo-"))
tips, inbox, status_f, control = tmp / "demo.tips.jsonl", tmp / "demo.inbox.jsonl", tmp / "status.json", tmp / "control"
control.mkdir()
inbox.write_text("")
tips.write_text("")

T0_WALL = datetime.now()
status = {"state": "recording", "title": "Demo: client call", "lines": 0, "queue": 0, "seq": 0,
          "mic": "ok", "system_audio": "ok", "errors": [], "mic_device": "default", "mic_stall_streak": 0,
          "mic_auto_switched": False, "me_lang": "en", "call_lang": "en", "call_type": "auto", "hiring_role": "",
          "audience": "client", "proactive": "off", "tips_paused": "off", "talk_me_pct": 0, "monologue_s": 0,
          "speakers": "loading", "speakers_rev": 0, "speaker_now": None,
          "started_at": T0_WALL.astimezone().isoformat(timespec="seconds"), "listener_age_s": 3}

vt = 0.0              # script time in seconds (wall time in a real run, virtual in --dry)
held = []             # automatic items held back while tips are paused
later = []            # (at, fn) one-shot actions
names, merged, skipped = {}, {}, set()
asks_open, asks_wait = None, []      # one open "Who is speaking?" at a time, like the recorder
mic_stall_from = None
log_lines = []


def now(offset=0.0):
    return (T0_WALL + timedelta(seconds=vt + offset)).strftime("%H:%M:%S")


def say(msg):
    log_lines.append(f"[{vt:6.1f}] {msg}")
    if DRY:
        print(log_lines[-1])


def write_status():
    status["seq"] += 1
    p = status_f.with_suffix(".tmp")
    p.write_text(json.dumps(status, ensure_ascii=False))
    os.replace(p, status_f)


def emit(item):
    item.setdefault("t", now())
    with open(tips, "a", encoding="utf-8") as f:
        f.write(json.dumps(item, ensure_ascii=False) + "\n")
    say(f"item {item.get('kind')}: {item.get('gist') or item.get('sid') or item.get('key') or ''}")


def auto(item):
    """An automatic item: held while tips are paused (manual answers are never held)."""
    if status["tips_paused"] == "on":
        held.append(item)
        say(f"held while paused: {item.get('kind')}")
    else:
        emit(item)


def root(sid):
    while sid in merged:
        sid = merged[sid]
    return sid


# ---------- the scripted call ----------
AGENDA = ["Release status", "Cutoff by document", "3DS timeline", "Next steps"]


def agenda(done):
    emit({"kind": "agenda", "gist": "Client sync, 4 points",
          "items": [{"text": x, "done": i < done, "cur": i == done} for i, x in enumerate(AGENDA)]})


def ask_speaker(sid, suggestions, known):
    global asks_open
    item = {"kind": "speaker_ask", "sid": sid, "t": now(-3), "seconds": 8.4,
            "quote": QUOTES[sid], "suggestions": suggestions, "known": known}
    if asks_open or sid in skipped or root(sid) in names:
        if sid not in skipped and root(sid) not in names:
            asks_wait.append(item)
        return
    asks_open = sid
    auto(item)


def ask_done(sid):
    global asks_open
    if asks_open == sid:
        asks_open = None
        while asks_wait:
            nxt = asks_wait.pop(0)
            if nxt["sid"] not in skipped and root(nxt["sid"]) not in names:
                asks_open = nxt["sid"]
                nxt["known"] = sorted(set(names.values()) | set(nxt["known"]))[:6]
                auto(nxt)
                break


QUOTES = {"S1": "If the cutoff moves to Friday, QA still needs two days on stage.",
          "S2": "From our side the 3DS certificates are ready, we only wait for Pomelo."}

SCRIPT = [
    (1, lambda: agenda(0)),
    (2, lambda: emit({"kind": "info", "level": "info", "gist": "Demo call: try ⏸ / ▶, 🆘 and the 🗣 line",
                      "note": "about 2.5 minutes, nothing leaves this Mac"})),
    (5, lambda: emit({"kind": "speech", "level": "info", "gist": "🟢 Your speech: since last sync",
                      "phrase": "Short update from my side. We are on track.",
                      "items": ["Done", "1. Cutoff by document is on stage", "2. Payment flow agreed",
                                "Next", "3. Release window on Friday", "Decision needed: 3DS date"]})),
    (8, lambda: status.update(speakers="on")),
    (14, lambda: auto({"kind": "question", "gist": "❓ How long will the cutoff fix take on stage?"})),
    (19, lambda: auto({"kind": "answer", "level": "info", "gist": "🟢 Cutoff fix: 2 days dev + 1 day QA",
                       "phrase": "Two days of development and one day of QA on stage, so Thursday.",
                       "src": now(-5), "at": now()})),
    (22, lambda: ask_speaker("S1", [{"name": "Ірина Мельник", "score": 0.71}, {"name": "Тарас Бондар", "score": 0.52}],
                             ["Андрій Шевчук", "Carlos Andrés Gómez Ruiz"])),
    (30, lambda: agenda(1)),
    (36, lambda: auto({"kind": "tip", "level": "orange", "gist": "🟠 Fix owner and date",
                       "phrase": "So Andres owns the stage check, and we confirm on Thursday?",
                       "src": now(-4), "at": now()})),
    (48, lambda: ask_speaker("S2", [{"name": "Carlos Andrés Gómez Ruiz", "score": 0.66}], ["Андрій Шевчук", "Ірина Мельник"])),
    (56, lambda: start_mic_stall()),
    (66, lambda: agenda(2)),
    (72, lambda: auto({"kind": "question", "gist": "❓ When can we switch 3DS on in production?"})),
    (78, lambda: auto({"kind": "tip", "level": "red", "gist": "🔴 3DS date depends on Pomelo. Do not promise",
                       "phrase": "It depends on Pomelo's certification. We will confirm the date once they reply.",
                       "src": now(-6), "at": now()})),
    (92, lambda: auto({"kind": "card", "level": "info", "gist": "📌 Deploys need client approval",
                       "phrase": "Any prod deploy goes out only after your written approval."})),
    (100, lambda: agenda(3)),
    (112, lambda: auto({"kind": "tip", "level": "orange", "gist": "🟠 Your turn: next steps",
                        "items": ["Cutoff on stage by Thursday", "3DS date after Pomelo replies",
                                  "Next sync on Monday"], "src": now(-3), "at": now()})),
    (126, lambda: emit({"kind": "agenda", "gist": "Client sync, 4 points",
                        "items": [{"text": x, "done": True} for x in AGENDA]})),
]

# Who talks on the other side: (from, to, sid). Gaps = the PM talks or nobody does.
VOICES = [(10, 19, "S1"), (24, 33, "S2"), (37, 44, "S1"), (47, 55, "S2"), (60, 68, "S1"), (72, 79, "S2"),
          (84, 92, "S1"), (97, 104, "S2"), (108, 116, "S1"), (120, 126, "S2")]


def start_mic_stall():
    global mic_stall_from
    mic_stall_from = vt
    status.update(mic="stalled", mic_stall_streak=1)
    say("mic stalled: the window shows 'Use Mac mic'")


def tick_voices():
    cur = next((v for v in VOICES if v[0] <= vt < v[1]), None)
    status["talk_me_pct"] = 38 if vt > 5 else 0
    if cur:
        sid = cur[2]
        # "t" = start of the current line (a new line every 4 s), what the 🗣 popover's "this line" moves.
        status["speaker_now"] = {"sid": sid, "name": names.get(root(sid)), "t": now(-((vt - cur[0]) % 4))}
        status["monologue_s"] = 0
    else:
        status["speaker_now"] = None
        prev_end = max([v[1] for v in VOICES if v[1] <= vt] or [5])
        status["monologue_s"] = int(vt - prev_end) if vt > 5 else 0


def tick_mic():
    global mic_stall_from
    if mic_stall_from is None:
        return
    if status["mic_device"] == "builtin":          # "Use Mac mic" pressed: the recorder switches
        status.update(mic="ok", mic_stall_streak=0)
        mic_stall_from = None
        say("mic ok on the Mac mic")
    elif vt - mic_stall_from > 25:                  # nobody pressed it: the recorder switches itself
        status.update(mic="ok", mic_stall_streak=0, mic_device="builtin", mic_auto_switched=True)
        mic_stall_from = None
        say("mic auto switched to the Mac mic")
    elif vt - mic_stall_from > 12:
        status["mic_stall_streak"] = 3


# ---------- what the window sends ----------
def on_setting(key, value):
    value = "" if value is None else value
    if key == "tips_paused":
        status["tips_paused"] = "on" if value == "on" else "off"
        say(f"tips_paused={status['tips_paused']} (echoed in the status)")
        if status["tips_paused"] == "off":
            while held:
                emit(held.pop(0))
        return
    if key == "speaker_name":
        sid, _, name = str(value).partition("|")
        names[sid] = name
        status["speakers_rev"] += 1
        ask_done(sid)
        return
    if key == "speaker_merge":
        a, _, b = str(value).partition("|")
        merged[a] = b
        status["speakers_rev"] += 1
        ask_done(a)
        return
    if key == "speaker_skip":
        skipped.add(str(value))
        status["speakers_rev"] += 1
        ask_done(str(value))
        return
    if key == "speaker_fix":
        status["speakers_rev"] += 1
        say(f"line moved: {value}")
        return
    if key == "tip_feedback":
        return
    status[key] = value
    if key == "call_lang":
        status["me_lang"] = "en" if value == "en" else "uk"
    if key in ("call_lang", "mic_device", "ui_lang"):
        return                                       # the recorder applies these itself; ui_lang needs no ack
    later.append((vt + 1.5, lambda: emit({"kind": "ack", "key": key, "value": value})))


def on_ask(text):
    if text.strip().lower() == "sos":
        # The recorder answers at once from the fact book, Claude a few seconds later.
        emit({"kind": "fact", "level": "red", "gist": "🆘 Cutoff fix: Thursday on stage",
              "phrase": "Two days of development and one day of QA, so Thursday on stage.", "note": "fact CUTOFF-ETA"})
        emit({"kind": "card", "level": "red", "gist": "🆘 3DS: date depends on Pomelo",
              "phrase": "We will confirm the 3DS date once Pomelo finishes the certification."})
        later.append((vt + 4, lambda: emit({"kind": "answer", "level": "red", "q": "HELP NOW",
                                            "gist": "🔴 Say: Thursday for the cutoff, 3DS after Pomelo",
                                            "phrase": "Cutoff is on stage Thursday. For 3DS we wait for Pomelo and confirm the date then."})))
        return
    later.append((vt + 2, lambda: emit({"kind": "answer", "level": "info", "q": text,
                                        "gist": "Demo answer: in a real call the answer comes from the brief and the transcript"})))


def read_inbox(pos):
    data = inbox.read_bytes()
    if len(data) <= pos:
        return pos
    for raw in data[pos:].decode("utf-8", "replace").splitlines():
        try:
            d = json.loads(raw)
        except Exception:  # noqa: BLE001
            continue
        if d.get("kind") == "setting":
            on_setting(d.get("key", ""), d.get("value"))
        else:
            on_ask(d.get("text", ""))
    return len(data)


# In --dry the "user" clicks are simulated by writing what the window would write.
DRY_CLICKS = [(26, {"kind": "setting", "key": "speaker_name", "value": "S1|Ірина Мельник"}),
              (40, {"kind": "setting", "key": "tips_paused", "value": "on"}),
              (50, {"kind": "setting", "key": "tips_paused", "value": "off"}),
              (52, {"kind": "setting", "key": "speaker_skip", "value": "S2"}),
              (60, {"kind": "setting", "key": "mic_device", "value": "builtin"}),
              (64, {"text": "sos"}),
              (88, {"kind": "setting", "key": "speaker_fix", "value": "12:00:00|S2"}),
              (95, {"text": "what was decided"}),
              (100, {"kind": "setting", "key": "audience", "value": "team"})]


def main():
    global vt
    write_status()
    win = None
    if not DRY:
        if not PROMPTER.exists():
            raise SystemExit(f"No window app at {PROMPTER}: run install.sh first.")
        cmd = [str(PROMPTER), "--tips", str(tips), "--inbox", str(inbox), "--status", str(status_f),
               "--control", str(control), "--html", str(ROOT / "src" / "prompter.html"),
               "--title", "Prompter (demo)"]
        log = open(tmp / "prompter.log", "w")
        win = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        time.sleep(3)
        if win.poll() is not None:
            log.close()
            print(f"The window app exited at once (code {win.returncode}). Its output:")
            print((tmp / "prompter.log").read_text(errors="replace") or "(empty)")
            raise SystemExit(1)
        print(f"Demo window is running (pid {win.pid}). Files: {tmp}")
        print("If you do not see it: it may sit exactly over or under the live tips window "
              "(same saved position), or on another screen / Space. Close the window or press Ctrl+C to stop.")
    t0 = time.time()
    pos, step, lines, finished = 0, 0, 0, False
    clicks = list(DRY_CLICKS) if DRY else []
    try:
        while True:
            if DRY:
                vt += 0.5
                if vt > END_AT + 10:
                    break
            else:
                if win.poll() is not None:
                    break
                time.sleep(0.5)
                vt = time.time() - t0
            while clicks and clicks[0][0] <= vt:
                with open(inbox, "a", encoding="utf-8") as f:
                    f.write(json.dumps(dict(clicks.pop(0)[1], t=now()), ensure_ascii=False) + "\n")
            lines += 1
            status["lines"] = lines // 2
            if (control / "mic_muted").exists():
                status["mic"] = "muted"
            elif status["mic"] == "muted":
                status["mic"] = "ok"
            pos = read_inbox(pos)
            while step < len(SCRIPT) and vt >= SCRIPT[step][0]:
                SCRIPT[step][1]()
                step += 1
            due = [x for x in later if x[0] <= vt]
            later[:] = [x for x in later if x[0] > vt]
            for _, fn in due:
                fn()
            tick_voices()
            tick_mic()
            # Finally the red "Claude is not listening" warning, then the recording stops.
            status["listener_age_s"] = 76 + int(vt - 132) if 132 <= vt < END_AT else 3
            if vt >= END_AT and not finished:
                finished = True
                status.update(state="stopped", speaker_now=None)
                say("script finished")
                if not DRY:
                    print("Demo script finished. Close the window to exit.")
            write_status()
    except KeyboardInterrupt:
        pass
    if win and win.poll() is None:
        win.terminate()
    if DRY:
        print(f"DRY OK: {len(log_lines)} events, files in {tmp}")
    else:
        print("Demo finished.")


if __name__ == "__main__":
    main()
