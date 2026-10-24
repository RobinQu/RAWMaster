#!/usr/bin/env python3
"""Frozen 5x6 metadata research units. No builds/downloads/RAW reads/golden rewrites or264benchmark."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import sys
import time
import uuid

DEPENDENCY=Path(__file__).with_name('sequence-spatial-experiment.py')
spec=importlib.util.spec_from_file_location('metadata_watchdog_dependency',DEPENDENCY)
watch=importlib.util.module_from_spec(spec);spec.loader.exec_module(watch)
VARIANTS=('dev4','strict-continuation','strict-shortRestart','assumed-continuation','assumed-shortRestart')
SELECTOR='RAWMasterImagingTests.SequenceMetadataExperimentTests/testOfflineUnit'

def schedule():return [(case,variant) for case in watch.CASES for variant in VARIANTS]
def fingerprint(value):return hashlib.sha256(watch.canonical(value)).hexdigest()
def source_snapshot(repository):
    repository=Path(repository).resolve()
    base=watch.snapshot(repository,Path(__file__).resolve())
    entries=list(base['files'])
    for relative in ['scripts/sequence-spatial-experiment.py','scripts/export-sequence-metadata.py','scripts/audit-sequence-metadata.py','scripts/sequence-metadata-fields-v1.json','docs/diagnostics/spatial-cv-v1-summary.json']:
        entries.append({'path':relative,'sha256':watch.digest_file(repository/relative)})
    entries=sorted({row['path']:row for row in entries}.values(),key=lambda row:row['path'])
    return {'files':entries,'sha256':fingerprint(entries)}
def metadata_snapshot(repository):
    root=repository/'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingMetadata/v2'
    index=json.loads((root/'index.json').read_text())
    if index['schemaVersion']!=2 or index['assetCount']!=1265 or len(index['cases'])!=6 or {c['id']:c['assetCount'] for c in index['cases']}!=watch.CASES:raise ValueError('Metadata population changed')
    entries=[{'path':'index.json','sha256':watch.digest_file(root/'index.json')}]
    for item in index['cases']:
        path=(root/item['path']).resolve()
        if root.resolve() not in path.parents or watch.digest_file(path)!=item['sha256']:raise ValueError('Metadata case bytes changed')
        entries.append({'path':item['path'],'sha256':item['sha256']})
    for relative in ('README.md','baselines/behavior-v1.json'):
        entries.append({'path':relative,'sha256':watch.digest_file(root/relative)})
    return {'indexSHA256':entries[0]['sha256'],'files':entries,'sha256':fingerprint(entries),'auditSeal':index['auditSeal'],'caseSHA256s':{c['id']:c['sha256'] for c in index['cases']}}
def verify_metadata(repository,frozen):
    root=repository/'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingMetadata/v2'
    for row in frozen['files']:
        if watch.digest_file(root/row['path'])!=row['sha256']:raise RuntimeError('Frozen metadata supplement changed')
def validate_unit(report,identity,expected_count,expected_analysis_path=None):
    if report.get('schemaVersion')!=1 or report.get('identity')!=identity:raise ValueError('Native metadata identity mismatch')
    if identity['phase']=='bootstrap':
        if report.get('kind')!='metadata-descriptor' or report.get('labelsRead') is not False:raise ValueError('Invalid metadata descriptor')
        return
    if report.get('kind')!='metadata-quality-unit' or not all(report.get(k) is True for k in ('integrityValidated','strictValidated','analysisSealedBeforeLabels')):raise ValueError('Native integrity/strict/seal failed')
    behavior=report['behavior']
    if behavior['id']!=identity['caseID'] or behavior['assetCount']!=expected_count or behavior['policyFingerprint']!=identity['expectedPolicyFingerprint']:raise ValueError('Actual metadata case/policy mismatch')
    if report['pairPrecision'] is not None:raise ValueError('No pair precision truth exists')
    if report['associationHypothesisAssumed'] and (report['topQualityAccepted'] or report['metricsMeaning']!='conditionalGroupingMetrics'):raise ValueError('Assumed association cannot claim native/top quality')
    if identity['variant'].startswith('strict-') and report['associationHypothesisAssumed']:raise ValueError('Strict mode silently assumed an exposure')
    sealed_path=Path(report['analysisPath'])
    if sealed_path.is_symlink() or (expected_analysis_path is not None and sealed_path.resolve()!=Path(expected_analysis_path).resolve()):raise ValueError('Analysis path identity mismatch')
    with sealed_path.open('rb') as handle:sealed_bytes=handle.read(16*1024*1024+1)
    if len(sealed_bytes)>16*1024*1024:raise ValueError('Analysis artifact budget')
    if hashlib.sha256(sealed_bytes).hexdigest()!=report['supplementAnalysisSealSHA256']:raise ValueError('Supplement analysis seal mismatch')
    sealed=json.loads(sealed_bytes)
    if sealed['analysis']['result']!=behavior['result'] or sealed['configuration']!=report['configuration'] or sealed['eventMap']!=report['eventMap']:raise ValueError('Report diverges from pre-label sealed analysis')
    if not math.isfinite(report['wholeUnitSeconds']) or report['wholeUnitSeconds']<0:raise ValueError('Invalid elapsed measurement')

def main():
    deadline=time.monotonic()+1800;watch.DEADLINE=deadline
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--test-bundle',required=True,type=Path);parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();repository=Path(__file__).resolve().parent.parent;bundle=args.test_bundle.resolve(strict=True)
    output=watch.safe_output(args.output,repository,bundle)
    if (repository/'output').resolve() not in output.parents:raise ValueError('Research output must be ignored local output')
    if output.exists() and any(output.iterdir()):raise ValueError('Fresh/empty output required')
    output.mkdir(parents=True,exist_ok=True)
    plist=plistlib.loads((bundle/'Contents/Info.plist').read_bytes());binary=bundle/'Contents/MacOS'/plist['CFBundleExecutable']
    executable=watch.digest_file(binary);sources=source_snapshot(repository);v1=watch.fixture_snapshot(repository);v2=metadata_snapshot(repository)
    run_id=str(uuid.uuid4());command=['/usr/bin/xcrun','xctest','-XCTest',SELECTOR,str(bundle)]
    watch.execute(['/usr/bin/xcrun','swift','--version'],os.environ.copy(),output/'toolchain.log',deadline)
    toolchain=(output/'toolchain.log').read_text().strip()
    freeze={'schemaVersion':1,'runID':run_id,'sourceSnapshot':sources,'fixtures':v1,'metadata':v2,'executableSHA256':executable,
        'command':command,'testBundle':str(bundle),'swift':toolchain,'schedule':{'qualityUnits':30,'bootstrapUnits':6,'benchmarkUnits':0,'unitSeconds':60,'batchSeconds':1800,'terminationGraceSeconds':2},
        'order':schedule(),'meaning':'Execution completion is not quality acceptance. Assumed grouping remains conditional. No native pair truth.'}
    watch.write_json(output/'freeze.json',freeze,repository,bundle);completed=[];descriptors={}
    def verify():
        if time.monotonic()>=deadline:raise TimeoutError('Metadata batch1800s expired')
        if source_snapshot(repository)!=sources or watch.digest_file(binary)!=executable:raise RuntimeError('Frozen source/binary changed')
        watch.verify_fixture_controls(repository,v1);verify_metadata(repository,v2)
    def unit(phase,case,variant=None):
        verify()
        identity={'schemaVersion':1,'runID':run_id,'unitID':str(uuid.uuid4()),'phase':phase,'caseID':case,
            'fixtureIndexSHA256':v1['indexSHA256'],'metadataIndexSHA256':v2['indexSHA256'],
            'sourceSnapshotSHA256':sources['sha256'],'executableSHA256':executable}
        if variant:
            identity.update(variant=variant,expectedPolicyFingerprint=descriptors[case][variant])
        prefix=output/identity['unitID'];control=prefix.with_suffix('.control.json');report=prefix.with_suffix('.report.json')
        watch.write_json(control,identity,repository,bundle)
        env=os.environ.copy()
        for key in list(env):
            if key.startswith('RAWMASTER_SEQUENCE_FIXTURE_') or key.startswith('RAWMASTER_SPATIAL_EXPERIMENT_') or key.startswith('RAWMASTER_METADATA_EXPERIMENT_'):env.pop(key)
        env.update(RAWMASTER_METADATA_EXPERIMENT_UNIT=str(control),RAWMASTER_METADATA_EXPERIMENT_REPORT=str(report),RAWMASTER_SEQUENCE_FIXTURE_SWIFT_VERSION=toolchain)
        wall=watch.execute(command,env,prefix.with_suffix('.log'),deadline)
        value=json.loads(report.read_text());validate_unit(value,identity,watch.CASES[case],str(report)+'.analysis.json')
        if value.get('metadataSnapshotSHA256')!=v2['caseSHA256s'][case] or value.get('metadataAuditSeal' if phase=='bootstrap' else 'auditSeal')!=v2['auditSeal']:raise ValueError('Actual metadata supplement identity mismatch')
        if phase!='bootstrap':value['processWallSeconds']=wall
        verify();return value
    try:
        for case in watch.CASES:
            record=unit('bootstrap',case);names={v['variant']:v['policyFingerprint'] for v in record['variants']}
            if set(names)!=set(VARIANTS) or len(set(names.values()))!=5:raise ValueError('Aliased/missing five-way metadata controls')
            descriptors[case]=names
            watch.write_json(output/(case+'.descriptor.json'),record,repository,bundle)
        for case,variant in schedule():
            completed.append(unit('quality',case,variant))
            watch.write_json(output/'progress.json',{'runID':run_id,'completedQualityUnits':len(completed),'expectedQualityUnits':30},repository,bundle)
        verify()
        if watch.fixture_snapshot(repository)!=v1 or metadata_snapshot(repository)!=v2:raise RuntimeError('Frozen dataset bytes changed')
        watch.write_json(output/'quality.json',completed,repository,bundle)
        watch.write_json(output/'complete.json',{'schemaVersion':1,'runID':run_id,'complete':True,'qualityAccepted':all(v['topQualityAccepted'] for v in completed),
            'qualityUnits':len(completed),'benchmarkUnits':0,'sourceSnapshotSHA256':sources['sha256'],'metadataSnapshotSHA256':v2['sha256'],
            'actualReadBoundary':'Historical sealed original metadata plus actual native current JPEG reader; no original-media reads in this run'},repository,bundle)
        print('Metadata research complete:30quality units,0benchmark units; qualityAccepted='+str(all(v['topQualityAccepted'] for v in completed)))
    except BaseException as error:
        watch.write_json(output/'failure.json',{'schemaVersion':1,'runID':run_id,'complete':False,'completedQualityUnits':len(completed),'error':str(error)},repository,bundle)
        raise

def interrupted(signum,_frame):raise KeyboardInterrupt('Signal '+str(signum))
if __name__=='__main__':
    for sig in (signal.SIGINT,signal.SIGTERM):signal.signal(sig,interrupted)
    try:main()
    except SystemExit:raise
    except BaseException as error:
        if watch.ACTIVE is not None:watch.stop_group(watch.ACTIVE)
        print('Metadata experiment hard error:',str(error),file=sys.stderr);sys.exit(1)
