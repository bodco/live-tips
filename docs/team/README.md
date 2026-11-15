# Pacenote for teams (in progress)

[Українською](README.uk.md)

**Status:** Stage 0 works today. Stage 1 is being built: the server part has run since 2026-11-15, the app part
comes next (see Stage 1). The diagram below is the original idea from 2026-10-28; in Stage 1 transcripts stay with
the person (on the Mac and, if they choose, in their Google Drive) and preparation stays on the Mac.

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

## Stage 1: the Pacenote server

**Status (2026-11-15):** the first part is built and running (sign-in, organizations and roles in the database,
isolation tests). The app does not use it yet: signing in from the app comes next, then sending calls.

### Goal

Every person keeps working on their Mac as today. After each call the app also keeps a copy of the call's results
on the Pacenote server, so they are not lost with the Mac, can be opened on another Mac and later on the phone, and
a team lead can see the calls of the people they manage. The server is optional: without signing in, nothing changes.

### What goes to the server, and what never does

| Data | Mac | The person's Google Drive | Pacenote server |
|---|---|---|---|
| Audio of the call | yes (during recognition; the file if recording is on) | only if a recording is uploaded | **never** |
| Screen recording (video) | yes | yes, in the chosen folder | only the link |
| Transcript | yes | optional, a `.md` file next to the recording | only the link |
| Voice prints, settings, keys | yes | no | never |
| Live tips | yes | no | never (only counts: shown, rated useful) |
| Meeting Sheet | yes | no | yes |
| Summary, decisions, tasks | yes | no | yes |
| Call details (title, time, length, type, project, participants, consent) | yes | no | yes |

The Mac stays the source of truth for its own calls; the server holds a copy.

### Components

One server in the EU (Hetzner), Docker Compose with four parts:

| Component | What it does |
|---|---|
| **Caddy** | HTTPS in front of the API; reachable only through Cloudflare |
| **API** (Python, FastAPI) | Sign-in, sessions, organizations, calls, permissions, plans, audit log |
| **PostgreSQL** (with pgvector for later search) | All data, with row-level security |
| **Backup** | A nightly encrypted dump to separate storage, with a monthly restore test |

The server makes no AI calls in this stage: preparation, tips and notes keep running on the Mac through the
person's own key or Claude account.

### Sign-in

- Google only (OpenID Connect, scopes `openid email profile`). The app signs in through the browser with a local
  redirect and PKCE, the same way it connects Google today, but as a separate sign-in: the account used for Pacenote
  and the Google accounts connected for Drive and Calendar stay independent.
- The server checks the Google ID token (signature, audience, issuer, expiry, verified email) and keys the person
  by Google's stable id, not the email.
- The app gets a short access token (15 minutes) and a refresh token that changes on every use; both live in the
  Keychain. A refresh token used twice ends that device's session. Devices are listed in the profile, with
  "Sign out everywhere".
- The server never gets access to the person's Drive, Calendar or Docs.

### Organizations, teams and roles

The first sign-in creates a personal organization with the person as its owner. The same tables serve teams later,
so moving to a team needs no data migration.

| Level | Role | In short |
|---|---|---|
| Organization | **Owner** | Everything, including plan, policy and deleting the organization |
| Organization | **Admin** | People, departments, teams, policy; does **not** read the content of other people's calls |
| Organization | **Member** | Their own calls; more through a team or department role |
| Department | **Head** | Calls of everyone in the department's teams |
| Team | **Lead** | Calls of the people in their team |

### Who sees what

| What | The person | Team lead, department head | Admin | Others |
|---|---|---|---|---|
| Call details | yes | yes | totals only, no titles | no |
| Summary, decisions, tasks | yes | yes | no | no |
| Meeting Sheet | yes | yes, unless the organization turns it off | no | no |
| Links to the recording and transcript | yes | yes (Drive decides who can open them) | no | no |
| A call marked private | yes | only that it happened and its length | no | no |

When a person leaves an organization, their calls stay with the organization. Recordings and transcripts in Google
Drive are seen by whoever has access to that Drive folder; for teams a shared drive per team or department works
best.

### How it is protected

- Row-level security in Postgres on every table: the database itself refuses rows of another person or another
  organization, even if the API had a bug. Isolation tests run on every change.
- The content of calls (titles, participants, summaries, decisions, tasks, Meeting Sheets) is encrypted with a key
  of each person, kept wrapped by a server key that is not in the database or its backups. Deleting a person
  destroys their key, so their content is unreadable in old backups too.
- HTTPS only, the server reachable only through Cloudflare, administrative access only from known addresses, logs without any
  call content, an audit log of sign-ins, exports, deletions and a manager opening someone's call.
- Delete a call or all server data at any time (removed at once, from backups within 30 days); export everything.

### API (version 1)

| Method and path | Purpose | Status |
|---|---|---|
| `GET /healthz` | Uptime check | built |
| `POST /v1/auth/google`, `/v1/auth/refresh`, `/v1/auth/logout` | Sign-in, token refresh, sign-out (this device or all) | built |
| `GET /v1/me`, `DELETE /v1/me` | The person, organizations, roles, plan, policy; delete all server data | built |
| `GET /v1/devices`, `DELETE /v1/devices/{id}` | Signed-in devices | built |
| `PUT /v1/calls/{client_call_id}` and its parts (`/summary`, `/decisions`, `/tasks`, `/sheet`, `/assets`) | Send a call, each part on its own | next |
| `GET /v1/calls`, `GET /v1/calls/{id}`, `DELETE /v1/calls/{id}`, `GET /v1/sync` | Read and sync across devices | next |
| `GET /v1/export` | Export everything | next |
| `/v1/orgs/{id}/members`, `/departments`, `/teams`, `/invites`, `/policy` | Team structure and policy | later |
| `GET /v1/team/calls`, `GET /v1/team/analysis` | The manager's overview | later |

### What changes in the Mac app

- Settings > Account: **Sign in to Pacenote**, devices, sign out, delete server data.
- After the notes, the call goes into a send queue that survives restarts and being offline. Sending can be turned
  off for a project or a single call.
- Settings > Call recording > Google Drive: choose the folder for recordings (a shared drive works too) and,
  optionally, a transcript `.md` next to each recording.
- Live tips, recording and preparation: unchanged.

### Build plan

| Step | Scope | Status |
|---|---|---|
| B5 | Server: sign-in, organizations, teams, roles, visibility, row-level security with tests, audit, plans, deploy | built 2026-11-15 (backups pending) |
| B7 | App: Settings > Account, sign-in, Keychain, devices; Drive folder picker and transcript in Drive | next |
| B8 | Sending calls, queue, export, deletion | after B7 |
| B6 | Team structure and policy through the API, a minimal admin page, quotas | before the first team |
| B9 | The manager's overview, search | after B8 |

### Open questions

- Microsoft sign-in: only when a real team asks for it.
- Moving personal calls into a team organization: per project is the proposal.
- Preparation on the server (B11) would send text to AI providers from the server: a separate decision, with an
  update to the privacy notice.

---

## Stage 2: later

SCIM provisioning, several organizations on one server, Salesforce and Pipedrive adapters, analytics
across calls (talk time, open commitments per account), approval flows for summaries, and an on-premise
package for clients who require it.

### CRM integration (design from 2026-10-28, for later)

Not part of Stage 1: the Pacenote server does not talk to a CRM yet. Kept as the design for when it does.

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
