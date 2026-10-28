from types import SimpleNamespace as S

from livetips_m0.engine import asks_the_pm, route_when_off


def sig(**kw):
    base = dict(name_vocative=False, question=False, second_person=False, third_person=False, name_mention=False, trigger_hint="")
    return S(**dict(base, **kw))


def test_asks_the_pm():
    assert asks_the_pm(sig(name_vocative=True))
    assert asks_the_pm(sig(question=True, second_person=True))
    assert not asks_the_pm(sig(question=True))
    assert not asks_the_pm(sig(second_person=True))
    assert not asks_the_pm(sig(name_vocative=True, third_person=True))


def test_route_when_off():
    assert route_when_off(sig(question=True, trigger_hint="question")) == "classify"
    assert route_when_off(sig(name_mention=True)) == "classify"
    assert route_when_off(sig(question=True, trigger_hint="pm_commitment")) is None
    assert route_when_off(sig(question=True, trigger_hint="new_requirement")) is None
    assert route_when_off(sig()) is None
