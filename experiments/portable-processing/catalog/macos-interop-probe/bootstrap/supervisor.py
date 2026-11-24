"""Single writer and namespace owner inside a new, mode-0700 disposable APFS directory."""

import array
import errno
import fcntl
import importlib.util
import json
import mmap
import os
from pathlib import Path
import secrets
import select
import socket
import stat
import struct
import subprocess as sp
import time
import uuid

root = next(
    p
    for p in Path(__file__).resolve().parents
    if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
cross = root / "experiments/portable-processing/catalog/macos-interop-probe"
spec = importlib.util.spec_from_file_location(
    "cross_platform_fixture", cross / "run.py"
)
X = importlib.util.module_from_spec(spec)
spec.loader.exec_module(X)
Q = X.old
NAMES = X.NAMES
REQ = struct.Struct("=Qiiii")
RESP = struct.Struct("=i")


def ensure(test, err=errno.ESTALE):
    if not test:
        raise OSError(err, os.strerror(err))


def identity(st):
    return st.st_dev, st.st_ino


def pinned(fd):
    return identity(os.fstat(fd))


def owned(fd):
    return fd is not None and fd >= 0


def closeall(fds):
    for fd in fds:
        if owned(fd):
            os.close(fd)


def wait_exit(proc):
    if proc.poll() is None:
        proc.kill()
    proc.wait(timeout=6)


def rights(anc):
    fds = []
    try:
        for level, kind, buf in anc:
            ensure(
                level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS, errno.EPROTO
            )
            r = array.array("i")
            r.frombytes(buf)
            fds.extend(r)
        for fd in fds:
            os.set_inheritable(fd, False)
        return fds
    except BaseException:
        closeall(fds)
        raise


def answer(sock, rc, fd=None):
    vec = (
        []
        if fd is None
        else [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))]
    )
    ensure(sock.sendmsg([RESP.pack(rc)], vec) == RESP.size, errno.EPIPE)


def description(sender, returned, independent, challenge):
    """All descriptor users are paused. SEEK changes only OFD offset, never file size or data."""
    cur = lambda fd: os.lseek(fd, 0, os.SEEK_CUR)
    a, b, c = map(cur, (sender, returned, independent))
    size = os.fstat(sender).st_size
    ensure(a == b and challenge not in (a, b, c))
    try:
        os.lseek(sender, challenge, os.SEEK_SET)
        first = cur(returned)
        untouched = cur(independent)
        # Symmetric proof that neither duplicate is an independent open.
        os.lseek(returned, challenge + 17, os.SEEK_SET)
        second = cur(sender)
        ensure(first == challenge and second == challenge + 17 and untouched == c)
    finally:
        os.lseek(sender, a, os.SEEK_SET)
        os.lseek(returned, b, os.SEEK_SET)
        os.lseek(independent, c, os.SEEK_SET)
        ensure((cur(sender), cur(returned), cur(independent)) == (a, b, c))
        ensure(os.fstat(sender).st_size == size)
    return {
        "sameOFD": True,
        "independentSameInodeUnchanged": True,
        "offsetsAndSizeRestored": True,
    }


class Owner(X.Catalog):
    def __init__(self, path, bins, runtime, keeperbin):
        path.mkdir(mode=0o700)
        self.path = path.resolve()
        self.db = self.path / NAMES[0]
        self.out = self.path / "delivery"
        self.out.mkdir()
        self.bins = bins
        self.runtime = runtime
        self.private = bins / "target/debug/mac-private"
        self.keeperbin = keeperbin
        self.dirfd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        seed, self.origin = X.open_peer(
            [keeperbin.parent / "system-origin", runtime, self.db, Q.DDL]
        )
        try:
            self.holds = {1: os.open(self.db, os.O_RDONLY | os.O_NOFOLLOW)}
            self.writer = sp.check_output(
                [
                    "/usr/bin/sqlite3",
                    "-readonly",
                    self.db,
                    "SELECT value FROM metadata WHERE key='deviceID'",
                ],
                text=True,
            ).strip()
            self.initial_checkpoint = X.command(seed, "truncate")
            ensure(self.initial_checkpoint == {"checkpointRC": 0, "log": 0, "done": 0})
            seed.stdin.write("finish\n")
            seed.stdin.flush()
            self.origin_close = X.line(seed)
            ensure(
                seed.wait(timeout=5) == 0
                and self.origin_close["closeRC"]
                == self.origin_close["persistentAfter"]
                == 0
            )
        finally:
            X.cleanup_process(seed)
        ensure(
            len(self.writer) > 0
            and self.origin["version"] == 10
            and self.origin["abiIdentityMatches"]
        )
        ensure(all(not os.path.lexists(self.path / n) for n in NAMES[1:]))
        self.epoch = 1
        self.phase = "pending"
        self.keeper = None
        self.sock = None
        self.sent = {}
        self.view = None
        self.readers = []
        self.held_writer = False
        self.batch = str(uuid.uuid4())
        self.commands = []
        self.events = []
        self.reports = []
        self.activate_grants()

    def activate_grants(self):
        self.fds = [self.dirfd, *(self.holds[role] for role in sorted(self.holds))]
        self.env = dict(
            os.environ,
            RM_MAC_DIRECTORY=str(self.path),
            RM_MAC_GRANTS=",".join(map(str, self.fds)),
        )

    def validate(self):
        d = os.stat(self.path, follow_symlinks=False)
        ensure(
            identity(d) == pinned(self.dirfd)
            and stat.S_ISDIR(d.st_mode)
            and d.st_uid == os.geteuid()
            and d.st_mode & 0o077 == 0
        )
        for r, fd in self.holds.items():
            obj = os.stat(NAMES[r - 1], dir_fd=self.dirfd, follow_symlinks=False)
            ensure(stat.S_ISREG(obj.st_mode) and identity(obj) == pinned(fd))

    def initial(self):
        self.validate()
        for name in [
            *(NAMES[r - 1] for r in (2, 3) if r not in self.holds),
            NAMES[0] + "-journal",
        ]:
            try:
                os.stat(name, dir_fd=self.dirfd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise OSError(errno.EEXIST, "preexisting attachment")

    def role(self, r, flags, perm, fault):
        ensure(r == len(self.sent) + 1, errno.EPROTO)
        self.validate()
        access = flags & os.O_ACCMODE
        ensure(
            access == os.O_RDWR and flags & os.O_NOFOLLOW and not flags & os.O_TRUNC,
            errno.EACCES,
        )
        if r == 1:
            ensure(not flags & os.O_CREAT)
            self.initial()
        if r > 1:
            ensure(
                perm & 0o777 == os.fstat(self.holds[1]).st_mode & 0o777, errno.EACCES
            )
        if r == 3 and fault == "denySHM":
            raise OSError(errno.EIO, "independent injected denial before creating SHM")
        if r == 3 and fault == "entryAfterWAL":
            descriptor = os.open(
                NAMES[2], os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600, dir_fd=self.dirfd
            )
            os.close(descriptor)
        create = r not in self.holds
        req = access | os.O_NOFOLLOW | os.O_CLOEXEC
        if create:
            ensure(r in (2, 3) and flags & os.O_CREAT and self.phase == "pending")
            req |= os.O_CREAT | os.O_EXCL
        data = os.open(NAMES[r - 1], req, perm & 0o777, dir_fd=self.dirfd)
        try:
            if create:
                os.fchmod(data, perm & 0o777)
                self.holds[r] = os.dup(data)
                os.fsync(data)
                os.fsync(self.dirfd)
            ensure(pinned(data) == pinned(self.holds[r]))
            self.validate()
        except BaseException:
            os.close(data)
            raise
        self.sent[r] = data
        self.events.append(
            {
                "epoch": self.epoch,
                "role": NAMES[r - 1],
                "createdExclusively": create,
                "devInode": pinned(data),
                "initialBytes": os.fstat(data).st_size,
            }
        )
        return data

    def kernel(self, main, shm):
        raw = sp.check_output(
            [self.bins / "system-peer", "locks", str(main), str(shm)],
            pass_fds=(main, shm),
            text=True,
        )
        return json.loads(raw)

    def attest(self, received):
        ensure(len(received) == len(self.sent) == 3)
        self.validate()
        rows = []
        for r, actual in enumerate(received, 1):
            ensure(pinned(self.holds[r]) == pinned(actual) == pinned(self.sent[r]))
            third = os.open(
                NAMES[r - 1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.dirfd
            )
            try:
                ensure(pinned(third) == pinned(actual))
                rows.append(
                    description(
                        self.sent[r], actual, third, (secrets.randbits(31) + 1) * 32
                    )
                )
            finally:
                os.close(third)
        locks = self.kernel(received[0], received[2])
        pid = self.keeper.pid
        read_slots = [z for z in range(123, 128) if X.has(locks, z, pid, "read")]
        ensure(
            X.has(locks, 1073741826, pid, "read")
            and X.has(locks, 120, pid)
            and read_slots
        )
        ensure(os.fstat(received[2]).st_size >= 32768)
        self.view = mmap.mmap(
            self.holds[3], 32768, flags=mmap.MAP_SHARED, prot=mmap.PROT_READ
        )
        self.view[0], self.view[32767]
        return {
            "roles": rows,
            "mainSharedOffset": 1073741826,
            "shmWriteOffset": 120,
            "readSlots": read_slots,
            "posixAndOFDBothReportActualKeeper": True,
            "observationPID": locks["observerPID"],
            "keeperPID": pid,
        }

    def begin(self, fault=None):
        ensure(self.phase == "pending" and self.keeper is None)
        self.initial()
        nonce = secrets.randbits(63) + 1
        self.sock, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        env = dict(
            os.environ,
            RM_OWNER_FD=str(child.fileno()),
            RM_OWNER_NONCE=str(nonce),
            RM_OWNER_PID=str(os.getpid()),
            RM_DIR_FD=str(self.dirfd),
            RM_MAIN_FD=str(self.holds[1]),
            RM_DIRECTORY=str(self.path),
        )
        self.keeper = sp.Popen(
            [self.keeperbin, self.db],
            pass_fds=(child.fileno(), self.dirfd, self.holds[1]),
            env=env,
            stdin=sp.PIPE,
            stdout=sp.PIPE,
            stderr=sp.PIPE,
            text=True,
        )
        child.close()
        verified = None
        deadline = time.monotonic() + 7
        try:
            while time.monotonic() < deadline:
                ready = select.select(
                    [self.sock, self.keeper.stdout],
                    [],
                    [],
                    min(1.0, max(0, deadline - time.monotonic())),
                )[0]
                if self.sock in ready:
                    msg, anc, flags, _ = self.sock.recvmsg(
                        REQ.size, socket.CMSG_SPACE(3 * array.array("i").itemsize)
                    )
                    allfds = rights(anc)
                    try:
                        ensure(
                            len(msg) == REQ.size
                            and not flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC),
                            errno.EPROTO,
                        )
                        cap, r, fl, perm, res = REQ.unpack(msg)
                        ensure(
                            cap == nonce
                            and res == 0
                            and len(allfds) == (3 if r == 4 else 0),
                            errno.EPROTO,
                        )
                        if r in (1, 2, 3):
                            answer(self.sock, 0, self.role(r, fl, perm, fault))
                        elif r == 4:
                            ensure(verified is None)
                            verified = self.attest(allfds)
                            answer(self.sock, 0)
                        else:
                            raise OSError(errno.EPROTO, "unexpected keeper action")
                    except OSError as e:
                        self.events.append(
                            {"epoch": self.epoch, "deniedRole": r, "errno": e.errno}
                        )
                        answer(self.sock, e.errno)
                    finally:
                        closeall(allfds)
                if self.keeper.stdout in ready:
                    out = self.keeper.stdout.readline()
                    if not out:
                        err = self.keeper.stderr.read()[:300]
                        raise OSError(errno.EIO, "keeper failed: " + err)
                    detail = json.loads(out)
                    ensure(
                        verified
                        and detail["txn"] == 2
                        and detail["walBytes"] == 0
                        and detail["mappingBytes"] == 32768
                        and detail["shareMode"] in (4, 5, 7)
                    )
                    ensure(
                        detail["catalog"]
                        == {
                            "libraryID": self.origin["library"],
                            "writer": self.writer,
                            "schema": 10,
                            "journal": "wal",
                        }
                    )
                    self.validate()
                    after = self.kernel(self.holds[1], self.holds[3])
                    pid = self.keeper.pid
                    ensure(
                        X.has(after, 1073741826, pid, "read")
                        and X.has(after, 120, pid)
                        and any(
                            X.has(after, slot, pid, "read")
                            for slot in verified["readSlots"]
                        )
                    )
                    verified["allLocksRetainedAfterReturnedDuplicatesClosed"] = True
                    self.phase = "active"
                    self.held_writer = True
                    self.activate_grants()
                    self.reports.append(
                        {
                            "generation": self.epoch,
                            "sqlite": detail,
                            "independent": verified,
                        }
                    )
                    return self.reports[-1]
            raise TimeoutError("initial attachment verification timeout")
        except BaseException:
            wait_exit(self.keeper)
            self.keeper = None
            self.clear_channel()
            raise

    def release(self):
        ensure(self.phase == "active" and self.held_writer)
        ensure(X.command(self.keeper, "release") == {"released": True})
        self.held_writer = False

    def request(self, action, body, **kwargs):
        ensure(
            self.phase == "active"
            and not self.held_writer
            and self.keeper.poll() is None
        )
        self.validate()
        return super().req(action, body, **kwargs)

    def peer(self):
        ensure(self.phase == "active")
        p, identity = X.open_peer([self.bins / "system-peer", self.runtime, self.db])
        ensure(identity["sameSQLiteFunction"] and identity["sqliteVersion"] == 3054000)
        self.readers.append(p)
        return p

    def drop_peer(self, p):
        ensure(p in self.readers)
        X.done(p)
        ensure(p.poll() == 0)
        self.readers.remove(p)

    def ck(self):
        ensure(self.phase == "active" and not self.held_writer)
        return X.command(self.keeper, "checkpoint")

    def retire(self, expected_ticket):
        ensure(self.phase == "active" and not self.held_writer)
        ensure(not self.readers, errno.EBUSY)
        self.validate()
        c = self.ck()
        ensure(
            c == {"rc": 0, "busy": 0, "log": 0, "checkpointed": 0}
            and os.fstat(self.holds[2]).st_size == 0,
            errno.EBUSY,
        )
        ensure(X.command(self.keeper, "ticket") == expected_ticket)
        self.phase = "draining"
        X.done(self.keeper)
        ensure(self.keeper.poll() == 0)
        self.keeper = None
        self.clear_channel()
        self.validate()
        # This service alone controls the generated directory. Keep the detached FDs
        # alive for the stale-generation test; the next generation cannot reuse them.
        detached = [self.holds[r] for r in (2, 3)]
        for r in (2, 3):
            os.unlink(NAMES[r - 1], dir_fd=self.dirfd)
            self.holds.pop(r)
        os.fsync(self.dirfd)
        self.initial()
        self.epoch += 1
        self.phase = "pending"
        self.activate_grants()
        return c, detached

    def clear_channel(self):
        if self.view is not None:
            self.view.close()
            self.view = None
        closeall(self.sent.values())
        self.sent = {}
        if self.sock is not None:
            self.sock.close()
            self.sock = None

    def close(self):
        for p in self.readers:
            X.cleanup_process(p)
        if self.keeper is not None:
            X.cleanup_process(self.keeper)
        self.clear_channel()
        closeall(self.holds.values())
        os.close(self.dirfd)
