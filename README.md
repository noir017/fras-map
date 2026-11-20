# fras-map

A zero-dependency, Git-versioned **two-tier FRAS (Function / Relations / API / Semantics)** codebase map for coding agents (Claude Code, Codex, Antigravity, OpenCode, Cursor, etc.).

Inspired by the FRAS entry format from [aoci-code](https://github.com/aoci-spec/aoci-code), designed as a lightweight, non-invasive specification and CI validator without requiring an MCP server or runtime dependencies.

## Why Two-Tier FRAS?

- **L1 (`AGENTS.md` -> ` ```fras `)**: Module-level map placed directly in `AGENTS.md`, automatically injected into the agent's context by all major harnesses without extra tool calls. Kept under 50 lines.
- **L2 (`*.fras`)**: File-level FRAS entries loaded on-demand per task. Kept under 80 lines per file and sorted alphabetically.
- **Flexible L2 Placement**: Default to `docs/fras/<module>.fras`, or place `.fras` directly in module directories next to existing module `README.md` files.
- **Coexistence with Existing Docs**: When a module already has an architectural README, do not rewrite it; L2 entries only record file-level relations (`R:`) and semantic invariants (`S:`) absent from the documentation.
- **API & Test Invariant Verification**: Public entrypoints in `A:` and test tags in `S:` (`[T:<test_name>]`) are strictly verified against actual source code and test declarations.

## When NOT to Use FRAS

- Small repositories (< 20,000 LOC) where the full codebase easily fits in standard agent context windows.
- Forks, upstream mirrors, or third-party vendored repositories where maintenance overhead exceeds value.

## Division of Responsibility: FRAS vs Hindsight

- **FRAS**: Tracks **what holds in the code right now** (contracts, file dependencies, cross-cutting invariants, verified by tests). Branch- and commit-scoped.
- **Hindsight**: Tracks **why decisions were made**, historical context, environment quirks, and team preferences across sessions.

---

## Continuous Integration (CI)

`fras-map` provides a composite GitHub / Gitea Action to enforce FRAS integrity on every push and pull request.

### GitHub Actions (`.github/workflows/fras.yml`)

```yaml
name: FRAS Map Check

on:
  push:
    branches: [main]
  pull_request:

jobs:
  fras-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Validate FRAS Map
        uses: noir017/fras-map@v1
        with:
          base: ${{ github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.event.before }}
          stale: 'false'
```

### Gitea Actions

In Gitea Actions, specify the full URL to the action repository:

```yaml
      - name: Validate FRAS Map
        uses: https://github.com/noir017/fras-map@v1
        with:
          base: ${{ github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.event.before }}
```

### Checks Enforced

- **Hard Errors (Exit code 1)**:
  - Malformed L1 or L2 syntax.
  - L1 target file missing.
  - L2 path or glob matching zero git-tracked files.
  - L2 `R:` path target does not exist.
  - `A:` API symbols not found in matched files (via literal `git grep -w -F`).
  - Line limits exceeded (L1 > 50 lines, L2 > 80 lines).
  - Test references `[T:<test_name>]` not matching test declarations (`func Name(`, `describe/it/test('Name'`, `def name`).
  - Private IP ranges (`10.x`, `172.16-31.x`, `192.168.x`) or private hostnames (`.lan`, `.local`, `.internal`, including comments and multi-level subdomains).
- **Diff Warnings**:
  - Emits annotations when a source file is modified in the git diff but its corresponding `.fras` file was left untouched.
- **Staleness Report (`stale: 'true'` or `--stale`)**:
  - Reports `.fras` entries whose target files/globs have had multiple git commits since the FRAS line was last updated.

---

## Local Usage

Run the validator directly in the root of any git repository:

```bash
# Basic check
sh skills/fras-map/scripts/fras-check.sh

# Check with diff warnings against base branch
sh skills/fras-map/scripts/fras-check.sh --base origin/main

# Run with staleness report
sh skills/fras-map/scripts/fras-check.sh --stale
```

## License

MIT
