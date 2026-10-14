#!/usr/bin/env python3
"""Demo of the tips window (prompter) without a call, a model or Claude.

Opens the real window with a fake recording status and plays a short scripted call:
tips appear one by one, the setup row (gear) works, questions typed in the window get a
canned answer, the mute button and the "Claude is not listening" warning are shown.

  python3 ~/work/Tools/live-transcriber/bin/demo_prompter.py        # about 2 minutes
Close the window or press Ctrl+C to end it.
"""
import json
import os
import subprocess
import tempfile
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPTER = ROOT / "bin" / "prompter"
tmp = Path(tempfile.mkdtemp(prefix="prompter-demo-"))
tips, inbox, status_f, control = tmp / "demo.tips.jsonl", tmp / "demo.inbox.jsonl", tmp / "status.json", tmp / "control"
control.mkdir()
inbox.write_text("")
tips.write_text("")

status = {"state": "recording", "title": "Demo: client call", "lines": 0, "queue": 0,
          "mic": "ok", "system_audio": "ok", "errors": [], "mic_device": "default",
          "me_lang": "en", "setup_open": True, "call_type": "", "hiring_role": "",
          "started_at": datetime.now().astimezone().isoformat(timespec="seconds"),
          "listener_age_s": 3}


def now():
    return datetime.now().strftime("%H:%M:%S")


def write_status():
    p = status_f.with_suffix(".tmp")
    p.write_text(json.dumps(status, ensure_ascii=False))
    os.replace(p, status_f)


def tip(**kw):
    kw.setdefault("t", now())
    with open(tips, "a", encoding="utf-8") as f:
        f.write(json.dumps(kw, ensure_ascii=False) + "\n")


SCRIPT = [
    (2, dict(kind="info", level="info", gist="Set the meeting type in ⚙ to get your speech",
             note="demo: try the gear row above, then ⓘ for help")),
    (8, dict(kind="speech", level="info", gist="🟢 Твій спіч: за 13-14.10",
             phrase="Short update from my side. We are on track.",
             items=["Done", "1. Transaction report is in testing", "2. Payment flow agreed",
                    "Next", "3. Release window on Friday", "Decision needed: release date"])),
    (10, dict(kind="tip", level="orange", gist="🟠 Можеш додати: ціни конкурентів",
              phrase="We compared two tools. Both charge per seat, about 30 euro a month.",
              note="порівняння цін, 13.10")),
    (10, dict(kind="tip", level="red", gist="🔴 Нова вимога. Не погоджуй зараз.",
              phrase="Good idea. I will write it down. We will check it and come back to you.")),
    (10, dict(kind="tip", level="orange", gist="🟠 Уточни: коли буде готово",
              phrase="What exactly is left, and when do you expect it to be done?")),
    (10, dict(kind="tip", level="red", gist="🔴 Твоя черга: апдейт",
              phrase="Short update from my side. We are on track.",
              items=["Transaction report is in testing", "Payments: waiting for the client",
                     "We need a decision on the release date"])),
    (10, dict(kind="tip", level="orange", gist="💡 API testing",
              items=["Postman or REST Assured", "status codes, schemas, negative cases",
                     "contract tests in CI"], note="interview mode: what a strong answer contains")),
    (8, dict(kind="tip", level="info", gist="✓ кандидат: схеми і негативні кейси є, CI не згадав")),
]


def main():
    write_status()
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
    pos = 0
    step, next_at, lines = 0, time.time() + SCRIPT[0][0], 0
    deaf_from = None
    try:
        while win.poll() is None:
            time.sleep(0.5)
            lines += 1
            status["lines"] = lines // 2
            status["mic"] = "muted" if (control / "mic_muted").exists() else "ok"
            # Questions and settings from the window.
            data = inbox.read_bytes()
            if len(data) > pos:
                for raw in data[pos:].decode("utf-8", "replace").splitlines():
                    try:
                        d = json.loads(raw)
                    except Exception:  # noqa: BLE001
                        continue
                    if d.get("kind") == "setting":
                        status[d["key"]] = d.get("value")
                        if d["key"] == "call_lang":
                            status["me_lang"] = "en" if d["value"] == "en" else "uk"
                        # Newer windows confirm a setting when Claude writes an "ack" item.
                        time.sleep(1.5)
                        tip(kind="ack", key=d["key"], value=d.get("value"))
                        tip(kind="tip", level="info", gist=f"⚙ {d['key']} = {d.get('value')}",
                            note="demo: the skill would rebuild the prep for this")
                    else:
                        tip(kind="answer", level="info", q=d.get("text", ""),
                            gist="Demo answer: in a real call the answer comes from the brief and the transcript")
                pos = len(data)
            if step < len(SCRIPT) and time.time() >= next_at:
                tip(**SCRIPT[step][1])
                step += 1
                if step < len(SCRIPT):
                    next_at = time.time() + SCRIPT[step][0]
                else:
                    deaf_from = time.time() + 8
            # Finally show the red "Claude is not listening" warning for a while.
            if deaf_from and time.time() >= deaf_from:
                status["listener_age_s"] = 76 + int(time.time() - deaf_from)
            else:
                status["listener_age_s"] = 3
            write_status()
    except KeyboardInterrupt:
        win.terminate()
    print("Demo finished.")


if __name__ == "__main__":
    main()
