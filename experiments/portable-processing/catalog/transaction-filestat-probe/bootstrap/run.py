"""Real managed cold bootstrap and normal C ABI deliveries using generated, private v10 catalogs."""

import argparse
import errno
import json
import os
from pathlib import Path
import platform
import select
import shutil
import socket
import subprocess as sp
import sys
import tempfile
import uuid
from broker import Grant, NAMES, pin, fd_id

HERE = Path(__file__).resolve().parent
REPO = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
PREV = (
    REPO / "experiments/portable-processing/catalog/transaction-filestat-probe/mapping"
)
sys.path.insert(0, str(PREV))
from fixtures import cases, digest  # noqa: E402


def line(p):
    if not select.select([p.stdout], [], [], 8)[0]:
        raise TimeoutError("keeper output")
    answer = p.stdout.readline()
    if not answer:
        raise RuntimeError(p.stderr.read())
    return json.loads(answer)


def command(p, msg):
    p.stdin.write(msg + "\n")
    p.stdin.flush()
    return line(p)


def close(p):
    p.stdin.write("finish\n")
    p.stdin.flush()
    assert p.wait(timeout=6) == 0


class Catalog:
    def __init__(self, directory, bins):
        directory.mkdir(mode=0o700)
        self.path = directory
        self.db = directory / NAMES[1]
        self.destination = directory / "delivery"
        self.destination.mkdir(mode=0o700)
        self.bins = bins
        self.batch = str(uuid.uuid4())
        self.outputs = []
        self.started = []
        self.denials = []
        natural = sp.Popen(
            [bins / "filestat-keeper", self.db, cases.helper.DDL],
            stdin=sp.PIPE,
            stdout=sp.PIPE,
            stderr=sp.PIPE,
            text=True,
        )
        initial = line(natural)
        assert initial["version"] == 10
        self.sourceid = initial["sourceID"]
        assert (
            self.sourceid
            == "2026-06-03 19:12:13 d6e03d8c777cfa2d35e3b60d8ec3e0187f3e9f99d8e2ee9cac695fd6fcdf1a24"
        )
        # These handles and the library trust record exist before SQLite's genuine final-close cleanup.
        self.owner = Grant(
            directory,
            pin(directory),
            pin(self.db),
            initial["library"],
            "controlled-fixture-writer",
        )
        assert (directory / NAMES[2]).exists() and (directory / NAMES[3]).exists()
        assert command(natural, "truncate")["checkpointRC"] == 0
        close(natural)
        assert all(not (directory / n).exists() for n in (NAMES[2], NAMES[3]))
        self.k = None

    def boot(self, success=True):
        ch = self.owner.attach("keeper", [self.bins / "owner-keeper", self.db])
        try:
            record = line(ch.proc)
            if not success and self.owner.writer == "wrong-expected-writer":
                try:
                    self.owner.activate(ch, record)
                except OSError:
                    pass
                else:
                    raise AssertionError("foreign writer activated")
                assert self.owner.phase == "pending"
                command(ch.proc, "release")
                close(ch.proc)
                ch.join()
                return {
                    "ownerRefusedDurableWriterMismatch": True,
                    "attestation": self.owner.last_attest,
                }
            assert success, record
            self.owner.activate(ch, record)
            assert command(ch.proc, "release") == {"released": True}
            self.k = ch
            self.started.append(
                {
                    "transaction": {
                        k: v
                        for k, v in record.items()
                        if k not in ("library", "writer")
                    },
                    "actualOfd": self.owner.last_attest,
                }
            )
            return record
        except RuntimeError as e:
            ch.proc.wait(timeout=6)
            ch.join()
            assert not success and ch.proc.returncode != 0, (e, ch.denials)
            self.denials.extend(ch.denials)
            return {"denials": ch.denials, "workerFailed": True}

    def shutdown(self):
        if self.k:
            assert command(self.k.proc, "checkpoint") == {"checkpointRC": 0}
            self.owner.checkpoint = True
            close(self.k.proc)
            self.k.join()
            self.k = None

    def req(self, action, params, expected=True, paired=False, rename=False):
        grants = [self.owner.directory, *[self.owner.holds[i] for i in (1, 2, 3)]]
        cmd = {
            "action": action,
            **({} if action == "register" else {"batchID": self.batch}),
            **params,
        }
        wire = {
            "operation": "scheduler",
            "request": {"op": "workbenchBatch", "command": cmd},
        }
        env = {
            "RM_PRIVATE_FIXTURE_GRANTS": ",".join(map(str, grants)),
            "RM_MAP_ARM": "address",
            "RM_MAP_PAIR_ACK": str(int(paired)),
            "RM_PRIVATE_NO_HARDLINK": str(int(rename)),
        }
        ch = self.owner.attach(
            "queue",
            [
                sys.executable,
                HERE / "child.py",
                self.bins / "librawmaster_library.so",
                self.db,
            ],
            extras=grants,
            env=env,
        )
        stdout, stderr = ch.proc.communicate(json.dumps(wire), timeout=8)
        ch.join()
        assert ch.proc.returncode == 0, stderr
        replies = [json.loads(s) for s in stdout.splitlines()]
        guards = [json.loads(s) for s in stderr.splitlines()]
        assert len(replies) == (2 if paired else 1) and all(
            (r["status"] == 0) == expected for r in replies
        ), (action, replies, guards, ch.denials)
        if paired:
            assert replies[0] == replies[1]
        self.outputs.append(
            {
                "action": action,
                "statuses": [r["status"] for r in replies],
                "fencePhases": [
                    (e["phase"], e["state"], e["walBytes"]) for e in guards
                ],
                "ownerChecks": ch.seals,
                "denials": ch.denials,
            }
        )
        return replies[-1]["reply"]

    def prepare(self):
        parent = self.req(
            "register",
            {
                "manifest": cases.helper.source(
                    self.owner.library, self.destination, self.batch
                ),
                "directory": str(self.destination),
                "leaseMs": 120000,
            },
        )
        self.lease = {"token": parent["token"], "generation": 1, "ordinal": 1}
        self.lease["itemToken"] = self.req(
            "claimItem", {**self.lease, "leaseMs": 120000}
        )["itemToken"]
        folder = self.destination / (".rawmaster-export-" + str(uuid.uuid4()))
        folder.mkdir()
        self.stage = folder / "pixels.jpg"
        shutil.copyfile(cases.helper.IMAGE, self.stage)
        self.sha = digest(self.stage)
        self.initial_inode = self.stage.stat().st_ino
        prepared = self.req(
            "prepareItem",
            {
                **self.lease,
                "directory": str(self.destination),
                "stage": str(self.stage.relative_to(self.destination)),
                "suffix": 1,
            },
        )
        self.final = self.destination / prepared["item"]["filename"]
        self.ticket = command(self.k.proc, "ticket")
        assert (
            self.ticket["state"] == "prepared"
            and self.ticket["reservations"] == 1
            and not self.final.exists()
        )

    def pending(self):
        assert (
            self.stage.stat().st_ino == self.initial_inode
            and digest(self.stage) == self.sha
            and not self.final.exists()
        )
        if self.k:
            assert command(self.k.proc, "ticket") == self.ticket

    def deliver(self, rename=False):
        assert command(self.k.proc, "checkpoint") == {"checkpointRC": 0}
        assert (self.path / NAMES[2]).stat().st_size == 0
        assert (
            self.req(
                "publishItem",
                {**self.lease, "directory": str(self.destination)},
                rename=rename,
            )["status"]
            == "published"
        )
        assert command(self.k.proc, "ticket") == self.ticket
        assert (
            self.req(
                "acknowledgeItem",
                {"ordinal": 1, "directory": str(self.destination)},
                paired=True,
            )["status"]
            == "delivered"
        )
        ticket = command(self.k.proc, "ticket")
        assert (
            ticket["state"] == "delivered"
            and ticket["ticket"] == self.ticket["ticket"]
            and ticket["reservations"] == 0
        )
        assert (
            self.final.stat().st_ino == self.initial_inode
            and digest(self.final) == self.sha
            and not self.stage.exists()
        )
        assert command(self.k.proc, "integrity") == {
            "quickCheck": "ok",
            "foreignKeyViolations": 0,
        }
        return {
            "bytes": self.final.stat().st_size,
            "sha256": self.sha,
            "unchangedPreparedIdentity": True,
            "duplicateACK": True,
            "reservationsAfterACK": 0,
            "quickCheck": "ok",
            "foreignKeyViolations": 0,
        }


def case(root, bins, name):
    c = Catalog(root / name, bins)
    o = c.owner
    extra = {}
    try:
        if name == "private-protocol-order":
            ch = o.attach("keeper", [sys.executable, HERE / "protocol-check.py"])
            body, diagnostic = ch.proc.communicate(timeout=5)
            ch.join()
            assert ch.proc.returncode == 0, diagnostic
            assert len(json.loads(body)) == 4 and set(o.holds) == {1} and not o.events
            extra["badNonceRoleOrderAndExcessOrMissingRightsRefusedWithoutFileOpen"] = (
                True
            )
            rollback = c.path / (NAMES[1] + "-journal")
            rollback.touch()
            assert (
                c.boot(False)["denials"]
                and rollback.read_bytes() == b""
                and set(o.holds) == {1}
            )
            rollback.unlink()
            extra["unknownRollbackJournalWasLeftForExplicitMaintenance"] = True
        if name in ("preexisting-empty-WAL", "preexisting-empty-SHM"):
            role = 2 if name.endswith("WAL") else 3
            sentinel = c.path / NAMES[role]
            sentinel.touch()
            original = sentinel.stat().st_ino
            r = c.boot(False)
            assert r["denials"] and not any(e.get("createdExclusive") for e in o.events)
            assert (
                sentinel.stat().st_ino == original
                and sentinel.read_bytes() == b""
                and set(o.holds) == {1}
                and o.phase == "pending"
            )
            sentinel.unlink()
            extra["foreignEmptyPreservedAndExplicitlyRemovedByFixture"] = True
        if name in (
            "between-exclusive",
            "partial-owner-retry",
            "real-channel-loss-after-WAL",
        ):
            role = 3
            o.fault = {
                "between-exclusive": "between",
                "partial-owner-retry": "stopAfterWAL",
                "real-channel-loss-after-WAL": "disconnectAfterWAL",
            }[name]
            r = c.boot(False)
            assert r["denials"] and set(o.holds) == {1, 2} and o.phase == "pending"
            first = fd_id(o.holds[2])
            extra["pendingWALInode"] = first[1]
            if o.fault in ("stopAfterWAL", "disconnectAfterWAL"):
                o.fault = None
                assert not (c.path / NAMES[3]).exists()
            else:
                sentinel = c.path / NAMES[3]
                assert sentinel.read_bytes() == b""
                sentinel.unlink()
            c.boot()
            assert fd_id(o.holds[2]) == first
            extra["reusedOnlyOwnContinuallyHeldWAL"] = True
        elif name == "different-durable-writer":
            valid = o.writer
            o.writer = "wrong-expected-writer"
            r = c.boot(False)
            assert r["ownerRefusedDurableWriterMismatch"] and o.phase == "pending"
            o.writer = valid
            c.boot()
            extra.update(r)
        else:
            c.boot()
        if name == "ofd-smoke":
            assert c.started[0]["transaction"]["walBytes"] == 0
            return {
                "case": name,
                "genuineLastCloseAbsent": True,
                "attestations": c.started,
                "events": o.events,
            }
        c.prepare()
        if name == "graceful-recreation":
            c.pending()
            try:
                o.retire()
            except OSError as e:
                assert e.errno == errno.EBUSY
            else:
                raise AssertionError("live keeper allowed retirement")
            old = [os.dup(o.holds[i]) for i in (2, 3)]
            try:
                c.shutdown()
                o.retire()
                assert all(not (c.path / NAMES[i]).exists() for i in (2, 3))
                c.boot()
                new = [fd_id(o.holds[i]) for i in (2, 3)]
                assert all(fd_id(f) != n for f, n in zip(old, new))
                c.pending()
            finally:
                for fd in old:
                    os.close(fd)
            extra.update(
                {
                    "sameLiveSupervisor": True,
                    "oldConnectionsPreventedRetirement": True,
                    "preparedTicketPreservedAcrossNewEpoch": True,
                    "bothNewInodes": True,
                }
            )
        if name == "socket-EOF-while-keeper-alive":
            assert command(c.k.proc, "checkpoint") == {"checkpointRC": 0}
            o.checkpoint = True
            c.k.parent.shutdown(socket.SHUT_RDWR)
            c.k.thread.join(4)
            assert not o.live and c.k in o.children and c.k.proc.poll() is None
            assert not select.select([c.k.pidfd], [], [], 0)[0]
            ids = [fd_id(o.holds[i]) for i in (2, 3)]
            try:
                o.retire()
            except OSError as e:
                assert e.errno == errno.EBUSY
            else:
                raise AssertionError(
                    "retired after socket EOF while keeper process was alive"
                )
            assert ids == [fd_id(o.holds[i]) for i in (2, 3)]
            assert (
                o.phase == "suspended"
                and not c.final.exists()
                and digest(c.stage) == c.sha
            )
            close(c.k.proc)
            c.k.join()
            c.k = None
            o.retire()
            c.boot()
            c.pending()
            extra["socketEOFWithLivePidfdBlockedRetirementUntilExactChildExited"] = True
        if name == "foreign-entry-during-unwind":
            assert command(c.k.proc, "checkpoint") == {"checkpointRC": 0}
            o.checkpoint = True
            real = c.path / NAMES[3]
            saved = c.path / "original-owned-shm"
            real.rename(saved)
            real.touch()
            inode = real.stat().st_ino
            wal = (c.path / NAMES[2]).stat().st_ino
            close(c.k.proc)
            c.k.join()
            c.k = None
            assert (
                real.stat().st_ino == inode
                and real.read_bytes() == b""
                and (c.path / NAMES[2]).stat().st_ino == wal
            )
            try:
                o.retire()
            except OSError as e:
                assert e.errno == errno.ESTALE
            else:
                raise AssertionError("removed a role while namespace mismatched")
            assert (
                real.stat().st_ino == inode and (c.path / NAMES[2]).stat().st_ino == wal
            )
            real.unlink()
            saved.rename(real)
            o.retire()
            c.boot()
            c.pending()
            extra["foreignEntryPreservedDuringNativeLastCloseAndOwnerRetirement"] = True
        if name == "live-name-mismatch":
            # A synthetic save operation moves the SHM pathname while an old genuine mapping remains live.
            real = c.path / NAMES[3]
            saved = c.path / "owned-shm.saved"
            real.rename(saved)
            real.touch()
            foreign = real.stat().st_ino
            try:
                c.req(
                    "publishItem", {**c.lease, "directory": str(c.destination)}, False
                )
                assert (
                    not c.final.exists()
                    and digest(c.stage) == c.sha
                    and real.stat().st_ino == foreign
                    and real.read_bytes() == b""
                )
            finally:
                real.unlink()
                saved.rename(real)
            c.pending()
            extra["oldMappedKeeperAndForeignNamePreserved"] = True
        if name == "revoke-before-effect":
            o.fault = "revokeBeforePublish"
            c.req("publishItem", {**c.lease, "directory": str(c.destination)}, False)
            c.pending()
            assert o.phase == "suspended"
            o.fault = None
            c.shutdown()
            o.retire()
            c.boot()
            c.pending()
            extra["revokedBeforeExclusivePublicationThenRetriedFromOriginalTicket"] = (
                True
            )
        extra["delivery"] = c.deliver(rename=name == "ordinary-rename")
        return {
            "case": name,
            "genuineLastCloseAbsent": True,
            "attestations": c.started,
            "commands": c.outputs,
            "bootstrapDenials": c.denials,
            "events": o.events,
            **extra,
        }
    finally:
        c.shutdown()
        o.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-dir", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()
    bins = args.build_dir.resolve() / "target/debug"
    names = (
        ["ofd-smoke"]
        if args.smoke
        else [
            "ordinary-link",
            "ordinary-rename",
            "preexisting-empty-WAL",
            "preexisting-empty-SHM",
            "between-exclusive",
            "partial-owner-retry",
            "different-durable-writer",
            "graceful-recreation",
            "live-name-mismatch",
            "revoke-before-effect",
            "foreign-entry-during-unwind",
            "real-channel-loss-after-WAL",
            "private-protocol-order",
            "socket-EOF-while-keeper-alive",
        ]
    )
    out = {
        "platform": platform.platform(),
        "runtimeSHA256": digest(bins / "librawmaster_library.so"),
        "keeperSHA256": digest(bins / "owner-keeper"),
        "cases": [],
    }
    out["sqliteSourceID"] = (
        "2026-06-03 19:12:13 d6e03d8c777cfa2d35e3b60d8ec3e0187f3e9f99d8e2ee9cac695fd6fcdf1a24"
    )
    with tempfile.TemporaryDirectory(
        prefix="rm-private-owner-", dir="/tmp"
    ) as temporary:
        for n in names:
            out["cases"].append(case(Path(temporary), bins, n))
            print("passed", n, flush=True)
            args.output.write_text(json.dumps(out, indent=2) + "\n")
        if not args.smoke:
            from owner_loss import study

            out["cases"].append(study(Path(temporary), bins))
            print("passed owner-exit-unwitnessed-restart", flush=True)
            args.output.write_text(json.dumps(out, indent=2) + "\n")


if __name__ == "__main__":
    main()
