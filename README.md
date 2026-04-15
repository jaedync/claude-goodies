# claude-goodies

Jaedyn's personal [Claude Code](https://docs.claude.com/en/docs/claude-code) plugin marketplace. A grab-bag of skills and tools I've built and want to sync across my own machines. Public because there's no reason not to be.

## Install

```bash
/plugin marketplace add jaedync/claude-goodies
```

Then install whichever plugins you want:

```bash
/plugin install engram@claude-goodies
/plugin install caldera-mcp@claude-goodies
```

## Plugins

| Plugin | What it does |
|--------|--------------|
| [`engram`](./plugins/engram) | Obsidian-backed long-term knowledge graph and memory system for Claude |
| [`caldera-mcp`](./plugins/caldera-mcp) | Ignition SCADA development skills + MCP tools via [Caldera](https://github.com/caldera-mcp/caldera-mcp) |

## Also in this repo

- [`desktop-extension/`](./desktop-extension): Claude Desktop (`.mcpb`) build of the Caldera MCP tools for folks who don't use Claude Code. Releases are published as a `.mcpb` bundle.

## License

MIT
