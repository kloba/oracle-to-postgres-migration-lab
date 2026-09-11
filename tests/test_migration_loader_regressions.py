"""Regression tests for the data_loader.py fixes owned by verify-loader-findings.

These lock in the loader defect fixes with attempted-refutation intent:

  * exact wide-Decimal fidelity through json/jsonb (never float-coerced);
  * the JSON ``null`` VALUE vs SQL NULL vs a nested null are all distinct;
  * non-null verification counts a JSON null value as present (no false abort);
  * a fractional NUMBER maps to bool by non-zero semantics, never int() truncation;
  * a malformed manifest entry becomes a structured blocker, never a bare KeyError;
  * the manifest/mapping are decoded as UTF-8 even under a non-UTF-8 locale;
  * the dead helper is gone and the identifier fold rule has a single home;
  * a post-commit sequence-discovery failure flips the enumerated/completeness flag.

The DB-backed fidelity tests are OPT-IN and fail-closed: they require
``LOADER_IT_DSN`` to name a disposable LOCAL PostgreSQL, validate that it is a
loopback/local target BEFORE importing psycopg or opening a socket, bind the
validated params into PG* for the loader's own env-only connection, and never
fall back to the ambient libpq environment.  The pure-core tests run anywhere.
"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
import uuid
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from migration_team import data_loader as dl  # noqa: E402
from _it_pg_guard import GuardContractMixin, bind_local_target  # noqa: E402


# --------------------------------------------------------------------------- #
# Fixture helpers                                                             #
# --------------------------------------------------------------------------- #
def _col(name, typ, **kw):
    base = {"name": name, "type": typ, "type_owner": None, "virtual": "NO", "identity": "NO"}
    base.update(kw)
    return base


def _write_snapshot(dirpath: Path, tables: dict) -> Path:
    """Write JSONL files + a valid manifest.json; return the manifest path."""
    import hashlib
    manifest = {"schema": "CONTOSO", "observed_scn": "1", "tables": [],
                "excluded": [], "blockers": []}
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
    mpath.write_text(json.dumps(manifest), encoding="utf-8")
    return mpath


# --------------------------------------------------------------------------- #
# Pure-core: fractional bool (non-zero semantics, never int() truncation)      #
# --------------------------------------------------------------------------- #
class FractionalBoolTests(unittest.TestCase):
    def _b(self, value):
        return dl.encode_field(value, dl.TypeInfo("scalar", "bool", "B"))

    def test_fractional_decimal_is_nonzero_true_not_truncated_false(self):
        # The old code did int(value) != 0, silently turning 0.5 into "false".
        self.assertEqual(self._b(Decimal("0.5")), "true")
        self.assertEqual(self._b(Decimal("-0.5")), "true")
        self.assertEqual(self._b(Decimal("0.0000001")), "true")

    def test_zero_and_integers_and_bools(self):
        self.assertEqual(self._b(Decimal("0")), "false")
        self.assertEqual(self._b(0), "false")
        self.assertEqual(self._b(1), "true")
        self.assertEqual(self._b(2), "true")
        self.assertEqual(self._b(0.5), "true")   # float, also non-zero
        self.assertEqual(self._b(True), "true")
        self.assertEqual(self._b(False), "false")


# --------------------------------------------------------------------------- #
# Pure-core: malformed manifest -> structured blocker (no bare KeyError)        #
# --------------------------------------------------------------------------- #
class MalformedManifestTests(unittest.TestCase):
    def _validate(self, entry):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "data.jsonl").write_text("[]\n", encoding="utf-8")
            (d / "manifest.json").write_text(json.dumps({"tables": [entry]}), encoding="utf-8")
            return dl.validate_manifest(d / "manifest.json")

    def test_missing_table_key_is_structured_blocker_not_keyerror(self):
        chk = self._validate({"file": "data.jsonl", "sha256": "x", "rows": 0})
        kinds = [e["kind"] for e in chk.errors]
        self.assertIn("file_validation", kinds)
        err = next(e for e in chk.errors if e["kind"] == "file_validation")
        self.assertEqual(err["table"], "<unknown>")

    def test_missing_file_key_still_blocker(self):
        chk = self._validate({"table": "T", "sha256": "x", "rows": 0})
        self.assertTrue(any(e["kind"] == "file_validation" and e["table"] == "T"
                            for e in chk.errors))


# --------------------------------------------------------------------------- #
# Pure-core: manifest decoded as UTF-8 even under a non-UTF-8 process locale    #
# --------------------------------------------------------------------------- #
class Utf8ManifestTests(unittest.TestCase):
    def test_non_ascii_manifest_validates_in_process(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = _write_snapshot(d, {"café": {"columns": [_col("ID", "NUMBER")],
                                                   "rows": [[1]]}})
            chk = dl.validate_manifest(mp)
            self.assertEqual(chk.errors, [])
            self.assertIn("café", chk.files)

    def test_non_ascii_manifest_under_c_locale_does_not_crash(self):
        # Under LC_ALL=C the old read_text() (locale default) raised
        # UnicodeDecodeError; the explicit encoding='utf-8' must survive it.
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = _write_snapshot(d, {"café": {"columns": [_col("ID", "NUMBER")],
                                                   "rows": [[1]]}})
            script = textwrap.dedent(f"""
                import sys
                sys.path.insert(0, {str(Path(dl.__file__).resolve().parents[1])!r})
                from migration_team import data_loader as dl
                chk = dl.validate_manifest({str(mp)!r})
                assert chk.errors == [], chk.errors
                print("OK")
            """)
            env = dict(os.environ, LC_ALL="C", LANG="C", PYTHONUTF8="0",
                       PYTHONCOERCECLOCALE="0")
            env.pop("PYTHONIOENCODING", None)
            proc = subprocess.run([sys.executable, "-c", script], env=env,
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("OK", proc.stdout)


# --------------------------------------------------------------------------- #
# Pure-core: json encoding fidelity (exact Decimal, JSON-null sentinel)         #
# --------------------------------------------------------------------------- #
class JsonEncodeUnitTests(unittest.TestCase):
    def setUp(self):
        self.ti = dl.TypeInfo("scalar", "jsonb", "U")

    def test_json_literal_null_yields_sentinel_not_none(self):
        self.assertIs(dl.encode_field("null", self.ti), dl.JSON_NULL)

    def test_source_sql_null_is_none(self):
        self.assertIsNone(dl.encode_field(None, self.ti))

    def test_nested_null_preserved_as_python_none(self):
        self.assertEqual(dl.encode_field('{"a": null}', self.ti), {"a": None})

    def test_wide_source_number_stays_exact_decimal(self):
        wide = "12345678901234567890.123456789"
        out = dl.encode_field('{"n": %s}' % wide, self.ti)
        self.assertIsInstance(out["n"], Decimal)
        self.assertEqual(str(out["n"]), wide)

    def test_oracle_object_decimal_attr_stays_exact_decimal(self):
        wide = Decimal("12345678901234567890.123456789")
        obj = dl.OracleObject("T_SPEC", {"WIDTH": wide})
        out = dl.encode_field(obj, self.ti)
        self.assertIsInstance(out["WIDTH"], Decimal)
        self.assertEqual(out["WIDTH"], wide)

    def test_dumps_batch_renders_decimal_as_exact_bare_number(self):
        wide = "12345678901234567890.123456789"
        text = dl._dumps_batch([{"n": Decimal(wide)}])
        self.assertIn(wide, text)                       # exact digits present
        self.assertNotIn('"%s"' % wide, text)           # NOT quoted -> a JSON number
        self.assertEqual(json.loads(text, parse_float=Decimal)[0]["n"], Decimal(wide))

    def test_dumps_batch_wrapped_json_null_is_bare_null(self):
        text = dl._dumps_batch([{"payload": {dl._JSON_WRAP_KEY: None}}])
        self.assertEqual(json.loads(text)[0]["payload"], {dl._JSON_WRAP_KEY: None})
        self.assertNotIn('"null"', text)                # a JSON null, never the string "null"

    def test_dumps_batch_folds_nested_json_null_sentinel(self):
        # A JSON_NULL sentinel can arrive nested inside a composite/array value;
        # it must serialize as a bare null, never leak to json.dumps and crash.
        text = dl._dumps_batch([{"c": {"a": dl.JSON_NULL, "b": [dl.JSON_NULL, 1]}}])
        self.assertEqual(json.loads(text)[0]["c"], {"a": None, "b": [None, 1]})

    def test_dumps_batch_rejects_non_finite_decimal(self):
        with self.assertRaises(dl.MappingBlocker):
            dl._dumps_batch([{"n": Decimal("NaN")}])


# --------------------------------------------------------------------------- #
# Pure-core: identifier fold rule single-homed; dead helper removed             #
# --------------------------------------------------------------------------- #
class IdentifierAndDeadCodeTests(unittest.TestCase):
    def test_matches_still_implements_documented_rule_via_fold(self):
        self.assertTrue(hasattr(dl, "fold_identifier"))
        for s in ("ABC", "abc", "MixedCase", "mixedcase", "A_b"):
            for t in ("abc", "ABC", "MixedCase", "mixedcase", "a_b"):
                expected = (s == t) or (s.isupper() and s.lower() == t)
                self.assertEqual(dl._matches(s, t), expected, (s, t))

    def test_dead_rowcount_helper_removed(self):
        self.assertFalse(hasattr(dl.Introspector, "table_rowcount_nonzero"))


# --------------------------------------------------------------------------- #
# Pure-core: post-commit sequence discovery completeness flag                   #
# --------------------------------------------------------------------------- #
class _FailDiscoveryCursor:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, sql, params=None):
        if "pg_depend" in str(sql):
            raise RuntimeError("permission denied for table pg_depend")
        raise AssertionError("setval must not run after a discovery failure")

    def fetchall(self):
        return []

    def fetchone(self):
        return [None]


class _FailDiscoveryConn:
    closed = False

    def cursor(self):
        return _FailDiscoveryCursor()


class SequenceDiscoveryCompletenessTests(unittest.TestCase):
    def test_discovery_failure_marks_incomplete_and_receipt_has_no_seq(self):
        plan = type("P", (), {"oid": 1, "target_table": "t"})()
        out = dl._finalize_sequences(_FailDiscoveryConn(), "s", [plan])
        self.assertEqual(out["status"], "failed")
        self.assertFalse(out["discovery_complete"])   # the fix: not a complete enumeration
        r = out["receipts"][0]
        self.assertEqual(r["status"], "error")
        self.assertNotIn("sequence", r)
        self.assertNotIn("column", r)

    def test_no_owned_sequences_is_complete(self):
        class _OkCursor(_FailDiscoveryCursor):
            def execute(self, sql, params=None):
                return None            # discovery succeeds, returns no rows
        class _OkConn:
            closed = False
            def cursor(self):
                return _OkCursor()
        plan = type("P", (), {"oid": 1, "target_table": "t"})()
        out = dl._finalize_sequences(_OkConn(), "s", [plan])
        self.assertEqual(out["status"], "ok")
        self.assertTrue(out["discovery_complete"])


# --------------------------------------------------------------------------- #
# Opt-in DB fidelity: real json/jsonb round-trips on a disposable LOCAL PG      #
#                                                                              #
# The opt-in / disposable-local guard is the shared hardened one in            #
# tests/_it_pg_guard.py (bind_local_target); see that module for the design.   #
# GuardContractTests at the end runs its DB-free contract in THIS module too.   #
# --------------------------------------------------------------------------- #


class JsonFidelityIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # bind_local_target opts-in-or-skips, validates the DSN is a disposable
        # LOCAL target, binds it into a fully-cleared PG* for the whole class (so
        # dl.main()'s env-only connection reaches it too), and registers the
        # env-restore + conn-close cleanups.  The schema drop is registered AFTER,
        # so LIFO runs drop -> close -> restore even if setUp raises mid-DDL.
        cls.conn = bind_local_target(cls)
        cls.database = cls.conn.execute("SELECT current_database()").fetchone()[0]
        cls.schema = "loader_reg_" + uuid.uuid4().hex[:12]
        cls.addClassCleanup(cls._drop_schema)
        cls.conn.execute(f"CREATE SCHEMA {cls.schema}")
        cls.conn.execute(f"CREATE TABLE {cls.schema}.probe_dec (id bigint, payload jsonb)")
        cls.conn.execute(f"CREATE TABLE {cls.schema}.probe_txt (id bigint, payload jsonb)")
        cls.conn.execute(f"CREATE TABLE {cls.schema}.probe_jn (id bigint, payload jsonb)")
        cls.conn.execute(f"CREATE TABLE {cls.schema}.probe_bool (id bigint, flag boolean)")
        # nested json inside a composite target column
        cls.conn.execute(f"CREATE TYPE {cls.schema}.t_wrap AS (payload jsonb, label text)")
        cls.conn.execute(f"CREATE TABLE {cls.schema}.probe_comp (id bigint, spec {cls.schema}.t_wrap)")
        # json array target column
        cls.conn.execute(f"CREATE TABLE {cls.schema}.probe_arr (id bigint, tags jsonb[])")
        # a DOMAIN over jsonb with a CHECK that inspects the VALUE's shape
        cls.conn.execute(
            f"CREATE DOMAIN {cls.schema}.jnum AS jsonb CHECK (jsonb_typeof(VALUE) = 'number')")
        cls.conn.execute(f"CREATE TABLE {cls.schema}.probe_dom (id bigint, payload {cls.schema}.jnum)")
        # identity sequence: exercises the finalization receipt metadata
        cls.conn.execute(f"CREATE TABLE {cls.schema}.probe_seq "
                         f"(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, note text)")

    @classmethod
    def _drop_schema(cls):
        cls.conn.execute(f"DROP SCHEMA IF EXISTS {cls.schema} CASCADE")

    def _load(self, table, columns, rows):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            mp = _write_snapshot(d, {table: {"columns": columns, "rows": rows}})
            rp = d / "report.json"
            code = dl.main(["--manifest", str(mp), "--target-schema", self.schema,
                            "--database", self.database, "--apply", "--report", str(rp)])
            return code, json.loads(rp.read_text(encoding="utf-8"))

    def test_wide_decimal_in_oracle_object_preserved_exactly(self):
        wide = "12345678901234567890.123456789"
        cols = [_col("ID", "NUMBER"), _col("PAYLOAD", "T_SPEC", type_owner="CONTOSO")]
        row = [1, {"$oracle_object": "T_SPEC", "attributes": {"WIDTH": {"$decimal": wide}}}]
        code, rep = self._load("PROBE_DEC", cols, [row])
        self.assertEqual(code, 0, rep)
        self.assertTrue(rep["applied"], rep)
        got = self.conn.execute(
            f"SELECT (payload->'WIDTH')::text FROM {self.schema}.probe_dec").fetchone()[0]
        self.assertEqual(got, wide)   # exact arbitrary-precision numeric, no float rounding

    def test_wide_decimal_in_source_json_text_preserved_exactly(self):
        wide = "98765432109876543210.987654321"
        cols = [_col("ID", "NUMBER"), _col("PAYLOAD", "CLOB")]
        row = [1, '{"n": %s}' % wide]
        code, rep = self._load("PROBE_TXT", cols, [row])
        self.assertEqual(code, 0, rep)
        got = self.conn.execute(
            f"SELECT (payload->'n')::text FROM {self.schema}.probe_txt").fetchone()[0]
        self.assertEqual(got, wide)

    def test_json_null_vs_sql_null_vs_nested_null(self):
        cols = [_col("ID", "NUMBER"), _col("PAYLOAD", "CLOB")]
        rows = [[1, None], [2, "null"], [3, '{"a": null}']]
        code, rep = self._load("PROBE_JN", cols, rows)
        self.assertEqual(code, 0, rep)
        self.assertTrue(rep["applied"], rep)
        got = {r[0]: r for r in self.conn.execute(
            f"SELECT id, payload IS NULL, "
            f"  CASE WHEN payload IS NOT NULL THEN jsonb_typeof(payload) END, payload::text "
            f"FROM {self.schema}.probe_jn ORDER BY id").fetchall()}
        # id1: source SQL NULL -> SQL NULL
        self.assertTrue(got[1][1])
        # id2: JSON null VALUE -> jsonb 'null', NOT SQL NULL (the fidelity fix)
        self.assertFalse(got[2][1])
        self.assertEqual(got[2][2], "null")
        # id3: nested null preserved inside the object
        self.assertFalse(got[3][1])
        self.assertEqual(got[3][3], '{"a": null}')
        # all three rows present: the non-null verify must not have aborted
        n = self.conn.execute(f"SELECT count(*) FROM {self.schema}.probe_jn").fetchone()[0]
        self.assertEqual(n, 3)

    def test_fractional_number_into_bool_is_true(self):
        cols = [_col("ID", "NUMBER"), _col("FLAG", "NUMBER")]
        code, rep = self._load("PROBE_BOOL", cols, [[1, {"$decimal": "0.5"}]])
        self.assertEqual(code, 0, rep)
        flag = self.conn.execute(f"SELECT flag FROM {self.schema}.probe_bool").fetchone()[0]
        self.assertIs(flag, True)   # non-zero -> true, never truncated to false

    def test_nested_json_in_composite_faithful_null_and_exact(self):
        # A jsonb attribute inside a composite must preserve the JSON null VALUE
        # (jsonb 'null') distinct from a SQL NULL attribute, keep wide numbers
        # exact, and distinguish a SQL-NULL composite from a non-null all-null one.
        wide = "12345678901234567890.123456789"
        cols = [_col("ID", "NUMBER"), _col("SPEC", "T_WRAP", type_owner="CONTOSO")]

        def obj(payload, label):
            return {"$oracle_object": "T_WRAP", "attributes": {"PAYLOAD": payload, "LABEL": label}}
        rows = [
            [1, obj("null", "a")],               # JSON null VALUE attribute
            [2, obj(None, "b")],                 # SQL NULL attribute
            [3, obj('{"n": %s}' % wide, "c")],   # exact wide number attribute
            [4, None],                           # whole composite SQL NULL
            [5, obj(None, None)],                # non-null composite, all fields NULL
        ]
        code, rep = self._load("PROBE_COMP", cols, rows)
        self.assertEqual(code, 0, rep)
        self.assertTrue(rep["applied"], rep)
        got = {r[0]: r for r in self.conn.execute(
            f"SELECT id, spec::text IS NULL, (spec).payload IS NULL, "
            f"  CASE WHEN (spec).payload IS NOT NULL THEN jsonb_typeof((spec).payload) END, "
            f"  ((spec).payload->'n')::text, (spec).label "
            f"FROM {self.schema}.probe_comp ORDER BY id").fetchall()}
        # id1: JSON null VALUE attribute -> jsonb 'null', NOT SQL NULL
        self.assertFalse(got[1][2]); self.assertEqual(got[1][3], "null")
        # id2: SQL NULL attribute
        self.assertTrue(got[2][2]); self.assertEqual(got[2][5], "b")
        # id3: exact wide number attribute
        self.assertEqual(got[3][4], wide)
        # id4: whole composite is SQL NULL (spec::text is NULL only for a true NULL row)
        self.assertTrue(got[4][1])
        # id5: non-null composite with all-NULL fields -- distinct from a NULL row
        # (row IS NULL is true when all fields null, so observe via spec::text)
        self.assertFalse(got[5][1]); self.assertTrue(got[5][2]); self.assertIsNone(got[5][5])

    def test_nested_json_in_array_faithful_null_and_exact(self):
        # Array of jsonb: a JSON null VALUE element stays jsonb 'null'; a SQL NULL
        # element stays SQL NULL; wide numbers stay exact; order preserved.
        wide = "98765432109876543210.987654321"
        cols = [_col("ID", "NUMBER"), _col("TAGS", "T_TAGS", type_owner="CONTOSO")]
        rows = [[1, {"$oracle_collection": "T_TAGS",
                     "values": [wide, "null", None, '{"a": 1}']}]]
        code, rep = self._load("PROBE_ARR", cols, rows)
        self.assertEqual(code, 0, rep)
        r = self.conn.execute(
            f"SELECT array_length(tags, 1), (tags[1])::text, jsonb_typeof(tags[2]), "
            f"  tags[3] IS NULL, (tags[4])::text "
            f"FROM {self.schema}.probe_arr").fetchone()
        self.assertEqual(r[0], 4)
        self.assertEqual(r[1], wide)        # exact number element
        self.assertEqual(r[2], "null")      # JSON null VALUE element -> jsonb 'null'
        self.assertTrue(r[3])               # SQL NULL element stays SQL NULL
        self.assertEqual(r[4], '{"a": 1}')  # object element preserved

    def test_domain_over_jsonb_check_accepts_valid_number_exactly(self):
        # The domain CHECK(jsonb_typeof(VALUE)='number') sees the REAL projected
        # value (not a wrapper), so a valid number is accepted and stays exact.
        wide = "12345678901234567890.123456789"
        cols = [_col("ID", "NUMBER"), _col("PAYLOAD", "NUMBER")]
        code, rep = self._load("PROBE_DOM", cols, [[1, {"$decimal": wide}]])
        self.assertEqual(code, 0, rep)
        self.assertTrue(rep["applied"], rep)
        got = self.conn.execute(
            f"SELECT payload::text, jsonb_typeof(payload) FROM {self.schema}.probe_dom").fetchone()
        self.assertEqual(got[0], wide)
        self.assertEqual(got[1], "number")

    def test_domain_over_jsonb_check_rejects_json_null_and_rolls_back(self):
        # A JSON null VALUE violates jsonb_typeof(VALUE)='number': the load must
        # FAIL CLOSED (reject + full rollback), never silently store SQL NULL.
        self.conn.execute(f"TRUNCATE {self.schema}.probe_dom")
        cols = [_col("ID", "NUMBER"), _col("PAYLOAD", "CLOB")]
        code, rep = self._load("PROBE_DOM", cols, [[1, "null"]])
        self.assertNotEqual(code, 0)
        self.assertFalse(rep.get("applied", False))
        n = self.conn.execute(f"SELECT count(*) FROM {self.schema}.probe_dom").fetchone()[0]
        self.assertEqual(n, 0)   # fully rolled back, nothing stored

    def test_sequence_receipt_carries_schema_and_name(self):
        # The finalization receipt must carry the sequence's search_path-INDEPENDENT
        # identity (schema + name) so an exit-3 resume can build a qualified setval.
        cols = [_col("ID", "NUMBER", identity="YES"), _col("NOTE", "VARCHAR2")]
        code, rep = self._load("PROBE_SEQ", cols, [[7, "a"], [9, "b"]])
        self.assertEqual(code, 0, rep)
        recs = [r for r in rep["sequences_reset"] if r.get("column") == "id"]
        self.assertTrue(recs, rep["sequences_reset"])
        r = recs[0]
        self.assertEqual(r["sequence_schema"], self.schema)
        self.assertTrue(r["sequence_name"])            # e.g. probe_seq_id_seq
        self.assertEqual(r["status"], "completed")
        # schema+name resolve to the real sequence regardless of search_path
        reg = self.conn.execute(
            "SELECT to_regclass(quote_ident(%s) || '.' || quote_ident(%s))",
            (r["sequence_schema"], r["sequence_name"])).fetchone()[0]
        self.assertIsNotNone(reg)


# --------------------------------------------------------------------------- #
# Opt-in / disposable-local guard contract (DB-free) -- the SAME shared suite   #
# as test_migration_data_loader.py, so both integration classes are covered by  #
# one hardened guard (host+hostaddr locality, explicit dbname, full PG* bind).   #
# --------------------------------------------------------------------------- #
class GuardContractTests(GuardContractMixin, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()
