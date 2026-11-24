"""Exercise cold APFS attachment authority and reuse the real X2 Rust queue and Apple reader."""

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess as sp
import tempfile
import uuid
from supervisor import Owner, Q, X, NAMES, pinned, closeall, ensure

CASES = (
    "fresh",
    "empty-WAL",
    "empty-SHM",
    "partial-WAL",
    "partial-with-foreign-SHM",
    "partial-same-bytes-WAL",
    "old-live-reader",
    "live-reader-after-checkpoint",
    "published-before-generation-change",
)


def stale_call(operation, expected=None):
    try:
        operation()
    except OSError as err:
        if expected:
            ensure(err.errno in expected)
        return err.errno
    raise AssertionError("operation unexpectedly proceeded")


def test_external(owner, index):
    name = owner.path / NAMES[index]
    fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        assert stale_call(owner.begin, (errno.EEXIST,)) == errno.EEXIST
        assert (
            pinned(fd) == (name.stat().st_dev, name.stat().st_ino)
            and os.fstat(fd).st_size == 0
        )
        assert set(owner.holds) == {1} and owner.keeper is None
        name.unlink()
    finally:
        os.close(fd)
    return {"unknownEmptyEntryPreserved": NAMES[index], "attachmentsRegistered": 0}


def test_partial(owner, kind):
    fault = "entryAfterWAL" if kind == "partial-with-foreign-SHM" else "denySHM"
    denied = stale_call(lambda: owner.begin(fault), (errno.EIO, errno.ECONNRESET))
    errno_at_role = errno.EEXIST if fault == "entryAfterWAL" else errno.EIO
    assert any(
        e.get("deniedRole") == 3 and e["errno"] == errno_at_role for e in owner.events
    )
    wal = owner.path / NAMES[1]
    shm = owner.path / NAMES[2]
    assert (
        owner.keeper is None and owner.phase == "pending" and set(owner.holds) == {1, 2}
    )
    original = pinned(owner.holds[2])
    assert (
        original == (wal.stat().st_dev, wal.stat().st_ino) and wal.stat().st_size == 0
    )
    result = {
        "firstKeeperDenied": denied,
        "directRoleErrno": errno_at_role,
        "onlyCreatedWALRegistered": True,
        "failedKeeperTerminated": True,
    }
    if kind == "partial-with-foreign-SHM":
        before = shm.stat()
        assert before.st_size == 0
        denied = stale_call(owner.begin, (errno.EEXIST,))
        assert (
            owner.keeper is None
            and shm.stat().st_ino == before.st_ino
            and set(owner.holds) == {1, 2}
        )
        shm.unlink()
        result["unknownRemainingSHMKept"] = True
    elif kind == "partial-same-bytes-WAL":
        saved = owner.path / "detached-original"
        wal.rename(saved)
        wal.write_bytes(b"")
        try:
            assert wal.stat().st_ino != saved.stat().st_ino and X.sha(wal) == X.sha(
                saved
            )
            stale_call(owner.begin, (errno.ESTALE,))
            assert (
                owner.keeper is None
                and saved.stat().st_ino == original[1]
                and not shm.exists()
            )
        finally:
            wal.unlink()
            saved.rename(wal)
        result["partialSameBytesReplacementDeniedWhileOriginalPinned"] = True
    else:
        assert not shm.exists()
    return result


def independent_ticket(o, main_only=False):
    sql = "SELECT json_object('state',json_extract(value,'$.state'),'ticket',json_extract(value,'$.ticket'),'reservations',(SELECT count(*) FROM lc_workbench_names)) FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'"
    db = o.db.as_uri() + "?mode=ro&immutable=1" if main_only else o.db
    return json.loads(
        sp.check_output(["/usr/bin/sqlite3", "-readonly", db, sql], text=True)
    )


def snapshot(o):
    return {
        "initialLastClose": o.origin_close,
        "initialCheckpoint": o.initial_checkpoint,
        "caseEvents": o.events,
        "activations": o.reports,
        "requests": o.commands,
    }


def run_case(o, name):
    fault = None
    if name in ("empty-WAL", "empty-SHM"):
        fault = test_external(o, 1 if name == "empty-WAL" else 2)
    if name.startswith("partial-"):
        fault = test_partial(o, name)
    g1 = o.begin()
    other = o.peer()
    busy = X.command(other, "write")
    assert busy["rc"] & 255 == 5 and busy["state"] == 0
    o.release()
    assert (
        X.command(other, "write")["state"] == 2
        and X.command(other, "rollback")["rc"] == 0
    )
    if name != "old-live-reader":
        o.drop_peer(other)
    parent = o.request(
        "register",
        {
            "manifest": Q.source(o.origin["library"], o.out, o.batch),
            "directory": str(o.out),
            "leaseMs": 120000,
        },
    )
    own = {"ordinal": 1, "generation": 1, "token": parent["token"]}
    own["itemToken"] = o.request("claimItem", {**own, "leaseMs": 120000})["itemToken"]
    if name == "old-live-reader":
        assert X.command(other, "read")["state"] == 1
    folder = o.out / (".rawmaster-export-" + str(uuid.uuid4()))
    folder.mkdir()
    stage = folder / "pixels.jpg"
    shutil.copyfile(Q.IMAGE, stage)
    inode = stage.stat().st_ino
    digest = X.sha(stage)
    a = o.request(
        "prepareItem",
        {
            **own,
            "directory": str(o.out),
            "stage": str(stage.relative_to(o.out)),
            "suffix": 1,
        },
    )
    target = o.out / a["item"]["filename"]
    original = X.command(o.keeper, "ticket")
    assert (
        original["state"] == "prepared"
        and original["reservations"] == 1
        and independent_ticket(o) == original
    )
    publish = {**own, "directory": str(o.out)}
    ack = {"ordinal": 1, "directory": str(o.out)}
    published_early = name == "published-before-generation-change"
    if published_early:
        assert (
            o.request("publishItem", publish)["status"] == "published"
            and target.stat().st_ino == inode
        )
    barrier = None
    if name in ("old-live-reader", "live-reader-after-checkpoint"):
        if name == "live-reader-after-checkpoint":
            assert o.ck() == {"rc": 0, "busy": 0, "log": 0, "checkpointed": 0}
            other = o.peer()
            assert X.command(other, "read")["state"] == 1
        physical = o.ck()
        assert stale_call(lambda: o.retire(original), (errno.EBUSY,)) == errno.EBUSY
        assert o.phase == "active" and o.epoch == 1 and other.poll() is None
        if name == "old-live-reader":
            assert (
                physical["rc"] == physical["busy"] * 5 == 5
                and physical["log"] > physical["checkpointed"]
            )
        else:
            assert os.fstat(o.holds[2]).st_size == 0
        barrier = {
            "sqliteCheckpointWithReader": physical,
            "retirementRefusedWhileActualReaderAlive": True,
        }
        o.drop_peer(other)
    c, old = o.retire(original)
    try:
        assert all(not (o.path / n).exists() for n in NAMES[1:]) and all(
            os.fstat(fd).st_nlink == 0 for fd in old
        )
        assert independent_ticket(o, main_only=True) == original
        assert all(not os.path.lexists(o.path / n) for n in NAMES[1:])
        main = pinned(o.holds[1])
        g2 = o.begin()
        assert main == pinned(o.holds[1]) and all(
            pinned(old[r - 2]) != pinned(o.holds[r]) for r in (2, 3)
        )
        o.release()
        assert X.command(o.keeper, "ticket") == independent_ticket(o) == original
        saved_fds = o.fds
        saved_env = o.env
        try:
            o.fds = [o.dirfd, o.holds[1], *old]
            o.env = dict(o.env, RM_MAC_GRANTS=",".join(map(str, o.fds)))
            o.request(
                "acknowledgeItem" if published_early else "publishItem",
                ack if published_early else publish,
                deny=True,
            )
        finally:
            o.fds = saved_fds
            o.env = saved_env
        bad = [p for p in o.commands[-1]["phases"] if not p["allowed"]]
        assert (
            len(bad) == 1 and bad[0]["phase"] == "read" and bad[0]["rows"][0]["matches"]
        )
        assert all(
            not r["matches"]
            and r["actual"] == r["directoryEntry"]
            and r["actual"] != r["authorized"]
            for r in bad[0]["rows"][1:]
        )
        assert independent_ticket(o) == original and (
            target.exists() == published_early
        )
        if not published_early:
            assert stage.stat().st_ino == inode and X.sha(stage) == digest
            assert o.request("publishItem", publish)["status"] == "published"
        assert target.stat().st_ino == inode and X.sha(target) == digest
        a = o.request("acknowledgeItem", ack)
        b = o.request("acknowledgeItem", ack)
        end = independent_ticket(o)
        assert (
            a == b
            and a["status"] == "delivered"
            and end["ticket"] == original["ticket"]
            and end["state"] == "delivered"
            and end["reservations"] == 0
            and not stage.exists()
        )
        integrity = X.command(o.keeper, "integrity")
        assert integrity == {"quick": "ok", "foreign": 0}
        return {
            "case": name,
            "coldFault": fault,
            "reader": barrier,
            "systemWriterBusyThenRetried": True,
            "retirement": c,
            "originalTicketReadFromImmutableMainWithBothNamesAbsent": True,
            "oldBothUnlinkedButPinned": True,
            "sameMainNewDistinctSidecars": True,
            "oldPinsRefusedByActualRustRead": True,
            "originalTicketSHA256": hashlib.sha256(
                json.dumps(
                    original["ticket"], sort_keys=True, separators=(",", ":")
                ).encode()
            ).hexdigest(),
            "repeatACK": True,
            "finalOriginalInode": True,
            "integrity": integrity,
            "JPEGBytes": target.stat().st_size,
            "JPEGSHA256": digest,
            **snapshot(o),
        }
    finally:
        closeall(old)


def system_baseline(parent, bins, runtime):
    result = []
    for readonly, checkpoint in (
        (False, False),
        (True, False),
        (False, True),
        (True, True),
    ):
        d = parent / f"default-{readonly}-{checkpoint}"
        d.mkdir(mode=0o700)
        db = d / NAMES[0]
        peer, origin = X.open_peer([bins / "system-keeper", runtime, db, Q.DDL])
        try:
            if readonly:
                assert (
                    sp.check_output(
                        [
                            "/usr/bin/sqlite3",
                            "-readonly",
                            db,
                            "SELECT count(*) FROM lc_meta",
                        ],
                        text=True,
                    )
                    .strip()
                    .isdigit()
                )
            ck = X.command(peer, "truncate") if checkpoint else None
            X.done(peer)
            files = {n: (d / n).stat().st_size for n in NAMES}
            assert files[NAMES[1]] == 0 and files[NAMES[2]] == 32768
            result.append(
                {
                    "additionalReadOnlyProcess": readonly,
                    "explicitCheckpoint": ck,
                    "filesAfterNormalSystemClose": files,
                    "sourceID": origin["sourceID"],
                }
            )
        finally:
            X.cleanup_process(peer)
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--build-dir", required=True, type=Path)
    p.add_argument("--interop-build", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--runtime", type=Path, default=X.RUNTIME)
    p.add_argument("--case", choices=CASES)
    cfg = p.parse_args()
    build = cfg.build_dir.resolve()
    x = cfg.interop_build.resolve()
    runtime = cfg.runtime.resolve()
    system = build / "system-origin"
    keeper = build / "apfs-owner-keeper"
    report = {
        "host": platform.platform(),
        "runtimeSHA256": X.sha(runtime),
        "originSHA256": X.sha(system),
        "privateKeeperSHA256": X.sha(keeper),
        "existingRealRustCABIExecutableSHA256": X.sha(x / "target/debug/mac-private"),
        "directKeeperDependencies": sp.check_output(
            ["otool", "-L", keeper], text=True
        ).splitlines()[1:],
        "cases": [],
    }
    with tempfile.TemporaryDirectory(prefix="generated-apfs-", dir=build) as tmp:
        if not cfg.case:
            report["systemDefaultClose"] = system_baseline(Path(tmp), x, runtime)
        for name in [cfg.case] if cfg.case else CASES:
            o = Owner(Path(tmp) / name, x, runtime, keeper)
            try:
                report["cases"].append(run_case(o, name))
            finally:
                o.close()
            cfg.output.write_text(json.dumps(report, indent=2) + "\n")
            print("passed", name, flush=True)


if __name__ == "__main__":
    main()
