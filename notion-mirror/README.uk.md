# notion-mirror

Копія твого PM Control Tower з Notion у вигляді Markdown-файлів на Маку, лише для читання, з тією
ж структурою, що в Notion: workspace, проєкт, база. Скіли і застосунок Live Tips читають її для
фактів і локального пошуку під час дзвінка; усе новіше за останній прогін і далі береться з
Notion API. Редагувати можна лише в Notion.

Python 3.9+, лише стандартна бібліотека. English: [README.md](README.md).

## Структура

```
<work>/
  <Workspace>/
    _notion/workspace.md       сторінка воркспейсу
    _notion/<база>/...         рядки воркспейсу без проєкту або з кількома проєктами
    <Project>/_notion/
      project.md               рядок Projects
      current-state.md         сторінка Current State
      meetings/ threads/ tasks/ reports/ risks/ decisions/ topics/ knowledge/ inbox/
  _notion/
    INDEX.md                   де лежить кожен проєкт
    MIRROR_STATUS.md           результат останнього прогону (OK / PARTIAL / FAILED)
```

- Файл рядка: `YYYY-MM-DD назва [<32 hex id>].md` з YAML-шапкою (`notion_id`, `url`, `db`,
  `last_edited` і всі властивості; relations назвами, люди іменами).
- Згадки сторінок і людей стають назвами і посиланнями, дати простим текстом.
- Сторінки, яких більше немає в Notion, на повному прогоні переїжджають у `_notion/_archived/`;
  файли, старші за 30 днів, звідти йдуть у `<work>/_to_delete/`. Скрипт нічого не видаляє.
- Проєкт кладеться в `project_folders` з конфігу, інакше в `local_paths.project_root` з його
  конфігу Control Tower, інакше в наявну папку з його назвою, інакше в
  `<work>/<Workspace>/<Project>/`. Ніколи в git-репозиторій (у кожній `_notion/` ще й
  `.gitignore` з `*`).

## Налаштування через застосунок Live Tips (найпростіше)

Settings > General > Notion mirror > **Set up sync**. Застосунок копіює цю папку в
`<work>/Tools/notion-mirror`, пише конфіг, знаходить бази Control Tower токеном Notion з
Settings > Keys і запускає дзеркало кожні 2 години, ніколи під час дзвінка. Токен лишається в
Keychain і передається скрипту лише на час прогону.

## Налаштування вручну

1. Створи внутрішню інтеграцію на [notion.so/my-integrations](https://www.notion.so/my-integrations)
   і поділися з нею сторінкою Control Tower (Connections).
2. `cp mirror.config.example.json mirror.config.json`, вкажи `work_root`, `configs_dir` (твої
   конфіги `projects/`) і або `NOTION_TOKEN` у середовищі, або `secrets_file` + `token_env`
   (назва змінної у файлі секретів; значення ніколи не друкується).
3. `./run.sh --discover` знаходить бази за назвами і записує їхні id у конфіг.
4. `./run.sh --full` для першого прогону, потім `./install.sh` для launchd-задачі кожні 2 години.

## Команди

| Команда | Що робить |
|---|---|
| `./run.sh` | Інкрементальний прогін: сторінки, змінені з минулого разу (раз на 7 днів повний) |
| `./run.sh --full` | Повний прогін: перечитує все, архівує зниклі сторінки |
| `./run.sh --status` | Показує останній статус |
| `./run.sh --discover` | Знаходить бази Control Tower і записує їх у конфіг |
| `python3 mirror.py --selftest` | Офлайн-перевірки без звернень до Notion |

`NOTION_MIRROR_CONFIG=/шлях/mirror.config.json` бере інший конфіг; стан і логи тоді лежать поруч
із ним.
