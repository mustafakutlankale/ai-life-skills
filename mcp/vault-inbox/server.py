#!/usr/bin/env python3
"""vault-inbox — a narrow MCP gate from Claude Desktop chat into an Obsidian vault.

Chat can WRITE to exactly one place (the inbox folder) and READ anywhere in the
vault. Everything captured is later triaged by a Claude Code session into its
proper folder (decisions, project backlogs, references). Nothing here calls a
model; it is file I/O plus the vault-lint hook.

Run:  VAULT_ROOT=/path/to/vault python server.py         (stdio transport)
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from mcp.server.mcpserver import MCPServer

VAULT = Path(os.environ.get("VAULT_ROOT", "")).expanduser().resolve()
INBOX_DIR = os.environ.get("INBOX_DIR", "00 Inbox")
LINT = Path(os.environ.get("VAULT_LINT", "~/.claude/hooks/vault-lint.sh")).expanduser()
EXCLUDE_DIRS = {".obsidian", ".trash", ".Trash", ".git", "_Attachments", "node_modules", ".claude"}
KINDS = ("thought", "decision", "idea", "question")

if not VAULT.is_dir() or not (VAULT / ".obsidian").is_dir():
    sys.exit(f"vault-inbox: VAULT_ROOT is not an Obsidian vault: {VAULT}")

server = MCPServer(
    name="vault-inbox",
    instructions=(
        "Second-brain gate. Use `capture` whenever the user states a decision, a "
        "reusable idea, a thought worth keeping, or an open question — do not wait "
        "to be told to save. Use `recall` before answering questions about the "
        "user's projects, people, past decisions or notes; cite the path. "
        "`read_memory` tells you how this user works. Write only through `capture`."
    ),
)


# --------------------------------------------------------------------------- helpers
def _safe_rel(path: str) -> Path:
    p = (VAULT / path).resolve()
    if VAULT not in p.parents and p != VAULT:
        raise ValueError("path escapes the vault")
    return p


def _slug(title: str) -> str:
    t = re.sub(r"[\\/:*?\"<>|#^\[\]]", " ", title).strip()
    t = re.sub(r"\s+", " ", t)
    return t[:80] or "untitled"


def _lint(path: Path) -> dict:
    if not LINT.is_file():
        return {"lint": "not installed"}
    payload = json.dumps({"tool_input": {"file_path": str(path)}})
    r = subprocess.run([str(LINT)], input=payload, text=True, capture_output=True, timeout=30)
    if r.returncode == 2:
        return {"lint": "block", "detail": r.stderr.strip()}
    if r.stdout.strip():
        try:
            ctx = json.loads(r.stdout)["hookSpecificOutput"]["additionalContext"]
            return {"lint": "warn", "detail": ctx}
        except Exception:
            pass
    return {"lint": "clean"}


def _walk_md():
    for root, dirs, files in os.walk(VAULT):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for f in files:
            if f.endswith(".md"):
                yield Path(root) / f


# --------------------------------------------------------------------------- tools
@server.tool()
def capture(kind: str, title: str, body: str, project: str = "", tags: list[str] | None = None) -> dict:
    """Save a thought, decision, idea or question from this chat into the vault inbox.

    kind: one of thought | decision | idea | question.
    title: short, specific — becomes the filename.
    body: the substance, in the user's words where possible; include the reasoning
          for a decision and the alternatives that were considered.
    project: optional project name if it belongs to one.
    The note lands in the inbox with status: new; a later Claude Code session files it.
    """
    if kind not in KINDS:
        return {"error": f"kind must be one of {KINDS}"}
    now = datetime.now()
    inbox = VAULT / INBOX_DIR
    inbox.mkdir(parents=True, exist_ok=True)
    name = f"{now:%Y-%m-%d} {_slug(title)}"
    path = inbox / f"{name}.md"
    i = 2
    while path.exists():
        path = inbox / f"{name} ({i}).md"
        i += 1
    tag_yaml = "".join(f"\n  - {re.sub(r'[^A-Za-z0-9_-]', '-', t)}" for t in (tags or []))
    fm = (
        "---\n"
        f"created: {now:%Y-%m-%dT%H:%M}\n"
        f"updated: {now:%Y-%m-%dT%H:%M}\n"
        "type: inbox\n"
        f"kind: {kind}\n"
        "source: claude-chat\n"
        f"project: {project}\n"
        "status: new\n"
        f"tags:{tag_yaml or ' []'}\n"
        "unread: true\n"
        "---\n"
    )
    path.write_text(fm + body.strip() + "\n", encoding="utf-8")
    result = {"saved": str(path.relative_to(VAULT))}
    result.update(_lint(path))
    return result


@server.tool()
def recall(query: str, limit: int = 8, folder: str = "") -> list[dict]:
    """Full-text search across the vault. Returns matching notes with a snippet.

    query: words to look for (case-insensitive, all words must appear in the note).
    folder: optional vault-relative folder to restrict to, e.g. "09 Decisions".
    """
    words = [w.lower() for w in query.split() if w.strip()]
    if not words:
        return []
    base = _safe_rel(folder) if folder else VAULT
    hits = []
    for p in _walk_md():
        if base != VAULT and base not in p.parents:
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        low = text.lower()
        if not all(w in low for w in words):
            continue
        idx = low.find(words[0])
        start = max(0, idx - 120)
        snippet = text[start : idx + 200].replace("\n", " ").strip()
        score = sum(low.count(w) for w in words)
        hits.append({"path": str(p.relative_to(VAULT)), "score": score, "snippet": snippet})
    hits.sort(key=lambda h: -h["score"])
    return hits[: max(1, min(limit, 25))]


@server.tool()
def read_note(path: str, max_chars: int = 12000) -> str:
    """Read one vault note by vault-relative path (as returned by recall)."""
    p = _safe_rel(path)
    if p.suffix != ".md" or not p.is_file():
        return f"not a note: {path}"
    text = p.read_text(encoding="utf-8", errors="replace")
    return text if len(text) <= max_chars else text[:max_chars] + f"\n\n[... truncated, {len(text)} chars total]"


@server.tool()
def read_memory() -> str:
    """How this user works: the vault's memory index plus every memory file (short)."""
    mem = VAULT / "_Memory"
    if not mem.is_dir():
        return "no _Memory/ in this vault"
    out = []
    idx = mem / "MEMORY.md"
    if idx.is_file():
        out.append("# MEMORY.md\n" + idx.read_text(encoding="utf-8"))
    for f in sorted(mem.glob("*.md")):
        if f.name == "MEMORY.md":
            continue
        out.append(f"# {f.stem}\n" + f.read_text(encoding="utf-8"))
    return "\n\n".join(out)


@server.tool()
def list_inbox() -> list[dict]:
    """Items waiting in the inbox (not yet filed by a Claude Code session)."""
    inbox = VAULT / INBOX_DIR
    if not inbox.is_dir():
        return []
    items = []
    for p in sorted(inbox.glob("*.md")):
        head = p.read_text(encoding="utf-8", errors="replace")[:600]
        kind = re.search(r"^kind: (.*)$", head, re.M)
        status = re.search(r"^status: (.*)$", head, re.M)
        items.append({"path": str(p.relative_to(VAULT)), "kind": kind.group(1) if kind else "?",
                      "status": status.group(1) if status else "?"})
    return items


if __name__ == "__main__":
    server.run("stdio")
