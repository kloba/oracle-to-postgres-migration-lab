# 05 — Validate

Proving that the converted database answers the same questions as the source. This is where the
lab produces its actual output: a table of predicted versus observed, per hard case.

- [What validation means here](#what-validation-means-here)
- [1. Before you start](#1-before-you-start)
- [2. Level 1 — structural: is everything there?](#2-level-1--structural-is-everything-there)
- [3. Level 2 — behavioural: does it answer the same questions?](#3-level-2--behavioural-does-it-answer-the-same-questions)
- [4. The three that matter most](#4-the-three-that-matter-most)
- [5. Level 3 — performance: what got slower, and why](#5-level-3--performance-what-got-slower-and-why)
- [6. Recording results](#6-recording-results)
- [7. What "done" looks like](#7-what-done-looks-like)
- [8. Troubleshooting](#8-troubleshooting)

---

## What validation means here

Three questions, in increasing order of difficulty and of value:

| Level | Question | Failure mode it catches |
| --- | --- | --- |
| **1. Structural** | Does the target contain what the source contained? | Objects the converter silently dropped |
| **2. Behavioural** | Do the same questions get the same answers? | Objects that converted *plausibly but wrongly* |
| **3. Performance** | What got materially slower, and is that acceptable? | Constructs whose translation is correct and useless |

Level 1 is easy and nearly worthless on its own. **Level 2 is the point of the lab.** A conversion
that compiles, deploys, passes every structural check, and returns a different set of rows is the
outcome this entire repository was built to catch — and it is the outcome that a demo, a green
report, and an enthusiastic blog post will all miss.

> **The AI cannot validate itself.** The conversion tool's own report tells you what *it* thinks it
> did. `plpgsql_check` tells you the code compiles and is internally consistent. Neither of them has
> ever seen your data, and neither can tell you that `ROWNUM` and `LIMIT` selected different rows.
> Only running both databases and diffing can do that.

---

## 1. Before you start

### Gate zero: was the source itself valid?

Before anything else, and ideally before you ever ran [03](03-run-ai-migration.md).

**An Oracle object that will not compile in Oracle cannot be meaningfully converted.** The tool
reads it as source text and translates it anyway, and what comes back is syntactically plausible
PL/pgSQL derived from PL/SQL that never worked — confident nonsense. You then spend an afternoon
debugging a faithful translation of a bug, and every finding you record from that run is
contaminated because you cannot tell which differences are the converter's and which were already
broken.

Connected as `CONTOSO`:

```sql
SELECT object_name, object_type FROM user_objects WHERE status = 'INVALID';
```

**That must return no rows.** If it returns any, get the real errors before you touch anything else:

```sql
SELECT name, type, line, position, text FROM user_errors ORDER BY name, sequence;
```

Most invalid objects after a fresh seed are dependency-order artefacts — something compiled before
the object it references. One schema-wide recompile clears those. Recompile, then re-check, and
repeat until the count is either zero or has stopped falling:

```sql
EXEC DBMS_UTILITY.COMPILE_SCHEMA('CONTOSO');

SELECT object_name, object_type FROM user_objects WHERE status = 'INVALID';
SELECT name, type, line, position, text FROM user_errors ORDER BY name, sequence;
```

Anything still invalid after a full recompile has a **real** compilation error, and `user_errors`
names the line. Three that this schema produces and that are worth recognising on sight:

| Error | What it actually means |
| --- | --- |
| `ORA-00984: column not allowed here` | A column reference somewhere only a literal or a bind is allowed — usually a trigger body or a `DEFAULT` clause |
| `PLS-00204: function or pseudo-column may be used inside a SQL statement only` | `DECODE` (or another SQL-only construct) used in procedural PL/SQL. `CASE` is the PL/SQL form |
| `PLS-00678: a compound trigger body cannot have RETURN` | `RETURN` used to leave a compound trigger section. Restructure the section instead |

`src/oracle/99-verify-objects.sql` asserts this at the end of every seed and exits non-zero if the
count is not zero, so a clean `./scripts/seed-oracle.sh` run has already made the check for you.
Make it again by hand anyway: a recompile triggered by an unrelated DDL change can invalidate
objects after the fact, and the seed's verdict ages.

> **If you converted an invalid schema, do not try to salvage the output.** Fix the source, re-seed,
> convert again. It is faster than deciding, finding by finding, which of your results were real.

### Then the rest of the checklist

| # | Check | Why |
| --- | --- | --- |
| 1 | [03](03-run-ai-migration.md) complete, schema applied to `contoso_store` | Nothing to compare against otherwise |
| 2 | [04](04-migrate-data.md) complete, rows copied and counts checked | Behavioural comparison needs data on both sides |
| 3 | Sequences reset, constraints validated | [04 § 6 and § 9](04-migrate-data.md#9-sequences-and-the-bug-you-find-in-production) |
| 4 | **The source is unchanged since the copy** | If anything wrote to `CONTOSO` after the copy, every difference you find is your own fault |
| 5 | You wrote down the model you used | `gpt-5.2` and `gpt-5-mini` do not produce comparable results. It belongs at the top of your notes |
| 6 | The database-level `search_path` is set | Otherwise `to_char` is PostgreSQL's, not orafce's, and half your date comparisons diverge for a reason that has nothing to do with the conversion |

On 6, confirm rather than assume:

```sql
-- ./scripts/connect.sh postgres
SHOW search_path;
SELECT oracle.to_char(now(), 'DD-MON-YYYY') AS orafce_version,
                to_char(now(), 'DD-MON-YYYY') AS pg_version;
```

Those two will differ. That is the `pg_catalog`-wins-the-search-path gotcha, working exactly as
documented, and you want to have seen it deliberately before you meet it inside a failing test.

### What the existing harness does and does not cover

`tests/run-tests.sh` runs the repository's static checks and the **Oracle-side** structural
assertions (`tests/verify-schema.sql`, `tests/verify-counts.sql`):

```bash
tests/run-tests.sh                       # static checks only, no database
tests/run-tests.sh --local  --scale 0.01 # + Oracle in Docker
tests/run-tests.sh --azure  --scale 1    # + the Oracle VM
tests/run-tests.sh --list                # what would run
```

It has no PostgreSQL target. **The PostgreSQL half of the differential comparison is manual
today** — the queries below are the manual half, and turning them into a paired harness is the most
useful contribution anyone could make to this repository.

---

## 2. Level 1 — structural: is everything there?

Census both sides and diff by object type. The interesting output is the *gaps*, not the totals.

```sql
-- Oracle:  ./scripts/connect.sh oracle-azure
SELECT object_type, COUNT(*) AS n
  FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION')
 GROUP BY object_type ORDER BY n DESC;
```

```sql
-- PostgreSQL:  ./scripts/connect.sh postgres
SELECT 'TABLE'     AS object_type, count(*) FROM information_schema.tables
  WHERE table_schema='contoso' AND table_type='BASE TABLE'
UNION ALL SELECT 'VIEW',      count(*) FROM information_schema.views     WHERE table_schema='contoso'
UNION ALL SELECT 'MATVIEW',   count(*) FROM pg_matviews                  WHERE schemaname='contoso'
UNION ALL SELECT 'ROUTINE',   count(*) FROM information_schema.routines  WHERE routine_schema='contoso'
UNION ALL SELECT 'TRIGGER',   count(*) FROM information_schema.triggers  WHERE trigger_schema='contoso'
UNION ALL SELECT 'INDEX',     count(*) FROM pg_indexes                   WHERE schemaname='contoso'
UNION ALL SELECT 'SEQUENCE',  count(*) FROM pg_sequences                 WHERE schemaname='contoso'
ORDER BY 1;
```

The counts will **not** line up, and they are not supposed to. What matters is whether each
discrepancy has an explanation you can name:

| Source object type | Expected on target | If it is missing |
| --- | --- | --- |
| `TABLE`, `VIEW`, `INDEX`, `SEQUENCE`, `TRIGGER` | Roughly 1:1 | A real gap. Investigate |
| `PACKAGE` + `PACKAGE BODY` | Becomes a schema of functions, so the *count* changes shape entirely | Compare routine counts, not package counts |
| `SYNONYM` (174 of them) | **Nothing.** PostgreSQL has no synonyms | Expected — but did the report *say so*? |
| `JOB`, `PROGRAM`, `SCHEDULE` | **Nothing.** No in-database scheduler (H-14) | Expected. Needs `pg_cron` or an external scheduler |
| `TYPE BODY` | **Nothing.** No method dispatch (H-03) | Expected |
| `MLOG$_*` tables | **Nothing.** Fast-refresh machinery (H-15) | Expected |
| `MATERIALIZED VIEW` | 1:1, but **complete refresh only** | The object exists; its refresh semantics do not |

**The question that matters is not "is it missing" but "did the tool tell you".** A converter that
drops 174 synonyms and says so has behaved correctly. One that drops them silently has produced a
report you cannot trust about anything else either. Record which one you got.

Then check that what *did* arrive is healthy — the target-side counterpart of the Oracle assertion
in `src/oracle/99-verify-objects.sql`:

```sql
-- no unvalidated constraints
SELECT conrelid::regclass, conname, contype FROM pg_constraint
 WHERE connamespace='contoso'::regnamespace AND NOT convalidated;

-- every function actually compiles under plpgsql_check
SELECT p.proname, (plpgsql_check_function(p.oid))[1] AS first_issue
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'contoso' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname='plpgsql')
 LIMIT 50;
```

If `plpgsql_check_function` does not exist, the extension is not installed in `contoso_store` —
install it there for *your own* validation. The conversion tool only ever needed it on the scratch
database.

---

## 3. Level 2 — behavioural: does it answer the same questions?

The method: pick questions a business would actually ask, run them against both databases, and
diff. Not "does the query run" — **does it return the same rows**.

### The method

1. Write the question once for Oracle and once for PostgreSQL. They will not be textually identical;
   that is fine and is itself informative.
2. Run both, capturing sorted output to a file.
3. `diff`. Any difference is a finding until you have explained it.
4. Explain it, and classify: **conversion defect**, **acceptable semantic difference**, or **our
   test is wrong**. All three happen.

```bash
# The repo does not ship these query pairs - you write them, because which
# questions matter depends on what you are trying to prove. Put each one in
# out/validate/ as a pair: <id>.sql for Oracle, <id>.pg.sql for PostgreSQL.
# out/ is gitignored, so your working queries stay out of the repo.
mkdir -p out/validate

./scripts/connect.sh oracle-azure -c "@out/validate/q01.sql" > out/validate/q01.oracle.txt
./scripts/connect.sh postgres     -c "$(cat out/validate/q01.pg.sql)" > out/validate/q01.pg.txt
diff out/validate/q01.oracle.txt out/validate/q01.pg.txt && echo "q01 MATCH"
```

Sort deterministically in the query itself. `ORDER BY` with a unique tiebreaker, always — otherwise
you will spend an afternoon diffing two correct results that came back in different orders. And
note that Oracle sorts `NULL` last by default while PostgreSQL sorts it last only on `ASC`; on
`DESC` PostgreSQL puts it first. Use explicit `NULLS LAST` on both sides or you have manufactured a
difference.

### A starting set of questions

Each one is chosen because it crosses at least one hard case.

| # | Business question | Crosses |
| --- | --- | --- |
| Q1 | Top 20 products by revenue last quarter, per country | H-08 analytics, H-30 `ROWNUM`, T-01 numeric |
| Q2 | Customers with no order in 12 months, by loyalty tier | H-38 empty string, T-04 `CHAR` padding |
| Q3 | The full category tree with paths and depths | H-06 `CONNECT BY`, `SYS_CONNECT_BY_PATH`, `LEVEL` |
| Q4 | Every employee's management chain to the top | H-06 again, on a different tree, with a cycle guard |
| Q5 | Stock position by store and variant, as at a date | H-15 materialised view, H-19 partitioning |
| Q6 | Orders and their payments, including unpaid ones | H-32 `(+)` outer joins in `v_legacy_orders` |
| Q7 | Effective price for a variant/store/channel/date | H-24 `RESULT_CACHE`, H-31 `DECODE`/`NVL2` |
| Q8 | Trial balance by GL account, rolled up | H-06 bottom-up rollup, T-02 `DATE` truncation |
| Q9 | Promotion effectiveness by rule type | H-35 `XMLTYPE`/`XMLTABLE` |
| Q10 | Store trading hours in local time for one UTC instant | H-36 `INTERVAL`, H-37 `TSLTZ` |

Ten questions is enough to find most of what there is to find. Twenty is better. Fifty has
diminishing returns, because the same three root causes keep producing them.

---

## 4. The three that matter most

If you run nothing else, run these. Each is a case where the conversion **looks** correct and is
not, and each needs enough rows to be visible — which is why `--scale 0.01` is a legitimate way to
test *schema* conversion but not a legitimate way to test *behaviour*.

### H-30 — `ROWNUM` is not `LIMIT`

Oracle applies `ROWNUM` **before** `ORDER BY`. The naive conversion to `LIMIT` applies it after.
The two return a **different set of rows**, not merely a different order — and if the outer query
then aggregates, you get a different number with no indication anything happened.

```sql
-- Oracle: ROWNUM assigned before the sort
SELECT * FROM (SELECT product_id, list_price FROM product WHERE ROWNUM <= 10)
 ORDER BY list_price DESC;
```

```sql
-- PostgreSQL, as a converter is likely to render it: sort first, then limit
SELECT product_id, list_price FROM contoso.product ORDER BY list_price DESC LIMIT 10;
```

The Oracle version returns ten *arbitrary* products sorted by price. The PostgreSQL version returns
the ten *most expensive* products. Both are ten rows. Only one of them is what the source did.

The faithful conversion of the Oracle behaviour is a subquery with no ordering and a `LIMIT` inside
it — which looks wrong to every reviewer, and is right.

### H-32 — `(+)` on the wrong side

`v_legacy_orders` uses Oracle's `(+)` outer-join syntax throughout, on purpose.

```sql
-- Oracle: keep all orders, payments optional
SELECT o.order_id, p.amount FROM sales_order o, order_payment p
 WHERE o.order_id = p.order_id(+);
```

The `(+)` marks the side that is allowed to be null-extended — which is the **opposite** of where
`LEFT` goes in the ANSI form. Get it backwards and you produce `RIGHT JOIN`, the query runs
perfectly, and unpaid orders vanish from the result. Count them:

```sql
-- both sides; the numbers must match
SELECT COUNT(*) FROM sales_order o
 WHERE NOT EXISTS (SELECT 1 FROM order_payment p WHERE p.order_id = o.order_id);
```

### H-38 — empty string is `NULL`

Oracle treats `''` as `NULL`; PostgreSQL treats it as a zero-length string that is emphatically not
`NULL`. After the copy, an Oracle `''` has arrived as a PostgreSQL `NULL` — faithfully — and every
predicate over that column now behaves differently.

```sql
-- Oracle: both return the same rows, because '' IS NULL
SELECT COUNT(*) FROM customer WHERE middle_name IS NULL;
SELECT COUNT(*) FROM customer WHERE middle_name = '';
```

```sql
-- PostgreSQL: these are now two different questions
SELECT COUNT(*) FROM contoso.customer WHERE middle_name IS NULL;
SELECT COUNT(*) FROM contoso.customer WHERE middle_name = '';   -- 0
```

Nothing errors. Nothing is flagged. Rows quietly move to the other side of a predicate, and any
converted `WHERE col = ''` in a package body is now dead code that used to match rows. Grep the
converted source for `= ''` and `<> ''` and treat every hit as a defect until proven otherwise.

---

## 5. Level 3 — performance: what got slower, and why

Correct and unusably slow is still a failed migration. `pg_stat_statements` is allowlisted and
preloaded for this.

```sql
-- ./scripts/connect.sh postgres
SELECT pg_stat_statements_reset();
-- ... run your question set ...
SELECT calls, round(mean_exec_time::numeric,1) AS mean_ms,
       round(total_exec_time::numeric,0) AS total_ms, left(query, 90) AS query
  FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 25;
```

Four regressions this schema is built to produce:

| Case | Construct | What you should see |
| --- | --- | --- |
| **H-24** | `RESULT_CACHE` functions | `fn_convert_amount` and friends were memoised in Oracle. PostgreSQL has no equivalent, so the removal compiles cleanly and the function is now called once per row. Look for a function with an enormous `calls` count |
| **H-19** | Interval range partitioning | If the conversion flattened it to a single table, every query that relied on partition pruning now scans everything. `EXPLAIN` on Q5 will show it |
| **T-06** | Optimiser hints | `/*+ INDEX(...) */` and `/*+ PARALLEL(4) */` are comments to PostgreSQL. Silently ignored, no error, completely different plan |
| **H-23** | `DETERMINISTIC` functions | Oracle's `DETERMINISTIC` and PostgreSQL's `IMMUTABLE` are not the same promise. If the converter dropped the marker, function-based index equivalents stop being usable |

Compare plans side by side rather than raw timings — the two databases are on different hardware
and raw times are not comparable, but "index scan became sequential scan" is.

```sql
-- Oracle
EXPLAIN PLAN FOR <query>;  SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
```

```sql
-- PostgreSQL
EXPLAIN (ANALYZE, BUFFERS) <query>;
```

---

## 6. Recording results

This is the deliverable. One row per hard case:

| Case | Predicted | Observed | Tool flagged it? | Agent mode fixed it? | Human minutes |
| --- | --- | --- | --- | --- | ---: |
| H-02 | review task | | | | |
| H-19 | partial | | | | |
| H-26 | review task | | | | |
| H-30 | partial | | | | |
| H-32 | partial | | | | |
| H-38 | review task | | | | |
| … | | | | | |

The predictions for all 43 cases are in [`design.md`](design.md) section 9. The headline prediction
is **10 clean, 21 partial, 12 review task**.

Four rules that make the record worth having:

1. **Where observation disagrees with prediction, observation wins.** Correct section 9 of
   `design.md` in the same change, and say why. The lab is worth more as an honest record than as a
   demo.
2. **Record the model name and the extension version at the top.** Results are not comparable
   across either. `code --list-extensions --show-versions | grep vscode-pgsql`.
3. **Record whether `plpgsql_check` was actually allowlisted.** A run without it is not a data
   point, it is a blank. See [03 § 1.1](03-run-ai-migration.md#11-plpgsql_check-is-fail-open--check-it-first).
4. **"Tool flagged it?" is a separate column from "was it wrong?" on purpose.** The four
   combinations are all different findings, and the dangerous one is *not flagged, and wrong*.

| | Tool flagged it | Tool did not flag it |
| --- | --- | --- |
| **Converted correctly** | Conservative — a little noisy, harmless | Ideal |
| **Converted wrongly** | Working as designed — you were warned | **The one that matters.** Every instance is worth writing up |

---

## 7. What "done" looks like

Honest completion criteria, in order:

- [ ] Every object type gap in § 2 has a named explanation, and you know whether the report
      mentioned it
- [ ] No unvalidated constraints on the target
- [ ] `plpgsql_check` returns no issues over the converted routines — *and* it was allowlisted
      during the conversion run
- [ ] At least ten differential questions run on both sides, with every difference explained
- [ ] H-30, H-32 and H-38 explicitly tested with enough rows to be meaningful
- [ ] Plans compared for the four Level 3 cases
- [ ] One row per hard case recorded, with `design.md` section 9 corrected where it was wrong

What this does **not** establish, and should not be claimed:

- That the application works. Nothing here executes application code. That is the public-preview
  application/code conversion, and it is a separate exercise with a separate scope.
- That the conversion is production-ready. Microsoft's own documentation says AI-generated
  conversions must be reviewed by a human before production use, and that is the correct position.
- That the numbers generalise. One schema, one model, one run. A second run with the other model is
  the cheapest way to find out how much of your result was the tool and how much was the weather.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The Oracle source has INVALID objects | Real compilation errors, or dependency order | `EXEC DBMS_UTILITY.COMPILE_SCHEMA('CONTOSO');` then re-read `user_errors`. **Do not convert until the count is zero** — § 1 |
| A converted routine is nonsense and the Oracle original looks odd too | The source object was INVALID when it was converted | Fix the source, re-seed, convert again. The run's other findings are contaminated too — § 1 |
| Every date-formatted comparison differs | `pg_catalog` wins the search path, so `to_char` is PostgreSQL's | Call `oracle.to_char(...)`, and set the database-level `search_path` |
| Row counts match, content does not | The copy truncated silently, or a `DATE` became `date` | [04 § 7 and § 8](04-migrate-data.md#7-the-long-column) |
| Diffs that are only ordering | No unique tiebreaker in `ORDER BY`, or `NULL` sort order | Add a tiebreaker and explicit `NULLS LAST` on both sides |
| `plpgsql_check_function` does not exist | The extension is not installed in `contoso_store` | `CREATE EXTENSION plpgsql_check;` — the tool only needed it on scratch |
| Materialised views are empty | They are populated by `REFRESH`, not by the data copy | `REFRESH MATERIALIZED VIEW contoso.mv_…;` — and note that PostgreSQL has no incremental refresh (H-15) |
| A converted query returns fewer rows and no error | `(+)` translated to the wrong join side | § 4, H-32 |
| A converted query returns different rows entirely | `ROWNUM` translated to `LIMIT` | § 4, H-30 |
| `WHERE col = ''` matches nothing on the target | Oracle's `''` arrived as `NULL` | § 4, H-38. Rewrite as `IS NULL` and record it as a finding |
| Everything passes and it looks too easy | `plpgsql_check` was fail-open during conversion, or `--scale` was too small for behaviour to show | Re-check the allowlist; re-run behavioural tests at `--scale 1` |

A fuller symptom index for the whole lab is in [troubleshooting.md](troubleshooting.md).

---

You now have a converted, populated, and measured database, and a record of where the conversion
was right, where it was wrong, and where it was wrong *quietly*. That last column is the one worth
publishing.

Back to the [README](../README.md), or to [`design.md`](design.md) section 9 to correct the
predictions you just disproved.
