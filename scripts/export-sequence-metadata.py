#!/usr/bin/env python3
"""Reproduce a scrubbed additive supplement from the complete sealed audit; never read originals/labels."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

AUDIT_SEAL='ba663312eec6cfd0aabfcc2837bd39e75fa45f64d4585c63a60c20c4497c3f17'
TOOL_COMMIT='2200871d9cef988051d2a99d67df3bda6cbb30a8'
NORMALIZER='qualified-parser-facts-v1.1'
RECIPE='audit-to-current-jpeg-v1'
VERSION='sequence-metadata-export-v1'
CASES={'burst123':123,'burst14-context38':38,'burst48-context72':72,'interval427-context439':439,'burst193-context217':217,'dji187-context376':376}
PRIVATE={'exif.SerialNumber','exif.CameraSerialNumber','sony.SerialNumber','sony.InternalSerialNumber','dji.SensorID','exif.ImageUniqueID','exif.RawDataUniqueID','xmp.ImageUniqueID','xmpEX.ImageUniqueID'}
CAPTURE={'dateTimeOriginalRaw','subsecTimeOriginalRaw','offsetTimeOriginalRaw','exposureSeconds','cameraMake','cameraModel','orientation'}

def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode()
def digest(data):return hashlib.sha256(data).hexdigest()
def sha(path):
    result=hashlib.sha256()
    with Path(path).open('rb') as handle:
        while chunk:=handle.read(1024*1024):result.update(chunk)
    return result.hexdigest()
def read(path,maximum=4*1024*1024):
    with Path(path).open('rb') as handle:data=handle.read(maximum+1)
    if len(data)>maximum:raise ValueError('Control budget exceeded')
    return json.loads(data),digest(data)
def relative(root,path):
    if not path or Path(path).is_absolute() or '\\' in path or '\0' in path or any(x in ('','.','..') for x in path.split('/')):raise ValueError('Unsafe relative path')
    result=(root/path).resolve()
    if root.resolve() not in result.parents:raise ValueError('Path escaped explicit root')
    return result
def overlap(a,b):
    a,b=Path(a).resolve(),Path(b).resolve();return a==b or a in b.parents or b in a.parents
def write(path,value):
    data=canonical(value)+b'\n'
    if len(data)>8*1024*1024:raise ValueError('Curated case budget exceeded')
    with path.open('xb') as handle:handle.write(data)
    return digest(data)
def publish(stage,output):
    if output.exists() or stage.stat().st_dev!=output.parent.stat().st_dev or sys.platform!='darwin':raise ValueError('Exclusive same-filesystem macOS publication required')
    lib=ctypes.CDLL(None,use_errno=True);function=lib.renamex_np
    function.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];function.restype=ctypes.c_int
    if function(os.fsencode(stage),os.fsencode(output),4):raise ValueError('Exclusive publication failed')
def curate(row,declared,receipt,fields):
    proof=row['sourceIntegrity'];source=row['sourceIdentity']
    if row['status']!='complete' or not proof['credentialUnchanged'] or not proof['matchesFixtureProvenance'] or proof['beforeSHA256']!=proof['afterSHA256'] or proof['beforeSHA256']!=source['sha256']:raise ValueError('Incomplete original proof')
    if source['sha256']!=declared['sourceCapture']['sha256'] or row['fixtureIdentity']['sha256']!=declared['jpegSHA256'] or source['nativeFormatConsistentWithDeclared'] is not True:raise ValueError('Original/current/native type mismatch')
    fmt={'ARW':'arw','DNG':'dng','JPEG':'jpeg'}.get(source['format'])
    if fmt is None or set(row['capture'])!=CAPTURE or set(row['fieldStates'])!=set(fields):raise ValueError('Unexpected capture/field schema')
    numbers={};qualified={};opaque={}
    for fid,field in fields.items():
        observations=[f for f in row['fields'] if f['fieldID']==fid]
        qualified[fid]=sorted(f['qualifiedKey'] for f in observations)
        if row['fieldStates'][fid]!='present':continue
        if field['kind']=='number' and field['privacy']!='private-opaque':
            values={f['numericCanonical'] for f in observations if f['status']=='present'}
            if len(values)!=1 or None in values:raise ValueError('Unresolved numeric fact')
            numbers[fid]=next(iter(values))
        if fid in PRIVATE:
            candidates={c['opaqueDigest'] for c in row['identityCandidates'] if c['fieldID']==fid and c['usable']}
            if len(candidates)>1:raise ValueError('Conflicting private aggregate was promoted')
            if candidates:opaque[fid]=next(iter(candidates))
    return dict(assetID=row['assetID'],ordinal=row['ordinal'],currentSHA256=declared['jpegSHA256'],originalSHA256=source['sha256'],
        originalFormat=fmt,capture=row['capture'],fieldStates=row['fieldStates'],resolvedNumbers=numbers,opaqueCandidates=opaque,
        qualifiedFieldSources=qualified,auditWarningCount=len(row['warnings']))
def run(args):
    repository=Path(__file__).resolve().parent.parent
    audit=Path(args.audit).resolve();v1=Path(args.v1).resolve();output=Path(args.output).resolve()
    for protected in (audit,v1,repository/'Tests/Fixtures/SequenceGroupingInputs'):
        if overlap(output,protected):raise ValueError('Output aliases frozen audit/v1/inputs')
    if output.exists():raise ValueError('Existing output is never overwritten')
    receipt,_=read(audit/'receipt.json');claimed=receipt.pop('factsSealSHA256')
    if claimed!=AUDIT_SEAL or digest(canonical(receipt))!=claimed or receipt['status']!='complete' or not receipt['analysisReady'] or [receipt[k] for k in ('requested','metadataRows','sourceVerified')]!=[1265]*3:raise ValueError('Accepted full audit seal required')
    if receipt['normalizerVersion']!=NORMALIZER or receipt['parser']['commit']!=TOOL_COMMIT or receipt['parser']['version']!='13.59':raise ValueError('Unsupported audit lineage')
    if sha(audit/'assets.jsonl')!=receipt['rowsSHA256'] or sha(audit/'availability.json')!=receipt['availabilitySHA256']:raise ValueError('Audit artifacts changed')
    registry,registry_sha=read(repository/'scripts/sequence-metadata-fields-v1.json')
    if registry_sha!=receipt['registrySHA256'] or sha(repository/'scripts/audit-sequence-metadata.py')!=receipt['scriptSHA256']:raise ValueError('Accepted exporter input definition changed')
    fields={f['fieldID']:f for f in registry['fields']}
    index,v1sha=read(v1/'index.json')
    if {c['id']:c['assetCount'] for c in index['cases']}!=CASES or len(index['cases'])!=6:raise ValueError('Frozen cohort changed')
    controls={x['role']:x['sha256'] for x in receipt['controls']}
    if v1sha!=controls['fixtureIndex']:raise ValueError('V1 index differs from audit')
    stage_root=repository/'output';stage_root.mkdir(exist_ok=True)
    stage=stage_root/('.metadata-export-'+uuid.uuid4().hex)
    if any(overlap(stage,p) for p in (audit,v1,output)):raise ValueError('Unsafe staging')
    stage.mkdir(mode=0o700);(stage/'cases').mkdir()
    cases=[];used=set();audit_input=(audit/'assets.jsonl').open()
    for item in index['cases']:
        manifest_path=relative(v1,item['manifestPath']);manifest,manifest_sha=read(manifest_path)
        if manifest_sha!=item['manifestSHA256'] or manifest_sha!=controls[item['id']+'Manifest'] or len(manifest['files'])!=CASES[item['id']]:raise ValueError('Manifest lineage changed')
        curated=[]
        for ordinal,file in enumerate(manifest['files']):
            key=(item['id'],file['assetID'])
            line=audit_input.readline()
            if not line or len(line.encode())>64*1024:raise ValueError('Audit row coverage/budget')
            row=json.loads(line)
            if key in used or (row['caseID'],row['assetID'])!=key:raise ValueError('Audit original-order/identity mismatch')
            used.add(key)
            if row['ordinal']!=ordinal or file['ordinal']!=ordinal:raise ValueError('Ordinal mismatch')
            current=relative(manifest_path.parent,file['relativePath'])
            if sha(current)!=file['jpegSHA256']:raise ValueError('Actual current JPEG changed')
            curated.append(curate(row,file,receipt,fields))
        case=dict(schemaVersion=2,recipeVersion=RECIPE,caseID=item['id'],auditSeal=AUDIT_SEAL,auditRowsSHA256=receipt['rowsSHA256'],registrySHA256=registry_sha,
            normalizerVersion=NORMALIZER,keyID=receipt['keyID'],v1IndexSHA256=v1sha,caseManifestSHA256=manifest_sha,files=curated)
        path='cases/'+item['id']+'.json';case_sha=write(stage/path,case)
        cases.append(dict(id=item['id'],assetCount=len(curated),path=path,sha256=case_sha,caseManifestSHA256=manifest_sha))
        del case,curated
    if audit_input.readline() or len(used)!=1265:raise ValueError('Unconsumed/extra audit rows')
    audit_input.close()
    output_index=dict(schemaVersion=2,datasetID='sequence-original-metadata-v2',recipeVersion=RECIPE,exporterVersion=VERSION,exporterSHA256=sha(Path(__file__)),
        auditSeal=AUDIT_SEAL,auditRowsSHA256=receipt['rowsSHA256'],registrySHA256=registry_sha,normalizerVersion=NORMALIZER,v1IndexSHA256=v1sha,
        assetCount=1265,cases=cases)
    write(stage/'index.json',output_index)
    (stage/'README.md').write_text('''# Historical original metadata supplement v2

This additive, scrubbed research fixture was reproduced from the complete accepted audit02. It is not JPEG EXIF and is not an original RAW token. Each file binds its historical original hash and audit lineage to the actual current JPEG hash. Current native-reader time/offset is never repaired from this supplement.

Raw capture strings are normalized by the existing Swift strict TimestampParser at load time. Numeric facts retain exact Decimal text. Duplicate/conflicting fields are not resolved by picking an instance. Opaque candidates are keyed pseudonyms in the audit namespace, not native device/exposure verification. No key, plain serial, GPS, original paths, MakerNotes dump, warning text, labels or image pixels are exported. Qualified tag names and parser warning counts remain for provenance. Fingerprint means the curated case file byte SHA.

All cases are development data. v1 images/truth/dev4/007 baselines remain unchanged. An assumed RAW/JPEG event is only a conditional hypothesis; it cannot create pair precision or top-level quality acceptance. Software and photographic rights retain their existing separate scopes.
''')
    # Recheck immutable source controls immediately before publication; no originals are read.
    if sha(audit/'assets.jsonl')!=receipt['rowsSHA256'] or sha(v1/'index.json')!=v1sha or sha(repository/'scripts/sequence-metadata-fields-v1.json')!=registry_sha:raise ValueError('Controls changed during export')
    output.parent.mkdir(parents=True,exist_ok=True);publish(stage,output)
    print('Published 1265 scrubbed source-bound metadata rows; v1/truth unchanged')
def main():
    repository=Path(__file__).resolve().parent.parent;p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--audit',required=True);p.add_argument('--v1',default=str(repository/'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'))
    p.add_argument('--output',default=str(repository/'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingMetadata/v2'))
    try:run(p.parse_args());return 0
    except Exception as error:
        print('Metadata export failed:',type(error).__name__,'; no successful publication',file=sys.stderr);return 1
if __name__=='__main__':sys.exit(main())
