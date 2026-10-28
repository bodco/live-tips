# Pacenote for teams (design, not built yet)

[Українською](README.uk.md)

**Status:** a design written on 2026-10-28 to keep the idea. Nothing on this page is built yet, except
that Stage 0 works with what Pacenote 0.8.2 already does.

**The question:** project knowledge lives in one place, several people (PMs, sales) use the app, each
prepares for their own calls, and all summaries land in one place. How should that be organized?

## The one principle

**Recording, speech recognition, live tips and voice prints stay on each person's Mac. Knowledge,
preparation and summaries become shared.**

- Audio never leaves the Mac. That is the privacy promise, and it keeps working in a team.
- A tip must arrive within 1-2 seconds of the question. A round trip to a team server adds a delay
  and a point of failure in the middle of a call, so live tips keep calling Claude directly.
- Preparation and summaries are not time-critical. They are where shared knowledge pays off, so they
  are the jobs that move to a shared place.

```
 Each person's Mac (Pacenote)              Shared place
 ────────────────────────────              ─────────────────────────────────────
 recording + Whisper (local)               project knowledge: folders, Notion copy,
 live tips (Claude, fast)                  CRM context, search index
 "prepare my 15:00 call"  ───────────────> preparation (Claude Code or the API)
 <─────────────── brief, cards, facts
 transcript after the call ──────────────> summary -> Notion / CRM / archive
```

Stage 0 does this with Google Drive and Notion, no server. Stage 1 adds a team server with users,
roles and CRM connectors. Stage 2 is what a larger organization would need later.

---

## Stage 0: Google Drive and Notion, no server (works today)

### How it works

1. **One shared place for project folders in Google Drive.** A shared drive (Google Workspace) or a
   folder in someone's My Drive shared with the team. Inside, the same layout Pacenote already uses:

   ```
   Pacenote Team/                      (shared drive)
     Northwind Studio/                 (a workspace: a client or a group of projects)
       Orbit SaaS Launch/              (a project)
         docs, specs, proposals        (anything the team keeps for this project)
         live/                         (preparations and transcripts, written by the app)
         _notion/                      (the local copy of Notion, if the project uses it)
       Internal Delivery Playbook/
   ```

2. **Access is given in Google Drive, per person.** Whoever should prepare for calls of a project gets
   access to its folder. Nobody else sees it. Pacenote itself has no users or permissions in Stage 0:
   it sees exactly what Drive gives the person.

   - The simplest clean split: **one shared drive per access group** (for example "Sales EU",
     "Delivery", "Leadership"), because membership of a shared drive is the most predictable unit
     of access. Restricting single folders inside one shared drive is limited and depends on your
     Workspace settings; check with your Workspace admin before relying on it.
   - Removing a person from the drive removes their access to new files. Files already synced to
     their Mac stay there until Drive removes them, so offboarding also means signing them out of
     Drive on that Mac.

3. **Each Mac runs Google Drive for desktop** with the team folders **available offline** (mirror
   mode, or "Available offline" on the folders in stream mode). Claude Code reads real files during
   the preparation and the local search builds its index from them; files that exist only in the
   cloud would be skipped or slow.

4. **Each person adds the projects in Pacenote** (Settings > Projects), pointing at their own Drive
   path, for example `~/Library/CloudStorage/GoogleDrive-<account>/Shared drives/Pacenote Team/...`.
   The path differs per person, which is fine: the app stores it per Mac.

5. **Summaries go to one Notion database.** Everyone's Pacenote writes the meeting page into the same
   Meetings database (each person uses their own Notion token with access to it). Transcripts stay in
   the project's `live/` folder in Drive, so the team has both: the readable page in Notion and the
   full text next to the project files.

6. **Claude access per person.** Either each person's own Claude plan (Settings > AI > Claude account,
   good for preparation and summaries) or an API key from the organization's Anthropic Console.
   Prefer one key per person in a shared Console workspace: spend is visible per key, and revoking one
   person does not break the others.

### Why there is no VPN or Tailscale here

Nothing needs to reach a server. Google Drive moves the files and handles access; Notion holds the
summaries; Claude is reached directly. A private network only becomes useful in Stage 1, and even
there it is optional (see "Network").

### Known gaps of Stage 0 (to fix in the app)

| Gap | Effect | Planned fix |
|---|---|---|
| Two people preparing the same meeting write the same file name in `live/` | Drive keeps both as "conflicted copies" | One owner per meeting for now; the app gets a per-person `live/<person>/` option |
| The local search index (`.livetips-index/`) is built inside the project folder | It syncs to everyone and is rebuilt on each Mac | Option to keep the index outside synced folders |
| Everyone with access sees all transcripts in the folder | Fine for small teams, not for sensitive calls | Stage 1: transcripts private to the owner by default |
| No CRM context | Sales preparation relies on files and Notion only | Stage 1: CRM connectors |
| The Notion copy is per Mac | Each person syncs it, or one Mac syncs it into Drive | Stage 1: the server keeps one copy |

Stage 0 is the right way to try the team idea with 2-5 people before building anything.

---

## Stage 1: the team server (design)

### Goal

One place that knows every project and account, prepares any person's call from it, and collects every
summary, with users, roles and permissions. The Mac app stays the same for the live part and gets a
third way for preparation and summaries: **Team server**, next to "API key" and "Claude account" in
Settings > AI (the routing added in 0.8.2 is the hook for it).

### Components

| Component | What it does |
|---|---|
| **API** | HTTPS JSON API for the app and the admin UI (endpoints below) |
| **Auth** | Sign-in with Google Workspace (OIDC). The app signs in through the browser (device code flow) and keeps its token in the macOS Keychain |
| **Knowledge store** | Project folders (synced from Google Drive through the Drive API, or uploaded), the Notion copy (one mirror for everyone), CRM context from connectors |
| **Search index** | The same local-AI search (bge-m3 embeddings) per project, built once on the server |
| **Preparation worker** | Runs the same preparation instructions as the app (the live-tips skill's prep), through Claude Code headless or the API, on the server's copy of the project |
| **Summary worker** | Builds the summary from an uploaded transcript, writes the Notion page and the CRM activity |
| **Connectors** | Google Drive, Notion, HubSpot, a custom CRM (adapter interface below), later Salesforce |
| **Database** | Users, roles, projects, memberships, calls, jobs, audit log. SQLite is enough for up to ~10 people; Postgres after that |
| **Admin UI** | A small web page: people, roles, projects, connectors, costs, retention |
| **Audit log** | Who prepared, read, downloaded or deleted what, and when |

### Where it runs

| | Mac mini (owned, static IP) | Hetzner dedicated or cloud (Linux) | AWS |
|---|---|---|---|
| Start | Fastest: the engine runs on macOS today | Needs the Python engine on Linux (it is plain Python; the embeddings run on ONNX on Linux too) | Same as Hetzner |
| Reliability | One machine: power, home internet, updates | Data center, backups, EU location | Highest, plus compliance options |
| Cost | Already owned | about EUR 40-60 a month | Several times more |

A sensible path: start on the Mac mini, move to a Hetzner Linux server when more than a handful of
people depend on it. Speech recognition does not run on the server at all (it stays on each Mac), so
the server needs no GPU.

### Network

Every request carries a signed-in user's token, so the server can be on the public internet behind
HTTPS: Caddy with Let's Encrypt on the static IP, or a Cloudflare Tunnel (no open ports). A private
network (Tailscale or a VPN) is optional, for an organization that wants the server unreachable from
the internet at all.

### Users, teams and roles

**Users** sign in with their Google Workspace account. The admin allows the company domain and invites
people; SCIM provisioning comes in Stage 2. **Teams** group people (Sales EU, Delivery). A **membership**
gives a user or a whole team a role on a workspace or a project.

| Role | Who | In short |
|---|---|---|
| **Owner** | One or two people | Everything, including billing, connectors and deleting the organization's data |
| **Admin** | IT or ops | People, teams, roles, connectors, retention; does not read transcripts by default |
| **Manager** | Team lead | Their team's projects: prepare, read summaries and transcripts of the team's calls, see the team's costs |
| **Member** | PM, sales | Projects they are a member of: prepare their own calls, read summaries, their own transcripts |
| **Viewer** | Stakeholder | Read summaries of projects they are a member of; no preparation, no transcripts |

### Permissions

| Permission | Owner | Admin | Manager | Member | Viewer |
|---|---|---|---|---|---|
| Invite and remove people, change roles | yes | yes | own team: invite only | no | no |
| Connect Google Drive, Notion, CRM | yes | yes | no | no | no |
| Create workspaces and projects | yes | yes | yes | no | no |
| See a project | all | all | team's | member of | member of |
| Prepare a call | yes | no | yes | own calls | no |
| Read summaries | all | no (unless member) | team's | project's | project's |
| Read full transcripts | yes | no | team's (unless marked private) | own; others' only if the owner shares | no |
| Write a summary to the CRM | yes | no | yes | own calls, after "Send to CRM" | no |
| Edit preparation rules and templates | yes | yes | team's | no | no |
| See costs | all | all | team's | own | no |
| Export or delete data | yes | yes (with audit) | no | own transcripts | no |

Rules behind the table:

- **Transcripts are private to the person who recorded the call by default.** The summary is what the
  project shares. A person can share a transcript with the project; a manager can read the team's
  transcripts unless the owner marked the call private.
- **Nothing goes to a CRM or to the client by itself.** The app shows the draft; the person presses
  "Send to CRM" (the same rule as Pacenote today: drafts yes, sending always by a person).
- **Every read of a transcript and every download of a preparation package is in the audit log.**

### Data model

| Entity | Main fields |
|---|---|
| Organization | name, allowed domains, retention policy, Claude key reference |
| User | email, name, status, teams |
| Team | name, members, manager |
| Workspace | name (a client or a group), projects |
| Project | name, slug, workspace, sources (Drive folder id, Notion page, CRM company or deal ids), rules |
| Membership | subject (user or team), object (workspace or project), role |
| Call | title, start, owner, attendees' emails, project, CRM ids, consent recorded (who, when, how) |
| Preparation | call, version, files (brief, cards, facts, outline), sources used, created by, cost |
| Transcript | call, owner, private flag, uploaded at, retention date |
| Summary | call, structured JSON, Notion page URL, CRM activity id, sent by |
| Commitment | project, text, owner, due date, status (the register Pacenote already keeps) |
| Connector | type, account, encrypted token, scopes, status |
| Job | type (prep, summary, sync), status, timings, cost, error |
| Audit event | who, what, object, when, from where |

### API (first version)

| Method and path | Purpose |
|---|---|
| `POST /v1/auth/device`, `POST /v1/auth/token` | Sign-in from the app through the browser (device code) |
| `GET /v1/me` | The user, roles and projects |
| `GET /v1/projects` | Projects the user can see, with their sources |
| `GET /v1/calls?from&to` | The user's upcoming calls the server knows about (from CRM meetings; the app adds its own calendar) |
| `POST /v1/calls` | Register a call from the app (title, start, attendees, project) |
| `POST /v1/calls/{id}/prep` | Start a preparation job; returns a job id |
| `GET /v1/jobs/{id}` | Job status and progress |
| `GET /v1/calls/{id}/prep/package` | The preparation as a signed package (brief, cards, facts, outline) with an expiry; the app caches it, so a call works even if the connection drops |
| `POST /v1/calls/{id}/transcript` | Upload the transcript and the app's tips after the call |
| `POST /v1/calls/{id}/summary` | Build the summary (server) and return the draft |
| `POST /v1/calls/{id}/summary/send` | Send the approved summary to Notion and the CRM |
| `GET /v1/projects/{id}/search?q=` | Search the project's knowledge (optional for "find" during a call, 1-3 s is acceptable there) |
| `POST /v1/webhooks/{connector}` | Events from the CRM (a deal stage changed) |

### Flows

**Before the call.** The app shows the person's calls (their Mac calendar plus calls the server knows).
"Prepare" sends the call to the server. The server gathers the project's files and Notion copy, the CRM
context of the account and the earlier calls of the same meeting, runs the preparation and stores it.
The app downloads the package and keeps it locally.

**During the call.** Unchanged: recording, Whisper and tips on the Mac, tips through the person's own
way to Claude. Optionally "find" can search the server's index.

**After the call.** The app uploads the transcript (with the consent record). The server builds the
summary through the organization's Claude key and returns the draft. The person checks it and presses
"Send": the Notion meeting page, the CRM activity and the tasks are created, and commitments go into
the project's register.

### Claude on the server

- The organization's **API key** from the Anthropic Console, in its own workspace, with per-user spend
  tracked by the server (and limits per user and per team).
- Not a personal Claude plan: a plan belongs to one person and its limits would run out for a team.
- Preparation can still use Claude Code headless with that key, exactly as the app does today.

### CRM integration

The server talks to every CRM through one **adapter interface** and turns what it gets into one
normalized context that the preparation reads. The CRM is the source of truth for sales facts (deal
stage, amount, contacts, last touches); Drive and Notion are the source for project documents.

**The adapter interface**

| Operation | In | Out |
|---|---|---|
| `match_call(attendee_emails, title, start)` | A call | Account and deal ids, contacts found |
| `get_context(account_id, deal_id)` | Ids | Normalized context (below) |
| `list_meetings(user, from, to)` | A user | Meetings known to the CRM, optional |
| `write_activity(ids, summary, action_items)` | The approved summary | Activity id, task ids |
| `map_user(email)` | A Pacenote user | The CRM owner id |

**Normalized context (what the preparation sees)**

```json
{
  "account": {"name": "Northwind Studio", "domain": "northwind.example", "industry": "Software", "owner": "Mike Johnson"},
  "contacts": [{"name": "Emily Clark", "title": "Product owner", "email": "emily@northwind.example", "last_touch": "2026-10-21"}],
  "deals": [{"name": "Orbit SaaS Launch", "stage": "Proposal", "amount": 48000, "currency": "USD", "close_date": "2026-12-15", "next_step": "Pilot plan"}],
  "activities": [{"type": "meeting", "date": "2026-10-21", "summary": "Pilot scope agreed, test accounts open"}],
  "open_tasks": [{"text": "Send the pilot user list", "owner": "Emily Clark", "due": "2026-10-30"}]
}
```

**HubSpot** (checked against HubSpot's developer docs on 2026-10-28; HubSpot changes this area often,
so check again before building)

- **Auth.** For one company's own portal: a **Service Key** (HubSpot's replacement for private apps,
  which can no longer be created since late October 2026), or a developer-platform app with static auth
  and private distribution if webhooks are needed. For many companies: a developer-platform app with
  **OAuth**.
- **Scopes.** `crm.objects.contacts.read`, `crm.objects.companies.read`, `crm.objects.deals.read` to read;
  the matching `.write` scopes to create activities and tasks associated with them; `sales-email-read`
  only if email content is needed. Activities (meetings, notes, tasks) are covered by the object scopes
  of the records they are associated with.
- **Match a call.** Search contacts by each attendee's email (CRM search), then read their associations
  to companies and deals. Several open deals: the one with the nearest close date, and the person can
  change it in the app.
- **Read context.** The company, its contacts, open deals (stage, amount, close date, next step), the last
  meetings and notes on the timeline, open tasks.
- **Write after the call** (only after "Send to CRM"): a **meeting** record (title, start and end, the
  summary as its body) associated with the contacts, the company and the deal; **tasks** for the action
  items, assigned to their owners, with due dates; optionally a suggested "next step" for the deal that
  the person confirms.
- **Webhooks.** A subscription to deal property changes for `dealstage`: the server marks that deal's
  preparations as stale, the same way Pacenote marks a brief that needs a refresh.
- **Limits.** Private apps share a daily limit per portal (hundreds of thousands of requests a day) and
  about 100-190 requests per 10 seconds; CRM search allows about 5 requests a second. A call needs a few
  dozen requests, so the server caches context per account for a few minutes and backs off on 429.

**A custom CRM**

- **It has an API:** write an adapter for the five operations. Configuration instead of code where
  possible: the base URL, the auth (API key or OAuth), and a field mapping:

  ```yaml
  crm: custom
  base_url: https://crm.example.com/api
  auth: {type: bearer, secret: CRM_TOKEN}
  match:
    contact_by_email: GET /contacts?email={email}
    account_of_contact: "{contact.account_id}"
  map:
    account.name: name
    deals[].stage: pipeline_stage
    deals[].amount: value
    deals[].close_date: expected_close
  write:
    activity: POST /accounts/{account_id}/activities   # body: {type: meeting, text: summary}
    task: POST /tasks                                   # body: {title, assignee, due}
  ```

- **It has no API:** a nightly export (CSV or JSON into a Drive folder or a bucket) read as context,
  read-only; the summary goes back as an email to the CRM's inbox address or through a webhook the CRM
  accepts. Less fresh, but it works without touching the CRM.

### Security and privacy

- Sign-in with Google Workspace; the app's token in the Keychain; short-lived tokens with refresh.
- Roles and memberships checked on every request; transcripts private to the owner by default.
- Encryption in transit (TLS) and at rest (disk encryption; connector tokens encrypted with a key that is
  not stored with the database).
- Consent: the app records when the consent message was said or posted; the server stores it with the
  call. No recording without it is the organization's policy, not a technical guess.
- Retention: transcripts deleted after a set number of days (for example 90), summaries kept; deletion on
  request with an audit entry.
- Data location: an EU server keeps files and transcripts in the EU; text sent to Claude follows
  Anthropic's commercial terms (API data is not used for training by default).
- Backups of the database and the knowledge store, encrypted, tested by a restore.

### What changes in the Mac app

- Settings > AI: a third way **Team server** for preparation and after the call; sign-in to the server.
- Projects come from the server (the person can still add local ones).
- A cache of preparation packages and an upload queue that survives being offline.
- "Send to CRM" next to "Send to Notion" on the call page.
- Live tips and recording: unchanged.

### Build plan (one developer, rough)

| Step | Scope | Time |
|---|---|---|
| M1 | Server skeleton, Google sign-in, users, teams, roles, projects, memberships, audit log; Drive sync of project folders | 2-3 weeks |
| M2 | Preparation as a service, the package API; the app's "Team server" way, package cache | 2 weeks |
| M3 | Transcript upload, summary worker, Notion page; HubSpot adapter (read context, write meeting and tasks, webhook) | 2-3 weeks |
| M4 | Admin UI, costs per user, retention, the custom CRM adapter with field mapping | 2 weeks |

### Open questions

- Is Google Workspace the identity for every team that would use it, or is Microsoft 365 needed too?
- Should managers read the team's transcripts by default, or only summaries?
- One Notion workspace for everyone, or one per team?
- Which CRM comes first after HubSpot?
- Is a hosted version for other companies a goal, or only self-hosted?

---

## Stage 2: later

SCIM provisioning, several organizations on one server, Salesforce and Pipedrive adapters, analytics
across calls (talk time, open commitments per account), approval flows for summaries, and an on-premise
package for clients who require it.
