# CLAUDE.md

## Project

A local Evernote-style notes app: plain HTML/CSS/JS front end, a PowerShell server, and a SQLite database (free, public domain). No frameworks, no build step, no package manager. Same approach as the sibling "To Do Project". Cloud sync, AI assistant, transcription, calendar and scanning are deliberately out of scope.

## Running

```powershell
.\start.bat
```

Runs `server.ps1` on `http://localhost:8766/`. Opening `index.html` directly shows "NOT SAVED"; use the server.

Env vars for **test servers** (always use all three so the user's real data is never touched):
`NOTE_PORT` (port), `NOTE_DB` (database file path), `NOTE_LEGACY` (path of the old-data file, point it at a copy or a non-existent file), `NOTE_NO_BROWSER=1` (don't open a browser).

## Storage (SQLite)

- `sqlite3.exe` (official SQLite 3.54.1 CLI, SHA3-256 verified) sits next to `server.ps1`; the server spawns it per request. `schema.sql` is run at start-up (idempotent). Data file: `notes.db` (+ `-wal`/`-shm`), git-ignored.
- Tables: `notes` (id, title, html, text, nb, pinned, trashed, created, updated), `note_tags`, `attachments` (data URLs), `meta` (JSON docs: notebooks, tasks, templates, nextId), `notes_fts` (FTS5 over title/text/tags, rowid = note id; rewritten by the server on every note write).
- SQL safety: user data never goes into SQL text. The server writes query params / request bodies to temp files, loads them into temp tables via `readfile()`, and SQL refers to them as `@P` / `@J` (macros replaced in `Run-Sql`). Sort columns and views are whitelisted. Keep it that way.
- API: `GET /api/notes?q=&title=&from=&to=&field=created|updated&sort=updated|created|title|relevance&order=asc|desc&nb=&nbs=&tag=&view=all|pinned|trash&has=&todo=` (summaries + highlighted snippet, max 500), `GET/PUT/DELETE /api/notes/{id}`, `POST /api/notes`, `DELETE /api/notes?view=trash`, `GET /api/summary` (counts), `GET/PUT /api/meta`, `POST /api/move`, `POST /api/tag-rename`, `GET /api/legacy` + `POST /api/legacy/done`. PUT/POST require `application/json`; non-localhost Host headers are refused. A PUT without an `att` key leaves attachments unchanged.
- One-time migration: if the old `notes.json` exists and `meta.legacyDone` is unset, the page imports it through the API, then the server renames it to `notes.json.bak`. The page does the import because it computes the plain-text column.

## Front end (`index.html`)

- Notes are not held in memory: `list` (summaries from the last query), `counts`, and `curNote` (full open note) are the only note state. `S` = meta (notebooks, tasks, templates, nextId). `refresh()` re-queries with `buildParams()` (view + sidebar content search + list filters `F`); `refreshSoon()` debounces typing.
- Edit path: `onEdit()` -> `touch()` -> `queueNote()` -> debounced `flushNote()` (PUT) -> `refresh()`. The editor is rebuilt only on selection change so the caret survives. `#sidetop` and the list header/filter bar are built once so inputs keep focus.
- Search UI: sidebar box = content search (supports `tag:` `notebook:` `has:image` `has:attachment` `todo:true`); list filter bar = title search, created/updated date range, sort (date updated/created, title, relevance) and order.
- Notebooks are folders (optionally grouped into stacks): sidebar "+ New notebook" inline form, note's notebook dropdown has "New notebook…", rename/delete via the pencil (delete moves notes to another notebook).
- Note HTML is untrusted (paste, drop, .enex import): always pass through `sanitize()`. Checklists are `<ul class="todo"><li data-done="0|1">`.
- `?demo` uses an in-memory `demoApi()` (never touches the server data); `?theme=light|dark` forces a theme. `.enex` import/export, HTML export, print/PDF, light/dark theme, phone layout (`body[data-pane]`) are unchanged.

## Testing notes

- Never modify or delete `notes.db` / `notes.json` while testing. A test server run without `NOTE_LEGACY` will import and rename the real `notes.json`.
