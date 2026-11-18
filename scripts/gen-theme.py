#!/usr/bin/env python3
"""Pacenote theme token generator (redesign, block 1).

Reads the design source `research/redesign-src/_themes.js` (the Roadbook and Broadsheet palettes and style
parameters, the same file the canvas boards are built from) and writes:

  app/Sources/LiveTips/PNTheme+Tokens.swift   PNTheme.roadbookDark / roadbookLight / broadsheetLight / broadsheetDark
  app/Resources/tips/tokens.css               the block between the GENERATED markers (data-style x data-theme)

Classic is not generated: it is the look the app had (PNTheme.classic in PNTheme.swift and the :root block of
tokens.css), so "Classic without regressions" stays true by construction.

Usage:  python3 scripts/gen-theme.py [path/to/_themes.js] [--check]
  --check  exit 1 when the generated files differ from what is on disk (for CI and for the ship checklist)
Default source: <repo>/../research/redesign-src/_themes.js (the Bodco/Pacenote workspace layout), or
$PACENOTE_THEMES_JS.
"""
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SWIFT_OUT = REPO / "app" / "Sources" / "LiveTips" / "PNTheme+Tokens.swift"
CSS_OUT = REPO / "app" / "Resources" / "tips" / "tokens.css"
BEGIN, END = "/* BEGIN GENERATED THEMES (scripts/gen-theme.py, do not edit) */", "/* END GENERATED THEMES */"


def parse_js(src: str):
    """Returns {const name: dict} with Object.assign({}, BASE, {...}) resolved."""
    consts = {}
    pair = re.compile(r"(\w+)\s*:\s*('(?:[^']*)'|-?\d+(?:\.\d+)?)")

    def fields(body):
        d = {}
        for k, v in pair.findall(body):
            d[k] = v[1:-1] if v.startswith("'") else (float(v) if "." in v else int(v))
        return d

    for m in re.finditer(r"const (\w+) = \{([^{}]*)\};", src):
        consts[m.group(1)] = fields(m.group(2))
    for m in re.finditer(r"const (\w+) = Object\.assign\(\{\}, (\w+), \{([^{}]*)\}\);", src):
        d = dict(consts[m.group(2)])
        d.update(fields(m.group(3)))
        consts[m.group(1)] = d
    return consts


def hexv(s):
    """'#0D0D0B' -> 0x0D0D0B literal text; 'transparent' or '' -> None."""
    if not s or s == "transparent":
        return None
    assert re.fullmatch(r"#[0-9A-Fa-f]{6}", s), s
    return "0x" + s[1:].upper()


def req(t, k):
    v = hexv(t[k])
    assert v, f"{k} must be a colour"
    return v


def opt(t, k):
    return hexv(t.get(k, "transparent")) or "nil"


def em(s):
    s = str(s)
    return "0" if s in ("0", "") else s.replace("em", "")


def derived(t):
    """Same rules as the tail of _themes.js."""
    sp = t["markDot"] if str(t.get("markDot", "")).startswith("#") else (
        "#4D9DFF" if t.get("markBg") == "transparent" and re.match(r"#[0-3]", t["bg"]) else "#0A6CFF")
    return sp


def swift_theme(name, style, dark, t):
    rb = style == "roadbook"
    font = {"Barlow Condensed": ".barlowCondensed", "Barlow": ".barlow", "Inter Tight": ".interTight",
            "JetBrains Mono": ".jetBrainsMono", "IBM Plex Mono": ".plexMono"}
    face = lambda k: font[t[k].split(",")[0].strip()]
    nrbg = opt(t, "nrBg")
    # legacy roles of PN.C: turn = ready text, on-me = not-ready text, danger = rec text
    lines = [
        f"    static let {name} = PNTheme(",
        f"        style: .{style}, dark: {'true' if dark else 'false'},",
        f"        bg: {req(t,'bg')}, surface: {req(t,'surface')}, surface2: {req(t,'surface2')}, frame: {req(t,'frame')},",
        f"        ink: {req(t,'ink')}, ink2: {req(t,'ink2')}, ink3: {req(t,'ink3')},",
        f"        rule: {req(t,'rule')}, ruleStrong: {req(t,'ruleStrong')}, field: {req(t,'field')},",
        f"        accent: {req(t,'accent')}, onAccent: {req(t,'onAccent')}, link: {req(t,'link')},",
        f"        hlBg: {opt(t,'hlBg')}, hlFg: {req(t,'hlFg')},",
        f"        markBg: {opt(t,'markBg')}, markFg: {req(t,'markFg')}, markDot: {req(t,'markDot')}, spDot: {hexv(derived(t))},",
        f"        ready: {req(t,'ready')}, readyText: {req(t,'readyText')},",
        f"        notready: {req(t,'notready')}, notreadyText: {req(t,'notreadyText')}, nrBg: {nrbg},",
        f"        rec: {req(t,'rec')}, recText: {req(t,'recText')},",
        f"        answer: {req(t,'answer')}, docs: {req(t,'docs')}, edge: {req(t,'edge')},",
        f"        turn: {req(t,'readyText')}, onMe: {req(t,'notreadyText')}, danger: {req(t,'recText')}, pending: {req(t,'notreadyText')}, pendingFill: {req(t,'notready')},",
        f"        caps: {'true' if t['caps']=='uppercase' else 'false'}, radiusButton: 0, radiusCard: 0, ruleHeavy: 3, statusSquare: {'true' if t['stR']=='0' else 'false'},",
        f"        display: {face('fD')}, text: {face('fT')}, mono: {face('fM')},",
        f"        bSize: {t['bSize']}, bigBtn: {t['bigBtn']}, tabSize: {t['tabSize']}, secSize: {t['secSize']}, titleSize: {t['titleSize']}, bigNum: {t['bigNum']},",
        f"        bTrack: {em(t['bLS'])}, secTrack: {em(t['secLS'])}, lblTrack: {em(t['lblLS'])}, dTrack: {em(t['dLS'])},",
        f"        ringSteps: {4 if rb else 'nil'}, drawSteps: {6 if rb else 'nil'}, barSteps: {3 if rb else 'nil'}, barRound: {'false' if rb else 'true'})",
    ]
    return "\n".join(lines)


CSS_FONT = {"Barlow Condensed": "'Barlow Condensed'", "Barlow": "'Barlow'", "Inter Tight": "'Inter Tight'",
            "JetBrains Mono": "'JetBrains Mono'", "IBM Plex Mono": "'IBM Plex Mono'"}


def css_block(style, mode, t):
    rb = style == "roadbook"
    fam = lambda k: CSS_FONT[t[k].split(",")[0].strip()]
    fb = {"fD": ", 'Arial Narrow', sans-serif" if rb else ", -apple-system, sans-serif",
          "fT": ", -apple-system, sans-serif", "fM": ", ui-monospace, Menlo, monospace"}
    c = lambda k: t[k] if t.get(k) and t[k] != "transparent" else "transparent"
    v = []
    add = lambda n, val: v.append(f"  --pn-{n}:{val};")
    for k in ("bg", "surface", "surface2", "frame", "ink", "ink2", "ink3", "rule", "ruleStrong", "field", "accent", "onAccent",
              "link", "hlBg", "hlFg", "markBg", "markFg", "markDot", "ready", "readyText", "notready", "notreadyText", "nrBg",
              "rec", "recText", "answer", "docs", "edge"):
        add(re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), k), c(k))
    add("sp-dot", derived(t))
    add("nr-pad", t["nrPad"])
    add("radius-button", "0"); add("radius-card", "0")
    add("rule-heavy", "3px"); add("status-radius", "0" if t["stR"] == "0" else "50%")
    add("caps", t["caps"]); add("font-display", fam("fD") + fb["fD"]); add("font-text", fam("fT") + fb["fT"]); add("font-mono", fam("fM") + fb["fM"])
    add("d-track", t["dLS"] if t["dLS"] != "0" else "0"); add("l-track", t["lblLS"] if t["lblLS"] != "0" else "0")
    add("ring", "1.6s " + ("steps(4,end)" if rb else "cubic-bezier(.3,0,.2,1)"))
    add("draw", "1.6s " + ("steps(6,end)" if rb else "cubic-bezier(.45,0,.2,1)"))
    add("bar-ease", "steps(3,end)" if rb else "ease-in-out"); add("bar-radius", "0" if rb else "99px")
    # the names tips.css already uses, so the tips window takes the style without a rewrite (block 3 refines it)
    leg = {"bg": "bg", "surface": "surface", "surface-2": "surface2", "border": "rule", "separator": "rule", "text": "ink",
           "text-2": "ink2", "text-3": "ink3", "accent": "link", "accent-fill": "accent", "brand": "markDot", "rec": "rec",
           "danger-text": "recText", "k-answer": "answer", "k-docs": "docs", "k-turn": "readyText", "k-onme": "notreadyText",
           "k-neutral": "ink2"}
    for n, k in leg.items():
        v.append(f"  --{n}:{t[k]};")
    for n, k in (("accent-soft", "link"), ("danger-soft", "recText"), ("k-answer-soft", "answer"), ("k-turn-soft", "readyText"),
                 ("k-onme-soft", "notreadyText"), ("k-docs-soft", "docs"), ("k-neutral-soft", "ink2")):
        v.append(f"  --{n}:color-mix(in srgb,{t[k]} 14%,transparent);")
    v.append("  --shadow-card:none;")
    return f'[data-style="{style}"][data-theme="{mode}"]{{\n' + "\n".join(v) + "\n}"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    src_path = Path(args[0]) if args else Path(os.environ.get("PACENOTE_THEMES_JS", REPO.parent / "research" / "redesign-src" / "_themes.js"))
    c = parse_js(src_path.read_text())
    sets = [("roadbookDark", "roadbook", True, "rbD"), ("roadbookLight", "roadbook", False, "rbL"),
            ("broadsheetLight", "broadsheet", False, "bsL"), ("broadsheetDark", "broadsheet", True, "bsD")]
    for _, _, _, k in sets:
        assert k in c, f"{k} not found in {src_path}"

    swift = ["// GENERATED by scripts/gen-theme.py from research/redesign-src/_themes.js. Do not edit by hand:",
             "// change the design source and run the script again (python3 scripts/gen-theme.py).",
             "", "import SwiftUI", "", "extension PNTheme {"]
    swift += [swift_theme(n, s, d, c[k]) + "\n" for n, s, d, k in sets]
    swift.append("}\n")
    swift_text = "\n".join(swift)

    blocks = "\n".join(css_block(s, "dark" if d else "light", c[k]) for _, s, d, k in sets)
    anim = ("@keyframes pn-draw{0%{stroke-dashoffset:1;opacity:1}60%,85%{stroke-dashoffset:0;opacity:1}100%{stroke-dashoffset:0;opacity:0}}\n"
            "@keyframes pn-ping{0%{transform:scale(1);opacity:.6}70%,100%{transform:scale(2.4);opacity:0}}\n"
            "@keyframes pn-bar{0%,100%{transform:scaleY(.25)}50%{transform:scaleY(1)}}\n"
            "@media (prefers-reduced-motion:reduce){.pn-m{animation:none!important}}")
    css_gen = f"{BEGIN}\n{blocks}\n{anim}\n{END}"
    css = CSS_OUT.read_text()
    if BEGIN in css:
        css_new = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), lambda _: css_gen, css, flags=re.S)
    else:
        css_new = css.rstrip("\n") + "\n\n" + css_gen + "\n"

    cur_swift = SWIFT_OUT.read_text() if SWIFT_OUT.exists() else ""
    if check:
        if cur_swift != swift_text or css != css_new:
            print("generated theme files are out of date: run python3 scripts/gen-theme.py")
            sys.exit(1)
        print("theme files are up to date")
        return
    SWIFT_OUT.write_text(swift_text)
    CSS_OUT.write_text(css_new)
    print(f"wrote {SWIFT_OUT.relative_to(REPO)} and {CSS_OUT.relative_to(REPO)} from {src_path}")


if __name__ == "__main__":
    main()
