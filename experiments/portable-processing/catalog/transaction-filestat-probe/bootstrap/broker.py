"""Linux-only, private test service. Every directory is freshly generated under /tmp."""

import array
import errno
import fcntl
import os
from pathlib import Path
import secrets
import select
import socket
import stat
import struct
import subprocess
import threading

REQ = struct.Struct("=Qiiii")
RESP = struct.Struct("=i")
PAIR_QUERY = 1027  # F_DUPFD_QUERY, Linux 6.10+.
NAMES = {1: "library.sqlite", 2: "library.sqlite-wal", 3: "library.sqlite-shm"}
FLOCK = struct.Struct(
    "=hh4xqqi4x"
)  # Linux arm64 native struct flock in the pinned container.


def own_lock(fd, offset, expected_type, pid):
    question = FLOCK.pack(fcntl.F_WRLCK, os.SEEK_SET, offset, 1, 0)
    kind, whence, start, length, holder = FLOCK.unpack(
        fcntl.fcntl(fd, fcntl.F_GETLK, question)
    )
    require(
        kind == expected_type
        and holder == pid
        and whence == os.SEEK_SET
        and start <= offset
        and (not length or offset < start + length)
    )
    return {
        "offset": offset,
        "type": "write" if kind == fcntl.F_WRLCK else "read",
        "keeperPIDMatched": True,
    }


def identity(s):
    return (s.st_dev, s.st_ino)


def fd_id(fd):
    return identity(os.fstat(fd))


def require(ok, code=errno.ESTALE):
    if not ok:
        raise OSError(code, os.strerror(code))


def rights(anc):
    result = []
    for level, kind, data in anc:
        require(level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS, errno.EPROTO)
        f = array.array("i")
        f.frombytes(data)
        result.extend(f)
    return result


def response(s, err, data=None):
    anc = (
        []
        if data is None
        else [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [data]))]
    )
    require(s.sendmsg([RESP.pack(err)], anc) == RESP.size, errno.EPIPE)


def pin(path):
    return os.open(path, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC)


class Grant:
    """A directory/main O_PATH acquired from the creating fixture before natural last-close."""

    def __init__(self, directory, dir_fd, main_fd, library, writer):
        self.path = Path(directory)
        self.directory = dir_fd
        self.holds = {1: main_fd}
        self.library = library
        self.writer = writer
        self.epoch = 1
        self.phase = "pending"
        self.live = set()
        self.children = set()
        self.lock = threading.RLock()
        self.fault = None
        self.events = []
        self.keep = None
        self.checkpoint = False
        self.last_attest = None

    def close(self):
        require(not self.live and not self.children, errno.EBUSY)
        for fd in self.holds.values():
            os.close(fd)
        os.close(self.directory)

    def inspect(self):
        d = self.path.stat(follow_symlinks=False)
        require(
            identity(d) == fd_id(self.directory)
            and stat.S_ISDIR(d.st_mode)
            and d.st_uid == os.geteuid()
            and d.st_mode & 0o077 == 0
        )
        for role, witness in self.holds.items():
            n = os.stat(NAMES[role], dir_fd=self.directory, follow_symlinks=False)
            require(stat.S_ISREG(n.st_mode) and identity(n) == fd_id(witness))

    def empty_for_cold(self):
        self.inspect()
        unknown = [NAMES[1] + "-journal"]
        unknown.extend(NAMES[role] for role in (2, 3) if role not in self.holds)
        for name in unknown:
            try:
                os.stat(name, dir_fd=self.directory, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise OSError(errno.EEXIST, "unowned attachment")

    def sync_directory(self):
        d = os.open(
            ".", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC, dir_fd=self.directory
        )
        try:
            os.fsync(d)
        finally:
            os.close(d)

    def open_role(self, s, role, flags, mode):
        require(
            s.epoch == self.epoch
            and (
                self.phase == "active"
                or (self.phase == "pending" and s.kind == "keeper")
            ),
            errno.EPERM,
        )
        require(role == 1 or 1 in s.sent, errno.EPROTO)
        require(role != 3 or 2 in s.sent, errno.EPROTO)
        self.inspect()
        mode_flags = flags & os.O_ACCMODE
        require(
            mode_flags in (os.O_RDWR, os.O_RDONLY)
            and flags & os.O_NOFOLLOW
            and not (flags & os.O_TRUNC),
            errno.EINVAL,
        )
        if role == 1:
            require(not flags & os.O_CREAT)
            if self.phase == "pending":
                self.empty_for_cold()
        if self.fault == "between" and role == 3:
            self.fault = None
            fd = os.open(
                NAMES[role],
                os.O_RDWR | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=self.directory,
            )
            os.close(fd)
            self.events.append({"fixtureCreatedEmptyEntryBeforeExclusiveCreate": True})
        if self.fault == "stopAfterWAL" and role == 3:
            raise OSError(errno.EIO, "injected SHM open failure")
        if role in (2, 3):
            require(mode == os.fstat(self.holds[1]).st_mode & 0o777, errno.EACCES)
        if role not in self.holds:
            require(
                s.kind == "keeper"
                and self.phase == "pending"
                and flags & os.O_CREAT
                and mode_flags == os.O_RDWR,
                errno.EPERM,
            )
            data = os.open(
                NAMES[role],
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                mode & 0o777,
                dir_fd=self.directory,
            )
            try:
                self.holds[role] = os.open(
                    "/proc/self/fd/" + str(data), os.O_PATH | os.O_CLOEXEC
                )
                require(fd_id(self.holds[role]) == fd_id(data))
                os.fchmod(data, mode & 0o777)
                os.fsync(data)
                self.sync_directory()
                self.inspect()
            except BaseException:
                os.close(data)
                raise
            creating = True
        else:
            data = os.open(
                "/proc/self/fd/" + str(self.holds[role]), mode_flags | os.O_CLOEXEC
            )
            try:
                require(fd_id(data) == fd_id(self.holds[role]))
            except BaseException:
                os.close(data)
                raise
            creating = False
        if role in s.sent:
            os.close(s.sent[role])
        s.sent[role] = data
        self.events.append(
            {
                "epoch": self.epoch,
                "role": NAMES[role],
                "createdExclusive": creating,
                "handler": s.kind,
                "inode": fd_id(data)[1],
            }
        )
        return data

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
        for role, actual in enumerate(fds, 1):
            require(
                fd_id(actual) == fd_id(self.holds[role])
                and fcntl.fcntl(s.sent[role], PAIR_QUERY, actual) == 1
            )
        # A self-value must be true. Independent opens of the same inode must be false.
        independent = os.open(
            "/proc/self/fd/" + str(self.holds[1]), os.O_RDONLY | os.O_CLOEXEC
        )
        try:
            require(fcntl.fcntl(s.sent[1], PAIR_QUERY, independent) == 0)
        finally:
            os.close(independent)
        locks = [
            own_lock(fds[0], 1073741826, fcntl.F_RDLCK, s.proc.pid),
            own_lock(fds[2], 120, fcntl.F_WRLCK, s.proc.pid),
            own_lock(fds[2], 123, fcntl.F_RDLCK, s.proc.pid),
        ]
        s.verified = True
        self.last_attest = {
            "sameOpenFileDescriptions": [True] * 3,
            "separateOpenSameInodeWasDifferent": True,
            "inodes": [fd_id(x)[1] for x in fds],
            "epoch": self.epoch,
            "kernelPOSIXLocks": locks,
        }

    def activate(self, s, record):
        with self.lock:
            self.inspect()
            require(s.verified and s.epoch == self.epoch and self.phase == "pending")
            require(
                record["library"] == self.library
                and record["writer"] == self.writer
                and record["version"] == 10
                and record["txnState"] == 2
                and record["readMask"] & 0xF8
                and record["exclusiveMask"] & 1
                and record["journalMode"] == "wal"
                and record["observedSharedMappingBytes"] == 32768
            )
            self.phase = "active"
            self.keep = s

    def permit(self, s):
        require(
            self.phase == "active"
            and self.keep in self.live
            and s.epoch == self.epoch
            and s.kind == "queue"
            and set(s.sent) == {1, 2, 3},
            errno.EPERM,
        )
        self.inspect()
        if self.fault == "revokeBeforePublish" and s.seals == 2:
            self.phase = "suspended"
            raise OSError(errno.ECANCELED, "simulated epoch retirement")
        s.seals += 1

    def retire(self):
        # Administrative retirement runs only after the service's single-writer namespace quiesces.
        with self.lock:
            require(
                not self.live
                and not self.children
                and self.checkpoint
                and os.fstat(self.holds[2]).st_size == 0,
                errno.EBUSY,
            )
            self.inspect()
            for role in (2, 3):
                os.unlink(NAMES[role], dir_fd=self.directory)
            self.sync_directory()
            for role in (2, 3):
                os.close(self.holds.pop(role))
            self.phase = "pending"
            self.keep = None
            self.last_attest = None
            self.checkpoint = False
            self.epoch += 1

    def attach(self, kind, args, extras=(), env=None):
        with self.lock:
            return Channel(self, kind, args, extras, env or {})


class Channel:
    def __init__(self, owner, kind, args, extras, env):
        self.owner = owner
        self.kind = kind
        self.epoch = owner.epoch
        self.nonce = secrets.randbits(64) or 1
        self.sent = {}
        self.verified = False
        self.seals = 0
        self.denials = []
        self.parent, self.child = socket.socketpair(
            socket.AF_UNIX, socket.SOCK_SEQPACKET
        )
        ce = dict(
            os.environ,
            **env,
            RM_OWNER_FD=str(self.child.fileno()),
            RM_OWNER_NONCE=str(self.nonce),
            RM_OWNER_PID=str(os.getpid()),
        )
        self.proc = subprocess.Popen(
            args,
            text=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=(*extras, self.child.fileno()),
            env=ce,
        )
        self.child.close()
        try:
            self.pidfd = os.pidfd_open(self.proc.pid)
        except OSError:
            self.parent.close()
            self.proc.kill()
            self.proc.wait(timeout=5)
            raise
        with owner.lock:
            owner.live.add(self)
            owner.children.add(self)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        try:
            while True:
                data, anc, flags, _ = self.parent.recvmsg(
                    REQ.size,
                    socket.CMSG_SPACE(3 * array.array("i").itemsize),
                    socket.MSG_CMSG_CLOEXEC,
                )
                if not data:
                    break
                fds = rights(anc)
                op = -1
                try:
                    require(
                        len(data) == REQ.size
                        and not (flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC)),
                        errno.EPROTO,
                    )
                    nonce, op, oflags, mode, reserved = REQ.unpack(data)
                    require(
                        nonce == self.nonce
                        and reserved == 0
                        and len(fds) == (3 if op == 4 else 0),
                        errno.EPROTO,
                    )
                    with self.owner.lock:
                        fd = None
                        if (
                            self.owner.fault == "disconnectAfterWAL"
                            and op == 3
                            and self.kind == "keeper"
                        ):
                            self.denials.append(
                                {"operation": op, "socketClosedAfterOnlyWAL": True}
                            )
                            self.parent.shutdown(socket.SHUT_RDWR)
                            return
                        if op in (1, 2, 3):
                            fd = self.owner.open_role(self, op, oflags, mode)
                        elif op == 4:
                            self.owner.attest(self, fds)
                        elif op == 5:
                            self.owner.permit(self)
                        else:
                            raise OSError(errno.EPROTO, "unknown operation")
                        response(self.parent, 0, fd)
                except OSError as e:
                    self.denials.append(
                        {
                            "operation": op if len(data) == REQ.size else -1,
                            "errno": e.errno,
                            "epoch": self.epoch,
                        }
                    )
                    response(self.parent, e.errno)
                finally:
                    for fd in fds:
                        os.close(fd)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.parent.close()
            with self.owner.lock:
                for fd in self.sent.values():
                    os.close(fd)
                self.owner.live.discard(self)
                if self.owner.keep == self:
                    self.owner.phase = "suspended"

    def join(self):
        self.thread.join(6)
        require(not self.thread.is_alive(), errno.ETIMEDOUT)
        with self.owner.lock:
            require(bool(select.select([self.pidfd], [], [], 0)[0]), errno.EBUSY)
            os.close(self.pidfd)
            self.owner.children.remove(self)
