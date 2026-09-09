---
name: verify
description: Exercise the migration-team CLI and GitHub Copilot agents against safe local fixtures.
---

# Verify the Copilot migration team

No Azure deployment, Oracle re-seed, or production database is needed. Never use
an existing source/target server as the scratch environment. No model key is
needed for the Python CLI; running Copilot itself uses the user's Copilot session.

1. Use a new state directory under `out/` on every fixture run. Run the public CLI,
   `python3 tools/migration-team.py`, not imports of internal functions.
2. Build the image explicitly if absent:
   `docker build -f tools/migration_team/Dockerfile -t o2p-migration-validator:pg16 tools/migration_team`.
3. `init --state <new-dir> --report tests/fixtures/migration-team/mapping.csv`, then
   `claim --state <new-dir> --worker repair-1`. Keep the returned task ID.
4. `stage --state <dir> --id <id> --worker repair-1 --source tests/fixtures/migration-team/source.sql --candidate tests/fixtures/migration-team/candidate.sql --checks tests/fixtures/migration-team/checks.sql`.
5. `validate --state <dir> --id <id> --worker repair-1` must report `passed` and
   `pending_review`, with one routine deep-checked and four behavior assertions.
6. `review` as `repair-1` must fail. `review --reviewer fixture-reviewer --decision accept --note 'Synthetic fixture only'`
   must succeed. Actor labels are a workflow guard, not authentication.
7. In separate queues, change the tax multiplier from 1.20 to 1.30: compilation
   passes but behavior must fail. A PL/pgSQL body using a nonexistent variable
   must fail deep validation, even with an unrelated true behavior assertion.
   A missing Docker image must be blocked, never passed.
8. `compare-data --source tests/fixtures/migration-team/source.csv --target tests/fixtures/migration-team/target.csv --key order_id`
   passes; a changed amount fails. `cases` lists 43 cases, all `not_tested`.
9. Confirm no `o2p-mig-val-*` containers remain. Capture CLI stdout/stderr and exit
   codes under `out/` and cite the important output in the response.
10. For agent changes, run the actual `copilot --agent o2p-coordinator` from this
    repo with a bounded read-only prompt. Keep permissions narrow; never use
    allow-all or publish/email as a verification step. If auth is unavailable,
    report that part BLOCKED rather than treating static agent files as a live run.

The fixture does not demonstrate an improved historical conversion percentage,
Oracle behavior equivalence, an Azure deployment, or a production cutover.
