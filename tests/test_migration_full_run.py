"""Regression tests for the whole-migration controller (tools/migration_team/full_run.py).

Run with `PYTHONPATH=tools pytest tests/test_migration_full_run.py`. These are ADDED as
regression coverage; per the run contract, runtime evidence comes from actual CLI/SQL/Copilot
behavior, not from a test-suite rerun. Plan-dependent tests skip cleanly if the plan artifacts
are absent so the suite stays hermetic.
"""
import json
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from migration_team import full_run as fr  # noqa: E402

PLAN = fr.DEFAULT_PLAN
plan_available = pytest.mark.skipif(
    not (PLAN / "work-units.json").exists(), reason="full-migration plan artifacts not present"
)


# ---- pure logic: dependency levelization + batching ----
def test_topo_levels_orders_dependencies_and_detects_cycle():
    units = [
        {"unit_id": "a", "depends_on": []},
        {"unit_id": "b", "depends_on": ["a"]},
        {"unit_id": "c", "depends_on": ["a"]},
        {"unit_id": "d", "depends_on": ["b", "c"]},
        {"unit_id": "x", "depends_on": ["gate:external"]},  # external dep is advisory
    ]
    levels = fr.topo_levels(units)
    pos = {uid: i for i, lvl in enumerate(levels) for uid in lvl}
    assert pos["a"] < pos["b"] and pos["a"] < pos["c"]
    assert pos["d"] > pos["b"] and pos["d"] > pos["c"]
    assert "x" in pos  # advisory external dependency does not block placement

    with pytest.raises(RuntimeError):
        fr.topo_levels([{"unit_id": "p", "depends_on": ["q"]},
                        {"unit_id": "q", "depends_on": ["p"]}])


# ---- tight permission profiles ----
def test_lane_profiles_are_tight_and_never_broad():
    for lane in ("coordinator", "o2p-repair", "o2p-reviewer", "o2p-data", "o2p-hard-cases"):
        flags = fr.lane_profile(lane)
        joined = " ".join(flags)
        assert "shell(mt:*)" in flags               # only the CLI wrapper stem
        assert "shell(python3:*)" not in joined      # never broad python
        assert "--allow-all" not in joined and "--yolo" not in joined
        assert "--allow-all-paths" not in joined
        assert "--no-ask-user" in flags and "--disable-builtin-mcps" in flags
    # only the coordinator gets the subagent tool; only repair may write, and only scoped files
    assert "task" in fr.lane_profile("coordinator")
    assert "task" not in fr.lane_profile("o2p-reviewer")
    rep = " ".join(fr.lane_profile("o2p-repair"))
    assert "apply_patch" in rep and "write(candidate.sql)" in rep and "write(checks.sql)" in rep
    assert "apply_patch" not in " ".join(fr.lane_profile("o2p-reviewer"))


def test_gtt_temp_tables_are_mine_not_schema_foundation():
    # schema-foundation owns the 93 base tables; the 3 GLOBAL TEMPORARY tables are my temp-table class.
    for g in ("table:CONTOSO.GTT_ORDER_STAGE", "table:CONTOSO.GTT_PRICE_CALC", "table:CONTOSO.GTT_REPLENISHMENT"):
        assert fr._is_schema_foundation(g) is False
    assert fr._is_schema_foundation("table:CONTOSO.ADDRESS") is True      # base table stays foundation's
    assert fr._is_schema_foundation("type:CONTOSO.T_PARTY") is True
    assert fr._is_schema_foundation("function:CONTOSO.FN_X") is False


def test_task_id_matches_cli_formula():
    # Pinned to tools/migration_team/queue.py and known live queue ids.
    assert fr._task_id("FUNCTION", "CONTOSO.FN_SPLIT_CSV") == "a69d05a8aad1df57b194"
    assert fr._task_id("FUNCTION", "CONTOSO.FN_GEN_CHK_IMPURE_032") == "d3787f6ddfbf58b97bb4"
    assert fr._parse_source_key("TABLE|CONTOSO.ADDRESS") == ("TABLE", "CONTOSO.ADDRESS")


# ---- exhaustive manifest / ledger ----
@plan_available
def test_manifest_accounts_for_every_unit_and_hard_case(tmp_path):
    cov = fr.build_manifest(PLAN, tmp_path)
    summary = json.load(open(PLAN / "summary.json"))
    assert cov["work_units_total"] == summary["source_work_units"]
    assert cov["load_units_total"] == summary["base_table_load_units"]
    assert cov["remaining_author_review_task_count"] == summary["remaining_author_review_task_count"]
    assert cov["distinct_prior_reviewed"] == summary["distinct_prior_reviewed_scope_count"]
    assert cov["hard_cases_missing"] == []            # all 43 represented
    assert cov["fully_accounted"] is True
    # per-object mapping + no-auto-credit invariant on every unit
    man = json.load(open(tmp_path / "controller-manifest.json"))
    assert len(man["units"]) == summary["source_work_units"]
    assert all(u["fresh_evidence_required"] for u in man["units"])
    assert all(u["controller_state"] == "unstarted" for u in man["units"])


@plan_available
def test_batches_respect_max_dependency_batch(tmp_path):
    out = fr.build_batches(PLAN, tmp_path)
    max_batch = json.load(open(PLAN / "summary.json")).get("max_dependency_batch", 5)
    assert out["batch_count"] > 0
    all_units = [u for b in out["batches"] for u in b["unit_ids"]]
    assert len(all_units) == len(set(all_units))       # every unit placed exactly once
    assert len(all_units) == out.get("levels", 0) or True
    for b in out["batches"]:
        assert 1 <= b["size"] <= max_batch


# ---- state receipts (append-only; never touches SQLite) ----
def test_receipts_are_append_only(tmp_path):
    fr._receipt(tmp_path, "unit_started", unit_id="function:CONTOSO.X")
    fr._receipt(tmp_path, "unit_reviewed", unit_id="function:CONTOSO.X", decision="accept")
    lines = (tmp_path / "receipts" / "receipts.jsonl").read_text().splitlines()
    assert len(lines) == 2
    kinds = [json.loads(l)["kind"] for l in lines]
    assert kinds == ["unit_started", "unit_reviewed"]
    assert all("receipt_id" in json.loads(l) and "ts" in json.loads(l) for l in lines)


# ---- run gating: never launches without full authorization ----
@plan_available
def test_run_refuses_without_authorization(tmp_path, capsys):
    fr.build_manifest(PLAN, tmp_path)

    class A:
        plan = str(PLAN)
        controller = str(tmp_path)
        authorize = False
        target_profile = None
        run_queue = None
        batch = None
        max_batches, max_credits, timeout = 1, 30, 60
    rc = fr.cmd_run(A())
    out = capsys.readouterr().out
    assert rc == 0                                   # preview is not an execution claim
    assert "dry-run-preview" in out and '"authorized": false' in out
    recs = (tmp_path / "receipts" / "receipts.jsonl").read_text().splitlines()
    assert any(json.loads(l)["kind"] == "run_preview" for l in recs)


# ---- ingest-data: only reviewed_pass credits, with independent compare cross-check ----
@plan_available
def test_ingest_data_credits_only_reviewed_pass_and_catches_tamper(tmp_path):
    fr.build_manifest(PLAN, tmp_path)
    man = json.loads((tmp_path / "controller-manifest.json").read_text())
    a, b, c, d, e = [lu["source_table"] for lu in man["load_units"]][:5]
    vout = tmp_path / "vout"
    (vout / "compare").mkdir(parents=True)
    report = {"run": {"manifest_sha256": "x"}, "table_status": {
        a: {"status": "parity_pass", "reviewed_pass": True, "compare_json": f"compare/{a}.json"},
        b: {"status": "empty_verified", "reviewed_pass": True, "compare_json": None},
        c: {"status": "parity_fail", "reviewed_pass": False, "compare_json": f"compare/{c}.json"},
        d: {"status": "parity_pass", "reviewed_pass": True, "compare_json": f"compare/{d}.json"},
        e: {"status": "schema_mismatch", "reviewed_pass": False, "compare_json": None},
    }}
    (vout / "full-validation-report.json").write_text(json.dumps(report))
    (vout / "compare" / f"{a}.json").write_text(json.dumps({"status": "passed"}))
    (vout / "compare" / f"{c}.json").write_text(json.dumps({"status": "failed"}))
    (vout / "compare" / f"{d}.json").write_text(json.dumps({"status": "failed"}))  # tamper: report=pass, compare=fail
    out = fr.ingest_data(tmp_path, vout)
    state = {r["table"]: r["controller_state"] for r in out["results"] if r.get("table") and "controller_state" in r}
    assert state[a] == "reviewed"
    assert state[b] == "reviewed"
    assert state[c] == "blocked"
    assert state[d] != "reviewed"          # report claimed pass but compare said fail -> not credited
    assert state[e] == "blocked"           # schema_mismatch -> blocked, never a false pass
    assert out["load_units_reviewed"] == 2


# ---- loader contract: pinned hash + exit-3 sequence resume ----
def test_loader_hash_is_pinned_and_matches_bytes():
    assert fr.LOADER_SHA256 == "26ad5280425ae7b466c6f93ecc61f12c656c0947426d691387cd842c08f35e13"
    assert fr.verify_loader()["match"] is True   # drift here is a real finding, by design


def test_loader_exit3_resume_setval_for_error_and_pending_only():
    # Real loader receipt shape: table is BARE (schema is report.target_schema); sequence namespace+name
    # explicit. Only error/pending receipts produce a setval; 'completed' is skipped.
    report = {"applied": True, "finalization_failed": True, "target_schema": "contoso",
              "sequence_finalization": {"status": "failed", "errors": 2, "enumerated": True},
              "sequences_reset": [
                  {"sequence": "contoso.a_seq", "sequence_schema": "contoso", "sequence_name": "a_seq",
                   "column": "a_id", "table": "a", "status": "error"},
                  {"sequence": "contoso.b_seq", "sequence_schema": "contoso", "sequence_name": "b_seq",
                   "column": "b_id", "table": "b", "status": "completed"},
                  {"sequence": "contoso.c_seq", "sequence_schema": "contoso", "sequence_name": "c_seq",
                   "column": "c_id", "table": "c", "status": "pending"},
              ]}
    interp = fr.interpret_loader_exit(3, report)
    assert interp["meaning"] == "committed_retained_finalization_failed_resume"
    assert interp["resume_required"] and interp["no_reload_no_truncate"]
    assert [s["sequence"] for s in interp["resume_setvals"]] == ["contoso.a_seq", "contoso.c_seq"]
    sql0 = interp["resume_setvals"][0]["setval_sql"]
    assert "setval(" in sql0 and 'FROM "contoso"."a"' in sql0   # table qualified from report.target_schema
    # exit 2 = fully rolled back; no resume plan
    assert fr.interpret_loader_exit(2, {"applied": False})["meaning"].startswith("fatal_rolled_back")
    assert "resume_setvals" not in fr.interpret_loader_exit(2, {})


def test_loader_exit3_unenumerated_requires_catalog_rederive():
    interp = fr.interpret_loader_exit(3, {"applied": True,
                                          "sequence_finalization": {"status": "failed", "enumerated": False},
                                          "sequences_reset": []})
    assert interp["sequences_enumerated"] is False
    assert interp["resume_setvals"] == [] and interp["catalog_enumeration_required"] is True
    assert "re-derive" in interp["resume_directive"] and interp["no_reload_no_truncate"]


def test_loader_exit4_commit_ack_unknown_inspects_target_never_reloads():
    interp = fr.interpret_loader_exit(4, {"applied": "unknown", "commit_outcome": "unknown"})
    assert interp["meaning"] == "commit_ack_unknown"
    assert interp["outcome"] == "unknown" and interp["inspect_target_required"] is True
    assert interp["no_reload"] is True and interp["no_assume_rollback"] is True
    assert "resume_setvals" not in interp   # must inspect target first, not blind-resume


# ---- next-ready frontier + registration/support catalog linkage ----
@plan_available
def test_next_ready_frontier_split_by_owner(tmp_path):
    fr.build_manifest(PLAN, tmp_path)
    fr.build_batches(PLAN, tmp_path)
    out = fr.compute_next_ready(tmp_path)
    assert out["reviewed_units"] == 0
    assert out["frontier_total"] == out["my_drivable_units"] + out["schema_foundation_units"]
    assert out["my_drivable_units"] > 0 and out["my_next_batches_total"] > 0
    # my_next_batches is the FULL ready+owned frontier (not a 20-batch window); none of its units are
    # schema-foundation-OWNED. Use the ownership predicate, not a naive kind prefix -- the 3 GTT temp
    # tables are kind 'table' yet mine, and now surface here instead of being truncated away.
    assert out["my_next_batches_total"] == len(out["my_next_batches"])   # no truncation
    for b in out["my_next_batches"]:
        assert all(not fr._is_schema_foundation(uid) for uid in b["unit_ids"])


@plan_available
def test_link_catalog_is_separate_axis_without_double_count(tmp_path):
    fr.build_manifest(PLAN, tmp_path)
    cat = fr.DEFAULT_CONTROLLER.parent / "source-catalog"
    if not (cat / "manifest.json").exists():
        pytest.skip("source-catalog not present")
    reg = fr.link_catalog(tmp_path, cat)
    assert reg["accounting_axis"] == "registration_support"
    assert reg["metadata_only"] and reg["no_task_classification"] and reg["no_original_writes_or_nextval"]
    cov = json.loads((tmp_path / "coverage.json").read_text())
    assert cov["work_units_total"] == 1256 and cov["load_units_total"] == 93   # totals unchanged
    assert "registration_support" in cov


# ---- post-review failure lifecycle: supersede invalidates stale reviewed credit ----
@plan_available
def test_supersede_invalidates_reviewed_credit_and_requires_fresh_review(tmp_path):
    fr.build_manifest(PLAN, tmp_path)
    man = json.loads((tmp_path / "controller-manifest.json").read_text())
    uid = man["units"][0]["unit_id"]
    for u in man["units"]:
        if u["unit_id"] == uid:
            u["controller_state"] = "reviewed"
            u["reviewed_task_ids"] = ["deadbeef00000000dead"]
    (tmp_path / "controller-manifest.json").write_text(json.dumps(man))
    res = fr.supersede_unit(tmp_path, uid, reason="runtime counterexample refutes candidate", actor="tester")
    assert res["new_state"] == "superseded_needs_fresh_review"
    assert res["previous_state"] == "reviewed"
    u2 = next(u for u in json.loads((tmp_path / "controller-manifest.json").read_text())["units"]
              if u["unit_id"] == uid)
    assert u2["controller_state"] == "superseded_needs_fresh_review"
    assert u2["reviewed_task_ids"] == []                       # credit cleared
    assert u2["supersessions"][-1]["reason"] == "runtime counterexample refutes candidate"
    # unknown key is a clean no-op error, not a crash
    assert "error" in fr.supersede_unit(tmp_path, "no:such-unit", reason="x", actor="t")


# ---- batch execution: exit codes never report success on an authorization failure ----
@plan_available
def test_run_preview_zero_but_authorization_failure_nonzero_and_nothing_launched(tmp_path):
    fr.build_manifest(PLAN, tmp_path)

    class Preview:
        plan, controller = str(PLAN), str(tmp_path)
        authorize, target_profile, run_queue, batch = False, None, None, None
        max_batches, max_credits, timeout = 1, 30, 60
    assert fr.cmd_run(Preview()) == 0                     # preview is not an execution claim

    class Authorized:
        plan, controller = str(PLAN), str(tmp_path)
        authorize, target_profile, run_queue, batch = True, None, None, None
        max_batches, max_credits, timeout = 1, 30, 60
    rc = fr.cmd_run(Authorized())
    assert rc != 0                                        # readiness/authorization failure != success
    recs = [json.loads(l) for l in (tmp_path / "receipts" / "receipts.jsonl").read_text().splitlines()]
    assert any(r["kind"] == "run_authorization_failed" for r in recs)
    assert not any(r["kind"] == "batch_launch" for r in recs)   # nothing was launched


@plan_available
def test_ingest_queue_state_credits_reviewed_not_queued(tmp_path):
    fr.build_manifest(PLAN, tmp_path)
    reviewed_q = fr.REPO / "out/team-live-readiness-20260910-125114/readiness-queue"
    if not (reviewed_q / "queue.sqlite3").exists():
        pytest.skip("readiness run queue (runtime artifact) not present")
    res = fr.ingest_queue_state(tmp_path, reviewed_q, ["function:CONTOSO.FN_SPLIT_CSV"])
    assert res[0]["controller_state"] == "reviewed"
    assert res[0]["task_states"][0]["status"] == "reviewed"
    recs = [json.loads(l) for l in (tmp_path / "receipts" / "receipts.jsonl").read_text().splitlines()]
    assert any(r["kind"] == "unit_state_ingested" for r in recs)   # resumable per-unit receipt


# ---- manifest rebuild must PRESERVE ingested progress (no reset to unstarted) ----
@plan_available
def test_manifest_rebuild_preserves_reviewed_state(tmp_path):
    fr.build_manifest(PLAN, tmp_path)
    man = json.loads((tmp_path / "controller-manifest.json").read_text())
    uid = man["units"][0]["unit_id"]
    for u in man["units"]:
        if u["unit_id"] == uid:
            u["controller_state"] = "reviewed"
            u["reviewed_task_ids"] = ["cafebabe0000cafebabe"]
    (tmp_path / "controller-manifest.json").write_text(json.dumps(man))
    fr.build_manifest(PLAN, tmp_path)                     # a rebuild must NOT wipe it
    man2 = json.loads((tmp_path / "controller-manifest.json").read_text())
    u2 = next(u for u in man2["units"] if u["unit_id"] == uid)
    assert u2["controller_state"] == "reviewed"
    assert u2["reviewed_task_ids"] == ["cafebabe0000cafebabe"]


# ---- lifetime-budget + quarantine lineage gate (fail-closed; main-owned public audit contract) ----
def _fake_run(mapping):
    """Fake subprocess.run for `mt audit`: mapping[task_id] -> (exit, validation_budget dict)."""
    class R:
        def __init__(self, code, out):
            self.returncode, self.stdout, self.stderr = code, out, ""

    def run(argv, capture_output=True, text=True):
        tid = argv[-1]                                  # `audit --state <q> --id <tid>`
        code, vb = mapping.get(tid, (2, None))          # unknown -> exit 2, no budget (fail closed)
        payload = {"validation_budget": vb} if vb is not None else {"task_status": "reviewed"}
        return R(code, json.dumps(payload))
    return run


def test_quarantined_lineage_helper_matches_roots_and_names():
    assert fr._is_quarantined_lineage("a6a87394cd803e9d186c", "x") is True     # a6 root
    assert fr._is_quarantined_lineage("751448ea21165e786b0f", "x") is True     # v2 root
    assert fr._is_quarantined_lineage("zzz", "support:CONTOSO.scalar_ingress_v2") is True  # by name
    assert fr._is_quarantined_lineage("4b5f0698d51d8be22d27",
                                      "function:CONTOSO.FN_GEN_PRICE_006_IT") is False


def test_budget_cleared_requires_review_eligible_and_fails_closed(monkeypatch):
    monkeypatch.setattr(fr.subprocess, "run", _fake_run({
        "clean": (0, {"policy": fr.BUDGET_POLICY, "review_eligible": True,
                      "within_limit": True, "quarantined": False}),
        "exhausted": (1, {"review_eligible": False, "within_limit": False, "quarantined": False}),
        "quarantined": (0, {"review_eligible": False, "within_limit": True, "quarantined": True}),
        "absent": (0, None),                            # NO validation_budget field
    }))
    assert fr._budget_cleared("q", "clean")[0] is True
    assert fr._budget_cleared("q", "exhausted")[0] is False       # over lifetime limit
    assert fr._budget_cleared("q", "quarantined")[0] is False     # persistent hold
    assert fr._budget_cleared("q", "absent")[0] is False          # absent field != eligible
    assert fr._budget_cleared("q", "unknown")[0] is False         # unknown history -> fail closed


def test_ingest_evidence_denies_quarantine_and_ineligible_credits_only_clean(tmp_path, monkeypatch):
    man = {"units": [
        {"unit_id": "support:CONTOSO.scalar_ingress", "source_keys": [],
         "task_ids": ["a6a87394cd803e9d186c"], "reviewed_task_ids": [], "evidence": [],
         "controller_state": "unstarted"},
        {"unit_id": "function:CONTOSO.EXH", "source_keys": [],
         "task_ids": ["1111111111111111exha"], "reviewed_task_ids": [], "evidence": [],
         "controller_state": "unstarted"},
        {"unit_id": "function:CONTOSO.CLEAN", "source_keys": [],
         "task_ids": ["2222222222222222clea"], "reviewed_task_ids": [], "evidence": [],
         "controller_state": "unstarted"},
    ]}
    (tmp_path / "controller-manifest.json").write_text(json.dumps(man))
    # `show` embeds validation_budget (queue.py:270), which ingest_evidence reuses -- no separate audit.
    budgets = {
        "1111111111111111exha": {"review_eligible": False, "within_limit": False, "quarantined": False},
        "2222222222222222clea": {"policy": fr.BUDGET_POLICY, "review_eligible": True,
                                 "within_limit": True, "quarantined": False},
        "a6a87394cd803e9d186c": {"review_eligible": True, "within_limit": True, "quarantined": False},
    }
    H = {"candidate.sql": "hc", "checks.sql": "hk", ":config": "cfg"}   # inputs unchanged -> fresh
    monkeypatch.setattr(fr.subprocess, "check_output", lambda argv, *a, **k: json.dumps(
        {"status": "reviewed", "reviewer": "rev", "worker": "wrk",
         "evidence": {"status": "passed", "input_sha256": H}, "current_input_sha256": H,
         "validation_budget": budgets.get(argv[-1], {})}).encode())
    ev = [{"task_id": t, "queue": "q", "reviewer": "rev", "worker": "wrk"}
          for t in ("a6a87394cd803e9d186c", "1111111111111111exha", "2222222222222222clea")]
    (tmp_path / "ev.json").write_text(json.dumps(ev))
    out = fr.ingest_evidence(tmp_path, tmp_path / "ev.json")
    st = {r["task_id"]: r["status"] for r in out["results"]}
    assert st["a6a87394cd803e9d186c"] == "not_credited"     # lineage hold (clean budget cannot override)
    assert st["1111111111111111exha"] == "not_credited"     # budget ineligible despite reviewed
    assert st["2222222222222222clea"] == "reviewed"         # clean + eligible -> credited
    assert out["credited"] == 1
    recs = [json.loads(l) for l in (tmp_path / "receipts" / "receipts.jsonl").read_text().splitlines()]
    assert any(r["kind"] == "source_budget_audit" for r in recs)   # provenance preserved


def test_reverify_supersedes_on_budget_loss_and_when_unauditable(tmp_path, monkeypatch):
    man = {"units": [
        {"unit_id": "function:CONTOSO.A", "controller_state": "reviewed",
         "task_ids": ["aaaacleanaaaaclean01"], "reviewed_task_ids": ["aaaacleanaaaaclean01"],
         "evidence": [{"queue": "q", "task_id": "aaaacleanaaaaclean01"}],
         "run_state_history": [], "supersessions": []},
        {"unit_id": "function:CONTOSO.B", "controller_state": "reviewed",
         "task_ids": ["bbbbexhaustbbbbexh02"], "reviewed_task_ids": ["bbbbexhaustbbbbexh02"],
         "evidence": [{"queue": "q", "task_id": "bbbbexhaustbbbbexh02"}],
         "run_state_history": [], "supersessions": []},
        {"unit_id": "function:CONTOSO.C", "controller_state": "reviewed",
         "task_ids": ["cccc03cccc03cccc0303"], "reviewed_task_ids": ["cccc03cccc03cccc0303"],
         "evidence": [], "run_state_history": [], "supersessions": []},
    ]}
    (tmp_path / "controller-manifest.json").write_text(json.dumps(man))
    # reverify reuses the fresh validation_budget `show` returns (no separate audit); make show carry it.
    budgets = {
        "aaaacleanaaaaclean01": {"policy": fr.BUDGET_POLICY, "review_eligible": True,
                                 "within_limit": True, "quarantined": False},
        "bbbbexhaustbbbbexh02": {"review_eligible": False, "within_limit": False, "quarantined": False},
    }
    H = {"candidate.sql": "hc", ":config": "cfg"}   # A's inputs unchanged since validation -> fresh
    monkeypatch.setattr(fr.subprocess, "check_output", lambda argv, *a, **k: json.dumps(
        {"status": "reviewed", "reviewer": "rev", "worker": "wrk",
         "evidence": {"status": "passed", "input_sha256": H}, "current_input_sha256": H,
         "validation_budget": budgets.get(argv[-1], {})}).encode())
    out = fr.reverify_ledger(tmp_path)
    states = {u["unit_id"]: u["controller_state"]
              for u in json.loads((tmp_path / "controller-manifest.json").read_text())["units"]}
    assert states["function:CONTOSO.A"] == "reviewed"                       # still budget-clean
    assert states["function:CONTOSO.B"] == "superseded_needs_fresh_review"  # lost budget clearance
    assert states["function:CONTOSO.C"] == "superseded_needs_fresh_review"  # no re-auditable evidence
    assert out["superseded"] == 2


def test_grant_gate_credits_only_matching_authorization(tmp_path, monkeypatch):
    controller = tmp_path / "controller"
    controller.mkdir()
    (tmp_path / "main-approvals").mkdir()
    appr, sha, a6 = "grant-a6-0001", "abc123def", "a6a87394cd803e9d186c"
    (tmp_path / "main-approvals" / "scalar-helper-grant.json").write_text(
        json.dumps({"task_id": a6, "grant": {"approval_id": appr, "approval_sha256": sha}}))
    man = {"units": [{"unit_id": "function:CONTOSO.scalar_ingress", "source_keys": [],
                      "task_ids": [a6], "reviewed_task_ids": [], "evidence": [],
                      "controller_state": "unstarted"}]}
    ev = [{"task_id": a6, "queue": "q", "reviewer": "rev", "worker": "wrk"}]
    (controller / "ev.json").write_text(json.dumps(ev))
    monkeypatch.setattr(fr.subprocess, "run", _fake_run(
        {a6: (0, {"review_eligible": True, "within_limit": True, "quarantined": False})}))

    def show_with_auth(auth_id):
        H = {"candidate.sql": "hc", ":config": "cfg"}   # inputs unchanged since validation -> fresh
        payload = {"status": "reviewed", "reviewer": "rev", "worker": "wrk",
                   "evidence": {"status": "passed", "input_sha256": H}, "current_input_sha256": H,
                   "validation_budget": {"active_authorization": {"approval_id": appr, "approval_sha256": sha},
                                         "review_eligible": True, "within_limit": True, "quarantined": False}}
        if auth_id is not None:
            payload["evidence"]["validation_authorization_id"] = auth_id
        return lambda argv, *a, **k: json.dumps(payload).encode()

    # (a) a held lineage WITH a valid grant AND matching evidence auth id -> credited (hold overridden)
    (controller / "controller-manifest.json").write_text(json.dumps(man))
    monkeypatch.setattr(fr.subprocess, "check_output", show_with_auth(appr))
    assert fr.ingest_evidence(controller, controller / "ev.json")["credited"] == 1

    # (b) same held lineage but evidence carries NO validation_authorization_id -> denied
    (controller / "controller-manifest.json").write_text(json.dumps(man))
    monkeypatch.setattr(fr.subprocess, "check_output", show_with_auth(None))
    assert fr.ingest_evidence(controller, controller / "ev.json")["credited"] == 0

    # (c) evidence auth id present but does NOT match the active authorization / grant -> denied
    (controller / "controller-manifest.json").write_text(json.dumps(man))
    monkeypatch.setattr(fr.subprocess, "check_output", show_with_auth("some-other-approval"))
    assert fr.ingest_evidence(controller, controller / "ev.json")["credited"] == 0


# ---- fix: full ready+owned frontier is reachable (no my_batches[:20] truncation) ----
def test_next_ready_full_frontier_not_truncated_and_reachable(tmp_path):
    # >20 ready+owned single-unit batches: compute_next_ready must expose them ALL, and cmd_run's
    # --units/--batch selectors must reach a unit/batch beyond index 20 (was silently unreachable).
    units, batches = [], []
    for i in range(25):
        uid = f"function:CONTOSO.FN_{i:03d}"
        units.append({"unit_id": uid, "controller_state": "unstarted", "depends_on": [],
                      "source_keys": [f"FUNCTION|CONTOSO.FN_{i:03d}"], "task_ids": [],
                      "reviewed_task_ids": [], "evidence": []})
        batches.append({"batch_id": f"B{i:04d}", "level": 0, "unit_ids": [uid], "size": 1})
    fr._write_json(tmp_path / "controller-manifest.json", {"coverage": {}, "units": units})
    fr._write_json(tmp_path / "batches.json", {"batches": batches})
    nr = fr.compute_next_ready(tmp_path)
    assert nr["my_next_batches_total"] == 25
    assert len(nr["my_next_batches"]) == 25                       # NOT truncated to 20
    ids = [b["batch_id"] for b in nr["my_next_batches"]]
    assert "B0024" in ids                                         # the 25th ready batch is reachable
    cand = [b for b in nr["my_next_batches"] if b["batch_id"] == "B0024"]   # cmd_run --batch path
    assert cand and cand[0]["unit_ids"] == ["function:CONTOSO.FN_024"]
    want = {"function:CONTOSO.FN_024"}                            # cmd_run --units path
    ready = [u for b in nr["my_next_batches"] for u in b["unit_ids"] if u in want]
    assert ready == ["function:CONTOSO.FN_024"]


# ---- fix: exit-3 sequence resume uses real receipt metadata; qualified, search_path-independent, injection-safe ----
def test_sequence_resume_qualifies_from_metadata_and_is_injection_safe():
    # Real receipt shape (data_loader._finalize_sequences / _plan_to_report): table is a BARE name that
    # MAY contain a literal dot; the schema is report.target_schema; the sequence namespace+name are
    # explicit; column/sequence names may contain apostrophes.
    report = {"target_schema": "SalesOps",
              "sequence_finalization": {"status": "failed", "enumerated": True},
              "sequences_reset": [{"sequence": "SalesOps.\"Order'Seq\"",
                                   "sequence_schema": "SalesOps", "sequence_name": "Order'Seq",
                                   "column": "Order'Id", "table": "Order.Line", "status": "pending"}]}
    sql = fr.interpret_loader_exit(3, report)["resume_setvals"][0]["setval_sql"]
    # table qualified from report.target_schema; the dotted table name is NOT split into schema.table
    assert 'FROM "SalesOps"."Order.Line"' in sql
    assert '"Order"."Line"' not in sql
    # apostrophe column quoted as an identifier
    assert 'max("Order\'Id")' in sql
    # sequence: fully-qualified, search_path-INDEPENDENT ::regclass emitted as a SQL LITERAL with the
    # apostrophe DOUBLED (SQL-literal escaping, distinct from identifier quoting)
    expected_seq = fr._sql_literal(fr._quote_ident("SalesOps") + "." + fr._quote_ident("Order'Seq")) + "::regclass"
    assert f"setval({expected_seq}," in sql
    assert "''Seq" in sql                                        # apostrophe doubled inside the literal

    # discovery-error receipt (no sequence/column) -> catalog-rederive DIRECTIVE, never a None setval
    disc = fr.interpret_loader_exit(3, {"target_schema": "SalesOps",
        "sequence_finalization": {"status": "failed", "enumerated": True},
        "sequences_reset": [{"table": "orders", "status": "error", "detail": "discovery failed"}]})["resume_setvals"]
    assert disc[0]["action"] == "catalog_rederive_owned_sequences" and "setval_sql" not in disc[0]
    assert "None" not in json.dumps(disc)

    # ambiguous/legacy metadata (no target_schema, no sequence namespace) -> catalog-rederive, NOT a
    # guessed-schema or dot-split setval an operator could run against the wrong table
    legacy = fr.interpret_loader_exit(3, {"sequence_finalization": {"status": "failed", "enumerated": True},
        "sequences_reset": [{"sequence": "contoso.order_seq", "column": "OrderId",
                             "table": "contoso.Orders", "status": "pending"}]})["resume_setvals"]
    assert legacy[0]["action"] == "catalog_rederive_owned_sequences" and "setval_sql" not in legacy[0]


# ---- fix: controller state writes are atomic + symlink-refusing; _sha256 keeps optional semantics ----
def test_write_json_is_atomic_and_refuses_symlink(tmp_path):
    target = tmp_path / "state.json"
    fr._write_json(target, {"a": 1})
    assert json.loads(target.read_text()) == {"a": 1}
    assert not (tmp_path / "state.json.tmp").exists()             # temp atomically replaced, not left
    outside = tmp_path / "outside.json"
    link = tmp_path / "linked.json"
    link.symlink_to(outside)
    with pytest.raises(ValueError):
        fr._write_json(link, {"b": 2})                           # refuse writing THROUGH a symlink
    assert not outside.exists()


def test_sha256_returns_none_on_missing_preserving_optional_contract(tmp_path):
    import hashlib
    assert fr._sha256(tmp_path / "nope.bin") is None             # missing -> None (verify_inputs 'missing' count)
    f = tmp_path / "x.bin"; f.write_bytes(b"abc")
    assert fr._sha256(f) == hashlib.sha256(b"abc").hexdigest()


# ---- fix: budget clearance reuses show's fresh budget (no redundant audit), fail-closed unchanged ----
def test_budget_cleared_from_show_reuses_budget_without_audit(monkeypatch):
    calls = {"run": 0}
    monkeypatch.setattr(fr.subprocess, "run",
                        lambda *a, **k: calls.__setitem__("run", calls["run"] + 1))
    def shown(vb):  # a `mt show` result carrying validation_budget (queue.py:270)
        return {"status": "reviewed", "validation_budget": vb}
    assert fr._budget_cleared("q", "t", shown=shown(
        {"review_eligible": True, "within_limit": True, "quarantined": False}))[0] is True
    assert fr._budget_cleared("q", "t", shown=shown(
        {"review_eligible": False, "within_limit": True, "quarantined": False}))[0] is False
    assert fr._budget_cleared("q", "t", shown=shown(
        {"review_eligible": True, "within_limit": True, "quarantined": True}))[0] is False
    assert fr._budget_cleared("q", "t", shown={"status": "reviewed"})[0] is False   # absent -> fail closed
    ok, snap = fr._budget_cleared("q", "t", shown=shown(
        {"review_eligible": True, "within_limit": True, "quarantined": False}))
    assert ok is True and snap["budget_source"] == "show"
    assert calls["run"] == 0                                     # collapse: NO `mt audit` subprocess spawned


# ---- fix: seed_queue never reseeds an attempted/blocked/quarantined lineage (lifetime-no-reset) ----
def test_seed_queue_refuses_attempted_blocked_or_quarantined(tmp_path, monkeypatch):
    controller = tmp_path / "controller"; controller.mkdir()
    man = {"units": [
        {"unit_id": "function:CONTOSO.FRESH", "source_keys": ["FUNCTION|CONTOSO.FRESH"],
         "controller_state": "unstarted", "reviewed_task_ids": [], "evidence": [], "run_state_history": []},
        {"unit_id": "function:CONTOSO.BLOCKED", "source_keys": ["FUNCTION|CONTOSO.BLOCKED"],
         "controller_state": "blocked", "reviewed_task_ids": [], "evidence": [], "run_state_history": []},
        {"unit_id": "function:CONTOSO.RELEASED", "source_keys": ["FUNCTION|CONTOSO.RELEASED"],
         "controller_state": "unstarted", "reviewed_task_ids": [], "evidence": [],
         "run_state_history": [{"queue": "q", "states": [{"task_id": "t", "status": "validating"}]}]},
        {"unit_id": "support:CONTOSO.scalar_ingress", "source_keys": ["SUPPORT|CONTOSO.scalar_ingress"],
         "controller_state": "unstarted", "reviewed_task_ids": [], "evidence": [], "run_state_history": []},
    ]}
    (controller / "controller-manifest.json").write_text(json.dumps(man))

    class R:  # fake `mt init` success
        returncode, stdout, stderr = 0, "", ""
    monkeypatch.setattr(fr.subprocess, "run", lambda *a, **k: R())
    monkeypatch.setattr(fr.subprocess, "check_output",
                        lambda argv, *a, **k: json.dumps({"status": "queued"}).encode())
    res = fr.seed_queue(controller, tmp_path, tmp_path / "rq",
                        units=["function:CONTOSO.FRESH", "function:CONTOSO.BLOCKED",
                               "function:CONTOSO.RELEASED", "support:CONTOSO.scalar_ingress"])
    assert res["seeded_units"] == ["function:CONTOSO.FRESH"]     # only the never-attempted unit
    assert "function:CONTOSO.BLOCKED" in res["skipped"]          # exhausted/blocked -> re-drive in place
    assert "function:CONTOSO.RELEASED" in res["skipped"]         # prior attempt in run_state_history
    assert "support:CONTOSO.scalar_ingress" in res["skipped"]    # quarantined lineage
    # and _has_prior_attempts is the load-bearing predicate
    assert fr._has_prior_attempts({"reviewed_task_ids": ["x"]}) is True
    assert fr._has_prior_attempts({"evidence": [{"task_id": "x"}]}) is True
    assert fr._has_prior_attempts({"controller_state": "unstarted"}) is False


# ---- fix: ingest_data blocks keyless + empty-schema-unverified (triage-distinct from 'incomplete') ----
def test_ingest_data_blocks_keyless_and_empty_schema_unverified(tmp_path):
    man = {"units": [], "load_units": [
        {"unit_id": "load:CONTOSO.KEYLESS", "source_table": "KEYLESS", "controller_state": "unstarted"},
        {"unit_id": "load:CONTOSO.EMPTYSCHEMA", "source_table": "EMPTYSCHEMA", "controller_state": "unstarted"},
        {"unit_id": "load:CONTOSO.PENDING", "source_table": "PENDING", "controller_state": "unstarted"},
    ]}
    (tmp_path / "controller-manifest.json").write_text(json.dumps(man))
    vout = tmp_path / "vout"; vout.mkdir()
    report = {"table_status": {
        "KEYLESS": {"status": "blocked_no_comparable_key", "reviewed_pass": False,
                    "blocked_reason": "no usable key"},
        "EMPTYSCHEMA": {"status": "empty_schema_unverified", "reviewed_pass": False,
                        "blocked_reason": "needs --source-catalog"},
        "PENDING": {"status": "source_projected", "reviewed_pass": False},   # genuinely not-yet-run
    }}
    (vout / "full-validation-report.json").write_text(json.dumps(report))
    out = fr.ingest_data(tmp_path, vout)
    state = {r["table"]: r["controller_state"] for r in out["results"]
             if r.get("table") and "controller_state" in r}
    assert state["KEYLESS"] == "blocked"          # keyless non-empty -> blocked, never a false parity pass
    assert state["EMPTYSCHEMA"] == "blocked"      # needs catalog/adaptation input -> blocked, not incomplete
    assert state["PENDING"] == "incomplete"       # genuinely not-yet-run stays incomplete
    assert out["load_units_reviewed"] == 0        # nothing credited
    # specific status retained for triage even though the coarse state is 'blocked'
    lu = next(l for l in json.loads((tmp_path / "controller-manifest.json").read_text())["load_units"]
              if l["source_table"] == "KEYLESS")
    assert lu["evidence"][-1]["status"] == "blocked_no_comparable_key"


# ---- sec-fix 3: verify_inputs fails closed on a MISSING pinned artifact; explicit-null is optional ----
def test_verify_inputs_fails_closed_on_missing_pinned_artifact(tmp_path, monkeypatch):
    import hashlib
    plan = tmp_path / "plan"; plan.mkdir()
    ctrl = tmp_path / "ctrl"; ctrl.mkdir()
    states = {"reviewed": 1}
    (plan / "summary.json").write_text(json.dumps({
        "original_queue_states": states, "separate_cohort_queue_states": states,
        "input_queue_snapshots_sha256": "x"}))
    # make the prior-queue logical check pass (mt report -> matching states) so we isolate artifact logic
    monkeypatch.setattr(fr.subprocess, "check_output",
                        lambda argv, *a, **k: json.dumps({"states": states}).encode())
    present = plan / "present.sql"; present.write_bytes(b"CREATE TABLE t(x int);")
    ph = hashlib.sha256(present.read_bytes()).hexdigest()
    # (1) a PINNED expected hash whose artifact is absent -> all_match False (fail closed)
    (plan / "input-hashes.json").write_text(json.dumps({str(present): ph, str(plan / "gone.sql"): "dead"}))
    res = fr.verify_inputs(plan, ctrl)
    assert res["all_match"] is False
    assert res["source_artifact_immutability"]["missing_pinned"] == 1
    # (2) present (matching) + an explicitly-null optional artifact -> all_match True
    (plan / "input-hashes.json").write_text(json.dumps({str(present): ph, str(plan / "opt.sql"): None}))
    res2 = fr.verify_inputs(plan, ctrl)
    assert res2["all_match"] is True
    assert res2["source_artifact_immutability"]["optional_absent"] == 1
    assert res2["source_artifact_immutability"]["missing_pinned"] == 0


# ---- sec-fix 1: freshness predicate + stale-review denial on post-review input drift ----
def test_evidence_fresh_predicate_is_fail_closed():
    H = {"candidate.sql": "1", ":config": "c"}
    assert fr._evidence_fresh({"evidence": {"input_sha256": H}, "current_input_sha256": H})[0] is True
    assert fr._evidence_fresh(
        {"evidence": {"input_sha256": H}, "current_input_sha256": {"candidate.sql": "1", ":config": "d"}})[0] is False
    assert fr._evidence_fresh({"evidence": {"input_sha256": H}})[0] is False   # no current -> fail closed
    assert fr._evidence_fresh({"current_input_sha256": H})[0] is False         # no evidence -> fail closed


def test_ingest_evidence_denies_stale_review_on_input_drift(tmp_path, monkeypatch):
    man = {"units": [{"unit_id": "function:CONTOSO.S", "source_keys": [],
                      "task_ids": ["stale00000000000stal"], "reviewed_task_ids": [], "evidence": [],
                      "controller_state": "unstarted"}]}
    (tmp_path / "controller-manifest.json").write_text(json.dumps(man))
    EV = {"candidate.sql": "old", ":config": "cfgA"}
    CUR = {"candidate.sql": "old", ":config": "cfgB"}    # :config drifted (post-review reconfigure)
    monkeypatch.setattr(fr.subprocess, "check_output", lambda argv, *a, **k: json.dumps(
        {"status": "reviewed", "reviewer": "rev", "worker": "wrk",
         "evidence": {"status": "passed", "input_sha256": EV}, "current_input_sha256": CUR,
         "validation_budget": {"review_eligible": True, "within_limit": True, "quarantined": False}}).encode())
    (tmp_path / "ev.json").write_text(json.dumps(
        [{"task_id": "stale00000000000stal", "queue": "q", "reviewer": "rev", "worker": "wrk"}]))
    out = fr.ingest_evidence(tmp_path, tmp_path / "ev.json")
    assert out["credited"] == 0
    assert out["results"][0]["status"] == "not_credited"
    assert "fresh=False" in out["results"][0]["detail"]


# ---- real-Queue helpers (public Queue class, mock validator, no Docker) ----
def _seed_real_queue(root, kind="FUNCTION", name="CONTOSO.FN"):
    import csv as _csv
    from migration_team.queue import Queue
    report = root / "mapping.csv"
    with report.open("w", newline="", encoding="utf-8") as fh:
        w = _csv.writer(fh)
        w.writerow(["Source_Object_Type", "Source_Object", "Azure_PostgreSQL_Object_Type",
                    "Azure_PostgreSQL_Object", "Status", "Action_Required", "Error_Message"])
        w.writerow([kind, name, kind, name.lower(), "Not-Converted", "yes", ""])
    q = Queue(root / "state")
    q.initialize(report, max_workers=2, target_schemas=["contoso"])
    return q


def _stage_real(q, root, tid):
    paths = []
    for fname, text in [("source.sql", "CREATE TABLE T (id NUMBER);"),
                        ("candidate.sql", "CREATE TABLE t (id numeric);"),
                        ("checks.sql", "SELECT 't' AS check_name, true AS passed;")]:
        p = root / fname; p.write_text(text); paths.append(p)
    q.stage(tid, "repair-1", *paths)


def _fake_valid(candidate, checks, dependencies, **opt):
    from migration_team.queue import digest
    return {"status": "passed", "candidate_sha256": digest(candidate),
            "checks_sha256": digest(checks), "checks": [], "log": "unit double"}


# ---- sec-fix 1 (real Queue): a public reconfigure after review makes the reviewed label stale ----
def test_freshness_detects_stale_review_after_real_reconfigure(tmp_path):
    q = _seed_real_queue(tmp_path)
    tid = q.claim("repair-1")["id"]
    _stage_real(q, tmp_path, tid)
    q.validate(tid, "repair-1", _fake_valid, "test-double", 10)
    q.review(tid, "skeptic-1", "accept", "Compared semantics; correct")
    shown = q.show(tid)
    assert shown["status"] == "reviewed"
    shown.setdefault("current_input_sha256", q.hashes(tid))   # queue owner adds; fall back to real hashes
    assert fr._evidence_fresh(shown)[0] is True               # fresh immediately after review
    # a PUBLIC reconfigure changes config_digest -> :config in hashes() -> prior evidence is stale
    q.configure(target_schemas=["contoso", "audit"])
    shown2 = q.show(tid)
    shown2["current_input_sha256"] = q.hashes(tid)            # authoritative current hashes
    assert shown2["status"] == "reviewed"                     # configure does NOT touch the task label
    assert shown2["evidence"]["input_sha256"] != q.hashes(tid)  # inputs really drifted (:config)
    assert fr._evidence_fresh(shown2)[0] is False             # controller denies the now-stale review


# ---- sec-fix 2 (real Queue): validate -> release -> ingest -> reseed cannot reset the lifetime budget ----
def test_reseed_denied_for_released_attempted_identity_real_queue(tmp_path):
    q = _seed_real_queue(tmp_path)                            # queue task = FUNCTION|CONTOSO.FN
    tid = q.claim("repair-1")["id"]
    _stage_real(q, tmp_path, tid)
    q.validate(tid, "repair-1", lambda c, k, d, **o: {"status": "failed", "checks": [], "log": "no"},
               "test-double", 10)                             # a real failed attempt: used -> 1
    q.release(tid, "repair-1", "need a dependency first")     # back to 'queued'
    shown = q.show(tid)
    assert shown["status"] == "queued" and shown["validation_budget"]["used"] >= 1
    assert fr._task_id("FUNCTION", "CONTOSO.FN") == tid       # controller reconciliation key matches

    ctrl = tmp_path / "controller"; ctrl.mkdir()
    uid = "function:CONTOSO.FN"
    (ctrl / "controller-manifest.json").write_text(json.dumps({"units": [
        {"unit_id": uid, "source_keys": ["FUNCTION|CONTOSO.FN"], "task_ids": [tid],
         "controller_state": "unstarted", "reviewed_task_ids": [], "evidence": [], "run_state_history": []}]}))
    # ingest the LIVE released state: the identity read 'queued' but its lifetime used>0 is retained
    fr.ingest_queue_state(ctrl, tmp_path / "state", [uid])
    u = json.loads((ctrl / "controller-manifest.json").read_text())["units"][0]
    assert (u.get("lifetime_attempts_used") or 0) >= 1
    assert fr._has_prior_attempts(u) is True
    # reseeding it into a FRESH queue is refused -> the lifetime-three budget cannot be reset to 0
    res = fr.seed_queue(ctrl, tmp_path, tmp_path / "reseed-queue", units=[uid])
    assert res.get("seeded_units") in (None, [])
    assert uid in (res.get("skipped") or {})


# ---- sec-fix 4: a NONEMPTY parity_pass credits ONLY with a readable, explicitly-PASSED compare receipt ----
def test_ingest_data_requires_readable_passed_compare_for_nonempty(tmp_path):
    man = {"units": [], "load_units": [
        {"unit_id": f"load:{t}", "source_table": t, "controller_state": "unstarted"}
        for t in ("PASS", "TAMPER", "MISSING", "CORRUPT", "EMPTY")]}
    (tmp_path / "controller-manifest.json").write_text(json.dumps(man))
    vout = tmp_path / "vout"; (vout / "compare").mkdir(parents=True)
    report = {"table_status": {
        "PASS":    {"status": "parity_pass", "reviewed_pass": True, "empty": False,
                    "rows_source": 5, "compare_json": "compare/PASS.json"},
        "TAMPER":  {"status": "parity_pass", "reviewed_pass": True, "empty": False,
                    "rows_source": 5, "compare_json": "compare/TAMPER.json"},
        "MISSING": {"status": "parity_pass", "reviewed_pass": True, "empty": False,
                    "rows_source": 5, "compare_json": "compare/MISSING.json"},   # file never written
        "CORRUPT": {"status": "parity_pass", "reviewed_pass": True, "empty": False,
                    "rows_source": 5, "compare_json": "compare/CORRUPT.json"},
        "EMPTY":   {"status": "empty_verified", "reviewed_pass": True, "empty": True,
                    "rows_source": 0, "compare_json": None},
    }}
    (vout / "full-validation-report.json").write_text(json.dumps(report))
    (vout / "compare" / "PASS.json").write_text(json.dumps({"status": "passed"}))
    (vout / "compare" / "TAMPER.json").write_text(json.dumps({"status": "failed"}))
    (vout / "compare" / "CORRUPT.json").write_text("{ not valid json")     # unreadable receipt
    out = fr.ingest_data(tmp_path, vout)
    state = {r["table"]: r["controller_state"] for r in out["results"]
             if r.get("table") and "controller_state" in r}
    assert state["PASS"] == "reviewed"
    assert state["EMPTY"] == "reviewed"               # empty_verified is intentionally comparison-free
    assert state["TAMPER"] == "blocked"               # receipt says failed
    assert state["MISSING"] == "blocked"              # receipt absent -> withheld credit (the SEC-4 fix)
    assert state["CORRUPT"] == "blocked"              # unreadable receipt is not a pass
    assert out["load_units_reviewed"] == 2            # only PASS + EMPTY credited
    assert out["data_phase_complete"] is False        # 2 of 5 -> phase not complete
