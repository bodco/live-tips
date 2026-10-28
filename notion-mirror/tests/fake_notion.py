"""A small fake Notion for the mirror's tests: data sources, pages, markdown, blocks and users,
answered at the level of Notion.req (method, path, body). Synthetic data only."""
import copy
import re

import mirror


def uid(n):
    return "%032x" % n


def dashed(h):
    return "%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:])


def title(t):
    return {"type": "title", "title": [{"plain_text": t}]}


def rel(*ids):
    return {"type": "relation", "relation": [{"id": dashed(i)} for i in ids]}


def date(s):
    return {"type": "date", "date": {"start": s}}


def page(pid, props, edited="2026-10-01T10:00:00.000Z", **extra):
    return dict({"id": dashed(pid), "url": "https://www.notion.so/" + pid, "created_time": "2026-09-01T08:00:00.000Z",
                 "last_edited_time": edited, "properties": props}, **extra)


class World:
    """Projects (pds), workspaces (wds), meetings (mds), tasks (tds), reports (rds)."""

    def __init__(self):
        W1, P1, P2, CS1 = uid(1), uid(2), uid(3), uid(4)
        M1, T1, T2, T3, R1, CH1, U1, B1 = uid(10), uid(11), uid(12), uid(13), uid(14), uid(15), uid(16), uid(17)
        self.ids = dict(W1=W1, P1=P1, P2=P2, CS1=CS1, M1=M1, T1=T1, T2=T2, T3=T3, R1=R1, CH1=CH1, U1=U1, B1=B1)
        self.schemas = {"pds": {"properties": {"Name": {"type": "title"},
                                               "Workspace": {"type": "relation", "relation": {"data_source_id": "wds"}},
                                               "Project Inbox": {"type": "relation", "relation": {"data_source_id": "ids"}},
                                               "Other": {"type": "relation", "relation": {"data_source_id": "xds"}}}}}
        self.ds = {
            "wds": [page(W1, {"Name": title("🏠 Northwind Studio")})],
            "pds": [page(P1, {"Name": title("Orbit SaaS Launch"), "Workspace": rel(W1),
                              "Current State": {"type": "url", "url": "https://www.notion.so/x-" + CS1}}),
                    page(P2, {"Name": title("Internal Delivery Playbook"),
                              "Slug": {"type": "rich_text", "rich_text": [{"plain_text": "playbook"}]}})],
            "mds": [page(M1, {"Name": title("Weekly sync 2026-10-01T15:00:00.000+03:00"), "Project": rel(P1),
                              "Date": date("2026-10-01T15:00:00.000+03:00"),
                              "Attendees": {"type": "people", "people": [{"id": dashed(U1)}]}})],
            "tds": [page(T1, {"Task": title("Ship the export"), "Project": rel(P1, P2), "Due": date("2026-10-05"),
                              "Status": {"type": "status", "status": {"name": "In progress"}},
                              "Tags": {"type": "multi_select", "multi_select": [{"name": "a"}, {"name": "b"}]},
                              "Done": {"type": "checkbox", "checkbox": False}}),
                    page(T2, {"Task": title("Loose task: no project / no workspace")}),
                    page(T3, {"Task": title("Trashed")}, in_trash=True)],
            "rds": [page(R1, {"Name": title("Status report"), "Workspace": rel(W1),
                              "Score": {"type": "formula", "formula": {"type": "number", "number": 7}}})],
            "ids": [],
        }
        self.pages = {dashed(CS1): page(CS1, {"title": title("Current State")}),
                      dashed(CH1): page(CH1, {"title": title("Child notes")})}
        self.md = {
            dashed(M1): "Agenda<br>one\n<mention-page url=\"https://www.notion.so/%s\"/> and "
                        "<mention-user url=\"user://%s\"/> on <mention-date start=\"2026-10-02T09:30:00\"/>\n"
                        "<transcript>[00:01] hello</transcript>" % (P1, dashed(U1)),
            dashed(T1): "Do it.",
            dashed(T2): "Loose.",
            dashed(R1): "Report body\n<page url=\"https://www.notion.so/%s\">Child notes</page>" % CH1,
            dashed(CH1): "Inside the child page.",
            dashed(CS1): "We are on track.",
            dashed(P1): "Project page.", dashed(P2): "Playbook page.", dashed(W1): "Workspace page.",
        }
        self.blocks = {}                       # page id -> children (markdown endpoint fails -> blocks API)
        self.md_errors = {}                    # page id -> HTTP code
        self.users = [{"id": dashed(U1), "name": "Ann Example"}, {"id": dashed(uid(99))}]
        self.users_error = None
        self.calls = []

    def answer(self, method, path, body=None, version=None):
        self.calls.append((method, path))
        m = re.match(r"^/data_sources/([^/]+)/query$", path)
        if m:
            rows = self.ds.get(m.group(1))
            if rows is None:
                raise mirror.NotionError(404, "no such data source")
            since = ((body or {}).get("filter") or {}).get("last_edited_time", {}).get("on_or_after")
            rows = [r for r in rows if not since or r["last_edited_time"] >= since]
            return {"results": copy.deepcopy(rows), "has_more": False}
        m = re.match(r"^/data_sources/([^/]+)$", path)
        if m:
            return copy.deepcopy(self.schemas.get(m.group(1), {"properties": {}}))
        if path.startswith("/users"):
            if self.users_error:
                raise mirror.NotionError(self.users_error, "users")
            return {"results": copy.deepcopy(self.users), "has_more": False}
        m = re.match(r"^/pages/([0-9a-f-]+)/markdown", path)
        if m:
            pid = m.group(1)
            if pid in self.md_errors:
                raise mirror.NotionError(self.md_errors[pid], "markdown")
            text = self.md.get(pid, "")
            if "include_transcript" not in path:
                text = re.sub(r"<transcript>.*?</transcript>", "<transcript omitted/>", text, flags=re.S)
            return {"markdown": text, "truncated": pid == dashed(self.ids["R1"])}
        m = re.match(r"^/pages/([0-9a-f-]+)$", path)
        if m:
            p = self.pages.get(m.group(1))
            if p is None:
                raise mirror.NotionError(404, "no page")
            return copy.deepcopy(p)
        m = re.match(r"^/blocks/([0-9a-f-]+)/children", path)
        if m:
            return {"results": copy.deepcopy(self.blocks.get(m.group(1), [])), "has_more": False}
        raise AssertionError("unexpected call %s %s" % (method, path))
