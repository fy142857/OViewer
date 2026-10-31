"""Summarize observed device frame waits; never impute or drop timed-out turns."""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path
from statistics import median


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def summary(records):
    samples = [s for record in records for s in record['samples']]
    waits = [s['wait_after_scroll_ms'] for s in samples]
    displays = [s['display_ms'] for s in samples]
    events = [e for r in records for e in r['http']['events']]
    return dict(cases=len(records), turns=len(samples),
                mean_wait_ms=round(sum(waits) / len(waits), 2), total_wait_ms=round(sum(waits), 2),
                median_wait_ms=round(median(waits), 2), p95_wait_ms=round(percentile(waits, .95), 2),
                median_display_ms=round(median(displays), 2), p95_display_ms=round(percentile(displays, .95), 2),
                waits_over_100ms=sum(w > 100 for w in waits), timeouts=sum(s['timeout'] for s in samples),
                link_misses=sum(not s['links_ready'] for s in samples),
                file_misses=sum(not s['files_ready'] for s in samples),
                median_entry_ms=round(median(r['entry_ms'] for r in records), 2),
                html_requests=sum(e['kind'] == 'html' for e in events),
                image_requests=sum(e['kind'] == 'image' for e in events),
                response_bytes=sum(e['bytes'] for e in events))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('input')
    parser.add_argument('--stage', default='screen')
    parser.add_argument('--output', required=True)
    parser.add_argument('--plan', help='Require every listed case for each lead (final audit)')
    parser.add_argument('--leads', help='Optional comma-separated comparison variants')
    args = parser.parse_args()
    records = [json.loads(line) for line in Path(args.input).read_text(encoding='utf-8').splitlines() if line.strip()]
    stages = args.stage.split(',')
    leads = None if args.leads is None else {int(x) for x in args.leads.split(',')}
    records = [r for r in records if r['plan'].get('stage') in stages
               and (leads is None or r['lead'] in leads)]
    if not records:
        raise ValueError('No measured cases')
    by_lead = defaultdict(list)
    cohorts = defaultdict(lambda: defaultdict(list))
    identities = set()
    def case_key(plan):
        return (plan['profile'], plan['n'], plan['mode'], plan['double'], plan['pace_ms'], plan.get('backward', False))
    for record in records:
        plan = record['plan']
        key = case_key(plan)
        identity = (record['lead'], key, plan['repeat'])
        if identity in identities:
            raise ValueError(f'Duplicate case: {identity}')
        identities.add(identity)
        if len(record['samples']) != plan['turns']:
            raise ValueError('Missing measured turns')
        if record['http']['active'] != 0:
            raise ValueError('HTTP evidence was collected before requests finished')
        if (args.plan or args.stage.startswith(('clean', 'existing'))) and record.get('cache_before_bytes') != 0:
            raise ValueError('Uncontrolled cache state in comparison')
        if any(s['timeout'] for s in record['samples']):
            raise ValueError('Timed-out turn: cannot claim a successful measurement')
        if record.get('driver_revision') == 2:
            for sample in record['samples']:
                if plan['mode'] == 2:
                    if not set(sample['pages']).issubset(sample['visible_pages']):
                        raise ValueError('Vertical target did not reach the measured viewport')
                elif sample['current_page'] not in sample['pages']:
                    raise ValueError('Horizontal target did not become the current page')
        if plan['mode'] != 2:
            size = 2 if plan['double'] else 1
            targets = [40, *(p for s in record['samples'] for p in s['pages'])]
            low = max(0, (min(targets) // size - plan['n']) * size)
            high = min(120, (max(targets) // size + plan['n'] + 1) * size)
            if any(e['kind'] == 'image' and not low <= e['page'] < high
                   for e in record['http']['events']):
                raise ValueError('An image was downloaded outside the visited image windows')
            link_low = max(0, low - record['lead'] * size)
            link_high = min(120, high + record['lead'] * size)
            if any(e['kind'] == 'html' and not link_low <= e['page'] < link_high
                   for e in record['http']['events']):
                raise ValueError('A link was fetched outside the visited link windows')
        by_lead[record['lead']].append(record)
        cohorts[str(key)][record['lead']].append(record)
    if args.plan:
        plan = json.loads(Path(args.plan).read_text(encoding='utf-8-sig'))
        expected = {(lead, case_key(p), p['repeat'])
                    for lead in (leads or by_lead.keys()) for p in plan if p['stage'] in stages}
        if identities != expected:
            raise ValueError(f'Incomplete matrix: missing={expected-identities}, unexpected={identities-expected}')
        expected_plans = {(case_key(p), p['repeat']): p for p in plan if p['stage'] in stages}
        for record in records:
            p = record['plan']
            if p != expected_plans[(case_key(p), p['repeat'])]:
                raise ValueError('Measured case configuration does not match the plan')
    result = dict(stage=args.stage,
                  overall={lead: summary(rows) for lead, rows in sorted(by_lead.items())},
                  cohorts={key: {lead: summary(rows) for lead, rows in sorted(group.items())}
                           for key, group in sorted(cohorts.items())})
    Path(args.output).write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(json.dumps(result['overall'], ensure_ascii=False))


if __name__ == '__main__':
    main()
