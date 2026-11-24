"""Disposable APFS catalogs, separate SQLite implementations, and an independent lock observer."""

import argparse
import fcntl
import hashlib
import importlib.util
import json
import mmap
import os
from pathlib import Path
import platform
import select
import shutil
import socket
import subprocess as sp
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
ROOT = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
Q = ROOT / "experiments/portable-processing/catalog/queue-transaction-probe"
spec = importlib.util.spec_from_file_location("arch_fixture", Q / "run.py")
old = importlib.util.module_from_spec(spec)
spec.loader.exec_module(old)
RUNTIME = (
    ROOT
    / ".build/release/LibraryCatalog_RAWMasterLibrary.bundle/Contents/Resources/rawmaster-library.runtime"
)
NAMES = ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"]


def sha(path):
    d = hashlib.sha256()
    with Path(path).open("rb") as f:
        while b := f.read(1048576):
            d.update(b)
    return d.hexdigest()


def line(p):
    if not select.select([p.stdout], [], [], 8)[0]:
        raise TimeoutError("peer stopped replying")
    s = p.stdout.readline()
    if not s:
        raise RuntimeError(p.stderr.read())
    return json.loads(s)


def command(p, s):
    p.stdin.write(s + "\n")
    p.stdin.flush()
    return line(p)


def done(p):
    if p.poll() is None:
        p.stdin.write("finish\n")
        p.stdin.flush()
    assert p.wait(timeout=6) == 0, p.stderr.read()


def open_peer(args, env=None, fds=()):
    p = sp.Popen(
        args,
        stdin=sp.PIPE,
        stdout=sp.PIPE,
        stderr=sp.PIPE,
        text=True,
        env=env,
        pass_fds=fds,
    )
    return p, line(p)


def local_id(st):
    return [st.st_dev, st.st_ino]


def cleanup_process(p):
    if p is None or p.poll() is not None:
        return
    try:
        done(p)
    except Exception:
        p.kill()
        p.wait()


class Catalog:
    def __init__(self, path, bins, runtime):
        path.mkdir(mode=0o700)
        self.path = path.resolve()
        self.db = self.path / NAMES[0]
        self.out = self.path / "delivery"
        self.out.mkdir()
        self.bins = bins
        self.runtime = runtime
        self.private = bins / "target/debug/mac-private"
        self.keeper, self.origin = open_peer(
            [bins / "system-keeper", runtime, self.db, old.DDL]
        )
        assert self.origin["version"] == 10 and self.origin["abiIdentityMatches"]
        self.fds = [
            os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW),
            *[os.open(self.path / n, os.O_RDONLY | os.O_NOFOLLOW) for n in NAMES],
        ]
        self.env = dict(
            os.environ,
            RM_MAC_DIRECTORY=str(self.path),
            RM_MAC_GRANTS=",".join(map(str, self.fds)),
        )
        self.batch = str(uuid.uuid4())
        self.commands = []
        self.snapshots = []

    def close(self):
        cleanup_process(self.keeper)
        for fd in self.fds:
            os.close(fd)

    def locks(self):
        return json.loads(
            sp.check_output(
                [
                    self.bins / "system-peer",
                    "locks",
                    str(self.fds[1]),
                    str(self.fds[3]),
                ],
                text=True,
                pass_fds=[self.fds[1], self.fds[3]],
            )
        )

    def req(
        self,
        action,
        body,
        *,
        deny=False,
        swap=None,
        force_rename=False,
        wrong_grant=None,
    ):
        cmd = {
            "action": action,
            **({} if action == "register" else {"batchID": self.batch}),
            **body,
        }
        envelope = {
            "operation": "scheduler",
            "request": {"op": "workbenchBatch", "command": cmd},
        }
        env = self.env.copy()
        fds = list(self.fds)
        added = []
        gate = remote = None
        saved = None
        swapped = None
        nominal = None
        other = None
        substitution = None
        if force_rename:
            env["RM_MAC_NO_LINK"] = "1"
        if wrong_grant is not None:
            i = wrong_grant
            other = self.path / ("foreign-" + str(i))
            shutil.copyfile(self.path / NAMES[i], other)
            assert (
                sha(other) == sha(self.path / NAMES[i])
                and other.stat().st_ino != os.fstat(self.fds[i + 1]).st_ino
            )
            fd = os.open(other, os.O_RDONLY | os.O_NOFOLLOW)
            added.append(fd)
            fds[i + 1] = fd
            env["RM_MAC_GRANTS"] = ",".join(map(str, fds))
        if swap:
            gate, remote = socket.socketpair()
            gate.settimeout(6)
            env["RM_MAC_BARRIER"] = str(remote.fileno())
            env["RM_MAC_PAUSE_PHASE"] = swap[0]
            fds.append(remote.fileno())
        p = sp.Popen(
            [self.private, "queue", self.db],
            stdin=sp.PIPE,
            stdout=sp.PIPE,
            stderr=sp.PIPE,
            text=True,
            env=env,
            pass_fds=fds,
        )
        try:
            p.stdin.write(json.dumps(envelope))
            p.stdin.close()
            p.stdin = None
            if swap:
                remote.close()
                phase, i = swap
                assert gate.recv(1) == b"p", (
                    "private C ABI did not reach selected fence"
                )
                nominal = self.path / NAMES[i]
                saved = self.path / ("save-" + str(i))
                swapped = self.path / ("peer-" + str(i))
                shutil.copyfile(nominal, swapped)
                before = sha(nominal)
                assert before == sha(swapped)
                nominal.rename(saved)
                swapped.rename(nominal)
                swapped = None
                assert (
                    local_id(os.stat(saved)) == local_id(os.fstat(self.fds[i + 1]))
                    and nominal.stat().st_ino != saved.stat().st_ino
                )
                changed = local_id(os.stat(nominal))
                oldLocks = self.locks()
                assert has(oldLocks, 120, p.pid), oldLocks
                unowned = None
                if i in (0, 2):
                    fd = os.open(nominal, os.O_RDONLY | os.O_NOFOLLOW)
                    try:
                        file_pair = (fd, self.fds[3]) if i == 0 else (self.fds[1], fd)
                        peer_locks = json.loads(
                            sp.check_output(
                                [
                                    self.bins / "system-peer",
                                    "locks",
                                    *map(str, file_pair),
                                ],
                                pass_fds=file_pair,
                                text=True,
                            )
                        )
                        offset = 1073741826 if i == 0 else 120
                        unowned = entry(peer_locks, offset)
                        assert all(
                            unowned[k]["type"] == fcntl.F_UNLCK
                            for k in ("posix", "ofd")
                        ), unowned
                    finally:
                        os.close(fd)
                substitution = {
                    "bytes": nominal.stat().st_size,
                    "originalAndPeerSHA256": before,
                    "original": local_id(os.stat(saved)),
                    "sameBytesOther": changed,
                    "oldSHMWriterPID": p.pid,
                    "oldLockObserver": oldLocks,
                    "unlockedSubstitute": unowned,
                }
                try:
                    gate.sendall(b"g")
                    assert gate.recv(1) == b"q"
                    assert sha(nominal) == sha(saved) == before
                finally:
                    nominal.unlink()
                    saved.rename(nominal)
                    saved = None
                assert local_id(nominal.stat()) == local_id(os.fstat(self.fds[i + 1]))
                gate.sendall(b"g")
            stdout, error = p.communicate(timeout=8)
            assert p.returncode == 0, error
            response = json.loads(stdout)
            events = [json.loads(s) for s in error.splitlines() if s]
            assert (response["status"] != 0) == deny, (action, response, events)
            if deny:
                failed = [e for e in events if not e["allowed"]]
                assert len(failed) == 1, (response, events)
                fail = failed[0]
                if swap:
                    row = fail["rows"][swap[1]]
                    assert (
                        fail["phase"] == swap[0]
                        and row["actual"] == row["authorized"]
                        and row["directoryEntry"][:2] == changed
                        and not row["matches"]
                    )
                if wrong_grant is not None:
                    row = fail["rows"][wrong_grant]
                    assert (
                        row["actual"] == row["directoryEntry"]
                        and row["authorized"] != row["actual"]
                    )
            elif action in ("prepareItem", "publishItem", "acknowledgeItem"):
                assert events and all(e["allowed"] for e in events), events
            self.commands.append(
                {
                    "action": action,
                    "status": response["status"],
                    "phases": events,
                    "syntheticLinkEPERM": force_rename,
                    "currentNameTemporarilyChanged": swap,
                    "restoredBeforePrivateSQLiteUnwind": bool(swap),
                    "substitution": substitution,
                }
            )
            return response["answer"]
        finally:
            if saved is not None:
                if nominal.exists():
                    nominal.unlink()
                saved.rename(nominal)
            if swapped and swapped.exists():
                swapped.unlink()
            for sock in (gate, remote):
                if sock:
                    sock.close()
            for fd in added:
                os.close(fd)
            if other:
                other.unlink(missing_ok=True)
            if p.poll() is None:
                p.kill()
                p.wait()


def entry(lock, at):
    return next(v for v in lock["locks"] if v["offset"] == at)


def has(lock, at, pid, mode="write"):
    e = entry(lock, at)
    kind = fcntl.F_WRLCK if mode == "write" else fcntl.F_RDLCK
    return all(
        e[method]["type"] == kind and e[method]["pid"] == pid
        for method in ("posix", "ofd")
    )


def test_locks(path, bins, runtime):
    cat = Catalog(path, bins, runtime)
    a = b = t = None
    steps = []

    def act(p, cmd, want, marker=None):
        v = command(p, cmd)
        assert v["rc"] & 255 == want, (cmd, v)
        if marker is not None:
            assert v["marker"] == marker, (cmd, v)
        steps.append({"pid": p.pid, "command": cmd, **v})
        return v

    try:
        a, system = open_peer([bins / "system-peer", runtime, cat.db])
        assert (
            system["sqliteVersion"] == 3054000
            and system["sameSQLiteFunction"]
            and system["filestatPrepareRC"] != 0
        )
        act(a, "read", 0, 0)
        done(cat.keeper)
        cat.keeper = None
        first = cat.locks()
        assert has(first, 1073741826, a.pid, "read") and any(
            has(first, i, a.pid, "read") for i in range(123, 128)
        ), first
        b, private = open_peer([cat.private, "peer", cat.db], cat.env, cat.fds)
        assert (
            private["sqliteVersion"] == 3053002
            and private["sameSQLiteFunction"]
            and Path(private["image"]).name == "mac-private"
        )
        act(b, "write", 0, 0)
        live = command(b, "proof")
        assert live.get("allowed"), live
        mixed = cat.locks()
        assert has(mixed, 120, b.pid), mixed
        t, _ = open_peer([bins / "system-peer", runtime, cat.db])
        act(t, "write", 5)
        act(b, "bump", 0, 1)
        act(b, "commit", 0, 1)
        act(a, "marker", 0, 0)
        act(a, "rollback", 0, 1)
        act(t, "write", 0, 1)
        systemWriter = cat.locks()
        assert has(systemWriter, 120, t.pid)
        act(b, "write", 5)
        act(b, "read", 0, 1)
        privateRead = command(b, "proof")
        assert privateRead.get("allowed"), privateRead
        act(t, "bump", 0, 2)
        act(t, "commit", 0, 2)
        act(b, "marker", 0, 1)
        act(b, "rollback", 0, 2)
        act(b, "write", 0, 2)
        done(a)
        a = None
        done(t)
        t = None
        soloBefore = cat.locks()
        sole = command(b, "proof")
        soloAfter = cat.locks()

        def retained(lock):
            return (
                has(lock, 1073741826, b.pid, "read")
                and has(lock, 120, b.pid)
                and any(has(lock, i, b.pid, "read") for i in range(123, 128))
            )

        assert (
            retained(soloBefore)
            and retained(soloAfter)
            and all(row["matches"] for row in sole["rows"])
        )
        original = cat.path / NAMES[2]
        replica = cat.path / "mapping-replica"
        shutil.copyfile(original, replica)
        assert (
            sha(original) == sha(replica)
            and original.stat().st_ino != replica.stat().st_ino
        )

        def with_view(fd):
            with mmap.mmap(
                fd, 32768, flags=mmap.MAP_SHARED, prot=mmap.PROT_READ
            ) as view:
                assert len(view[0:1]) == len(view[32767:32768]) == 1
                return command(b, "proof")

        with replica.open("rb") as other:
            foreignMapped = with_view(other.fileno())
        independentlyMapped = with_view(cat.fds[3])
        afterMap = command(b, "proof")
        assert (
            independentlyMapped["allowed"]
            and afterMap["allowed"] == sole["allowed"]
            and retained(cat.locks())
            and foreignMapped["allowed"] == sole["allowed"]
            and all(
                x["rows"] == sole["rows"]
                for x in (foreignMapped, independentlyMapped, afterMap)
            )
        )
        a, _ = open_peer([bins / "system-peer", runtime, cat.db])
        act(a, "read", 0, 2)
        secondEngine = command(b, "proof")
        assert secondEngine["allowed"] and secondEngine["rows"] == sole["rows"]
        act(b, "rollback", 0, 2)
        return {
            "system": system,
            "private": private,
            "steps": steps,
            "appleReaderSole": first,
            "mixedPrivateWriter": mixed,
            "mixedSystemWriter": systemWriter,
            "singleMapper": sole,
            "mappedForeignPeer": foreignMapped,
            "readOnlyMappingSameSHM": independentlyMapped,
            "afterUnmap": afterMap,
            "secondSQLiteMapped": secondEngine,
            "privateSoleBeforeProof": soloBefore,
            "privateSoleAfterProof": soloAfter,
            "privateWriteProof": live,
            "privateReadProof": privateRead,
            "bidirectionalBusyAndRetry": True,
            "readSnapshotsSurvivedOtherEngineCommitBothDirections": True,
            "kernelLocksRetainedAcrossBorrowedFDProbe": True,
        }
    finally:
        for p in (t, b, a):
            cleanup_process(p)
        cat.close()


def delivery(path, bins, runtime, name):
    c = Catalog(path, bins, runtime)
    try:
        parent = c.req(
            "register",
            {
                "manifest": old.source(c.origin["library"], c.out, c.batch),
                "directory": str(c.out),
                "leaseMs": 120000,
            },
        )
        own = {"generation": 1, "ordinal": 1, "token": parent["token"]}
        own["itemToken"] = c.req("claimItem", {**own, "leaseMs": 120000})["itemToken"]
        folder = c.out / (".rawmaster-export-" + str(uuid.uuid4()))
        folder.mkdir()
        stage = folder / "pixels.jpg"
        shutil.copyfile(old.IMAGE, stage)
        before = stage.stat().st_ino
        original = sha(stage)
        prepare = {
            **own,
            "stage": str(stage.relative_to(c.out)),
            "suffix": 1,
            "directory": str(c.out),
        }
        rejectionResult = None
        if name == "denied-before-prepare":
            c.req("prepareItem", prepare, deny=True, swap=("prepare", 1))
            assert (
                not any(p.is_file() for p in c.out.iterdir()) and sha(stage) == original
            )
            pending = sp.check_output(
                [
                    "/usr/bin/sqlite3",
                    "-readonly",
                    c.db,
                    "SELECT json_extract(value,'$.state'),json_extract(value,'$.ticket') IS NULL,(SELECT count(*) FROM lc_workbench_names) FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'",
                ],
                text=True,
            ).strip()
            assert pending == "running|1|0", pending
            rejectionResult = (
                "running, no ticket, zero reservations, no final, original stage intact"
            )
        prepared = c.req("prepareItem", prepare)
        final = c.out / prepared["item"]["filename"]
        ticket = command(c.keeper, "ticket")
        assert ticket["state"] == "prepared" and ticket["reservations"] == 1
        assert (
            command(c.keeper, "truncate")["checkpointRC"] == 0
            and (c.path / NAMES[1]).stat().st_size == 0
        )
        publish = {**own, "directory": str(c.out)}
        ack = {"ordinal": 1, "directory": str(c.out)}
        faults = {
            "same-byte-main-name": ("link", 0),
            "same-byte-WAL-name": ("link", 1),
            "same-byte-SHM-name": ("link", 2),
            "rename-fence": ("rename", 1),
        }
        rename = name in ("rename-fence", "clean-rename")
        if name in faults or name == "wrong-empty-WAL-pin":
            c.req(
                "publishItem",
                publish,
                deny=True,
                swap=faults.get(name),
                wrong_grant=1 if name == "wrong-empty-WAL-pin" else None,
                force_rename=rename,
            )
            assert (
                not final.exists()
                and stage.stat().st_ino == before
                and sha(stage) == original
                and command(c.keeper, "ticket") == ticket
            )
            rejectionResult = (
                "same prepared ticket, one reservation, no final, original stage intact"
            )
        assert (
            c.req("publishItem", publish, force_rename=rename)["status"] == "published"
        )
        assert (
            final.stat().st_ino == before
            and sha(final) == original
            and command(c.keeper, "ticket") == ticket
        )
        if name == "after-publish-bad-ACK":
            c.req("acknowledgeItem", ack, deny=True, swap=("ack", 2))
            assert sha(final) == original and command(c.keeper, "ticket") == ticket
            rejectionResult = "same prepared ticket, one reservation, unchanged final"
        one = c.req("acknowledgeItem", ack)
        two = c.req("acknowledgeItem", ack)
        assert one == two and one["status"] == "delivered"
        end = command(c.keeper, "ticket")
        assert (
            end["ticket"] == ticket["ticket"]
            and end["state"] == "delivered"
            and end["reservations"] == 0
            and not stage.exists()
        )
        integrity = sp.check_output(
            [
                "/usr/bin/sqlite3",
                "-readonly",
                c.db,
                "SELECT quick_check FROM pragma_quick_check; SELECT count(*) FROM pragma_foreign_key_check; SELECT count(*) FROM lc_workbench_names;",
            ],
            text=True,
        ).splitlines()
        assert integrity == ["ok", "0", "0"], integrity
        return {
            "independentAppleIntegrity": integrity,
            "rejectionResult": rejectionResult,
            "case": name,
            "originalInodeUsed": True,
            "bytes": final.stat().st_size,
            "sha256": sha(final),
            "systemKeeperReadMatchingPreparedAndDelivered": True,
            "clearedReservation": True,
            "twoIdenticalACKs": True,
            "commands": c.commands,
        }
    finally:
        c.close()


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--build-dir", required=True, type=Path)
    a.add_argument("--output", required=True, type=Path)
    a.add_argument("--runtime", type=Path, default=RUNTIME)
    a.add_argument("--only-locks", action="store_true")
    cfg = a.parse_args()
    bins = cfg.build_dir.resolve()
    runtime = cfg.runtime.resolve()
    assert runtime.is_file()
    p = bins / "target/debug/mac-private"
    out = {
        "host": platform.platform(),
        "runtimeSHA256": sha(runtime),
        "privateExecutableSHA256": sha(p),
        "privateQueueDylibSHA256": sha(
            bins / "target/debug/librawmaster_library.dylib"
        ),
        "dependencies": {
            str(q.name): sp.check_output(["otool", "-L", q], text=True).splitlines()[1:]
            for q in (p, bins / "system-peer")
        },
        "deliveries": [],
    }
    with tempfile.TemporaryDirectory(prefix="generated-apfs-", dir=bins) as tmp:
        root = Path(tmp)
        out["locks"] = test_locks(root / "locks", bins, runtime)
        cfg.output.write_text(json.dumps(out, indent=2) + "\n")
        print("passed bidirectional locks", flush=True)
        if not cfg.only_locks:
            for name in [
                "clean-link",
                "clean-rename",
                "wrong-empty-WAL-pin",
                "same-byte-main-name",
                "same-byte-WAL-name",
                "same-byte-SHM-name",
                "rename-fence",
                "denied-before-prepare",
                "after-publish-bad-ACK",
            ]:
                out["deliveries"].append(delivery(root / name, bins, runtime, name))
                cfg.output.write_text(json.dumps(out, indent=2) + "\n")
                print("passed", name, flush=True)


if __name__ == "__main__":
    main()
