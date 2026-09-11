"""Focused regressions for the queue-maintenance fixes verified in
out/bugfix-review-20260911-gzvf9a7v/verified-queue.json (Q1/Q2/BASE_LIMIT).

Self-contained; does not touch the baseline suite in test_migration_team.py.
Fake validators exercise state handling only, never real SQL.
"""
import csv
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from migration_team.queue import BASE_LIMIT, COLUMNS, Queue, digest


def _mapping(kind='TABLE', name='CONTOSO.T', target='contoso.t'):
    return dict(zip(COLUMNS, (kind, name, kind, target, 'Not-Converted', 'yes', '')))


def _write_csv(path, rows):
    with path.open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    return path


def _fake_valid(candidate, checks, dependencies, **options):
    return {'status': 'passed', 'candidate_sha256': digest(candidate),
            'checks_sha256': digest(checks), 'checks': [], 'log': 'unit-test double only'}


class QueueMaintenanceRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.report = self.root / 'mapping.csv'
        self.q = Queue(self.root / 'state')

    def _init(self):
        _write_csv(self.report, [_mapping()])
        self.q.initialize(self.report, target_schemas=['contoso'])

    def _stage(self):
        self._init()
        task_id = self.q.claim('repair-1')['id']
        paths = []
        for name, text in [('source.sql', 'CREATE TABLE T (id NUMBER);'),
                           ('candidate.sql', 'CREATE TABLE t (id numeric);'),
                           ('checks.sql', "SELECT 'c' AS check_name, true AS passed;")]:
            path = self.root / name
            path.write_text(text)
            paths.append(path)
        self.q.stage(task_id, 'repair-1', *paths)
        return task_id

    # --- Q1: events(task_id, seq) index exists in a freshly-initialised queue ---

    def test_new_queue_creates_events_index(self):
        self._init()
        con = sqlite3.connect(self.q.db)
        try:
            names = {r[0] for r in con.execute(
                "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='events'")}
            self.assertIn('events_task_seq', names)
        finally:
            con.close()

    def test_budget_events_query_uses_the_index_not_a_scan(self):
        # The exact query validation_budget() runs must be planned as an indexed
        # SEARCH, not a full-table SCAN, on a fresh queue.
        task_id = self._stage()
        con = sqlite3.connect(self.q.db)
        try:
            plan = con.execute(
                "EXPLAIN QUERY PLAN "
                "SELECT seq,action,detail FROM events WHERE task_id=? ORDER BY seq",
                (task_id,)).fetchall()
            detail = ' '.join(row[-1] for row in plan)
            self.assertIn('events_task_seq', detail)
            self.assertIn('SEARCH', detail)
            self.assertNotIn('SCAN events', detail)
        finally:
            con.close()

    # --- Q2: removing the dead pre-debit assignment keeps budget accounting exact ---

    def test_validate_start_still_counts_attempts_after_deadstore_removal(self):
        # Two interrupted validate-starts under a baseline must count as 2 used,
        # exercising the baseline branch whose redundant assignment was removed.
        task_id = self._stage()

        def crash(*a, **k):
            raise RuntimeError('validator crashed mid-run')

        for _ in range(2):
            with self.assertRaises(RuntimeError):
                self.q.validate(task_id, 'repair-1', crash, 'test-double', 10)
        with self.q.connection() as c:
            task = self.q.task(c, task_id)
            budget = self.q.validation_budget(c, task)
        self.assertEqual(budget['used'], 2)
        self.assertEqual(budget['remaining'], BASE_LIMIT - 2)
        self.assertTrue(budget['within_limit'])

    def test_third_attempt_reaches_the_cap_and_blocks_further_validation(self):
        task_id = self._stage()  # already claimed by repair-1
        # Consume the full lifetime cap: validate then reject, re-claiming the
        # requeued task before each subsequent attempt.
        for i in range(BASE_LIMIT):
            if i > 0:
                self.q.claim('repair-1', task_id)
            self.q.validate(task_id, 'repair-1', _fake_valid, 'test-double', 10)
            self.q.review(task_id, 'skeptic', 'reject', 'rejected again')
        with self.q.connection() as c:
            task = self.q.task(c, task_id)
            budget = self.q.validation_budget(c, task)
        self.assertEqual(budget['used'], BASE_LIMIT)
        self.assertFalse(budget['can_validate'])
        self.assertEqual(self.q.show(task_id)['status'], 'blocked')

    # --- BASE_LIMIT: single source of truth surfaces the base cap ---

    def test_base_limit_constant_surfaced_in_ungranted_budget(self):
        task_id = self._stage()
        with self.q.connection() as c:
            task = self.q.task(c, task_id)
            budget = self.q.validation_budget(c, task)
        self.assertEqual(BASE_LIMIT, 3)
        self.assertEqual(budget['base_limit'], BASE_LIMIT)
        self.assertEqual(budget['limit'], BASE_LIMIT)  # no grant -> base cap


if __name__ == '__main__':
    unittest.main()
