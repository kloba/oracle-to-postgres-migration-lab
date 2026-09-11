"""Regressions for hard_cases catalog-vs-design format selection (gap-sweep G2).

A markdown --design whose first non-blank character is '[' (a ``[TOC]`` marker
or a ``[ref]: url`` reference link) must still be read as a markdown design, not
misrouted to the JSON-catalog reader. The explicit --catalog path and the
invalid-JSON fail-closed behaviour must be preserved, as must the bundled design.

Self-contained; does not touch the baseline suite in test_migration_team.py.
"""
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from migration_team.cli import main
from migration_team.evidence import hard_cases

DESIGN_WITH_LEADING_BRACKET = (
    "[TOC]\n"
    "[ref]: https://example.invalid/spec\n\n"
    "# Hard cases\n\n"
    "### H-01 - Packages\n- **Prediction:** partial\n\n"
    "### H-02 - Autonomous transactions\n- **Prediction:** review task\n"
)


class HardCaseFormatSelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    # --- G2: a markdown design that opens with '[' is not misread as JSON ---

    def test_design_with_leading_bracket_via_explicit_markdown(self):
        path = self.root / 'design.md'
        path.write_text(DESIGN_WITH_LEADING_BRACKET, encoding='utf-8')
        cases = hard_cases(path, as_catalog=False)['cases']
        self.assertEqual([c['id'] for c in cases], ['H-01', 'H-02'])

    def test_cli_cases_design_flag_reads_markdown_even_with_leading_bracket(self):
        path = self.root / 'design.md'
        path.write_text(DESIGN_WITH_LEADING_BRACKET, encoding='utf-8')
        out = self.root / 'checklist.json'
        code = self._run(['cases', '--design', str(path), '--output', str(out)])
        self.assertEqual(code, 0)
        cases = json.loads(out.read_text())['cases']
        self.assertEqual([c['id'] for c in cases], ['H-01', 'H-02'])

    def test_auto_detect_still_misroutes_only_when_format_unstated(self):
        # Backward-compat: a direct caller that does NOT pass as_catalog keeps the
        # first-char sniff, so a leading '[' is treated as (empty) JSON and fails
        # closed -- the exact legacy behaviour, unchanged for None.
        path = self.root / 'design.md'
        path.write_text(DESIGN_WITH_LEADING_BRACKET, encoding='utf-8')
        with self.assertRaises(ValueError):
            hard_cases(path)  # as_catalog=None -> sniff '[' -> JSON reader -> raises

    # --- Preserve explicit --catalog JSON support and invalid-JSON fail-closed ---

    def test_explicit_catalog_flag_parses_json(self):
        path = self.root / 'catalog.json'
        path.write_text(json.dumps({'cases': [{'id': 'PKG-1', 'title': 'Packages'},
                                               {'id': 'WH-2'}]}))
        cases = hard_cases(path, as_catalog=True)['cases']
        self.assertEqual([c['id'] for c in cases], ['PKG-1', 'WH-2'])

    def test_cli_catalog_flag_invalid_json_fails_closed(self):
        path = self.root / 'catalog.json'
        path.write_text('{ this is not valid json ')
        code = self._run(['cases', '--catalog', str(path)])
        self.assertEqual(code, 2)  # ValueError/JSONDecodeError -> clean nonzero exit

    def test_explicit_markdown_flag_on_json_file_has_no_headings(self):
        # A JSON file forced through the markdown reader fails closed with the
        # design error, not a JSON parse (flags mean what they say).
        path = self.root / 'catalog.json'
        path.write_text(json.dumps({'cases': [{'id': 'A'}]}))
        with self.assertRaisesRegex(ValueError, 'no case-id headings'):
            hard_cases(path, as_catalog=False)

    # --- The bundled lab design still yields its H-NN cases via --design ---

    def test_bundled_design_still_parses_under_explicit_markdown(self):
        design = Path(__file__).resolve().parents[1] / 'docs/design.md'
        if not design.is_file():
            self.skipTest('bundled design.md not present')
        auto = [c['id'] for c in hard_cases(design)['cases']]
        forced = [c['id'] for c in hard_cases(design, as_catalog=False)['cases']]
        self.assertEqual(auto, forced)
        self.assertTrue(all(cid.startswith('H-') for cid in forced))
        self.assertTrue(forced)

    def _run(self, argv):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return main(argv)


if __name__ == '__main__':
    unittest.main()
