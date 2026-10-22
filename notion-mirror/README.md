# notion-mirror

A read-only copy of your PM Control Tower in Notion as Markdown files on your Mac, laid out like
Notion: workspace, project, database. Skills and the Live Tips app read it for facts and local
search during a call; anything newer than the last run still comes from the Notion API. Notion
stays the only place where things are edited.

Python 3.9+, standard library only. Українська версія: [README.uk.md](README.uk.md).

## Layout

```
<work>/
  <Workspace>/
    _notion/workspace.md       the workspace page
    _notion/<db>/...           workspace rows without a project or with several projects
    <Project>/_notion/
      project.md               the Projects row
      current-state.md         the Current State page
      meetings/ threads/ tasks/ reports/ risks/ decisions/ topics/ knowledge/ inbox/
  _notion/
    INDEX.md                   where each project lives
    MIRROR_STATUS.md           result of the last run (OK / PARTIAL / FAILED)
```

- A row file is `YYYY-MM-DD title [<32 hex id>].md` with a YAML header (`notion_id`, `url`,
  `db`, `last_edited` and all properties; relations by name, people by name).
- Page and people mentions become names and links, dates become plain text.
- Pages removed from Notion move to `_notion/_archived/` on a full run; files older than 30 days
  there move to `<work>/_to_delete/`. The script never deletes anything.
- A project goes to `project_folders` from the config, else `local_paths.project_root` from its
  Control Tower config, else an existing folder with its name, else `<work>/<Workspace>/<Project>/`.
  Never into a git repository (each `_notion/` also gets a `.gitignore` with `*`).

## Set up with the Live Tips app (easiest)

Settings > General > Notion mirror > **Set up sync**. The app copies this folder to
`<work>/Tools/notion-mirror`, writes the config, finds your Control Tower databases with the
Notion token from Settings > Keys and runs the mirror every 2 hours, never during a call. The
token stays in the Keychain and is passed to the script only for the run.

## Set up by hand

1. Create an internal integration at [notion.so/my-integrations](https://www.notion.so/my-integrations)
   and share your Control Tower page with it (Connections).
2. `cp mirror.config.example.json mirror.config.json` and set `work_root`, `configs_dir` (your
   `projects/` configs) and either `NOTION_TOKEN` in the environment or `secrets_file` + `token_env`
   (the variable name in your secrets file; the value is never printed).
3. `./run.sh --discover` finds the databases by name and writes their ids into the config.
4. `./run.sh --full` for the first run, then `./install.sh` for a launchd job every 2 hours.

## Commands

| Command | What it does |
|---|---|
| `./run.sh` | Incremental run: pages edited since the last run (a full run every 7 days) |
| `./run.sh --full` | Full run: re-reads everything, archives removed pages |
| `./run.sh --status` | Prints the last status |
| `./run.sh --discover` | Finds the Control Tower databases and writes them to the config |
| `python3 mirror.py --selftest` | Offline checks, no Notion calls |

`NOTION_MIRROR_CONFIG=/path/mirror.config.json` uses another config; state and logs then live next
to it.
