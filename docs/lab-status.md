# Lab status — what is verified and what is not

**Last updated: 2026-09-02.**

This document exists so you know how much to trust the rest of this repository. It separates
**what has actually been executed and observed** from **what has only been written down**. Where
those two disagree, this page records the disagreement rather than smoothing it over.

Read this before you spend money.

> **The short version.** The Oracle side of this lab is real and proven: the schema builds, it is
> large, it is valid, and it contains the hard cases it claims to. The **Azure side has now been
> deployed for real once, and destroyed** (2026-09-02): the infrastructure stands up, the deployed
> resources match what the docs claim, and teardown removes the resource group cleanly. But the
> **AI conversion has never been run**, the Oracle VM was never driven through to a working
> database, and **no data has ever been migrated**. Every prediction in `docs/design.md` about how
> the converter will behave is still a prediction, not an observation.

---

## 1. Verified by actual execution

Everything in this section was run on a developer machine (macOS 14, Apple Silicon, Docker Desktop,
`bash` 3.2, Python 3.14, Azure CLI logged in) on 2026-09-02, and the output inspected.

### 1.1 The static test suite — all 8 checks pass

`./tests/run-tests.sh` with no target flag, and again as CI runs it:

| Check | Result | Detail |
| --- | --- | --- |
| `bash-syntax` | PASS | 8 scripts parse under `bash -n` |
| `shellcheck` | PASS | 8 scripts clean at `severity=warning`, shellcheck v0.10.0 |
| `exec-bits` | PASS | 8 shell scripts executable |
| `bicep-build` | PASS | 8 templates compile under `az bicep build` |
| `python-compile` | PASS | both generators compile |
| `generator-determinism` | PASS | 13 files byte-identical across two different `PYTHONHASHSEED`s |
| `markdown-links` | PASS | 99 relative links across 11 files, 0 broken |
| `secret-scan` | PASS | no real GUIDs, no tracked `.env` |

### 1.2 The Oracle schema genuinely builds, and is genuinely large

The full seed was executed end to end against a local Oracle Free 23ai container and
`tests/verify-schema.sql` was run against the result.

- **1,823 objects** by the contract's counting rule
  (`user_objects` excluding `LOB`, `TABLE PARTITION`, `INDEX PARTITION`, `LOB PARTITION`).
- **1,448 objects** if you also exclude `TABLE SUBPARTITION` and `INDEX SUBPARTITION`.
- **The 1,000-object floor is met on either interpretation.** This is the binding requirement and it
  passes with large headroom.
- **0 objects with status `INVALID`.** Nothing in the schema is a compilation stub.
- **98 foreign keys, all `ENABLED` and `VALIDATED`.** All PK/UK/CHECK constraints likewise.

### 1.3 The hard migration cases are actually present, not just described

`verify-schema.sql` section A6 asserts each construct exists by querying the data dictionary. **All
19 construct assertions pass:**

| Case | Construct | Observed |
| --- | --- | --- |
| H-19, H-20 | Partitioned tables | 5 |
| H-18 | Index-organized tables | 4 |
| H-21 | Global temporary tables | 3 |
| H-15 | Materialised views + MV logs | 6 MVs, 3 logs |
| H-03 | Object types + inheritance | 9 types, 2 subtypes |
| H-04, H-05 | VARRAY + nested table types | 4 + 5 |
| H-26 | Compound triggers | 9 |
| H-27 | `INSTEAD OF` triggers | 7 |
| H-17 | Virtual columns | 13 |
| H-33 | The one `LONG` column | 1 |
| H-35 | `XMLTYPE` columns | 2 |
| H-37 | `TIMESTAMP WITH LOCAL TIME ZONE` columns | 143 |
| H-16 | Function-based indexes | 46 |
| H-14 | Scheduler jobs | 10 |
| H-40 | VPD policies | 3 |
| H-02 | `PRAGMA AUTONOMOUS_TRANSACTION` | 3 program units |
| H-06 | `CONNECT BY` in PL/SQL | 17 program units |
| H-24 | `RESULT_CACHE` | 12 program units |
| T-07 | Quoted mixed-case table | 1 |

All 43 hard-case IDs `H-01` … `H-43` are referenced in `src/oracle/`, and the hand-written sources
carry **189 `MIGRATION NOTE` comments**. The generated corpus marks its embedded hard cases with
`H-nn` references in file headers rather than the `MIGRATION NOTE` prefix — a different convention,
not an absence.

### 1.4 `preflight.sh` behaves correctly on a clean clone

Tested by copying only the files git would commit into an empty directory, running
`cp .env.example .env`, and running preflight **without editing any placeholder**:

- It collected **6 distinct failures**, printed the exact fix for each, exited **1**, and deployed
  nothing.
- It correctly refused to proceed on placeholder passwords, the placeholder subscription ID, and the
  placeholder Key Vault name.
- Resource-provider, region, compute-quota and Foundry-quota probes all executed against live Azure
  and returned real answers.

This is the single best-tested script in the repo.

### 1.5 Bicep compiles, and the whole thing now deploys

All 8 templates and the `.bicepparam` compile cleanly. Compiling is not deploying — but as of
2026-09-02 the deploy path has now been executed for real too. See §1.6.

### 1.6 The Azure deployment stood up for real — once — and tore down cleanly

On 2026-09-02, against subscription `MCAPS-Hybrid-REQ-72163-2024` in `swedencentral`, the full
deploy-and-destroy path was executed end to end for the first time:

- `scripts/deploy.sh --what-if` validated cleanly against real ARM: **"Resource changes: 25 to
  create."**
- `scripts/deploy.sh --yes` then deployed for real. All six modules reached **Succeeded** —
  `deploy-network`, `deploy-foundry`, `deploy-postgres`, `deploy-jumpbox`, `deploy-bastion`,
  `deploy-oracle-vm` — and **20 resources** were created.
- `scripts/destroy.sh --yes` deleted the entire resource group in **13m 10s**. `az group exists`
  returns **false** afterwards. Destroy also renamed `generated/outputs.json` to
  `outputs.json.stale`, and left the local Docker container, `./generated` and `.env` untouched.

This is the single biggest change to this page since it was written. The deploy and teardown paths
the README tells you to rely on to start and stop the meter are no longer theoretical.

### 1.7 The deployed resources were verified with `az`, not assumed

While the resource group existed, the configuration claims the docs make were queried against the
live resources and matched:

| What the docs claim | What the live deployment showed |
| --- | --- |
| Foundry model deployment `o2p-schema-conversion` | model **`gpt-5.2`**, version **2025-12-11**, capacity **500** (500,000 TPM), `provisioningState` **Succeeded** |
| `azure.extensions` applied exactly as specified | `orafce,uuid-ossp,pgcrypto,pg_trgm,postgis,postgis_topology,postgis_tiger_geocoder,pg_partman,pg_stat_statements,plpgsql_check,dblink` |
| `shared_preload_libraries` | `pg_partman_bgw,pg_stat_statements,plpgsql_check` |
| Two databases on one flexible server | `contoso_store` **and** `migration_scratch` both present (alongside Azure's own `azure_maintenance`, `postgres`, `azure_sys`) |
| Both VMs at `Standard_D4s_v5` | `o2p-jump` and `o2p-oracle-vm`, both running |

The most load-bearing line there is the extensions one. **`plpgsql_check` really is on the
`azure.extensions` allowlist and in `shared_preload_libraries` on a live server** — the fail-open
trap this whole lab warns about is closed by the template exactly as claimed, now confirmed against
Azure rather than inferred from the Bicep.

### 1.8 Two real bugs, found only by deploying, now fixed

Static analysis had passed all of this. Deploying against real ARM found two defects that no amount
of `bicep build` or `shellcheck` would have surfaced. Both are now fixed in `scripts/deploy.sh`:

1. **The rendered cloud-init exceeded Azure's `customData` cap.** It was **104,264** base64
   characters; Azure caps `osProfile.customData` at **87,380**. The first real deployment failed
   with `InvalidParameter` on `osProfile.customData` after about eight minutes. The fix gzips the
   document before base64 — cloud-init sniffs the gzip magic bytes and inflates it itself — which
   brings it to **28,756** characters. `deploy.sh` now also checks the limit up front and fails
   immediately, printing the real numbers, instead of losing eight minutes to ARM first.
2. **The billing-confirmation prompt died where there is no terminal.** It tested `[[ -r /dev/tty ]]`,
   which only checks permission bits. In CI, a detached job, or a container with no controlling
   terminal, the device node is readable but `open()` fails with `ENXIO`, so the test passed and the
   `read` then died mid-run. It now tests whether the device actually opens, and otherwise fails
   cleanly, telling the reader to pass `--yes`.

These are precisely the class of defect that §2's warnings exist to flag as *possible*. Deploying
turned two of them from "possible" into "found and fixed".

---

## 2. NOT verified — do not assume these work

The deployment ran and the resource group came up clean (§1.6–§1.8), but almost everything
downstream of "the infrastructure exists" did not run. Do not let §1.6–§1.8 talk you into trusting
any of the following.

### 2.1 What the deployment did *not* exercise

The infrastructure stood up; nothing was driven through it.

- **The Oracle VM was created and booted, but was never confirmed to reach a working database.**
  cloud-init started, but nobody watched it through to `DATABASE IS READY TO USE!`, and `CONTOSO`
  was never loaded on the VM.
- **`scripts/seed-oracle.sh --azure` was never run.** Only the `--local` Docker path is proven for
  seeding; `scripts/install-oracle.sh` ran on the VM only as far as cloud-init carried it on its
  own.
- **`scripts/connect.sh` and `scripts/status.sh` were never run against the live resources.** The
  Bastion-tunnel, connection and allowlist-reporting logic in those two scripts is still
  unexercised end to end, even though the resources they target were up.

What *is* newly confirmed is that a successful `deploy.sh` writes `generated/outputs.json` — destroy
later renamed it to `outputs.json.stale` — so the Bicep output names the scripts depend on
(`postgresServerName`, `foundryEndpoint`, `bastionName`, `oracleVmName`, `oracleVmId`,
`oracleAdminUsername`, `resourceGroupName`) really are produced, not just declared. That is more
than the old static consistency check, but it is still not evidence that `connect.sh`, `status.sh`,
or a seed against the VM works.

### 2.2 The AI conversion itself. Never run.

**No conversion has ever been performed with this schema.** The Foundry deployment now provably
*exists* (§1.7), but it has never been *called*. Specifically untested:

- The `ms-ossdata.vscode-pgsql` extension against this source. It has to be driven interactively
  from the jumpbox in VS Code, and nobody has logged into the jumpbox to do it.
- Whether the deployed `gpt-5.2` model actually *serves* a conversion. It deployed with 500,000 TPM
  capacity and `provisioningState` Succeeded (§1.7); that is not the same as having converted a
  single object.
- The scratch-database compile step and `plpgsql_check` validation. The allowlist and preload
  library are confirmed present on the live server (§1.7); the tool that consumes them never ran.
- GitHub Copilot agent mode on the review-task queue.
- **Every prediction in `docs/design.md` section 9** — the "10 clean, 21 partial, 12 review task"
  split and all 43 per-case predictions are reasoned guesses. **Zero have been observed.** The
  README says observation beats prediction; as of today there are no observations.
- The claimed 45–90 minute conversion time and the $5–30 token cost.

### 2.3 Data migration and validation. Never run.

- `ora2pg` has never been run; `tools/ora2pg.conf` is untested.
- **No data has ever been migrated.** A PostgreSQL target server *was* created and its server-level
  configuration verified — the `azure.extensions` allowlist and `shared_preload_libraries` are
  confirmed on the live server (§1.7) — but `contoso_store` and `migration_scratch` were left
  empty: no converted schema, no rows. The database-level `search_path` claim was never applied or
  checked on a live database.
- The differential testing method in `docs/05-validate.md` has never been executed. That document
  describes a method; it does not report results.

### 2.4 Cost and timing figures

Every number in "What it costs" and "How long it takes" is an **estimate from public pricing**, not
a measured bill. The 2026-09-02 deployment did create billable resources for the time it existed, so
a small real charge was incurred — but no itemised bill was captured and compared against the
estimates, and no steady-state day was ever run. The one hard timing number now on record is
teardown: `scripts/destroy.sh` deleted the resource group in **13m 10s** (§1.6).

### 2.5 Client platform claims

VS Code version floors, the ARM64 caveat, and the Windows-jumpbox recommendation are taken from
Microsoft's documentation. No client was set up and no extension was installed.

---

## 3. Known discrepancies between the docs and reality

These are real inconsistencies found by inspection. None of them break the build. Several have since
been fixed and are marked **Resolved** inline (dated); the rest will still mislead a careful reader.

### 3.1 Object count — resolved: docs now state ~1,820, with 1,110 kept only as the design budget

The README headline, the architecture diagram, `docs/design.md` and roughly **18 other places** used
to call this a "1,110-object" schema, presenting the **per-type design budget** (the minimums in the
README / `design.md` section 8 table, which sum to 1,110) as if it were the live object count. The
measured count is **1,823** by the contract's counting rule (§1.2), of which **1,448** are
non-partition objects; the remainder are subpartitions of composite-partitioned `inventory_movement`
that drift with data volume. Actual per-type counts exceed nearly every design minimum (`INDEX`
332 vs 78, `TABLE` 108 vs 64, `VIEW` 208 vs 198).

**Resolved (2026-09-02):** the docs now use **~1,820** as the headline, add the ~1,450-non-partition /
subpartition-drift note wherever the number is explained, keep **1,110** only where it is explicitly
the design budget, and describe the 1,000 floor as comfortably cleared. `docs/02-seed-oracle.md`'s
sample transcript now prints `TOTAL_OBJECTS=1823` and an abridged real census. The 1,000 floor
remains the only asserted figure (`src/oracle/99-verify-objects.sql`), which still reports 1,110 as
its design target — correct, since that is the budget. Take the exact figure from your own seed run;
it moves as the generated half is tuned and with data volume.

### 3.2 `verify-schema.sql` fails 2 of 41 assertions — `PACKAGE` and `PACKAGE BODY` are short

| Type | Actual | Design minimum | Gap |
| --- | ---: | ---: | ---: |
| `PACKAGE` | 74 | 85 | −11 |
| `PACKAGE BODY` | 74 | 85 | −11 |

This is scale-independent and reproducible. Either the generator should emit 11 more package pairs
or `docs/design.md` should lower the figure. **`tests/run-tests.sh --local` exits non-zero because
of this**, so the repo does not currently pass its own full test suite.

### 3.3 `verify-counts.sql` contradicts the deliberately-messy seed data

`generated/oracle/data/14-data-messy-edge-cases.sql` **intentionally** inserts negative stock, and
says so in a comment: *"Retail books negative stock every day: shrink, write-off, reversal … Any
converted report that assumes non-negative quantities is wrong before it runs."*

`tests/verify-counts.sql` assertion **B2-e "no negative qty_on_hand"** then fails on exactly that
data (80 rows). One of the two is wrong. This is a design decision, not a typo.

### 3.4 800 of 801 GL journals do not balance

Assertion **B2-o "every GL journal balances"** reports **800 unbalanced journals** out of 801 rows.
Unlike §3.3 this does **not** appear to be deliberate — the messy-data file only adds one journal,
for an unrelated `DATE`-truncation case, and nothing documents unbalanced journals as intentional.
This looks like a genuine defect in the finance data generation in
`generated/oracle/data/13-data-finance.sql`. A trial-balance query (question Q8 in
`docs/05-validate.md`) will produce nonsense until it is fixed.

### 3.5 Test-harness scale — resolved: the harness now detects the scale

`tests/run-tests.sh --local` used to default to `--scale 1`; run against a `--scale 0.01` seed it
produced **31 failures, 24 of them pure scale mismatch** ("SHORT" row counts), which trains a reader
to ignore failures.

**Resolved (2026-09-02):** before running `verify-counts`, the harness measures the actual
`sales_order` volume and either **auto-selects** the matching named scale when `--scale` was not
given, or **fails immediately, naming the right flag**, when an explicit `--scale` is an order of
magnitude off the data. `verify-schema` is scale-independent and is unaffected, and CI still passes
`--scale 0.01` against its 0.01 seed (the detector confirms it). The genuine, non-scale failures are
unchanged — see §3.2–§3.4.

### 3.6 Oracle image — resolved: documented honestly

`.env.example` set `ORACLE_IMAGE=container-registry.oracle.com/database/free:latest`, but the schema
was actually proven against **`gvenzl/oracle-free:23-slim`** (container `oracle-lab`), which is also
what the `oracle-smoke` CI workflow uses.

**Resolved (2026-09-02):** `.env.example` and `docs/02-seed-oracle.md` now state this plainly. The
official Oracle image stays the `ORACLE_IMAGE` default for the **Azure VM** path; the **local Docker**
path (and CI) use `gvenzl/oracle-free:23-slim`, which needs no registry login and starts far faster,
so it is the documented local default. The official image still works locally after
`docker login container-registry.oracle.com`. Both are Oracle Free 23ai; the conversion itself has
still never been run against either (§2.2).

### 3.7 Unused `.env.example` variables — resolved

`AZ_TENANT_ID`, `VSCODE_EXTENSION_ID`, `VSCODE_MIN_VERSION`, `EXTENSION_MIN_VERSION`,
`ORACLE_UTL_FILE_HOST_DIR` and `OUT_DIR` were read by no script, template or workflow.

**Resolved (2026-09-02):** `AZ_TENANT_ID`, `ORACLE_UTL_FILE_HOST_DIR` (also misleading — the UTL_FILE
host path is chosen by `install-oracle.sh` under the VM data mount, not by this variable) and
`OUT_DIR` are deleted. `VSCODE_EXTENSION_ID`, `VSCODE_MIN_VERSION` and `EXTENSION_MIN_VERSION` are
kept but now carry a `REFERENCE ONLY` comment stating that no script reads them and what they pin.

### 3.8 Conflicts inherited from Microsoft's own documentation

Two of these remain genuinely unresolved; the third — the model name — was settled by the
2026-09-02 deployment and is marked so:

- **Model name — resolved (2026-09-02).** `gpt-5.2` is **verified deployable in `swedencentral`**:
  preflight found quota `OpenAI.GlobalStandard.gpt-5.2: 1000/1000 kTPM free`, and the deployment
  created the model at version **2025-12-11** (§1.7). Microsoft's own `mslearn-postgresql` lab
  template still defaults to `gpt-5-mini`, so the two documents still disagree on which to *use*;
  what is no longer in question is that the Learn-documented `gpt-5.2` is real and deployable. Model
  availability still varies by region, so `preflight.sh` checks it, and `FOUNDRY_MODEL_NAME` still
  selects between them.
- **RBAC role.** Learn says **Foundry User**; DP-300 lab 18 says **Cognitive Services OpenAI User**.
  Still unresolved — grant whichever your portal offers.
- **Oracle source version.** Microsoft documents 12.1, 12.2, 18c, 19c and 21c as supported
  conversion sources. This lab — and Microsoft's own lab — uses **23ai**, which is not on that list.

---

## 4. Security and privacy posture

**Scanned and clean.** Every file git would commit was checked:

- No occurrences of the maintainer's name or any personal identifier.
- No `/Users/...` or other absolute personal paths.
- The only GUIDs present are five instances of `00000000-0000-0000-0000-000000000000`.
- No hardcoded credentials. Every password reference resolves to a shell variable, a
  `readEnvironmentVariable()` call, a Key Vault secret *name*, or a `__PLACEHOLDER__` token that
  `deploy.sh` substitutes at render time.
- `.env`, `generated/` and `out/` are gitignored and untracked. `.env.example` is correctly
  re-included by a negation rule.
- The repo's own `secret-scan` check enforces this in CI on every push.

**One caution that is not a repo defect.** `scripts/preflight.sh` prints your real Azure sign-in
address and, when the subscription does not match, your **real subscription ID** to the terminal —
by design, as part of the fix hint. `docs/00-prerequisites.md` already warns against pasting those
back into the repo. Redact both before pasting preflight output into an issue or a screenshot.

---

## 5. Licence and disclaimer

- `LICENSE` is present: **MIT**, "Contoso Store Migration Lab contributors".
- The **"not an official Microsoft product"** disclaimer is present and unambiguous, in two places
  in `README.md`: the scope callout near the top and the `## Disclaimer` section at the bottom. It
  covers non-affiliation with both Microsoft and Oracle, trademark attribution, the synthetic nature
  of all data, and the fact that running the lab creates billable resources.

---

## 6. What a new user should actually expect

| If you want to… | Can you, today? |
| --- | --- |
| Read a large, realistic, deliberately hostile Oracle schema | **Yes.** This is the strongest part of the repo |
| Build that schema locally in Docker and poke at it | **Yes.** Proven working, ~1,823 objects, 0 invalid |
| Study 43 documented hard migration cases with predictions | **Yes**, as analysis. The predictions are untested |
| Run the repo's static checks and CI | **Yes.** All 8 pass |
| Run the repo's full Oracle test suite and see it green | **No.** 2 schema assertions and 2 data assertions fail — §3.2, §3.3, §3.4 |
| Deploy the Azure environment from Bicep | **Yes.** Deployed for real and destroyed clean on 2026-09-02 (§1.6); the live resources were verified (§1.7) |
| Seed Oracle on the Azure VM, or run `connect.sh` / `status.sh` live | **Unknown.** The VM booted; nothing was driven through it (§2.1) |
| Run the AI conversion and compare against the predictions | **Unknown.** Never attempted |
| Trust the cost estimates | Treat as order-of-magnitude only |

**Recommended first step:** `./scripts/seed-oracle.sh --local --scale 0.01`, then
`./tests/run-tests.sh --local --scale 0.01`. That path is proven, costs nothing, and exercises the
part of this lab that is genuinely finished.

---

## 7. How to update this page

This document is only useful if it stays honest. When you run something that is listed here as
unverified, move it to §1 with the date and the observed numbers — and if it failed, say so and
move it to §3. A status page that only ever gains green checkmarks is not being maintained; it is
being marketed.
