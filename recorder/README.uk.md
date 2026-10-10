# live-transcriber

[English](README.md) · Повний опис: [docs/uk/17-live-tips.md](../../docs/uk/17-live-tips.md)

Локальна транскрипція дзвінків для скіла `live-tips`. Пише мікрофон і системний звук двома
каналами, розпізнає кожну фразу на Маку через Whisper large-v3-turbo (MLX) і дописує рядки в
`<папка проєкту>/live/<YYYY-MM-DD-HHMM>-<назва>.md`:

```
[12:30:11] Я (uk): ...
[12:30:15] Співрозмовник (ru): ...
```

У мережу нічого не йде, крім одноразового завантаження моделі.

## Встановлення (Apple Silicon, macOS 14.2+, Python 3.10+)

```
cp -R tools/live-transcriber ~/work/Tools/
bash ~/work/Tools/live-transcriber/install.sh
```

Коли macOS спитає, дозволь Terminal мікрофон і запис системного звуку. Лог:
`logs/install.log`; піки `mic` і `sys` мають бути більші за нуль (під час тесту `sys`
увімкни будь-який звук).

## Керування

- Старт: файл `control/start.json`, напр.
  `{"project_dir": "/Users/you/work/Acme Portal", "title": "Sync", "slug": "acme-portal", "me_lang": "uk", "langs": "uk+ru", "prompt": "Acme, Portal, Jira"}`.
  LaunchAgent побачить файл і відкриє вікно Terminal "Live transcriber".
- Стоп: `touch control/stop` або Ctrl+C у цьому вікні. Закриття Zoom/Meet запис НЕ зупиняє.
- Стан: `state/status.json` (`state`, `file`, `started_at`, `lines`, `queue`, `mic`, `system_audio`, `errors`).
- Скіл читає лише нові рядки через `bin/read_delta.py FILE OFFSET --wait 25 --settle 2 --status state/status.json`.

Вручну, без скіла:

```
cd ~/work/Tools/live-transcriber
.venv/bin/python src/transcriber.py --project-dir "$HOME/work/Test" --title "Тест" --me-lang uk --langs uk+en
```

## Налаштування

`config.json`: модель, мітки каналів, мови за замовчуванням, `launchd_label` (назва
LaunchAgent, за замовчуванням `com.pm-control-tower.live-transcriber`). Поля зі `start.json`
мають пріоритет. Тонкі параметри (VAD, довжина фраз, вікно відлуння, список галюцинацій)
лежать у `DEFAULTS` і `HALLUCINATIONS` у `src/transcriber.py`.
