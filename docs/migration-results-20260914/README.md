# Migration results — 2026-09-13/14

This directory records a **completed VS Code conversion and bounded, independently
reviewed Copilot repairs**. It is not a complete application schema or production
migration approval. See the [run report](../08-vscode-migration-20260913.md) for the
execution sequence, interruptions, recovery, and remaining blockers.

## Recorded artifacts

- [`results.json`](results.json) — machine-readable converter metrics, candidate
  hashes, review/attempt results, combined runtime evidence, and limitations.
- Reviewed candidate SQL and the 70 expected function observations remain in the
  private evidence directory under `out/`. Their repository-relative private paths
  and SHA-256 hashes are recorded in `results.json`; publication is not authorized.

The private SQL copies are **byte-identical to the reviewed candidates**. Each was accepted
by a reviewer distinct from its author, after one lifetime validation attempt.
A separate fresh local PostgreSQL run deployed only these three production
routines and matched all 70 recorded observations, including seven actual
expected string-overflow exceptions. No verification-only helper is included in
these production SQL files.

The reviewed `SALES_ORDER_LINE` candidate separately passed 91 target DML checks
and a public-loader run of 5,600 pinned source rows. Independent comparison covered
all 11 columns, including generated `line_total`: 61,600 compared cells, zero
mismatches. A repeated load was refused without changing the rows. This is a
single structural-table result, not foreign-key, application-trigger, physical
partition, or complete 93-table acceptance.

## Scope and prerequisites

These routines target the `contoso` schema. Any reproduction should use a **new,
disposable PostgreSQL 16 database**, an explicitly selected connection, and a
non-superuser schema owner—not an existing source, shared target, or production
database. The schema/bootstrap is deliberately not embedded in the candidates.
The exercised environment used UTF-8; `fn_gen_valid_code_004` also requires the
`C.utf8` collation used for its measured uppercase behavior.

The expected CSV preserves empty text separately from NULL, exact Unicode and
control characters, and exact decimal values with documented presentation-only
normalization. Its `string_overflow` category maps only the observed Oracle
`ORA-06502` string-buffer errors and PostgreSQL SQLSTATE `22001` errors. **The raw
error codes are not identical.** Original source observations, actual target
command outputs, and projection provenance remain in the private evidence bundle
referenced by the run report.

Passing these observations is not exhaustive equivalence of all Oracle input
domains, locales, application callers, or schema behavior. The code validator's
acceptance of a final newline is an observed source behavior, not a recommendation
for new identifier-validation code.

## Limits that remain

- The full converter deployment still has unresolved artifact findings and manual
  review items; do not substitute these three routines for the full deployment.
- The full 93-table data migration, foreign keys, application triggers, operational
  and physical partition behavior, and production cutover are not certified here.
- Existing exhausted validation budgets, quarantines, and unapproved operational
  changes remain held. Copying these artifacts does not reset a task's history or
  grant another repair attempt.
- The converter's technical and customer reports differ by one standalone object;
  both reported results are retained in `results.json` rather than silently merged.
