"""Download the audio of a link for Transcribe a recording (Pacenote 0.8.6, rules/transcribe.yaml > link).

  fetchlink.py <url> <out dir>

Uses the optional Link downloader (yt-dlp in the core's private venv, rules/components.yaml), audio only, no
re-encoding when possible. Google Drive falls back to the plain download URL with the confirm token. Prints JSON
lines: {"stage": "download", "pct": ..} and at the end {"ok": true, "file": .., "title": .., "date": "YYYY-MM-DD"}
or {"ok": false, "error": ..}."""
from __future__ import annotations

import http.cookiejar
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

SIGN_IN = ("This link needs a sign-in. Set sharing to Anyone with the link, or download the file and drop it here.")


def emit(o: dict) -> None:
    print(json.dumps(o, ensure_ascii=False), flush=True)


def source(url: str) -> str:
    """The chip of the Transcribe window: drive, youtube, vimeo, dropbox, direct (or "" when not a link)."""
    try:
        u = urllib.parse.urlparse(url.strip())
    except ValueError:
        return ""
    if u.scheme not in ("http", "https") or not u.netloc:
        return ""
    h = u.netloc.lower()
    if h.endswith("drive.google.com") or h.endswith("docs.google.com"):
        return "drive"
    if h.endswith("youtube.com") or h.endswith("youtu.be"):
        return "youtube"
    if h.endswith("vimeo.com"):
        return "vimeo"
    if h.endswith("dropbox.com"):
        return "dropbox"
    return "direct"


def drive_id(url: str) -> str | None:
    m = re.search(r"/d/([A-Za-z0-9_-]{10,})", url) or re.search(r"[?&]id=([A-Za-z0-9_-]{10,})", url)
    return m.group(1) if m else None


def needs_sign_in(msg: str) -> bool:
    m = msg.lower()
    return any(k in m for k in ("sign in", "login", "private video", "401", "403", "permission", "accounts.google.com",
                                "requested format is not available", "cookies"))


def drive_fallback(fid: str, out: Path) -> Path:
    """https://drive.google.com/uc?export=download&id=<id>, following the confirm page of large files."""
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    url = f"https://drive.google.com/uc?export=download&id={fid}"
    r = op.open(url, timeout=60)
    ctype = r.headers.get("Content-Type", "")
    if "text/html" in ctype:
        page = r.read().decode("utf-8", "replace")
        if "accounts.google.com" in page or "ServiceLogin" in page:
            raise PermissionError(SIGN_IN)
        tok = re.search(r'name="confirm" value="([^"]+)"', page) or re.search(r"confirm=([0-9A-Za-z_-]+)", page)
        uuid = re.search(r'name="uuid" value="([^"]+)"', page)
        if not tok:
            raise PermissionError(SIGN_IN)
        q = {"export": "download", "id": fid, "confirm": tok.group(1)}
        if uuid:
            q["uuid"] = uuid.group(1)
        r = op.open("https://drive.usercontent.google.com/download?" + urllib.parse.urlencode(q), timeout=60)
        if "text/html" in r.headers.get("Content-Type", ""):
            raise PermissionError(SIGN_IN)
    name = "drive-" + fid
    cd = r.headers.get("Content-Disposition", "")
    m = re.search(r'filename="?([^";]+)', cd)
    if m:
        name = Path(m.group(1)).name
    dst = out / name
    total = int(r.headers.get("Content-Length") or 0)
    got = 0
    with open(dst, "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            f.write(b)
            got += len(b)
            if total:
                emit({"stage": "download", "pct": round(100 * got / total, 1)})
    return dst


def run(url: str, out: Path) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    kind = source(url)
    if not kind:
        return {"ok": False, "error": "Not a link."}
    try:
        import yt_dlp  # type: ignore
    except Exception:  # noqa: BLE001
        yt_dlp = None
    if yt_dlp is not None:
        info_box: dict = {}

        def hook(d):
            if d.get("status") == "downloading":
                tot = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                if tot:
                    emit({"stage": "download", "pct": round(100 * (d.get("downloaded_bytes") or 0) / tot, 1)})
            elif d.get("status") == "finished":
                info_box["file"] = d.get("filename")
        opts = {"format": "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]/bestaudio/best", "outtmpl": str(out / "%(id)s.%(ext)s"), "quiet": True, "noprogress": True,
                "progress_hooks": [hook], "noplaylist": True}
        try:
            with yt_dlp.YoutubeDL(opts) as y:
                info = y.extract_info(url, download=True)
                f = info_box.get("file") or y.prepare_filename(info)
            d = str(info.get("upload_date") or "")
            return {"ok": True, "file": f, "title": info.get("title") or "",
                    "date": f"{d[:4]}-{d[4:6]}-{d[6:8]}" if len(d) == 8 else ""}
        except Exception as e:  # noqa: BLE001
            msg = str(e)
            if kind not in ("drive", "dropbox"):
                return {"ok": False, "error": SIGN_IN if needs_sign_in(msg) else msg[:300]}
    elif kind not in ("drive", "direct", "dropbox"):
        return {"ok": False, "error": "needs_component", "component": "link_downloader"}
    try:
        if kind == "drive":
            fid = drive_id(url)
            if not fid:
                return {"ok": False, "error": "This Google Drive link has no file id."}
            f = drive_fallback(fid, out)
        else:
            if kind == "dropbox":          # a shared Dropbox page; dl=1 gives the file itself
                url = re.sub(r"([?&])dl=0", r"\1dl=1", url) if "dl=0" in url else url + ("&" if "?" in url else "?") + "dl=1"
            name = Path(urllib.parse.urlparse(url).path).name or "download"
            f = out / name
            with urllib.request.urlopen(url, timeout=60) as r, open(f, "wb") as w:
                if "text/html" in r.headers.get("Content-Type", ""):
                    return {"ok": False, "error": SIGN_IN}
                w.write(r.read())
        return {"ok": True, "file": str(f), "title": Path(f).stem, "date": ""}
    except PermissionError:
        return {"ok": False, "error": SIGN_IN}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": SIGN_IN if needs_sign_in(str(e)) else str(e)[:300]}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    res = run(sys.argv[1], Path(sys.argv[2]))
    emit(res)
    sys.exit(0 if res.get("ok") else 1)
