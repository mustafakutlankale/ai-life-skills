#!/bin/bash
# session-start.sh — SessionStart hook for an Obsidian vault used as a second brain.
#
# Prints a short orientation block to stdout (SessionStart stdout is added to
# Claude's context): decisions awaiting review, open backlog items per project,
# and the tail of the most recent daily note. No model calls, no writes.
#
# Wire in <vault>/.claude/settings.local.json:
#   {"hooks":{"SessionStart":[{"hooks":[{"type":"command",
#     "command":"\"$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh\"","timeout":10}]}]}}
#
# Folder names follow the summarize skill's defaults; override via env if yours differ.

set -u
VAULT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -d "$VAULT/.obsidian" ] || exit 0
DECISIONS_DIR="${DECISIONS_DIR:-09 Decisions}"
PROJECTS_DIR="${PROJECTS_DIR:-05 Projects}"
DAILY_DIR="${DAILY_DIR:-02 Daily}"

out=""

# 0. Inbox items captured from chat and not yet filed (status: new)
INBOX_DIR="${INBOX_DIR:-00 Inbox}"
if [ -d "$VAULT/$INBOX_DIR" ]; then
  new_items=$(grep -l '^status: new' "$VAULT/$INBOX_DIR"/*.md 2>/dev/null)
  n=$(printf '%s\n' "$new_items" | grep -c . 2>/dev/null)
  if [ "$n" -gt 0 ]; then
    out+="Inbox — dosyalanmamış $n kayıt ($INBOX_DIR/), önce bunları yerine koy:"$'\n'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      kind=$(sed -n 's/^kind: *//p' "$f" | head -1)
      out+="  - [$kind] $(basename "$f" .md)"$'\n'
    done <<< "$new_items"
  fi
fi

# 1. Decisions awaiting review (status: proposed)
if [ -d "$VAULT/$DECISIONS_DIR" ]; then
  pending=$(grep -l '^status: proposed' "$VAULT/$DECISIONS_DIR"/*.md 2>/dev/null)
  n=$(printf '%s\n' "$pending" | grep -c . 2>/dev/null)
  if [ "$n" -gt 0 ]; then
    out+="Onay bekleyen kararlar ($n) — $DECISIONS_DIR/:"$'\n'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      title=$(basename "$f" .md)
      by=$(sed -n 's/^decided_by: *//p' "$f" | head -1)
      out+="  - $title (${by:-?})"$'\n'
    done <<< "$pending"
  fi
fi

# 2. Open backlog items per project
if [ -d "$VAULT/$PROJECTS_DIR" ]; then
  for b in "$VAULT/$PROJECTS_DIR"/*/backlog.md; do
    [ -f "$b" ] || continue
    proj=$(basename "$(dirname "$b")")
    open=$(sed -n '/^## open/,/^## done/p' "$b" | grep -c '^- \[ \]' || echo 0)
    [ "$open" -gt 0 ] && out+="Backlog $proj: $open açık madde"$'\n'
  done
fi

# 3. Tail of the most recent daily note (today, else newest file)
latest=""
today=$(date '+%m-%d-%y')
latest=$(ls "$VAULT/$DAILY_DIR"/*/*/"$today"*.md 2>/dev/null | head -1)
[ -n "$latest" ] || latest=$(ls -t "$VAULT/$DAILY_DIR"/*/*/*.md 2>/dev/null | head -1)
if [ -n "$latest" ]; then
  todo=$(sed -n '/^## TODO for next session/,$p' "$latest" | sed -n '2,12p' | grep -v '^$')
  out+="Son daily note: $(basename "$latest" .md)"$'\n'
  [ -n "$todo" ] && out+="$todo"$'\n'
fi

[ -n "$out" ] && printf '[vault] Oturum başı durum\n%s' "$out"
exit 0
