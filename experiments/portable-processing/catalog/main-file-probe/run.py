#!/usr/bin/env python3
"""Compile against macOS system SQLite. Each case owns an isolated, temporary fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
WRITER = "identical-catalog-writer"
MARKER = "identical-frozen-batch-receipt"
CASES = (
    "read", "write", "no-txn", "no-mmap", "injected-proc-reject",
    "folder-before-open", "folder-after-open", "folder-after-verified", "folder-decoy-return",
    "file-before-open", "file-after-open", "file-decoy-return",
)

def initial(root, mode):
    for part in ("live", "peer"):
        (root / part).mkdir()
    first = root / "live/db.sqlite"
    db = sqlite3.connect(first)
    try:
        assert db.execute(f"PRAGMA journal_mode={mode}").fetchone()[0] == mode
        db.execute("PRAGMA synchronous=FULL")
        db.execute("PRAGMA user_version=10")
        db.execute("CREATE TABLE probe(id INTEGER PRIMARY KEY, deviceID TEXT NOT NULL, marker TEXT NOT NULL)")
        db.execute("INSERT INTO probe VALUES(1, ?, ?)", (WRITER, MARKER))
        db.commit()
        if mode == "wal":
            assert db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0] == 0
    finally:
        db.close()
    assert list(first.parent.iterdir()) == [first]
    shutil.copyfile(first, root / "peer/db.sqlite")
    assert first.stat().st_ino != (root / "peer/db.sqlite").stat().st_ino

def inspect(root):
    out = []
    for part in ("live", "peer"):
        file = root / part / "db.sqlite"
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        db = sqlite3.connect(file.as_uri() + "?mode=ro&immutable=1", uri=True)
        try:
            row = db.execute("SELECT deviceID, marker FROM main.probe WHERE id=1").fetchone()
            version = db.execute("PRAGMA user_version").fetchone()[0]
            integrity = db.execute("PRAGMA quick_check").fetchone()[0]
        finally:
            db.close()
        out.append(dict(mainSHA256=digest, bytes=file.stat().st_size, inode=file.stat().st_ino,
                        writer=row[0], marker=row[1], version=version, integrity=integrity))
    return out

def verify(case, events, before, after):
    env, *proofs, teardown = events
    final = proofs[-1]
    conditions = {
        "positiveProofWhenExpected": final["allowed"] == (case in ("read", "write")),
        "firstProofBeforeSwap": len(proofs) == (2 if case.endswith("after-verified") else 1)
        and (len(proofs) == 1 or proofs[0]["allowed"]),
        "resourceAndMarkerGuard": teardown["forbiddenSQLRequests"] == 0 and teardown["changes"] == 0 and teardown["markerMatches"] and
        teardown["closeRC"] == 0 and teardown["rollbackRC"] == 0,
        "restoredMapLimit": teardown["restoredMmapLimit"] == env["originalMmapLimit"],
        "perConnectionLimitApplied": env["activeMmapLimit"] == (0 if case == "no-mmap" else 4096),
        "bothPhysicalCatalogsUnchanged": before == after and before[0]["mainSHA256"] == before[1]["mainSHA256"] and
        all(x["writer"] == WRITER and x["marker"] == MARKER and x["integrity"] == "ok" for x in after),
        "everyBorrowReleased": all(x["unfetchCount"] == (1 if x["borrowed"] else 0) and
        (not x["borrowed"] or x["unfetchRC"] == 0) for x in proofs),
    }
    if case == "no-txn":
        conditions["noTransactionNoFetch"] = final["txn"] == 0 and final["fetchCount"] == 0
    elif case == "no-mmap":
        conditions["nullHasNoUnfetch"] = final["fetchRC"] == 0 and not final["borrowed"] and final["unfetchCount"] == 0
    else:
        conditions["mappedRegular100ByteRange"] = all(x["contained"] and x["mappedFileOffsetMatchesRequest"] and x["vnodeRegular"]
                and x["regionBytes"] == x["expectedRegionBytes"] for x in proofs)
        if "before-open" in case:
            conditions["decoyAtCurrentPath"] = final["preMoved"] == 0 and final["mapDevInoMatchesPath"] and not final["mapDevInoMatchesHeld"]
        if "after-open" in case or "after-verified" in case:
            conditions["openFileMoved"] = final["preMoved"] == 1 and final["mapDevInoMatchesHeld"] and not final["mapDevInoMatchesPath"]
        if "decoy-return" in case:
            conditions["pathRestoredActualHandleIsDecoy"] = final["pathMatchesHeld"] and not final["mapDevInoMatchesHeld"] and not final["mapDevInoMatchesPath"]
        if case == "injected-proc-reject":
            conditions["faultWithValidMappingReleased"] = final["injectedProcRejection"] and final["mapDevInoMatchesHeld"] and final["unfetchRC"] == 0
    return conditions

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New directory for the executable and receipt")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("The vnode identity check uses the macOS libproc API")
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    binary = destination / "catalog_handle"
    compile_cmd = ["/usr/bin/clang", "-std=c11", "-D_DARWIN_C_SOURCE", "-O1", "-Wall", "-Wextra", "-Werror",
                   str(HERE / "catalog_handle.c"), "-lsqlite3", "-lproc", "-o", str(binary)]
    subprocess.run(compile_cmd, check=True)
    receipt = {"host": {"macOS": platform.mac_ver()[0], "kernel": platform.release(), "architecture": platform.machine()},
               "linked": subprocess.check_output(["/usr/bin/otool", "-L", binary], text=True).splitlines()[1:],
               "cases": []}
    for case in CASES:
        with tempfile.TemporaryDirectory(prefix="rawmaster-catalog-handle-") as temp:
            root = Path(os.path.realpath(temp))
            mode = "delete" if case.startswith("file-") else "wal"
            initial(root, mode)
            before = inspect(root)
            p = subprocess.run([binary, case, root], text=True, capture_output=True)
            after = inspect(root)
            events = [json.loads(line) for line in p.stdout.splitlines()]
            errors = (verify(case, events, before, after) if p.returncode == 0 and len(events) >= 3 else {"executable": False})
            result = {"case":case,"journalMode":mode,"exitStatus":p.returncode,"stderr":p.stderr,
                      "events":events,"fixturesBefore":before,"fixturesAfter":after,"assertions":errors}
            receipt["cases"].append(result)
            print(case, "PASS" if all(errors.values()) else "FAIL", [k for k,v in errors.items() if not v], flush=True)
    receipt["passed"] = sum(all(c["assertions"].values()) for c in receipt["cases"])
    receipt["total"] = len(receipt["cases"])
    (destination / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return not receipt["passed"] == receipt["total"]

if __name__ == "__main__":
    raise SystemExit(main())
