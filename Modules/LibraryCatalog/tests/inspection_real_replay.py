#!/usr/bin/env python3
"""Exercise the production Swift inspector and Rust catalogue in a new private SQLite fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile


def sha(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


INSPECTION_SOURCES=["LibraryEngine","CatalogActions","CatalogJSON","LibraryInspectionGeometry","LibraryInspectionReader","LibraryInspectionPixels"]


def build_probe(crate,root,runtime,main,files):
    bundle=root/"Probe.bundle";res=bundle/"Contents/Resources";res.mkdir(parents=True)
    (bundle/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"org.rawmaster.inspection-validation","CFBundlePackageType":"BNDL"}))
    shutil.copy2(runtime,res/"rawmaster-library.runtime")
    (root/"module.modulemap").write_text('module CLibraryCatalogABI { header "'+str(crate/"Bridge/include/LibraryLoader.h")+'" export * }\n')
    swift_bundle=root/"Bundle.swift"
    swift_bundle.write_text('import Foundation\nextension Bundle { static let module = Bundle(path: ProcessInfo.processInfo.environment["PROBE_BUNDLE"]!)! }\n')
    loader=root/"loader.o"
    subprocess.run(["xcrun","clang","-I",str(crate/"Bridge/include"),"-c",str(crate/"Bridge/LibraryLoader.c"),"-o",str(loader)],check=True)
    sources=[crate/"Swift"/(s+".swift") for s in files]
    binary=root/"probe"
    subprocess.run(["xcrun","swiftc","-swift-version","6","-parse-as-library","-O","-I",str(root),*map(str,sources),str(swift_bundle),
                    str(crate/"tests/ProbeCatalogConnection.swift"),str(main),str(loader),"-lsqlite3","-o",str(binary)],check=True)
    environment={**os.environ,"PROBE_BUNDLE":str(bundle)}
    return binary,environment


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ("manifest","scratch","runtime","exiftool"):
        p.add_argument("--"+name,type=Path,required=True)
    p.add_argument("--sources", type=Path, nargs="+", help="ordered caller-selected RAWs for an anonymized manifest")
    p.add_argument("--save-private-patches",action="store_true",help="save reviewed 192 px patches inside this private run")
    args=p.parse_args()
    crate=Path(__file__).resolve().parents[1]
    root=Path(tempfile.mkdtemp(prefix="inspection-real-",dir=args.scratch))
    root.chmod(0o700)
    manifest=json.loads(args.manifest.read_text())
    if args.sources:
        assert len(args.sources)==len(manifest["inputs"]), "wrong number of caller-selected originals"
        for row,path in zip(manifest["inputs"],args.sources): row["path"]=str(path.resolve())
    for row in manifest["inputs"]:
        f=Path(row["path"]);assert f.is_absolute()
        calculated=sha(f)
        if "digest" in row: assert row["digest"]==calculated, "specified digest does not match input"
        row.update(digest=calculated,size=f.stat().st_size)
    hashes={row["id"]:row["digest"] for row in manifest["inputs"]}
    for proof in manifest.get("sourceSets",[]):
        combined=hashlib.sha256(b"".join(bytes.fromhex(hashes[i]) for i in proof["ids"])).hexdigest()
        assert combined==proof["sha256"], "frozen source set does not match"
    path=root/"inputs.json";path.write_text(json.dumps(manifest))
    dbfile=root/"library.sqlite"
    with sqlite3.connect(dbfile) as db:
        db.executescript((crate/"src/authority/legacy_v7_reference.sql").read_text())
        db.execute("PRAGMA user_version=7")
        db.execute("INSERT INTO projects VALUES('p','{}')")
        session={"id":"s","projectID":"p","mode":"reference","sourcePath":str(root),"scanCompleted":True,"status":"completed"}
        db.execute("INSERT INTO sessions VALUES('s',?)",(json.dumps(session),))
        db.execute("INSERT INTO session_workflows VALUES('s',?)",(json.dumps({"sessionID":"s","projectID":"p","phase":"screening","importActive":False}),))
        for row in manifest["inputs"]:
            data={"id":row["id"],"sessionID":"s","projectID":"p","filename":Path(row["path"]).name,"relativePath":Path(row["path"]).name,
                  "sourcePath":row["path"],"currentPath":row["path"],"contentHash":row["digest"],"fileSize":row["size"],
                  "availability":"available","importState":"ready"}
            db.execute("INSERT INTO assets(id,session_id,source_path,data) VALUES(?,'s',?,?)",(row["id"],row["path"],json.dumps(data)))
        for group in manifest["groups"]:
            ids=[x["id"] for x in group["frames"]];data={"id":group["id"],"projectID":"p","assetIDs":ids,"kind":"burst","origin":"manual"}
            db.execute("INSERT INTO groups_data VALUES(?,'p',?)",(group["id"],json.dumps(data)))
            db.executemany("INSERT INTO membership VALUES(?,?,?,1)",[(group["id"],v,i) for i,v in enumerate(ids)])
    binary,environment=build_probe(crate,root,args.runtime,crate/"tests/InspectionRawProbe.swift",INSPECTION_SOURCES)
    if args.save_private_patches:
        (root/"patches").mkdir(mode=0o700);environment["RAWMASTER_FOCUS_REVIEW_PATCH_DIR"]=str(root/"patches")
    result=root/"observations.json"
    subprocess.run([str(binary),str(dbfile),str(path),str(args.exiftool.resolve()),str(result)],env=environment,check=True)
    print(result)


if __name__=="__main__":
    main()
