"""0.10.0 (Meeting Sheet, phase 6): web pages and LinkedIn captures as sources.

Only invented pages: LinkedIn-like HTML written here (Emily Parker at Lumenfield) and a tiny invented site served by a
local http.server thread with its own robots.txt. Nothing here touches a real third-party page.
"""
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from livetips_m0.sheet import linkedin as LI
from livetips_m0.sheet import web as W

LOREM = ("Lumenfield builds data tools for product teams. We help teams read their numbers, plan releases and keep "
         "quality high. Our customers range from small studios to large retailers, and we work with them closely. ")

# ---------------------------------------------------------------- invented LinkedIn pages

NAV = '<nav class="global-nav"><a>Home</a><a>My Network</a><a>Jobs</a><a>Messaging</a><a>Notifications</a><a>Me</a></nav>'


def profile_page(show_all=True, contacts=True):
    about = ("I lead engineering at Lumenfield, where our platform serves 50,000+ users across retail and media. "
             "Before that I built payments tools.")
    if contacts:
        about += " Write to emily.parker@lumenfield.example or call +1 512 555 0142."
    return f"""<html><head><title>Emily J. Parker | LinkedIn</title></head><body>{NAV}
<main>
<section class="artdeco-card pv-top-card">
  <h1>Emily Parker</h1>
  <div class="text-body-medium">VP Engineering at Lumenfield | Data tools for product teams</div>
  <span class="text-body-small">Austin, Texas, United States</span>
  <a href="/in/emily-parker-lf/overlay/contact-info/">Contact info</a>
  <span>500+ connections</span>
  <button>Message</button><button>More</button>
</section>
<section class="artdeco-card"><div id="analytics"></div><h2><span aria-hidden="true">Analytics</span><span class="visually-hidden">Analytics</span></h2>
  <span>Private to you</span><p>142 profile views</p><p>Who viewed your profile: Mike Carter and 9 others</p></section>
<section class="artdeco-card"><div id="about"></div><h2><span aria-hidden="true">About</span><span class="visually-hidden">About</span></h2>
  <div><span aria-hidden="true">{about}</span></div></section>
<section class="artdeco-card"><div id="featured"></div><h2>Featured</h2><ul>
  <li><a href="https://emilyparker.design/">Portfolio<br>emilyparker.design</a></li>
  <li><a href="https://medium.com/@emilyparker/scaling-data-teams">Scaling data teams<br>Medium</a></li>
  <li><a href="https://www.linkedin.com/feed/update/123">Post</a><span>Emily Parker reposted this</span><p>A repost about hiring at Northwind Studio</p></li>
</ul></section>
<section class="artdeco-card"><div id="activity"></div><h2>Activity</h2><ul><li>Liked by Jake T. and 20 others</li><li>Sarah M. reposted this</li></ul></section>
<section class="artdeco-card"><div id="experience"></div><h2>Experience</h2><ul>
  <li><div><span>VP Engineering</span></div><div><span>Lumenfield · Full-time</span></div><div><span>2023 - Present · 3 yrs</span></div>
      <div><span>Austin, Texas</span></div><div><span>Leads the platform used by 42,000+ users.</span></div></li>
  <li><div>Engineering Manager</div><div>Orbit · Full-time</div><div>2018 - 2023 · 5 yrs</div><div>Grew the team to 30 engineers; the app reached 12,000+ users.</div></li>
  <li><div>Senior Engineer</div><div>Northwind Studio</div><div>2015 - 2018</div></li>
</ul>{'<a href="/in/emily-parker-lf/details/experience/">Show all 5 experiences</a>' if show_all else ''}</section>
<section class="artdeco-card"><div id="education"></div><h2>Education</h2><ul>
  <li><div>University of Texas at Austin</div><div>MS, Computer Science</div><div>2011 - 2013</div></li>
  <li><div>Rice University</div><div>BS, Mathematics</div></li></ul></section>
<section class="artdeco-card"><div id="skills"></div><h2>Skills</h2><ul><li>Data platforms</li><li>Team leadership</li></ul>
  <a href="/in/emily-parker-lf/details/skills/">Show all 6 skills</a></section>
<section class="artdeco-card"><div id="certifications"></div><h2>Licenses &amp; certifications</h2><ul>
  <li><div>Certified Scrum Master</div><div>Scrum Alliance</div><div>Issued Jan 2020</div><button>Show credential</button></li></ul></section>
<section class="artdeco-card"><div id="languages"></div><h2>Languages</h2><ul><li>English<br>Native</li><li>Spanish<br>Professional working proficiency</li></ul></section>
<section class="artdeco-card"><div id="interests"></div><h2>Interests</h2><ul><li>Lumenfield</li></ul></section>
</main>
<aside><section><h2>People you may know</h2><ul><li>Mike Carter, CTO at Orbit</li></ul></section>
<section class="ad-banner"><h2>Promoted</h2><p>Try Premium for free</p></section></aside>
</body></html>"""


def detail(section, items, title="Em Parker"):
    lis = "".join(f"<li>{i}</li>" for i in items)
    return (f'<article data-pacenote-page="https://www.linkedin.com/in/emily-parker-lf/details/{section}/" '
            f'data-pacenote-title="{section.capitalize()} | {title} | LinkedIn"><main><h2>{section.capitalize()}</h2><ul>{lis}</ul></main></article>')


def full_capture():
    prof = profile_page()
    body = prof[prof.index("<body>") + 6: prof.index("</body>")]
    exp = detail("experience", [
        "<div>VP Engineering</div><div>Lumenfield · Full-time</div><div>2023 - Present</div><div>Leads the platform used by 42,000+ users.</div>",
        "<div>Engineering Manager</div><div>Orbit</div><div>2018 - 2023</div><div>The app reached 12,000+ users.</div>",
        "<div>Senior Engineer</div><div>Northwind Studio</div><div>2015 - 2018</div>",
        "<div>Engineer</div><div>Orbit</div><div>2013 - 2015</div>",
        "<div>Intern</div><div>Lumenfield</div><div>2012</div>"])
    sk = detail("skills", ["Data platforms", "Team leadership", "Python", "Product analytics", "Hiring", "Roadmapping"])
    return ("<html><head><title>Emily J. Parker | LinkedIn</title></head><body>"
            f'<article data-pacenote-page="https://www.linkedin.com/in/emily-parker-lf/" data-pacenote-title="Emily J. Parker | LinkedIn">{body}</article>'
            f"{exp}{sk}</body></html>")


def test_scrub_contacts_keeps_dates_and_numbers():
    s, n = W.scrub_contacts("Mail emily.parker@lumenfield.example, call +1 512 555 0142 or (512) 555-0199. "
                            "2018 - 2023 · 5 yrs. 50,000+ users. Founded 2015.")
    assert n == 3
    assert "@" not in s and "555" not in s
    assert "2018 - 2023" in s and "50,000+ users" in s and "2015" in s


def test_linkedin_full_capture_reads_only_profile_sections():
    r = LI.parse(full_capture(), "", "https://www.linkedin.com/in/emily-parker-lf/")
    assert r["state"] == "read" and r["signed_in"] is True
    assert r["name"] == "Emily Parker"
    assert set(r["aliases"]) == {"Emily J. Parker", "Em Parker"}
    assert r["headline"].startswith("VP Engineering at Lumenfield")
    assert r["location"] == "Austin, Texas, United States"
    secs = r["sections"]
    assert set(secs) == {"about", "featured", "experience", "education", "skills", "certifications", "languages"}
    assert len(secs["experience"]["items"]) == 5 and secs["experience"]["expanded"]
    assert len(secs["skills"]["items"]) == 6 and secs["skills"]["expanded"]
    assert len(secs["education"]["items"]) == 2 and len(secs["languages"]["items"]) == 2
    assert r["not_received"] == []
    for k in ("ads", "people you may know", "owner analytics", "activity (liked by, reposts)"):
        assert k in r["left_out"], k
    assert "interests" in r["other_sections"]
    dump = json.dumps(r)
    for bad in ("Liked by", "reposted", "Premium", "profile views", "Mike Carter", "Jake T.", "Sarah M.", "Private to you"):
        assert bad not in dump, bad
    # no contacts, ever
    assert "@lumenfield" not in dump and "555 0142" not in dump and r["contacts_removed"] >= 2
    assert "Contact info" not in dump


def test_linkedin_facts_have_locators_and_featured_links_are_suggested():
    r = LI.parse(full_capture(), "", "https://www.linkedin.com/in/emily-parker-lf/")
    assert r["facts"] and all(f["locator"]["section"] and f["locator"]["quote"] and f["locator"]["url"] for f in r["facts"])
    exp = [f for f in r["facts"] if f["section"] == "experience"]
    assert exp[0]["label"] == "VP Engineering at Lumenfield"
    assert all(f["locator"]["url"].endswith("/details/experience/") for f in exp)
    about = [f for f in r["facts"] if f["section"] == "about"][0]
    assert about["locator"]["url"] == "https://www.linkedin.com/in/emily-parker-lf/"
    sugg = r["suggested_sources"]
    assert [s["uri"] for s in sugg] == ["https://emilyparker.design/", "https://medium.com/@emilyparker/scaling-data-teams"]
    assert all(s["access"] == "pending" and s["why"] == ["found in Featured on LinkedIn"] for s in sugg)
    assert r["taken"][0] == "Header" and "Experience (5, expanded)" in r["taken"]


def test_linkedin_different_numbers_stay_side_by_side_with_a_question():
    r = LI.parse(full_capture(), "", "https://www.linkedin.com/in/emily-parker-lf/")
    users = [n for n in r["numbers_to_check"] if n["what"] == "users"]
    assert len(users) == 1
    vals = [v["value"] for v in users[0]["values"]]
    assert vals == ["50,000+", "42,000+", "12,000+"]
    assert {v["section"] for v in users[0]["values"]} == {"about", "experience"}
    assert "Which one is current" in users[0]["question"]
    assert not [n for n in r["numbers_to_check"] if n["what"] == "engineers"]   # one number, nothing to ask


def test_linkedin_profile_only_reports_what_was_not_expanded():
    r = LI.parse(profile_page(), "", "https://www.linkedin.com/in/emily-parker-lf/")
    assert r["state"] == "read"
    nr = {x["section"]: x for x in r["not_received"]}
    assert nr["experience"]["shown"] == 3 and nr["experience"]["total"] == 5
    assert nr["skills"]["total"] == 6
    assert r["aliases"] == ["Emily J. Parker"]


def test_linkedin_authwall_without_a_session():
    html = ("<html><head><title>Sign Up | LinkedIn</title></head><body><main><h1>Join LinkedIn</h1>"
            "<p>Sign in to view Emily's full profile</p><a>Join now</a><a>Sign in</a></main></body></html>")
    r = LI.parse(html, "", "https://www.linkedin.com/in/emily-parker-lf/")
    assert r["state"] == "authwall" and r["signed_in"] is False
    assert r["facts"] == [] and r["name"] == ""
    s = LI.to_source(r, "s5", 5)
    assert s["access"] == "denied" and s["access_reason"] == "authwall" and s["fix_action"] == "open_in_browser"


def test_linkedin_hidden_by_owner_differs_from_authwall():
    html = (f"<html><head><title>LinkedIn</title></head><body>{NAV}<main><section><h2>This profile is not available</h2>"
            "<p>The profile you are looking for is not available.</p></section></main></body></html>")
    r = LI.parse(html, "", "https://www.linkedin.com/in/emily-parker-lf/")
    assert r["state"] == "hidden_by_owner" and r["signed_in"] is True
    s = LI.to_source(r, "s5", 5)
    assert s["access_reason"] == "hidden_by_owner" and s["fix_action"] == "save_as_pdf"
    member = f"<html><body>{NAV}<main><section><h1>LinkedIn Member</h1></section></main></body></html>"
    assert LI.parse(member, "", "https://www.linkedin.com/in/x/")["state"] == "hidden_by_owner"


def test_linkedin_empty_page():
    r = LI.parse(f"<html><body>{NAV}<main></main></body></html>", "", "https://www.linkedin.com/in/emily-parker-lf/")
    assert r["state"] == "empty"
    assert LI.to_source(r, "s1", 1)["used"] == "not_used"


def test_merge_names_and_urls():
    p, a = LI.merge_names(["Emily Parker", "Emily J. Parker", "Mike Carter", "Em Parker", "Emily Parker"])
    assert p == "Emily Parker" and a == ["Emily J. Parker", "Em Parker"]
    assert LI.detail_url("https://www.linkedin.com/in/emily-parker-lf/?trk=x", "experience") == \
        "https://www.linkedin.com/in/emily-parker-lf/details/experience/"
    assert LI.page_kind("https://www.linkedin.com/in/emily-parker-lf/details/skills/") == "detail"
    assert LI.page_kind("https://www.linkedin.com/company/lumenfield/") == "company"
    assert LI.is_linkedin("https://ua.linkedin.com/in/x") and not LI.is_linkedin("https://linkedin.com.example/in/x")


# ---------------------------------------------------------------- an invented site on a local server

def page(title, body, links=()):
    a = "".join(f'<a href="{h}">{t}</a> ' for h, t in links)
    return (f"<html><head><title>{title}</title></head><body><nav>{a}</nav><header><nav><a href='/'>Home</a></nav></header>"
            f"<main><h1>{title}</h1><p>{body}</p></main><footer>Footer links</footer></body></html>")


SITE = {
    "/robots.txt": "User-agent: *\nDisallow: /private/\n",
    "/": page("Lumenfield", LOREM, [("/about", "About"), ("/team", "Team"), ("/services", "Services"), ("/cases", "Cases"),
                                     ("/blog", "Blog"), ("/contact", "Contact"), ("/login", "Sign in"), ("/cart", "Cart"),
                                     ("/privacy-policy", "Privacy"), ("/private/secret", "Secret"), ("/about#team", "About again"),
                                     ("/about/?utm_source=x", "About tracked"), ("/about-us", "About us"), ("/empty", "Soon"),
                                     ("/brochure.pdf", "Brochure"), ("mailto:hello@lumenfield.example", "Mail"),
                                     ("https://www.linkedin.com/company/lumenfield", "LinkedIn"),
                                     ("https://crunchbase.example/organization/lumenfield", "Crunchbase")]),
    "/about": page("About Lumenfield", "Founded in 2015 in Austin. " + LOREM * 2),
    "/about-us": page("About Lumenfield", "Founded in 2015 in Austin. " + LOREM * 2),
    "/team": page("Team", "Emily Parker, VP Engineering. Mike Carter, CEO. " + LOREM),
    "/services": page("Services", "Analytics setup, release planning. " + LOREM),
    "/cases": page("Cases", "Northwind Studio cut reporting time in half. " + LOREM),
    "/blog": page("Blog", "Notes from the team. " + LOREM, [("/blog/post-1", "First post"), ("/blog/post-2", "Second post"),
                                                            ("https://medium.example/lumenfield", "Medium")]),
    "/blog/post-1": page("First post", "How Orbit plans releases. " + LOREM),
    "/blog/post-2": page("Second post", "Hiring at Lumenfield. " + LOREM),
    "/contact": page("Contact", "Write to hello@lumenfield.example or call +1 512 555 0100. Office in Austin. " + LOREM),
    "/empty": page("Soon", "This page is being updated."),
    "/private/secret": page("Secret", "Never fetched. " + LOREM),
}


class _H(BaseHTTPRequestHandler):
    hits = []
    agents = []
    site = SITE

    def do_GET(self):
        path = self.path.split("?")[0].split("#")[0]
        if len(path) > 1:
            path = path.rstrip("/")
        type(self).hits.append(path)
        type(self).agents.append(self.headers.get("User-Agent", ""))
        body = type(self).site.get(path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain" if path.endswith(".txt") else "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


@pytest.fixture()
def site():
    _H.hits, _H.agents, _H.site = [], [], dict(SITE)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), _H)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", _H
    srv.shutdown()
    srv.server_close()


def test_web_plan_same_site_skips_and_external(site):
    base, h = site
    p = W.plan(base + "/")
    assert p["start"]["status"] == "ok" and p["robots"]["found"] is True
    by = {x["path"]: x for x in p["pages"]}
    assert by["/"]["planned"] and by["/"]["depth"] == 0
    for path in ("/about", "/team", "/services", "/cases", "/blog", "/contact", "/about-us", "/empty"):
        assert by[path]["planned"], path
    assert by["/login"]["note"] == "sign-in" and by["/cart"]["note"] == "cart" and by["/privacy-policy"]["note"] == "policy"
    assert by["/private/secret"]["note"] == "robots" and by["/brochure.pdf"]["note"] == "file"
    assert sum(1 for x in p["pages"] if x["path"] == "/about") == 1          # fragment and utm are the same page
    assert {e["domain"] for e in p["external"]} == {"linkedin.com", "crunchbase.example"}
    assert all(x["url"].startswith(base) for x in p["pages"])
    assert "/private/secret" not in h.hits
    assert all("Pacenote" in a for a in h.agents)
    planned = [x["path"] for x in p["pages"] if x["planned"]]
    assert planned[1] == "/about"                                            # about pages first
    assert planned.index("/contact") > planned.index("/blog")


def test_web_plan_limit(site):
    base, _h = site
    p = W.plan(base + "/", max_pages=3)
    assert p["planned"] == 3
    assert [x["path"] for x in p["pages"] if x["planned"]] == ["/", "/about", "/about-us"]
    assert any(x["note"] == "limit" for x in p["pages"])


def test_web_fetch_pages_become_sources_with_a_report(site, tmp_path):
    base, h = site
    p = W.plan(base + "/")
    slept = []
    r = W.fetch(p, tmp_path, delay=0.01, sleep=slept.append)
    st = {x["path"]: x["status"] for x in r["pages"]}
    assert st["/"] == "read" and st["/about"] == "read" and st["/blog/post-1"] == "read" and st["/blog/post-2"] == "read"
    assert st["/about-us"] == "duplicate" and st["/empty"] == "empty"
    assert st["/login"] == "skipped" and st["/private/secret"] == "skipped"
    assert "/private/secret" not in h.hits and "/login" not in h.hits and "/cart" not in h.hits
    assert "/robots.txt" in h.hits and all("Pacenote" in a for a in h.agents)
    srcs = r["sources"]
    assert all(s["type"] == "web_page" and s["access"] == "ok" for s in srcs)
    uris = [s["uri"] for s in srcs]
    assert len(uris) == len(set(uris)) and base + "/blog/post-1" in uris
    assert [s["n"] for s in srcs] == list(range(1, len(srcs) + 1))
    contact = next(s for s in srcs if s["uri"].endswith("/contact"))
    txt = Path(contact["path"]).read_text()
    assert "hello@" not in txt and "555 0100" not in txt and "Office in Austin" in txt
    assert "Footer links" not in Path(srcs[0]["path"]).read_text()           # main content only
    empty = next(s for s in srcs if s["uri"].endswith("/empty"))
    assert empty["used"] == "not_used" and "placeholder" in empty["reason"]
    fetched = [x for x in r["pages"] if x["status"] in ("read", "empty", "duplicate", "error")]
    assert len(slept) == len(fetched) - 1 and all(x >= 0.01 for x in slept)          # a wait before every page but the first
    assert r["summary"]["read"] >= 9 and r["summary"]["duplicate"] == 1 and r["summary"]["empty"] == 1
    assert {e["domain"] for e in r["external"]} >= {"linkedin.com", "crunchbase.example", "medium.example"}
    sugg = W.external_sources(r["external"])
    li = next(s for s in sugg if "linkedin" in s["uri"])
    assert li["type"] == "linkedin" and li["access"] == "pending" and li["fix_action"] == "open_in_browser"


def test_web_fetch_depth_one_and_ticks(site):
    base, h = site
    p = W.plan(base + "/", depth=1)
    for x in p["pages"]:
        if x["path"] == "/team":
            x["planned"] = False                                              # the user unticks Team
    r = W.fetch(p, None, delay=0, sleep=lambda s: None)
    st = {x["path"]: (x["status"], x.get("note")) for x in r["pages"]}
    assert "/blog/post-1" not in st and "/blog/post-1" not in h.hits
    assert st["/team"] == ("skipped", "not ticked") and "/team" not in h.hits


def test_web_robots_disallow_all(site):
    base, h = site
    _H.site["/robots.txt"] = "User-agent: Pacenote\nDisallow: /\n"
    p = W.plan(base + "/")
    assert p["start"]["status"] == "blocked" and p["planned"] == 0
    r = W.fetch(p, None, delay=0, sleep=lambda s: None)
    assert r["sources"] == [] and h.hits == ["/robots.txt"]


def test_web_normalize_and_skip_rules():
    assert W.normalize("/About/?utm_source=x&b=2&a=1#top", "https://Lumenfield.example/x") == "https://lumenfield.example/About?a=1&b=2"
    assert W.normalize("mailto:a@b.c") is None and W.normalize("https://lumenfield.example/index.html") == "https://lumenfield.example/"
    assert W.skip_reason("https://x.example/terms-of-service") == "policy"
    assert W.skip_reason("https://x.example/careers") is None
    assert W.kind_of("https://x.example/case-studies/orbit") == "case-studies"


def test_captured_pages_and_cli(tmp_path, monkeypatch, capsys):
    from livetips_m0.sheet import __main__ as M
    li_html = tmp_path / "emily-parker-lf-20261112-010203.html"
    li_html.write_text(full_capture(), encoding="utf-8")
    site_html = tmp_path / "lumenfield-20261112-010300.html"
    site_html.write_text(page("Lumenfield", LOREM * 2), encoding="utf-8")
    req = tmp_path / "req.json"
    req.write_text(json.dumps({"captured": [
        {"html": str(li_html), "url": "https://www.linkedin.com/in/emily-parker-lf/", "captured_at": "2026-11-12T01:02:03Z"},
        {"html": str(site_html), "url": "https://lumenfield.example/"}]}))
    code = M.main(["webfetch", "--request", str(req)])
    out = json.loads(capsys.readouterr().out)
    assert code == 0
    s1, s2 = out["sources"]
    assert s1["type"] == "linkedin" and s1["access"] == "ok" and s1["title"] == "Emily Parker (LinkedIn)" and s1["checked_at"]
    assert s2["type"] == "web_page" and s2["used"] == "full"
    assert len(out["suggested"]) == 2
    code = M.main(["webplan", "--request", str(tmp_path / "missing.json")])
    assert code == 3 and "error" in json.loads(capsys.readouterr().out)


def test_cli_webplan_and_webfetch(site, tmp_path, capsys):
    from livetips_m0.sheet import __main__ as M
    base, _h = site
    req = tmp_path / "p.json"
    req.write_text(json.dumps({"url": base + "/", "max_pages": 4}))
    assert M.main(["webplan", "--request", str(req)]) == 0
    p = json.loads(capsys.readouterr().out)
    assert p["planned"] == 4
    req2 = tmp_path / "f.json"
    req2.write_text(json.dumps({"plan": p, "out_dir": str(tmp_path / "pages"), "delay": 0}))
    assert M.main(["webfetch", "--request", str(req2)]) == 0
    f = json.loads(capsys.readouterr().out)
    assert f["summary"]["read"] >= 3 and f["suggested"]


def test_phase6_files_have_no_long_dash_and_no_forbidden_names():
    here = Path(__file__).resolve()
    m0 = here.parents[1]
    files = [m0 / "livetips_m0/sheet/web.py", m0 / "livetips_m0/sheet/linkedin.py", here]
    sw = m0.parents[1] / "app/Sources/LiveTips/PacenoteBrowser.swift"
    core = m0.parents[1] / "app/Sources/LiveTipsCore/BrowserCapture.swift"
    files += [f for f in (sw, core) if f.exists()]
    names = [n[::-1] for n in ("anelO", "ayraD", "notnA", "aiiraM", "ailataN", "xelA", "iiskelO")]   # spelled backwards on purpose
    bad = re.compile(r"\b(" + "|".join(names) + r")\b")
    for f in files:
        t = f.read_text(encoding="utf-8")
        assert chr(0x2014) not in t, f
        assert not bad.search(t), f
