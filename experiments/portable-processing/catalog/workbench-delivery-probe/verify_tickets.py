"""Replay a previously generated 035 mixed-workload fixture through the shipped catalog C ABI.

The fixture contains catalog.sqlite and delivery/*.jpg. The source catalog is opened read-only.
Every new batch, stage and delivered file is confined to a temporary directory beside --report.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import uuid

args = argparse.ArgumentParser()
args.add_argument("--runtime", required=True, type=Path)
args.add_argument("--fixture", required=True, type=Path, help="Generated 035 mixed-workload directory")
args.add_argument("--count", required=True, type=int)
args.add_argument("--report", required=True, type=Path)
opt = args.parse_args()
original = opt.fixture.resolve()
if not 1 <= opt.count <= 200:
    args.error("--count must be within 1...200")
if opt.report.exists() or opt.report.resolve().is_relative_to(original):
    args.error("select a new --report path outside the fixture")
if not opt.report.parent.is_dir():
    args.error("the parent directory of --report must exist")
def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()
class Reply(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("length", ctypes.c_size_t)]
abi = ctypes.CDLL(str(opt.runtime.resolve()))
abi.rm_library_request_v1.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(Reply)]
abi.rm_library_release_v1.argtypes = [ctypes.POINTER(Reply)]
rows = []
with tempfile.TemporaryDirectory(dir=opt.report.parent) as path:
    directory = Path(path).resolve()
    db = directory / "library.sqlite"
    output = directory / "deliver"
    output.mkdir()
    with sqlite3.connect((original / "catalog.sqlite").as_uri() + "?mode=ro", uri=True) as before, sqlite3.connect(db) as after:
        before.backup(after)
    keep = sqlite3.connect(db)
    candidates = keep.execute("SELECT value FROM lc_meta WHERE key GLOB 'wb032.manifest.v1/*'").fetchall()
    if len(candidates) != 1:
        args.error("the generated mixed-workload fixture must contain one frozen batch")
    base = json.loads(candidates[0][0])
    assert len(base["items"]) >= opt.count and base["schema"] == 1
    batch = str(uuid.uuid4())
    base.update(batchID=batch, destination={"grantID": batch, "pathHint": str(output)}, items=base["items"][:opt.count])
    def request(action, **fields):
        command = dict(action=action, **fields)
        if action != "register":
            command["batchID"] = batch
        message = json.dumps({"operation": "scheduler", "request": {"op": "workbenchBatch", "command": command}}).encode()
        name = os.fsencode(db)
        reply = Reply()
        rc = abi.rm_library_request_v1(name, len(name), message, len(message), ctypes.byref(reply))
        try:
            answer = json.loads(ctypes.string_at(reply.data, reply.length))
        finally:
            abi.rm_library_release_v1(ctypes.byref(reply))
        assert rc == 0, (action, answer)
        return answer
    def ledger(ordinal):
        row = keep.execute("SELECT value FROM lc_meta WHERE key GLOB ? AND json_extract(value,'$.ordinal')=?", ("wb032.item.v1/" + batch + "/*", ordinal)).fetchone()
        return json.loads(row[0])
    initial = request("register", manifest=base, directory=str(output), leaseMs=120000)
    for ordinal, item in enumerate(base["items"], 1):
        lease = dict(ordinal=ordinal, generation=1, token=initial["token"])
        lease["itemToken"] = request("claimItem", **lease, leaseMs=120000)["itemToken"]
        filename = item["stem"] + ".jpg"
        expected = original / "delivery" / filename
        stage = output / (".rawmaster-export-" + str(uuid.uuid4())) / "pixels.jpg"
        stage.parent.mkdir()
        shutil.copyfile(expected, stage)
        result = request("prepareItem", **lease, directory=str(output), stage=str(stage.relative_to(output)), suffix=1)
        prepared = ledger(ordinal)
        ticket = prepared["ticket"]
        assert result["item"]["state"] == prepared["state"] == "prepared"
        assert ticket["sha256"] == sha(expected) and ticket["byteCount"] == expected.stat().st_size and ticket["filename"] == filename
        inode = stage.stat().st_ino
        assert ticket["identity"]["inode"] == inode
        assert request("publishItem", **lease, directory=str(output))["status"] == "published"
        published = ledger(ordinal)
        assert published["state"] == "prepared" and published["ticket"] == ticket
        assert (output / filename).stat().st_ino == inode
        assert (output / filename).stat().st_size == ticket["byteCount"] and sha(output / filename) == ticket["sha256"]
        assert request("acknowledgeItem", ordinal=ordinal, directory=str(output))["status"] == "delivered"
        ack = ledger(ordinal)
        assert ack["state"] == "delivered" and ack["ticket"] == ticket and ack["tokenDigest"] is None
        rows.append([filename, ticket["sha256"]])
    for ordinal in {1, opt.count}:
        assert request("acknowledgeItem", ordinal=ordinal, directory=str(output))["status"] == "delivered"
        assert ledger(ordinal)["state"] == "delivered"
    assert request("items")["complete"]
    assert request("load")["batch"]["phase"] == "done"
    assert keep.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    assert sorted(p.name for p in output.iterdir()) == sorted(name for name,_ in rows)
    keep.close()
report = dict(runtimeSHA256=sha(opt.runtime), count=len(rows), passed=True,
    inventorySHA256=hashlib.sha256(json.dumps(sorted(rows),separators=(",",":"),ensure_ascii=False).encode()).hexdigest(),
    immutableTicketThroughPreparePublishAck=True, regularFileInodeFromStage=True, digestAndLength=True, duplicateAckOrdinals=sorted({1, opt.count}),
    allTerminal=True, integrityCheck="ok", namesAndDigests=rows)
opt.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
