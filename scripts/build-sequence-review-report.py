#!/usr/bin/env python3
"""Build an offline, hash-bound review of existing reduced JPEGs; never opens originals."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import sys


class InvalidReport(ValueError):
    pass


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise InvalidReport('Duplicate JSON key: ' + key)
        value[key] = item
    return value


def read_bound_json(path):
    raw = path.read_bytes()
    return json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object), sha_bytes(raw)


def read_json(path):
    return read_bound_json(path)[0]


def sha_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha_file(path):
    with path.open('rb') as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def contained(root, relative):
    item = pathlib.PurePosixPath(relative)
    if item.is_absolute() or not item.parts or any(p in ('..', '.') for p in item.parts) or '//' in relative or '\x00' in relative:
        raise InvalidReport('Unsafe relative path: ' + relative)
    result = (root / relative).resolve(strict=True)
    if not result.is_relative_to(root.resolve()):
        raise InvalidReport('Escaping fixture path: ' + relative)
    return result


def bound_json(root, relative, expected):
    path = contained(root, relative)
    document, digest = read_bound_json(path)
    if digest != expected:
        raise InvalidReport('Fixture control hash mismatch: ' + relative)
    return document


def ranges_of(record):
    behavior = record.get('behavior', record)
    result = behavior.get('result', record.get('analysis', {}).get('result', {}))
    ranges = record.get('fileRanges', record.get('ranges', result.get('ranges')))
    if ranges is None:
        raise InvalidReport('Algorithm artifact has no per-file ranges')
    return ranges


def normalized_units(document, spec):
    if spec['format'] == 'behavior':
        units = document['cases']
    elif spec['format'] == 'quality':
        units = document if isinstance(document, list) else document['quality']
    elif spec['format'] == 'probe':
        units = [document]
    else:
        raise InvalidReport('Unknown artifact format')
    for unit in units:
        identity = unit.get('identity', {})
        case_id = identity.get('caseID') or unit.get('caseID') or unit.get('id') or spec.get('caseID')
        variant = identity.get('variant') or unit.get('variant') or spec.get('variant', 'baseline')
        if spec.get('variants') and variant not in spec['variants']:
            continue
        behavior = unit.get('behavior', unit)
        metrics = behavior.get('evaluation', unit.get('metrics', unit.get('evaluation', unit)))
        yield {'id': spec['id'] + ':' + variant, 'title': spec.get('title', spec['id']) + ' · ' + variant,
               'phase': spec.get('phase', spec['id']), 'variant': variant, 'caseID': case_id,
               'ranges': ranges_of(unit), 'metrics': {key: metrics.get(key) for key in (
                   'truePositive', 'falsePositive', 'falseNegative', 'trueNegative', 'precision', 'recall',
                   'typedCoverage', 'exactGroupFraction', 'unknownPositivePairs', 'unknownNegativePairs', 'failures')},
               'resultSHA256': unit.get('resultSHA256'), 'analysisSealSHA256': unit.get('analysisSealSHA256', unit.get('analysisSHA256')),
               'associationAssumed': unit.get('associationHypothesisAssumed', 'assumed' in variant),
               'metricsMeaning': unit.get('metricsMeaning', 'manifest adjacent labeled edges'),
               'pairPrecision': unit.get('pairPrecision'), 'negativeAssessments': metrics.get('negativePairs', []), 'sourceArtifactID': spec['id']}


def known_edges(case):
    assets = case['assets']; by_id = {a['assetID']: a['ordinal'] for a in assets}
    edges = {}
    for group in case['truth']['groups']:
        members = {by_id[item] for item in group['assetIDs']}
        for first in sorted(members):
            if first + 1 in members:
                edges[first] = 'same'
    for pair in case['truth']['negativePairs']:
        first, second = sorted((by_id[pair['from']], by_id[pair['to']]))
        if second != first + 1 or edges.get(first) == 'same':
            raise InvalidReport('Non-adjacent or contradictory truth edge')
        edges[first] = 'separate'
    return edges


def memberships(ranges, count):
    membership = {}
    for index, group in enumerate(ranges):
        first, last = group['range']['first'], group['range']['last']
        if type(first) is not int or type(last) is not int or not 0 <= first <= last < count:
            raise InvalidReport('Algorithm range outside manifest')
        for ordinal in range(first, last + 1):
            if ordinal in membership:
                raise InvalidReport('Overlapping algorithm ranges')
            membership[ordinal] = index
    return membership


def default_sources(repo):
    return {'artifacts': [
        {'id': 'dev4', 'title': '原始规则', 'phase': 'dev4', 'format': 'behavior', 'path': str(repo / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/baselines/behavior-v1.json')},
        *[{'id': phase, 'title': title, 'phase': phase, 'format': 'quality', 'path': str(repo / 'docs/diagnostics' / (name + '.json'))}
          for phase, title, name in [('007', '空间连续性', 'spatial-cv-v1-summary'), ('008', '元数据事件', 'metadata-sequence-v1-summary'), ('009', '暂停桥接', 'metadata-pause-bridge-v1-summary')]]], 'attributions': []}


def validate_reviews(document, catalog):
    if document is None:
        return {'reviewMethod': '尚未提供视觉复核', 'reviews': [], 'limitations': ['未提供实际视觉复核记录；报告不推测视觉结论。']}
    if document.get('schemaVersion') != 1 or document.get('datasetIndexSHA256') != catalog['indexSHA256'] or not str(document.get('reviewMethod', '')).startswith('Codex native image inspection'):
        raise InvalidReport('Visual review is not bound to this dataset/method')
    cases = {case['id']: case for case in catalog['cases']}; seen = set()
    for review in document['reviews']:
        if not review['id'] or review['id'] in seen or review['caseID'] not in cases:
            raise InvalidReport('Invalid visual review identity')
        seen.add(review['id']); assets = cases[review['caseID']]['assets']
        ordinals, hashes = review['ordinals'], review['imageSHA256']
        if not ordinals or len(set(ordinals)) != len(ordinals) or len(ordinals) != len(hashes):
            raise InvalidReport('Visual review images must be exact parallel lists')
        for ordinal, digest in zip(ordinals, hashes):
            if type(ordinal) is not int or not 0 <= ordinal < len(assets) or assets[ordinal]['jpegSHA256'] != digest:
                raise InvalidReport('Visual review image hash/ordinal mismatch')
        if review['labelAssessment'] not in ('retain', 'human-review', 'unknown') or review['confidence'] not in ('high', 'medium', 'low'):
            raise InvalidReport('Invalid visual review assessment')
        for key in ('observations', 'attribution', 'recommendation'):
            text = review[key]
            if not isinstance(text, str) and not (isinstance(text, list) and all(isinstance(t, str) for t in text)):
                raise InvalidReport('Visual review text must be text or text list')
    return document


def build_catalog(fixture_root, sources=None, visual_review=None, sources_base=None):
    fixture_root = fixture_root.resolve(); index_path = fixture_root / 'index.json'; index, index_digest = read_bound_json(index_path)
    catalog = {'schemaVersion': 1, 'datasetID': index['datasetID'], 'indexSHA256': index_digest, 'cases': [], 'algorithms': [], 'artifacts': [], 'errors': [], 'attributions': []}
    for item in index['cases']:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', item['id']): raise InvalidReport('Unsafe case ID')
        manifest = bound_json(fixture_root, item['manifestPath'], item['manifestSHA256'])
        truth = bound_json(fixture_root, item['truthPath'], item['truthSHA256'])
        bound_json(fixture_root, item['metadataPath'], item['metadataSHA256'])
        assets = []
        if len(manifest['files']) != item['assetCount']:
            raise InvalidReport('Case count differs from manifest')
        for ordinal, value in enumerate(manifest['files']):
            if not re.fullmatch(r'[A-Za-z0-9_-]+', value['assetID']) or value['ordinal'] != ordinal or value['assetID'] in {a['assetID'] for a in assets}:
                raise InvalidReport('Unordered/duplicate manifest asset')
            source = value['sourceCapture']
            assets.append({'caseID': item['id'], 'assetID': value['assetID'], 'ordinal': ordinal,
                'filename': pathlib.PurePosixPath(source['relativePath']).name, 'originalRelativePath': source['relativePath'],
                'originalSHA256': source['sha256'], 'jpegSHA256': value['jpegSHA256'],
                'fixturePath': str(pathlib.PurePosixPath(item['manifestPath']).parent / value['relativePath']),
                'width': value['width'], 'height': value['height'], 'thumbnail': 'thumbnails/' + item['id'] + '/' + value['assetID'] + '.jpg'})
        case = {'id': item['id'], 'manifestSHA256': item['manifestSHA256'], 'truthSHA256': item['truthSHA256'], 'metadataSHA256': item['metadataSHA256'],
            'completeGroupTruth': item['completeGroupTruth'], 'unknownAssetIDs': item.get('unknownAssetIDs', []), 'assets': assets, 'truth': truth, 'algorithms': []}
        allowed = {a['assetID'] for a in assets}
        if any(a not in allowed for g in truth['groups'] for a in g['assetIDs']) or not set(case['unknownAssetIDs']) <= allowed:
            raise InvalidReport('Truth references unknown asset')
        known_edges(case); catalog['cases'].append(case)
    if sum(len(c['assets']) for c in catalog['cases']) != index['assetCount']:
        raise InvalidReport('Dataset count mismatch')
    case_by_id = {c['id']: c for c in catalog['cases']}; algorithms = {}
    source_ids = set()
    for spec in sources['artifacts']:
        if spec['id'] in source_ids:
            raise InvalidReport('Duplicate artifact ID')
        source_ids.add(spec['id']); path = pathlib.Path(spec['path'])
        if not path.is_absolute(): path = sources_base / path
        document, digest = read_bound_json(path)
        catalog['artifacts'].append({'id': spec['id'], 'path': str(path), 'sha256': digest, 'phase': spec.get('phase', spec['id'])})
        added = 0
        for unit in normalized_units(document, spec):
            if unit['caseID'] not in case_by_id: raise InvalidReport('Artifact references unknown case')
            case = case_by_id[unit['caseID']]
            if any(u['id'] == unit['id'] for u in case['algorithms']): raise InvalidReport('Duplicate algorithm/case input')
            membership = memberships(unit['ranges'], len(case['assets']))
            edges = []
            for first, expected in known_edges(case).items():
                joined = first in membership and membership[first] == membership.get(first + 1)
                assessment = next((p for p in unit['negativeAssessments'] if {p.get('from'), p.get('to')} == {case['assets'][first]['assetID'], case['assets'][first + 1]['assetID']}), None)
                negative_unknown = (assessment is not None and not assessment.get('decidable', False)) or (assessment is None and (unit['metrics'].get('unknownNegativePairs') or 0) > 0)
                outcome = 'TP' if expected == 'same' and joined else 'FN' if expected == 'same' else 'FP' if joined else 'unknown' if negative_unknown else 'TN'
                edges.append({'firstOrdinal': first, 'expected': expected, 'outcome': outcome})
            unit['edges'] = edges
            unit['derivedEdgeCounts'] = {key: sum(e['outcome'] == key for e in edges) for key in ('TP', 'FP', 'FN', 'TN')}
            for short, sealed in [('TP', 'truePositive'), ('FP', 'falsePositive'), ('FN', 'falseNegative'), ('TN', 'trueNegative')]:
                expected = unit['metrics'].get(sealed)
                if expected is not None and (type(expected) is not int or expected != unit['derivedEdgeCounts'][short]):
                    raise InvalidReport('Derived edge count disagrees with sealed metric: ' + unit['id'] + '/' + case['id'] + '/' + sealed)
            case['algorithms'].append(unit); added += 1
            algorithms[unit['id']] = {k: unit[k] for k in ('id', 'title', 'phase', 'variant')}
        if not added: raise InvalidReport('Artifact matched no requested quality units')
    for case in catalog['cases']:
        union = {}
        for unit in case['algorithms']:
            for edge in unit['edges']:
                if edge['outcome'] not in ('FP', 'FN'): continue
                first = edge['firstOrdinal']; left, right = case['assets'][first:first + 2]
                if first not in union:
                    union[first] = {'id': case['id'] + ':' + left['assetID'] + ':' + right['assetID'], 'caseID': case['id'],
                        'firstOrdinal': first, 'leftAssetID': left['assetID'], 'rightAssetID': right['assetID'], 'expected': edge['expected'], 'occurrences': []}
                union[first]['occurrences'].append({'algorithmID': unit['id'], 'outcome': edge['outcome']})
        catalog['errors'].extend(union.values())
    for attribution in sources.get('attributions', []):
        case = case_by_id[attribution['caseID']]
        if attribution['rightOrdinal'] != attribution['leftOrdinal'] + 1 or not 0 <= attribution['leftOrdinal'] < len(case['assets']) - 1:
            raise InvalidReport('Invalid attribution edge')
        if attribution['category'] not in ('temporal-rule', 'visual-rule', 'capture-representation', 'metadata-clock', 'user-intent', 'unresolved'):
            raise InvalidReport('Unknown attribution category')
        catalog['attributions'].append(attribution)
    catalog['algorithms'] = list(algorithms.values()); catalog['assetCount'] = index['assetCount']
    catalog['visualReview'] = validate_reviews(visual_review, catalog)
    catalog['binding'] = {'indexSHA256': catalog['indexSHA256'], 'truthSHA256ByCase': {c['id']: c['truthSHA256'] for c in catalog['cases']},
        'assetBindings': [{k: a[k] for k in ('caseID', 'assetID', 'ordinal', 'jpegSHA256', 'originalSHA256')} for c in catalog['cases'] for a in c['assets']]}
    catalog['catalogSHA256'] = sha_bytes(encoded(catalog))
    return catalog


def thumbnail(source, destination):
    try:
        from PIL import Image
    except ImportError as error:
        raise InvalidReport('Pillow is required only for report JPEG resizing; use the configured workspace Python') from error
    with Image.open(source) as image:
        image.load(); image = image.convert('RGB'); image.thumbnail((384, 384), Image.Resampling.LANCZOS)
        image.save(destination, format='JPEG', quality=80, subsampling=2, optimize=False, progressive=False)
        return {'width': image.width, 'height': image.height}


def jpeg_annotation_projection(catalog, case_ids):
    """Create a separate annotation dataset, preserving the sealed file-level source."""
    selected = set(case_ids)
    if not selected or not selected <= {c['id'] for c in catalog['cases']}:
        raise InvalidReport('JPEG annotation selection is empty or references unknown case')
    if 'annotationProjection' in catalog:
        raise InvalidReport('Annotation projection cannot be projected again')
    result = json.loads(json.dumps(catalog))
    descriptor = {'policy': 'jpeg-only-annotation-v1', 'sourceBinding': json.loads(json.dumps(catalog['binding'])), 'cases': []}
    for case in result['cases']:
        if case['id'] not in selected:
            continue
        original_count = len(case['assets'])
        kept = [a for a in case['assets'] if pathlib.PurePosixPath(a['filename']).suffix.lower() in ('.jpg', '.jpeg')]
        if len(kept) < 2:
            raise InvalidReport('JPEG annotation requires at least two JPEG captures')
        allowed = {a['assetID'] for a in kept}
        descriptor['cases'].append({'caseID': case['id'], 'sourceCount': original_count,
            'keptAssetIDs': [a['assetID'] for a in kept]})
        for ordinal, asset in enumerate(kept):
            asset['sourceOrdinal'] = asset['ordinal']
            asset['ordinal'] = ordinal
        case['assets'] = kept
        case['truth']['groups'] = [{**g, 'assetIDs': [a for a in g['assetIDs'] if a in allowed]}
            for g in case['truth']['groups'] if sum(a in allowed for a in g['assetIDs']) >= 2]
        # Only explicitly labeled retained endpoints survive; never invent a negative boundary.
        case['truth']['negativePairs'] = [p for p in case['truth']['negativePairs'] if p['from'] in allowed and p['to'] in allowed]
        case['unknownAssetIDs'] = [a for a in case['unknownAssetIDs'] if a in allowed]
        case['truthSHA256'] = sha_bytes(encoded(case['truth']))
        case['annotationOnly'] = True
        case['annotationNote'] = f'仅标注 JPEG 拍摄序列：{len(kept)} 张；已排除 {original_count - len(kept)} 个非 JPEG 表示。未确认的组边界继续保持未知。历史文件级算法结果保存在旧报告，不作为此序列的评分。'
        case['algorithms'] = []
        known_edges(case)
    result['errors'] = [e for e in result['errors'] if e['caseID'] not in selected]
    result['attributions'] = [a for a in result['attributions'] if a['caseID'] not in selected]
    # Historical visual statements about DNG/JPEG pairs must not become JPEG-only claims.
    result['visualReview']['reviews'] = [r for r in result['visualReview']['reviews'] if r['caseID'] not in selected]
    result['visualReview'].setdefault('limitations', []).append('DJI 改用 JPEG 单表示标注；原 DNG/JPEG 视觉复核和文件级评分仍保存在源报告，本页不将其重解释为 JPEG 事件级评测。')
    result['annotationProjection'] = json.loads(json.dumps({'descriptor': descriptor, 'sourceCatalogSHA256': catalog['catalogSHA256'],
        'legacyCatalog': {'indexSHA256': catalog['indexSHA256'], 'binding': catalog['binding'],
            'cases': [{k: c[k] for k in ('id', 'truthSHA256', 'assets', 'truth')} for c in catalog['cases']]}}))
    result['indexSHA256'] = sha_bytes(encoded(descriptor))
    result['datasetID'] += '-jpeg-annotation-v1'
    result['assetCount'] = sum(len(c['assets']) for c in result['cases'])
    result['binding'] = {'indexSHA256': result['indexSHA256'],
        'truthSHA256ByCase': {c['id']: c['truthSHA256'] for c in result['cases']},
        'assetBindings': [{k: a[k] for k in ('caseID', 'assetID', 'ordinal', 'jpegSHA256', 'originalSHA256')}
            for c in result['cases'] for a in c['assets']]}
    result.pop('catalogSHA256', None)
    result['catalogSHA256'] = sha_bytes(encoded(result))
    return result


def generate(fixture_root, output, catalog, thumbnailer=thumbnail):
    root = fixture_root.resolve(); output = output.resolve()
    if output.exists() or output.is_relative_to(root) or root.is_relative_to(output):
        raise InvalidReport('Output must be a new directory outside fixture root and its parents')
    # Preflight every allowed path before creating any result; no directory enumeration/media neighbors.
    entries = [(a, contained(root, a['fixturePath'])) for c in catalog['cases'] for a in c['assets']]
    for asset, path in entries:
        if path.suffix.lower() not in ('.jpg', '.jpeg') or sha_file(path) != asset['jpegSHA256']:
            raise InvalidReport('JPEG hash mismatch: ' + asset['assetID'])
    output.mkdir(parents=True)
    preservation = []
    for asset, path in entries:
        destination = output / asset['thumbnail']; destination.parent.mkdir(parents=True, exist_ok=True)
        dimensions = thumbnailer(path, destination)
        if max(dimensions.values()) > 384 or sha_file(path) != asset['jpegSHA256']:
            raise InvalidReport('Thumbnail bounds or source preservation failed')
        preservation.append({'caseID': asset['caseID'], 'assetID': asset['assetID'], 'jpegSHA256BeforeAndAfter': asset['jpegSHA256'], 'thumbnailSHA256': sha_file(destination), **dimensions})
    assets = pathlib.Path(__file__).resolve().parent / 'sequence-review-report'
    document = (assets / 'index.html').read_text()
    payload = encoded(catalog).decode().replace('&', '\\u0026').replace('<', '\\u003c').replace('>', '\\u003e').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    (output / 'index.html').write_text(document.replace('__CATALOG_JSON__', payload), encoding='utf-8')
    for name in ('review.js', 'review.css'): shutil.copyfile(assets / name, output / name)
    (output / 'catalog.json').write_bytes(encoded(catalog))
    (output / 'preservation-receipt.json').write_bytes(encoded({'schemaVersion': 1, 'indexSHA256': catalog['indexSHA256'], 'assetCount': len(entries),
        'operation': 'Existing JPEG → RGB JPEG longest edge <=384; Pillow LANCZOS quality80 subsampling2, no original RAW access', 'files': preservation}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture-root', type=pathlib.Path, required=True)
    parser.add_argument('--sources', type=pathlib.Path)
    parser.add_argument('--visual-review', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--jpeg-only-case', action='append', default=[], help='Separate annotation projection; preserves source fixtures and baselines')
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parents[1]
    sources = read_json(args.sources) if args.sources else default_sources(repo)
    catalog = build_catalog(args.fixture_root, sources, read_json(args.visual_review) if args.visual_review else None,
        args.sources.resolve().parent if args.sources else repo)
    if args.jpeg_only_case:
        catalog = jpeg_annotation_projection(catalog, args.jpeg_only_case)
    generate(args.fixture_root, args.output, catalog)
    print('Built', catalog['assetCount'], 'files,', len(catalog['errors']), 'unique historical error edges:', args.output / 'index.html')


if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError, OSError) as error:
        print('Report refused: ' + str(error), file=sys.stderr); sys.exit(1)
