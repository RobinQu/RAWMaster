#!/usr/bin/env python3
"""Analyze opt-in native traces; never substitute automation tool latency for app timing."""
import argparse
import json
import math
from pathlib import Path


def summarize(values):
    ordered = sorted(values)
    return {'count': len(values), 'p50Ms': ordered[math.ceil(len(ordered) * .50) - 1],
            'p95Ms': ordered[math.ceil(len(ordered) * .95) - 1], 'maxMs': ordered[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--minimum-samples', type=int, default=30)
    parser.add_argument('--expected-card-clicks', type=int, help='Controlled run: exact number of submitted changed-card single clicks, excluding other pointer actions')
    parser.add_argument('--measure-only', action='store_true', help='Save a pre-fix baseline without enforcing latency limits')
    args = parser.parse_args()
    operations = {}
    for line in args.trace.read_text().splitlines():
        row = json.loads(line)
        operations.setdefault(row['operationID'], {})[row['event']] = row
    samples, incomplete = [], []
    for token, events in operations.items():
        commit = events.get('selection.commit')
        if not commit or not commit['changed'] or commit.get('inputKind') != 'pointer':
            continue
        if 'input.down' not in events or 'selection.view-update' not in events:
            incomplete.append(token)
            continue
        start = events['input.down']['uptimeSeconds']
        end = events['selection.view-update']['uptimeSeconds']
        selected = commit['uptimeSeconds']
        if not start <= selected <= end:
            raise ValueError('Non-monotonic correlated sample: ' + token)
        samples.append({'operationID': token, 'eventToSelectionMs': (selected-start)*1000,
                        'eventToViewUpdateMs': (end-start)*1000,
                        'selectionToViewUpdateMs': (end-selected)*1000})
    failures = []
    if args.expected_card_clicks is not None:
        downs = sum(events.get('input.down', {}).get('clickCount') == 1 for events in operations.values())
        if downs != args.expected_card_clicks or len(samples) != args.expected_card_clicks:
            failures.append(f'Expected {args.expected_card_clicks} changed card clicks; observed {downs} single-pointer downs and {len(samples)} complete selections')
    if len(samples) < args.minimum_samples:
        failures.append(f'Only {len(samples)} completed changed-selection samples; require {args.minimum_samples}')
    if incomplete:
        failures.append(f'{len(incomplete)} selection operations lack an input or view-update completion')
    metrics = {name: summarize([s[name] for s in samples]) for name in
               ('eventToSelectionMs', 'eventToViewUpdateMs', 'selectionToViewUpdateMs')} if samples else {}
    limits = {'eventToSelectionMs': {'p95Ms': 100, 'maxMs': 150},
              'eventToViewUpdateMs': {'p95Ms': 150, 'maxMs': 250}}
    if not args.measure_only:
        for metric, checks in limits.items():
            for statistic, maximum in checks.items():
                if metric in metrics and metrics[metric][statistic] > maximum:
                    failures.append(f'{metric}.{statistic} exceeds {maximum} ms')
    result = {'schemaVersion': 1, 'boundary': 'NSEvent timestamp to model selection and NSView update; NOT screen presentation',
              'percentileMethod': 'nearest rank', 'measureOnly': args.measure_only,
              'minimumSamples': args.minimum_samples, 'metrics': metrics, 'limits': limits,
              'samples': samples, 'incompleteOperations': incomplete, 'failures': failures,
              'passed': not failures}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'metrics': metrics, 'failures': failures}, indent=2))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
