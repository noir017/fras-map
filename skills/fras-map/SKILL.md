---
name: fras-map
description: Maintain a lightweight, Git-versioned, two-tier FRAS (Function/Relations/API/Semantics) codebase map for coding agents. Use when bootstrapping a repository index, orienting in an unfamiliar codebase, or syncing the map after code changes via git diff.
---

# FRAS Layered Codebase Map

Maintain a high-density, plain-text architectural map of the repository using a **two-tier (L1 + L2) FRAS layout**, with zero external binaries or runtime dependencies.

## 1. Directory Layout

```text
├── AGENTS.md                   # Entry pointer (5-10 lines): read L1 before coding
└── docs/
    └── fras/
        ├── INDEX.fras          # L1: Module-level overview (always read first)
        ├── <module>.fras       # L2: File-level FRAS per module (read on demand)
        └── schema.fras         # L2 (optional): Core database tables / models
```

- Keep `INDEX.fras` concise (ideally under 50 lines) so it loads cheaply at session start.
- Keep each L2 `<module>.fras` under 80 lines. If a module grows past that, split it into sub-modules.

## 2. FRAS Line Syntax

### L1 (`docs/fras/INDEX.fras`) — Module Granularity

```text
[<module>] -> docs/fras/<module>.fras | F:<responsibility> | R:<coupled modules> | A:<public entrypoints> | S:<cross-cutting invariants>
```

Example:

```text
[billing] -> docs/fras/billing.fras | F:Subscription billing, charge retries, and ledger reconciliation | R:auth,schema | A:CreateCharge,RefundWebhook | S:All write operations require idempotency keys; never call payment gateway inside DB transactions
```

### L2 (`docs/fras/<module>.fras`) — File Granularity

```text
<relative/path> [<Tier>]: F:<responsibility> | R:<must-read coupled files> | A:<exported contracts/routes/tables> | S:<non-obvious invariants>
```

- **Tier tags**: `[Core]` (business logic / state machines), `[Infra]` (shared plumbing / storage / middleware), `[Edge]` (API / CLI / webhook handlers).
- **F (Function)**: One crisp phrase stating what the file owns.
- **R (Relations)**: Only list files you must read together when modifying this file (shared state, mirrored protocols, schema definitions). Do NOT dump ordinary imports.
- **A (API)**: Public functions, interfaces, HTTP routes, or DB tables callers depend on.
- **S (Semantics)**: Highest-value field. Record only invariants that cannot be inferred from syntax/AST alone (lock ordering, transaction boundaries, idempotency, retry assumptions, compatibility traps). Omit `| S:...` if none exist.

## 3. Scope Filtering (Anti-Bloat Rules)

Do NOT index every file in the repository. Classify files into three tiers:

1. **Index individually (L2)**: Core business logic, state transitions, public entrypoints, shared infrastructure, critical config, and DB schema definitions.
2. **Summarize by glob (single line)**: Repetitive files such as pure DTOs/types, CRUD boilerplate, or i18n bundles (e.g., `src/dto/*.ts [Edge]: F:Request/response schemas for public REST API`).
3. **Ignore completely**: Unit/integration tests, mocks/fixtures, build artifacts, generated code (protobuf/ORM/OpenAPI gen), lockfiles, and static assets.

## 4. Workflows

### Workflow A: Read Before Acting (Orientation)

1. Read `docs/fras/INDEX.fras` first to locate relevant modules and cross-cutting constraints (`S:`).
2. Read only the L2 `docs/fras/<module>.fras` files relevant to the current task and any modules listed under `R:`.
3. Inspect the actual source files before editing. Never rely on FRAS alone for exact implementation details.

### Workflow B: Bootstrap (First-Time Index)

1. Inspect the repository tree (respecting `.gitignore`) and group core directories into logical modules.
2. For each module, read the actual source files (never guess from filenames alone) and write `docs/fras/<module>.fras`.
3. If the project has SQL migrations or ORM schemas, optionally create `docs/fras/schema.fras` for core tables and constraints.
4. Synthesize `docs/fras/INDEX.fras` from the completed L2 files.
5. Append the entry pointer block below to `AGENTS.md` (create it if missing):

```markdown
## Codebase Map (FRAS)

- Before modifying code, read `docs/fras/INDEX.fras`, then load only the relevant `docs/fras/<module>.fras` files.
- After completing structural or behavioral changes, run the `fras-map` incremental sync workflow to keep affected FRAS entries aligned.
```

### Workflow C: Incremental Sync (Post-Change Maintenance)

1. Run `git diff --name-only HEAD` (or against the base branch, e.g., `git diff --name-only main...HEAD`) plus `git status --short` to list changed, added, and deleted files.
2. Filter the list using the Scope Filtering rules in Section 3.
3. For each affected file:
   - **Deleted**: Remove its line from the corresponding L2 file.
   - **Added**: Read the file and add a FRAS line to its module's L2 file.
   - **Modified**: Read the diff/file and update the line ONLY if `F`, `R`, `A`, or `S` actually changed.
4. Update `docs/fras/INDEX.fras` only if module boundaries, cross-module relations, public entrypoints, or top-level invariants changed.
5. **Strict rule**: Never rewrite or reformat untouched entries.

## 5. Quality Guardrails

- **No hallucinated invariants**: Every `S:` claim must be backed by code, comments, or verified evidence in the repo.
- **No prose bloat**: Keep every entry strictly single-line.
- **Git-friendly diffs**: Sort entries alphabetically by path within each L2 file to minimize merge conflicts.
