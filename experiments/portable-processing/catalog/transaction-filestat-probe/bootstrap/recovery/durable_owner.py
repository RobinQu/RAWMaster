"""One owner per installed vault. Scoped Linux-only fixture, isolated workers and typed attestation."""

import array
import errno
import fcntl
import importlib.util
import os
from pathlib import Path
import secrets
import select
import socket
import stat
import struct
import subprocess
import sys
import threading
from ledger import (
    boot,
    fid,
    starttime,
    pidfd_pid,
    shafile,
    walk_wal,
    facts,
    validate_obligations,
)

HERE = Path(__file__).resolve().parent
REPO = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
V3 = (
    REPO
    / "experiments/portable-processing/catalog/transaction-filestat-probe/bootstrap"
)
sys.path.insert(0, str(V3))
from broker import (
    Grant,
    Channel,
    NAMES,
    PAIR_QUERY,
    FLOCK,
    own_lock,
    fd_id,
    require,
    pin,
)

_spec = importlib.util.spec_from_file_location("v3_catalog", V3 / "run.py")
v3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(v3)


def original_file(directory, role):
    f = os.open(NAMES[role], os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
    s = os.fstat(f)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.geteuid():
        os.close(f)
        raise ValueError("expected an original service-owned single-link regular file")
    return f


def read_fd(fd):
    return os.open(f"/proc/self/fd/{fd}", os.O_RDONLY | os.O_CLOEXEC)


def inspect_wal(fd, expected=None):
    data = read_fd(fd)
    try:
        return walk_wal(data, expected)
    finally:
        os.close(data)


def required_free(fd, offset):
    data = read_fd(fd)
    try:
        inquiry = FLOCK.pack(fcntl.F_WRLCK, os.SEEK_SET, offset, 1, 0)
        kind, *_ = FLOCK.unpack(fcntl.fcntl(data, fcntl.F_GETLK, inquiry))
        require(kind == fcntl.F_UNLCK, errno.EBUSY)
    finally:
        os.close(data)


class ParkedChannel(Channel):
    """No catalog descriptor is inherited. Authorize the observed child before sending any capabilities."""

    def __init__(self, owner, kind, args, extras, environment):
        self.owner = owner
        self.kind = kind
        self.epoch = owner.epoch
        self.nonce = secrets.randbits(64) or 1
        self.sent = {}
        self.verified = False
        self.seals = 0
        self.denials = []
        self.parent, request = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        gate, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        gate.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
        gate.settimeout(4)
        ce = dict(
            os.environ,
            **environment,
            RM_OWNER_NONCE=str(self.nonce),
            RM_OWNER_PID=str(os.getpid()),
        )
        ce.pop("RM_PRIVATE_FIXTURE_GRANTS", None)
        self.proc = subprocess.Popen(
            [sys.executable, HERE / "launch.py", str(child.fileno()), kind, *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=[child.fileno()],
            env=ce,
        )
        child.close()
        self.pidfd = None
        try:
            self.pidfd = os.pidfd_open(self.proc.pid)
            packet, anc, flags, _ = gate.recvmsg(16, socket.CMSG_SPACE(12))
            require(
                packet == b"ready"
                and not flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC)
                and len(anc) == 1,
                errno.EPROTO,
            )
            lev, typ, info = anc[0]
            pid, uid, gid = struct.unpack("=iii", info)
            require(
                lev == socket.SOL_SOCKET
                and typ == socket.SCM_CREDENTIALS
                and pid == self.proc.pid == pidfd_pid(self.pidfd)
                and uid == os.geteuid()
                and not select.select([self.pidfd], [], [], 0)[0],
                errno.EPROTO,
            )
            self.start = starttime(pid)
            owner.vault.append(
                {
                    "kind": "child",
                    "boot": boot(),
                    "pid": pid,
                    "start": self.start,
                    "nonce": str(self.nonce),
                }
            )
            # The owner's exclusive installation lock is never in this list.
            assert owner.vault.lock not in extras and (
                not extras if kind == "keeper" else len(extras) == 4
            )
            transfer = array.array("i", [request.fileno(), *extras])
            require(
                gate.sendmsg(
                    [str(self.nonce).encode()],
                    [(socket.SOL_SOCKET, socket.SCM_RIGHTS, transfer)],
                )
                > 0,
                errno.EPIPE,
            )
            owner.live.add(self)
            owner.children.add(self)
            self.thread = threading.Thread(target=self.serve, daemon=True)
            self.thread.start()
        except BaseException:
            self.proc.kill()
            self.proc.wait(timeout=5)
            self.parent.close()
            if self.pidfd is not None:
                os.close(self.pidfd)
            raise
        finally:
            request.close()
            gate.close()

    def join(self):
        super().join()
        with self.owner.lock:
            self.owner.vault.append({"kind": "exit", "nonce": str(self.nonce)})


class DurableGrant(Grant):
    def __init__(self, path, dirfd, main, library, writer, vault):
        super().__init__(path, dirfd, main, library, writer)
        self.vault = vault
        self.last_inventory = None
        self.restoring = False
        self.obligations = []

    @classmethod
    def enroll(cls, c, vault):
        g = cls(
            c.path,
            os.dup(c.owner.directory),
            os.dup(c.owner.holds[1]),
            c.owner.library,
            c.owner.writer,
            vault,
        )
        c.owner.close()
        assert os.fstat(g.holds[1]).st_nlink == 1 and not vault.records
        vault.append(
            {
                "kind": "origin",
                "boot": boot(),
                "directory": fid(g.directory),
                "main": fid(g.holds[1]),
                "baselineMainSHA256": shafile(f"/proc/self/fd/{g.holds[1]}"),
                "library": g.library,
                "writer": g.writer,
            }
        )
        return g

    @classmethod
    def recover(cls, path, vault):
        drained = vault.drain_prior()
        origin, roles, obligations = vault.history()
        if not obligations or "2" not in roles or "3" not in roles:
            raise ValueError("incomplete acknowledged origin")
        handles = []
        try:
            directory = pin(path)
            handles.append(directory)
            if (
                not stat.S_ISDIR(os.fstat(directory).st_mode)
                or fid(directory) != origin["directory"]
            ):
                raise ValueError("directory object differs")
            main = original_file(directory, 1)
            handles.append(main)
            if (
                fid(main) != origin["main"]
                or shafile(f"/proc/self/fd/{main}") != origin["baselineMainSHA256"]
            ):
                raise ValueError("main object or checkpoint generation differs")
            wal = original_file(directory, 2)
            handles.append(wal)
            if fid(wal) != roles["2"]:
                raise ValueError("WAL object differs")
            shm = None
            try:
                shm = original_file(directory, 3)
            except FileNotFoundError:
                pass
            if shm is not None:
                handles.append(shm)
                if fid(shm) != roles["3"]:
                    raise ValueError("existing SHM object differs")
            snapshot = inspect_wal(wal, [o["wal"] for o in obligations])
            required_free(main, 1073741826)
            if shm is not None:
                required_free(shm, 128)
            g = cls(path, directory, main, origin["library"], origin["writer"], vault)
            g.holds[2] = wal
            if shm is not None:
                g.holds[3] = shm
            g.restoring = True
            g.obligations = obligations
            g.startup = {
                "drainedPriorRecords": drained,
                "presentSHM": shm is not None,
                "wal": snapshot,
            }
            g.inspect()
            handles = []
            return g
        finally:
            for fd in handles:
                os.close(fd)

    def attach(self, kind, args, extras=(), env=None):
        with self.lock:
            return ParkedChannel(self, kind, args, extras, env or {})

    def open_role(self, s, role, flags, mode):
        before = role in self.holds
        result = super().open_role(s, role, flags, mode)
        if not before:
            # Persist the exact created role before the broker sends its real data fd.
            self.vault.append(
                {"kind": "role", "name": str(role), "fid": fid(self.holds[role])}
            )
        return result

    def attest(self, s, fds):
        require(
            s.kind == "keeper"
            and self.phase == "pending"
            and s.epoch == self.epoch
            and len(fds) == 3
            and len(s.sent) == 3,
            errno.EPROTO,
        )
        self.inspect()
        for role, f in enumerate(fds, 1):
            require(
                fd_id(f) == fd_id(self.holds[role])
                and fcntl.fcntl(s.sent[role], PAIR_QUERY, f) == 1
            )
        independent = read_fd(self.holds[1])
        try:
            require(fcntl.fcntl(s.sent[1], PAIR_QUERY, independent) == 0)
        finally:
            os.close(independent)
        slots = []
        locks = [
            own_lock(fds[0], 1073741826, fcntl.F_RDLCK, s.proc.pid),
            own_lock(fds[2], 120, fcntl.F_WRLCK, s.proc.pid),
        ]
        for slot in range(3, 8):
            q = FLOCK.pack(fcntl.F_WRLCK, os.SEEK_SET, 120 + slot, 1, 0)
            kind, _, _, _, pid = FLOCK.unpack(fcntl.fcntl(fds[2], fcntl.F_GETLK, q))
            if kind == fcntl.F_RDLCK and pid == s.proc.pid:
                slots.append(slot)
                locks.append(own_lock(fds[2], 120 + slot, fcntl.F_RDLCK, pid))
        require(bool(slots))
        s.verified = True
        self.last_attest = {
            "sameOFD": [True] * 3,
            "kernelLocks": locks,
            "nativeReadMask": sum(1 << p for p in slots),
        }

    def activate(self, s, record):
        require(self.last_attest["nativeReadMask"] == record["readMask"] & 0xF8)
        inventory = v3.command(s.proc, "facts")
        require(inventory["txnState"] == 2)
        current = facts(inventory)
        validate_obligations(self.obligations, current)
        self.last_inventory = current
        super().activate(s, record)

    def seal(self, c, label):
        raw = v3.command(c.k.proc, "facts")
        current = facts(raw)
        validate_obligations(self.obligations, current)
        if not current:
            raise ValueError("no physical receipt to confirm")
        snapshot = inspect_wal(self.holds[2], [r["wal"] for r in self.obligations])
        # The controlled worker is serialized, and the WAL generation has never checkpointed.
        if not snapshot["commits"]:
            raise ValueError("missing WAL commit")
        record = {
            "kind": "commit",
            "sequence": len(self.obligations) + 1,
            "label": label,
            "wal": snapshot["commits"][-1],
            "facts": current,
        }
        self.vault.append(record)
        self.obligations.append(record)
        return record
