#!/usr/bin/env python3
"""Fixed-cohort read-only metadata research. No pixel decode, pairing, labels or app dependency."""
import argparse
import collections
import ctypes
import decimal
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import resource
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid

VERSION = 'sequence-original-metadata-audit-v1'
NORMALIZER = 'qualified-parser-facts-v1.1'
TOOL_COMMIT = '2200871d9cef988051d2a99d67df3bda6cbb30a8'
TOOL_VERSION = '13.59'
SPEC_SHA = '3db0644e6fcfa1a5a409d007538caf24f7befa5f26e1d2d5147776a81f76872d'
INDEX_SHA = 'e2bc0f560c96d9c60cea737d43718d3d867aacc7c0e6599a44f6d7da58efb48c'
REGISTRY_SHA = '3e5f23907acdfdc2a7d268204fa2a4dfa2603053815d82bd698926f3404f5e46'
DIAGNOSTIC_SELECTORS = ('ExifTool:Warning','ExifTool:Error')
CASES = {'burst123':123, 'burst14-context38':38, 'burst48-context72':72,
         'interval427-context439':439, 'burst193-context217':217, 'dji187-context376':376}
CHUNK = 1024 * 1024
LIMITS = dict(wrapperSampledRSSCeilingBytes=64*CHUNK, artifactBytes=64*CHUNK, stdoutBytes=CHUNK,
              stderrBytes=64*1024, rowBytes=64*1024, controlBytes=4*CHUNK, scalarBytes=256,
              childSeconds=15, jobSeconds=1800, childRSSBytes=256*CHUNK, pollSeconds=0.05, graceSeconds=0.25)
CANCELLED = False

class AuditError(Exception):
    def __init__(self, code): self.code = code; super().__init__(code)

class NumberText(str): pass

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()

def digest(value): return hashlib.sha256(value).hexdigest()

def wrapper_peak_bytes():
    value=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if sys.platform=='darwin' else value*1024)

def gate_failure(deadline=float('inf')):
    if CANCELLED: return 'cancelled'
    if time.monotonic() >= deadline: return 'jobTimeout'
    if wrapper_peak_bytes()>LIMITS['wrapperSampledRSSCeilingBytes']: return 'wrapperRSSBudget'
    return None

def check(deadline=float('inf')):
    failure=gate_failure(deadline)
    if failure: raise AuditError(failure)

def hash_file(path, deadline=float('inf')):
    result = hashlib.sha256()
    with Path(path).open('rb') as handle:
        while True:
            check(deadline)
            chunk = handle.read(CHUNK)
            if not chunk: break
            result.update(chunk)
    check(deadline)
    return result.hexdigest()

def hash_artifact(path):
    # Cancellation finalization hashes ONLY bounded local sanitized artifacts, never originals.
    result=hashlib.sha256(); total=0
    with Path(path).open('rb') as handle:
        while True:
            chunk=handle.read(CHUNK)
            if not chunk: break
            total+=len(chunk)
            if total>LIMITS['artifactBytes']: raise AuditError('artifactBudget')
            result.update(chunk)
    return result.hexdigest()

def pairs_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise AuditError('duplicateJSONKey')
        result[key] = value
    return result

def parse_json(data):
    try:
        return json.loads(data, object_pairs_hook=pairs_object, parse_int=NumberText,
                          parse_float=NumberText, parse_constant=lambda _: (_ for _ in ()).throw(AuditError('nonfiniteJSON')))
    except AuditError: raise
    except Exception: raise AuditError('invalidJSON') from None

def read_control(path, expected=None):
    with Path(path).open('rb') as handle: data = handle.read(LIMITS['controlBytes']+1)
    if len(data) > LIMITS['controlBytes']: raise AuditError('controlBudget')
    if expected and digest(data) != expected: raise AuditError('controlHashMismatch')
    # Controls are trusted structures after exact bytes binding, not tool numeric lexemes.
    try: return json.loads(data), digest(data)
    except Exception: raise AuditError('invalidControl') from None

def overlaps(a,b):
    a,b = Path(a).resolve(),Path(b).resolve()
    return a == b or a in b.parents or b in a.parents

def safe_relative(root, relative):
    path = Path(relative)
    if not relative or path.is_absolute() or '\\' in relative or '\0' in relative or any(p in ('','..','.') for p in relative.split('/')):
        raise AuditError('unsafeRelativePath')
    root = Path(root).resolve(); current = root
    for part in path.parts:
        current = current / part
        if current.is_symlink(): raise AuditError('symlinkInput')
    result = current.resolve()
    if root not in result.parents: raise AuditError('escapedInput')
    return result

def guard_paths(source, output, key, repository, tool):
    source,output,key,repository,tool = [Path(p).resolve() for p in (source,output,key,repository,tool)]
    local = repository/'output'
    if local not in output.parents or local not in key.parents: raise AuditError('outputMustBeIgnoredLocal')
    for path in (output,key):
        if overlaps(source,path) or overlaps(tool,path): raise AuditError('sourceOutputOverlap')
    if overlaps(output,key): raise AuditError('keyOutputOverlap')
    for path in (repository/'Tests', repository/'Sources', repository/'scripts'):
        if overlaps(output,path) or overlaps(key,path): raise AuditError('protectedOutputOverlap')
    if output.exists(): raise AuditError('outputExists')
    return source,output,key

def credential(path):
    value = Path(path).lstat()
    if not stat.S_ISREG(value.st_mode): raise AuditError('nonregularSource')
    return [value.st_dev,value.st_ino,value.st_size,value.st_mtime_ns,value.st_ctime_ns]

def load_key(path):
    path = Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    try:
        fd = os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as handle: handle.write(os.urandom(32))
    except FileExistsError: pass
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or stat.S_IMODE(value.st_mode) != 0o600: raise AuditError('unsafeKeyFile')
    with path.open('rb') as handle: key = handle.read(33)
    if len(key)!=32: raise AuditError('invalidKeyFile')
    # Stable opaque key identifier, never the key itself or a plain serial digest.
    key_id = hmac.new(key,b'RAWMaster.audit.keyID.v1',hashlib.sha256).hexdigest()
    return key,key_id

def opaque(key,namespace,kind,text):
    return hmac.new(key,canonical(['RAWMaster.original-metadata.v1',namespace,kind,text]),hashlib.sha256).hexdigest()

def scalar(raw):
    if isinstance(raw,NumberText): return 'number',str(raw)
    if isinstance(raw,str): return 'string',raw
    raise AuditError('unsupportedScalar')

def normal_value(raw,field,key):
    kind,text = scalar(raw)
    if len(text.encode())>LIMITS['scalarBytes']: raise AuditError('scalarBudget')
    if field['privacy']=='private-opaque':
        cleaned = text.strip(' \t\r\n\0')
        if kind=='number' and (not cleaned.isascii() or not cleaned.isdigit()): raise AuditError('unusableIdentity')
        if (not cleaned or set(cleaned)=={'0'} or cleaned.lower() in {'unknown','none','n/a','null','(null)','not available'}
            or any(ord(c)<32 for c in cleaned)): raise AuditError('unusableIdentity')
        return kind,None,None,opaque(key,field['selector'],kind,cleaned)
    if field['kind']=='string':
        # ExifTool JSON quotes by appearance, not the catalog storage type. Keep the
        # number token verbatim for catalog strings; never Decimal-convert/pad it.
        if kind not in ('string','number') or any(ord(c)<32 for c in text): raise AuditError('invalidString')
        return kind,text,None,None
    try: number = decimal.Decimal(text)
    except decimal.InvalidOperation: raise AuditError('invalidNumber') from None
    if not number.is_finite(): raise AuditError('invalidNumber')
    return kind,text,str(number),None

def matches(key,field):
    selector = field['selector']
    if not selector or ':' not in key: return False
    parts = key.split(':'); group,tag = selector.split(':',1)
    if parts[-1] != tag: return False
    if group=='EXIF': return parts[0]=='EXIF' and len(parts)>=3
    if group=='Sony': return parts[0]=='MakerNotes' and parts[1]=='Sony'
    if group=='DJI':
        # Observed APP7 alias is allowed only for this already-requested private selector.
        allowed = ('MakerNotes','APP7') if selector=='DJI:SensorID' else ('MakerNotes',)
        return parts[0] in allowed and parts[1]=='DJI'
    if group=='File': return parts[0]=='File'
    return parts[0]=='XMP' and parts[1]==group

def normalize_tool(data,fields,key,expected_source):
    decoded = parse_json(data)
    if not isinstance(decoded,list) or len(decoded)!=1 or not isinstance(decoded[0],dict): raise AuditError('invalidToolShape')
    obj = decoded[0]; observed = collections.defaultdict(list); warnings=[]
    source = obj.pop('SourceFile',None)
    if not isinstance(source,str) or Path(source).resolve()!=Path(expected_source).resolve(): raise AuditError('toolSourceMismatch')
    for qualified,value in obj.items():
        if qualified.split(':')[-1] in ('Error','Warning'):
            if qualified.split(':')[0]!='ExifTool': raise AuditError('unrequestedToolField')
            if qualified.split(':')[-1]=='Error': raise AuditError('toolReportedError')
            warnings.append({'code':'toolWarning','opaqueDigest':opaque(key,'tool-warning','string',str(value))}); continue
        selected = [f for f in fields if matches(qualified,f)]
        if len(selected)!=1: raise AuditError('unrequestedToolField')
        observed[selected[0]['fieldID']].append((qualified,value))
    facts=[]; states={}; resolved={}; identities=[]
    for field in fields:
        fid=field['fieldID']; instances=observed[fid]
        if field['selector'] is None: states[fid]='unsupportedSelector'; continue
        if not instances: states[fid]='absent'; continue
        values=[]; failed=False
        for qualified,raw in instances:
            fact=dict(fieldID=fid,qualifiedKey=qualified,tagID=None,candidateRole=field['candidateRole'],
                      possibleDefinitions=[field['catalogDefinition']],runtimeTableResolution='unresolved',
                      status='present',scalarType=None,rawScalarText=None,numericCanonical=None,opaqueDigest=None)
            try:
                kind,text,number,hashed=normal_value(raw,field,key)
                fact.update(scalarType=kind,rawScalarText=text,numericCanonical=number,opaqueDigest=hashed)
                if field['kind']=='string' and kind=='number':
                    fact['transportEncodingNote']='numeric-looking-catalog-string-output-as-JSON-number; exact-lexeme-preserved'
                values.append((kind,text,number,hashed))
                if hashed: identities.append(dict(fieldID=fid,namespace=field['selector'],opaqueDigest=hashed,usable=True,semanticValidation='unvalidated'))
            except AuditError as error:
                fact.update(status='invalid',invalidReason=error.code); failed=True
            facts.append(fact)
        unique=set(values)
        states[fid]='invalid' if failed else 'conflicting' if len(unique)>1 else 'present'
        if states[fid]=='present': resolved[fid]=values[0]
    def string(tag):
        value=resolved.get('exif.'+tag); return value[1] if value else None
    def number(tag):
        value=resolved.get('exif.'+tag)
        if value is None: return None
        try:
            result=float(value[2]); return result if math.isfinite(result) else None
        except (ValueError,OverflowError): return None
    capture=dict(dateTimeOriginalRaw=string('DateTimeOriginal'),subsecTimeOriginalRaw=string('SubSecTimeOriginal'),
                 offsetTimeOriginalRaw=string('OffsetTimeOriginal'),exposureSeconds=number('ExposureTime'),
                 cameraMake=string('Make'),cameraModel=string('Model'),orientation=number('Orientation'))
    for candidate in identities:
        candidate['usable'] = states[candidate['fieldID']]=='present'
    native={name:resolved['file.'+tag][1] if 'file.'+tag in resolved else None for name,tag in [('fileType','FileType'),('mimeType','MIMEType')]}
    return dict(capture=capture,native=native,fields=facts,fieldStates=states,identityCandidates=identities,warnings=warnings)

def child_environment(): return {'PATH':'/usr/bin:/bin','LC_ALL':'C','LANG':'C'}

def stop_child(process):
    failures=[]
    try: os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError: pass
    except OSError: failures.append('terminateGroupFailed')
    try: process.wait(timeout=LIMITS['graceSeconds'])
    except subprocess.TimeoutExpired: pass
    try: os.killpg(process.pid,signal.SIGKILL)
    except ProcessLookupError: pass
    except OSError: failures.append('killGroupFailed')
    try: process.wait(timeout=LIMITS['graceSeconds'])
    except subprocess.TimeoutExpired: failures.append('reapFailed')
    if failures: raise AuditError('childCleanupFailed')

def child_rss(pid):
    # Sampled process RSS; no claim of an OS-hard allocation limit. No tool stdout is passed to ps.
    try:
        value=subprocess.run(['/bin/ps','-o','rss=','-p',str(pid)],capture_output=True,timeout=0.2,env=child_environment())
        return int(value.stdout.strip())*1024 if value.returncode==0 and value.stdout.strip() else None
    except (OSError,ValueError,subprocess.TimeoutExpired): return None

def run_child(command,deadline,measurement):
    check(deadline); started=time.monotonic(); process=None; poller=selectors.DefaultSelector()
    buffers={'stdout':bytearray(),'stderr':bytearray()}
    try:
        process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=child_environment(),start_new_session=True)
        for name,pipe in [('stdout',process.stdout),('stderr',process.stderr)]:
            os.set_blocking(pipe.fileno(),False); poller.register(pipe,selectors.EVENT_READ,name)
        last_rss=0
        while poller.get_map():
            check(deadline)
            if time.monotonic()-started>=LIMITS['childSeconds']: raise AuditError('childTimeout')
            if time.monotonic()-last_rss>=0.1:
                rss=child_rss(process.pid); last_rss=time.monotonic()
                if rss is not None:
                    measurement['childRSSSamples']+=1; measurement['childPeakRSSBytes']=max(measurement['childPeakRSSBytes'] or 0,rss)
                    if rss>LIMITS['childRSSBytes']: raise AuditError('childRSSBudget')
            for event,_ in poller.select(LIMITS['pollSeconds']):
                chunk=os.read(event.fileobj.fileno(),65536)
                if not chunk: poller.unregister(event.fileobj); continue
                name=event.data; buffers[name].extend(chunk)
                if len(buffers[name])>LIMITS[name+'Bytes']: raise AuditError(name+'Budget')
        # A child can close pipes and keep running; wait remains inside the same deadline.
        while process.poll() is None:
            check(deadline)
            if time.monotonic()-started>=LIMITS['childSeconds']: raise AuditError('childTimeout')
            time.sleep(LIMITS['pollSeconds'])
        if process.returncode!=0: raise AuditError('toolExitFailure')
        if buffers['stderr']: raise AuditError('toolStderr')
        check(deadline)
        measurement['metadataSeconds']+=time.monotonic()-started
        return bytes(buffers['stdout'])
    finally:
        poller.close()
        if process is not None:
            stop_child(process)
            for pipe in (process.stdout,process.stderr):
                if pipe: pipe.close()
        # Never write raw stdout/stderr/serials, including failed subprocess diagnostics.
        buffers['stdout'].clear(); buffers['stderr'].clear()

def tool_command(perl,tool,fields,source):
    return [str(perl),str(tool),'-config','','-j','-n','-a','-G0:1:4'] + ['-'+f['selector'] for f in fields if f['selector']] + ['-'+tag for tag in DIAGNOSTIC_SELECTORS] + [str(source)]

def verify_tool(root,perl,registry,deadline,measurement):
    def git(*args):
        value=subprocess.run(['/usr/bin/git','-C',str(root),*args],capture_output=True,env=child_environment(),timeout=5)
        if value.returncode: raise AuditError('toolGitFailure')
        return value.stdout
    if git('rev-parse','HEAD').decode().strip()!=TOOL_COMMIT or git('status','--porcelain','--untracked-files=all').strip(): raise AuditError('toolPinMismatch')
    paths=git('ls-files','-z').decode().split('\0'); entries=[]
    for name in paths:
        if not name: continue
        path=safe_relative(root,name); credential(path)
        entries.append(dict(path=name,sha256=hash_file(path,deadline)))
    version=run_child([str(perl),str(root/'exiftool'),'-config','','-ver'],deadline,measurement).decode().strip()
    if version!=TOOL_VERSION or registry['toolCommit']!=TOOL_COMMIT or registry['toolVersion']!=TOOL_VERSION: raise AuditError('toolVersionMismatch')
    perl_version=run_child([str(perl),'-e','print $^V'],deadline,measurement).decode().strip()
    return dict(commit=TOOL_COMMIT,version=version,closureSHA256=digest(canonical(entries)),files=entries,perlSHA256=hash_file(perl,deadline),perlVersion=perl_version)

def inventory(spec_path,fixture_root,source):
    spec,spec_hash=read_control(spec_path,SPEC_SHA); index,index_hash=read_control(fixture_root/'index.json',INDEX_SHA)
    if {c['id']:len(c['files']) for c in spec['cases']}!=CASES or len(spec['cases'])!=6: raise AuditError('populationChanged')
    controls=[dict(role='inputSpec',sha256=spec_hash),dict(role='fixtureIndex',sha256=index_hash)]; records=[]
    indexed={c['id']:c for c in index['cases']}
    for case in spec['cases']:
        icase=indexed[case['id']]; manifest_path=safe_relative(fixture_root,icase['manifestPath'])
        manifest,sha=read_control(manifest_path,icase['manifestSHA256']); controls.append(dict(role=case['id']+'Manifest',sha256=sha))
        if len(manifest['files'])!=len(case['files']): raise AuditError('caseCountMismatch')
        for position,(entry,file) in enumerate(zip(case['files'],manifest['files'])):
            expected=case['sourceRelativeRoot']+'/'+entry['relativePath']
            if (entry['ordinal']!=position or file['ordinal']!=position or entry['assetID']!=file['assetID'] or file['sourceCapture']['relativePath']!=expected): raise AuditError('sourceMappingMismatch')
            path=safe_relative(source,expected)
            records.append(dict(caseID=case['id'],assetID=entry['assetID'],ordinal=position,path=path,
                expectedHash=file['sourceCapture']['sha256'],fixtureHash=file['jpegSHA256'],format=path.suffix[1:].upper(),
                before=None,beforeHash=None,after=None,afterHash=None))
    if len(records)!=1265: raise AuditError('populationChanged')
    return records,controls

def atomic_publish(stage,output):
    if output.exists(): raise AuditError('outputExists')
    if stage.stat().st_dev!=output.parent.stat().st_dev: raise AuditError('crossFilesystemPublication')
    if sys.platform!='darwin': raise AuditError('exclusiveRenameRequiresMacOS')
    library=ctypes.CDLL(None,use_errno=True)
    function=library.renamex_np; function.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]; function.restype=ctypes.c_int
    if function(os.fsencode(stage),os.fsencode(output),4)!=0: raise AuditError('exclusiveRenameFailed')

class ArtifactWriter:
    def __init__(self): self.bytes=0
    def write(self,path,value):
        data=canonical(value)+b'\n'; self.bytes+=len(data)
        if self.bytes>LIMITS['artifactBytes']: raise AuditError('artifactBudget')
        with path.open('xb') as handle: handle.write(data)
    def line(self,handle,value):
        data=canonical(value)+b'\n'
        if len(data)>LIMITS['rowBytes']: raise AuditError('rowBudget')
        self.bytes+=len(data)
        if self.bytes>LIMITS['artifactBytes']: raise AuditError('artifactBudget')
        handle.write(data)

def build_rows(stage,records,writer):
    provisional=stage/'provisional.jsonl'
    handle=provisional.open('rb') if provisional.exists() else None
    first=handle.readline() if handle else b''
    pending=json.loads(first) if first else None
    with (stage/'assets.jsonl').open('xb') as output, (stage/'local-proof.jsonl').open('xb') as proof:
        for record in records:
            row_key=(record['caseID'],record['assetID'])
            data=None
            if pending and (pending['caseID'],pending['assetID'])==row_key:
                data=pending; line=handle.readline(); pending=json.loads(line) if line else None
            verified=record['beforeHash']==record['afterHash']==record['expectedHash'] and record['before']==record['after'] and record['after'] is not None
            status='complete' if data and verified else 'afterUnverified' if data else 'notRead'
            native=(data or {}).get('native',{}); native_format=native.get('fileType')
            expected_native={'ARW':'ARW','DNG':'DNG','JPG':'JPEG','JPEG':'JPEG'}.get(record['format'])
            row=dict(schemaVersion=1,caseID=record['caseID'],assetID=record['assetID'],ordinal=record['ordinal'],status=status,
                     sourceIdentity=dict(sha256=record['expectedHash'],format=native_format,filenameDeclaredFormat=record['format'],mimeType=native.get('mimeType'),nativeFormatConsistentWithDeclared=(native_format==expected_native if native_format is not None else None)),
                     fixtureIdentity=dict(sha256=record['fixtureHash'],binding='declared-by-frozen-v1-manifest'),
                     sourceIntegrity=dict(beforeSHA256=record['beforeHash'],afterSHA256=record['afterHash'],credentialUnchanged=verified,matchesFixtureProvenance=verified))
            if data: row.update(data); row['status']=status
            writer.line(output,row)
            writer.line(proof,dict(caseID=record['caseID'],assetID=record['assetID'],before=record['before'],after=record['after'],beforeSHA256=record['beforeHash'],afterSHA256=record['afterHash']))
    if handle: handle.close()
    provisional.unlink(missing_ok=True)

def run(args):
    repository=Path(__file__).resolve().parent.parent; started=time.monotonic(); deadline=started+LIMITS['jobSeconds']
    source,output,key_path=guard_paths(args.source_base,args.output,args.key_file,repository,args.tool_root)
    if Path(args.perl).resolve()!=Path('/usr/bin/perl').resolve(): raise AuditError('unsupportedPerlInterpreter')
    registry,registry_hash=read_control(args.field_registry,REGISTRY_SHA)
    if registry['schemaVersion']!=1 or len(registry['fields'])>48 or registry.get('diagnosticSelectors')!=list(DIAGNOSTIC_SELECTORS): raise AuditError('registryInvalid')
    records,controls=inventory(Path(args.input_spec),Path(args.fixture_root).resolve(),source)
    key,key_id=load_key(key_path); output.parent.mkdir(parents=True,exist_ok=True)
    guard_paths(source,output,key_path,repository,args.tool_root)
    stage=output.with_name('.'+output.name+'.staging-'+uuid.uuid4().hex); stage.mkdir(mode=0o700)
    writer=ArtifactWriter(); tool=None; failure=None
    measurements=dict(childRSSSamples=0,childPeakRSSBytes=None,metadataSeconds=0.0,beforeHashSeconds=0.0,afterHashSeconds=0.0)
    script_hash=hash_file(Path(__file__),deadline); field_stats=collections.defaultdict(collections.Counter); model_stats=collections.Counter()
    transition_stats=collections.defaultdict(collections.Counter); previous_values={}; precision_counts=collections.Counter()
    per_field_values=collections.defaultdict(set); controls_before=controls
    try:
        tool=verify_tool(Path(args.tool_root).resolve(),Path(args.perl).resolve(),registry,deadline,measurements)
        phase=time.monotonic()
        for record in records:
            check(deadline); before=credential(record['path']); hashed=hash_file(record['path'],deadline)
            if credential(record['path'])!=before or hashed!=record['expectedHash']: raise AuditError('sourceBeforeMismatch')
            record['before']=before; record['beforeHash']=hashed
        measurements['beforeHashSeconds']=time.monotonic()-phase
        metadata_started=time.monotonic()
        with (stage/'provisional.jsonl').open('xb') as provisional:
            for i,record in enumerate(records):
                check(deadline)
                if credential(record['path'])!=record['before']: raise AuditError('sourceBeforeMetadataChanged')
                raw=run_child(tool_command(args.perl,Path(args.tool_root)/'exiftool',registry['fields'],record['path']),deadline,measurements)
                data=normalize_tool(raw,registry['fields'],key,record['path']); del raw
                if credential(record['path'])!=record['before']: raise AuditError('sourceDuringMetadataChanged')
                data.update(caseID=record['caseID'],assetID=record['assetID'],ordinal=record['ordinal'])
                writer.line(provisional,data)
                cohort=(record['caseID'],data['capture']['cameraMake'],data['capture']['cameraModel'],data['native']['fileType'])
                model_stats[cohort]+=1
                for fid,state in data['fieldStates'].items(): field_stats[(cohort,fid)][state]+=1
                for fact in data['fields']:
                    if fact['status']=='present' and data['fieldStates'][fact['fieldID']]=='present':
                        per_field_values[(cohort,fact['fieldID'])].add(fact['opaqueDigest'] or fact['numericCanonical'] or fact['rawScalarText'])
                subsec=data['capture']['subsecTimeOriginalRaw']
                precision_counts['missing' if subsec is None else 'digits:'+str(len(subsec)) if subsec.isascii() and subsec.isdigit() else 'invalid']+=1
                for field in registry['fields']:
                    if field['kind']!='number' or field['privacy']!='public-counter': continue
                    fid=field['fieldID']; identity=(record['caseID'],fid)
                    candidates=[f['numericCanonical'] for f in data['fields'] if f['fieldID']==fid and f['status']=='present']
                    numeric=decimal.Decimal(candidates[0]) if candidates and data['fieldStates'][fid]=='present' else None
                    current=(record['ordinal'],cohort[1:3],data['capture']['offsetTimeOriginalRaw'],numeric)
                    previous=previous_values.get(identity)
                    if previous is not None:
                        counts=transition_stats[identity]; counts['adjacentPairsRequested']+=1
                        if previous[0]+1!=current[0] or previous[3] is None or numeric is None:
                            counts['uncomparableMissingInvalidOrConflicting']+=1
                        elif previous[1]!=current[1] or previous[2]!=current[2]: counts['cameraOrOffsetChange']+=1
                        else:
                            counts['numericAdjacentPairs']+=1
                            counts['increasing' if numeric>previous[3] else 'same' if numeric==previous[3] else 'decreasing']+=1
                    previous_values[identity]=current
                if (i+1)%100==0: print('Metadata rows observed:',i+1,'/',len(records),flush=True)
        measurements['metadataPhaseWallSeconds']=time.monotonic()-metadata_started
        phase=time.monotonic()
        for record in records:
            check(deadline)
            if credential(record['path'])!=record['before']: raise AuditError('sourceBeforeAfterHashChanged')
            hashed=hash_file(record['path'],deadline); after=credential(record['path'])
            if after!=record['before'] or hashed!=record['beforeHash']: raise AuditError('sourceAfterMismatch')
            record['after']=after; record['afterHash']=hashed
        measurements['afterHashSeconds']=time.monotonic()-phase
        for record in records:
            if credential(record['path'])!=record['before']: raise AuditError('sourceBeforeSealChanged')
        _,controls_after=inventory(Path(args.input_spec),Path(args.fixture_root).resolve(),source)
        if controls_before!=controls_after or hash_file(Path(__file__),deadline)!=script_hash or hash_file(Path(args.field_registry),deadline)!=registry_hash: raise AuditError('auditControlsChanged')
        parser_after=verify_tool(Path(args.tool_root).resolve(),Path(args.perl).resolve(),registry,deadline,measurements)
        if parser_after!=tool: raise AuditError('parserClosureChanged')
        for record in records:
            if credential(record['path'])!=record['before']: raise AuditError('sourceFinalStatChanged')
        check(deadline)
    except Exception as error:
        failure=error.code if isinstance(error,AuditError) else 'executionFailure'
    build_rows(stage,records,writer)
    availability=[]
    for (cohort,fid),counts in sorted(field_stats.items(),key=lambda item:repr(item[0])):
        availability.append(dict(caseID=cohort[0],make=cohort[1],model=cohort[2],format=cohort[3],fieldID=fid,
                                 counts=dict(counts),distinctUsableValues=len(per_field_values[(cohort,fid)])))
    writer.write(stage/'availability.json',dict(schemaVersion=1,fields=availability,requested=len(records),metadataRows=sum(model_stats.values()),
        caseRequestedCounts=CASES,subsecondLexicalPrecisionCounts=dict(precision_counts),
        clockValidationAbsent=True,rawAdjacentCounterDeltas=[dict(caseID=k[0],fieldID=k[1],counts=dict(v)) for k,v in sorted(transition_stats.items())],
        warning='Raw adjacent numeric deltas only; clock validation is absent. These are not within-era continuity, validated resets, wraps or grouping boundaries. Missing rows are not filtered to invent continuity.'))
    rows_sha=hash_artifact(stage/'assets.jsonl'); availability_sha=hash_artifact(stage/'availability.json')
    if failure is None: failure=gate_failure(deadline)
    ready=failure is None
    measurements['wrapperPeakRSSBytes']=wrapper_peak_bytes()
    receipt=dict(schemaVersion=1,tool=VERSION,normalizerVersion=NORMALIZER,status='complete' if ready else 'partial',analysisReady=ready,
        requested=len(records),metadataRows=sum(model_stats.values()),sourceVerified=sum(r['afterHash'] is not None for r in records),failureCode=failure,
        sourceReads='metadata-only; no preview/image/RAW render requested',nativeDeviceIdentityVerified=False,captureAssociationVerified=False,
        controls=controls,registrySHA256=registry_hash,scriptSHA256=script_hash,parser=tool,keyID=key_id,
        limits=LIMITS,measurements=measurements,totalSeconds=time.monotonic()-started,rowsSHA256=rows_sha,availabilitySHA256=availability_sha,
        argvTemplate=['perl','PINNED_TOOL','-config','','-j','-n','-a','-G0:1:4']+['-'+f['selector'] for f in registry['fields'] if f['selector']]+['-'+tag for tag in DIAGNOSTIC_SELECTORS]+['APPROVED_SOURCE_FILE'],
        labelsRead=False,metadataSecondsIncludesToolVersionChecks=True,wrapperMemoryBoundary='Sampled process high-water RSS ceiling checked at hash/child/publication checkpoints; not an exact managed-allocation or OS allocation cap',runtimeTableIdentity='unresolved; catalog definitions are possibilities, not runtime firmware proof')
    if ready:
        guard_paths(source,output,key_path,repository,args.tool_root)
        if gate_failure(deadline):
            ready=False; failure=gate_failure(deadline)
            receipt.update(status='partial',analysisReady=False,failureCode=failure)
    receipt['factsSealSHA256']=digest(canonical(receipt)); writer.write(stage/'receipt.json',receipt)
    if ready and gate_failure(deadline):
        ready=False; failure=gate_failure(deadline)
        receipt.pop('factsSealSHA256'); receipt.update(status='partial',analysisReady=False,failureCode=failure)
        receipt['factsSealSHA256']=digest(canonical(receipt))
        (stage/'receipt.json').unlink(); writer.write(stage/'receipt.json',receipt)
    if ready:
        atomic_publish(stage,output)
        print('Audit complete:',len(records),'source files verified; native identity/association remain unvalidated')
        return 0
    partial=output.with_name(output.name+'.partial-'+uuid.uuid4().hex)
    guard_paths(source,partial,key_path,repository,args.tool_root)
    atomic_publish(stage,partial); print('Audit partial:',failure,'; analysisReady=false',file=sys.stderr)
    return 2

def main():
    repository=Path(__file__).resolve().parent.parent
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-spec',default=str(repository/'Tests/Fixtures/SequenceGroupingInputs/v1/cases.json'))
    parser.add_argument('--fixture-root',default=str(repository/'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'))
    parser.add_argument('--field-registry',default=str(Path(__file__).with_name('sequence-metadata-fields-v1.json')))
    parser.add_argument('--source-base',required=True); parser.add_argument('--tool-root',required=True)
    parser.add_argument('--perl',default='/usr/bin/perl'); parser.add_argument('--key-file',required=True); parser.add_argument('--output',required=True)
    args=parser.parse_args()
    def cancelled(_signal,_frame):
        global CANCELLED
        CANCELLED=True
    for sig in (signal.SIGINT,signal.SIGTERM): signal.signal(sig,cancelled)
    try: return run(args)
    except Exception as error:
        code=error.code if isinstance(error,AuditError) else 'auditPreflightOrPublicationFailure'
        print('Audit failed:',code,'; no analysis-ready publication',file=sys.stderr); return 1

if __name__=='__main__': sys.exit(main())
