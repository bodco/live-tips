"""0.10.0 (Meeting Sheet, Google Picker): a Drive file link stays "denied" with confirm_google until the PM confirms
it in Google Picker; the app's copy in <project>/live/google/google-file-<id16>.<ext> then makes it "ok". No network:
the copies are written here. Invented data only (Emily Parker, Lumenfield)."""
import os
import time

from livetips_m0.sheet import size as Z
from livetips_m0.sheet import sources as SRC

FILE_ID = "1FileIdIdIdIdIdXYZ"
URL = f"https://drive.google.com/file/d/{FILE_ID}/view?usp=sharing"


def _check(src, req):
    s = SRC.normalize([src])[0]
    texts = {}
    SRC.check(s, req, texts, "codex", Z.load_windows())
    return s, texts


def _req(root, connected=True, **g):
    return {"project": {"root": str(root)}, "google": dict({"connected": connected}, **g)}


def test_drive_file_denied_until_confirmed(tmp_path):
    s, _ = _check({"uri": URL}, _req(tmp_path))
    assert s["type"] == "drive_file" and s["access"] == "denied" and s["fix_action"] == "confirm_google"
    assert SRC.picked_copy(_req(tmp_path), {"uri": URL}) is None


def test_confirmed_copy_on_disk_makes_it_ok(tmp_path):
    folder = tmp_path / "live" / "google"
    folder.mkdir(parents=True)
    (folder / f"google-file-{FILE_ID[:16]}.txt").write_text("Lumenfield rollout: Emily Parker signs on Friday",
                                                            encoding="utf-8")
    s, texts = _check({"uri": URL}, _req(tmp_path))
    assert s["access"] == "ok" and "fix_action" not in s
    assert s["copy"].endswith(".txt") and "Emily Parker" in texts[s["id"]]
    # even without a Google connection the confirmed copy is read (it is on this Mac)
    s, _ = _check({"uri": URL}, _req(tmp_path, connected=False))
    assert s["access"] == "ok"


def test_copy_from_the_request_wins_and_newest_copy_is_used(tmp_path):
    folder = tmp_path / "live" / "google"
    folder.mkdir(parents=True)
    old = folder / f"google-file-{FILE_ID[:16]}.md"
    old.write_text("old text", encoding="utf-8")
    new = folder / f"google-file-{FILE_ID[:16]}.csv"
    new.write_text("name,role\nEmily Parker,owner\n", encoding="utf-8")
    t = time.time()
    os.utime(old, (t - 100, t - 100))
    os.utime(new, (t, t))
    (folder / f"google-file-{FILE_ID[:16]}.pdf.part").write_text("partial", encoding="utf-8")
    assert SRC.picked_copy(_req(tmp_path), {"uri": URL}) == str(new)
    given = tmp_path / "given.md"
    given.write_text("from the app's google.copies", encoding="utf-8")
    s, texts = _check({"uri": URL}, _req(tmp_path, copies={FILE_ID: str(given)}))
    assert s["copy"] == str(given) and "google.copies" in texts[s["id"]]


def test_a_copy_of_another_file_or_a_doc_link_is_not_used(tmp_path):
    folder = tmp_path / "live" / "google"
    folder.mkdir(parents=True)
    (folder / "google-file-1OtherFileIdIdId.txt").write_text("another file", encoding="utf-8")
    s, _ = _check({"uri": URL}, _req(tmp_path))
    assert s["access"] == "denied" and s["fix_action"] == "confirm_google"
    # a Google Doc link never takes a Picker copy: Docs are read through documents.readonly
    doc = "https://docs.google.com/document/d/1FileIdIdIdIdIdXYZ/edit"
    (folder / f"google-file-{FILE_ID[:16]}.txt").write_text("picked", encoding="utf-8")
    assert SRC.picked_copy(_req(tmp_path), {"uri": doc}) is None
    s, _ = _check({"uri": doc}, _req(tmp_path))
    assert s["access"] == "pending" and s["fix_action"] == "retry"


def test_empty_copy_is_unsupported_not_ok(tmp_path):
    folder = tmp_path / "live" / "google"
    folder.mkdir(parents=True)
    (folder / f"google-file-{FILE_ID[:16]}.txt").write_text("   ", encoding="utf-8")
    s, _ = _check({"uri": URL}, _req(tmp_path))
    assert s["access"] == "unsupported"
