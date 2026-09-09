"""Offline regression suite; fake validators exercise state handling, not SQL correctness."""
import csv
import io
import json
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from migration_team.cli import main
from migration_team.cases import record_case
from migration_team.evidence import compare_exports, hard_cases
from migration_team.queue import COLUMNS, Queue, digest


def mapping(kind='TABLE', name='CONTOSO.T', target='contoso.t', status='Not-Converted', action='yes'):
    return dict(zip(COLUMNS, (kind, name, kind if target else '', target, status, action, '')))


def csv_file(path, rows, fields=None):
    with path.open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields or list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    return path


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.report = self.root / 'mapping.csv'
        self.q = Queue(self.root / 'state')

    def init(self, rows=None, max_workers=2):
        csv_file(self.report, rows or [mapping()])
        return self.q.initialize(self.report, max_workers=max_workers)

    def stage(self):
        self.init()
        task_id = self.q.claim('repair-1')['id']
        paths = []
        for name, text in [('source.sql', 'CREATE TABLE T (id NUMBER);'),
                           ('candidate.sql', 'CREATE TABLE t (id numeric);'),
                           ('checks.sql', "SELECT 't exists' AS check_name, true AS passed;")]:
            path = self.root / name
            path.write_text(text)
            paths.append(path)
        self.q.stage(task_id, 'repair-1', *paths)
        return task_id

    @staticmethod
    def fake_valid(candidate, checks, dependencies, **options):
        return {'status': 'passed', 'candidate_sha256': digest(candidate),
                'checks_sha256': digest(checks), 'checks': [], 'log': 'unit-test double only'}

    def validated(self):
        task_id = self.stage()
        self.q.validate(task_id, 'repair-1', self.fake_valid, 'test-double', 10)
        return task_id

    def test_preserves_all_mappings_and_source_type_case(self):
        rows = [mapping(target='contoso.t'), mapping(target='contoso.t_idx'),
                mapping(status='Converted', action='no'),
                mapping(kind='VIEW'), mapping(name='CONTOSO.t'),
                mapping(name='CONTOSO.GOOD', status='Converted', action='no'),
                mapping(name='CONTOSO.REVIEW', status='Converted', action='yes'),
                mapping(name='CONTOSO.MISSING', target='', action='no')]
        report = self.init(rows)
        self.assertEqual(report['input']['report_rows'], 8)
        self.assertEqual(report['tasks'], 5)
        task = next(t for t in self.q.list() if t['source_name'] == 'CONTOSO.T' and t['source_type'] == 'TABLE')
        self.assertEqual(len(self.q.show(task['id'])['mappings']), 3)

    def test_ids_do_not_depend_on_row_order(self):
        rows = [mapping(name='CONTOSO.B'), mapping(name='CONTOSO.A')]
        self.init(rows)
        q2 = Queue(self.root / 'other-state')
        csv_file(self.report, rows[::-1])
        q2.initialize(self.report)
        self.assertEqual([x['id'] for x in self.q.list()], [x['id'] for x in q2.list()])

    def test_reimport_refuses_to_overwrite_state(self):
        self.init()
        with self.assertRaisesRegex(ValueError, 'empty'):
            self.q.initialize(self.report)
        self.assertEqual(self.q.summary()['tasks'], 1)

    def test_unknown_status_is_not_silently_skipped(self):
        with self.assertRaisesRegex(ValueError, 'unknown Status'):
            self.init([mapping(status='Maybe')])
        self.assertFalse(self.q.db.exists())

    def test_unknown_column_or_short_row_rejected(self):
        self.report.write_text('wrong,column\na,b\n')
        with self.assertRaises(ValueError):
            self.q.initialize(self.report)
        self.report.write_text(','.join(COLUMNS) + '\nTABLE,CONTOSO.T\n')
        with self.assertRaises(ValueError):
            self.q.initialize(self.report)

    def test_claim_is_atomic_and_bounded_across_connections(self):
        self.init([mapping(name='CONTOSO.T%d' % i) for i in range(8)])
        def claim(i):
            try:
                return Queue(self.q.root).claim('worker-%d' % i)['id']
            except ValueError:
                return None
        with ThreadPoolExecutor(max_workers=8) as pool:
            claimed = [r for r in pool.map(claim, range(8)) if r]
        self.assertEqual(len(claimed), 2)
        self.assertEqual(len(set(claimed)), 2)

    def test_wrong_owner_cannot_stage_or_release(self):
        task_id = self.stage()
        with self.assertRaisesRegex(ValueError, 'this worker'):
            self.q.release(task_id, 'someone-else', 'no')

    def test_mapping_without_ddl_cannot_be_validated(self):
        self.init()
        task_id = self.q.claim('repair-1')['id']
        with self.assertRaisesRegex(ValueError, 'missing source.sql'):
            self.q.validate(task_id, 'repair-1', self.fake_valid, 'test-double', 10)

    def test_passing_validation_needs_an_independent_review(self):
        task_id = self.validated()
        self.assertEqual(self.q.show(task_id)['status'], 'pending_review')
        with self.assertRaisesRegex(ValueError, 'own work'):
            self.q.review(task_id, ' REPAIR-1 ', 'accept', 'looks fine')
        result = self.q.review(task_id, 'skeptic-1', 'accept', 'Compared Oracle semantics and tested nulls')
        self.assertEqual(result['status'], 'reviewed')

    def test_any_changed_input_invalidates_acceptance(self):
        for filename in ('source.sql', 'candidate.sql', 'checks.sql', 'dependencies.sql'):
            with self.subTest(filename=filename):
                task_id = self.validated() if not self.q.db.exists() else self.q.list()[0]['id']
                path = self.q.workdir(task_id) / filename
                original = path.read_bytes() if path.exists() else None
                path.write_text('changed')
                with self.assertRaisesRegex(ValueError, 'stale'):
                    self.q.review(task_id, 'skeptic', 'accept', 'reject stale evidence')
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_failed_validation_does_not_reach_review(self):
        task_id = self.stage()
        def failed(*a, **kw):
            return {'status': 'failed', 'checks': [], 'log': 'SQL error'}
        result = self.q.validate(task_id, 'repair-1', failed, 'test-double', 10)
        self.assertEqual(result['status'], 'claimed')
        with self.assertRaisesRegex(ValueError, 'passing scratch'):
            self.q.review(task_id, 'skeptic', 'accept', 'cannot approve failure')

    def test_three_validation_attempts_then_explicit_block_and_unblock(self):
        task_id = self.stage()
        def failed(*a, **kw):
            return {'status': 'failed', 'checks': [], 'log': 'SQL error'}
        for _ in range(3):
            self.q.validate(task_id, 'repair-1', failed, 'test-double', 10)
        with self.assertRaisesRegex(ValueError, 'three validation'):
            self.q.validate(task_id, 'repair-1', failed, 'test-double', 10)
        self.q.release(task_id, 'repair-1', 'Need missing dependency', blocked=True)
        self.q.unblock(task_id, 'Dependency now supplied by coordinator')
        task = self.q.claim('repair-2', task_id)
        self.assertEqual(task['validation_attempts'], 0)

    def test_crashed_validator_returns_task_to_owner(self):
        task_id = self.stage()
        def crashed(*a, **kw):
            raise RuntimeError('crash')
        with self.assertRaises(RuntimeError):
            self.q.validate(task_id, 'repair-1', crashed, 'test-double', 10)
        self.assertEqual(self.q.show(task_id)['status'], 'claimed')

    def test_validation_input_change_during_execution_fails(self):
        task_id = self.stage()
        def mutates(candidate, checks, deps, **kw):
            candidate.write_text('changed during test')
            return {'status': 'passed', 'checks': [], 'log': ''}
        result = self.q.validate(task_id, 'repair-1', mutates, 'test-double', 10)
        self.assertEqual(result['evidence']['status'], 'failed')

    def test_blocked_work_resumes_with_reason(self):
        self.init()
        task_id = self.q.claim('repair-1')['id']
        self.q.release(task_id, 'repair-1', 'Original DDL missing', blocked=True)
        with self.assertRaises(ValueError):
            self.q.claim('repair-2', task_id)
        self.q.unblock(task_id, 'Original DDL archived locally')
        self.assertEqual(self.q.claim('repair-2', task_id)['attempts'], 2)

    def test_symlink_candidate_is_refused(self):
        task_id = self.stage()
        file = self.q.workdir(task_id) / 'candidate.sql'
        file.unlink()
        file.symlink_to(self.root / 'source.sql')
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            self.q.validate(task_id, 'repair-1', self.fake_valid, 'test-double', 10)

    def test_case_classification_requires_fresh_independent_review(self):
        task_id = self.validated()
        path = self.root / 'cases.json'
        path.write_text(json.dumps({'cases': [{'id': 'H-01', 'status': 'not_tested'}]}))
        with self.assertRaisesRegex(ValueError, 'independently reviewed'):
            record_case(path, 'H-01', self.q, [task_id], 'partial', 'Package session state inspected')
        self.q.review(task_id, 'skeptic', 'accept', 'Checked the supplied behavior assertions')
        result = record_case(path, 'H-01', self.q, [task_id], 'partial', 'Package session state inspected')
        self.assertEqual(result['status'], 'reviewed_candidate')
        (self.q.workdir(task_id) / 'checks.sql').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'stale'):
            record_case(path, 'H-01', self.q, [task_id], 'clean', 'New tests needed')

    def test_malformed_case_checklist_is_a_clean_cli_error(self):
        path = self.root / 'cases.json'
        for document in ({}, [], {'cases': [None]}, {'cases': [{}]}, {'cases': 'bad'}, {'cases': [{'id': 1}]}):
            with self.subTest(document=document):
                path.write_text(json.dumps(document))
                stderr = io.StringIO()
                with redirect_stdout(io.StringIO()), redirect_stderr(stderr):
                    rc = main(['case-record', '--state', str(self.q.root), '--checklist', str(path),
                               '--id', 'H-01', '--task', 'fixture', '--outcome', 'clean', '--note', 'probe'])
                self.assertEqual(rc, 2)
                self.assertIn('not a valid hard-case checklist', stderr.getvalue())
                self.assertNotIn('Traceback', stderr.getvalue())

    def test_cli_reports_errors_nonzero(self):
        self.init()
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(main(['show', '--state', str(self.q.root), '--id', 'unknown']), 2)
            self.assertEqual(main(['report', '--state', str(self.q.root)]), 0)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.csv'
        self.target = self.root / 'target.csv'

    def test_compare_ignores_order_but_not_values(self):
        rows = [{'id': '1', 'value': 'α,β'}, {'id': '2', 'value': '__NULL__'}]
        csv_file(self.source, rows)
        csv_file(self.target, rows[::-1], ['value', 'id'])
        self.assertEqual(compare_exports(self.source, self.target, ['id'])['status'], 'passed')
        csv_file(self.target, [rows[0], {'id': '2', 'value': ''}])
        result = compare_exports(self.source, self.target, ['id'])
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['changed_rows'], 1)

    def test_missing_extra_and_duplicate_keys(self):
        csv_file(self.source, [{'id': '1'}, {'id': '2'}])
        csv_file(self.target, [{'id': '1'}, {'id': '3'}])
        result = compare_exports(self.source, self.target, ['id'])
        self.assertEqual((result['missing_keys'], result['extra_keys']), (1, 1))
        csv_file(self.target, [{'id': '1'}, {'id': '1'}])
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            compare_exports(self.source, self.target, ['id'])

    def test_empty_or_different_projections_are_not_a_pass(self):
        self.source.write_text('id\n')
        self.target.write_text('id\n')
        with self.assertRaisesRegex(ValueError, 'empty'):
            compare_exports(self.source, self.target, ['id'])
        self.target.write_text('other\n1\n')
        with self.assertRaises(ValueError):
            compare_exports(self.source, self.target, ['id'])

    def test_hard_case_checklist_is_not_a_result(self):
        path = self.root / 'design.md'
        path.write_text('Text mentions H-99\n### H-01 — Packages\n- **Prediction:** partial\n'
                        '### H-02 — Autonomous transactions\n- **Prediction:** review task\n')
        cases = hard_cases(path)['cases']
        self.assertEqual([c['id'] for c in cases], ['H-01', 'H-02'])
        self.assertTrue(all(c['status'] == 'not_tested' for c in cases))
        self.assertIn('partial', cases[0]['prediction'])

    def test_real_report_can_be_imported_without_sql(self):
        report = Path(__file__).resolve().parents[1] / 'docs/conversion-report/object_mapping_summary.csv'
        q = Queue(self.root / 'real-report')
        result = q.initialize(report)
        self.assertEqual(result['input']['report_rows'], 2507)
        self.assertEqual(result['input']['source_groups'], 1706)
        self.assertGreater(result['tasks'], 0)
        self.assertEqual(result['states'], {'queued': result['tasks']})


if __name__ == '__main__':
    unittest.main()
