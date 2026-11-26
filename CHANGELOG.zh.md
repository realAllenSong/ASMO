# 更新记录

逐日（ASMO）的每个版本，新的在前。下载在 [GitHub Releases](https://github.com/realAllenSong/ASMO/releases)。English: [CHANGELOG.md](CHANGELOG.md)

## 2.8.1 · 2026-11-26

- **配色跟着新图标：** 时间、今天和主要按钮用朱红；浅色是暖纸色，深色是暖墨色（不再是偏紫的灰）。给文字标紫的颜色仍是紫色。
- 网站、使用指南和分享卡片也换成了同一套颜色。

## 2.8 · 2026-11-25

**新图标，笔记更好读**

- **新图标：** 一笔朱红的太阳从纸上升起。
- **再宽的表格也画成表格：** 列宽按内容分，放不下就在单元格里换行；提示框里的表格也一样。点一下表格就能改源码。
- **图片、图表、公式、表格：** 双击看大图（放大缩小、适合窗口、原始大小、拷贝、存储、用「预览」打开）。右键可以拷贝、存储、在访达中显示、改大小（小、中、适合一栏，写成 Obsidian 的 `![[图片|240]]`），或者编辑、拷贝源码。
- **提示框和引用里的列表、勾选框、小标题**都画出来了，`> >` 嵌套引用也认。
- **目录回到正文左边：** 列出大的章节，读到哪一节就展开哪一节。

## 2.7.1 · 2026-11-23

- 选中一行划掉、再点别处之后，上面不再留下一根残留的线。

## 2.7 · 2026-11-22

**日程和笔记连起来**

- **在日程的一行里打 `#`**，弹出小菜单：让这一行重复（每天、工作日、每周、每月），存成每年的生日或纪念日，或者连到一篇笔记（已有的，或新建一篇以这一行命名的）。
- **日程里的 `[[笔记]]` 链接**：点一下就在这一行旁边的小窗口里打开，直接写；也有按钮全屏打开到笔记里。手机上这一行不显示链接，笔记名写在备注里。
- **改过的时间会重新整理**：把事项里的「5点到7点」改成「5点到7点半」，光标离开后就显示成 17:00–19:30。
- **出行**：「今天」跟着电脑的时区走；事项在日历里保持钟面上的时间（在北京 14:00 还是 14:00）。生日照旧在它所在时区那天开始的时刻提醒。
- 停笔后多等一会儿（8 秒）再自动整理。
- 选中一行划掉之后，不再留下选中的残影。
- 「7-8 点」「19:00点」不会再在文字里留下一个「点」。

## 2.6 · 2026-11-22

**笔记，一步到位**

- **笔记首页：** 接着写的、从以前的笔记里翻出的几段话（每天换几篇）、所有分类一目了然；顶上可以搜索笔记和日程。
- **工具栏设段落样式：** 正文、标题 1–4（⌥⌘0–4），像石墨文档一样。打开的笔记的标题列在侧边栏这篇下面，点一下就跳过去，正在读的那节会标出来。
- **全局搜索：** ⌘P 找笔记名、任何笔记里的一行、任何一天的待办，打开就停在那一行。
- **就地画出来：** 表格、提示框（`> [!tip]`）、代码上色、脚注、公式（`$…$`、`$$`，app 自带 KaTeX）、mermaid 图表、嵌入另一篇笔记（`![[笔记]]`）。
- **内置 Excalidraw 画板：** 打开笔记库里的画板或从工具栏新建，保存格式和 Obsidian 的 Excalidraw 插件一样；嵌了画板的笔记会把它显示成图。
- 笔记的标题和正文在同一栏，跟着一起滚动。

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

- 2点到3点, 2-3点, 2到3点, 2~3点, 二到三点, 两点到三点, 2点钟
- 2:00-3:00, 14：00-15：00, 下午2点到3点, 2pm-3pm, 2-3pm
- 2点半到3点, 2-3点半

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
