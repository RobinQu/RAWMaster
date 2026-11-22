#!/usr/bin/env python3
"""Exercise native work-version edits and restore on a private copy of a migrated Lightroom catalogue."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

from inspection_real_replay import INSPECTION_SOURCES,build_probe,sha


def original_fixture(crate,root,source):
    folder=root/"original-case";folder.mkdir(mode=0o700)
    photo=folder/("private-input"+source.suffix.lower())
    shutil.copyfile(source,photo)
    digest=sha(photo);size=photo.stat().st_size
    dbpath=folder/"catalog.sqlite"
    with sqlite3.connect(dbpath) as db:
        db.executescript((crate/"src/authority/legacy_v7_reference.sql").read_text())
        db.execute("PRAGMA user_version=7")
        db.execute("INSERT INTO projects VALUES('p','{}')")
        s={"id":"s","projectID":"p","mode":"reference","sourcePath":str(folder),"scanCompleted":True,"status":"completed"}
        db.execute("INSERT INTO sessions VALUES('s',?)",(json.dumps(s),))
        w={"sessionID":"s","projectID":"p","phase":"screening","importActive":False}
        db.execute("INSERT INTO session_workflows VALUES('s',?)",(json.dumps(w),))
        a={"id":"photo","sessionID":"s","projectID":"p","filename":photo.name,"relativePath":photo.name,
           "sourcePath":str(photo),"currentPath":str(photo),"contentHash":digest,"fileSize":size,
           "availability":"available","importState":"ready"}
        db.execute("INSERT INTO assets(id,session_id,source_path,data) VALUES('photo','s',?,?)",(str(photo),json.dumps(a)))
    return dbpath,photo


def local_clone(source,destination):
    if Path(source).is_symlink():
        raise ValueError("resource fixture contains a symlink")
    try:
        os.link(source,destination)
    except OSError:
        shutil.copy2(source,destination)
    return destination


def catalog_scope(db):
    totals={}
    counts={
        "works":"SELECT COUNT(*) FROM lc_org_works",
        "virtualCopies":"SELECT COUNT(*) FROM lc_org_works WHERE kind='virtual'",
        "virtualsWithHistoricalLooks":"SELECT COUNT(DISTINCT w.work_id) FROM lc_org_works w JOIN lc_lr_looks l USING(work_id) WHERE w.kind='virtual' AND l.decoded=1",
        "resources":"SELECT COUNT(*) FROM lc_resources",
        "originalScopes":"SELECT COUNT(*) FROM lc_scopes",
    }
    for key,query in counts.items():
        totals[key]=db.execute(query).fetchone()[0]
    return totals


def ui_probe(crate,host,root,env,catalog,master):
    module=root/"ui-module";module.mkdir()
    framework=module/"libRAWMasterLibrary.dylib"
    subprocess.run(["xcrun","swiftc","-swift-version","6","-parse-as-library","-emit-library","-emit-module","-module-name","RAWMasterLibrary",
                    "-I",str(root),"-emit-module-path",str(module/"RAWMasterLibrary.swiftmodule"),*map(str,sorted((crate/"Swift").glob("*.swift"))),
                    str(root/"Bundle.swift"),str(root/"loader.o"),"-lsqlite3","-o",str(framework)],check=True)
    ui=root/"ui-probe";sources=host/"Sources/RAWMaster"
    subprocess.run(["xcrun","swiftc","-swift-version","6","-parse-as-library","-I",str(module),"-I",str(root),"-L",str(module),"-lRAWMasterLibrary",
                    "-Xlinker","-rpath","-Xlinker",str(module),str(sources/"CatalogWorkMedia.swift"),str(sources/"CatalogWorkEditor.swift"),
                    str(crate/"tests/ProbeCatalogConnection.swift"),str(crate/"tests/CatalogWorkEditUIProbe.swift"),"-lsqlite3","-o",str(ui)],check=True)
    evidence=root/"ui-evidence.json"
    subprocess.run([str(ui),str(catalog),master,str(evidence)],check=True,env=env)
    return json.loads(evidence.read_text())


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ("catalog","scratch","runtime"):
        p.add_argument("--"+name,type=Path,required=True)
    p.add_argument("--raw",type=Path,help="also exercise admitted RAW and full restore on a private copy")
    p.add_argument("--host",type=Path,help="also drive the actual app work card and editor sheet from this checkout in an invisible private window")
    args=p.parse_args()
    crate=Path(__file__).resolve().parents[1]
    parent=Path(tempfile.mkdtemp(prefix="work-edit-",dir=args.scratch))
    live=parent/"live";live.mkdir(mode=0o700)
    source=args.catalog.resolve();target=live/"library.sqlite"
    with sqlite3.connect(source.as_uri()+"?mode=ro",uri=True) as reader, sqlite3.connect(target) as writer:
        reader.backup(writer)
        scope=catalog_scope(writer)
        row=writer.execute("""SELECT m.work_id,w.work_id FROM lc_org_works w JOIN lc_org_works m ON m.work_id=w.master_work_id
          WHERE w.kind='virtual' AND EXISTS(SELECT 1 FROM lc_lr_looks a WHERE a.work_id=w.work_id AND a.decoded=1)
            AND EXISTS(SELECT 1 FROM lc_lr_looks a WHERE a.work_id=m.work_id AND a.decoded=1)
          ORDER BY m.work_id,w.work_id LIMIT 1""").fetchone()
        if not row:
            raise ValueError("This fixture needs a migrated virtual copy and its master, each with an archived preview")
    resources=source.parent/"LibraryResources"
    shutil.copytree(resources,live/"LibraryResources",copy_function=local_clone)
    binary,env=build_probe(crate,parent,args.runtime,crate/"tests/CatalogWorkEditProbe.swift",[*INSPECTION_SOURCES,"CatalogLocalEditing"])
    subprocess.run([str(binary),str(target),str(parent),*row],check=True,env=env)
    report=parent/"evidence.json"
    summary=json.loads(report.read_text())
    summary["inputCatalog"]=scope
    if args.raw:
        rawdb,raw=original_fixture(crate,parent,args.raw.resolve())
        subprocess.run([str(binary),"--original",str(rawdb),str(raw)],check=True,env=env)
        summary["admittedOriginal"]=json.loads((rawdb.parent/"original-evidence.json").read_text())
    if args.host:
        summary["hostInterface"]=ui_probe(crate,args.host.resolve(),parent,env,parent/"restored/library.sqlite",row[0])
    report.write_text(json.dumps(summary,indent=2,sort_keys=True)+"\n")
    print(parent/"evidence.json")


if __name__=="__main__":
    main()
