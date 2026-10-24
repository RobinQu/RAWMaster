#!/usr/bin/env python3
"""Require complete performance evidence and optionally compare equivalent release runs."""
import argparse
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(directory, measure_only=False):
    ui = json.loads((directory / 'ui.json').read_text())
    image = json.loads((directory / 'image.json').read_text())
    require(ui['build'] == image['build'] == 'release', 'Both benchmarks must be release builds')
    require(not ui['failures'], 'UI benchmark reported failed or timed-out samples')
    surfaces = {m['surface']: m for m in ui['surfaces']}
    require(set(surfaces) == {'grid', 'filmstrip'}, 'Both real input surfaces are required')
    for name, metric in surfaces.items():
        require(metric['eventToSelection']['count'] >= 30, name + ' needs at least 30 changed selections')
        require(metric['eventToViewUpdate']['count'] == metric['eventToSelection']['count'], name + ' lost view updates')
    require(image['status'] == 'passed', 'Image benchmark did not finish successfully')
    if not measure_only:
        require(ui['mode'] == 'budget-gated', 'UI report did not enable regression timing gates')
        require(image.get('timingGatesEnabled') is True, 'Image report did not enable regression timing gates')
        for name, metric in surfaces.items():
            for field, p95, maximum in (('eventToSelection', 100, 150), ('eventToViewUpdate', 150, 250)):
                require(metric[field]['p95Ms'] <= p95 and metric[field]['maxMs'] <= maximum, name + '.' + field + ' failed absolute limits')
    metrics = {m['name']: m for m in image['metrics']}
    for name, minimum in {'embedded_preview_app_cache_cold': 30, 'true_raw_app_cache_cold': 30,
                          'embedded_preview_warm_cache': 100, 'true_raw_warm_cache': 50,
                          'compare_2_native_raw': 3, 'compare_3_native_raw': 3,
                          'compare_4_native_raw': 3, 'sequential_preview_navigation': 15,
                          'rapid_navigation_cancel_burst': 1,
                          'canvas_1_fit': 30, 'canvas_1_zoom-pan': 30,
                          'canvas_2_fit': 30, 'canvas_2_zoom-pan': 30,
                          'canvas_4_fit': 30, 'canvas_4_zoom-pan': 30}.items():
        require(name in metrics and metrics[name]['count'] >= minimum, name + ' lacks required samples')
    require(len(image['fixtures']) >= 15, 'Fifteen distinct real RAW fixtures are required')
    if not measure_only:
        gates = {g['metric']: g for g in image.get('gates', [])}
        require(set(gates) == set(metrics), 'Image timing gates must cover every measured operation')
        for name, metric in metrics.items():
            gate = gates[name]
            require(gate['passed'] is True, name + ' has a failed image gate')
            require(metric['p95Milliseconds'] <= gate['p95LimitMilliseconds'] and metric['maxMilliseconds'] <= gate['maxLimitMilliseconds'], name + ' exceeds its reported limits')
            if gate.get('relativeP95LimitMilliseconds') is not None:
                require(metric['p95Milliseconds'] <= gate['relativeP95LimitMilliseconds'], name + ' exceeds its relative limit')
    return ui, image


def compare(current, baseline):
    ui, image = current
    old_ui, old_image = baseline
    for key in ('hardwareModel', 'physicalMemory', 'operatingSystem', 'build'):
        require(image[key] == old_image[key], 'Baseline differs in ' + key + '; record a new baseline explicitly')
    require(ui['assetCount'] == old_ui['assetCount'] and ui['fixture'] == old_ui['fixture'], 'UI fixture changed')
    require(image['fixtures'] == old_image['fixtures'], 'RAW fixture metadata changed')
    old_surfaces = {m['surface']: m for m in old_ui['surfaces']}
    for metric in ui['surfaces']:
        prior = old_surfaces[metric['surface']]
        for field, floor in (('eventToSelection', 5), ('eventToViewUpdate', 20)):
            budget = max(floor, prior[field]['p95Ms'] * 1.5)
            require(metric[field]['p95Ms'] <= budget,
                    f"{metric['surface']}.{field}: p95 exceeds equivalent baseline +50% / {floor}ms jitter floor")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--baseline-dir', type=Path)
    parser.add_argument('--measure-only', action='store_true')
    args = parser.parse_args()
    try:
        current = load(args.directory, measure_only=args.measure_only)
        if args.baseline_dir and not args.measure_only:
            compare(current, load(args.baseline_dir, measure_only=True))
        result = ({'status': 'baseline-recorded', 'regressionPassed': None, 'timingGatesRequired': False}
                  if args.measure_only else {'status': 'regression-passed', 'passed': True, 'baselineCompared': bool(args.baseline_dir)})
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = {'passed': False, 'error': str(error)}
    args.directory.mkdir(parents=True, exist_ok=True)
    (args.directory / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result.get('passed') is True or result.get('status') == 'baseline-recorded' else 1


if __name__ == '__main__':
    raise SystemExit(main())
