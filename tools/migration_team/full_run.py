#!/usr/bin/env python3
"""Executable controller for the WHOLE remaining Oracle->PostgreSQL migration.

Run as a module:  PYTHONPATH=tools python -m migration_team.full_run <subcommand> [opts]
or directly:      python tools/migration_team/full_run.py <subcommand> [opts]

What it is
----------
A deterministic *host* controller that plans and (when authorized) drives the real GitHub
Copilot migration team across the entire remaining queue as one exhaustive run -- not a
sampled cohort. It:
  * builds an exhaustive manifest/ledger accounting for every source work unit, base-table
    load unit and hard case, with per-object historical + baseline-support mapping;
  * computes dependency-ordered batches (topological; <= max_dependency_batch);
  * spawns bounded, real Copilot lanes (coordinator delegates o2p-repair then an independent
    o2p-reviewer) under a TIGHT permission profile -- the only shell command a lane may run is
    the migration-team CLI, exposed via a wrapper stem (`mt`); scoped SQL-file writes only;
    native `task`; NO general python3:*, NO allow-all, NO global settings changes;
  * writes explicit append-only state/resume receipts and reconstructs progress from the
    public CLI queue -- it never hand-edits SQLite;
  * before any paid batch, runs a runtime permission probe proving an allowed CLI command
    works while an unrelated `python3 -c` is denied.

What it is NOT
--------------
It does not edit tools/migration_team/cli.py, does not mutate the Oracle source or existing
target data, does not compute a success percentage, and does not credit prior scoped cohorts
(they are provenance; fresh independent evidence is required for every task).

Safety: dry-run by default. `run` refuses to launch any Copilot session unless ALL hold:
--authorize, controller/AUTHORIZED_TO_RUN exists, a --target-profile is supplied, and input
immutability verification passes.
"""
from __future__ import annotations
import argparse, datetime, hashlib, json, os, shutil, subprocess, sys, uuid
from collections import Counter, defaultdict, deque
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MT_CLI = [sys.executable, str(REPO / "tools" / "migration-team.py")]
DEFAULT_PLAN = REPO / "out" / "full-migration-plan-20260910-aotOfC"
DEFAULT_CONTROLLER = REPO / "out" / "full-migration-e2e-20260910-sQkuC0" / "controller"
HISTORICAL_MAPPING = REPO / "docs" / "conversion-report" / "object_mapping_summary.csv"

MAX_ACTIVE_LANES = 2            # queue-enforced ceiling; contract policy
MAX_VALIDATE_ATTEMPTS = 3      # contract policy
BUDGET_POLICY = "lifetime-three-no-reset-v1"   # main-owned public budget/lifetime contract name

# Parent-owned quarantine: support-helper lineages DENIED regardless of any locally-clean budget,
# until main clears them. scalar_ingress_v2 descends from scalar_ingress (a6 -> v2), so a locally
# clean v2 budget is NOT clearance -- the whole lineage is held. The public `audit` scope is
# "local queue history only", so this cross-queue, parent-owned hold lives here and fails closed.
QUARANTINED_LINEAGE = {
    "a6a87394cd803e9d186c": "CONTOSO.scalar_ingress (char_byte_normalize/date_canonical) -- unauthorized budget reset",
    "751448ea21165e786b0f": "CONTOSO.scalar_ingress_v2 (a6 lineage; adds date_from_source_text)",
}


# ---------- small io helpers ----------
def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def _load(p: Path):
    with open(p) as fh:
        return json.load(fh)

def _sha256(p: Path):
    try:
        return hashlib.sha256(p.read_bytes()).hexdigest()
    except OSError:
        return None

def _task_id(source_type: str, source_name: str) -> str:
    """Deterministic queue task id. MUST match tools/migration_team/queue.py (pinned by test):
    sha256(json.dumps([type, name]))[:20]. This is the reconciliation key across queues."""
    return hashlib.sha256(json.dumps([source_type, source_name]).encode()).hexdigest()[:20]

def _parse_source_key(sk: str):
    """'TYPE|CONTOSO.NAME' -> ('TYPE', 'CONTOSO.NAME')."""
    t, _, n = sk.partition("|")
    return t, n

def _write_json(p: Path, obj):
    """Durable, symlink-refusing JSON write for controller state/provenance files (mirrors the
    contract of migration_team.queue.write_json): refuse a symlink target/temp, write a sibling
    temp then atomically os.replace it into place -- so a mid-write crash can never leave a truncated
    controller-manifest/coverage/receipt file, and a planted symlink can't redirect the write out of
    the controller dir. Inlined (not imported) so it holds under direct-script and module execution."""
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.is_symlink():
        raise ValueError("refusing a symlink output: %s" % p)
    tmp = p.with_suffix(p.suffix + ".tmp")
    if tmp.is_symlink():
        raise ValueError("refusing a symlink temp: %s" % tmp)
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")
    tmp.replace(p)

def _receipt(controller: Path, kind: str, **fields):
    """Append-only, tamper-evident-ish state receipt. Never edits the queue SQLite."""
    rec = {"receipt_id": uuid.uuid4().hex[:16], "ts": _now(), "kind": kind, **fields}
    rp = controller / "receipts" / "receipts.jsonl"
    rp.parent.mkdir(parents=True, exist_ok=True)
    with open(rp, "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    return rec


# ---------- plan loading ----------
def load_plan(plan_root: Path) -> dict:
    art = {}
    for name in ("summary", "work-units", "load-units", "families", "execution-phases",
                 "reviewed-scope-overlay", "data-validation-companions", "type-dependencies"):
        p = plan_root / f"{name}.json"
        art[name] = _load(p) if p.exists() else None
    return art


# ---------- manifest / exhaustive ledger ----------
def build_manifest(plan_root: Path, controller: Path) -> dict:
    art = load_plan(plan_root)
    units = art["work-units"]
    loads = art["load-units"]
    summary = art["summary"]
    overlay = art["reviewed-scope-overlay"] or []
    prior_reviewed_tasks = {o["task_id"] for o in overlay}

    uindex = {u["unit_id"]: u for u in units}
    hard_cover = defaultdict(list)
    kinds, fams = Counter(), Counter()
    with_cand = 0
    records = []
    # Preserve ingested run state across rebuilds -- a `manifest` refresh must never wipe
    # reviewed/evidence/supersession progress recorded by ingestion.
    _prior = {}
    _mp = controller / "controller-manifest.json"
    if _mp.exists():
        try:
            _prior = _load(_mp)
        except Exception:  # noqa: BLE001
            _prior = {}
    prior_state = {pu["unit_id"]: pu for pu in _prior.get("units", [])}
    prior_load = {lu["unit_id"]: lu for lu in _prior.get("load_units", [])}
    for u in units:
        cand = list(u.get("candidate_ids") or [])
        if cand:
            with_cand += 1
        for hc in (u.get("hard_cases") or []):
            hard_cover[hc].append(u["unit_id"])
        kinds[u["kind"]] += 1
        fams[u.get("family")] += 1
        prior = sorted(set(u.get("reviewed_scope_task_ids") or []) & prior_reviewed_tasks)
        task_ids = [_task_id(*_parse_source_key(sk)) for sk in u.get("source_keys", []) if "|" in sk]
        ps = prior_state.get(u["unit_id"], {})
        records.append({
            "unit_id": u["unit_id"],
            "kind": u["kind"],
            "family": u.get("family"),
            "source_keys": u.get("source_keys", []),
            "task_ids": task_ids,                      # deterministic queue ids (reconciliation key)
            # per-object historical + baseline-support mapping:
            "historical_task_ids": u.get("historical_task_ids", []),
            "reviewed_scope_task_ids": u.get("reviewed_scope_task_ids", []),
            "candidate_ids": cand,
            "has_baseline_candidate": bool(cand),
            "depends_on": u.get("depends_on", []),
            "external_dependencies": u.get("external_dependencies", []),
            "hard_cases": u.get("hard_cases", []),
            "prior_reviewed_overlap": prior,
            "fresh_evidence_required": True,          # never auto-credit prior cohorts
            "planning_status": u.get("planning_status"),
            # preserved across rebuilds:
            "controller_state": ps.get("controller_state", "unstarted"),
            "reviewed_task_ids": ps.get("reviewed_task_ids", []),
            "evidence": ps.get("evidence", []),
            "run_state_history": ps.get("run_state_history", []),
            "supersessions": ps.get("supersessions", []),
        })

    # Hard-case coverage across BOTH work units and load units (all 43 must appear).
    for lu in loads:
        for hc in (lu.get("hard_cases") or []):
            hard_cover[hc].append(lu["unit_id"])

    hard_total = summary.get("hard_case_count", 43)
    coverage = {
        "generated_at": _now(),
        "plan_root": str(plan_root),
        "controller_root": str(controller),
        "work_units_total": len(units),
        "work_units_planned_equal": len(units) == summary.get("source_work_units"),
        "load_units_total": len(loads),
        "load_units_planned_equal": len(loads) == summary.get("base_table_load_units"),
        "historical_task_count": summary.get("historical_task_count"),
        "remaining_author_review_task_count": summary.get("remaining_author_review_task_count"),
        "remaining_not_converted": summary.get("remaining_not_converted_task_count"),
        "remaining_converted_action_required": summary.get("remaining_converted_action_required_task_count"),
        "distinct_prior_reviewed": summary.get("distinct_prior_reviewed_scope_count"),
        "prior_reviewed_task_ids": sorted(prior_reviewed_tasks),
        "units_with_baseline_candidate": with_cand,
        "units_without_baseline_candidate": len(units) - with_cand,
        "units_by_kind": dict(kinds),
        "families_total": len(art["families"] or {}),
        "hard_cases_total_declared": hard_total,
        "hard_cases_covered": sorted(hard_cover),
        "hard_cases_missing": sorted(set(f"H-{i:02d}" for i in range(1, hard_total + 1)) - set(hard_cover))
                              if hard_total else [],
        "exported_row_count": summary.get("exported_row_count"),
        "input_queue_snapshots_sha256": summary.get("input_queue_snapshots_sha256"),
        "policy": {
            "max_active_repair_lanes": MAX_ACTIVE_LANES,
            "max_validation_attempts_per_task": MAX_VALIDATE_ATTEMPTS,
            "no_stub_or_tautological_success": True,
            "genuine_source_required": True,
            "no_blanket_python_or_docker_permissions": True,
            "prior_cohorts_are_provenance_not_credit": True,
        },
    }
    coverage["fully_accounted"] = (
        coverage["work_units_planned_equal"]
        and coverage["load_units_planned_equal"]
        and not coverage["hard_cases_missing"]
    )
    _write_json(controller / "controller-manifest.json",
                {"coverage": coverage, "units": records,
                 "load_units": [{
                     "unit_id": lu["unit_id"], "source_table": lu.get("source_table"),
                     "rows": lu.get("rows"), "required_checks": lu.get("required_checks", []),
                     "hard_cases": lu.get("hard_cases", []), "depends_on": lu.get("depends_on", []),
                     "controller_state": prior_load.get(lu["unit_id"], {}).get("controller_state", "unstarted"),
                     "evidence": prior_load.get(lu["unit_id"], {}).get("evidence", []),
                 } for lu in loads],
                 "hard_case_coverage": {k: v for k, v in sorted(hard_cover.items())}})
    _write_json(controller / "coverage.json", coverage)
    # reconciliation index: deterministic task_id -> unit_id, for peers seeding their own queues.
    recon = {}
    for r in records:
        for t in r["task_ids"]:
            recon[t] = r["unit_id"]
    _write_json(controller / "reconciliation-index.json",
                {"task_id_formula": "sha256(json.dumps([source_type, source_name]))[:20]",
                 "count": len(recon), "task_id_to_unit_id": recon})
    _receipt(controller, "manifest_built",
             work_units=len(units), load_units=len(loads),
             fully_accounted=coverage["fully_accounted"])
    return coverage


# ---------- dependency batches ----------
def topo_levels(units: list) -> list:
    """Kahn levelization over intra-set unit_id edges (external/gate deps are advisory)."""
    ids = {u["unit_id"] for u in units}
    deps = {u["unit_id"]: {d for d in (u.get("depends_on") or []) if d in ids} for u in units}
    indeg = {n: len(d) for n, d in deps.items()}
    dependents = defaultdict(list)
    for n, ds in deps.items():
        for d in ds:
            dependents[d].append(n)
    ready = deque(sorted(n for n, k in indeg.items() if k == 0))
    levels, placed = [], 0
    while ready:
        level = list(ready)
        ready.clear()
        levels.append(level)
        placed += len(level)
        nxt = []
        for n in level:
            for m in dependents[n]:
                indeg[m] -= 1
                if indeg[m] == 0:
                    nxt.append(m)
        ready.extend(sorted(nxt))
    if placed != len(ids):
        raise RuntimeError(f"dependency cycle: placed {placed} of {len(ids)} units")
    return levels

def build_batches(plan_root: Path, controller: Path) -> dict:
    art = load_plan(plan_root)
    units = art["work-units"]
    max_batch = (art["summary"] or {}).get("max_dependency_batch", 5)
    fam = {u["unit_id"]: u.get("family") for u in units}
    levels = topo_levels(units)
    batches, bidx = [], 0
    for lvl, members in enumerate(levels):
        # keep same-family units adjacent, then chunk to <= max_batch
        members = sorted(members, key=lambda uid: (str(fam.get(uid)), uid))
        for i in range(0, len(members), max_batch):
            chunk = members[i:i + max_batch]
            batches.append({"batch_id": f"B{bidx:04d}", "level": lvl,
                            "unit_ids": chunk, "size": len(chunk)})
            bidx += 1
    out = {"generated_at": _now(), "max_dependency_batch": max_batch,
           "levels": len(levels), "batch_count": len(batches),
           "runtime_concurrency": {"max_active_repair_lanes": MAX_ACTIVE_LANES},
           "batches": batches}
    _write_json(controller / "batches.json", out)
    _receipt(controller, "batches_built", levels=len(levels), batches=len(batches),
             max_dependency_batch=max_batch)
    return out


# ---------- tight Copilot permission profile ----------
def lane_profile(lane: str) -> list:
    """Tight per-lane Copilot flags. `mt` is the migration-team CLI wrapper stem."""
    common = ["--no-ask-user", "--disable-builtin-mcps", "--no-remote-export", "--no-color"]
    if lane == "coordinator":
        return ["--available-tools", "bash", "view", "glob", "task",
                "--allow-tool", "shell(mt:*)", "--allow-tool", "task"] + common
    if lane == "o2p-repair":
        return ["--available-tools", "bash", "view", "glob", "apply_patch",
                "--allow-tool", "shell(mt:*)",
                "--allow-tool", "write(candidate.sql)", "--allow-tool", "write(checks.sql)",
                "--allow-tool", "write(target-ddl.sql)", "--allow-tool", "write(notes.md)"] + common
    # reviewer / data / hard-cases: read + CLI only
    return ["--available-tools", "bash", "view", "glob", "--allow-tool", "shell(mt:*)"] + common

def ensure_wrapper(controller: Path) -> Path:
    binp = controller / "bin"
    binp.mkdir(parents=True, exist_ok=True)
    mt = binp / "mt"
    mt.write_text('#!/bin/sh\n# migration-team CLI wrapper (fixed target); no arbitrary python.\n'
                  f'exec {sys.executable} "{REPO}/tools/migration-team.py" "$@"\n')
    mt.chmod(0o755)
    return mt


# ---------- input immutability verification ----------
def verify_inputs(plan_root: Path, controller: Path) -> dict:
    """Immutability gate. Prior-queue immutability is verified LOGICALLY via the public CLI --
    SQLite file bytes churn on mere reads (WAL/mmap) and are NOT a reliable signal. Genuine
    source artifacts are verified by content hash (byte-stable)."""
    summary = _load(plan_root / "summary.json")
    # 1. Prior-queue logical immutability (states must match the plan snapshot).
    q_expected = {
        "original": (REPO / "out/e2e-20260910-c74z2rie/team-historical-unresolved",
                     summary.get("original_queue_states")),
        "cohort": (REPO / "out/not-converted-team-e2e-20260910-KhxxaA/nc-queue",
                   summary.get("separate_cohort_queue_states")),
    }
    q_checks, states_ok = [], True
    for label, (qpath, expected) in q_expected.items():
        try:
            got = json.loads(subprocess.check_output(MT_CLI + ["report", "--state", str(qpath)]))["states"]
        except Exception as e:  # noqa: BLE001 - report the failure as evidence
            got = {"error": str(e)}
        match = (got == expected)
        states_ok = states_ok and match
        q_checks.append({"label": label, "queue": str(qpath),
                         "expected_states": expected, "observed_states": got, "match": match})
    # 2. Source-artifact byte immutability from the plan's input-hashes ledger. A PINNED (non-null)
    # expected hash whose artifact is MISSING is a hard immutability failure -- fail closed BEFORE any
    # model launch, never fall open. An explicitly-null expected hash is a declared-optional artifact
    # (valid contract) and does not fail the gate.
    ih = _load(plan_root / "input-hashes.json")
    ok = bad = missing = optional_absent = 0
    changed, missing_pinned = [], []
    for p, h in ih.items():
        if h is None:                 # explicitly-optional artifact (declared absent) -- not required
            optional_absent += 1
            continue
        got = _sha256(Path(p))
        if got is None:               # pinned expected hash, artifact absent -> hard fail (fail closed)
            missing += 1
            missing_pinned.append(p)
        elif got == h:
            ok += 1
        else:
            bad += 1
            changed.append(p)
    all_match = states_ok and bad == 0 and missing == 0
    res = {
        "verified_at": _now(),
        "all_match": all_match,
        "prior_queue_logical_immutability": {"states_ok": states_ok, "checks": q_checks},
        "source_artifact_immutability": {"total": len(ih), "ok": ok, "changed": bad,
                                          "missing_pinned": missing, "optional_absent": optional_absent,
                                          "changed_sample": changed[:10],
                                          "missing_pinned_sample": missing_pinned[:10]},
        "note": "Prior queues verified logically (SQLite bytes are not a reliable signal). Genuine source "
                "artifacts verified by content hash; a MISSING pinned artifact fails closed (an explicit "
                "null expected hash is a declared-optional artifact and is allowed).",
        "plan_recorded_queue_snapshot_sha256_informational": summary.get("input_queue_snapshots_sha256"),
    }
    _write_json(controller / "input-verification.json", res)
    _receipt(controller, "inputs_verified", all_match=all_match, states_ok=states_ok,
             source_changed=bad, source_missing_pinned=missing, optional_absent=optional_absent)
    return res


# ---------- permission probe (real Copilot, gated) ----------
def build_probe_argv(controller: Path, queue_state: str, session_id: str) -> list:
    return (["copilot", "-C", str(REPO), "--agent", "o2p-coordinator"]
            + lane_profile("coordinator")
            + ["--max-ai-credits", "30", "--log-dir", str(controller / "copilot-logs"),
               "--session-id", session_id,
               "-p", ("Permission probe. Run EXACTLY two shell commands and report each outcome, "
                      f"then stop: (1) mt report --state {queue_state}   "
                      '(2) python3 -c "print(42)"')])


# ---------- fail-closed lifetime-budget + lineage clearance (main-owned public audit) ----------
def _is_quarantined_lineage(task_id: str, unit_id: str) -> bool:
    """Parent-owned cross-queue deny. True if the task_id is a known quarantined root, or the unit is
    a scalar-ingress/schema-adapter helper by name. A locally-clean budget never overrides this."""
    if task_id in QUARANTINED_LINEAGE:
        return True
    uid = (unit_id or "").lower()
    return any(tok in uid for tok in ("scalar_ingress", "scalar_adapter", "schema_adapter"))


def _budget_ok(vb: dict) -> bool:
    """Lifetime-budget clearance predicate over a validation_budget dict. BOTH `mt show` (queue.py:270)
    and `mt audit` (queue.py:258) embed this SAME computed budget, so the predicate is identical
    whichever command carried it. Fail-closed: an absent/None review_eligible or within_limit, or a
    truthy quarantined, is NOT clearance."""
    return (vb.get("review_eligible") is True
            and vb.get("within_limit") is True
            and vb.get("quarantined") is not True)


def _budget_cleared(queue: str, task_id: str, shown: dict = None):
    """Fail-closed lifetime-budget clearance. Returns (ok, snapshot).

    When `shown` (a FRESH `mt show` result that already embeds validation_budget) is provided, reuse
    ITS budget instead of spawning a redundant second `mt audit` subprocess: the show read is the
    same-instant source of both status and budget, and show/audit compute the IDENTICAL
    validation_budget (queue.py:270/258). Otherwise fall back to the standalone `mt audit` subprocess
    (the main-owned public audit) -- used by callers that have no preceding show.

    ok REQUIRES review_eligible IS True, within_limit IS True, quarantined is NOT True (and, on the
    audit path, audit exit 0). An ABSENT validation_budget or a non-True review_eligible FAILS CLOSED
    -- never assume absent == eligible. Scope is local-queue only (per the audit's own `scope`);
    cross-queue lineage is the caller's job. The snapshot carries budget_source ('show'|'audit') so a
    SourceBudgetAudit receipt records how clearance was established."""
    snap = {"task_id": task_id, "queue": queue, "policy_expected": BUDGET_POLICY}
    if shown is not None:
        vb = (shown or {}).get("validation_budget") or {}
        ok = _budget_ok(vb)
        snap.update(validation_budget=vb, budget_source="show", budget_cleared=ok)
        return ok, snap
    try:
        proc = subprocess.run(MT_CLI + ["audit", "--state", queue, "--id", task_id],
                              capture_output=True, text=True)
    except Exception as e:  # noqa: BLE001
        snap.update(error=str(e), budget_source="audit", budget_cleared=False)
        return False, snap
    snap["audit_exit"] = proc.returncode
    try:
        audit = json.loads(proc.stdout)
    except Exception:
        audit = {"parse_error": (proc.stdout or "")[:400], "stderr": (proc.stderr or "")[:400]}
    vb = (audit or {}).get("validation_budget") or {}
    ok = (proc.returncode == 0 and _budget_ok(vb))
    snap.update(validation_budget=vb, budget_source="audit", budget_cleared=ok)
    return ok, snap


def _load_grants(controller: Path) -> dict:
    """Recorded parent-owned budget grants (main-approvals/*-grant.json), keyed by approval_id.
    Operator-written, one-shot, outside the mt agent surface. A granted lineage is creditable ONLY
    against one of these, never a bare active_authorization the queue happens to echo."""
    grants = {}
    gdir = controller.parent / "main-approvals"
    if gdir.is_dir():
        for p in sorted(gdir.glob("*-grant.json")):
            try:
                g = json.loads(p.read_text())
            except Exception:  # noqa: BLE001
                continue
            gr = g.get("grant") or {}
            appr = gr.get("approval_id")
            if appr:
                grants[appr] = {"file": p.name, "task_id": g.get("task_id"),
                                "approval_sha256": gr.get("approval_sha256")}
    return grants


def _authorization_ok(controller: Path, task_id: str, budget: dict, evidence: dict):
    """Grant clearance. Ordinary units (no active_authorization in their budget) pass through.
    A unit whose budget carries an active_authorization is creditable ONLY if that authorization is a
    RECORDED main-approvals grant FOR THIS task_id (approval_id + sha match) AND the evidence carries
    the matching validation_authorization_id -- i.e. the passing validation happened UNDER the grant.
    A linked prior attempt (e.g. scalar_ingress_v2) never carries its OWN grant, so it never clears."""
    aa = (budget or {}).get("active_authorization") or {}
    if not aa:
        return True, "no active_authorization"
    appr = aa.get("approval_id")
    g = _load_grants(controller).get(appr)
    if not g:
        return False, f"active_authorization {appr} not a recorded main-approvals grant"
    if g.get("task_id") != task_id:
        return False, f"grant {appr} authorizes task {g.get('task_id')}, not {task_id}"
    if g.get("approval_sha256") != aa.get("approval_sha256"):
        return False, "grant approval_sha256 mismatch"
    ev_auth = (evidence or {}).get("validation_authorization_id")
    if ev_auth != appr:
        return False, f"evidence.validation_authorization_id {ev_auth} != grant {appr}"
    return True, "grant matches"


def _evidence_fresh(shown: dict):
    """Freshness gate against post-review input drift. A review is creditable ONLY if the CURRENT staged
    inputs (candidate/checks/dependencies SQL + the :config schema/engine digest) still match the hashes
    the evidence was validated against. `mt show` carries the evidence's recorded input_sha256 AND the
    queue's current_input_sha256 (a show-only field); public Queue.configure (or any post-review drift)
    changes the latter while LEAVING the 'reviewed' label, and review() only checks freshness at accept
    time -- so every credit/reverify path must re-check here. Fail-closed: fresh REQUIRES both hashes
    present and EQUAL; a missing current_input_sha256 (older CLI that cannot prove freshness) or a
    mismatch is NOT fresh. Returns (fresh_bool, reason)."""
    ev = (shown.get("evidence") or {}).get("input_sha256")
    cur = shown.get("current_input_sha256")
    if ev is None:
        return False, "no evidence input_sha256 to compare"
    if cur is None:
        return False, "mt show did not expose current_input_sha256 (cannot verify freshness)"
    if cur != ev:
        return False, "staged inputs drifted since validation (stale review; likely reconfigure/re-stage)"
    return True, "current inputs match the validation receipt"


# ---------- ingest peer reviewed evidence (CLI-re-verified; never blind trust) ----------
def ingest_evidence(controller: Path, evidence_path: Path) -> dict:
    """Fold a peer's reviewed evidence into the controller ledger. Each record is INDEPENDENTLY
    re-verified through the public CLI (`show`): the unit is credited only if the task is
    `reviewed`, reviewer != worker, and validation status is `passed`. This is fresh evidence
    from the authorized full run -- not a prior cohort -- so crediting it is honest, not a lift.

    Evidence record schema (list of):
      {"task_id": <20hex>, "queue": <state dir>, "reviewer": str, "worker": str,
       "validation_json": path, "source_key"/"unit_id": optional fallbacks}
    """
    manp = controller / "controller-manifest.json"
    man = _load(manp)
    units = man["units"]
    by_task, by_sk, by_uid = {}, {}, {}
    for u in units:
        for t in u.get("task_ids", []):
            by_task[t] = u
        for sk in u.get("source_keys", []):
            by_sk[sk] = u
        by_uid[u["unit_id"]] = u

    results = []
    for rec in _load(evidence_path):
        tid = rec.get("task_id")
        unit = by_task.get(tid) or by_sk.get(rec.get("source_key")) or by_uid.get(rec.get("unit_id"))
        if unit is None:
            results.append({"key": tid or rec.get("unit_id"), "status": "unmatched"})
            continue
        q = rec.get("queue")
        verified, detail, shown, budget_snap = False, "no queue+task_id to re-verify", {}, {}
        lineage_hold = _is_quarantined_lineage(tid, unit["unit_id"])
        if q and tid:
            try:
                shown = json.loads(subprocess.check_output(MT_CLI + ["show", "--state", q, "--id", tid]))
                review_ok = (shown.get("status") == "reviewed" and shown.get("reviewer")
                             and shown.get("worker") and shown["reviewer"] != shown["worker"]
                             and (shown.get("evidence") or {}).get("status") == "passed")
                # reuse the fresh validation_budget `show` already returned -- no redundant `mt audit`.
                budget_ok, budget_snap = _budget_cleared(q, tid, shown=shown)
                vb = shown.get("validation_budget", {}) or {}
                auth_ok, auth_reason = _authorization_ok(controller, tid, vb, shown.get("evidence") or {})
                # a quarantined lineage clears ONLY via a valid grant FOR THIS exact task (never an alias)
                lineage_ok = (not lineage_hold) or (bool(vb.get("active_authorization")) and auth_ok)
                # freshness: a post-review reconfigure/re-stage leaves the 'reviewed' label but drifts the
                # staged inputs; never credit a review whose inputs no longer match its validation receipt.
                fresh_ok, fresh_reason = _evidence_fresh(shown)
                verified = bool(review_ok) and budget_ok and auth_ok and lineage_ok and fresh_ok
                detail = (f"status={shown.get('status')} reviewer={shown.get('reviewer')} "
                          f"worker={shown.get('worker')} review_eligible={vb.get('review_eligible')} "
                          f"within_limit={vb.get('within_limit')} quarantined={vb.get('quarantined')} "
                          f"budget_source={budget_snap.get('budget_source')} lineage_hold={lineage_hold} "
                          f"auth_ok={auth_ok}({auth_reason}) fresh={fresh_ok}({fresh_reason})")
            except Exception as e:  # noqa: BLE001
                detail = f"cli-error {e}"
        elif lineage_hold:
            detail = "quarantined lineage hold (parent-owned deny); no queue+task_id to re-verify"
        # SourceBudgetAudit receipt (append-only provenance) for every task-bearing ingest attempt.
        if tid:
            _receipt(controller, "source_budget_audit", task_id=tid, unit=unit["unit_id"],
                     credited=bool(verified), lineage_hold=bool(lineage_hold),
                     validation_budget=budget_snap.get("validation_budget", {}),
                     budget_source=budget_snap.get("budget_source"),
                     audit_exit=budget_snap.get("audit_exit"))
        if verified:
            if tid not in unit["reviewed_task_ids"]:
                unit["reviewed_task_ids"].append(tid)
            unit["evidence"].append({"task_id": tid, "reviewer": shown.get("reviewer"),
                                     "worker": shown.get("worker"), "queue": q,
                                     "validation_json": rec.get("validation_json"),
                                     "verified_via_cli": True,
                                     "validation_budget": budget_snap.get("validation_budget", {})})
            complete = bool(unit["task_ids"]) and set(unit["reviewed_task_ids"]) >= set(unit["task_ids"])
            unit["controller_state"] = "reviewed" if complete else "partially_reviewed"
            results.append({"unit": unit["unit_id"], "task_id": tid, "status": unit["controller_state"]})
        else:
            results.append({"unit": unit["unit_id"], "task_id": tid,
                            "status": "not_credited", "detail": detail})
    _write_json(manp, man)
    credited = sum(1 for r in results if r["status"] in ("reviewed", "partially_reviewed"))
    out = {"ingested": len(results), "credited": credited, "results": results}
    _write_json(controller / "ingest-result.json", out)
    _receipt(controller, "evidence_ingested", records=len(results), credited=credited)
    return out


# ---------- ingest data-validation results (load units; authoritative reviewed_pass) ----------
def ingest_data(controller: Path, validation_out: Path) -> dict:
    """Fold full_validation results into the load-unit ledger. Contract (from full_validation):
    report["table_status"][<EXACT source table name>] = {status, reviewed_pass, empty,
      rows_source, rows_target, parity{...}|null, compare_json|null, blocked_reason}.
    Authoritative signal is reviewed_pass (True only for parity_pass or empty_verified). When a
    compare_json is present it is INDEPENDENTLY re-read and its public compare-data status must be
    `passed` to credit -- symmetric to how `mt show` re-verifies schema evidence. Never a false pass."""
    manp = controller / "controller-manifest.json"
    man = _load(manp)
    by_table = {lu["source_table"]: lu for lu in man.get("load_units", [])}
    report = _load(validation_out / "full-validation-report.json")
    tstat = report.get("table_status", {})
    results = []
    for tbl, st in tstat.items():
        lu = by_table.get(tbl)
        if lu is None:
            results.append({"table": tbl, "status": "unmatched"})
            continue
        reviewed_pass = bool(st.get("reviewed_pass"))
        status = st.get("status")
        is_empty = bool(st.get("empty")) or status == "empty_verified"
        # independent cross-check of the public compare-data output. A corrupt/unreadable receipt is
        # NOT a pass (never credit on a receipt we cannot read).
        xcheck = None
        cj = st.get("compare_json")
        if cj:
            cp = validation_out / cj
            if cp.exists():
                try:
                    xcheck = (_load(cp).get("status") == "passed")
                except Exception:  # noqa: BLE001 -- corrupt/invalid receipt is not a pass
                    xcheck = False
        # A NON-EMPTY parity_pass MUST carry a readable, explicitly-PASSED comparison receipt. A missing
        # or invalid compare_json -- e.g. an interrupted full_validation rerun that deleted the old
        # comparison before writing the new summary, leaving a genuine older passing summary + no receipt
        # -- WITHHOLDS credit (xcheck None/False are both non-credit here). empty_verified is intentionally
        # comparison-free, so an empty table needs no receipt.
        compare_ok = True if is_empty else (xcheck is True)
        credited = reviewed_pass and compare_ok
        if credited:
            state = "reviewed"
        elif reviewed_pass and not is_empty and not compare_ok:
            # the producer reported a nonempty pass but its comparison receipt is missing / unreadable /
            # not-passed -> withhold credit and flag for a FRESH comparison (never credit on a stale
            # summary alone). Distinct from 'incomplete' (= genuinely not yet run).
            state = "blocked"
        elif st.get("status") in ("parity_fail", "empty_mismatch", "schema_mismatch",
                                   "blocked_complex_target_render", "target_table_missing",
                                   "blocked_no_comparable_key", "empty_schema_unverified"):
            # fail-closed AND triage-distinct: a keyless non-empty table (no comparable key) and an
            # empty table whose full-scope schema gate needs --source-catalog/--adaptation are BLOCKED
            # (needs disposition/input), not left as 'incomplete' = not-yet-run. The specific status is
            # retained in the evidence.blocked_reason below.
            state = "blocked"
        else:
            state = "incomplete"
        lu["controller_state"] = state
        lu.setdefault("evidence", []).append({
            "status": st.get("status"), "reviewed_pass": reviewed_pass,
            "rows_source": st.get("rows_source"), "rows_target": st.get("rows_target"),
            "parity": st.get("parity"), "compare_json": cj, "empty": is_empty,
            "compare_status_reverified": xcheck, "compare_receipt_ok": compare_ok,
            "blocked_reason": st.get("blocked_reason")})
        results.append({"table": tbl, "load_unit": lu["unit_id"], "controller_state": state})
    covered = {r.get("table") for r in results}
    for tbl, lu in by_table.items():
        if tbl not in covered:
            results.append({"table": tbl, "load_unit": lu["unit_id"],
                            "controller_state": lu["controller_state"], "note": "absent_from_report"})
    _write_json(manp, man)
    reviewed = sum(1 for r in results if r.get("controller_state") == "reviewed")
    total = len(by_table)
    dv = (report.get("receipts", {}) or {}).get("data_validation", {}) or {}
    inv = report.get("inventory_summary", {}) or {}
    out = {"tables_in_report": len(tstat), "total_load_units": total,
           "load_units_reviewed": reviewed, "data_phase_complete": reviewed == total,
           "report_data_validation_status": dv.get("status"), "report_coverage": inv.get("coverage"),
           "coverage_note": ("Data phase completes only when ALL load-units are reviewed via per-table "
                             "reviewed_pass + compare cross-check -- never on a run exit code alone."),
           "results": results}
    _write_json(controller / "ingest-data-result.json", out)
    _receipt(controller, "data_ingested", tables=len(tstat), reviewed=reviewed,
             total=total, complete=reviewed == total)
    return out


# ---------- loader contract (pinned; exit-code + exit-3 sequence resume) ----------
LOADER_PATH = REPO / "tools" / "migration_team" / "data_loader.py"
LOADER_SHA256 = "26ad5280425ae7b466c6f93ecc61f12c656c0947426d691387cd842c08f35e13"
LOADER_EXIT = {0: "ok", 1: "blocked_or_refused", 2: "fatal_rolled_back_no_partial_data",
               3: "committed_retained_finalization_failed_resume", 4: "commit_ack_unknown"}

def verify_loader() -> dict:
    got = _sha256(LOADER_PATH)
    return {"loader": str(LOADER_PATH), "pinned_sha256": LOADER_SHA256,
            "actual_sha256": got, "match": got == LOADER_SHA256}

def _quote_ident(name: str) -> str:
    """PostgreSQL identifier quoting: wrap in double quotes, doubling any embedded quote (mirrors
    psycopg sql.Identifier). A '.' inside a quoted identifier is part of the NAME, never a schema
    separator -- so identifiers are quoted as separate parts, never built by splitting on '.'."""
    return '"' + str(name).replace('"', '""') + '"'

def _sql_literal(s: str) -> str:
    """A safe single-quoted SQL string literal, doubling embedded single-quotes. SQL-literal quoting
    is DISTINCT from identifier quoting: an apostrophe in a name must be doubled here, not backslashed
    or double-quoted."""
    return "'" + str(s).replace("'", "''") + "'"

def plan_sequence_resume(report: dict) -> list:
    """Exit-3 resume: re-run ONLY sequence finalization for receipts still error/pending.
    Data is durable and verified -- NEVER reload or truncate. The setval is NULL-safe: it only fires
    when max(col) IS NOT NULL, mirroring the loader's own 'skipped' rule so a pending receipt on a
    genuinely empty table is a no-op, not an error (per loader-loss-guard).

    Correctness against the ACTUAL loader receipt shape (data_loader._finalize_sequences /
    _plan_to_report): the receipt's `table` is a BARE plan.target_table (it may itself contain a '.'),
    and the table's schema lives ONLY in report['target_schema'] -- so the FROM is qualified as
    _quote_ident(target_schema).'.'._quote_ident(table), NEVER by splitting the table on '.'. The
    sequence is emitted as a FULLY-QUALIFIED, search_path-INDEPENDENT ::regclass built from the
    receipt's explicit sequence_schema + sequence_name and rendered as a SQL LITERAL (single-quote
    escaped, so an apostrophe in an identifier is safe) -- NOT from the receipt's search_path-dependent
    regclass text. Any receipt lacking unambiguous metadata (target_schema, bare table, column,
    sequence_schema, sequence_name) yields a catalog-re-derive DIRECTIVE -- never a guessed-schema,
    dot-split, apostrophe-broken, or None-identifier setval an operator would paste and run."""
    schema = report.get("target_schema")   # every loaded table (and its owned sequence) lives here
    out = []
    for r in report.get("sequences_reset", []):
        if r.get("status") not in ("error", "pending"):
            continue
        col, tbl = r.get("column"), r.get("table")
        seq_schema, seq_name = r.get("sequence_schema"), r.get("sequence_name")
        base = {"sequence": r.get("sequence"), "column": col, "table": tbl, "table_schema": schema,
                "sequence_schema": seq_schema, "sequence_name": seq_name, "null_safe": True}
        if schema and tbl and col and seq_schema and seq_name:
            seq_ref = _sql_literal(_quote_ident(seq_schema) + "." + _quote_ident(seq_name)) + "::regclass"
            from_ref = _quote_ident(schema) + "." + _quote_ident(tbl)
            out.append({**base, "action": "setval_owned_sequence_to_source_max",
                        "setval_sql": (f"SELECT setval({seq_ref}, m, true) "
                                       f"FROM (SELECT max({_quote_ident(col)}) AS m "
                                       f"FROM {from_ref}) s WHERE m IS NOT NULL;")})
        else:
            # Insufficient/ambiguous metadata (e.g. a post-commit sequence DISCOVERY-error table-level
            # receipt, or a legacy receipt without an explicit sequence namespace). Emit a catalog-
            # re-derive DIRECTIVE, never a setval that could target the wrong schema/table or break.
            out.append({**base, "action": "catalog_rederive_owned_sequences",
                        "reason": "insufficient unambiguous metadata (need target_schema + bare table + "
                                  "column + sequence_schema + sequence_name) for a search_path-independent "
                                  "setval; no valid SQL emitted",
                        "resume_directive": (
                            "re-derive OWNED sequences for this table from pg_catalog (schema+name, NOT a "
                            "search_path-dependent regclass text) and setval each NULL-safe: SELECT "
                            "setval(seq, m, true) FROM (SELECT max(col) AS m FROM tbl) s WHERE m IS NOT "
                            "NULL; never reload/truncate")})
    return out

def interpret_loader_exit(rc: int, report: dict) -> dict:
    res = {"exit_code": rc, "meaning": LOADER_EXIT.get(rc, f"unknown_exit_{rc}"),
           "applied": report.get("applied"),
           "sequence_finalization": report.get("sequence_finalization")}
    if rc == 3:
        seqfin = report.get("sequence_finalization") or {}
        enumerated = seqfin.get("enumerated", True)
        res.update(resume_required=True, no_reload_no_truncate=True, sequences_enumerated=enumerated)
        if enumerated:
            res["resume_setvals"] = plan_sequence_resume(report)   # from {error,pending} receipts
        else:
            # Post-commit discovery/connection failed: sequences_reset is empty. Re-derive owned
            # sequences from the catalog and setval to max(col) (NULL-safe), not from receipts.
            res["resume_setvals"] = []
            res["catalog_enumeration_required"] = True
            res["resume_directive"] = (
                "re-derive OWNED sequences from pg_catalog (each target's identity/serial columns) and "
                "setval each NULL-safe: SELECT setval(seq, m, true) FROM (SELECT max(col) AS m FROM tbl) s "
                "WHERE m IS NOT NULL; never reload/truncate")
    elif rc == 4:
        # commit_ack_unknown: outcome UNKNOWN. Rows may or may not be present. Inspect the target
        # (count vs expected) before any resume/retry; never blind-reload, never assume rollback.
        res.update(outcome="unknown", commit_outcome=report.get("commit_outcome", "unknown"),
                   inspect_target_required=True, no_reload=True, no_assume_rollback=True,
                   blocker="commit_ack_unknown",
                   directive="inspect the target (count vs expected) before deciding to resume/retry; "
                             "rows may or may not be present; never blind-reload and never assume rollback")
    elif rc == 1:
        res["blockers"] = report.get("blockers")
    elif rc == 2:
        res["rolled_back"] = True
    return res

def cmd_dataload(args) -> int:
    """Hash-gate the pinned loader and, given a post-apply --report + --exit-code, interpret the
    exit contract and (exit 3) emit the sequence-resume plan. Does NOT itself write to the target
    DB: the application-DB apply/resume is coordinated by main (credentials never reach Copilot)."""
    controller = Path(args.controller)
    v = verify_loader()
    _receipt(controller, "loader_verified", match=v["match"], actual_sha256=v["actual_sha256"])
    if not v["match"]:
        print(json.dumps({"error": "loader hash mismatch -- refusing to proceed", **v}, indent=2))
        return 1
    if args.report:
        interp = interpret_loader_exit(args.exit_code, _load(Path(args.report)))
        _write_json(controller / "loader-interpretation.json", interp)
        _receipt(controller, "loader_interpreted", exit_code=args.exit_code,
                 meaning=interp["meaning"], resume_setvals=len(interp.get("resume_setvals", [])))
        print(json.dumps(interp, indent=2))
        return 0
    print(json.dumps({"loader": v, "exit_contract": LOADER_EXIT,
                      "invocation_template": ("python -m migration_team.data_loader --manifest "
                          "<snapshot manifest.json> --target-schema contoso --database <APP_DB> "
                          "[--mapping <json>] --apply --report <report.json>"),
                      "note": "Controller hash-gates the loader and owns exit-3 sequence resume "
                              "(setval per error/pending receipt; never reload/truncate). Application-DB "
                              "apply/resume execution is coordinated by main; credentials never enter Copilot."},
                     indent=2))
    return 0


# ---------- next-ready frontier + registration/support catalog linkage ----------
SCHEMA_FOUNDATION_KINDS = {"type", "table", "ref-constraint"}
# GLOBAL TEMPORARY tables are NOT in schema-foundation's 151 (session-scoped, export-excluded).
# They are this controller's separate temp-table class -- drivable by me despite the table: kind.
MY_TEMP_TABLE_UNITS = {"table:CONTOSO.GTT_ORDER_STAGE", "table:CONTOSO.GTT_PRICE_CALC",
                       "table:CONTOSO.GTT_REPLENISHMENT"}

def _kind_of(unit_id: str) -> str:
    return unit_id.split(":", 1)[0]

def _is_schema_foundation(unit_id: str) -> bool:
    """schema-foundation owns type/table/ref-constraint EXCEPT the 3 GTT temp tables (mine)."""
    return _kind_of(unit_id) in SCHEMA_FOUNDATION_KINDS and unit_id not in MY_TEMP_TABLE_UNITS

def compute_next_ready(controller: Path) -> dict:
    """The runnable frontier: unstarted units whose every work-unit dependency is reviewed.
    Split by ownership -- schema-foundation drives type/table/ref-constraint; I drive the rest
    and ingest their reviewed evidence. On a fresh ledger the frontier is the level-0 leaves."""
    man = _load(controller / "controller-manifest.json")
    by = {u["unit_id"]: u for u in man["units"]}
    ids = set(by)
    reviewed = {uid for uid, u in by.items() if u["controller_state"] == "reviewed"}

    def deps_ok(u):
        return all(d in reviewed for d in u["depends_on"] if d in ids)

    frontier = [u for u in man["units"] if u["controller_state"] in ("unstarted", "superseded_needs_fresh_review")
                and deps_ok(u)]
    mine = [u["unit_id"] for u in frontier if not _is_schema_foundation(u["unit_id"])]
    schema = [u["unit_id"] for u in frontier if _is_schema_foundation(u["unit_id"])]
    batches = _load(controller / "batches.json")["batches"]
    # A partially-completed batch still offers its remaining ready+mine units (no stranding).
    my_batches = []
    for b in batches:
        ready = [uid for uid in b["unit_ids"]
                 if by[uid]["controller_state"] in ("unstarted", "superseded_needs_fresh_review")
                 and deps_ok(by[uid]) and not _is_schema_foundation(uid)]
        if ready:
            my_batches.append({"batch_id": b["batch_id"], "level": b["level"], "unit_ids": ready})
    # my_next_batches is the FULL ready+owned frontier: cmd_run's --units/--batch selectors scan it
    # to reach a requested unit/batch "from ANYWHERE in the frontier" (not just the first window), so
    # it must NOT be truncated. The dry-run preview shows my_next_batches_total + the first batch only.
    out = {"generated_at": _now(), "reviewed_units": len(reviewed), "frontier_total": len(frontier),
           "my_drivable_units": len(mine), "schema_foundation_units": len(schema),
           "my_next_batches_total": len(my_batches), "my_next_batches": my_batches,
           "note": "Ready = unstarted with all work-unit deps reviewed. Deeper units unlock as their "
                   "dependencies (incl. schema-foundation's ingested reviews) reach reviewed."}
    _write_json(controller / "next-ready.json", out)
    _receipt(controller, "next_ready_computed", frontier=len(frontier), my_batches=len(my_batches))
    return out

def link_catalog(controller: Path, catalog_dir: Path) -> dict:
    """Link the read-only source registration/support catalog as a SEPARATE accounting axis.
    Metadata only -- no task/DDL classification, never double-counted into the work/load/task totals."""
    m = _load(catalog_dir / "manifest.json")
    ds = {d["name"]: {"rows": d["rows"], "sha256": d["sha256"]} for d in m.get("datasets", [])}
    reg = {
        "source_catalog": str(catalog_dir), "captured_at": m.get("captured_at"),
        "scope": m.get("scope"), "status": m.get("status"), "errors": m.get("errors"),
        "datasets": ds, "total_rows": sum(v["rows"] for v in ds.values()),
        "accounting_axis": "registration_support",
        "metadata_only": True, "no_task_classification": True, "no_original_writes_or_nextval": True,
        "double_count_policy": ("Separate axis; NOT added to the 908-task / 1256-work-unit / 93-load-unit "
            "totals. Overlapping classes (triggers/MVs/sequences) already appear as work-units where the "
            "historical run flagged them; this is the fuller source-side registration inventory for gate "
            "linkage only. The schema-151 support queue and the 4 older reviews stay tracked in the ledger "
            "(prior_reviewed / ingest) and are not re-counted here."),
        "hard_case_gate_links": {
            "triggers": "trigger hard cases; gated per reviewed trigger work-unit",
            "materialized-views": "MV definition/refresh hard cases",
            "sequences": "identity/sequence finalization -- owned post-load by the loader exit-3 setval resume",
            "policies+contexts+policy-contexts": "VPD/RLS + application-context hard cases",
            "scheduler-jobs+programs+schedules": "DBMS_SCHEDULER hard cases",
            "directories+nls": "filesystem/NLS environment support",
            "columns": "1222 column semantics feed data-phase required_checks + full_validation projections",
        },
    }
    for f in ("coverage.json", "controller-manifest.json"):
        obj = _load(controller / f)
        (obj["coverage"] if f == "controller-manifest.json" else obj)["registration_support"] = reg
        _write_json(controller / f, obj)
    _receipt(controller, "catalog_linked", datasets=len(ds), rows=reg["total_rows"])
    return reg


# ---------- post-review failure lifecycle: supersede stale credit; require fresh review ----------
def reverify_ledger(controller: Path) -> dict:
    """Re-check every credited unit against the LIVE public queue. A unit previously credited
    reviewed but now no longer `reviewed` in its queue (e.g. main reopened it after a runtime
    counterexample) is SUPERSEDED: its credit is cleared and it requires fresh validation +
    independent review. Coverage never rests on a stale 'reviewed' label. Evidence is kept for
    provenance (append-only); nothing in the queue/SQLite is modified."""
    man = _load(controller / "controller-manifest.json")
    checked = still = 0
    superseded = []
    for u in man["units"]:
        if u["controller_state"] not in ("reviewed", "partially_reviewed"):
            continue
        # (queue, task_id) pairs to re-audit: from evidence[], with a fallback to reviewed_task_ids
        # paired with the queue recorded in run_state_history -- queue-state credits carry no
        # evidence[] rows but must still be budget-re-auditable, never trusted on a bare label.
        pairs = {(ev.get("queue"), ev.get("task_id")) for ev in u.get("evidence", [])
                 if ev.get("queue") and ev.get("task_id")}
        if not pairs and u.get("reviewed_task_ids"):
            qs = [h.get("queue") for h in u.get("run_state_history", []) if h.get("queue")]
            if qs:
                pairs = {(qs[-1], tid) for tid in u["reviewed_task_ids"]}
        bad = []
        for q, tid in sorted(pairs):
            checked += 1
            if _is_quarantined_lineage(tid, u["unit_id"]):
                bad.append({"task_id": tid, "reason": "quarantined_lineage_hold"})
                continue
            try:
                d = json.loads(subprocess.check_output(MT_CLI + ["show", "--state", q, "--id", tid]))
                if d.get("status") != "reviewed":
                    bad.append({"task_id": tid, "observed_status": d.get("status")})
                    continue
                # full-scope re-verify still checks EVERY credited unit; reuse show's fresh budget.
                budget_ok, bsnap = _budget_cleared(q, tid, shown=d)
                if not budget_ok:
                    vb = bsnap.get("validation_budget", {})
                    bad.append({"task_id": tid, "reason": "budget_not_cleared",
                                "review_eligible": vb.get("review_eligible"),
                                "within_limit": vb.get("within_limit"),
                                "quarantined": vb.get("quarantined"),
                                "budget_source": bsnap.get("budget_source")})
                    continue
                # supersede a review whose staged inputs drifted since validation (e.g. a reconfigure
                # after the credit) -- coverage must not rest on a now-stale 'reviewed' label.
                fresh_ok, fresh_reason = _evidence_fresh(d)
                if not fresh_ok:
                    bad.append({"task_id": tid, "reason": "stale_inputs", "detail": fresh_reason})
            except Exception as e:  # noqa: BLE001
                bad.append({"task_id": tid, "error": str(e)})
        if not pairs:  # credited but nothing re-auditable -> fail closed (cannot verify == not verified)
            bad.append({"reason": "no_reauditable_evidence", "reviewed_task_ids": u.get("reviewed_task_ids")})
        if bad:
            u["controller_state"] = "superseded_needs_fresh_review"
            u["reviewed_task_ids"] = []
            u.setdefault("supersessions", []).append({"at": _now(), "trigger": "reverify", "details": bad})
            superseded.append({"unit": u["unit_id"], "details": bad})
        else:
            still += 1
    _write_json(controller / "controller-manifest.json", man)
    out = {"reverified_evidence_checked": checked, "still_reviewed": still,
           "superseded": len(superseded), "superseded_units": superseded}
    _write_json(controller / "reverify-result.json", out)
    _receipt(controller, "ledger_reverified", superseded=len(superseded), still_reviewed=still)
    return out

def supersede_unit(controller: Path, key: str, reason: str, actor: str) -> dict:
    """Explicitly invalidate a unit's accepted coverage on a verified counterexample, before or
    alongside a queue `reopen`. Sets superseded_needs_fresh_review and clears the reviewed credit;
    prior evidence is retained for provenance. Requires fresh validation + independent review."""
    man = _load(controller / "controller-manifest.json")
    by_uid = {u["unit_id"]: u for u in man["units"]}
    by_task = {t: u for u in man["units"] for t in u.get("task_ids", [])}
    u = by_uid.get(key) or by_task.get(key)
    if u is None:
        return {"error": "unit/task not found", "key": key}
    prev = u["controller_state"]
    u["controller_state"] = "superseded_needs_fresh_review"
    u["reviewed_task_ids"] = []
    u.setdefault("supersessions", []).append({"at": _now(), "trigger": "counterexample",
                                              "actor": actor, "reason": reason, "previous_state": prev})
    _write_json(controller / "controller-manifest.json", man)
    _receipt(controller, "unit_superseded", unit=u["unit_id"], previous_state=prev, actor=actor, reason=reason)
    return {"unit": u["unit_id"], "previous_state": prev, "new_state": u["controller_state"],
            "reason": reason, "requires": "fresh validation + independent review"}


# ---------- real bounded batch execution ----------
def _source_index(plan_root: Path) -> dict:
    """source_key -> genuine Oracle DDL path (for the repair lane to stage; no reconstruction)."""
    return {e["source_key"]: e.get("ddl_path") for e in _load(plan_root / "source-inventory.json")}

def ingest_queue_state(controller: Path, run_queue: Path, unit_ids: list) -> list:
    """Read the LIVE run queue via `mt show` for each unit's task(s) and fold the observed state
    into the ledger with a resumable per-unit receipt. A unit is credited reviewed only if ALL its
    tasks are reviewed with reviewer != worker -- never on a label the controller wrote itself."""
    man = _load(controller / "controller-manifest.json")
    by = {u["unit_id"]: u for u in man["units"]}
    results = []
    for uid in unit_ids:
        u = by.get(uid)
        if u is None:
            results.append({"unit": uid, "error": "unknown unit"})
            continue
        states = []
        for tid in u.get("task_ids", []):
            lineage_hold = _is_quarantined_lineage(tid, uid)
            try:
                d = json.loads(subprocess.check_output(MT_CLI + ["show", "--state", str(run_queue), "--id", tid]))
                vb = d.get("validation_budget", {}) or {}
                # reuse the fresh validation_budget `show` already returned -- no redundant `mt audit`.
                budget_ok, bsnap = _budget_cleared(str(run_queue), tid, shown=d)
                auth_ok, auth_reason = _authorization_ok(controller, tid, vb, d.get("evidence") or {})
                lineage_ok = (not lineage_hold) or (bool(vb.get("active_authorization")) and auth_ok)
                fresh_ok, fresh_reason = _evidence_fresh(d)   # post-review input-drift guard
                states.append({"task_id": tid, "status": d.get("status"),
                               "reviewer": d.get("reviewer"), "worker": d.get("worker"),
                               "lineage_hold": lineage_hold, "budget_cleared": bool(budget_ok),
                               "auth_ok": bool(auth_ok), "lineage_ok": bool(lineage_ok),
                               "fresh": bool(fresh_ok), "fresh_reason": fresh_reason,
                               "review_eligible": vb.get("review_eligible"),
                               "within_limit": vb.get("within_limit"), "quarantined": vb.get("quarantined"),
                               "used": vb.get("used"), "budget_source": bsnap.get("budget_source")})
                _receipt(controller, "source_budget_audit", task_id=tid, unit=uid, run_queue=str(run_queue),
                         lineage_hold=lineage_hold, auth_ok=bool(auth_ok), validation_budget=vb,
                         budget_source=bsnap.get("budget_source"))
            except Exception as e:  # noqa: BLE001
                states.append({"task_id": tid, "status": "cli-error", "detail": str(e),
                               "lineage_hold": lineage_hold, "budget_cleared": False,
                               "auth_ok": False, "lineage_ok": not lineage_hold, "fresh": False})
        # Credit reviewed ONLY if every task is reviewed, reviewer != worker, lifetime-budget cleared
        # (review_eligible/within_limit/not quarantined), grant-authorization ok, the review's inputs are
        # still FRESH (not drifted since validation), and any quarantined lineage hold is overridden ONLY
        # by a valid grant FOR that exact task.
        all_rev = bool(states) and all(
            s.get("status") == "reviewed" and s.get("reviewer") and s.get("worker")
            and s["reviewer"] != s["worker"] and s.get("budget_cleared") is True
            and s.get("auth_ok") is True and s.get("lineage_ok") is True
            and s.get("fresh") is True for s in states)
        if all_rev:
            st = "reviewed"
            u["reviewed_task_ids"] = [s["task_id"] for s in states]
            existing = {(e.get("queue"), e.get("task_id")) for e in u.get("evidence", [])}
            for s in states:  # record re-auditable evidence so reverify can re-audit the budget later
                if (str(run_queue), s["task_id"]) not in existing:
                    u.setdefault("evidence", []).append({
                        "task_id": s["task_id"], "reviewer": s.get("reviewer"), "worker": s.get("worker"),
                        "queue": str(run_queue), "verified_via_cli": True,
                        "validation_budget": {"review_eligible": s.get("review_eligible"),
                                              "within_limit": s.get("within_limit"),
                                              "quarantined": s.get("quarantined")}})
        elif any(s["status"] == "blocked" for s in states):
            st = "blocked"
        elif any(s["status"] == "pending_review" for s in states):
            st = "pending_review"
        elif any(s["status"] in ("claimed", "validating") for s in states):
            st = "repairing"
        elif states and all(s["status"] == "queued" for s in states):
            st = "unstarted"        # back in the queue (e.g. released after a dead lane) -> drivable again
        else:
            st = u["controller_state"]  # unchanged (still queued/unstarted)
        u["controller_state"] = st
        # Retain the LIFETIME validation attempts observed for this identity so a later reseed into a
        # fresh queue cannot silently reset the lifetime-three budget: any identity with used>0 (even one
        # released back to 'queued') is a prior attempt and stays non-seedable (see _has_prior_attempts).
        used_now = max([(s.get("used") or 0) for s in states] + [0])
        u["lifetime_attempts_used"] = max(u.get("lifetime_attempts_used") or 0, used_now)
        u.setdefault("run_state_history", []).append({"at": _now(), "queue": str(run_queue), "states": states})
        _receipt(controller, "unit_state_ingested", unit=uid, state=st, run_queue=str(run_queue))
        results.append({"unit": uid, "controller_state": st, "task_states": states})
    _write_json(controller / "controller-manifest.json", man)
    return results

def _batch_prompt(controller: Path, run_queue: Path, batch: dict, specs: list) -> str:
    lines = [
        "You are the o2p-coordinator executing ONE bounded batch of the full migration. Route ONLY",
        "through the migration-team CLI wrapper `mt`; delegate via your `task` tool to o2p-repair then,",
        "after a passing validation, an INDEPENDENT o2p-reviewer (reviewer != worker). Keep at most 2",
        "active lanes; max 3 validate attempts per task; on honest failure `mt release --blocked`.",
        "Never fabricate original Oracle DDL (stage the genuine ddl_path given); never touch Azure/",
        "deploy/git/email; never read any credentials/secret file. Write only under the repair_dir given.",
        f"Queue (state dir): {run_queue}",
        "Units in this batch (each: task_id, genuine source ddl_path, repair_dir):",
    ]
    for s in specs:
        lines.append(f"  - {s['unit_id']} | task_id {s['task_id']} | source {s['ddl_path']} | out {s['repair_dir']}")
    kinds = {_kind_of(s["unit_id"]) for s in specs}
    if "sequence" in kinds:
        lines += [
            "SEQUENCE units — a CREATE SEQUENCE that merely compiles is NOT done. The candidate must",
            "faithfully map source INCREMENT BY / START WITH / MIN/MAXVALUE / CYCLE|NOCYCLE / ORDER|NOORDER /",
            "CACHE|NOCACHE. MAXVALUE up to 9999999999999999999999999999 (28 nines) EXCEEDS PostgreSQL bigint",
            "-- do NOT blindly clamp to bigint. Per architect convergence the target uses ONE shared numeric(28)",
            "allocator ADAPTER (independent commit + row-level locking + per-session CURRVAL), authored ONCE as a",
            "labelled support work-unit; the 75 sequences become per-target MAPPINGS + source boundary fixtures",
            "onto that single adapter -- do NOT emit 75 (or 54) duplicate allocator implementations, and do NOT",
            "invent an unproven hi/lo carry scheme. The independent-commit mechanism consumes a PARENT-OWNED",
            "trusted fixed named connection (dblink is available + azure-allowlisted but UNINSTALLED, 0 named",
            "servers, no shared restart needed) -- do NOT install dblink or create named servers yourself; that",
            "bootstrap is main's, and this whole adapter path is GATED on main approval + runtime verification.",
            "checks.sql MUST include boundary tests (increment step, CYCLE wrap, min/max edges). The reviewer",
            "rejects a bare compile. The LOAD-TIME next value/floor is the integration owner's concern -- a value",
            "PHASE-ALIGNED to the source (smallest V congruent to captured LAST_NUMBER modulo the increment,",
            "V >= LAST_NUMBER and V > max loaded key), NOT a naive max(col)+increment; do not assert that",
            "stronger condition here. 'One shared allocator' means one shared IMPLEMENTATION, NOT one shared",
            "counter: each sequence keeps its OWN logical allocator state, so where MULTIPLE independent",
            "generators feed one column (e.g. DATA_QUALITY_ISSUE.ISSUE_ID, JOB_RUN_LOG.RUN_ID) you still PRESERVE",
            "and TEST the source collision/error behavior -- never collapse independent logical sequences into",
            "one counter.",
        ]
    if kinds & {"trigger", "materialized-view", "view", "procedure", "package_body", "package_state"}:
        lines += [
            "TRIGGER/MATERIALIZED_VIEW/VIEW/PROCEDURE/PACKAGE units: preserve exact semantics (timing/",
            "level/WHEN, refresh/definition, column list + nullability, package state); a green compile over",
            "trivial checks is not acceptance. A catalog-VALID source object may still FAIL AT RUNTIME --",
            "e.g. MV_CUSTOMER_RFM refresh raises ORA-42804 (RLS disclosure); JOB_REFRESH_REPORTING fails on a",
            "missing PKG_MV_REFRESH.REFRESH_GROUP and an invalid SQLERRM identifier; a registered context",
            "references a non-existent PKG_SECURITY_CTX. Do NOT stub success, do NOT silently disable VPD/RLS/",
            "security context, do NOT claim a functional waiver. Preserve the source's genuine behavior; if it",
            "genuinely fails, `mt release --blocked` with the named reason for a main-owned disposition --",
            "never fabricate a pass. Catalog VALID != runtime valid.",
        ]
    if "trigger" in kinds:
        lines += [
            "TRIGGER app-transform semantics (33 app-transform tables): a row trigger that NORMALIZES a",
            "column -- ADDRESS line1/city TRIM; CUSTOMER email LOWER(TRIM); EMPLOYEE first/last INITCAP(TRIM);",
            "the 30 STG_* sku UPPER(TRIM) -- must preserve the EXACT transform AND the source firing order",
            "(H38) AND the post-transform empty->NULL rule: Oracle collapses a value that becomes '' AFTER",
            "trimming to NULL, so the target assignment must be e.g. NULLIF(lower(btrim(NEW.col)),'') -- the",
            "ingress normalizer alone does NOT normalize empties the trigger itself creates later. checks.sql",
            "MUST exercise the transform, the post-trim empty->NULL case, and multi-trigger firing order. This",
            "is a SEPARATE work-unit from the table DDL; a table DDL review does NOT close it.",
        ]
    if kinds & {"function", "procedure", "package_body", "package_state"}:
        lines += [
            "ROUTINE volatility + session cache (source-tested H23/H24/H43): PRESERVE the source's exact",
            "volatility -- an IMPURE/table-reading function is STABLE (or VOLATILE), NEVER over-promoted to",
            "IMMUTABLE, and a DETERMINISTIC-but-reading routine must not be IMMUTABLE-folded. Package SESSION",
            "(package-global) cache retains a value written before an OUTER ROLLBACK (Oracle: PKG_PRICING keeps",
            "NEW 277.1022 after rollback restores PRODUCT to old 267.1022; only its own reset_cache clears it) --",
            "do NOT emulate package session cache with a TEMP table / GUC / session table that is transactional",
            "and would vanish on rollback; that loses the semantics. RESULT_CACHE is distinct: the writer's own",
            "uncommitted txn sees NEW, a second session sees OLD, COMMIT invalidates it, a later restore",
            "invalidates again. A PREPARED CONSTANT lookup (FN_TIER_FOR_POINTS: BRONZE->SILVER when the lookup",
            "row updates, back to BRONZE on rollback) re-evaluates on its dependency -- do NOT constant-fold it.",
            "checks.sql MUST exercise these across a txn boundary. Do NOT stub a source failure into a pass.",
            "checks.sql must derive each EXPECTED value INDEPENDENTLY of the non-deterministic expression under",
            "test: a check that computes its expected clock/SYSDATE/random/sequence boundary from the SAME",
            "expression it is exercising is TAUTOLOGICAL (it can never fail) and the reviewer rejects it -- pin",
            "an independent expected value (a captured constant, a second isolated call, or an out-of-band bound).",
        ]
    lines += [
        "Process the units ONE AT A TIME, finishing each fully before starting the next -- so if the AI-credit",
        "or session limit is hit, COMPLETED units are left reviewed, not a batch of half-staged ones. For each",
        "unit make exactly ONE `task` call to o2p-repair that runs the WHOLE repair lifecycle under a single",
        "identity --worker o2p-repair-full: `mt claim --state <queue> --worker o2p-repair-full --id <task_id>`,",
        "read the genuine ddl_path, write candidate.sql + checks.sql (grounded in the source) + notes.md under",
        "the repair_dir, `mt stage --state <queue> --id <task_id> --worker o2p-repair-full --source <ddl_path>",
        "--candidate <repair_dir>/candidate.sql --checks <repair_dir>/checks.sql`, then `mt validate` (<=3",
        "attempts). On a passing validation make ONE `task` call to o2p-reviewer that runs `mt review --state",
        "<queue> --id <task_id> --reviewer o2p-reviewer-full --decision accept|reject --note '<specific>'`.",
        "YOU (the coordinator) never run claim/stage/validate/review yourself and never re-claim a task a lane",
        "already owns (that self-conflicts on the worker identity). reviewer != worker, always. Report each",
        "unit's final state. This is one bounded batch; do not exceed it.",
    ]
    return "\n".join(lines)

def exec_session_profile() -> list:
    """One coordinator SESSION that delegates o2p-repair (needs apply_patch + scoped SQL writes) then
    an independent o2p-reviewer (read + CLI). Subagents inherit the session tool set, so the session
    exposes the union -- still tight: only the `mt` wrapper for shell, `task`, and per-filename writes."""
    common = ["--no-ask-user", "--disable-builtin-mcps", "--no-remote-export", "--no-color"]
    return (["--available-tools", "bash", "view", "glob", "apply_patch", "task",
             "--allow-tool", "shell(mt:*)", "--allow-tool", "task",
             "--allow-tool", "write(candidate.sql)", "--allow-tool", "write(checks.sql)",
             "--allow-tool", "write(notes.md)", "--allow-tool", "write(target-ddl.sql)"] + common)

def execute_batch(controller: Path, run_queue: Path, batch: dict, plan_root: Path,
                  credits: int, timeout: int) -> dict:
    """Launch a real, bounded o2p-coordinator run for one batch under the tight profile, then ingest
    the resulting queue state. The application-DB/credentials are never involved (Docker validation)."""
    src = _source_index(plan_root)
    by = {u["unit_id"]: u for u in _load(controller / "controller-manifest.json")["units"]}
    bdir = controller / "batch-exec" / batch["batch_id"]
    bdir.mkdir(parents=True, exist_ok=True)
    specs = []
    for uid in batch["unit_ids"]:
        u = by.get(uid)
        if not u:
            continue
        rd = bdir / uid.replace(":", "__")
        rd.mkdir(exist_ok=True)
        for sk in u["source_keys"]:
            specs.append({"unit_id": uid, "source_key": sk,
                          "task_id": _task_id(*_parse_source_key(sk)),
                          "ddl_path": src.get(sk), "repair_dir": str(rd)})
    ppath = bdir / "prompt.txt"
    ppath.write_text(_batch_prompt(controller, run_queue, batch, specs))
    sid = str(uuid.uuid4())   # Copilot --session-id requires a canonical dashed UUID
    ensure_wrapper(controller)
    argv = (["copilot", "-C", str(REPO), "--agent", "o2p-coordinator"] + exec_session_profile()
            + ["--max-ai-credits", str(credits), "--log-dir", str(controller / "copilot-logs"),
               "--session-id", sid, "-p", f"@{ppath}"])
    env = dict(os.environ, PATH=f"{controller / 'bin'}:" + os.environ.get("PATH", ""))
    _receipt(controller, "batch_launch", batch=batch["batch_id"], units=batch["unit_ids"],
             session_id=sid, credits=credits)
    rc, err = None, None
    try:
        p = subprocess.run(argv, cwd=str(REPO), env=env, capture_output=True, text=True, timeout=timeout)
        (bdir / "stdout.log").write_text(p.stdout)
        (bdir / "stderr.log").write_text(p.stderr)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        rc, err = 124, "timeout"
        _receipt(controller, "batch_timeout", batch=batch["batch_id"], timeout=timeout)
    except FileNotFoundError as e:
        rc, err = 127, str(e)
    ingested = ingest_queue_state(controller, run_queue, batch["unit_ids"])
    _receipt(controller, "batch_complete", batch=batch["batch_id"], copilot_rc=rc, error=err,
             session_id=sid, reviewed=sum(1 for r in ingested if r.get("controller_state") == "reviewed"))
    return {"batch": batch["batch_id"], "copilot_rc": rc, "error": err, "session_id": sid,
            "ingested": ingested, "launch_ok": err is None}


# ---------- target-profile validation (non-secret schema, not just a non-empty string) ----------
TARGET_PROFILE_REQUIRED = ("schema", "application_database", "compiler_database", "role_nonsuperuser")
_SECRETY = ("password", "pgpassword", "secret", "token", "dsn", "private_key", "connection_string")

def validate_target_profile(path) -> dict:
    """A valid controller target profile is a JSON object with the required NON-SECRET keys and no
    field that looks like an embedded credential value. Used by the run gate (not a nonempty check)."""
    if not path:
        return {"valid": False, "error": "--target-profile missing"}
    try:
        prof = _load(Path(path))
    except Exception as e:  # noqa: BLE001
        return {"valid": False, "error": f"unreadable or not JSON: {e}"}
    if not isinstance(prof, dict):
        return {"valid": False, "error": "target profile must be a JSON object"}
    missing = [k for k in TARGET_PROFILE_REQUIRED if not prof.get(k)]
    leaks = []
    def scan(o, pfx=""):
        if isinstance(o, dict):
            for k, v in o.items():
                kl = k.lower()
                if (any(s in kl for s in _SECRETY)
                        and not any(x in kl for x in ("path", "policy", "reference", "note", "file"))
                        and isinstance(v, str) and v):
                    leaks.append(pfx + k)
                scan(v, pfx + k + ".")
        elif isinstance(o, list):
            for i, v in enumerate(o):
                scan(v, f"{pfx}[{i}].")
    scan(prof)
    return {"valid": (not missing and not leaks), "missing": missing,
            "possible_secret_fields": leaks, "schema": prof.get("schema"),
            "application_database": prof.get("application_database")}


# ---------- seed a private run queue for a batch (public CLI; enqueues every unit) ----------
def _has_prior_attempts(u: dict) -> bool:
    """True if the unit has any recorded prior validation attempt/credit, so reseeding it into a FRESH
    queue would illegitimately reset its lifetime-three budget. A unit can read 'unstarted' again after
    being released back to 'queued', yet still have consumed lifetime attempts in its old queue -- so
    also honor the retained lifetime used count and any per-task used>0 in history, not just the current
    controller_state label or a non-queued status."""
    if u.get("reviewed_task_ids") or u.get("evidence"):
        return True
    if (u.get("lifetime_attempts_used") or 0) > 0:
        return True
    for h in (u.get("run_state_history") or []):
        for s in (h.get("states") or []):
            if s.get("status") not in (None, "queued"):
                return True
            if (s.get("used") or 0) > 0:
                return True
    return False


def seed_queue(controller: Path, plan_root: Path, run_queue: Path,
               batch_id: str = None, units: list = None, max_workers: int = 2) -> dict:
    """Seed a private run queue containing a batch's units via a synthesized Action_Required mapping,
    so `mt show`/claim can address units even when they are absent from the historical report queue.
    Never seeds schema-foundation-owned kinds (no duplication of their active batches)."""
    import csv as _csv
    import io as _io
    man = _load(controller / "controller-manifest.json")
    by = {u["unit_id"]: u for u in man["units"]}
    if batch_id:
        b = next((x for x in _load(controller / "batches.json")["batches"] if x["batch_id"] == batch_id), None)
        if b is None:
            return {"error": f"unknown batch {batch_id}"}
        uids = list(b["unit_ids"])
    else:
        uids = list(units or [])
    if units:
        uids = [u for u in uids if u in set(units)]
    uids = [u for u in uids if not _is_schema_foundation(u)]
    # not_authorized: a FRESH run queue starts every task at a clean lifetime-3 budget, so it is ONLY
    # for units that were NEVER attempted. Never reseed a unit that is credited (reviewed/partially),
    # a held quarantine lineage, OR one that already has recorded prior attempts (blocked/exhausted,
    # in-flight, or superseded) -- those must be re-driven IN their existing queue, where the
    # lifetime-no-reset ledger persists; reseeding them into a fresh queue would silently reset the cap.
    skipped, seedable = {}, []
    for u in uids:
        if u not in by:
            skipped[u] = "unknown unit"
            continue
        st = by[u]
        state = st.get("controller_state")
        if _is_quarantined_lineage("", u):
            skipped[u] = "quarantined_lineage"
        elif state in ("reviewed", "partially_reviewed"):
            skipped[u] = f"credited ({state}); reseeding would grant fresh attempts"
        elif state not in (None, "unstarted"):
            skipped[u] = f"already worked ({state}); re-drive in existing queue, do not reset budget"
        elif _has_prior_attempts(st):
            skipped[u] = "recorded prior attempts; re-drive in existing queue, do not reset budget"
        else:
            seedable.append(u)
    uids = seedable
    if not uids:
        return {"error": "no seedable units for this selection (never-attempted, non-schema-foundation "
                         "only)", "skipped": skipped}
    run_queue = Path(run_queue)
    if run_queue.exists() and any(run_queue.iterdir()):
        return {"error": f"run-queue exists and is non-empty (init refuses it): {run_queue}"}
    buf = _io.StringIO()
    w = _csv.writer(buf)
    w.writerow(["Source_Object_Type", "Source_Object", "Azure_PostgreSQL_Object_Type",
                "Azure_PostgreSQL_Object", "Status", "Action_Required", "Error_Message"])
    for uid in uids:
        for sk in by[uid]["source_keys"]:
            t, n = _parse_source_key(sk)
            w.writerow([t, n, t, n.lower(), "Not-Converted", "yes", "full-run seed"])
    csv_path = controller / "seed-queues" / f"{batch_id or 'units'}.csv"
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    csv_path.write_text(buf.getvalue())
    init = subprocess.run(MT_CLI + ["init", "--state", str(run_queue), "--report", str(csv_path),
                                    "--target-schema", "contoso", "--max-workers", str(max(1, min(2, max_workers)))],
                          capture_output=True, text=True)
    if init.returncode != 0:
        return {"error": "mt init failed", "stderr": init.stderr}
    tasks = []
    for uid in uids:
        for sk in by[uid]["source_keys"]:
            tid = _task_id(*_parse_source_key(sk))
            try:
                d = json.loads(subprocess.check_output(MT_CLI + ["show", "--state", str(run_queue), "--id", tid]))
                tasks.append({"unit": uid, "task_id": tid, "status": d.get("status")})
            except Exception as e:  # noqa: BLE001
                tasks.append({"unit": uid, "task_id": tid, "error": str(e)})
    _receipt(controller, "run_queue_seeded", run_queue=str(run_queue), units=len(uids), tasks=len(tasks))
    return {"run_queue": str(run_queue), "seeded_units": uids, "skipped": skipped,
            "csv": str(csv_path), "tasks": tasks}


def global_active_lanes(queues: list) -> dict:
    """Active repair lanes (claimed + validating) across the given queue state dirs. The global
    two-lane cap spans EXTERNAL coordinated queues (e.g. schema-foundation's), not just my own."""
    per, total = {}, 0
    for q in queues:
        n = 0
        for st in ("claimed", "validating"):
            try:
                n += len(json.loads(subprocess.check_output(MT_CLI + ["list", "--state", str(q), "--status", st])))
            except Exception:  # noqa: BLE001
                pass
        per[str(q)] = n
        total += n
    return {"total": total, "per_queue": per}

def _queue_max_workers(queue: Path) -> int:
    try:
        return int(json.loads(subprocess.check_output(MT_CLI + ["report", "--state", str(queue)]))["input"]["max_workers"])
    except Exception:  # noqa: BLE001
        return MAX_ACTIVE_LANES


def read_authorization(controller: Path):
    """Parent-owned run gate. Honors the marker's CONTENTS, not mere existence: returns (marker, reasons).
    A missing/unparseable marker, or one without a required_run_controls block, is a hard authorization
    failure -- the controller never self-authorizes and never treats a bare file as a blank check."""
    p = controller / "AUTHORIZED_TO_RUN"
    if not p.exists():
        return None, ["AUTHORIZED_TO_RUN missing"]
    try:
        marker = json.loads(p.read_text())
    except Exception as e:  # noqa: BLE001
        return None, [f"AUTHORIZED_TO_RUN unparseable ({e})"]
    if not isinstance(marker, dict) or "required_run_controls" not in marker:
        return None, ["AUTHORIZED_TO_RUN has no required_run_controls block"]
    return marker, []


def check_run_controls(marker: dict, controller: Path, args, run_queue: Path) -> list:
    """Enforce the marker's required_run_controls against THIS invocation. Any drift toward looser
    controls than the parent authorized is a hard fail -- the run must not proceed."""
    rc = marker.get("required_run_controls", {}) or {}
    reasons = []
    want_mw = rc.get("run_queue_max_workers")
    if want_mw is not None and run_queue.exists():
        have_mw = _queue_max_workers(run_queue)
        if have_mw > want_mw:
            reasons.append(f"run-queue max_workers {have_mw} exceeds marker limit {want_mw}")
    want_res = rc.get("reserved_external_lanes")
    have_res = getattr(args, "reserved_external_lanes", 0) or 0
    if want_res is not None and have_res < want_res:
        reasons.append(f"--reserved-external-lanes {have_res} below marker requirement {want_res}")
    want_cq = rc.get("coordinated_queue")
    if want_cq:
        want_abs = (controller / want_cq).resolve()
        coords = {Path(c).resolve() for c in (getattr(args, "coordinated_queues", None) or [])}
        if want_abs not in coords:
            reasons.append(f"marker coordinated_queue {want_abs} not in --coordinated-queues")
    want_policy = rc.get("audit_policy")
    if want_policy and want_policy != BUDGET_POLICY:
        reasons.append(f"marker audit_policy {want_policy} != controller BUDGET_POLICY {BUDGET_POLICY}")
    return reasons


def cmd_run(args) -> int:
    controller = Path(args.controller)
    plan_root = Path(args.plan)
    ensure_wrapper(controller)
    ver = verify_inputs(plan_root, controller)

    # No --authorize: a PREVIEW only. Returns 0 but never claims execution happened.
    if not args.authorize:
        build_batches(plan_root, controller)
        nr = compute_next_ready(controller)
        print(json.dumps({"mode": "dry-run-preview", "authorized": False,
                          "immutability_ok": ver["all_match"],
                          "my_next_batches": nr["my_next_batches_total"],
                          "first_batch": nr["my_next_batches"][:1],
                          "note": "preview only; execute with --authorize + AUTHORIZED_TO_RUN + "
                                  "--target-profile + --run-queue"}, indent=2))
        _receipt(controller, "run_preview", my_next_batches=nr["my_next_batches_total"])
        return 0

    # --authorize requested: readiness/authorization failure must NOT return success.
    marker, reasons = read_authorization(controller)
    tp = validate_target_profile(args.target_profile)
    if not tp["valid"]:
        reasons.append("target-profile invalid: " + json.dumps(
            {k: tp[k] for k in ("error", "missing", "possible_secret_fields") if tp.get(k)}))
    if not ver["all_match"]:
        reasons.append("input immutability mismatch")
    if not args.run_queue:
        reasons.append("--run-queue missing")
    if marker and args.run_queue:                       # honor the marker's CONTENTS, not just existence
        reasons += check_run_controls(marker, controller, args, Path(args.run_queue))
    if reasons:
        print(json.dumps({"mode": "authorization_failed", "executed": False, "blocked_on": reasons},
                         indent=2))
        _receipt(controller, "run_authorization_failed", blocked_on=reasons)
        return 3  # non-zero: nothing executed

    run_queue = Path(args.run_queue)
    build_batches(plan_root, controller)
    executed, launch_errors = [], 0
    for _ in range(max(1, args.max_batches)):
        nr = compute_next_ready(controller)  # dependency-aware: only ready, deps reviewed
        if getattr(args, "units", None):      # --units is authoritative: gather matching READY units
            want = set(args.units)             # from ANYWHERE in the frontier, not just the first batch
            ready = [u for b in nr["my_next_batches"] for u in b["unit_ids"] if u in want]
            if not ready:
                break
            batch = {"batch_id": "UNITS", "level": 0, "unit_ids": ready}
        else:
            cand = [b for b in nr["my_next_batches"] if args.batch is None or b["batch_id"] == args.batch]
            if not cand:
                break
            batch = dict(cand[0])
        # not_authorized: never drive a quarantined/held lineage (scalar helper v1/v2 etc.).
        held = [u for u in batch["unit_ids"] if _is_quarantined_lineage("", u)]
        if held:
            print(json.dumps({"mode": "refused_quarantined_lineage", "executed": False, "units": held},
                             indent=2))
            _receipt(controller, "run_refused_quarantined", units=held)
            return 6
        # GLOBAL two-lane reservation: the cap spans EXTERNAL coordinated queues (schema-foundation),
        # not just my own. Foundation may RESERVE both slots even when momentarily idle, so honor a
        # declared reservation, not just the live active count -- no handoff means no launch.
        coord = [Path(q) for q in (getattr(args, "coordinated_queues", None) or [])]
        external = global_active_lanes(coord)["total"] if coord else 0
        reserved = getattr(args, "reserved_external_lanes", 0) or 0
        external_effective = max(external, reserved)
        budget = MAX_ACTIVE_LANES - external_effective
        my_workers = _queue_max_workers(run_queue)
        if budget <= 0 or my_workers > budget:
            print(json.dumps({"mode": "global_lane_cap", "executed": False,
                              "external_active_lanes": external, "external_reserved": reserved,
                              "external_effective": external_effective, "cap": MAX_ACTIVE_LANES,
                              "my_run_queue_max_workers": my_workers, "budget": budget,
                              "note": "no global lane slot, or run-queue max-workers exceeds the budget; "
                                      "coordinate a handover and reseed the run-queue with --max-workers "
                                      "<= budget"}, indent=2))
            _receipt(controller, "run_no_global_slot", external=external, budget=budget, my_workers=my_workers)
            return 5  # non-zero: refused to exceed the global cap
        res = execute_batch(controller, run_queue, batch, plan_root, args.max_credits, args.timeout)
        executed.append({"batch": res["batch"], "copilot_rc": res["copilot_rc"],
                         "launch_ok": res["launch_ok"],
                         "reviewed": sum(1 for r in res["ingested"] if r.get("controller_state") == "reviewed")})
        launch_errors += 0 if res["launch_ok"] else 1
        if args.batch:  # a specific batch: exactly one
            break
    failures = sum(1 for r in executed if not r["launch_ok"] or r["copilot_rc"] not in (0, None))
    if not executed:
        # Nothing eligible ran -- NOT a success execution. Report explicitly so no one credits a no-op.
        nr = compute_next_ready(controller)
        summary = {"mode": "no_eligible_work", "executed": False, "batches_executed": 0,
                   "my_next_batches_available": nr["my_next_batches_total"],
                   "note": "no ready+owned batch selected (dependencies unmet, the selected units are "
                           "already reviewed, or --units/--batch matched nothing). Nothing credited."}
        _write_json(controller / "run-result.json", summary)
        _receipt(controller, "run_no_eligible_work", available=nr["my_next_batches_total"])
        print(json.dumps(summary, indent=2))
        return 0
    summary = {"mode": "executed", "batches_executed": len(executed),
               "batch_failures": failures, "results": executed}
    _write_json(controller / "run-result.json", summary)
    _receipt(controller, "run_executed", batches=len(executed), failures=failures)
    print(json.dumps(summary, indent=2))
    # An agent-session/launch failure is a real failure; only clean executed batches return 0.
    return 4 if failures else 0



def cmd_status(args) -> int:
    controller = Path(args.controller)
    rp = controller / "receipts" / "receipts.jsonl"
    recs = [json.loads(l) for l in rp.read_text().splitlines()] if rp.exists() else []
    kinds = Counter(r["kind"] for r in recs)
    cov = controller / "coverage.json"
    work_states, load_states = {}, {}
    mp = controller / "controller-manifest.json"
    if mp.exists():
        man = _load(mp)
        work_states = dict(Counter(u["controller_state"] for u in man.get("units", [])))
        load_states = dict(Counter(lu["controller_state"] for lu in man.get("load_units", [])))
    print(json.dumps({"receipts": len(recs), "by_kind": dict(kinds),
                      "coverage_present": cov.exists(),
                      "work_unit_states": work_states, "load_unit_states": load_states,
                      "note": "reviewed counts are currently-valid credit only; "
                              "superseded_needs_fresh_review is NOT reviewed and needs fresh validation+review",
                      "last": recs[-1] if recs else None}, indent=2))
    return 0


def cmd_resume(args) -> int:
    """Reconstruct controller state from receipts + the public CLI queue (never edits SQLite)."""
    controller = Path(args.controller)
    q = controller / "queue"
    live = None
    if q.exists():
        try:
            live = json.loads(subprocess.check_output(MT_CLI + ["report", "--state", str(q)]))["states"]
        except Exception as e:
            live = {"error": str(e)}
    rp = controller / "receipts" / "receipts.jsonl"
    recs = [json.loads(l) for l in rp.read_text().splitlines()] if rp.exists() else []
    print(json.dumps({"live_queue_states": live, "receipt_count": len(recs),
                      "resumable": True}, indent=2))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="migration_team.full_run",
                                 description="Controller for the whole remaining migration.")
    ap.add_argument("--plan", default=str(DEFAULT_PLAN))
    ap.add_argument("--controller", default=str(DEFAULT_CONTROLLER))
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("manifest", "batches", "verify-inputs", "status", "resume", "next-ready", "reverify"):
        sub.add_parser(name)
    pr = sub.add_parser("run")
    pr.add_argument("--authorize", action="store_true")
    pr.add_argument("--target-profile", help="target/data contract JSON (from cohort-integrator/main)")
    pr.add_argument("--run-queue", help="state dir of the seeded run queue the lanes drive")
    pr.add_argument("--batch", help="run exactly this batch id (else the next ready my-owned batch)")
    pr.add_argument("--max-batches", type=int, default=1, help="bounded count of ready batches to run")
    pr.add_argument("--max-credits", type=int, default=150, help="Copilot credit cap per batch")
    pr.add_argument("--timeout", type=int, default=1800, help="per-batch wall-clock seconds")
    pr.add_argument("--units", nargs="*", help="restrict execution to these unit_ids within the batch")
    pr.add_argument("--coordinated-queues", nargs="*",
                    help="external queue state dirs (e.g. schema-foundation's) counted toward the global 2-lane cap")
    pr.add_argument("--reserved-external-lanes", type=int, default=0,
                    help="lanes another owner reserves globally even when idle (e.g. 2 = foundation holds both; no launch)")
    psq = sub.add_parser("seed-queue")
    psq.add_argument("--run-queue", required=True, help="new (empty) state dir to seed")
    psq.add_argument("--batch", help="seed all of this batch's units")
    psq.add_argument("--units", nargs="*", help="seed these unit_ids")
    psq.add_argument("--max-workers", type=int, default=2, help="run-queue lane budget (<= global slot)")
    pi = sub.add_parser("ingest-evidence")
    pi.add_argument("--evidence", required=True, help="peer reviewed-evidence JSON list")
    pd = sub.add_parser("ingest-data")
    pd.add_argument("--validation-out", required=True,
                    help="full_validation --out dir containing full-validation-report.json")
    pl = sub.add_parser("dataload")
    pl.add_argument("--report", help="post-apply loader report JSON to interpret against the contract")
    pl.add_argument("--exit-code", type=int, default=0, help="loader process exit code (0/1/2/3/4)")
    plc = sub.add_parser("link-catalog")
    plc.add_argument("--catalog", required=True, help="source-catalog dir containing manifest.json")
    psu = sub.add_parser("supersede")
    psu.add_argument("--id", required=True, help="unit_id or task_id whose accepted coverage to invalidate")
    psu.add_argument("--reason", required=True, help="the verified counterexample / failure")
    psu.add_argument("--actor", required=True)
    args = ap.parse_args(argv)

    plan_root, controller = Path(args.plan), Path(args.controller)
    controller.mkdir(parents=True, exist_ok=True)
    if args.cmd == "manifest":
        cov = build_manifest(plan_root, controller)
        print(json.dumps({k: cov[k] for k in (
            "work_units_total", "load_units_total", "remaining_author_review_task_count",
            "distinct_prior_reviewed", "units_with_baseline_candidate",
            "units_without_baseline_candidate", "hard_cases_total_declared",
            "hard_cases_missing", "fully_accounted")}, indent=2))
        return 0
    if args.cmd == "batches":
        out = build_batches(plan_root, controller)
        print(json.dumps({"levels": out["levels"], "batch_count": out["batch_count"],
                          "max_dependency_batch": out["max_dependency_batch"]}, indent=2))
        return 0
    if args.cmd == "verify-inputs":
        print(json.dumps(verify_inputs(plan_root, controller), indent=2))
        return 0
    if args.cmd == "ingest-evidence":
        print(json.dumps(ingest_evidence(controller, Path(args.evidence)), indent=2))
        return 0
    if args.cmd == "ingest-data":
        print(json.dumps(ingest_data(controller, Path(args.validation_out)), indent=2))
        return 0
    if args.cmd == "dataload":
        return cmd_dataload(args)
    if args.cmd == "next-ready":
        print(json.dumps(compute_next_ready(controller), indent=2))
        return 0
    if args.cmd == "link-catalog":
        print(json.dumps(link_catalog(controller, Path(args.catalog)), indent=2))
        return 0
    if args.cmd == "reverify":
        print(json.dumps(reverify_ledger(controller), indent=2))
        return 0
    if args.cmd == "supersede":
        print(json.dumps(supersede_unit(controller, args.id, args.reason, args.actor), indent=2))
        return 0
    if args.cmd == "seed-queue":
        print(json.dumps(seed_queue(controller, plan_root, Path(args.run_queue),
                                    args.batch, args.units, args.max_workers), indent=2))
        return 0
    if args.cmd == "run":
        return cmd_run(args)
    if args.cmd == "status":
        return cmd_status(args)
    if args.cmd == "resume":
        return cmd_resume(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
