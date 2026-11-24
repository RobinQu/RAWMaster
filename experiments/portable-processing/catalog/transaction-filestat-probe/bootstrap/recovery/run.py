"""Single-machine Linux restart for genuinely uncheckpointed C ABI workbench delivery."""

import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import sqlite3
import struct
import subprocess as sp
import sys
import tempfile
import uuid
from durable_owner import (
    DurableGrant,
    v3,
    V3,
    NAMES,
    inspect_wal,
    read_fd,
)
from ledger import (
    Vault,
    canon,
    shafile,
    facts,
    fid,
    AT_EMPTY_PATH,
    AT_HANDLE_FID,
    AT_HANDLE_MNT_ID_UNIQUE,
)


def report(s, data):
    payload = json.dumps(data).encode()
    assert len(payload) < 96 * 1024 and s.send(payload) == len(payload)


def receive(s):
    return json.loads(s.recv(96 * 1024))


def main_only_count(path, dirpath):
    independent = dirpath / "main-only.sqlite"
    shutil.copyfile(path, independent)
    with sqlite3.connect(independent.as_uri() + "?mode=ro&immutable=1", uri=True) as db:
        return db.execute(
            "SELECT count(*) FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'"
        ).fetchone()[0]


def sha_state(root):
    return {
        n: (os.stat(root / n, follow_symlinks=False).st_ino, shafile(root / n))
        for n in NAMES.values()
        if (root / n).is_file()
    }


def shm_index(g, snapshot):
    f = read_fd(g.holds[3])
    try:
        h = os.pread(f, 96, 0)
    finally:
        os.close(f)
    committed = snapshot["commits"][-1]
    assert len(h) == 96 and h[:48] == h[48:] and h[12] == 1
    mx, dbpages, c1, c2 = struct.unpack_from("=4I", h, 16)
    salt = struct.unpack_from(">2I", h, 32)
    assert (
        mx == committed["frame"]
        and dbpages == committed["dbPages"]
        and list(salt) == committed["salt"]
        and [c1, c2] == committed["rolling"]
    )
    return {
        "twoHeadersAgree": True,
        "mxFrame": mx,
        "dbPages": dbpages,
        "saltAndFinalRollingChecksumMatchWAL": True,
    }


class ServiceCatalog(v3.Catalog):
    def boot(self):
        ch = self.owner.attach("keeper", [self.bins / "wal-recovery-keeper", self.db])
        try:
            state = v3.line(ch.proc)
            index = (
                shm_index(self.owner, self.owner.startup["wal"])
                if self.owner.restoring
                else None
            )
            self.owner.activate(ch, state)
            assert v3.command(ch.proc, "release") == {"released": True}
        except BaseException:
            # A rejected first attachment must not cause SQLite's graceful last-close checkpoint.
            ch.proc.kill()
            ch.proc.wait(timeout=5)
            ch.join()
            raise
        self.k = ch
        return {
            "txnState": state["txnState"],
            "walBytes": state["walBytes"],
            "readMask": state["readMask"],
            "exclusiveMask": state["exclusiveMask"],
            "mappingBytes": state["observedSharedMappingBytes"],
            "nativeEvidence": self.owner.last_attest,
            "rebuiltIndex": index,
        }

    @classmethod
    def reopen(cls, path, bins, vault):
        self = object.__new__(cls)
        self.path = path
        self.db = path / NAMES[1]
        self.destination = path / "delivery"
        self.k = None
        self.outputs = []
        self.started = []
        self.denials = []
        self.bins = bins
        self.owner = DurableGrant.recover(path, vault)
        return self

    def prepare_item(self, label):
        self.batch = str(uuid.uuid4())
        manifest = v3.cases.helper.source(
            self.owner.library, self.destination, self.batch
        )
        manifest["items"][0]["stem"] = label
        parent = self.req(
            "register",
            {
                "manifest": manifest,
                "directory": str(self.destination),
                "leaseMs": 120000,
            },
        )
        lease = {"token": parent["token"], "generation": 1, "ordinal": 1}
        lease["itemToken"] = self.req("claimItem", {**lease, "leaseMs": 120000})[
            "itemToken"
        ]
        folder = self.destination / (".rawmaster-export-" + str(uuid.uuid4()))
        folder.mkdir()
        stage = folder / "pixels.jpg"
        shutil.copyfile(v3.cases.helper.IMAGE, stage)
        result = self.req(
            "prepareItem",
            {
                **lease,
                "directory": str(self.destination),
                "stage": str(stage.relative_to(self.destination)),
                "suffix": 1,
            },
        )
        assert result["item"]["state"] == "prepared"
        final = self.destination / result["item"]["filename"]
        assert not final.exists()
        return {
            "batch": self.batch,
            "lease": lease,
            "stage": str(stage.relative_to(self.path)),
            "final": str(final.relative_to(self.path)),
            "inode": stage.stat().st_ino,
            "sha": shafile(stage),
        }

    def publish(self, item, rename=False):
        self.batch = item["batch"]
        assert (
            self.req(
                "publishItem",
                {**item["lease"], "directory": str(self.destination)},
                rename=rename,
            )["status"]
            == "published"
        )

    def ack(self, item, paired):
        self.batch = item["batch"]
        assert (
            self.req(
                "acknowledgeItem",
                {"ordinal": 1, "directory": str(self.destination)},
                paired=paired,
            )["status"]
            == "delivered"
        )

    def faulted_real_register(self):
        snapshot = inspect_wal(self.owner.holds[2])
        before = snapshot["bytes"]
        assert snapshot["unparsedTailBytes"] == 0
        cap = before + 24 + 777
        batch = str(uuid.uuid4())
        manifest = v3.cases.helper.source(self.owner.library, self.destination, batch)
        wire = {
            "operation": "scheduler",
            "request": {
                "op": "workbenchBatch",
                "command": {
                    "action": "register",
                    "directory": str(self.destination),
                    "manifest": manifest,
                    "leaseMs": 120000,
                },
            },
        }
        grants = [self.owner.directory, *[self.owner.holds[i] for i in (1, 2, 3)]]
        ch = self.owner.attach(
            "queue",
            [
                sys.executable,
                V3 / "child.py",
                self.bins / "librawmaster_library.so",
                self.db,
            ],
            extras=grants,
            env={"RM_MAP_ARM": "address", "RM_WAL_FIXTURE_LIMIT": str(cap)},
        )
        out, err = ch.proc.communicate(json.dumps(wire), timeout=8)
        ch.join()
        assert ch.proc.returncode == -signal.SIGXFSZ and not out, (
            ch.proc.returncode,
            out,
            err,
        )
        after = inspect_wal(
            self.owner.holds[2], [r["wal"] for r in self.owner.obligations]
        )
        assert after["bytes"] == cap and after["unparsedTailBytes"] == 801
        assert (self.path / NAMES[2]).stat().st_size == cap and after["commits"][
            -1
        ] == snapshot["commits"][-1]
        return {
            "nativeCAbiRegisterDiedWithSIGXFSZ": True,
            "bytesBefore": before,
            "kernelEnforcedFileLimit": cap,
            "realIncompleteFrameBytes": 801,
            "committedFramesBefore": snapshot["commits"][-1]["frame"],
            "committedFramesAfter": after["commits"][-1]["frame"],
            "faultedBatchID": batch,
        }


def crash_owner(root, bins, name, fd):
    channel = socket.socket(fileno=fd)
    channel.settimeout(20)
    v = Vault(root / "vault")
    c = ServiceCatalog(root / "catalog", bins)
    c.owner = DurableGrant.enroll(c, v)
    c.boot()
    items = [c.prepare_item("source-one")]
    c.owner.seal(c, "prepared-one")
    if name in ("two-confirmed", "semantic-obligation-mismatch"):
        items.append(c.prepare_item("source-two"))
        c.owner.seal(c, "prepared-two")
    if name in ("published-before-ACK", "ACK-before-confirmation", "confirmed-ACK"):
        c.publish(items[0])
        if name != "published-before-ACK":
            c.ack(items[0], False)
        if name == "confirmed-ACK":
            c.owner.seal(c, "ack-confirmed")
    fault = c.faulted_real_register() if name == "kernel-short-write" else None
    assert main_only_count(c.db, root) == 0
    record = v3.command(c.k.proc, "facts")
    snap = inspect_wal(c.owner.holds[2], [r["wal"] for r in c.owner.obligations])
    assert snap["bytes"] > 32 and snap["commits"] and facts(record)
    report(
        channel,
        {
            "keeper": c.k.proc.pid,
            "items": items,
            "snap": snap,
            "obligations": len(c.owner.obligations),
            "fault": fault,
            "committedFacts": facts(record),
            "batches": record["batches"],
            "submitted": c.outputs,
        },
    )
    if name == "old-child-live":
        assert channel.recv(16) == b"drop-lock"
        fcntl.flock(
            v.lock, fcntl.LOCK_UN
        )  # Authorized fixture fault, original keeper remains alive/registered.
        report(channel, {"released": True})
    channel.recv(16)
    raise AssertionError("fixture supervisor should be killed before graceful close")


def delivery_snapshot(db):
    return {
        str(p.relative_to(db)): (p.stat().st_ino, shafile(p))
        for p in (db / "delivery").rglob("*")
        if p.is_file()
    }


def reject(root, bins, reason, may_rebuild_index=False):
    db = root / "catalog"
    before = sha_state(db)
    physical = delivery_snapshot(db)
    try:
        with VaultContext(root / "vault") as v:
            c = ServiceCatalog.reopen(db, bins, v)
            try:
                c.boot()
            finally:
                if c.k:
                    c.k.proc.kill()
                    c.k.proc.wait(timeout=5)
                    c.k.join()
                c.owner.close()
    except (OSError, ValueError) as e:
        assert reason in str(e), (reason, e)
        after = sha_state(db)
        if may_rebuild_index:
            before.pop(NAMES[3])
            after.pop(NAMES[3])
        assert before == after and physical == delivery_snapshot(db), (
            "rejection altered a file",
            reason,
        )
        return str(e)
    raise AssertionError("an untrusted restart was accepted")


class VaultContext:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.vault = Vault(self.path)
        return self.vault

    def __exit__(self, *_):
        self.vault.close()


def independent_recovered(db, sibling):
    sibling.mkdir()
    main = sibling / NAMES[1]
    shutil.copyfile(db / NAMES[1], main)
    shutil.copyfile(db / NAMES[2], sibling / NAMES[2])
    with sqlite3.connect(main) as conn:
        return {
            "states": dict(
                conn.execute(
                    "SELECT key,json_extract(value,'$.state') FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'"
                )
            ),
            "reservations": conn.execute(
                "SELECT count(*) FROM lc_workbench_names"
            ).fetchone()[0],
            "quickCheck": conn.execute("PRAGMA quick_check").fetchone()[0],
        }


def drive(root, bins, name):
    root.mkdir(mode=0o700)
    Vault.provision(root / "vault")
    parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    parent.settimeout(12)
    process = sp.Popen(
        [
            sys.executable,
            __file__,
            "--owner",
            str(root),
            str(bins),
            name,
            str(child.fileno()),
        ],
        pass_fds=[child.fileno()],
        stderr=sp.PIPE,
    )
    child.close()
    pidfd = None
    kpidfd = None
    ret = {
        "case": name,
        "catalogRuntimeSHA256": shafile(bins / "librawmaster_library.so"),
    }
    try:
        try:
            info = receive(parent)
        except Exception:
            if process.poll() is not None:
                raise RuntimeError(process.stderr.read().decode())
            raise
        pidfd = os.pidfd_open(process.pid)
        kpidfd = os.pidfd_open(info["keeper"])
        assert not select.select([pidfd, kpidfd], [], [], 0)[0]
        lockid = (root / "vault/owner.lock").stat()
        for p in Path(f"/proc/{info['keeper']}/fd").iterdir():
            try:
                s = p.stat()
            except FileNotFoundError:
                continue
            assert (s.st_dev, s.st_ino) != (lockid.st_dev, lockid.st_ino)
        ret["keeperDidNotInheritSupervisorLock"] = True
        if name == "old-child-live":
            try:
                Vault(root / "vault")
            except BlockingIOError:
                pass
            else:
                raise AssertionError("two independent supervisors acquired vault lock")
            parent.send(b"drop-lock")
            assert receive(parent) == {"released": True}
            try:
                with VaultContext(root / "vault") as incoming:
                    incoming.drain_prior()
            except OSError as e:
                assert e.errno == errno.EBUSY
            else:
                raise AssertionError("active escaped fixture child was not fenced")
            ret["liveSignedPIDBlockedIndependentSupervisorAfterFlockLoss"] = True
        signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        assert process.wait(timeout=5) == -signal.SIGKILL
        assert select.select([kpidfd], [], [], 4)[0]
        db = root / "catalog"
        ret.update(
            {
                "supervisorSIGKILL": True,
                "keeperPidfdTerminated": True,
                "noCatalogFDInheritedByNewSupervisor": True,
                "mainOnlyItemCountBeforeCrash": 0,
                "hotWALBytes": info["snap"]["bytes"],
                "lastActualCommittedFrame": info["snap"]["commits"][-1]["frame"],
                "confirmedRecordsBeforeCrash": info["obligations"],
                "actualCAbiBeforeCrash": [c["action"] for c in info["submitted"]],
            }
        )
        if info["fault"]:
            ret["kernelFault"] = {
                k: v for k, v in info["fault"].items() if k != "faultedBatchID"
            }
        if name == "wrong-objects":
            ret["refused"] = []
            original = sha_state(db)
            for role, id in ((1, "main"), (2, "WAL"), (3, "existing SHM")):
                p = db / NAMES[role]
                saved = db / ("original-" + str(role))
                p.rename(saved)
                shutil.copyfile(saved, p)
                assert (
                    shafile(saved) == shafile(p)
                    and p.stat().st_ino != saved.stat().st_ino
                )
                try:
                    ret["refused"].append(reject(root, bins, id + " object"))
                finally:
                    p.unlink()
                    saved.rename(p)
            empty = db / NAMES[3]
            saved = db / "saved-owned-shm"
            empty.rename(saved)
            empty.touch()
            try:
                ret["refused"].append(reject(root, bins, "existing SHM object"))
            finally:
                empty.unlink()
                saved.rename(empty)
            original_dir = root / "original-catalog"
            db.rename(original_dir)
            shutil.copytree(original_dir, db)
            try:
                ret["refused"].append(reject(root, bins, "directory object differs"))
            finally:
                shutil.rmtree(db)
                original_dir.rename(db)
            assert original == sha_state(db)
        if name == "semantic-obligation-mismatch":
            with VaultContext(root / "vault") as v:
                _, _, obligations = v.history()
                import copy

                original = obligations[-1]
                # An intentionally incorrect private service confirmation. Data FIDs, WAL prefix and HMAC are valid.
                wrong = copy.deepcopy(original)
                wrong["sequence"] += 1
                key = next(iter(obligations[0]["facts"]))
                wrong["facts"][key]["ticketSHA256"] = "0" * 64
                assert len(original["facts"]) == 2 and len(obligations[0]["facts"]) == 1
                v.append(wrong)
            ret["expectedRejection"] = reject(
                root, bins, "confirmed work identity missing", may_rebuild_index=True
            )
            ret["allTwoPhysicalTicketsMatchIndependentSQLite"] = (
                len(independent_recovered(db, root / "truth")["states"]) == 2
            )
            assert ret["allTwoPhysicalTicketsMatchIndependentSQLite"] and all(
                not (db / i["final"]).exists() and shafile(db / i["stage"]) == i["sha"]
                for i in info["items"]
            )
            ret["allStageFilesPreservedBothFinalsVacant"] = True
            ret["completed"] = False
            return ret
        if name == "damaged-owned-index":
            p = db / NAMES[3]
            original_inode = p.stat().st_ino
            with p.open("r+b") as f:
                f.write(bytes(96))
                f.flush()
                os.fsync(f.fileno())
            assert p.read_bytes()[:96] == bytes(96)
            ret["intentionallyClearedOwnedIndexHeaders"] = True
        if name == "auth-record-damaged":
            record = next(
                p
                for p in sorted((root / "vault").glob("record.*"), reverse=True)
                if json.loads(p.read_bytes())["payload"]["body"]["kind"] == "commit"
            )
            original = record.read_bytes()
            parsed = json.loads(original)
            parsed["payload"]["body"]["label"] = "changed"
            record.write_bytes(canon(parsed))
            try:
                ret["refused"] = reject(root, bins, "invalid prior service record")
            finally:
                record.write_bytes(original)
        if name == "short-acknowledged-prefix":
            path = db / NAMES[2]
            oldinode = path.stat().st_ino
            commits = info["snap"]["commits"]
            assert len(commits) >= 2
            end = commits[-2]["end"]
            with path.open("r+b") as f:
                f.truncate(end)
                f.flush()
                os.fsync(f.fileno())
            assert path.stat().st_ino == oldinode
            ret["expectedRejection"] = reject(root, bins, "acknowledged WAL prefix")
            ret["sameOriginalWALInode"] = True
            ret["bytesAfterPartialMediaLoss"] = end
            ret["independentSQLiteAfterEarlierValidCommit"] = independent_recovered(
                db, root / "earlier"
            )
            assert all(
                k not in ret["independentSQLiteAfterEarlierValidCommit"]["states"]
                or ret["independentSQLiteAfterEarlierValidCommit"]["states"][k]
                != "prepared"
                for k in info["committedFacts"]
            )
            assert all(
                not (db / x["final"]).exists() and shafile(db / x["stage"]) == x["sha"]
                for x in info["items"]
            )
            ret["stagePreservedFinalVacant"] = True
            ret["completed"] = False
            return ret
        if name in ("new-SHM", "kernel-short-write", "two-confirmed"):
            old = db / NAMES[3]
            saved = db / "old-verified-volatile-index"
            old.rename(saved)
            ret["oldIndexBeforeRemoved"] = shafile(saved)
        with VaultContext(root / "vault") as v:
            c = ServiceCatalog.reopen(db, bins, v)
            state = c.boot()
            if name == "damaged-owned-index":
                assert (db / NAMES[3]).stat().st_ino == original_inode and (
                    db / NAMES[3]
                ).read_bytes()[:96] != bytes(96)
                ret["SQLiteRebuiltExistingOwnedIndexInPlace"] = True
            try:
                ret["recoveryTransaction"] = state
                raw = v3.command(c.k.proc, "facts")
                assert raw["batches"] == info["batches"], (raw, info["batches"])
                assert facts(raw) == info["committedFacts"]
                if name in ("new-SHM", "kernel-short-write", "two-confirmed"):
                    assert (db / NAMES[3]).stat().st_ino != saved.stat().st_ino
                for item in info["items"]:
                    final = db / item["final"]
                    if not final.exists():
                        c.publish(item, rename=name == "new-SHM")
                    else:
                        assert (
                            final.stat().st_ino == item["inode"]
                            and shafile(final) == item["sha"]
                        )
                    c.ack(item, True)
                    assert (
                        final.stat().st_ino == item["inode"]
                        and shafile(final) == item["sha"]
                        and not (db / item["stage"]).exists()
                    )
                ending = c.owner.seal(c, "recovered-ack")
                assert all(
                    x["state"] == "delivered" and x["reservations"] == 0
                    for x in ending["facts"].values()
                )
                assert v3.command(c.k.proc, "integrity") == {
                    "quickCheck": "ok",
                    "foreignKeyViolations": 0,
                }
                ret.update(
                    {
                        "completed": True,
                        "deliveredCount": len(info["items"]),
                        "duplicateACKs": len(info["items"]),
                        "bytesEach": (db / info["items"][0]["final"]).stat().st_size,
                        "sha256Each": info["items"][0]["sha"],
                        "allExternallyConfirmedFactsRecovered": True,
                        "zeroReservationsAfterACK": True,
                        "quickCheck": "ok",
                        "foreignKeyViolations": 0,
                        "actualCAbiRecoveryActions": [x["action"] for x in c.outputs],
                    }
                )
            finally:
                c.shutdown()
                c.owner.close()
        return ret
    finally:
        parent.close()
        if process.poll() is None:
            process.kill()
            process.wait()
        if pidfd is not None:
            os.close(pidfd)
        if kpidfd is not None:
            os.close(kpidfd)


def capabilities(path):
    path.mkdir(mode=0o700)
    original = path / "source"
    original.write_bytes(b"fixture")
    other = path / "copy"
    shutil.copyfile(original, other)
    root = os.open(path, os.O_DIRECTORY | os.O_PATH | os.O_NOFOLLOW)
    held = os.open(original, os.O_PATH | os.O_NOFOLLOW)
    try:
        try:
            fid(held, AT_EMPTY_PATH)
            plain = 0
        except OSError as e:
            plain = e.errno
        real = fid(held)
        from_name = fid(root, AT_HANDLE_FID | AT_HANDLE_MNT_ID_UNIQUE, b"source")
        peer = fid(root, AT_HANDLE_FID | AT_HANDLE_MNT_ID_UNIQUE, b"copy")
        original.rename(path / "moved")
        after = fid(root, AT_HANDLE_FID | AT_HANDLE_MNT_ID_UNIQUE, b"moved")
        assert (
            real == from_name == after and real != peer and os.fstat(held).st_nlink == 1
        )
        return {
            "ordinaryHandleErrno": plain,
            "opaqueHandleType": real["type"],
            "opaqueHandleBytes": len(bytes.fromhex(real["handle"])),
            "heldFDNameAndRenameMatch": True,
            "sameBytesSeparateObjectDiffers": True,
            "mainRequiresOnlyOneHardLink": True,
        }
    finally:
        os.close(held)
        os.close(root)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--owner":
        crash_owner(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], int(sys.argv[5]))
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-dir", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--case")
    a = ap.parse_args()
    bins = a.build_dir.resolve() / "target/debug"
    names = [
        "normal-hot-WAL",
        "new-SHM",
        "published-before-ACK",
        "ACK-before-confirmation",
        "confirmed-ACK",
        "two-confirmed",
        "kernel-short-write",
        "wrong-objects",
        "auth-record-damaged",
        "old-child-live",
        "short-acknowledged-prefix",
        "damaged-owned-index",
        "semantic-obligation-mismatch",
    ]
    assert not a.case or a.case in names
    record = {
        "sqliteSourceID": "2026-06-03 19:12:13 d6e03d8c777cfa2d35e3b60d8ec3e0187f3e9f99d8e2ee9cac695fd6fcdf1a24",
        "runtimeSHA256": shafile(bins / "librawmaster_library.so"),
        "keeperSHA256": shafile(bins / "wal-recovery-keeper"),
        "cases": [],
    }
    with tempfile.TemporaryDirectory(
        prefix="rawmaster-wal-recovery-", dir="/tmp"
    ) as tmp:
        record["fileHandleCapabilities"] = capabilities(Path(tmp) / "capabilities")
        for name in [a.case] if a.case else names:
            record["cases"].append(drive(Path(tmp) / name, bins, name))
            print("passed", name, flush=True)
            a.output.write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()
