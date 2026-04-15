# engram

A Claude Code skill that turns an Obsidian vault into a long-term knowledge graph. Brain-first memory that compounds over time, with source archival and automated maintenance.

## What it does

- **Brain-first memory**: Claude's built-in memory handles quick recall; the Obsidian vault holds the knowledge graph: projects, decisions, patterns, people, sources, and the connections between them.
- **Source archival**: save articles, tweets, videos, PDFs, and posts as permanent notes with raw content preserved alongside clean markdown.
- **Compounding knowledge**: every session adds context. Backlinks, tags, and templates keep the graph navigable as it grows.
- **Automated maintenance**: passive lint catches structural issues; file-back keeps notes on disk in sync with vault state.

## Setup

### 1. Install the skill

```bash
cp -r skills/engram ~/.claude/skills/learned/engram
```

### 2. Create the vault

```bash
mkdir -p ~/engram/{People,Projects,Decisions,Knowledge,Sessions,templates,attachments}
mkdir -p ~/engram/Sources/{articles,tweets,videos,documents,posts,raw}
cp skills/engram/templates/*.md ~/engram/templates/
```

### 3. Open in Obsidian

Open Obsidian → "Open folder as vault" → select `~/engram/`

### 4. Install dependencies

The `obsidian:obsidian-cli` skill for vault operations.

Archive script dependencies (all via Homebrew):

```bash
brew install defuddle yt-dlp pandoc poppler jq
```

(`poppler` provides `pdftotext`)

## Vault structure

```
~/engram/
├── _Index.md              # Map of Content, entry point
├── People/                # Who you work with
├── Projects/              # Active and past work
├── Decisions/             # Why X was chosen over Y
├── Knowledge/             # Technical patterns, lessons learned
├── Sessions/              # Session logs
├── Sources/               # Archived external content
│   ├── articles/
│   ├── tweets/
│   ├── videos/
│   ├── documents/
│   ├── posts/
│   └── raw/               # Original downloaded files
└── templates/             # Note templates for each type
```

## Note types

| Type | Folder | Key frontmatter |
|------|--------|-----------------|
| Source | Sources/*/ | `type`, `url`, `author`, `raw`, `captured` |
| Person | People/ | `role`, `aliases` |
| Project | Projects/ | `status`, `started` |
| Decision | Decisions/ | `date`, `decision`, `context`, `status` |
| Knowledge | Knowledge/ | `domain` |
| Session | Sessions/ | `date` |

## Scripts

| Script | Purpose |
|--------|---------|
| `archive-source.sh <url>` | Download and archive any source |
| `crawl-thread.py <tweet-url>` | Crawl X/Twitter threads via fxtwitter API |
| `clean-transcript.py <vtt-file>` | Clean VTT subtitles to plain text |
| `lint-brain.sh [vault-path]` | Vault health scan |

## Requirements

- [Obsidian](https://obsidian.md) running with vault open
- Obsidian CLI (`obsidian` command available in terminal)
- Claude Code with the `obsidian:obsidian-cli` skill installed
- `defuddle`, `yt-dlp`, `pandoc`, `pdftotext`, `jq` (see Setup)

## Credits

Inspired by Andrej Karpathy's [notes on a personal LLM knowledge base](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f): a three-layer raw, wiki, schema pattern for compounding knowledge. Engram adapts that approach on top of Obsidian so the graph syncs across devices and stays browsable outside of Claude.
