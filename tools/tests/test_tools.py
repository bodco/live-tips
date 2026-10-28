"""tools/check_anonymized.py and tools/gen_skill_section.py on temp trees (pinned before the ub-mode split)."""
import shutil
from pathlib import Path

import check_anonymized as A
import gen_skill_section as G

REPO = Path(__file__).absolute().parents[2]
LD = chr(0x2014)
USERS = "/Us" + "ers/"                     # built at run time: this file must pass the same check
KEY = "sk-" + "ant-abcdefgh123"
HEXID = "a1b2c3d4e5f6" + "0718293a4b5c6d7e8f90"


def test_check_anonymized(tmp_path, capsys):
    (tmp_path / "ok.md").write_text("Fake ids are fine: 11111111-1111-1111-1111-111111111111 0123456789abcdef0123456789abcdef\n")
    (tmp_path / "bad.py").write_text("p = '" + USERS + "somebody/x'\nkey = '" + KEY + "'\nid = '" + HEXID + "'\n"
                                     "dash = 'a" + LD + "b'\nok = '" + USERS + "you/x'\nname = 'Acme Corp'\n")
    for d in (".git", "runs", ".metrics"):
        (tmp_path / d).mkdir()
        (tmp_path / d / "x.md").write_text(USERS + "somebody")
    (tmp_path / "LICENSE").write_text(USERS + "somebody")
    (tmp_path / "image.png").write_text(USERS + "somebody")
    deny = tmp_path / "deny.txt"
    deny.write_text("# comment\n\nacme corp\n")
    assert A.main(["--root", str(tmp_path)]) == 1
    out = capsys.readouterr().out.splitlines()
    assert out == ["bad.py:1: absolute macOS user path", "bad.py:2: Anthropic key", "bad.py:3: UUID (Notion or other ID)",
                   "bad.py:4: long dash", "anonymization: 4 finding(s)"]
    assert A.main(["--root", str(tmp_path), "--deny", str(deny)]) == 1
    assert "bad.py:6: deny list term" in capsys.readouterr().out
    (tmp_path / "bad.py").unlink()
    assert A.main(["--root", str(tmp_path)]) == 0


def copy_rules(tmp_path):
    rules = tmp_path / "rules"
    shutil.copytree(REPO / "rules", rules)
    return rules


def test_gen_skill_section(tmp_path, monkeypatch, capsys):
    rules = copy_rules(tmp_path)
    for name in ("ROOT", "RULES", "OUT", "OUT_REG", "OUT_AFTER"):
        val = {"ROOT": tmp_path, "RULES": rules, "OUT": rules / "generated" / "skill_triggers.md",
               "OUT_REG": rules / "generated" / "skill_register.md", "OUT_AFTER": rules / "generated" / "skill_after.md"}[name]
        monkeypatch.setattr(G, name, val)
    shutil.rmtree(rules / "generated")
    assert G.main(["--check"]) == 1
    assert G.main([]) == 0 and "wrote rules/generated/skill_triggers.md" in capsys.readouterr().out
    assert G.main(["--check"]) == 0
    skill = tmp_path / "SKILL.md"
    good = ("# Skill\n\n### Triggers\n\nintro\n\n" + G.render(rules) + "\nafter\n\n" + G.REG_HEAD + "\n\n" + G.render_register(rules) +
            "\n" + G.AFTER_HEAD + "\n" + G.render_after(rules) + "\n## End\n")
    skill.write_text(good)
    assert G.main(["--compare", str(skill)]) == 0
    skill.write_text(good.replace(G.AFTER_HEAD, "### Something else"))
    assert G.main(["--compare", str(skill)]) == 1
    lines = G.render(rules).splitlines()
    skill.write_text(good.replace(lines[2], lines[2] + " changed"))
    assert G.main(["--compare", str(skill)]) == 1
    assert "DRIFT: the Triggers table" in capsys.readouterr().err
    (rules / "generated" / "skill_after.md").write_text("old")
    assert G.main(["--check"]) == 1


def test_real_repo_is_clean_and_generated():
    assert A.main([]) == 0
    assert G.main(["--check"]) == 0
