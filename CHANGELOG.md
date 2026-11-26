# Changelog

Every release of ASMO (逐日), newest first. Downloads are on [GitHub Releases](https://github.com/realAllenSong/ASMO/releases). 中文版：[CHANGELOG.zh.md](CHANGELOG.zh.md)

## 2.8.3 · 2026-11-26

- **Click a picture to open it, as on a phone:** a picture, diagram or formula opens large over the window, the rest dimmed. Pinch or ⌘+ / ⌘− to zoom, drag to move, double-click to zoom in or back; the bar below copies, saves, opens it in Preview or edits its source. Click beside it or press Esc to close.
- Diagrams in notes are drawn sharp at any zoom.

## 2.8.2 · 2026-11-26

- **A bar over every picture, diagram, formula and table:** move the pointer onto one for buttons to view it large, copy it, edit its source, and the rest of its menu. A click on a picture, diagram or formula no longer turns it back into its source.
- The dark look's vermilion is redder and calmer, closer to the icon.

## 2.8.1 · 2026-11-26

- **Colours from the new icon:** vermilion for times, today and the main buttons, warm paper in the light look and warm ink in the dark look (no longer a violet grey). The 标紫 colour for words stays violet.
- The website, guides and share card use the same colours.

## 2.8 · 2026-11-25

**A new icon, and notes that read well**

- **New icon:** a brush-stroke sun rising over a page.
- **Tables drawn as tables, however wide:** columns are sized to their words and cells wrap when the column is narrow; tables inside callouts too. Click a table to edit its source.
- **Pictures, diagrams, formulas and tables:** double-click to view them large (zoom, fit, actual size, copy, save, open in Preview). Right-click for copy, save, show in Finder, a size (small, medium, the column, written as `![[a.png|240]]` like Obsidian), or the source to edit or copy.
- **Lists, checkboxes and headings inside callouts and quotes**, and `> >` quotes inside quotes.
- **The note's contents sit beside its text:** the main sections, with the one you're reading opened.

## 2.7.1 · 2026-11-23

- No line is left behind above a struck-through line after selecting it and clicking elsewhere.

## 2.7 · 2026-11-22

**Days and notes, joined**

- **Type `#` in a line of the days** for a short menu: make the line repeat (daily, weekdays, weekly, monthly), keep it every year as a birthday or an anniversary, or join it to a note (an existing one, or a new one named after the line).
- **`[[note]]` links in the days.** A click opens the note in a small window by the line, to write in, with a button to open it full size among the notes. On the phone the line shows without the link, and the note's name is in its notes.
- **A time written over is read again.** Change "5点到7点" to "5点到7点半" in an item and it shows as 17:00–19:30 once you move on.
- **Travel.** Today follows the Mac's time zone, and items' Calendar events keep their time on the clock (14:00 stays 14:00 in Beijing). Birthdays still come at the moment their day begins where they're kept.
- Organizing waits a little longer after you stop typing (8 s).
- No highlight is left behind after striking through a selected line.
- "7-8 点" and "19:00点" no longer leave a 点 in the words.

## 2.6 · 2026-11-22

**Notes, all the way**

- **A home page for the notes.** What to go on with, a few lines written long ago to read again (new ones every day), and every folder with what's in it. A search box for notes and days at the top.
- **Paragraph styles in the toolbar.** Text and Heading 1–4 (⌥⌘0–4), like a word processor. The open note's headings are listed under it in the sidebar; click one to go there, and the one you're reading is marked.
- **Search everything.** ⌘P finds a note by name, a line in any note, or a to-do on any day, and opens it at that line.
- **Drawn in place:** tables as tables, callouts (`> [!tip]`), coloured code, footnotes, formulas (`$…$`, `$$`, KaTeX inside the app), mermaid diagrams, and other notes inside a note (`![[note]]`).
- **Excalidraw built in.** Open a drawing from the vault or start one from the toolbar. It's saved the way Obsidian's Excalidraw plugin saves it, and a note that embeds it shows it as a picture.
- The note's name now scrolls with the text, in the same column.

## 2.5 · 2026-11-22

### Notes, beside the days

逐日 now keeps notes too: a folder of Markdown files for everything that isn't tied to a day. It opens your Obsidian vault as it is (it finds one on the Desktop or in Documents), so nothing has to be moved or converted.

- **Markdown with a live preview.** The text you edit is the file itself. Headings, bold, highlights, lists and checklists show as a page; their marks appear only on the line you're on.
- **Links and pictures.** `[[links]]` suggest notes as you type and open on a click. `![[pictures]]` show under their line, and a pasted or dropped picture is saved to the vault's picture folder.
- **Find and organise.** A folder tree in the sidebar, the note's headings in the margin, and ⌘P to find a note by its name or by words in it. Renaming a note updates the links to it.
- **Git sync.** A vault that is a Git repository pulls on launch and every ten minutes, and commits and pushes two minutes after you write. Obsidian on the phone sees what you wrote. A conflict is never left half-merged; the sidebar says so instead.
- **For agents.** `asmo notes`, `asmo note PATH`, `asmo note write PATH [--append|--new]`, `asmo note search`, `asmo note mv`, `asmo note rm`, and the same as MCP tools.

Every note in a 67-note vault was checked to come back from the editor byte for byte.

Requires a Mac with Apple silicon and macOS 15 or later. Earlier 2.x versions offer this update by themselves. The first time it opens your notes, macOS may ask for access to the Desktop or Documents folder.

## 2.4 · 2026-11-22

### A journal layout

Each day's date now sits in a margin on the left, with the day's things to do beside it, starting on the same line. In the light look the page is white, the contents sidebar a quiet grey, and a hairline separates the days.

### Writing gets organized again, in time order

Lines you finish are organized again after a short pause (the line you're on is left alone). Each day's items stand in time order under the date: timed ones first, then the rest. A line written at the bottom with a time moves up into its place; a to-do you give a time later moves too.

Times are read however they're written, at the start of a line or at the end:

One to six o'clock without 上午 or 下午 is the afternoon, on any day. An eval of more than 60 phrasings now guards this.

### Fixes

- Editing the words of a timed item in the evening no longer turns its morning time into an evening one.
- An empty bullet left by one Return too many is no longer made into a to-do.
- A line weighing two dates ("1/15 或者 1/19") is no longer moved to the first of them.

Requires a Mac with Apple silicon and macOS 15 or later. Earlier 2.x versions offer this update by themselves.

## 2.3 · 2026-11-22

### Repeating items on the phone

Repeating items now go to Apple Calendar and Reminders like everything else: one for each day they repeat, a week ahead (an event if the routine has a time, a reminder if not). Check one off on the phone and that day is done in 逐日. A day you skip isn't written, and yesterday's, left undone, is cleared away.

### Every day is there

Days behind today all show, written on or not; an empty day is no longer skipped. A month opened from the sidebar shows every one of its days.

### Contents by year

The sidebar groups months under their year. Click a year to fold it; this year and the one on screen are open.

Requires a Mac with Apple silicon and macOS 15 or later. Earlier 2.x versions offer this update by themselves.

## 2.2 · 2026-11-22

### Fixed: small bullets after a repeating line

Pressing Return at the end of a repeating line (one with a small "# 每天" label) started the next bullet in the label's small type, and what you wrote on such a line could come out small too. New bullets and writing are now always in the page's own size, next to a label or a time. Lines that were already saved small are put right when the page is drawn.

Everything in 2.1 is included: one reminder per to-do, birthdays in their own time zone, and a document that runs on as you scroll.

Requires a Mac with Apple silicon and macOS 15 or later. Earlier 2.x versions offer this update by themselves.

## 2.1 · 2026-11-22

### Fixed: reminders piling up on the phone

In 2.0, a to-do rolled over to today got a new reminder each day while the old ones stayed behind as overdue. Now each to-do has one reminder, which moves with it. On first launch, 2.1 removes the duplicates and the leftover reminders of to-dos you have since deleted or rewritten. Finished ones are kept.

Checking off an overdue reminder on the phone now sticks, even if the Mac rolls the to-do over to today before it hears about it.

### Birthdays in their own time zone

Each important date is kept in a time zone (birthdays in China time unless you set another) and shows when its day begins there: a birthday on the 22nd in China is at 11:00 on the 21st in New York. It is also put in Apple Calendar at that moment, with an alert, so your phone tells you when to send wishes.

- A lunar date imported together with a Gregorian one now shows on both days.
- Click a date's time zone label in the document to change it.

### The document runs on

Every day ahead is there to write on: the document starts with six weeks and adds a month each time you scroll to the end. The contents sidebar lists the next two years.

### For agents

- `asmo date add … --zone Asia/Shanghai` and `asmo date set ID --zone … | --title … | --on MM-DD`.
- `asmo day` gives a date's local start as `"begins"` and `"dayThere"`.
- `--year` on a date means "only in that year"; the help said otherwise.

Requires a Mac with Apple silicon and macOS 15 or later. 2.0 offers this update by itself.

## 2.0 · 2026-11-17

### Write your days like a document

The month calendar is gone. ASMO is now one long page of days, today first. A line with a bullet is a to-do, a line with a time is on your schedule, everything else is notes. When you pause, or switch to another app, finished lines become items, with the time read from your words ("10" written at 7 pm is 10 pm). Strike a line or click its bullet to check it off.

- **Contents sidebar:** jump to any month; **This month** brings you back (⇧⌘T).
- **Repeat button:** daily, weekdays, weekly on that day, or monthly on that date, with no syntax to learn.
- **Formatting toolbar:** bold, italic, underline, strike, highlight, colours, headings, lists, checkboxes, links and pictures, or Markdown as you type.

### Apple Calendar and Reminders, both ways

From today on, items with a time become events in a calendar named 逐日, and the rest become reminders in a list named 逐日. Through iCloud they reach your iPhone and watch. Changes made there come back within seconds: checking off, moving, deleting, and new reminders or events added to the 逐日 list or calendar. Past days are left as they are. `asmo mirror off` turns it off.

### For agents

- `asmo pages` lists which days have a page.
- `asmo page import` writes many days at once from JSON, as one undoable change.
- `asmo routine add … --on monthly:15` adds monthly routines.
- `asmo mirror` syncs with Calendar and Reminders now.

### Upgrading

1.1 offers this update by itself. Your items and pages carry over. On first launch, macOS asks for full access to Calendar and Reminders; the sync needs both.

Requires a Mac with Apple silicon and macOS 15 or later.

## 1.1 · 2026-11-12

### Install in one step

Download `ASMO-v1.1-macOS.zip` below, unzip it, move **ASMO** to Applications and open it. That's all: ASMO now connects the assistants on your Mac by itself (the `asmo` command, the skill for Claude Code and Codex, and the MCP server for the Claude desktop app). **Settings ▸ AI assistants** shows what is connected.

### Updates itself

ASMO checks GitHub Releases after it opens and once a day. When a newer version is out it asks; **Update Now** downloads it, checks the signature, replaces the app and reopens it. **Settings ▸ Updates** has **Check for Updates**.

### Upgrading from 1.0

1.0 can't update itself, so download this one by hand. On first launch, 1.1 copies your data and settings to `~/Library/Application Support/ASMO`; the old copy is kept. macOS may ask for Calendar access once more.

Requires a Mac with Apple silicon and macOS 15 or later.

## 1.0 · 2026-11-12

The first release of ASMO (逐日): a calendar and to-do list for macOS that your coding agent can use.

### Install

1. Download `ASMO-v1.0-macOS.zip` below, unzip it and move **ASMO** to Applications. It is signed with a Developer ID and notarized by Apple.
2. Open it once, then set up the command in Terminal:

   ```bash
   /Applications/ASMO.app/Contents/Helpers/asmo setup
   ```

   This links `asmo` into `~/.local/bin`, gives Claude Code and Codex the skill, and registers the MCP server with the Claude desktop app.

Requires a Mac with Apple silicon and macOS 15 or later. See the [README](https://github.com/realAllenSong/ASMO#readme) for what it can do.
