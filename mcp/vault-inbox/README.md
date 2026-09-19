# vault-inbox — MCP gate from Claude Desktop chat into the vault

Chat conversations don't run hooks, so nothing said there reaches the second brain
on its own. This tiny MCP server gives Claude Desktop (chat) a **narrow** door:

| tool | does |
|---|---|
| `capture(kind, title, body, project?, tags?)` | writes one note to `00 Inbox/` (`kind`: thought / decision / idea / question, `status: new`), runs `vault-lint` on it |
| `recall(query, limit?, folder?)` | full-text search over the vault (all words must match), returns path + snippet |
| `read_note(path)` | reads one note; paths are confined to the vault |
| `read_memory()` | returns `_Memory/` so chat knows how you work |
| `list_inbox()` | what's waiting to be filed |

Chat can write **only** through `capture`. A Claude Code session files inbox items
into their real home (decisions → `09 Decisions/`, ideas → project backlog,
concepts → `07 References/`) — see the vault's CLAUDE.md "Triage the inbox" rule
and `hooks/session-start.sh`, which lists unfiled items at session start.

## Install

```bash
cd mcp/vault-inbox
python3 -m venv .venv && .venv/bin/pip install mcp        # mcp 2.x, Python ≥ 3.10
```

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`
(Windows: `%APPDATA%\Claude\claude_desktop_config.json`) and restart Claude Desktop:

```json
{
  "mcpServers": {
    "vault-inbox": {
      "command": "/abs/path/to/mcp/vault-inbox/.venv/bin/python",
      "args": ["/abs/path/to/mcp/vault-inbox/server.py"],
      "env": { "VAULT_ROOT": "/abs/path/to/your/vault" }
    }
  }
}
```

Optional env: `INBOX_DIR` (default `00 Inbox`), `VAULT_LINT` (default `~/.claude/hooks/vault-lint.sh`).

## Tell chat when to use it

Paste into your Claude.ai profile preferences or a Project's instructions:

> I keep a second brain in an Obsidian vault reachable through the `vault-inbox` tools.
> Whenever I state a decision, a reusable idea, a thought worth keeping, or an open
> question, call `capture` without being asked — decisions with the reasoning and the
> alternatives. Before answering anything about my projects, people or past decisions,
> call `recall` and cite the note path. Call `read_memory` once at the start of a
> conversation about my work.

## Test without Claude Desktop

```bash
VAULT_ROOT=/abs/vault .venv/bin/python -c "
import asyncio,os
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
async def m():
    async with stdio_client(StdioServerParameters(command='.venv/bin/python',args=['server.py'],env=dict(os.environ))) as (r,w):
        async with ClientSession(r,w) as s:
            await s.initialize(); print([t.name for t in (await s.list_tools()).tools])
asyncio.run(m())"
```
