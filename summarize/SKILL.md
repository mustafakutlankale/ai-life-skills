---
name: summarize
description: Summarize any content (YouTube video, article, whitepaper/PDF, podcast episode, book chapter, etc.) into a rich Obsidian note with section-by-section breakdowns, wikilinks to all technical concepts and people, and reference notes for every linked term. Use when the user provides a URL, file, or content to summarize and document in the vault.
user_invocable: true
---

# Summarize

Universal content summarizer. Takes any input — YouTube video, web article, whitepaper/PDF, epub book, podcast, lecture — and produces a rich, interlinked Obsidian summary note with reference notes for every concept mentioned.

## Requirements

**Vault structure** — the skill expects these folders inside your Obsidian vault. Folder names are the defaults; override them in the Configuration block below if your vault uses different names.

| Folder | Purpose |
|---|---|
| `08 Summaries/` | Where summary notes land |
| `07 References/` | Concept / company / product / place notes |
| `04 People/` | Person notes (creators, guests, mentioned people) |
| `02 Daily/YYYY/MM/` | Daily notes, named `MM-DD-YY ddd.md` (e.g. `03-29-26 Sun.md`) |
| `_Templates/` | Note templates — skill installs `new person template.md` here on first run |
| `_Bases/` (optional) | Obsidian Bases — only needed if you use the Bases plugin |

**CLI tools** — install these before first use, or let Step 0 walk you through it:

| Tool | Purpose | Install |
|---|---|---|
| `yt-dlp` | YouTube/podcast download + metadata + subs | `brew install yt-dlp` or `pip install yt-dlp` |
| `defuddle` | Web article extraction | `npm install -g defuddle` |
| `pdftotext` | PDF text extraction | `brew install poppler` |
| `pandoc` | EPUB / DOCX → markdown | `brew install pandoc` |
| `mlx_whisper` (optional) | Local audio transcription fallback | `pip install mlx-whisper` |

Alternative to `mlx_whisper`: set `ELEVENLABS_API_KEY` to use ElevenLabs Scribe for transcription.

## Configuration

The skill reads these variables at runtime. Override any of them via environment variables, or edit the defaults here:

```
VAULT_ROOT     = $VAULT_ROOT        # auto-detected if not set (see Step 0a)
SUMMARIES_DIR  = 08 Summaries
REFERENCES_DIR = 07 References
PEOPLE_DIR     = 04 People
DAILY_DIR      = 02 Daily
TEMPLATES_DIR  = _Templates
BASES_DIR      = _Bases
```

All paths below are relative to `$VAULT_ROOT`.

## Trigger

When the user provides content to summarize: a URL (YouTube, article, blog), a PDF/file path, pasted text, or a reference to content already in the vault.

## Inputs

- **Source**: URL, file path, or pasted text
- **Audience** (optional): defaults to "general reader." User may specify (e.g. "high school student", "expert", "5-year-old")
- **Depth** (optional): defaults to "full." User may request "tldr only", "section-by-section", or "deep dive"

## Step 0: Bootstrap check (first run)

Before doing any work, verify the environment is ready. **Skip any check that already passes** — only prompt the user when something is actually missing. Do not re-run Step 0 on subsequent invocations if the initial setup succeeded; you can tell it already ran if `$VAULT_ROOT` resolves and the required folders + tools are present.

### 0a. Resolve the vault root

```bash
vault=""
if [ -n "$VAULT_ROOT" ]; then
  vault="$VAULT_ROOT"
else
  dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.obsidian" ]; then vault="$dir"; break; fi
    dir="$(dirname "$dir")"
  done
fi
echo "Vault: ${vault:-NOT FOUND}"
```

If no vault is found, ask the user:

> **What's the absolute path to your Obsidian vault?**
> Recommended: use a **new, dedicated Obsidian vault** for this skill — not your existing personal vault. The skill creates and modifies many notes and folders, and a clean vault avoids polluting your existing notes. If you don't have one yet, create an empty folder, open it in Obsidian (File → Open vault as folder), and paste that path here.

After they answer, validate that `<answer>/.obsidian/` exists before using it — if not, warn that the path doesn't look like an Obsidian vault (they may need to open it in Obsidian first) and ask them to confirm or re-enter. Use the validated answer as `$VAULT_ROOT` for the session (and suggest they set it permanently in their shell profile).

### 0b. Check required folders

```bash
for d in "$SUMMARIES_DIR" "$REFERENCES_DIR" "$PEOPLE_DIR" "$DAILY_DIR" "$TEMPLATES_DIR"; do
  [ -d "$VAULT_ROOT/$d" ] || echo "MISSING: $d"
done
```

For each missing folder, ask the user: **"Create `<folder>` in your vault? [y/N]"** — if yes, `mkdir -p "$VAULT_ROOT/<folder>"`.

### 0c. Check required CLI tools

```bash
for tool in yt-dlp defuddle pdftotext pandoc; do
  command -v "$tool" >/dev/null 2>&1 || echo "MISSING: $tool"
done
```

For each missing tool, tell the user what's missing and **ask before installing** — installs touch the user's system. Use the install commands from the Requirements table above. If the user declines, note which tools are missing and warn that the corresponding content types (YouTube, web articles, PDFs, EPUBs) will fail until installed.

### 0d. Install the person template if missing

The skill ships two person templates in the repo's `templates/` folder (shared with `summarize-call`):

- **`new person template.md`** — full version with Dataview callouts (current age, total hours talked) and Obsidian Bases embeds (`posts.base`, `books.base`, `meetings.base`). Requires the Dataview plugin and Obsidian Bases.
- **`new person template (minimal).md`** — stripped version. Just frontmatter, a `> [!info]` summary callout, and an `## updates` section. Works in any vault.

If `$VAULT_ROOT/$TEMPLATES_DIR/new person template.md` already exists, leave it alone — the user may have their own customized version.

Otherwise, ask the user which version to install:

> **Install person template — which version?**
> 1. **Minimal** (default, works in any vault)
> 2. **Full** (requires Dataview plugin + Obsidian Bases)

Then copy the chosen template into the user's `_Templates/` folder:

**Resolving the repo path**: this skill is normally *symlinked* into
`~/.claude/skills/` rather than copied there, so a naive `$skill_dir/../templates/`
resolves against `~/.claude/skills/templates` — which does not exist — instead of
the repo root. Resolve the symlink before walking up.

Note also that the shell positional-parameter idiom sometimes used here is not
meaningful: you are an agent reading this file, not a script being executed, and
the slash-command loader substitutes the invocation arguments into any such
placeholder before you ever see it. Use the "Base directory for this skill" path
from your context as `skill_dir`.

```bash
skill_dir="<the 'Base directory for this skill' path from your context>"

# cd -P resolves symlinks physically, so this lands in the real cloned repo
# even when skill_dir is ~/.claude/skills/summarize -> ~/src/ai-life-skills/summarize
repo_dir="$(cd -P "$skill_dir" && cd .. && pwd)"
templates_dir="$repo_dir/templates"

if [ ! -d "$templates_dir" ]; then
  echo "ERROR: shared templates/ not found at $templates_dir"
  echo "Expected it as a sibling of the skill dir in the cloned repo."
  exit 1
fi

target="$VAULT_ROOT/$TEMPLATES_DIR/new person template.md"

if [ ! -f "$target" ]; then
  # Use the user's choice — default to minimal
  src="$templates_dir/new person template (minimal).md"
  # if user picked full: src="$templates_dir/new person template.md"
  cp "$src" "$target"
fi
```

Note: whichever version gets installed lands at `_Templates/new person template.md` (no `(minimal)` suffix) so the skill's later references work uniformly.

Once Step 0 passes, proceed to Step 0.5.

## Step 0.5: Determine depth mode

Before extraction, establish which depth the user wants:

1. **Scan the invocation first.** If the user's request already specifies a mode, use it and skip the prompt:
   - Words like `minimal`, `fast`, `quick`, `--minimal`, `-m` → minimal mode
   - Words like `detailed`, `deep`, `full`, `--detailed`, `-d` → detailed mode
2. **Otherwise, prompt.** No default — if unspecified, ask every time:

> **Depth?**
> 1. **Detailed** (best results) — full reference notes for every wikilinked concept, person notes for every mentioned person, parallel highest-available-model subagents per section, base updates
> 2. **Minimal** (fast) — summary note only, wikilinks left dangling, person notes for creators/guests only, Sonnet summary

This keeps interactive runs explicit while letting scheduled tasks / cron / `/loop` pass the mode in the invocation (e.g. `/summarize <url> minimal`) without blocking on input.

The chosen mode determines which steps run:

| Step | Detailed | Minimal |
|---|---|---|
| 0.6 New-territory gate | ✓ (asks) | ✓ (defaults + logs) |
| 1 Extract text | ✓ | ✓ |
| 1b Save transcript | ✓ | ✓ |
| 2 Output structure | ✓ | ✓ |
| 3a Depth from word count | ✓ | ✓ |
| 3b Parallel subagents | ✓ (>3000 words, highest available model) | ✓ (>3000 words, Sonnet) |
| 4 Assemble summary | ✓ | ✓ (skip `## People Mentioned` section) |
| 5 Reference notes (concepts) | ✓ | ✗ — wikilinks left dangling |
| 5 Person notes | ✓ (all mentioned) | ✓ (creators/guests only — those in `people` frontmatter) |
| 5c Dangling-link audit | ✓ | ✗ |
| 6 Bases update | ✓ (if bases exist) | ✗ |
| 7 Daily note | ✓ | ✓ |

For book chapter-by-chapter depth (Step 1 book section), detailed mode gets the full 300-600 words per chapter; minimal mode gets a flatter single summary regardless of chapter count.

## Step 0.6: New-territory gate (first run of a content type)

The skill's conventions were written for content types it has already seen. The
first time it meets a *new* one, every convention it applies is a guess — and a
guess made silently on a first run becomes cleanup work later (the first Turkish
source in one vault created concept notes that later had to be merged across 200
links; the first audio-archived summary shipped transcript block IDs that did not
resolve). So: before extracting anything, check whether this run is a first, and
if so surface the assumptions instead of applying them.

**Detect.** Decide the content type from the source (YouTube, article, PDF/paper,
EPUB/book, podcast, lecture) and any sub-variant that changes the output shape
(audio archived to the vault, cropped segment, multi-part series). Then check
whether the vault already has an example:

```bash
type="<youtube|article|paper|book|podcast|lecture>"
# any existing summary tagged with this type?
grep -rlE "^\s*-\s*$type\s*$" "$VAULT_ROOT/$SUMMARIES_DIR" --include='*.md' 2>/dev/null | head -1
# sub-variants: has the vault ever archived audio / cropped a segment?
grep -rl '^audio:'   "$VAULT_ROOT/$SUMMARIES_DIR" --include='*.md' 2>/dev/null | head -1
grep -rl '^segment:' "$VAULT_ROOT/$SUMMARIES_DIR" --include='*.md' 2>/dev/null | head -1
```

A hit means the territory is known — **the gate stays silent and you proceed to
Step 1.** Do not ask anything. Language, channel and author are deliberately *not*
triggers: they recur too often, and the vault's own CLAUDE.md governs naming.

**No hit → this is a first.** List, in one message, the assumptions that will
shape the output and that a later run cannot cheaply undo:

- where the note lands (folder, filename pattern) and which frontmatter extras it gets
- transcript / audio shape, if any (block-ID format, pinned player, crop offset)
- depth and structure choices specific to the type (per-chapter sections for a
  book, `segment:` for a cropped podcast, `authors`/`affiliations` for a paper)
- anything the vault's CLAUDE.md says that conflicts with this skill's default

Then:

- **Interactive run** (depth was *prompted* in Step 0.5, so a user is present):
  ask the 2–4 questions that matter, with a recommended option each. Apply the
  answers, and write them into the daily note under `## notes` so the next run of
  this type finds them.
- **Autonomous run** (depth came from the invocation — cron, `/loop`,
  `/schedule`): do not block. Take the most reversible default for each
  assumption, proceed, and record every assumption in the daily note as a
  *decision pending* bullet under `## TODO for next session`. The user reviews
  and corrects; the notes are cheap to fix, the missed run is not.

Either way the gate fires once per content type per vault. After the first
summary of that type exists, the detection above finds it and the gate is silent.

## Step 1: Detect content type and extract text

### YouTube video
**Cookies**: do NOT hardcode `--cookies-from-browser chrome`. That flag is a hard
failure — not a warning — when the named browser isn't installed
(`ERROR: could not find chrome cookies database in ...`), which breaks the skill
on any machine using Safari, Arc, Firefox, or a Chrome profile in a non-default
location. Most public videos need no cookies at all, so try bare first and only
fall back to a browser if that fails.

```bash
URL="<URL>"
FMT="%(id)s|%(title)s|%(duration)s|%(upload_date)s|%(view_count)s|%(channel)s|%(channel_id)s"

# Try with no cookies first. $YTDLP_COOKIES holds the flag (often empty) so the
# subtitle/audio calls below reuse whatever worked here.
YTDLP_COOKIES=""
meta="$(yt-dlp --print "$FMT" --no-download "$URL" 2>/dev/null)"

if [ -z "$meta" ]; then
  # Bare call failed — likely age-gated, private, region-locked, or a bot check.
  # Probe browsers that are actually present rather than assuming Chrome.
  for b in chrome brave edge firefox safari arc chromium vivaldi opera; do
    meta="$(yt-dlp --cookies-from-browser "$b" --print "$FMT" --no-download "$URL" 2>/dev/null)" || continue
    if [ -n "$meta" ]; then YTDLP_COOKIES="--cookies-from-browser $b"; break; fi
  done
fi

if [ -z "$meta" ]; then
  echo "ERROR: yt-dlp could not fetch metadata with or without cookies."
  echo "Video may be private, age-gated, region-locked, or hitting a bot check."
  exit 1
fi
echo "$meta"

# Try auto-subtitles first (fastest, free)
# $YTDLP_COOKIES is intentionally unquoted — it must word-split into two argv
# entries, or expand to nothing when empty.
# shellcheck disable=SC2086
yt-dlp $YTDLP_COOKIES \
  --write-auto-sub --sub-lang en --sub-format json3 \
  --skip-download -o "/tmp/summarize/%(id)s" "$URL"
```

If yt-dlp warns `no impersonate target is available`, it is usually harmless, but
on videos with stricter bot checks it causes empty results. Fix with
`brew install curl-impersonate` (or `pip install "yt-dlp[default,curl-cffi]"`).

If auto-subs exist, extract text from the JSON3 file. If not, or if quality is poor:
- Download audio (below) and transcribe (same as `youtube-transcribe` skill — ask user: local mlx_whisper or ElevenLabs Scribe)

**Download the audio** — needed for Step 1c (vault archive + click-to-play) and
for the transcription fallback. Kick it off in the background right after the
subtitle fetch so it runs while you read the transcript.

YouTube's default `web` client frequently returns `HTTP Error 403: Forbidden` on
the media download even when metadata and subtitles worked (the "SABR-only
streaming experiment" — see yt-dlp issue #12482). `ios`, `android` and `tv`
clients then fail with `Requested format is not available`. The `mweb` client
reliably still serves a downloadable format, so fall through a client list
rather than giving up on the first 403:

```bash
# shellcheck disable=SC2086
audio_ok=""
for client in "" mweb web_safari tv; do
  extra=""
  [ -n "$client" ] && extra="--extractor-args youtube:player_client=$client"
  if yt-dlp $YTDLP_COOKIES $extra -f "bestaudio/best" \
       -x --audio-format mp3 --audio-quality 5 \
       -o "/tmp/summarize/%(id)s.%(ext)s" "$URL" >/tmp/summarize/audio.log 2>&1; then
    audio_ok="yes"; echo "audio ok (client: ${client:-default})"; break
  fi
  echo "audio failed (client: ${client:-default}), trying next"
done
[ -n "$audio_ok" ] || echo "WARNING: audio download failed on every client — Step 1c will be skipped"
```

If every client fails, continue without audio: skip Step 1c entirely (no
`audio:` field, no pinned player, no `▶` jump links) and say so in the daily note.
The summary and transcript notes are still valid without it.

### Web article / blog post
```bash
defuddle parse "<URL>" --md -o /tmp/summarize/article.md
```

If defuddle is not installed: `npm install -g defuddle`

Extract title, author, date, domain from defuddle metadata:
```bash
defuddle parse "<URL>" -p title
defuddle parse "<URL>" -p domain
```

### PDF
```bash
pdftotext "<path>" /tmp/summarize/paper.txt
```

If `pdftotext` is not available: `brew install poppler`

### EPUB (books)
```bash
# Extract full text as markdown (preserves chapter structure)
pandoc "<path>" -t markdown --wrap=none -o /tmp/summarize/book.md

# If you need chapter boundaries, extract the TOC:
pandoc "<path>" -t json | python3 -c "
import json, sys
doc = json.load(sys.stdin)
for block in doc['blocks']:
    if block['t'] == 'Header':
        level = block['c'][0]
        text = ''.join(
            item['c'] if item['t'] == 'Str' else ' ' if item['t'] == 'Space' else ''
            for item in block['c'][2]
        )
        print(f'L{level}: {text}')
"
```

**Chapter splitting strategy for books:**
1. Extract full text with `pandoc` → markdown
2. Identify chapter boundaries from headers (epubs have built-in TOC structure that pandoc preserves as `#`/`##` headers)
3. Split into one chunk per chapter
4. Dispatch parallel Opus subagents — **one per chapter** — same as any other long content
5. A typical book (60-100k words, 15-30 chapters) produces chapters of ~3-5k words each — well within subagent context limits

**For very long books (>30 chapters):** batch chapters into groups of ~5 per subagent to keep the number of parallel agents manageable. Each subagent summarizes its batch and returns section summaries.

**CRITICAL — Book summary depth requirement:**
- Each chapter MUST get its own dedicated `## Chapter N: Title` section with a **substantial** summary (300-600 words per chapter depending on chapter length)
- Do NOT batch multiple chapters into a single brief paragraph — every chapter gets its own detailed treatment
- Include key arguments, data points, examples, and quotes from each chapter
- A 10-chapter book should produce ~3000-6000 words of summary content (excluding frontmatter/tldr)
- A 30-chapter book should produce ~5000-10000 words
- Think of each chapter summary as a standalone mini-essay that captures the chapter's core contribution
- The goal is that someone reading the summary should understand what each chapter argues, not just what the book is "about" at a high level

**Output structure for books:**
- Location: `08 Summaries/<Book Title>.md` (or `08 Summaries/<Author>/<Book Title>.md` if summarizing multiple books by one author)
- Frontmatter tag: `book`
- Extra fields: `creator` (author wikilink), `published` (year), `isbn` (if known), `source` (wikilink to the epub file if it's in the vault, e.g. `"[[Book Title.epub]]"`)
- Each chapter gets its own `## Chapter N: Title` section in the summary
- Add a `## Chapter Navigation` callout at the top if the book has many chapters

### Other files (txt, docx, etc.)

For `.docx`: `pandoc "<path>" -t markdown --wrap=none -o /tmp/summarize/doc.md`

For plain text: read directly.

### Pasted text / vault note
Read directly from user message or vault path.

## Step 1b: Save transcript (audio/video content only)

For any content that has audio — YouTube videos, podcast episodes, lectures/talks with recordings — save the extracted transcript as a permanent vault note.

**When to create a transcript note:**
- YouTube videos (from auto-subs or whisper transcription)
- Podcast episodes (from transcription)
- Lectures/talks with audio/video recordings
- Any content where the source is spoken word

**Do NOT create transcript notes for:** articles, blog posts, PDFs, books, pasted text — these are already text.

**Location:** Same folder as the summary note, with ` Transcript` appended to the filename.

**Format:**
```markdown
---
date: YYYY-MM-DD
duration: <seconds>
recording: "<source URL>"
meeting: "[[<Summary Note Title>]]"
unread: true
---

**[0:00:00]** First segment text ^p1-0-00-00

**[0:00:13]** Second segment text ^p1-0-00-13

**[0:00:27]** Third segment text ^p1-0-00-27
```

**Segment format — every line must be separated by a blank line.** Each segment is
one paragraph: a bold `**[H:MM:SS]**` timestamp, the text, then a block ID
`^p1-H-MM-SS` (zero-padded minutes/seconds, matching the timestamp) so the
summary can embed it with `![[<Title> Transcript#^p1-H-MM-SS]]` and Step 1c can
derive the audio jump-link offset from the ID.

The blank lines are not cosmetic. Markdown joins consecutive lines into a single
paragraph, and Obsidian registers only the *last* `^id` of a paragraph — so a
transcript written as consecutive lines yields exactly one resolvable block, and
every other quote embed renders as *"Unable to find ^p1-… in … Transcript"*.
Join segments with `"\n\n"`, not `"\n"`.

Merging raw caption events into ~10-second segments before emitting is fine (and
makes the block IDs more useful); just keep the segment's start time as its
timestamp/ID.

**Link from summary:** Add `transcript: "[[<Title> Transcript]]"` to the summary note's frontmatter.

This step happens immediately after text extraction (Step 1) and before output structure planning (Step 2). The transcript is the raw source material — always preserve it.

## Step 1c: Archive audio to the vault + enable click-to-play timestamps (audio/video content only)

If the user has the **[Media Extended](https://github.com/aidenlx/media-extended)** Obsidian plugin installed (assume YES unless proven otherwise — it's a common companion plugin for this workflow), move the downloaded source audio into the vault and wire up click-to-play timestamps throughout the summary.

### 1c-i. Archive the audio

Copy (or move) the downloaded mp3/wav/mp4 into `$VAULT_ROOT/_Attachments/` with a descriptive, human-scannable filename that includes the date and — if cropped — the segment range.

```
<Creator> x <Guest> <YYYY-MM-DD>.mp3
<Creator> x <Guest> <YYYY-MM-DD> (HhMMm-HhMMm).mp3   # if cropped
```

**Add `audio: "[[<filename>.mp3]]"`** to the summary note's frontmatter so the attachment is a first-class property on the note (parallel to `transcript:`, `source:`, etc.).

### 1c-ii. Embed ONE pinned player at the top

Place a single full-length audio/video embed at the top of the summary, just above the `> [!tldr]` callout:

```markdown
> [!abstract] Audio — full interview (cropped H:MM:SS – H:MM:SS of the VOD)
> ![[<filename>.mp3]]
```

**Do not scatter multiple `![[audio.mp3#t=...]]` embeds through the note** — every embed spawns a fresh player. Media Extended's pattern is one pinned player + many text-link jump-points.

**Do NOT add:**
- A "Pin this player / Media Extended: right-click → Pin" instruction underneath the embed. The user knows how their plugin works. Don't narrate it.
- A "Key moments" / "Jump to" / "Chapters" callout listing timestamped highlights. The per-quote inline jumps (Step 1c-iii) already give every notable moment a click-to-play entry point; a separate highlights list is redundant and repeats the same timestamps twice.

### 1c-iii. Add inline click-to-play links next to every quote

For every `> [!quote]` callout that embeds a transcript line (`![[...Transcript#^block-id]]`), add a sibling line inside the same callout:

```markdown
> [!quote] Who — what they said
> ![[<Transcript Note>#^block-id]]
> ▶ [[<filename>.mp3#t=<seconds>|jump player to H:MM:SS]]
```

- The `#t=<seconds>` fragment is **audio-local seconds**, not wall-clock VOD time. If the audio was cropped (e.g. starting at VOD 1:17:00), subtract the crop offset from the VOD timestamp before emitting.
- The `|jump player to H:MM:SS` alias is what the user reads — format it `H:MM:SS` when ≥1 hour, else `M:SS`.
- The leading `▶ ` (U+25B6) is a visual cue — keep it.
- These are **text links** (no `!` prefix), not embeds. Media Extended routes the click to the pinned player instead of creating a new one.

### 1c-iv. Math for audio-local offsets

```
audio_sec = (vod_h * 3600 + vod_m * 60 + vod_s) - crop_start_sec
```

If the transcript already uses block IDs of the form `^p1-H-MM-SS` (absolute VOD timestamps), this regex transformation converts every quote-embed into one with an audio-local jump link appended:

```python
import re
AUDIO = "<filename>.mp3"
CROP_OFFSET_SEC = <crop start seconds>   # 0 if audio starts at beginning of the source

pattern = re.compile(
    r'^(> !\[\[[^\]]*Transcript#\^p1-(\d+)-(\d+)-(\d+)(?:-\d+)?\]\])$',
    re.MULTILINE,
)

def repl(m):
    block_line = m.group(1)
    h, mm, ss = int(m.group(2)), int(m.group(3)), int(m.group(4))
    audio_sec = (h*3600 + mm*60 + ss) - CROP_OFFSET_SEC
    if audio_sec < 0:
        return block_line
    hh = audio_sec // 3600
    mm2 = (audio_sec % 3600) // 60
    ss2 = audio_sec % 60
    label = f"{hh}:{mm2:02d}:{ss2:02d}" if hh else f"{mm2}:{ss2:02d}"
    return f"{block_line}\n> ▶ [[{AUDIO}#t={audio_sec}|jump player to {label}]]"

text = pattern.sub(repl, text)
```

Run this after Step 4 assembles the summary — it's a pure string transform.

### 1c-v. If the user does NOT have Media Extended

Fall back to native Obsidian syntax: one top-of-note `![[audio.mp3]]` embed only. Do **not** scatter `![[audio.mp3#t=N]]` embeds inline — they each spawn a separate player, which clutters the note. Inline timestamp references in that case should just be the VOD timestamp as plain text.

## Step 2: Determine output structure

Based on content type, choose the appropriate format:

| Content type | Location | Frontmatter tags | Extra fields |
|---|---|---|---|
| YouTube video | `08 Summaries/<Channel>/Summaries/<Title>.md` | `youtube` | `recording`, `audio` (wikilink to vault mp3 if archived per Step 1c), `views`, `creator`, `people`, `guest`, `hosts`, `guests`, `duration`, `uploaded`, `transcript` |
| Article / blog | `08 Summaries/<Title>.md` | `article` | `creator`, `source` (URL), `published` |
| Whitepaper / PDF | `08 Summaries/<Title>.md` | `paper` | `authors`, `affiliations`, `source` (wikilink to PDF if in vault, or URL), `published` |
| EPUB / book | `08 Summaries/<Title>.md` | `book` | `creator` (author wikilink), `published` (year), `isbn`, `source` (wikilink to epub if in vault) |
| Podcast episode | `08 Summaries/<Show>/Summaries/<Title>.md` | `podcast` | `recording`, `audio` (wikilink to vault mp3 if archived per Step 1c), `segment` (e.g. `"1:17:00 – 2:50:50"` if cropped), `people`, `guest`, `hosts`, `guests`, `duration`, `transcript` |
| Lecture / talk | `08 Summaries/<Title>.md` | `lecture` | `creator`, `recording` (if URL), `audio` (wikilink to vault mp3 if archived per Step 1c), `transcript` |

**All notes** get: `created`, `updated`, `date`, `summary`, `categories: ["[[posts.base]]"]`, `unread: true`

**`summary` field length — HARD LIMIT: ≤70 characters.** One tight line, no wikilinks, no paragraph-length blurbs. The `> [!tldr]` callout at the top of the body is where the long-form overview lives. The frontmatter `summary` is just a scannable hint for base views — think newspaper subhead, not abstract. Examples that are the right size:
- `"Ledger interviews Cobie — 3h 51m UpOnly career retrospective"` (60 chars)
- `"Cobie on ThreadGuy — first interview since joining Coinbase"` (59 chars)
- `"Lex x Karpathy — state of AI, RLHF, self-driving, education"` (60 chars)

If it's longer than 70 characters, cut it. Do not paste the tldr into the summary field.

If a channel/show folder is needed, check if it already exists before creating.

## Step 3: Analyze structure, determine depth, and plan sections

Read the full extracted text. Identify the natural sections/chapters/topics.

### 3a. Determine summary depth from source length

Summary length must be **proportional** to the source material. A 10-minute video and a 3-hour documentary should not produce the same size summary. Use the source word count to determine the target summary word count:

| Source word count | Source examples | Target summary words | Sections | TLDR |
|---|---|---|---|---|
| <1,500 | 5-min video, short article | 200–400 | 1–2 | 2 sentences |
| 1,500–5,000 | 10–20 min video, blog post, short paper | 500–1,200 | 3–5 | 3 sentences |
| 5,000–15,000 | 30–60 min video, long article, whitepaper | 1,500–3,000 | 5–8 | 3–4 sentences |
| 15,000–40,000 | 1–3 hr video/podcast, long paper | 3,000–6,000 | 8–15 | 4–5 sentences |
| 40,000–80,000 | Short book, multi-hour series | 5,000–10,000 | 15–25 | 5 sentences |
| 80,000+ | Full book (200+ pages) | 8,000–15,000 | 20–40 | 5 sentences |

**The ratio is roughly 1:5 to 1:10** — a 10,000-word source should produce ~1,500–2,500 words of summary. Denser/more technical content skews toward the higher end; conversational/repetitive content skews lower.

**For videos/podcasts**, estimate source words from duration: ~150 words/minute for conversational, ~120 words/minute for interviews with pauses, ~170 words/minute for scripted/narrated content. Or just use the actual transcript word count.

**Per-section depth**: each section's word budget should be proportional to its share of the source material. A section covering 20% of the transcript gets ~20% of the summary word budget. Adjust up for particularly dense/important sections, down for filler/repetitive ones.

### 3b. Plan sections and dispatch

**For long content (>3000 source words):** dispatch parallel subagents (see Model usage table for which model) — one per section — to summarize simultaneously. Each subagent gets:
- The section text
- The audience level
- A **specific word count target** (calculated from 3a above)
- Instructions to use `[[wikilinks]]` for every technical concept, person, place, company, and notable noun

**For short content (<3000 source words):** summarize directly without subagents.

**Model choice**: detailed mode uses the highest available model (Opus if the user has access, else Sonnet); minimal mode always uses Sonnet. Never Haiku.

## Step 4: Assemble the summary note

### Structure

```markdown
---
[frontmatter per Step 2]
---

[embed if applicable: ![[file.pdf]], ```vid URL```, etc.]

> [!tldr]
> [Overview — sentence count per Step 3a depth table. What is it about, who made it, what are the key takeaways?]

## [Section 1 Title]

[Summary paragraphs with [[wikilinks]] to all concepts, people, places, companies, products]

## [Section 2 Title]

[...]

## People Mentioned
- [[Person Name]] — brief context of who they are and their role in this content
```

### Formatting rules

1. **No `# Title` heading** — filename is the title
2. **Never repeat frontmatter in the body** — if it's in metadata, don't write it again
3. **`> [!tldr]`** for the overview, not `## Summary`
4. **`> [!quote]`** callouts for notable quotes (with speaker wikilink and source location if available)
5. **Wikilink EVERYTHING** — people, places, companies, concepts, technical terms, **book/film/show titles**, even if no note exists yet
5b. **Never create two separate wikilinks for the same entity.** If a person has a canonical note name plus other handles / real names / pseudonyms, use alias syntax — `[[Cobie|Jordan Fish]]`, `[[Bob Laksiv|King BTC]]` — not two siblings like `[[Cobie]] / [[Jordan Fish]]` or `[[Bob Laksiv]] / [[King BTC]]`. The canonical note is whichever name already exists (or will exist) in `04 People/`; everything else is a display alias pointing at it. Same for companies/products with renames — `[[Facebook|Meta]]`, `[[X|Twitter]]`. When it's natural to mention both, write it as prose: `[[Cobie]] (real name Jordan Fish)`, `[[Bob Laksiv]] (a.k.a. King BTC)`. Rule of thumb: one entity = one link target, always.

5c. **Concept note names are lowercase; capitalise with an alias, never with a second link.**
This is the most common way rule 5b gets violated in practice. Writing a sentence that
*begins* with a linked concept invites capitalising it — `[[Quantum entanglement]] is a
correlation...` — while the same concept mid-sentence is written `[[quantum entanglement]]`.
That is two link targets for one entity.

The failure is worse than cosmetic, because macOS and Windows filesystems are
case-insensitive by default while `find -name` is case-*sensitive*:

- The audit in Step 5a looks for `Quantum entanglement.md`, does not find the existing
  `quantum entanglement.md`, and falsely reports it MISSING.
- Acting on that false report writes `Quantum entanglement.md`, which **silently
  overwrites** the real note. No error, no warning, content gone.

So: name concept notes in lowercase (proper nouns keep their capitals — `[[Apple Watch]]`,
`[[Neville Goddard]]`, `[[Japan]]`). When a sentence starts with one, use the alias form:

```markdown
[[quantum entanglement|Quantum entanglement]] is a correlation between particles...
[[behavioral psychology|Behavioral psychology]] explains the chain as...
```

The reader sees a normally capitalised sentence; the vault sees one note. Before creating
any note, check case-insensitively whether it already exists (see Step 5a).
6. **Use actual Japanese/Chinese characters** for non-English words, not romanization
7. **Timestamps** on topic headings and quotes when available (YouTube, podcasts)
8. **`people` field**: only people who created/appeared in the content. Mentioned people go in `## People Mentioned`
9. **Audio click-to-play** — if Step 1c archived a local mp3 and Media Extended is installed, every `> [!quote]` callout that embeds a transcript block should also carry a `> ▶ [[<audio>.mp3#t=<sec>|jump player to H:MM:SS]]` text link (one pinned top-of-note player, many text-link jumps). See Step 1c for the full pattern and the regex transform.

### Audience adaptation

- **High school / college student**: plain language, analogies, explain jargon inline before first wikilink use
- **General reader**: balanced — explain key terms but don't over-simplify
- **Expert**: technical language fine, focus on novel contributions and critiques

## Step 5: Create reference notes (one layer deep)

**This is the most important step. Every wikilink MUST resolve to a note. No dangling links.**

### 5a. Extract and audit all wikilinks

After the summary note is fully assembled, extract every unique wikilink programmatically:

The regex excludes `|` (alias), `#` (heading ref), and `^` (block ref) so `[[Target|Alias]]`, `[[Page#Heading]]`, and `[[Page^block]]` all resolve to the canonical note name (`Target` / `Page`):
```bash
grep -oE '\[\[[^]|#^]+' "<summary_note_path>" | sed 's/\[\[//' | sort -u
```

Then check which ones are missing:

Use `-iname`, **not** `-name`. On case-insensitive filesystems (macOS, Windows) a
case-sensitive lookup reports an existing note as missing, and creating it then
silently overwrites the original — see rule 5c.

```bash
for term in <each extracted term>; do
  found=$(find "$VAULT_ROOT" -iname "$term.md" \
    -not -path "*/.Trash/*" -not -path "*/Clippings/*" 2>/dev/null | head -1)
  if [ -z "$found" ]; then echo "MISSING: $term"; fi
done
```

Also check the extracted list against itself for links that differ only by case — these
are rule 5c violations that must be collapsed to alias form *before* any note is created:

```bash
grep -oE '\[\[[^]|#^]+' "<summary_note_path>" | sed 's/\[\[//' | sort -u \
  | awk '{ k=tolower($0); if (k in seen) print "CASE COLLISION: " seen[k] " vs " $0; else seen[k]=$0 }'
```

**Do NOT skip this step. Do NOT estimate from memory which notes exist.** Always run the audit.

### 5b. Create missing notes

#### Technical concepts, companies, products, places
Create in `07 References/<Term>.md`:

```markdown
---
created: YYYY-MM-DDT00:00
updated: YYYY-MM-DDT00:00
type: reference
unread: true
---

[2-4 sentence plain-language explanation. Use [[wikilinks]] to cross-reference related concepts.]
```

#### People
Create in `$PEOPLE_DIR/<Full Name>.md` using the person template at `$VAULT_ROOT/$TEMPLATES_DIR/new person template.md` (installed by Step 0d). Conventions:

- **Public figures**: research and write a rich bio (birthday, career, links, key facts). The `> [!info]` callout should be a substantive snapshot — life story, mission, current focus — not a stub.
- **Private individuals**: minimal note with only what's known from the content. The note will grow naturally over time.
- **`> [!note] current age` callout** (from template): keep it if `birthday` is known or can be estimated. If estimated, append `(estimated)` to the callout text — but `birthday` in frontmatter must stay a pure YAML date (e.g. `2001-01-01`), never text.
- **`> [!abstract] total hours talked` callout** (from template): ONLY keep this if the person has had real 1-on-1 calls/meetings with the vault owner (i.e. they appear in meeting notes). Delete the callout for people discovered through summarizing videos, articles, books, or podcasts — those people will never have meeting entries, so the callout would always show 0h.
- **No `# Title` heading** — Obsidian shows the filename as the title.
- **`unread: true`** in frontmatter on every new or modified note.

#### Dispatch in parallel
For large numbers of missing notes (>10), use parallel subagents (highest available model) in batches of ~20-25 notes each. Each subagent creates the notes and returns confirmation.

### 5c. Verify — no dangling links

After all notes are created, re-run the audit from 5a to confirm zero missing notes. If any remain (e.g. a subagent failed or skipped one), create them manually. **The summary is not done until this verification passes.**

### 5d. Lint every note you wrote

The `vault-lint.sh` PostToolUse hook (see the repo's `hooks/`) only fires on the
Edit/Write tools. Notes written through Bash heredocs or scripts — the usual way
this skill emits summaries, transcripts and batches of reference notes — bypass
it silently. So lint them explicitly before declaring the run done:

```bash
lint="$HOME/.claude/hooks/vault-lint.sh"
if [ -x "$lint" ]; then
  for f in "<summary note>" "<transcript note>" "<each person/reference note written this run>"; do
    printf '{"tool_input":{"file_path":"%s"}}' "$f" | "$lint" || echo "LINT BLOCK: $f"
  done
fi
```

A `BLOCK` finding (root/case collision, unresolved block ref, joined block IDs,
`# Title`, missing frontmatter) must be fixed before Step 6. Warnings are
informational. If the hook is not installed, say so in the daily note and fall
back to the 5a/5c audit alone.

## Step 6: Update bases (optional — skip if not using Obsidian Bases)

This step only applies if `$VAULT_ROOT/$BASES_DIR/posts.base` exists. If it doesn't, skip Step 6 entirely.

```bash
[ -f "$VAULT_ROOT/$BASES_DIR/posts.base" ] || echo "No posts.base — skipping Step 6"
```

If it does exist:
- **`posts.base`**: if new people appeared as creators/guests, add named views for them using the YAML block below, then embed them in their person notes (in a `## episodes` or `## videos` section) via `![[posts.base#Person Name]]`.
- If a new channel/show folder was created, add a channel-specific view to `posts.base` the same way.

Named view YAML block to append under the `views:` list:
```yaml
  - type: table
    name: "Person Name"
    filters:
      and:
        - recording != null
        - people.contains(link("Person Name"))
    order:
      - date
      - views
      - file.name
      - summary
    sort:
      - property: date
        direction: DESC
```

## Step 7: Update daily note

Update `$VAULT_ROOT/$DAILY_DIR/YYYY/MM/MM-DD-YY ddd.md` (e.g. `02 Daily/2026/04/04-11-26 Sat.md`). Create the `YYYY/MM/` subdirectories if they don't exist. No `# Title` heading — the filename is the title. Set `unread: true` in frontmatter.

```markdown
## content summary
- summarized [[Note Title]] — [1-line description of what it is]
- created reference notes: [[Term 1]], [[Term 2]], ...
- created person notes: [[Person 1]], [[Person 2]], ...
```

## Model usage

| Task | Detailed | Minimal |
|------|----------|---------|
| Content extraction | Scripts (defuddle, pdftotext, yt-dlp) | Scripts |
| Section summarization | Highest available (Opus if accessible, else Sonnet) | **Sonnet** |
| Reference note creation | Highest available | (skipped) |
| Person note creation | Highest available | **Sonnet** (creators/guests only) |
| **NEVER** | **Haiku** | **Haiku** |

## Key rules

1. **Wikilink everything** — every concept, person, company, place, and **book/film/show title** gets a `[[wikilink]]`
2. **One layer deep** — create reference/person notes for EVERY wikilinked term that doesn't already have a note
3. **No `# Title` headings** — Obsidian shows filename as title
4. **Never repeat frontmatter in body** — frontmatter is metadata, body is content
5. **Set `unread: true`** on every note created or modified
6. **Parallel Opus subagents** for long content — one per section for summaries, batches of ~20 for reference notes
7. **Audience-appropriate language** — match the user's requested level
8. **Always embed/link the source** — PDF embed, vid embed, or source URL in frontmatter
9. **`> [!tldr]`** is mandatory — every summary starts with a concise overview callout
10. **Person note `## updates` links to the content note, NEVER the daily note**
11. **Audio archival + click-to-play** — for downloaded audio/video, archive the file to `_Attachments/`, embed ONE pinned player at the top, and add `▶ [[audio.mp3#t=<sec>|jump player to H:MM:SS]]` text links inside every quote callout. Never scatter multiple `![[audio.mp3#t=N]]` embeds (they each spawn a separate player). See Step 1c.
