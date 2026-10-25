#!/usr/bin/env python3
"""Run additive accepted-label regression. Requires a built XCTest bundle; never edits goldens."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('accepted_review_catalog', REPO / 'scripts/build-sequence-review-report.py')
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)
SELECTOR = 'RAWMasterImagingTests.SequenceAcceptedAnnotationTests/testAcceptedHumanGroupingRegression'


def executable_path(bundle):
    if bundle.suffix != '.xctest':
        raise ValueError('Expected a .xctest bundle')
    return bundle / 'Contents/MacOS' / bundle.stem


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(repository):
    paths = sorted(set(repository.glob('Sources/**/*.swift')) | set(repository.glob('Tests/**/*.swift')) |
                   set(repository.glob('scripts/*.py')) | set(repository.glob('scripts/*.cjs')) |
                   set(repository.glob('scripts/sequence-review-report/*.js')) |
                   set(repository.glob('scripts/*.json')) | {repository / 'Package.swift'})
    files = [{'path': str(p.relative_to(repository)), 'sha256': digest(p)} for p in paths]
    return {'files': files, 'sha256': hashlib.sha256(review.encoded(files)).hexdigest()}


def validate_mirror(swift, scored):
    expected = {(r['caseID'], r['variant'], r['associationPolicy']): r for r in swift['score']['rows']}
    if len(expected) != len(scored['rows']):
        raise ValueError('Swift/JS scoring row counts differ')
    for row in scored['rows']:
        key = (row['caseID'], row['variant'], row['associationPolicy'])
        old = expected[key]
        if old['counts'] != row['counts'] or old['groups'] != row['groups']:
            raise ValueError('Swift scorer differs from annotation UI model: ' + str(key))
        if old['errors'] != [{k: e[k] for k in ('firstOrdinal', 'result')} for e in row['errors']]:
            raise ValueError('Swift/JS error details differ')


def timings(predictions):
    rows = []
    for case in predictions['cases']:
        for variant in case['variants']:
            samples = variant['engineSeconds']
            if not samples or not all(isinstance(x, (int, float)) and math.isfinite(x) and x >= 0 for x in samples):
                raise ValueError('Invalid timing samples')
            rows.append({'caseID': case['id'], 'variant': variant['variant'], 'associationPolicy': variant['associationPolicy'],
                         'engineSeconds': samples, 'medianEngineSeconds': statistics.median(samples),
                         'preparationSeconds': case['preparationSeconds'],
                         'engineManagedPeakEstimateBytes': variant['engineManagedPeakEstimateBytes']})
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, help='Built RAWMasterImagingTests.xctest bundle')
    parser.add_argument('--predictions', type=Path, help='Score an already sealed prediction and its .score.json receipt')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3, choices=range(1, 11))
    args = parser.parse_args()
    if bool(args.binary) == bool(args.predictions):
        parser.error('Choose exactly one of --binary or --predictions')
    output = args.output.resolve()
    if not output.is_relative_to((REPO / 'output').resolve()) or output.exists():
        parser.error('Use a new directory under this checkout/output')
    output.mkdir(parents=True)
    frozen = snapshot(REPO)
    predictions_path = args.predictions.resolve() if args.predictions else output / 'predictions.json'
    execution = {'mode': 'score-existing' if args.predictions else 'execute-xctest', 'selector': SELECTOR}
    if args.binary:
        binary = args.binary.resolve()
        executable = executable_path(binary)
        execution['executableSHA256'] = digest(executable)
        environment = dict(os.environ, RAWMASTER_ACCEPTED_REPORT=str(predictions_path), RAWMASTER_ACCEPTED_REPEATS=str(args.repeats))
        with (output / 'swift.log').open('w') as stream:
            result = subprocess.run(['xcrun', 'xctest', '-XCTest', SELECTOR, str(binary)], cwd=REPO,
                                    env=environment, stdout=stream, stderr=subprocess.STDOUT, timeout=900)
        execution['exitCode'] = result.returncode
        if not predictions_path.is_file():
            raise ValueError('Inference did not seal predictions; see swift.log')
        if digest(executable) != execution['executableSHA256']:
            raise ValueError('Test executable changed during regression')
    if snapshot(REPO) != frozen:
        raise ValueError('Source files changed during regression; rerun once implementation is frozen')
    predictions = review.read_json(predictions_path)
    swift = review.read_json(Path(str(predictions_path) + '.score.json'))
    if swift['predictionSHA256'] != digest(predictions_path) or swift['analysisSealedBeforeLabels'] is not True:
        raise ValueError('Prediction seal mismatch')
    # Only now open human labels through the UI's canonical model. No label data enters inference.
    fixture = REPO / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'
    catalog = review.jpeg_annotation_projection(review.build_catalog(fixture, review.default_sources(REPO), sources_base=REPO), ['dji187-context376'])
    catalog_path = output / 'catalog.json'; catalog_path.write_bytes(review.encoded(catalog))
    accepted = REPO / 'Tests/Fixtures/SequenceGroupingAnnotations/v1/accepted-revision.json'
    receipt = review.read_json(accepted.with_name('receipt.json'))
    if digest(accepted) != receipt['acceptedRevisionSHA256']:
        raise ValueError('Accepted revision receipt mismatch')
    scored = json.loads(subprocess.run(['node', str(REPO / 'scripts/sequence-accepted-score.cjs'), str(catalog_path), str(accepted), str(predictions_path)],
                                      check=True, capture_output=True, text=True).stdout)
    validate_mirror(swift, scored)
    document = {'schemaVersion': 1, 'kind': 'accepted-annotation-regression', 'execution': execution,
                'predictionPath': str(predictions_path.relative_to(REPO)), 'predictionSHA256': digest(predictions_path),
                'acceptedRevisionSHA256': digest(accepted), 'sourceSnapshot': frozen,
                'sourceSnapshotScope': 'scoring-only; inference source identity not recaptured' if args.predictions else 'unchanged throughout this inference and scoring run', 'scoringCrossCheck': 'Swift == annotation UI JS model',
                'evaluation': scored, 'timings': timings(predictions), 'timingBoundary': predictions['timingBoundary'],
                'platform': predictions['platform']}
    if snapshot(REPO) != frozen or digest(predictions_path) != swift['predictionSHA256']:
        raise ValueError('Sources or sealed predictions changed while scoring')
    (output / 'report.json').write_bytes(review.encoded(document))
    print(json.dumps({'qualityPassed': scored['qualityPassed'], 'totals': scored['totals'], 'report': str(output / 'report.json')}, ensure_ascii=False))
    return 0 if scored['qualityPassed'] and execution.get('exitCode', 0) == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
