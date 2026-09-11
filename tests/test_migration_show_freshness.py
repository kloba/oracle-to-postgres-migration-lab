"""Regressions for the Queue.show current-fingerprint / freshness interface.

Queue.show now exposes, in addition to the persisted task fields:
  - current_input_sha256: the authoritative CURRENT hash of the staged
    artifacts + schema/engine :config (or None when it cannot be computed),
  - evidence_fresh: bool, True only when a recorded evidence's input_sha256
    equals current_input_sha256.

A consumer (the controller crediting reviewed units) reads these to avoid
crediting a review that a later public `configure` has invalidated -- WITHOUT
the persisted 'reviewed' status flipping and without weakening any guard.

Self-contained; does not touch the baseline test_migration_team.py.
"""
import csv
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from migration_team.queue import COLUMNS, Queue, digest


def _mapping():
    return dict(zip(COLUMNS, ('TABLE', 'CONTOSO.T', 'TABLE', 'contoso.t',
                              'Not-Converted', 'yes', '')))


def _write_csv(path):
    with path.open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(COLUMNS))
        writer.writeheader()
        writer.writerow(_mapping())
    return path


def _fake_valid(candidate, checks, dependencies, **options):
    return {'status': 'passed', 'candidate_sha256': digest(candidate),
            'checks_sha256': digest(checks), 'checks': [], 'log': 'unit-test double'}


class ShowFreshnessInterface(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.report = self.root / 'mapping.csv'
        self.q = Queue(self.root / 'state')

    def _reviewed(self, schema='contoso'):
        _write_csv(self.report)
        self.q.initialize(self.report, target_schemas=[schema])
        task_id = self.q.claim('repair-1')['id']
        paths = []
        for name, text in [('source.sql', 'CREATE TABLE T (id NUMBER);'),
                           ('candidate.sql', 'CREATE TABLE t (id numeric);'),
                           ('checks.sql', "SELECT 'c' AS check_name, true AS passed;")]:
            path = self.root / name
            path.write_text(text)
            paths.append(path)
        self.q.stage(task_id, 'repair-1', *paths)
        self.q.validate(task_id, 'repair-1', _fake_valid, 'test-double', 10)
        self.q.review(task_id, 'skeptic', 'accept', 'independent review')
        return task_id

    def test_fresh_review_reports_evidence_fresh_true(self):
        task_id = self._reviewed()
        s = self.q.show(task_id)
        self.assertEqual(s['status'], 'reviewed')
        self.assertTrue(s['evidence_fresh'])
        self.assertIsNotNone(s['current_input_sha256'])
        self.assertIn(':config', s['current_input_sha256'])
        self.assertEqual(s['current_input_sha256'], s['evidence']['input_sha256'])

    def test_reconfigure_persists_status_but_flips_evidence_fresh(self):
        # The exact stale-credit hazard: reviewed status persists across a public
        # configure, but evidence_fresh must go False so a consumer can detect it.
        task_id = self._reviewed()
        self.q.configure(target_schemas=['warehouse'])
        s = self.q.show(task_id)
        self.assertEqual(s['status'], 'reviewed')          # persisted, unchanged
        self.assertFalse(s['evidence_fresh'])              # but now detectably stale
        self.assertNotEqual(s['current_input_sha256'], s['evidence']['input_sha256'])

    def test_unstaged_task_is_graceful(self):
        _write_csv(self.report)
        self.q.initialize(self.report, target_schemas=['contoso'])
        task_id = self.q.claim('repair-1')['id']  # no files staged yet
        s = self.q.show(task_id)
        self.assertIsNone(s['current_input_sha256'])
        self.assertFalse(s['evidence_fresh'])

    def test_unconfigured_queue_is_graceful(self):
        # Staged files present but no target schema configured: config_digest
        # cannot be computed, so show() reports None rather than raising.
        _write_csv(self.report)
        self.q.initialize(self.report)  # no target-schema
        task_id = self.q.claim('repair-1')['id']
        wd = self.q.workdir(task_id)
        for name in ('source.sql', 'candidate.sql', 'checks.sql'):
            (wd / name).write_text('x')
        s = self.q.show(task_id)   # must not raise
        self.assertIsNone(s['current_input_sha256'])
        self.assertFalse(s['evidence_fresh'])

    def test_show_still_carries_budget_and_does_not_weaken_accept_guard(self):
        task_id = self._reviewed()
        self.q.configure(target_schemas=['warehouse'])
        # validation_budget still present and intact (grants/attempts preserved).
        s = self.q.show(task_id)
        self.assertIn('validation_budget', s)
        self.assertEqual(s['validation_budget']['used'], 1)
        # A reopened+reconfigured task cannot be re-accepted on stale evidence:
        # reviewing requires pending_review, and the accept path still hash-checks.
        # Here we assert the interface exposes staleness without touching status.
        self.assertFalse(s['evidence_fresh'])


if __name__ == '__main__':
    unittest.main()
