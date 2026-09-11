# 06 — The Copilot migration team

A repo-native way to work the conversion's **review tasks** — the objects the AI tool could
not convert cleanly — as a small team of GitHub Copilot custom agents sitting on top of a
deterministic queue. The queue, not the model, is the arbiter: every state change goes
through `tools/migration-team.py`, which records file hashes and events as a **tamper-evident**
log — accountability, not a security boundary — and validation runs against a real PostgreSQL
16 server in a disposable container, not against a model's opinion of itself.

The team is **schema-agnostic**: it validates against whatever target schema(s) a project
configures, for the Oracle→PostgreSQL engine pair. Contoso Store is the bundled worked example,
not a built-in assumption — nothing here hardcodes a `contoso` schema or a Contoso database
name, and an unsupported engine pair is rejected rather than silently "translated".

This is the automatable companion to [05 — Validate](05-validate.md). Where 05 is the manual
differential method, this page is the scaffolding that lets several agents (or one agent and a
human) grind through review objects without ever letting the author of a change be the one who
approves it.

- [What this is, and is not](#what-this-is-and-is-not)
- [The five agents](#the-five-agents)
- [The queue and its states](#the-queue-and-its-states)
- [Prerequisites](#prerequisites)
- [Quickstart A — the real conversion report (offline)](#quickstart-a--the-real-conversion-report-offline)
- [Quickstart B — the synthetic fixture, end to end](#quickstart-b--the-synthetic-fixture-end-to-end)
- [The data-comparison lane](#the-data-comparison-lane)
- [The hard-case registry](#the-hard-case-registry)
- [Running the agents in Copilot](#running-the-agents-in-copilot)
- [What the numbers mean, and do not](#what-the-numbers-mean-and-do-not)
- [Honest limits](#honest-limits)

---

## What this is, and is not

| It is | It is not |
| --- | --- |
| A deterministic Python queue (`tools/migration-team.py`) that Copilot agents drive | A model grading its own conversions |
| Local and offline: `python3` plus one **local** Docker container run with `--network none` | Anything that connects to Azure, deploys, or writes to production |
| A review workflow where the reviewer identity must differ from the author's | A security boundary — the identity strings are accountability labels, not authentication |
| A record of **review states** and reviewed-task-backed observations | A conversion success percentage, or a claim the migration is "done" |

> **No Claude/Anthropic runtime is involved.** These are GitHub Copilot custom agents that call
> a deterministic CLI. The commands behave identically whether a person or an agent types them.

The AI cannot validate itself (05 opens with the same warning). Everything here is built so
that the thing which says "passed" is `plpgsql_check` and a real server, and the thing which
says "accepted" is a *different* party than the one who wrote the SQL.

---

## The five agents

Definitions live in [`.github/agents/`](../.github/agents/); the user entrypoint is
[`.github/prompts/migrate-with-team.prompt.md`](../.github/prompts/migrate-with-team.prompt.md).
Each agent is a thin charter over the CLI — it decides *what* to run and enforces the rules the
CLI cannot, and the CLI enforces the rest.

| Agent | Role | CLI commands it drives | Tools |
| --- | --- | --- | --- |
| `o2p-coordinator` | Routes work, tracks state, reports. Works one bounded batch (≤2 lanes) at a time; delegates; never approves. | `init`, `configure`, `list`, `show`, `report`, `unblock` | read, search, execute, agent |
| `o2p-repair` | Repairs one object: stages original DDL + candidate + checks, validates in the container. | `claim`, `stage`, `validate`, `release` | read, search, edit, execute |
| `o2p-reviewer` | Independent review; no `edit` tool. The queue blocks self-approval (`reviewer != worker`); it must not modify SQL. | `show`, `review` | read, search, execute |
| `o2p-data` | Plans consistent exports (e.g. `ora2pg`) and diffs them offline. Does not move data. | `compare-data` | read, search, edit, execute |
| `o2p-hard-cases` | Maintains a hard-case checklist (the lab's design or a project's own catalog); records an assessment only from reviewed tasks. | `cases`, `case-record` | read, search, execute |

The tool lists use GitHub Copilot's documented tool aliases (`read`, `edit`, `search`,
`execute`, and `agent` for delegation) — no invented tool names. Withholding the `edit` alias
from the reviewer is a **guardrail, not a security boundary**: the reviewer still needs
`execute` to run the `review` command, and anything with shell access can write a file. What
actually keeps review independent is the queue's `reviewer != worker` rule and the discipline
in the charter, not the missing alias.

---

## The queue and its states

A task is one **source object** (grouped by type and case-sensitive name), not one CSV row.
`init` enqueues only objects that are Not-Converted or flagged Action Required. On the real
report that is **908 tasks** from **1,706 distinct source objects** across **2,507 mapping
rows** — so the task count is already far below the row count, and is a count of work, not a
percentage.

| From | Command | To |
| --- | --- | --- |
| `queued` | `claim` | `claimed` |
| `claimed` | `stage` | `claimed` (SQL attached) |
| `claimed` | `validate` (max 3 per task) | `validating` → `pending_review` (passed) / `claimed` (failed or blocked) |
| `claimed` | `release --blocked` | `blocked` |
| `blocked` | `unblock` (unused budget, no quarantine) | `queued` (budget retained) |
| `pending_review` | `review --decision accept` | `reviewed` |
| `pending_review` | `review --decision reject` | `queued` / `blocked` (budget exhausted) |
| `reviewed` | `reopen` with a concrete new regression | `queued` / `blocked` (existing budget exhausted) |

What the CLI enforces on every call, so no running agent can talk it out of them (the state
directory itself is tamper-evident, not tamper-proof — see [Honest limits](#honest-limits)):

- **Ownership.** `stage`, `validate`, and `release` only work for the `--worker` that holds the
  `claimed` task.
- **A ceiling of two active lanes.** `claim` refuses once `max-workers` (default 2) tasks are
  `claimed`/`validating`. There is no flag to raise it mid-run, and agents must not invent one.
- **Real artifacts before a verdict.** `validate` requires non-empty `source.sql`,
  `candidate.sql`, and `checks.sql`; a missing file errors with *"the historical CSV alone is
  not enough to validate a repair."* You attach the **original** Oracle DDL — you do not
  reconstruct it from the mapping CSV.
- **A configured target schema.** `validate` refuses until the queue has an explicit target
  schema (set with `init --target-schema <name>` or `configure --target-schema <name>`, repeat
  for several) — it never guesses one from the CSV, and rejects PostgreSQL system or
  extension-owned namespaces (the `pg_` prefix, `information_schema`, `oracle`). The schema and
  engine configuration is folded into each validation's evidence, so reconfiguring it makes
  prior reviews stale and they must re-validate. A legacy queue created before this existed
  gets that same actionable error — never a traceback — and `configure` migrates it in place
  without touching its tasks.
- **No self-approval.** `review` rejects a `--reviewer` whose name equals the task's `worker`.
- **No stale acceptance.** Every staged file's SHA-256 is stored with the evidence; if the SQL
  changed after validation, `review --decision accept` refuses and you must re-validate.
- **Accepted reviews can be refuted by new evidence.** `reopen --state <dir> --id <task>
  --actor <independent-actor> --reason "<concrete regression>"` archives the prior recorded
  task/review and current files under its `history/`, then clears acceptance. The actor must
  differ from the repair author. Validation-attempt counts are retained, never reset: the
  task becomes `queued` if attempts remain, otherwise `blocked`. Corrected SQL requires fresh
  validation and independent review; an old `reviewed` label cannot hide a later failure.
- **A lifetime three-attempt validation budget.** `audit --state <dir> --id <task>` exposes
  recorded history and `validation_budget`; `show` includes the same budget summary. New
  start events count interrupted attempts, and a baseline retains completed legacy attempts
  even if an old counter was reset. `unblock` never replenishes the budget and refuses when
  it is exhausted. Renaming a helper or creating another queue is not authorization for
  additional attempts on the same lineage; cross-queue provenance must be audited separately.
- **Quarantined reviews cannot be reused.** `reopen --quarantine` archives the prior record
  and current files, clears acceptance and holds the task blocked. Ordinary `unblock` cannot
  release an authorization/lineage quarantine. Neither this command nor an agent's claimed
  re-scope grants extra budget. Review and hard-case acceptance reject invalid local budget
  history; the full-run ledger must additionally enforce cross-queue lineage holds.
- **A specific user-approved revision is not a reset.** The separate operator-only
  `python -m migration_team.budget_admin --approval <private-receipt> [--apply]` records a
  one-shot forward allowance after actual user consent; it is deliberately not available
  through the worker CLI. Queue/task identity, the prior audit, staged input hashes and
  linked quarantined lineage must match the receipt. Previous attempts are retained and
  linked attempts are debited, not discarded. A new validation binds its approval ID and
  required fresh inputs; old reviews cannot satisfy the new revision. An approval file is
  an accountability record, not authentication or permission for an agent to approve itself.

---

## Prerequisites

- **Python 3** (standard library only). No cloud credentials, no LLM key. Every
  `tools/migration-team.py` command below is offline and runs on its own.
- **A GitHub Copilot sign-in** — only to *drive* these commands through the Copilot agents. The
  agent layer needs a Copilot seat (Pro+, Business, or Enterprise, per the repo README) and
  `copilot login`; the deterministic CLI it calls still needs no key and no network. You can run
  the whole workflow by hand with no Copilot at all.
- **Docker**, for the `validate` step only. Build the validator image **explicitly once** — the
  validator never builds or pulls it and [fails closed](../tools/migration_team/validator.py)
  if it is absent:

  ```bash
  docker build -f tools/migration_team/Dockerfile -t o2p-migration-validator:pg16 tools/migration_team
  ```

  The image is PostgreSQL 16 with `plpgsql_check` (and `orafce` when the PGDG package is
  available). Each `validate` starts one throwaway container with `--network none`, no host
  mounts, and RAM/CPU/PID ceilings, runs three phases, and destroys it. Nothing is published
  and nothing reaches a network.

`init`, `list`, `show`, `report`, `cases`, and `compare-data` need only `python3`. Only
`validate` needs Docker.

---

## Quickstart A — the real conversion report (offline)

Import the actual run's mapping and see the shape of the work. No Docker, no network.

```bash
# 1. Import the real conversion report into a fresh (empty) queue directory.
python3 tools/migration-team.py init \
  --state out/migration-team \
  --report docs/conversion-report/object_mapping_summary.csv \
  --max-workers 2

# 2. See the state histogram. Its own output reminds you these are review states,
#    not a conversion success rate.
python3 tools/migration-team.py report --state out/migration-team

# 3. See the objects waiting for a repair lane.
python3 tools/migration-team.py list --state out/migration-team --status queued
```

The CSV has 2,507 mapping rows across 1,706 distinct source objects; the queue holds **908
tasks** — the objects that are Not-Converted or flagged Action Required. **That 908 is the
work identified, not the 79.92% headline and not a percentage at all** — see
[below](#what-the-numbers-mean-and-do-not).

`out/` is gitignored. `init` refuses a non-empty state directory, so an existing queue is
resumed rather than silently re-imported.

---

## Quickstart B — the synthetic fixture, end to end

A self-contained repair→validate→review→record loop on a tiny fixture, so you can exercise the
whole machine — including the container — without the Oracle or PostgreSQL servers. The fixture
lives under [`tests/fixtures/migration-team/`](../tests/fixtures/migration-team/): a one-object
mapping, the original Oracle `source.sql`, a PostgreSQL `candidate.sql`, and a `checks.sql`
whose assertions encode the *source* semantics (NULL→0, rounding, tax).

```bash
STATE=out/mig-demo
FIX=tests/fixtures/migration-team

# 0. Build the validator image once (see Prerequisites).
docker build -f tools/migration_team/Dockerfile -t o2p-migration-validator:pg16 tools/migration_team

# 1. Fresh queue from the fixture mapping (one queued task). The fixture's candidate
#    targets the `contoso` schema, so configure that target up front; validation needs it.
python3 tools/migration-team.py init --state "$STATE" --report "$FIX/mapping.csv" \
  --target-schema contoso

# 2. Repair lane claims the next queued task and captures its id from the JSON output.
#    (Or run `claim` alone, read the "id" field, and set TASK='<that-id>' with quotes.)
TASK=$(python3 tools/migration-team.py claim --state "$STATE" --worker o2p-repair \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

# 3. Attach the ORIGINAL Oracle DDL, the candidate, and the checks.
#    --source is stored for the reviewer and is never executed.
python3 tools/migration-team.py stage --state "$STATE" --id "$TASK" --worker o2p-repair \
  --source "$FIX/source.sql" --candidate "$FIX/candidate.sql" --checks "$FIX/checks.sql"

# 4. Validate in the disposable container. Passes -> pending_review.
python3 tools/migration-team.py validate --state "$STATE" --id "$TASK" --worker o2p-repair

# 5. INDEPENDENT review. The reviewer identity must differ from the worker above.
python3 tools/migration-team.py review --state "$STATE" --id "$TASK" \
  --reviewer o2p-reviewer --decision accept \
  --note "Candidate preserves NVL->coalesce and ROUND semantics; checks assert source behaviour."
```

`validate` exits `0` only when the evidence status is `passed` (`1` otherwise); the wrapper
returns `2` on a usage or filesystem error. If step 5 is run with `--reviewer o2p-repair`, the
queue rejects it — that is the self-approval guard working.

Try the failure paths too, minding which state each needs:

- **Block a task you cannot finish honestly** (e.g. no original Oracle DDL). `release` works
  only while the task is **`claimed`** — after `claim`/`stage`, before `validate`:
  `release --state "$STATE" --id "$TASK" --worker o2p-repair --blocked --reason "no original DDL"`.
  It parks in `blocked` until `unblock`. A task that already passed is `pending_review`, not
  `claimed`, so `release` refuses it — to abandon that one, **reject it first**
  (`review --decision reject` → `queued`), then re-claim.
- **Stale evidence.** If the SQL changes after a passing validation, `review --decision accept`
  refuses ("validation evidence is stale"); reject it back to `queued`, then re-claim, re-stage,
  and re-validate the changed SQL.

> The mocked unit tests (`tests/test_migration_team.py`, `tests/test_migration_validator.py`,
> run by `tests/run-tests.sh`) are owned by the test/CI integration and exercise these paths
> without Docker; this quickstart is the live version.

---

## The data-comparison lane

`o2p-data` compares two CSV exports **you supply** and reports whether they match; it moves no
data, reads no database, and cannot prove on its own that a real migration copied the rows —
its verdict is only as good as the snapshots you hand it. Data movement is the `ora2pg` step in
[04 — Migrate the data](04-migrate-data.md). The agent plans a consistent-snapshot export of an
identical projection from each side (making NULLs, timezones, numeric formatting, and Oracle
`''`-vs-`NULL` explicit in the projection itself), then diffs the two exported CSVs offline:

```bash
python3 tools/migration-team.py compare-data \
  --source tests/fixtures/migration-team/source.csv \
  --target tests/fixtures/migration-team/target.csv \
  --key order_id \
  --output out/mig-demo/compare.json
```

Repeat `--key` for a composite key; read the CSV header to choose the right column rather than
assuming one. The command hashes both files before and after and aborts if either changed
mid-comparison, refuses duplicate or empty keys, and reports `missing_keys`, `extra_keys`,
`changed_rows`, and up to ten sample changed keys. `status` is `passed` only when all three are
zero. `--output` refuses to overwrite existing evidence. Its scope line is binding: *"Exact
exported text only; not a live database, business-semantic or cutover certification."*

---

## The hard-case registry

`docs/design.md` predicts, for each of the Contoso lab's 43 hard cases `H-01`…`H-43`, whether
it converts clean, partial, or into a review task. Those 43 are **the lab's sample, not a
universal list** — another project supplies its own markdown design (`cases --design <md>`) or a
JSON case catalog with arbitrary case ids (`cases --catalog <catalog.json>`). Either way the
extracted cases start `not_tested`. `o2p-hard-cases` turns a prediction into a recorded
observation — but only when reviewed work backs it.

```bash
# Extract the cases (each not_tested) from the bundled lab design...
python3 tools/migration-team.py cases --output out/mig-demo/hard-cases.json
# ...or from a project's own catalog instead:
# python3 tools/migration-team.py cases --catalog my-cases.json --output out/hard-cases.json

# Record an observed assessment — ONLY from reviewed task(s) that actually exercised THIS
# case. H-01 is "packages with overloaded procedures", so its evidence must be a reviewed
# task that converted such a package. Substitute that task id; do not reuse an unrelated one.
python3 tools/migration-team.py case-record \
  --checklist out/mig-demo/hard-cases.json --state out/mig-demo \
  --id H-01 --task '<reviewed-task-id-that-converted-an-overloaded-package>' --outcome partial \
  --note "Overloaded members split into name-mangled functions; callers rewritten. Evidence: <reviewed task + validation.json>."
```

> **The Quickstart B fixture validates none of the 43 hard cases.** It is a single tax
> function — plumbing to exercise the queue and container, nothing more. Recording any `H-NN`
> from it would be false evidence, and `case-record` cannot catch that for you: it enforces
> that the cited task is *reviewed* with fresh hashes, not that the task is *relevant* to the
> case. Relevance is your judgement — cite a task that genuinely converted the construct.

`case-record` refuses unless every `--task` is a **distinct** `reviewed` task with validation
evidence whose hashes still match the staged files. `--outcome` is an *observed*
classification (`clean`/`partial`/`manual`), never the design's guess; the case is written as
`reviewed_candidate`, not "closed". Where observation disagrees with the prediction, the
observation wins and `design.md` section 9 should be corrected in the same spirit as 05 § 6.

---

## Running the agents in Copilot

Two entry points, same queue underneath:

- **CLI:** from the repo root, `copilot --agent o2p-coordinator` (the flag takes the agent
  file's stem). The coordinator delegates the repair and review lanes to `o2p-repair` and
  `o2p-reviewer` via the CLI's subagent **`task`** tool — each subagent runs in its own
  context and returns its result to the coordinator. To allow that one hop in a headless
  (`-p`) run, authorize just it: `--allow-tool task` (verified against Copilot CLI v1.0.74).
  You can also run a lane directly, e.g. `copilot --agent o2p-repair`.
- **VS Code:** pick the **o2p-coordinator** agent, or invoke the
  `migrate-with-team` prompt, which is bound to the coordinator.

**Keep the permission gates on.** Start `copilot --agent o2p-repair` and approve the actual
queue and disposable-validation commands as they appear. Do not blanket-allow Python or
Docker: arbitrary Python can modify files, and arbitrary Docker can mount host directories.
The validator's own restricted container does not constrain other shell commands.

Do **not** use `--allow-all-tools`, `--allow-all`, or `--yolo`, and do not grant automatic
`git push`. The agent files intentionally omit a model override; use the models and permissions
available in your Copilot environment. Delegation is explicit in the coordinator charter.

---

## What the numbers mean, and do not

The historical technical report scored **79.92%** conversion on `CONTOSO`
([conversion-report/README.md](conversion-report/README.md)). That run included contention and
manual intervention, so it is not a clean comparative benchmark. This team has not repeated
that full run, separated all failure causes, or demonstrated a higher conversion rate.

This queue does not restate, beat, or replace that figure:

- `report` counts **task review states**. Its own output says so: *"Task review states only;
  not a conversion success rate or production approval."* Quote it; do not convert "12 reviewed"
  into "12% done" or "92% converted".
- A queued task count is the amount of **work identified**, not a percentage of anything.
- There is no target like "95%" anywhere in this workflow, and inventing one would be exactly
  the kind of green-dashboard claim [05](05-validate.md) exists to puncture.

---

## What was exercised on 2026-09-09

- Copilot CLI 1.0.74 loaded `o2p-coordinator` and delegated to the repository's
  `o2p-reviewer` through its native `task` tool. Both smoke runs made zero file changes.
- Through the public Python CLI, the synthetic repair compiled on PostgreSQL 16.15,
  passed `plpgsql_check` and four SQL assertions, and reached `pending_review`.
  Self-approval was refused; a separate reviewer label could accept it.
- Wrong arithmetic failed the behavior assertions. A deferred PL/pgSQL body error
  failed deep validation even when an unrelated assertion returned true. Missing
  images, stale evidence, a fourth validation attempt, and malformed checklist JSON
  were refused. The created validator containers were removed.
- The historical CSV imported into **908 queued tasks**, retaining all **2,507 mappings**
  across **1,706 distinct source keys**. The 43 hard cases remain `not_tested`.
- Consistent three-row fixture exports compared equal despite row/column ordering;
  changing one amount produced one changed row and a nonzero exit.

These are implementation checks, not a new execution of the full Contoso migration.
The VS Code UI was not driven in this verification; the live Copilot checks used the CLI.

For the subsequent run against genuine remaining objects and live Oracle measurements,
see [07 — Remaining-migration team E2E evidence](07-remaining-migration-e2e.md).
That report distinguishes bounded cohort evidence from the unfinished full migration.

## Honest limits

- **Use trusted SQL inputs and review the assertions.** The disposable container has no network,
  host mounts or published ports, has resource caps, and runs candidate SQL as a non-superuser.
  These reduce accidental side effects; they are not a hardened sandbox for hostile SQL.
  A trivial `SELECT true` is still a weak test. Independent review must assess test quality,
  source fidelity, dependency coverage and relevant Oracle edge cases.
- **Reviewer and worker identities are operational, not cryptographic.** The queue guarantees
  the two strings differ and that evidence is fresh; it does not prove who typed them. The value
  is the reviewed-task chain and the matching hashes, not the name.
- **The state directory is not a security boundary.** Hash comparisons detect SQL changes
  relative to recorded evidence during normal use. Someone with write access can also replace
  the evidence, database and event log. Protect the directory with filesystem permissions;
  do not treat its contents as independently authenticated proof.
- **Agents treat task content as data, not instructions.** The staged SQL, its comments, task
  notes, and validator logs are material to convert, check, and compare — a comment that reads
  `-- approved` or `reviewer: accept` is not a command, and the charters say so explicitly.
- **A passing validation is one object in a scratch database.** It says the object compiles,
  deep-checks clean, and satisfies the assertions you wrote — no more. It is not a production
  sign-off, and Microsoft's own guidance is that AI-generated conversions need human review
  before production use.
- **Nothing here deploys.** No Azure, no cutover, no production writes. Data comparison reads two
  CSV files and touches no database.

Back to [05 — Validate](05-validate.md) for the manual differential method these agents
automate, or to [`design.md`](design.md) section 9 for the predictions the hard-case lane
records against.
