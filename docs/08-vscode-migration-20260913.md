# 08 — VS Code migration and agent continuation (2026-09-13)

**Status: VS Code conversion completed; four agent-reviewed candidates verified. Full migration acceptance remains incomplete.**

This run follows the requested order: run the actual VS Code PostgreSQL migration
workflow, preserve its terminal conversion results, then invoke the repository's
GitHub Copilot migration agents on the remaining work. Neither the historical
**79.92%** conversion result nor intermediate checkpoints certify this run.

## Terminal conversion result

At **02:30 UTC on 2026-09-14**, the actual VS Code UI displayed **Migration Complete**
and **105 of 105 chunks**, and both the backend session and conversion index recorded
`completed` for the same session, `aacf0b96`.

| Reported measure | Observed result |
| --- | --- |
| Extracted artifacts | 1,346; zero extraction failures; 138 exclusions |
| Completed chunks | 105 / 105; zero final failed chunks |
| Standalone-object conversion | **1,146 / 1,232 eligible (93.02%)**, as reported by the converter |
| Model | `gpt-5.2`, deployed version `2025-12-11` |
| Reported tokens | 6,141,972 |
| Converter cost estimate | $17.49; not an itemized cloud bill |
| Recorded session duration | 6,717 seconds; a resumed-run statistic, not end-to-end elapsed time |
| Wizard start to terminal progress | Approximately **8h 35m**, including interruptions and recovery |

The customer summary differs by one standalone object: **1,145 / 1,232 (92.94%)**
rather than the technical report's 1,146 (93.02%). Both raw reports and their hashes
are preserved; this discrepancy has not been silently reconciled.

The final technical report, deployment SQL, mapping CSV, review artifacts, and
session metadata are preserved in a private immutable snapshot with **7,943 hashed
files**. The terminal receipt and per-file manifest are retained under this run's
`out/` directory. This is genuine completed converter output, not intermediate chunk
SQL or a relabelled historical run.

**Completion is not deployment approval.** Final artifact analysis logged **213
findings, including 143 blocking findings**; 143 findings were reported at run level
rather than attributed to a single object. The object manifest listed **10
unaccounted-for source objects**. The exported review material contains **523 action
items, two run-level actions, and 548 compatibility considerations**. These counts
have different scopes and must not be added to a conversion-success denominator.
The raw artifacts remain the input to the following repair/review stage, not a
certified full schema/data migration.

The exact ten identifiers are preserved in `internal/review_tasks/review_tasks.json`,
run-level action **`RT-MANIFEST-1056`** (`MANIFEST.UNACCOUNTED.ALL`):

- `PACKAGE_BODY:pkg_audit`
- `PACKAGE_BODY:pkg_catalog`
- `PACKAGE_BODY:pkg_error`
- `PACKAGE_BODY:pkg_etl_export`
- `PACKAGE_BODY:pkg_finance_gl`
- `PACKAGE_BODY:pkg_fulfilment`
- `PACKAGE_BODY:pkg_gen_ifc_in_003`
- `PACKAGE_BODY:pkg_gen_ifc_out_024`
- `PROCEDURE:pkg_order_mgmt$validate_basket`
- `TRIGGER:trg_ad_coupon_audit`

These are the manifest action's reported identifiers, not an inference from package
container status or proof that every package member is absent. The action is marked
manual review/action-required with `blocking_release=false`; it does not clear or
replace the separate 143 reported blocking artifact findings. Earlier guesses that
included the schema object were not used as verified evidence.

The reported duration does not include the whole first invocation, downtime, and
recovery sequence. Token/cost fields are the converter's reported totals and are
not billing evidence for every unsuccessful or interrupted call. This resumed,
interrupted run is also not a controlled benchmark against the historical 79.92%
result; the reported denominators differ.

## Verified preflight

Observed on **2026-09-13**, using the dedicated VS Code Remote-SSH workspace on the
existing Oracle lab VM:

- VS Code **1.137.0** and Microsoft PostgreSQL extension **1.30.1** are available.
- The actual migration wizard successfully connected as **`O2P_READER`** and loaded
  the available schemas. Only **`CONTOSO`** was selected.
- A separate read-only Oracle metadata transaction found **zero invalid CONTOSO
  objects**. It did not recompile or reseed the source.
- The reader account was open and held the required `SELECT` grant on
  `SYS.ARGUMENT$` for package-argument extraction.
- Observed source counts include **108 tables**, **136 functions**, **112
  procedures**, **90 packages**, **90 package bodies**, **208 views**, **96
  triggers**, **18 types**, and **8 type bodies**. These are dictionary object
  counts, not the count of base tables eligible for data loading.

## Isolation and execution gates

The conversion uses a **new, uniquely named compiler database**, not the old
compiler database or an existing application target. Its setup receipt, completed
at **17:44 UTC**, verifies PostgreSQL **16.15**, zero user tables, the required
extensions installed, and `plpgsql_check` present in the running server's preload
libraries. The existing bounded actor passed an empty-schema creation probe that
was rolled back. No global role flags were changed.

VS Code's actual connection test passed using TLS. The wizard selected the exact
new profile/database and displayed **Extensions Verified**. Foundry's connection
test also passed with **Microsoft Entra ID**, the tenant matched to the lab's
subscription, and the existing **`gpt-5.2`** deployment.

Project creation paused at the dashboard with extraction and conversion both
**Not started**. Before **Migrate**, the generated project configuration was backed
up and received explicit single-worker limits with automatic quota-driven
parallelism increases disabled. The stored PostgreSQL database name matched the
new compiler target and no runtime sessions existed at configuration time.

The **Migrate** action was issued through the VS Code wizard at **17:54 UTC**.
Extraction completed in **2m 53s**: **1,346 extracted, zero failed, 138 excluded**.
The earlier discovery count was **1,307 extractable objects**; discovery and emitted
artifact counts are different counters, not interchangeable totals. Dependency
harvesting recorded **3,096 resolved edges and 367 unresolved references**.

Conversion session **`aacf0b96`** started at **17:57 UTC**, with **105 chunks**.
Its actual runtime snapshot confirms maximum/minimum parallelism **1**, automatic
optimization disabled, package-member/compile/catalog limits **1**, short compiler
transactions enabled, and the exact new compiler database. Compilation-time
`plpgsql_check` and its final barrier are enabled. The initial telemetry reports
**AIMD window 1**. A read-only compiler-database observation at **17:58 UTC** found
zero blocked sessions; this is an initial observation, not a claim about the
entire run.

**Early runtime findings:** the first two chunks completed by **18:03 UTC**.
Chunk `003` compiled 39 objects and deferred one cross-chunk dependency;
chunk `001` compiled all 40 objects. These are intermediate chunk results, not
final conversion totals. Session-summary counters remained zero during this
period and aggregate telemetry lagged the chunk-completion events, so observation
now also reads the actual per-chunk completion events.

The compiler explicitly disabled short transactions for chunk `003` because
strict-first routine validation requires its long-transaction engine. Chunk `001`
used the short-transaction engine. The configured flag therefore does **not**
establish that every chunk uses short transactions. Strict validation remains
enabled; single-worker execution is retained to limit contention.

**Authentication interruption and recovery:** from **19:19 UTC**, chunk `011`
logged repeated `CognitiveServicesTokenRefreshError` timeouts. The compiler had
zero blocked sessions and the dedicated editor window was hidden. After that
existing window and project tab were brought into view, successful model calls
resumed at **19:25:46 UTC**, and the chunk completed at **19:26:35 UTC**. No token
was injected or exported, no credentials or permissions were changed, and the
converter was not restarted. A separate CLI authentication-availability check
succeeded later, at **19:26:05 UTC**, so it was not the first observed recovery.
The precise callback/renderer root cause is not proven. Monitoring now surfaces
new token-refresh errors without waiting for the next chunk checkpoint.
Recurrences at **20:34 UTC** and **21:41 UTC** were detected by that alert and
recovered after restoring visibility of the same window; model calls and chunk
completion resumed without credential changes, token injection, or restarts.

The same chunk also logged a **300-second cycle-peer wait timeout** before review:
its peers had not converted yet under the one-worker limit. That is recorded as
waiting overhead, not database lock contention or a successful dependency check.
Read-only inspection of the installed-version implementation identified a supported
**future-run** setting, `converter.enable_early_release: false`, that skips this
wait. Scratch mode already disables effective early dependency release, while the
barrier still checks the raw configuration flag. Configuration is captured once
at conversion startup: changing YAML does not update the active job. The installed
UI/RPC surface offered no verified safe cancellation route, so the current run was
not interrupted for this optimization. The setting's control flow was inspected;
its final-output equivalence and performance were not runtime-tested in this run.

**PostgreSQL availability interruption:** Azure activity records show a server
stop request at **23:05 UTC**. At **23:09 UTC**, chunk `042` failed to connect to
scratch PostgreSQL; the converter quarantined its partial records instead of
emitting them as deployable DDL. An independent VM-to-server TCP probe timed out,
Azure reported **Stopped**, and the local forwarding process was still present.
The same existing lab server was started once at **23:14 UTC**; no databases were
recreated, no data reset, and no role or shutdown-schedule changes were made.
Azure returned **Ready** at **23:16 UTC**, and a read-only probe reached the exact
compiler database with its scratch relations intact. A subsequent read-only
administrator check verified TLS, the bounded actor's role flags, and
`plpgsql_check` **2.8** with its preload entry present. The bounded actor's own
server-setting inspection was refused; no extra grant was added. Recovery of the
failed chunk itself remains a separate gate, not implied by server availability.

**Converter-host interruption:** the same administrative caller later deallocated
the Oracle VM at **23:48 UTC**, interrupting the host running the conversion.
PostgreSQL remained Ready; the lost SSH route was not a second PostgreSQL stop.
The same VM was started at **23:55 UTC**, with no redeployment or source reseed.
The original SSH host identity matched, Oracle returned healthy, and a read-only
post-boot query found **2,094 valid CONTOSO objects and zero invalid objects**.

A new private pre-resume backup contains **3,272 hashed files**. All **55 completed
checkpoints** have matching raw source-chunk hashes (the converter uses the first
16 hexadecimal characters of SHA-256) and matching compiled SQL hashes. Failed
and in-flight work was not promoted to completed. After reconnecting the existing
VS Code project, its UI still displayed a disabled **Converting** button and
**0 of 0 chunks**, while the conversion log had not advanced since before reboot.
The stored `running` status is not evidence of a surviving worker. The status
reader was traced before any recovery edit was attempted.

**Audited operator recovery, 2026-09-14:** the UI's authoritative status comes from
the current entry in `convert/index.json`, not `session.json.status` alone. After
verifying the host interruption, new boot, unchanged pre-boot log, original file
hashes, and all 55 checkpoints, an operator repair at **00:31 UTC** reconciled only
this interrupted run's index/session statuses to **failed**, plus its metadata
update timestamp. Counters, checkpoint bytes, quarantine, source data, and real
migration-team queues/budgets were not edited. Original bytes and before/after
hashes were retained. This was **not a built-in extension repair command**, and no
work was marked completed to obtain a retry.

The scheduling-only setting `converter.enable_early_release: false` was applied
for the next invocation, with the other limits and validation settings unchanged.
Closing and reopening the existing project exposed the normal, enabled
**Conversion Failed** button. That ordinary retry was invoked once at **00:36 UTC**.
The actual log recorded **Resumed 55 chunks from checkpoints**, with the exact
verified checkpoint set, the same session `aacf0b96`, 105 total chunks, and
AIMD window 1. The original log prefix was preserved. The stored session
`config_snapshot` can retain the initial settings on reuse, so the changed
configuration is evidenced separately by its file hashes and resume boundary.

The outage-affected chunk `042` was retried first and completed at **00:39:46 UTC**:
**19 routines compiled, zero failed**, with 19 strict-first clean routine checks.
Its original failure evidence remains preserved. This establishes recovery of
that compile failure, not blanket source/target behavior equivalence.

The scheduling change's runtime benefit is **not established by this resume**:
the actual chunk dependency graph contains a 30-member strongly connected group,
and all 30 members were among the 55 reused checkpoints. The remaining graph is
acyclic. The pre-interruption log records 29 cycle-wait timeouts of 300 seconds
(**145 minutes of logged waiting**), but that is not a measured saving for the
remaining work. A resumed package chunk proceeded from conversion to review
without an observed wait; its dependencies were already complete, so that is not
an eligible test of the changed scheduling branch. No extra reconversion was run
merely to manufacture such a test.

Monitoring pins the new project's conversion session ID. Final acceptance requires
current-session terminal status, the technical report, deployment SQL, and an
inventory of unresolved objects. A populated scratch database or partial chunk SQL
is not a deployment artifact.

## Agent continuation gates

Fresh converter SQL and classifications are inputs to review, not accepted review
evidence. The continuation must preserve existing queue identities, source hashes,
validation attempts, independent-review requirements, and quarantines. Existing
attempts must be reconciled across all prior queues before any work is called
unstarted; a new queue must not reset an overlapping object's validation budget.

Previously held operational changes and new validation-budget grants remain held.
The requested migration does not silently authorize those separate changes.

A read-only public-CLI audit of **186 canonical tasks across nine execution queues**
found **59 reviewed, seven blocked, 119 queued, and one pending review**, with no
active claims. Fifty identities marked unstarted in the controller already had
recorded validation use. `STG_GEN_CAT_012` was queued but had exhausted all three
attempts. These are pre-continuation review states, not results of this conversion.

The fresh extraction was reconciled against the preserved source inventory:
**all 1,346 DDL files matched their exact type/name and recorded SHA-256**, with
no source-byte drift. This does not establish current data-snapshot freshness or
acceptance of any target candidate.

Source-only preparation captured **56 bounded Oracle observations** for
`FN_GEN_VALID_AMOUNT_011` (18), `FN_GEN_VALID_AMOUNT_021` (14), and
`FN_GEN_VALID_CODE_004` (24), after checking that their bodies were pure scalar
functions. The calls ran in read-only transactions. The code validator's measured
cases distinguish an empty string (`Y`) from spaces only (`N`) and include an
`ORA-06502` overflow case. These observations are inputs to later target checks,
not evidence of PostgreSQL parity or exhausted-budget authorization.

### Validator prerequisite and agent-instruction correction

A new **synthetic-only** public-CLI fixture passed compilation, one routine's deep
check, and four behavior assertions using the existing validator image. A controlled
contrast that only prepended `CREATE SCHEMA IF NOT EXISTS contoso;` failed with the
same `permission denied for database o2p_scratch` error preserved from an earlier
real task. The validator already provisions configured schemas; the redundant
statement requires database CREATE permission. No image rebuild or wider CONNECT
or CREATE grant was needed. Both disposable containers were removed, and no real
task validation attempt was consumed.

The repair-agent charter was corrected to avoid redundant schema setup and
unconditional Docker builds. It also contained an obsolete claim that coordinator
`unblock` resets the attempt counter; the corrected instructions require the actual
lifetime budget and explicitly prohibit resets, replacement queues, denied-command
retries, or agent-created grants. A read-only Copilot coordinator session actually delegated
to `o2p-repair` and `o2p-reviewer`: its native event trace contains two `task` calls
and eight `view` calls, with no shell or edit calls. A wording ambiguity about
releasing an unowned queued task was then clarified. A follow-up run of the real
repair agent read the final charter and correctly distinguished **no queue commands
for an exhausted queued task** from **release blocked for an exhausted task already
claimed by that worker**. These are synthetic instruction checks, separate from
the still-pending remaining-migration repairs.

## Actual remaining-team execution

After terminal conversion, the real `o2p-coordinator` delegated remaining-work
triage to repository agents. The reviewer lane completed, but the hard-case lane
was cut short by the configured Copilot credit ceiling. That partial triage is
not presented as a complete hard-case assessment, and it changed no queue state.

Three existing canonical tasks then completed real coordinator → repair →
independent reviewer runs through a narrowly scoped CLI. Public `show`/`audit`
confirmed fresh, hash-bound passing evidence and distinct worker/reviewer identities:

| Existing source task | Result | Assertions, excluding compile/deep-check phases | Lifetime attempts used |
| --- | --- | ---: | ---: |
| `FN_GEN_VALID_AMOUNT_011` | Independently reviewed | 28, including all 18 measured Oracle cases | 1 / 3 |
| `FN_GEN_VALID_AMOUNT_021` | Independently reviewed | 20, including all 14 measured Oracle cases | 1 / 3 |
| `FN_GEN_VALID_CODE_004` | Independently reviewed | 41: 38 source-observation cases plus three structural checks | 1 / 3 |

The fresh converter mapping already classified both amount functions as Converted
with no action-required flag. These runs therefore close previously unreviewed
team tasks; they are **not** evidence of two newly failed converter objects or a
higher conversion percentage. The second candidate is SQL-language, so its zero
PL/pgSQL routines deep-checked is expected; its actual function calls passed.

`FN_GEN_VALID_CODE_004` was action-required in the fresh mapping. Its accepted
candidate was checked against the original 24 source observations plus 14 additional
read-only byte/Unicode cases. It preserves the 60-byte buffer limit, trimming before
overflow, the source's measured Unicode uppercase behavior, and acceptance of `AB`
followed by a final newline. Expected Oracle string-buffer errors are explicitly
mapped to PostgreSQL SQLSTATE `22001` and exercised as errors, not substituted with
`N`. The verification-only SQLSTATE-capture helper is in the hashed test dependency
file, not the production candidate. Both PL/pgSQL routines were deep-checked with
zero findings.

**Independent combined runtime: passed.** A fresh local PostgreSQL target ran the
three unchanged, hash-matched production candidates as a non-superuser, with
exactly three production routines in its catalog and no verification helper.
All **70 recorded Oracle observations** matched: 18 amount-011, 14 amount-021,
24 code-004, and 14 additional byte/Unicode cases. This includes **seven actual
expected exceptions**, each observed as PostgreSQL SQLSTATE `22001`, rather than
replaced with a Boolean assertion. Independent `plpgsql_check` inspected the one
PL/pgSQL production routine with zero findings; the other two routines are SQL
language. Source packs retain intentional duplicate cases across groups.

Two preliminary verification-harness runs stopped before deploying/exercising
candidates; their failure receipts were preserved. The corrected harness used
unchanged candidate bytes. All three containers created for those verification
attempts were removed, and public queue audits still showed one lifetime attempt
used per task. No candidate, product, or queue mutation was used to obtain the
combined result.

**`SALES_ORDER_LINE` structural table repair: independently reviewed.** The first
coordinator session produced a passing candidate but reached its credit ceiling
before a reviewer verdict was recorded. A review-only continuation used the
already-permitted public `show`/`audit` hashes and recorded independent acceptance
without another validation attempt. The task remains at **1 / 3 lifetime attempts**.
Its 13 catalog assertions and attached normalization-function deep check passed.

A separate fresh local target then exercised **91 DML checks** and loaded an
explicitly scoped subset of the pinned 2026-09-10 source snapshot through the
public loader CLI: **5,600 rows**. Independent comparison covered **all 11 columns
and 61,600 cells**, including generated `line_total`, with **zero mismatches**.
The public comparator agreed, and a second load was refused with all rows unchanged.
The real data agent subsequently reran the exact source/target CSV comparison:
5,600 / 5,600 rows, zero missing keys, extra keys, or changed rows. The test container
was removed; the original source and existing targets were not used as disposable
test databases.

The existing plan permits this ordinary-table adaptation while preserving global
keys and row shape. Foreign keys, application AFTER triggers, physical partition
operations, performance, and full assembly remain separate gates. The referenced
`PRODUCT_VARIANT` lineage remains exhausted and was not bypassed.

**All five repository agent roles were exercised.** Coordinator, repair, and
reviewer performed the real candidate workflow. The data agent compared both the
70 function observations and the 5,600-row table exports. The hard-case agent
recorded only **H-38** as a **partial `reviewed_candidate`**, backed by the reviewed
code-validator task and actual combined observations; the other **42 cases remain
`not_tested`** in this run's checklist.

Hashes, verification outcomes, and a machine-readable results summary are recorded
in [`migration-results-20260914/`](migration-results-20260914/README.md). Reviewed
production SQL and expected function observations remain private under `out/`,
as required by the full-run contract; separate publication approval has not been granted.

No replacement queue, validation-budget reset, new grant, deployment, or data-load
acceptance was used to obtain these reviewed task outcomes.

## Results still pending

| Gate | Current result |
| --- | --- |
| Read-only Oracle source preflight | Passed |
| Dedicated compiler database and extension verification | Passed, including VS Code wizard verification |
| VS Code extraction and terminal conversion | Completed; actual UI and backend terminal state verified |
| Final conversion artifact preservation | Completed; immutable snapshot and per-file hashes retained |
| Real Copilot repair and independent review continuation | Three routines and one structural table independently reviewed; all five roles exercised; broader queue not complete |
| Bounded runtime and data verification | 70 function observations and 5,600 table rows/all 11 columns matched |
| Combined schema deployment and full data parity | Full 93-table result not established |
| Complete hard-case and operational acceptance | Not established |

Private runtime evidence is retained under
`out/vscode-migration-20260913-5xsf803a/`, including
`oracle-metadata-preflight.json`. Credentials, endpoint details, private connection
profiles, raw logs, and unredacted screenshots are not repository assets.

No production cutover, cloud teardown, commit, or repository push is claimed.
