#!/usr/bin/env python3
"""Darwin subprocess-only observer of native SQLite WAL/SHM attachment lifetimes."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ID = ctypes.c_uint64 * 4
ROLES = {"main": "db.sqlite", "wal": "db.sqlite-wal", "shm": "db.sqlite-shm"}
CASES = {
    "read-wal": ("read", "dirty", "normal", "", "never"),
    "write-wal": ("write", "dirty", "normal", "", "never"),
    "read-empty": ("read", "empty", "normal", "", "never"),
    "write-empty": ("write", "empty", "normal", "", "never"),
    "wal-before": ("read", "dirty", "normal", "wal", "before"),
    "shm-before": ("read", "dirty", "normal", "shm", "before"),
    "wal-after": ("write", "dirty", "normal", "wal", "after"),
    "shm-after": ("write", "dirty", "normal", "shm", "after"),
    "both-after": ("write", "dirty", "normal", "wal shm", "after"),
    "wal-return": ("read", "dirty", "normal", "wal", "return"),
    "shm-return": ("read", "dirty", "normal", "shm", "return"),
    "both-return": ("read", "dirty", "normal", "wal shm", "return"),
    "exclusive-heap": ("read", "empty", "exclusive", "", "never"),
    "rollback": ("read", "empty", "rollback", "", "never"),
}


def setup(db, journal, dirty):
    assert db.execute(f"PRAGMA journal_mode={journal}").fetchone()[0] == journal
    db.execute("PRAGMA wal_autocheckpoint=0")
    db.execute("CREATE TABLE probe(id INTEGER PRIMARY KEY, writer TEXT, marker TEXT)")
    db.execute("INSERT INTO probe VALUES(1,'same-writer','from-main')")
    db.commit()
    if journal == "wal":
        assert db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0] == 0
    if dirty:
        db.execute("UPDATE probe SET marker='only-in-wal' WHERE id=1")
        db.commit()


def keeper(path, form):
    db = sqlite3.connect(path)
    setup(db, "wal", form == "dirty")
    print("ready", flush=True)
    try:
        assert sys.stdin.readline().strip() == "finish"
    finally:
        db.close()


def default_artifact_directory():
    for parent in HERE.parents:
        if (parent / "Modules/LibraryCatalog/Cargo.toml").is_file():
            return parent / "output/035-development/catalog-attachment-replay"
    return Path(tempfile.gettempdir()) / "rawmaster-catalog-attachment-replay"


def build(artifacts):
    flags = [
        "/usr/bin/clang",
        "-std=c11",
        "-D_DARWIN_C_SOURCE",
        "-O1",
        "-Wall",
        "-Wextra",
        "-Werror",
    ]
    subprocess.run(
        flags + [HERE / "gate.c", "-lsqlite3", "-o", artifacts / "gate"], check=True
    )
    subprocess.run(
        flags + [HERE / "worker.c", "-lsqlite3", "-lproc", "-o", artifacts / "worker"],
        check=True,
    )
    subprocess.run(
        flags
        + [
            "-dynamiclib",
            HERE / "inspector.c",
            "-lproc",
            "-o",
            artifacts / "inspector.dylib",
        ],
        check=True,
    )


def load_inspector(artifacts):
    api = ctypes.CDLL(str(artifacts / "inspector.dylib"), use_errno=True)
    api.inspect_fd.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ID)]
    api.inspect_region.argtypes = [
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_uint64,
        ctypes.POINTER(ID),
    ]
    api.inspect_pin.argtypes = [ctypes.c_int, ctypes.POINTER(ID)]
    api.exchange_files.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    return api


def get(api_fn, *args):
    out = ID()
    ctypes.set_errno(0)
    ok = api_fn(*args, ctypes.byref(out))
    return list(out) if ok else None


def pinned(api, path):
    if not path.exists():
        return None
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        return get(api.inspect_pin, fd)
    finally:
        os.close(fd)


def digest(path):
    if not path.is_file():
        return None
    return {
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def file_digests(folder):
    return {role: digest(folder / name) for role, name in ROLES.items()}


def run_case(api, root, name, artifacts):
    mode, form, storage, selection, timing = CASES[name]
    selected = selection.split()
    original, peer = root / "live", root / "peer"
    original.mkdir()
    peer.mkdir()
    dbfile = original / ROLES["main"]
    keep = None
    if storage == "normal":
        keep = subprocess.Popen(
            [sys.executable, __file__, "--keeper", str(dbfile), form],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        assert keep.stdout.readline().strip() == "ready"
    else:
        connection = sqlite3.connect(dbfile)
        setup(connection, "wal" if storage == "exclusive" else "delete", False)
        connection.close()
        if storage == "exclusive":
            (original / ROLES["wal"]).write_bytes(b"")
            (original / ROLES["shm"]).write_bytes(b"\0" * 32768)
    for filename in ROLES.values():
        f = original / filename
        if f.exists():
            shutil.copyfile(f, peer / filename)
    before = file_digests(original)
    assert before == file_digests(peer)
    expected_fds = {
        role: os.open(original / n, os.O_RDONLY | os.O_NOFOLLOW)
        for role, n in ROLES.items()
        if (original / n).exists()
    }
    trusted = {role: get(api.inspect_pin, fd) for role, fd in expected_fds.items()}
    twin = {role: pinned(api, peer / n) for role, n in ROLES.items()}
    assert all(trusted[k] != twin[k] for k in trusted)
    swapped = set()

    def choose(target):
        for role in selected:
            want = role in target
            if want != (role in swapped):
                a, b = original / ROLES[role], peer / ROLES[role]
                assert api.exchange_files(os.fsencode(a), os.fsencode(b)) == 0
                if want:
                    swapped.add(role)
                else:
                    swapped.remove(role)

    def take(row):
        pp = pinned(api, original / ROLES["main"])
        physical = {
            "main": pp,
            **{k: pinned(api, original / ROLES[k]) for k in ("wal", "shm")},
        }
        addr = row.pop("address")
        rem_main = (
            get(api.inspect_fd, p.pid, row["mainFd"]) if row["mainFd"] >= 0 else None
        )
        rem_wal = (
            get(api.inspect_fd, p.pid, row["walFd"]) if row["walFd"] >= 0 else None
        )
        rem_shm = (
            get(api.inspect_region, p.pid, addr, row["length"])
            if addr and row["length"] > 0
            else None
        )
        row["addressPresent"] = bool(addr)
        row["remoteMain"] = rem_main
        row["remoteWal"] = rem_wal
        row["remoteShm"] = rem_shm
        row["currentNames"] = physical
        row["mainPathPinned"] = pp == trusted["main"]
        row["mainAuthorized"] = bool(
            row["mainWitness"]
            and rem_main
            and row["mainIdentity"] == rem_main == trusted["main"] == pp
        )
        for role, remote, key, proof in [
            ("wal", rem_wal, "walIdentity", "walWitness"),
            ("shm", rem_shm, "shmIdentity", "shmWitness"),
        ]:
            mine = row[key]
            row[role + "RemoteAgrees"] = bool(row[proof] and remote and mine == remote)
            row[role + "MatchesTrusted"] = bool(
                row[role + "RemoteAgrees"] and mine == trusted.get(role)
            )
            row[role + "MatchesCurrent"] = bool(
                row[role + "RemoteAgrees"] and mine == physical[role]
            )
            row[role + "Authorized"] = (
                row[role + "MatchesTrusted"] and row[role + "MatchesCurrent"]
            )
        row["attachmentsVerified"] = (
            row["mainAuthorized"] and row["walAuthorized"] and row["shmAuthorized"]
        )

    bar_digests = {}
    events = []
    p = subprocess.Popen(
        [artifacts / "worker", dbfile, mode, form, storage],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        for line in p.stdout:
            row = json.loads(line)
            event = row["event"]
            if event == "pause":
                phase = row["phase"]
                if phase == "beforeOpen" and timing in ("before", "return"):
                    choose(selected)
                if phase == "active" and timing == "return":
                    choose([])
                if phase == "second" and timing == "after":
                    choose(selected)
                if phase == "restore":
                    chose_peer = (
                        set(selected) if timing in ("before", "return") else set()
                    )
                    choose(chose_peer)
                    row["namesBeforeSQLiteTeardown"] = {
                        role: pinned(api, original / filename)
                        for role, filename in ROLES.items()
                    }
                    row["matchExactOpenSet"] = all(
                        row["namesBeforeSQLiteTeardown"][role]
                        == (twin[role] if role in chose_peer else trusted.get(role))
                        for role in ROLES
                    )
                if phase in ("active", "second"):
                    bar_digests["first" if phase == "active" else "second"] = {
                        "live": file_digests(original),
                        "peer": file_digests(peer),
                    }
            if event == "cursor":
                take(row)
                row["beforeMeasurement"] = bar_digests[row["point"]]
                row["afterMeasurement"] = {
                    "live": file_digests(original),
                    "peer": file_digests(peer),
                }
                row["mainWalShmBytesUnchangedDuringObservation"] = (
                    row["afterMeasurement"] == row["beforeMeasurement"]
                )
            events.append(row)
            if event != "end":
                p.stdin.write("x")
                p.stdin.flush()
        error = p.stderr.read()
        code = p.wait(timeout=8)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
        choose([])
        for fd in expected_fds.values():
            os.close(fd)
        if keep:
            keep.stdin.write("finish\n")
            keep.stdin.flush()
            keep.wait(timeout=8)
    final = file_digests(original)
    db = sqlite3.connect(dbfile.as_uri() + "?immutable=1&mode=ro", uri=True)
    try:
        result = db.execute("SELECT writer,marker FROM probe WHERE id=1").fetchone()
        integrity = db.execute("PRAGMA quick_check").fetchone()[0]
    finally:
        db.close()
    checks = {
        "childCleanExit": code == 0,
        "fixtureIntegrity": integrity == "ok"
        and result
        == ("same-writer", "only-in-wal" if form == "dirty" else "from-main"),
    }
    proofs = [r for r in events if r["event"] == "cursor"]
    last = next((r for r in events if r["event"] == "end"), {})
    checks["twoTrueTransactions"] = len(proofs) == 2 and all(
        r["active"] and r["txn"] == (2 if mode == "write" else 1) for r in proofs
    )
    checks["noSQLWritesOrLostLifetimes"] = (
        last.get("changes") == 0
        and last.get("denied") == 0
        and last.get("afterRollback") == 0
        and last.get("walInvalidated")
        and last.get("lastMapInvalidated")
        and last.get("restored")
    )
    checks["exactOpenSetRestoredBeforeSQLiteTeardown"] = any(
        r.get("phase") == "restore" and r.get("matchExactOpenSet") for r in events
    )
    checks["actualMainMatchesAnchor"] = len(proofs) == 2 and all(
        r["mainAuthorized"] for r in proofs
    )
    checks["noBytesChangedInMeasurements"] = len(proofs) == 2 and all(
        r["mainWalShmBytesUnchangedDuringObservation"] for r in proofs
    )
    if storage == "normal":
        checks["realWALAndSHM"] = len(proofs) == 2 and all(
            r["walRemoteAgrees"] and r["shmRemoteAgrees"] and r["mainPathPinned"]
            for r in proofs
        )
        checks["unmapAndRelease"] = (
            last.get("walCloses") == 1
            and last.get("mainCloses") == 1
            and last.get("shmUnmaps", 0) >= 1
            and last.get("exclusiveAfterRollback") == 0
            and last.get("sharedAfterRollback") == 0
        )
        for row in proofs:
            first = row["point"] == "first"
            for role in ("wal", "shm"):
                new_at_open = role in selected and timing in ("before", "return")
                post_swap = role in selected and (
                    (timing == "after" and not first) or timing == "return"
                )
                checks[row["point"] + "-" + role] = row[role + "MatchesTrusted"] == (
                    not new_at_open
                ) and row[role + "MatchesCurrent"] == (not post_swap)
            checks[row["point"] + "-decision"] = row["attachmentsVerified"] == (
                not selected or (timing == "after" and first)
            )
    else:
        checks["unsupportedSHMRejected"] = len(proofs) == 2 and all(
            not p["shmWitness"] and not p["attachmentsVerified"] for p in proofs
        )
        if storage == "exclusive":
            checks["unusedPlausibleShmDoesNotCount"] = trusted.get(
                "shm"
            ) is not None and all(not p["addressPresent"] for p in proofs)
    return {
        "case": name,
        "mode": mode,
        "form": form,
        "storage": storage,
        "swap": selection,
        "when": timing,
        "trustedIDs": trusted,
        "peerIDs": twin,
        "initialByteIdentical": before,
        "afterNormalClose": final,
        "exit": code,
        "stderr": error,
        "afterNormalCloseLogical": result,
        "assertions": checks,
        "events": events,
    }


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--keeper":
        keeper(sys.argv[2], sys.argv[3])
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="+", choices=CASES, default=list(CASES))
    ap.add_argument("--artifact-dir", type=Path, default=default_artifact_directory())
    ap.add_argument(
        "--output", type=Path, help="Defaults to receipt.json in --artifact-dir"
    )
    ap.add_argument("--no-build", action="store_true")
    args = ap.parse_args()
    artifacts = args.artifact_dir.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    output = (args.output or (artifacts / "receipt.json")).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if not args.no_build:
        build(artifacts)
    api = load_inspector(artifacts)
    with tempfile.TemporaryDirectory(prefix="rm-wal-hook-") as t:
        gate = json.loads(
            subprocess.check_output(
                [artifacts / "gate", Path(t).resolve() / "gate.db"], text=True
            )
        )
    result = {
        "macOS": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "keeperSQLite": sqlite3.sqlite_version,
        "gate": gate,
        "cases": [],
    }
    for name in args.only:
        with tempfile.TemporaryDirectory(prefix="rm-vfs-") as t:
            c = run_case(api, Path(t).resolve(), name, artifacts)
            failures = [k for k, ok in c["assertions"].items() if not ok]
            print(
                name,
                "PASS" if not failures else "FAIL",
                failures,
                c["stderr"],
                flush=True,
            )
            result["cases"].append(c)
            output.write_text(json.dumps(result, indent=2) + "\n")
    if any(not all(c["assertions"].values()) for c in result["cases"]):
        sys.exit(1)


if __name__ == "__main__":
    main()
