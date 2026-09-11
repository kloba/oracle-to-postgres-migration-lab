# 07 — Remaining-migration team E2E evidence

**Run date: 2026-09-10. Team E2E: PASS for the bounded three-function real-source
cohort. Full migration: BLOCKED / incomplete.**

This run exercises the Copilot team on genuine work from the historical VS Code
conversion queue, rather than treating a synthetic fixture as migration evidence.
A successful bounded cohort is not completion of the remaining queue, the full
schema/data migration, or a production cutover.

## Baseline and source provenance

- The historical conversion result remains **79.92%**. Queue review counts do not
  change that result or establish an improved conversion percentage.
- The original queue contains **908 tasks**: **711** have at least one
  `Not-Converted` mapping, and **197** are additional `Converted` tasks flagged
  Action Required. At the start of this continuation, `FN_SPLIT_CSV` was the only
  reviewed task; **907** remained queued.
- The fresh Azure Oracle extraction contains **1,346** source DDL files. These are
  new source artifacts, **not recovered September 4 conversion output**. Matching
  names does not establish that the historical and current DDL bytes are identical.
- Exact type and case-sensitive name reconciliation accounts for all 908 tasks:
  **474** direct inventory matches, **378** package-member declarations in genuine
  package source, and **56** converter-synthetic package-state tasks with genuine
  package/body sources. No task lacks the corresponding source or parent source.
  **16** package-member tasks are overloaded; declaration matching is not proof of
  signature or behavioral equivalence.
- The preserved typed snapshot contains **93 base tables and 54,588 rows**, exported
  in one Oracle read-only transaction with UTC session time and no export blockers.

## Observed runtime guards

All checks below used the public `python3 tools/migration-team.py` CLI and fresh
local state. Validation used disposable PostgreSQL 16 containers. No unit-test,
smoke-test, or typecheck invocation is being presented as runtime evidence.

| Surface exercised | Observed result |
| --- | --- |
| Synthetic candidate validation | Passed; one routine deep-checked, four behavior assertions; `pending_review` |
| Author attempts to accept their own candidate | Refused, exit 2; independent reviewer acceptance reached `reviewed` |
| Tax multiplier changed from 1.20 to 1.30 | Compilation passed; behavior failed |
| Deferred PL/pgSQL body error with an unrelated true assertion | Deep validation failed: `column "v_rate" does not exist` |
| Missing validator image | `blocked`, never passed |
| Identical versus changed CSV exports | Identical passed; one changed amount failed with one changed row |
| Missing target schema configuration | Validation refused before starting a container, with an actionable error |
| Quoted, mixed-case `SalesOps` target schema | Validation passed |
| Schema reconfiguration after validation | Review acceptance refused because evidence was stale |
| Unsupported Oracle→MySQL pair | Initialization refused; no queue created |
| Hard-case registry extraction | 43 cases, all initially `not_tested`; no fixture-backed hard-case completion claimed |
| Container cleanup | Created validator containers removed; preexisting Oracle container untouched |

The public data-loader CLI also verified all **93 snapshot files** and the expected
**54,588 source rows**. Against a fresh local target with no converted schema, both
plan and apply refused with **93 missing-table blockers**, and the target retained
zero `contoso` relations. This demonstrates a fail-closed gate, **not successful
full data loading**.

## Data-loss defect found in the real snapshot path

**Fixed and verified through the public loader CLI.** The Oracle
snapshot labels `PRODUCT.SPEC_SHEET` and `PRODUCT.ATTRIBUTES` as `virtual=YES`,
although genuine Oracle DDL declares stored XML/object columns. Both contain
non-null values in all 1,100 product rows. The original loader incorrectly used
that metadata flag to exempt missing source columns from its dropped-column gate.

Against a fresh local target representing every product column except
`SPEC_SHEET`, the public loader returned a plan with **zero blockers**, then
reported **`applied=True` and 1,100 rows loaded** while all source XML values were
omitted. This was an actual apply-path reproduction, not just inspection or a
row-count assertion. The Oracle source and shared target were not modified.

The corrected planner requires a target representation for every source column.
Actual target generated columns may represent source values without being inserted;
a source `virtual` flag alone no longer authorizes omission. Post-fix runtime
observations:

- Missing `SPEC_SHEET`: plan and apply exit 1 with `dropped_source_column`; target
  remains empty. Missing `ATTRIBUTES`, or both columns, also blocks planning.
- Complete targets: apply loads 1,100 rows. Independent source/target comparisons
  establish **1,100/1,100 exact XML matches**, and matching attributes and channels.
- Both JSONB and typed `t_product_attr[]` representations preserve all 3,300
  attribute elements; `text[]` channels match the source in all 1,100 rows.
- `margin_pct` is not inserted. Database-generated values match Oracle's exported
  values in **1,100/1,100 rows**, including eight expected nulls for zero list prices.
- Invalid explicit generated-column mappings and ambiguous source matches are
  blocked. A genuine target-only generated column remains allowed and is not inserted.
- The original untracked loader bytes, final bytes and a patch are preserved with
  hashes. Focused regression tests were added, **not executed** in this runtime
  verification. Created PostgreSQL containers were removed.

This verifies the missing-column gate and the exercised representations; it is
not blanket certification of every Oracle/PostgreSQL type conversion.

## Real remaining-work cohort

Source measurements have been captured through SQL against the live Oracle lab,
inside read-only transactions:

| Object | Historical classification | Oracle observations captured |
| --- | --- | ---: |
| `FN_GEN_VALID_EAN13_005` | Converted + Action Required, not Not-Converted | 21 |
| `FN_GEN_CHK_IMPURE_032` | Not-Converted | 23 |
| `FN_GEN_CHK_IMPURE_035` | Not-Converted | 23 |
| `FN_GEN_CHK_IMPURE_038` | Not-Converted | 23 |

An observed EAN-13 edge case is significant: Oracle accepts a valid 13-digit barcode
followed by a newline. Null and empty inputs also return `Y`. A translation must
preserve observed behavior rather than silently replace it with stricter input
validation.

The three impure-check functions read `TAX_RATE`. Their **160 live dependency rows**
were compared with the preserved typed snapshot and matched exactly. Measurements
cover null/empty/unknown country codes, case and whitespace, inclusive start and
exclusive end dates, null dates, open-ended validity, and omitted date arguments.
Default-date observations are time-specific. Oracle's `DETERMINISTIC` annotation
does not make a table lookup immutable.

**Combined cohort runtime: PASS.** Actual Copilot `o2p-coordinator` sessions
used the native `task` tool to delegate to `o2p-repair` and a separate
`o2p-reviewer`. All three Not-Converted candidates passed validation and were
accepted by reviewer `o2p-reviewer`, distinct from worker `o2p-repair-impure`.
Each task's source, candidate, checks, dependencies and configuration hashes were
preserved. The standalone table DDL matches the CREATE TABLE statement in the
hashed, reviewed dependency SQL after whitespace normalization.

The combined run at **11:29 UTC** used the final fixed loader in a fresh local
PostgreSQL container, with candidate/data work under a non-superuser role:

- Loaded **160 TAX_RATE rows**, comparing every value in all **six columns** by the
  real primary key. Independent source and target exports were byte-identical:
  **zero missing keys, extra keys or changed rows**. CHAR blank-padding normalization
  applied only to the genuine `country_code CHAR(2)` column.
- Deployed **all three routines together**. Independent `plpgsql_check` inspected
  all three with **zero error findings**.
- Passed **69/69 original Oracle-grounded calls**: 57 explicit-date calls and
  **12 actual one-argument calls** exercising the default. A separate 12-call
  explicit-clock replay also passed; it was not substituted for default calls.
- Refused a second load with `target_not_empty` and left all 160 rows unchanged.
- Verified `pg_proc.provolatile = 's'` for all three. Prepared constant calls
  returned **Y → N → Y** before an in-transaction deletion of four IE rows, after
  deletion, and after rollback. The original 160 rows and export hash were restored.
  This is a **target-only semantic probe**, not measured Oracle mutation parity.
- Verified PK/unique/check constraints were validated, then removed the container.

**All five agent roles exercised.** Subsequent coordinator sessions delegated to
`o2p-data` and `o2p-hard-cases` through the native `task` tool:

- The data agent independently ran public `compare-data` on the actual source/target
  exports: **160/160 rows, zero differences**, matching the runtime comparison.
- The hard-case agent recorded **only H-23** as `reviewed_candidate` with observed
  classification `partial`, backed by all three independently reviewed tasks and
  current hashes. Its note limits the evidence to this cohort and the PostgreSQL
  prepared-call probe; Oracle-side mutation parity was not measured.
- The other **42 hard cases remain `not_tested`**. No conversion percentage or full
  migration completion was inferred from task review counts.

Headless permission guards refused incidental shell operations (`find`, `mkdir`,
`shasum`) outside the narrow allowlist. The requested workflow completed through
permitted operations and the deterministic CLI; no blanket allow-all permission
was used. Raw refusals and the successful native delegation traces are preserved.

## Full-migration limits

The fresh VS Code conversion has not yet supplied a final deployment artifact and
technical report to this run. A live read-only diagnostic at **11:04 UTC** found
**16 idle-in-transaction compiler sessions** and a compiler statement waiting on
one of those transactions for approximately **33 minutes**, with its lock and
statement timeouts disabled. The conversion log had stopped advancing at
10:31 UTC. These observations establish a prolonged stall, not the precise client
root cause or a guarantee that a restart will recover it.

Fifteen chunk checkpoints/SQL files survive locally, reporting 363 converted
items in aggregate; the last aggregate progress log reports 14 chunks/333 items.
These are different checkpoint/progress views, not interchangeable final totals.
Some checkpoint objects have `compilation_verified=false`. Intermediate chunk SQL
and a populated compiler scratch database are **not a final deployable schema**.

Full schema assembly, all-table data loading, constraint/sequence/materialized-view
reconciliation, and assessment of all 43 hard cases remain incomplete. Do not use
isolated function validations or the bounded dependency table to certify those
steps. Interrupting the stalled original converter requires a separately verified
recovery recipe and approval; this continuation has not killed that process or
cleared its database sessions.

No shared PostgreSQL target or Oracle source was used as a disposable test target
in this continuation. The original Azure conversion and its private artifacts
remain preserved; no cloud teardown, publication, or production cutover is claimed.

## Full-scope continuation (2026-09-11)

The stalled converter described above was subsequently stopped through approved,
identity-checked recovery after its private artifacts were preserved. The full
run now uses dependency-ordered Copilot repairs and new isolated application and
compiler targets rather than treating the stalled checkpoints as deployment SQL.
The original Oracle source and existing target data remain outside the disposable
validation scope.

**The full migration remains incomplete.** The pinned scope is still 93 base
tables, 54,588 rows, all source columns, and all 43 hard cases. Table/type
corrections, combined deployment, all-table parity, and operational acceptance
must each supply current evidence. An accepted candidate, a passing fixture, or
a green regression suite is not a substitute for those gates.

## Local evidence locations

These directories are private, gitignored runtime artifacts, not repository assets.
A private evidence bundle with a per-file SHA-256 manifest is preserved under
`out/team-e2e-handoff-20260910-L8WwdI/`; it is not a full backup of the active Azure/VS Code lab.

- `out/reconciliation-20260910-AV75x1/` — full task reconciliation, source hashes,
  exact package declaration locations, and remaining-work CSVs.
- `out/verify-runtime-guards-20260910-124256/` — CLI commands, outputs and
  `verify_summary.json`.
- `out/verify-schema-config-guards-20260910-124805/` — configuration probes and
  `probe_summary.json`.
- `out/remaining-team-e2e-20260910-WYccvg/` — genuine EAN-13 source and live Oracle
  observations.
- `out/not-converted-team-e2e-20260910-KhxxaA/` — three genuine Not-Converted function
  sources, dependency DDL/rows and live Oracle observations.
- `out/real-snapshot-loader-20260910-b3IdX7/` — full-snapshot fail-closed CLI evidence
  and explicitly scoped TAX_RATE subset with parent-manifest provenance.
- `out/combined-cohort-e2e-20260910-1b3a85/` — combined deployment, all 69 source calls,
  real data comparison, prepared-call mutability and reapply-refusal evidence.
- `out/loader-loss-guard-20260910-130753-28758/` — reproduced XML omission, before/after
  loader bytes and patch, final rejection/load/value comparisons. `README-evidence.md`
  explains the retained first-pass composite-decoding mistake and corrected comparison.
- `out/conversion-observation-20260910-104409-10211/` — read-only live diagnostics of
  the original stalled VS Code conversion and compiler transactions.

For workflow rules and limits, see [06 — The Copilot migration team](06-copilot-migration-team.md).
