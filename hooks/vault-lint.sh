#!/bin/bash
# vault-lint.sh — lint Obsidian notes the moment Claude writes them.
#
# Two modes:
#   hook   (default) PostToolUse on Edit|Write. Reads {"tool_input":{"file_path":..}}
#          from stdin, lints that one file. BLOCK → exit 2 + stderr (Claude must
#          fix); WARN → exit 0 + additionalContext JSON (Claude is told).
#   --all  [vault]   Lint every .md in the vault (auto-detected from $PWD if not
#          given). Prints a grouped report; exit 2 if any BLOCK finding.
#
# Wire into ~/.claude/settings.json next to post-edit-lint.sh:
#   {"type": "command", "command": "/Users/kutlan/.claude/hooks/vault-lint.sh"}
#
# Manual single-file test:
#   echo '{"tool_input":{"file_path":"/abs/note.md"}}' | vault-lint.sh

set -u

find_vault() {  # walk up from $1 until a dir containing .obsidian/
  local d; d="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  while [ "$d" != "/" ]; do
    [ -d "$d/.obsidian" ] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

MODE="hook"; FILES=(); VAULT=""
if [ "${1:-}" = "--all" ]; then
  MODE="all"
  VAULT="$(find_vault "${2:-$PWD}")" || { echo "vault-lint: no .obsidian/ found above ${2:-$PWD}" >&2; exit 1; }
else
  FILE_PATH=$(jq -r '.tool_input.file_path // empty' < /dev/stdin)
  [ -z "$FILE_PATH" ] && exit 0
  case "$FILE_PATH" in *.md) ;; *) exit 0 ;; esac
  [ -f "$FILE_PATH" ] || exit 0
  VAULT="$(find_vault "$(dirname "$FILE_PATH")")" || exit 0
  FILES=("$FILE_PATH")
fi

python3 - "$MODE" "$VAULT" ${FILES[@]+"${FILES[@]}"} <<'PY'
import json, os, re, sys

MODE, VAULT = sys.argv[1], sys.argv[2]
FILES = sys.argv[3:]

# ---------------------------------------------------------------------------
# Policy — decided 2026-09-19.
#   block → exit 2, Claude must fix.   warn → exit 0, Claude is told.   off → skip.
SEVERITY = {
    "dangling_link":     "warn",   # minimal mode leaves these on purpose; 5c audit catches the rest
    "root_collision":    "block",  # [[Claude]] → CLAUDE.md: wrong target, invisible for 11 days
    "case_collision":    "block",  # [[Serotonin]] vs serotonin.md: creating it overwrites the original
    "block_ref_missing": "block",  # [[Note#^id]] with no ^id in Note → "Unable to find" embed
    "block_ids_joined":  "block",  # ^id line followed by a non-blank line → only last id resolves
    "h1_heading":        "block",  # `# Title` in body; fenced code ignored
    "no_frontmatter":    "block",  # every note carries metadata (unread, created, ...)
    "unread_missing":    "warn",   # costs a blue dot, nothing more
    "summary_too_long":  "warn",   # frontmatter summary > 70 chars overflows base views
}

# Folders whose files are prompts/templates, not notes: exempt from frontmatter rules.
EXEMPT_FM = ("_Templates/", "01 Updates/")
# Root-level instruction/dashboard files: never valid link targets.
ROOT_NON_CONTENT = {"CLAUDE.md", "PROJECTS.md", "README.md"}
# Folders never indexed as link targets and never linted.
EXCLUDE_DIRS = {".obsidian", ".trash", ".Trash", "Clippings", "_Attachments", "node_modules", ".git"}
SUMMARY_MAX = 70
ATTACHMENT_EXT = (".mp3", ".mp4", ".m4a", ".wav", ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".base", ".epub", ".canvas")

# ---------------------------------------------------------------------------
# Vault index (built once): lowercase basename → real paths.
INDEX = {}
ALL_MD = []
for root, dirs, files in os.walk(VAULT):
    dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
    for f in files:
        if f.endswith(".md"):
            p = os.path.join(root, f)
            INDEX.setdefault(f[:-3].lower(), []).append(p)
            ALL_MD.append(p)

def is_root_non_content(p):
    return os.path.dirname(p) == VAULT and os.path.basename(p) in ROOT_NON_CONTENT

if MODE == "all":
    FILES = sorted(p for p in ALL_MD if not is_root_non_content(p))
elif FILES and is_root_non_content(FILES[0]):
    sys.exit(0)                                          # CLAUDE.md is instructions, not a note

WIKILINK = re.compile(r"\[\[([^\]|#^]+)(?:#\^([^\]|]+))?(?:#[^\]|^]+)?(?:\|[^\]]*)?\]\]")
BLOCK_ID_EOL = re.compile(r"\s\^([A-Za-z0-9-]+)\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")

def resolve(target):
    hits = INDEX.get(target.lower(), [])
    exact = [p for p in hits if os.path.basename(p)[:-3] == target]
    variant = [p for p in hits if os.path.basename(p)[:-3] != target]
    return (exact[0] if exact else None), (variant[0] if variant else None)

def split_frontmatter(t):
    if t.startswith("---\n"):
        end = t.find("\n---\n", 4)
        if end != -1:
            return t[4:end], t[end + 5:]
        if t.rstrip().endswith("\n---"):          # frontmatter-only file
            return t[4:].rstrip()[:-3], ""
    return None, t

_body_cache = {}
def body_of(path):
    if path not in _body_cache:
        _body_cache[path] = split_frontmatter(open(path, encoding="utf-8", errors="replace").read())[1]
    return _body_cache[path]

# ---------------------------------------------------------------------------
class Note:
    def __init__(self, path):
        self.path = path
        self.rel = os.path.relpath(path, VAULT)
        self.text = open(path, encoding="utf-8", errors="replace").read()
        self.fm, self.body = split_frontmatter(self.text)
        self.findings = []
        self.exempt_fm = self.rel.startswith(EXEMPT_FM)

    def report(self, rule, msg):
        if SEVERITY.get(rule, "off") != "off":
            self.findings.append((rule, msg))

    def links(self):
        # Links inside `inline code` or fenced blocks are mentions, not links.
        prose = "\n".join(l for _, l in self.body_lines_outside_fences())
        prose = re.sub(r"`[^`\n]*`", "", prose)
        for m in WIKILINK.finditer(prose):
            yield m.group(1).strip(), m.group(2)

    def body_lines_outside_fences(self):
        """Yield (lineno, line) for body lines not inside ``` / ~~~ fences."""
        in_fence = False
        for i, line in enumerate(self.body.split("\n"), 1):
            if FENCE.match(line):
                in_fence = not in_fence
                continue
            if not in_fence:
                yield i, line

# ---------------------------------------------------------------------------
# Rules

def rule_links(n):
    seen = set()
    for target, _ in n.links():
        if target in seen or target.lower().endswith(ATTACHMENT_EXT):
            continue
        seen.add(target)
        exact, variant = resolve(target)
        hit = exact or variant
        # Obsidian resolves case-insensitively, so root files win the lookup.
        if hit and os.path.dirname(hit) == VAULT and os.path.basename(hit) in ROOT_NON_CONTENT:
            n.report("root_collision",
                     f"[[{target}]] resolves to root-level {os.path.basename(hit)} — "
                     f"link a content note instead (e.g. [[Claude models|{target}]])")
            continue
        if exact:
            continue
        if variant:
            vname = os.path.basename(variant)[:-3]
            n.report("case_collision",
                     f"[[{target}]] — note exists as {os.path.relpath(variant, VAULT)}; "
                     f"write [[{vname}|{target}]] (creating '{target}.md' would overwrite it)")
            continue
        n.report("dangling_link", f"[[{target}]] has no note")

def rule_block_refs(n):
    checked = set()
    for target, block in n.links():
        if not block or (target, block) in checked:
            continue
        checked.add((target, block))
        exact, _ = resolve(target)
        if not exact:
            continue                                    # dangling_link's job
        if not re.search(r"\s\^" + re.escape(block) + r"\s*$", body_of(exact), re.M):
            n.report("block_ref_missing",
                     f"[[{target}#^{block}]] — ^{block} is not at the end of any paragraph in "
                     f"{os.path.relpath(exact, VAULT)}")

def rule_block_ids_joined(n):
    """A ^id must be the last thing in its paragraph. If the next line is
    non-blank, the paragraph continues and this id will not resolve."""
    lines = n.body.split("\n")
    hits = []
    for i, line in enumerate(lines):
        m = BLOCK_ID_EOL.search(line)
        if m and i + 1 < len(lines) and lines[i + 1].strip():
            hits.append(m.group(1))
    if hits:
        n.report("block_ids_joined",
                 f"{len(hits)} block id(s) are followed by a non-blank line and will not resolve "
                 f"(first: ^{hits[0]}) — separate every ^id line with a blank line")

def rule_h1(n):
    for i, line in n.body_lines_outside_fences():
        if re.match(r"^# \S", line):
            n.report("h1_heading",
                     f"line {i}: `{line.strip()[:60]}` — no `# Title` headings; the filename is the title")
            return

def rule_frontmatter(n):
    if n.exempt_fm:
        return
    if n.fm is None:
        n.report("no_frontmatter", "no frontmatter block — every note needs `---` metadata (at least unread/created)")
        return
    # Hook mode: Claude just wrote this note, so it must be flagged unread.
    # --all mode: `unread: false` means the user read it — only a missing key is a finding.
    if MODE == "hook":
        if not re.search(r"^unread:\s*true\s*$", n.fm, re.M):
            n.report("unread_missing", "frontmatter lacks `unread: true` — set it on every note you create or modify")
    elif not re.search(r"^unread:", n.fm, re.M):
        n.report("unread_missing", "frontmatter has no `unread:` key")
    m = re.search(r"^summary:\s*(.*)$", n.fm, re.M)
    if m:
        val = m.group(1).strip().strip('"').strip("'")
        if len(val) > SUMMARY_MAX:
            n.report("summary_too_long",
                     f"`summary:` is {len(val)} chars (limit {SUMMARY_MAX}) — the tldr callout is where the long version lives")

RULES = (rule_links, rule_block_refs, rule_block_ids_joined, rule_h1, rule_frontmatter)

# ---------------------------------------------------------------------------
# Run

def lint(path):
    n = Note(path)
    for fn in RULES:
        try:
            fn(n)
        except Exception as e:                          # a broken rule must never block Claude
            sys.stderr.write(f"vault-lint: {fn.__name__} crashed on {n.rel}: {e}\n")
    return n

def fmt(items):
    return "\n".join(f"  - [{r}] {m}" for r, m in items)

notes = [lint(p) for p in FILES]
any_block = False

if MODE == "all":
    tot_b = tot_w = 0
    for n in notes:
        b = [(r, m) for r, m in n.findings if SEVERITY[r] == "block"]
        w = [(r, m) for r, m in n.findings if SEVERITY[r] == "warn"]
        if not (b or w):
            continue
        tot_b += len(b); tot_w += len(w)
        print(f"{'BLOCK' if b else 'warn '} {n.rel}")
        if b: print(fmt(b))
        if w: print(fmt(w))
    print(f"\n{len(notes)} notes scanned — {tot_b} block, {tot_w} warn")
    sys.exit(2 if tot_b else 0)

# hook mode: exactly one note
n = notes[0]
blocks = [(r, m) for r, m in n.findings if SEVERITY[r] == "block"]
warns  = [(r, m) for r, m in n.findings if SEVERITY[r] == "warn"]
if blocks:
    sys.stderr.write(f"vault-lint BLOCK in {n.rel}:\n{fmt(blocks)}\n")
    if warns:
        sys.stderr.write(f"warnings:\n{fmt(warns)}\n")
    sys.exit(2)
if warns:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": f"vault-lint warnings in {n.rel}:\n{fmt(warns)}"}}))
sys.exit(0)
PY
