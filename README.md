# My Note Project

A local, Evernote-style notes app for Windows. Plain HTML/CSS/JS front end, a PowerShell server, and a SQLite database. No frameworks, no build step, no accounts, no cloud.

## Features
- Rich-text editor: headings, lists, checklists, tables, images, attachments, links, code, highlight
- Notebooks (folders, optionally grouped in stacks), tags, pinned notes, trash
- Search by title, by content (full-text, with highlighted matches), and by date range, with sorting
- Tasks with due dates, templates, find-in-note
- Import/export `.enex` (Evernote), HTML export, print/PDF
- Light/dark theme, phone layout

## Setup
1. Download the **sqlite-tools-win-x64** zip from <https://www.sqlite.org/download.html> (free, public domain) and put `sqlite3.exe` in this folder, next to `server.ps1`.
2. Run `start.bat`. It starts the server on <http://localhost:8766/> and opens your browser.

Your notes are stored in `notes.db` in this folder (not part of the repository). Close the server window to stop.

See `CLAUDE.md` for architecture and test-server notes.
