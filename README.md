# fras-map

A zero-dependency, pure-Skill implementation of a **two-tier FRAS (Function / Relations / API / Semantics)** codebase map for coding agents (Claude Code, Codex, OpenCode, Cursor, etc.).

Inspired by the FRAS entry format from [aoci-code](https://github.com/aoci-spec/aoci-code), extracted into a lightweight, non-invasive Git-versioned workflow without requiring an MCP server or external binary.

## Why Two-Tier FRAS?

- **L1 (`docs/fras/INDEX.fras`)**: Module-level map loaded at the start of a session.
- **L2 (`docs/fras/<module>.fras`)**: File-level FRAS entries loaded on demand per task.
- **Low token overhead & low merge conflicts**: Only core files are indexed, split by module, and synced incrementally via `git diff`.

## Repository Structure

```text
fras-map/
├── README.md
├── LICENSE
└── skills/
    └── fras-map/
        └── SKILL.md
```

## Installation

Copy `skills/fras-map/` into your agent's skills directory:

- **Claude Code (project)**: `.claude/skills/fras-map/SKILL.md`
- **Claude Code (global)**: `~/.claude/skills/fras-map/SKILL.md`
- **Codex / OpenCode / Generic**: `.agents/skills/fras-map/SKILL.md`

Or install via the Skills CLI:

```bash
npx skills add noir017/fras-map
```

## Usage

- **Bootstrap a repo**: Ask your agent to *"Use the fras-map skill to bootstrap the layered FRAS map for this repository."*
- **Sync after changes**: Ask your agent to *"Sync the FRAS map for my current git diff."*

## License

MIT
