import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('review_report', REPO / 'scripts/build-sequence-review-report.py')
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReviewReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.root = pathlib.Path(self.temporary.name)
        self.fixture = self.root / 'fixture'; self.fixture.mkdir()
        self.case = self.fixture / 'cases/example'; self.case.mkdir(parents=True)
        self.assets = []
        for i in range(6):
            path = self.case / ('f%d.jpg' % i); path.write_bytes(('synthetic-not-an-image-%d' % i).encode())
            self.assets.append({'assetID': 'f%d' % i, 'ordinal': i, 'relativePath': path.name, 'width': 1024, 'height': 683,
                'jpegSHA256': report.sha_file(path), 'sourceCapture': {'relativePath': 'original/F%d.ARW' % i, 'sha256': str(i) * 64}})
        truth = {'groups': [{'id': 'truth', 'kind': 'burst', 'assetIDs': ['f1', 'f2', 'f3']}], 'negativePairs': [{'from': 'f0', 'to': 'f1'}, {'from': 'f3', 'to': 'f4'}]}
        for name, value in [('manifest.json', {'files': self.assets}), ('truth.json', truth), ('metadata.json', {})]: (self.case / name).write_text(json.dumps(value))
        index_case = {'id': 'example', 'assetCount': 6, 'completeGroupTruth': True, 'unknownAssetIDs': ['f5']}
        for key, name in [('manifest', 'manifest.json'), ('truth', 'truth.json'), ('metadata', 'metadata.json')]:
            index_case[key + 'Path'] = 'cases/example/' + name; index_case[key + 'SHA256'] = report.sha_file(self.case / name)
        (self.fixture / 'index.json').write_text(json.dumps({'datasetID': 'synthetic', 'assetCount': 6, 'cases': [index_case]}))
        self.artifact = self.root / 'quality.json'
        self.artifact.write_text(json.dumps({'quality': [self.unit('split', 2, 3), self.unit('merge', 0, 4)]}))
        self.sources = {'artifacts': [{'id': 'test', 'format': 'quality', 'path': str(self.artifact)}]}

    def tearDown(self): self.temporary.cleanup()

    def unit(self, variant, first, last):
        return {'caseID': 'example', 'variant': variant, 'fileRanges': [{'kind': 'burst', 'range': {'first': first, 'last': last}}], 'metrics': {'unknownNegativePairs': 0}}

    def catalog(self): return report.build_catalog(self.fixture, self.sources, sources_base=self.root)

    def testCompleteCatalogAndFullHistoricalErrorUnionKeepUnknownUnlabeled(self):
        c = self.catalog()
        self.assertEqual(c['assetCount'], 6); self.assertEqual(len(c['cases'][0]['assets']), 6)
        self.assertEqual({e['firstOrdinal'] for e in c['errors']}, {0, 1, 3})
        self.assertNotIn(4, {e['firstOrdinal'] for e in c['errors']})
        self.assertEqual(c['cases'][0]['unknownAssetIDs'], ['f5'])
        self.assertEqual(len(c['binding']['assetBindings']), 6)
        self.assertEqual(c['visualReview']['reviews'], [])

    def testDefinedSealedEdgeCountsMustMatchAndNullCountsRemainAllowed(self):
        unit = self.unit('count-bound', 2, 3)
        counts = {'truePositive': 1, 'falsePositive': 0, 'falseNegative': 1, 'trueNegative': 2}
        unit['metrics'].update(counts)
        self.artifact.write_text(json.dumps({'quality': [unit]}))
        self.assertEqual(self.catalog()['cases'][0]['algorithms'][0]['derivedEdgeCounts'], {'TP': 1, 'FP': 0, 'FN': 1, 'TN': 2})
        for key, value in counts.items():
            unit['metrics'] = dict(counts, **{key: value + 1})
            self.artifact.write_text(json.dumps({'quality': [unit]}))
            with self.assertRaisesRegex(report.InvalidReport, 'disagrees with sealed metric'):
                self.catalog()
        unit['metrics'] = {key: None for key in counts}
        self.artifact.write_text(json.dumps({'quality': [unit]}))
        self.assertEqual(self.catalog()['cases'][0]['algorithms'][0]['derivedEdgeCounts']['TP'], 1)

    def testVisualReviewRequiresActualParallelHashBindings(self):
        base = self.catalog()
        review = {'schemaVersion': 1, 'datasetIndexSHA256': base['indexSHA256'], 'reviewMethod': 'Codex native image inspection',
            'reviews': [{'id': 'one', 'caseID': 'example', 'ordinals': [1], 'imageSHA256': [self.assets[1]['jpegSHA256']], 'observations': 'Observed only', 'attribution': [], 'labelAssessment': 'unknown', 'recommendation': 'Human decides', 'confidence': 'low'}]}
        self.assertEqual(len(report.validate_reviews(review, base)['reviews']), 1)
        review['reviews'][0]['imageSHA256'][0] = '0' * 64
        with self.assertRaises(report.InvalidReport): report.validate_reviews(review, base)

    def testControlAndPathTamperingRefuse(self):
        (self.case / 'truth.json').write_text('{}')
        with self.assertRaises(report.InvalidReport): self.catalog()
        with self.assertRaises(report.InvalidReport): report.contained(self.fixture, '../escape')
        (self.fixture / 'escape').symlink_to(self.root)
        with self.assertRaises(report.InvalidReport): report.contained(self.fixture, 'escape/quality.json')
        with self.assertRaises(report.InvalidReport): report.unique_object([('x', 1), ('x', 2)])

    def testUnknownNegativeCannotBecomeDerivedTrueNegative(self):
        unit = self.unit('unknown', 1, 3); unit['metrics']['unknownNegativePairs'] = 1
        self.artifact.write_text(json.dumps({'quality': [unit]}))
        c = self.catalog(); derived = c['cases'][0]['algorithms'][0]['derivedEdgeCounts']
        self.assertEqual(derived['TN'], 0); self.assertEqual(derived['TP'], 2)

    def testPortableGenerationUsesOnlyExplicitJPEGsAndCannotOverwrite(self):
        c = self.catalog(); before = {a['assetID']: report.sha_file(self.case / a['relativePath']) for a in self.assets}; called = []
        def stub(source, destination):
            called.append(source.name); destination.write_bytes(b'synthetic-thumbnail'); return {'width': 384, 'height': 256}
        out = self.root / 'report'
        report.generate(self.fixture, out, c, thumbnailer=stub)
        self.assertEqual(len(called), 6)
        self.assertTrue((out / 'index.html').exists()); self.assertTrue((out / 'review.js').exists())
        self.assertIn('catalog-data', (out / 'index.html').read_text())
        self.assertTrue(all(report.sha_file(self.case / a['relativePath']) == before[a['assetID']] for a in self.assets))
        with self.assertRaises(report.InvalidReport): report.generate(self.fixture, out, c, thumbnailer=stub)
        with self.assertRaises(report.InvalidReport): report.generate(self.fixture, self.fixture / 'bad', c, thumbnailer=stub)

    def testJPEGHashTamperingDoesNotStartThumbnailProcessing(self):
        c = self.catalog(); (self.case / 'f2.jpg').write_bytes(b'changed')
        called = []
        with self.assertRaises(report.InvalidReport): report.generate(self.fixture, self.root / 'report', c, thumbnailer=lambda *a: called.append(a))
        self.assertFalse(called)

    def testEmbeddedDatasetCannotBreakScriptElement(self):
        c = self.catalog(); c['visualReview']['limitations'] = ['</script><script>alert(1)</script>']
        out = self.root / 'report'
        def stub(source, destination): destination.write_bytes(b'thumb'); return {'width': 1, 'height': 1}
        report.generate(self.fixture, out, c, thumbnailer=stub)
        self.assertNotIn('</script><script>alert(1)', (out / 'index.html').read_text())

    @unittest.skipUnless(shutil.which('node'), 'Node only needed for pure revision-validator test')
    def testRevisionRoundtripTamperConflictsAndDuplicateJSONRejected(self):
        catalog = self.catalog(); catalog_path = self.root / 'catalog.json'; catalog_path.write_text(json.dumps(catalog))
        program = r'''
const assert=require('assert'),fs=require('fs'),m=require(process.argv[1]); const c=JSON.parse(fs.readFileSync(process.argv[2]));
const d=m.empty(c); assert.deepEqual(m.validate(m.parseStrictJSON(JSON.stringify(d)),c),d);
let bad=m.clone(d);bad.assetBindings[0].jpegSHA256='wrong';assert.throws(()=>m.validate(bad,c));
bad=m.clone(d);bad.truthSHA256ByCase.example='wrong';assert.throws(()=>m.validate(bad,c));
bad=m.clone(d);bad.assetBindings.pop();assert.throws(()=>m.validate(bad,c));
let edit=m.caseEdit(d,'example');edit.edgeEdits.push({leftAssetID:'f1',rightAssetID:'f2',relation:'unknown',note:''});
assert.equal(m.conflicts(c,d).length,1);assert.throws(()=>m.validate(d,c));m.validate(d,c,true);
edit.groupEdits.push({id:'truth',firstOrdinal:2,lastOrdinal:3,kind:'burst'});assert.equal(m.conflicts(c,d).length,0);m.validate(d,c);
edit.edgeEdits[0].rightAssetID='f3';assert.throws(()=>m.validate(d,c));
const same=m.empty(c),sameEdit=m.caseEdit(same,'example');
sameEdit.groupEdits=[{id:'truth',firstOrdinal:0,lastOrdinal:1,kind:'burst'},{id:'right',firstOrdinal:2,lastOrdinal:3,kind:'burst'}];
sameEdit.edgeEdits=[{leftAssetID:'f1',rightAssetID:'f2',relation:'same',note:''}];
assert.equal(m.conflicts(c,same).length,1);assert.throws(()=>m.validate(same,c));m.validate(same,c,true);
sameEdit.groupEdits=[{id:'truth',firstOrdinal:0,lastOrdinal:3,kind:'burst'}];assert.equal(m.conflicts(c,same).length,0);m.validate(same,c);
const singles=m.empty(c),singlesEdit=m.caseEdit(singles,'example');singlesEdit.removedGroupIDs=['truth'];
singlesEdit.edgeEdits=[{leftAssetID:'f4',rightAssetID:'f5',relation:'same',note:''}];assert.equal(m.conflicts(c,singles).length,0);m.validate(singles,c);
assert.throws(()=>m.parseStrictJSON('{"a":1,"a":2}'));assert.throws(()=>m.parseStrictJSON('{"__proto__":{}}'));
console.log('revision validator pass');
'''
        completed = subprocess.run([shutil.which('node'), '-e', program, str(REPO / 'scripts/sequence-review-report/review.js'), str(catalog_path)], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)


    def testContinuousAnnotationDOMWorkflowPreservesDraftAndProgress(self):
        node = shutil.which('node')
        modules = pathlib.Path(os.environ.get('RAWMASTER_REVIEW_NODE_MODULES', REPO / 'Tests/ReviewUI/node_modules'))
        if not node or not (modules / 'jsdom').is_dir():
            self.skipTest('Run npm ci --prefix Tests/ReviewUI --ignore-scripts for pinned in-memory DOM tests')
        catalog_path = self.root / 'dom-catalog.json'
        catalog_path.write_text(json.dumps(self.catalog()))
        env = dict(os.environ, RAWMASTER_REVIEW_NODE_MODULES=str(modules))
        completed = subprocess.run([node, str(REPO / 'Tests/ReviewUI/continuous-annotation.cjs'), str(catalog_path)],
                                   capture_output=True, text=True, env=env)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def jpeg_projection(self):
        catalog = self.catalog()
        case = catalog['cases'][0]
        for a in case['assets']:
            a['filename'] = 'capture%d.%s' % (a['ordinal'] // 2, 'JPG' if a['ordinal'] % 2 else 'DNG')
        # A second unchanged case exercises migration of existing Sony-style labels.
        other = json.loads(json.dumps(case)); other['id'] = 'unchanged'
        for a in other['assets']:
            a['caseID'] = 'unchanged'
        catalog['cases'].append(other)
        catalog['assetCount'] = 12
        catalog['binding']['truthSHA256ByCase']['unchanged'] = other['truthSHA256']
        catalog['binding']['assetBindings'] += [{k: a[k] for k in ('caseID', 'assetID', 'ordinal', 'jpegSHA256', 'originalSHA256')} for a in other['assets']]
        return catalog, report.jpeg_annotation_projection(catalog, ['example'])

    def testJPEGProjectionPreservesSourceBindingAndUnknownWithoutReinterpretingMetrics(self):
        source, projected = self.jpeg_projection()
        before = json.dumps(source, sort_keys=True)
        case = projected['cases'][0]
        self.assertEqual([(a['ordinal'], a['sourceOrdinal'], a['assetID']) for a in case['assets']], [(0, 1, 'f1'), (1, 3, 'f3'), (2, 5, 'f5')])
        self.assertTrue(all(a['filename'].endswith('.JPG') for a in case['assets']))
        self.assertEqual(case['truth']['groups'][0]['assetIDs'], ['f1', 'f3'])
        self.assertEqual(case['unknownAssetIDs'], ['f5'])
        self.assertEqual(case['truth']['negativePairs'], [])
        self.assertEqual(report.known_edges(case), {0: 'same'})
        self.assertEqual(case['algorithms'], [])
        self.assertFalse(any(e['caseID'] == 'example' for e in projected['errors']))
        self.assertEqual(projected['cases'][1], source['cases'][1])
        self.assertEqual(projected['assetCount'], 9)
        self.assertEqual(projected['annotationProjection']['legacyCatalog']['binding'], source['binding'])
        self.assertNotEqual(projected['indexSHA256'], source['indexSHA256'])
        self.assertNotEqual(case['truthSHA256'], source['cases'][0]['truthSHA256'])
        self.assertEqual(json.dumps(source, sort_keys=True), before)
        detached = report.jpeg_annotation_projection(source, ['example'])
        detached['annotationProjection']['legacyCatalog']['cases'][0]['assets'][0]['filename'] = 'changed'
        detached['annotationProjection']['descriptor']['sourceBinding']['assetBindings'].clear()
        self.assertEqual(json.dumps(source, sort_keys=True), before)
        with self.assertRaises(report.InvalidReport):
            report.jpeg_annotation_projection(source, ['missing'])
        with self.assertRaises(report.InvalidReport):
            report.jpeg_annotation_projection(projected, ['example'])
        for a in case['assets'][:2]:
            a['filename'] = 'raw.DNG'
        with self.assertRaises(report.InvalidReport):
            report.jpeg_annotation_projection({k: v for k, v in projected.items() if k != 'annotationProjection'}, ['example'])

    def testJPEGProjectionDraftMigrationAndDOMKeepLegacyStorageUnchanged(self):
        node = shutil.which('node')
        modules = pathlib.Path(os.environ.get('RAWMASTER_REVIEW_NODE_MODULES', REPO / 'Tests/ReviewUI/node_modules'))
        if not node or not (modules / 'jsdom').is_dir():
            self.skipTest('Run npm ci --prefix Tests/ReviewUI --ignore-scripts')
        _, projected = self.jpeg_projection()
        catalog_path = self.root / 'jpeg-catalog.json'; catalog_path.write_text(json.dumps(projected))
        completed = subprocess.run([node, str(REPO / 'Tests/ReviewUI/jpeg-annotation.cjs'), str(catalog_path)],
            capture_output=True, text=True, env=dict(os.environ, RAWMASTER_REVIEW_NODE_MODULES=str(modules)))
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def testConflictingAndUnfinishedDraftsRemainExportableAndRecoverable(self):
        node = shutil.which('node')
        modules = pathlib.Path(os.environ.get('RAWMASTER_REVIEW_NODE_MODULES', REPO / 'Tests/ReviewUI/node_modules'))
        if not node or not (modules / 'jsdom').is_dir():
            self.skipTest('Run npm ci --prefix Tests/ReviewUI --ignore-scripts')
        catalog_path = self.root / 'export-catalog.json'; catalog_path.write_text(json.dumps(self.catalog()))
        completed = subprocess.run([node, str(REPO / 'Tests/ReviewUI/export-recovery.cjs'), str(catalog_path)],
            capture_output=True, text=True, env=dict(os.environ, RAWMASTER_REVIEW_NODE_MODULES=str(modules)))
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def testGuidedAnnotationKeepsChoicesAndGroupRangesConsistent(self):
        node = shutil.which('node')
        modules = pathlib.Path(os.environ.get('RAWMASTER_REVIEW_NODE_MODULES', REPO / 'Tests/ReviewUI/node_modules'))
        if not node or not (modules / 'jsdom').is_dir():
            self.skipTest('Run npm ci --prefix Tests/ReviewUI --ignore-scripts')
        catalog_path = self.root / 'guided-catalog.json'; catalog_path.write_text(json.dumps(self.catalog()))
        completed = subprocess.run([node, str(REPO / 'Tests/ReviewUI/guided-annotation.cjs'), str(catalog_path)],
            capture_output=True, text=True, env=dict(os.environ, RAWMASTER_REVIEW_NODE_MODULES=str(modules)))
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def testHumanReviewGuidanceRequiresExactBoundaryAndImageBindings(self):
        c = self.catalog(); assets = c['cases'][0]['assets']; before = json.dumps(c, sort_keys=True)
        g = {'schemaVersion': 1, 'annotationIndexSHA256': c['indexSHA256'], 'tasks': [
            {'id': 'test', 'caseID': 'example', 'firstOrdinal': 1, 'leftAssetID': 'f1', 'rightAssetID': 'f2',
             'imageSHA256': [a['jpegSHA256'] for a in assets[1:3]], 'scope': {'first': 0, 'last': 5}, 'recommendedRelation': 'separate'}],
             'viewedImages': [{'caseID': 'example', 'ordinal': 1, 'assetID': 'f1', 'jpegSHA256': assets[1]['jpegSHA256']}]}
        attached = report.attach_guidance(c, g)
        self.assertEqual(attached['binding'], c['binding']); self.assertEqual(json.dumps(c, sort_keys=True), before)
        for mutate in [lambda x: x.update(annotationIndexSHA256='bad'),
                       lambda x: x['tasks'][0].update(firstOrdinal=2),
                       lambda x: x['tasks'][0]['scope'].update(last=1),
                       lambda x: x['viewedImages'][0].update(jpegSHA256='bad')]:
            bad = json.loads(json.dumps(g)); mutate(bad)
            with self.assertRaises(report.InvalidReport): report.attach_guidance(c, bad)


if __name__ == '__main__': unittest.main()
