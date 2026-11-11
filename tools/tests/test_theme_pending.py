"""2026-11-10 (owner): the "not ready" orange stays bright in both themes. It turned brown twice "for contrast"
(C2410C, then B45309); this test fails when PN.C.pending or PN.C.pendingFill gets dull, dark or red again."""
import colorsys
import re
from pathlib import Path

THEME = Path(__file__).absolute().parents[2] / "app" / "Sources" / "LiveTips" / "PacenoteTheme.swift"


def colors(name):
    m = re.search(r"static let " + name + r"\s*=\s*Color\.pn\(0x([0-9A-Fa-f]{6}),\s*0x([0-9A-Fa-f]{6})", THEME.read_text())
    assert m, name + " not found in PacenoteTheme.swift"
    return m.group(1), m.group(2)


def hsv(hexs):
    r, g, b = (int(hexs[i:i + 2], 16) / 255 for i in (0, 2, 4))
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    return h * 360, s, v


def test_pending_orange_is_bright():
    for name in ("pending", "pendingFill"):
        for theme, value in zip(("light", "dark"), colors(name)):
            h, s, v = hsv(value)
            assert 18 <= h <= 40, f"{name} {theme} #{value}: hue {h:.0f} is not orange"
            assert v >= 0.88, f"{name} {theme} #{value}: too dark ({v:.2f}), the owner wants it bright"
            assert s >= 0.7, f"{name} {theme} #{value}: too dull ({s:.2f})"


def test_old_brown_values_do_not_come_back():
    for value in colors("pending") + colors("pendingFill"):
        assert value.upper() not in ("B45309", "C2410C", "9A4600"), "#" + value + " is the brown the owner rejected"
