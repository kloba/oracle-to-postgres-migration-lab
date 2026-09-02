# 02 — Seed the Oracle source

Build the `CONTOSO` schema: about 350 hand-written objects, about 760 generated ones, and a few
million rows of retail data. One command does all of it and then proves it worked.

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
| 2. Generated schema | `generated/oracle/*.sql`, from `tools/generate-objects.py` | Views, synonyms, functions, procedures, packages, sequences, triggers, all carrying a `gen_` infix | 760 objects |
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
  needs no registry login and starts far faster, so it is the local default:

  ```bash
  docker run -d --name o2p-oracle -p 1521:1521 \
    -e ORACLE_PASSWORD="$ORACLE_SYSTEM_PASSWORD" \
    gvenzl/oracle-free:23-slim
  docker logs -f o2p-oracle          # wait for DATABASE IS READY TO USE!
  ```

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
| `tools/generate-objects.py` | ~760 schema objects into `generated/oracle/` | `--out`, `--seed`, `--count N` (or `--count-multiplier M`), `--no-tables`, `--quiet`. Defaults come from `GEN_OUTPUT_DIR` and `GEN_SEED`; `seed-oracle.sh` passes `GEN_OBJECT_TARGET` as `--count` |
| `tools/generate-data.py` | Row data into `generated/oracle/data/` | `--out`, `--scale {small,medium,large}`, `--seed`, `--quiet`. Defaults come from `GEN_OUTPUT_DIR` and `GEN_SEED` |

Read that second row carefully, because two different things in this lab are called "scale" and
they are **not** the same knob:

- **`generate-data.py --scale`** takes `small`, `medium` or `large` — three named row-count
  presets. It does not accept a number, and it does not read `SEED_ORDER_ROWS` or
  `SEED_CUSTOMER_ROWS`.
- **`seed-oracle.sh --scale`** takes a number. It is handed to the SQL as the SQL\*Plus
  substitution variable `&scale`, alongside `&order_rows` and `&customer_rows` from
  `SEED_ORDER_ROWS` and `SEED_CUSTOMER_ROWS` in `.env`. `seed-oracle.sh` also maps your number onto
  the nearest named preset when it invokes `generate-data.py` for you.

`seed-oracle.sh` runs the object generator automatically when `generated/oracle/` contains no SQL,
and the data generator when `generated/oracle/data/` contains none. You can run either yourself:

```bash
python3 tools/generate-objects.py --seed 20260902 --count 760 --out ./generated
ls generated/oracle/*.sql | wc -l          # 13
python3 tools/generate-data.py --seed 20260902 --scale small --out ./generated
ls generated/oracle/data/*.sql | wc -l     # 17
```

Both write into a subdirectory of `--out`, not into `--out` itself: `<out>/oracle/` and
`<out>/oracle/data/`. `ls generated/*.sql` finds nothing and always will.

The 13 object files are not 13 objects. Each one holds a whole family — `40-gen-views.sql` alone
carries 180 views. `--count` sets the number of **objects**, not files, and the file count is
fixed.

### Determinism is a contract, not a nicety

Same `GEN_SEED`, same output — byte for byte, on any machine, on any supported Python. The lab
diffs conversion reports across runs and across machines, so generator drift would make every
comparison meaningless.

```bash
# Prove it
python3 tools/generate-objects.py --seed 20260902 --count 760 --out /tmp/gen-a
python3 tools/generate-objects.py --seed 20260902 --count 760 --out /tmp/gen-b
diff -r /tmp/gen-a/oracle /tmp/gen-b/oracle && echo "deterministic"
```

Leave `GEN_SEED=20260902` alone unless you are deliberately producing a different corpus — and if
you do change it, record the new value alongside your results.

### The generated objects are not noise

Each `pkg_gen_rules_NNN` is a plausible pricing or eligibility rule package over the real tables;
each `v_gen_*` is a real projection. About 15% of them deliberately contain one of the hard cases
from [`design.md`](design.md) section 9, so scale testing stresses the difficult paths rather than
just inflating a count. A converter facing 760 copies of one template would be pattern-matching, not
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
| `--scale <n>` | Row-volume multiplier. `1` is the `.env` default; `0.01` is a fast smoke test |
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
any scale — about **1,450** real objects, or **~1,820** by the contract's counting rule once its
composite-partition subpartitions are included. Only that subpartition slice moves with data volume.
If you only care about *schema and code* conversion — which is what the
Microsoft tool actually does — `--scale 0.01` is a completely legitimate way to run this lab, and it
saves you half an hour and 8 GB.

Scale starts to matter when you want:

- meaningful timings for the separate data-movement step;
- behavioural diffs where row counts are the evidence, notably H-30 (`ROWNUM`), H-32 (`(+)` outer
  joins) and H-38 (empty string is `NULL`) — a divergence needs enough rows to be visible;
- realistic query plans, so the performance regressions from H-24 (`RESULT_CACHE`) and H-19
  (partitioning) actually show up.

| `--scale` | `sales_order` | Total rows | DDL phase | Data phase | Total (local) | Total (Azure VM) | Oracle datafiles |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `0.01` | 2,500 | ~50 K | 5–9 min | 1–2 min | 6–11 min | 8–14 min | ~1.5 GB |
| `0.1` | 25,000 | ~450 K | 5–9 min | 4–7 min | 9–16 min | 12–20 min | ~2.5 GB |
| `1` (default) | 250,000 | ~4.5 M | 5–9 min | 30–45 min | 35–55 min | 45–75 min | ~9 GB |
| `2` | 500,000 | ~9 M | 5–9 min | 65–100 min | 70–110 min | 85–145 min | ~17 GB |

Measured on a `Standard_D4s_v5` with a Premium SSD data disk and on an M-series laptop with Docker
Desktop. Treat them as the right order of magnitude, not a promise.

Things worth noticing in that table:

- **The DDL phase is a fixed cost.** Building the ~1,450 real objects — 25 package bodies, 26
  triggers, 6 materialised views and the rest — takes the same 5 to 9 minutes whatever the scale. It
  dominates at `0.01` and
  disappears at `2`.
- **Azure is slower than local at the same scale.** SQL\*Plus is driven over an SSH tunnel through
  Bastion, so every statement pays a round trip. The gap widens with row count.
- **Disk is not the constraint on Azure.** The data disk is 128 GiB, so even `--scale 4` fits. It
  *is* the constraint on a laptop: budget the datafile figure plus about 3 GB for the image plus
  redo and temp headroom.

At scale 1 the fact tables land roughly here:

| Table | Rows |
| --- | ---: |
| `inventory_movement` | ~1.2 M |
| `sales_order_line` | ~750 K |
| `inventory_stock` | ~500 K |
| `loyalty_transaction` | ~400 K |
| `price_list_item` | ~300 K |
| `order_payment` | ~275 K |
| `sales_order` | 250 K |
| `purchase_order_line` | ~200 K |
| `gl_journal_line` | ~180 K |
| `product_variant` | ~60 K |
| `customer` | 50 K |

Set the row baseline in `.env` (`SEED_ORDER_ROWS`, `SEED_CUSTOMER_ROWS`) and let `seed-oracle.sh
--scale` multiply it. Both values are handed to the seed SQL as `&order_rows` and `&customer_rows`,
and `--scale` as `&scale`. These are SQL\*Plus substitution variables, not generator arguments —
`tools/generate-data.py` never sees them, and picks its row counts from its own
`--scale {small,medium,large}` presets.

---

## 5. Expected output

```text
== Generator ==
  [ .. ] python3 tools/generate-objects.py --seed 20260902 --count 760 --out generated
  [ ok ] generated 13 file(s) in 0.3s
  [ .. ] python3 tools/generate-data.py --seed 20260902 --scale medium --out generated
  [ ok ] generated 17 data file(s) in 2.1s

== Plan ==
  target           azure
  schema           CONTOSO
  service          FREEPDB1
  scale            1
  to run           41 file(s)

== Tunnel ==
  [ ok ] az network bastion tunnel on 127.0.0.1:12043 -> o2p-oracle-vm:22
  [ ok ] ssh port-forward 127.0.0.1:15210 -> 10.42.1.10:1521

== Running ==
  1    src/oracle/00-user-tablespace.sql                 4.1s  ok
  2    src/oracle/01-types.sql                           2.8s  ok
  3    src/oracle/02-tables.sql                         18.6s  ok
  4    src/oracle/03-constraints.sql                    12.9s  ok
  5    src/oracle/04-indexes.sql                        21.4s  ok
  6    src/oracle/05-sequences.sql                       1.9s  ok
  7    src/oracle/06-views.sql                           6.7s  ok
  8    src/oracle/07-packages.sql                       58.3s  ok
  ...
  14   src/oracle/13-synonyms-grants.sql                 3.9s  ok
  15   generated/oracle/10-gen-sequences.sql             8.2s  ok
  ...
  20   generated/oracle/40-gen-views.sql                44.7s  ok
  ...
  26   generated/oracle/data/01-data-session-prep.sql    0.4s  ok
  ...
  35   generated/oracle/data/10-data-orders.sql      22m 41s  ok
  ...
  41   src/oracle/99-verify-objects.sql                  9.6s  ok

  41 file(s) in 48m 12s

== Verification ==
  ---- object count (the contract's counting rule) ----
  TOTAL_OBJECTS=1823

  ---- by type (abridged; the seed also prints generated vs hand-written) ----
  OBJECT_TYPE                    TOTAL
  --------------------------- --------
  INDEX                            332
  INDEX SUBPARTITION               250
  VIEW                             208
  SYNONYM                          174
  FUNCTION                         136
  TABLE SUBPARTITION               125
  PROCEDURE                        112
  TABLE                            108
  TRIGGER                           96
  SEQUENCE                          75
  PACKAGE                           74
  PACKAGE BODY                      74
  ...

  ---- invalid objects ----
  INVALID_OBJECTS=0

  ---- row counts ----
  TABLE_NAME                             NUM_ROWS
  ---------------------------------- ------------
  INVENTORY_MOVEMENT                    1,204,880
  SALES_ORDER_LINE                        751,204
  INVENTORY_STOCK                         498,112
  ...
  TOTAL_ROWS=4,512,908

== Summary ==
  files run              41
  files failed           0
  elapsed                48m 12s
  logs                   out/logs/seed-20260902-121544
  objects in CONTOSO     1823 (floor 1000)

CONTOSO is loaded and verified.
```

The 41 files are 14 hand-written, 11 generated schema, 15 generated data and the verification file.
That is fewer than the 13 and 17 the generators wrote, because two of each are never executed by the
script: `00-gen-load-all.sql` is a SQL\*Plus driver that `@@`-includes its siblings for a human
running them by hand, and `99-gen-verify-objects.sql` is superseded by `src/oracle/99-verify-objects.sql`.
Run `--dry-run` to see the exact list on your machine.

`TOTAL_OBJECTS` counts by the contract's rule, which excludes `LOB` and the three `PARTITION` types
but keeps the composite-partition **subpartitions** — the two `SUBPARTITION` rows in the census
above. That is why it lands near ~1,820 rather than the ~1,450 real schema objects, and why it
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

**Floor: 1,000 (the only figure asserted). Per-type design budget: 1,110. A loaded schema: ~1,820.**

The exclusions matter. `LOB` segments and `TABLE`/`INDEX`/`LOB PARTITION` objects are storage
artefacts, not schema objects a converter has to reason about, so the rule drops them. It does
**not** drop `TABLE`/`INDEX SUBPARTITION`, though, and `inventory_movement` is composite-partitioned
— so its subpartitions are counted, which is why a loaded schema reports ~1,820 rather than the
~1,450 real objects, and why that figure drifts upward with data volume and with the seed date.

The gap over the 1,000 floor is not decoration. The per-type budget of 1,110 exists to guarantee the
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

  Last 25 lines of out/logs/seed-20260902-121544/08-07-packages.log:
    ...

seed failed: stopped at src/oracle/07-packages.sql
fix: read out/logs/seed-20260902-121544/08-07-packages.log in full, fix the SQL, then
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

Then re-run only the data phase. The data files are `generated/oracle/data/NN-data-*.sql`, so the
glob matches on the `-data-` infix rather than on a number:

```bash
./scripts/seed-oracle.sh --azure --scale 0.1 --only '*-data-*.sql'
```

`--only` matches the **basename**, and `--dry-run` shows you the exact list before you commit to it.

### Regenerate the generated objects

You almost never need to. Determinism means a regeneration with the same `GEN_SEED` produces
identical files.

```bash
rm -rf generated/oracle
python3 tools/generate-objects.py --seed 20260902 --count 760 --out ./generated
python3 tools/generate-data.py    --seed 20260902 --scale small --out ./generated
```

Note `generated/oracle`, not `generated`. Both generators write into a subdirectory of `--out`;
`rm -f generated/*.sql` deletes nothing.

If you change `GEN_SEED`, you get a different 760 objects — still valid, still the right count, but
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

`CONTOSO` is loaded and verified. You now have a source database with about **1,820 objects**
(roughly 1,450 once subpartitions are excluded), every one
of the 43 hard cases present and exercised by data, and no invalid objects.

**Next:** [03 — Run the AI migration](03-run-ai-migration.md)

Background reading, if you want to know why the lab is shaped this way before you point an LLM at
it: [architecture.md](architecture.md).
