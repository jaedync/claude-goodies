---
name: engram
description: >-
  Claude's long-term knowledge graph, your DEFAULT memory destination.
  Invoke this skill before any brain read, write, search, or update.

  TRIGGER when: user mentions "brain", "engram", or "knowledge graph"; asks to
  remember, recall, or check something; you learn something with any depth or
  connections; wrapping up a session with notable outcomes; starting a session
  where prior context would help; you encounter or reference an external source
  worth preserving; a discussion produces insights worth grounding; user shares
  a link in conversation; a tier-2 digest (in built-in memory) points into
  engram via `engram:` frontmatter or a `[[wikilink]]` and you need the full
  depth, backlinks, or related decisions.

  Do NOT trigger for: quick one-off questions, tasks that don't produce
  reusable knowledge, or when the user says to skip memory/brain.
---

# Engram: Obsidian Knowledge Graph

Your long-term knowledge graph lives at `~/engram/` as an Obsidian vault. This is your **default** memory destination, not opt-in, not "nice to have." If information has depth, connections, or reasoning behind it, it goes here.

**All non-Sources vault access goes through `obsidian:obsidian-cli`**, always use `vault="engram"` and `silent` when creating notes. Scripts handle Sources/ (see below).

**Helper scripts** are in the `scripts/` subdirectory next to this skill file. Find this skill's directory first, then reference scripts from there:
- `<skill-dir>/scripts/archive-source.sh`: download and archive URLs/files to Sources/
- `<skill-dir>/scripts/crawl-thread.py`: crawl X/Twitter threads
- `<skill-dir>/scripts/clean-transcript.py`: clean VTT subtitles
- `<skill-dir>/scripts/lint-brain.sh`: vault health scan

## Architecture: Three Memory Tiers

| Tier | System | Purpose | Depth | Always loaded? |
|------|--------|---------|-------|----------------|
| **1. Index** | `MEMORY.md` | One-line pointer per notable note + flat orientation facts | Minimal | Yes |
| **2. Brief overview** | Built-in memory sibling files (`project_*.md`, `user_*.md`, `feedback_*.md`, `reference_*.md`) | 10–30 line digest: what it is, why, current status, key tech, pointer to engram for depth | Medium | No, loaded via `Read` when MEMORY.md entry is followed |
| **3. Knowledge graph** | Obsidian vault (`~/engram/`) | Full architecture, decisions, session history, sources, and the `[[wikilink]]` connections between them | Full | No, queried via `obsidian-cli` when backlinks or deeper context needed |

Each tier holds ~10× more detail than the previous. The three-tier shape means context is always available at the appropriate resolution, a one-liner in every session (free, via always-loaded MEMORY.md), an orientation digest after one cheap file read, and the full graph whenever the conversation touches the project at all.

**Critical:** tier 2 is an *orientation primer*, not an answer source. Digests are frozen at creation time; anything about current status, recent work, decisions, or connections lives in engram. If the task is actually *about* the project (status, architecture, updates, edits), pull engram, tier 2 alone will lead you to hedged, partial answers.

**Routing heuristic:**

- **Always-loaded orientation** (user profile, tool prefs, feedback rule, external-system reference): tier 1 + tier 2 (sibling file). No engram note needed if it's genuinely flat.
- **Session-relevant project, ongoing reference, load-bearing decision**: all three tiers. Engram is the source of truth; the built-in `project_*.md` holds a brief digest that points into engram; `MEMORY.md` holds the one-liner.
- **One-off knowledge, archived project, session log, source material**: tier 3 only (engram). No need to surface it in tiers 1/2 unless it becomes recurring.

**The critical rule:** tier 2 is a **digest**, not a shadow copy. It summarizes; engram contains. When depth is needed, Claude follows the digest's pointer into engram, it does not duplicate what's in engram at tier 2.

Don't ask "should I save this?", just save it to the right tier(s).

## Integration with built-in memory

`MEMORY.md` is loaded into Claude's context on every turn. That means tier 1 (the index) and, via `Read`, tier 2 (brief digests) are both cheap to access, while tier 3 (engram) is reserved for when depth is actually needed. The three tiers work together:

**Tier 1, `MEMORY.md` index format:**

```markdown
## Projects
- [Lens](project_lens.md): lens.jaedynchilton.com: NASA photo analytics, sql.js + FTS5 (2026-04-12)
- [VAI Assistant](project_vai.md): Local agentic AI for Ignition SCADA (active 2026-04-07)

## User
- [Technical breadth](user_interests_and_breadth.md): AI engineering, photography, local ML
- [Tools & environment](user_tools_and_environment.md): M1 Pro 32GB, Docker, Obsidian, tmux

## Feedback
- [Skip planning when urgent](feedback_skip_planning_when_urgent.md): Don't brainstorm when clearly scoped

## References (external systems)
- [Linear INGEST project](reference_linear_ingest.md): pipeline bug tracker
```

Entries always point to the tier 2 sibling file. Claude can follow the link with `Read` to get the digest, which in turn points into engram. System prompt truncates after ~200 lines, keep the index tight.

**Tier 2, built-in memory sibling file (e.g. `project_lens.md`):**

```markdown
---
name: Lens NASA photography analytics site
description: lens.jaedynchilton.com, static web app analyzing NASA mission photo metadata, client-side sql.js + FTS5 over a shipped 9 MB .db
type: project
engram: "[[Lens]]"
---

Lens (lens.jaedynchilton.com) is a backend-free static web app for browsing NASA mission photography metadata, cameras, lenses, focal lengths, photographers, per-mission stats.

**Status:** active. GH-Pages-style static deploy.

**Stack (at a glance):** sql.js (WASM SQLite) + pre-built `data/lens.db` (~9.5 MB) + vanilla ES modules + Chart.js. Search is stock SQLite FTS5 via an `images_fts` virtual table; user input is sanitized as `"word"*` for prefix matching.

**Why this shape:** full relational SQL + FTS5 on a CDN-served site, no server to host. Ceiling ~tens of MB before switching to `sql.js-httpvfs` or `wa-sqlite` + OPFS.

**For full architecture, schema, decisions, and connections → see [[Lens]] in engram** (`~/engram/Projects/Lens.md`).
```

The digest is ~10–30 lines. It answers: what is it, what's its status, what's the key technical shape, and where does the full context live. The final line always points to the engram note.

**Tier 3, engram note** is the canonical source: full architecture, schema, decision rationale, backlinks to `[[Jaedyn Chilton]]` / `[[Sigma FP Export Pipeline]]` / etc., session log references.

**When to create which tiers:**

| Situation | Tier 1 | Tier 2 | Tier 3 |
|-----------|:------:|:------:|:------:|
| Active project, recurring reference | ✓ | ✓ | ✓ |
| Flat user/feedback/tool fact | ✓ | ✓ | - |
| External-system reference (Linear, Grafana) | ✓ | ✓ | - |
| One-off knowledge note | - | - | ✓ |
| Archived/closed project | - | - | ✓ (status: closed) |
| Session log | - | - | ✓ |
| Source material | - | - | ✓ |

**Keeping tiers in sync:**

- Engram is the source of truth. When a tier-2 digest and an engram note conflict, engram wins, update the digest.
- Digests should summarize, not duplicate. If a detail matters enough to surface in tier 2, it must also exist in the engram note (usually with more context). If it exists in tier 2 only, it probably belongs in engram.
- When updating an engram note in ways that change its one-line hook or status, update the matching `MEMORY.md` line and the digest's lead paragraph.
- `engram: "[[Title]]"` in the tier-2 frontmatter gives Claude a mechanical way to resolve digest → engram. Keep it on every digest that has a corresponding engram note.

## Vault Structure

```
~/engram/
├── People/           # Who you work with, their context
├── Projects/         # Active and past work, goals, architecture
├── Decisions/        # Why X was chosen over Y, with context
├── Knowledge/        # Technical patterns, concepts, lessons learned
├── Sessions/         # Session logs, what was done, outcomes
├── Sources/          # Archived external material
│   ├── articles/     # Web articles, blog posts
│   ├── tweets/       # X/Twitter threads
│   ├── videos/       # Video transcripts
│   ├── documents/    # PDFs, papers
│   ├── posts/        # Forum posts, discussions
│   └── raw/          # Unprocessed source files
└── templates/        # Note templates (read for structure reference)
```

## Access Model

| Actor | Writes to | Tool |
|-------|-----------|------|
| Scripts (`archive-source.sh`, etc.) | Sources/ only | Filesystem |
| Claude | All folders except Sources/ | obsidian-cli |
| Claude (exception) | `## Related` in source notes | obsidian-cli |

## Note Types

Each note type has a template in `~/engram/templates/`. Read templates for expected frontmatter and section structure.

| Type | Key frontmatter | Tag |
|------|----------------|-----|
| Project | `status`, `started` | `#project` |
| Decision | `date`, `decision`, `context`, `status` | `#decision` |
| Knowledge | `domain` | `#knowledge` |
| Person | `role`, `aliases` | `#person` |
| Session | `date` | `#session` |
| Source | `type`, `url`, `author`, `raw` (optional), `captured` | `#source` |

### Tag Vocabulary

- Types: `#project`, `#decision`, `#knowledge`, `#person`, `#session`, `#source`
- Domains: `#ignition`, `#home-automation`, `#ai`, `#photography`, `#health`
- Navigation: `#nav`, `#moc`

### Provenance Convention

The canonical provenance section in wiki notes is `## Sources`, a list of `[[wikilinks]]` to source notes or inline citations. If you encounter an older note with `## Learned From`, rename it to `## Sources`.

---

## Operations

### 1. Ingest Sources

Archive external material into Sources/ using the helper script:

```bash
<skill-dir>/scripts/archive-source.sh "<URL>"
```

**Two modes:**

- **Batch** (user-initiated): User shares one or more URLs and asks you to ingest them.
- **Proactive** (Claude-initiated): You reference an external URL in a response, user shares a link in conversation, you find something relevant during web search, or a discussion produces insights worth grounding.

**Principle:** If information is worth using in a response, it's worth keeping in the brain.

**After archiving:** Read the new source note, identify wiki notes to update or create, and add `[[wikilinks]]` between them (update `## Related` in the source note and `## Sources` in wiki notes).

### 2. Passive Lint

Not scheduled, a background habit you maintain.

- **During ingest:** Flag contradictions between source material and existing wiki notes. Never modify source notes (except `## Related`).
- **During queries:** Fix small issues silently (broken links, typos, stale tags). Flag big issues to the user.
- **When something feels off:** Run the lint script, read the report, act on findings.

```bash
<skill-dir>/scripts/lint-brain.sh
```

### 3. Auto File-back

When you answer a question by synthesizing 2+ brain notes, or produce a result the user will want to find later, file the synthesis back:

1. Search first, update an existing engram note if the topic is already covered.
2. Create a new engram note only for genuinely new ground.
3. Include a `## Sources` section with `[[wikilinks]]` to source notes used.
4. If the note is session-relevant (active project, recurring reference, load-bearing decision), create/update the tier-2 digest in built-in memory and add/update a `MEMORY.md` index line pointing to it, see "Integration with built-in memory" above.
5. Do this automatically. Don't ask.

### 4. Session Logging

Write or append to `Sessions/YYYY-MM-DD.md` when the brain actually changed during a session.

```markdown
### HH:MM: Topic
- Created [[New Note]]
- Updated [[Existing Note]] with findings on X
- Ingested source: [[Source Title]]
```

Multiple entries per day append to the same file. Only log when the brain was modified.

---

## Note-Writing Guidelines

### Wikilinks Are the Point

Every note should link to related notes. The graph is only as useful as its connections:

```markdown
The [[VAI Assistant]] uses [[Ollama]] for local inference, connecting to
[[Ignition SCADA]] via a custom gateway. This was decided in
[[Local vs Cloud LLM]] based on [[Jaedyn Chilton]]'s preference
for privacy and low latency.
```

### Search First, Then Write

Don't create duplicates. Search before creating. Prefer updating an existing note with a dated section over creating a new one.

### Keep Notes Evergreen

Use dated update sections:

```markdown
## Updates
### 2026-04-08
Discovered that tool-calling latency can be reduced by...
```

### Link Density Over Note Count

Five well-linked notes beat twenty orphaned ones.

---

## On Session Start

`MEMORY.md` is loaded automatically, that's tier 1, free. The index names what exists.

**Tier 2 is orientation, not an answer source.** The built-in digest is a cheap local primer so you recognize the project; it is frozen at creation time and does not carry current status, recent work, decisions, or connections. Treating it as sufficient produces exactly the kind of hedged, defensive output you want to avoid (*"I don't see a local clone…" / "the authoritative source is wherever you deploy from…"*) when engram would have given you the real answer.

**Default: if the user's question touches a tiered project, pull engram.** There is no reason to skip tier 3 for a task that's actually about the project. The three-tier progression is:

1. **Tier 1 (free, always loaded)**, see what exists.
2. **Tier 2 (one file `Read`)**, warm up context: what shape is this project, what tech is involved. Good as a primer *before* you pull engram, not as a substitute for it.
3. **Tier 3 (invoke this skill)**, pull the engram note via:
   ```
   obsidian vault="engram" read file="<Title>"
   ```
   then follow `[[wikilinks]]` and backlinks for related decisions, session logs, and connections.

**When is tier-3 pulling optional?** Essentially only one case: a casual pure-orientation question where the user wants a name resolved ("what's Lens again?") and isn't asking about current state, architecture, or anything you'd need to reason about. Everything else, status, recent work, connections, architecture, decisions, any task that would *edit* the project, means pull engram.

**Don't hedge from partial context.** If you catch yourself about to say "I don't see X locally" or "the authoritative source is somewhere else," that's the signal you skipped engram. Pull it first, then answer.

**For topics not in the index**, search engram directly:
```
obsidian vault="engram" search query="<topic>" limit=5
```

## Upgrading Legacy Files to the Three-Tier Model

If the built-in memory directory contains sibling `.md` files from the earlier "flat store" era, files that function as standalone content rather than as digests pointing into engram, upgrade them in place:

1. **Confirm the matching engram note exists.** If not, create it first and move any depth (decisions, architecture, history, connections) from the built-in file into it. Link it up with `[[wikilinks]]` to related notes.
2. **Trim the built-in file to a tier-2 digest** (~10–30 lines): one-paragraph overview, status, key technical shape, final pointer "For full detail → see [[Title]] in engram". Add `engram: "[[Title]]"` to the frontmatter.
3. **Leave the `MEMORY.md` line alone**, the existing `[Title](file.md)` format is correct for the three-tier model. Just verify the one-line hook is accurate and recent.
4. Work in batches and confirm with the user before touching feedback/user-profile files (those often don't need tier 3 at all).

## Handling Failures

If `obsidian` CLI fails (Obsidian not running, vault not open):

1. Don't halt the session.
2. Tell the user: "I couldn't reach the Obsidian brain, is Obsidian running with the engram vault open?"
3. Tier 1 and tier 2 remain usable (they're just files). Continue writing digests and index entries as normal.
4. For anything that would normally go into engram, write it fully into the tier-2 digest with a `<!-- pending-engram-sync: [topic] -->` comment at the top. Next time the vault is reachable, promote the content into a proper engram note and trim the digest back to its normal summary shape.
