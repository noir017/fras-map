---
name: fras-map
description: Maintain a lightweight, Git-versioned, two-tier FRAS (Function/Relations/API/Semantics) codebase map for coding agents. Use when bootstrapping a repository index, orienting in an unfamiliar codebase, or syncing the map after code changes via git diff.
---

# FRAS Layered Codebase Map (v1)

A zero-dependency, Git-versioned architectural map for coding agents using a **two-tier (L1 + L2) FRAS layout** (Function, Relations, API, Semantics).

## 1. Architecture Overview

- **L1 (Module-level, inside `AGENTS.md`)**: Automatically loaded by coding agent harnesses (Claude Code, Codex, Antigravity, OpenCode, etc.) at session start. Kept strictly under 50 lines.
- **L2 (File-level `*.fras` files)**: Loaded on-demand per task. Each file is under 80 lines and sorted alphabetically by path.
  - Placement: Default to `docs/fras/<module>.fras`. In repositories with existing module READMEs, place `.fras` alongside the README in the module directory.
  - Coexistence: If a module already has an architectural README, do not duplicate its description; L2 only records cross-file couplings (`R:`) and invariants (`S:`) missing from the README.

### Division of Responsibility: FRAS vs Hindsight
- **FRAS**: Tracks **current verifiable constraints** that hold in the code right now. Versioned with Git alongside source code.
- **Hindsight / Memory**: Tracks **why** decisions were made, project history, deployment runbooks, and environment facts.

### When NOT to Use FRAS
- Small codebases (< 20,000 LOC): agent context windows handle the whole tree directly.
- Forks, upstream mirrors, or third-party vendored code.

---

## 2. Syntax Specifications

### Path & Pattern Rules
- Paths and globs **must NOT contain whitespace**.
- In glob patterns, `*` matches across directory boundaries (matching subdirectories recursively in Git pathspec).
- Extensionless filenames ending in `.local` (e.g. `app/env.local`) are treated as private hostnames by the checker. To prevent false positives, use extensions (e.g. `.local.env`, `.local.json`) or avoid referencing extensionless `.local` paths directly in `.fras` lines.

### L1 (`AGENTS.md` under `## Codebase Map (FRAS)`)
Place entries in a single ````fras` block (max 50 lines):

```text
[<module>] -> <l2_file_path> | F:<responsibility> | R:<coupled_modules> | A:<entrypoints> | S:<cross_module_invariants>
```
- `R:`, `A:`, `S:` may be omitted if empty.
- Never use ` | ` inside field contents.
- Every symbol in `A:` is verified via `git grep -w -F` across all files registered in `<l2_file_path>` (verifying literal occurrence, not code declaration, so routes, table names, and CLI commands remain valid).

Example:
```fras
[billing] -> docs/fras/billing.fras | F:Subscription charges and invoices | R:auth,db | A:CreateInvoice,WebhookHandler | S:Mutations require idempotency keys
[auth] -> docs/fras/auth.fras | F:JWT issue and token verification | A:VerifyToken,IssueToken | S:Stateless verification; never touch database in hot path
```

### L2 (`*.fras` files)
Each non-comment line represents an indexed core file (max 80 lines per file):

```text
<repo_relative_path_or_glob> [Core|Infra|Edge]: F:<responsibility> | R:<paths,comma-separated> | A:<apis> | S:<non-obvious invariants>
```
- **Tiers**: `[Core]` (business logic / state machine), `[Infra]` (shared plumbing / db / storage), `[Edge]` (API handlers / CLI / webhooks).
- **API entrypoints `A:`**: Every comma-separated symbol in `A:` must appear in the target files matched by the entry via literal `git grep -w -F`. Checks literal occurrence rather than formal declaration to accommodate routes, table names, and commands without false positives.
- **Test linking `[T:<test_func>]`**: Put `[T:]` only in `S:` when a semantic invariant is guarded by tests. The reference must match a test declaration located in test files (`*_test.go`, `*.test.*`, `*.spec.*`, `test_*.py`, `*_test.py`, `test/`, `tests/`, `__tests__/`), supporting Go standalone functions and receiver methods, JS/TS `describe/it/test` (with quotes, backticks, `.skip`, `.only`, `.each`), and Python functions/methods.
- Lines starting with `#` are comments.
- Sort entries alphabetically by file path.

Example:
```fras
# Core billing logic
src/billing/charge.py [Core]: F:Credit card charge workflow | R:src/billing/gateway.py | A:charge_customer | S:Must lock customer ledger before charge [T:test_charge_lock_order]
src/billing/gateway.py [Infra]: F:Payment processor client | A:send_payment | S:Network timeout strictly capped at 5s [T:test_gateway_timeout]
src/billing/models/*.py [Infra]: F:ORM models for invoices and subscriptions
```

---

## 3. Scope Filtering (Anti-Bloat Rules)

- **Index individually (L2)**: Core business logic, state machines, public entrypoints, shared infrastructure, critical configuration.
- **Index by glob (single line)**: Repetitive files such as DTOs, pure schemas, or auto-generated boilerplate.
- **Do NOT index**: Unit/integration tests, build artifacts, generated code, lockfiles, temporary files.

---

## 4. Maintenance Workflows

### Bootstrap
1. Group core directories into modules.
2. Create `.fras` files for each module (under 80 lines each, alphabetized).
3. Insert the `## Codebase Map (FRAS)` section with the ````fras` block into `AGENTS.md`.
4. Validate with `sh <path>/fras-check.sh`.

### Incremental Sync via Git Diff
1. Inspect modified files: `git diff --name-only <base>..HEAD`.
2. Update existing `.fras` entries if F, R, A, or S changed.
3. If new core files were introduced, add corresponding entries.
4. Run `fras-check.sh --base <base>` to verify zero hard errors and review un-synced file warnings.

---

## 5. Automated CI Checks (`fras-check`)

Run via GitHub Actions (`noir017/fras-map@v1`) or locally via `skills/fras-map/scripts/fras-check.sh`:
- **Hard Errors (exit code 1)**: Syntax violation, L1 target file missing, L2 path not matching git-tracked files, R: path missing, A: symbol missing from matched files, file line limits exceeded (L1 > 50, L2 > 80), test tag `[T:x]` not matching a test declaration, or private network addresses (including comments; 10.x, 172.16-31.x, 192.168.x, .lan, .local, .internal; `host.docker.internal` is whitelisted).
- **Diff Warnings**: Flags source files changed in diff whose `.fras` file was left untouched.
- **Staleness Report (`--stale`)**: Identifies `.fras` entries whose target files/globs have been changed repeatedly since the FRAS entry's last commit.
