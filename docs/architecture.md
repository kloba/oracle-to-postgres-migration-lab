# Architecture and design rationale

Why the lab is shaped the way it is. Nothing here is required to run it — start at
[00 — Prerequisites](00-prerequisites.md) if you want to get moving. Read this if you want to know
why an Oracle VM and not a managed service, what the scratch database is actually for, and what the
conversion tool is really doing when it says it is converting your schema.

- [1. The shape of the problem](#1-the-shape-of-the-problem)
- [2. Why an Oracle VM and not a managed service](#2-why-an-oracle-vm-and-not-a-managed-service)
- [3. Why this target](#3-why-this-target)
- [4. Why a separate scratch database](#4-why-a-separate-scratch-database)
- [5. How the conversion pipeline actually works](#5-how-the-conversion-pipeline-actually-works)
- [6. Where the human stays in the loop](#6-where-the-human-stays-in-the-loop)
- [7. Why this lab insists on validation](#7-why-this-lab-insists-on-validation)
- [8. The gap the tool does not fill](#8-the-gap-the-tool-does-not-fill)
- [9. Why the schema is the size and shape it is](#9-why-the-schema-is-the-size-and-shape-it-is)
- [10. Decisions in one table](#10-decisions-in-one-table)

---

## 1. The shape of the problem

An Oracle to PostgreSQL migration has four separable problems, and conflating them is the most
common way a migration programme loses a quarter.

| Problem | What it means | Who solves it here |
| --- | --- | --- |
| **Schema** | Tables, types, constraints, indexes, partitioning | The Microsoft tool. Generally available |
| **Code** | Packages, procedures, triggers, views, jobs | The Microsoft tool. Application/code conversion is **public preview** |
| **Data** | The actual rows | **Nothing in the Microsoft tool.** A separate step — see section 8 |
| **Application** | Every driver, ORM, error-code check and connection string above the database | Nobody. It is your programme's largest line item |

This lab covers the first two properly, is honest about the third, and deliberately does not
pretend to address the fourth.

The reason to care about the boundary is that the first two are where an LLM helps enormously and
the last two are where it helps least. Schema and code conversion is a translation problem with a
verifiable target: does it compile, and does it behave the same? That is a good fit for a model with
a compiler behind it. Moving 4.5 million rows correctly is a plumbing problem, and rewriting an
application's error handling is a judgement problem.

---

## 2. Why an Oracle VM and not a managed service

The obvious question: Oracle Database@Azure exists, and Oracle Autonomous Database exists. Why put
Oracle on a plain Ubuntu VM and run it in a container?

**1. The lab must be free to run and free to fork.** Oracle Database Free 23ai has no licence cost
and no entitlement check. Oracle Database@Azure is a real Oracle licence with real Oracle pricing,
which would put a public teaching repository behind a procurement conversation. A lab that most
readers cannot run is not a lab.

**2. The source in a real migration is almost never a managed service.** The database people
actually migrate off is a twenty-year-old instance on a server somebody's team owns, with a schema
that grew by accretion, a `LONG` column nobody dares touch, and three hierarchies walked by
`CONNECT BY`. Standing that up on a VM you control is a more faithful simulation than standing up a
pristine managed instance — and it lets the lab do things a managed service would refuse, such as
setting `sessions`, creating a filesystem `DIRECTORY` object for `UTL_FILE`, and running `DBMS_RLS`
policies.

**3. `UTL_FILE` needs a filesystem.** `pkg_etl_export` writes flat extracts through an Oracle
`DIRECTORY` object. That is not incidental colour — it is hard case H-13, and it is one of the more
instructive failures in the lab, because the honest PostgreSQL answer is architectural (there is no
server filesystem on a managed PostgreSQL) rather than syntactic. You cannot exercise it without a
real directory on a real disk.

**4. The tool only ever reads metadata.** The conversion tool connects as `O2P_READER` with
`CONNECT`, `SELECT_CATALOG_ROLE` (or `SELECT ANY DICTIONARY`) and `SELECT` on `SYS.ARGUMENT$`. It
never writes to Oracle and never touches an application table. So the source needs to be
*representative*, not *production-grade*. A container on a VM is representative.

**5. Version choice stays yours.** Microsoft documents 12.1, 12.2, 18c, 19c and 21c as supported
sources. This lab defaults to Oracle Database Free 23ai, which is **not** on that list — and neither
is it on the list in Microsoft's own `mslearn-postgresql` lab, which also deploys 23ai. Rather than
paper over that, the lab makes `ORACLE_IMAGE` a variable so you can pin 19c or 21c and stay inside
the documented matrix. A container image is a one-line change; a managed service is not.

The cost of this choice is honest too: you own the VM. Patching, backup and the fact that it bills
whether or not you are using it are all yours, which is exactly why
[`scripts/destroy.sh`](../scripts/destroy.sh) is so prominent in the documentation.

---

## 3. Why this target

**Azure Database for PostgreSQL flexible server, PostgreSQL 15 or later.** Three constraints
converge on it:

1. The conversion tool **requires** flexible server 15+ for its scratch database. Azure HorizonDB is
   explicitly not supported in that role — it *is* supported as a conversion target from extension
   v1.27.x, which is a distinction worth keeping straight.
2. `MERGE` arrived in PostgreSQL 15. Four places in CONTOSO use Oracle `MERGE` (hard case H-07), and
   whether that converts cleanly or becomes a pile of `INSERT … ON CONFLICT` depends entirely on the
   target version.
3. Flexible server is where the extension allowlist lives. Single server is retired; a container or
   a VM-hosted PostgreSQL would let you install anything, which would make the lab *easier* and
   therefore wrong — the `azure.extensions` allowlist is a real constraint that real migrations hit,
   and one of its members fails open (section 7).

The template deploys 16. The lab is written against 15+ throughout.

---

## 4. Why a separate scratch database

This is the piece of the architecture people most often mistake for an implementation detail.

The tool does not translate your schema and hand you a file. It **compiles what it produced**,
against a real PostgreSQL server, before it shows you anything. To do that it needs somewhere it can
create and drop objects freely. That is the scratch database, and the tool creates and drops schemas
prefixed `_mig_scratch_` inside it.

Why it must not be your target database:

| Reason | Consequence if you point it at the target |
| --- | --- |
| The tool creates and drops schemas at will | Object churn in the database you are trying to build |
| Failed compilations are the normal case, not the exception | Partial objects, dropped and recreated, in your golden target |
| Compilation is repeated across the fix loop | `pg_catalog` bloat from create/drop churn |
| Several people may share a lab | One person's run drops another's scratch schema |
| The target should be reproducible from reviewed DDL | If the tool wrote directly to it you can never say what is in there |

The requirement is its own **database**, not its own **server**. This lab creates
`migration_scratch` alongside `contoso_store` on the same flexible server, which is cheaper and
means the server-level `azure.extensions` allowlist covers both automatically. If several people
share the lab, give scratch its own server — and give it the *same* allowlist and the *same*
`shared_preload_libraries`, because the scratch server is where validation actually runs. A scratch
server without `plpgsql_check` produces a flattering report about a target that was never checked.

There is a quieter reason too. Because compilation happens somewhere disposable, the tool can afford
to be wrong and try again. That is what makes the fix loop in the next section possible at all: the
cost of a failed attempt is a dropped schema, not a corrupted target.

---

## 5. How the conversion pipeline actually works

It is not "send the DDL to an LLM and print the answer". It is a hybrid: deterministic parsing where
determinism is possible, a model where it is not, and a compiler as the arbiter.

```text
   Oracle (CONTOSO)
        │
        │  read-only metadata: SELECT_CATALOG_ROLE + SYS.ARGUMENT$
        ▼
  ┌───────────────────────────────────────────────────────────────────┐
  │ 1. EXTRACT + PARSE                            deterministic       │
  │    Read the data dictionary. Build an object graph with real      │
  │    dependency edges: types before tables, tables before packages, │
  │    packages before the views that call them.                      │
  └───────────────────────────────────────────────────────────────────┘
        ▼
  ┌───────────────────────────────────────────────────────────────────┐
  │ 2. RULE-BASED TRANSLATION                     deterministic       │
  │    Everything with one right answer: VARCHAR2 -> varchar,         │
  │    NUMBER(9) -> the appropriate numeric, ORGANIZATION INDEX       │
  │    dropped, sequence clauses mapped one to one.                   │
  │    Same input, same output, every run. No tokens spent.           │
  └───────────────────────────────────────────────────────────────────┘
        ▼
  ┌───────────────────────────────────────────────────────────────────┐
  │ 3. LLM TRANSLATION                            Microsoft Foundry   │
  │    Everything with a judgement in it: PL/SQL bodies, CONNECT BY   │
  │    to WITH RECURSIVE, compound triggers, collection mappings,     │
  │    dynamic SQL. This is where your TPM quota goes.                │
  └───────────────────────────────────────────────────────────────────┘
        ▼
  ┌───────────────────────────────────────────────────────────────────┐
  │ 4. COMPILE ON SCRATCH                         ground truth        │
  │    Apply the candidate DDL to a _mig_scratch_ schema on the       │
  │    scratch server. The PostgreSQL parser is the judge. An LLM     │
  │    cannot argue with a syntax error.                              │
  └───────────────────────────────────────────────────────────────────┘
        ▼
  ┌───────────────────────────────────────────────────────────────────┐
  │ 5. DEEP VALIDATION                            plpgsql_check       │
  │    Compiling is a low bar: PL/pgSQL bodies are only parsed, not   │
  │    semantically checked, until they run. plpgsql_check inspects   │
  │    the body — unknown columns, type mismatches, unreachable code, │
  │    missing RETURN.                                                │
  │    *** If plpgsql_check is not allow-listed this step is SKIPPED  │
  │        SILENTLY. No error. No warning in the report. ***          │
  └───────────────────────────────────────────────────────────────────┘
        ▼
     ┌──────────────┐   errors    ┌──────────────────────────────────┐
     │  clean?      │────────────▶│ 6. AI FIX LOOP                   │
     │              │             │    Feed the compiler and checker │
     │              │◀────────────│    diagnostics back to the model │
     └──────┬───────┘   retry     │    with the failing object.      │
            │ yes                 │    Bounded: a few attempts, then │
            │                     │    give up and escalate.         │
            │                     └───────────────┬──────────────────┘
            │                                     │ still failing
            ▼                                     ▼
  ┌────────────────────────┐        ┌───────────────────────────────────┐
  │ CONVERTED DDL          │        │ 7. REVIEW TASK                    │
  │ + conversion report    │        │    Flagged, described, handed to  │
  │                        │        │    GitHub Copilot agent mode with │
  │                        │        │    the human in the chair.        │
  └───────────┬────────────┘        └───────────────┬───────────────────┘
              │                                     │
              └──────────────────┬──────────────────┘
                                 ▼
                    HUMAN REVIEW, then apply to
                    contoso_store (schema contoso)
```

### Stage 1 — Extract and parse

Read-only, deterministic, and the reason the Oracle grant list is so small. The object graph matters
more than it sounds: CONTOSO contains a deliberate foreign-key cycle (`region.manager_employee_id →
employee` and `employee.store_id → store → region`), and any converter that emits DDL in strict
dependency order deadlocks on it. Oracle tolerates the cycle because constraints are applied after
all tables exist. Watching whether the tool reproduces that separation is a free, cheap test of how
seriously it takes ordering.

### Stage 2 — Rules before models

Type mappings, storage clauses, sequence options and most constraint syntax have exactly one correct
translation. Running those through a model would be slower, more expensive, and *less* reliable —
a model that translates `VARCHAR2(30)` correctly 99.9% of the time is worse than a lookup table that
does it correctly every time, because you have ~1,855 objects and 0.1% is one silent defect.

This is the single most important architectural point about the tool: **the LLM is used where
determinism is impossible, not everywhere.**

### Stage 3 — The model

Foundry, in your subscription, on your quota. What lands here is the genuinely hard material: PL/SQL
procedural bodies, hierarchical queries, collection semantics, trigger restructuring, dynamic SQL.
This is why 500,000 TPM is the recommendation and why a ~1,855-object schema throttles badly below
it.

Model choice is one of the two conflicts the lab records rather than hides: Learn documents
`gpt-5.2`, Microsoft's own lab template ships `gpt-5-mini`. The 2026-09-02 deployment settled the
deployability half — `gpt-5.2` was created for real in `swedencentral` at version `2025-12-11` — so
what is left open is only which of the two to *use*. Results are not comparable across models, so
record which one produced them at the top of any results you keep.

### Stage 4 — The compiler is the arbiter

Candidate DDL goes to a real PostgreSQL server. This is the step that separates this tool from a
chat window: the output is checked by something that cannot be persuaded. An LLM can be argued into
agreeing that invalid syntax is valid; `postgres` cannot.

### Stage 5 — `plpgsql_check`, and why it is load-bearing

PostgreSQL only *parses* a PL/pgSQL body at creation time. It does not check that the columns exist,
that the types line up, or that every path returns. A function referencing a column you renamed will
`CREATE` perfectly happily and fail the first time that branch executes — possibly in production, six
weeks later.

`plpgsql_check` walks the body and catches that class of defect statically. For a schema whose whole
point is 25 converted package bodies, it is the difference between "it compiled" and "it is
plausibly correct".

**And it fails open.** If the extension is not in the `azure.extensions` allowlist, this stage is
skipped silently: no error, no warning, nothing in the report to tell you validation did not happen.
The result looks *better*, not worse. Section 7 is about what that implies.

### Stage 6 — The fix loop

Compiler and checker diagnostics are fed back to the model along with the failing object, and it
tries again. This is the part that most resembles how a human works, and it is bounded on purpose:
after a few attempts the object is escalated rather than retried forever. Unbounded retry loops on a
metered model are how you turn a conversion run into an invoice.

### Stage 7 — Review tasks

What the loop cannot fix becomes a **review task**: flagged, described, and handed to GitHub Copilot
agent mode with a human in the chair. Agent mode can read the surrounding schema, propose a change,
and apply it — but it is interactive by design, because these are the items where the right answer
depends on facts that are not in the database.

`pkg_audit` is the canonical example. It uses `PRAGMA AUTONOMOUS_TRANSACTION` so audit rows survive
a rollback of the change they describe. PostgreSQL has no autonomous transactions. You can emulate
them with a `dblink` self-connection — which opens a new connection per call, acceptable for error
logging and catastrophic for a per-row audit trigger. Or you can accept that audit rows now roll
back with the transaction, which is a *behaviour change your compliance function has to sign off*.
No tool can make that call, and any tool that made it silently would be dangerous.

Roughly a quarter of the hard cases in [`design.md`](design.md) section 9 are predicted to land
here. That is not a criticism of the tool. It is what the work actually is.

---

## 6. Where the human stays in the loop

Four places, and they are not optional.

**Before the run: allowlisting.** `plpgsql_check` must be enabled before the first conversion, not
after. A report produced without it cannot be repaired retrospectively — you would have to run
again, and you would have already formed an impression.

**At review tasks: the design decisions.** Nested table to array-of-composite or to a proper child
table? `DETERMINISTIC` to `IMMUTABLE` or to `STABLE`? Widen a primary key or abandon partitioning?
Each of these has a right answer that depends on how the data is queried, and none of that is in the
data dictionary.

**After the run: differential testing.** The cases most likely to convert *silently wrong* are
exactly the ones a compiler cannot catch — `ROWNUM` versus `LIMIT` (H-30), Oracle `(+)` outer joins
mixed with filter predicates (H-32), and empty string being `NULL` (H-38). All three produce code
that compiles and runs and returns a *different row count*. `tests/` runs the same business questions
against both databases and diffs the answers, because reading the SQL is not evidence.

**Throughout: judging the report.** Which brings us to the caveat Microsoft itself publishes:

> "AI systems can occasionally confirm their own mistakes."
>
> — Microsoft, [Schema conversion overview](https://learn.microsoft.com/en-us/azure/postgresql/migrate/oracle-conversions-schema/schema-conversions-overview)

That sentence is doing more work than its length suggests, and it is unusually candid for vendor
documentation.

The failure mode it describes is not hallucination. It is *self-consistency*. The same model that
produced a translation is well placed to produce a confident explanation of why that translation is
correct — because the reasoning that generated the error and the reasoning that assesses it are the
same reasoning. A model that converts `DETERMINISTIC` to `IMMUTABLE` because the words look
equivalent will, asked to review its work, explain that `DETERMINISTIC` and `IMMUTABLE` are
equivalent. It is not lying. It is being consistent, and consistency is not correctness.

This is precisely why stages 4 and 5 exist and why they are not the model. A compiler and a static
checker are *external* sources of truth. They have no stake in the translation being right and no
memory of why it was produced.

---

## 7. Why this lab insists on validation

Three concrete reasons, all of them earned rather than theoretical.

**1. A fail-open validator makes everything look easy.** [`design.md`](design.md) section 9 predicts
roughly 10 clean cases, 21 partial, and 12 needing a human. If your run comes back dramatically
better than that, the first hypothesis is not that the tool exceeded expectations — it is that
`plpgsql_check` was never allowlisted and stage 5 never ran. The lab writes the predictions down
*before* measuring precisely so that an implausibly good result is recognisable as implausible.

**2. Compiling is a low bar, and the interesting failures clear it.** Look at the shape of the hard
cases. `RESULT_CACHE` (H-24) is simply dropped: the function compiles, returns correct answers, and
is slower — a defect you discover in load testing, not at conversion. `UTL_FILE` (H-13) may emit
orafce calls that compile and then fail at runtime because managed PostgreSQL has no filesystem.
Optimiser hints (T-06) are comments to PostgreSQL: silently ignored, no error, different plan. Every
one of those passes "did it compile".

**3. Prediction before measurement, and the measurement wins.** Section 9 of the design contract is
a set of falsifiable claims. [05 — Validate](05-validate.md) records what actually happened, and
where the two disagree the finding wins and the prediction gets corrected in the same pull request.
A lab that only ever confirms its own expectations has the same defect as the AI system it is
studying.

That is the pedagogical core of this repository. The interesting output of a conversion run is not
the converted DDL. It is a calibrated sense of which categories of construct you can trust a machine
with and which you cannot — and you only get that by writing predictions down first and being
willing to be wrong in public.

---

## 8. The gap the tool does not fill

**The conversion tool moves schema and code. It does not copy a single table row.**

That is not a defect, it is scope. But it means "we ran the migration tool" and "we migrated" are
different statements, and a lab that stopped at converted DDL would be teaching a dangerous half-truth.

So the lab adds its own data step, and treats it as a first-class stage rather than an appendix:

| Option | Good for | Watch out for |
| --- | --- | --- |
| **`ora2pg`** (the lab's default, `DATA_MOVE_TOOL`) | One-shot bulk copy, mature Oracle type handling | Slow on very large tables; needs an Oracle client |
| `pgloader` | Fast bulk load | Weaker Oracle type coverage |
| Partner CDC tools | Near-zero-downtime cutover | Cost, and a whole operational model |

Even at lab scale this is not a formality. `store.legacy_migration_notes` is a `LONG` column (hard
case H-33), and `LONG` cannot be used in most SQL expressions, cannot be selected across a database
link, and is unreadable by many drivers — which is why Oracle deprecated it decades ago and why data
movement tools choke on it. One column, disproportionate pain, entirely realistic. The usual answer
is a pre-migration `ALTER TABLE … MODIFY … CLOB` on the *source*, which is a change to a production
system before the migration has started.

That is the kind of thing you want to discover in a lab.

---

## 9. Why the schema is the size and shape it is

**Why at least 1,000 objects.** Below a few hundred, a conversion run tells you almost nothing about
the tool's behaviour at scale: throttling, dependency-ordering, report readability and the fix
loop's failure modes only appear in bulk. A thousand is also roughly where the report stops being
something you read end to end and starts being something you have to query — which is itself a
finding about the workflow.

**Why the split is ~350 hand-written and ~792 generated.** The hand-written core is a coherent
retail domain: ten subject areas, 45 core tables, four separate hierarchies, real business logic in
25 packages. It has to be believable, because a converter facing plausible code behaves differently
from one facing obvious test fixtures. The generated bulk provides scale without asking anyone to
hand-write 792 more objects — and about 15% of the generated objects deliberately carry a hard case,
so scale testing stresses the difficult paths rather than 792 copies of the easy one.

**Why the generator is deterministic.** Same `GEN_SEED`, byte-identical output, on any machine. The
lab's value comes from diffing conversion reports — across runs, across models, across extension
versions. Generator drift would make every one of those comparisons meaningless.

**Why the counting rule excludes partitions and LOBs.**

```sql
SELECT COUNT(*) FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION');
```

Partition and LOB segments are storage artefacts, not constructs a converter has to reason about.
Counting them would let the lab hit its target by adding partitions instead of adding difficulty,
and the total would drift with the seed date because three tables are interval-partitioned. The
per-type budget sums to 1,120 against a floor of 1,000, and a loaded schema runs higher still —
about **1,855** by this rule, of which roughly **1,480** are non-partition objects and the rest
subpartitions that move with data volume. The budget exists to guarantee the 1,000 floor by
construction; a lab that only just cleared it would be one that fails on somebody else's machine.

**Why the hard cases are placed where they are.** The two most disruptive items sit on the two
busiest tables on purpose. `sales_order` and `purchase_order` have primary keys that do not include
the partition key — legal in Oracle with a global index, flatly impossible in PostgreSQL, where every
unique constraint on a partitioned table must include all partition columns. There is no workaround
that preserves both the key and the partitioning. You widen the primary key and fix every foreign
key that referenced it. Putting that on a lookup table would make it a curiosity; putting it on the
order tables makes it the schedule risk it really is.

---

## 10. Decisions in one table

| Decision | Alternative rejected | Why |
| --- | --- | --- |
| Oracle Free 23ai on a VM | Oracle Database@Azure, Autonomous | Free, forkable, and closer to what people actually migrate from |
| Ubuntu VM + container | Oracle on bare metal | Reproducible, one-line version pin via `ORACLE_IMAGE` |
| PostgreSQL flexible server 16 | HorizonDB, container PostgreSQL | 15+ required for scratch; `MERGE` needs 15; the extension allowlist is a real constraint worth exercising |
| Scratch as a second database on one server | A second flexible server | Cheaper, and one server-level allowlist covers both. Separate server if the lab is shared |
| Private access, no public endpoint | Public endpoint plus firewall rules | Matches what a security review would demand, and forces the jumpbox pattern to be real |
| NAT gateway | Default outbound access | Azure retired default outbound in September 2025. Without it, image pulls and Marketplace hang |
| Windows x64 jumpbox by default | Run VS Code locally | ARM64 is unsupported on Windows and Linux, and the thick-client documentation says "Windows and Linux only". Removes a class of platform debugging |
| Deterministic Python generator, stdlib only | Faker, or hand-writing 792 objects | Byte-identical output across machines; no PyPI egress needed on the jumpbox |
| Predictions written before measurement | Reporting only what happened | Makes the lab falsifiable, and makes an implausibly good result recognisable |
| Conflicts documented, not resolved | Quietly picking a side | Two upstream conflicts (model name, RBAC role name) are genuinely unresolved. Readers hitting them deserve to know they are not going mad |
| `ora2pg` as the data step | Pretending the tool moves data | It does not. Any end-to-end story that implies otherwise is wrong |

---

## Further reading

| Document | What it covers |
| --- | --- |
| [`design.md`](design.md) | The binding contract: naming, table catalogue, all 43 hard cases with predictions |
| [00 — Prerequisites](00-prerequisites.md) | Everything needed before spending money |
| [01 — Deploy the infrastructure](01-deploy-infrastructure.md) | The Azure side, resource by resource |
| [02 — Seed the Oracle source](02-seed-oracle.md) | Building CONTOSO and proving it is complete |
| [03 — Run the AI migration](03-run-ai-migration.md) | Driving the extension, GA scope versus preview scope, and working the review-task queue with Copilot agent mode |
| [04 — Migrate the data](04-migrate-data.md) | The step the tool does not do |
| [05 — Validate](05-validate.md) | Proving the converted database answers the same questions as the source |
| [troubleshooting.md](troubleshooting.md) | Symptom to cause to fix, across every stage |
