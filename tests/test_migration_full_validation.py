"""Focused regression tests for migration_team.full_validation.

Pure-core tests for the canonical projector and DDL parsers -- they run anywhere
with the standard library, no database.  They lock the correctness-critical rules
the whole-migration data validation depends on: exact wide Decimals (no rounding),
month-vs-day interval separation, CHAR blank-pad, NULL distinct from empty string,
VARRAY (ordered) vs nested table (multiset), case-insensitive object attributes,
TIMESTAMP-WITH-LOCAL-TIME-ZONE as a UTC instant, XML canonical equality, BLOB hex,
and large-cell bounding.
"""
import json
import sys
import unittest
from collections import namedtuple
from decimal import Decimal
from datetime import datetime, date, timezone, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from migration_team import full_validation as fv  # noqa: E402

REG = {
    'T_CONTACT': {'kind': 'object', 'attributes': [
        {'name': 'contact_name', 'type': 'VARCHAR2(120)'}, {'name': 'email', 'type': 'VARCHAR2(150)'}]},
    'T_CHANNEL_VARR': {'kind': 'varray', 'ordered': True, 'element_type': 'VARCHAR2(20)'},
    'T_NUM_TAB': {'kind': 'table', 'ordered': False, 'element_type': 'NUMBER'},
    'T_BENEFIT': {'kind': 'object', 'attributes': [
        {'name': 'code', 'type': 'VARCHAR2(30)'}, {'name': 'value', 'type': 'NUMBER(12,4)'},
        {'name': 'valid_from', 'type': 'DATE'}]},
    'T_BENEFIT_TAB': {'kind': 'table', 'ordered': False, 'element_type': 't_benefit'},
}


class ProjectorScalars(unittest.TestCase):
    def setUp(self):
        self.p = fv.Projector(REG)

    def test_numeric_no_round_38_digits(self):
        big = '1234567890123456789012345678.12345678'   # 38 significant digits
        self.assertEqual(self.p.render(Decimal(big), 'numeric'), big)

    def test_numeric_trailing_zero_canon(self):
        self.assertEqual(self.p.render(Decimal('16.00'), 'numeric'), '16')
        self.assertEqual(self.p.render(Decimal('21.50'), 'numeric'), '21.5')
        self.assertEqual(self.p.render(Decimal('0'), 'numeric'), '0')

    def test_char_exact_byte_pad_not_trimmed(self):
        # CHAR fidelity is byte-exact: trailing pad is SIGNIFICANT (do not rtrim), so a
        # padded value differs from its trimmed form -- surfaces a pad-fidelity gap.
        self.assertEqual(self.p.render('GB  ', 'char'), 'GB  ')
        self.assertNotEqual(self.p.render('GB  ', 'char'), self.p.render('GB', 'char'))

    def test_varchar_exact_and_null_distinct_from_empty(self):
        self.assertEqual(self.p.render('', 'varchar'), '')
        self.assertEqual(self.p.render(None, 'varchar'), fv.NULL_TOKEN)
        self.assertNotEqual(self.p.render('', 'varchar'), self.p.render(None, 'varchar'))

    def test_timestamp_ltz_normalised_to_utc(self):
        aware = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone(timedelta(hours=5)))
        # 12:00+05:00 == 07:00Z
        self.assertEqual(self.p.render(aware, 'timestamp_ltz'), '2026-01-01T07:00:00')

    def test_binary_hex(self):
        self.assertEqual(self.p.render(b'\x00\xffAB', 'binary'), '00ff4142')


class ProjectorIntervals(unittest.TestCase):
    def setUp(self):
        self.p = fv.Projector(REG)

    def test_year_month_is_months_not_days(self):
        # 1 year 2 months -> 14 months, days=0, secs=0
        self.assertEqual(self.p.render({'years': 1, 'months': 2}, 'interval_ym'), '14|0|0')

    def test_day_second_keeps_days_not_months(self):
        self.assertEqual(self.p.render({'days': 15, 'seconds': 0, 'microseconds': 0}, 'interval_ds'),
                         '0|15|0')

    def test_month_and_day_intervals_never_collide(self):
        ym = self.p.render({'years': 0, 'months': 1}, 'interval_ym')      # 1 month
        ds = self.p.render({'days': 30, 'seconds': 0, 'microseconds': 0}, 'interval_ds')  # 30 days
        self.assertNotEqual(ym, ds)                                       # 1 mon != 30 days

    def test_fractional_seconds(self):
        self.assertEqual(self.p.render({'days': 0, 'seconds': 3, 'microseconds': 500000}, 'interval_ds'),
                         '0|0|3.5')


class ProjectorComplex(unittest.TestCase):
    def setUp(self):
        self.p = fv.Projector(REG)

    def test_object_case_insensitive_attributes_and_order(self):
        val = {'$oracle_object': 'T_CONTACT',
               'attributes': {'CONTACT_NAME': 'Ann', 'EMAIL': 'a@x.invalid'}}
        self.assertEqual(self.p.render(val, 'object'),
                         'OBJ<T_CONTACT>(contact_name=Ann' + fv.UNIT + 'email=a@x.invalid)')

    def test_object_recurses_typed_attributes(self):
        val = {'$oracle_object': 'T_BENEFIT',
               'attributes': {'CODE': 'X', 'VALUE': {'$decimal': '1.50'},
                              'VALID_FROM': {'$datetime': '2024-01-01T00:00:00'}}}
        out = self.p.render(val, 'object')
        self.assertIn('value=1.5', out)                      # numeric canon inside object
        self.assertIn('valid_from=2024-01-01T00:00:00', out)  # date canon inside object

    def test_varray_is_ordered(self):
        val = {'$oracle_collection': 'T_CHANNEL_VARR', 'values': ['WEB', 'POS']}
        self.assertEqual(self.p.render(val, 'collection_varray'), 'VARR[WEB' + fv.UNIT + 'POS]')

    def test_nested_table_is_multiset_unordered(self):
        a = {'$oracle_collection': 'T_NUM_TAB', 'values': [{'$decimal': '2'}, {'$decimal': '1'}]}
        b = {'$oracle_collection': 'T_NUM_TAB', 'values': [{'$decimal': '1'}, {'$decimal': '2'}]}
        self.assertEqual(self.p.render(a, 'collection_nested'), self.p.render(b, 'collection_nested'))
        self.assertTrue(self.p.render(a, 'collection_nested').startswith('MSET{'))

    def test_nested_table_preserves_duplicate_multiplicity_not_set_dedupe(self):
        # {1,1,2} must NOT canonicalise equal to {1,2}: multiset, not a set.
        dup = {'$oracle_collection': 'T_NUM_TAB',
               'values': [{'$decimal': '1'}, {'$decimal': '1'}, {'$decimal': '2'}]}
        nodup = {'$oracle_collection': 'T_NUM_TAB',
                 'values': [{'$decimal': '1'}, {'$decimal': '2'}]}
        self.assertNotEqual(self.p.render(dup, 'collection_nested'),
                            self.p.render(nodup, 'collection_nested'))
        # order among the duplicates is still irrelevant (multiset)
        reordered = {'$oracle_collection': 'T_NUM_TAB',
                     'values': [{'$decimal': '2'}, {'$decimal': '1'}, {'$decimal': '1'}]}
        self.assertEqual(self.p.render(dup, 'collection_nested'),
                         self.p.render(reordered, 'collection_nested'))

    def test_nested_table_preserves_null_slots(self):
        # A NULL element occupies a slot; {1,NULL} must differ from {1} and keep the NULL token.
        withnull = {'$oracle_collection': 'T_NUM_TAB', 'values': [{'$decimal': '1'}, None]}
        without = {'$oracle_collection': 'T_NUM_TAB', 'values': [{'$decimal': '1'}]}
        rn = self.p.render(withnull, 'collection_nested')
        self.assertNotEqual(rn, self.p.render(without, 'collection_nested'))
        self.assertIn(fv.NULL_TOKEN, rn)

    def test_varray_order_is_data_identity(self):
        # For VARRAY order IS identity: WEB,POS must NOT equal POS,WEB (unlike nested table).
        ab = {'$oracle_collection': 'T_CHANNEL_VARR', 'values': ['WEB', 'POS']}
        ba = {'$oracle_collection': 'T_CHANNEL_VARR', 'values': ['POS', 'WEB']}
        self.assertNotEqual(self.p.render(ab, 'collection_varray'),
                            self.p.render(ba, 'collection_varray'))

    def test_nested_table_of_objects(self):
        val = {'$oracle_collection': 'T_BENEFIT_TAB', 'values': [
            {'$oracle_object': 'T_BENEFIT', 'attributes': {'CODE': 'B', 'VALUE': {'$decimal': '0'},
                                                           'VALID_FROM': None}},
            {'$oracle_object': 'T_BENEFIT', 'attributes': {'CODE': 'A', 'VALUE': {'$decimal': '0'},
                                                           'VALID_FROM': None}}]}
        out = self.p.render(val, 'collection_nested')
        self.assertTrue(out.startswith('MSET{'))
        self.assertIn('code=A', out)
        self.assertIn('code=B', out)

    def test_xml_canonical_equality(self):
        # C14N normalises attribute order (and self-closing/entities); whitespace
        # between elements stays SIGNIFICANT by design, so equal-logical docs that
        # differ only in attribute order compare equal.
        a = '<r><a x="1" y="2">t</a></r>'
        b = '<r><a y="2" x="1">t</a></r>'   # attribute order only
        self.assertEqual(self.p.xml_c14n(a), self.p.xml_c14n(b))

    def test_xml_whitespace_is_significant_not_silently_normalised(self):
        # Inter-element whitespace differences are NOT hidden (surfaced for review).
        compact = '<r><a>t</a></r>'
        pretty = '<r>\n  <a>t</a>\n</r>'
        self.assertNotEqual(self.p.xml_c14n(compact), self.p.xml_c14n(pretty))


class Bounding(unittest.TestCase):
    def test_small_cell_unchanged(self):
        self.assertEqual(fv.bound_cell('hello'), 'hello')

    def test_large_cell_wrapped_with_length_and_hash(self):
        big = 'x' * (fv.BIG_CELL_BYTES + 10)
        out = fv.bound_cell(big)
        self.assertTrue(out.startswith('BIG:len=%d:sha256=' % len(big.encode())))
        self.assertLess(len(out), 120)


class DdlParsers(unittest.TestCase):
    def test_inline_and_generated(self):
        ddl = ('CREATE TABLE "CONTOSO"."T" (\n'
               '  "ID" NUMBER(9,0),\n'
               '  "AMT" NUMBER(12,4) NOT NULL ENABLE,\n'
               '  "CALC" NUMBER GENERATED ALWAYS AS (ROUND("AMT",2)) VIRTUAL ,\n'
               '  CONSTRAINT "PK_T" PRIMARY KEY ("ID")\n);')
        colmeta = {'ID': {'nullable': 'N'}, 'AMT': {'nullable': 'N'}, 'CALC': {'nullable': 'Y'}}
        kg = fv.parse_keys_and_gen(ddl, colmeta)
        self.assertEqual(kg['primary_key']['columns'], ['ID'])
        self.assertEqual(kg['generated'], ['CALC'])
        self.assertEqual(kg['usable_key']['columns'], ['ID'])

    def test_pk_on_generated_or_nullable_is_not_usable(self):
        ddl = 'CREATE TABLE "CONTOSO"."T" ("K" NUMBER, CONSTRAINT "PK" PRIMARY KEY ("K"));'
        kg = fv.parse_keys_and_gen(ddl, {'K': {'nullable': 'Y'}})   # nullable PK col -> not usable
        self.assertIsNone(kg['usable_key'])


class AdaptationManifest(unittest.TestCase):
    def test_norm_sql_collapses_whitespace(self):
        self.assertEqual(fv._norm_sql('CHECK (  a\n  >   b )'), 'CHECK ( a > b )')
        self.assertIsNone(fv._norm_sql(None))

    def test_load_adaptation_folds_table_keys_and_accepts_both_shapes(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            wrapped = Path(d) / 'a.json'
            wrapped.write_text('{"tables": {"TAX_RATE": {"checks": ["CHECK (x)"]}}}')
            bare = Path(d) / 'b.json'
            bare.write_text('{"TAX_RATE": {"defaults": {"c": "0"}}}')
            aw = fv.load_adaptation(wrapped)
            ab = fv.load_adaptation(bare)
            self.assertIn(fv.fold('TAX_RATE'), aw)     # 'TAX_RATE' folds to 'tax_rate'
            self.assertEqual(aw[fv.fold('TAX_RATE')]['checks'], ['CHECK (x)'])
            self.assertIn(fv.fold('TAX_RATE'), ab)     # bare map (no "tables" wrapper) also folded
            self.assertEqual(ab[fv.fold('TAX_RATE')]['defaults'], {'c': '0'})

    def test_load_adaptation_preserves_representation_and_normalizer(self):
        import tempfile
        doc = ('{"tables": {"TAX_RATE": {"representation": {"tax_code": '
               '{"kind": "varchar_as_text", "octet_max": 20}}, '
               '"normalizer": {"function": "contoso.tax_rate_norm", "definition_sha256": "ab12"}}}}')
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'a.json'
            p.write_text(doc)
            e = fv.load_adaptation(p)[fv.fold('TAX_RATE')]
        self.assertEqual(e['representation']['tax_code'], {'kind': 'varchar_as_text', 'octet_max': 20})
        self.assertEqual(e['normalizer']['definition_sha256'], 'ab12')

    def test_source_requirements_classification(self):
        # user-named CHECK -> requires checks; VARCHAR2 BYTE -> byte guard; real DEFAULT ->
        # default; VIRTUAL *with a real expression* -> generated; VIRTUAL with NULL default
        # (stored-mislabeled) -> NOT generated (loaded data); TIMESTAMP -> datetime.
        import tempfile
        cols = {'rows': [
            {'TABLE_NAME': 'T', 'COLUMN_NAME': 'NAME', 'DATA_TYPE': 'VARCHAR2', 'CHAR_USED': 'B',
             'DATA_LENGTH': 20, 'DATA_DEFAULT': None, 'VIRTUAL_COLUMN': 'NO'},
            {'TABLE_NAME': 'T', 'COLUMN_NAME': 'CODE', 'DATA_TYPE': 'CHAR', 'CHAR_USED': 'B',
             'DATA_LENGTH': 2, 'DATA_DEFAULT': None, 'VIRTUAL_COLUMN': 'NO'},   # CHAR not byte-required
            {'TABLE_NAME': 'T', 'COLUMN_NAME': 'FLAG', 'DATA_TYPE': 'NUMBER', 'CHAR_USED': None,
             'DATA_LENGTH': None, 'DATA_DEFAULT': '0', 'VIRTUAL_COLUMN': 'NO'},
            {'TABLE_NAME': 'T', 'COLUMN_NAME': 'CALC', 'DATA_TYPE': 'NUMBER', 'CHAR_USED': None,
             'DATA_LENGTH': None, 'DATA_DEFAULT': 'x+1', 'VIRTUAL_COLUMN': 'YES'},   # genuine generated
            {'TABLE_NAME': 'T', 'COLUMN_NAME': 'ATTRS', 'DATA_TYPE': 'XMLTYPE', 'CHAR_USED': None,
             'DATA_LENGTH': None, 'DATA_DEFAULT': None, 'VIRTUAL_COLUMN': 'YES'},   # STORED-mislabeled
            {'TABLE_NAME': 'T', 'COLUMN_NAME': 'TS', 'DATA_TYPE': 'TIMESTAMP(6) WITH LOCAL TIME ZONE',
             'CHAR_USED': None, 'DATA_LENGTH': None, 'DATA_DEFAULT': None, 'VIRTUAL_COLUMN': 'NO'}]}
        con = {'columns': {'rows': []}, 'constraints': [
            {'TABLE_NAME': 'T', 'CONSTRAINT_NAME': 'CK_BIZ', 'CONSTRAINT_TYPE': 'C', 'GENERATED': 'USER NAME'},
            {'TABLE_NAME': 'T', 'CONSTRAINT_NAME': 'SYS_C1', 'CONSTRAINT_TYPE': 'C', 'GENERATED': 'GENERATED NAME'}]}
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'columns.json').write_text(json.dumps(cols))
            (Path(d) / 'constraints-full.json').write_text(json.dumps(con))
            req = fv.load_source_catalog(d)['requirements'][fv.fold('T')]
        self.assertTrue(req['checks'])                       # CK_BIZ is user-named
        self.assertEqual(req['check_ids'], {'CK_BIZ'})        # exact id tracked (SYS_C1 excluded)
        self.assertEqual(req['byte'], {'name'})              # VARCHAR2 BYTE only, not CHAR
        self.assertEqual(req['defaults'], {'flag'})          # real default, non-virtual
        self.assertEqual(req['generated'], {'calc'})         # VIRTUAL *with expression* only
        self.assertNotIn('attrs', req['generated'])          # stored-mislabeled -> NOT generated
        self.assertEqual(req['datetime'], {'ts'})            # TIMESTAMP-family


class CompareDataRegen(unittest.TestCase):
    def test_compare_data_regenerates_stale_output(self):
        # The public CLI refuses to overwrite an existing --output; full_validation
        # must clear it first so a re-run reflects the CURRENT csvs, not stale ones.
        import tempfile
        import csv as _csv
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            def write(path, rows):
                with open(path, 'w', newline='', encoding='utf-8') as fh:
                    w = _csv.writer(fh)
                    w.writerow(['id', 'v'])
                    for r in rows:
                        w.writerow(r)
            src = d / 'src.csv'
            tgt = d / 'tgt.csv'
            out = d / 'cmp.json'
            write(src, [['1', 'a'], ['2', 'b']])
            write(tgt, [['1', 'a'], ['2', 'b']])
            r1 = fv.compare_data(sys.executable, src, tgt, ['id'], out)
            self.assertEqual(r1['_exit'], 0)
            self.assertEqual(r1['status'], 'passed')
            # change the target and re-run into the SAME output path
            write(tgt, [['1', 'a'], ['2', 'CHANGED']])
            r2 = fv.compare_data(sys.executable, src, tgt, ['id'], out)
            self.assertEqual(r2['_exit'], 1)              # genuinely re-ran & failed (not stale exit 2)
            self.assertEqual(r2['status'], 'failed')      # reflects the CURRENT target
            self.assertEqual(r2['changed_rows'], 1)


class Receipts(unittest.TestCase):
    GATES = {'data_consistency_gates': [{'id': g} for g in (
        'DATA-COUNTS', 'DATA-KEYS', 'DATA-COLUMNS', 'DATA-TIME', 'DATA-STRING', 'DATA-LONG-LOB',
        'DATA-CONTENT', 'DATA-REFERENTIAL', 'DATA-SEQUENCES')]}

    def test_source_only_is_prepared_not_pass(self):
        tr = {'A': {'result': None}, 'B': {'result': None}}
        r = fv.build_receipts(self.GATES, tr, source_only=True, selected_count=2, total_tables=93)
        self.assertEqual(r['data_validation']['status'], 'prepared')
        self.assertEqual(r['overall'], 'INCOMPLETE')
        self.assertEqual(r['data_validation']['coverage'], 'subset')

    def test_all_missing_is_failed_and_gate_not_passed(self):
        tr = {'A': {'result': 'target_table_missing'}, 'B': {'result': 'target_table_missing'}}
        r = fv.build_receipts(self.GATES, tr, source_only=False, selected_count=2, total_tables=2)
        self.assertEqual(r['data_validation']['status'], 'failed')
        self.assertEqual(r['overall'], 'FAIL')
        self.assertEqual(r['data_gates']['DATA-COUNTS']['result'], 'failed')      # not "passed" by capability
        self.assertEqual(r['data_gates']['DATA-SEQUENCES']['result'],
                         'not_executed_needs_target_ops_or_other_lane')

    def test_all_pass_is_passed(self):
        tr = {'A': {'result': 'parity_pass'}, 'B': {'result': 'empty_verified'}}
        r = fv.build_receipts(self.GATES, tr, source_only=False, selected_count=2, total_tables=2)
        self.assertEqual(r['data_validation']['status'], 'passed')
        self.assertEqual(r['overall'], 'PASS')
        self.assertTrue(r['data_gates']['DATA-KEYS']['executed'])
        self.assertEqual(r['data_gates']['DATA-KEYS']['result'], 'passed')

    def test_mixed_is_failed(self):
        tr = {'A': {'result': 'parity_pass'}, 'B': {'result': 'schema_mismatch'}}
        r = fv.build_receipts(self.GATES, tr, source_only=False, selected_count=2, total_tables=2)
        self.assertEqual(r['data_validation']['status'], 'failed')
        self.assertEqual(r['data_validation']['tables_failed_or_blocked'], ['B'])

    def test_blocked_no_comparable_key_is_failed(self):
        # A keyless non-empty table is a distinct blocked disposition; it must never pass.
        tr = {'A': {'result': 'parity_pass'}, 'B': {'result': 'blocked_no_comparable_key'}}
        r = fv.build_receipts(self.GATES, tr, source_only=False, selected_count=2, total_tables=2)
        self.assertEqual(r['data_validation']['status'], 'failed')
        self.assertEqual(r['overall'], 'FAIL')
        self.assertEqual(r['data_validation']['tables_failed_or_blocked'], ['B'])


class DateTargetRendering(unittest.TestCase):
    """A PG `date`-typed target (accepted by TYPE_FAMILY['date']) yields a datetime.date, which must
    render without crashing AND canonicalise to MIDNIGHT so the same calendar day matches an Oracle
    DATE at 00:00:00, while a non-midnight Oracle DATE (time dropped) still differs."""
    def setUp(self):
        self.p = fv.Projector({})

    def test_bare_date_normalised_to_midnight_not_crash(self):
        self.assertEqual(self.p.dt_canon(date(2026, 1, 1)), '2026-01-01T00:00:00')
        self.assertEqual(self.p.scalar(date(2026, 1, 1), 'date'), '2026-01-01T00:00:00')

    def test_midnight_datetime_matches_bare_date(self):
        # SAME calendar day at midnight must canonically MATCH (no false parity fail)
        self.assertEqual(self.p.dt_canon(date(2026, 1, 1)),
                         self.p.dt_canon(datetime(2026, 1, 1, 0, 0)))
        self.assertEqual(self.p.scalar(datetime(2026, 1, 1, 0, 0), 'date'),
                         self.p.scalar(date(2026, 1, 1), 'date'))

    def test_non_midnight_datetime_differs_from_bare_date(self):
        # a dropped time-of-day (date target) must still be surfaced as a DIFFERENCE
        self.assertNotEqual(self.p.scalar(datetime(2026, 1, 1, 9, 30), 'date'),
                            self.p.scalar(date(2026, 1, 1), 'date'))
        self.assertEqual(self.p.scalar(datetime(2026, 1, 1, 9, 30), 'date'), '2026-01-01T09:30:00')

    def test_render_target_cell_date_typed_column(self):
        c = {'rule': 'date', 'oracle_type': 'DATE'}
        self.assertEqual(fv._render_target_cell(self.p, c, [date(2026, 1, 1)]), '2026-01-01T00:00:00')


class CategoryByRegistry(unittest.TestCase):
    """category() classifies object/collection by SOURCE type-registry membership, not a hardcoded
    owner literal -- so a UDT owned by any schema is classified from its parsed type."""
    REG = {'ADDRESS_T': {'kind': 'object'}, 'PHONES_T': {'kind': 'varray'},
           'TAGS_T': {'kind': 'table'}}

    def test_udt_in_registry_is_complex_regardless_of_owner(self):
        self.assertEqual(fv.category({'type': 'ADDRESS_T', 'type_owner': 'HR'}, self.REG), 'object')
        self.assertEqual(fv.category({'type': 'ADDRESS_T', 'type_owner': None}, self.REG), 'object')
        self.assertEqual(fv.category({'type': 'PHONES_T', 'type_owner': 'SALES'}, self.REG),
                         'collection_varray')
        self.assertEqual(fv.category({'type': 'TAGS_T', 'type_owner': 'SALES'}, self.REG),
                         'collection_nested')

    def test_xmltype_and_scalars_unchanged(self):
        self.assertEqual(fv.category({'type': 'XMLTYPE', 'type_owner': 'X'}, self.REG), 'xml')
        self.assertEqual(fv.category({'type': 'NUMBER', 'type_owner': None}, self.REG), 'numeric')
        # a type NOT in the parsed registry is a scalar, even a CONTOSO-style owner or T_ name
        self.assertEqual(fv.category({'type': 'T_UNKNOWN', 'type_owner': 'CONTOSO'}, self.REG),
                         'varchar')


class OctetGuardBinding(unittest.TestCase):
    """_octet_guard_for / _parse_octet_guard bind the WHOLE predicate to a specific column with a
    distinct operator (CHAR '='; VARCHAR '<='). Fragments, extra terms, arithmetic, non-text casts,
    string literals, wrong columns, and wrong operators are all rejected."""
    def test_real_pg_constraintdef_forms(self):
        # exact strings emitted by pg_get_constraintdef(oid, true) on PostgreSQL 16
        self.assertEqual(fv._octet_guard_for(['CHECK (octet_length(code) = 20)'], 'code'), ('=', 20))
        self.assertEqual(fv._octet_guard_for(['CHECK (octet_length(code) <= 20)'], 'code'), ('<=', 20))
        self.assertEqual(fv._octet_guard_for(['CHECK (code IS NULL OR octet_length(code) <= 20)'],
                                             'code'), ('<=', 20))

    def test_author_forms_spacing_and_text_cast(self):
        self.assertEqual(fv._octet_guard_for(['CHECK (octet_length(status)<=15)'], 'status'), ('<=', 15))
        self.assertEqual(fv._octet_guard_for(['CHECK (octet_length(tax_code::text) <= 20)'], 'tax_code'),
                         ('<=', 20))
        self.assertEqual(fv._octet_guard_for(['CHECK (octet_length((tax_code)::text) <= 20)'], 'tax_code'),
                         ('<=', 20))

    def test_quoted_mixed_case_identifier(self):
        self.assertEqual(fv._octet_guard_for(['CHECK (octet_length("MixedCase") <= 10)'], 'MixedCase'),
                         ('<=', 10))
        self.assertIsNone(fv._octet_guard_for(['CHECK (octet_length("MixedCase") <= 10)'], 'mixedcase'))

    def test_char_equality_form_is_parsed(self):   # regression: '=' must NOT be rejected
        self.assertEqual(fv._octet_guard_for(['CHECK (octet_length(currency_code) = 3)'],
                                             'currency_code'), ('=', 3))

    def test_rejects_substring_other_column(self):
        # real gl_account collision: a guard on parent_account_code must NOT credit account_code
        defs = ['CHECK (octet_length(parent_account_code) <= 30)']
        self.assertIsNone(fv._octet_guard_for(defs, 'account_code'))
        self.assertEqual(fv._octet_guard_for(defs, 'parent_account_code'), ('<=', 30))

    def test_rejects_five_invalid_probes(self):
        # each of these previously matched a fragment and wrongly returned a bound
        self.assertIsNone(fv._octet_guard_for(['CHECK (octet_length(code) <= 20 OR TRUE)'], 'code'))
        self.assertIsNone(fv._octet_guard_for(['CHECK (octet_length(code) <= 20*1000)'], 'code'))
        self.assertIsNone(fv._octet_guard_for(['CHECK (octet_length(code::name) <= 20)'], 'code'))
        self.assertIsNone(fv._octet_guard_for(["CHECK (code = 'octet_length(code) <= 20')"], 'code'))
        self.assertIsNone(fv._octet_guard_for(['CHECK (true)'], 'code'))

    def test_rejects_extra_terms_and_missing(self):
        self.assertIsNone(fv._octet_guard_for([], 'code'))
        self.assertIsNone(fv._octet_guard_for(['CHECK (length(code) <= 5)'], 'code'))   # not octet_length
        # a guard on a DIFFERENT column plus the real one still credits only the real one
        two = ['CHECK (octet_length(other) <= 9)', 'CHECK (octet_length(code) <= 5)']
        self.assertEqual(fv._octet_guard_for(two, 'code'), ('<=', 5))

    def test_nullable_wrapper_column_must_match(self):
        # the IS NULL column must equal the guarded column
        self.assertIsNone(fv._octet_guard_for(
            ['CHECK (other IS NULL OR octet_length(code) <= 20)'], 'code'))
        self.assertEqual(fv._octet_guard_for(
            ['CHECK ((code IS NULL) OR (octet_length(code) <= 20))'], 'code'), ('<=', 20))


class PrimaryKeyDecision(unittest.TestCase):
    """_primary_key_ok distinguishes usable_key-IS-source-PK (ordered PK equality) from a fallback
    UNIQUE comparison key (target must carry it as a PK-or-UNIQUE column set)."""
    def test_source_pk_ordered_equality(self):
        pk = {'name': 'PK1', 'columns': ['A', 'B']}
        ok, is_pk = fv._primary_key_ok(['a', 'b'], [], pk, pk)
        self.assertTrue(ok); self.assertTrue(is_pk)
        ok2, _ = fv._primary_key_ok(['b', 'a'], [], pk, pk)    # order matters
        self.assertFalse(ok2)

    def test_fallback_unique_accepts_target_unique_not_pk(self):
        src_pk = {'name': 'PK1', 'columns': ['A']}            # source PK (unusable)
        uk = {'name': 'UQ1', 'columns': ['B']}                # usable_key fell back to a UNIQUE
        # target has a surrogate PK ['id'] and the unique ['b']; must pass on the unique set
        ok, is_pk = fv._primary_key_ok(['id'], [['b']], uk, src_pk)
        self.assertTrue(ok); self.assertFalse(is_pk)
        # if the target lacks that unique column set entirely -> not ok
        ok2, _ = fv._primary_key_ok(['id'], [['other']], uk, src_pk)
        self.assertFalse(ok2)

    def test_keyless_requires_some_target_pk(self):
        self.assertEqual(fv._primary_key_ok(['id'], [], None, None)[0], True)
        self.assertEqual(fv._primary_key_ok([], [], None, None)[0], False)


class CompositeUnderParseFailsClosed(unittest.TestCase):
    """When the parsed type registry lists a DIFFERENT attribute count than the live composite tuple
    (registry under-parse), _pg_to_source_shape fails CLOSED rather than silently dropping fields."""
    REG = {'T_X': {'kind': 'object', 'attributes': [
        {'name': 'A', 'type': 'VARCHAR2(10)'}, {'name': 'B', 'type': 'VARCHAR2(10)'}]}}

    def test_matched_arity_renders(self):
        TX = namedtuple('TX', ['a', 'b'])
        shape = fv._pg_to_source_shape(TX('x', 'y'), 'T_X', self.REG)
        self.assertEqual(shape['$oracle_object'], 'T_X')
        self.assertEqual(set(shape['attributes']), {'A', 'B'})

    def test_extra_fields_raise_not_implemented(self):
        TX = namedtuple('TX', ['a', 'b', 'c'])                # registry lists only A,B
        with self.assertRaises(NotImplementedError):
            fv._pg_to_source_shape(TX('x', 'y', 'z'), 'T_X', self.REG)

    def test_render_target_cell_propagates_block(self):
        TX = namedtuple('TX', ['a', 'b', 'c'])
        p = fv.Projector(self.REG)
        with self.assertRaises(NotImplementedError):     # caught by export_target -> blocked disposition
            fv._render_target_cell(p, {'rule': 'object', 'oracle_type': 'T_X'}, [TX('x', 'y', 'z')])


class SecurityPathContainment(unittest.TestCase):
    """Untrusted table/file names cannot escape their base dir, and SOURCE vs TARGET artifacts get
    genuinely distinct in-tree paths (a '../P' name can no longer self-compare to a false PASS)."""
    def test_contained_path_rejects_escape_and_absolute(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            (base / 'ok.txt').write_text('x')
            self.assertEqual(fv._contained_path(base, 'ok.txt'), (base / 'ok.txt').resolve())
            for bad in ('../evil', '/etc/passwd', '../../x', 'a/../../b'):
                with self.assertRaises(ValueError):
                    fv._contained_path(base, bad)

    def test_artifact_stem_safe_and_distinct(self):
        for name in ('../P', 'P', 'a/../b', '"Mixed/Case"', 'ADDRESS'):
            stem = fv._artifact_stem(name)
            self.assertNotIn('/', stem)
            self.assertNotIn('..', stem)
            self.assertNotIn('\\', stem)
        # distinct names -> distinct stems; a traversal name never collides with a plain one
        self.assertNotEqual(fv._artifact_stem('../P'), fv._artifact_stem('P'))

    def test_source_and_target_artifacts_do_not_collide(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / 'source-csv').mkdir(); (out / 'target-csv').mkdir()
            name = '../P'                                  # the canary traversal name
            stem = fv._artifact_stem(name)
            src = (out / 'source-csv' / (stem + '.csv'))
            tgt = (out / 'target-csv' / (stem + '.csv'))
            self.assertNotEqual(src.resolve(), tgt.resolve())      # NOT the same file
            self.assertIn(out.resolve(), src.resolve().parents)    # both stay in-tree
            self.assertIn(out.resolve(), tgt.resolve().parents)


def _write_min_snapshot(root: Path, file_name='T.jsonl', jsonl='[{"$decimal": "1"}]\n'):
    """Build a minimal in-tree snapshot + DDL fixture; returns (manifest_path, ddl_root)."""
    (root / 'ddl' / 'TABLE').mkdir(parents=True)
    (root / 'ddl' / 'TABLE' / 'T.sql').write_text(
        'CREATE TABLE "CONTOSO"."T" (\n"ID" NUMBER,\nCONSTRAINT "PK_T" PRIMARY KEY ("ID")\n);\n')
    (root / file_name).write_text(jsonl, encoding='utf-8')
    import hashlib as _h
    sha = _h.sha256((root / file_name).read_bytes()).hexdigest()
    manifest = {'schema': 'CONTOSO', 'tables': [{
        'table': 'T', 'file': file_name, 'rows': 1, 'sha256': sha,
        'columns': [{'name': 'ID', 'type': 'NUMBER', 'nullable': 'N'}]}]}
    (root / 'manifest.json').write_text(json.dumps(manifest))
    return root / 'manifest.json', root / 'ddl'


class SecuritySourceHashVerification(unittest.TestCase):
    """project_source verifies the source JSONL against the manifest sha256 (genuine snapshot bytes);
    tampered content -- even with the same row count -- is refused before projection."""
    def test_genuine_bytes_project(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            manifest, ddl = _write_min_snapshot(root)
            _m, inv = fv.build_inventory(manifest, ddl)
            entry = inv['per_table']['T']
            out_csv = root / 'out.csv'
            self.assertEqual(fv.project_source(root, entry, fv.Projector({}), out_csv), 1)

    def test_tampered_same_rowcount_refused(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            manifest, ddl = _write_min_snapshot(root)
            _m, inv = fv.build_inventory(manifest, ddl)
            entry = inv['per_table']['T']
            # overwrite the JSONL with DIFFERENT bytes but the SAME single-row count
            (root / 'T.jsonl').write_text('[{"$decimal": "999"}]\n', encoding='utf-8')
            with self.assertRaises(ValueError):
                fv.project_source(root, entry, fv.Projector({}), root / 'out.csv')

    def test_traversal_file_entry_refused_before_read(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            manifest, ddl = _write_min_snapshot(root, file_name='T.jsonl')
            doc = json.loads((root / 'manifest.json').read_text())
            doc['tables'][0]['file'] = '../evil.jsonl'      # escape attempt
            (root / 'manifest.json').write_text(json.dumps(doc))
            with self.assertRaises(ValueError):
                fv.build_inventory(root / 'manifest.json', ddl)


class SecurityBodyPinExactBytes(unittest.TestCase):
    """The trigger-body security pin is over EXACT bytes: two bodies differing ONLY by a comment (or
    whitespace) must NOT collide, even though a whitespace-collapsing normaliser would fuse them."""
    def test_comment_and_whitespace_change_alters_pin(self):
        a = "BEGIN\n  -- keep\n  NEW.code := NULLIF(NEW.code, '');\nEND;"
        b = "BEGIN\n  -- keep NEW.code := NULLIF(NEW.code, '');\nEND;"     # 2nd line commented out
        sha_a, exact_a = fv._function_body_pin(a)
        sha_b, exact_b = fv._function_body_pin(b)
        self.assertNotEqual(sha_a, sha_b)                 # exact-byte pins differ (behavior change caught)
        self.assertEqual(exact_a, a)
        # the OLD whitespace-collapsing approach WOULD have collided -> proves the fix matters
        self.assertEqual(fv._norm_sql(a), fv._norm_sql(b))


class SecurityCredentialEnvRouting(unittest.TestCase):
    """load_target_credentials clears ambient PGHOSTADDR/PGSERVICE so they cannot redirect to the
    wrong cluster; an explicit credential-file hostaddr (intentional tunnel) is preserved. No
    network connection is made."""
    def _run(self, cred):
        import tempfile, os as _os
        saved = {k: _os.environ.get(k) for k in
                 ('PGHOST', 'PGHOSTADDR', 'PGSERVICE', 'PGPORT', 'PGUSER', 'PGPASSWORD')}
        try:
            _os.environ['PGHOSTADDR'] = '10.0.0.9'         # ambient redirect that must be cleared
            _os.environ['PGSERVICE'] = 'evil-service'
            with tempfile.TemporaryDirectory() as d:
                p = Path(d) / 'cred.json'
                p.write_text(json.dumps(cred))
                meta = fv.load_target_credentials(p)
            return meta, dict(_os.environ)
        finally:
            for k, v in saved.items():
                if v is None:
                    _os.environ.pop(k, None)
                else:
                    _os.environ[k] = v

    def test_ambient_hostaddr_and_service_cleared(self):
        meta, env = self._run({'host': 'target.example', 'port': 5432, 'user': 'u',
                               'password': 'S3cr3t-PW-xyz'})
        self.assertEqual(env.get('PGHOST'), 'target.example')
        self.assertNotIn('PGHOSTADDR', env)                # ambient redirect removed
        self.assertNotIn('PGSERVICE', env)
        self.assertFalse(meta['hostaddr_present'])
        self.assertTrue(meta['password_present'])          # never the value
        self.assertNotIn('S3cr3t-PW-xyz', json.dumps(meta))

    def test_explicit_file_hostaddr_preserved(self):
        _meta, env = self._run({'host': 'target.example', 'hostaddr': '192.0.2.10', 'user': 'u'})
        self.assertEqual(env.get('PGHOSTADDR'), '192.0.2.10')   # intentional tunnel preserved
        self.assertNotIn('PGSERVICE', env)


if __name__ == '__main__':
    unittest.main()
