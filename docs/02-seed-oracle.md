# 02 — Seed the Oracle source

Build the `CONTOSO` schema: about 350 hand-written objects, 792 budgeted generated ones, and up to a
couple of million rows of retail data. One command does all of it and then proves it worked.

- [What "seeding" means here](#what-seeding-means-here)
- [1. Before you start](#1-before-you-start)
- [2. The generators](#2-the-generators)
- [3. Run the seed](#3-run-the-seed)
- [4. Choosing a scale](#4-choosing-a-scale)
- [5. Expected output](#5-expected-output)
- [6. Verify](#6-verify)
- [7. When it fails](#7-when-it-fails)
- [8. Reset and re-seed](#8-reset-and-re-seed)
- [9. Troubleshooting](#9-troubleshooting)

---

## What "seeding" means here

`scripts/seed-oracle.sh` runs four phases in a fixed order:

| Phase | Source | Produces | Roughly |
| --- | --- | --- | ---: |
| 1. Hand-written schema | `src/oracle/00-*.sql` … `src/oracle/13-*.sql` | Types, tables, constraints, indexes, sequences, views, materialised views, synonyms, 25 packages, standalone routines, triggers, VPD policies, scheduler jobs | 350 objects |
| 2. Generated schema | `generated/oracle/*.sql`, from `tools/generate-objects.py` | Views, synonyms, functions, procedures, packages, sequences, triggers, all carrying a `gen_` infix, plus staging and archive tables with their indexes | 792 budgeted |
| 3. Row data | `generated/oracle/data/*.sql`, from `tools/generate-data.py` | Reference data, catalogue, customers, orders, inventory movements, GL postings | scale-dependent |
| 4. Verification | `src/oracle/99-verify-objects.sql` | The object-count assertion, invalid-object check and the hard-case presence checks | — |

Ordering is not negotiable. Circular foreign keys (`region.manager_employee_id → employee` and
`employee.store_id → store → region`) mean constraints have to be applied after all tables exist,
which is exactly why they are in a separate file. That circularity is deliberate: naive converters
emit DDL in dependency order and fail on it.

> **Where the files actually live.** The hand-written schema is in `src/oracle/`. The seed script
> looks in `sql/` first and falls back to `src/oracle/`, because `docs/design.md` originally
> specified the shorter name — but `src/oracle/` is what exists and what everything else in this
> page refers to. Row data is generated into `generated/oracle/data/`; `seed/` and `src/seed/` are
> accepted as alternatives on the same basis, and neither exists in the repository.

---

## 1. Before you start

**Either** the Azure path:

- [`01 — Deploy the infrastructure`](01-deploy-infrastructure.md) completed.
- Oracle cloud-init **finished**. The deployment reporting "Succeeded" is not the same thing; the
  container image pull takes another 10–20 minutes. `sudo cloud-init status --wait` on the VM, and
  wait for `DATABASE IS READY TO USE!` in `docker logs o2p-oracle`.
- `generated/outputs.json` present, from a successful `deploy.sh`.

**Or** the local path:

- Docker running, with roughly 12 GB free for the image and datafiles, more at higher scales.
- The Oracle Free container up. This lab was verified against `gvenzl/oracle-free:23-slim`, which
  needs no registry login and starts far faster, so it is the local default. Despite the `23-slim`
  tag, that image now serves **Oracle AI Database 26ai Free Release 23.26.x** — run
  `SELECT banner_full FROM v$version;` for the exact build; the lab targets Oracle Free generally,
  not a pinned release, so the drift is harmless. With `.env` in place (`cp .env.example .env`), load
  it so the container name, port and password come from it, then start the container:

  ```bash
  set -a; . ./.env; set +a
  docker run -d --name "$ORACLE_CONTAINER_NAME" -p "$ORACLE_PORT:1521" \
    -e ORACLE_PASSWORD="$ORACLE_SYSTEM_PASSWORD" \
    gvenzl/oracle-free:23-slim
  docker logs -f "$ORACLE_CONTAINER_NAME"   # wait for DATABASE IS READY TO USE!
  ```

  > **On Apple Silicon (and other ARM64 hosts):** `gvenzl/oracle-free` is published for
  > `linux/amd64` only, so `docker run` prints a `platform (linux/amd64) does not match the detected
  > host platform` warning and the database runs under emulation. That is expected — it works, just
  > slower — not an error to fix.

  Oracle's own `container-registry.oracle.com/database/free:latest` — the `ORACLE_IMAGE` default the
  Azure VM path pulls — works too, but it is a ~9 GB image and needs a one-time
  `docker login container-registry.oracle.com` after you accept the licence. On that image the
  password variable is `-e ORACLE_PWD=`, not `-e ORACLE_PASSWORD=`.

**Both paths need:**

- `.env` with `ORACLE_SYSTEM_PASSWORD` and `CONTOSO_PASSWORD` set (or `USE_KEYVAULT=1`).
- `sqlplus` available — inside the container on the local path, on the VM on the Azure path. You do
  not need an Oracle client on your own machine.
- Python 3.9 or later.

---

## 2. The generators

Two Python scripts, both standard-library only. **Do not run `pip install`** — `tools/requirements.txt`
exists to tell you there is nothing to install and to explain why.

| Script | Emits | Interface |
| --- | --- | --- |
| `tools/generate-objects.py` | 792 budgeted schema objects into `generated/oracle/`, plus 144 staging tables, indexes and their triggers that sit outside the budget | `--out`, `--seed`, `--count N` (or `--count-multiplier M`), `--no-tables`, `--quiet`. Defaults come from `GEN_OUTPUT_DIR` and `GEN_SEED`. `seed-oracle.sh` deliberately does **not** pass `--count`; see [Do not pass `--count`](#do-not-pass---count) |
| `tools/generate-data.py` | Row data into `generated/oracle/data/` | `--out`, `--scale TIER\|FACTOR`, `--seed`, `--quiet`. Defaults come from `GEN_OUTPUT_DIR` and `GEN_SEED` |

Read that second row carefully, because two different things in this lab are called "scale" and
they are **not** the same knob:

- **`generate-data.py --scale`** selects one of three named row-count tiers: `small`, `medium`
  (the default) or `large`, which multiply one table of base row counts by 1, 40 and 200. A bare
  number is accepted too and is snapped to the nearest tier, so `--scale 0.01` behaves exactly like
  `--scale small` — byte for byte. What it does **not** read is `SEED_ORDER_ROWS` or
  `SEED_CUSTOMER_ROWS`.
- **`seed-oracle.sh --scale`** takes a number, and its only effect on row volume is which of those
  three tiers it picks when it invokes `generate-data.py` for you:

  | `seed-oracle.sh --scale` | tier handed to `generate-data.py` |
  | --- | --- |
  | `0`, `0.0…` (so `0.01`, `0.05`), `0.1` | `small` |
  | `0.5`, `1`, `1.…` | `medium` |
  | everything else, including `0.2` | `large` |

  That last row is a real trap and not a typo: the mapping is a `case` over string patterns, not
  arithmetic, so `--scale 0.2` falls through to `large` and loads 9.8 M rows. Stick to `0.01`, `1`
  and `2`.

  The number is *also* emitted to SQL\*Plus as the substitution variable `&scale`, alongside
  `&order_rows` and `&customer_rows` taken from `SEED_ORDER_ROWS` and `SEED_CUSTOMER_ROWS`. Do not
  read more into that than is there: `&scale` is consumed only by `tests/verify-counts.sql`, and
  **no file anywhere in the repository reads `&order_rows` or `&customer_rows`**. Setting
  `SEED_ORDER_ROWS=1000000` in `.env` changes nothing and raises no error. Row volume comes from the
  tier and from nothing else.

`seed-oracle.sh` runs the object generator automatically when `generated/oracle/` contains no SQL,
and the data generator when `generated/oracle/data/` contains none. You can run either yourself:

```bash
python3 tools/generate-objects.py --seed 20260902 --out ./generated
ls generated/oracle/*.sql | wc -l          # 13
python3 tools/generate-data.py --seed 20260902 --scale small --out ./generated
ls generated/oracle/data/*.sql | wc -l     # 17
```

Both write into a subdirectory of `--out`, not into `--out` itself: `<out>/oracle/` and
`<out>/oracle/data/`. `ls generated/*.sql` finds nothing and always will.

The 13 object files are not 13 objects. Each one holds a whole family — `40-gen-views.sql` alone
carries 180 views. The file count is fixed at 13 whatever the object count is.

### Do not pass `--count`

The object generator owns its own budget — `GEN_OBJECT_TARGET = 792` in `tools/generate-objects.py`
— and asserts against it at the end of every run. `--count N` is not a cap; it is turned into a
multiplier of `N / 792` and applied to every family. Any value but 792 therefore changes every file
*and* disarms the assertion. The generator says so itself, at length:

```console
$ python3 tools/generate-objects.py --seed 20260902 --count 760 --out /tmp/gen-c
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
WARNING: the section 8 budget assertion was NOT run.

  --count-multiplier is 0.959596, not 1.0, so this run does NOT reproduce
  the design contract. Only the generator's own default does.

  Per-type minimums this run is BELOW:
    VIEW            173  (design minimum 180, short by 7)
    ...
    PACKAGE          74  (design minimum 76, short by 2)
    PACKAGE BODY     74  (design minimum 76, short by 2)
    SEQUENCE         48  (design minimum 50, short by 2)

  A schema built from this output will FAIL tests/verify-schema.sql
  assertion A3, even though the seed itself will report success:
  99-verify-objects.sql only asserts the 1000 floor, not the per-type
  budget. Re-run without --count to get the contract corpus.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  TOTAL                 763      792      -29
```

All 12 output files differ from a default run, so nobody can diff their conversion report against
yours — which is the whole point of the next section. The bare default is the only invocation that
reproduces the contract, so that is what this page uses everywhere and what `seed-oracle.sh` runs.
`GEN_OBJECT_TARGET` in `.env.example` is reference only: it documents the generator's number, it
does not set it. If you deliberately want a non-contract corpus, export `GEN_OBJECT_COUNT` and
`seed-oracle.sh` will pass it through with a warning.

### Determinism is a contract, not a nicety

Same `GEN_SEED`, same output — byte for byte, on any machine, on any supported Python. The lab
diffs conversion reports across runs and across machines, so generator drift would make every
comparison meaningless.

```bash
# Prove it
python3 tools/generate-objects.py --seed 20260902 --out /tmp/gen-a
python3 tools/generate-objects.py --seed 20260902 --out /tmp/gen-b
diff -r /tmp/gen-a/oracle /tmp/gen-b/oracle && echo "deterministic"
```

Leave `GEN_SEED=20260902` alone unless you are deliberately producing a different corpus — and if
you do change it, record the new value alongside your results.

### The generated objects are not noise

Each `pkg_gen_rules_NNN` is a plausible pricing or eligibility rule package over the real tables;
each `v_gen_*` is a real projection. About 15% of them deliberately contain one of the hard cases
from [`design.md`](design.md) section 9, so scale testing stresses the difficult paths rather than
just inflating a count. A converter facing 792 copies of one template would be pattern-matching, not
translating.

Every generated object carries a `gen_` infix, so one predicate separates generated from
hand-written in any report:

```sql
SELECT CASE WHEN LOWER(object_name) LIKE '%gen[_]%' ESCAPE '['
            THEN 'generated' ELSE 'hand-written' END AS origin,
       COUNT(*)
  FROM user_objects
 GROUP BY 1;
```

---

## 3. Run the seed

Pick exactly one target.

```bash
# PRIMARY: the Oracle VM in the lab VNet, over an az network bastion tunnel.
# This is the headline path - the VM stands in for the customer's on-premises server.
./scripts/seed-oracle.sh --azure

# SECONDARY: a Docker container on your own machine. Cheap, fast, and exercises
# none of the network story - no Bastion, no private endpoint, no realistic latency.
./scripts/seed-oracle.sh --local
```

Both produce a byte-identical schema; only the transport differs. Use `--local` while you are
iterating on SQL or running CI, then run the real thing against the VM.

On the Azure path the Bastion tunnel is opened and closed for you, including when the run fails.
You do not need to open one yourself.

Look before you leap — `--dry-run` prints the execution plan, connects to nothing, and costs
nothing:

```bash
./scripts/seed-oracle.sh --azure --dry-run
```

### Options

| Flag | Effect |
| --- | --- |
| `--scale <n>` | Row-volume tier selector, not a free multiplier. `0.01` and `0.1` both give `small`; `0.5` and `1` (the default) give `medium`; everything else, `0.2` included, gives `large`. See [4. Choosing a scale](#4-choosing-a-scale) |
| `--dry-run` | Print the plan and exit |
| `--no-generate` | Do not run the object generator even if `generated/` is empty. The object count will fall short of 1,000 and verification will fail — this is for debugging the hand-written schema only |
| `--only <glob>` | Run only files whose basename matches, e.g. `--only '1?-*.sql'`. Order preserved |
| `--from <name>` | Skip everything before this file. How you resume after a failure |
| `--continue-on-error` | Keep going past a failing file. Off by default, and usually the wrong choice: one bad DDL file makes every later file fail too, and the first error is the real one |

Passwords never reach a command line. SQL\*Plus is started with `/nolog` and the `CONNECT` is fed on
stdin, so nothing sensitive shows up in `ps` on your machine or on the VM.

---

## 4. Choosing a scale

**Scale changes rows, not the schema.** Every table, package, trigger and hard case is present at
any scale — about **1,480** real objects, or **~1,855** by the contract's counting rule once its
composite-partition subpartitions are included. Only that subpartition slice moves with data volume.
If you only care about *schema and code* conversion — which is what the
Microsoft tool actually does — `--scale 0.01` is a completely legitimate way to run this lab, and it
saves you roughly half an hour and 2 GB of disk.

Scale starts to matter when you want:

- meaningful timings for the separate data-movement step;
- behavioural diffs where row counts are the evidence, notably H-30 (`ROWNUM`), H-32 (`(+)` outer
  joins) and H-38 (empty string is `NULL`) — a divergence needs enough rows to be visible;
- realistic query plans, so the performance regressions from H-24 (`RESULT_CACHE`) and H-19
  (partitioning) actually show up.

| `--scale` | tier | `sales_order` | Total rows | DDL phase | Data phase | Total (local) | Oracle datafiles |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `0.01` | `small` | 2,400 | ~55 K | ~1m 40s | ~35s | ~3 min | 1.8 GB |
| `0.1` | `small` | 2,400 | ~55 K | ~1m 40s | ~35s | ~3 min | 1.8 GB |
| `1` (default) | `medium` | 96,000 | ~2.0 M | ~1m 40s | ~20–30 min | ~25–35 min | ~4–6 GB |
| `2` | `large` | 480,000 | ~9.8 M | ~1m 40s | ~100–150 min | ~105–155 min | ~10–16 GB |

`0.01` and `0.1` are the same run — both land on the `small` tier, so there is no reason to prefer
`0.1`. Use `0.01` and mean it.

**The row counts are exact, not estimates.** They come straight from the generator's plan —
`SCALABLE_ROWS` in `tools/generate-data.py` times the tier factor — which the generator prints
before it writes a line of SQL. Add a few dozen rows on top for the deliberate edge cases in
`14-data-messy-edge-cases.sql`: `sales_order` lands on 2,406 rather than 2,400 at `small`.

**The timings and datafile sizes are a different matter.** Only the `small` row is measured. It is
the run transcribed in [5. Expected output](#5-expected-output): 41 files, DDL phase 1m 41s, data
phase 34s, verification 45s — the `Total` column includes that verification phase — for 3 minutes
of wall clock on an M-series laptop with Docker Desktop, leaving 1.75 GB in `CONTOSO_DATA`. The
`medium` and `large` timings scale the *data phase* by 40x and 200x and leave the DDL phase alone;
the datafile figures assume the ~1.6 GB partition floor described below, plus room for the rows.
Both are arithmetic on one measurement, not four measurements. Treat them as the right order of
magnitude and nothing more, and re-measure before you quote them. Azure VM runs are slower again,
because SQL\*Plus is driven over an SSH tunnel through Bastion and every statement pays a round
trip; the gap widens with row count.

Things worth noticing in that table:

- **The DDL phase is a fixed cost**, and a small one. Building the ~1,480 real objects — 90 package
  bodies, 96 triggers, 6 materialised views and the rest — takes the same minute and a half whatever
  the scale. It dominates at `0.01` and disappears at `2`.
- **Most of the `small` datafile is not data.** Of the 1.6 GB of `CONTOSO` segments in the measured
  run, 1.5 GB is 195 partition and subpartition segments each sitting on one uniform 8 MB extent —
  a fixed cost of the partitioning the lab deliberately carries, almost all of it still empty at
  55 K rows. That is why `small` still needs 1.8 GB, and why the datafile grows nowhere near as fast
  as the row count does.
- **Disk is not the constraint on Azure.** The data disk is 128 GiB, so even `--scale 4` fits. It
  *is* the constraint on a laptop: budget the datafile figure plus about 3 GB for the image plus
  redo and temp headroom.

At `--scale 1` — the `medium` tier — the fact tables are planned exactly here:

| Table | Rows |
| --- | ---: |
| `sales_order_line` | 224,000 |
| `inventory_movement` | 160,000 |
| `inventory_stock` | 128,000 |
| `loyalty_transaction` | 112,000 |
| `shipment_line` | 112,000 |
| `order_payment` | 104,000 |
| `customer_address` | 96,000 |
| `gl_journal_line` | 96,000 |
| `product_variant` | 96,000 |
| `sales_order` | 96,000 |
| `customer` | 80,000 |
| `price_list_item` | 80,000 |
| `purchase_order_line` | 72,000 |

`python3 tools/generate-data.py --seed 20260902 --scale medium --out /tmp/plan` prints the whole
plan, all 46 tables, before writing a line of SQL. That printout is the authority; this table is a
copy of it.

Do **not** try to set the row baseline in `.env`. `SEED_ORDER_ROWS` and `SEED_CUSTOMER_ROWS` are
handed to SQL\*Plus as `&order_rows` and `&customer_rows`, but no `.sql` file in the repository
reads either one, so they have no effect on anything and produce no error when you change them.
`&scale` is defined the same way and is read only by `tests/verify-counts.sql`.
`tools/generate-data.py` never sees any of the three; it takes its row counts from its own tier.

---

## 5. Expected output

This is a real run — `./scripts/seed-oracle.sh --local --scale 0.01` — abridged at the `...` marks
and with the colour stripped. Every count and timing below is from
`out/logs/seed-20260902T153420Z/`:

```text
== Generator ==
  [ .. ] python3 tools/generate-objects.py --seed 20260902 --out generated
  [ ok ] generated 13 file(s) in 105ms

== Data generator ==
  [ .. ] python3 tools/generate-data.py --seed 20260902 --scale small --out generated
  [ ok ] generated 17 data file(s) in 85ms

== Plan ==
  target           local
  schema           CONTOSO
  service          FREEPDB1
  scale            0.01
  to run           41 file(s)

== Target: local Docker container ==
  [ ok ] container o2p-oracle is running

== Loading 41 file(s) ==
  #    FILE                                                TIME  RESULT
  --   grant execute on sys.dbms_rls (as sysdba)                  ok
  1    src/oracle/00-user-tablespace.sql                  36.0s  ok
  2    src/oracle/01-types.sql                             3.0s  ok
  3    src/oracle/02-tables.sql                            4.0s  ok
  4    src/oracle/03-constraints.sql                      15.0s  ok
  5    src/oracle/04-indexes.sql                           3.0s  ok
  ...
  25   generated/oracle/81-gen-archive-tables.sql          4.0s  ok
  26   generated/oracle/data/01-data-session-prep.sql      2.0s  ok
  ...
  34   generated/oracle/data/09-data-inventory.sql         5.0s  ok
  35   generated/oracle/data/10-data-orders.sql            4.0s  ok
  ...
  41   src/oracle/99-verify-objects.sql                   20.0s  ok

== Verification ==

---- recompiling the schema before counting

---- object count (the contract's counting rule)

TOTAL_OBJECTS=1855

---- by type

OBJECT_TYPE              GENERATED HANDWRITTEN   TOTAL
------------------------ --------- ----------- -------
INDEX                          114         218     332
INDEX SUBPARTITION               0         250     250
VIEW                           180          28     208
SYNONYM                        150          24     174
FUNCTION                       120          16     136
TABLE SUBPARTITION               0         125     125
PROCEDURE                      100          12     112
TABLE                           42          66     108
TRIGGER                         70          26      96
PACKAGE                         76          14      90
PACKAGE BODY                    76          14      90
SEQUENCE                        50          25      75
...

---- invalid objects

INVALID_OBJECTS=0

---- row counts

TABLE_NAME                             NUM_ROWS
---------------------------------- ------------
SALES_ORDER_LINE                          5,600
INVENTORY_MOVEMENT                        4,004
INVENTORY_STOCK                           3,200
EXCHANGE_RATE                             2,920
LOYALTY_TRANSACTION                       2,802
...

TOTAL_ROWS=56988

== Summary ==
  files run              41
  files failed           0
  elapsed                3m 00s
  logs                   out/logs/seed-20260902T153420Z
  objects in CONTOSO     1855 (floor 1000)

CONTOSO is loaded and verified.
Next: scripts/connect.sh oracle-local
```

On `--azure` the `== Target: local Docker container ==` block is replaced by
`== Target: Azure Oracle VM via Bastion ==`, which opens and closes the tunnel for you.

Per-file times above are reconstructed from the log timestamps in that directory, so they are
accurate to the second and no better; the generator times are from re-running the two generators.
The object counts, `TOTAL_ROWS` and `TOTAL_OBJECTS` are copied verbatim from
`out/logs/seed-20260902T153420Z/999-report.log`.

At `--scale 1` the shape is identical; only the fifteen `*-data-*.sql` timings and the row-count
block change. Those files carry 40x the rows.

The 41 files are 14 hand-written, 11 generated schema, 15 generated data and the verification file.
That is fewer than the 13 and 17 the generators wrote, because two of each are never executed by the
script: `00-gen-load-all.sql` is a SQL\*Plus driver that `@@`-includes its siblings for a human
running them by hand, and `99-gen-verify-objects.sql` is superseded by `src/oracle/99-verify-objects.sql`.
Run `--dry-run` to see the exact list on your machine.

`TOTAL_OBJECTS` counts by the contract's rule, which excludes `LOB` and the three `PARTITION` types
but keeps the composite-partition **subpartitions** — the two `SUBPARTITION` rows in the census
above. That is why it lands near ~1,855 rather than the ~1,480 real schema objects, and why it
climbs at higher scale as more subpartitions are created. Your totals will differ from this sample
as the generated half is tuned and with data volume; take them from your own run.

Every file's full SQL\*Plus output is kept under `out/logs/seed-<timestamp>/`, whether it passed or
failed. `out/` is gitignored.

---

## 6. Verify

The seed script does this for you and exits non-zero if anything is wrong. To check by hand:

```bash
./scripts/connect.sh oracle-azure     # or oracle-local
```

### Object count — the contract's counting rule

```sql
SELECT COUNT(*) AS object_count
  FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION');
```

**Floor: 1,000 (the only figure asserted). Per-type design budget: 1,120. A loaded schema: ~1,855.**

The exclusions matter. `LOB` segments and `TABLE`/`INDEX`/`LOB PARTITION` objects are storage
artefacts, not schema objects a converter has to reason about, so the rule drops them. It does
**not** drop `TABLE`/`INDEX SUBPARTITION`, though, and `inventory_movement` is composite-partitioned
— so its subpartitions are counted, which is why a loaded schema reports ~1,855 rather than the
~1,480 real objects, and why that figure drifts upward with data volume and with the seed date.

The gap over the 1,000 floor is not decoration. The per-type budget of 1,120 exists to guarantee the
floor by construction, not by piling on partitions; a lab that lands on 1,001 is a lab that fails on
somebody else's machine.

### No invalid objects

```sql
SELECT object_type, object_name, status
  FROM user_objects
 WHERE status = 'INVALID'
 ORDER BY object_type, object_name;
```

Must be empty. An invalid package body is a package body the conversion tool will read as source
text and translate anyway, producing a converted object that is wrong in a way nobody notices until
runtime. Do not proceed with invalid objects.

Most invalid objects after a clean run are just dependency-order artefacts. Recompile:

```sql
EXEC UTL_RECOMP.RECOMP_SERIAL('CONTOSO');
```

Then re-check. If something is still invalid, it is a genuine compilation error:

```sql
SELECT name, type, line, position, text
  FROM user_errors
 ORDER BY name, sequence;
```

### Rows landed

```sql
EXEC DBMS_STATS.GATHER_SCHEMA_STATS(USER, cascade => TRUE);

SELECT table_name, num_rows
  FROM user_tables
 WHERE num_rows > 0
 ORDER BY num_rows DESC
 FETCH FIRST 20 ROWS ONLY;
```

`num_rows` comes from the optimiser statistics, so gather stats first or you will read stale zeros.
The seed script gathers automatically before it reports.

### Referential integrity

No orphan rows across any foreign key. Cheap insurance, because a converted database that
disagrees with the source on row counts is impossible to debug if the source was already
inconsistent:

```sql
SELECT c.table_name, c.constraint_name, c.status, c.validated
  FROM user_constraints c
 WHERE c.constraint_type = 'R'
   AND (c.status <> 'ENABLED' OR c.validated <> 'VALIDATED');
```

Must return no rows.

### The hard cases are actually present

`src/oracle/99-verify-objects.sql` also checks that the headline constructs are present —
partitioned tables, index-organized tables, compound and `INSTEAD OF` triggers, VPD policies, object
and collection types, virtual columns, function-based indexes, the `LONG` column, `XMLTYPE`,
`TIMESTAMP WITH LOCAL TIME ZONE`, the scheduler, and the `AUTONOMOUS_TRANSACTION` / `CONNECT BY` /
`RESULT_CACHE` source constructs. A construct nobody can find is a construct the converter was never
asked about, and a lab that quietly lost one produces a flattering report.

It draws a deliberate line between **absent** and **thin**. A construct that is gone entirely fails
the seed: it silently flatters the conversion report. A construct that is present but below the
count `design.md` designs for warns instead, because it still exercises the converter and losing the
whole schema over it would be a worse trade. The exhaustive per-object-type census, covering all 43
hard cases, is asserted hard in `tests/verify-schema.sql`.

Spot-check a few:

```sql
SELECT table_name, partitioning_type, subpartitioning_type FROM user_part_tables;
SELECT trigger_name, trigger_type FROM user_triggers WHERE trigger_type LIKE 'COMPOUND%';
SELECT object_name, policy_name FROM user_policies;
SELECT type_name FROM user_types WHERE supertype_name IS NOT NULL;
```

---

## 7. When it fails

The script stops at the first failing file by default. That is the right behaviour: one bad DDL file
makes every later file fail too, and only the first error tells you anything.

You get the last 25 lines of the failing file's log inline, plus the exact resume command:

```text
  8    src/oracle/07-packages.sql                        8.2s  FAIL
       PLS-00302: component 'RESOLVE_PRICES' must be declared

  Last 25 lines of out/logs/seed-20260902T153420Z/008-07-packages.sql.log:
    ...

seed failed: stopped at src/oracle/07-packages.sql
fix: read out/logs/seed-20260902T153420Z/008-07-packages.sql.log in full, fix the SQL, then
     resume without redoing the earlier files:
     seed-oracle.sh --azure --from 07-packages.sql
```

`--from` takes the **basename**, not the path, and re-runs the named file and everything after it,
so you do not pay for the first seven files again.

### Why exit code alone is not enough

SQL\*Plus exits 0 even when a package body compiles with errors. The script therefore reads every
log as well as the exit status, and treats any of these as a failure:

- a line starting `ORA-` or `PLS-`
- a line starting `SP2-` that is not on the benign ignore list
- the text `created with compilation errors`

This is the single most common way an Oracle build "succeeds" while leaving invalid objects behind.
If you write your own Oracle automation, steal this.

---

## 8. Reset and re-seed

### Full reset, keeping the database

```sql
-- as SYSTEM, against FREEPDB1
DROP USER CONTOSO CASCADE;
```

Then re-run the seed. `src/oracle/00-user-tablespace.sql` drops and recreates `CONTOSO` itself, so
in practice you can just re-run the seed without the manual `DROP`. `CASCADE` takes the tables,
packages, types, jobs, policies and everything else with it. Two things it does **not** take, and
which **no `.sql` file recreates either**:

- **The `CONTOSO_EXPORT_DIR` directory object.** It lives at database level, and it is created
  (`CREATE OR REPLACE DIRECTORY`) by `scripts/install-oracle.sh`, not by any file in `src/oracle/`.
  Harmless to leave in place — dropping `CONTOSO` only removes its `READ`/`WRITE` grant on it.
- **The `O2P_READER` account.** Also created by `scripts/install-oracle.sh`.

If you dropped either by hand, re-run `scripts/install-oracle.sh` rather than looking for a SQL file
that recreates them. `src/oracle/00-user-tablespace.sql` grants `CREATE ANY DIRECTORY` to `CONTOSO`
so the schema *can* make directory objects; it does not make this one.

### Full reset, local Docker

Faster than dropping the user, and gives you a genuinely clean database:

```bash
docker rm -f o2p-oracle
docker run -d --name o2p-oracle -p 1521:1521 \
  -e ORACLE_PASSWORD="$ORACLE_SYSTEM_PASSWORD" \
  gvenzl/oracle-free:23-slim
docker logs -f o2p-oracle       # wait for DATABASE IS READY TO USE!
./scripts/seed-oracle.sh --local --scale 0.01
```

### Reset only the data, keep the schema

Useful when you want a different scale without rebuilding the whole schema. There is no
`TRUNCATE ALL`, so generate the statements:

```sql
SELECT 'TRUNCATE TABLE ' || table_name || ' CASCADE;'
  FROM user_tables
 WHERE table_name NOT LIKE 'MLOG$%'
   AND table_name NOT LIKE '%_NTAB'
   AND temporary = 'N'
 ORDER BY table_name;
```

Then re-run only the data phase. Delete the old data SQL first: `seed-oracle.sh` only invokes
`generate-data.py` when `generated/oracle/data/` is empty, so without the `rm` a new `--scale` would
silently re-load the *previous* tier's files. The data files are `generated/oracle/data/NN-data-*.sql`,
so the glob matches on the `-data-` infix rather than on a number:

```bash
rm -rf generated/oracle/data
./scripts/seed-oracle.sh --azure --scale 1 --only '*-data-*.sql'
```

`--only` matches the **basename**, and `--dry-run` shows you the exact list before you commit to it.
Remember that only three tiers exist, so `--scale 0.1` gets you the same rows as `--scale 0.01`.

### Regenerate the generated objects

You almost never need to. Determinism means a regeneration with the same `GEN_SEED` produces
identical files.

```bash
rm -rf generated/oracle
python3 tools/generate-objects.py --seed 20260902 --out ./generated
python3 tools/generate-data.py    --seed 20260902 --scale small --out ./generated
```

Note `generated/oracle`, not `generated`. Both generators write into a subdirectory of `--out`;
`rm -f generated/*.sql` deletes nothing. And no `--count`: see
[Do not pass `--count`](#do-not-pass---count).

If you change `GEN_SEED`, you get a different 792 objects — still valid, still the right count, but
**no longer comparable** to any conversion report produced with the old seed. Record the value you
used with your results.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ORA-12541: TNS:no listener` | Oracle is not up yet | `docker logs o2p-oracle`, wait for `DATABASE IS READY TO USE!` |
| `ORA-12514: listener does not currently know of service` | Wrong service name | It is `FREEPDB1` (the PDB), not `FREE` (the CDB) |
| `ORA-01017: invalid username/password` | Placeholder still in `.env`, or a password containing `@` or `/` | Replace `replace-me-*`; avoid `@` and `/`, which break easy-connect strings |
| `ORA-00018: maximum number of sessions exceeded` | `sessions` too low | `ALTER SYSTEM SET sessions=200 SCOPE=SPFILE;` and restart. Must be > 10 |
| `ORA-01950: no privileges on tablespace` | Quota not granted | `src/oracle/00-user-tablespace.sql` grants `QUOTA UNLIMITED ON contoso_data`; check that file actually ran, and that it ran as `SYSTEM` |
| `ORA-01536: space quota exceeded` | Datafile or disk full | Lower `--scale`, or grow the tablespace / data disk |
| `no .sql files in sql/ (nor src/oracle)` | Wrong directory | Run from the repository root. The schema is in `src/oracle/` |
| `generated/ is empty and tools/generate-objects.py does not exist` | Generator not present | It is required. `--no-generate` only gets you a schema that fails the 1,000 floor |
| `no 99-*.sql in src/oracle` warning | The assertion file is missing | The object floor is then **not** asserted. Restore `src/oracle/99-verify-objects.sql` |
| `ls generated/*.sql` shows nothing | Wrong path — the generators write to `generated/oracle/` | Use `generated/oracle/*.sql` and `generated/oracle/data/*.sql` |
| Object count short of 1,000 | Generator skipped, or files failed silently | Check the by-type table against the expected counts; `--continue-on-error` hides failures |
| Invalid objects after a clean run | Dependency-order artefacts | `EXEC UTL_RECOMP.RECOMP_SERIAL('CONTOSO');` then re-check `user_errors` |
| `num_rows` is 0 for everything | Stale optimiser statistics | `EXEC DBMS_STATS.GATHER_SCHEMA_STATS(USER, cascade => TRUE);` |
| Bastion tunnel dies mid-run | Idle timeout or a dropped session | Re-run with `--from <last successful file>` |
| Seed takes far longer than the table says | Running `--azure` over a slow link, or a small VM | Try `--local` first, or lower `--scale` |

A fuller symptom index for the whole lab lives in [troubleshooting.md](troubleshooting.md).

---

`CONTOSO` is loaded and verified. You now have a source database with about **1,855 objects**
(roughly 1,480 once subpartitions are excluded), every one
of the 43 hard cases present and exercised by data, and no invalid objects.

**Next:** [03 — Run the AI migration](03-run-ai-migration.md)

Background reading, if you want to know why the lab is shaped this way before you point an LLM at
it: [architecture.md](architecture.md).
