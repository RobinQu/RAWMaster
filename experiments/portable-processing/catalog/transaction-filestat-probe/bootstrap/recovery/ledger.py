"""Authenticated service-private grants and WAL commitments for one controlled boot/mount."""

import ctypes as c
import errno
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import select
import stat
import struct

AT_EMPTY_PATH = 0x1000
AT_HANDLE_FID = 0x200
AT_HANDLE_MNT_ID_UNIQUE = 1
SYSTEM = c.CDLL(None, use_errno=True)


class Handle(c.Structure):
    _fields_ = [("length", c.c_uint), ("kind", c.c_int), ("bytes", c.c_ubyte * 128)]


SYSTEM.name_to_handle_at.argtypes = [
    c.c_int,
    c.c_char_p,
    c.POINTER(Handle),
    c.c_void_p,
    c.c_int,
]


def fid(fd, flags=AT_EMPTY_PATH | AT_HANDLE_FID | AT_HANDLE_MNT_ID_UNIQUE, name=b""):
    h = Handle(128)
    m = c.c_uint64()
    if SYSTEM.name_to_handle_at(fd, name, c.byref(h), c.byref(m), flags) != 0:
        n = c.get_errno()
        raise OSError(n, os.strerror(n))
    if not 0 < h.length <= 128:
        raise ValueError("unsupported filesystem handle width")
    return {
        "uniqueMount": m.value,
        "type": h.kind,
        "handle": bytes(h.bytes[: h.length]).hex(),
    }


def boot():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def canon(value):
    return json.dumps(
        value, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def shafile(path):
    with Path(path).open("rb") as data:
        return hashlib.file_digest(data, "sha256").hexdigest()


def starttime(pid):
    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]


def pidfd_pid(fd):
    for line in Path(f"/proc/self/fdinfo/{fd}").read_text().splitlines():
        if line.startswith("Pid:"):
            return int(line.split()[1])
    raise ValueError("pidfd lacks PID")


def assert_dead(entry):
    if entry["boot"] != boot():
        raise ValueError("different Linux boot")
    try:
        pfd = os.pidfd_open(entry["pid"])
    except ProcessLookupError:
        return
    try:
        if select.select([pfd], [], [], 0)[0]:
            return
        try:
            current = starttime(entry["pid"])
        except FileNotFoundError:
            if select.select([pfd], [], [], 0)[0]:
                return
            raise
        if current == entry["start"] and not select.select([pfd], [], [], 0)[0]:
            raise OSError(errno.EBUSY, "recorded child is alive")
    finally:
        os.close(pfd)


class Vault:
    def __init__(self, path):
        self.path = Path(path)
        self.d = os.open(
            path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        )
        self.lock = None
        try:
            s = os.fstat(self.d)
            if s.st_uid != os.geteuid() or s.st_mode & 0o077:
                raise ValueError("untrusted vault directory")
            self.lock = self.file("owner.lock", os.O_RDWR)
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with os.fdopen(self.file("origin.key", os.O_RDONLY), "rb") as key:
                self.key = key.read()
            if len(self.key) != 32:
                raise ValueError("invalid service secret")
            self.records = []
            self.last = "0" * 64
            names = sorted(n for n in os.listdir(self.d) if n.startswith("record."))
            if len(names) > 4096:
                raise ValueError("fixture journal cap")
            for seq, name in enumerate(names, 1):
                if name != f"record.{seq:08d}":
                    raise ValueError("gap in service journal")
                with os.fdopen(self.file(name, os.O_RDONLY), "rb") as f:
                    raw = f.read(262145)
                if len(raw) > 262144:
                    raise ValueError("oversize service record")
                obj = json.loads(raw)
                payload = obj["payload"]
                if (
                    payload["seq"] != seq
                    or payload["prev"] != self.last
                    or not hmac.compare_digest(obj["mac"], self.sign(payload))
                ):
                    raise ValueError("invalid prior service record")
                self.last = obj["mac"]
                self.records.append(payload["body"])
        except BaseException:
            self.close()
            raise

    @staticmethod
    def provision(path):
        path.mkdir(mode=0o700)
        for n, content in [
            ("owner.lock", b""),
            ("origin.key", secrets.token_bytes(32)),
        ]:
            with os.fdopen(
                os.open(
                    path / n,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                ),
                "wb",
            ) as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno())
        for d in (path, path.parent):
            fd = os.open(d, os.O_DIRECTORY | os.O_RDONLY | os.O_CLOEXEC)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)

    def close(self):
        if self.lock is not None:
            os.close(self.lock)
            self.lock = None
        if self.d is not None:
            os.close(self.d)
            self.d = None

    def file(self, name, flags):
        fd = os.open(name, flags | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=self.d)
        s = os.fstat(fd)
        if (
            not stat.S_ISREG(s.st_mode)
            or s.st_uid != os.geteuid()
            or s.st_mode & 0o077
            or s.st_nlink != 1
        ):
            os.close(fd)
            raise ValueError("invalid private service file")
        return fd

    def sign(self, obj):
        return hmac.new(self.key, canon(obj), hashlib.sha256).hexdigest()

    def append(self, body):
        seq = len(self.records) + 1
        payload = {"seq": seq, "prev": self.last, "body": body}
        mac = self.sign(payload)
        raw = canon({"payload": payload, "mac": mac})
        if seq > 4096 or len(raw) > 262144:
            raise ValueError("fixture journal cap")
        tmp = ".pending-" + secrets.token_hex(12)
        fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=self.d,
        )
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            # The exclusive vault lock serializes the only authorized writer. Rename leaves exactly one inode link.
            dst = f"record.{seq:08d}"
            try:
                os.stat(dst, dir_fd=self.d, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise ValueError("service sequence reused")
            os.rename(tmp, dst, src_dir_fd=self.d, dst_dir_fd=self.d)
            os.fsync(self.d)
        except BaseException:
            try:
                os.unlink(tmp, dir_fd=self.d)
            except FileNotFoundError:
                pass
            raise
        self.records.append(body)
        self.last = mac

    def drain_prior(self):
        live = {}
        for r in self.records:
            if r["kind"] == "child":
                live[r["nonce"]] = r
            elif r["kind"] == "exit":
                live.pop(r["nonce"], None)
        for entry in live.values():
            assert_dead(entry)
        return len(live)

    def history(self):
        origins = [r for r in self.records if r["kind"] == "origin"]
        if len(origins) != 1 or origins[0]["boot"] != boot():
            raise ValueError("unknown catalog or machine boot")
        roles = {}
        for r in self.records:
            if r["kind"] == "role":
                roles[r["name"]] = r["fid"]
        commits = [r for r in self.records if r["kind"] == "commit"]
        for seq, item in enumerate(commits, 1):
            if item["sequence"] != seq or (
                seq > 1
                and (
                    item["wal"]["salt"] != commits[seq - 2]["wal"]["salt"]
                    or item["wal"]["frame"] < commits[seq - 2]["wal"]["frame"]
                )
            ):
                raise ValueError("service commit progression differs")
        return origins[0], roles, commits


def checksum(buf, order, pair):
    a, b = pair
    for x, y in struct.iter_unpack(order + "II", buf):
        a = (a + x + b) & 0xFFFFFFFF
        b = (b + y + a) & 0xFFFFFFFF
    return a, b


def walk_wal(fd, require_prefix=None):
    """Stream real frames, verifying both SQLite checksums and cryptographic committed-byte prefixes."""
    size = os.fstat(fd).st_size
    if size > 32 * 1024 * 1024:
        raise ValueError("fixture WAL size cap")
    header = os.pread(fd, 32, 0)
    if len(header) != 32:
        raise ValueError("missing WAL header")
    magic, version, page, sequence, salt1, salt2, check1, check2 = struct.unpack(
        ">8I", header
    )
    if (
        magic not in (0x377F0682, 0x377F0683)
        or version != 3007000
        or not 512 <= page <= 65536
        or page & (page - 1)
    ):
        raise ValueError("invalid WAL header")
    order = "<" if magic & 1 == 0 else ">"
    prev = checksum(header[:24], order, (0, 0))
    if prev != (check1, check2):
        raise ValueError("invalid WAL header checksum")
    accum = hashlib.sha256(header)
    frame_len = page + 24
    at = 32
    frames = 0
    commits = []
    while at + frame_len <= size:
        frame = os.pread(fd, frame_len, at)
        if len(frame) != frame_len:
            raise ValueError("WAL changed during check")
        p, dbpages, a, b, x, y = struct.unpack(">6I", frame[:24])
        pair = checksum(frame[24:], order, checksum(frame[:8], order, prev))
        if not p or (a, b) != (salt1, salt2) or pair != (x, y):
            break
        prev = pair
        accum.update(frame)
        frames += 1
        at += frame_len
        if dbpages:
            commits.append(
                {
                    "frame": frames,
                    "end": at,
                    "dbPages": dbpages,
                    "salt": [a, b],
                    "rolling": [x, y],
                    "prefixSHA256": accum.hexdigest(),
                }
            )
    if require_prefix:
        expected = {c["frame"]: c for c in commits}
        if any(expected.get(item["frame"]) != item for item in require_prefix):
            raise ValueError("acknowledged WAL prefix is missing or altered")
    return {
        "headerPageSize": page,
        "bytes": size,
        "validFrames": frames,
        "unparsedTailBytes": size - at,
        "commits": commits,
    }


def facts(raw):
    if raw["txnState"] not in (0, 2):
        raise ValueError("unexpected inventory transaction")
    result = {}
    for item in raw["items"]:
        if item["key"] in result:
            raise ValueError("duplicate item")
        if item["state"] not in ("prepared", "delivered"):
            continue
        if (
            not re.fullmatch(r"[0-9a-f]{64}", item["manifest"])
            or item["ticket"] is None
            or item["reservations"] != int(item["state"] == "prepared")
        ):
            raise ValueError("missing immutable work identity")
        result[item["key"]] = {
            "manifest": item["manifest"],
            "ticketSHA256": digest(canon(json.loads(item["ticket"]))),
            "state": item["state"],
            "reservations": item["reservations"],
        }
    return result


def validate_obligations(records, current):
    for r in records:
        for key, old in r["facts"].items():
            new = current.get(key)
            if (
                new is None
                or new["manifest"] != old["manifest"]
                or new["ticketSHA256"] != old["ticketSHA256"]
            ):
                raise ValueError("confirmed work identity missing")
            if new["state"] not in (
                ("prepared", "delivered")
                if old["state"] == "prepared"
                else ("delivered",)
            ):
                raise ValueError("confirmed work state regressed")
            if new["reservations"] != int(new["state"] == "prepared"):
                raise ValueError("unexpected confirmed name reservation")
