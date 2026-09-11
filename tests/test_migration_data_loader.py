"""Tests for migration_team.data_loader.

The pure-core tests (decode / identifier / mapping / manifest path / encode)
run anywhere with the standard library.  The integration tests load one real
typed row (numeric, blob, interval, composite, array, json, xml, quoted
mixed-case identifier) into a disposable local PostgreSQL and prove a
check-constraint failure rolls the whole load back.  They are OPT-IN: they run
only when LOADER_IT_DSN names a disposable LOCAL PostgreSQL, never fall back to
the ambient libpq PG* environment, and refuse a non-local DSN before importing
psycopg or connecting -- so the default discovery stays offline even when a
developer's PGHOST points at oracle-lab or the real Azure target.
"""
import base64
import datetime
import hashlib
import json
import os
import unittest
import uuid
from decimal import Decimal
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from migration_team import data_loader as dl  # noqa: E402
from _it_pg_guard import (  # noqa: E402
    GuardContractMixin, bind_local_target, db_available as _db_available)


# --------------------------------------------------------------------------- #
# Fixture helpers                                                              #
# --------------------------------------------------------------------------- #
def write_snapshot(dirpath: Path, tables: dict, *, blockers=None, excluded=None) -> Path:
    """Write JSONL files + a valid manifest.json; return the manifest path.

    ``tables`` maps table name -> {"columns": [colspec...], "rows": [[encoded...]]}.
    """
    manifest = {"schema": "CONTOSO", "observed_scn": "1", "tables": [],
                "excluded": excluded or [], "blockers": blockers or []}
    for name, spec in tables.items():
        payload = "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in spec["rows"])
        raw = payload.encode("utf-8")
        fname = hashlib.sha256(name.encode()).hexdigest()[:20] + ".jsonl"
        (dirpath / fname).write_bytes(raw)
        manifest["tables"].append({
            "table": name, "file": fname, "columns": spec["columns"],
            "rows": len(spec["rows"]), "sha256": hashlib.sha256(raw).hexdigest(),
        })
    mpath = dirpath / "manifest.json"
    mpath.write_text(json.dumps(manifest))
    return mpath


def col(name, typ, **kw):
    base = {"name": name, "type": typ, "type_owner": None, "virtual": "NO", "identity": "NO"}
    base.update(kw)
    return base


# --------------------------------------------------------------------------- #
# Pure-core unit tests                                                         #
# --------------------------------------------------------------------------- #
class DecodeTests(unittest.TestCase):
    def test_scalars_pass_through(self):
        for v in (None, True, 5, "hi", 3.5):
            self.assertEqual(dl.decode_tag(v), v)

    def test_typed_tags(self):
        self.assertEqual(dl.decode_tag({"$decimal": "1.230"}), Decimal("1.230"))
        self.assertEqual(dl.decode_tag({"$float": "1.5"}), 1.5)
        self.assertEqual(dl.decode_tag({"$bytes": base64.b64encode(b"xy").decode()}), b"xy")
        self.assertEqual(dl.decode_tag({"$datetime": "2024-01-02T03:04:05"}),
                         datetime.datetime(2024, 1, 2, 3, 4, 5))
        self.assertEqual(dl.decode_tag({"$interval_ds": {"days": 2, "seconds": 3, "microseconds": 4}}),
                         datetime.timedelta(days=2, seconds=3, microseconds=4))
        self.assertEqual(dl.decode_tag({"$interval_ym": {"years": 1, "months": 2}}),
                         dl.IntervalYM(1, 2))

    def test_nested_object_and_collection(self):
        v = {"$oracle_collection": "T_TAB", "values": [
            {"$oracle_object": "T_O", "attributes": {"A": {"$decimal": "9"}, "B": None}}]}
        out = dl.decode_tag(v)
        self.assertIsInstance(out, dl.OracleCollection)
        obj = out.values[0]
        self.assertIsInstance(obj, dl.OracleObject)
        self.assertEqual(obj.attributes["A"], Decimal("9"))

    def test_unknown_tag_raises(self):
        with self.assertRaises(dl.LoaderError):
            dl.decode_tag({"$mystery": 1})


class IdentifierTests(unittest.TestCase):
    def test_fold(self):
        self.assertEqual(dl.fold_identifier("ADDRESS"), "address")
        self.assertEqual(dl.fold_identifier("MixedCase"), "MixedCase")

    def test_resolve_exact_and_fold(self):
        self.assertEqual(dl.resolve_name("address", ["ADDRESS", "OTHER"]), "ADDRESS")
        self.assertEqual(dl.resolve_name("MixedCase", ["MixedCase", "OTHER"]), "MixedCase")

    def test_ambiguity_requires_mapping(self):
        with self.assertRaises(dl.LoaderError):
            dl.resolve_name("address", ["ADDRESS", "address"])
        # explicit mapping resolves it
        self.assertEqual(dl.resolve_name("address", ["ADDRESS", "address"], explicit="ADDRESS"), "ADDRESS")

    def test_missing_raises(self):
        with self.assertRaises(dl.LoaderError):
            dl.resolve_name("nope", ["ADDRESS"])

    def test_explicit_must_exist(self):
        with self.assertRaises(dl.LoaderError):
            dl.resolve_name("address", ["ADDRESS"], explicit="GHOST")


class EncodeFieldTests(unittest.TestCase):
    def test_numeric_is_lossless_string(self):
        ti = dl.TypeInfo("scalar", "numeric", "N")
        self.assertEqual(dl.encode_field(Decimal("0.10"), ti), "0.10")

    def test_bytea_hex(self):
        ti = dl.TypeInfo("scalar", "bytea", "U")
        self.assertEqual(dl.encode_field(b"\x00\xff", ti), "\\x00ff")

    def test_intervals(self):
        self.assertEqual(dl.encode_field(datetime.timedelta(days=15), dl.TypeInfo("scalar", "interval", "T")),
                         "15 days 0 seconds 0 microseconds")
        self.assertEqual(dl.encode_field(dl.IntervalYM(1, 2), dl.TypeInfo("scalar", "interval", "T")),
                         "1 years 2 months")

    def test_json_text_is_parsed_not_stringified(self):
        ti = dl.TypeInfo("scalar", "jsonb", "U")
        self.assertEqual(dl.encode_field('{"a": [1, 2]}', ti), {"a": [1, 2]})

    def test_json_bad_text_blocks(self):
        with self.assertRaises(dl.MappingBlocker):
            dl.encode_field("not json", dl.TypeInfo("scalar", "jsonb", "U"))

    def test_composite_maps_attributes(self):
        obj = dl.OracleObject("T_CONTACT", {"CONTACT_NAME": "N", "PHONE": "P"})
        ti = dl.TypeInfo("composite", "t_contact", "C", fields=[
            ("contact_name", dl.TypeInfo("scalar", "text", "S")),
            ("phone", dl.TypeInfo("scalar", "text", "S"))])
        self.assertEqual(dl.encode_field(obj, ti), {"contact_name": "N", "phone": "P"})

    def test_array_of_scalars(self):
        coll = dl.OracleCollection("T_VARR", ["A", "B"])
        ti = dl.TypeInfo("array", "_text", "A", element=dl.TypeInfo("scalar", "text", "S"))
        self.assertEqual(dl.encode_field(coll, ti), ["A", "B"])

    def test_domain_unwraps_to_base(self):
        ti = dl.TypeInfo("domain", "postal", "S", base=dl.TypeInfo("scalar", "text", "S"))
        self.assertEqual(dl.encode_field("X", ti), "X")

    def test_object_into_scalar_text_blocks(self):
        obj = dl.OracleObject("T", {"A": 1})
        with self.assertRaises(dl.MappingBlocker):
            dl.encode_field(obj, dl.TypeInfo("scalar", "text", "S"))

    def test_non_finite_float(self):
        ti = dl.TypeInfo("scalar", "float8", "N")
        self.assertEqual(dl.encode_field(float("inf"), ti), "Infinity")


class ManifestValidationTests(unittest.TestCase):
    def test_valid_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = write_snapshot(d, {"ADDRESS": {"columns": [col("ID", "NUMBER")], "rows": [[1], [2]]}})
            chk = dl.validate_manifest(mp)
            self.assertEqual(chk.errors, [])
            self.assertIn("ADDRESS", chk.files)

    def test_hash_mismatch_is_error(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = write_snapshot(d, {"ADDRESS": {"columns": [col("ID", "NUMBER")], "rows": [[1]]}})
            m = json.loads(mp.read_text())
            m["tables"][0]["sha256"] = "0" * 64
            mp.write_text(json.dumps(m))
            chk = dl.validate_manifest(mp)
            self.assertTrue(any(e["kind"] == "file_validation" for e in chk.errors))

    def test_row_count_mismatch_is_error(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = write_snapshot(d, {"ADDRESS": {"columns": [col("ID", "NUMBER")], "rows": [[1]]}})
            m = json.loads(mp.read_text())
            m["tables"][0]["rows"] = 99
            mp.write_text(json.dumps(m))
            chk = dl.validate_manifest(mp)
            self.assertTrue(any(e["kind"] == "file_validation" for e in chk.errors))

    def test_export_blocker_refused(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = write_snapshot(d, {"ADDRESS": {"columns": [col("ID", "NUMBER")], "rows": [[1]]}},
                                blockers=[{"table": "X", "error": "boom"}])
            chk = dl.validate_manifest(mp)
            self.assertTrue(any(e["kind"] == "export_blocker" for e in chk.errors))

    def test_path_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            with self.assertRaises(dl.LoaderError):
                dl._safe_member_path(d, "../evil.jsonl")
            with self.assertRaises(dl.LoaderError):
                dl._safe_member_path(d, "sub/evil.jsonl")

    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "real.jsonl").write_text("[]\n")
            link = d / "link.jsonl"
            try:
                os.symlink(d / "real.jsonl", link)
            except (OSError, NotImplementedError):
                self.skipTest("symlinks unavailable")
            with self.assertRaises(dl.LoaderError):
                dl._safe_member_path(d, "link.jsonl")

    def test_materialized_view_excluded_separately(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = write_snapshot(
                d, {"ADDRESS": {"columns": [col("ID", "NUMBER")], "rows": [[1]]}},
                excluded=[{"table": "MV_SALES", "reasons": ["derived materialized view; refresh after base loading"]},
                          {"table": "GTT_X", "reasons": ["session-scoped temporary table"]}])
            chk = dl.validate_manifest(mp)
            self.assertEqual([e["table"] for e in chk.materialized_views], ["MV_SALES"])
            self.assertEqual([e["table"] for e in chk.excluded], ["GTT_X"])


# --------------------------------------------------------------------------- #
# Integration: real typed load into a disposable local PostgreSQL              #
#                                                                              #
# These tests mutate a real database (CREATE SCHEMA ... / DROP SCHEMA CASCADE), #
# so they are OPT-IN and fail-closed.  The opt-in / disposable-local guard that #
# keeps the advertised-offline default discovery from ever touching a database  #
# lives in tests/_it_pg_guard.py and is shared verbatim with                    #
# test_migration_loader_regressions.py -- see that module for the design.  This #
# class binds via bind_local_target() and proves the guard via GuardContractMixin.#
# --------------------------------------------------------------------------- #


TYPED_COLUMNS = [
    col("ID", "NUMBER", identity="YES"),
    col("PRICE", "NUMBER"),
    col("AMOUNT", "NUMBER"),
    col("IMAGE", "BLOB"),
    col("LEAD_TIME", "INTERVAL DAY(3) TO SECOND(0)"),
    col("REVIEW_INTERVAL", "INTERVAL YEAR(2) TO MONTH"),
    col("PRIMARY_CONTACT", "T_CONTACT", type_owner="CONTOSO"),
    col("BENEFITS", "T_BENEFIT_TAB", type_owner="CONTOSO"),
    col("ATTRIBUTES", "CLOB"),
    col("SPEC_SHEET", "XMLTYPE", type_owner="PUBLIC"),
    col("MixedCase", "VARCHAR2"),
    col("TOTAL", "NUMBER", virtual="YES"),  # generated on target; must be skipped
]

TYPED_ROW = [
    {"$decimal": "42"},                                             # ID (identity, explicit)
    {"$decimal": "19.9900"},                                        # PRICE
    {"$decimal": "3"},                                              # AMOUNT
    {"$bytes": base64.b64encode(b"\x00PNG\xff").decode()},        # IMAGE
    {"$interval_ds": {"days": 15, "seconds": 0, "microseconds": 0}},   # LEAD_TIME
    {"$interval_ym": {"years": 1, "months": 2}},                   # REVIEW_INTERVAL
    {"$oracle_object": "T_CONTACT", "attributes": {                # PRIMARY_CONTACT
        "CONTACT_NAME": "Ελένη Rossi", "PHONE": "+51 100"}},
    {"$oracle_collection": "T_BENEFIT_TAB", "values": [            # BENEFITS
        {"$oracle_object": "T_BENEFIT", "attributes": {"BENEFIT_CODE": "FREE", "BENEFIT_VALUE": {"$decimal": "1"}}},
        {"$oracle_object": "T_BENEFIT", "attributes": {"BENEFIT_CODE": "VIP", "BENEFIT_VALUE": {"$decimal": "2"}}}]},
    '{"colour": "coffee", "weight_kg": 10}',                       # ATTRIBUTES (jsonb)
    "<spec><attr name=\"colour\">coffee</attr></spec>",           # SPEC_SHEET (xml)
    "keepME",                                                       # MixedCase
    {"$decimal": "59.9700"},                                        # TOTAL (ignored; generated)
]

SETUP_SQL = """
CREATE SCHEMA {schema};
CREATE TYPE {schema}.t_contact AS (contact_name text, phone text);
CREATE TYPE {schema}.t_benefit AS (benefit_code text, benefit_value numeric);
CREATE TABLE {schema}.category (id bigint PRIMARY KEY, name text NOT NULL);
CREATE TABLE {schema}.widget (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id      bigint,
    price            numeric(10,4) NOT NULL,
    amount           numeric NOT NULL,
    image            bytea,
    lead_time        interval,
    review_interval  interval,
    primary_contact  {schema}.t_contact,
    benefits         {schema}.t_benefit[],
    attributes       jsonb,
    spec_sheet       xml,
    "MixedCase"      text,
    total            numeric GENERATED ALWAYS AS (price * amount) STORED,
    CONSTRAINT widget_price_ck CHECK (price >= 0)
);
ALTER TABLE {schema}.widget
    ADD CONSTRAINT widget_category_fk FOREIGN KEY (category_id) REFERENCES {schema}.category(id);
CREATE FUNCTION {schema}.touch() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN RETURN NEW; END $$;
CREATE TRIGGER widget_touch BEFORE INSERT ON {schema}.widget
    FOR EACH ROW EXECUTE FUNCTION {schema}.touch();
"""


class IntegrationLoadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # bind_local_target opts-in-or-skips, binds the validated LOCAL DSN into a
        # fully-cleared PG* for the whole class (so dl.main()'s env-only connection
        # reaches it too), and registers env-restore + conn-close cleanups.  We
        # register the schema drop AFTER so LIFO runs drop -> close -> restore, and
        # all fire even if this setUp raises mid-DDL (autocommit makes each
        # statement durable, which would otherwise orphan the schema).
        cls.conn = bind_local_target(cls)
        cls.schema = "loader_it_" + uuid.uuid4().hex[:12]
        cls.addClassCleanup(cls._drop_schema)
        cls.database = cls.conn.execute("SELECT current_database()").fetchone()[0]
        cls.conn.execute(SETUP_SQL.format(schema=cls.schema))
        # a source category so the FK validates
        cls.conn.execute(f"INSERT INTO {cls.schema}.category (id, name) VALUES (7, 'cat')")

    @classmethod
    def _drop_schema(cls):
        cls.conn.execute(f"DROP SCHEMA IF EXISTS {cls.schema} CASCADE")

    def _run(self, rows, apply, extra_cols=None):
        columns = list(TYPED_COLUMNS)
        if extra_cols:
            columns = extra_cols
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = write_snapshot(d, {"WIDGET": {"columns": columns, "rows": rows}})
            report_path = d / "report.json"
            code = dl.main([
                "--manifest", str(mp), "--target-schema", self.schema,
                "--database", self.database, "--apply" if apply else "--report",
                *([] if apply else [str(report_path)]),
                *(["--report", str(report_path)] if apply else []),
            ])
            return code, json.loads(report_path.read_text())

    def test_typed_row_roundtrip(self):
        # include the category_id column so the FK is exercised
        cols = list(TYPED_COLUMNS)
        cols.insert(1, col("CATEGORY_ID", "NUMBER"))
        row = list(TYPED_ROW)
        row.insert(1, {"$decimal": "7"})
        code, report = self._run([row], apply=True, extra_cols=cols)
        self.assertEqual(code, 0, report)
        self.assertTrue(report["applied"], report)

        r = self.conn.execute(
            f'SELECT id, category_id, price, amount, image, lead_time::text, '
            f'review_interval::text, primary_contact::text, benefits::text, '
            f'attributes, spec_sheet::text, "MixedCase", total '
            f"FROM {self.schema}.widget"
        ).fetchone()
        self.assertEqual(r[0], 42)                      # identity preserved
        self.assertEqual(r[1], 7)
        self.assertEqual(r[2], Decimal("19.9900"))
        self.assertEqual(r[3], Decimal("3"))
        self.assertEqual(bytes(r[4]), b"\x00PNG\xff")   # blob
        self.assertEqual(r[5], "15 days")               # interval day-second
        self.assertEqual(r[6], "1 year 2 mons")         # interval year-month
        self.assertIn("Ελένη Rossi", r[7])              # composite, unicode preserved
        self.assertIn("FREE", r[8])                     # array of composite
        self.assertIn("VIP", r[8])
        self.assertEqual(r[9], {"colour": "coffee", "weight_kg": 10})  # jsonb parsed
        self.assertIn("coffee", r[10])                  # xml
        self.assertEqual(r[11], "keepME")               # quoted mixed-case preserved
        self.assertEqual(r[12], Decimal("59.9700"))     # generated = price*amount

        # sequence for the identity column advanced past the source max
        seqrep = {s["column"]: s for s in report["sequences_reset"]}
        self.assertIn("id", seqrep)
        nxt = self.conn.execute(
            f"INSERT INTO {self.schema}.widget (category_id, price, amount) "
            f"VALUES (7, 1, 1) RETURNING id"
        ).fetchone()[0]
        self.assertGreater(nxt, 42)
        # clean up so other tests see an empty table
        self.conn.execute(f"TRUNCATE {self.schema}.widget")

    def test_check_constraint_failure_rolls_back(self):
        cols = list(TYPED_COLUMNS)
        cols.insert(1, col("CATEGORY_ID", "NUMBER"))
        bad = list(TYPED_ROW)
        bad[1] = {"$decimal": "-5"}          # PRICE < 0 violates widget_price_ck
        bad.insert(1, {"$decimal": "7"})     # CATEGORY_ID
        code, report = self._run([bad], apply=True, extra_cols=cols)
        self.assertNotEqual(code, 0)
        self.assertFalse(report.get("applied", False))
        # table stays empty; constraints and trigger remain intact
        n = self.conn.execute(f"SELECT count(*) FROM {self.schema}.widget").fetchone()[0]
        self.assertEqual(n, 0)
        fk = self.conn.execute(
            "SELECT count(*) FROM pg_constraint WHERE conname = 'widget_category_fk'"
        ).fetchone()[0]
        self.assertEqual(fk, 1)
        tg = self.conn.execute(
            "SELECT tgenabled FROM pg_trigger WHERE tgname = 'widget_touch'"
        ).fetchone()[0]
        self.assertEqual(tg, "O")   # trigger restored to enabled

    def test_refuses_when_target_not_empty(self):
        self.conn.execute(
            f"INSERT INTO {self.schema}.widget (category_id, price, amount) VALUES (7, 1, 1)")
        try:
            cols = list(TYPED_COLUMNS)
            cols.insert(1, col("CATEGORY_ID", "NUMBER"))
            row = list(TYPED_ROW)
            row.insert(1, {"$decimal": "7"})
            code, report = self._run([row], apply=True, extra_cols=cols)
            self.assertNotEqual(code, 0)
            self.assertFalse(report.get("applied", False))
            self.assertTrue(any(b.get("kind") == "target_not_empty"
                                for b in report["blockers"]), report["blockers"])
        finally:
            self.conn.execute(f"TRUNCATE {self.schema}.widget")

    def test_plan_only_writes_nothing(self):
        cols = list(TYPED_COLUMNS)
        cols.insert(1, col("CATEGORY_ID", "NUMBER"))
        row = list(TYPED_ROW)
        row.insert(1, {"$decimal": "7"})
        code, report = self._run([row], apply=False, extra_cols=cols)
        self.assertEqual(code, 0, report)
        self.assertEqual(report["mode"], "plan")
        n = self.conn.execute(f"SELECT count(*) FROM {self.schema}.widget").fetchone()[0]
        self.assertEqual(n, 0)
        # generated column reported, not an insert target
        wt = next(t for t in report["tables"] if t["target_table"] == "widget")
        self.assertIn("total", wt["generated_columns"])
        self.assertNotIn("total", [c["target"] for c in wt["insert_columns"]])

    def test_reapply_refuses_under_lock_recheck(self):
        # The under-lock re-check must refuse when the target became non-empty,
        # independently of the plan-time pre-check.  Exercise the helper directly
        # on a separate transaction so the guard, not the pre-check, is what fires.
        dl._load_psycopg()  # ensure the sql module is bound outside a full run()
        self.conn.execute(
            f"INSERT INTO {self.schema}.widget (category_id, price, amount) VALUES (7, 1, 1)")
        other = _db_available()
        self.assertIsNotNone(other)
        try:
            other.autocommit = False
            plans = [type("P", (), {"target_table": "widget"})()]
            existing, refusal = dl._lock_and_recheck_empty(other, self.schema, plans)
            other.rollback()
            self.assertEqual(existing.get("widget"), 1)
            self.assertIsNotNone(refusal)
            self.assertEqual(refusal[0]["kind"], "target_not_empty")
            self.assertIn("under lock", refusal[0]["detail"])
        finally:
            other.close()
            self.conn.execute(f"TRUNCATE {self.schema}.widget")

    def test_deferred_constraint_failure_at_commit_rolls_back(self):
        # A DEFERRABLE INITIALLY DEFERRED unique constraint fails at COMMIT (not at
        # insert time).  A definite server-side abort must be exit 2 (rolled back),
        # NOT the unknown-commit outcome, and the table must be left empty.
        self.conn.execute(
            f"CREATE TABLE {self.schema}.defu (id bigint PRIMARY KEY, grp text, "
            f" CONSTRAINT defu_uq UNIQUE (grp) DEFERRABLE INITIALLY DEFERRED)")
        try:
            cols = [col("ID", "NUMBER"), col("GRP", "VARCHAR2")]
            rows = [[{"$decimal": "1"}, "x"], [{"$decimal": "2"}, "x"]]  # dup grp -> commit fails
            with tempfile.TemporaryDirectory() as d:
                d = Path(d)
                mp = write_snapshot(d, {"DEFU": {"columns": cols, "rows": rows}})
                rp = d / "report.json"
                code = dl.main(["--manifest", str(mp), "--target-schema", self.schema,
                                "--database", self.database, "--apply", "--report", str(rp)])
                report = json.loads(rp.read_text())
            self.assertEqual(code, 2, report)
            self.assertIn("fatal_error", report)
            self.assertNotIn("commit_outcome", report)  # definite abort, not "unknown"
            n = self.conn.execute(f"SELECT count(*) FROM {self.schema}.defu").fetchone()[0]
            self.assertEqual(n, 0)  # fully rolled back
        finally:
            self.conn.execute(f"DROP TABLE IF EXISTS {self.schema}.defu")

    def test_sequence_finalization_failure_retains_data_and_exits_nonzero(self):
        # If setval fails AFTER the rows are committed, the loader must keep the
        # data, report applied=true with an honest error receipt, and exit non-zero
        # -- never claim a rollback.  A capped identity sequence forces the failure.
        self.conn.execute(
            f"CREATE TABLE {self.schema}.capseq ("
            f"  id bigint GENERATED BY DEFAULT AS IDENTITY (MAXVALUE 2) PRIMARY KEY,"
            f"  note text)")
        try:
            cols = [col("ID", "NUMBER"), col("NOTE", "VARCHAR2")]
            rows = [[{"$decimal": str(i)}, f"n{i}"] for i in (1, 2, 3)]  # max 3 > cap 2
            with tempfile.TemporaryDirectory() as d:
                d = Path(d)
                mp = write_snapshot(d, {"CAPSEQ": {"columns": cols, "rows": rows}})
                rp = d / "report.json"
                code = dl.main(["--manifest", str(mp), "--target-schema", self.schema,
                                "--database", self.database, "--apply", "--report", str(rp)])
                report = json.loads(rp.read_text())
            self.assertEqual(code, 3, report)
            self.assertTrue(report["applied"], report)
            self.assertEqual(report["sequence_finalization"]["status"], "failed", report)
            self.assertTrue(any(r.get("status") == "error" for r in report["sequences_reset"]), report)
            n = self.conn.execute(f"SELECT count(*) FROM {self.schema}.capseq").fetchone()[0]
            self.assertEqual(n, 3)  # rows retained despite the finalization failure
        finally:
            self.conn.execute(f"DROP TABLE IF EXISTS {self.schema}.capseq")


# --------------------------------------------------------------------------- #
# build_plan loss-of-column gate (DB-free; hand-built target model)            #
# --------------------------------------------------------------------------- #
def _tcol(name, typname="text", typcat="S", *, generated=False, identity="",
          notnull=False, has_default=False, attnum=1):
    """A TargetColumn backed by a hand-built scalar TypeInfo (no live catalog)."""
    return dl.TargetColumn(
        name=name, typinfo=dl.TypeInfo("scalar", typname, typcat), attnum=attnum,
        generated=generated, identity=identity, notnull=notnull, has_default=has_default,
    )


class _StubIntrospector:
    """Serves a hand-built target model so build_plan needs no live database."""

    def __init__(self, target_table, columns):
        self._oids = {target_table: 1}
        self._columns = columns

    def table_oids(self):
        return dict(self._oids)

    def columns(self, oid):
        return list(self._columns)


class BuildPlanGateTests(unittest.TestCase):
    """The loss-of-column gate must not trust the source virtual=YES flag: Oracle
    reports XMLTYPE and object/nested-table columns as virtual even though they
    store real data (see the genuine PRODUCT snapshot: SPEC_SHEET/ATTRIBUTES are
    virtual=YES but store real data, only MARGIN_PCT is genuinely generated)."""

    def _check(self, tables):
        with tempfile.TemporaryDirectory() as d:
            mp = write_snapshot(Path(d), tables)
            return dl.validate_manifest(mp)

    def _dropped(self, blockers):
        return sorted(b["column"] for b in blockers
                      if b["kind"] == "dropped_source_column")

    def test_stored_virtual_yes_columns_missing_target_block(self):
        # SPEC_SHEET (XMLTYPE) and ATTRIBUTES (nested table) are tagged virtual=YES
        # but hold real data; a target that omits them must block each, not drop it.
        check = self._check({"PRODUCT": {"columns": [
            col("PRODUCT_ID", "NUMBER"),
            col("SPEC_SHEET", "XMLTYPE", type_owner="PUBLIC", virtual="YES"),
            col("ATTRIBUTES", "T_PRODUCT_ATTR_TAB", type_owner="CONTOSO", virtual="YES"),
        ], "rows": [[{"$decimal": "1"}, "<spec/>", None]]}})
        intro = _StubIntrospector("product", [_tcol("product_id", "numeric", "N")])
        plans, blockers = dl.build_plan(intro, check, {})
        self.assertEqual(plans, [])  # table blocked, nothing planned
        self.assertEqual(self._dropped(blockers), ["ATTRIBUTES", "SPEC_SHEET"])

    def test_generated_source_matches_generated_target_not_inserted(self):
        # A genuinely generated source column (MARGIN_PCT) is represented by a
        # target generated column of the same name: never inserted, never dropped.
        check = self._check({"PRODUCT": {"columns": [
            col("UNIT_COST", "NUMBER"),
            col("LIST_PRICE", "NUMBER"),
            col("MARGIN_PCT", "NUMBER", virtual="YES"),
        ], "rows": [[{"$decimal": "1"}, {"$decimal": "2"}, {"$decimal": "50"}]]}})
        intro = _StubIntrospector("product", [
            _tcol("unit_cost", "numeric", "N"),
            _tcol("list_price", "numeric", "N"),
            _tcol("margin_pct", "numeric", "N", generated=True),
        ])
        plans, blockers = dl.build_plan(intro, check, {})
        self.assertEqual(self._dropped(blockers), [])
        self.assertEqual(len(plans), 1)
        p = plans[0]
        self.assertEqual(p.generated_columns, ["margin_pct"])
        self.assertNotIn("margin_pct", [c.target for c in p.insert_columns])
        self.assertEqual(sorted(c.source for c in p.insert_columns),
                         ["LIST_PRICE", "UNIT_COST"])

    def test_ambiguous_generated_match_not_silently_accepted(self):
        # Two source columns fold-match the target generated column ambiguously;
        # neither may be silently treated as represented -- the ambiguity is
        # surfaced and both source columns still block.
        check = self._check({"PRODUCT": {"columns": [
            col("TOTAL", "NUMBER", virtual="YES"),
            col("total", "NUMBER", virtual="YES"),
        ], "rows": [[{"$decimal": "1"}, {"$decimal": "2"}]]}})
        intro = _StubIntrospector("product", [_tcol("total", "numeric", "N", generated=True)])
        plans, blockers = dl.build_plan(intro, check, {})
        self.assertEqual(plans, [])
        self.assertIn("ambiguous_generated_source", {b["kind"] for b in blockers})
        self.assertEqual(self._dropped(blockers), ["TOTAL", "total"])

    def test_invalid_explicit_mapping_on_generated_blocks(self):
        # An explicit mapping onto a generated column that names a non-existent
        # source is a real operator error and must block -- it must not pass
        # silently just because the source column is flagged elsewhere.
        check = self._check({"PRODUCT": {"columns": [
            col("UNIT_COST", "NUMBER"),
            col("LIST_PRICE", "NUMBER"),
            col("MARGIN_PCT", "NUMBER", virtual="YES"),
        ], "rows": [[{"$decimal": "1"}, {"$decimal": "2"}, {"$decimal": "50"}]]}})
        intro = _StubIntrospector("product", [
            _tcol("unit_cost", "numeric", "N"),
            _tcol("list_price", "numeric", "N"),
            _tcol("margin_pct", "numeric", "N", generated=True),
        ])
        mapping = {"tables": {"product": {"columns": {"margin_pct": "NO_SUCH_SOURCE"}}}}
        plans, blockers = dl.build_plan(intro, check, mapping)
        self.assertEqual(plans, [])
        self.assertIn("invalid_generated_mapping", {b["kind"] for b in blockers})

    def test_target_only_generated_column_allowed(self):
        # A generated target column with no source counterpart and no explicit
        # mapping is legitimate: it represents nothing, is never inserted, and
        # must NOT block the load.
        check = self._check({"PRODUCT": {"columns": [
            col("LIST_PRICE", "NUMBER"),
        ], "rows": [[{"$decimal": "10"}]]}})
        intro = _StubIntrospector("product", [
            _tcol("list_price", "numeric", "N"),
            _tcol("price_with_tax", "numeric", "N", generated=True),
        ])
        plans, blockers = dl.build_plan(intro, check, {})
        self.assertEqual(blockers, [])
        self.assertEqual(len(plans), 1)
        self.assertEqual(plans[0].generated_columns, ["price_with_tax"])
        self.assertNotIn("price_with_tax", [c.target for c in plans[0].insert_columns])


# --------------------------------------------------------------------------- #
# Post-commit safety (DB-free): commit-ack classification + fail-safe finalize #
# --------------------------------------------------------------------------- #
class _FakeExc(Exception):
    def __init__(self, sqlstate=None):
        super().__init__(sqlstate or "boom")
        self.sqlstate = sqlstate


class _FakeCursor:
    def __init__(self, fail):
        self._fail = fail

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, *a, **k):
        if self._fail:
            raise _FakeExc("08006")  # connection failure while discovering sequences

    def fetchall(self):
        return []

    def fetchone(self):
        return [None]


class _FakeConn:
    def __init__(self, fail=False, closed=False):
        self._fail = fail
        self.closed = closed

    def cursor(self):
        return _FakeCursor(self._fail)


class PostCommitSafetyTests(unittest.TestCase):
    def test_lost_commit_ack_classification(self):
        open_conn = _FakeConn()
        # connection-class error (SQLSTATE 08xxx) -> outcome unknown
        self.assertTrue(dl._is_lost_commit_ack(_FakeExc("08006"), open_conn))
        # a definite server-side abort (e.g. deferred unique, class 23) -> known rollback
        self.assertFalse(dl._is_lost_commit_ack(_FakeExc("23505"), open_conn))
        # an already-closed connection -> unknown regardless of sqlstate
        self.assertTrue(dl._is_lost_commit_ack(_FakeExc("23505"), _FakeConn(closed=True)))
        # no sqlstate, connection open -> treated as a definite (non-connection) error
        self.assertFalse(dl._is_lost_commit_ack(_FakeExc(None), open_conn))

    def test_finalize_sequences_discovery_failure_is_error_receipt(self):
        # A post-commit discovery failure (connection drop) must NOT raise: it is
        # recorded as an error receipt with an overall "failed" status, so the
        # caller can report applied=true / exit 3 rather than crashing.
        plan = type("P", (), {"oid": 1, "target_table": "t"})()
        out = dl._finalize_sequences(_FakeConn(fail=True), "s", [plan])
        self.assertEqual(out["status"], "failed")
        self.assertEqual(out["errors"], 1)
        self.assertEqual(out["receipts"][0]["status"], "error")
        self.assertIn("discovery", out["receipts"][0]["detail"])


# --------------------------------------------------------------------------- #
# Opt-in / disposable-local guard contract (DB-free)                           #
#                                                                              #
# The shared guard in tests/_it_pg_guard.py is proved here via GuardContractMixin #
# (the identical suite runs in test_migration_loader_regressions.py).  It shows  #
# the default discovery cannot touch a database: no opt-in / remote host or      #
# hostaddr / multi-host / service / unsupported key all return None WITHOUT      #
# connecting, and an accepted DSN binds only explicit LOCAL params into a fully  #
# cleared PG*.  A fake psycopg (fake conninfo + raising connect) stands in, so   #
# no real database is used and the suite runs even without psycopg installed.    #
# --------------------------------------------------------------------------- #
class IntegrationGuardTests(GuardContractMixin, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()
