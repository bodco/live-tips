"""0.10.0 (Meeting Sheet, phase 1): manual edits survive a rebuild (Refresh uses it, phase 3).

protect_edits(old, new) returns a copy of `new` where:
  - a block the user edited (edited_by_user) is the old block as it was;
  - a fact the user wrote (origin user) or changed (status edited) is the old fact as it was, in the same block:
    it replaces the new fact with the same id, or is added at its old place when the new build has no such fact;
  - a protected fact whose block is gone from the new sheet brings its block back with only the protected facts.
Facts of the readiness engine are not protected: it adds them again by itself.
"""
import copy
from typing import Dict, List


def is_protected(fact: dict) -> bool:
    return fact.get("status") == "edited" or fact.get("origin") == "user"


def _key(b: dict) -> str:
    return b.get("id") or b.get("type", "")


def protect_edits(old_sheet: dict, new_sheet: dict) -> dict:
    out = copy.deepcopy(new_sheet)
    blocks: List[dict] = out.setdefault("blocks", [])
    by_id: Dict[str, dict] = {_key(b): b for b in blocks}
    by_type: Dict[str, dict] = {}
    for b in blocks:
        by_type.setdefault(b.get("type", ""), b)
    for ob in old_sheet.get("blocks") or []:
        nb = by_id.get(_key(ob)) or by_type.get(ob.get("type", ""))
        if ob.get("edited_by_user"):
            keep = copy.deepcopy(ob)
            if nb is None:
                blocks.append(keep)
            else:
                blocks[blocks.index(nb)] = keep
            continue
        old_facts = ob.get("facts") or []
        prot = [(i, f) for i, f in enumerate(old_facts) if is_protected(f)]
        if not prot:
            continue
        if nb is None:
            nb = copy.deepcopy(ob)
            nb["facts"] = []
            blocks.append(nb)
        facts = nb.setdefault("facts", [])
        for i, f in prot:
            keep = copy.deepcopy(f)
            keep.pop("diff", None)
            at = next((j for j, x in enumerate(facts) if x.get("id") == f.get("id")), None)
            if at is not None:
                facts[at] = keep
            else:
                facts.insert(min(i, len(facts)), keep)
    # A protected fact moved into another block by the user must not also stay where the new build put it.
    prot_ids = {f.get("id") for b in blocks for f in b.get("facts") or [] if is_protected(f)}
    for b in blocks:
        b["facts"] = [f for f in b.get("facts") or [] if is_protected(f) or f.get("id") not in prot_ids]
    return out
