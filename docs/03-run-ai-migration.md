# 03 — Run the AI migration

Point the AI-assisted converter at `CONTOSO` and read what it gives back. This is the stage the
rest of the lab exists to set up.

- [What this stage does, and what it does not](#what-this-stage-does-and-what-it-does-not)
- [1. Before you start](#1-before-you-start)
- [2. Install the extension — and check you got the right one](#2-install-the-extension--and-check-you-got-the-right-one)
- [3. The four connections](#3-the-four-connections)
- [4. Create the migration project](#4-create-the-migration-project)
- [5. Run the schema conversion](#5-run-the-schema-conversion)
- [6. Read the report](#6-read-the-report)
- [7. Work the review queue with Copilot agent mode](#7-work-the-review-queue-with-copilot-agent-mode)
- [8. What CONTOSO will actually put in the queue](#8-what-contoso-will-actually-put-in-the-queue)
- [9. Application and code conversion (public preview)](#9-application-and-code-conversion-public-preview)
- [10. Apply to the target](#10-apply-to-the-target)
- [11. Troubleshooting](#11-troubleshooting)

---

## What this stage does, and what it does not

> **The tool converts schema and code. It does not copy a single table row.**
>
> When this stage finishes you will have a `contoso` schema in `contoso_store` containing tables,
> constraints, indexes, views, functions, procedures and triggers — and **no data at all**. Closing
> that gap is [04 — Migrate the data](04-migrate-data.md), which the lab treats as a first-class
> step rather than an appendix.

Two more distinctions worth keeping straight in your own notes, because they are easy to blur once
you are inside the same wizard:

| Capability | Status | What it covers |
| --- | --- | --- |
| **Schema conversion** | **Generally available**, extension v1.23.0 (2026-05-26) | Tables, constraints, indexes, sequences, views, materialised views, synonyms, packages, procedures, functions, triggers, types |
| **Application and code conversion** | **Public preview** | Loose files: `.sql`, `.ctl`, `.sh`, `.load`, `.java` |

Both are used in this lab. Do not describe the second one as GA in anything you publish from your
results — it is not, and the distinction matters to anyone planning a real migration around it.

### How the conversion actually works

Understanding the pipeline is what lets you interpret the report instead of just believing it.

```text
   Oracle CONTOSO                                   PostgreSQL flexible server
   (metadata only,                          ┌──────────────────────────────────┐
    read by O2P_READER)                     │  migration_scratch               │
          │                                 │  ┌────────────────────────────┐  │
          │  1. rule-based parse            │  │  _mig_scratch_<run>        │  │
          ▼     the deterministic half      │  │  throwaway schema          │  │
   ┌─────────────┐                          │  └────────────────────────────┘  │
   │  extension  │  2. LLM translation      │                                  │
   │  ms-ossdata │ ──────────────────────▶  │  3. COMPILE it here              │
   │ .vscode-pgsql│    Microsoft Foundry    │  4. plpgsql_check over it        │
   └─────────────┘                          └──────────────────────────────────┘
          │                                                │
          │  5. automated fix loop  ◀──────────────────────┘  errors feed back
          ▼
   ┌─────────────────────────────────────────────┐
   │  converted DDL   +   report   +   review     │  6. what does not converge
   │                                     tasks   │     becomes a review task
   └─────────────────────────────────────────────┘
                          │
                          ▼  7. you, with GitHub Copilot agent mode
```

Steps 3 and 4 are the reason a scratch database exists. Without them the output is a language
model's guess written to a file. With them, every object the tool calls "done" has at least
compiled somewhere. That is a much stronger claim, and it is the claim that the next section can
silently take away from you.

---

## 1. Before you start

Nine things. The first one is the one that ruins runs.

### 1.1 `plpgsql_check` is **fail-open** — check it first

If `plpgsql_check` is not in the `azure.extensions` allowlist, the tool **skips its deeper
validation silently**. No error. No warning. Nothing in the report says validation did not run. You
get a clean-looking result that was never checked, and you find out weeks later when converted
PL/pgSQL fails at runtime.

There is no way to retro-fix a report produced without it. The run has to be repeated.

```bash
az postgres flexible-server parameter show \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --server-name "$(jq -r .postgresServerName generated/outputs.json)" \
  --name azure.extensions --query value --output tsv
```

`plpgsql_check` must appear in that list. It must also be in `shared_preload_libraries`, which is a
static parameter and therefore needed a server restart:

```bash
az postgres flexible-server parameter show \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --server-name "$(jq -r .postgresServerName generated/outputs.json)" \
  --name shared_preload_libraries --query value --output tsv
```

Empty output means the restart never happened. Fix both before you run anything.
`./scripts/status.sh` checks the allowlist for you and says so loudly when it is short.

You do **not** need to `CREATE EXTENSION plpgsql_check` in `contoso_store` yourself. The check runs
on the scratch database and the tool installs the extension there. The allowlist and the preload
library are what you owe it; the extension object is not.

### 1.2 The rest of the checklist

| # | Check | How |
| --- | --- | --- |
| 2 | The seed finished and asserted itself | The last line of `seed-oracle.sh` reports the object count against the floor of 1000, and `src/oracle/99-verify-objects.sql` passed |
| 3 | **Zero invalid objects** in `CONTOSO` | See below — this one is not optional |
| 4 | The scratch database exists | `./scripts/connect.sh scratch -c '\l'` lists `migration_scratch` |
| 5 | `O2P_READER` exists and can read the dictionary | `./scripts/connect.sh oracle-azure --reader -c 'SELECT COUNT(*) FROM all_objects;'` |
| 6 | Oracle `sessions` > 10 | `./scripts/connect.sh oracle-azure --system -c "SELECT value FROM v\$parameter WHERE name='sessions';"` |
| 7 | A GitHub Copilot **Pro+, Business or Enterprise** seat | Copilot chat in VS Code offers **Agent** in its mode picker. Free and Pro do not |
| 8 | The Foundry data-plane role is granted to *you* | [01 § 6.2](01-deploy-infrastructure.md#62-grant-yourself-the-foundry-data-plane-role) |
| 9 | Outbound HTTPS to **four** destinations | [00 § 9](00-prerequisites.md#9-network-egress) — the `github.com/microsoft/pgsql-tools/` one is the one that gets missed |

**On check 3.** An invalid package body is worse than a missing one. The tool reads it as source
text and translates it anyway, producing a converted object that is syntactically fine and
semantically wrong, and nothing in the report distinguishes it from an object that was healthy.
Do not convert a schema with invalid objects:

```sql
SELECT object_type, object_name FROM user_objects WHERE status = 'INVALID';
EXEC UTL_RECOMP.RECOMP_SERIAL('CONTOSO');   -- then re-check
```

---

## 2. Install the extension — and check you got the right one

**There is no separate "Oracle to PostgreSQL" extension, and there is no product called a
"migration copilot".** The conversion is a feature of the **PostgreSQL extension for Visual Studio
Code**:

| Field | Value |
| --- | --- |
| Extension ID | `ms-ossdata.vscode-pgsql` |
| Publisher | **Microsoft** |
| Minimum for schema conversion | v1.23.0 |
| VS Code | 1.95.2 or later |

The Marketplace has several third-party PostgreSQL extensions with similar names and icons. Check
the publisher, not the name. From the command line:

```bash
code --install-extension ms-ossdata.vscode-pgsql
code --list-extensions --show-versions | grep vscode-pgsql
```

### Where to run it

| Platform | Supported |
| --- | --- |
| Windows x64 | Yes — the lab's jumpbox |
| Linux x64 | Yes |
| macOS 13+ | Listed as supported |
| Windows/Linux **ARM64** | **No** |

Apple Silicon is genuinely risky here: the overview page's thick-client section also says "Windows
and Linux only", which contradicts the macOS support line. The lab deploys `o2p-jump`, a Windows
x64 VM, so you do not have to gamble on which statement is current. RDP into it through Bastion:

```bash
az network bastion rdp \
  --name "$(jq -r .bastionName generated/outputs.json)" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --target-resource-id "$(jq -r .jumpboxVmId generated/outputs.json)"
```

Sign in to GitHub Copilot inside VS Code before going further. Agent mode has to be available
*before* the conversion produces its review queue — discovering it is missing afterwards is the
expensive ordering.

---

## 3. The four connections

The conversion needs four endpoints. Three of them are private, so from anywhere except the jumpbox
they go through Bastion.

| # | Endpoint | What it is | Credentials |
| --- | --- | --- | --- |
| 1 | Microsoft Foundry | The model deployment that does the translating | Your own Entra identity + the data-plane role |
| 2 | Oracle source | `CONTOSO` metadata, read-only | `O2P_READER` |
| 3 | Scratch PostgreSQL | `migration_scratch` — compile and validate | `PGUSER` / `SCRATCH_PGUSER` |
| 4 | Target PostgreSQL | `contoso_store` — where converted DDL lands | `PGUSER` |

### 3.1 Foundry

```bash
jq -r '.foundryEndpoint, .foundryDeploymentName' generated/outputs.json
```

Two things about this that are contested upstream, and the lab records both rather than picking:

**The model.** Microsoft Learn says the deployment must be **`gpt-5.2`**; Microsoft's own
`mslearn-postgresql` lab ARM template defaults to **`gpt-5-mini`**. Both are real, current
Microsoft statements — and `gpt-5.2` is now **verified deployable in `swedencentral` (2026-09-02,
version `2025-12-11`)**, so the only open choice is which of the two to *use*. The lab makes it the
`FOUNDRY_MODEL_NAME` parameter and defaults to `gpt-5.2`, following Learn; availability varies by
region, so preflight checks it. Check what you actually deployed:

```bash
az cognitiveservices account deployment list \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --name "$(jq -r .foundryAccountName generated/outputs.json)" \
  --query "[].{name:name, model:properties.model.name, version:properties.model.version, capacity:sku.capacity}" \
  --output table
```

Write down which one you used. Conversion results are not comparable across models, so the model
name belongs at the top of any result you record in [05 — Validate](05-validate.md).

**The role.** Current Microsoft Foundry documentation calls the data-plane role **Foundry User**.
DP-300 lab 18 says **Cognitive Services OpenAI User**. Grant whichever your tenant offers, and grant
both if both exist:

```bash
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "$(jq -r .foundryAccountId generated/outputs.json)" \
  --query "[].roleDefinitionName" --output tsv
```

Capacity: the lab asks for 500,000 TPM (`foundryModelCapacity: 500`). Below that the tool spends its
time in retry backoff on a schema this size. It still finishes; it is just a miserable afternoon.

**The authentication method, and why the API Key box may be a trap.** The wizard's *Choose a
Microsoft Foundry Model* step offers **API Key** and **Microsoft Entra Id**. API Key looks like the
easy path — the key is one `az` call away — but on a governed tenant it cannot work at all:

```
Azure OpenAI connection test failed: Key based authentication is disabled for this resource.
```

`infra/modules/foundry.bicep` asks for `disableLocalAuth: false`. The deployed resource came back
`true` anyway, and re-setting it through ARM silently had no effect. The reason is a policy
assignment, which you can see for yourself:

```bash
az policy state list --resource "$(jq -r .foundryAccountId generated/outputs.json)" \
  --query "[].{policy:policyDefinitionName, effect:policyDefinitionAction}" --output table
```

On the tenant this lab was built against that lists `CognitiveServices_LocalAuth_Modify` with a
**`modify`** effect: it rewrites `disableLocalAuth` to `true` on every write, so the template never
gets the last word and nothing in the deployment output says so. **Choose Microsoft Entra Id**,
select your account and tenant, and the same Test button turns green. That is also the path the role
assignment above exists for — with API Key the role is never consulted.

### 3.2 Oracle source

The tool reads **metadata only**. It never writes to Oracle and needs no privilege on application
tables. `O2P_READER` holds exactly:

- `CONNECT`
- `SELECT_CATALOG_ROLE` **or** `SELECT ANY DICTIONARY`
- `SELECT` on `SYS.ARGUMENT$` — easy to miss, and without it packaged routine arguments come back
  empty, which the tool reports as "no parameters" rather than as an error

Oracle's `sessions` parameter must be greater than 10; the extension opens parallel metadata reads.

**And it must be able to read `V$RESOURCE_LIMIT`.** This one is not in Microsoft's prerequisite
list and it is the difference between a conversion and a blank screen. Before the extractor
enumerates a single object it sizes its connection pool by asking how many sessions are free, in
`connection_pool.auto_detect_workers()`. Without the privilege that query raises

```text
ORA-00942: table or view "SYS"."V_$RESOURCE_LIMIT" does not exist
```

the pool never initialises, and the UI says only **Extraction Failed** — the run ends `0 extracted,
0 failed, 0 excluded` and the reason is buried in
`artifacts/oracle/<SCHEMA>/extract/internal/logs/extraction.log`. That is exactly how the first real
run of this lab failed. `scripts/seed-oracle.sh` now makes the grant as `SYSDBA` straight after
`00-user-tablespace.sql`; by hand it is:

```sql
ALTER SESSION SET CONTAINER = FREEPDB1;
GRANT SELECT ON sys.v_$resource_limit TO contoso;   -- v_$, not v$: you cannot grant on a synonym
```

The view returns **zero rows inside a PDB** — it is a CDB-level view. That is fine. The extractor
logs `Auto-detected workers: 5 (sessions: 0/0, available: 0)` and carries on. It is the missing
privilege that is fatal, not the empty result.

From the jumpbox the Oracle VM is directly reachable on the VNet at `10.42.1.10:1521`, service
`FREEPDB1`. From your own machine, open a tunnel and point the extension at `localhost`:

```bash
./scripts/connect.sh oracle-azure --tunnel-only --port 15210
```

> **Version note, stated honestly.** Microsoft documents 12.1, 12.2, 18c, 19c and 21c as supported
> Oracle sources. This lab — like Microsoft's own `mslearn-postgresql` lab — runs Oracle Database
> Free **23ai**, which is not on that list. It works, and it is what the official sample deploys,
> but it is outside the documented matrix. Set `ORACLE_IMAGE` to a 19c or 21c image if you need to
> stay strictly inside it.

### 3.3 Scratch and target

Both are databases on the **same** flexible server. There is no separate scratch host:

```bash
jq -r '.postgresFqdn, .postgresDatabaseName, .postgresScratchDatabaseName' generated/outputs.json
```

```text
postgresFqdn                 o2p-pg-<uniq>.postgres.database.azure.com
postgresDatabaseName         contoso_store
postgresScratchDatabaseName  migration_scratch
```

So `SCRATCH_PGHOST` equals `PGHOST`. If you are hunting for a second hostname, there isn't one —
`infra/main.bicep` creates both databases on one server precisely so that `azure.extensions` and
`shared_preload_libraries`, which are server-level, are configured once and apply to both.

The server has no public endpoint. From your own machine:

```bash
./scripts/connect.sh postgres --tunnel-only --port 15432
# then point the extension at localhost:15432, database contoso_store
./scripts/connect.sh scratch  --tunnel-only --port 15433
```

Through a tunnel you are connecting to `127.0.0.1`, so the server certificate's CN cannot match.
Use `sslmode=require` — encrypted, no hostname check. `verify-full` will fail and it is not a
misconfiguration.

The tool creates and drops schemas named `_mig_scratch_*` in the scratch database. Two people
running conversions against the same scratch database at the same time will interfere with each
other. If you are sharing a lab, that is the one case that justifies a second server — and it needs
the same allowlist and the same preload libraries, especially `plpgsql_check`.

**Allowlisting is not installing.** `azure.extensions` decides what you are *permitted* to create.
Nothing in the template runs `CREATE EXTENSION`, and ARM has no resource that does, so a correctly
deployed server still contains nothing but `plpgsql`. The wizard's **Verify Extensions** button is
where you find out:

> The following recommended Azure Database for PostgreSQL extensions are not installed in database
> "migration_scratch": orafce, pg_partman, pgcrypto, postgis, postgis_tiger_geocoder,
> postgis_topology, tablefunc, uuid-ossp, pg_trgm

Run the installer before you open the wizard, and it turns into **✓ Extensions Verified**:

```bash
./scripts/install-pg-extensions.sh              # from the jumpbox
PGHOST=127.0.0.1 PGPORT=15432 ./scripts/install-pg-extensions.sh   # over a tunnel
```

That script also does the one check `deploy.sh` and `status.sh` cannot: it asks the *running server*
`SHOW shared_preload_libraries` rather than asking ARM whether a restart is pending. ARM is not the
server, and `plpgsql_check` fails open — if it is not in memory the converter skips its deeper
validation silently and the report looks clean.

---

## 4. Create the migration project

In VS Code, open the PostgreSQL extension's view and start a new Oracle migration. The wizard asks
for the four connections above in roughly that order, then for a scope.

> Exact command titles and button labels move between extension releases. This document describes
> the shape of the flow, not a fixed sequence of clicks; if a label here does not match what you
> see, the flow is still the same and the
> [Learn walkthrough](https://learn.microsoft.com/en-us/azure/postgresql/development/vs-code-extension/oracle-migration)
> is the authority on the current UI.

**Scope: one schema, `CONTOSO`.** Do not point it at the whole database. `SYS`, `SYSTEM` and the
sample schemas add thousands of objects that are not yours to migrate and will dominate both your
token bill and your report.

The tool will enumerate the source. It reports the schema's real objects — **around 1,480** — which
is fewer than the **~1,855** that `99-verify-objects.sql` counts under the contract rule, because
that rule also counts the composite-partition subpartitions and the converter does not. Both clear
the contract floor of 1,000 (the per-type design budget is 1,120). Take the exact figure from your
own seed run rather than from this page; it moves as the generated half is tuned and as data volume
changes the subpartition count. If it reports drastically fewer, the project is either scoped to the
wrong schema or connected as an account without `SELECT_CATALOG_ROLE`.

Set the target schema to **`contoso`**, lower case. Oracle folds unquoted identifiers to upper case
and PostgreSQL folds them to lower; letting the tool carry `CONTOSO` through as a quoted upper-case
schema name means every hand-written query you try afterwards needs quoting too. This is trap T-07
in [`design.md`](design.md) section 10, and the lab's one deliberately quoted mixed-case table
(`"StoreAudit_Legacy"`) is there to make you meet it under controlled conditions rather than by
accident across the whole schema.

---

## 5. Run the schema conversion

Start the conversion and leave it alone. On ~1,480 convertible objects at 500,000 TPM, expect
**45–90 minutes**. On lower quota, considerably longer — it does not fail, it backs off.

What you should see happening, in order:

1. **Enumeration and rule-based parsing.** Fast, deterministic, no model calls. Tables, columns,
   constraints and indexes mostly resolve here.
2. **LLM translation.** The long phase. PL/SQL bodies go to the Foundry deployment.
3. **Compilation in `migration_scratch`.** Watch for `_mig_scratch_*` schemas appearing and
   disappearing — that is the tool working, not a leak.
4. **`plpgsql_check` validation.** Only happens if you did § 1.1.
5. **The automated fix loop.** Compile errors are fed back for another attempt. Most objects that
   are going to converge converge here.
6. **Review tasks.** Whatever did not converge is handed to you.

While it runs, you can watch the scratch side:

```sql
-- ./scripts/connect.sh scratch
SELECT nspname FROM pg_namespace WHERE nspname LIKE '\_mig\_scratch\_%';
SELECT count(*) FROM pg_stat_activity WHERE datname = 'migration_scratch';
```

**Cost.** This is the only usage-billed part of the lab: $5–30 per conversion run with `gpt-5.2`,
roughly a tenth of that with `gpt-5-mini`. An idle deployment costs nothing, so there is no reason
to delete it between runs.

---

## 6. Read the report

The report classifies every object. Read it in this order:

**First: did validation actually run?** If the report has no `plpgsql_check` findings anywhere
across 85 package bodies, that is not a clean schema, that is a skipped check. Go back to § 1.1.
The most dangerous report this pipeline can produce is a flattering one.

**Second: the counts.** Objects in, objects converted, objects flagged. Compare against
`design.md` section 9's headline prediction for the hand-written half: **10 clean, 21 partial,
12 review task** across the 43 hard cases.

**Third: the flagged list**, in the order the tool gives it. Do not re-sort by object type — the
tool's ordering usually puts dependency roots first, and fixing a root often clears several
dependants.

**Fourth: what is silently missing.** This is the part no report has a section for. Check by
difference:

```sql
-- on the target, after applying:  ./scripts/connect.sh postgres
SELECT count(*) FROM information_schema.tables    WHERE table_schema = 'contoso';
SELECT count(*) FROM information_schema.routines  WHERE routine_schema = 'contoso';
SELECT count(*) FROM information_schema.triggers  WHERE trigger_schema = 'contoso';
```

against the source:

```sql
-- ./scripts/connect.sh oracle-azure
SELECT object_type, COUNT(*) FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION')
 GROUP BY object_type ORDER BY 2 DESC;
```

Object types with no PostgreSQL counterpart at all — `SYNONYM`, `JOB`, `PROGRAM`, `SCHEDULE`,
`TYPE BODY`, materialised view logs — will not appear on the target. Whether the tool *told* you
they were dropped, or simply did not mention them, is one of the more interesting findings this lab
can produce. Record it either way.

### Microsoft's own caveat

Microsoft's documentation is unusually candid that AI-generated conversions must be reviewed by a
human before production use. Take that at face value. "The AI said it was fine" is not evidence;
a passing differential test in [05 — Validate](05-validate.md) is.

---

## 7. Work the review queue with Copilot agent mode

Flagged objects become **review tasks**. Each carries the source construct, the tool's attempt, and
why it stopped. You resolve them with **GitHub Copilot agent mode**, which needs a **Pro+, Business
or Enterprise** seat.

The extension offers **Run Task** on a single item and **Run all** on the queue. Both hand the task
to agent mode, which edits the converted code, and — because the scratch database is still
connected — the result gets recompiled and re-checked rather than merely accepted.

**Do not start with Run all.** Run three or four tasks individually first and read what agent mode
did. You are calibrating your own trust, and the tasks in this lab are specifically chosen to
include ones where a *plausible* fix is a *wrong* fix. Once you know what its failure modes look
like on this schema, Run all becomes reasonable for the long tail.

A workable loop per task:

1. Read the Oracle source. Find its `H-` number in [`design.md`](design.md) section 9 and read the
   prediction *before* you look at the fix.
2. Run the task. Read the diff.
3. Ask: does this preserve **semantics**, or only **syntax**? Most bad fixes in this queue compile.
4. If it is wrong, say why in the chat rather than editing by hand. The correction is data.
5. Record predicted versus observed. That table is the actual output of this lab.

Budget **3–8 hours** for the queue if you are reading it properly. That is not overhead; that is
the lab.

---

## 8. What CONTOSO will actually put in the queue

The schema was built to produce this queue. These are predictions from
[`design.md`](design.md) section 9 — when observation disagrees, observation wins and the
prediction gets corrected.

### Certain review tasks

| Case | Construct | Why it cannot convert cleanly |
| --- | --- | --- |
| **H-02** | `PRAGMA AUTONOMOUS_TRANSACTION` | PostgreSQL has no autonomous transaction. The workaround is `dblink` back to the same database — and `dblink` is therefore needed on the **target**, not just on scratch. Present in `pkg_audit` and `pkg_error` |
| **H-15** | Fast-refresh materialised views + refresh group | PostgreSQL has no incremental refresh at all. `REFRESH MATERIALIZED VIEW` is always complete. The three `MLOG$` tables have no counterpart and the refresh group has none either |
| **H-26** | Compound triggers | They exist to solve Oracle's mutating-table problem, which PostgreSQL does not have. A faithful translation preserves machinery for a problem that is gone; a correct one deletes the machinery and keeps the intent |
| **H-05** | Nested table collections | Schema-level `TABLE OF` types with their own storage tables. Array, composite type, or a real table — only a human knows which |
| **H-03** | Object types with member methods and inheritance | No PostgreSQL equivalent for method dispatch or `UNDER` |
| **H-13** | `UTL_FILE` writing to `CONTOSO_EXPORT_DIR` | Managed PostgreSQL has no server filesystem you can write to. Needs redesign, not translation |
| **H-14** | `DBMS_SCHEDULER` jobs, programs, schedules | 6 jobs, 3 programs, 3 schedules — no in-database scheduler on a managed service |
| **H-24** | `RESULT_CACHE` functions | No equivalent. Removing it compiles and quietly changes performance |
| **H-38** | Empty string is `NULL` | Nothing fails. Rows silently move to the other side of `IS NULL`. The worst failure mode in the whole list |
| **H-40** | VPD policies (`DBMS_RLS`) | Row-level security is the answer, but the policy predicate has to be rewritten, not translated |
| **H-43** | Package-level session state | `pkg_pricing.g_price_cache` and friends persist for the session. PostgreSQL has no equivalent |

### The interesting partials

These are more dangerous than the review tasks, because nothing flags them.

| Case | Construct | What quietly changes |
| --- | --- | --- |
| **H-19** | Interval range partitioning with a PK that excludes the partition key | PostgreSQL flatly refuses. The PK must widen to include the partition key — and every foreign key that referenced it follows. A schema-wide change from one table |
| **H-30** | `ROWNUM` versus `ROW_NUMBER()` | The naive `LIMIT` conversion returns a **different set of rows**, not just a different order. `ROWNUM` is applied before `ORDER BY` |
| **H-32** | Oracle `(+)` outer joins | `v_legacy_orders` uses them throughout. Converting `(+)` to the wrong side of a `LEFT JOIN` produces a query that runs and answers differently |
| **H-33** | The `LONG` column | `store.legacy_migration_notes`. Also the reason [04](04-migrate-data.md) is not a one-liner |
| **H-37** | `TIMESTAMP WITH LOCAL TIME ZONE` | 143 columns in the reference build — assertion `A6-l` in [`tests/verify-schema.sql`](../tests/verify-schema.sql) prints the count for *your* build. Oracle normalises to the session zone on read; `timestamptz` does not behave identically |
| **H-06** | `CONNECT BY` over four hierarchies | Becomes a recursive CTE. `CONNECT BY NOCYCLE`, `LEVEL` and `SYS_CONNECT_BY_PATH` each need separate handling |
| **T-06** | Optimiser hints | `/*+ INDEX(...) */` is a comment to PostgreSQL. Silently ignored, no error, different plan |
| **T-09** | `SYSDATE` versus `now()` | `SYSDATE` does not advance within a statement; `clock_timestamp()` does, `now()` does not. Picking the wrong one changes audit timestamps |

### And then there is the generated half

About 15% of the ~792 generated objects deliberately embed one of these same constructs. That is
the point of them: a converter facing 792 copies of one easy template is pattern-matching, not
translating. Watch whether the tool's success rate on the generated half matches its success rate
on the hand-written half. If it is much higher, it found a template. If it is much lower, scale
itself is degrading quality — which is a more interesting finding than either.

---

## 9. Application and code conversion (public preview)

Separately from the schema, the extension converts loose files: `.sql`, `.ctl`, `.sh`, `.load`,
`.java`. **This is public preview, not GA.**

It is worth exercising precisely because it is where a real migration spends its unbudgeted time —
the application still has to run. Good candidates already in this repository:

- `src/oracle/*.sql` — hand-written DDL, as an independent check on the schema conversion
- `tests/verify-counts.sql` — SQL\*Plus-specific syntax (`DEFINE`, `&substitution`, `SET`) that has
  no PostgreSQL equivalent and must become something else entirely
- `scripts/seed-oracle.sh` — a shell script that drives `sqlplus` and would have to drive `psql`

Keep preview results in a separate section of your notes from GA results. Conflating them is how a
blog post ends up claiming more than Microsoft does.

---

## 10. Apply to the target

The tool can write the converted schema to `contoso_store` for you. Before you let it:

**Take the DDL first.** Save the generated script into `out/` and read it. It is the only artefact
of this stage that survives a redeploy, and it is what you will diff between runs to see whether a
model change or a prompt change moved anything.

**Apply order matters here for the same reason it did in Oracle.** The circular foreign keys
(`region.manager_employee_id → employee`, `employee.store_id → store → region`) mean no
dependency-ordered DDL emission can succeed. If the tool emits in dependency order and fails, that
is finding H-19's cousin and worth recording — the fix is to apply tables first and constraints
afterwards, exactly as `src/oracle/` splits them.

Afterwards, set the database-level `search_path`, because `pg_catalog` is always searched first and
`to_char`, `to_date` and `substr` therefore resolve to the **PostgreSQL** builtins rather than
orafce's Oracle-compatible versions. That is not an error — it is subtly different formatted output.

```sql
ALTER DATABASE contoso_store
  SET search_path = contoso, public, oracle, topology, tiger,
                    dbms_output, dbms_lob, dbms_random, plvstr, plvsubst, utl_file;
```

Database-level, not session-level: a session `SET` evaporates and the next connection quietly gets
different behaviour. The value is `PG_SEARCH_PATH` in `.env`. Where Oracle semantics actually
matter, call them explicitly:

```sql
SELECT oracle.to_char(order_ts, 'DD-MON-YYYY') FROM contoso.sales_order;
```

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The report is suspiciously clean | `plpgsql_check` not allowlisted — it is fail-open | § 1.1. The run must be repeated; the report cannot be salvaged |
| Conversion fails immediately, but Copilot chat itself works | Egress to `https://github.com/microsoft/pgsql-tools/` is blocked | [00 § 9](00-prerequisites.md#9-network-egress). Reads like a licensing error, is a network one |
| "Agent mode is not available" | Copilot Free or Pro | Needs Pro+, Business or Enterprise |
| The tool cannot reach the model | Foundry role not granted, or granted under the other name | Grant both `Foundry User` and `Cognitive Services OpenAI User`; allow a minute to propagate |
| Model deployment rejects the SKU | Provisioned/PTU capacity denied on the subscription | Deploy as `GlobalStandard`. Change region rather than switching to Provisioned |
| Throttling, very slow progress | TPM quota below the recommended 500,000 | Raise quota, or accept the wall-clock cost |
| Scratch schemas pile up as `_mig_scratch_*` | A run was killed mid-flight | Drop them by hand; they are throwaway by design |
| No parameters shown for packaged routines | `SELECT` on `SYS.ARGUMENT$` not granted to `O2P_READER` | Grant it and re-enumerate |
| `ORA-00018: maximum number of sessions exceeded` | Oracle `sessions` at or below 10 | `ALTER SYSTEM SET sessions=200 SCOPE=SPFILE;` and restart |
| Converted `to_char` output differs from Oracle | `pg_catalog` wins the search path | Call `oracle.to_char(...)` explicitly |
| Target tables are all empty | **Expected.** The tool does not copy rows | [04 — Migrate the data](04-migrate-data.md) |

A fuller symptom index for the whole lab is in [troubleshooting.md](troubleshooting.md).

---

You now have a converted schema, a report, and a pile of decisions you made about the review queue.
It contains no data.

**Next:** [04 — Migrate the data](04-migrate-data.md)

Background on why the pipeline is shaped this way, and where the human is load-bearing:
[architecture.md](architecture.md).
