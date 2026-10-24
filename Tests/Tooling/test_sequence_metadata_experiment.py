"""Synthetic exporter/driver contracts; no fixture JPEGs, original media, Swift or actual experiments."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
runner=module('metadata_experiment_driver',ROOT/'scripts/sequence-metadata-experiment.py')
exporter=module('metadata_fixture_exporter',ROOT/'scripts/export-sequence-metadata.py')

class MetadataExperimentDriverTests(unittest.TestCase):
    def test_exact_factorial_is_thirty_quality_units_without_performance_repeat(self):
        order=runner.schedule()
        self.assertEqual(len(order),30);self.assertEqual(len(set(order)),30)
        self.assertEqual({case for case,_ in order},set(runner.watch.CASES))
        self.assertEqual({variant for _,variant in order},set(runner.VARIANTS))
        self.assertTrue(all(sum(v==variant for _,v in order)==6 for variant in runner.VARIANTS))
    def test_source_freeze_includes_real_sqlite_helpers_exporter_and_old_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo=Path(temporary);(repo/'Sources/CSQLite').mkdir(parents=True);(repo/'Tests').mkdir()
            (repo/'Package.swift').write_text('//fixture')
            (repo/'Sources/CSQLite/shim.h').write_text('#include <sqlite3.h>')
            for rel in ['scripts/sequence-metadata-experiment.py','scripts/sequence-spatial-experiment.py','scripts/export-sequence-metadata.py','scripts/audit-sequence-metadata.py','scripts/sequence-metadata-fields-v1.json','docs/diagnostics/spatial-cv-v1-summary.json']:
                path=repo/rel;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('{}')
            # The snapshot explicitly includes the actual driver too, plus repository-specific dependencies.
            with mock.patch.object(runner,'__file__',str(repo/'scripts/sequence-metadata-experiment.py')):
                before=runner.source_snapshot(repo)
                (repo/'scripts/export-sequence-metadata.py').write_text('#changed')
                after=runner.source_snapshot(repo)
            self.assertNotEqual(before['sha256'],after['sha256'])
            paths={e['path'] for e in before['files']}
            self.assertIn('Sources/CSQLite/shim.h',paths);self.assertIn('docs/diagnostics/spatial-cv-v1-summary.json',paths)
    def test_metadata_freeze_includes_observed_behavior_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo=Path(temporary)
            root=repo/'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingMetadata/v2'
            (root/'cases').mkdir(parents=True);(root/'baselines').mkdir()
            cases=[]
            for name,count in runner.watch.CASES.items():
                relative='cases/'+name+'.json';path=root/relative;path.write_text('{}')
                cases.append(dict(id=name,assetCount=count,path=relative,sha256=runner.watch.digest_file(path)))
            (root/'index.json').write_text(json.dumps(dict(schemaVersion=2,assetCount=1265,cases=cases,auditSeal='a'*64)))
            (root/'README.md').write_text('synthetic historical supplement')
            baseline=root/'baselines/behavior-v1.json';baseline.write_text('{"kind":"observed-metadata-behavior"}')
            frozen=runner.metadata_snapshot(repo)
            self.assertIn('baselines/behavior-v1.json',{row['path'] for row in frozen['files']})
            runner.verify_metadata(repo,frozen)
            baseline.write_text('{"changed":true}')
            with self.assertRaisesRegex(RuntimeError,'Frozen metadata supplement changed'):
                runner.verify_metadata(repo,frozen)
    def test_assumed_reports_never_claim_top_acceptance_or_native_pair_precision(self):
        identity=dict(phase='quality',caseID='synthetic',variant='assumed-continuation',expectedPolicyFingerprint='a'*64)
        report=dict(schemaVersion=1,identity=identity,kind='metadata-quality-unit',integrityValidated=True,strictValidated=True,
                    analysisSealedBeforeLabels=True,behavior=dict(id='synthetic',assetCount=2,policyFingerprint='a'*64),pairPrecision=None,
                    associationHypothesisAssumed=True,topQualityAccepted=True,metricsMeaning='conditionalGroupingMetrics')
        with self.assertRaisesRegex(ValueError,'Assumed'):runner.validate_unit(report,identity,2)
        report['topQualityAccepted']=False;report['pairPrecision']=1
        with self.assertRaisesRegex(ValueError,'pair precision'):runner.validate_unit(report,identity,2)
    def test_curated_projection_preserves_decimal_omits_conflicting_and_private_raw_values(self):
        original='a'*64;current='b'*64;opaque='c'*64
        fields={'exif.ExposureTime':dict(kind='number',privacy='public-capture'),
                'sony.ReleaseMode2':dict(kind='number',privacy='public-counter'),
                'exif.SerialNumber':dict(kind='identity',privacy='private-opaque')}
        capture={key:None for key in exporter.CAPTURE};capture['orientation']=1
        row=dict(status='complete',sourceIntegrity=dict(credentialUnchanged=True,matchesFixtureProvenance=True,beforeSHA256=original,afterSHA256=original),
            sourceIdentity=dict(sha256=original,format='ARW',nativeFormatConsistentWithDeclared=True),fixtureIdentity=dict(sha256=current),
            capture=capture,assetID='opaque-asset',ordinal=0,fieldStates={'exif.ExposureTime':'present','sony.ReleaseMode2':'conflicting','exif.SerialNumber':'present'},
            fields=[dict(fieldID='exif.ExposureTime',qualifiedKey='EXIF:ExifIFD:ExposureTime',numericCanonical='0.123456789123456789',status='present'),
                    dict(fieldID='sony.ReleaseMode2',qualifiedKey='MakerNotes:Sony:ReleaseMode2',numericCanonical='0',status='present'),
                    dict(fieldID='sony.ReleaseMode2',qualifiedKey='MakerNotes:Sony:Copy1:ReleaseMode2',numericCanonical='1',status='present')],
            identityCandidates=[dict(fieldID='exif.SerialNumber',opaqueDigest=opaque,usable=True)],warnings=[])
        declared=dict(jpegSHA256=current,sourceCapture=dict(sha256=original))
        curated=exporter.curate(row,declared,{},fields)
        self.assertEqual(curated['resolvedNumbers'],{'exif.ExposureTime':'0.123456789123456789'})
        self.assertEqual(curated['opaqueCandidates'],{'exif.SerialNumber':opaque})
        self.assertEqual(curated['originalFormat'],'arw');self.assertEqual(curated['currentSHA256'],current)
        self.assertNotIn('relativePath',json.dumps(curated));self.assertNotIn('rawScalarText',json.dumps(curated))
        row['sourceIntegrity']['afterSHA256']='d'*64
        with self.assertRaises(ValueError):exporter.curate(row,declared,{},fields)

if __name__=='__main__':unittest.main()
