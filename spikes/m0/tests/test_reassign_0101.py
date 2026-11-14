"""0.10.1 (A2): op "move" in the commitments register (rules/commitments.yaml), same fold as Swift."""
from livetips_m0 import commitments as cm


def ev(op, cid, **kw):
    return dict({"op": op, "id": cid}, **kw)


def test_move_removes_item_and_alias():
    events = [
        ev("add", "c-1", text="Send the deck to Mike", owner="me", call="a.app.md"),
        ev("add", "c-2", text="Send the deck to Mike now", owner="me", call="a.md"),   # duplicate -> alias of c-1
        ev("add", "c-3", text="Other", owner="me", call="b.app.md"),
        ev("done", "c-1", at="t"),
        ev("move", "c-1", to="my-calls"),
        ev("move", "c-2", to="my-calls"),
    ]
    assert [i["id"] for i in cm.fold(events)] == ["c-3"]


def test_move_back_re_adds_once():
    events = [
        ev("add", "c-1", text="Check the budget", owner="Emily", call="a.md"),
        ev("move", "c-1", to="x"),
        ev("add", "c-1", text="Check the budget", owner="Emily", call="a.md"),
        ev("done", "c-1", at="t"),
    ]
    items = cm.fold(events)
    assert len(items) == 1 and items[0]["status"] == "done"
