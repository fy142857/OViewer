import unittest
import copy
import contextlib
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

from scripts.analyze_reader_preload_benchmark import main, percentile, summary
from scripts.reader_preload_fixture import PNG


class ReaderPreloadEvidenceTests(unittest.TestCase):
    def test_percentiles_keep_tail_waits_instead_of_averaging_them_away(self):
        samples = [1] * 18 + [200, 900]
        self.assertEqual(percentile(samples, .95), 200)
        self.assertEqual(percentile(samples, 1), 900)

    def test_summary_counts_timeouts_misses_and_actual_response_bytes(self):
        result = summary([dict(entry_ms=25, samples=[
            dict(wait_after_scroll_ms=2, display_ms=182, timeout=False, links_ready=True, files_ready=True),
            dict(wait_after_scroll_ms=10000, display_ms=10180, timeout=True, links_ready=False, files_ready=False),
        ], http=dict(events=[dict(kind='html', bytes=16384), dict(kind='image', bytes=100)]))])
        self.assertEqual(result['turns'], 2)
        self.assertEqual(result['timeouts'], 1)
        self.assertEqual(result['p95_wait_ms'], 10000)
        self.assertEqual(result['link_misses'], 1)
        self.assertEqual(result['html_requests'], 1)
        self.assertEqual(result['response_bytes'], 16484)

    def test_fixture_is_a_real_png_with_nontrivial_network_payload(self):
        self.assertEqual(PNG[:8], b'\x89PNG\r\n\x1a\n')
        self.assertGreater(len(PNG), 128 * 1024)
        self.assertLess(len(PNG), 256 * 1024)

    def test_final_audit_rejects_incomplete_or_invalid_evidence(self):
        plan = dict(profile='sample', n=3, mode=0, double=False, pace_ms=350,
                    turns=1, repeat=1, warmup_ms=2000, html_ms=1200,
                    image_ms=60, kbps=2048, stage='existing_test')
        record = dict(lead=1, plan=plan, entry_ms=100, cache_before_bytes=0,
                      driver_revision=2, samples=[dict(pages=[41], current_page=41,
                      visible_pages=[41], wait_after_scroll_ms=3, display_ms=183,
                      timeout=False, links_ready=True, files_ready=True)],
                      http=dict(active=0, events=[dict(kind='image', page=41, bytes=10)]))
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            data, plans, output = folder/'data.jsonl', folder/'plan.json', folder/'summary.json'
            plans.write_text(json.dumps([plan]), encoding='utf-8')
            argv = ['analyze', str(data), '--stage', 'existing_test', '--plan', str(plans),
                    '--leads', '1', '--output', str(output)]

            def audit(rows):
                data.write_text(''.join(json.dumps(r)+'\n' for r in rows), encoding='utf-8')
                with patch('sys.argv', argv), contextlib.redirect_stdout(io.StringIO()):
                    main()

            audit([record])
            self.assertEqual(json.loads(output.read_text())['overall']['1']['turns'], 1)
            invalid = [[], [record, record]]
            for mutate in [
                lambda r: r.update(cache_before_bytes=1),
                lambda r: r['samples'][0].update(timeout=True),
                lambda r: r['samples'][0].update(current_page=0),
                lambda r: r['http'].update(active=1),
                lambda r: r['http']['events'][0].update(page=100),
                lambda r: r['http']['events'][0].update(kind='html', page=100),
                lambda r: r['plan'].update(html_ms=1),
            ]:
                bad = copy.deepcopy(record)
                mutate(bad)
                invalid.append([bad])
            for rows in invalid:
                with self.subTest(rows=rows), self.assertRaises(ValueError):
                    audit(rows)


if __name__ == '__main__':
    unittest.main()
