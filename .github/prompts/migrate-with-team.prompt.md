---
description: Start the Oracle-to-PostgreSQL migration team on a review object, routed through the deterministic tools/migration-team.py queue by the o2p-coordinator.
agent: o2p-coordinator
argument-hint: "state=out/migration-team [report=docs/conversion-report/object_mapping_summary.csv] [id=<task>] [request=...]"
---

# Migrate with the o2p team

Hand a migration-review request to the **o2p-coordinator**, which routes it across the
repair, review, data, and hard-case lanes over the shared queue. The coordinator owns
sequencing and reporting; the queue owns state and evidence.

## Inputs

- `${input:state}`: (Required) The queue root passed as `--state` to every stateful command
  (for example `out/migration-team`). For a brand-new queue this directory must be empty;
  existing queues are resumed, not re-imported.
- `${input:report}`: (Optional) The mapping CSV to import when the queue does not exist yet.
  Defaults to `docs/conversion-report/object_mapping_summary.csv` (the real conversion run).
  For a self-contained trial, point it at the synthetic fixture
  `tests/fixtures/migration-team/mapping.csv`.
- `${input:id}`: (Optional) A specific task id to work, from `list`/`show`. When omitted, the
  repair lane claims the next queued task.
- `${input:request}`: (Optional) Free-text intent for this turn (e.g. "block anything whose
  original DDL we can't find", "just report current state").

## What to do

1. If `${input:state}` has no queue yet, run
   `init --state ${input:state} --report ${input:report}` and report the state histogram —
   citing its own disclaimer that the counts are review states, **not** a conversion success
   rate. Do not restate the historical 79.92% as a target.
2. Otherwise resume: `list`/`show` to find work, then route one repair lane
   (`o2p-repair`) and, after a passing validation, one independent review lane
   (`o2p-reviewer`) whose reviewer identity differs from the repairer's worker. Keep at most
   two lanes active — the queue enforces this ceiling.
3. Delegate the data comparison to `o2p-data` and hard-case recording to `o2p-hard-cases`
   when asked. Data comparison needs explicit, consistently exported source and target CSVs;
   hard-case classification needs independently reviewed tasks that actually exercise that case.
4. Never fabricate original Oracle DDL, never approve work you produced, never touch Azure or
   production, and keep the usual permission prompts on (no blanket allow-all, no git push).

Full workflow, prerequisites, the Docker build, and both a real-report and a synthetic
fixture quickstart are in `docs/06-copilot-migration-team.md`.
