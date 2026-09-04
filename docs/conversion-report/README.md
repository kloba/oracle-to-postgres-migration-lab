# The conversion report from a real run

These are the tool's own outputs from the conversion described in
[docs/images/screenshots/](../images/screenshots/README.md), run on **2026-09-04**
against this lab's `CONTOSO` schema. Nothing here was written by hand.

| | |
|---|---|
| Source | Oracle 23.26.3.0.0 (`CONTOSO` on the lab's Azure VM) |
| Target | Azure Database for PostgreSQL flexible server, PG 16 |
| Tool | `ms-ossdata.vscode-pgsql` **1.30.1**, session `9ca12a0f` |
| Model | **`gpt-5.2`**, deployment `o2p-schema-conversion`, 500 kTPM |
| Duration | **2h 56m 53s** |
| Tokens | **7,178,840** — about **$15.50** at the tool's own running estimate |

## The headline number, and why there are two of them

```text
Schema     Objects Extracted   Converted   Not-Converted   Converted %
CONTOSO                1,185         947             238        79.92%
```

The **Conversion Summary** shown in VS Code reports 1,189 / 947 / 242 / 79.65% for
the same session. Neither is wrong. The report counts each package **once**, the
customer summary counts the **members inside** packages, and the two documents are
regenerated at slightly different moments. `object_mapping_summary.csv` here is
the member-level view: **2,507 rows, 1,376 converted, 1,131 not**.

By object type, from `technical_conversion_report.md`:

| Type | Objects | Converted | % |
|---|---:|---:|---:|
| TABLE | 96 | 96 | **100%** |
| SEQUENCE | 75 | 75 | **100%** |
| TYPE | 18 | 18 | **100%** |
| SCHEMA | 1 | 1 | **100%** |
| FUNCTION | 136 | 132 | 97.06% |
| INDEX | 158 | 153 | 96.84% |
| REF_CONSTRAINT | 40 | 37 | 92.50% |
| PROCEDURE | 112 | 94 | 83.93% |
| TRIGGER | 96 | 74 | 77.08% |
| VIEW | 208 | 154 | 74.04% |
| MATERIALIZED_VIEW | 6 | 4 | 66.67% |
| SYNONYM | 149 | 82 | 55.03% |
| **PACKAGE_BODY** | **90** | **27** | **30.00%** |

## Read the failure reasons before you read the percentage

The 79.92% is **not** a measurement of how well `gpt-5.2` translates Oracle. Count
the reasons the tool gives for its own failures in `customer_summary.md`:

```text
628  chunk timeout
176  lock timeout   ("canceling statement due to lock timeout … in relation pg_proc")
 38  does not exist
  4  deadlock
```

Four fifths of the stated reasons are **timeouts and lock contention in the
scratch database**, not bad translations. The compile-and-validate stage opens a
transaction per object and holds it while the LLM fix call is in flight; with ~20
chunks in flight against one scratch database they serialise on catalog locks.
`pg_stat_activity` during the run:

```text
state                 wait_event        count   longest
idle in transaction   Client/ClientRead    17   00:36:14
active                Lock/transactionid    1   00:20:14
```

Packages fare worst (30%) because a package body is many members, and one member
timing out fails the whole body.

**The run stalled twice and had to be unwedged by hand.** With `lock_timeout` set
to `0` by the tool, one worker waited 20+ minutes on a peer that was itself parked
idle-in-transaction, and PostgreSQL could not see it as a deadlock because the
cycle ran through the client. Terminating the blocking backend released it and the
run resumed each time. Four terminations were performed across three hours. Some
of the 238 failures are the direct cost of those terminations, and they cannot be
separated from the rest — **treat this report as a lower bound on what the tool can
do, not an upper one.**

One more thing that is the tool's own, not ours: 65 occurrences of

```text
ValueError: Invalid lifecycle transition for CONTOSO.PACKAGE_BODY.…$__state__:
COMPILED -> COMPILING
```

between 19:51 and 20:17, forty minutes after the last manual intervention.

## Also worth knowing

- **`339 object(s) were converted before their dependencies`** to break cycles, which
  the report flags itself: a missing-relation failure among those is a deployment
  ordering artefact, not a translation defect.
- **641 objects need a manual touch** before the schema is production-ready, grouped
  by cause with a time estimate each. The largest benign group is 39 cross-chunk
  foreign keys — "run `deploy.sql` end-to-end so deferred FK DDL executes late",
  ~5 minutes on cutover day.
- Extraction itself was clean: **1,299 extracted, 0 failed, 185 excluded, 7
  unsupported types, in 2m 50s** (`oracle_extraction_report.md`).

## What is here, and what is not

| File | |
|---|---|
| `technical_conversion_report.md` | the full report: snapshot, inventory, per-chunk performance, Action Required, deploy preparation |
| `object_mapping_summary.csv` | every source object → target object, with status and error, 2,507 rows |
| `oracle_extraction_report.md` | what came out of Oracle before any conversion |

Two files from the same session are **not** committed: `customer_summary.md`
(1.3 MB) and `review_tasks.md` (448 KB). Both are per-object prose that repeats the
same remediation paragraph hundreds of times; the same information is in the CSV in
a form you can actually query. Regenerate them by running the conversion yourself.

Nor is the converted schema itself: **9.1 MB of `.sql` under `postgres_ddl/`** and a
**1.8 MB `deploy.sql`** that concatenates it in dependency order. It is machine
output, it is reproducible, and it would dominate this repository. It has also
**never been executed** — `contoso_store` is still empty. See
[docs/lab-status.md](../lab-status.md) §2.2.

## This does not close `docs/design.md` section 9

`docs/design.md` predicts, for each of 43 hard cases, whether it converts clean,
partial, or into a review task. This report is the first real evidence against
those predictions — but nobody has done the comparison yet, and doing it properly
means a run that did not have to be unstuck by hand. Until then the predictions
stay predictions. See [docs/lab-status.md](../lab-status.md) §1.10.
