# Contributing

Contributions are welcome. The most valuable ones are **findings** — a hard case from
[`docs/design.md`](docs/design.md) section 9 that behaved differently from the prediction is
worth more to this lab than a new feature.

---

## 1. Read the contract first

[`docs/design.md`](docs/design.md) is authoritative. Object counts, table shapes, naming,
the list of hard cases and the tooling facts all live there. If your change disagrees with it,
**change that document in the same pull request and say why** — do not quietly diverge.

Two rules that are never negotiable:

- **No secrets, ever.** This is a public repository. No real tenant IDs, subscription IDs,
  endpoints, resource names or passwords in any committed file. Every variable belongs in
  [`.env.example`](.env.example) with a placeholder. `.env` is gitignored and stays that way.
- **The generators stay deterministic and standard-library only.** See
  [`tools/requirements.txt`](tools/requirements.txt) for the reasoning. Cross-run diffs of the
  conversion report are the entire point of the lab; a dependency that changes its float
  formatting between releases breaks that silently.

---

## 2. Running the tests

Everything runs through one script: [`tests/run-tests.sh`](tests/run-tests.sh).

### Static checks — no database, no Azure, no secrets

```bash
tests/run-tests.sh
```

This is what CI runs on every push. It needs nothing but the repo and a few CLI tools, and it
takes about a minute. Any tool that is missing is reported as `SKIP` rather than failing, so
the command is always safe to type.

### Against Oracle

```bash
# Oracle in Docker (see docs/02-seed-oracle.md for getting one running)
tests/run-tests.sh --local --scale 0.01

# The Oracle VM in Azure, over an az network bastion tunnel
tests/run-tests.sh --azure --scale 1
```

`--local` and `--azure` mean exactly what they mean in
[`scripts/seed-oracle.sh`](scripts/seed-oracle.sh), and the connection is established the same
way — SQL\*Plus with `/nolog` and the `CONNECT` fed on stdin, so no password ever reaches a
command line.

Pass the same `--scale` you seeded with. The row-count minimums scale with it.

### Useful flags

| Flag | Effect |
| --- | --- |
| `--list` | Show the checks that would run, then exit. |
| `--only <glob>` | Run a subset: `--only bicep`, `--only 'verify-*'`, `--only '*lint*'`. |
| `--strict` | Treat `SKIP` as a failure. CI uses this — every tool is installed there on purpose, so a silent skip would be a lie. |
| `--scale <n>` | Row-count multiplier. `0.01` is the CI smoke scale, `1` is the full lab. |
| `VERBOSE=1` | Environment variable. Show every check's full output. |
| `NO_COLOR=1` | Environment variable. Disable colour. |

Exit status is `0` if everything passed, `1` if a check failed, `2` if the harness could not
run at all. Per-check logs land in `out/logs/tests-<timestamp>/`, which is gitignored.

### What each check does

| Check | Needs | What it proves |
| --- | --- | --- |
| `bash-syntax` | bash | Every `*.sh` parses (`bash -n`). |
| `shellcheck` | shellcheck | Every `*.sh` is clean at `severity=warning`; `--strict` raises that to `style`. |
| `exec-bits` | — | Every `*.sh` has its executable bit, as design.md section 2 requires. |
| `bicep-build` | az + bicep | Every `*.bicep` and `*.bicepparam` compiles. |
| `python-compile` | python3 | Every `*.py` compiles. |
| `generator-determinism` | python3 | The generator produces byte-identical output across two runs with **different** `PYTHONHASHSEED` values. |
| `markdown-links` | python3 | Every *relative* link in every `*.md` resolves to a file that exists. External URLs are never fetched — a test that needs the internet is a test that fails on a train. |
| `secret-scan` | — | No GUID that is not the all-zero placeholder, and no `.env` tracked by git. |
| `verify-schema` | `--local`/`--azure` | [`tests/verify-schema.sql`](tests/verify-schema.sql) — object budget, zero invalid objects, foreign keys validated, hard-case constructs present. |
| `verify-counts` | `--local`/`--azure` | [`tests/verify-counts.sql`](tests/verify-counts.sql) — row counts per scale, referential integrity, hierarchy sanity. |

### Running the SQL by hand

Both SQL files are read-only and standalone. Connected as `CONTOSO`:

```sql
SQL> @tests/verify-schema.sql
SQL> DEFINE scale = 0.01
SQL> @tests/verify-counts.sql
```

Each prints one `PASS` or `FAIL` line per assertion and calls `RAISE_APPLICATION_ERROR` at the
end if anything failed, so SQL\*Plus exits non-zero and any script can just test `$?`.
`verify-schema.sql` raises `ORA-20101`; `verify-counts.sql` raises `ORA-20102`.

`verify-counts.sql` needs `&scale` to be defined. Both `run-tests.sh` and `seed-oracle.sh` set
it in their SQL\*Plus preamble; for a manual run, `DEFINE scale = 1` first or SQL\*Plus will
prompt.

---

## 3. Repository layout

```text
oracle-to-postgres-migration-lab/
├── README.md                  the tour
├── CONTRIBUTING.md            this file
├── LICENSE                    MIT
├── .env.example               every variable the lab uses, with placeholders
├── .github/workflows/         CI
│   ├── ci.yml                 static checks, every push and PR, no secrets
│   └── oracle-smoke.yml       the real integration test against Oracle Free
├── docs/
│   ├── design.md              THE CONTRACT — read this first
│   ├── architecture.md        why the lab is shaped the way it is
│   └── NN-*.md                the walkthrough, in order
├── infra/                     Bicep: VNet, Oracle VM, PostgreSQL flexible server,
│   └── modules/               Foundry, jumpbox, Bastion
├── scripts/                   bash drivers: preflight, deploy, seed, connect, status, destroy
├── src/oracle/                the hand-written CONTOSO schema, numbered 00 → 13,
│                              plus 99-verify-objects.sql (the object-count assertion)
├── tools/                     generate-objects.py, generate-data.py — stdlib only
├── tests/                     run-tests.sh, verify-schema.sql, verify-counts.sql
├── generated/                 gitignored — generator output, deployment outputs
│   └── oracle/                generated SQL, and data/ for the row generator
└── out/                       gitignored — logs, converted DDL, conversion reports
```

> **A note on `src/oracle/` versus `sql/`.** `docs/design.md` section 3 specifies `sql/`.
> The tree above records where the files actually are today. `scripts/seed-oracle.sh` and the
> test harness accept **either** location, so both work; if you move them, move them wholesale
> and update design.md in the same pull request.

---

## 4. File ownership

This repository is built by several contributors working in parallel on separate areas. To keep
merges clean, **stay inside the area you are changing**, and raise anything cross-cutting in
`docs/design.md` first — that document is the interface between areas.

| Area | Owns | Depends on |
| --- | --- | --- |
| **Contract** | `docs/design.md` | nothing — it is the root |
| **Schema** | `src/oracle/*.sql` | the contract's sections 4–6 |
| **Generators** | `tools/*.py`, `tools/requirements.txt` | the schema's table names; the contract's sections 7–8 |
| **Infrastructure** | `infra/**`, `scripts/*.sh`, `scripts/cloud-init/` | `.env.example` variable names |
| **Documentation** | `README.md`, `docs/*.md` except `design.md` | everything else |
| **Tests and CI** | `tests/**`, `.github/workflows/**`, `CONTRIBUTING.md` | every area above |
| **Repo roots** | `.env.example`, `.gitignore`, `LICENSE` | the contract's section 2 |

The couplings that actually bite, and which the tests exist to catch:

- **Test thresholds follow the contract.** The per-object-type minimums in `verify-schema.sql`
  are transcribed from design.md section 8, and the row minimums in `verify-counts.sql` from
  `SEED_ORDER_ROWS` / `SEED_CUSTOMER_ROWS` in `.env.example`. Change either and the tests must
  change with them, in the same pull request.
- **The harness probes the generators rather than assuming their flags.** `run-tests.sh` and
  both workflows read `--help` and use only the options the generator advertises, so the
  generators can change their command line without breaking CI.
- **`gen_` is the one predicate that separates generated from hand-written.** Reports, tests
  and the object census all rely on it. Do not drop the infix.

---

## 5. Conventions

From `docs/design.md` section 2, repeated here because they are what review will ask about:

- **Shell:** `#!/usr/bin/env bash`, then `set -euo pipefail`, executable bit set, passes
  `bash -n`. macOS ships bash 3.2 — **no associative arrays**, no GNU-only flags without a
  fallback. The test harness uses parallel arrays for exactly this reason.
- **File names:** kebab-case. SQL files carry a two-digit ordinal and a dash: `04-indexes.sql`.
- **SQL identifiers:** lower-case and unquoted in source, so Oracle folds them up and
  PostgreSQL folds them down. Exactly one table — `"StoreAudit_Legacy"` — is deliberately
  quoted and mixed-case, to exercise trap T-07. Do not "fix" it.
- **Prefixes:** `pkg_`, `sp_`, `fn_`, `trg_`, `v_`, `mv_`, `syn_`, `seq_`, `t_`, `gtt_`,
  `ix_`/`uq_`/`fbi_`/`bmp_`, `pk_`/`fk_`/`ck_`. Generated objects carry a `gen_` infix.
- **Passwords:** environment variables or `az keyvault secret show`. Never a literal, never on
  a command line where `ps` can see it.

---

## 6. Continuous integration

### [`ci.yml`](.github/workflows/ci.yml) — every push and pull request

Static checks only. **No Azure credentials, no database, no secrets** — a fork can run it with
no configuration at all. It delegates to `tests/run-tests.sh --strict` so that what CI checks
and what you check locally cannot drift apart.

It also runs the generator determinism check as a separate job across Python 3.9 and 3.12,
which is the closest a single workflow gets to design.md's "two runs on two machines", and
publishes a SHA-256 of the whole generated corpus to the job summary as a drift alarm.

### [`oracle-smoke.yml`](.github/workflows/oracle-smoke.yml) — the real integration test

Stands up `gvenzl/oracle-free:23-slim` as a service container, generates the bulk objects,
loads the whole schema at `--scale 0.01`, and runs both SQL test files against it.

- **It needs no secrets.** The Oracle password is a throwaway for a container that lives for
  one job and is reachable only from that runner. Override it with an `ORACLE_CI_PASSWORD`
  repository variable if you want to; nothing breaks if you do not.
- **It waits on the container's healthcheck, never on a fixed sleep.** Oracle takes minutes to
  open the PDB on a GitHub runner, and a fixed sleep is how this kind of test becomes flaky.
  The job then proves an actual `CONNECT` succeeds before it starts loading.
- It runs on pushes to `main`, on pull requests that touch the schema, generators, tests or the
  seed script, nightly at 04:17 UTC, and on manual dispatch.
- **Version honesty:** design.md section 11.5 lists 12.1, 12.2, 18c, 19c and 21c as documented
  conversion sources. 23ai is not among them, and this workflow uses it anyway because it is
  the only Oracle that starts in minutes in a container. It proves the schema is valid Oracle;
  it does not prove the conversion tool supports the version.

### Expect some red while the lab is being built

The checks are honest, which means they go red on real gaps before the area that owns them has
landed. `markdown-links` will flag links to walkthrough documents that have not been written
yet; `verify-schema` will report every object type as `SHORT` until the schema and generator
are both complete. That is the intended behaviour — these are not warnings to be suppressed.
Fix the gap, not the test.

---

## 7. Adding a test

- **A new static check** goes in `tests/run-tests.sh` as another `if selected <name>; then`
  block that ends in one `record <name> PASS|FAIL|SKIP "<detail>" "<ms>"` call, plus the name
  in the `CHECKS` array. Nothing else needs editing; CI picks it up automatically because it
  calls the harness rather than listing checks itself.
- **A new Oracle assertion** goes in `verify-schema.sql` (structure) or `verify-counts.sql`
  (data), as one more `assert(...)` call. Use `warn(...)` when a check *could not run* — a
  missing privilege on a dictionary view must never masquerade as a pass.
- **Query dictionary views directly, but reach application tables through `probe()` or
  `row_count()`.** PL/SQL resolves static SQL at compile time, so a single not-yet-created
  table in a static query stops the whole block from compiling and you get no report at all
  instead of a report naming the missing table.
- Keep both SQL files **read-only**. They create nothing and change nothing, so they are safe
  to run against a populated lab.

---

## 8. When the harness itself misbehaves

| Symptom | Cause |
| --- | --- |
| `shellcheck` fails on a comment | A comment whose first word is `shellcheck` is parsed as a directive. Reword it. |
| `bicep-build` reports `SKIP` | `az bicep install`. |
| `bicep-build` fails on a `.bicepparam` | `build-params` evaluates `readEnvironmentVariable()`. A required variable is unset — the same error you would get at deploy time. |
| `generator-determinism` reports `SKIP` | The generator exposes no `--help` or no `--out` flag yet. |
| `verify-counts` prompts for a value and hangs | `&scale` is not defined. `DEFINE scale = 1` first. |
| Every Oracle assertion says `query failed` | You are connected to the wrong schema, or the schema is not loaded. Check `CONTOSO_SCHEMA` in `.env`. |

---

## 9. Pull requests

- One area per pull request where you can manage it.
- Run `tests/run-tests.sh` before pushing. Run it with `--local` too if you touched the schema,
  the seed layer or the generators.
- If you changed a prediction in design.md section 9 because a run disproved it, say so in the
  description. Being wrong in public, on the record, is the point of this lab.
