"""0.8.7 (H5, rules/index.yaml > answer_cards): the answer cards file is a document source of the project index."""
import importlib.util
from pathlib import Path

import pytest

np = pytest.importorskip("numpy")
SRC = Path(__file__).resolve().parents[3] / "recorder" / "src" / "semantic.py"


def semantic():
    spec = importlib.util.spec_from_file_location("semantic_087", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_cards_are_indexed_even_when_the_folder_is_excluded(tmp_path):
    sem = semantic()
    (tmp_path / "pacenote").mkdir()
    cards = tmp_path / "pacenote" / "answer-cards.md"
    cards.write_text("## Price is too high\nOrbit pays back in 4 months.\nTags: price\n", encoding="utf-8")
    (tmp_path / "notes.md").write_text("Northwind kickoff notes", encoding="utf-8")
    rels = {rel for _, rel, _ in sem.iter_files([(tmp_path, "")])}
    assert rels == {"notes.md", "pacenote/answer-cards.md"}
    only = {rel for _, rel, _ in sem.iter_files([(tmp_path, "")], exclude={str(tmp_path / "pacenote") + "/*"})}
    assert "pacenote/answer-cards.md" in only, "the cards stay a source even when their folder is excluded"
    extra = tmp_path / "shared"
    (extra / "pacenote").mkdir(parents=True)
    (extra / "pacenote" / "answer-cards.md").write_text("## Security\nSOC 2 report on request.\n", encoding="utf-8")
    rels = [rel for _, rel, _ in sem.iter_files([(tmp_path, ""), (extra, "shared")])]
    assert rels.count("pacenote/answer-cards.md") == 1 and "shared/pacenote/answer-cards.md" in rels


def test_rules_list_the_cards_source():
    import yaml
    doc = yaml.safe_load((SRC.parents[2] / "rules" / "index.yaml").read_text(encoding="utf-8"))
    assert doc["answer_cards"]["file"] == "/".join(semantic().ANSWER_CARDS)
